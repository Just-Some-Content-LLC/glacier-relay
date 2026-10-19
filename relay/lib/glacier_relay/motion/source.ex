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
  """

  defstruct [
    :share_id,
    :interval_ms,
    :duration_ms,
    :opened_at,
    :label,
    phase: :open,
    last_seq: 0,
    last_native_ms: nil,
    last_sent_r: nil,
    close: nil,
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
        send_dropped: 0
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

  @doc "A native `hero.sample` of the bound share."
  def hero_sample(%__MODULE__{} = st, hs, now) do
    st = bump(st, :native)

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

  @doc "Ends the share (no arming): asks the native to stop and ends the stream on the peer link."
  def close(%__MODULE__{phase: :open} = st, reason, now) do
    st = %{st | phase: :closing, close: %{reason: reason, state: :requested, requested_r: now}}

    {st,
     [
       {:send_share_close, reason},
       {:send_peer, "stream.end",
        %{
          "stream_id" => st.share_id,
          "reason" => reason_text(reason),
          "last_seq" => st.last_seq,
          "sent" => st.counts.relayed
        }},
       trace(st, now, "close_requested", %{"reason" => reason_text(reason)})
     ]}
  end

  def close(st, _reason, _now), do: {st, []}

  @doc "The native's `share.closed`."
  def native_closed(%__MODULE__{} = st, c, now) do
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

  @doc "The duration bound."
  def tick(%__MODULE__{phase: :open} = st, now) do
    if now >= st.opened_at + st.duration_ms, do: close(st, :duration, now), else: {st, []}
  end

  def tick(st, _now), do: {st, []}

  def next_deadline(%__MODULE__{phase: :open} = st), do: st.opened_at + st.duration_ms
  def next_deadline(_), do: nil

  def summary(%__MODULE__{} = st),
    do: %{
      share_id: st.share_id,
      phase: st.phase,
      close: st.close && Map.update(st.close, :reason, nil, &reason_text/1),
      counts: st.counts,
      last_seq: st.last_seq
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
