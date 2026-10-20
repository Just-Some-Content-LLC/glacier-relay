defmodule GlacierRelay.Peer.Endpoint do
  @moduledoc """
  M7-B1: the peer link's one endpoint per node (`docs/design/M7_NETWORK_GHOST.md` sections 4.3 and
  15.7): it either **listens** (the headless peer's side) or **connects out** (the game host's side,
  which never listens on a peer port), for exactly one allowlisted peer, one connection at a time.

  By default it is loopback only, as in B1: a listen address or a connect target other than
  `{127, 0, 0, 1}` is refused at start (`{:not_loopback, ip}`) — no `0.0.0.0`, no `::`, no LAN
  address, no port proxy. M7-L1 (design section 20): the explicit `:network` profile `lan_ipv4`
  instead names one concrete private IPv4 socket for the role (`Peer.Network`); the listener binds
  exactly it and checks its socket name, and the connector checks its peer name. Every socket plan
  is validated before any socket exists.

  Both listeners (the loopback default and the profile; the M7-L1 correction) accept TCP
  themselves and close, before any TLS byte, a connection from any address but a profile's
  declared initiator (`refused_address`) or a second connection while one is up (`refused_busy`),
  then upgrade an admitted one with `:ssl.handshake/3` under the TLS policy
  (`TLS.upgrade_options/1`). A handshake that fails, raises or exits closes its socket and counts a
  handshake failure; the acceptor keeps serving. An endpoint whose acceptor has died stops (closing
  its socket) rather than keep a bound socket that serves no one, and its teardown ends the
  acceptor (with any handshake in progress) and the connection. B1's loopback listener used
  `:ssl.transport_accept/1` and refused with `:ssl.close/1`, which OTP 28 does not perform on a
  `transport_accept` socket, so a refused connection stayed open; and a handshake exit ended its
  acceptor unnoticed (M7-L1 findings). Each handshake runs with a 5 s deadline in the acceptor (or
  connector) process, after which the socket passes to a new `Peer.Connection` with the next
  connection generation. The connecting side retries every `reconnect_ms` while no connection is
  up, when that option is given (default: no retry).

  Options: `:role` (`:listen` | `:connect`), `:ip`, `:port` (default 4760; 0 picks one when
  listening) or instead `:network` (`Peer.Network`), `:credentials` (`Peer.TLS.credentials/1`),
  `:local` (`%{label, client_kind}`; the boot id is generated here), `:expected` (`%{label,
  client_kind}` of the one allowlisted peer), `:handler` (`{module, server}`), `:reconnect_ms`,
  `:name`.
  """

  use GenServer
  require Logger

  alias GlacierRelay.Command.Schema
  alias GlacierRelay.Peer.{Connection, Network, TLS}

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

    # the whole socket plan is validated before any socket exists (M7-L1)
    with true <- role in [:listen, :connect] or {:error, {:bad_role, role}},
         {:ok, plan} <- Network.plan(opts),
         {:ok, creds} <- TLS.credentials(Keyword.fetch!(opts, :credentials)) do
      local = Keyword.fetch!(opts, :local) |> Map.new() |> Map.put(:boot_id, Schema.uuid4())

      state = %{
        role: role,
        ip: plan.ip,
        port: plan.port,
        network: plan,
        # test seam only (M7-L1): the module whose listen/connect calls the endpoint makes (default
        # :gen_tcp for the listener of either plan, :ssl for the connector); an injected one lets a
        # test see the exact non-loopback call without touching the network
        sock: Keyword.get(opts, :socket_module),
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
        counts: %{
          connections: 0,
          refused_busy: 0,
          refused_address: 0,
          handshake_failures: 0,
          connect_failures: 0
        }
      }

      case role do
        :listen -> listen(state)
        :connect -> {:ok, maybe_connect(state)}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # both plans accept TCP themselves (see the moduledoc; the M7-L1 correction): the listen call
  # carries socket options only, and the TLS options go to the acceptor for the upgrade
  defp listen(%{network: plan} = state) do
    case (state.sock || :gen_tcp).listen(state.port, TLS.tcp_listen_options(state.ip)) do
      {:ok, ls} ->
        name = :inet.sockname(ls)

        case Network.check_socket(plan, :bound, name) do
          :ok ->
            {:ok, {_ip, bound}} = name
            me = self()
            tls = TLS.upgrade_options(state.creds)
            acceptor = spawn_link(fn -> accept_loop(me, ls, plan, tls) end)
            Logger.info(listening(plan, state.ip, bound))
            {:ok, %{state | listen_socket: ls, port: bound, acceptor: acceptor}}

          {:error, reason} ->
            :gen_tcp.close(ls)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  defp listening(%{profile: :loopback}, ip, port),
    do: "peer endpoint: listening on #{:inet.ntoa(ip)}:#{port} (loopback)"

  defp listening(plan, _ip, _port), do: "peer endpoint: listening (#{Network.describe(plan)})"

  defp maybe_connect(%{conn: nil, connecting: nil} = state) do
    me = self()
    %{ip: ip, port: port, sock: sock, network: plan} = state
    opts = TLS.connect_options(state.creds)

    {pid, ref} =
      spawn_monitor(fn ->
        case (sock || :ssl).connect(ip, port, opts, TLS.handshake_timeout_ms()) do
          {:ok, socket} ->
            # M7-L1: the connection reached exactly the declared destination
            case Network.check_socket(plan, :peer, :ssl.peername(socket)) do
              :ok ->
                hand_over(me, socket)

              {:error, reason} ->
                :ssl.close(socket)
                exit({:shutdown, {:connect_refused, reason}})
            end

          {:error, reason} ->
            exit({:shutdown, {:connect_failed, reason}})
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

  # The listener's loop (both plans). Only an allowed address (a profile's declared initiator; any
  # under the loopback plan), and only while no connection is up, reaches the TLS handshake;
  # anything else is closed with no TLS byte sent. The handshake's options hold the private key, so
  # a raise inside it is caught and reduced to its exception name.
  defp accept_loop(endpoint, ls, plan, tls) do
    case :gen_tcp.accept(ls) do
      {:ok, tcp} ->
        remote =
          case :inet.peername(tcp) do
            {:ok, {ip, _port}} -> ip
            {:error, reason} -> {:error, reason}
          end

        cond do
          not Network.initiator_allowed?(plan, remote) ->
            :gen_tcp.close(tcp)
            GenServer.cast(endpoint, {:refused_address, remote})

          GenServer.call(endpoint, :busy?) ->
            :gen_tcp.close(tcp)
            GenServer.cast(endpoint, :refused_busy)

          true ->
            case upgrade(tcp, tls) do
              {:ok, socket} ->
                hand_over(endpoint, socket)

              {:error, reason} ->
                :gen_tcp.close(tcp)
                GenServer.cast(endpoint, {:handshake_failed, reason})
            end
        end

        accept_loop(endpoint, ls, plan, tls)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(endpoint, ls, plan, tls)
    end
  end

  # verifier V3: :ssl.handshake/3 can also exit (a key that does not decode); either way the acceptor
  # survives and counts a handshake failure
  defp upgrade(tcp, tls) do
    :ssl.handshake(tcp, tls, TLS.handshake_timeout_ms())
  rescue
    e -> {:error, {:handshake_raised, e.__struct__}}
  catch
    :exit, _ -> {:error, :handshake_exited}
  end

  # the credentials (with the private key) never appear in a crash report or a :sys.get_status —
  # nor does the listen socket (B1's TLS listen socket embedded the TLS options, the private key
  # included: an M7-L1 finding; the listen socket is now a TCP socket, and stays redacted)
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{creds: _} = state -> %{state | creds: :redacted, listen_socket: :redacted}
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
       network: Network.describe(state.network),
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

  def handle_cast({:refused_address, remote}, state) do
    Logger.info("peer endpoint: connection from #{inspect(remote)} refused (not the initiator)")
    {:noreply, %{state | counts: Map.update!(state.counts, :refused_address, &(&1 + 1))}}
  end

  def handle_cast({:handshake_failed, reason}, state) do
    Logger.info("peer endpoint: handshake refused (#{inspect(reason)})")
    {:noreply, %{state | counts: Map.update!(state.counts, :handshake_failures, &(&1 + 1))}}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, %{conn: %{pid: pid}} = state) do
    {:noreply, schedule_reconnect(%{state | conn: nil})}
  end

  # M7-L1 (verifier V3; both plans since the correction): a listener whose acceptor has died stops,
  # closing its socket, rather than keep a bound socket that serves and closes no one
  def handle_info({:EXIT, pid, reason}, %{acceptor: pid} = state),
    do: {:stop, {:acceptor_exited, reason}, %{state | acceptor: nil}}

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

  # the acceptor first (the M7-L1 correction: a handshake in progress, with its socket, no longer
  # outlives the endpoint; its owner gone, the TLS connection process closes it), then the listen
  # socket, then the connection
  @impl true
  def terminate(_reason, state) do
    if state.acceptor, do: Process.exit(state.acceptor, :kill)
    if state.listen_socket, do: :gen_tcp.close(state.listen_socket)
    if state.conn, do: Process.exit(state.conn.pid, :shutdown)
    :ok
  end
end
