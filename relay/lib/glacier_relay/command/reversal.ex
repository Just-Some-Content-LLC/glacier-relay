defmodule GlacierRelay.Command.Reversal do
  @moduledoc """
  The reversal planner (M5 C-2A; M5 design section 26.3): derives the complete prior outfit tuple
  of an applied `player.outfit.set` v2 from **verified, durable** command evidence — the journal
  file — and never from the authority's in-memory record alone. It performs no native command and
  never reverses anything by itself; its plan is issued, if at all, by the operator through
  `GlacierRelay.Command.reverse/2`, which additionally demands a fresh current-tuple confirmation
  and the live mission generation: the journal proves what the peer reported then, never the
  game state now.

  Fail-closed rules: the journal must read and verify (`Command.Journal.read/1`); the command
  must have exactly one `command.accepted` (name `player.outfit.set`, version 2, a complete
  `expect_current` tuple and a `mission_generation` precondition), one `command.transmitted`,
  one `command.received` and exactly one `command.terminal`, in that order, no `command.unknown`
  and no refinement; the terminal must be `applied` with `previous_*` and `current_*` tuples all
  observed and an `effect` of `changed` (an `unchanged` effect is nothing to reverse; an
  `uncertain` effect — an unexpected tuple, a post-call generation change, a missing read-back —
  is never planned, whatever later observations were journaled: M5 pre-C-3 hardening, correction
  B / finding N3 — a complete tuple inside an uncertain result does not establish that the command
  changed state safely, and a later inspection may inform a separate explicit operator recovery
  decision but never rewrites the original effect; a `failed` terminal with a possible effect and
  an `unknown` outcome are refused likewise);
  the `peer.identified` entry of the command's link generation must name the adapter identity;
  the journal must not be degraded (`journal_status`) and the authority's audit must be intact;
  when the in-memory record is supplied it must agree with the journal (status, result,
  generation, adapter) and be `audit: :intact`. Every failure is a named reason.
  """

  alias GlacierRelay.Command.{Journal, Schema}

  @doc """
  M5 pre-C-3 hardening, correction C: verifies that `inspection_id` names a completed
  `relay.inspect.outfit/1` whose journaled evidence qualifies it to confirm the reversal plan's
  expected-current tuple. From the journal entries alone: the inspection has exactly one
  `command.accepted` and one `command.terminal`, no `command.unknown`; it is an inspection; its
  terminal is `applied`; the `peer.identified` entry of its link generation names the plan's
  adapter instance; its link generation is the current link's (`:link_generation`); its result's
  mission generation is the plan's; its observed hero tuple (id, charset, variation) equals the
  plan's `expect_current`; its native frame is later than the original command's applying frame;
  its terminal was received within `:max_age_ms` of `:now_mono_ms` (the node's monotonic clock).
  An inspection is evidence of the state at its frame, not proof the outfit is unchanged since:
  the native applying-frame expected-current gate stays the final protection. Returns
  `{:ok, binding}` or `{:error, reason}`.
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
           (a["name"] == "relay.inspect.outfit" and a["version"] == 1) or
             {:error, :not_an_inspection},
         true <- t["status"] == "applied" or {:error, {:inspection_not_applied, t["status"]}},
         {:ok, adapter} <- adapter_identity(entries, a["link_generation"]),
         true <- adapter == plan.adapter_instance_id or {:error, :inspection_adapter_mismatch},
         true <-
           (is_integer(link_generation) and a["link_generation"] == link_generation) or
             {:error, :inspection_link_not_current},
         true <-
           t["mission_generation"] == plan.mission_generation or
             {:error, :inspection_generation_mismatch},
         {:ok, hero} <- tuple_or(t["observed"], "hero", :inspection_hero_unobserved),
         true <-
           hero == plan.params["expect_current"] or {:error, {:inspection_tuple_mismatch, hero}},
         true <-
           (is_integer(t["frame"]) and is_integer(plan.frame) and t["frame"] > plan.frame) or
             {:error, :inspection_not_later},
         true <-
           (is_integer(t["mono_ms"]) and now >= t["mono_ms"] and now - t["mono_ms"] <= max_age) or
             {:error, :inspection_stale} do
      {:ok,
       %{
         inspection_command_id: inspection_id,
         frame: t["frame"],
         command_frame: plan.frame,
         age_ms: now - t["mono_ms"],
         max_age_ms: max_age,
         hero: hero,
         link_generation: a["link_generation"],
         mission_generation: t["mission_generation"],
         label: "evidence of the hero's tuple at that frame; not proof it is unchanged since"
       }}
    end
  end

  @doc """
  Plans the reversal of `command_id` from the journal at `path`. `opts`: `:record` (the
  authority's in-memory record to cross-check), `:journal_status` (`:open` expected),
  `:audit` (`:intact` expected). Returns `{:ok, plan}` or `{:error, reason}`.
  """
  def plan(path, command_id, opts \\ []) when is_binary(path) and is_binary(command_id) do
    with :ok <- check_health(opts),
         {:ok, journal} <- Journal.read(path),
         {:ok, stages} <- locate(journal.entries, command_id),
         {:ok, accepted} <- check_accepted(stages.accepted),
         {:ok, terminal} <- check_terminal(stages.terminal, stages.observations),
         {:ok, adapter} <- adapter_identity(journal.entries, accepted["link_generation"]),
         :ok <- cross_check(opts[:record], accepted, terminal, adapter) do
      {:ok,
       %{
         reversal_of: command_id,
         journal_id: journal.journal_id,
         journal_seq: terminal.seq,
         adapter_instance_id: adapter,
         link_generation: accepted["link_generation"],
         mission_generation: accepted["preconditions"]["mission_generation"],
         original_expect_current: accepted["params"]["expect_current"],
         original_target:
           Map.take(accepted["params"], ["disguise_repository_id", "charset", "variation"]),
         previous: terminal.previous,
         current: terminal.current,
         effect: terminal.effect,
         frame: terminal.frame,
         terminal_mono_ms: terminal.mono_ms,
         status: "applied",
         audit: :continuous,
         ambiguous_stages: [],
         params: Map.put(terminal.previous, "expect_current", terminal.current),
         requires: [
           :qualifying_inspection,
           :same_mission_generation,
           :effectful_arming
         ],
         consequences: :unknown
       }}
    end
  end

  defp check_health(opts) do
    cond do
      Keyword.get(opts, :journal_status, :open) != :open -> {:error, :journal_degraded}
      Keyword.get(opts, :audit, :intact) != :intact -> {:error, :audit_degraded}
      true -> :ok
    end
  end

  # Every entry of the command, grouped and checked for count and order.
  defp locate(entries, id) do
    mine = Enum.filter(entries, &(&1["command_id"] == id))
    by = fn event -> Enum.filter(mine, &(&1["event"] == event)) end

    accepted = by.("command.accepted")
    transmitted = by.("command.transmitted")
    received = by.("command.received")
    terminal = by.("command.terminal")
    unknown = by.("command.unknown")
    refined = by.("command.unknown_refined")
    observations = by.("operator.observation")

    cond do
      mine == [] -> {:error, :command_not_in_journal}
      length(accepted) != 1 -> {:error, {:accepted_entries, length(accepted)}}
      length(transmitted) != 1 -> {:error, {:transmitted_entries, length(transmitted)}}
      length(received) != 1 -> {:error, {:received_entries, length(received)}}
      refined != [] -> {:error, :outcome_refined_unknown}
      unknown != [] -> {:error, :outcome_unknown}
      length(terminal) != 1 -> {:error, {:terminal_entries, length(terminal)}}
      not ordered?([accepted, transmitted, received, terminal]) -> {:error, :stages_out_of_order}
      true -> {:ok, %{accepted: hd(accepted), terminal: hd(terminal), observations: observations}}
    end
  end

  defp ordered?(groups) do
    seqs = Enum.map(groups, &hd(&1)["seq"])
    seqs == Enum.sort(seqs) and Enum.all?(seqs, &is_integer/1)
  end

  defp check_accepted(accepted) do
    params = accepted["params"]
    expect = is_map(params) && params["expect_current"]
    generation = get_in(accepted, ["preconditions", "mission_generation"])

    cond do
      accepted["name"] != "player.outfit.set" or accepted["version"] != 2 ->
        {:error, :not_an_effectful_outfit_command}

      not tuple?(expect) ->
        {:error, :expect_current_incomplete}

      not (is_binary(generation) and byte_size(generation) in 1..64) ->
        {:error, :mission_generation_missing}

      not is_integer(accepted["link_generation"]) ->
        {:error, :link_generation_missing}

      true ->
        {:ok, accepted}
    end
  end

  defp check_terminal(terminal, _observations) do
    observed = terminal["observed"]

    with "applied" <- terminal["status"] || {:error, :terminal_status_missing},
         {:ok, previous} <- tuple_or(observed, "previous", :previous_tuple_unobserved),
         {:ok, current} <- tuple_or(observed, "current", :current_tuple_unobserved),
         {:ok, effect} <- effect(observed) do
      {:ok,
       %{
         previous: previous,
         current: current,
         effect: effect,
         seq: terminal["seq"],
         frame: terminal["frame"],
         mono_ms: terminal["mono_ms"]
       }}
    else
      {:error, _} = error -> error
      other when is_binary(other) -> {:error, {:not_applied, other}}
    end
  end

  defp tuple_or(observed, prefix, reason) do
    case Schema.observed_tuple(observed, prefix) do
      {:ok, tuple} -> {:ok, tuple}
      :unobserved -> {:error, reason}
    end
  end

  # Only a verified `changed` effect is reversible by an ordinary plan. An `uncertain` effect is
  # refused however many later-frame observations say "consistent": they are testimony about a
  # later frame, never a rewrite of what the setter did on its own frame (correction B / N3).
  defp effect(observed) when is_map(observed) do
    case Schema.observed_value(observed["effect"]) do
      {:ok, "changed"} -> {:ok, "changed"}
      {:ok, "unchanged"} -> {:error, :effect_unchanged}
      {:ok, "uncertain"} -> {:error, :effect_uncertain}
      {:ok, other} -> {:error, {:effect_unexpected, other}}
      :unobserved -> {:error, :effect_unreported}
    end
  end

  defp effect(_), do: {:error, :effect_unreported}

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
    cond do
      record[:audit] != :intact ->
        {:error, {:record_audit, record[:audit]}}

      record[:status] != :applied ->
        {:error, {:record_status, record[:status]}}

      record[:link_generation] != accepted["link_generation"] ->
        {:error, :record_generation_disagrees}

      record[:adapter_instance_id] != adapter ->
        {:error, :record_adapter_disagrees}

      Schema.observed_tuple(record[:result][:observed], "previous") != {:ok, terminal.previous} ->
        {:error, :record_previous_disagrees}

      Schema.observed_tuple(record[:result][:observed], "current") != {:ok, terminal.current} ->
        {:error, :record_current_disagrees}

      true ->
        :ok
    end
  end

  defp tuple?(%{"disguise_repository_id" => id, "charset" => c, "variation" => v} = map),
    do: map_size(map) == 3 and Schema.uuid?(id) and is_integer(c) and is_integer(v)

  defp tuple?(_), do: false
end
