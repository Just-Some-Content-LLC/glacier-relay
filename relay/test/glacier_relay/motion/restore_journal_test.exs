defmodule GlacierRelay.Motion.RestoreJournalTest do
  @moduledoc """
  M7-B1 correction, finding B (end to end, after the fix): a restoration's judgement is journaled
  (`motion.session.restore_judged`: the outcome, whether it releases, the unmet requirements and
  every read-back fact kept apart) before it takes effect, and a judgement the journal cannot take
  releases nothing — the session stays `restoring`. Fake-native evidence only.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.{Command, Motion}
  alias GlacierRelay.Command.TransformWords
  alias GlacierRelay.Motion.{Course, Hub}
  alias GlacierRelay.Test.{CountingWriter, FakeMotionNative, MotionStack}

  @gen FakeMotionNative.generation()
  @p FakeMotionNative.anchor_words()

  defp wait(fun, attempts \\ 400), do: MotionStack.wait(fun, attempts, 10)
  defp done?, do: match?(%{status: :done}, Hub.status().session)
  defp registry(sid), do: Enum.find(Command.status().motion.sessions, &(&1.session_id == sid))
  defp journal_events(name), do: Enum.filter(MotionStack.journal(), &(&1["event"] == name))

  defp away_course do
    {ax, ay} = {TransformWords.to_float(elem(@p, 0)), TransformWords.to_float(elem(@p, 1))}

    Course.build([{:hold, 300}, {:line, {ax + 0.1, ay}}, {:hold, 100}],
      origin_words: @p,
      speed_mps: 0.5
    )
  end

  # a closed, clean, displaced session and a fresh inspection with effectful arming
  defp ready(opts) do
    st = MotionStack.start(opts)
    stream = MotionStack.start_course(away_course())
    {sid, _} = MotionStack.open_session(st.adapter, stream)
    wait(&done?/0, 800)
    assert Hub.status().session.summary.restorable
    insp = MotionStack.inspect_exact()
    :ok = MotionStack.arm_effectful(st.adapter)
    {st, sid, insp}
  end

  test "an unqualified restoration is journaled with its reasons and its facts kept apart" do
    {st, sid, insp} = ready([])

    :ok =
      FakeMotionNative.fault(
        st.fake,
        {:restore_field, "postimage_dirty", FakeMotionNative.obs(true)}
      )

    {:ok, rid} =
      Motion.restore_session(sid, inspection_command_id: insp, expected_generation: @gen)

    wait(fn -> Command.command(rid).status == :applied end)
    assert registry(sid).state == :restore_unqualified

    [j] = journal_events("motion.session.restore_judged")
    assert j["session_id"] == sid and j["command_id"] == rid
    assert j["state"] == "restore_unqualified" and j["releases"] == false
    assert j["reasons"] == ["postimage_dirty"]
    f = j["facts"]
    assert f["dirty"] == true and f["control"] == "unchanged" and f["same_entity"] == true

    assert f["requested_world"] == FakeMotionNative.pre() and
             f["observed_world"] == f["requested_world"]

    assert f["observed_local"] == FakeMotionNative.local() and f["parent"] == f["expected_parent"]
    assert f["invocation"] == "reported" and f["effect"] == "changed"

    # the terminal is journaled before the judgement
    [t] =
      Enum.filter(
        MotionStack.journal(),
        &(&1["event"] == "command.terminal" and &1["command_id"] == rid)
      )

    assert t["seq"] < j["seq"]
  end

  test "a judgement the journal cannot take releases nothing: the session stays restoring" do
    {:ok, agent} = CountingWriter.start()
    {st, sid, insp} = ready(command: [writer: {CountingWriter, agent}])
    # the terminal arrives 300 ms after the acknowledgement; the journal then takes exactly one
    # more entry (the terminal) and fails the next (the judgement)
    :ok = FakeMotionNative.fault(st.fake, {:delay_terminal, 300})

    {:ok, rid} =
      Motion.restore_session(sid, inspection_command_id: insp, expected_generation: @gen)

    wait(fn -> Command.command(rid).status == :received end)
    CountingWriter.fail_after(agent, 1)
    wait(fn -> Command.command(rid).status == :applied end)

    assert registry(sid).state == :restoring

    assert {:error, {:motion_session_not_restored, ^sid, :restoring}} =
             Command.status().motion.exclusivity

    # the judgement's write was attempted and its sync failed: the authority counts it as not
    # persisted (the line may still be in the file; its durability is unknown) and releases nothing
    assert %{degraded: true, failed_event: "motion.session.restore_judged"} =
             Command.status().audit
  end
end
