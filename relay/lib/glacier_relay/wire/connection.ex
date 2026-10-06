defmodule GlacierRelay.Wire.Connection do
  @moduledoc """
  One accepted TCP connection from a native adapter. Owns the socket, frames NDJSON, decodes and
  validates each envelope, and hands valid ones to `GlacierRelay.MissionSession`.

  Failure policy:
  - a line that is not a valid envelope is logged and dropped; the connection continues
  - a line longer than the limit closes the connection (the stream cannot be resynchronised)
  - nothing is ever sent back; there is no inbound protocol on the native side in M1
  """

  use GenServer, restart: :temporary
  require Logger

  alias GlacierRelay.MissionSession
  alias GlacierRelay.Wire.{Envelope, Framing}

  def start_link({socket, max_line_bytes}) do
    GenServer.start_link(__MODULE__, {socket, max_line_bytes})
  end

  @impl true
  def init({socket, max_line_bytes}) do
    {:ok,
     %{
       socket: socket,
       framing: Framing.new(max_line_bytes),
       peer: peer(socket),
       lines: 0,
       rejected: 0
     }}
  end

  @impl true
  def handle_info({:tcp, socket, bytes}, %{socket: socket} = state) do
    case Framing.push(state.framing, bytes) do
      {:ok, lines, framing} ->
        state = Enum.reduce(lines, %{state | framing: framing}, &handle_line/2)
        :inet.setopts(socket, active: :once)
        {:noreply, state}

      {:error, :line_too_long} ->
        Logger.error("relay: #{state.peer}: line exceeds the limit; closing")
        :gen_tcp.close(socket)
        {:stop, :normal, state}
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Logger.info(
      "relay: #{state.peer} disconnected after #{state.lines} line(s), #{state.rejected} rejected"
    )

    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.warning("relay: #{state.peer} socket error #{inspect(reason)}")
    {:stop, :normal, state}
  end

  defp handle_line(line, state) do
    state = %{state | lines: state.lines + 1}

    case Envelope.decode(line) do
      {:ok, envelope} ->
        MissionSession.handle_event(envelope)
        state

      {:error, reason} ->
        Logger.warning("relay: #{state.peer}: rejected line #{state.lines}: #{inspect(reason)}")
        %{state | rejected: state.rejected + 1}
    end
  end

  defp peer(socket) do
    case :inet.peername(socket) do
      {:ok, {ip, port}} -> "#{:inet.ntoa(ip)}:#{port}"
      _ -> "unknown peer"
    end
  end
end
