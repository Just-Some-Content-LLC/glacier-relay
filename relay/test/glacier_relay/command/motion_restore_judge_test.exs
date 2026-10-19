defmodule GlacierRelay.Command.MotionRestoreJudgeTest do
  @moduledoc """
  M7-B1 correction, finding B (pure, after the fix): `MotionControl.judge_restore/2`, the
  restoration-result contract, on hand-built inputs. The wire-reachable variations are proven end
  to end in `Motion.RestoreResultTest`; the cases here marked **internal input** are shapes the
  production decoder would also admit but that the end-to-end tests do not drive (an invalid word
  text, a non-boolean flag, a parent of the other kind, a missing effect classification), exercised
  only to pin the classification. Every fact is kept apart in the judgement's `facts`.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.Command.MotionControl
  alias GlacierRelay.Test.FakeMotionNative

  @pre FakeMotionNative.pre()
  @local FakeMotionNative.local()
  @brick FakeMotionNative.parent()
  @gen FakeMotionNative.generation()
  @displaced String.replace(@pre, "c2b2fae1", "c2b2f0a4")
  @open_id "00000000-0000-4000-8000-0000000000bb"

  defp o(v), do: FakeMotionNative.obs(v)

  defp cmd(effect \\ %{invocation: :reported, effect: :changed, read_back: :native_same_frame}),
    do: %{
      id: "00000000-0000-4000-8000-0000000000aa",
      params: %{"target_world" => @pre, "expect_parent" => @brick, "restore_of" => @open_id},
      binding: %{"mission_generation" => @gen},
      effect: effect
    }

  defp observed(overrides) do
    Map.merge(
      %{
        "mode" => o("restore"),
        "restore_of" => o(@open_id),
        "world_match" => o("target"),
        "requested_world_words" => o(@pre),
        "postimage_world_words" => o(@pre),
        "postimage_local_words" => o(@local),
        "postimage_parent" => o(@brick),
        "postimage_dirty" => o(false),
        "post_same_entity" => o(true),
        "generation_post" => o(@gen),
        "hero_control" => o("unchanged"),
        "local_match" => o("unchanged")
      },
      overrides
    )
    |> Enum.reject(fn {_, v} -> v == :omit end)
    |> Map.new()
  end

  defp judge(overrides \\ %{}, status \\ "applied", c \\ cmd()),
    do: MotionControl.judge_restore(c, %{status: status, observed: observed(overrides)})

  test "the whole contract: restored, nothing unmet; every fact recorded apart" do
    j = judge()
    assert j.state == :restored and j.reasons == []

    assert j.facts == %{
             "status" => "applied",
             "mode" => "restore",
             "restore_of" => @open_id,
             "expected_restore_of" => @open_id,
             "world_match" => "target",
             "target_world" => @pre,
             "requested_world" => @pre,
             "observed_world" => @pre,
             "observed_local" => @local,
             "local_match" => "unchanged",
             "parent" => @brick,
             "expected_parent" => @brick,
             "dirty" => false,
             "same_entity" => true,
             "generation_post" => @gen,
             "expected_generation" => @gen,
             "control" => "unchanged",
             "invocation" => "reported",
             "effect" => "changed"
           }
  end

  test "parent-relative words are recorded, never required equal (the world setter does not promise them)" do
    other = String.replace(@local, "c2b2fae1", "c2b2f0a4")
    j = judge(%{"postimage_local_words" => o(other), "local_match" => o("changed")})
    assert j.state == :restored and j.facts["observed_local"] == other
  end

  @one_fact [
    # the result's identity and the native's own comparison (verifier finding F2)
    {"the mode absent", %{"mode" => :omit}, [:mode_unobserved]},
    {"another mode", %{"mode" => FakeMotionNative.obs("open")}, [:mode_not_restore]},
    {"restore_of absent", %{"restore_of" => :omit}, [:restore_of_unobserved]},
    {"a foreign restore_of",
     %{"restore_of" => FakeMotionNative.obs("00000000-0000-4000-8000-0000000000cc")},
     [:restore_of_mismatch]},
    {"the native's world comparison not target",
     %{"world_match" => FakeMotionNative.obs("neither")}, [:world_match_not_target]},
    {"the native's world comparison absent", %{"world_match" => :omit},
     [:world_match_unobserved]},
    {"requested words absent", %{"requested_world_words" => :omit},
     [:requested_world_unobserved]},
    {"requested words not the target",
     %{"requested_world_words" => FakeMotionNative.obs(@displaced)},
     [:requested_not_target, :postimage_not_requested]},
    {"observed world words absent", %{"postimage_world_words" => :omit},
     [:postimage_world_unobserved]},
    {"parent-relative words unavailable",
     %{"postimage_local_words" => %{"status" => "unavailable"}}, [:postimage_local_unobserved]},
    {"another parent", %{"postimage_parent" => FakeMotionNative.obs("00ffffffffffff01")},
     [:parent_changed]},
    {"parent absent", %{"postimage_parent" => :omit}, [:postimage_parent_unobserved]},
    {"post cache dirty", %{"postimage_dirty" => FakeMotionNative.obs(true)}, [:postimage_dirty]},
    {"post dirty state absent", %{"postimage_dirty" => :omit}, [:postimage_dirty_unobserved]},
    {"another entity", %{"post_same_entity" => FakeMotionNative.obs(false)},
     [:post_entity_changed]},
    {"entity continuity absent", %{"post_same_entity" => :omit}, [:post_entity_unobserved]},
    {"another generation", %{"generation_post" => FakeMotionNative.obs("1-other")},
     [:generation_changed]},
    {"generation absent", %{"generation_post" => :omit}, [:generation_post_unobserved]},
    {"control changed", %{"hero_control" => FakeMotionNative.obs("changed")},
     [{:hero_control, "changed"}]},
    {"control within tolerance (not the accepted policy)",
     %{"hero_control" => FakeMotionNative.obs("within_tolerance")},
     [{:hero_control, "within_tolerance"}]},
    {"control unavailable", %{"hero_control" => %{"status" => "unavailable"}},
     [:hero_control_unobserved]},
    # internal inputs (admitted shapes the end-to-end tests do not drive)
    {"internal input: an invalid requested word text",
     %{"requested_world_words" => FakeMotionNative.obs("zz")}, [:requested_world_unobserved]},
    {"internal input: a non-boolean dirty flag",
     %{"postimage_dirty" => FakeMotionNative.obs("no")}, [:postimage_dirty_unobserved]},
    {"internal input: parent none where a brick was expected",
     %{"postimage_parent" => FakeMotionNative.obs("none")}, [:parent_changed]}
  ]

  for {label, overrides, reasons} <- @one_fact do
    @overrides overrides
    @reasons reasons
    test "applied with target-equal world words but #{label}: restore_unqualified" do
      j = judge(@overrides)
      assert j.state == :restore_unqualified and j.reasons == @reasons
    end
  end

  test "observed world words that differ: restore_not_exact (never released)" do
    j = judge(%{"postimage_world_words" => o(@displaced), "world_match" => o("neither")})
    assert j.state == :restore_not_exact

    assert j.reasons == [
             :postimage_not_target,
             :postimage_not_requested,
             :world_match_not_target
           ]
  end

  test "the invocation and effect come from the authority's classification" do
    j = judge(%{}, "applied", cmd(%{invocation: :not_reported, effect: :changed}))
    assert j.state == :restore_unqualified and j.reasons == [:invocation_not_reported]

    j = judge(%{}, "applied", cmd(%{invocation: :reported, effect: :uncertain}))
    assert j.reasons == [{:effect, :uncertain}]

    j = judge(%{}, "applied", cmd(%{invocation: :reported, effect: :unchanged}))
    assert j.reasons == [{:effect, :unchanged}]

    # internal input: no classification at all
    j = judge(%{}, "applied", Map.put(cmd(), :effect, nil))
    assert j.reasons == [:invocation_not_reported, {:effect, :unreported}]
  end

  test "a non-application returns to closed_clean only without a reported invocation or effect" do
    none = %{invocation: :not_called, effect: :none, read_back: :none}
    assert %{state: :closed_clean, reasons: []} = judge(%{}, "precondition_failed", cmd(none))

    assert %{
             state: :restore_unqualified,
             reasons: [
               :nonapplication_reports_invocation,
               {:nonapplication_reports_effect, :changed}
             ]
           } = judge(%{}, "precondition_failed")

    uncertain = %{invocation: :not_reported, effect: :uncertain, read_back: :none}

    assert %{state: :restore_unqualified, reasons: [{:nonapplication_reports_effect, :uncertain}]} =
             judge(%{}, "rejected", cmd(uncertain))
  end

  test "any other terminal status is restore_unknown" do
    assert %{state: :restore_unknown, reasons: [{:status, :failed}]} = judge(%{}, "failed")
    assert %{state: :restore_unknown} = judge(%{}, "busy")
  end

  test "the journal entry names the outcome, whether it releases, the reasons and the facts" do
    e = MotionControl.restore_entry(cmd(), "sid", judge(%{"postimage_dirty" => o(true)}))
    assert e["event"] == "motion.session.restore_judged" and e["state"] == "restore_unqualified"
    assert e["releases"] == false and e["reasons"] == ["postimage_dirty"]
    assert e["facts"]["dirty"] == true and e["command_id"] == cmd().id

    e = MotionControl.restore_entry(cmd(), "sid", judge(%{"hero_control" => o("changed")}))
    assert e["reasons"] == ["hero_control:changed"]
    assert MotionControl.restore_entry(cmd(), "sid", judge())["releases"] == true
  end
end
