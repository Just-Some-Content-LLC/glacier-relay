defmodule GlacierRelay.Peer.Endpoint do
  @moduledoc """
  M7-B1: the peer link's one endpoint per node (`docs/design/M7_NETWORK_GHOST.md` sections 4.3 and
  15.7): it either **listens** (the headless peer's side) or **connects out** (the game host's side,
  which never listens on a peer port), for exactly one allowlisted peer, one connection at a time.

  B1 is loopback only: a listen address or a connect target other than `{127, 0, 0, 1}` is refused
  at start (`{:not_loopback, ip}`) — no `0.0.0.0`, no `::`, no LAN address, no port proxy. A second
  TCP connection while one is up is closed before its TLS handshake. Each handshake runs with a 5 s
  deadline in the acceptor (or connector) process, after which the socket passes to a new
  `Peer.Connection` with the next connection generation. The connecting side retries every
  `reconnect_ms` while no connection is up, when that option is given (default: no retry).

  Options: `:role` (`:listen` | `:connect`), `:ip`, `:port` (default 4760; 0 picks one when
  listening), `:credentials` (`Peer.TLS.credentials/1`), `:local` (`%{label, client_kind}`; the boot
  id is generated here), `:expected` (`%{label, client_kind}` of the one allowlisted peer),
  `:handler` (`{module, server}`), `:reconnect_ms`, `:name`.
  """

  use GenServer
  require Logger

  alias GlacierRelay.Command.Schema
  alias GlacierRelay.Peer.{Connection, TLS}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def status(server), do: GenServer.call(server, :status)
  def port(server), do: GenServer.call(server, :port)

  @doc "Starts one connection attempt now (connect role)."
  def connect(server), do: GenServer.cast(server, :connect)

  @doc false
  def register(server, socket), do: GenServer.call(server, {:register, socket}, 10_000)

  @impl true
  def init(opts) do
    # connections are linked and die with the endpoint; the endpoint sees their exits
    Process.flag(:trap_exit, true)
    role = Keyword.fetch!(opts, :role)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})

    with true <- role in [:listen, :connect] or {:error, {:bad_role, role}},
         true <- TLS.bind_allowed?(ip) or {:error, {:not_loopback, ip}},
         {:ok, creds} <- TLS.credentials(Keyword.fetch!(opts, :credentials)) do
      local = Keyword.fetch!(opts, :local) |> Map.new() |> Map.put(:boot_id, Schema.uuid4())

      state = %{
        role: role,
        ip: ip,
        port: Keyword.get(opts, :port, 4760),
        creds: creds,
        local: local,
        expected: opts |> Keyword.fetch!(:expected) |> Map.new() |> Map.put(:pin, creds.peer_pin),
        handler: Keyword.fetch!(opts, :handler),
        reconnect_ms: Keyword.get(opts, :reconnect_ms),
        listen_socket: nil,
        acceptor: nil,
        connecting: nil,
        conn: nil,
        next_generation: 1,
        counts: %{connections: 0, refused_busy: 0, handshake_failures: 0, connect_failures: 0}
      }

      case role do
        :listen -> listen(state)
        :connect -> {:ok, maybe_connect(state)}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp listen(state) do
    case :ssl.listen(state.port, TLS.listen_options(state.creds, state.ip)) do
      {:ok, ls} ->
        {:ok, {_ip, bound}} = :ssl.sockname(ls)
        me = self()
        acceptor = spawn_link(fn -> accept_loop(me, ls) end)
        Logger.info("peer endpoint: listening on #{:inet.ntoa(state.ip)}:#{bound} (loopback)")
        {:ok, %{state | listen_socket: ls, port: bound, acceptor: acceptor}}

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  defp maybe_connect(%{conn: nil, connecting: nil} = state) do
    me = self()
    %{ip: ip, port: port} = state
    opts = TLS.connect_options(state.creds)

    {pid, ref} =
      spawn_monitor(fn ->
        case :ssl.connect(ip, port, opts, TLS.handshake_timeout_ms()) do
          {:ok, socket} -> hand_over(me, socket)
          {:error, reason} -> exit({:shutdown, {:connect_failed, reason}})
        end
      end)

    %{state | connecting: {pid, ref}}
  end

  defp maybe_connect(state), do: state

  # in the process that owns the socket: register a connection, pass the socket, start it
  # verifier finding N: a failed hand-over closes the socket and ends the registered connection;
  # the acceptor keeps serving
  defp hand_over(endpoint, socket) do
    case register(endpoint, socket) do
      {:ok, pid} ->
        case :ssl.controlling_process(socket, pid) do
          :ok ->
            Connection.go(pid)

          {:error, _} ->
            :ssl.close(socket)
            Process.exit(pid, :kill)
        end

      {:error, _} ->
        :ssl.close(socket)
    end
  end

  defp accept_loop(endpoint, ls) do
    case :ssl.transport_accept(ls) do
      {:ok, transport} ->
        if GenServer.call(endpoint, :busy?) do
          :ssl.close(transport)
          GenServer.cast(endpoint, :refused_busy)
        else
          case :ssl.handshake(transport, TLS.handshake_timeout_ms()) do
            {:ok, socket} ->
              hand_over(endpoint, socket)

            {:error, reason} ->
              GenServer.cast(endpoint, {:handshake_failed, reason})
          end
        end

        accept_loop(endpoint, ls)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(endpoint, ls)
    end
  end

  # the credentials (with the private key) never appear in a crash report or a :sys.get_status
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{creds: _} = state -> %{state | creds: :redacted}
      other -> other
    end)
  end

  @impl true
  def handle_call(:busy?, _from, state), do: {:reply, state.conn != nil, state}
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call({:register, socket}, _from, %{conn: nil} = state) do
    generation = state.next_generation

    {:ok, pid} =
      Connection.start_link(
        socket: socket,
        role: state.role,
        generation: generation,
        handler: state.handler,
        local: state.local,
        expected: state.expected
      )

    {:reply, {:ok, pid},
     %{
       state
       | conn: %{pid: pid, generation: generation},
         next_generation: generation + 1,
         counts: Map.update!(state.counts, :connections, &(&1 + 1))
     }}
  end

  def handle_call({:register, _socket}, _from, state) do
    {:reply, {:error, :busy},
     %{state | counts: Map.update!(state.counts, :refused_busy, &(&1 + 1))}}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       role: state.role,
       address: {state.ip, state.port},
       local: state.local,
       expected: Map.take(state.expected, [:label, :client_kind, :pin]),
       own_pin: state.creds.own_pin,
       connection: state.conn && %{pid: state.conn.pid, generation: state.conn.generation},
       counts: state.counts
     }, state}
  end

  @impl true
  def handle_cast(:connect, state), do: {:noreply, maybe_connect(state)}

  def handle_cast(:refused_busy, state),
    do: {:noreply, %{state | counts: Map.update!(state.counts, :refused_busy, &(&1 + 1))}}

  def handle_cast({:handshake_failed, reason}, state) do
    Logger.info("peer endpoint: handshake refused (#{inspect(reason)})")
    {:noreply, %{state | counts: Map.update!(state.counts, :handshake_failures, &(&1 + 1))}}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, %{conn: %{pid: pid}} = state) do
    {:noreply, schedule_reconnect(%{state | conn: nil})}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{connecting: {_, ref}} = state) do
    state = %{state | connecting: nil}

    state =
      case reason do
        :normal -> state
        _ -> %{state | counts: Map.update!(state.counts, :connect_failures, &(&1 + 1))}
      end

    {:noreply, if(state.conn == nil, do: schedule_reconnect(state), else: state)}
  end

  def handle_info(:reconnect, state), do: {:noreply, maybe_connect(state)}
  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_reconnect(%{role: :connect, reconnect_ms: ms} = state) when is_integer(ms) do
    Process.send_after(self(), :reconnect, ms)
    state
  end

  defp schedule_reconnect(state), do: state

  @impl true
  def terminate(_reason, state) do
    if state.listen_socket, do: :ssl.close(state.listen_socket)
    if state.conn, do: Process.exit(state.conn.pid, :shutdown)
    :ok
  end
end
