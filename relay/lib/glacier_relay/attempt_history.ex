defmodule GlacierRelay.AttemptHistory do
  @moduledoc """
  The attempt-boundary reading of the instance's gap evidence, shared by every derived per-attempt
  view (`Disguise.derive/2` since M2 B3, `Items.derive/2` since M2 B4). Extracted unchanged from
  `Disguise` so both views bound history the same way; it adds no evidence and stores nothing.

  Gaps are recorded on the instance as `{expected, got}`, newest first, detected at `got`. One
  belongs to an attempt when it was detected after the rise and no later than the attempt's end on
  the stream: its stop, or — for a superseded attempt, whose stop was never observed — the rise
  that superseded it (`superseded_at`). A gap detected at that rise is the superseded attempt's
  evidence; gaps detected later belong to later attempts and can never reach it. An open attempt
  has no upper bound. A gap detected at a later rise *after a stop* lies between attempts and is
  instance-level evidence belonging to neither.
  """

  alias GlacierRelay.Lifecycle.Attempt

  @doc "This attempt's gaps, oldest first, as `{expected, got}`."
  @spec gaps_in_attempt([{pos_integer(), pos_integer()}], Attempt.t()) :: [{pos_integer(), pos_integer()}]
  def gaps_in_attempt(gaps, %Attempt{playing: %{sequence: lo}} = attempt) do
    hi =
      cond do
        attempt.stopped -> attempt.stopped.sequence
        attempt.mission == :superseded -> attempt.superseded_at
        true -> nil
      end

    gaps
    |> Enum.reverse()
    |> Enum.filter(fn {_expected, got} -> got > lo and (is_nil(hi) or got <= hi) end)
  end

  @doc """
  Attempt-level completeness from the bounded gaps, the attempt's interruptions and its
  supersession: `:complete`, or `{:incomplete, reasons}` with each reason as
  `{:gap, expected, got}`, `{:interruption, at, reason}` or `{:superseded, by, at_sequence}`,
  in that order.
  """
  @spec history(Attempt.t(), [{pos_integer(), pos_integer()}]) ::
          :complete | {:incomplete, [term()]}
  def history(%Attempt{} = attempt, instance_gaps) do
    reasons =
      Enum.map(gaps_in_attempt(instance_gaps, attempt), fn {expected, got} -> {:gap, expected, got} end) ++
        Enum.map(attempt.interruptions, fn i -> {:interruption, i.at, i.reason} end) ++
        if(attempt.mission == :superseded,
          do: [{:superseded, attempt.superseded_by, attempt.superseded_at}],
          else: []
        )

    if reasons == [], do: :complete, else: {:incomplete, reasons}
  end
end
