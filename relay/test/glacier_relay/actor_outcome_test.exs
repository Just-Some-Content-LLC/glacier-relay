defmodule GlacierRelay.ActorOutcomeTest do
  @moduledoc """
  M2 B1: actor.died / actor.pacified validation, attempt association by stream order, no
  collapsing of pacify-then-died, unattributed outcomes, and the summary counts. Uses the 18
  envelopes the native pipeline (TelemetryNormalizer -> RelayAdapter -> TcpRelaySink) produced
  from the 16 recorded B0 telemetry events in the B1 standalone wire run (2026-10-07).
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.{Lifecycle, Summary}
  alias GlacierRelay.Lifecycle.{Attempt, Outcome}
  alias GlacierRelay.Wire.Envelope

  @lines File.read!("test/b1_probe_envelopes.ndjson") |> String.split("\n", trim: true)
  @id "bf3be44e-a36d-4ac6-9508-d94330fb855e"

  defp decoded,
    do:
      Enum.map(@lines, fn l ->
        {:ok, e} = Envelope.decode(l)
        e
      end)

  defp fold(envelopes, instance \\ Lifecycle.new(@id)) do
    Enum.reduce(envelopes, {instance, []}, fn e, {inst, notes} ->
      {inst, more} = Lifecycle.apply_event(inst, e, nil)
      {inst, notes ++ more}
    end)
  end

  defp valid_outcome_map(type \\ "actor.died") do
    %{
      "protocol_version" => 1,
      "adapter_instance_id" => "00000000-0000-4000-8000-000000000001",
      "sequence" => 2,
      "timestamp" => "2026-10-07T02:00:00.000Z",
      "event_type" => type,
      "schema_version" => 1,
      "payload" => %{
        "source" => "engine_telemetry",
        "repository_id" => "5dc7ede5-bb9d-4f93-a892-cb7fb2791b19",
        "actor_name" => "Jacqueline Ducloitre",
        "engine_actor_id" => 195_054_661,
        "actor_type" => "civilian",
        "is_target" => false,
        "death_type" => "kill",
        "death_context" => "murder",
        "accident" => false,
        "kill_class" => "melee",
        "method_broad" => "unarmed",
        "method_strict" => "",
        "damage_events" => ["CoupDeGrace"]
      }
    }
  end

  defp decode(map), do: map |> JSON.encode!() |> Envelope.decode()

  # -- validation ----------------------------------------------------------------------------

  test "every envelope the native pipeline produced decodes; 16 actor outcomes between playing and stopped" do
    envelopes = decoded()
    assert Enum.map(envelopes, & &1.sequence) == Enum.to_list(1..18)
    assert hd(envelopes).event_type == "mission.playing"
    assert List.last(envelopes).event_type == "mission.stopped"

    actors = Enum.filter(envelopes, &GlacierRelay.Events.actor_outcome?(&1.event_type))
    assert length(actors) == 16
    assert Enum.count(actors, &(&1.event_type == "actor.died")) == 10
    assert Enum.count(actors, &(&1.event_type == "actor.pacified")) == 6

    assert Enum.all?(
             actors,
             &(&1.schema_version == 1 and &1.payload.source == "engine_telemetry")
           )

    # Glacier field names never appear on the BEAM side.
    refute Enum.any?(actors, fn e ->
             Map.has_key?(e.payload, :KillType) or Map.has_key?(e.payload, "KillType")
           end)
  end

  test "actor outcome payload: required fields, optional fields, types" do
    assert {:ok, %Envelope{payload: p}} = decode(valid_outcome_map())
    assert p.repository_id == "5dc7ede5-bb9d-4f93-a892-cb7fb2791b19"
    assert p.engine_actor_id == 195_054_661

    assert p.death_type == "kill" and p.death_context == "murder" and
             p.damage_events == ["CoupDeGrace"]

    assert p.item_repository_id == nil and p.contract_session_id == nil and
             p.engine_timestamp_s == nil

    assert p.death_type_code == nil

    with_opts =
      valid_outcome_map()
      |> put_in(["payload", "item_repository_id"], "e70adb5b")
      |> put_in(["payload", "contract_session_id"], "2516109628137904204-c00b2d17")
      |> put_in(["payload", "engine_timestamp_s"], 393.780243)
      |> put_in(["payload", "death_type_code"], 7)

    assert {:ok, %Envelope{payload: p2}} = decode(with_opts)

    assert p2.item_repository_id == "e70adb5b" and p2.engine_timestamp_s == 393.780243 and
             p2.death_type_code == 7

    assert {:ok, %Envelope{event_type: "actor.pacified"}} =
             decode(valid_outcome_map("actor.pacified"))
  end

  test "malformed actor outcomes are rejected" do
    for key <-
          ~w(source repository_id actor_name engine_actor_id actor_type is_target death_type death_context accident kill_class method_broad method_strict damage_events) do
      assert {:error, {:missing_field, ^key}} =
               decode(update_in(valid_outcome_map(), ["payload"], &Map.delete(&1, key)))
    end

    assert {:error, {:invalid_field, "repository_id"}} =
             decode(put_in(valid_outcome_map(), ["payload", "repository_id"], ""))

    assert {:error, {:invalid_field, "engine_actor_id"}} =
             decode(put_in(valid_outcome_map(), ["payload", "engine_actor_id"], -1))

    assert {:error, {:invalid_field, "engine_actor_id"}} =
             decode(put_in(valid_outcome_map(), ["payload", "engine_actor_id"], "x"))

    assert {:error, {:invalid_field, "is_target"}} =
             decode(put_in(valid_outcome_map(), ["payload", "is_target"], "no"))

    assert {:error, {:invalid_field, "damage_events"}} =
             decode(put_in(valid_outcome_map(), ["payload", "damage_events"], "Shoot"))

    assert {:error, {:invalid_field, "damage_events"}} =
             decode(put_in(valid_outcome_map(), ["payload", "damage_events"], [1]))

    assert {:error, {:invalid_field, "engine_timestamp_s"}} =
             decode(put_in(valid_outcome_map(), ["payload", "engine_timestamp_s"], "late"))

    assert {:error, {:unsupported_schema_version, "actor.died", 2}} =
             decode(Map.put(valid_outcome_map(), "schema_version", 2))

    assert {:error, {:unknown_event_type, "actor.killed"}} =
             decode(Map.put(valid_outcome_map(), "event_type", "actor.killed"))

    # unknown payload keys are ignored
    assert {:ok, _} = decode(put_in(valid_outcome_map(), ["payload", "future"], 1))
  end

  # -- attempt association --------------------------------------------------------------------

  test "outcomes attach to the open attempt in stream order; pacify then died stays two outcomes" do
    {instance, notes} = fold(decoded())
    assert notes == []
    assert [%Attempt{mission: :stopped, outcomes: outcomes}] = instance.attempts
    assert length(outcomes) == 16
    assert Enum.map(outcomes, & &1.sequence) == Enum.to_list(2..17)
    assert instance.unattributed_outcomes == []

    ducloitre = Enum.filter(outcomes, &(&1.payload.actor_name == "Jacqueline Ducloitre"))

    assert [%Outcome{kind: :pacified, sequence: 4}, %Outcome{kind: :died, sequence: 5}] =
             ducloitre

    assert Enum.map(ducloitre, & &1.payload.engine_actor_id) == [195_054_661, 195_054_661]

    novikov = Enum.filter(outcomes, &(&1.payload.actor_name == "Viktor Novikov"))
    assert [%Outcome{kind: :pacified}, %Outcome{kind: :died}] = novikov
    assert Enum.all?(novikov, & &1.payload.is_target)
  end

  test "an outcome with no open attempt is unattributed, never attached to a neighbour" do
    [playing | rest] = decoded()
    {first_outcome, _} = List.pop_at(rest, 0)
    stopped = List.last(rest)

    # before any attempt
    {instance, notes} = fold([first_outcome])
    assert instance.attempts == []
    assert [%Outcome{sequence: 2}] = instance.unattributed_outcomes
    assert notes == [{:unattributed_outcome, 2}]

    # after the attempt stopped
    {instance, notes} = fold([playing, stopped, first_outcome])
    assert [%Attempt{mission: :stopped, outcomes: []}] = instance.attempts
    assert [%Outcome{sequence: 2}] = instance.unattributed_outcomes
    assert {:unattributed_outcome, 2} in notes

    # a second attempt gets only its own outcomes
    second_playing = %{playing | sequence: 19}
    {instance, _} = fold([playing, stopped, second_playing, %{first_outcome | sequence: 20}])

    assert [
             %Attempt{outcomes: []},
             %Attempt{mission: :playing, outcomes: [%Outcome{sequence: 20}]}
           ] = instance.attempts
  end

  test "outcomes are not deduplicated by BEAM either" do
    [playing | rest] = decoded()
    kill = Enum.find(rest, &(&1.event_type == "actor.died"))
    {instance, notes} = fold([playing, kill, %{kill | sequence: kill.sequence + 1}])
    assert [%Attempt{outcomes: [_, _]}] = instance.attempts
    # only the sequence gap is noted (the fixture's kill is not sequence 2); nothing was collapsed
    assert Enum.all?(notes, &match?({:gap, _, _}, &1))
  end

  # -- summary ----------------------------------------------------------------------------------

  test "summary counts are conservative and state provenance" do
    {instance, []} = fold(decoded())
    [s] = Summary.build(%{@id => instance})
    [attempt] = s.attempts

    assert attempt.outcome_counts.died.total == 10
    assert attempt.outcome_counts.pacified.total == 6
    assert attempt.outcome_counts.died.target == 1 and attempt.outcome_counts.died.non_target == 9
    assert attempt.outcome_counts.pacified.target == 1
    assert attempt.outcome_counts.died.by_actor_type == %{"civilian" => 8, "guard" => 2}
    assert attempt.outcome_counts.died.by_death_context == %{"murder" => 9, "accident" => 1}
    assert attempt.outcome_counts.pacified.by_death_context == %{"murder" => 5, "accident" => 1}
    assert attempt.outcome_counts.died.accidents == 1
    assert length(attempt.outcomes) == 16
    refute Map.has_key?(attempt, :unique_actors)
    refute Map.has_key?(attempt, :score)

    text = Summary.render(%{@id => instance})

    assert text =~
             "actor outcomes (engine telemetry): 10 died (1 target, 9 non-target; 8 civilian, 2 guard; context accident 1, murder 9); 6 pacified (1 target, 5 non-target; 6 civilian; context accident 1, murder 5)"

    assert text =~
             "#4 pacified Jacqueline Ducloitre (civilian, non-target): pacify/murder melee unarmed [Subdue]"

    assert text =~
             "#5 died Jacqueline Ducloitre (civilian, non-target): kill/murder melee unarmed [CoupDeGrace]"

    assert text =~
             "#12 died Kurt Donovan (guard, non-target): kill/accident explosion accident/accident_explosion [Shoot]"

    refute text =~ "killed by"
    refute text =~ "Silent Assassin"
    refute text =~ "score"
  end

  test "summary renders an attempt with no outcomes and unattributed outcomes" do
    [playing | rest] = decoded()
    stopped = List.last(rest)
    kill = Enum.find(rest, &(&1.event_type == "actor.died"))
    {instance, _} = fold([playing, stopped, kill])
    text = Summary.render(%{@id => instance})
    assert text =~ "actor outcomes (engine telemetry): none observed"

    assert text =~
             "died Jacqueline Ducloitre (civilian, non-target): kill/murder melee unarmed [CoupDeGrace]"

    assert text =~ "with no open attempt"
  end
end
