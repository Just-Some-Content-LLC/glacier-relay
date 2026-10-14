defmodule GlacierRelay.Command.Correlation do
  @moduledoc """
  The engine-consistent-telemetry rule (M5 C-2A; M5 design section 25 §8, research section 7)
  as a pure function over plain maps. The command authority never reads the observer (section
  26.1): the operator tooling fetches a Relay envelope from the observer side out of band and
  applies this rule before recording an `engine_consistent` operator observation. The verdict's
  wording is "consistent with the command", never "caused by": the same engine event can be
  produced by gameplay, a script or the operator, and causality is not established here.

  A `disguise.equipped` envelope is consistent with an applied `player.outfit.set` when every one
  of these holds: the envelope's adapter instance id equals the command's; its event type is
  `disguise.equipped` with `kind` `change`; its disguise repository id equals the command's target
  id; its contract session id equals the command's mission generation; its native timestamp is
  after the result's `native_at` and within the window (default 5,000 ms); and, when a sequence
  floor is given, its sequence is above it. Anything missing or unparsable is a stated reason.
  """

  @default_window_ms 5_000

  @doc """
  `command`: the authority's record of an applied effectful command (`adapter_instance_id`,
  `params`, `preconditions`, `result.native_at`). `envelope`: a plain map with string keys
  (`adapter_instance_id`, `event_type`, `native_at`, `sequence`, `payload` with `kind`,
  `disguise_repository_id`, `contract_session_id`). Returns `{:consistent, details}` or
  `{:inconsistent, reasons}`.
  """
  def check(command, envelope, opts \\ []) when is_map(command) and is_map(envelope) do
    window = Keyword.get(opts, :window_ms, @default_window_ms)
    floor = Keyword.get(opts, :sequence_floor)
    payload = envelope["payload"] || %{}
    target = get_in(command, [:params, "disguise_repository_id"])
    generation = get_in(command, [:preconditions, "mission_generation"])
    result_at = command[:result] && command.result[:native_at]

    reasons =
      [
        {:adapter_mismatch, envelope["adapter_instance_id"] != command[:adapter_instance_id]},
        {:not_disguise_equipped, envelope["event_type"] != "disguise.equipped"},
        {:not_a_change, payload["kind"] != "change"},
        {:target_mismatch, is_nil(target) or payload["disguise_repository_id"] != target},
        {:generation_mismatch,
         is_nil(generation) or payload["contract_session_id"] != generation},
        {:sequence_not_after_floor,
         is_integer(floor) and
           not (is_integer(envelope["sequence"]) and envelope["sequence"] > floor)}
      ] ++ timing_reasons(result_at, envelope["native_at"], window)

    case for {reason, true} <- reasons, do: reason do
      [] ->
        {:consistent,
         %{
           sequence: envelope["sequence"],
           native_at: envelope["native_at"],
           delay_ms: delay_ms(result_at, envelope["native_at"]),
           window_ms: window,
           wording: "consistent with the command; causality not established"
         }}

      failed ->
        {:inconsistent, failed}
    end
  end

  defp timing_reasons(result_at, event_at, window) do
    case delay_ms(result_at, event_at) do
      nil -> [{:timestamps_unparsable, true}]
      delay when delay < 0 -> [{:event_before_result, true}]
      delay when delay > window -> [{:outside_window, true}]
      _ -> []
    end
  end

  defp delay_ms(result_at, event_at) do
    with {:ok, a, _} <- parse(result_at), {:ok, b, _} <- parse(event_at) do
      DateTime.diff(b, a, :millisecond)
    else
      _ -> nil
    end
  end

  defp parse(text) when is_binary(text), do: DateTime.from_iso8601(text)
  defp parse(_), do: :error
end
