defmodule GlacierRelay.Motion.StreamProgress do
  @moduledoc """
  M7-L3 source-sequence admission correction (`docs/design/M7_NETWORK_GHOST.md` section 29.2): the
  received progress of one open peer stream on the game host. `Motion.Hub` keeps one record per
  stream open on the current peer connection and updates it for every sample it processes there —
  unrouted, while a session is being opened, or routed to the session. Pure.

  A receipt count is not a source sequence: a source can omit indices (spacing, producer drops,
  stale-queue drops) while its schedule advances, so the counts and the highest sequence number are
  kept apart:
  - `received`: the sample items processed for the stream, in any order;
  - `advanced` / `not_advanced`: of those, the ones whose sequence number was above every earlier
    one, and the duplicates or older ones — which never move `high` or overwrite its values;
  - `first_seq`, `index_gaps`: the first sequence number seen, and the sum of the index jumps
    between advancing samples. A gap is observed; its cause is not known, and `high.seq - received`
    is not a loss count;
  - `high`: the highest sequence number processed, with that same sample's horizontal words (`xy`,
    the x / y of its decoded `pos`), its `qualified` flag, its source time (`src_mono_ms`, the
    source's clock) and this node's processing time (`received_mono_ms`), never combined; nil until
    the first sample. A newer unqualified sample replaces it, so an older qualified sample never
    stands in for current progress. Absent progress is not zero progress.

  The record describes progress within one stream of one connection generation and boot, and ends
  with them. It is not the source's present position, a freshness or one-way latency bound, or
  proof that the source is stationary.
  """

  alias GlacierRelay.Command.TransformWords

  @doc "The record of a stream that has no sample yet."
  def new,
    do: %{received: 0, advanced: 0, not_advanced: 0, first_seq: nil, index_gaps: 0, high: nil}

  @doc """
  One processed `pose.sample` (decoded by `Peer.Codec`: `seq` a positive integer, `pos` three
  words) at this node's time `now`.
  """
  def observe(p, %{seq: seq, pos: pos} = s, now) when is_integer(seq) and seq > 0 do
    p = %{p | received: p.received + 1}

    if p.high != nil and seq <= p.high.seq do
      %{p | not_advanced: p.not_advanced + 1}
    else
      gaps = if p.high, do: p.index_gaps + (seq - p.high.seq - 1), else: p.index_gaps

      %{
        p
        | advanced: p.advanced + 1,
          first_seq: p.first_seq || seq,
          index_gaps: gaps,
          high: %{
            seq: seq,
            xy: xy(pos),
            qualified: s[:qualified] == true,
            src_mono_ms: s[:src_mono_ms],
            received_mono_ms: now
          }
      }
    end
  end

  defp xy(pos) do
    case TransformWords.decode(pos, 3) do
      {:ok, [xw, yw, _zw]} -> TransformWords.encode([xw, yw])
      _ -> nil
    end
  end
end
