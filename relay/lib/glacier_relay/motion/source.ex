defmodule GlacierRelay.Motion.Source do
  @moduledoc """
  M7-B1: one share's BEAM-side relay (`docs/design/M7_NETWORK_GHOST.md` sections 15.2, 15.4 and
  15.6), pure like `Motion.Destination`: `{state, actions}` with `{:send_peer, kind, fields}`,
  `{:send_share_close, reason}`, `{:trace, map}` and `{:closed, summary}`.

  It relays only the bound native share's `hero.sample` lines — the local sampler's output, never
  anything received from a peer and never the candidate — as `pose.sample` on the share's stream
  (`stream_id` = `share_id`, `source_kind: game`, the native clock as `src_clock`). A sample is
  relayed when its share is open, its sequence number exceeds every earlier one (else refused and
  counted), its native clock increases (else the share closes) and at least 90 % of the share's
  interval has passed on this node's clock since the previous relayed sample (else dropped and
  counted: `rate`). A dirty sample is relayed **labelled** (`qualified: false`, `reason: dirty`) so
  the sink can account for it; a receiver never applies it. The share ends on its duration, the
  operator, the native's `share.closed`, the peer link's loss, or the trace's loss.

  **Time (M7-B1 correction A), as `Motion.Destination`'s:** `hero_sample/3`, `native_closed/3` and
  `tick/2` first apply every deadline that has passed at their processing time (`expire/2`; `>=`):
  the duration while open, the 1,000 ms confirmation while closing. A sample processed at or after
  the duration is not relayed, whichever message came first; a `share.closed` processed after the
  confirmation deadline is kept as qualified evidence (`late_native_close`) and never turns the
  `unknown` close into a confirmed one. `before_send/3` checks the duration again immediately before
  the hub hands a relayed sample to the peer connection, and gives the connection the same bound
  (`not_after`), which it checks again before the TLS write; a sample cancelled there counts as
  `cancelled_before_send` and no longer as relayed. Neither check recalls a line already written.
  """

  @close_confirm_ms 1_000

  defstruct [
    :share_id,
    :interval_ms,
    :duration_ms,
    :opened_at,
    :label,
    phase: :open,
    announced: false,
    last_seq: 0,
    last_native_ms: nil,
    last_sent_r: nil,
    close: nil,
    late_native_close: nil,
    counts: %{}
  ]

  @doc "A new open share: `:share_id`, `:interval_ms`, `:duration_ms`, `:opened_at`, `:label` (text)."
  def new(%{share_id: id, interval_ms: i, duration_ms: d, opened_at: t} = p) do
    %__MODULE__{
      share_id: id,
      interval_ms: i,
      duration_ms: d,
      opened_at: t,
      label: Map.get(p, :label),
      counts: %{
        native: 0,
        relayed: 0,
        relayed_unqualified: 0,
        duplicate: 0,
        older: 0,
        rate: 0,
        not_open: 0,
        send_dropped: 0,
        cancelled_before_send: 0
      }
    }
  end

  @doc "The `stream.open` fields announcing this share's stream."
  def stream_open(%__MODULE__{} = st),
    do: %{
      "stream_id" => st.share_id,
      "source_kind" => "game",
      "interval_ms" => st.interval_ms,
      "src_clock" => "native",
      "label" => st.label,
      "course" => nil
    }

  @doc "The stream was announced to the peer (`stream.open` queued)."
  def announced(%__MODULE__{} = st), do: %{st | announced: true}

  @doc "A native `hero.sample` of the bound share."
  def hero_sample(%__MODULE__{} = st, hs, now) do
    {st, expired} = expire(st, now)
    {st, actions} = take_hero_sample(bump(st, :native), hs, now)
    {st, expired ++ actions}
  end

  defp take_hero_sample(st, hs, now) do
    cond do
      st.phase != :open ->
        {bump(st, :not_open), []}

      hs.seq == st.last_seq ->
        {bump(st, :duplicate),
         [trace(st, now, "refused", %{"seq" => hs.seq, "why" => "duplicate"})]}

      hs.seq < st.last_seq ->
        {bump(st, :older), [trace(st, now, "refused", %{"seq" => hs.seq, "why" => "older"})]}

      st.last_native_ms != nil and hs.native_mono_ms <= st.last_native_ms ->
        close(%{st | last_seq: hs.seq}, :native_clock_not_increasing, now)

      st.last_sent_r != nil and now - st.last_sent_r < div(st.interval_ms * 9, 10) ->
        st = %{st | last_seq: hs.seq, last_native_ms: hs.native_mono_ms} |> bump(:rate)
        {st, [trace(st, now, "refused", %{"seq" => hs.seq, "why" => "rate"})]}

      true ->
        qualified = hs.dirty == false

        st =
          %{st | last_seq: hs.seq, last_native_ms: hs.native_mono_ms, last_sent_r: now}
          |> bump(:relayed)
          |> then(&if(qualified, do: &1, else: bump(&1, :relayed_unqualified)))

        fields = %{
          "stream_id" => st.share_id,
          "seq" => hs.seq,
          "src_mono_ms" => hs.native_mono_ms,
          "src_frame" => hs.frame,
          "pos" => hs.pos,
          "qualified" => qualified,
          "reason" => if(qualified, do: nil, else: "dirty")
        }

        {st,
         [
           {:send_peer, "pose.sample", fields},
           trace(st, now, "relayed", %{
             "seq" => hs.seq,
             "native_mono_ms" => hs.native_mono_ms,
             "frame" => hs.frame,
             "pos" => hs.pos,
             "qualified" => qualified
           })
         ]}
    end
  end

  @doc "A relayed sample the peer connection could not take (counted, never retried)."
  def send_dropped(%__MODULE__{} = st), do: bump(st, :send_dropped)

  @doc """
  The send boundary (correction A): the hub calls this immediately before handing a relayed
  sample (`fields`) to the peer connection. `{:send, state, not_after}` — the share's bound,
  which the connection checks again before its write — or `{:cancel, state, actions}`: the sample
  is not handed over (counted `cancelled_before_send`, no longer relayed), and a share that reached
  its duration closes.
  """
  def before_send(%__MODULE__{phase: :open} = st, fields, now) do
    bound = st.opened_at + st.duration_ms

    if now >= bound do
      {st, tr} = cancel_send(st, fields, :duration, now)
      {st, closing} = close(st, :duration, now)
      {:cancel, st, tr ++ closing}
    else
      {:send, st, bound}
    end
  end

  def before_send(%__MODULE__{} = st, fields, now) do
    {st, tr} = cancel_send(st, fields, :not_open, now)
    {:cancel, st, tr}
  end

  defp cancel_send(st, fields, why, now) do
    st =
      %{st | counts: Map.update!(st.counts, :relayed, &(&1 - 1))}
      |> bump(:cancelled_before_send)
      |> then(fn st ->
        if fields["qualified"] == false,
          do: %{st | counts: Map.update!(st.counts, :relayed_unqualified, &(&1 - 1))},
          else: st
      end)

    {st, [trace(st, now, "send_cancelled", %{"seq" => fields["seq"], "why" => reason_text(why)})]}
  end

  @doc """
  Ends the share (no arming): asks the native to stop and — when the stream was announced — ends it
  on the peer link. Close states as a destination's: `requested` → `transmitted` → `confirmed` (the
  native's `share.closed`) or `unknown` (no confirmation within 1,000 ms, or the link lost first; the
  link is then dropped).
  """
  def close(%__MODULE__{phase: :open} = st, reason, now) do
    st = %{st | phase: :closing, close: %{reason: reason, state: :requested, requested_r: now}}

    end_stream =
      if st.announced,
        do: [
          {:send_peer, "stream.end",
           %{
             "stream_id" => st.share_id,
             "reason" => reason_text(reason),
             "last_seq" => st.last_seq,
             "sent" => st.counts.relayed
           }}
        ],
        else: []

    {st,
     [{:send_share_close, reason}] ++
       end_stream ++ [trace(st, now, "close_requested", %{"reason" => reason_text(reason)})]}
  end

  def close(st, _reason, _now), do: {st, []}

  @doc "The `share.close` line was written."
  def close_transmitted(%__MODULE__{close: %{state: :requested}} = st, _now),
    do: put_in(st.close.state, :transmitted) |> then(&{&1, []})

  def close_transmitted(st, _now), do: {st, []}

  @doc """
  The native's `share.closed` — confirmed, unless the confirmation deadline passed first
  (`expire/2`): the close then stays `unknown` and this message is kept as qualified evidence.
  """
  def native_closed(%__MODULE__{} = st, c, now) do
    {st, expired} = expire(st, now)
    {st, actions} = take_native_close(st, c, now)
    {st, expired ++ actions}
  end

  defp take_native_close(%{phase: :closed, close: %{state: :confirmed}} = st, c, now),
    do: {st, [trace(st, now, "closed_duplicate", %{"native_reason" => c.reason})]}

  defp take_native_close(%{phase: :closed} = st, c, now) do
    st = %{st | late_native_close: c}

    {st,
     [
       trace(st, now, "closed_late", %{
         "native_reason" => c.reason,
         "native_last_seq" => c.last_seq,
         "native_sent" => c.sent,
         "qualification" => "received after the close was declared unknown; not a confirmation"
       })
     ]}
  end

  defp take_native_close(st, c, now) do
    {st, actions} = close(st, {:native, c.reason}, now)
    actions = Enum.reject(actions, &match?({:send_share_close, _}, &1))
    close = Map.merge(st.close || %{}, %{state: :confirmed, native_reason: c.reason})
    st = %{st | phase: :closed, close: close}

    {st,
     actions ++
       [
         trace(st, now, "closed", %{
           "native_reason" => c.reason,
           "native_last_seq" => c.last_seq,
           "native_sent" => c.sent
         }),
         {:closed, summary(st)}
       ]}
  end

  @doc "The motion link is gone: the share can no longer be confirmed closed."
  def link_lost(%__MODULE__{phase: :closed} = st, _now), do: {st, []}

  def link_lost(%__MODULE__{} = st, now) do
    {st, actions} = close(st, :link_lost, now)
    actions = Enum.reject(actions, &match?({:send_share_close, _}, &1))
    st = %{st | phase: :closed, close: Map.put(st.close, :state, :unknown)}
    {st, actions ++ [{:closed, summary(st)}]}
  end

  @doc "The duration bound, and the 1,000 ms close confirmation (`expire/2`)."
  def tick(%__MODULE__{} = st, now), do: expire(st, now)

  @doc "Applies the deadlines that have passed at `now`; every event calls it first."
  def expire(%__MODULE__{phase: :open} = st, now) do
    if now >= st.opened_at + st.duration_ms, do: close(st, :duration, now), else: {st, []}
  end

  def expire(%__MODULE__{phase: :closing, close: %{state: s} = c} = st, now)
      when s in [:requested, :transmitted] do
    if now >= c.requested_r + @close_confirm_ms do
      st = %{st | phase: :closed, close: %{c | state: :unknown}}

      {st,
       [
         trace(st, now, "close_unknown", %{"why" => "no confirmation"}),
         {:drop_link, :share_close_unconfirmed},
         {:closed, summary(st)}
       ]}
    else
      {st, []}
    end
  end

  def expire(st, _now), do: {st, []}

  def next_deadline(%__MODULE__{phase: :open} = st), do: st.opened_at + st.duration_ms

  def next_deadline(%__MODULE__{phase: :closing, close: %{state: s, requested_r: r}})
      when s in [:requested, :transmitted],
      do: r + @close_confirm_ms

  def next_deadline(_), do: nil

  def summary(%__MODULE__{} = st),
    do: %{
      share_id: st.share_id,
      phase: st.phase,
      close: st.close && Map.update(st.close, :reason, nil, &reason_text/1),
      counts: st.counts,
      last_seq: st.last_seq,
      late_native_close:
        st.late_native_close &&
          %{
            reason: st.late_native_close.reason,
            qualification: "received after the close was declared unknown; not a confirmation"
          }
    }

  defp reason_text(r) when is_atom(r), do: Atom.to_string(r)
  defp reason_text({tag, detail}) when is_atom(tag), do: "#{tag}:#{detail}"
  defp reason_text(r) when is_binary(r), do: r
  defp reason_text(r), do: inspect(r)

  defp bump(st, key), do: %{st | counts: Map.update!(st.counts, key, &(&1 + 1))}

  defp trace(st, now, event, fields),
    do:
      {:trace,
       Map.merge(fields, %{
         "event" => "source." <> event,
         "share_id" => st.share_id,
         "beam_mono_ms" => now
       })}
end
