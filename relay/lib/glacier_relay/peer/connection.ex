defmodule GlacierRelay.Peer.Connection do
  @moduledoc """
  M7-B1: one authenticated peer connection (`docs/design/M7_NETWORK_GHOST.md` sections 15.2,
  15.6 and 15.7), started by `Peer.Endpoint` after the TLS handshake for either role. It re-checks
  the pin on the received DER, exchanges `hello` (within 2 s; the peer's label and client kind must
  equal the configured allowlisted peer, and its boot must differ from this node's), then carries
  the stream messages to its **handler** — `Motion.Hub` on a game host, `HeadlessPeer.Driver` on a
  headless peer — and nothing else: a message here never authorizes anything.

  Inbound: one TLS read at a time (`active: :once`); each line is decoded strictly
  (`Peer.Codec`) and handled before the next read, so a slow handler applies backpressure to the
  peer instead of growing a mailbox; a handler that does not answer within 200 ms closes the
  connection. A headless peer may open only `synthetic` streams; at most two streams are open per
  connection; a sample, an end or a second open naming a stream not open on this connection is a
  violation. Any violation closes the connection (no resynchronization).

  Outbound: `send_sample/2` and `send_control/3` are bounded before anything is queued — at most 8
  samples and 16 control messages waiting for this process (an `:atomics` count). A sample above the
  bound is dropped by its producer (`{:error, :backlog}`, counted there); a sample that waited more
  than 100 ms is dropped here as stale (counted); a control message above the bound closes the
  connection, so stop stays possible. Every TLS send has a 500 ms deadline and closes on timeout.
  Liveness: `ping` every second (the RTT is measured on this node's clock only, from its own
  `sender_mono_ms` echoed back); three seconds without any input closes the connection.
  """

  use GenServer, restart: :temporary
  require Logger

  alias GlacierRelay.Motion.Clock
  alias GlacierRelay.Peer.{Codec, TLS}
  alias GlacierRelay.Wire.Framing

  @hello_timeout_ms 2_000
  @ping_ms 1_000
  @idle_ms 3_000
  @handler_timeout_ms 200
  @sample_credits 8
  @control_credits 16
  @max_send_age_ms 100
  @max_streams 2

  def limits,
    do: %{
      hello_timeout_ms: @hello_timeout_ms,
      ping_ms: @ping_ms,
      idle_ms: @idle_ms,
      handler_timeout_ms: @handler_timeout_ms,
      sample_credits: @sample_credits,
      control_credits: @control_credits,
      max_send_age_ms: @max_send_age_ms,
      max_streams: @max_streams
    }

  # -- producer API (any process holding the connection's info) -------------------------------------

  @doc "Queues one `pose.sample` (bounded). `:ok` or `{:error, :backlog}`."
  def send_sample(%{connection: pid, credits: ref}, fields) when is_map(fields) do
    if :atomics.add_get(ref, 1, 1) > @sample_credits do
      :atomics.sub(ref, 1, 1)
      {:error, :backlog}
    else
      GenServer.cast(pid, {:sample, fields, Clock.now_ms()})
      :ok
    end
  end

  @doc "Queues one control message (bounded; an overflow closes the connection)."
  def send_control(%{connection: pid, credits: ref}, kind, fields)
      when is_binary(kind) and is_map(fields) do
    if :atomics.add_get(ref, 2, 1) > @control_credits do
      :atomics.sub(ref, 2, 1)
      Process.exit(pid, {:shutdown, :control_overflow})
      {:error, :control_overflow}
    else
      GenServer.cast(pid, {:control, kind, fields})
      :ok
    end
  end

  @doc "Closes the connection (a `bye` is attempted)."
  def close(%{connection: pid}, reason), do: GenServer.cast(pid, {:close, reason})

  @doc "This connection's counters and identity (no credential)."
  def status(pid), do: GenServer.call(pid, :status)

  # -- lifecycle ---------------------------------------------------------------------------------------

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  # called by the endpoint once the socket's controlling process is this connection
  def go(pid), do: GenServer.cast(pid, :go)

  @impl true
  def init(opts) do
    # the endpoint must hand the socket over and say go within the handshake deadline
    Process.send_after(self(), :tls_timeout, TLS.handshake_timeout_ms())

    {:ok,
     %{
       socket: Keyword.fetch!(opts, :socket),
       role: Keyword.fetch!(opts, :role),
       generation: Keyword.fetch!(opts, :generation),
       handler: Keyword.fetch!(opts, :handler),
       local: Keyword.fetch!(opts, :local),
       expected: Keyword.fetch!(opts, :expected),
       credits: :atomics.new(2, signed: true),
       framing: Framing.new(Codec.max_line_bytes()),
       phase: :tls,
       remote: nil,
       streams: %{},
       hello_timer: nil,
       ping_timer: nil,
       ping_seq: 0,
       ping_sent: nil,
       last_inbound: Clock.now_ms(),
       closed: false,
       counts: %{
         lines_in: 0,
         lines_out: 0,
         samples_in: 0,
         samples_out: 0,
         samples_stale: 0,
         controls_out: 0,
         pings: 0,
         pongs: 0
       },
       last_rtt_ms: nil
     }}
  end

  @impl true
  def handle_cast(:go, %{phase: :tls} = state) do
    case TLS.check_peer(state.socket, state.expected.pin) do
      :ok ->
        line = Codec.hello(state.local.label, state.local.client_kind, state.local.boot_id)

        case :ssl.send(state.socket, line) do
          :ok ->
            :ssl.setopts(state.socket, active: :once)
            timer = Process.send_after(self(), :hello_timeout, @hello_timeout_ms)
            {:noreply, %{state | phase: :awaiting_hello, hello_timer: timer} |> out(:lines_out)}

          {:error, reason} ->
            shutdown(state, {:send_failed, reason})
        end

      {:error, reason} ->
        shutdown(state, {:peer_check_failed, reason})
    end
  end

  def handle_cast({:sample, fields, enqueued}, state) do
    :atomics.sub(state.credits, 1, 1)

    cond do
      state.phase != :identified or state.closed ->
        {:noreply, state}

      Clock.now_ms() - enqueued > @max_send_age_ms ->
        {:noreply, out(state, :samples_stale)}

      true ->
        send_line(state, Codec.encode("pose.sample", fields), :samples_out)
    end
  end

  def handle_cast({:control, kind, fields}, state) do
    :atomics.sub(state.credits, 2, 1)

    if state.phase != :identified or state.closed,
      do: {:noreply, state},
      else: send_line(state, Codec.encode(kind, fields), :controls_out)
  end

  def handle_cast({:close, reason}, state), do: shutdown(state, {:local, reason}, true)

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       role: state.role,
       generation: state.generation,
       phase: state.phase,
       remote: state.remote,
       streams: Map.keys(state.streams),
       counts: state.counts,
       last_rtt_ms: state.last_rtt_ms,
       queued_samples: :atomics.get(state.credits, 1),
       queued_controls: :atomics.get(state.credits, 2)
     }, state}
  end

  @impl true
  def handle_info({:ssl, socket, bytes}, %{socket: socket} = state) do
    state = %{state | last_inbound: Clock.now_ms()}

    case Framing.push(state.framing, bytes) do
      {:ok, lines, framing} ->
        case Enum.reduce_while(lines, {:ok, %{state | framing: framing}}, &line/2) do
          {:ok, state} ->
            :ssl.setopts(socket, active: :once)
            {:noreply, state}

          {:close, reason, state} ->
            shutdown(state, reason, true)
        end

      {:error, :line_too_long} ->
        shutdown(state, {:violation, :line_too_long}, true)
    end
  end

  def handle_info({:ssl_closed, socket}, %{socket: socket} = state),
    do: shutdown(state, :peer_closed)

  def handle_info({:ssl_error, socket, reason}, %{socket: socket} = state),
    do: shutdown(state, {:tls_error, reason})

  def handle_info(:hello_timeout, %{phase: :awaiting_hello} = state),
    do: shutdown(state, {:violation, :hello_timeout}, true)

  def handle_info(:hello_timeout, state), do: {:noreply, state}

  def handle_info(:tls_timeout, %{phase: :tls} = state),
    do: {:stop, :normal, %{state | closed: true}}

  def handle_info(:tls_timeout, state), do: {:noreply, state}

  def handle_info(:ping, %{phase: :identified} = state) do
    now = Clock.now_ms()

    if now - state.last_inbound >= @idle_ms do
      shutdown(state, :idle, true)
    else
      seq = state.ping_seq + 1

      state = %{
        state
        | ping_seq: seq,
          ping_sent: {seq, now},
          ping_timer: Process.send_after(self(), :ping, @ping_ms)
      }

      send_line(
        state,
        Codec.encode("ping", %{"ping_seq" => seq, "sender_mono_ms" => now}),
        :pings
      )
    end
  end

  def handle_info(:ping, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # -- lines -------------------------------------------------------------------------------------------

  defp line(bytes, {:ok, state}) do
    state = out(state, :lines_in)

    case {Codec.decode(bytes), state.phase} do
      {{:ok, {:hello, h}}, :awaiting_hello} ->
        hello(h, state)

      {{:ok, {:hello, _}}, _} ->
        {:halt, {:close, {:violation, :hello_after_handshake}, state}}

      {{:ok, _}, :awaiting_hello} ->
        {:halt, {:close, {:violation, :message_before_hello}, state}}

      {{:ok, {:stream_open, f}}, :identified} ->
        stream_open(f, state)

      {{:ok, {:pose_sample, f}}, :identified} ->
        if Map.has_key?(state.streams, f.stream_id) do
          state = out(state, :samples_in)
          event(state, {:sample, info(state), f})
        else
          {:halt, {:close, {:violation, :sample_for_a_stream_not_open}, state}}
        end

      {{:ok, {:stream_end, f}}, :identified} ->
        if Map.has_key?(state.streams, f.stream_id) do
          event(
            %{state | streams: Map.delete(state.streams, f.stream_id)},
            {:stream_end, info(state), f}
          )
        else
          {:halt, {:close, {:violation, :end_for_a_stream_not_open}, state}}
        end

      {{:ok, {:ping, f}}, :identified} ->
        case :ssl.send(
               state.socket,
               Codec.encode("pong", %{
                 "ping_seq" => f.ping_seq,
                 "echo_mono_ms" => f.sender_mono_ms
               })
             ) do
          :ok -> {:cont, {:ok, out(state, :lines_out)}}
          {:error, reason} -> {:halt, {:close, {:send_failed, reason}, state}}
        end

      {{:ok, {:pong, f}}, :identified} ->
        # the RTT on this node's clock only, from the send time it kept itself (verifier finding
        # M: the peer's echo is never trusted); an unmatched pong is counted and ignored
        state = out(state, :pongs)

        case state.ping_sent do
          {seq, sent} when seq == f.ping_seq ->
            rtt = Clock.now_ms() - sent
            state = %{state | last_rtt_ms: rtt, ping_sent: nil}
            notify(state, {:rtt, info(state), %{ping_seq: seq, rtt_ms: rtt}})
            {:cont, {:ok, state}}

          _ ->
            {:cont, {:ok, state}}
        end

      {{:ok, {:bye, f}}, _} ->
        {:halt, {:close, {:peer_bye, f.reason}, state}}

      {{:error, reason}, _} ->
        {:halt, {:close, {:violation, reason}, state}}
    end
  end

  defp hello(h, state) do
    e = state.expected

    cond do
      h.peer_label != e.label ->
        {:halt, {:close, {:violation, :foreign_peer_label}, state}}

      h.client_kind != e.client_kind ->
        {:halt, {:close, {:violation, :client_kind_mismatch}, state}}

      h.boot_id == state.local.boot_id ->
        {:halt, {:close, {:violation, :self_connection}, state}}

      true ->
        if state.hello_timer, do: Process.cancel_timer(state.hello_timer)

        state = %{
          state
          | phase: :identified,
            hello_timer: nil,
            remote: %{label: h.peer_label, client_kind: h.client_kind, boot_id: h.boot_id},
            ping_timer: Process.send_after(self(), :ping, @ping_ms)
        }

        event(state, {:up, info(state)})
    end
  end

  defp stream_open(f, state) do
    cond do
      Map.has_key?(state.streams, f.stream_id) ->
        {:halt, {:close, {:violation, :stream_already_open}, state}}

      map_size(state.streams) >= @max_streams ->
        {:halt, {:close, {:violation, :too_many_streams}, state}}

      state.remote.client_kind == "headless" and f.source_kind != "synthetic" ->
        {:halt, {:close, {:violation, :headless_peer_declared_game_source}, state}}

      true ->
        state = %{state | streams: Map.put(state.streams, f.stream_id, f.source_kind)}
        event(state, {:stream_open, info(state), f})
    end
  end

  defp info(state),
    do: %{
      connection: self(),
      credits: state.credits,
      generation: state.generation,
      role: state.role,
      label: state.remote && state.remote.label,
      client_kind: state.remote && state.remote.client_kind,
      boot_id: state.remote && state.remote.boot_id,
      pin: state.expected.pin
    }

  # a handler call with a deadline; a slow or failed handler closes the connection
  defp event(state, ev) do
    {mod, server} = state.handler

    try do
      case mod.peer_event(server, ev, @handler_timeout_ms) do
        :ok -> {:cont, {:ok, state}}
        {:close, reason} -> {:halt, {:close, {:handler, reason}, state}}
      end
    catch
      :exit, reason -> {:halt, {:close, {:handler_unavailable, short(reason)}, state}}
    end
  end

  defp notify(state, ev) do
    {mod, server} = state.handler
    mod.peer_notify(server, ev)
  end

  defp send_line(state, line, counter) do
    case :ssl.send(state.socket, line) do
      :ok -> {:noreply, state |> out(:lines_out) |> out(counter)}
      {:error, reason} -> shutdown(state, {:send_failed, reason})
    end
  end

  defp shutdown(state, reason, say_bye \\ false)
  defp shutdown(%{closed: true} = state, _reason, _bye), do: {:stop, :normal, state}

  defp shutdown(state, reason, say_bye) do
    if say_bye and state.phase == :identified do
      _ = :ssl.send(state.socket, Codec.encode("bye", %{"reason" => reason_text(reason)}))
    end

    _ = :ssl.close(state.socket)
    if state.phase in [:identified], do: notify(state, {:down, info(state), reason})
    Logger.info("peer connection #{state.generation}: closed (#{inspect(short(reason))})")
    {:stop, :normal, %{state | closed: true}}
  end

  defp out(state, key), do: %{state | counts: Map.update!(state.counts, key, &(&1 + 1))}

  defp reason_text(reason),
    do: GlacierRelay.Motion.Codec.to_text(inspect(short(reason)))

  defp short({:timeout, _}), do: :timeout
  defp short(reason), do: reason
end
