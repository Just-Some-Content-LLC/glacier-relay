defmodule GlacierRelay.Motion.HubAbandonTest do
  @moduledoc """
  M7-L1 correction: `Motion.Hub.abandon/1` — forgetting a prepared share or session that the
  authority did not accept — on the owned loopback motion stack with the fake native (fake-native
  evidence only). Its earlier form evaluated a strict `and` on a nil session and raised
  `BadBooleanError`, so an authority refusal of a prepared share crashed the hub (an M7-L1
  finding).

  Through the production facade (`GlacierRelay.Motion`, the authority, the result decoder): an
  ordinary authority refusal after a share's or a session's preparation is answered as that
  refusal, the pending preparation is gone, the hub is the same process on the same motion link
  and peer connection, and no open reaches the native; a legitimate open afterwards succeeds.
  Directly on the hub: only the matching PENDING preparation is forgotten — no share or session, a
  foreign id, or an active or done operation leave everything as it was (no release, no
  eligibility or budget change, no stream replaced).
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.{Command, Motion}
  alias GlacierRelay.Command.Schema
  alias GlacierRelay.Motion.Hub
  alias GlacierRelay.Peer.{Connection, Endpoint}
  alias GlacierRelay.Test.{FakeMotionNative, MotionStack}

  @gen FakeMotionNative.generation()

  defp wait(fun, attempts \\ 400), do: MotionStack.wait(fun, attempts, 10)

  # the hub's identity and its two links, which an abandonment must leave as they are
  defp health do
    s = Hub.status()

    %{
      hub: Process.whereis(Hub),
      link: s.link,
      peer: s.peer && Map.take(s.peer, [:connection_generation, :boot_id]),
      connection: Endpoint.status(Motion.PeerEndpoint).connection
    }
  end

  defp commands(fake, name),
    do:
      for({:command, ^name, mode, status, _} <- FakeMotionNative.events(fake), do: {mode, status})

  # what an abandonment must not change: the hub's view and the authority's motion registry
  defp untouched do
    hub = :sys.get_state(Hub)

    %{
      share: hub.share && Map.take(hub.share, [:id, :status]),
      session: hub.session && Map.take(hub.session, [:id, :status]),
      used_streams: hub.used_streams,
      streams: hub.peer && Map.keys(hub.peer.streams),
      authority: Map.take(Command.status().motion, [:sessions, :exclusivity])
    }
  end

  defp statement(id) do
    s = Hub.status()

    %{
      share_id: id,
      motion_link_generation: s.link.generation,
      duration_ms: 1_000,
      interval_ms: 50,
      peer: %{connection_generation: s.peer.connection_generation, boot_id: s.peer.boot_id},
      label: "abandon test"
    }
  end

  defp approval(id, stream) do
    s = Hub.status()

    %{
      session_id: id,
      peer: Map.take(s.peer, [:connection_generation, :boot_id, :label, :pin]),
      stream_id: stream,
      source_kind: "synthetic",
      motion_link_generation: s.link.generation,
      limits: GlacierRelay.Motion.Destination.defaults(),
      mapping: "identity"
    }
  end

  describe "through the production facade" do
    test "an authority refusal of a prepared share (no session): the refusal answered, the share forgotten, nothing sent" do
      st = MotionStack.start()
      :ok = MotionStack.arm()
      before = health()

      # a duration below the schema's 1,000 ms: the authority refuses before any issuance
      assert {:error, {:invalid_param, "duration_ms", {:not_an_integer_within, 1_000, 300_000}}} =
               Motion.open_share(duration_ms: 600, expected_generation: @gen)

      assert Hub.status().share == nil and Hub.status().session == nil
      assert health() == before
      assert commands(st.fake, "player.pose.share") == []

      # control: a legitimate share opens on the same hub, through the native's answer
      {:ok, %{share_id: id, command_id: cid}} =
        Motion.open_share(duration_ms: 1_000, expected_generation: @gen)

      wait(fn -> Command.command(cid).status == :applied end)
      wait(fn -> match?(%{id: ^id, status: :active}, Hub.status().share) end)
      assert commands(st.fake, "player.pose.share") == [{"open", "applied"}]
      assert health() == before
    end

    test "an authority refusal of a prepared session while a share is active: only the pending session is forgotten" do
      st = MotionStack.start()
      :ok = MotionStack.arm()
      {:ok, %{share_id: share}} = Motion.open_share(duration_ms: 5_000, expected_generation: @gen)
      wait(fn -> match?(%{id: ^share, status: :active}, Hub.status().share) end)
      stream = MotionStack.start_course()
      :ok = MotionStack.arm_effectful(st.adapter)
      before = health()
      native_before = Hub.status().share.summary.counts.native

      # an inspection this authority never completed: refused before any issuance
      assert {:error, :inspection_not_in_journal} =
               Motion.open_session(
                 inspection_command_id: Schema.uuid4(),
                 expected_generation: @gen,
                 stream_id: stream,
                 source_kind: "synthetic"
               )

      assert Hub.status().session == nil
      assert commands(st.fake, "candidate.motion.session") == []
      # the active share is undisturbed: the same share, still active, still sampling
      assert match?(%{id: ^share, status: :active}, Hub.status().share)
      wait(fn -> Hub.status().share.summary.counts.native > native_before end)
      assert health() == before

      # control: a legitimate session opens on the same stream (the refusal consumed no arming)
      insp = MotionStack.inspect_exact()

      {:ok, %{session_id: sid, command_id: cid}} =
        Motion.open_session(
          inspection_command_id: insp,
          expected_generation: @gen,
          stream_id: stream,
          source_kind: "synthetic"
        )

      wait(fn -> Command.command(cid).status == :applied end)
      wait(fn -> match?(%{id: ^sid, status: :active}, Hub.status().session) end)
      assert commands(st.fake, "candidate.motion.session") == [{"open", "applied"}]
      assert health() == before
    end
  end

  describe "on the hub" do
    test "no share and no session: an abandonment changes nothing" do
      MotionStack.start()
      before = {health(), untouched()}
      assert :ok = Hub.abandon(Schema.uuid4())
      assert {health(), untouched()} == before
    end

    test "a pending share with no session: the share alone is forgotten" do
      MotionStack.start()
      id = Schema.uuid4()
      {:ok, _} = Hub.prepare_share(statement(id))
      assert match?(%{id: ^id, status: :pending}, Hub.status().share)
      before = health()
      assert :ok = Hub.abandon(id)
      assert Hub.status().share == nil and Hub.status().session == nil
      assert health() == before
    end

    test "a pending session with no share: the session alone is forgotten" do
      MotionStack.start()
      stream = MotionStack.start_course()
      id = Schema.uuid4()
      {:ok, _} = Hub.prepare_session(approval(id, stream))
      assert match?(%{id: ^id, status: :pending}, Hub.status().session)
      before = health()
      assert :ok = Hub.abandon(id)
      assert Hub.status().session == nil and Hub.status().share == nil
      assert Map.has_key?(Hub.status().peer.streams, stream)
      assert health() == before
    end

    test "foreign ids leave both preparations; each id forgets only its own" do
      MotionStack.start()
      stream = MotionStack.start_course()
      {share, session} = {Schema.uuid4(), Schema.uuid4()}
      {:ok, _} = Hub.prepare_share(statement(share))
      {:ok, _} = Hub.prepare_session(approval(session, stream))
      before = untouched()

      for foreign <- [Schema.uuid4(), "not-an-id", stream] do
        assert :ok = Hub.abandon(foreign)
        assert untouched() == before
      end

      assert :ok = Hub.abandon(share)
      assert Hub.status().share == nil
      assert match?(%{id: ^session, status: :pending}, Hub.status().session)
      assert :ok = Hub.abandon(session)
      assert Hub.status().session == nil
    end

    test "an active share and an active session are not abandoned: no release, the motion continues" do
      st = MotionStack.start()
      :ok = MotionStack.arm()
      {:ok, %{share_id: share}} = Motion.open_share(duration_ms: 5_000, expected_generation: @gen)
      wait(fn -> match?(%{id: ^share, status: :active}, Hub.status().share) end)
      stream = MotionStack.start_course(MotionStack.short_course(prefix_ms: 3_000))
      {sid, _} = MotionStack.open_session(st.adapter, stream)
      before = {health(), untouched()}
      %{pid: conn} = Endpoint.status(Motion.PeerEndpoint).connection
      out_before = Connection.status(conn).counts.samples_out

      assert :ok = Hub.abandon(share)
      assert :ok = Hub.abandon(sid)
      assert {health(), untouched()} == before
      # nothing was released: the share still relays and the session still receives
      wait(fn -> Connection.status(conn).counts.samples_out > out_before end)
      received = Hub.status().session.summary.counts.received
      wait(fn -> Hub.status().session.summary.counts.received > received end)
      assert FakeMotionNative.status(st.fake).session.id == sid
    end

    test "a done share and a done session are not abandoned: their accounts and the authority's registry stay" do
      st = MotionStack.start(max_sessions: 2)
      :ok = MotionStack.arm()
      {:ok, %{share_id: share}} = Motion.open_share(duration_ms: 1_000, expected_generation: @gen)
      wait(fn -> match?(%{id: ^share, status: :done}, Hub.status().share) end, 500)
      stream = MotionStack.start_course()
      {sid, _} = MotionStack.open_session(st.adapter, stream)
      wait(fn -> match?(%{id: ^sid, status: :done}, Hub.status().session) end, 800)
      summaries = {Hub.status().share.summary, Hub.status().session.summary}
      before = {health(), untouched()}

      assert :ok = Hub.abandon(share)
      assert :ok = Hub.abandon(sid)
      assert {health(), untouched()} == before
      assert {Hub.status().share.summary, Hub.status().session.summary} == summaries
    end
  end
end
