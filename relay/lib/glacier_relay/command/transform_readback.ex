defmodule GlacierRelay.Command.TransformReadback do
  @moduledoc """
  M6-F: the pure decoder of the exact-transform read-backs — `relay.inspect.candidate_transform`
  v1's snapshot and `candidate.transform.set` v1's result — and the declared later-observation
  classification (`docs/design/M6D2_NEXT_STEP_DESIGN.md` sections 12.4, 12.7 and 12.8).

  Every word group decodes strictly through `Command.TransformWords`; a field object whose status
  is not `observed` decodes to its status, so a missing value is never a default, and a text that
  does not match the grammar decodes to `:invalid`, never a partial value. Nothing here is an
  independent observation of the engine: a later classification is a sampled state at the
  inspection's frame, never proof of continuous behaviour or of which system caused a change.

  The later classes (`classify_later/3`): `:held` (the later world group is bit-equal to the
  requested group), `:returned_to_baseline` (bit-equal to the preimage group), `:near_target` and
  `:near_baseline` (within the declared tolerance but not bit-equal: drift within tolerance, never
  held or returned), `:drifted` (neither), `:indeterminate` (the later cache is dirty: the stored
  words establish nothing), `:unavailable` (no later words).
  """

  alias GlacierRelay.Command.{CandidateReadback, TransformWords}

  @doc "The inspection's exact snapshot fields for one prefix (`\"cand\"` or `\"hero\"`)."
  def snapshot(observed, prefix) when is_map(observed) and is_binary(prefix) do
    %{
      world_words: words(observed["#{prefix}_world_words"], :world),
      local_words: words(observed["#{prefix}_local_words"], :local),
      dirty: CandidateReadback.field(observed["#{prefix}_dirty"], :bool),
      parent: CandidateReadback.field(observed["#{prefix}_parent"], :parent),
      world: CandidateReadback.field(observed["#{prefix}_world"], :vec3),
      local: CandidateReadback.field(observed["#{prefix}_local"], :local),
      spatial_flags: CandidateReadback.field(observed["#{prefix}_spatial_flags"], :spatial_flags)
    }
  end

  @doc "Decodes the whole `relay.inspect.candidate_transform` read-back."
  def decode_inspection(observed) when is_map(observed) do
    %{
      generation_fresh: CandidateReadback.field(observed["generation_fresh"], :text),
      targets: CandidateReadback.field(observed["targets"], :text),
      snapshot_version: CandidateReadback.field(observed["snapshot_version"], :integer),
      cand_brick_present: CandidateReadback.field(observed["cand_brick_present"], :bool),
      cand_index_check: CandidateReadback.field(observed["cand_index_check"], :text),
      cand_resolved: CandidateReadback.field(observed["cand_resolved"], :bool),
      cand_hitman5: CandidateReadback.field(observed["cand_hitman5"], :bool),
      cand_id_match: CandidateReadback.field(observed["cand_id_match"], :bool),
      cand_distinct: CandidateReadback.field(observed["cand_distinct"], :bool),
      cand_brick_owner: CandidateReadback.field(observed["cand_brick_owner"], :text),
      cand_spatial: CandidateReadback.field(observed["cand_spatial"], :bool),
      cand_spatial_distinct: CandidateReadback.field(observed["cand_spatial_distinct"], :bool),
      registry_slots: CandidateReadback.field(observed["registry_slots"], :slots),
      cand_in_registry: CandidateReadback.field(observed["cand_in_registry"], :bool),
      candidate: snapshot(observed, "cand"),
      hero_entity_id: CandidateReadback.field(observed["hero_entity_id"], :hex16),
      hero_flags: CandidateReadback.field(observed["hero_flags"], :integer),
      hero: snapshot(observed, "hero"),
      reads_on_frame: CandidateReadback.field(observed["reads_on_frame"], :bool)
    }
  end

  @doc "Decodes the `candidate.transform.set` result's read-back: the three exact groups and the facts."
  def decode_apply(observed) when is_map(observed) do
    %{
      mode: CandidateReadback.field(observed["mode"], :text),
      generation_fresh: CandidateReadback.field(observed["generation_fresh"], :text),
      generation_post: CandidateReadback.field(observed["generation_post"], :text),
      preimage: %{
        world_words: words(observed["preimage_world_words"], :world),
        local_words: words(observed["preimage_local_words"], :local),
        parent: CandidateReadback.field(observed["preimage_parent"], :parent),
        dirty: CandidateReadback.field(observed["preimage_dirty"], :bool)
      },
      requested_world_words: words(observed["requested_world_words"], :world),
      postimage: %{
        world_words: words(observed["postimage_world_words"], :world),
        local_words: words(observed["postimage_local_words"], :local),
        parent: CandidateReadback.field(observed["postimage_parent"], :parent),
        dirty: CandidateReadback.field(observed["postimage_dirty"], :bool)
      },
      post_same_entity: CandidateReadback.field(observed["post_same_entity"], :bool),
      world_match: CandidateReadback.field(observed["world_match"], :text),
      local_match: CandidateReadback.field(observed["local_match"], :text),
      hero_control: CandidateReadback.field(observed["hero_control"], :text),
      restore_of: CandidateReadback.field(observed["restore_of"], :text),
      restore_facts: restore_facts(observed["restore_facts"]),
      setter_called: CandidateReadback.field(observed["setter_called"], :bool),
      apply_log: CandidateReadback.field(observed["apply_log"], :text),
      invocation: CandidateReadback.field(observed["invocation"], :text),
      effect: CandidateReadback.field(observed["effect"], :text),
      precondition_ok: CandidateReadback.field(observed["precondition_ok"], :bool),
      precondition_reasons: CandidateReadback.field(observed["precondition_reasons"], :text),
      budget_remaining: CandidateReadback.field(observed["budget_remaining"], :integer),
      cand_distinct: CandidateReadback.field(observed["cand_distinct"], :bool),
      cand_spatial_distinct: CandidateReadback.field(observed["cand_spatial_distinct"], :bool),
      registry_slots: CandidateReadback.field(observed["registry_slots"], :slots),
      reduced: observed["observed_reduced"] == true
    }
  end

  @doc "A word-group field: `{:ok, [word]}`, `{:invalid, text}`, `{:unobserved, status}` or `:missing`."
  def words(nil, _kind), do: :missing

  def words(%{"status" => "observed", "value" => value}, kind) when is_binary(value) do
    decoded =
      if kind == :world,
        do: TransformWords.decode_world(value),
        else: TransformWords.decode_local(value)

    case decoded do
      {:ok, list} -> {:ok, list}
      {:error, _} -> {:invalid, value}
    end
  end

  def words(%{"status" => status}, _kind) when is_binary(status), do: {:unobserved, status}
  def words(_other, _kind), do: :missing

  @restore_keys ~w(world local parent dirty snapshot within_tol)

  @doc "The packed restore facts `world=B,local=B,parent=B,dirty=B,snapshot=B,within_tol=B` as a map of booleans."
  def restore_facts(nil), do: :missing

  def restore_facts(%{"status" => "observed", "value" => value}) when is_binary(value) do
    pairs = String.split(value, ",")

    with true <- length(pairs) == length(@restore_keys),
         parsed <-
           Enum.map(pairs, fn pair ->
             case String.split(pair, "=") do
               [k, "0"] -> {k, false}
               [k, "1"] -> {k, true}
               _ -> :error
             end
           end),
         false <- :error in parsed,
         true <- Enum.map(parsed, &elem(&1, 0)) == @restore_keys do
      {:ok, Map.new(parsed, fn {k, v} -> {String.to_existing_atom(k), v} end)}
    else
      _ -> {:invalid, value}
    end
  end

  def restore_facts(%{"status" => status}) when is_binary(status), do: {:unobserved, status}
  def restore_facts(_), do: :missing

  @doc """
  The later-observation class of a later snapshot against a plan's exact groups. `later` is a
  snapshot map (`snapshot/2`), `preimage` and `target` are word lists. Bit equality decides
  `:held` and `:returned_to_baseline`; the declared tolerance decides `:near_*`; a dirty later
  cache is `:indeterminate`; missing words are `:unavailable`. A sampled state, never a cause.
  """
  def classify_later(later, preimage, target, tolerance \\ TransformWords.tolerance())
      when is_map(later) and is_list(preimage) and is_list(target) do
    case {later.world_words, later.dirty} do
      {{:ok, _}, {:ok, true}} ->
        :indeterminate

      {{:ok, words}, {:ok, false}} ->
        cond do
          TransformWords.equal?(words, target) -> :held
          TransformWords.equal?(words, preimage) -> :returned_to_baseline
          TransformWords.within_tolerance?(words, target, tolerance) -> :near_target
          TransformWords.within_tolerance?(words, preimage, tolerance) -> :near_baseline
          true -> :drifted
        end

      _ ->
        :unavailable
    end
  end

  @doc """
  The control comparison of two snapshots of the local hero (an earlier and a later inspection):
  `:unchanged` (bit-equal world, parent-relative and parent), `:within_tolerance`, `:changed`,
  `:unavailable`. Recorded and judged under the declared policy, never attributed to the
  candidate's setter.
  """
  def classify_control(before, later, tolerance \\ TransformWords.tolerance())
      when is_map(before) and is_map(later) do
    with {:ok, w0} <- before.world_words,
         {:ok, w1} <- later.world_words,
         {:ok, l0} <- before.local_words,
         {:ok, l1} <- later.local_words,
         {:ok, p0} <- before.parent,
         {:ok, p1} <- later.parent do
      cond do
        w0 == w1 and l0 == l1 and p0 == p1 ->
          :unchanged

        l0 == l1 and p0 == p1 and TransformWords.within_tolerance?(w0, w1, tolerance) ->
          :within_tolerance

        true ->
          :changed
      end
    else
      _ -> :unavailable
    end
  end
end
