defmodule GlacierRelay.Motion.Link do
  @moduledoc """
  M7-B1: one accepted motion-link connection (`docs/design/M7_NETWORK_GHOST.md` section 15.5). It
  frames lines (1,024 bytes), decodes them strictly (`Motion.Codec`) and decides nothing itself:
  the **binding** is the authority's (`Command.Authority.motion_hello/3`, `motion_attest/2`) and
  every bound message goes to `Motion.Hub`.

  Binding: `motion.hello` naming the current, token-verified command link's adapter and
  generation; `motion.welcome` with a fresh nonce; `motion.attest` (the run-token HMAC) within the
  hello deadline (2 s). Anything else before the binding, a second hello or attest, an oversized or
  undecodable line, or a hub that does not answer within 500 ms closes the link (no
  resynchronization). Loopback access alone binds nothing. The authority drops the link when its
  command link goes; the native closes its share and session on the loss.
  """

  use GenServer, restart: :temporary
  require Logger

  alias GlacierRelay.Command.Authority
  alias GlacierRelay.Motion.{Codec, Hub}
  alias GlacierRelay.Wire.Framing

  @hub_timeout_ms 500

  def start_link({socket, opts}), do: GenServer.start_link(__MODULE__, {socket, opts})

  @impl true
  def init({socket, opts}) do
    timer =
      Process.send_after(self(), :binding_timeout, Keyword.get(opts, :hello_timeout_ms, 2_000))

    {:ok,
     %{
       socket: socket,
       framing: Framing.new(Codec.max_line_bytes()),
       phase: :connected,
       generation: nil,
       adapter: nil,
       command_generation: nil,
       timer: timer,
       closed: false
     }}
  end

  @impl true
  def handle_info({:tcp, socket, bytes}, %{socket: socket} = state) do
    case Framing.push(state.framing, bytes) do
      {:ok, lines, framing} ->
        case Enum.reduce_while(lines, {:ok, %{state | framing: framing}}, &line/2) do
          {:ok, state} ->
            :inet.setopts(socket, active: :once)
            {:noreply, state}

          {:close, reason, state} ->
            {:stop, :normal, close(state, reason)}
        end

      {:error, :line_too_long} ->
        {:stop, :normal, close(state, {:violation, :line_too_long})}
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: {:stop, :normal, close(state, :peer_closed)}

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state),
    do: {:stop, :normal, close(state, {:tcp_error, reason})}

  def handle_info(:binding_timeout, %{phase: phase} = state) when phase != :bound,
    do: {:stop, :normal, close(state, {:violation, :binding_timeout})}

  def handle_info(:binding_timeout, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: close(state, :link_process_exit)

  defp line(bytes, {:ok, state}) do
    case {Codec.decode_from_native(bytes), state.phase} do
      {{:ok, {:motion_hello, h}}, :connected} ->
        case Authority.motion_hello(self(), h.adapter_instance_id, h.command_link_generation) do
          {:ok, generation, nonce} ->
            case :gen_tcp.send(state.socket, Codec.welcome(generation, nonce)) do
              :ok ->
                {:cont,
                 {:ok,
                  %{
                    state
                    | phase: :welcomed,
                      generation: generation,
                      adapter: h.adapter_instance_id,
                      command_generation: h.command_link_generation
                  }}}

              {:error, reason} ->
                {:halt, {:close, {:welcome_not_sent, reason}, state}}
            end

          {:error, reason} ->
            _ = :gen_tcp.send(state.socket, Codec.refused(reason))
            {:halt, {:close, {:refused, reason}, state}}
        end

      {{:ok, {:motion_attest, a}}, :welcomed} ->
        with :ok <- Authority.motion_attest(state.generation, a),
             :ok <-
               Hub.link_bound(%{
                 generation: state.generation,
                 socket: state.socket,
                 pid: self(),
                 adapter_instance_id: state.adapter,
                 command_link_generation: state.command_generation
               }) do
          if state.timer, do: Process.cancel_timer(state.timer)
          {:cont, {:ok, %{state | phase: :bound, timer: nil}}}
        else
          {:error, reason} ->
            _ = :gen_tcp.send(state.socket, Codec.refused(reason))
            {:halt, {:close, {:attest_failed, reason}, state}}
        end

      {{:ok, {kind, _}}, phase} when kind in [:motion_hello, :motion_attest] ->
        {:halt, {:close, {:violation, {kind, :out_of_order, phase}}, state}}

      {{:ok, {kind, fields}}, :bound} ->
        try do
          case Hub.native(state.generation, {kind, fields}, @hub_timeout_ms) do
            :ok -> {:cont, {:ok, state}}
            {:close, reason} -> {:halt, {:close, {:hub, reason}, state}}
          end
        catch
          :exit, _ -> {:halt, {:close, :hub_unavailable, state}}
        end

      {{:ok, {kind, _}}, phase} ->
        {:halt, {:close, {:violation, {kind, :before_binding, phase}}, state}}

      {{:error, reason}, _} ->
        {:halt, {:close, {:violation, reason}, state}}
    end
  end

  defp close(%{closed: true} = state, _reason), do: state

  defp close(state, reason) do
    if state.generation, do: Authority.motion_link_closed(state.generation, reason)
    :gen_tcp.close(state.socket)
    Logger.info("motion link #{inspect(state.generation)}: closed (#{inspect(reason)})")
    %{state | closed: true}
  end
end
