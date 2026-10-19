defmodule GlacierRelay.HeadlessPeer.Driver do
  @moduledoc """
  M7-B1: the headless peer's driver — the handler of its one peer connection, a synthetic **source**
  and a recording **sink** (`docs/design/M7_NETWORK_GHOST.md` sections 9, 15.2, 15.8 and 15.9).

  Source (`start_course/2`): one stream per course run — a fresh `stream_id`, `source_kind:
  synthetic`, the course's description and label — then the course's deterministic samples
  (`Motion.Course.samples/1`) at its interval, scheduled from the run's start (no drift), each
  stamped with this node's clock as `src_mono_ms` (`src_clock: beam`), all `qualified`; a sample
  the connection cannot queue is dropped and counted, never retried; then `stream.end` with the
  last sequence number and the number sent. `stop_course/1` ends the stream early.

  Sink: for every inbound stream, its declared kind, clock, label and course; counts received,
  duplicates, older, gaps, qualified / unqualified; the declared sampling bounds checked
  (`sink_bounds`: area around a centre, a minimum receipt interval — a check, not an approval);
  every sample traced; at `stream.end` the source's `last_seq` and `sent` reconciled against what
  arrived. The sink only records: nothing it receives reaches the source or any send.
  """

  use GenServer
  require Logger

  alias GlacierRelay.Command.{Schema, TransformWords}
  alias GlacierRelay.Motion.{Clock, Course, Trace}
  alias GlacierRelay.Peer.Connection

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Starts a course stream to the connected game host. `opts`: `:label`."
  def start_course(%Course{} = course, opts \\ []),
    do: GenServer.call(__MODULE__, {:start_course, course, opts})

  def stop_course(reason \\ :operator), do: GenServer.call(__MODULE__, {:stop_course, reason})

  # -- peer handler -----------------------------------------------------------------------------------

  @doc false
  def peer_event(server, event, timeout), do: GenServer.call(server, {:peer, event}, timeout)
  @doc false
  def peer_notify(server, event), do: GenServer.cast(server, {:peer_notify, event})

  @impl true
  def init(opts) do
    {:ok,
     %{
       trace: Keyword.fetch!(opts, :trace),
       bounds: Keyword.get(opts, :sink_bounds),
       peer: nil,
       source: nil,
       sources_done: [],
       streams: %{},
       done: [],
       counts: %{trace_refused: 0}
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       peer: state.peer && Map.take(state.peer.info, [:generation, :label, :client_kind, :boot_id, :pin]),
       source: state.source && source_view(state.source),
       sources_done: state.sources_done,
       sink: Map.new(state.streams, fn {id, s} -> {id, sink_view(s)} end),
       sink_done: state.done,
       counts: state.counts
     }, state}
  end

  def handle_call({:start_course, course, opts}, _from, state) do
    cond do
      state.peer == nil ->
        {:reply, {:error, :no_peer}, state}

      state.source != nil ->
        {:reply, {:error, :course_running}, state}

      true ->
        stream_id = Schema.uuid4()
        samples = Course.samples(course)

        fields = %{
          "stream_id" => stream_id,
          "source_kind" => "synthetic",
          "interval_ms" => course.interval_ms,
          "src_clock" => "beam",
          "label" => Keyword.get(opts, :label, "synthetic course (headless peer)"),
          "course" => Course.describe(course)
        }

        case Connection.send_control(state.peer.info, "stream.open", fields) do
          :ok ->
            start = Clock.now_ms()

            source = %{
              stream_id: stream_id,
              course: course.name,
              interval_ms: course.interval_ms,
              pending: samples,
              total: length(samples),
              start: start,
              sent: 0,
              dropped: 0,
              last_seq: 0,
              timer: Process.send_after(self(), :emit, 0)
            }

            state =
              trace(state, [
                Map.merge(fields, %{
                  "event" => "source.stream_open",
                  "samples" => length(samples),
                  "beam_mono_ms" => start
                })
              ])

            {:reply, {:ok, stream_id}, %{state | source: source}}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:stop_course, _reason}, _from, %{source: nil} = state),
    do: {:reply, {:error, :no_course}, state}

  def handle_call({:stop_course, reason}, _from, state),
    do: {:reply, :ok, end_source(state, reason)}

  def handle_call({:peer, event}, _from, state) do
    {reply, state} = peer(event, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:peer_notify, {:rtt, info, rtt}}, state) do
    {:noreply,
     trace(state, [
       %{
         "event" => "peer.rtt",
         "connection_generation" => info.generation,
         "ping_seq" => rtt.ping_seq,
         "rtt_ms" => rtt.rtt_ms,
         "label" => "round trip on this node's clock only; not a one-way latency"
       }
     ])}
  end

  def handle_cast({:peer_notify, {:down, info, reason}}, state) do
    {:noreply, peer_lost(state, info.generation, reason)}
  end

  @impl true
  def handle_info(:emit, %{source: %{pending: []}} = state),
    do: {:noreply, end_source(state, :course_complete)}

  def handle_info(:emit, %{source: src} = state) when src != nil do
    [s | rest] = src.pending
    now = Clock.now_ms()

    fields = %{
      "stream_id" => src.stream_id,
      "seq" => s.seq,
      "src_mono_ms" => now,
      "src_frame" => nil,
      "pos" => s.pos,
      "qualified" => true,
      "reason" => nil
    }

    {src, rec} =
      case state.peer && Connection.send_sample(state.peer.info, fields) do
        :ok -> {%{src | sent: src.sent + 1, last_seq: s.seq}, "sent"}
        _ -> {%{src | dropped: src.dropped + 1}, "dropped"}
      end

    # the next sample at the run's start + k × interval: no accumulated drift
    next_at = src.start + (src.total - length(rest)) * src.interval_ms
    timer = Process.send_after(self(), :emit, max(next_at - Clock.now_ms(), 0))
    src = %{src | pending: rest, timer: timer}

    state =
      trace(%{state | source: src}, [
        %{
          "event" => "source.sample",
          "stream_id" => src.stream_id,
          "seq" => s.seq,
          "course_t_ms" => s.t_ms,
          "pos" => s.pos,
          "outcome" => rec,
          "beam_mono_ms" => now
        }
      ])

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{peer: %{ref: ref}} = state),
    do: {:noreply, peer_lost(state, state.peer.info.generation, {:connection_down, reason})}

  def handle_info(_msg, state), do: {:noreply, state}

  defp end_source(%{source: nil} = state, _reason), do: state

  defp end_source(%{source: src} = state, reason) do
    if src.timer, do: Process.cancel_timer(src.timer)

    fields = %{
      "stream_id" => src.stream_id,
      "reason" => to_string(reason),
      "last_seq" => src.last_seq,
      "sent" => src.sent
    }

    if state.peer, do: Connection.send_control(state.peer.info, "stream.end", fields)

    done = %{
      stream_id: src.stream_id,
      course: src.course,
      reason: to_string(reason),
      sent: src.sent,
      dropped: src.dropped,
      last_seq: src.last_seq,
      total: src.total
    }

    %{state | source: nil, sources_done: Enum.take([done | state.sources_done], 16)}
    |> trace([Map.merge(fields, %{"event" => "source.stream_end", "dropped" => src.dropped})])
  end

  # -- sink -------------------------------------------------------------------------------------------

  defp peer({:up, info}, state) do
    ref = Process.monitor(info.connection)

    state =
      trace(state, [
        %{
          "event" => "peer.up",
          "connection_generation" => info.generation,
          "label" => info.label,
          "client_kind" => info.client_kind,
          "boot_id" => info.boot_id,
          "pin" => info.pin
        }
      ])

    {:ok, %{state | peer: %{info: info, ref: ref}}}
  end

  defp peer({:stream_open, _info, f}, state) do
    s = %{
      source_kind: f.source_kind,
      src_clock: f.src_clock,
      interval_ms: f.interval_ms,
      label: f.label,
      course: f.course,
      received: 0,
      qualified: 0,
      unqualified: 0,
      duplicate: 0,
      older: 0,
      gaps: 0,
      last_seq: 0,
      last_r: nil,
      outside_bounds: 0,
      too_fast: 0,
      ended: nil
    }

    state =
      trace(%{state | streams: Map.put(state.streams, f.stream_id, s)}, [
        %{
          "event" => "sink.stream_open",
          "stream_id" => f.stream_id,
          "source_kind" => f.source_kind,
          "src_clock" => f.src_clock,
          "label" => f.label,
          "course" => f.course
        }
      ])

    {:ok, state}
  end

  defp peer({:sample, _info, f}, state) do
    now = Clock.now_ms()
    s = state.streams[f.stream_id]

    {verdict, s} =
      cond do
        f.seq == s.last_seq -> {"duplicate", %{s | duplicate: s.duplicate + 1}}
        f.seq < s.last_seq -> {"older", %{s | older: s.older + 1}}
        true -> {"recorded", %{s | gaps: s.gaps + max(f.seq - s.last_seq - 1, 0), last_seq: f.seq}}
      end

    {checks, s} = bounds_checks(state.bounds, f, s, now)

    s =
      %{s | received: s.received + 1, last_r: now}
      |> then(&if(f.qualified, do: %{&1 | qualified: &1.qualified + 1}, else: %{&1 | unqualified: &1.unqualified + 1}))

    state =
      trace(%{state | streams: Map.put(state.streams, f.stream_id, s)}, [
        %{
          "event" => "sink.sample",
          "stream_id" => f.stream_id,
          "seq" => f.seq,
          "src_mono_ms" => f.src_mono_ms,
          "src_frame" => f.src_frame,
          "pos" => f.pos,
          "qualified" => f.qualified,
          "reason" => f.reason,
          "verdict" => verdict,
          "checks" => checks,
          "beam_mono_ms" => now
        }
      ])

    {:ok, state}
  end

  defp peer({:stream_end, _info, f}, state) do
    s = state.streams[f.stream_id]

    reconciliation = %{
      "source_last_seq" => f.last_seq,
      "source_sent" => f.sent,
      "received" => s.received,
      "last_seq_received" => s.last_seq,
      "gaps" => s.gaps,
      "complete" => f.sent == s.received and f.last_seq == s.last_seq and s.gaps == 0
    }

    done = Map.merge(sink_view(s), %{stream_id: f.stream_id, reason: f.reason, reconciliation: reconciliation})

    state =
      %{state | streams: Map.delete(state.streams, f.stream_id), done: Enum.take([done | state.done], 16)}
      |> trace([
        Map.merge(reconciliation, %{"event" => "sink.stream_end", "stream_id" => f.stream_id, "reason" => f.reason})
      ])

    {:ok, state}
  end

  defp bounds_checks(nil, _f, s, _now), do: {[], s}

  defp bounds_checks(b, f, s, now) do
    {:ok, [xw, yw, _]} = TransformWords.decode(f.pos, 3)
    {cx, cy} = b.center
    x = TransformWords.to_float(xw)
    y = TransformWords.to_float(yw)
    outside = abs(x - cx) > b.half_extent_m or abs(y - cy) > b.half_extent_m
    fast = s.last_r != nil and now - s.last_r < b.min_interval_ms

    {Enum.reject([outside && "outside_declared_area", fast && "faster_than_declared"], &(&1 == false)),
     %{
       s
       | outside_bounds: s.outside_bounds + if(outside, do: 1, else: 0),
         too_fast: s.too_fast + if(fast, do: 1, else: 0)
     }}
  end

  defp peer_lost(%{peer: %{info: %{generation: g}}} = state, g, reason) do
    Process.demonitor(state.peer.ref, [:flush])

    state
    |> end_source(:peer_link_lost)
    |> Map.put(:peer, nil)
    |> trace([%{"event" => "peer.down", "connection_generation" => g, "reason" => inspect(reason)}])
  end

  defp peer_lost(state, _g, _reason), do: state

  defp source_view(src),
    do: Map.take(src, [:stream_id, :course, :total, :sent, :dropped, :last_seq])

  defp sink_view(s), do: Map.drop(s, [:last_r])

  defp trace(state, records) do
    case Trace.append(state.trace, records) do
      :ok -> state
      _ -> %{state | counts: Map.update!(state.counts, :trace_refused, &(&1 + 1))}
    end
  catch
    :exit, _ -> %{state | counts: Map.update!(state.counts, :trace_refused, &(&1 + 1))}
  end
end
