defmodule GlacierRelay.Motion.Listener do
  @moduledoc """
  M7-B1: the local motion link's listener (`docs/design/M7_NETWORK_GHOST.md` section 15.5),
  loopback only, started only inside the optional motion subtree; default `127.0.0.1:4750`. A bind
  address other than `{127, 0, 0, 1}` is refused at start. Each accepted socket becomes a
  `Motion.Link` under `Motion.LinkSupervisor` with a 200 ms send deadline that closes the socket on
  timeout; the authority decides whether it binds.
  """

  use GenServer
  require Logger

  alias GlacierRelay.Motion.Link

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def port, do: GenServer.call(__MODULE__, :port)
  def address, do: GenServer.call(__MODULE__, :address)

  @impl true
  def init(opts) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    port = Keyword.get(opts, :port, 4750)

    if ip != {127, 0, 0, 1} do
      {:stop, {:not_loopback, ip}}
    else
      link_opts = Keyword.take(opts, [:hello_timeout_ms])

      listen_opts = [
        :binary,
        ip: ip,
        packet: :raw,
        active: false,
        reuseaddr: true,
        backlog: 2,
        send_timeout: 200,
        send_timeout_close: true
      ]

      case :gen_tcp.listen(port, listen_opts) do
        {:ok, ls} ->
          {:ok, {_ip, bound}} = :inet.sockname(ls)
          Logger.info("motion link: listening on #{:inet.ntoa(ip)}:#{bound}")
          acceptor = spawn_link(fn -> accept_loop(ls, link_opts) end)
          {:ok, %{listen_socket: ls, ip: ip, port: bound, acceptor: acceptor}}

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

  defp accept_loop(ls, link_opts) do
    case :gen_tcp.accept(ls) do
      {:ok, socket} ->
        case DynamicSupervisor.start_child(
               GlacierRelay.Motion.LinkSupervisor,
               {Link, {socket, link_opts}}
             ) do
          {:ok, pid} ->
            :gen_tcp.controlling_process(socket, pid)
            :inet.setopts(socket, active: :once)

          _ ->
            :gen_tcp.close(socket)
        end

        accept_loop(ls, link_opts)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(ls, link_opts)
    end
  end
end
