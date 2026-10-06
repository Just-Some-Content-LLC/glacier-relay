defmodule GlacierRelay.Wire.Listener do
  @moduledoc """
  Owns the listening socket and accepts native adapter connections.

  The GenServer holds the listen socket; a linked acceptor process blocks in `accept` and starts
  one `GlacierRelay.Wire.Connection` per client under `GlacierRelay.Wire.ConnectionSupervisor`,
  handing over socket ownership. If the listener dies, the supervisor restarts it and it binds
  again; live connections are independent processes and survive.

  Bind address and port come from `config :glacier_relay, GlacierRelay.Wire.Listener`. Only
  loopback is intended; see the M1 design, section 6.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The port actually bound (useful when configured as 0)."
  def port, do: GenServer.call(__MODULE__, :port)

  @doc "The bound address and port."
  def address, do: GenServer.call(__MODULE__, :address)

  @impl true
  def init(_opts) do
    config = Application.fetch_env!(:glacier_relay, __MODULE__)
    ip = Keyword.fetch!(config, :ip)
    max_line_bytes = Keyword.fetch!(config, :max_line_bytes)

    listen_opts = [:binary, ip: ip, packet: :raw, active: false, reuseaddr: true, backlog: 8]

    case :gen_tcp.listen(Keyword.fetch!(config, :port), listen_opts) do
      {:ok, listen_socket} ->
        {:ok, {_ip, port}} = :inet.sockname(listen_socket)
        Logger.info("relay: listening on #{:inet.ntoa(ip)}:#{port}")

        acceptor = spawn_link(fn -> accept_loop(listen_socket, max_line_bytes) end)
        {:ok, %{listen_socket: listen_socket, ip: ip, port: port, acceptor: acceptor}}

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:address, _from, state), do: {:reply, {state.ip, state.port}, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen_socket)
  end

  defp accept_loop(listen_socket, max_line_bytes) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        case DynamicSupervisor.start_child(
               GlacierRelay.Wire.ConnectionSupervisor,
               {GlacierRelay.Wire.Connection, {socket, max_line_bytes}}
             ) do
          {:ok, pid} ->
            # The peer may already have gone away; the connection process finds out on its own.
            peer =
              case :inet.peername(socket) do
                {:ok, {ip, port}} -> "#{:inet.ntoa(ip)}:#{port}"
                {:error, _} -> "a peer that closed immediately"
              end

            :gen_tcp.controlling_process(socket, pid)
            :inet.setopts(socket, active: :once)
            Logger.info("relay: accepted #{peer}")

          {:error, reason} ->
            Logger.error("relay: could not start a connection process: #{inspect(reason)}")
            :gen_tcp.close(socket)
        end

        accept_loop(listen_socket, max_line_bytes)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.error("relay: accept failed: #{inspect(reason)}")
        accept_loop(listen_socket, max_line_bytes)
    end
  end
end
