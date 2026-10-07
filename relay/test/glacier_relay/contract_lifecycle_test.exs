defmodule GlacierRelay.ContractLifecycleTest do
  @moduledoc """
  M2 B2: contract.started / contract.ended validation, the BEAM-derived attempt ↔ contract-session
  correlation by stream order, dispositions from contract evidence only, ambiguity and mismatch
  handling, and the summary wording. Uses the 9 envelopes the native pipeline produced in the B2
  standalone wire run from the recorded B0 ContractStart/ContractFailed payloads in the frame
  order B0 and B1 showed (fresh load, restart, exit to menu).
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.{Events, Lifecycle, Summary}
  alias GlacierRelay.Lifecycle.{Attempt, ContractSession}
  alias GlacierRelay.Wire.Envelope

  @lines File.read!("test/b2_probe_envelopes.ndjson") |> String.split("\n", trim: true)
  @id "a5092b81-2103-4ec1-81a3-8103db3db375"
  @session_a "2516109628137904204-c00b2d17-08b1-4949-9f9d-5f68b691f40f"
  @session_b "2516109618691980006-9666b5ad-6a4f-44bb-b5fb-ff86bb3a8d76"
  @paris "assembly:/_PRO/Scenes/Missions/Paris/_Scene_FashionShowHit_01.entity"
  @restart_reason "Contract ended manually: OnRestartLevel"
  @exit_reason "Contract ended manually: User pressed exit to Main menu"

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

  defp env(type, seq, payload) do
    %Envelope{
      protocol_version: 1,
      adapter_instance_id: @id,
      sequence: seq,
      timestamp: "2026-10-07T05:00:#{String.pad_leading(Integer.to_string(seq), 2, "0")}.000Z",
      event_type: type,
      schema_version: 1,
      payload: payload
    }
  end

  defp playing(seq, opts \\ []),
    do:
      env("mission.playing", seq, %{
        scene_resource: @paris,
        scene_type: "mission",
        codename_hint: "Peacock",
        game_session_id: Keyword.get(opts, :session)
      })

  defp stopped(seq, opts),
    do:
      env("mission.stopped", seq, %{
        scene_resource: @paris,
        scene_type: "mission",
        codename_hint: "Peacock",
        game_session_id: Keyword.get(opts, :session)
      })

  defp started(seq, session),
    do:
      env("contract.started", seq, %{
        source: "engine_telemetry",
        engine_event: "ContractStart",
        contract_session_id: session,
        contract_id: "00000000-0000-0000-0000-000000000200",
        location_id: "LOCATION_PARIS",
        contract_type: "mission",
        difficulty_level: 2,
        starting_disguise_repository_id: "874c4c48-0a8b-49e9-883e-49fc5f1fb051",
        is_hitman_suit: true,
        engine_timestamp_s: 0
      })

  defp ended(seq, session, reason, kind),
    do:
      env("contract.ended", seq, %{
        source: "engine_telemetry",
        engine_event: "ContractFailed",
        contract_session_id: session,
        contract_id: "00000000-0000-0000-0000-000000000200",
        reason: reason,
        reason_kind: kind,
        engine_timestamp_s: 100.5
      })

  defp valid_started_map do
    %{
      "protocol_version" => 1,
      "adapter_instance_id" => @id,
      "sequence" => 1,
      "timestamp" => "2026-10-07T05:00:00.000Z",
      "event_type" => "contract.started",
      "schema_version" => 1,
      "payload" => %{
        "source" => "engine_telemetry",
        "engine_event" => "ContractStart",
        "contract_session_id" => @session_a,
        "contract_id" => "00000000-0000-0000-0000-000000000200",
        "location_id" => "LOCATION_PARIS",
        "contract_type" => "mission",
        "difficulty_level" => 2,
        "starting_disguise_repository_id" => "874c4c48-0a8b-49e9-883e-49fc5f1fb051",
        "is_hitman_suit" => true
      }
    }
  end

  defp valid_ended_map do
    %{
      "protocol_version" => 1,
      "adapter_instance_id" => @id,
      "sequence" => 4,
      "timestamp" => "2026-10-07T05:00:04.000Z",
      "event_type" => "contract.ended",
      "schema_version" => 1,
      "payload" => %{
        "source" => "engine_telemetry",
        "engine_event" => "ContractFailed",
        "contract_session_id" => @session_a,
        "contract_id" => "00000000-0000-0000-0000-000000000200",
        "reason" => @restart_reason,
        "reason_kind" => "restart"
      }
    }
  end

  defp decode(map), do: map |> JSON.encode!() |> Envelope.decode()

  defp text(instance), do: Summary.render(%{@id => instance})

  # -- validation ----------------------------------------------------------------------------

  test "the 9 native B2 envelopes decode in the observed order with one shared sequence" do
    envelopes = decoded()
    assert Enum.map(envelopes, & &1.sequence) == Enum.to_list(1..9)

    assert Enum.map(envelopes, & &1.event_type) == [
             "contract.started",
             "mission.playing",
             "actor.died",
             "contract.ended",
             "mission.stopped",
             "mission.playing",
             "contract.started",
             "mission.stopped",
             "contract.ended"
           ]

    assert Enum.all?(envelopes, &(&1.schema_version == 1))
  end

  test "every native payload field is equal to what BEAM validated (no field lost or changed)" do
    for line <- @lines do
      raw = JSON.decode!(line)
      {:ok, env} = Envelope.decode(line)

      for {key, value} <- raw["payload"] do
        assert Map.fetch!(env.payload, String.to_existing_atom(key)) == value,
               "#{env.event_type} ##{env.sequence} field #{key}"
      end
    end
  end

  test "contract.started v1 required fields and types" do
    assert {:ok, %Envelope{payload: p}} = decode(valid_started_map())
    assert p.contract_session_id == @session_a
    assert p.location_id == "LOCATION_PARIS" and p.difficulty_level == 2 and p.is_hitman_suit
    assert p.engine_timestamp_s == nil

    for key <- ~w(source engine_event contract_session_id contract_id location_id contract_type difficulty_level starting_disguise_repository_id is_hitman_suit) do
      map = update_in(valid_started_map(), ["payload"], &Map.delete(&1, key))
      assert {:error, {:missing_field, ^key}} = decode(map), key
    end

    bad = put_in(valid_started_map(), ["payload", "contract_session_id"], "")
    assert {:error, {:invalid_field, "contract_session_id"}} = decode(bad)
    bad = put_in(valid_started_map(), ["payload", "difficulty_level"], 2.0)
    assert {:error, {:invalid_field, "difficulty_level"}} = decode(bad)
    bad = put_in(valid_started_map(), ["payload", "is_hitman_suit"], "yes")
    assert {:error, {:invalid_field, "is_hitman_suit"}} = decode(bad)
    bad = put_in(valid_started_map(), ["schema_version"], 2)
    assert {:error, {:unsupported_schema_version, "contract.started", 2}} = decode(bad)
  end

  test "contract.ended v1: reason verbatim, reason_kind constrained, other accepted" do
    assert {:ok, %Envelope{payload: p}} = decode(valid_ended_map())
    assert p.reason == @restart_reason and p.reason_kind == "restart"

    other = valid_ended_map() |> put_in(["payload", "reason"], "new IOI reason") |> put_in(["payload", "reason_kind"], "other")
    assert {:ok, %Envelope{payload: %{reason: "new IOI reason", reason_kind: "other"}}} = decode(other)

    bad = put_in(valid_ended_map(), ["payload", "reason_kind"], "failed")
    assert {:error, {:invalid_field, "reason_kind"}} = decode(bad)
    bad = put_in(valid_ended_map(), ["payload", "reason"], "")
    assert {:error, {:invalid_field, "reason"}} = decode(bad)
    bad = update_in(valid_ended_map(), ["payload"], &Map.delete(&1, "contract_session_id"))
    assert {:error, {:missing_field, "contract_session_id"}} = decode(bad)

    refute Events.contract_event?("contract.failed")
    assert {:error, {:unknown_event_type, "contract.failed"}} = decode(put_in(valid_ended_map(), ["event_type"], "contract.failed"))
  end

  # -- correlation from the recorded wire run -----------------------------------------------

  test "the B2 wire run: attempt 1 paired by next rise and restarted, attempt 2 by open attempt and exited to menu" do
    {instance, notes} = fold(decoded())

    assert instance.gaps == []
    assert instance.pending_contracts == []
    assert instance.unmatched_contract_ends == []
    assert instance.anomalies == []

    assert [
             %Attempt{
               number: 1,
               mission: :stopped,
               contract_session_id: @session_a,
               contract_paired_by: :next_rise,
               disposition: :restarted,
               outcomes: [%{kind: :died}]
             },
             %Attempt{
               number: 2,
               mission: :stopped,
               contract_session_id: @session_b,
               contract_paired_by: :open_attempt,
               disposition: :exited_to_menu,
               outcomes: []
             }
           ] = instance.attempts

    # Both sessions remain first-class evidence with their full payloads, paired or not.
    assert [
             %ContractSession{
               contract_session_id: @session_a,
               attempt_number: 1,
               paired_by: :next_rise,
               ended_relative: :during,
               started: %{sequence: 1},
               ended: %{sequence: 4},
               started_payload: %{location_id: "LOCATION_PARIS", difficulty_level: 2},
               ended_payload: %{reason: @restart_reason, reason_kind: "restart"}
             },
             %ContractSession{
               contract_session_id: @session_b,
               attempt_number: 2,
               paired_by: :open_attempt,
               ended_relative: :after_stop,
               started: %{sequence: 7},
               ended: %{sequence: 9},
               ended_payload: %{reason_kind: "exit_to_menu"}
             }
           ] = instance.contract_sessions

    assert {:attempt_disposition, 1, :restarted, :during} in notes
    assert {:attempt_disposition, 2, :exited_to_menu, :after_stop} in notes
    refute Enum.any?(notes, &match?({:unattributed_outcome, _}, &1))
  end

  test "the summary says what Glacier said and what BEAM derived, and never 'failed'" do
    {instance, _} = fold(decoded())
    t = text(instance)

    assert t =~ "contract (engine telemetry): session #{@session_a}, LOCATION_PARIS, mission, difficulty 2; started #1"
    assert t =~ ~s|ended #4 by restart ("#{@restart_reason}")|
    assert t =~ "disposition (BEAM-derived, session paired by next_rise): restarted"
    assert t =~ ~s|ended #9 by exit to menu ("#{@exit_reason}")|
    assert t =~ "disposition (BEAM-derived, session paired by open_attempt): exited to menu"
    assert t =~ "on the contract clock"
    refute t =~ ~r/failed/i
    refute t =~ ~r/complet/i
    refute t =~ "anomaly"
  end

  # -- scenarios -----------------------------------------------------------------------------

  test "fresh load: contract.started then mission.playing pairs by next rise with the id check passing" do
    {instance, notes} = fold([started(1, @session_a), playing(2, session: @session_a)])
    assert [%Attempt{contract_session_id: @session_a, contract_paired_by: :next_rise, disposition: :not_observed}] = instance.attempts
    assert instance.pending_contracts == [] and instance.anomalies == [] and notes == []
    assert text(instance) =~ "disposition (BEAM-derived, session paired by next_rise): not observed; contract end not seen"
  end

  test "restart, same-frame variant: ended(A) during attempt 1, stop, rise, started(B) after the rise" do
    events = [
      started(1, @session_a),
      playing(2, session: @session_a),
      ended(3, @session_a, @restart_reason, "restart"),
      stopped(4, session: @session_b),
      playing(5, session: @session_b),
      started(6, @session_b)
    ]

    {instance, _} = fold(events)
    assert [%Attempt{disposition: :restarted, contract_session_id: @session_a}, %Attempt{disposition: :not_observed, contract_session_id: @session_b, contract_paired_by: :open_attempt}] = instance.attempts
    assert [%ContractSession{ended_relative: :during}, %ContractSession{ended: nil}] = instance.contract_sessions
    assert instance.anomalies == []
  end

  test "restart, early-start variant: started(B) arrives while attempt 1 (already paired) is still open and waits for the rise" do
    events = [
      started(1, @session_a),
      playing(2, session: @session_a),
      ended(3, @session_a, @restart_reason, "restart"),
      started(4, @session_b),
      stopped(5, session: @session_b),
      playing(6, session: @session_b)
    ]

    {instance, _} = fold(events)
    assert [%Attempt{number: 1, contract_session_id: @session_a, disposition: :restarted}, %Attempt{number: 2, contract_session_id: @session_b, contract_paired_by: :next_rise}] = instance.attempts
    assert instance.anomalies == [] and instance.pending_contracts == []
  end

  test "exit to menu: the stopped attempt still receives the later contract end and becomes exited_to_menu" do
    {instance, notes} = fold([started(1, @session_a), playing(2, session: @session_a), stopped(3, session: @session_a), ended(4, @session_a, @exit_reason, "exit_to_menu")])
    assert [%Attempt{mission: :stopped, disposition: :exited_to_menu}] = instance.attempts
    assert [%ContractSession{ended_relative: :after_stop}] = instance.contract_sessions
    assert {:attempt_disposition, 1, :exited_to_menu, :after_stop} in notes
    assert text(instance) =~ "exited to menu"
  end

  test "unknown reason: valid event, reason_kind other, disposition {:ended, reason}, string preserved" do
    {instance, _} = fold([started(1, @session_a), playing(2, session: @session_a), ended(3, @session_a, "Contract ended: brand new IOI reason", "other")])
    assert [%Attempt{disposition: {:ended, "Contract ended: brand new IOI reason"}}] = instance.attempts
    t = text(instance)
    assert t =~ ~s|an unmapped reason ("Contract ended: brand new IOI reason")|
    assert t =~ ~s|disposition (BEAM-derived, session paired by next_rise): ended, reason "Contract ended: brand new IOI reason"|
    refute t =~ ~r/failed/i
  end

  test "unmatched start: a contract session with no mission rise stays pending and unpaired" do
    {instance, notes} = fold([started(1, @session_a)])
    assert instance.attempts == []
    assert instance.pending_contracts == [@session_a]
    assert [%ContractSession{attempt_number: nil, paired_by: nil}] = instance.contract_sessions
    assert notes == []
    assert text(instance) =~ "contract session #{@session_a} (LOCATION_PARIS, mission, difficulty 2; started #1 @0s) not correlated to any attempt; end not observed"
  end

  test "multiple pending starts: no arbitrary pairing; candidates recorded, anomaly kept" do
    {instance, notes} = fold([started(1, @session_a), started(2, @session_b), playing(3, session: @session_b)])
    assert {:contract_pending_multiple, [@session_a, @session_b]} in notes
    assert {:contract_pairing_ambiguous, 1, [@session_a, @session_b]} in notes
    assert [%Attempt{contract_session_id: nil, contract_paired_by: nil, contract_candidates: [@session_a, @session_b], disposition: :not_observed}] = instance.attempts
    assert Enum.all?(instance.contract_sessions, &is_nil(&1.attempt_number))
    assert instance.pending_contracts == []
    assert [%{kind: :contract_pairing_ambiguous, attempt: 1}] = instance.anomalies

    # A later end for one of them closes that session (Glacier identity) but derives no
    # disposition, because the session is paired with no attempt.
    {instance, notes} = fold([ended(4, @session_b, @exit_reason, "exit_to_menu")], instance)
    assert notes == []
    assert [%Attempt{disposition: :not_observed}] = instance.attempts
    assert Enum.find(instance.contract_sessions, &(&1.contract_session_id == @session_b)).ended.sequence == 4
    t = text(instance)
    assert t =~ "2 sessions started before this rise; none correlated (ambiguous)"
    assert t =~ "anomaly: attempt 1 had 2 candidate contract sessions; none paired"
    assert t =~ "disposition (BEAM-derived): not observed"
  end

  test "unmatched end: a contract.ended with no open session of that id is kept, not attached by adjacency" do
    {instance, notes} = fold([playing(1, session: @session_a), stopped(2, session: @session_a), ended(3, @session_b, @exit_reason, "exit_to_menu")])
    assert [%Attempt{contract_session_id: nil, disposition: :not_observed}] = instance.attempts
    assert [%{observation: %{sequence: 3}, payload: %{contract_session_id: @session_b}}] = instance.unmatched_contract_ends
    assert {:unmatched_contract_end, 3, @session_b} in notes
    t = text(instance)
    assert t =~ "contract.ended #3 for session #{@session_b} (exit to menu"
    assert t =~ "with no open contract session"
    assert t =~ "contract (engine telemetry): not observed"
  end

  test "id mismatch: the rise's game_session_id differs from the paired session; pairing stands, anomaly visible, nothing rewritten" do
    {instance, _} = fold([started(1, @session_a), playing(2, session: @session_b)])
    assert [%Attempt{contract_session_id: @session_a, contract_paired_by: :next_rise, playing: %{game_session_id: @session_b}}] = instance.attempts
    assert [%{kind: :contract_session_id_mismatch, attempt: 1, rise_game_session_id: @session_b, contract_session_id: @session_a}] = instance.anomalies
    assert [%ContractSession{contract_session_id: @session_a, attempt_number: 1}] = instance.contract_sessions
    assert text(instance) =~ "anomaly: attempt 1 rose with game_session_id #{@session_b} but was paired (by next_rise) with contract session #{@session_a}; pairing kept, both ids preserved"
  end

  test "a rise without a registry id performs no check and records no anomaly" do
    {instance, _} = fold([started(1, @session_a), playing(2)])
    assert [%Attempt{contract_session_id: @session_a}] = instance.attempts
    assert instance.anomalies == []
  end

  test "TCP close fabricates no contract end and no disposition" do
    {instance, _} = fold([started(1, @session_a), playing(2, session: @session_a)])
    instance = Lifecycle.connection_closed(Lifecycle.connection_identified(instance, "p", nil, nil), ~U[2026-10-07 05:01:00Z], :peer_closed)
    assert [%Attempt{mission: :playing, disposition: :not_observed, interruptions: [_]}] = instance.attempts
    assert [%ContractSession{ended: nil}] = instance.contract_sessions
    t = text(instance)
    assert t =~ "last known playing"
    assert t =~ "not observed; contract end not seen"
  end

  test "direct process exit: the open attempt keeps disposition not_observed when no contract end was seen" do
    {instance, _} = fold([started(1, @session_a), playing(2, session: @session_a), env("actor.died", 3, hd(tl(tl(decoded()))).payload)])
    assert [%Attempt{mission: :playing, disposition: :not_observed, outcomes: [_]}] = instance.attempts
    refute text(instance) =~ ~r/restart|exit/
  end

  test "a second contract.started for the same id is recorded as evidence and noted" do
    {instance, notes} = fold([started(1, @session_a), playing(2, session: @session_a), started(3, @session_a)])
    assert {:contract_started_again, @session_a, 3} in notes
    assert length(instance.contract_sessions) == 2
    # The open attempt already has its session, so the duplicate waits rather than re-pairing.
    assert instance.pending_contracts == [@session_a]
    assert [%Attempt{contract_session_id: @session_a, contract_paired_by: :next_rise}] = instance.attempts
  end

  test "an end matching several open sessions with one id is ambiguous: unmatched plus anomaly" do
    {instance, notes} = fold([started(1, @session_a), started(2, @session_a), ended(3, @session_a, @restart_reason, "restart")])
    assert {:contract_end_ambiguous, 3, @session_a} in notes
    assert [%{observation: %{sequence: 3}}] = instance.unmatched_contract_ends
    assert [%{kind: :contract_end_ambiguous, open_sessions: [1, 2]}] = instance.anomalies
    assert Enum.all?(instance.contract_sessions, &is_nil(&1.ended))
  end

  test "contract, mission and actor events share one Relay sequence and the attempt counts only its outcomes" do
    {instance, _} = fold(decoded())
    assert instance.received == 9 and instance.last_sequence == 9
    summary = Summary.build(%{@id => instance}) |> hd()
    assert [%{outcome_counts: %{died: %{total: 1}}, contract: %{started_sequence: 1, ended_sequence: 4, reason_kind: "restart"}}, %{contract: %{started_sequence: 7, ended_sequence: 9}}] = summary.attempts
    assert length(summary.contract_sessions) == 2
    assert summary.unpaired_contract_sessions == [] and summary.anomalies == []
  end
end
