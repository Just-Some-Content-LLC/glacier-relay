defmodule GlacierRelay.Command.Listener do
  @moduledoc """
  The command-link listener (M5-A): loopback only, one accepted link at a time, started only
  inside the optional command subtree. Separate from the telemetry listener (4747) and the
  dashboard endpoint (4748); default `127.0.0.1:4749`. A bind address that is not loopback is
  refused at start. Each accepted socket becomes a `Command.Link` under `Command.LinkSupervisor`;
  the authority decides whether it is the one link or a refused second connection.
  """

  use GenServer
  require Logger

  alias GlacierRelay.Command.Link

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def port, do: GenServer.call(__MODULE__, :port)
  def address, do: GenServer.call(__MODULE__, :address)

  @impl true
  def init(opts) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    port = Keyword.get(opts, :port, 4749)

    if ip != {127, 0, 0, 1} do
      {:stop, {:not_loopback, ip}}
    else
      link_opts = Keyword.take(opts, [:max_line_bytes, :hello_timeout_ms])
      listen_opts = [:binary, ip: ip, packet: :raw, active: false, reuseaddr: true, backlog: 2]

      case :gen_tcp.listen(port, listen_opts) do
        {:ok, listen_socket} ->
          {:ok, {_ip, bound}} = :inet.sockname(listen_socket)
          Logger.info("command link: listening on #{:inet.ntoa(ip)}:#{bound}")
          acceptor = spawn_link(fn -> accept_loop(listen_socket, link_opts) end)
          {:ok, %{listen_socket: listen_socket, ip: ip, port: bound, acceptor: acceptor}}

        {:error, reason} ->
          {:stop, {:listen_failed, reason}}
      end
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:address, _from, state), do: {:reply, {state.ip, state.port}, state}

  @impl true
  def terminate(_reason, state), do: :gen_tcp.close(state.listen_socket)

  defp accept_loop(listen_socket, link_opts) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        case DynamicSupervisor.start_child(
               GlacierRelay.Command.LinkSupervisor,
               {Link, {socket, link_opts}}
             ) do
          {:ok, pid} ->
            :gen_tcp.controlling_process(socket, pid)
            :inet.setopts(socket, active: :once)

          :ignore ->
            # Refused by the link itself (a link is already up); it wrote the refusal and closed.
            :ok

          {:error, reason} ->
            Logger.error("command link: could not start a link process: #{inspect(reason)}")
            :gen_tcp.close(socket)
        end

        accept_loop(listen_socket, link_opts)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.error("command link: accept failed: #{inspect(reason)}")
        accept_loop(listen_socket, link_opts)
    end
  end
end
