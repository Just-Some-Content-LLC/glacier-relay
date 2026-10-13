defmodule GlacierRelay.Statistics do
  @moduledoc """
  Evidence-derived statistics over a replay (M4-C). A pure function from a
  `GlacierRelay.Recording.Replay` result — the folded `Lifecycle.Instance` values, the summary
  data the live session also builds, and the completeness account — to a structured, deterministic
  summary of **what was observed**. Nothing here reads the game, subscribes to the session, folds
  evidence again, reinterprets a native payload or stores anything.

  Every number is an occurrence count over the replayed evidence and says what it counted: actor
  outcomes are occurrences, never distinct actors; a disguise standing is the derived reading the
  B7 report already makes; a player-state value is the engine's last statement, never a current
  state; a duration exists only when both the rise and the fall were observed; engine times are
  compared only inside one established contract-session clock domain. Nothing is inferred about
  victory, failure, rating, target survival, inventory or anything the stream did not carry.

  The statistics inherit the evidence classification of their recording (`evidence`): the
  authoritative, unverified, ambiguous or legacy class, the recorder gaps, the unexplained missing
  records, the Relay sequence gaps, the transport and receipt-time availability, and the native
  drops (unknown unless reconciled outside the recording). The counts are therefore labelled as
  observed counts, with the reasons they must not be read as exhaustive totals
  (`evidence.observed_only_reasons`, never empty), and never as evidence that something missing
  did not happen. Nothing is combined into a single confidence score.

  Output schema: `glacier-relay.statistics/1`, versioned independently of the Relay wire schema
  (`schema` on the result). JSON (`GlacierRelay.Statistics.JSON`) and text
  (`GlacierRelay.Statistics.Text`) are derived artifacts of the structured result; the recording
  files are the evidence and are never written.
  """

  alias GlacierRelay.AttemptHistory
  alias GlacierRelay.Lifecycle.{Attempt, Instance}
  alias GlacierRelay.Recording.{Completeness, Replay}

  @schema "glacier-relay.statistics/1"

  @event_types ~w(mission.playing mission.stopped actor.died actor.pacified contract.started
    contract.ended disguise.equipped disguise.compromised disguise.compromise_cleared
    item.picked_up item.thrown item.removed_from_inventory objective.completed
    player.trespassing player.illegal_weapon)

  @families [:lifecycle, :contract, :actor, :disguise, :item, :objective, :player_state]

  @counting_rules %{
    occurrences:
      "each occurrence counted once as the engine recorded it; never a distinct-actor, distinct-item or state count",
    duration:
      "Relay clock (native publication timestamps), rise to fall; only when both were observed; a stop not observed leaves the attempt unbounded",
    engine_times:
      "engine occurrence times compared only between occurrences carrying the attempt's paired contract-session id (one clock domain); occurrences in another domain are counted, not compared",
    attribution:
      "the Lifecycle attribution fixed at receipt (stream order; a contradicting session vetoes an objective); unattributed occurrences are kept apart and never attached by proximity",
    standing:
      "the B7 report's derived readings (disguise standing, player-state last observation); last observed, never current state",
    not_inferred:
      "victory, failure, rating, target survival, inventory contents, current player state and anything the stream did not carry"
  }

  defstruct schema: @schema,
            recording: %{},
            evidence: %{},
            instances: %{},
            attempts: %{},
            envelopes: %{},
            actor_outcomes: %{},
            contracts: %{},
            disguise: %{},
            items: %{},
            objectives: %{},
            player_state: %{},
            transport: %{},
            anomalies: %{},
            per_attempt: [],
            unattributed: [],
            rules: @counting_rules

  @type t :: %__MODULE__{}

  @doc "The output schema identifier (versioned independently of the Relay wire schema)."
  def schema, do: @schema

  @doc "The supported event types, in vocabulary order."
  def event_types, do: @event_types

  @doc "The event families."
  def families, do: @families

  @doc "Statistics of one replay result (a recording or a legacy envelope-only import)."
  @spec of_replay(Replay.t()) :: t()
  def of_replay(%Replay{} = replay) do
    instances = replay.instances
    summary = replay.summary
    per_attempt = Enum.flat_map(summary, &attempt_rows(&1, instances))
    unattributed = Enum.map(summary, &unattributed_row(&1, instances))

    %__MODULE__{
      recording: recording(replay),
      evidence: evidence(replay, per_attempt),
      instances: %{
        observed: map_size(instances),
        ids: instances |> Map.keys() |> Enum.sort(),
        observation: frequencies(summary, & &1.observation)
      },
      attempts: attempts(summary, per_attempt),
      envelopes: envelopes(instances, replay),
      actor_outcomes: actor_outcomes(per_attempt, unattributed),
      contracts: contracts(summary),
      disguise: disguise(per_attempt, unattributed),
      items: items(per_attempt, unattributed),
      objectives: objectives(per_attempt, unattributed),
      player_state: player_state(per_attempt, unattributed),
      transport: transport(replay),
      anomalies: anomalies(summary),
      per_attempt: per_attempt,
      unattributed: unattributed
    }
  end

  # -- recording identity ---------------------------------------------------------------------

  defp recording(%Replay{source: :legacy} = r) do
    %{
      id: r.recording_id,
      source: :legacy,
      dir: nil,
      format: :legacy,
      first_record_no: r.first_record_no,
      boundary: r.boundary,
      node: :not_recorded,
      app_version: :not_recorded,
      schema_versions: schema_versions_from_instances(r.instances)
    }
  end

  defp recording(%Replay{reader: reader} = r) do
    header =
      case reader.segments do
        [%{header: h} | _] when is_map(h) -> h
        _ -> %{}
      end

    %{
      id: r.recording_id,
      source: :recording,
      dir: r.dir,
      format: r.completeness.format,
      first_record_no: r.first_record_no,
      boundary: r.boundary,
      node: Map.get(header, "node", :not_recorded),
      app_version: get_in(header, ["app", "vsn"]) || :not_recorded,
      schema_versions:
        reader.records
        |> Enum.filter(&(&1.kind == "envelope"))
        |> Enum.map(&get_in(&1.map, ["envelope", "schema_version"]))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp schema_versions_from_instances(instances) do
    instances
    |> Map.values()
    |> Enum.map(& &1.last_event)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.schema_version)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # -- evidence (inherited from the completeness account) -------------------------------------

  defp evidence(%Replay{completeness: %Completeness{} = c} = r, per_attempt) do
    sequence_gaps =
      c.relay_sequence_gaps
      |> Enum.map(fn {id, gaps} ->
        %{
          instance: id,
          gaps: Enum.map(gaps, fn {e, g} -> %{expected: e, got: g, missing: g - e} end)
        }
      end)
      |> Enum.sort_by(& &1.instance)

    intact = Enum.count(per_attempt, &(&1.history == :intact))
    broken = length(per_attempt) - intact

    reasons =
      [
        if(c.source == :legacy,
          do: "legacy envelope-only input: transport evidence and receipt times were not recorded"
        ),
        if(c.source == :recording and not c.recorder_authoritative?,
          do:
            "the recording is not recorder-authoritative (#{c.finalization}, evidence #{c.evidence})"
        ),
        if(c.records.unverified_used > 0,
          do: "#{c.records.unverified_used} record(s) come from unverified evidence"
        ),
        if(c.records.ambiguous != [],
          do: "ambiguous record number(s) withheld: #{inspect(c.records.ambiguous)}"
        ),
        if(c.recorder_gaps != [],
          do:
            "known recorder gap(s): " <>
              Enum.map_join(c.recorder_gaps, "; ", &"r=#{&1.from}..#{&1.to} (#{&1.cause})")
        ),
        if(c.open_ended_gaps != [],
          do:
            "open-ended recorder gap(s) from " <>
              Enum.map_join(c.open_ended_gaps, ", ", &"r=#{&1.from} (#{&1.cause})")
        ),
        if(c.unexplained_missing != [],
          do:
            "unexplained missing record(s): " <>
              Enum.map_join(c.unexplained_missing, ", ", fn {a, b} -> "#{a}..#{b}" end)
        ),
        if(sequence_gaps != [],
          do:
            "Relay sequence gap(s) (delivery or native loss): " <>
              Enum.map_join(sequence_gaps, "; ", fn g ->
                "#{g.instance}: " <> Enum.map_join(g.gaps, ", ", &"#{&1.expected}→#{&1.got}")
              end)
        ),
        if(r.rejected != [],
          do:
            "#{length(r.rejected)} recorded envelope(s) rejected by the current validator and not counted"
        ),
        if(broken > 0,
          do:
            "#{broken} attempt(s) with a broken observation history (gap, interruption or supersession)"
        ),
        if(Enum.any?(per_attempt, &(&1.mission != :stopped)),
          do:
            "#{Enum.count(per_attempt, &(&1.mission != :stopped))} attempt(s) whose stop was not observed"
        ),
        "native-side drops #{c.native_drops}: a recording cannot show them to be zero"
      ]
      |> Enum.reject(&is_nil/1)

    %{
      source: c.source,
      classification: c.evidence,
      recorder_authoritative?: c.recorder_authoritative?,
      finalization: c.finalization,
      format: c.format,
      records: %{
        first: c.records.first,
        last: c.records.last,
        resolved: c.records.resolved,
        verified: c.records.verified,
        durable_by_trusted_boundary: c.records.durable,
        unverified_used: c.records.unverified_used,
        duplicates: c.records.duplicates,
        conflicts: c.records.conflicts,
        ambiguous: c.records.ambiguous
      },
      segments: c.segments,
      boundaries: %{
        trusted: length(c.boundaries.trusted),
        untrusted: length(c.boundaries.untrusted),
        unstated: length(c.boundaries.unstated)
      },
      recorder_gaps: c.recorder_gaps,
      open_ended_gaps: c.open_ended_gaps,
      unexplained_missing: Enum.map(c.unexplained_missing, fn {a, b} -> %{from: a, to: b} end),
      corrupt_lines: c.corrupt_lines,
      malformed_records: c.malformed_records,
      relay_sequence_gaps: sequence_gaps,
      rejected_envelopes: length(r.rejected),
      reader_issues: length(c.replay_issues),
      transport: c.transport,
      receipt_times: c.receipt_times,
      native_drops: c.native_drops,
      close_reasons: %{exact: c.close_reasons.exact, qualified: length(c.close_reasons.qualified)},
      attempt_history: %{intact: intact, broken: broken},
      counts_are: :observed_occurrences,
      observed_only_reasons: reasons,
      limitations: c.limitations
    }
  end

  # -- attempts ---------------------------------------------------------------------------------

  defp attempts(summary, per_attempt) do
    unmatched_stops = summary |> Enum.map(&length(&1.unmatched_stops)) |> Enum.sum()
    bounded = Enum.filter(per_attempt, &is_integer(&1.duration_ms))

    %{
      observed: length(per_attempt),
      starts_observed: length(per_attempt),
      stops_observed: Enum.count(per_attempt, &(&1.mission == :stopped)) + unmatched_stops,
      stops_with_no_open_attempt: unmatched_stops,
      stopped: Enum.count(per_attempt, &(&1.mission == :stopped)),
      stop_not_observed: Enum.count(per_attempt, &(&1.mission != :stopped)),
      last_known_playing: Enum.count(per_attempt, &(&1.mission == :playing)),
      superseded: Enum.count(per_attempt, &(&1.mission == :superseded)),
      by_scene_resource: frequencies(per_attempt, & &1.scene_resource),
      by_disposition: frequencies(per_attempt, & &1.disposition.value),
      history: %{
        intact: Enum.count(per_attempt, &(&1.history == :intact)),
        broken: Enum.count(per_attempt, &(&1.history != :intact))
      },
      durations: %{
        rule: @counting_rules.duration,
        bounded: length(bounded),
        unbounded: length(per_attempt) - length(bounded),
        total_ms: bounded |> Enum.map(& &1.duration_ms) |> Enum.sum(),
        min_ms: bounded |> Enum.map(& &1.duration_ms) |> Enum.min(fn -> nil end),
        max_ms: bounded |> Enum.map(& &1.duration_ms) |> Enum.max(fn -> nil end)
      }
    }
  end

  # -- envelopes by event type (every folded envelope accounted for once) ---------------------

  defp envelopes(instances, replay) do
    per_instance =
      instances
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map(fn {id, inst} ->
        counts = envelope_counts(inst)
        total = counts |> Map.values() |> Enum.sum()

        %{
          instance: id,
          received: inst.received,
          accounted: total,
          reconciled?: total == inst.received,
          last_sequence: inst.last_sequence,
          by_event_type: counts
        }
      end)

    totals =
      Enum.reduce(per_instance, Map.new(@event_types, &{&1, 0}), fn row, acc ->
        Map.merge(acc, row.by_event_type, fn _k, a, b -> a + b end)
      end)

    %{
      received: per_instance |> Enum.map(& &1.received) |> Enum.sum(),
      accounted: totals |> Map.values() |> Enum.sum(),
      reconciled?: Enum.all?(per_instance, & &1.reconciled?),
      rejected_by_validator: length(replay.rejected),
      by_event_type: totals,
      by_family: for(f <- @families, into: %{}, do: {f, family_total(totals, f)}),
      per_instance: per_instance
    }
  end

  defp envelope_counts(%Instance{} = inst) do
    attempts = inst.attempts

    sum = fn fun -> attempts |> Enum.map(fun) |> Enum.sum() end
    outcomes = fn kind -> sum.(&Enum.count(&1.outcomes, fn o -> o.kind == kind end)) end
    unatt_outcomes = fn kind -> Enum.count(inst.unattributed_outcomes, &(&1.kind == kind)) end
    disg = fn type -> sum.(&Enum.count(&1.disguise_events, fn o -> o.type == type end)) end
    unatt_disg = fn type -> Enum.count(inst.unattributed_disguise_events, &(&1.type == type)) end
    item = fn type -> sum.(&Enum.count(&1.item_events, fn o -> o.type == type end)) end
    unatt_item = fn type -> Enum.count(inst.unattributed_item_events, &(&1.type == type)) end
    ps = fn subj -> sum.(&Enum.count(&1.player_state_events, fn o -> o.subject == subj end)) end

    unatt_ps = fn subj ->
      Enum.count(inst.unattributed_player_state_events, &(&1.subject == subj))
    end

    %{
      "mission.playing" => length(attempts),
      "mission.stopped" =>
        Enum.count(attempts, &(&1.stopped != nil)) + length(inst.unmatched_stops),
      "actor.died" => outcomes.(:died) + unatt_outcomes.(:died),
      "actor.pacified" => outcomes.(:pacified) + unatt_outcomes.(:pacified),
      "contract.started" => length(inst.contract_sessions),
      "contract.ended" =>
        Enum.count(inst.contract_sessions, &(&1.ended != nil)) +
          length(inst.unmatched_contract_ends),
      "disguise.equipped" => disg.(:equipped) + unatt_disg.(:equipped),
      "disguise.compromised" => disg.(:compromised) + unatt_disg.(:compromised),
      "disguise.compromise_cleared" =>
        disg.(:compromise_cleared) + unatt_disg.(:compromise_cleared),
      "item.picked_up" => item.(:picked_up) + unatt_item.(:picked_up),
      "item.thrown" => item.(:thrown) + unatt_item.(:thrown),
      "item.removed_from_inventory" =>
        item.(:removed_from_inventory) + unatt_item.(:removed_from_inventory),
      "objective.completed" =>
        sum.(&length(&1.objective_events)) + length(inst.unattributed_objective_events),
      "player.trespassing" => ps.(:trespassing) + unatt_ps.(:trespassing),
      "player.illegal_weapon" => ps.(:illegal_weapon) + unatt_ps.(:illegal_weapon)
    }
  end

  @doc "The family of a supported event type."
  def family("mission." <> _), do: :lifecycle
  def family("contract." <> _), do: :contract
  def family("actor." <> _), do: :actor
  def family("disguise." <> _), do: :disguise
  def family("item." <> _), do: :item
  def family("objective." <> _), do: :objective
  def family("player." <> _), do: :player_state

  defp family_total(by_type, family) do
    by_type
    |> Enum.filter(fn {t, _} -> family(t) == family end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.sum()
  end

  # -- per attempt ------------------------------------------------------------------------------

  defp attempt_rows(s, instances) do
    instance = Map.fetch!(instances, s.adapter_instance_id)

    Enum.map(s.attempts, fn a ->
      attempt = Enum.at(instance.attempts, a.number - 1)
      history = AttemptHistory.history(attempt, instance.gaps)

      %{
        instance: s.adapter_instance_id,
        number: a.number,
        scene_resource: a.scene_resource,
        scene_type: a.scene_type,
        codename_hint: a.codename_hint,
        mission: a.mission,
        start: %{sequence: a.playing_sequence, relay_at: a.playing_at, tag: :engine},
        stop: stop(a),
        duration_ms: a.duration_ms,
        duration: duration(a),
        contract: contract(a),
        disposition: disposition(a.disposition),
        engine_times: engine_times(a, attempt),
        history: history_view(history),
        interruptions: length(a.interruptions),
        gaps_in_attempt: length(AttemptHistory.gaps_in_attempt(instance.gaps, attempt)),
        superseded_by: a.superseded_by,
        actor_outcomes: attempt_outcomes(a),
        disguise: attempt_disguise(a),
        items: attempt_items(a),
        objectives: attempt_objectives(a),
        player_state: attempt_player_state(a),
        families: family_counts(a)
      }
    end)
  end

  defp stop(%{mission: :stopped} = a),
    do: %{observed: true, sequence: a.stopped_sequence, relay_at: a.stopped_at, tag: :engine}

  defp stop(%{mission: :playing}),
    do: %{observed: false, reason: :last_known_playing, tag: :not_observed}

  defp stop(%{mission: :superseded} = a),
    do: %{observed: false, reason: :superseded, by: a.superseded_by, tag: :not_observed}

  defp duration(%{duration_ms: ms}) when is_integer(ms),
    do: %{bounded: true, ms: ms, clock: :relay, rule: @counting_rules.duration}

  defp duration(%{mission: m}),
    do: %{
      bounded: false,
      reason: if(m == :superseded, do: :superseded, else: :stop_not_observed),
      rule: @counting_rules.duration
    }

  defp contract(%{contract: nil, contract_candidates: []}), do: %{status: :not_observed}

  defp contract(%{contract: nil, contract_candidates: c}),
    do: %{status: :ambiguous, candidates: c}

  defp contract(%{contract: c} = a) do
    %{
      status: :paired,
      paired_by: a.contract_paired_by,
      session_id: c.contract_session_id,
      contract_id: c.contract_id,
      location_id: c.location_id,
      contract_type: c.contract_type,
      difficulty_level: c.difficulty_level,
      started_sequence: c.started_sequence,
      ended_sequence: c.ended_sequence,
      ended_relative: c.ended_relative,
      reason_kind: c.reason_kind,
      correlation: :derived
    }
  end

  defp disposition(:not_observed), do: %{value: :not_observed, tag: :not_observed}
  defp disposition({:ended, reason}), do: %{value: :ended, reason: reason, tag: :derived}
  defp disposition(other), do: %{value: other, tag: :derived}

  # Engine times: only occurrences carrying the attempt's paired session id form the clock domain.
  defp engine_times(a, %Attempt{} = attempt) do
    domain = a.contract_session_id

    timed =
      Enum.map(
        attempt.outcomes,
        &{&1.payload[:contract_session_id], &1.payload[:engine_timestamp_s]}
      ) ++
        Enum.map(
          attempt.disguise_events,
          &{&1.payload[:contract_session_id], &1.payload[:engine_timestamp_s]}
        ) ++
        Enum.map(
          attempt.item_events,
          &{&1.payload[:contract_session_id], &1.payload[:engine_timestamp_s]}
        ) ++
        Enum.map(
          attempt.objective_events,
          &{&1.payload[:contract_session_id], &1.payload[:engine_timestamp_s]}
        ) ++
        Enum.map(
          attempt.player_state_events,
          &{&1.payload[:contract_session_id], &1.payload[:engine_timestamp_s]}
        ) ++
        contract_times(a)

    timed = Enum.reject(timed, fn {_s, t} -> is_nil(t) end)

    case domain do
      nil ->
        %{
          domain: :none,
          occurrences_timed: length(timed),
          occurrences_in_domain: 0,
          occurrences_outside_domain: length(timed),
          rule: @counting_rules.engine_times
        }

      session ->
        inside = for {^session, t} <- timed, do: t
        outside = Enum.count(timed, fn {s, _} -> s != session end)
        first = Enum.min(inside, fn -> nil end)
        last = Enum.max(inside, fn -> nil end)
        c = a.contract

        %{
          domain: session,
          occurrences_timed: length(timed),
          occurrences_in_domain: length(inside),
          occurrences_outside_domain: outside,
          first_s: first,
          last_s: last,
          observed_span_s: if(first != nil, do: last - first),
          contract_span_s:
            if(c && c.started_engine_timestamp_s != nil && c.ended_engine_timestamp_s != nil,
              do: c.ended_engine_timestamp_s - c.started_engine_timestamp_s
            ),
          rule: @counting_rules.engine_times
        }
    end
  end

  defp contract_times(%{contract: nil}), do: []

  defp contract_times(%{contract: c}),
    do: [
      {c.contract_session_id, c.started_engine_timestamp_s},
      {c.contract_session_id, c.ended_engine_timestamp_s}
    ]

  defp history_view(:complete), do: :intact
  defp history_view({:incomplete, reasons}), do: %{broken: Enum.map(reasons, &history_reason/1)}

  defp history_reason({:gap, e, g}), do: %{kind: :gap, expected: e, got: g}

  defp history_reason({:interruption, at, reason}),
    do: %{kind: :interruption, at: at, reason: inspect(reason)}

  defp history_reason({:superseded, by, at}), do: %{kind: :superseded, by: by, at_sequence: at}

  defp attempt_outcomes(a) do
    outcomes = a.outcomes

    %{
      occurrences: length(outcomes),
      died: a.outcome_counts.died.total,
      pacified: a.outcome_counts.pacified.total,
      target: %{died: a.outcome_counts.died.target, pacified: a.outcome_counts.pacified.target},
      non_target: %{
        died: a.outcome_counts.died.non_target,
        pacified: a.outcome_counts.pacified.non_target
      },
      accidents: a.outcome_counts.died.accidents + a.outcome_counts.pacified.accidents,
      by_actor_type: frequencies(outcomes, & &1.actor_type),
      by_death_type: frequencies(outcomes, & &1.death_type),
      by_death_context: frequencies(outcomes, & &1.death_context),
      by_kill_class: frequencies(outcomes, & &1.kill_class),
      by_method_broad: frequencies(outcomes, & &1.method_broad),
      by_method_strict: frequencies(outcomes, &(&1.method_strict || "")),
      with_item: Enum.count(outcomes, &(&1.item_repository_id != nil)),
      display_groups:
        outcomes |> Enum.map(&{&1.actor_name, &1.repository_id}) |> Enum.uniq() |> length(),
      note: "occurrence counts; display groups share a name and definition id and are not actors"
    }
  end

  defp attempt_disguise(a) do
    d = a.disguise

    %{
      occurrences: length(a.disguise_events),
      equipped_initial:
        Enum.count(a.disguise_events, &(&1.type == :equipped and &1.kind == :initial)),
      equipped_change:
        Enum.count(a.disguise_events, &(&1.type == :equipped and &1.kind == :change)),
      compromised: Enum.count(a.disguise_events, &(&1.type == :compromised)),
      compromise_cleared: Enum.count(a.disguise_events, &(&1.type == :compromise_cleared)),
      changes: d.changes,
      definitions_used: length(d.used),
      compromise_episodes: length(d.compromise_episodes),
      worn: if(d.worn == :not_observed, do: :not_observed, else: d.worn.repository_id),
      worn_standing: d.worn_standing,
      standing_reason: d.standing_reason,
      anomalies: length(d.anomalies),
      tag: :derived
    }
  end

  defp attempt_items(a) do
    i = a.items

    %{
      occurrences: i.occurrences,
      picked_up: i.picked_up,
      thrown: i.thrown,
      removed_from_inventory: i.removed_from_inventory,
      definitions_used: length(i.definitions_used),
      note: "direct occurrence counts; nothing paired, no inventory"
    }
  end

  defp attempt_objectives(a) do
    o = a.objectives

    %{
      occurrences: o.occurrences,
      distinct_objective_ids: length(o.objective_ids),
      conflicts: o.by_objective |> Enum.map(&length(&1.conflicts)) |> Enum.sum(),
      by_basis: frequencies(a.objective_events, & &1.attribution.basis),
      note: "occurrences reported done; says nothing about how the mission ended"
    }
  end

  defp attempt_player_state(a) do
    p = a.player_state

    %{
      occurrences: p.occurrences,
      trespassing: subject(p.trespassing),
      illegal_weapon: subject(p.illegal_weapon),
      tag: :last_observed
    }
  end

  defp subject(s) do
    %{
      occurrences: s.occurrences,
      observed_value_changes: s.observed_value_changes,
      standing: s.standing,
      last:
        if(s.last == :not_observed,
          do: :not_observed,
          else: %{value: s.last.value, sequence: s.last.sequence}
        ),
      notes: length(s.notes)
    }
  end

  defp family_counts(a) do
    %{
      lifecycle: 1 + if(a.mission == :stopped, do: 1, else: 0),
      contract: contract_count(a.contract),
      actor: length(a.outcomes),
      disguise: length(a.disguise_events),
      item: length(a.item_events),
      objective: length(a.objective_events),
      player_state: length(a.player_state_events)
    }
  end

  defp contract_count(nil), do: 0
  defp contract_count(c), do: 1 + if(c.ended_sequence, do: 1, else: 0)

  # -- unattributed, per instance -----------------------------------------------------------------

  defp unattributed_row(s, instances) do
    instance = Map.fetch!(instances, s.adapter_instance_id)

    %{
      instance: s.adapter_instance_id,
      actor_outcomes: %{
        died: Enum.count(s.unattributed_outcomes, &(&1.kind == :died)),
        pacified: Enum.count(s.unattributed_outcomes, &(&1.kind == :pacified))
      },
      disguise: length(s.unattributed_disguise_events),
      items: length(s.unattributed_item_events),
      objectives: %{
        total: length(s.unattributed_objective_events),
        by_basis: frequencies(s.unattributed_objective_events, & &1.attribution.basis)
      },
      player_state: length(s.unattributed_player_state_events),
      stops_with_no_open_attempt: length(s.unmatched_stops),
      unpaired_contract_sessions: length(s.unpaired_contract_sessions),
      unmatched_contract_ends: length(s.unmatched_contract_ends),
      total:
        length(s.unattributed_outcomes) + length(s.unattributed_disguise_events) +
          length(s.unattributed_item_events) + length(s.unattributed_objective_events) +
          length(s.unattributed_player_state_events) + length(instance.unmatched_stops),
      rule: @counting_rules.attribution
    }
  end

  # -- aggregates across attempts -----------------------------------------------------------------

  defp actor_outcomes(per_attempt, unattributed) do
    rows = Enum.map(per_attempt, & &1.actor_outcomes)
    sum = fn fun -> rows |> Enum.map(fun) |> Enum.sum() end
    merge = fn fun -> rows |> Enum.map(fun) |> merge_counts() end

    %{
      occurrences: sum.(& &1.occurrences),
      died: sum.(& &1.died),
      pacified: sum.(& &1.pacified),
      target: %{died: sum.(& &1.target.died), pacified: sum.(& &1.target.pacified)},
      non_target: %{died: sum.(& &1.non_target.died), pacified: sum.(& &1.non_target.pacified)},
      accidents: sum.(& &1.accidents),
      by_actor_type: merge.(& &1.by_actor_type),
      by_death_type: merge.(& &1.by_death_type),
      by_death_context: merge.(& &1.by_death_context),
      by_kill_class: merge.(& &1.by_kill_class),
      by_method_broad: merge.(& &1.by_method_broad),
      by_method_strict: merge.(& &1.by_method_strict),
      with_item: sum.(& &1.with_item),
      unattributed: %{
        died: unattributed |> Enum.map(& &1.actor_outcomes.died) |> Enum.sum(),
        pacified: unattributed |> Enum.map(& &1.actor_outcomes.pacified) |> Enum.sum()
      },
      counted: :occurrences,
      note:
        "occurrence counts, never distinct actors; an absent outcome is not evidence of survival"
    }
  end

  defp contracts(summary) do
    sessions = Enum.flat_map(summary, & &1.contract_sessions)

    %{
      sessions_observed: length(sessions),
      started: length(sessions),
      ended: Enum.count(sessions, &(&1.ended_sequence != nil)),
      paired: Enum.count(sessions, &(&1.attempt_number != nil)),
      unpaired: Enum.count(sessions, &is_nil(&1.attempt_number)),
      unmatched_ends: summary |> Enum.map(&length(&1.unmatched_contract_ends)) |> Enum.sum(),
      by_paired_by: frequencies(Enum.reject(sessions, &is_nil(&1.paired_by)), & &1.paired_by),
      by_reason_kind:
        frequencies(Enum.reject(sessions, &is_nil(&1.reason_kind)), & &1.reason_kind),
      by_contract_id: frequencies(sessions, & &1.contract_id),
      by_location_id: frequencies(sessions, & &1.location_id),
      by_difficulty_level: frequencies(sessions, & &1.difficulty_level),
      correlation: :derived
    }
  end

  defp disguise(per_attempt, unattributed) do
    rows = Enum.map(per_attempt, & &1.disguise)
    sum = fn fun -> rows |> Enum.map(fun) |> Enum.sum() end

    %{
      occurrences: sum.(& &1.occurrences),
      equipped_initial: sum.(& &1.equipped_initial),
      equipped_change: sum.(& &1.equipped_change),
      compromised: sum.(& &1.compromised),
      compromise_cleared: sum.(& &1.compromise_cleared),
      changes: sum.(& &1.changes),
      compromise_episodes: sum.(& &1.compromise_episodes),
      worn_standing_by_attempt: frequencies(rows, & &1.worn_standing),
      anomalies: sum.(& &1.anomalies),
      unattributed: unattributed |> Enum.map(& &1.disguise) |> Enum.sum(),
      standing_tag: :derived
    }
  end

  defp items(per_attempt, unattributed) do
    rows = Enum.map(per_attempt, & &1.items)
    sum = fn fun -> rows |> Enum.map(fun) |> Enum.sum() end

    %{
      occurrences: sum.(& &1.occurrences),
      picked_up: sum.(& &1.picked_up),
      thrown: sum.(& &1.thrown),
      removed_from_inventory: sum.(& &1.removed_from_inventory),
      unattributed: unattributed |> Enum.map(& &1.items) |> Enum.sum(),
      note: "direct occurrence counts; nothing paired, no inventory"
    }
  end

  defp objectives(per_attempt, unattributed) do
    rows = Enum.map(per_attempt, & &1.objectives)

    %{
      occurrences: rows |> Enum.map(& &1.occurrences) |> Enum.sum(),
      conflicts: rows |> Enum.map(& &1.conflicts) |> Enum.sum(),
      by_basis: rows |> Enum.map(& &1.by_basis) |> merge_counts(),
      unattributed: %{
        total: unattributed |> Enum.map(& &1.objectives.total) |> Enum.sum(),
        by_basis: unattributed |> Enum.map(& &1.objectives.by_basis) |> merge_counts()
      },
      note: "occurrences reported done; says nothing about how the mission ended"
    }
  end

  defp player_state(per_attempt, unattributed) do
    rows = Enum.map(per_attempt, & &1.player_state)

    subject = fn key ->
      own = Enum.map(rows, &Map.fetch!(&1, key))

      %{
        occurrences: own |> Enum.map(& &1.occurrences) |> Enum.sum(),
        observed_value_changes: own |> Enum.map(& &1.observed_value_changes) |> Enum.sum(),
        standing_by_attempt: frequencies(own, & &1.standing),
        notes: own |> Enum.map(& &1.notes) |> Enum.sum()
      }
    end

    %{
      occurrences: rows |> Enum.map(& &1.occurrences) |> Enum.sum(),
      trespassing: subject.(:trespassing),
      illegal_weapon: subject.(:illegal_weapon),
      unattributed: unattributed |> Enum.map(& &1.player_state) |> Enum.sum(),
      tag: :last_observed
    }
  end

  defp transport(%Replay{source: :legacy}) do
    %{
      status: :not_recorded,
      openings: :not_recorded,
      identifications: :not_recorded,
      closes: :not_recorded,
      closed_unidentified: :not_recorded,
      by_close_reason: %{},
      close_reasons: %{exact: 0, qualified: 0}
    }
  end

  defp transport(%Replay{reader: reader, completeness: c} = r) do
    count = fn kind -> Enum.count(reader.records, &(&1.kind == kind)) end

    reasons =
      Enum.flat_map(Map.values(r.instances), fn inst ->
        for conn <- inst.connections, conn.closed_at != nil, do: conn.close_reason
      end) ++ Enum.map(r.unidentified, & &1.close_reason)

    %{
      status: :recorded,
      openings: count.("connection.opened"),
      identifications: count.("connection.identified"),
      closes: count.("connection.closed"),
      closed_unidentified: length(r.unidentified),
      still_open_at_boundary:
        r.instances
        |> Map.values()
        |> Enum.map(fn inst -> Enum.count(inst.connections, &is_nil(&1.closed_at)) end)
        |> Enum.sum(),
      by_close_reason: frequencies(reasons, &reason_key/1),
      close_reasons: %{exact: c.close_reasons.exact, qualified: length(c.close_reasons.qualified)}
    }
  end

  defp reason_key(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_key(reason), do: inspect(reason)

  defp anomalies(summary) do
    all = Enum.flat_map(summary, & &1.anomalies)
    %{total: length(all), by_kind: frequencies(all, & &1.kind)}
  end

  # -- helpers ------------------------------------------------------------------------------------

  defp frequencies(list, fun),
    do: list |> Enum.frequencies_by(fun) |> Map.new(fn {k, v} -> {key(k), v} end)

  defp key(nil), do: "not_observed"
  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: inspect(k)

  defp merge_counts(maps),
    do: Enum.reduce(maps, %{}, &Map.merge(&2, &1, fn _k, a, b -> a + b end))
end
