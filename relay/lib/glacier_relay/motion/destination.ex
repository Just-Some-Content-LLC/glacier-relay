defmodule GlacierRelay.Motion.Destination do
  @moduledoc """
  M7-B1: one destination session's BEAM-side state machine (`docs/design/M7_NETWORK_GHOST.md`
  sections 15.3, 15.4 and 15.6), pure: every function takes the receiver's monotonic time `now`
  (ms, this BEAM node's clock) and returns `{state, actions}`; `Motion.Hub` executes the actions
  (`{:send_target, map}`, `{:send_close, reason}`, `{:drop_link, reason}`, `{:trace, map}`,
  `{:closed, summary}`) and calls `tick/2` at `next_deadline/1`.

  A session exists only after the local authority's approval and the native's confirmed open; its
  limits are fixed by that approval (`limits/1` — compiled bounds, defaults) and nothing received
  can change them. It is bound to one stream (`stream_id`); its anchor and first reference are the
  opening snapshot's x / y (the exact inspection the native confirmed).

  Samples (`sample/3`), in order: the session open, the bound stream, a sequence number greater
  than every earlier one (`duplicate` / `older` refused and counted, never re-applied), a source
  clock that increases (else the session closes: `source_clock_not_increasing`), bounded **lag
  growth** — the receiver interval minus the source interval since the least-delayed sample, each
  subtraction within one clock; absolute delay is not known — (above `max_lag_growth_ms` the
  session closes: `late`), `qualified` (else withheld: `unqualified`), inside the area — the anchor
  ± `half_extent_mm`, inclusive — (else the session closes: `outside_area`). A sample that passes is
  *validated* and takes the pending slot (a pending sample it replaces is *superseded*).

  Forwarding: at most one target in flight, at most one per `min_forward_interval_ms`; the pending
  sample is forwarded only when its distance from the **reference** — the last target the native
  confirmed applied (`ghost.applied`, exact, its postimage), or the opening snapshot before that —
  is at most `max_speed_mmps` × min(Δr, `credit_ms`), Δr the receiver time since the reference was
  sent (`≤` passes). There is no acquisition exemption: the first target is bounded against the
  opening snapshot like any other, and a pause earns at most `credit_ms` of movement. A refused
  target is withheld (`refused_displacement`), never clamped. Superseding or forwarding never moves
  the reference; only a confirmation does.

  The session closes — application ends, there is no resumption — on: an `uncertain` or inexact
  application, any native refusal, an acknowledgement missing for 200 ms (`ack_timeout`; the
  target's effect is unknown, never "unapplied"), an acknowledgement for another target, a report
  gap or a report whose counts disagree with the acknowledgements before it, no target forwarded
  for `stall_ms` (`stall`), the duration, and `close/3` (the operator, the stream's end, peer-link
  loss, trace or audit loss). Close states: `requested` → `transmitted` → `confirmed` (the native's
  `ghost.closed`) or `unknown` (no confirmation within 1,000 ms, or the motion link lost first). A
  native-initiated `ghost.closed` is `confirmed` with the native's reason.

  **Time (M7-B1 correction A).** A timer is a wakeup, not the deadline: every event —
  `sample/3`, `applied/3`, `report/3`, `native_closed/3` and `tick/2` — first applies, through
  `expire/2`, every deadline that has passed at its own processing time (`>=`: a deadline expires
  at its instant), in a fixed order: the acknowledgement of the target in flight, the duration,
  the stall; while closing, the acknowledgement and the 1,000 ms confirmation. Only then is the
  event itself handled, so an event that loses the race to its timer message cannot create an
  effect the timer would have prevented. `expire/2` never forwards. Its outcomes:
  - an acknowledgement deadline passed: the target's outcome is **unknown** (`uncertain`,
    `unacknowledged`, kept as `unresolved`) and, while open, the session closes (`ack_timeout`);
    an answer for it processed afterwards is a **late answer** — counted (`late_acks`) and kept
    beside the unresolved target as evidence, never a resolution: it moves no reference, counts no
    apply and releases no pending target;
  - the confirmation deadline passed: the close is `unknown` (the link is dropped); a
    `ghost.closed` processed afterwards is kept as qualified evidence (`late_native_close`), never
    a confirmation, and never overwrites the unknown close.

  The **send boundary** is checked again by `before_send/3`, which the hub calls after the
  batch's required trace write and immediately before the target's bytes: a target whose session
  has reached its duration, or whose stall deadline (measured from the previous send) has passed,
  is cancelled before any byte is written (`cancelled_before_send`; not uncertain) and the session
  closes; otherwise the target's send time — the start of its acknowledgement deadline, its forward
  pacing and its stall — is the actual send. A clock check does not make the later write atomic,
  and nothing recalls a line already written.
  """

  alias GlacierRelay.Command.TransformWords

  @ack_timeout_ms 200
  @close_confirm_ms 1_000

  # {key, min, max, default}: the compiled bounds of a session's limits (design section 15.3)
  @limit_bounds [
    {:half_extent_mm, 100, 8_000, 8_000},
    {:max_speed_mmps, 100, 3_000, 2_000},
    {:credit_ms, 50, 200, 100},
    {:min_forward_interval_ms, 50, 1_000, 50},
    {:stall_ms, 100, 1_000, 250},
    {:max_lag_growth_ms, 20, 250, 100},
    {:duration_ms, 1_000, 300_000, 120_000}
  ]

  @refusals ~w(not_open foreign_stream duplicate older unqualified late outside_area refused_displacement)a

  defstruct [
    :session_id,
    :stream_id,
    :limits,
    :anchor,
    :opened_at,
    :ref,
    :last_forward_r,
    phase: :open,
    last_seq: 0,
    last_applied_seq: 0,
    last_src: nil,
    lag_base: nil,
    pending: nil,
    in_flight: nil,
    unresolved: nil,
    report_seq: 0,
    close: nil,
    native_close: nil,
    late_native_close: nil,
    counts: %{}
  ]

  def ack_timeout_ms, do: @ack_timeout_ms
  def close_confirm_ms, do: @close_confirm_ms
  def limit_bounds, do: @limit_bounds
  def defaults, do: Map.new(@limit_bounds, fn {k, _, _, d} -> {k, d} end)

  @doc """
  Validates a session's limits: every key known (`limit_bounds/0`), each an integer inside its
  compiled bound; a missing key takes its default. `{:ok, limits}` or `{:error, reason}`.
  """
  def limits(given) when is_map(given) do
    known = Enum.map(@limit_bounds, &elem(&1, 0))

    case Map.keys(given) -- known do
      [] ->
        Enum.reduce_while(@limit_bounds, {:ok, %{}}, fn {k, min, max, d}, {:ok, acc} ->
          v = Map.get(given, k, d)

          if is_integer(v) and v >= min and v <= max,
            do: {:cont, {:ok, Map.put(acc, k, v)}},
            else: {:halt, {:error, {:limit_out_of_range, k, v}}}
        end)

      unknown ->
        {:error, {:unknown_limits, unknown}}
    end
  end

  def limits(_), do: {:error, :limits_not_a_map}

  @doc """
  A new open session. `params`: `:session_id`, `:stream_id`, `:limits` (validated), `:opening_world`
  (the native-confirmed opening snapshot, 12 words as text) and `:opened_at` (receiver time of the
  confirmation).
  """
  def new(%{
        session_id: sid,
        stream_id: stream,
        limits: limits,
        opening_world: world,
        opened_at: t
      }) do
    {:ok, words} = TransformWords.decode_world(world)
    xw = Enum.at(words, 9)
    yw = Enum.at(words, 10)

    anchor = %{
      x: TransformWords.to_float(xw),
      y: TransformWords.to_float(yw),
      pos: TransformWords.encode([xw, yw])
    }

    %__MODULE__{
      session_id: sid,
      stream_id: stream,
      limits: limits,
      anchor: anchor,
      opened_at: t,
      ref: Map.merge(anchor, %{seq: nil, r: t}),
      last_forward_r: t,
      counts: empty_counts()
    }
  end

  defp empty_counts do
    %{
      received: 0,
      validated: 0,
      superseded: 0,
      forwarded: 0,
      applied: 0,
      skipped: 0,
      refused_native: 0,
      uncertain: 0,
      unacknowledged: 0,
      reports: 0,
      dropped_on_close: 0,
      withdrawn: 0,
      cancelled_before_send: 0,
      late_acks: 0,
      max_lag_growth_ms: 0,
      refused: Map.new(@refusals, &{&1, 0})
    }
  end

  # -- samples --------------------------------------------------------------------------------------

  @doc "A received `pose.sample` (decoded by `Peer.Codec`) of the bound stream."
  def sample(%__MODULE__{} = st, s, now) do
    {st, expired} = expire(st, now)
    {st, actions} = take_sample(bump(st, :received), s, now)
    {st, expired ++ actions}
  end

  defp take_sample(st, s, now) do
    cond do
      st.phase != :open ->
        refuse(st, s, :not_open, now)

      s.stream_id != st.stream_id ->
        refuse(st, s, :foreign_stream, now)

      s.seq == st.last_seq ->
        refuse(st, s, :duplicate, now)

      s.seq < st.last_seq ->
        refuse(st, s, :older, now)

      st.last_src != nil and s.src_mono_ms <= st.last_src ->
        st = %{st | last_seq: s.seq}
        close(st, :source_clock_not_increasing, now)

      true ->
        st = %{st | last_seq: s.seq, last_src: s.src_mono_ms}
        {st, growth} = lag(st, s.src_mono_ms, now)
        {x, y, pos} = position(s.pos)

        cond do
          growth > st.limits.max_lag_growth_ms ->
            {st, a1} = refuse(st, s, :late, now, %{"lag_growth_ms" => growth})
            {st, a2} = close(st, :late, now)
            {st, a1 ++ a2}

          s.qualified != true ->
            refuse(st, s, :unqualified, now, %{"reason" => s[:reason]})

          not in_area?(st, x, y) ->
            {st, a1} = refuse(st, s, :outside_area, now)
            {st, a2} = close(st, :outside_area, now)
            {st, a1 ++ a2}

          true ->
            superseded = st.pending != nil

            st =
              %{st | pending: %{seq: s.seq, x: x, y: y, pos: pos, r: now}}
              |> bump(:validated)
              |> then(&if(superseded, do: bump(&1, :superseded), else: &1))

            {st, actions} = try_forward(st, now)

            {st,
             [
               trace(st, now, "sample", %{
                 "seq" => s.seq,
                 "src_mono_ms" => s.src_mono_ms,
                 "verdict" => "validated",
                 "lag_growth_ms" => growth,
                 "superseded_pending" => superseded
               })
               | actions
             ]}
        end
    end
  end

  # the growth of one-way delay since the least-delayed sample: receiver interval minus source
  # interval, each within its own clock; a negative growth re-bases on this sample
  defp lag(%{lag_base: nil} = st, s, r), do: {%{st | lag_base: {r, s}}, 0}

  defp lag(%{lag_base: {br, bs}} = st, s, r) do
    growth = r - br - (s - bs)

    if growth < 0 do
      {%{st | lag_base: {r, s}}, 0}
    else
      {put_in(st.counts.max_lag_growth_ms, max(st.counts.max_lag_growth_ms, growth)), growth}
    end
  end

  defp position(pos3) do
    {:ok, [xw, yw, _zw]} = TransformWords.decode(pos3, 3)
    {TransformWords.to_float(xw), TransformWords.to_float(yw), TransformWords.encode([xw, yw])}
  end

  defp in_area?(st, x, y) do
    half = st.limits.half_extent_mm / 1_000
    abs(x - st.anchor.x) <= half and abs(y - st.anchor.y) <= half
  end

  defp refuse(st, s, why, now, extra \\ %{}) do
    st = update_in(st.counts.refused[why], &(&1 + 1))

    {st,
     [
       trace(
         st,
         now,
         "sample",
         Map.merge(
           %{"seq" => s.seq, "src_mono_ms" => s[:src_mono_ms], "verdict" => Atom.to_string(why)},
           extra
         )
       )
     ]}
  end

  # -- forwarding -----------------------------------------------------------------------------------

  defp try_forward(%{phase: :open, in_flight: nil, pending: %{} = p} = st, now) do
    if now < st.last_forward_r + st.limits.min_forward_interval_ms do
      {st, []}
    else
      dt = min(now - st.ref.r, st.limits.credit_ms)
      allowance = st.limits.max_speed_mmps * max(dt, 0) / 1_000_000
      distance = :math.sqrt(:math.pow(p.x - st.ref.x, 2) + :math.pow(p.y - st.ref.y, 2))

      if distance <= allowance do
        st = %{
          st
          | in_flight: %{
              seq: p.seq,
              x: p.x,
              y: p.y,
              pos: p.pos,
              r_sent: now,
              prev_forward_r: st.last_forward_r
            },
            pending: nil,
            last_forward_r: now
        }

        st = bump(st, :forwarded)

        {st,
         [
           {:send_target, %{session_id: st.session_id, seq: p.seq, pos: p.pos}},
           trace(st, now, "forward", %{
             "seq" => p.seq,
             "pos" => p.pos,
             "reference_seq" => st.ref.seq,
             "distance_m" => distance,
             "allowance_m" => allowance
           })
         ]}
      else
        st = update_in(st.counts.refused[:refused_displacement], &(&1 + 1))

        {%{st | pending: nil},
         [
           trace(st, now, "sample", %{
             "seq" => p.seq,
             "verdict" => "refused_displacement",
             "reference_seq" => st.ref.seq,
             "distance_m" => distance,
             "allowance_m" => allowance
           })
         ]}
      end
    end
  end

  defp try_forward(st, _now), do: {st, []}

  # -- the native's answers -------------------------------------------------------------------------

  @doc "A `ghost.applied` for this session."
  def applied(%__MODULE__{} = st, ack, now) do
    {st, expired} = expire(st, now)
    {st, actions} = take_ack(st, ack, now)
    {st, expired ++ actions}
  end

  defp take_ack(st, ack, now) do
    f = st.in_flight
    u = st.unresolved

    cond do
      st.phase == :closed ->
        {bump(st, :late_acks), [trace(st, now, "ack_after_close", ack_fields(ack))]}

      # the answer for a target whose deadline already passed: evidence beside it, no resolution
      f == nil and is_map(u) and u.seq == ack.seq and is_map_key(u, :timed_out_r) ->
        st = %{bump(st, :late_acks) | unresolved: Map.put(u, :late_ack, ack_fields(ack))}

        {st,
         [
           trace(
             st,
             now,
             "ack_late",
             Map.put(ack_fields(ack), "deadline_mono_ms", u.r_sent + @ack_timeout_ms)
           )
         ]}

      f == nil or ack.seq != f.seq ->
        st = record_late_ack(st, ack)
        {st, a} = close(st, :ack_mismatch, now)
        {st, [trace(st, now, "ack_mismatch", ack_fields(ack)) | a]}

      true ->
        st = %{st | in_flight: nil}
        trace_ack = trace(st, now, "ack", ack_fields(ack))

        case ack.outcome do
          "applied" ->
            if ack.exact == true and ack.post == f.pos do
              st =
                %{
                  st
                  | ref: %{seq: f.seq, x: f.x, y: f.y, pos: f.pos, r: f.r_sent},
                    last_applied_seq: f.seq
                }
                |> bump(:applied)

              {st, a} = try_forward(st, now)
              {st, [trace_ack | a]}
            else
              st = bump(st, :uncertain)
              {st, a} = close(st, :postimage_mismatch, now)
              {%{st | unresolved: f}, [trace_ack | a]}
            end

          "skipped_identical" ->
            if f.pos == st.ref.pos do
              st = %{st | ref: %{st.ref | seq: f.seq, r: f.r_sent}} |> bump(:skipped)
              {st, a} = try_forward(st, now)
              {st, [trace_ack | a]}
            else
              st = bump(st, :uncertain)
              {st, a} = close(st, :skip_disagrees, now)
              {%{st | unresolved: f}, [trace_ack | a]}
            end

          "uncertain" ->
            st = bump(st, :uncertain)
            {st, a} = close(st, {:uncertain, ack.reason}, now)
            {%{st | unresolved: f}, [trace_ack | a]}

          "refused" ->
            st = bump(st, :refused_native)
            {st, a} = close(st, {:native_refused, ack.reason}, now)
            {st, [trace_ack | a]}
        end
    end
  end

  # an acknowledgement for a target that is not the one in flight is a control failure; a late
  # answer for the unresolved target is recorded beside it, never as a resolution
  defp record_late_ack(st, ack),
    do: %{
      st
      | counts: Map.update(st.counts, :mismatched_acks, 1, &(&1 + 1)),
        unresolved: st.unresolved || %{seq: ack.seq}
    }

  defp ack_fields(ack),
    do: %{
      "seq" => ack.seq,
      "outcome" => ack.outcome,
      "reason" => ack.reason,
      "post" => ack.post,
      "exact" => ack.exact,
      "frame" => ack.frame,
      "native_mono_ms" => ack.native_mono_ms
    }

  @doc "A `ghost.report` for this session."
  def report(%__MODULE__{} = st, rep, now) do
    {st, expired} = expire(st, now)
    {st, actions} = take_report(st, rep, now)
    {st, expired ++ actions}
  end

  defp take_report(st, rep, now) do
    expected = st.report_seq + 1
    acked = st.counts.applied + st.counts.skipped + st.counts.refused_native + st.counts.uncertain
    in_flight = if st.in_flight, do: 1, else: 0
    st = %{st | report_seq: max(st.report_seq, rep.report_seq)} |> bump(:reports)

    agrees =
      rep.applied == st.counts.applied and rep.skipped == st.counts.skipped and
        rep.refused == st.counts.refused_native and rep.uncertain == st.counts.uncertain and
        rep.superseded == 0 and rep.received >= acked and rep.received <= acked + in_flight

    tr =
      trace(st, now, "report", %{
        "report_seq" => rep.report_seq,
        "native_mono_ms" => rep.native_mono_ms,
        "frame" => rep.frame,
        "native_counts" => %{
          "received" => rep.received,
          "applied" => rep.applied,
          "skipped" => rep.skipped,
          "refused" => rep.refused,
          "uncertain" => rep.uncertain,
          "superseded" => rep.superseded
        },
        "agrees" => agrees
      })

    cond do
      st.phase != :open ->
        {st, [tr]}

      rep.report_seq != expected ->
        {st, a} = close(st, :report_gap, now)
        {st, [tr | a]}

      not agrees ->
        {st, a} = close(st, :report_disagrees, now)
        {st, [tr | a]}

      true ->
        {st, [tr]}
    end
  end

  @doc """
  The native's `ghost.closed` for this session: native-confirmed — unless the confirmation
  deadline passed first (`expire/2`), in which case the close stays `unknown` and this message is
  kept as qualified evidence (`late_native_close`).
  """
  def native_closed(%__MODULE__{} = st, c, now) do
    {st, expired} = expire(st, now)
    {st, actions} = take_native_close(st, c, now)
    {st, expired ++ actions}
  end

  defp take_native_close(%{phase: :closed, close: %{state: :confirmed}} = st, c, now),
    do: {st, [trace(st, now, "closed_duplicate", %{"reason" => c.reason})]}

  defp take_native_close(%{phase: :closed} = st, c, now) do
    st = %{st | late_native_close: c}

    {st,
     [
       trace(st, now, "closed_late", %{
         "native_reason" => c.reason,
         "clean" => c.clean,
         "final_world" => c.final_world,
         "last_applied_seq" => c.last_applied_seq,
         "native_applied" => c.applied,
         "qualification" => "received after the close was declared unknown; not a confirmation"
       })
     ]}
  end

  defp take_native_close(st, c, now) do
    close =
      case st.close do
        nil -> %{reason: {:native, c.reason}, by: :native, requested_r: now}
        cl -> cl
      end

    unresolved = st.unresolved || st.in_flight
    st = if st.in_flight, do: bump(st, :unacknowledged), else: st

    st = %{
      st
      | phase: :closed,
        native_close: c,
        in_flight: nil,
        unresolved: unresolved,
        close: Map.merge(close, %{state: :confirmed, confirmed_r: now})
    }

    {st,
     [
       trace(st, now, "closed", %{
         "native_reason" => c.reason,
         "clean" => c.clean,
         "final_world" => c.final_world,
         "last_applied_seq" => c.last_applied_seq,
         "native_applied" => c.applied
       }),
       {:closed, summary(st)}
     ]}
  end

  # -- close and time ---------------------------------------------------------------------------------

  @doc """
  Ends application (no arming; works in any state). The pending sample is dropped; a target in
  flight keeps its acknowledgement open for the record. Returns `{:send_close, reason}`.
  """
  def close(%__MODULE__{phase: :open} = st, reason, now) do
    dropped = if st.pending, do: 1, else: 0

    st =
      %{
        st
        | phase: :closing,
          pending: nil,
          close: %{reason: reason, by: :beam, state: :requested, requested_r: now}
      }
      |> update_in([Access.key!(:counts), :dropped_on_close], &(&1 + dropped))

    {st,
     [
       trace(st, now, "close_requested", %{"reason" => reason_text(reason)}),
       {:send_close, reason}
     ]}
  end

  def close(%__MODULE__{} = st, _reason, _now), do: {st, []}

  @doc """
  The target in flight was never written (its trace record was refused first): it is withdrawn —
  not uncertain, because no byte of it left this node — and the session is already closing.
  """
  def withdrawn(%__MODULE__{in_flight: %{seq: seq}} = st, seq) do
    # the bump first: a record update reading st.counts would discard it (M7-B1 correction)
    st = bump(st, :withdrawn)
    %{st | in_flight: nil, counts: Map.update!(st.counts, :forwarded, &(&1 - 1))}
  end

  def withdrawn(st, _seq), do: st

  @doc """
  The send boundary (correction A): the hub calls this after the batch's required trace write and
  immediately before writing the target's line. `{:send, state}` — the target's send time, and
  with it its acknowledgement deadline, its pacing and the stall, start now — or
  `{:cancel, state, actions}`: the target is cancelled before any byte of it is written (not
  uncertain), and a deadline that passed closes the session.
  """
  def before_send(%__MODULE__{phase: :open, in_flight: %{seq: seq} = f} = st, seq, now) do
    l = st.limits

    cond do
      now >= st.opened_at + l.duration_ms -> cancel_send(st, :duration, now)
      now >= f.prev_forward_r + l.stall_ms -> cancel_send(st, :stall, now)
      true -> {:send, %{st | in_flight: %{f | r_sent: now}, last_forward_r: now}}
    end
  end

  def before_send(%__MODULE__{in_flight: %{seq: seq}} = st, seq, now),
    do: cancel_send(st, :not_open, now)

  def before_send(%__MODULE__{} = st, seq, now),
    do:
      {:cancel, st,
       [trace(st, now, "send_cancelled", %{"seq" => seq, "why" => "not_the_target_in_flight"})]}

  defp cancel_send(st, why, now) do
    f = st.in_flight
    st = bump(st, :cancelled_before_send)
    st = %{st | in_flight: nil, counts: Map.update!(st.counts, :forwarded, &(&1 - 1))}

    tr =
      trace(st, now, "send_cancelled", %{
        "seq" => f.seq,
        "why" => reason_text(why),
        "decided_mono_ms" => f.r_sent
      })

    if why == :not_open do
      {:cancel, st, [tr]}
    else
      {st, closing} = close(st, why, now)
      {:cancel, st, [tr | closing]}
    end
  end

  @doc "The `ghost.close` line was written."
  def close_transmitted(%__MODULE__{close: %{state: :requested}} = st, now) do
    st = put_in(st.close.state, :transmitted)
    {st, [trace(st, now, "close_transmitted", %{})]}
  end

  def close_transmitted(st, _now), do: {st, []}

  @doc "The motion link is gone: the session can no longer be confirmed closed."
  def link_lost(%__MODULE__{phase: :closed} = st, _now), do: {st, []}

  def link_lost(%__MODULE__{} = st, now) do
    close = st.close || %{reason: :link_lost, by: :link, requested_r: now}
    st = if st.in_flight, do: bump(st, :unacknowledged), else: st

    st = %{
      st
      | phase: :closed,
        unresolved: st.unresolved || st.in_flight,
        in_flight: nil,
        pending: nil,
        close: Map.put(close, :state, :unknown)
    }

    {st, [trace(st, now, "close_unknown", %{"why" => "link_lost"}), {:closed, summary(st)}]}
  end

  @doc "Handles every deadline that has passed at `now` (`expire/2`), then forwards if the pacing allows."
  def tick(%__MODULE__{} = st, now) do
    {st, expired} = expire(st, now)
    {st, forwarded} = try_forward(st, now)
    {st, expired ++ forwarded}
  end

  @doc """
  Applies every deadline that has passed at `now` and nothing else (it never forwards): while
  open, the acknowledgement of the target in flight, the duration and the stall (the first that
  passed closes the session); while closing, the acknowledgement and the 1,000 ms confirmation.
  Every event calls it before handling itself.
  """
  def expire(%__MODULE__{phase: :open} = st, now) do
    l = st.limits

    cond do
      ack_due?(st, now) ->
        {st, timed_out} = time_out_ack(st, now)
        {st, closing} = close(st, :ack_timeout, now)
        {st, timed_out ++ closing}

      now >= st.opened_at + l.duration_ms ->
        close(st, :duration, now)

      now >= st.last_forward_r + l.stall_ms ->
        close(st, :stall, now)

      true ->
        {st, []}
    end
  end

  def expire(%__MODULE__{phase: :closing} = st, now) do
    {st, timed_out} = if ack_due?(st, now), do: time_out_ack(st, now), else: {st, []}

    if st.close.state in [:requested, :transmitted] and
         now >= st.close.requested_r + @close_confirm_ms do
      st = %{st | phase: :closed, close: %{st.close | state: :unknown}}

      {st,
       timed_out ++
         [
           trace(st, now, "close_unknown", %{"why" => "no confirmation"}),
           {:drop_link, :close_unconfirmed},
           {:closed, summary(st)}
         ]}
    else
      {st, timed_out}
    end
  end

  def expire(st, _now), do: {st, []}

  defp ack_due?(st, now),
    do: st.in_flight != nil and now >= st.in_flight.r_sent + @ack_timeout_ms

  # the target's outcome is unknown from its deadline on: never "unapplied", and no later answer
  # resolves it
  defp time_out_ack(%{in_flight: f} = st, now) do
    st = st |> bump(:uncertain) |> bump(:unacknowledged)
    st = %{st | in_flight: nil, unresolved: st.unresolved || Map.put(f, :timed_out_r, now)}
    {st, [trace(st, now, "ack_timeout", %{"seq" => f.seq, "sent_mono_ms" => f.r_sent})]}
  end

  @doc "The earliest time at which `tick/2` has something to do, or nil."
  def next_deadline(%__MODULE__{phase: :open} = st) do
    l = st.limits

    [
      st.in_flight && st.in_flight.r_sent + @ack_timeout_ms,
      st.opened_at + l.duration_ms,
      st.last_forward_r + l.stall_ms,
      st.pending && st.in_flight == nil && st.last_forward_r + l.min_forward_interval_ms
    ]
    |> Enum.filter(&is_integer/1)
    |> Enum.min(fn -> nil end)
  end

  def next_deadline(%__MODULE__{phase: :closing, close: %{state: s} = c})
      when s in [:requested, :transmitted],
      do: c.requested_r + @close_confirm_ms

  def next_deadline(_), do: nil

  @doc """
  The session's account: phase, close (reason, state, initiator), counts, the confirmed reference,
  the native's close facts, the unresolved target if any. `restorable` is true only for a
  native-confirmed, clean close with exact final words and no uncertainty.
  """
  def summary(%__MODULE__{} = st) do
    nc = st.native_close

    %{
      session_id: st.session_id,
      stream_id: st.stream_id,
      phase: st.phase,
      close:
        st.close &&
          %{
            reason: reason_text(st.close.reason),
            state: st.close.state,
            by: st.close.by
          },
      counts: st.counts,
      last_seq: st.last_seq,
      confirmed_seq: st.ref.seq,
      confirmed_pos: st.ref.pos,
      unresolved_seq: st.unresolved && st.unresolved.seq,
      native_close:
        nc &&
          %{
            reason: nc.reason,
            clean: nc.clean,
            final_world: nc.final_world,
            last_applied_seq: nc.last_applied_seq,
            applied: nc.applied
          },
      late_native_close:
        st.late_native_close &&
          %{
            reason: st.late_native_close.reason,
            clean: st.late_native_close.clean,
            final_world: st.late_native_close.final_world,
            qualification: "received after the close was declared unknown; not a confirmation"
          },
      restorable: restorable?(st, nc)
    }
  end

  # BEAM-side closes that mean the two sides disagree or an outcome is uncertain (an open whose
  # outcome is unknown or whose opening snapshot differed included): never restorable, whatever the
  # native reports
  @disagreements [
    :report_gap,
    :report_disagrees,
    :ack_mismatch,
    :skip_disagrees,
    :postimage_mismatch,
    :ack_timeout,
    :open_unknown,
    :open_unverified
  ]

  # restorable only after a native-confirmed clean close whose own counts agree with the
  # acknowledgements BEAM received, with no uncertainty and no disagreement on either side
  defp restorable?(st, nc) do
    st.phase == :closed and st.close != nil and st.close.state == :confirmed and nc != nil and
      nc.clean == true and is_binary(nc.final_world) and st.counts.uncertain == 0 and
      st.unresolved == nil and Map.get(st.counts, :mismatched_acks, 0) == 0 and
      not disagreement?(st.close.reason) and nc.applied == st.counts.applied and
      (nc.last_applied_seq || 0) == st.last_applied_seq
  end

  defp disagreement?(r) when r in @disagreements, do: true
  defp disagreement?({:uncertain, _}), do: true
  defp disagreement?(_), do: false

  @doc "A close reason as text."
  def reason_text(r) when is_atom(r), do: Atom.to_string(r)
  def reason_text({tag, detail}) when is_atom(tag), do: "#{tag}:#{detail}"
  def reason_text(r), do: inspect(r)

  defp bump(st, key), do: %{st | counts: Map.update!(st.counts, key, &(&1 + 1))}

  defp trace(st, now, event, fields),
    do:
      {:trace,
       Map.merge(fields, %{
         "event" => "destination." <> event,
         "session_id" => st.session_id,
         "beam_mono_ms" => now
       })}
end
