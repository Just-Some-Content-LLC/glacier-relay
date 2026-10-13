defmodule GlacierRelay.Statistics.Text do
  @moduledoc """
  The statistics as readable text (M4-C): a deterministic rendering of the structured result,
  one fact per line, each count saying what it counted and under which evidence class. It is a
  presentation of `GlacierRelay.Statistics` and adds nothing to it.
  """

  alias GlacierRelay.Statistics

  @doc "Renders one recording's statistics."
  @spec render(Statistics.t()) :: String.t()
  def render(%Statistics{} = s) do
    r = s.recording
    e = s.evidence
    a = s.attempts
    env = s.envelopes

    lines =
      [
        "== statistics (#{s.schema})",
        "recording #{r.id}: source #{r.source}, format #{inspect(r.format)}, records #{inspect(r.first_record_no)}..#{inspect(r.boundary)}, schema versions #{inspect(r.schema_versions)}, app #{inspect(r.app_version)}",
        "evidence: #{e.classification}; recorder-authoritative #{e.recorder_authoritative?}; finalization #{e.finalization}; records verified #{e.records.verified}, durable by trusted boundary #{e.records.durable_by_trusted_boundary}, unverified used #{e.records.unverified_used}, ambiguous #{length(e.records.ambiguous)}; recorder gaps #{length(e.recorder_gaps)} (+#{length(e.open_ended_gaps)} open-ended), unexplained missing #{length(e.unexplained_missing)}; Relay sequence gaps on #{length(e.relay_sequence_gaps)} instance(s); transport #{e.transport}; receipt times #{e.receipt_times}; native drops #{e.native_drops}; close reasons #{e.close_reasons.exact} exact, #{e.close_reasons.qualified} qualified",
        "counts are observed occurrences, not exhaustive totals:"
      ] ++
        Enum.map(e.observed_only_reasons, &"  - #{&1}") ++
        [
          "instances: #{s.instances.observed} observed #{inspect(s.instances.ids)}; observation #{kv(s.instances.observation)}",
          "attempts: #{a.observed} observed (#{a.stopped} stopped, #{a.last_known_playing} last known playing, #{a.superseded} superseded); starts observed #{a.starts_observed}, stops observed #{a.stops_observed} (#{a.stops_with_no_open_attempt} with no open attempt); stop not observed #{a.stop_not_observed}; history intact #{a.history.intact}, broken #{a.history.broken}; by disposition #{kv(a.by_disposition)}",
          "durations: #{a.durations.bounded} bounded, #{a.durations.unbounded} unbounded; total #{a.durations.total_ms} ms, min #{inspect(a.durations.min_ms)}, max #{inspect(a.durations.max_ms)} [#{a.durations.rule}]",
          "envelopes: #{env.received} received, #{env.accounted} accounted (reconciled #{env.reconciled?}), #{env.rejected_by_validator} rejected by the validator; by family #{kv(env.by_family)} (per event type in the structured result)",
          "actor outcomes: #{s.actor_outcomes.occurrences} occurrences; died #{s.actor_outcomes.died} (target #{s.actor_outcomes.target.died}, non-target #{s.actor_outcomes.non_target.died}), pacified #{s.actor_outcomes.pacified} (target #{s.actor_outcomes.target.pacified}, non-target #{s.actor_outcomes.non_target.pacified}); accidents #{s.actor_outcomes.accidents}; unattributed died #{s.actor_outcomes.unattributed.died}, pacified #{s.actor_outcomes.unattributed.pacified} [#{s.actor_outcomes.note}]",
          "  by death type #{kv(s.actor_outcomes.by_death_type)}; by death context #{kv(s.actor_outcomes.by_death_context)}; by kill class #{kv(s.actor_outcomes.by_kill_class)}; by method #{kv(s.actor_outcomes.by_method_broad)}; by actor type #{kv(s.actor_outcomes.by_actor_type)}",
          "contracts: #{s.contracts.sessions_observed} sessions (#{s.contracts.ended} ended, #{s.contracts.paired} paired, #{s.contracts.unpaired} unpaired, #{s.contracts.unmatched_ends} unmatched ends); paired by #{kv(s.contracts.by_paired_by)}; end reasons #{kv(s.contracts.by_reason_kind)}; contract ids #{kv(s.contracts.by_contract_id)}; locations #{kv(s.contracts.by_location_id)}; difficulty #{kv(s.contracts.by_difficulty_level)} [correlation BEAM-derived]",
          "disguise: #{s.disguise.occurrences} occurrences (initial #{s.disguise.equipped_initial}, change #{s.disguise.equipped_change}, compromised #{s.disguise.compromised}, cleared #{s.disguise.compromise_cleared}); changes #{s.disguise.changes}; compromise episodes #{s.disguise.compromise_episodes}; worn standing by attempt #{kv(s.disguise.worn_standing_by_attempt)}; anomalies #{s.disguise.anomalies}; unattributed #{s.disguise.unattributed} [standing BEAM-derived]",
          "items: #{s.items.occurrences} occurrences (picked up #{s.items.picked_up}, thrown #{s.items.thrown}, removed #{s.items.removed_from_inventory}); unattributed #{s.items.unattributed} [#{s.items.note}]",
          "objectives: #{s.objectives.occurrences} occurrences; conflicts #{s.objectives.conflicts}; by basis #{kv(s.objectives.by_basis)}; unattributed #{s.objectives.unattributed.total} #{kv(s.objectives.unattributed.by_basis)} [#{s.objectives.note}]",
          "player state: #{s.player_state.occurrences} occurrences; trespassing #{s.player_state.trespassing.occurrences} (#{s.player_state.trespassing.observed_value_changes} observed value changes, standing #{kv(s.player_state.trespassing.standing_by_attempt)}); illegal weapon #{s.player_state.illegal_weapon.occurrences} (#{s.player_state.illegal_weapon.observed_value_changes} observed value changes, standing #{kv(s.player_state.illegal_weapon.standing_by_attempt)}); unattributed #{s.player_state.unattributed} [last observed, never current state]",
          transport_line(s.transport),
          "anomalies: #{s.anomalies.total} #{kv(s.anomalies.by_kind)}",
          "per attempt:"
        ] ++
        Enum.map(s.per_attempt, &attempt_line/1) ++
        ["unattributed per instance:"] ++
        Enum.map(s.unattributed, &unattributed_line/1)

    Enum.join(lines, "\n")
  end

  defp transport_line(%{status: :not_recorded}), do: "transport: not recorded (legacy input)"

  defp transport_line(t),
    do:
      "transport: #{t.openings} openings, #{t.identifications} identifications, #{t.closes} closes (#{t.closed_unidentified} closed unidentified, #{t.still_open_at_boundary} still open at the boundary); by close reason #{kv(t.by_close_reason)}; #{t.close_reasons.exact} exact, #{t.close_reasons.qualified} qualified"

  defp attempt_line(a) do
    name =
      if a.codename_hint in [nil, ""],
        do: a.scene_resource,
        else: "#{a.codename_hint} (#{a.scene_resource})"

    stop =
      case a.stop do
        %{observed: true} = s -> "stopped ##{s.sequence}"
        %{reason: :last_known_playing} -> "stop not observed (last known playing)"
        %{reason: :superseded, by: by} -> "stop not observed (superseded by attempt #{by})"
      end

    duration =
      case a.duration do
        %{bounded: true, ms: ms} -> "duration #{ms} ms (Relay clock)"
        %{bounded: false, reason: why} -> "duration not bounded (#{why})"
      end

    contract =
      case a.contract do
        %{status: :paired} = c ->
          "contract #{c.contract_id} #{c.location_id} difficulty #{inspect(c.difficulty_level)} (paired by #{c.paired_by})"

        %{status: :ambiguous} = c ->
          "contract ambiguous (#{length(c.candidates)} candidates)"

        _ ->
          "contract not observed"
      end

    engine =
      case a.engine_times do
        %{domain: :none} = t ->
          "engine times: no clock domain (#{t.occurrences_timed} timed occurrences not compared)"

        t ->
          "engine times: domain #{String.slice(t.domain, 0, 8)}…, #{t.occurrences_in_domain} in domain (#{t.occurrences_outside_domain} outside), span #{inspect(t.observed_span_s)} s, contract span #{inspect(t.contract_span_s)} s"
      end

    history =
      if a.history == :intact,
        do: "history intact",
        else: "history broken (#{length(a.history.broken)} reason(s))"

    o = a.actor_outcomes
    d = a.disguise
    p = a.player_state

    "  #{a.instance} attempt #{a.number}: #{name}; #{a.mission}; start ##{a.start.sequence}; #{stop}; #{duration}; #{contract}; disposition #{a.disposition.value}; #{history}; #{engine}; outcomes #{o.occurrences} (died #{o.died}, pacified #{o.pacified}; #{o.display_groups} display groups, not actors); disguise #{d.occurrences} occurrences, #{d.changes} changes, worn #{inspect(d.worn)} standing #{d.worn_standing}; items #{a.items.occurrences} (#{a.items.picked_up}/#{a.items.thrown}/#{a.items.removed_from_inventory}); objectives #{a.objectives.occurrences} (#{a.objectives.distinct_objective_ids} ids); player state #{p.occurrences} (trespassing #{p.trespassing.occurrences}/#{p.trespassing.observed_value_changes} changes/#{p.trespassing.standing}, illegal weapon #{p.illegal_weapon.occurrences}/#{p.illegal_weapon.observed_value_changes} changes/#{p.illegal_weapon.standing})"
  end

  defp unattributed_line(u),
    do:
      "  #{u.instance}: #{u.total} unattributed (died #{u.actor_outcomes.died}, pacified #{u.actor_outcomes.pacified}, disguise #{u.disguise}, items #{u.items}, objectives #{u.objectives.total} #{kv(u.objectives.by_basis)}, player state #{u.player_state}, stops with no open attempt #{u.stops_with_no_open_attempt}); unpaired contract sessions #{u.unpaired_contract_sessions}, unmatched contract ends #{u.unmatched_contract_ends}"

  @doc "Renders a comparison."
  @spec render_comparison(map()) :: String.t()
  def render_comparison(c) do
    lines =
      [
        "== comparison (#{c.schema}); unit #{c.basis.unit}; grouped by #{inspect(c.basis.group_by)}; #{c.rows} row(s) from #{length(c.recordings)} result(s)",
        "recordings:"
      ] ++
        Enum.map(
          c.recordings,
          &"  #{&1.id}: #{&1.source}, evidence #{&1.evidence_class}, recorder-authoritative #{&1.recorder_authoritative?}, finalization #{&1.finalization}, #{&1.attempts} attempt(s) (#{&1.attempts_with_broken_history} broken history), Relay gaps on #{&1.relay_sequence_gaps} instance(s), recorder gaps #{&1.recorder_gaps}, schema #{inspect(&1.schema_versions)}, app #{inspect(&1.app_version)}"
        ) ++
        ["groups:"] ++
        Enum.map(c.groups, &group_line/1) ++
        ["limitations:"] ++
        Enum.map(c.limitations, &"  - #{&1}")

    Enum.join(lines, "\n")
  end

  defp group_line(g) do
    key = g.key |> Enum.sort() |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)

    "  [#{key}] attempts #{g.attempts} across #{length(g.recordings)} recording(s), #{g.instances} instance(s); evidence #{kv(g.evidence_classes)}; history intact #{g.history.intact}, broken #{g.history.broken}; mission #{kv(g.mission)}; disposition #{kv(g.disposition)}; durations #{g.durations.bounded} bounded (min #{inspect(g.durations.min_ms)}, max #{inspect(g.durations.max_ms)} ms), #{g.durations.unbounded} unbounded; contract spans #{g.contract_spans.observed} (min #{inspect(g.contract_spans.min_s)}, max #{inspect(g.contract_spans.max_s)} s); families #{kv(g.families)}; died #{g.actor_outcomes.died}, pacified #{g.actor_outcomes.pacified} (occurrences); mixed evidence #{g.mixed_evidence}"
  end

  defp kv(map) when map == %{}, do: "none"

  defp kv(map),
    do:
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort()
      |> Enum.map_join(", ", fn {k, v} -> "#{k} #{v}" end)
end
