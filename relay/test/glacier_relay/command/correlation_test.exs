defmodule GlacierRelay.Command.CorrelationTest do
  @moduledoc "M5 C-2A: the engine-consistent-telemetry rule as a pure function; consistent, never caused."
  use ExUnit.Case, async: true

  alias GlacierRelay.Command.Correlation

  @adapter "aaf540dd-c6df-4429-8fa5-84bc8933a13e"
  @target "4fc9396e-2619-4e66-a51e-2bd366230da7"
  @gen "2516103519921974492-5fd4f3e1-0fa5-408f-bce8-b58923581360"

  defp command(overrides \\ %{}) do
    Map.merge(
      %{
        adapter_instance_id: @adapter,
        params: %{"disguise_repository_id" => @target, "charset" => 0, "variation" => 0},
        preconditions: %{"mission_generation" => @gen},
        result: %{native_at: "2026-10-14T03:34:20.000Z"}
      },
      overrides
    )
  end

  defp envelope(overrides \\ %{}) do
    Map.merge(
      %{
        "adapter_instance_id" => @adapter,
        "event_type" => "disguise.equipped",
        "native_at" => "2026-10-14T03:34:21.250Z",
        "sequence" => 12,
        "payload" => %{
          "kind" => "change",
          "disguise_repository_id" => @target,
          "contract_session_id" => @gen
        }
      },
      overrides
    )
  end

  test "a change of the target id in the same generation, after the result and inside the window, is consistent (wording: consistent, not caused)" do
    assert {:consistent, details} = Correlation.check(command(), envelope(), sequence_floor: 10)
    assert details.delay_ms == 1_250 and details.sequence == 12 and details.window_ms == 5_000
    assert details.wording =~ "causality not established"
  end

  test "every failed condition is a named reason" do
    cases = [
      {:adapter_mismatch,
       envelope(%{"adapter_instance_id" => "11111111-2222-4333-8444-555555555555"})},
      {:not_disguise_equipped, envelope(%{"event_type" => "disguise.compromised"})},
      {:not_a_change, put_in(envelope(), ["payload", "kind"], "initial")},
      {:target_mismatch, put_in(envelope(), ["payload", "disguise_repository_id"], @adapter)},
      {:generation_mismatch, put_in(envelope(), ["payload", "contract_session_id"], "other")},
      {:event_before_result, envelope(%{"native_at" => "2026-10-14T03:34:19.999Z"})},
      {:outside_window, envelope(%{"native_at" => "2026-10-14T03:34:25.001Z"})},
      {:timestamps_unparsable, envelope(%{"native_at" => "soon"})}
    ]

    for {reason, env} <- cases do
      assert {:inconsistent, reasons} = Correlation.check(command(), env)
      assert reason in reasons, "#{reason}: #{inspect(reasons)}"
    end

    assert {:inconsistent, [:sequence_not_after_floor]} =
             Correlation.check(command(), envelope(), sequence_floor: 12)

    assert {:inconsistent, reasons} = Correlation.check(command(%{result: nil}), envelope())
    assert :timestamps_unparsable in reasons

    assert {:inconsistent, reasons} = Correlation.check(command(%{params: %{}}), envelope())
    assert :target_mismatch in reasons
    assert {:inconsistent, _} = Correlation.check(command(), %{})
  end

  test "the window is a parameter and the verdict never says caused" do
    assert {:consistent, _} = Correlation.check(command(), envelope(), window_ms: 1_250)

    assert {:inconsistent, [:outside_window]} =
             Correlation.check(command(), envelope(), window_ms: 1_249)

    refute inspect(Correlation.check(command(), envelope())) =~ "caused by"
  end
end
