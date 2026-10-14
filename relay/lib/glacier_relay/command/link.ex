defmodule GlacierRelay.Command.Link do
  @moduledoc """
  One accepted command-link connection (M5-A). Owns the socket, frames lines (4 KiB), decodes them
  strictly with `Command.Schema`, and hands every peer message to `Command.Authority` with the
  link generation the authority assigned. The link itself decides nothing: the authority owns the
  handshake states, the trust labels and every command.

  Failure policy: a line that does not decode, a hello after the handshake, a result before it, an
  oversized line or a hello that does not arrive in time is a protocol violation — reported to
  the authority and the link closes (the conservative failure; nothing is tolerated and retried).
  A second connection while one link is up is refused with a `refused` line and closed.
  """

  use GenServer, restart: :temporary
  require Logger

  alias GlacierRelay.Command.{Authority, Schema}
  alias GlacierRelay.Wire.Framing

  def start_link({socket, opts}), do: GenServer.start_link(__MODULE__, {socket, opts})

  @doc "Writes one already encoded line to the peer."
  def send_line(pid, line) when is_binary(line), do: GenServer.call(pid, {:send, line})

  @impl true
  def init({socket, opts}) do
    peer = peer(socket)

    case Authority.link_opened(self(), peer) do
      {:ok, generation} ->
        hello_timeout = Keyword.get(opts, :hello_timeout_ms, 2_000)
        timer = Process.send_after(self(), :hello_timeout, hello_timeout)

        {:ok,
         %{
           socket: socket,
           generation: generation,
           peer: peer,
           framing: Framing.new(Keyword.get(opts, :max_line_bytes, Schema.max_line_bytes())),
           phase: :connected,
           hello_timer: timer,
           closed: false
         }}

      {:error, :busy} ->
        _ = :gen_tcp.send(socket, Schema.encode_refusal(:busy))
        :gen_tcp.close(socket)
        Logger.warning("command link: refused #{peer}: a link is already up")
        :ignore
    end
  end

  @impl true
  def handle_call({:send, line}, _from, state) do
    {:reply, :gen_tcp.send(state.socket, line), state}
  end

  @impl true
  def handle_info({:tcp, socket, bytes}, %{socket: socket} = state) do
    case Framing.push(state.framing, bytes) do
      {:ok, lines, framing} ->
        case Enum.reduce_while(lines, {:ok, %{state | framing: framing}}, &handle_line/2) do
          {:ok, state} ->
            :inet.setopts(socket, active: :once)
            {:noreply, state}

          {:violation, reason, state} ->
            {:stop, :normal, close(state, {:protocol_violation, reason})}
        end

      {:error, :line_too_long} ->
        {:stop, :normal, close(state, {:protocol_violation, :line_too_long})}
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: {:stop, :normal, close(state, :peer_closed)}

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state),
    do: {:stop, :normal, close(state, {:tcp_error, reason})}

  def handle_info(:hello_timeout, %{phase: :connected} = state),
    do: {:stop, :normal, close(state, {:protocol_violation, :hello_timeout})}

  def handle_info(:hello_timeout, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: close(state, :link_process_exit)

  # -- lines ------------------------------------------------------------------------------------

  defp handle_line(line, {:ok, state}) do
    case {Schema.decode_line(line), state.phase} do
      {{:ok, {:hello, hello}}, :connected} ->
        case Authority.peer_hello(state.generation, hello) do
          {:ok, welcome} ->
            if state.hello_timer, do: Process.cancel_timer(state.hello_timer)

            case :gen_tcp.send(state.socket, welcome) do
              :ok -> {:cont, {:ok, %{state | phase: :identified, hello_timer: nil}}}
              {:error, reason} -> {:halt, {:violation, {:welcome_not_sent, reason}, state}}
            end

          {:error, reason} ->
            {:halt, {:violation, reason, state}}
        end

      {{:ok, {:hello, _}}, _} ->
        {:halt, {:violation, :hello_after_handshake, state}}

      {{:ok, {:result, result}}, :identified} ->
        Authority.result(state.generation, result)
        {:cont, {:ok, state}}

      {{:ok, {:result, _}}, _} ->
        {:halt, {:violation, :result_before_handshake, state}}

      {{:error, reason}, _} ->
        {:halt, {:violation, reason, state}}
    end
  end

  # Reports the close to the authority exactly once, then closes the socket.
  defp close(%{closed: true} = state, _reason), do: state

  defp close(state, reason) do
    Authority.link_closed(state.generation, reason)
    :gen_tcp.close(state.socket)
    Logger.info("command link: #{state.peer} closed (#{inspect(reason)})")
    %{state | closed: true}
  end

  defp peer(socket) do
    case :inet.peername(socket) do
      {:ok, {ip, port}} -> "#{:inet.ntoa(ip)}:#{port}"
      _ -> "unknown peer"
    end
  end
end
