defmodule GlacierRelay.Summary do
  @moduledoc """
  An event-derived summary of what BEAM knows (M2 Stage A). Pure: built from `Lifecycle.Instance`
  values, which are themselves folded from evidence. Nothing here inspects the game; nothing here
  infers a gameplay outcome. Each line says what was observed, and "not observed" where it wasn't.
  """

  alias GlacierRelay.{Disguise, Items, Lifecycle}
  alias GlacierRelay.Lifecycle.{Attempt, Connection, ContractSession, DisguiseOccurrence, Instance, ItemOccurrence, Outcome}

  @doc "Summary data, one map per instance, oldest attempt first."
  @spec build(%{String.t() => Instance.t()}) :: [map()]
  def build(instances) when is_map(instances) do
    instances
    |> Map.values()
    |> Enum.sort_by(&first_seen/1)
    |> Enum.map(&instance/1)
  end

  @doc "The same summary as text, for a log or an IEx session."
  @spec render(%{String.t() => Instance.t()}, [map()]) :: String.t()
  def render(instances, unidentified \\ []) do
    lines =
      case build(instances) do
        [] -> ["no adapter instance has delivered an event"]
        summaries -> Enum.flat_map(summaries, &render_instance/1)
      end

    extra =
      case unidentified do
        [] ->
          []

        list ->
          ["", "connections that closed before identifying an instance: #{length(list)}"] ++
            Enum.map(list, fn c ->
              "  #{c.peer} opened #{fmt(c.opened_at)} closed #{fmt(c.closed_at)} (#{inspect(c.close_reason)})"
            end)
      end

    Enum.join(lines ++ extra, "\n")
  end

  defp instance(%Instance{} = instance) do
    %{
      adapter_instance_id: instance.id,
      received: instance.received,
      last_sequence: instance.last_sequence,
      gaps: Enum.reverse(instance.gaps),
      observation: Lifecycle.observation(instance),
      connections: instance.connections |> Enum.reverse() |> Enum.map(&connection/1),
      attempts: Enum.map(instance.attempts, &attempt(&1, instance)),
      unmatched_stops:
        Enum.map(instance.unmatched_stops, fn stray ->
          %{
            sequence: stray.observation.sequence,
            timestamp: stray.observation.timestamp,
            scene_resource: stray.payload.scene_resource
          }
        end),
      unattributed_outcomes: Enum.map(instance.unattributed_outcomes, &outcome/1),
      # Disguise occurrences with no open attempt (M2 B3): kept visible, never attached.
      unattributed_disguise_events:
        Enum.map(instance.unattributed_disguise_events, &disguise_occurrence/1),
      # Item occurrences with no open attempt (M2 B4): kept visible, never attached.
      unattributed_item_events: Enum.map(instance.unattributed_item_events, &item_occurrence/1),
      # Contract lifecycle (M2 B2): every session Glacier reported, paired or not, plus what
      # could not be correlated and every observable discrepancy.
      contract_sessions: Enum.map(instance.contract_sessions, &contract_session/1),
      unpaired_contract_sessions:
        instance.contract_sessions
        |> Enum.filter(&is_nil(&1.attempt_number))
        |> Enum.map(&contract_session/1),
      unmatched_contract_ends:
        Enum.map(instance.unmatched_contract_ends, fn stray ->
          %{
            sequence: stray.observation.sequence,
            timestamp: stray.observation.timestamp,
            contract_session_id: stray.payload.contract_session_id,
            reason: stray.payload.reason,
            reason_kind: stray.payload.reason_kind
          }
        end),
      anomalies: instance.anomalies
    }
  end

  defp attempt(%Attempt{} = attempt, %Instance{contract_sessions: sessions} = instance) do
    paired =
      Enum.find(sessions, fn c ->
        c.attempt_number == attempt.number and c.contract_session_id == attempt.contract_session_id
      end)

    %{
      number: attempt.number,
      scene_resource: attempt.scene_resource,
      scene_type: attempt.scene_type,
      codename_hint: attempt.codename_hint,
      mission: attempt.mission,
      open?: attempt.mission == :playing,
      playing_at: attempt.playing.timestamp,
      playing_sequence: attempt.playing.sequence,
      stopped_at: attempt.stopped && attempt.stopped.timestamp,
      stopped_sequence: attempt.stopped && attempt.stopped.sequence,
      duration_ms: Lifecycle.duration_ms(attempt),
      superseded_by: attempt.superseded_by,
      interrupted?: attempt.interruptions != [],
      interruptions: attempt.interruptions,
      game_session_id: %{
        playing: attempt.playing.game_session_id,
        stopped: attempt.stopped && attempt.stopped.game_session_id
      },
      stopped_scene: attempt.stopped_scene,
      outcomes: Enum.map(attempt.outcomes, &outcome/1),
      outcome_counts: outcome_counts(attempt.outcomes),
      # BEAM-derived correlation to a Glacier contract session, and the disposition derived
      # only from that session's contract.ended (M2 B2).
      contract_session_id: attempt.contract_session_id,
      contract_paired_by: attempt.contract_paired_by,
      contract_candidates: attempt.contract_candidates,
      contract: paired && contract_session(paired),
      disposition: attempt.disposition,
      # Disguise (M2 B3): the occurrences as facts, then BEAM's labelled reading of them.
      disguise_events: Enum.map(attempt.disguise_events, &disguise_occurrence/1),
      disguise: Disguise.derive(attempt, instance),
      # Items (M2 B4): the occurrences as facts, then the direct counts per definition.
      item_events: Enum.map(attempt.item_events, &item_occurrence/1),
      items: Items.derive(attempt, instance)
    }
  end

  defp item_occurrence(%ItemOccurrence{} = o) do
    p = o.payload

    %{
      type: o.type,
      sequence: o.sequence,
      timestamp: o.timestamp,
      source: p.source,
      engine_event: p.engine_event,
      item_repository_id: p.item_repository_id,
      item_instance_id: p.item_instance_id,
      item_name: p.item_name,
      item_type: p.item_type,
      online_traits: p.online_traits,
      contract_session_id: p.contract_session_id,
      engine_timestamp_s: p.engine_timestamp_s
    }
  end

  defp disguise_occurrence(%DisguiseOccurrence{} = o) do
    p = o.payload

    %{
      type: o.type,
      kind: o.kind,
      sequence: o.sequence,
      timestamp: o.timestamp,
      source: p.source,
      engine_event: p.engine_event,
      disguise_repository_id: p.disguise_repository_id,
      contract_session_id: p.contract_session_id,
      engine_timestamp_s: p.engine_timestamp_s
    }
  end

  defp contract_session(%ContractSession{} = c) do
    p = c.started_payload
    e = c.ended_payload

    %{
      contract_session_id: c.contract_session_id,
      contract_id: p.contract_id,
      location_id: p.location_id,
      contract_type: p.contract_type,
      difficulty_level: p.difficulty_level,
      starting_disguise_repository_id: p.starting_disguise_repository_id,
      is_hitman_suit: p.is_hitman_suit,
      started_sequence: c.started.sequence,
      started_at: c.started.timestamp,
      started_engine_timestamp_s: p.engine_timestamp_s,
      ended_sequence: c.ended && c.ended.sequence,
      ended_at: c.ended && c.ended.timestamp,
      ended_engine_timestamp_s: e && e.engine_timestamp_s,
      reason: e && e.reason,
      reason_kind: e && e.reason_kind,
      attempt_number: c.attempt_number,
      paired_by: c.paired_by,
      ended_relative: c.ended_relative,
      source: p.source
    }
  end

  defp outcome(%Outcome{} = o) do
    p = o.payload

    %{
      kind: o.kind,
      sequence: o.sequence,
      timestamp: o.timestamp,
      source: p.source,
      actor_name: p.actor_name,
      repository_id: p.repository_id,
      engine_actor_id: p.engine_actor_id,
      actor_type: p.actor_type,
      is_target: p.is_target,
      death_type: p.death_type,
      death_context: p.death_context,
      accident: p.accident,
      kill_class: p.kill_class,
      method_broad: p.method_broad,
      method_strict: p.method_strict,
      damage_events: p.damage_events,
      item_repository_id: p.item_repository_id,
      engine_timestamp_s: p.engine_timestamp_s
    }
  end

  # Conservative counts of what the engine recorded. Each outcome is counted once; a pacified
  # then died actor contributes to both kinds. No unique-actor count, no score, no attribution.
  defp outcome_counts(outcomes) do
    for kind <- [:died, :pacified], into: %{} do
      of_kind = Enum.filter(outcomes, &(&1.kind == kind))

      {kind,
       %{
         total: length(of_kind),
         target: Enum.count(of_kind, & &1.payload.is_target),
         non_target: Enum.count(of_kind, &(not &1.payload.is_target)),
         by_actor_type: Enum.frequencies_by(of_kind, & &1.payload.actor_type),
         by_death_context: Enum.frequencies_by(of_kind, & &1.payload.death_context),
         accidents: Enum.count(of_kind, & &1.payload.accident)
       }}
    end
  end

  defp connection(%Connection{} = c) do
    %{
      peer: c.peer,
      opened_at: c.opened_at,
      identified_at: c.identified_at,
      closed_at: c.closed_at,
      close_reason: c.close_reason
    }
  end

  defp render_instance(s) do
    header =
      "adapter #{s.adapter_instance_id}: #{s.received} event(s), last sequence #{s.last_sequence}, " <>
        "gaps #{inspect(s.gaps)}, observation #{s.observation}"

    connections =
      Enum.map(s.connections, fn c ->
        closed =
          case c.closed_at do
            nil -> "still open"
            at -> "closed #{fmt(at)} (#{inspect(c.close_reason)})"
          end

        "  connection #{c.peer}: opened #{fmt(c.opened_at)}, identified #{fmt(c.identified_at)}, #{closed}"
      end)

    attempts =
      case s.attempts do
        [] -> ["  no mission attempt observed"]
        list -> Enum.flat_map(list, &render_attempt/1)
      end

    strays =
      Enum.map(s.unmatched_stops, fn stray ->
        "  mission.stopped ##{stray.sequence} at #{stray.timestamp} with no open attempt (#{stray.scene_resource})"
      end)

    unattributed =
      Enum.map(s.unattributed_outcomes, fn o ->
        "  #{render_outcome(o)} with no open attempt"
      end)

    unpaired =
      Enum.map(s.unpaired_contract_sessions, fn c ->
        "  contract session #{c.contract_session_id} (#{render_contract_facts(c)}) not correlated to any attempt" <>
          render_contract_end(c)
      end)

    unmatched_ends =
      Enum.map(s.unmatched_contract_ends, fn e ->
        "  contract.ended ##{e.sequence} for session #{e.contract_session_id} (#{render_reason(e.reason_kind, e.reason)}) with no open contract session"
      end)

    unattributed_disguise =
      Enum.map(s.unattributed_disguise_events, fn o ->
        "  disguise #{render_disguise_occurrence(o)} with no open attempt"
      end)

    unattributed_items =
      Enum.map(s.unattributed_item_events, fn o ->
        "  item #{render_item_occurrence(o)} with no open attempt"
      end)

    anomalies = Enum.map(s.anomalies, &("  anomaly: " <> render_anomaly(&1)))

    [header] ++ connections ++ attempts ++ strays ++ unattributed ++ unattributed_disguise ++ unattributed_items ++ unpaired ++ unmatched_ends ++ anomalies
  end

  defp render_attempt(a) do
    name =
      if a.codename_hint in [nil, ""],
        do: a.scene_resource,
        else: "#{a.codename_hint} (#{a.scene_resource})"

    ending =
      case a.mission do
        :stopped ->
          "stopped #{a.stopped_at} (##{a.stopped_sequence}), duration #{fmt_duration(a.duration_ms)}"

        :playing ->
          "stop not observed; last known playing"

        :superseded ->
          "stop not observed; superseded by attempt #{a.superseded_by}"
      end

    interrupted =
      case a.interruptions do
        [] ->
          ""

        list ->
          "; observation lost " <>
            Enum.map_join(list, ", ", fn i -> "#{fmt(i.at)} (#{inspect(i.reason)})" end)
      end

    line =
      "  attempt #{a.number}: #{name}: playing #{a.playing_at} (##{a.playing_sequence}), #{ending}#{interrupted}"

    outcome_lines =
      case a.outcomes do
        [] ->
          ["    actor outcomes (engine telemetry): none observed"]

        outcomes ->
          ["    actor outcomes (engine telemetry): " <> render_counts(a.outcome_counts)] ++
            Enum.map(outcomes, &("    " <> render_outcome(&1)))
      end

    [line] ++ render_attempt_contract(a) ++ outcome_lines ++ render_attempt_disguise(a) ++ render_attempt_items(a)
  end

  # One line per attempt (M2 B4, design section 38.6): direct counts of the item occurrences
  # Glacier reported, each type broken down per definition in first-seen order, with the engine's
  # display names as it sent them and the id where it sent none; then the history. Nothing is
  # paired. The deferred vocabulary (drops, destroys) is not shown at all. Words that never appear
  # here: inventory contents, holding, carried, owns, recovered, lost, throws.
  defp render_attempt_items(a) do
    i = a.items

    if i.occurrences == 0 do
      ["    items (engine telemetry): none observed in the attempt"]
    else
      per_type =
        Enum.map_join([{:picked_up, "picked up"}, {:thrown, "thrown"}, {:removed_from_inventory, "removed from inventory"}], "; ", fn {type, label} ->
          "#{label} #{Map.fetch!(i, type)}#{render_item_breakdown(i.by_definition, type)}"
        end)

      definitions = "#{length(i.definitions_used)} definition#{plural(length(i.definitions_used))}"

      history =
        case i.history do
          :complete -> "history intact"
          {:incomplete, reasons} -> "history broken: " <> Enum.map_join(reasons, ", ", &render_history_reason/1)
        end

      ["    items (engine telemetry): #{per_type}; #{definitions}; #{history}"]
    end
  end

  defp render_item_breakdown(rows, type) do
    case Enum.filter(rows, &(Map.fetch!(&1, type) > 0)) do
      [] ->
        ""

      used ->
        " — " <>
          Enum.map_join(used, ", ", fn row ->
            n = Map.fetch!(row, type)
            "#{render_item_label(row)}#{if n > 1, do: " ×#{n}", else: ""}"
          end)
    end
  end

  # The engine's display string as sent, or the short id when it sent none.
  defp render_item_label(%{item_name: name}) when is_binary(name) and name != "", do: name
  defp render_item_label(%{item_repository_id: id}), do: short(id)

  defp render_item_occurrence(o) do
    at = if o.engine_timestamp_s, do: " @#{o.engine_timestamp_s}s", else: ""

    what =
      case o.type do
        :picked_up -> "picked up"
        :thrown -> "thrown"
        :removed_from_inventory -> "removed from inventory"
      end

    "#{what} #{short(o.item_repository_id)} ##{o.sequence}#{at}"
  end

  # Two lines per attempt (M2 B3): the disguise occurrences Glacier reported, in order, then the
  # derived view with its uncertainty on the same line. Words that never appear: clean, undetected,
  # safe, Silent Assassin. An earlier episode is rendered with its own facts, never as the worn
  # outfit's standing.
  defp render_attempt_disguise(a) do
    contract_says =
      case a.contract do
        %{starting_disguise_repository_id: id, is_hitman_suit: suit?} ->
          "contract.started says #{short(id)}#{if suit?, do: " (hitman suit)", else: ""}; "

        _ ->
          ""
      end

    observed =
      case a.disguise_events do
        [] ->
          "    disguises (engine telemetry): #{contract_says}none observed in the attempt"

        events ->
          "    disguises (engine telemetry): #{contract_says}" <>
            Enum.map_join(events, "; ", &render_disguise_occurrence/1)
      end

    d = a.disguise

    worn =
      case d.worn do
        :not_observed -> "worn: not observed"
        %{repository_id: id, since_sequence: seq} -> "worn #{short(id)}#{suit_note(id, a.contract)} since ##{seq}"
      end

    standing = "worn outfit: " <> render_standing(d)

    counts = "#{d.changes} change#{plural(d.changes)}, #{length(d.used)} definition#{plural(length(d.used))} used"

    history =
      case d.history do
        # "complete" is reserved: it must never appear in a summary (it would read as mission completion).
        :complete -> "history intact"
        {:incomplete, reasons} -> "history broken: " <> Enum.map_join(reasons, ", ", &render_history_reason/1)
      end

    anomalies =
      case d.anomalies do
        [] -> ""
        list -> "; anomalies: " <> Enum.map_join(list, ", ", &inspect/1)
      end

    derived =
      "    disguise state (BEAM-derived): #{worn}; #{standing}; #{counts}; #{history}#{anomalies}"

    [observed, derived]
  end

  defp render_disguise_occurrence(o) do
    at = if o.engine_timestamp_s, do: " @#{o.engine_timestamp_s}s", else: ""

    what =
      case {o.type, o.kind} do
        {:equipped, :initial} -> "initial"
        {:equipped, :change} -> "change →"
        {:compromised, _} -> "compromised"
        {:compromise_cleared, _} -> "cleared"
      end

    "#{what} #{short(o.disguise_repository_id)} ##{o.sequence}#{at}"
  end

  defp render_standing(%{worn: :not_observed}), do: "not observed"

  defp render_standing(%{worn_standing: :unknown, standing_cut: %{cut: cut, standing_before: before}}) do
    where =
      case cut do
        {:gap, expected, got} -> "gap #{expected}→#{got} inside this wear"
        {:interruption, at, reason} -> "observation lost #{fmt(at)} (#{inspect(reason)}) inside this wear"
      end

    "unknown (#{where}; before it: #{render_plain_standing(before)})"
  end

  defp render_standing(%{worn_standing: :unknown, standing_reason: :latest_names_other}),
    do: "unknown (the latest statement in this wear names another outfit)"

  defp render_standing(%{worn_standing: :unknown, standing_reason: :earlier_compromise, compromise_episodes: episodes, worn: %{since_sequence: since}}) do
    earlier =
      episodes
      |> Enum.filter(fn e -> hd(e.compromised_sequences) < since end)
      |> Enum.map_join(", ", fn e ->
        "#{short(e.repository_id)} ##{hd(e.compromised_sequences)}" <>
          if(e.cleared_sequence, do: " cleared ##{e.cleared_sequence}", else: " episode open")
      end)

    "unknown (compromise observed earlier in this attempt: #{earlier}; not evidenced for this wear)"
  end

  defp render_standing(%{worn_standing: standing}), do: render_plain_standing(standing)

  defp render_plain_standing(:not_observed), do: "no compromise observed"
  defp render_plain_standing(:compromised), do: "compromised"
  defp render_plain_standing(:cleared), do: "cleared"
  defp render_plain_standing(:unknown), do: "unknown"

  defp render_history_reason({:gap, expected, got}), do: "gap #{expected}→#{got}"
  defp render_history_reason({:interruption, at, reason}), do: "observation lost #{fmt(at)} (#{inspect(reason)})"
  defp render_history_reason({:superseded, by, at}), do: "superseded by attempt #{by} at ##{at}"

  # "suit" only as a labelled id equality with the paired session's starting suit.
  defp suit_note(id, %{starting_disguise_repository_id: id, is_hitman_suit: true}), do: " (equals the starting suit id)"
  defp suit_note(_id, _contract), do: ""

  defp short(id) when is_binary(id) and byte_size(id) > 8, do: binary_part(id, 0, 8) <> "…"
  defp short(id), do: to_string(id)

  defp plural(1), do: ""
  defp plural(_), do: "s"

  # Two lines per attempt: what Glacier said about the correlated contract session (observed
  # semantic occurrences), then what BEAM derived from it and how (correlation and disposition).
  # The words "failed" and "completed" never appear for a restart or an exit; "not observed" is
  # the answer whenever the evidence is missing.
  defp render_attempt_contract(a) do
    contract =
      case {a.contract_session_id, a.contract_candidates} do
        {nil, []} ->
          "    contract (engine telemetry): not observed"

        {nil, candidates} ->
          "    contract (engine telemetry): #{length(candidates)} sessions started before this rise; " <>
            "none correlated (ambiguous): #{Enum.join(candidates, ", ")}"

        {id, _} ->
          "    contract (engine telemetry): session #{id}" <> render_attempt_contract_detail(a)
      end

    derived =
      case {a.contract_session_id, a.disposition} do
        {nil, _} ->
          "    disposition (BEAM-derived): not observed"

        {_, :not_observed} ->
          "    disposition (BEAM-derived, session paired by #{a.contract_paired_by}): not observed; contract end not seen"

        {_, disposition} ->
          "    disposition (BEAM-derived, session paired by #{a.contract_paired_by}): #{render_disposition(disposition)}"
      end

    [contract, derived]
  end

  defp render_attempt_contract_detail(%{contract: nil}), do: ""
  defp render_attempt_contract_detail(%{contract: c}), do: ", #{render_contract_facts(c)}" <> render_contract_end(c)

  defp render_contract_facts(c) do
    "#{c.location_id}, #{c.contract_type}, difficulty #{c.difficulty_level}; started ##{c.started_sequence}" <>
      if(c.started_engine_timestamp_s, do: " @#{c.started_engine_timestamp_s}s", else: "")
  end

  defp render_contract_end(%{ended_sequence: nil}), do: "; end not observed"

  defp render_contract_end(c) do
    "; ended ##{c.ended_sequence} by #{render_reason(c.reason_kind, c.reason)}" <>
      if(c.ended_engine_timestamp_s,
        do: " @#{c.ended_engine_timestamp_s}s on the contract clock",
        else: ""
      )
  end

  defp render_reason("restart", reason), do: "restart (#{inspect(reason)})"
  defp render_reason("exit_to_menu", reason), do: "exit to menu (#{inspect(reason)})"
  defp render_reason(_other, reason), do: "an unmapped reason (#{inspect(reason)})"

  defp render_disposition(:restarted), do: "restarted"
  defp render_disposition(:exited_to_menu), do: "exited to menu"
  defp render_disposition({:ended, reason}), do: "ended, reason #{inspect(reason)}"

  defp render_anomaly(%{kind: :contract_session_id_mismatch} = x),
    do:
      "attempt #{x.attempt} rose with game_session_id #{x.rise_game_session_id} but was paired (by #{x.paired_by}) " <>
        "with contract session #{x.contract_session_id}; pairing kept, both ids preserved"

  defp render_anomaly(%{kind: :contract_pairing_ambiguous} = x),
    do: "attempt #{x.attempt} had #{length(x.candidates)} candidate contract sessions; none paired"

  defp render_anomaly(%{kind: :contract_end_ambiguous} = x),
    do: "contract.ended ##{x.sequence} matched #{length(x.open_sessions)} open sessions with id #{x.contract_session_id}; kept unmatched"

  defp render_anomaly(other), do: inspect(other)

  defp render_counts(counts) do
    Enum.map_join([:died, :pacified], "; ", fn kind ->
      c = counts[kind]
      types = Enum.map_join(Enum.sort(c.by_actor_type), ", ", fn {t, n} -> "#{n} #{t}" end)
      contexts = Enum.map_join(Enum.sort(c.by_death_context), ", ", fn {t, n} -> "#{t} #{n}" end)

      "#{c.total} #{kind}" <>
        if(c.total > 0,
          do: " (#{c.target} target, #{c.non_target} non-target; #{types}; context #{contexts})",
          else: ""
        )
    end)
  end

  defp render_outcome(o) do
    target = if o.is_target, do: "target", else: "non-target"
    item = if o.item_repository_id, do: " item #{o.item_repository_id}", else: ""
    at = if o.engine_timestamp_s, do: " @#{o.engine_timestamp_s}s", else: ""

    "##{o.sequence} #{o.kind} #{o.actor_name} (#{o.actor_type}, #{target}): #{o.death_type}/#{o.death_context} " <>
      "#{o.kill_class} #{o.method_broad}#{if o.method_strict != "", do: "/" <> o.method_strict, else: ""} " <>
      "[#{Enum.join(o.damage_events, ",")}]#{item}#{at} (#{o.source})"
  end

  defp first_seen(%Instance{attempts: [first | _]}), do: first.playing.timestamp
  defp first_seen(%Instance{last_event: %{timestamp: ts}}), do: ts
  defp first_seen(%Instance{}), do: ""

  defp fmt(nil), do: "?"
  defp fmt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp fmt(other), do: to_string(other)

  defp fmt_duration(nil), do: "unknown"
  defp fmt_duration(ms) when ms < 1_000, do: "#{ms} ms"
  defp fmt_duration(ms), do: "#{Float.round(ms / 1_000, 1)} s"
end
