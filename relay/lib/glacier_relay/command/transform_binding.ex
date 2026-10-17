defmodule GlacierRelay.Command.TransformBinding do
  @moduledoc """
  M6-F1a binding correction: the evidence the issuing authority itself requires before it accepts
  a `candidate.transform.set` v1 command (`docs/design/M6F_TRANSFORM_CONTROL.md`, the corrective
  review record). Pure functions over the authority's **verified journal** (`Journal.read/1`), its
  in-memory records and its current link; called only from inside `Command.Authority`, never
  through a public facade, and never trusting caller-supplied binding metadata.

  A lift (`lift/3`) needs one specific completed `relay.inspect.candidate_transform` v1, named by
  its id — never an implicit "latest" inspection. A restoration (`restore/4`) needs the journal's
  plan of the original lift (`Command.TransformRestore.plan_journal/3`) and one specific later
  inspection. The inspection qualifies (`qualify/2`) only when, in the journal: exactly one
  acceptance, transmission, acknowledgement and terminal, in order, no unknown outcome or
  refinement; the terminal `applied`; the in-memory record agreeing; the inspection's link the
  current link, journaled as identified with the current adapter and token-verified; the
  terminal's mission generation and the snapshot's fresh generation the command's expected one;
  its age — measured on the journal's own monotonic clock, never a caller's claim — within the
  configured bound; the compiled target tuple (brick `007c57a6ea581f8c`, entity
  `feede715906f747f`), snapshot version 1, reads on one frame, the candidate present, in range,
  resolved, a hero, its authored id, owned by the compiled brick, distinct from the local hero,
  with a distinct spatial interface and in no registry slot; the local hero's control groups
  observed; the candidate's word groups strictly decoded and finite, its parent observed and its
  cache clean. An unobserved safety field never qualifies.

  The canonical parameters are derived from that evidence; a group the caller also supplied must
  equal it exactly (`{:expectation_mismatch, key}` otherwise). The binding returned is what the
  authority journals with the accepted command. It is evidence of the candidate's exact words at
  the inspection's frame, not proof they are unchanged since: the native applying-frame
  expectation gate stays the final state-drift check.
  """

  alias GlacierRelay.Command.{TransformReadback, TransformRestore, TransformWords}

  @inspection "relay.inspect.candidate_transform"
  @brick "007c57a6ea581f8c"
  @entity "feede715906f747f"
  @snapshot_version 1
  @lift_keys ~w(expect_world expect_local expect_parent)
  @restore_keys ~w(target_world expect_world expect_local expect_parent restore_of)

  @doc """
  The lift's canonical parameters and binding. `ctx`: `:journal` (a verified `Journal.read/1`
  result), `:now_mono_ms` (the journal's clock now), `:max_age_ms`, `:link` (the current link:
  `generation`, `adapter_instance_id`, `token_verified`), `:mission_generation` (the command's
  expected generation), `:records` (the authority's in-memory records by id). `supplied` holds
  the expectation groups the caller gave, if any. Returns `{:ok, params, binding}` or
  `{:error, reason}`.
  """
  def lift(ctx, inspection_id, supplied) when is_map(ctx) and is_map(supplied) do
    with {:ok, q} <- qualify(ctx, inspection_id),
         canonical = expectations(q),
         :ok <- compare(supplied, canonical, @lift_keys) do
      {:ok, Map.put(canonical, "mode", "lift"), binding_of(q)}
    end
  end

  @doc """
  The restoration's canonical parameters and binding: the plan of the lift `restore_of` from the
  verified journal (cross-checked with its in-memory record), the command's expected generation
  equal to the plan's, then one later qualifying inspection on the plan's adapter whose words
  hold the lift's postimage. `{:error, :already_at_baseline}` means the engine already shows the
  preimage and nothing is to be submitted; drift, a dirty cache or a changed parent stop
  issuance with their own reasons. `ctx` as `lift/3`.
  """
  def restore(ctx, restore_of, inspection_id, supplied)
      when is_map(ctx) and is_binary(restore_of) and is_map(supplied) do
    with {:ok, plan} <-
           TransformRestore.plan_journal(ctx.journal, restore_of,
             record: Map.get(ctx.records, restore_of)
           ),
         true <-
           plan.mission_generation == ctx.mission_generation or
             {:error, {:generation_mismatch, plan.mission_generation}},
         {:ok, q} <- qualify(ctx, inspection_id),
         true <- q.adapter == plan.adapter_instance_id or {:error, :inspection_adapter_mismatch},
         true <-
           (is_integer(q.frame) and is_integer(plan.frame) and q.frame > plan.frame) or
             {:error, :inspection_not_later},
         :ok <- TransformRestore.state_matches(q.world, false, q.parent, plan),
         canonical =
           Map.merge(expectations(q), %{
             "target_world" => plan.target_world,
             "restore_of" => restore_of
           }),
         :ok <- compare(supplied, canonical, @restore_keys) do
      {:ok, Map.put(canonical, "mode", "restore"),
       Map.merge(binding_of(q), %{
         "restore_of" => restore_of,
         "plan_journal_seq" => plan.journal_seq,
         "command_frame" => plan.frame,
         "target_world" => plan.target_world,
         "later_class" => "held"
       })}
    end
  end

  @doc """
  Qualifies one specific completed exact inspection from the verified journal (see the module
  documentation). Returns `{:ok, facts}` or `{:error, reason}`.
  """
  def qualify(ctx, inspection_id) do
    entries = ctx.journal.entries

    with true <- is_binary(inspection_id) or {:error, :inspection_command_id_required},
         {:ok, a, t} <- locate(entries, inspection_id),
         true <- t["status"] == "applied" or {:error, {:inspection_not_applied, t["status"]}},
         :ok <- cross_check(Map.get(ctx.records, inspection_id), a, t),
         true <-
           (is_integer(ctx.link.generation) and a["link_generation"] == ctx.link.generation) or
             {:error, :inspection_link_not_current},
         {:ok, adapter} <- adapter_identity(entries, a["link_generation"]),
         true <-
           adapter == ctx.link.adapter_instance_id or {:error, :inspection_adapter_mismatch},
         true <-
           (ctx.link.token_verified == true and
              token_verified?(entries, a["link_generation"], adapter)) or
             {:error, :inspection_link_not_token_verified},
         observed = if(is_map(t["observed"]), do: t["observed"], else: %{}),
         d = TransformReadback.decode_inspection(observed),
         true <-
           (is_binary(ctx.mission_generation) and
              t["mission_generation"] == ctx.mission_generation and
              d.generation_fresh == {:ok, ctx.mission_generation}) or
             {:error, :inspection_generation_mismatch},
         {:ok, age} <- age(t, ctx),
         :ok <- target_qualified(d),
         {:ok, world} <- group(d.candidate.world_words, :world),
         {:ok, local} <- group(d.candidate.local_words, :local),
         {:ok, parent} <- ok_or(d.candidate.parent, :inspection_parent_unobserved),
         :ok <- clean(d.candidate.dirty) do
      {:ok,
       %{
         inspection_command_id: inspection_id,
         journal_id: ctx.journal.journal_id,
         journal_seq: t["seq"],
         frame: t["frame"],
         mono_ms: t["mono_ms"],
         link_generation: a["link_generation"],
         adapter: adapter,
         mission_generation: t["mission_generation"],
         age_ms: age,
         max_age_ms: ctx.max_age_ms,
         world: world,
         local: local,
         parent: parent
       }}
    end
  end

  @doc "The inspection's age on the journal's clock now, or `{:error, :inspection_stale}`."
  def age(%{"mono_ms" => mono}, %{now_mono_ms: now, max_age_ms: max})
      when is_integer(mono) and is_integer(now) and is_integer(max) and now >= mono and
             now - mono <= max,
      do: {:ok, now - mono}

  def age(_terminal, _ctx), do: {:error, :inspection_stale}

  # Exactly one acceptance (of the exact inspection), transmission, acknowledgement and terminal, in
  # journal order; an unknown outcome or a refinement is never a qualifying inspection.
  defp locate(entries, id) do
    mine = Enum.filter(entries, &(&1["command_id"] == id))
    by = fn events -> Enum.filter(mine, &(&1["event"] in events)) end
    accepted = by.(["command.accepted"])
    transmitted = by.(["command.transmitted"])
    received = by.(["command.received"])
    terminal = by.(["command.terminal"])
    unknown = by.(["command.unknown", "command.unknown_refined"])

    cond do
      mine == [] ->
        {:error, :inspection_not_in_journal}

      length(accepted) != 1 ->
        {:error, {:inspection_accepted_entries, length(accepted)}}

      hd(accepted)["name"] != @inspection or hd(accepted)["version"] != 1 ->
        {:error, :not_an_exact_inspection}

      unknown != [] ->
        {:error, :inspection_outcome_unknown}

      length(transmitted) != 1 ->
        {:error, {:inspection_transmitted_entries, length(transmitted)}}

      length(received) != 1 ->
        {:error, {:inspection_received_entries, length(received)}}

      terminal == [] ->
        {:error, :inspection_not_terminal}

      length(terminal) != 1 ->
        {:error, {:inspection_terminal_entries, length(terminal)}}

      not ordered?([accepted, transmitted, received, terminal]) ->
        {:error, :inspection_stages_out_of_order}

      true ->
        {:ok, hd(accepted), hd(terminal)}
    end
  end

  defp ordered?(groups) do
    seqs = Enum.map(groups, &hd(&1)["seq"])
    Enum.all?(seqs, &is_integer/1) and seqs == Enum.sort(seqs)
  end

  # The in-memory record is never the authority; it must agree with the journal.
  defp cross_check(nil, _a, _t), do: {:error, :inspection_record_missing}

  defp cross_check(record, a, t) do
    result = record[:result]

    cond do
      record[:name] != @inspection or record[:version] != 1 ->
        {:error, :inspection_record_disagrees}

      record[:status] != :applied ->
        {:error, {:inspection_record_status, record[:status]}}

      record[:link_generation] != a["link_generation"] ->
        {:error, :inspection_record_disagrees}

      result == nil or result[:frame] != t["frame"] or
        result[:mission_generation] != t["mission_generation"] or
          result[:observed] != t["observed"] ->
        {:error, :inspection_record_disagrees}

      true ->
        :ok
    end
  end

  defp adapter_identity(entries, generation) do
    case Enum.filter(
           entries,
           &(&1["event"] == "peer.identified" and &1["link_generation"] == generation)
         ) do
      [%{"adapter_instance_id" => id}] when is_binary(id) -> {:ok, id}
      [] -> {:error, :adapter_identity_not_journaled}
      _ -> {:error, :adapter_identity_ambiguous}
    end
  end

  defp token_verified?(entries, generation, adapter) do
    Enum.any?(
      entries,
      &(&1["event"] == "peer.token_verified" and &1["link_generation"] == generation and
          &1["adapter_instance_id"] == adapter)
    )
  end

  defp target_qualified(d) do
    cond do
      d.targets != {:ok, "#{@brick},#{@entity}"} ->
        {:error, :inspection_target_not_compiled}

      d.snapshot_version != {:ok, @snapshot_version} ->
        {:error, :inspection_snapshot_version}

      d.reads_on_frame != {:ok, true} ->
        {:error, :inspection_not_on_one_frame}

      d.cand_brick_present != {:ok, true} ->
        {:error, :inspection_candidate_brick_absent}

      d.cand_index_check != {:ok, "in_range"} ->
        {:error, :inspection_candidate_index_not_in_range}

      d.cand_resolved != {:ok, true} ->
        {:error, :inspection_candidate_unresolved}

      d.cand_hitman5 != {:ok, true} ->
        {:error, :inspection_candidate_not_hitman5}

      d.cand_id_match != {:ok, true} ->
        {:error, :inspection_candidate_id_mismatch}

      d.cand_brick_owner != {:ok, @brick} ->
        {:error, :inspection_candidate_owner_mismatch}

      d.cand_distinct != {:ok, true} ->
        {:error, :inspection_candidate_not_distinct}

      d.cand_spatial != {:ok, true} ->
        {:error, :inspection_candidate_spatial_unavailable}

      d.cand_spatial_distinct != {:ok, true} ->
        {:error, :inspection_candidate_spatial_not_distinct}

      d.cand_in_registry == {:ok, true} ->
        {:error, :inspection_candidate_in_registry}

      d.cand_in_registry != {:ok, false} ->
        {:error, :inspection_registry_unobserved}

      not hero_control_observed?(d.hero) ->
        {:error, :inspection_hero_control_unobserved}

      true ->
        :ok
    end
  end

  defp hero_control_observed?(hero),
    do:
      match?({:ok, _}, hero.world_words) and match?({:ok, _}, hero.local_words) and
        match?({:ok, _}, hero.parent)

  defp group({:ok, words}, _kind), do: {:ok, words}
  defp group({:invalid, _}, :world), do: {:error, :inspection_world_invalid}
  defp group({:invalid, _}, :local), do: {:error, :inspection_local_invalid}
  defp group(_, :world), do: {:error, :inspection_world_unobserved}
  defp group(_, :local), do: {:error, :inspection_local_unobserved}

  defp clean({:ok, false}), do: :ok
  defp clean({:ok, true}), do: {:error, :inspection_cache_dirty}
  defp clean(_), do: {:error, :inspection_dirty_unobserved}

  defp expectations(q),
    do: %{
      "expect_world" => TransformWords.encode(q.world),
      "expect_local" => TransformWords.encode(q.local),
      "expect_parent" => parent_text(q.parent)
    }

  # Every group the caller supplied must equal the canonical value exactly; the canonical value is
  # what is accepted, journaled and transmitted.
  defp compare(supplied, canonical, keys) do
    case Enum.find(keys, &(Map.has_key?(supplied, &1) and supplied[&1] != canonical[&1])) do
      nil -> :ok
      key -> {:error, {:expectation_mismatch, key}}
    end
  end

  defp binding_of(q),
    do: %{
      "inspection_command_id" => q.inspection_command_id,
      "journal_id" => q.journal_id,
      "journal_seq" => q.journal_seq,
      "frame" => q.frame,
      "inspection_mono_ms" => q.mono_ms,
      "link_generation" => q.link_generation,
      "adapter_instance_id" => q.adapter,
      "mission_generation" => q.mission_generation,
      "age_ms" => q.age_ms,
      "max_age_ms" => q.max_age_ms,
      "expect_world" => TransformWords.encode(q.world),
      "expect_local" => TransformWords.encode(q.local),
      "expect_parent" => parent_text(q.parent),
      "verified_by" => "authority",
      "label" =>
        "the authority's own check of its journal at issuance; the candidate's exact words at that frame, not proof they are unchanged since"
    }

  defp parent_text(:none), do: "none"
  defp parent_text(text) when is_binary(text), do: text

  defp ok_or({:ok, v}, _reason), do: {:ok, v}
  defp ok_or(_, reason), do: {:error, reason}
end
