defmodule GlacierRelay.Command.TransformRestore do
  @moduledoc """
  M6-F: the restoration planner of `candidate.transform.set` v1 (`docs/design/M6D2_NEXT_STEP_DESIGN.md`
  section 12.9), the transform counterpart of `Command.Reversal`. It derives the exact preimage
  world group of an applied **lift** from **verified, durable** command evidence — the journal
  file — never from the authority's in-memory record alone, and binds the restoration to a later
  exact inspection. It performs no native command and never restores anything by itself: its plan
  is issued, if at all, by the operator through `GlacierRelay.Command.restore_candidate/2`, under
  fresh one-shot arming, and the native side revalidates everything against its own operation
  record before the one setter call.

  Fail-closed rules (`plan/3`): the journal reads and verifies; the command has exactly one
  `command.accepted` (name `candidate.transform.set`, version 1, mode `lift`, the exact
  expectation groups and a `mission_generation` precondition), one `transmitted`, one `received`
  and exactly one `terminal`, in order, no `unknown` and no refinement; the terminal is `applied`
  with `effect = changed`, `world_match = target`, `hero_control = unchanged`, the preimage and
  postimage groups observed (strictly decoded) and the requested group equal to the postimage;
  the `peer.identified` entry names the adapter; the journal is open and the audit intact; the
  in-memory record agrees. An `uncertain` or `unchanged` effect, an indeterminate post cache, a
  changed parent or a disturbed control is never planned.

  The inspection binding (`verify_inspection/4`): a completed `relay.inspect.candidate_transform/1`
  on the same adapter, the current link and the plan's generation, later than the lift's frame and
  recent, with a clean cache. Its `cand_world_words` must equal the plan's **postimage** group
  bit for bit; if they equal the **preimage** group instead, `{:error, :already_at_baseline}`
  records that no explicit restoration call is needed and none is submitted; within-tolerance
  agreement, drift, a dirty cache, a changed parent or a candidate that no longer resolves stop
  effectful issuance with their own reasons.

  M6-G1: the forward may also be a `candidate.transform.set` **v2** `step_y`. The plan carries the
  forward's journaled `version` and `forward_mode` (a historical v1 record already carries its
  version; nothing new is required of it): v1 plans only a v1 `lift`, v2 only a v2 `step_y`, and
  the restoration is issued at the plan's version — never a default, never a caller's choice.
  """

  alias GlacierRelay.Command.{Journal, TransformReadback, TransformWords}

  # M6-G1: the forward mode of each command version.
  @forward_modes %{1 => "lift", 2 => "step_y"}

  @name "candidate.transform.set"
  @inspection "relay.inspect.candidate_transform"

  @doc """
  Plans the restoration of the lift `command_id` from the journal at `path`. `opts`: `:record`
  (the authority's in-memory record to cross-check), `:journal_status` (`:open` expected),
  `:audit` (`:intact` expected). Returns `{:ok, plan}` or `{:error, reason}`.
  """
  def plan(path, command_id, opts \\ []) when is_binary(path) and is_binary(command_id) do
    with :ok <- check_health(opts),
         {:ok, journal} <- Journal.read(path) do
      plan_journal(journal, command_id, opts)
    end
  end

  @doc """
  `plan/3` over a journal already read and verified by `Journal.read/1` (M6-F1a binding
  correction: the issuing authority plans from its own verified read). `opts`: `:record`.
  """
  def plan_journal(%{entries: entries} = journal, command_id, opts \\ [])
      when is_list(entries) and is_binary(command_id) do
    with {:ok, stages} <- locate(journal.entries, command_id),
         {:ok, accepted} <- check_accepted(stages.accepted),
         {:ok, terminal} <- check_terminal(stages.terminal, @forward_modes[accepted["version"]]),
         {:ok, adapter} <- adapter_identity(journal.entries, accepted["link_generation"]),
         :ok <- cross_check(opts[:record], accepted, terminal, adapter) do
      {:ok,
       %{
         restore_of: command_id,
         version: accepted["version"],
         forward_mode: accepted["params"]["mode"],
         journal_id: journal.journal_id,
         journal_seq: terminal.seq,
         adapter_instance_id: adapter,
         link_generation: accepted["link_generation"],
         mission_generation: accepted["preconditions"]["mission_generation"],
         original_expect_world: accepted["params"]["expect_world"],
         preimage_world: terminal.preimage_world,
         preimage_local: terminal.preimage_local,
         preimage_parent: terminal.preimage_parent,
         requested_world: terminal.requested_world,
         postimage_world: terminal.postimage_world,
         postimage_local: terminal.postimage_local,
         postimage_parent: terminal.postimage_parent,
         effect: "changed",
         frame: terminal.frame,
         terminal_mono_ms: terminal.mono_ms,
         status: "applied",
         audit: :continuous,
         target_world: TransformWords.encode(terminal.preimage_world),
         requires: [:qualifying_exact_inspection, :same_mission_generation, :effectful_arming],
         consequences: :unknown,
         label:
           "restores the stored world matrix through the same single setter; parent-relative fields, parent and dirty flag are re-observed, never assigned; no rollback of gameplay consequences"
       }}
    end
  end

  @doc """
  Verifies that `inspection_id` names a completed `relay.inspect.candidate_transform/1` whose
  journaled evidence qualifies it to bind the plan's restoration (section 12.9). Returns
  `{:ok, binding}` — with the exact `expect_world`, `expect_local` and `expect_parent` the
  restoration must carry — or `{:error, reason}`, where `:already_at_baseline` means the engine
  already shows the preimage and no restoration call is to be submitted.
  """
  def verify_inspection(entries, plan, inspection_id, opts)
      when is_list(entries) and is_map(plan) and is_list(opts) do
    now = Keyword.fetch!(opts, :now_mono_ms)
    link_generation = Keyword.get(opts, :link_generation)
    max_age = Keyword.fetch!(opts, :max_age_ms)
    mine = Enum.filter(entries, &(&1["command_id"] == inspection_id))
    accepted = Enum.filter(mine, &(&1["event"] == "command.accepted"))
    terminal = Enum.filter(mine, &(&1["event"] == "command.terminal"))
    unknown = Enum.filter(mine, &(&1["event"] in ["command.unknown", "command.unknown_refined"]))

    with true <- is_binary(inspection_id) or {:error, :inspection_command_id_required},
         true <- mine != [] or {:error, :inspection_not_in_journal},
         true <-
           length(accepted) == 1 or {:error, {:inspection_accepted_entries, length(accepted)}},
         true <- unknown == [] or {:error, :inspection_outcome_unknown},
         true <- length(terminal) == 1 or {:error, :inspection_not_terminal},
         a = hd(accepted),
         t = hd(terminal),
         true <-
           (a["name"] == @inspection and a["version"] == 1) or {:error, :not_an_exact_inspection},
         true <- t["status"] == "applied" or {:error, {:inspection_not_applied, t["status"]}},
         {:ok, adapter} <- adapter_identity(entries, a["link_generation"]),
         true <- adapter == plan.adapter_instance_id or {:error, :inspection_adapter_mismatch},
         true <-
           (is_integer(link_generation) and a["link_generation"] == link_generation) or
             {:error, :inspection_link_not_current},
         true <-
           t["mission_generation"] == plan.mission_generation or
             {:error, :inspection_generation_mismatch},
         true <-
           (is_integer(t["frame"]) and is_integer(plan.frame) and t["frame"] > plan.frame) or
             {:error, :inspection_not_later},
         true <-
           (is_integer(t["mono_ms"]) and now >= t["mono_ms"] and now - t["mono_ms"] <= max_age) or
             {:error, :inspection_stale},
         observed = t["observed"] || %{},
         decoded = TransformReadback.decode_inspection(observed),
         :ok <- candidate_still_qualified(decoded),
         {:ok, words} <- ok_or(decoded.candidate.world_words, :inspection_world_unobserved),
         {:ok, local} <- ok_or(decoded.candidate.local_words, :inspection_local_unobserved),
         {:ok, parent} <- ok_or(decoded.candidate.parent, :inspection_parent_unobserved),
         {:ok, dirty} <- ok_or(decoded.candidate.dirty, :inspection_dirty_unobserved),
         :ok <- state_matches(words, dirty, parent, plan) do
      {:ok,
       %{
         inspection_command_id: inspection_id,
         frame: t["frame"],
         command_frame: plan.frame,
         age_ms: now - t["mono_ms"],
         max_age_ms: max_age,
         link_generation: a["link_generation"],
         mission_generation: t["mission_generation"],
         expect_world: TransformWords.encode(words),
         expect_local: TransformWords.encode(local),
         expect_parent: parent_text(parent),
         later_class: :held,
         label:
           "evidence of the candidate's exact words at that frame; not proof it is unchanged since"
       }}
    end
  end

  defp candidate_still_qualified(decoded) do
    cond do
      decoded.cand_resolved != {:ok, true} -> {:error, :inspection_candidate_unresolved}
      decoded.cand_distinct != {:ok, true} -> {:error, :inspection_candidate_not_distinct}
      decoded.cand_in_registry != {:ok, false} -> {:error, :inspection_candidate_in_registry}
      true -> :ok
    end
  end

  @doc """
  The later state against the plan: the postimage (with the postimage's parent) binds a
  restoration; the preimage means none is needed (`:already_at_baseline`); a dirty cache is
  `:inspection_cache_dirty`; everything else stops effectful issuance with its class.
  """
  def state_matches(words, dirty, parent, plan) do
    later = %{world_words: {:ok, words}, dirty: {:ok, dirty}}

    case TransformReadback.classify_later(later, plan.preimage_world, plan.postimage_world) do
      :held ->
        if parent_text(parent) == plan.postimage_parent,
          do: :ok,
          else: {:error, {:inspection_parent_changed, parent_text(parent)}}

      :returned_to_baseline ->
        {:error, :already_at_baseline}

      :indeterminate ->
        {:error, :inspection_cache_dirty}

      other ->
        {:error, {:state_drifted, other}}
    end
  end

  defp parent_text(:none), do: "none"
  defp parent_text(text) when is_binary(text), do: text

  defp check_health(opts) do
    cond do
      Keyword.get(opts, :journal_status, :open) != :open -> {:error, :journal_degraded}
      Keyword.get(opts, :audit, :intact) != :intact -> {:error, :audit_degraded}
      true -> :ok
    end
  end

  defp locate(entries, id) do
    mine = Enum.filter(entries, &(&1["command_id"] == id))
    by = fn event -> Enum.filter(mine, &(&1["event"] == event)) end

    accepted = by.("command.accepted")
    transmitted = by.("command.transmitted")
    received = by.("command.received")
    terminal = by.("command.terminal")
    unknown = by.("command.unknown")
    refined = by.("command.unknown_refined")

    cond do
      mine == [] -> {:error, :command_not_in_journal}
      length(accepted) != 1 -> {:error, {:accepted_entries, length(accepted)}}
      length(transmitted) != 1 -> {:error, {:transmitted_entries, length(transmitted)}}
      length(received) != 1 -> {:error, {:received_entries, length(received)}}
      refined != [] -> {:error, :outcome_refined_unknown}
      unknown != [] -> {:error, :outcome_unknown}
      length(terminal) != 1 -> {:error, {:terminal_entries, length(terminal)}}
      not ordered?([accepted, transmitted, received, terminal]) -> {:error, :stages_out_of_order}
      true -> {:ok, %{accepted: hd(accepted), terminal: hd(terminal)}}
    end
  end

  defp ordered?(groups) do
    seqs = Enum.map(groups, &hd(&1)["seq"])
    seqs == Enum.sort(seqs) and Enum.all?(seqs, &is_integer/1)
  end

  defp check_accepted(accepted) do
    params = accepted["params"]
    generation = get_in(accepted, ["preconditions", "mission_generation"])

    cond do
      accepted["name"] != @name or not Map.has_key?(@forward_modes, accepted["version"]) ->
        {:error, :not_a_transform_command}

      accepted["version"] == 1 and (not is_map(params) or params["mode"] != "lift") ->
        {:error, :not_a_lift}

      accepted["version"] == 2 and (not is_map(params) or params["mode"] != "step_y") ->
        {:error, :not_a_step}

      not match?({:ok, _}, TransformWords.decode_world(params["expect_world"] || "")) ->
        {:error, :expect_world_invalid}

      not (is_binary(generation) and byte_size(generation) in 1..64) ->
        {:error, :mission_generation_missing}

      not is_integer(accepted["link_generation"]) ->
        {:error, :link_generation_missing}

      true ->
        {:ok, accepted}
    end
  end

  defp check_terminal(terminal, forward_mode) do
    observed = terminal["observed"]

    with "applied" <- terminal["status"] || {:error, :terminal_status_missing},
         true <- is_map(observed) or {:error, :terminal_unobserved},
         d = TransformReadback.decode_apply(observed),
         :ok <- effect(d, forward_mode),
         {:ok, pre_w} <- ok_or(d.preimage.world_words, :preimage_world_unobserved),
         {:ok, pre_l} <- ok_or(d.preimage.local_words, :preimage_local_unobserved),
         {:ok, pre_p} <- ok_or(d.preimage.parent, :preimage_parent_unobserved),
         {:ok, false} <-
           ok_or(d.preimage.dirty, :preimage_dirty_unobserved) |> dirty(:preimage_dirty),
         {:ok, req} <- ok_or(d.requested_world_words, :requested_world_unobserved),
         {:ok, post_w} <- ok_or(d.postimage.world_words, :postimage_world_unobserved),
         {:ok, post_l} <- ok_or(d.postimage.local_words, :postimage_local_unobserved),
         {:ok, post_p} <- ok_or(d.postimage.parent, :postimage_parent_unobserved),
         {:ok, false} <-
           ok_or(d.postimage.dirty, :postimage_dirty_unobserved) |> dirty(:postimage_dirty),
         true <- TransformWords.equal?(post_w, req) or {:error, :postimage_not_requested},
         true <- not TransformWords.equal?(post_w, pre_w) or {:error, :postimage_equals_preimage},
         true <- pre_p == post_p or {:error, :parent_changed_by_lift} do
      {:ok,
       %{
         preimage_world: pre_w,
         preimage_local: pre_l,
         preimage_parent: parent_text(pre_p),
         requested_world: req,
         postimage_world: post_w,
         postimage_local: post_l,
         postimage_parent: parent_text(post_p),
         seq: terminal["seq"],
         frame: terminal["frame"],
         mono_ms: terminal["mono_ms"]
       }}
    else
      {:error, _} = error -> error
      other when is_binary(other) -> {:error, {:not_applied, other}}
    end
  end

  defp dirty({:ok, true}, reason), do: {:error, reason}
  defp dirty(other, _reason), do: other

  # Only a verified changed forward (a v1 lift or a v2 step, its native result naming the same
  # mode) with the target match, a clean post cache and an untouched control is restorable by an
  # ordinary plan.
  defp effect(d, forward_mode) do
    cond do
      d.mode != {:ok, forward_mode} and forward_mode == "step_y" -> {:error, :not_a_step}
      d.mode != {:ok, forward_mode} -> {:error, :not_a_lift}
      d.effect == {:ok, "unchanged"} -> {:error, :effect_unchanged}
      d.effect == {:ok, "uncertain"} -> {:error, :effect_uncertain}
      d.effect == {:ok, "none"} -> {:error, :effect_none}
      d.effect != {:ok, "changed"} -> {:error, :effect_unreported}
      d.world_match != {:ok, "target"} -> {:error, {:world_match, elem_or(d.world_match)}}
      d.hero_control != {:ok, "unchanged"} -> {:error, {:hero_control, elem_or(d.hero_control)}}
      d.post_same_entity != {:ok, true} -> {:error, :post_entity_changed}
      true -> :ok
    end
  end

  defp elem_or({:ok, v}), do: v
  defp elem_or(other), do: other

  defp ok_or({:ok, v}, _reason), do: {:ok, v}
  defp ok_or(_, reason), do: {:error, reason}

  defp adapter_identity(entries, generation) do
    case Enum.find(
           entries,
           &(&1["event"] == "peer.identified" and &1["link_generation"] == generation)
         ) do
      %{"adapter_instance_id" => id} when is_binary(id) -> {:ok, id}
      _ -> {:error, :adapter_identity_not_journaled}
    end
  end

  # The in-memory record is a convenience, never the authority: it must agree with the journal.
  defp cross_check(nil, _accepted, _terminal, _adapter), do: :ok

  defp cross_check(record, accepted, terminal, adapter) do
    observed = (record[:result] && record[:result][:observed]) || %{}
    d = TransformReadback.decode_apply(observed)

    cond do
      record[:audit] != :intact ->
        {:error, {:record_audit, record[:audit]}}

      record[:status] != :applied ->
        {:error, {:record_status, record[:status]}}

      record[:link_generation] != accepted["link_generation"] ->
        {:error, :record_generation_disagrees}

      record[:adapter_instance_id] != adapter ->
        {:error, :record_adapter_disagrees}

      d.preimage.world_words != {:ok, terminal.preimage_world} ->
        {:error, :record_preimage_disagrees}

      d.postimage.world_words != {:ok, terminal.postimage_world} ->
        {:error, :record_postimage_disagrees}

      true ->
        :ok
    end
  end
end
