defmodule GlacierRelay.Motion.AdmissionTest do
  @moduledoc """
  M7-L3 source-sequence admission correction (`docs/design/M7_NETWORK_GHOST.md` section 29): the
  `stationary_prefix` admission enforced where it takes effect — at preparation, at activation
  (after the native-open result), and at the first target — on the owned loopback topology
  (`Test.MotionStack`: the real fake native and motion socket, the in-VM headless peer). The normal
  case runs M7-C's unchanged course from the real headless driver over the TLS peer link; the other
  cases use deterministic sequences of production-decoded events injected through the hub's handler
  API on a stream opened the same way (`DeadlineHubTest`'s method), with the fake's delayed
  native-open answer (`{:delay_terminal, ms}`: the native opens, its result arrives later) for the
  in-flight cases. Evidence is the fake's log of the `ghost.target` lines it read and of what it
  applied, the hub's status, trace and the journal — command issuance, native open and setter calls
  kept apart. Fake-native evidence only.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.Command
  alias GlacierRelay.Command.{Schema, TransformWords}
  alias GlacierRelay.Motion
  alias GlacierRelay.Motion.{Clock, Course, Hub}
  alias GlacierRelay.Peer.Codec
  alias GlacierRelay.Test.{FakeMotionNative, MotionStack}

  @gen FakeMotionNative.generation()
  @p FakeMotionNative.anchor_words()
  @anchor TransformWords.encode([elem(@p, 0), elem(@p, 1)])
  @course_opts [
    distance_m: 1.0,
    speed_mps: 0.5,
    heading_rad: 0.0,
    direction: :reverse,
    prefix_ms: 4_000,
    hold_ms: 2_000,
    interval_ms: 50
  ]
  @limits %{duration_ms: 20_000, half_extent_mm: 1_250, max_speed_mmps: 1_000, credit_ms: 100}

  defp wait(fun, attempts \\ 400, sleep \\ 10), do: MotionStack.wait(fun, attempts, sleep)
  defp done?, do: match?(%{status: :done}, Hub.status().session)
  defp summary, do: Hub.status().session.summary
  defp peer_info, do: :sys.get_state(Hub).peer.info
  defp progress(stream), do: Hub.status().peer.streams[stream].progress
  defp registry(sid), do: Enum.find(Command.status().motion.sessions, &(&1.session_id == sid))
  defp course, do: Course.out_and_back(@p, @course_opts)
  defp samples, do: Course.samples(course())

  defp targets(fake),
    do: for({:target_line, _sid, seq, _t} <- FakeMotionNative.events(fake), do: seq)

  defp session_commands(fake),
    do:
      for(
        {:command, "candidate.motion.session", mode, status, _} <- FakeMotionNative.events(fake),
        do: {mode, status}
      )

  defp journal(event), do: Enum.filter(MotionStack.journal(), &(&1["event"] == event))

  defp admission(over \\ %{}),
    do:
      Map.merge(
        %{
          kind: "stationary_prefix",
          anchor: @anchor,
          course: Course.describe(course()),
          max_open_seq: 55,
          max_activation_seq: 61,
          first_changing_seq: 82
        },
        over
      )

  defp decode!(line) do
    {:ok, decoded} = Codec.decode(String.trim_trailing(line, "\n"))
    decoded
  end

  # a stream opened on the hub the way the peer connection opens one; `id` to reuse an identity
  defp open_stream(opts \\ []) do
    id = Keyword.get(opts, :id) || Schema.uuid4()

    {:stream_open, f} =
      decode!(
        Codec.encode("stream.open", %{
          "stream_id" => id,
          "source_kind" => "synthetic",
          "interval_ms" => 50,
          "src_clock" => "beam",
          "label" => "M7-L3 synthetic course (Mac headless peer; not a player)",
          "course" => Keyword.get(opts, :course, Course.describe(course()))
        })
      )

    :ok = Hub.peer_event(Hub, {:stream_open, peer_info(), f}, 1_000)
    id
  end

  defp end_stream(stream) do
    {:stream_end, f} =
      decode!(
        Codec.encode("stream.end", %{
          "stream_id" => stream,
          "reason" => "test",
          "last_seq" => nil,
          "sent" => 0
        })
      )

    :ok = Hub.peer_event(Hub, {:stream_end, peer_info(), f}, 1_000)
  end

  # sample `seq` of M7-C's course (its exact words), or `pos` / `qualified` overridden
  defp send_seq(stream, seq, opts \\ []) do
    s = Enum.find(samples(), &(&1.seq == seq)) || List.last(samples())

    {:pose_sample, f} =
      decode!(
        Codec.encode("pose.sample", %{
          "stream_id" => stream,
          "seq" => seq,
          "src_mono_ms" => Clock.now_ms(),
          "src_frame" => nil,
          "pos" => Keyword.get(opts, :pos, s.pos),
          "qualified" => Keyword.get(opts, :qualified, true),
          "reason" => nil
        })
      )

    :ok = Hub.peer_event(Hub, {:sample, peer_info(), f}, 1_000)
  end

  defp pos_at(dx),
    do:
      TransformWords.encode([
        TransformWords.to_word(TransformWords.to_float(elem(@p, 0)) + dx),
        elem(@p, 1),
        0
      ])

  # inspect and arm, then (optionally) inject a fault, then open; the facade's own answer
  defp open(st, stream, opts \\ []) do
    insp = MotionStack.inspect_exact()
    # a refused preparation issues nothing, so an earlier effectful arming is still held
    unless Command.status().trust.effectful_armed, do: :ok = MotionStack.arm_effectful(st.adapter)
    if f = opts[:fault], do: :ok = FakeMotionNative.fault(st.fake, f)

    Motion.open_session(
      Keyword.merge(
        [
          inspection_command_id: insp,
          expected_generation: @gen,
          stream_id: stream,
          source_kind: "synthetic",
          limits: @limits,
          admission: admission()
        ],
        Keyword.drop(opts, [:fault])
      )
    )
  end

  describe "the normal path" do
    @tag timeout: 60_000
    test "AD-1: M7-C's unchanged course from the real headless driver admits in its prefix, acquires at P and completes" do
      st = MotionStack.start()
      stream = MotionStack.start_course(course())
      wait(fn -> progress(stream).high != nil end)

      {sid, cid} =
        MotionStack.open_session(st.adapter, stream, limits: @limits, admission: admission())

      assert Command.command(cid).status == :applied
      wait(&done?/0, 1_800, 10)

      s = summary()
      assert s.close.reason == "stream_end:course_complete", inspect(s)
      assert %{state: :established, seq: acq} = s.acquisition
      assert acq < 82
      [first | _] = ts = targets(st.fake)
      assert first == acq and Enum.sort(ts) == ts

      # (a displacement withheld under the unchanged envelope is timing, not admission: not asserted)
      assert s.counts.applied > 0 and s.counts.uncertain == 0 and s.counts.refused_native == 0
      assert s.native_close.clean and s.native_close.final_world == FakeMotionNative.pre()

      [act] = journal("motion.session.activated")
      assert act["session_id"] == sid and act["admission"]["verdict"] == "met"
      assert act["admission"]["high_seq"] <= 61
      [accepted] = for e <- MotionStack.journal(), e["motion"]["session_id"] == sid, do: e
      assert accepted["motion"]["admission"]["max_open_seq"] == 55
    end
  end

  describe "preparation" do
    test "AD-2: receipt 2 at source sequence 83 is refused although the former count gate passes; nothing is issued" do
      st = MotionStack.start()
      stream = open_stream()
      base = Hub.status().counts.unrouted_samples
      :ok = send_seq(stream, 1)
      :ok = send_seq(stream, 83)
      assert Hub.status().counts.unrouted_samples - base == 2

      assert {:error, {:admission_not_met, {:progress_off_anchor, 83}}} = open(st, stream)
      assert Hub.status().session == nil and Command.status().motion.sessions == []
      assert session_commands(st.fake) == [] and targets(st.fake) == []

      [refused] = journal("motion.session.admission_not_met")

      assert %{"phase" => "prepare", "received" => 2, "high_seq" => 83, "index_gaps" => 81} =
               refused["admission"]
    end

    test "AD-2b: a prefix sample at P past the open bound is refused (56 > 55)" do
      st = MotionStack.start()
      stream = open_stream()
      :ok = send_seq(stream, 56)
      assert {:error, {:admission_not_met, {:progress_beyond, 56, 55}}} = open(st, stream)
      assert session_commands(st.fake) == []
    end

    test "AD-3: benign omissions inside the prefix pass; acquisition at P; the course then moves" do
      st = MotionStack.start()
      stream = open_stream()
      for seq <- [1, 4, 9, 30], do: :ok = send_seq(stream, seq)
      assert %{advanced: 4, index_gaps: 26, high: %{seq: 30}} = progress(stream)

      {_sid, _} =
        MotionStack.open_session(st.adapter, stream, limits: @limits, admission: admission())

      Process.sleep(60)
      :ok = send_seq(stream, 45)
      wait(fn -> summary().acquisition.state == :established end)
      Process.sleep(120)
      :ok = send_seq(stream, 83)
      wait(fn -> summary().counts.applied == 1 end)
      Process.sleep(60)
      :ok = send_seq(stream, 84)
      wait(fn -> summary().counts.applied == 2 end)
      :ok = Motion.close_session(:test_end)
      wait(&done?/0)

      assert targets(st.fake) == [45, 83, 84]
      assert %{state: :established, seq: 45} = summary().acquisition
      assert summary().counts.skipped == 1
    end

    test "AD-4: the current record wins over an earlier status reading" do
      st = MotionStack.start()
      stream = open_stream()
      :ok = send_seq(stream, 50)
      # an operator's reading: eligible
      assert progress(stream).high.seq == 50
      :ok = send_seq(stream, 56)
      assert {:error, {:admission_not_met, {:progress_beyond, 56, 55}}} = open(st, stream)
      assert session_commands(st.fake) == []
    end
  end

  describe "activation (the open in flight)" do
    test "AD-5: preparation at 55 passes; progress reaching 62 while the open is in flight closes it at activation, before any target" do
      st = MotionStack.start()
      stream = open_stream()
      :ok = send_seq(stream, 55)
      {:ok, %{session_id: sid, command_id: cid}} = open(st, stream, fault: {:delay_terminal, 300})
      wait(fn -> Command.command(cid).status == :received end)
      :ok = send_seq(stream, 62)
      wait(fn -> Command.command(cid).status == :applied end)
      wait(&done?/0)

      # the behaviour first: never activated, no target bytes; then the reason
      assert journal("motion.session.activated") == []
      assert targets(st.fake) == []
      assert summary().close.reason == "admission_not_met:progress_beyond:62>61"
      # the open was issued and applied natively; the budget is not refunded
      assert session_commands(st.fake) == [{"open", "applied"}]
      assert registry(sid).state not in [:not_opened, :accepted]

      [c] = journal("motion.session.closing_at_activation")

      assert %{"phase" => "activation", "high_seq" => 62, "verdict" => "progress_beyond:62>61"} =
               c["admission"]

      assert Enum.any?(
               FakeMotionNative.events(st.fake),
               &match?({:session_closed, ^sid, "beam:admission_not_met:" <> _, _}, &1)
             )
    end

    test "AD-5b: 61 at activation passes (inclusive); the next prefix sample acquires" do
      st = MotionStack.start()
      stream = open_stream()
      :ok = send_seq(stream, 50)
      {:ok, %{command_id: cid}} = open(st, stream, fault: {:delay_terminal, 300})
      wait(fn -> Command.command(cid).status == :received end)
      :ok = send_seq(stream, 61)
      wait(fn -> match?(%{status: :active}, Hub.status().session) end)
      [a] = journal("motion.session.activated")
      assert a["admission"]["high_seq"] == 61 and a["admission"]["verdict"] == "met"
      Process.sleep(60)
      :ok = send_seq(stream, 62)
      wait(fn -> summary().acquisition.state == :established end)
      :ok = Motion.close_session(:test_end)
      wait(&done?/0)
      assert targets(st.fake) == [62]
    end
  end

  describe "the first target" do
    test "AD-6: a valid activation prefix, then the remaining prefix omitted: the displaced 83 closes the session unforwarded" do
      st = MotionStack.start()
      stream = open_stream()
      :ok = send_seq(stream, 40)

      {_sid, _} =
        MotionStack.open_session(st.adapter, stream, limits: @limits, admission: admission())

      [a] = journal("motion.session.activated")
      assert a["admission"]["verdict"] == "met"
      # the same input that CE-1 shows applied without the admission: 0.05 m, inside the bound
      Process.sleep(150)
      :ok = send_seq(stream, 83)
      wait(&done?/0)

      # the behaviour first: no target bytes reached the native; then the reason
      s = summary()

      assert targets(st.fake) == [],
             "target bytes #{inspect(targets(st.fake))}; #{inspect(s.counts)}"

      assert s.counts.forwarded == 0 and s.counts.applied == 0
      assert s.close.reason == "acquisition_missed:past_prefix:83"
      assert %{state: :missed, seq: 83} = s.acquisition
      assert s.native_close.clean and s.native_close.final_world == FakeMotionNative.pre()
    end
  end

  describe "nothing manufactures eligibility" do
    test "AD-7a: unqualified, off-anchor, none, older after higher, course mismatch" do
      st = MotionStack.start()

      s1 = open_stream()
      :ok = send_seq(s1, 10)
      :ok = send_seq(s1, 11, qualified: false)
      assert {:error, {:admission_not_met, {:progress_unqualified, 11}}} = open(st, s1)

      s2 = open_stream()
      :ok = send_seq(s2, 10, pos: pos_at(0.001))
      assert {:error, {:admission_not_met, {:progress_off_anchor, 10}}} = open(st, s2)

      s3 = open_stream()
      assert {:error, {:admission_not_met, :no_progress}} = open(st, s3)

      s4 = open_stream()
      :ok = send_seq(s4, 60)
      :ok = send_seq(s4, 10)
      assert %{not_advanced: 1, high: %{seq: 60}} = progress(s4)
      assert {:error, {:admission_not_met, {:progress_beyond, 60, 55}}} = open(st, s4)

      s5 = open_stream(course: "out_and_back another")
      :ok = send_seq(s5, 10)
      assert {:error, {:admission_not_met, :course_mismatch}} = open(st, s5)

      assert session_commands(st.fake) == [] and targets(st.fake) == []
    end

    test "AD-7b: another stream's progress never qualifies the approved one; an unknown stream is not open" do
      st = MotionStack.start()
      a = open_stream()
      b = open_stream()
      :ok = send_seq(a, 10)
      :ok = send_seq(b, 70)
      assert {:error, {:admission_not_met, {:progress_beyond, 70, 55}}} = open(st, b)
      assert {:error, :stream_not_open} = open(st, Schema.uuid4())
      assert progress(a).high.seq == 10 and progress(b).high.seq == 70
    end

    test "AD-7c: a stream identity that ended and is opened again is marked reopened and cannot qualify" do
      st = MotionStack.start()
      x = open_stream()
      :ok = send_seq(x, 10)
      :ok = end_stream(x)
      ^x = open_stream(id: x)
      :ok = send_seq(x, 11)
      assert Hub.status().peer.streams[x].reopened == true
      assert {:error, {:admission_not_met, :stream_reopened}} = open(st, x)
    end

    test "AD-7d: a new peer connection generation starts with no streams; progress never transfers" do
      st = MotionStack.start()
      s = open_stream()
      :ok = send_seq(s, 10)
      g1 = Hub.status().peer.connection_generation
      Process.exit(peer_info().connection, :kill)
      wait(fn -> match?(%{connection_generation: g} when g != g1, Hub.status().peer) end, 600)
      assert Hub.status().peer.streams == %{}
      assert {:error, :stream_not_open} = open(st, s)
      assert {:error, :peer_connection_mismatch} = open(st, s, peer_connection_generation: g1)
      s2 = open_stream()
      assert progress(s2) == GlacierRelay.Motion.StreamProgress.new()
    end

    test "AD-7e: the authority refuses an anchor that is not the qualified inspection's; the hub's preparation is abandoned" do
      st = MotionStack.start()
      q = pos_at(0.5)
      {:ok, [qx, qy, _]} = TransformWords.decode(q, 3)
      s = open_stream()
      :ok = send_seq(s, 10, pos: q)

      assert {:error, :admission_anchor_not_the_inspection} =
               open(st, s, admission: admission(%{anchor: TransformWords.encode([qx, qy])}))

      assert Hub.status().session == nil and session_commands(st.fake) == []
    end

    test "AD-7f: an admission is for a synthetic stream only, and must be well formed" do
      st = MotionStack.start()
      s = open_stream()
      :ok = send_seq(s, 10)
      assert {:error, :admission_requires_synthetic} = open(st, s, source_kind: "game")

      assert {:error, :admission_sequence_bounds} =
               open(st, s, admission: admission(%{max_open_seq: 70}))

      assert Hub.status().session == nil and session_commands(st.fake) == []
    end
  end

  describe "existing semantics while the open is in flight (with an admission)" do
    test "AD-8a: the stream's end while opening: binding lost at activation; no target" do
      st = MotionStack.start()
      stream = open_stream()
      :ok = send_seq(stream, 20)
      {:ok, %{command_id: cid}} = open(st, stream, fault: {:delay_terminal, 300})
      wait(fn -> Command.command(cid).status == :received end)
      :ok = end_stream(stream)
      wait(&done?/0)
      assert summary().close.reason == "binding_lost_before_activation"
      assert targets(st.fake) == []
    end

    test "AD-8b: the operator's close while opening is applied at activation; no target" do
      st = MotionStack.start()
      stream = open_stream()
      :ok = send_seq(stream, 20)
      {:ok, %{command_id: cid}} = open(st, stream, fault: {:delay_terminal, 300})
      wait(fn -> Command.command(cid).status == :received end)
      :ok = Motion.close_session(:operator)
      wait(&done?/0)
      assert summary().close.reason == "operator"
      assert targets(st.fake) == []
    end

    test "AD-8c: peer-link loss while opening: binding lost at activation; no target" do
      st = MotionStack.start()
      stream = open_stream()
      :ok = send_seq(stream, 20)
      {:ok, %{command_id: cid}} = open(st, stream, fault: {:delay_terminal, 300})
      wait(fn -> Command.command(cid).status == :received end)
      Process.exit(peer_info().connection, :kill)
      wait(&done?/0, 600)
      assert summary().close.reason == "binding_lost_before_activation"
      assert targets(st.fake) == []
    end
  end
end
