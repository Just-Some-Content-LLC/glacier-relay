defmodule GlacierRelay.Statistics.Comparison do
  @moduledoc """
  Comparison of observed statistics across several replay results (M4-C). The unit of
  comparison is the mission attempt as the Lifecycle model bounded it; attempt rows from every
  recording are grouped by an explicit basis — any of `:recording_id`, `:instance`,
  `:scene_resource`, `:contract_id`, `:location_id`, `:difficulty_level`, `:attempt_number`,
  `:disposition`, `:mission`, `:event_family` — and each group reports observed counts with the
  evidence classes it drew on. A field a row does not carry (no paired contract, so no contract
  id or difficulty) groups under the explicit value `"not_observed"`, never under a guessed
  value, and such groups sort last.

  The comparison identifies its grouping basis and states its limitations: the counts are
  observed counts across recordings whose evidence classes it lists; a group that includes a
  non-authoritative recording or a broken attempt history is marked `mixed_evidence`; recordings are compared by their
  recorded facts only — the engine build is not part of the evidence, so comparability across
  builds is not established, and the schema versions observed are listed. Ordering is
  deterministic: rows by recording id, instance and attempt number; groups by key with unknowns
  last.
  """

  alias GlacierRelay.Statistics

  @keys [
    :recording_id,
    :instance,
    :scene_resource,
    :contract_id,
    :location_id,
    :difficulty_level,
    :attempt_number,
    :disposition,
    :mission,
    :event_family
  ]

  @doc "The supported grouping keys."
  def keys, do: @keys

  @doc """
  Compares statistics results. `opts`: `group_by` (a list of keys from `keys/0`; default
  `[:scene_resource]`).
  """
  @spec compare([Statistics.t()], keyword()) :: map()
  def compare(stats, opts \\ []) when is_list(stats) do
    group_by = Keyword.get(opts, :group_by, [:scene_resource])

    unknown = group_by -- @keys
    if unknown != [], do: raise(ArgumentError, "unsupported grouping key(s): #{inspect(unknown)}")

    rows =
      stats
      |> Enum.flat_map(&rows/1)
      |> Enum.sort_by(&{&1.recording_id, &1.instance, &1.attempt_number})

    rows = if :event_family in group_by, do: Enum.flat_map(rows, &family_rows/1), else: rows

    groups =
      rows
      |> Enum.group_by(fn row -> Enum.map(group_by, &Map.fetch!(row, &1)) end)
      |> Enum.map(fn {key, members} -> group(group_by, key, members) end)
      |> Enum.sort_by(&sort_key(group_by, &1.key))

    recordings = Enum.map(stats, &recording_summary/1) |> Enum.sort_by(& &1.id)

    %{
      schema: "glacier-relay.statistics-comparison/1",
      basis: %{
        unit: :attempt,
        group_by: group_by,
        ordering:
          "rows by recording id, instance and attempt number; groups by key, unknown values last"
      },
      recordings: recordings,
      rows: length(rows),
      groups: groups,
      limitations: limitations(stats, rows)
    }
  end

  # -- rows ------------------------------------------------------------------------------------

  defp rows(%Statistics{} = s) do
    Enum.map(s.per_attempt, fn a ->
      contract = a.contract

      %{
        recording_id: s.recording.id,
        source: s.recording.source,
        evidence_class: s.evidence.classification,
        recorder_authoritative?: s.evidence.recorder_authoritative?,
        instance: a.instance,
        attempt_number: a.number,
        scene_resource: a.scene_resource,
        scene_type: a.scene_type,
        codename_hint: a.codename_hint,
        contract_id: Map.get(contract, :contract_id) || "not_observed",
        location_id: Map.get(contract, :location_id) || "not_observed",
        difficulty_level:
          case Map.get(contract, :difficulty_level) do
            nil -> "not_observed"
            level -> to_string(level)
          end,
        contract_status: contract.status,
        mission: a.mission,
        disposition: to_string(a.disposition.value),
        history: if(a.history == :intact, do: :intact, else: :broken),
        duration_ms: a.duration_ms,
        contract_span_s: a.engine_times[:contract_span_s],
        families: a.families,
        died: a.actor_outcomes.died,
        pacified: a.actor_outcomes.pacified,
        event_family: :all
      }
    end)
  end

  defp family_rows(row) do
    for {family, count} <- Enum.sort(row.families) do
      %{row | event_family: family, families: %{family => count}}
    end
  end

  # -- groups ----------------------------------------------------------------------------------

  defp group(group_by, key, members) do
    bounded = Enum.filter(members, &is_integer(&1.duration_ms))
    spans = members |> Enum.map(& &1.contract_span_s) |> Enum.reject(&is_nil/1)

    %{
      key: Enum.zip(group_by, key) |> Map.new(),
      attempts: length(members),
      recordings: members |> Enum.map(& &1.recording_id) |> Enum.uniq() |> Enum.sort(),
      instances: members |> Enum.map(& &1.instance) |> Enum.uniq() |> length(),
      evidence_classes: frequencies(members, & &1.evidence_class),
      recorder_authoritative: Enum.count(members, & &1.recorder_authoritative?),
      history: %{
        intact: Enum.count(members, &(&1.history == :intact)),
        broken: Enum.count(members, &(&1.history == :broken))
      },
      mission: frequencies(members, & &1.mission),
      disposition: frequencies(members, & &1.disposition),
      durations: %{
        bounded: length(bounded),
        unbounded: length(members) - length(bounded),
        min_ms: bounded |> Enum.map(& &1.duration_ms) |> Enum.min(fn -> nil end),
        max_ms: bounded |> Enum.map(& &1.duration_ms) |> Enum.max(fn -> nil end),
        total_ms: bounded |> Enum.map(& &1.duration_ms) |> Enum.sum(),
        rule: "Relay clock, rise to fall, bounded attempts only"
      },
      contract_spans: %{
        observed: length(spans),
        min_s: Enum.min(spans, fn -> nil end),
        max_s: Enum.max(spans, fn -> nil end),
        rule: "paired contract session's engine clock, started to ended, when both were observed"
      },
      families: members |> Enum.map(& &1.families) |> merge_counts(),
      actor_outcomes: %{
        died: members |> Enum.map(& &1.died) |> Enum.sum(),
        pacified: members |> Enum.map(& &1.pacified) |> Enum.sum(),
        counted: :occurrences
      },
      counts_are: :observed_occurrences,
      mixed_evidence:
        Enum.any?(members, &(&1.history == :broken or not &1.recorder_authoritative?))
    }
  end

  # Groups sort by their key in the order the grouping basis names it; an unknown value sorts
  # last within its position; numbers sort numerically.
  defp sort_key(group_by, key) do
    Enum.map(group_by, fn k ->
      case Map.fetch!(key, k) do
        v when v in ["not_observed", :not_observed] -> {1, ""}
        v when is_integer(v) -> {0, v}
        v -> {0, to_string(v)}
      end
    end)
  end

  defp recording_summary(%Statistics{} = s) do
    %{
      id: s.recording.id,
      source: s.recording.source,
      evidence_class: s.evidence.classification,
      recorder_authoritative?: s.evidence.recorder_authoritative?,
      finalization: s.evidence.finalization,
      transport: s.evidence.transport,
      app_version: s.recording.app_version,
      schema_versions: s.recording.schema_versions,
      attempts: s.attempts.observed,
      attempts_with_broken_history: s.attempts.history.broken,
      relay_sequence_gaps: length(s.evidence.relay_sequence_gaps),
      recorder_gaps: length(s.evidence.recorder_gaps) + length(s.evidence.open_ended_gaps)
    }
  end

  defp limitations(stats, rows) do
    classes = frequencies(stats, & &1.evidence.classification)
    legacy = Enum.count(stats, &(&1.recording.source == :legacy))
    not_auth = Enum.count(stats, &(not &1.evidence.recorder_authoritative?))

    versions =
      stats |> Enum.flat_map(& &1.recording.schema_versions) |> Enum.uniq() |> Enum.sort()

    apps = stats |> Enum.map(& &1.recording.app_version) |> Enum.uniq() |> Enum.sort()

    [
      "observed counts over #{length(stats)} replay result(s) and #{length(rows)} row(s); evidence classes #{inspect(classes)}; not exhaustive totals",
      if(legacy > 0,
        do: "#{legacy} legacy envelope-only input(s): no transport evidence, no receipt times"
      ),
      if(not_auth > 0,
        do:
          "#{not_auth} result(s) not recorder-authoritative: their counts may miss evidence the recorder or the Relay stream lost"
      ),
      "the engine build is not part of the recorded evidence, so comparability across game builds is not established; schema versions observed #{inspect(versions)}; recorder app versions #{inspect(apps)}",
      "a group with a row that is not recorder-authoritative or whose attempt history is broken is marked mixed_evidence: its counts are observed, not comparable totals",
      "native-side drops are unknown for every recording unless reconciled outside it"
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp frequencies(list, fun),
    do: list |> Enum.frequencies_by(fun) |> Map.new(fn {k, v} -> {to_string(k), v} end)

  defp merge_counts(maps),
    do: Enum.reduce(maps, %{}, &Map.merge(&2, &1, fn _k, a, b -> a + b end))
end
