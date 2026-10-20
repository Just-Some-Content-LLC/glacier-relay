defmodule GlacierRelay.Motion.RestoreResultTest do
  @moduledoc """
  M7-B1 correction, finding B (end to end): a motion restoration releases the candidate only when
  its result proves the restoration, not when a status string and a matching world group say so.
  Each case drives a legitimate session — opened, applied, closed native-confirmed and clean,
  displaced — through the authority's own restoration flow, and the fake native answers `applied`
  with world words equal to the target while varying **one** accompanying fact of the result (each
  shape admitted by the production result decoder). The session must stay non-releasing, and the
  exclusion is proven by the next real attempt — an M6 forward — being refused for this session;
  a valid result must release it (the M6 forward is then accepted). Fake-native evidence only.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.{Command, Motion}
  alias GlacierRelay.Command.{TransformReadback, TransformWords}
  alias GlacierRelay.HeadlessPeer.Driver
  alias GlacierRelay.Motion.{Course, Hub}
  alias GlacierRelay.Test.{FakeMotionNative, MotionStack}

  @gen FakeMotionNative.generation()
  @p FakeMotionNative.anchor_words()

  defp wait(fun, attempts \\ 400), do: MotionStack.wait(fun, attempts, 10)
  defp done?, do: match?(%{status: :done}, Hub.status().session)
  defp registry(sid), do: Enum.find(Command.status().motion.sessions, &(&1.session_id == sid))

  # a course that moves 0.1 m from P and then HOLDS there until the test ends its stream (the M7-L1
  # correction: it used to end 100 ms after arriving, so a session admitted late in its 600 ms —
  # the gate's failure — met no displacement, closed restorable at the preimage, and was caught
  # only by the displaced-state assertion below)
  defp away_course do
    {ax, ay} = {TransformWords.to_float(elem(@p, 0)), TransformWords.to_float(elem(@p, 1))}

    Course.build([{:hold, 300}, {:line, {ax + 0.1, ay}}, {:hold, 20_000}],
      origin_words: @p,
      speed_mps: 0.5
    )
  end

  # one native-confirmed, clean, displaced session, then its restore answered under `faults`: the
  # session is admitted, the native confirms a target at the course's held end (the destination's
  # confirmed reference and the fake's candidate both there), and only then does the stream end,
  # closing the session as before (the stream's end)
  defp restore_with(faults) do
    st = MotionStack.start(max_sessions: 2)
    course = away_course()
    stream = MotionStack.start_course(course)
    {sid, _cid} = MotionStack.open_session(st.adapter, stream)
    %{x_word: xw, y_word: yw} = List.last(Course.samples(course))
    away = TransformWords.encode([xw, yw])

    # the destination's confirmed reference starts at the opening snapshot (P): the course's end must
    # differ from it, and at least one target must have been applied there
    refute away == TransformWords.encode([elem(@p, 0), elem(@p, 1)])

    wait(fn ->
      s = Hub.status().session

      s.status == :active and s.summary.counts.applied >= 1 and s.summary.confirmed_pos == away and
        Enum.slice(
          TransformWords.decode_world(FakeMotionNative.status(st.fake).world) |> elem(1),
          9,
          2
        ) ==
          [xw, yw]
    end)

    :ok = Driver.stop_course(:test_displaced)
    wait(&done?/0, 800)
    assert Hub.status().session.summary.restorable
    assert FakeMotionNative.status(st.fake).world != FakeMotionNative.pre()
    Enum.each(faults, &(:ok = FakeMotionNative.fault(st.fake, &1)))
    insp = MotionStack.inspect_exact()
    :ok = MotionStack.arm_effectful(st.adapter)

    {:ok, rid} =
      Motion.restore_session(sid, inspection_command_id: insp, expected_generation: @gen)

    wait(fn -> Command.command(rid).status not in [:accepted, :transmitted, :received] end)
    %{st: st, sid: sid, rid: rid}
  end

  # the result the authority received: admitted, and its world words equal the target
  defp assert_target_equal_result(rid, status) do
    r = Command.command(rid)
    assert r.status == status
    {:ok, post} = TransformReadback.words(r.result.observed["postimage_world_words"], :world)
    assert TransformWords.encode(post) == FakeMotionNative.pre()
  end

  # the next real attempts: a fresh inspection, fresh arming, an M6 forward
  defp next_attempts(ctx) do
    insp = MotionStack.inspect_exact()
    :ok = MotionStack.arm_effectful(ctx.st.adapter)
    step = Command.step_candidate(%{}, inspection_command_id: insp, expected_generation: @gen)

    %{
      state: registry(ctx.sid).state,
      exclusivity: Command.status().motion.exclusivity,
      step: step,
      insp: insp
    }
  end

  @unqualified [
    {"the post cache dirty", [{:restore_field, "postimage_dirty", FakeMotionNative.obs(true)}]},
    {"the post dirty state absent", [{:restore_field, "postimage_dirty", :omit}]},
    {"another parent after the call",
     [{:restore_field, "postimage_parent", FakeMotionNative.obs("00ffffffffffff01")}]},
    {"another entity after the call",
     [{:restore_field, "post_same_entity", FakeMotionNative.obs(false)}]},
    {"another mission generation after the call",
     [{:restore_field, "generation_post", FakeMotionNative.obs("1-another-generation")}]},
    {"the local hero's control changed",
     [{:restore_field, "hero_control", FakeMotionNative.obs("changed")}]},
    {"the control comparison unavailable",
     [{:restore_field, "hero_control", %{"status" => "unavailable"}}]},
    {"the effect uncertain", [{:restore_field, "effect", FakeMotionNative.obs("uncertain")}]},
    {"the invocation not reported", [{:restore_field, "setter_called", :omit}]},
    {"the requested words absent", [{:restore_field, "requested_world_words", :omit}]},
    {"the parent-relative words absent", [{:restore_field, "postimage_local_words", :omit}]}
  ]

  for {label, faults} <- @unqualified do
    @faults faults
    test "B: applied with target-equal world words but #{label}: not released, exclusion held" do
      ctx = restore_with(@faults)
      assert_target_equal_result(ctx.rid, :applied)
      sid = ctx.sid
      seen = next_attempts(ctx)

      assert match?(
               %{
                 state: :restore_unqualified,
                 exclusivity:
                   {:error, {:motion_session_not_restored, ^sid, :restore_unqualified}},
                 step: {:error, {:motion_session_not_restored, ^sid, :restore_unqualified}}
               },
               seen
             ),
             "the restoration was released on its world words alone: #{inspect(Map.delete(seen, :insp))}"

      # a new session is refused for the same reason (max_sessions 2: the budget is not the cause)
      stream2 = MotionStack.start_course(MotionStack.short_course(prefix_ms: 3_000))
      _ = MotionStack.arm_effectful(ctx.st.adapter)

      assert {:error, {:earlier_session_not_restored, ^sid, :restore_unqualified}} =
               Motion.open_session(
                 inspection_command_id: seen.insp,
                 expected_generation: @gen,
                 stream_id: stream2,
                 source_kind: "synthetic"
               )

      # no automatic retry, and no second restore or baseline release
      assert {:error, {:session_not_restorable, :restore_unqualified}} =
               Motion.restore_session(sid,
                 inspection_command_id: seen.insp,
                 expected_generation: @gen
               )

      assert {:error, {:session_not_restorable, :restore_unqualified}} =
               Motion.confirm_baseline(sid,
                 inspection_command_id: seen.insp,
                 expected_generation: @gen
               )
    end
  end

  test "B: a non-application status that reports an invocation and a changed effect is not re-eligible" do
    ctx = restore_with([{:restore_status, "precondition_failed"}])
    assert_target_equal_result(ctx.rid, :precondition_failed)
    sid = ctx.sid
    state = registry(sid).state
    insp = MotionStack.inspect_exact()

    # the candidate now shows the preimage: a re-eligible session would be released as a baseline
    baseline =
      Motion.confirm_baseline(sid, inspection_command_id: insp, expected_generation: @gen)

    assert state == :restore_unqualified and
             baseline == {:error, {:session_not_restorable, :restore_unqualified}},
           "a contradictory non-application renewed eligibility: #{inspect({state, baseline})}"

    assert {:error, {:motion_session_not_restored, ^sid, :restore_unqualified}} =
             Command.status().motion.exclusivity
  end

  test "B: a restoration result carrying the whole contract releases; an M6 forward is then accepted" do
    ctx = restore_with([])
    assert_target_equal_result(ctx.rid, :applied)
    seen = next_attempts(ctx)

    assert match?(%{state: :restored, exclusivity: :ok, step: {:ok, _}}, seen),
           inspect(Map.delete(seen, :insp))
  end

  test "B: a restoration result carrying the whole contract releases; a second session opens" do
    ctx = restore_with([])
    assert registry(ctx.sid).state == :restored
    stream2 = MotionStack.start_course(MotionStack.short_course(prefix_ms: 3_000))
    insp = MotionStack.inspect_exact()
    :ok = MotionStack.arm_effectful(ctx.st.adapter)

    assert {:ok, %{command_id: cid}} =
             Motion.open_session(
               inspection_command_id: insp,
               expected_generation: @gen,
               stream_id: stream2,
               source_kind: "synthetic"
             )

    wait(fn -> Command.command(cid).status == :applied end)
  end
end
