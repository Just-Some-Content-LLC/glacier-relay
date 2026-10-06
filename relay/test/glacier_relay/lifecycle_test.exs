defmodule GlacierRelay.LifecycleTest do
  use ExUnit.Case, async: true

  alias GlacierRelay.Lifecycle
  alias GlacierRelay.Lifecycle.{Attempt, Instance, Observation}
  alias GlacierRelay.Wire.Envelope

  @paris "assembly:/_PRO/Scenes/Missions/Paris/_Scene_FashionShowHit_01.entity"
  @sapienza "assembly:/_PRO/Scenes/Missions/CoastalTown/Mission01.entity"
  @id "d9281e62-1a66-480f-b060-9c763d28b524"

  defp envelope(type, sequence, timestamp, resource, opts) do
    %Envelope{
      protocol_version: 1,
      adapter_instance_id: Keyword.get(opts, :instance, @id),
      sequence: sequence,
      timestamp: timestamp,
      event_type: type,
      schema_version: 1,
      payload: %{
        scene_resource: resource,
        scene_type: Keyword.get(opts, :scene_type, "mission"),
        codename_hint: Keyword.get(opts, :hint, "Peacock"),
        game_session_id: Keyword.get(opts, :session, nil)
      }
    }
  end

  defp playing(seq, ts, resource, opts \\ []),
    do: envelope("mission.playing", seq, ts, resource, opts)

  defp stopped(seq, ts, resource, opts \\ []),
    do: envelope("mission.stopped", seq, ts, resource, opts)

  defp t(iso), do: elem(DateTime.from_iso8601(iso), 1)

  defp fold(instance, events) do
    Enum.reduce(events, {instance, []}, fn
      {:connection_identified, peer, opened, at}, {inst, notes} ->
        {Lifecycle.connection_identified(inst, peer, opened, at), notes}

      {:connection_closed, at, reason}, {inst, notes} ->
        {Lifecycle.connection_closed(inst, at, reason), notes}

      %Envelope{} = env, {inst, notes} ->
        {inst, more} = Lifecycle.apply_event(inst, env, t(env.timestamp))
        {inst, notes ++ more}
    end)
  end

  test "a new instance has no attempts and has never been observed" do
    instance = Lifecycle.new(@id)
    assert %Instance{id: @id, attempts: [], connections: []} = instance
    assert Lifecycle.observation(instance) == :never
    assert Lifecycle.current_attempt(instance) == nil
  end

  test "playing then stopped is one bounded attempt with a duration from native timestamps" do
    {instance, notes} =
      fold(Lifecycle.new(@id), [
        playing(1, "2026-10-06T22:44:38.230Z", @paris, session: "s1"),
        stopped(2, "2026-10-06T22:45:44.243Z", @paris, session: "s1")
      ])

    assert notes == []
    assert [%Attempt{number: 1, mission: :stopped} = attempt] = instance.attempts
    assert attempt.scene_resource == @paris

    assert %Observation{sequence: 1, timestamp: "2026-10-06T22:44:38.230Z", game_session_id: "s1"} =
             attempt.playing

    assert %Observation{sequence: 2, timestamp: "2026-10-06T22:45:44.243Z"} = attempt.stopped

    assert attempt.stopped_scene == %{
             scene_resource: @paris,
             scene_type: "mission",
             codename_hint: "Peacock"
           }

    assert Lifecycle.duration_ms(attempt) == 66_013
    assert Lifecycle.current_attempt(instance) == nil
    assert instance.last_sequence == 2 and instance.received == 2 and instance.gaps == []
  end

  test "an open attempt is last known playing with no stop and no duration" do
    {instance, []} = fold(Lifecycle.new(@id), [playing(1, "2026-10-06T22:44:38.230Z", @paris)])

    assert %Attempt{mission: :playing, stopped: nil} =
             attempt = Lifecycle.current_attempt(instance)

    assert Lifecycle.duration_ms(attempt) == nil
  end

  test "the M1 final-run timeline with falls: three bounded attempts, same mission twice is not labelled" do
    {instance, notes} =
      fold(Lifecycle.new(@id), [
        playing(1, "2026-10-06T22:44:38.230Z", @paris, session: "p1"),
        stopped(2, "2026-10-06T22:45:44.243Z", @paris, session: "p1"),
        playing(3, "2026-10-06T22:45:55.143Z", @paris, session: "p2"),
        stopped(4, "2026-10-06T22:46:50.000Z", @paris, session: "p2"),
        playing(5, "2026-10-06T22:47:20.571Z", @sapienza, hint: "Octopus", session: "s1"),
        stopped(6, "2026-10-06T22:48:10.000Z", @sapienza, hint: "Octopus", session: "s1")
      ])

    assert notes == []
    assert Enum.map(instance.attempts, & &1.number) == [1, 2, 3]
    assert Enum.map(instance.attempts, & &1.mission) == [:stopped, :stopped, :stopped]
    assert Enum.map(instance.attempts, & &1.scene_resource) == [@paris, @paris, @sapienza]
    # Attempts 1 and 2 are the same scene back to back. The model records two attempts and
    # nothing else: no "restart" field exists to be set.
    refute Map.has_key?(hd(instance.attempts), :restart)
    assert instance.gaps == []
  end

  test "a second playing while one is open supersedes it; the first is not marked stopped" do
    {instance, notes} =
      fold(Lifecycle.new(@id), [
        playing(1, "2026-10-06T22:44:38.230Z", @paris),
        # #2 (the stop) was lost; the gap shows it.
        playing(3, "2026-10-06T22:45:55.143Z", @paris)
      ])

    assert [
             %Attempt{number: 1, mission: :superseded, superseded_by: 2, stopped: nil},
             %Attempt{number: 2, mission: :playing}
           ] =
             instance.attempts

    assert {:gap, 2, 3} in notes
    assert {:superseded, 1, 2} in notes
    assert instance.gaps == [{2, 3}]
  end

  test "a stopped with no open attempt is kept as unmatched evidence; no attempt is invented" do
    {instance, notes} = fold(Lifecycle.new(@id), [stopped(1, "2026-10-06T22:45:44.243Z", @paris)])
    assert instance.attempts == []

    assert [%{observation: %Observation{sequence: 1}, payload: %{scene_resource: @paris}}] =
             instance.unmatched_stops

    assert notes == [{:unmatched_stop, 1}]
  end

  test "a stopped whose fall-frame scene differs from the rise still closes the attempt and says so" do
    {instance, notes} =
      fold(Lifecycle.new(@id), [
        playing(1, "2026-10-06T22:44:38.230Z", @paris),
        # Observability lost on the fall frame: the native side reports empty fields.
        stopped(2, "2026-10-06T22:45:44.243Z", "", scene_type: "", hint: "")
      ])

    assert [
             %Attempt{
               mission: :stopped,
               scene_resource: @paris,
               stopped_scene: %{scene_resource: ""}
             }
           ] = instance.attempts

    assert notes == [{:fall_scene_differs, 1, @paris, ""}]
  end

  test "connection closing with no open attempt changes observation only" do
    {instance, []} =
      fold(Lifecycle.new(@id), [
        {:connection_identified, "127.0.0.1:1", t("2026-10-06T22:42:54.295Z"),
         t("2026-10-06T22:44:38.300Z")},
        playing(1, "2026-10-06T22:44:38.230Z", @paris),
        stopped(2, "2026-10-06T22:45:44.243Z", @paris),
        {:connection_closed, t("2026-10-06T22:48:29.785Z"), :peer_closed}
      ])

    assert Lifecycle.observation(instance) == :lost
    assert [%Attempt{mission: :stopped, interruptions: []}] = instance.attempts
    assert [%{closed_at: %DateTime{}, close_reason: :peer_closed}] = instance.connections
  end

  test "connection closing while an attempt is open: last known playing, observation lost, no stop invented" do
    {instance, []} =
      fold(Lifecycle.new(@id), [
        {:connection_identified, "127.0.0.1:1", t("2026-10-06T22:42:54.295Z"),
         t("2026-10-06T22:44:38.300Z")},
        playing(1, "2026-10-06T22:47:20.571Z", @sapienza, hint: "Octopus"),
        {:connection_closed, t("2026-10-06T22:48:29.785Z"), :peer_closed}
      ])

    assert Lifecycle.observation(instance) == :lost

    assert %Attempt{mission: :playing, stopped: nil} =
             attempt = Lifecycle.current_attempt(instance)

    assert [%{at: %DateTime{}, reason: :peer_closed}] = attempt.interruptions
    assert Lifecycle.duration_ms(attempt) == nil
  end

  test "a semantic stop after the connection was lost closes the attempt from that evidence" do
    {instance, []} =
      fold(Lifecycle.new(@id), [
        {:connection_identified, "127.0.0.1:1", t("2026-10-06T22:42:54.295Z"),
         t("2026-10-06T22:44:38.300Z")},
        playing(1, "2026-10-06T22:44:38.230Z", @paris),
        {:connection_closed, t("2026-10-06T22:45:00.000Z"), {:tcp_error, :econnreset}},
        # The native sink reconnected with the same instance id and the stop arrived.
        {:connection_identified, "127.0.0.1:2", t("2026-10-06T22:45:03.000Z"),
         t("2026-10-06T22:45:44.300Z")},
        stopped(2, "2026-10-06T22:45:44.243Z", @paris)
      ])

    assert Lifecycle.observation(instance) == :live

    assert [
             %Attempt{mission: :stopped, interruptions: [%{reason: {:tcp_error, :econnreset}}]} =
               attempt
           ] = instance.attempts

    assert Lifecycle.duration_ms(attempt) == 66_013
    assert length(instance.connections) == 2
  end

  test "reconnect with the same instance id and no events invents no lifecycle" do
    {instance, []} =
      fold(Lifecycle.new(@id), [
        {:connection_identified, "127.0.0.1:1", t("2026-10-06T22:42:54.295Z"),
         t("2026-10-06T22:44:38.300Z")},
        playing(1, "2026-10-06T22:44:38.230Z", @paris),
        stopped(2, "2026-10-06T22:45:44.243Z", @paris),
        {:connection_closed, t("2026-10-06T22:46:00.000Z"), :peer_closed},
        {:connection_identified, "127.0.0.1:2", t("2026-10-06T22:46:03.000Z"),
         t("2026-10-06T22:46:03.100Z")}
      ])

    assert length(instance.attempts) == 1
    assert Lifecycle.observation(instance) == :live
  end

  test "closing when no connection is open is a no-op" do
    instance = Lifecycle.new(@id)

    assert Lifecycle.connection_closed(instance, t("2026-10-06T22:46:00.000Z"), :peer_closed) ==
             instance
  end

  test "sequence gaps are recorded as before and the first event is never a gap" do
    {instance, notes} =
      fold(Lifecycle.new(@id), [
        playing(5, "2026-10-06T22:44:38.230Z", @paris),
        stopped(6, "2026-10-06T22:45:44.243Z", @paris),
        playing(9, "2026-10-06T22:45:55.143Z", @paris)
      ])

    assert instance.gaps == [{7, 9}]
    assert notes == [{:gap, 7, 9}]
    assert instance.last_sequence == 9 and instance.received == 3
  end

  test "duration is nil when a timestamp does not parse" do
    {instance, []} =
      fold(Lifecycle.new(@id), [
        playing(1, "not-a-time", @paris),
        stopped(2, "2026-10-06T22:45:44.243Z", @paris)
      ])

    assert Lifecycle.duration_ms(hd(instance.attempts)) == nil
  end
end
