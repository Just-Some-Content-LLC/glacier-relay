defmodule GlacierRelay.Report do
  @moduledoc """
  The mission-oriented report (M2 B7, design section 50): a pure, additive presentation of what
  BEAM holds about each mission attempt, built from `Summary.build/1` (the existing derived
  views, folded once) and the `Lifecycle.Instance` records. Nothing here folds evidence again,
  stores anything, reorders or rewrites a record, or adds a fact the stream did not carry.

  Every reported fact carries one of four tags: `:engine` (an engine-authored occurrence or
  field, or the native observer's reading of engine scene state), `:derived` (a BEAM correlation
  or conservative reading: contract pairing, disposition attachment, disguise standing),
  `:last_observed` (a last-value reading, never a current state), `:not_observed` (an absence,
  never evidence of the opposite). Transport evidence (interruptions) is tagged `:transport` and
  carries no Relay sequence.

  Per attempt: `overview`, `targets` / `non_targets` (display groups by `{actor_name,
  repository_id}`; every occurrence kept; no distinct-actor count; a target without an outcome is
  not listed), `activity` (the existing derived views, labelled), `timeline` (Relay sequence
  order, both clocks, the clock-domain rule of section 50.3 as refined), `uncertainty` (one list,
  always ending with the standing limitations).

  Cost: one `Summary.build/1` per report (each attempt's views folded once) plus one pass over the
  attempt's records to lay out the timeline; nothing quadratic beyond the display grouping of
  outcomes, which is bounded by the attempt's outcome count.
  """

  alias GlacierRelay.{AttemptHistory, Summary}
  alias GlacierRelay.Lifecycle.{Attempt, Instance}

  @limitations [
    "whether the mission ended in success or failure is not observable on this stream: no terminal engine event is validated, and on the observed route the mission predicate stayed up through the end screens (section 44)",
    "ContractEnd is a name only; its payload is unvalidated and it is not a completed-contract event (section 46.9)",
    "the complete status of all mission targets is not established: an absent outcome is not evidence of survival",
    "player state is the engine's last statement per subject, not a continuously verified current state"
  ]

  @doc "Report data, one map per instance, oldest attempt first (the same order as `Summary.build/1`)."
  @spec report(%{String.t() => Instance.t()}) :: [map()]
  def report(instances) when is_map(instances) do
    built = Summary.build(instances)

    Enum.map(built, fn s ->
      instance = Map.fetch!(instances, s.adapter_instance_id)

      %{
        adapter_instance_id: s.adapter_instance_id,
        received: s.received,
        last_sequence: s.last_sequence,
        gaps: s.gaps,
        observation: s.observation,
        connections: s.connections,
        attempts: Enum.map(s.attempts, &attempt_report(&1, instance)),
        unattributed: %{
          outcomes: s.unattributed_outcomes,
          disguise: s.unattributed_disguise_events,
          items: s.unattributed_item_events,
          objectives: s.unattributed_objective_events,
          player_state: s.unattributed_player_state_events
        },
        unmatched_stops: s.unmatched_stops,
        unpaired_contract_sessions: s.unpaired_contract_sessions,
        unmatched_contract_ends: s.unmatched_contract_ends,
        anomalies: s.anomalies,
        limitations: @limitations
      }
    end)
  end

  # -- attempt ---------------------------------------------------------------------------------

  defp attempt_report(a, %Instance{} = instance) do
    attempt = Enum.at(instance.attempts, a.number - 1)
    completeness = AttemptHistory.history(attempt, instance.gaps)

    %{
      overview: overview(a, attempt, completeness),
      targets: outcome_groups(Enum.filter(a.outcomes, & &1.is_target), :target),
      non_targets: outcome_groups(Enum.filter(a.outcomes, &(not &1.is_target)), :non_target),
      outcome_counts: a.outcome_counts,
      activity: activity(a),
      timeline: timeline(a, attempt),
      uncertainty: uncertainty(a, attempt, instance, completeness)
    }
  end

  defp overview(a, %Attempt{} = attempt, completeness) do
    %{
      number: a.number,
      scene_resource: a.scene_resource,
      scene_type: a.scene_type,
      codename_hint: a.codename_hint,
      mission: a.mission,
      start: %{
        sequence: a.playing_sequence,
        relay_at: a.playing_at,
        game_session_id: a.game_session_id.playing,
        tag: :engine
      },
      stop: stop(a),
      duration_ms: a.duration_ms,
      contract: contract(a, attempt),
      disposition: disposition(a),
      completeness: completeness
    }
  end

  defp stop(%{mission: :stopped} = a),
    do: %{
      sequence: a.stopped_sequence,
      relay_at: a.stopped_at,
      game_session_id: a.game_session_id.stopped,
      scene: a.stopped_scene,
      tag: :engine
    }

  defp stop(%{mission: :playing}),
    do: %{status: :not_observed, reason: :last_known_playing, tag: :not_observed}

  defp stop(%{mission: :superseded} = a),
    do: %{status: :not_observed, reason: {:superseded, a.superseded_by}, tag: :not_observed}

  # The Glacier contract session is kept distinct from the Relay attempt: the facts are the
  # engine's (contract.started / contract.ended), the correlation is BEAM's and is labelled.
  defp contract(%{contract: nil, contract_candidates: []}, _attempt),
    do: %{status: :not_observed, tag: :not_observed}

  defp contract(%{contract: nil, contract_candidates: candidates}, _attempt)
       when candidates != [],
       do: %{status: :ambiguous, candidates: candidates, tag: :not_observed}

  defp contract(%{contract: c} = a, _attempt) do
    %{
      status: :paired,
      paired_by: a.contract_paired_by,
      session_id: c.contract_session_id,
      contract_id: c.contract_id,
      location_id: c.location_id,
      contract_type: c.contract_type,
      difficulty_level: c.difficulty_level,
      starting_disguise_repository_id: c.starting_disguise_repository_id,
      is_hitman_suit: c.is_hitman_suit,
      started: %{
        sequence: c.started_sequence,
        relay_at: c.started_at,
        engine_t: c.started_engine_timestamp_s,
        tag: :engine
      },
      ended:
        if(c.ended_sequence,
          do: %{
            sequence: c.ended_sequence,
            relay_at: c.ended_at,
            engine_t: c.ended_engine_timestamp_s,
            reason: c.reason,
            reason_kind: c.reason_kind,
            relative: c.ended_relative,
            tag: :engine
          },
          else: %{status: :not_observed, tag: :not_observed}
        ),
      correlation_tag: :derived
    }
  end

  defp disposition(%{disposition: :not_observed}), do: %{value: :not_observed, tag: :not_observed}

  defp disposition(%{contract: c, disposition: d}) when not is_nil(c),
    do: %{
      value: d,
      reason: c.reason,
      reason_kind: c.reason_kind,
      ended_sequence: c.ended_sequence,
      ended_relative: c.ended_relative,
      tag: :derived
    }

  defp disposition(%{disposition: d}), do: %{value: d, tag: :derived}

  # -- actor outcomes ----------------------------------------------------------------------------

  # Display grouping only: the key is the engine's display name and definition id, which generic
  # NPCs share; engine_actor_id is kept per occurrence as an observation and is never a key.
  defp outcome_groups(outcomes, class) do
    groups =
      outcomes
      |> Enum.reduce([], fn o, acc ->
        key = {o.actor_name, o.repository_id}
        occ = occurrence(o)

        case Enum.find_index(acc, &(&1.key == key)) do
          nil ->
            [
              %{
                key: key,
                actor_name: o.actor_name,
                repository_id: o.repository_id,
                occurrences: [occ]
              }
              | acc
            ]

          i ->
            List.update_at(acc, i, &%{&1 | occurrences: &1.occurrences ++ [occ]})
        end
      end)
      |> Enum.reverse()
      |> Enum.map(&Map.delete(&1, :key))

    base = %{groups: groups, occurrences: length(outcomes), grouping: :display_only, tag: :engine}

    if class == :target,
      do:
        Map.put(
          base,
          :note,
          "the full status of all mission targets is not established; an absent outcome is not evidence of survival"
        ),
      else: base
  end

  defp occurrence(o) do
    %{
      sequence: o.sequence,
      relay_at: o.timestamp,
      engine_t: o.engine_timestamp_s,
      kind: o.kind,
      engine_actor_id: o.engine_actor_id,
      actor_type: o.actor_type,
      is_target: o.is_target,
      death_type: o.death_type,
      death_context: o.death_context,
      accident: o.accident,
      kill_class: o.kill_class,
      method_broad: o.method_broad,
      method_strict: o.method_strict,
      damage_events: o.damage_events,
      item_repository_id: o.item_repository_id,
      tag: :engine
    }
  end

  # -- gameplay activity -------------------------------------------------------------------------

  defp activity(a) do
    %{
      disguise: %{
        events: a.disguise_events,
        view: a.disguise,
        events_tag: :engine,
        view_tag: :derived
      },
      items: %{events: a.item_events, view: a.items, events_tag: :engine, view_tag: :derived},
      objectives: %{
        events: a.objective_events,
        view: %{
          a.objectives
          | by_objective:
              Enum.map(a.objectives.by_objective, &Map.put(&1, :metadata_basis, :first_observed))
        },
        events_tag: :engine,
        view_tag: :derived
      },
      player_state: %{
        events: a.player_state_events,
        view: a.player_state,
        events_tag: :engine,
        view_tag: :last_observed
      }
    }
  end

  # -- timeline ----------------------------------------------------------------------------------

  @policy "Relay sequence order (publication order, replayable); each line shows the native publication time and, when the engine supplied one, the engine occurrence time on the contract clock; engine times are compared only between consecutive lines of the same established contract-session clock domain; a new session is a new clock; nothing is reordered by engine time"

  defp timeline(a, %Attempt{} = attempt) do
    session = a.contract_session_id

    # The legacy outcome map omits the session; read it from the attempt's own records by sequence.
    outcome_sessions = Map.new(attempt.outcomes, &{&1.sequence, &1.payload.contract_session_id})

    records =
      [rise_line(a)] ++
        contract_lines(a) ++
        Enum.map(a.outcomes, &outcome_line(&1, outcome_sessions[&1.sequence])) ++
        Enum.map(a.disguise_events, &disguise_line/1) ++
        Enum.map(a.item_events, &item_line/1) ++
        Enum.map(a.objective_events, &objective_line/1) ++
        Enum.map(a.player_state_events, &player_state_line/1) ++
        stop_lines(a) ++
        Enum.map(attempt.interruptions, &interruption_line/1)

    lines =
      records
      |> Enum.sort_by(& &1.position)
      |> clock_domains()
      |> relative_times(session)

    %{policy: @policy, lines: lines}
  end

  defp line(seq, relay_at, engine_t, domain, family, engine_event, fact, tag) do
    %{
      sequence: seq,
      position: {seq, 0},
      relay_at: relay_at,
      engine_t: engine_t,
      engine_t_rel: nil,
      clock: %{domain: domain || :unknown, comparability: nil, regression: false},
      family: family,
      engine_event: engine_event,
      fact: fact,
      tag: tag
    }
  end

  defp rise_line(a),
    do:
      line(
        a.playing_sequence,
        a.playing_at,
        nil,
        nil,
        :lifecycle,
        nil,
        "mission.playing: the mission predicate rose (#{a.codename_hint})",
        :engine
      )

  defp stop_lines(%{mission: :stopped} = a),
    do: [
      line(
        a.stopped_sequence,
        a.stopped_at,
        nil,
        nil,
        :lifecycle,
        nil,
        "mission.stopped: the mission predicate fell",
        :engine
      )
    ]

  defp stop_lines(_), do: []

  defp contract_lines(%{contract: nil}), do: []

  defp contract_lines(%{contract: c}) do
    started =
      line(
        c.started_sequence,
        c.started_at,
        c.started_engine_timestamp_s,
        c.contract_session_id,
        :contract,
        "ContractStart",
        "contract.started: session #{short(c.contract_session_id)}, #{c.location_id}, #{c.contract_type}, difficulty #{c.difficulty_level} (correlated to this attempt by #{c.paired_by})",
        :engine
      )

    ended =
      if c.ended_sequence,
        do: [
          line(
            c.ended_sequence,
            c.ended_at,
            c.ended_engine_timestamp_s,
            c.contract_session_id,
            :contract,
            "ContractFailed",
            "contract.ended: #{reason(c.reason_kind, c.reason)} (#{relative_text(c.ended_relative)})",
            :engine
          )
        ],
        else: []

    [started | ended]
  end

  defp outcome_line(o, session) do
    target = if o.is_target, do: "target", else: "non-target"
    item = if o.item_repository_id, do: ", item #{short(o.item_repository_id)}", else: ""

    line(
      o.sequence,
      o.timestamp,
      o.engine_timestamp_s,
      session,
      :actor,
      engine_name(o.kind),
      "actor.#{o.kind}: #{o.actor_name} (#{o.actor_type}, #{target}; engine actor id #{o.engine_actor_id}): #{o.death_type}/#{o.death_context}, #{o.kill_class}, #{o.method_broad}#{if o.method_strict != "", do: "/" <> o.method_strict, else: ""}, damage [#{Enum.join(o.damage_events, ",")}]#{item}",
      :engine
    )
  end

  defp engine_name(:died), do: "Kill"
  defp engine_name(:pacified), do: "Pacify"

  defp disguise_line(o) do
    what =
      case {o.type, o.kind} do
        {:equipped, :initial} ->
          "disguise.equipped (initial): #{short(o.disguise_repository_id)}"

        {:equipped, :change} ->
          "disguise.equipped (change): #{short(o.disguise_repository_id)}"

        {:compromised, _} ->
          "disguise.compromised: #{short(o.disguise_repository_id)}"

        {:compromise_cleared, _} ->
          "disguise.compromise_cleared: #{short(o.disguise_repository_id)}"
      end

    line(
      o.sequence,
      o.timestamp,
      o.engine_timestamp_s,
      o.contract_session_id,
      :disguise,
      o.engine_event,
      what,
      :engine
    )
  end

  defp item_line(o) do
    what =
      case o.type do
        :picked_up -> "item.picked_up"
        :thrown -> "item.thrown"
        :removed_from_inventory -> "item.removed_from_inventory"
      end

    name = if o.item_name not in [nil, ""], do: "#{o.item_name} ", else: ""

    line(
      o.sequence,
      o.timestamp,
      o.engine_timestamp_s,
      o.contract_session_id,
      :item,
      o.engine_event,
      "#{what}: #{name}#{short(o.item_repository_id)}",
      :engine
    )
  end

  defp objective_line(o) do
    label =
      case {o.objective_type, o.objective_category} do
        {nil, nil} -> "objective"
        {t, nil} -> t
        {nil, c} -> "?/#{c}"
        {t, c} -> "#{t}/#{c}"
      end

    line(
      o.sequence,
      o.timestamp,
      o.engine_timestamp_s,
      o.contract_session_id,
      :objective,
      o.engine_event,
      "objective reported done: #{label} #{short(o.objective_id)} (attributed to this attempt by #{o.attribution.basis})",
      :engine
    )
  end

  defp player_state_line(%{subject: :trespassing} = o) do
    room = if o.room_id, do: " (room_id #{o.room_id})", else: ""

    line(
      o.sequence,
      o.timestamp,
      o.engine_timestamp_s,
      o.contract_session_id,
      :player_state,
      o.engine_event,
      "player.trespassing: #{o.trespassing}#{room}",
      :engine
    )
  end

  defp player_state_line(%{subject: :illegal_weapon} = o) do
    weapon = if o.weapon, do: " (#{weapon_label(o.weapon)})", else: ""

    line(
      o.sequence,
      o.timestamp,
      o.engine_timestamp_s,
      o.contract_session_id,
      :player_state,
      o.engine_event,
      "player.illegal_weapon: #{o.holding}#{weapon}",
      :engine
    )
  end

  # Transport evidence: no Relay sequence is invented; the line sits after the last sequence the
  # instance had received when the connection closed (after_sequence), at its own timestamp.
  defp interruption_line(i) do
    %{
      sequence: nil,
      position: {i.after_sequence, 1},
      relay_at: i.at,
      engine_t: nil,
      engine_t_rel: nil,
      clock: %{domain: :none, comparability: nil, regression: false},
      family: :transport,
      engine_event: nil,
      fact:
        "observation lost: the connection closed (#{inspect(i.reason)}) after ##{i.after_sequence}; no mission.stopped is implied",
      tag: :transport
    }
  end

  # Clock domains (section 50.3 as refined): consecutive engine-timed lines are compared only when
  # both carry the same explicit contract session id; a different explicit session is a new clock
  # (no regression can be marked); an unknown domain on either side makes comparability unknown.
  defp clock_domains(lines) do
    {out, _prev} =
      Enum.reduce(lines, {[], nil}, fn l, {acc, prev} ->
        cond do
          is_nil(l.engine_t) ->
            {[l | acc], prev}

          is_nil(prev) ->
            {[put_in(l.clock.comparability, :first) | acc], l}

          l.clock.domain == :unknown or prev.clock.domain == :unknown ->
            {[put_in(l.clock.comparability, :unknown) | acc], l}

          l.clock.domain == prev.clock.domain ->
            regression = l.engine_t < prev.engine_t

            {[
               %{l | clock: %{l.clock | comparability: :same_domain, regression: regression}}
               | acc
             ], l}

          true ->
            {[put_in(l.clock.comparability, :new_domain) | acc], l}
        end
      end)

    Enum.reverse(out)
  end

  # A relative engine time only for lines in the attempt's paired session's domain, from that
  # domain's first engine-timed line; other lines keep their original engine time alone.
  defp relative_times(lines, nil), do: lines

  defp relative_times(lines, session) do
    case Enum.find(lines, &(&1.engine_t != nil and &1.clock.domain == session)) do
      nil ->
        lines

      base ->
        Enum.map(lines, fn l ->
          if l.engine_t != nil and l.clock.domain == session,
            do: %{l | engine_t_rel: l.engine_t - base.engine_t},
            else: l
        end)
    end
  end

  # -- uncertainty -------------------------------------------------------------------------------

  defp uncertainty(a, %Attempt{}, %Instance{} = instance, completeness) do
    history =
      case completeness do
        :complete -> []
        {:incomplete, reasons} -> Enum.map(reasons, &history_item/1)
      end

    lifecycle =
      case a.mission do
        :playing ->
          [
            item(
              :stop_not_observed,
              "the stop was not observed; the attempt is last known playing",
              :not_observed
            )
          ]

        :superseded ->
          [
            item(
              :stop_not_observed,
              "the stop was not observed; the attempt was superseded by attempt #{a.superseded_by}",
              :not_observed
            )
          ]

        _ ->
          []
      end

    contract =
      case {a.contract_session_id, a.contract_candidates} do
        {nil, []} ->
          [
            item(
              :contract_not_observed,
              "no contract session was correlated to this attempt",
              :not_observed
            )
          ]

        {nil, candidates} ->
          [
            item(
              :contract_ambiguous,
              "#{length(candidates)} contract sessions were waiting at the rise; none correlated: #{Enum.join(candidates, ", ")}",
              :not_observed
            )
          ]

        {_, _} ->
          if(a.contract && a.contract.ended_sequence,
            do: [],
            else: [
              item(
                :contract_end_not_observed,
                "the paired contract session's end was not observed; disposition not observed",
                :not_observed
              )
            ]
          )
      end

    disguise =
      Enum.flat_map(
        [
          if(a.disguise.worn_standing == :unknown,
            do: [
              item(
                :disguise_standing_unknown,
                "the worn outfit's standing is unknown (#{inspect(a.disguise.standing_reason)}#{if a.disguise.standing_cut, do: ", cut " <> inspect(a.disguise.standing_cut.cut), else: ""})",
                :derived
              )
            ],
            else: []
          ),
          Enum.map(a.disguise.anomalies, &item(:disguise_anomaly, inspect(&1), :derived))
        ],
        & &1
      )

    objectives =
      Enum.flat_map(a.objectives.by_objective, fn row ->
        Enum.map(
          row.conflicts,
          &item(
            :objective_conflict,
            "objective #{short(row.objective_id)}: ##{&1.sequence} #{&1.field} #{inspect(&1.observed)} differs from the first observed",
            :engine
          )
        )
      end)

    player =
      Enum.flat_map(
        [
          {:trespassing, a.player_state.trespassing},
          {:illegal_weapon, a.player_state.illegal_weapon}
        ],
        fn {subject, s} ->
          cut =
            if s.standing == :unknown,
              do: [
                item(
                  :player_state_unknown,
                  "#{subject}: standing unknown after #{inspect(s.standing_cut)} (last observed #{s.last.value} at ##{s.last.sequence})",
                  :last_observed
                )
              ],
              else: []

          notes =
            Enum.map(s.notes, &item(:player_state_note, "#{subject}: #{inspect(&1)}", :engine))

          cut ++ notes
        end
      )

    anomalies =
      instance.anomalies
      |> Enum.filter(
        &(Map.get(&1, :attempt) == a.number or Map.get(&1, :open_attempt) == a.number)
      )
      |> Enum.map(&item(:anomaly, inspect(&1), :derived))

    history ++
      lifecycle ++
      contract ++
      disguise ++
      objectives ++
      player ++ anomalies ++ Enum.map(@limitations, &item(:limitation, &1, :not_observed))
  end

  defp history_item({:gap, expected, got}),
    do:
      item(
        :gap,
        "sequence gap #{expected}→#{got} inside the attempt: #{got - expected} envelope(s) never arrived",
        :transport
      )

  defp history_item({:interruption, at, reason}),
    do: item(:interruption, "observation lost #{fmt(at)} (#{inspect(reason)})", :transport)

  defp history_item({:superseded, by, at}),
    do:
      item(
        :superseded,
        "superseded by attempt #{by} at ##{at}; this attempt's evidence ends there",
        :derived
      )

  defp item(kind, detail, tag), do: %{kind: kind, detail: detail, tag: tag}

  # -- text --------------------------------------------------------------------------------------

  @doc "The report as text."
  @spec render(%{String.t() => Instance.t()}, [map()]) :: String.t()
  def render(instances, unidentified \\ []) do
    lines =
      case report(instances) do
        [] -> ["no adapter instance has delivered an event"]
        reports -> Enum.flat_map(reports, &render_instance/1)
      end

    extra =
      case unidentified do
        [] ->
          []

        list ->
          ["", "connections that closed before identifying an instance: #{length(list)}"] ++
            Enum.map(
              list,
              &"  #{&1.peer} opened #{fmt(&1.opened_at)} closed #{fmt(&1.closed_at)} (#{inspect(&1.close_reason)})"
            )
      end

    Enum.join(lines ++ extra, "\n")
  end

  defp render_instance(r) do
    header =
      "adapter #{r.adapter_instance_id}: #{r.received} event(s), last sequence #{r.last_sequence}, gaps #{inspect(r.gaps)}, observation #{r.observation}"

    connections =
      Enum.map(r.connections, fn c ->
        closed =
          if c.closed_at,
            do: "closed #{fmt(c.closed_at)} (#{inspect(c.close_reason)})",
            else: "still open"

        "  connection #{c.peer}: opened #{fmt(c.opened_at)}, identified #{fmt(c.identified_at)}, #{closed} [transport]"
      end)

    attempts =
      case r.attempts do
        [] -> ["  no mission attempt observed [not observed]"]
        list -> Enum.flat_map(list, &render_attempt/1)
      end

    strays =
      Enum.map(
        r.unmatched_stops,
        &"  mission.stopped ##{&1.sequence} at #{&1.timestamp} with no open attempt (#{&1.scene_resource}) [engine]"
      ) ++
        Enum.map(
          r.unattributed.outcomes,
          &"  actor.#{&1.kind} ##{&1.sequence} #{&1.actor_name} with no open attempt [engine, unattributed]"
        ) ++
        Enum.map(
          r.unattributed.disguise,
          &"  disguise #{&1.type} #{short(&1.disguise_repository_id)} ##{&1.sequence} with no open attempt [engine, unattributed]"
        ) ++
        Enum.map(
          r.unattributed.items,
          &"  item #{&1.type} #{short(&1.item_repository_id)} ##{&1.sequence} with no open attempt [engine, unattributed]"
        ) ++
        Enum.map(
          r.unattributed.objectives,
          &"  objective #{short(&1.objective_id)} ##{&1.sequence} not attached (#{&1.attribution.basis}) [engine, unattributed]"
        ) ++
        Enum.map(
          r.unattributed.player_state,
          &"  player state #{&1.subject} ##{&1.sequence} with no open attempt [engine, unattributed]"
        ) ++
        Enum.map(
          r.unpaired_contract_sessions,
          &"  contract session #{short(&1.contract_session_id)} (#{&1.location_id}, started ##{&1.started_sequence}) not correlated to any attempt [engine; correlation not observed]"
        ) ++
        Enum.map(
          r.unmatched_contract_ends,
          &"  contract.ended ##{&1.sequence} for session #{short(&1.contract_session_id)} (#{reason(&1.reason_kind, &1.reason)}) with no open contract session [engine]"
        )

    anomalies = Enum.map(r.anomalies, &"  anomaly: #{inspect(&1)} [BEAM-derived]")

    [header] ++ connections ++ attempts ++ strays ++ anomalies
  end

  defp render_attempt(%{overview: o} = a) do
    name =
      if o.codename_hint in [nil, ""],
        do: o.scene_resource,
        else: "#{o.codename_hint} (#{o.scene_resource})"

    [
      "  attempt #{o.number}: #{name}",
      "    mission overview"
    ] ++
      render_overview(o) ++
      [
        "    actor outcomes [engine telemetry; grouping by name and definition id is display only, never an actor identity]"
      ] ++
      render_outcomes(a) ++
      ["    gameplay activity"] ++
      render_activity(a.activity) ++
      ["    timeline [#{a.timeline.policy}]"] ++
      Enum.map(a.timeline.lines, &render_line/1) ++
      ["    uncertainty and limitations"] ++
      Enum.map(a.uncertainty, &"      - #{&1.detail} [#{tag(&1.tag)}]")
  end

  defp render_overview(o) do
    contract =
      case o.contract do
        %{status: :paired} = c ->
          "      contract: session #{c.session_id} (#{c.location_id}, #{c.contract_type}, difficulty #{c.difficulty_level}, starting disguise #{short(c.starting_disguise_repository_id)}#{if c.is_hitman_suit, do: " hitman suit", else: ""}; started ##{c.started.sequence}) [engine telemetry; correlated to this attempt by #{c.paired_by}: BEAM-derived]"

        %{status: :ambiguous} = c ->
          "      contract: #{length(c.candidates)} sessions waiting at the rise, none correlated [not observed]"

        _ ->
          "      contract: not observed [not observed]"
      end

    stop =
      case o.stop do
        %{sequence: seq} = s ->
          "      stop: ##{seq} #{s.relay_at} (the predicate fell) [engine-observed]"

        %{reason: :last_known_playing} ->
          "      stop: not observed; last known playing [not observed]"

        %{reason: {:superseded, by}} ->
          "      stop: not observed; superseded by attempt #{by} [not observed]"
      end

    duration =
      if o.duration_ms,
        do: "      duration: #{fmt_duration(o.duration_ms)} (Relay clock, rise to fall)",
        else: "      duration: not bounded"

    disposition =
      case o.disposition do
        %{value: :not_observed} ->
          "      disposition: not observed [not observed]"

        %{value: v, reason: reason} = d ->
          "      disposition: #{disposition_text(v)} [engine reason #{inspect(reason)}; attached from the paired session's contract.ended ##{d.ended_sequence} (#{relative_text(d.ended_relative)}): BEAM-derived]"

        %{value: v} ->
          "      disposition: #{disposition_text(v)} [BEAM-derived]"
      end

    completeness =
      case o.completeness do
        :complete ->
          "      observation coverage: history intact (no gap, interruption or supersession inside the attempt)"

        {:incomplete, reasons} ->
          "      observation coverage: history broken — " <>
            Enum.map_join(reasons, ", ", &history_text/1)
      end

    [
      "      identity: #{o.scene_type} scene #{o.scene_resource}, hint #{inspect(o.codename_hint)}, attempt #{o.number} [engine-observed scene state]",
      contract,
      "      start: ##{o.start.sequence} #{o.start.relay_at} (the predicate rose#{if o.start.game_session_id, do: "; game_session_id " <> o.start.game_session_id <> " observed", else: ""}) [engine-observed]",
      stop,
      duration,
      disposition,
      completeness
    ]
  end

  defp render_outcomes(a) do
    targets =
      case a.targets.groups do
        [] ->
          ["      target outcomes observed: none in the stream; #{a.targets.note} [not observed]"]

        groups ->
          ["      target outcomes observed (#{a.targets.note}):"] ++
            Enum.flat_map(groups, &render_group/1)
      end

    non =
      case a.non_targets.groups do
        [] ->
          ["      non-target outcomes observed: none in the stream [not observed]"]

        groups ->
          ["      non-target outcomes observed:"] ++ Enum.flat_map(groups, &render_group/1)
      end

    targets ++
      non ++
      [
        "      counts: " <>
          render_counts(a.outcome_counts) <>
          " [engine classifications; occurrence counts, not an actor count]"
      ]
  end

  defp render_group(g) do
    [
      "        #{g.actor_name} (#{short(g.repository_id)}): #{length(g.occurrences)} occurrence#{plural(length(g.occurrences))}"
    ] ++
      Enum.map(g.occurrences, fn o ->
        item = if o.item_repository_id, do: ", item #{short(o.item_repository_id)}", else: ""

        "          ##{o.sequence} #{o.kind}#{engine_at(o.engine_t)} (#{o.actor_type}; engine actor id #{o.engine_actor_id}): #{o.death_type}/#{o.death_context}, #{o.kill_class}, #{o.method_broad}#{if o.method_strict != "", do: "/" <> o.method_strict, else: ""}, damage [#{Enum.join(o.damage_events, ",")}]#{item} [engine classification]"
      end)
  end

  defp render_counts(counts) do
    Enum.map_join([:died, :pacified], "; ", fn kind ->
      c = counts[kind]

      "#{c.total} #{kind}" <>
        if(c.total > 0, do: " (#{c.target} target, #{c.non_target} non-target)", else: "")
    end)
  end

  defp render_activity(act) do
    d = act.disguise.view

    worn =
      case d.worn do
        :not_observed ->
          "worn outfit not observed"

        %{repository_id: id, since_sequence: seq} ->
          "worn #{short(id)} since ##{seq}; standing #{standing_text(d)}"
      end

    disguise =
      "      disguises: #{length(act.disguise.events)} occurrence#{plural(length(act.disguise.events))} [engine telemetry]; #{worn}; #{d.changes} change#{plural(d.changes)} [BEAM-derived, conservative]"

    i = act.items.view

    items =
      "      items: picked up #{i.picked_up}, thrown #{i.thrown}, removed from inventory #{i.removed_from_inventory}; #{length(i.definitions_used)} definition#{plural(length(i.definitions_used))} [engine telemetry; direct counts, nothing paired]"

    ob = act.objectives.view

    objectives =
      case ob.by_objective do
        [] ->
          "      objectives: none observed in the attempt [not observed]"

        rows ->
          "      objectives: #{ob.occurrences} occurrence#{plural(ob.occurrences)} — " <>
            Enum.map_join(rows, ", ", fn row ->
              "#{objective_label(row)} (first observed) #{short(row.objective_id)} at #{Enum.map_join(row.sequences, " ", &"##{&1}")}"
            end) <> " [engine telemetry; says nothing about how the mission ended]"
      end

    p = act.player_state.view

    player =
      "      player state: #{subject_text("trespassing", p.trespassing)}; #{subject_text("illegal weapon", p.illegal_weapon)} [last observed, never current state]"

    [disguise, items, objectives, player]
  end

  defp subject_text(label, %{last: :not_observed}), do: "#{label} not observed"

  defp subject_text(label, s) do
    extra =
      case s do
        %{last: %{room_id: r}} when not is_nil(r) ->
          " (room_id #{r})"

        %{last: %{weapon: w}} when not is_nil(w) ->
          " (#{weapon_label(w)})"

        %{last_weapon: %{sequence: seq, weapon: w}} ->
          " (last named weapon #{weapon_label(w)} at ##{seq})"

        _ ->
          ""
      end

    standing =
      if s.standing == :unknown,
        do: ", standing unknown after #{inspect(s.standing_cut)}",
        else: ""

    "#{label} last observed #{s.last.value} at ##{s.last.sequence}#{extra}#{standing}, #{s.occurrences} occurrence#{plural(s.occurrences)}, #{s.observed_value_changes} observed value change#{plural(s.observed_value_changes)}"
  end

  defp standing_text(%{worn_standing: :unknown}), do: "unknown"
  defp standing_text(%{worn_standing: :not_observed}), do: "no compromise observed"
  defp standing_text(%{worn_standing: s}), do: to_string(s)

  defp render_line(l) do
    seq = if l.sequence, do: "##{l.sequence}", else: "--"

    engine =
      case l.engine_t do
        nil ->
          ""

        t ->
          " engine #{t}s#{if l.engine_t_rel, do: " (t+#{Float.round(l.engine_t_rel / 1, 3)}s)", else: ""}#{clock_text(l.clock)}"
      end

    "      #{seq} #{fmt(l.relay_at)}#{engine} #{l.fact} [#{tag(l.tag)}]"
  end

  defp clock_text(%{comparability: :new_domain}), do: " (new contract clock)"
  defp clock_text(%{comparability: :unknown}), do: " (clock comparability unknown)"
  defp clock_text(%{regression: true}), do: " (engine time earlier than the previous line)"
  defp clock_text(_), do: ""

  defp tag(:engine), do: "engine-authored"
  defp tag(:derived), do: "BEAM-derived"
  defp tag(:last_observed), do: "last observed"
  defp tag(:not_observed), do: "not observed"
  defp tag(:transport), do: "transport"

  defp disposition_text(:restarted), do: "restarted"
  defp disposition_text(:exited_to_menu), do: "exited to menu"
  defp disposition_text({:ended, reason}), do: "ended, reason #{inspect(reason)}"

  defp history_text({:gap, e, g}), do: "gap #{e}→#{g}"

  defp history_text({:interruption, at, reason}),
    do: "observation lost #{fmt(at)} (#{inspect(reason)})"

  defp history_text({:superseded, by, at}), do: "superseded by attempt #{by} at ##{at}"

  defp relative_text(:during), do: "during the attempt"
  defp relative_text(:after_stop), do: "after the stop"
  defp relative_text(other), do: inspect(other)

  defp reason("restart", r), do: "restart (#{inspect(r)})"
  defp reason("exit_to_menu", r), do: "exit to menu (#{inspect(r)})"
  defp reason(_, r), do: "an unmapped reason (#{inspect(r)})"

  defp objective_label(%{objective_type: t, objective_category: c}) do
    case {t, c} do
      {nil, nil} -> "objective"
      {t, nil} -> t
      {nil, c} -> "?/#{c}"
      {t, c} -> "#{t}/#{c}"
    end
  end

  defp weapon_label(%{item_name: name, item_repository_id: id})
       when is_binary(name) and name != "", do: "#{name} #{short(id)}"

  defp weapon_label(%{item_repository_id: id}), do: short(id)

  defp engine_at(nil), do: ""
  defp engine_at(t), do: " @#{t}s"

  defp short(id) when is_binary(id) and byte_size(id) > 8, do: binary_part(id, 0, 8) <> "…"
  defp short(id), do: to_string(id)

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp fmt(nil), do: "?"
  defp fmt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp fmt(other), do: to_string(other)

  defp fmt_duration(ms) when ms < 1_000, do: "#{ms} ms"
  defp fmt_duration(ms), do: "#{Float.round(ms / 1_000, 1)} s"
end
