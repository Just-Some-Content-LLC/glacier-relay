defmodule GlacierRelay.SummaryTest do
  use ExUnit.Case, async: true

  alias GlacierRelay.{Lifecycle, Summary}
  alias GlacierRelay.Wire.Envelope

  @paris "assembly:/_PRO/Scenes/Missions/Paris/_Scene_FashionShowHit_01.entity"
  @sapienza "assembly:/_PRO/Scenes/Missions/CoastalTown/Mission01.entity"
  @id "d9281e62-1a66-480f-b060-9c763d28b524"

  defp env(type, seq, ts, resource, hint) do
    %Envelope{
      protocol_version: 1,
      adapter_instance_id: @id,
      sequence: seq,
      timestamp: ts,
      event_type: type,
      schema_version: 1,
      payload: %{
        scene_resource: resource,
        scene_type: "mission",
        codename_hint: hint,
        game_session_id: "sid-#{seq}"
      }
    }
  end

  defp t(iso), do: elem(DateTime.from_iso8601(iso), 1)

  # The proposed Stage A run, in the outcome where the in-mission quit terminates the process
  # before the native observer sees the predicate fall: three attempts, the last left open, then
  # the connection closes.
  defp stage_a_quit_without_stop do
    instance = Lifecycle.new(@id)

    instance =
      Lifecycle.connection_identified(
        instance,
        "127.0.0.1:42288",
        t("2026-10-06T22:42:54.295Z"),
        t("2026-10-06T22:44:38.307Z")
      )

    events = [
      env("mission.playing", 1, "2026-10-06T22:44:38.230Z", @paris, "Peacock"),
      env("mission.stopped", 2, "2026-10-06T22:45:44.243Z", @paris, "Peacock"),
      env("mission.playing", 3, "2026-10-06T22:45:55.143Z", @paris, "Peacock"),
      env("mission.stopped", 4, "2026-10-06T22:46:50.000Z", @paris, "Peacock"),
      env("mission.playing", 5, "2026-10-06T22:47:20.571Z", @sapienza, "Octopus")
    ]

    instance =
      Enum.reduce(events, instance, fn e, inst ->
        {inst, _} = Lifecycle.apply_event(inst, e, t(e.timestamp))
        inst
      end)

    Lifecycle.connection_closed(instance, t("2026-10-06T22:48:29.785Z"), :peer_closed)
  end

  test "build describes attempts from events only, with observation separate from mission state" do
    [summary] = Summary.build(%{@id => stage_a_quit_without_stop()})

    assert summary.adapter_instance_id == @id
    assert summary.received == 5 and summary.last_sequence == 5 and summary.gaps == []
    assert summary.observation == :lost

    assert [%{peer: "127.0.0.1:42288", close_reason: :peer_closed, closed_at: %DateTime{}}] =
             summary.connections

    [a1, a2, a3] = summary.attempts

    assert %{
             number: 1,
             codename_hint: "Peacock",
             mission: :stopped,
             open?: false,
             duration_ms: 66_013,
             interrupted?: false
           } = a1

    assert a1.playing_at == "2026-10-06T22:44:38.230Z" and
             a1.stopped_at == "2026-10-06T22:45:44.243Z"

    assert a1.game_session_id == %{playing: "sid-1", stopped: "sid-2"}

    assert %{number: 2, mission: :stopped, scene_resource: @paris} = a2
    refute Map.has_key?(a2, :restart)

    assert %{
             number: 3,
             codename_hint: "Octopus",
             mission: :playing,
             open?: true,
             stopped_at: nil,
             duration_ms: nil,
             interrupted?: true
           } = a3

    assert [%{reason: :peer_closed}] = a3.interruptions
    refute Map.has_key?(a3, :outcome)
  end

  test "render states what was observed and says 'not observed' where nothing was" do
    text = Summary.render(%{@id => stage_a_quit_without_stop()})

    assert text =~ "adapter #{@id}: 5 event(s), last sequence 5, gaps [], observation lost"
    assert text =~ "connection 127.0.0.1:42288: opened 2026-10-06T22:42:54.295Z"
    assert text =~ "closed 2026-10-06T22:48:29.785Z (:peer_closed)"

    assert text =~
             "attempt 1: Peacock (#{@paris}): playing 2026-10-06T22:44:38.230Z (#1), stopped 2026-10-06T22:45:44.243Z (#2), duration 66.0 s"

    assert text =~ "attempt 2: Peacock"

    assert text =~
             "attempt 3: Octopus (#{@sapienza}): playing 2026-10-06T22:47:20.571Z (#5), stop not observed; last known playing; observation lost 2026-10-06T22:48:29.785Z (:peer_closed)"

    refute text =~ "restart"
    refute text =~ "ended"
    refute text =~ "complete"
  end

  test "render covers superseded attempts and unmatched stops" do
    instance = Lifecycle.new(@id)

    instance =
      Enum.reduce(
        [
          env("mission.stopped", 1, "2026-10-06T22:40:00.000Z", @paris, "Peacock"),
          env("mission.playing", 2, "2026-10-06T22:44:38.230Z", @paris, "Peacock"),
          env("mission.playing", 4, "2026-10-06T22:45:55.143Z", @paris, "Peacock")
        ],
        instance,
        fn e, inst -> elem(Lifecycle.apply_event(inst, e, t(e.timestamp)), 0) end
      )

    text = Summary.render(%{@id => instance})
    assert text =~ "observation never"
    assert text =~ "mission.stopped #1 at 2026-10-06T22:40:00.000Z with no open attempt"

    assert text =~
             "attempt 1: Peacock (#{@paris}): playing 2026-10-06T22:44:38.230Z (#2), stop not observed; superseded by attempt 2"

    assert text =~
             "attempt 2: Peacock (#{@paris}): playing 2026-10-06T22:45:55.143Z (#4), stop not observed; last known playing"

    assert text =~ "gaps [{3, 4}]"
  end

  test "an empty state and unidentified connections render" do
    assert Summary.render(%{}) == "no adapter instance has delivered an event"

    text =
      Summary.render(%{}, [
        %{
          peer: "127.0.0.1:5",
          opened_at: t("2026-10-06T22:00:00Z"),
          closed_at: t("2026-10-06T22:00:01Z"),
          close_reason: :peer_closed
        }
      ])

    assert text =~ "connections that closed before identifying an instance: 1"

    assert text =~
             "127.0.0.1:5 opened 2026-10-06T22:00:00Z closed 2026-10-06T22:00:01Z (:peer_closed)"
  end
end
