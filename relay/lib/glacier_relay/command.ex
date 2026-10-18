defmodule GlacierRelay.Command do
  @moduledoc """
  The operator-facing command API (M5-A; M5 C-1; M5 C-2A): the smallest surface needed to arm,
  disarm, probe, inspect, attest, arm for one effectful command, issue it, plan and issue its
  reversal and attach observations, for an explicitly controlled local IEx or RPC context. There
  is no browser path, no Phoenix route and no persistence of arming; every call below is refused
  unless the command subtree is enabled (`GLACIER_RELAY_COMMAND=1`) and running.

  M5-A proves that BEAM can govern a bounded command exchange with a peer; C-2A proves that it
  can govern effectful authority under a documented, limited trust model against fake peers. It
  authorizes no action on Glacier: no real native build implements `player.outfit.set` v2, and the
  authority advertises it only to a version-2 peer that attests the run token.
  """

  alias GlacierRelay.Command.{Authority, Journal, Reversal, TransformRestore}

  @doc "Whether the command subtree is running in this node."
  def enabled?, do: Process.whereis(GlacierRelay.Command.Supervisor) != nil

  @doc "Arms the authority for inert commands on the current identified link."
  def arm, do: guarded(fn -> Authority.arm() end)

  @doc "Disarms the authority (inert and effectful)."
  def disarm, do: guarded(fn -> Authority.disarm() end)

  @doc "Issues `relay.probe` v1 (no effect). Returns `{:ok, command_id}` or `{:error, reason}`."
  def probe(opts \\ []), do: guarded(fn -> Authority.issue("relay.probe", 1, %{}, opts) end)

  @doc """
  Issues `relay.inspect.outfit` v1 (M5 C-1; read-only, no effect). `params` may carry
  `"disguise_repository_id"` (a candidate kit id to resolve); `opts` as `probe/1` plus
  `:expected_generation`, the contract session id the hypothetical precondition is judged
  against (sent as the `mission_generation` precondition). Returns `{:ok, command_id}` or
  `{:error, reason}`; the read-back is in `command/1`'s result, every field with its own status.
  """
  def inspect_outfit(params \\ %{}, opts \\ []) when is_map(params) and is_list(opts) do
    guarded(fn -> Authority.issue("relay.inspect.outfit", 1, params, with_generation(opts)) end)
  end

  @doc """
  M6-B1: issues `relay.inspect.players` v1 (read-only, no effect, no parameters): the player
  registry's four declared slots with per-field statuses, the words at its array offset
  classified, and slot 0 beside M5's local-hero path. `opts` as `probe/1` (`:ttl_ms`). Inert
  arming only. The read-back is in `command/1`'s result; a non-null reference is never a living
  hero, and nothing in it is a stable player identity.
  """
  def inspect_players(opts \\ []) when is_list(opts),
    do: guarded(fn -> Authority.issue("relay.inspect.players", 1, %{}, opts) end)

  @doc """
  M6-B1: issues `relay.inspect.entity` v1 (read-only, no effect). `params` may carry `"brick"`
  and `"entity_id"`, each exactly 16 lowercase hex digits naming content (a brick's runtime
  resource id, an authored entity id); absent, the native reader applies the historical
  `hitmen.brick` / Agent48 defaults, whose expected answer without content is "candidate absent".
  `opts` as `probe/1`. Inert arming only. The read-back carries the loaded-brick inventory, the
  local hero's authored identity and stored transform (with its dirty flag), the round-trip
  outcome and the candidate's resolution, every field with its own status.
  """
  def inspect_entity(params \\ %{}, opts \\ []) when is_map(params) and is_list(opts),
    do: guarded(fn -> Authority.issue("relay.inspect.entity", 1, params, opts) end)

  @doc """
  M6-D1a: issues `relay.inspect.candidate` v1 (read-only, no effect). `params` as
  `inspect_entity/2` (`"brick"`, `"entity_id"`, 16 lowercase hex digits each; the spawn target is
  the native side's compiled historical default and is not a parameter). `opts` as `probe/1`.
  Inert arming only. The read-back carries, on one native frame, the candidate hero's and the
  local hero's stored spatial fields, member presence and `m_bActive` property, the spawn
  entity's stored transform and properties, and registry membership by entity identity, every
  field with its own status; the packed groups decode with `Command.CandidateReadback`. Nothing
  in it is a claim of initialization, simulation, placement, visibility or playability.
  """
  def inspect_candidate(params \\ %{}, opts \\ []) when is_map(params) and is_list(opts),
    do: guarded(fn -> Authority.issue("relay.inspect.candidate", 1, params, opts) end)

  @doc """
  M6-F: issues `relay.inspect.candidate_transform` v1 (read-only, no effect, no parameters): on
  one native frame, the compiled candidate's and the local hero's exact stored transform words
  (a 12-word world group and a 7-word parent-relative group), dirty flags, parents, the identity
  block and registry membership. `opts` as `probe/1`. Inert arming only. The read-back decodes
  with `Command.TransformReadback`; it is the expectation source of a lift and of a restoration,
  and the later observation of either. A sampled state, never a claim about simulation.
  """
  def inspect_candidate_transform(opts \\ []) when is_list(opts),
    do: guarded(fn -> Authority.issue("relay.inspect.candidate_transform", 1, %{}, opts) end)

  @doc """
  M6-F: issues `candidate.transform.set` v1 in mode `lift` — the compiled +0.25 world-z
  displacement of the compiled candidate, computed natively from the freshly validated snapshot.
  `opts`: `:inspection_command_id` (required: ONE completed `relay.inspect.candidate_transform/1`
  of this authority; never an implicit latest inspection), `:expected_generation` (required),
  `:ttl_ms`. The authority verifies that inspection from its own journal (the current
  token-verified link and adapter, the expected generation, within
  `reversal_inspection_max_age_ms` on the journal's clock, the compiled target tuple qualified, a
  clean and finite snapshot; `Command.TransformBinding`) and derives the expectation groups from
  it; `params` may carry `"expect_world"`, `"expect_local"` and `"expect_parent"`, which must then
  equal them exactly. The accepted entry journals the binding and the parameters as transmitted.
  Refused unless the link is token-verified, the entry was advertised, effectful arming is held
  and this authority's one lift budget is unconsumed; a supplied target or restore binding is
  refused. The lift is a limited experimental exposure with unknown engine consequences, not
  collision-proven safety, and not a visual-presence experiment.
  """
  def lift_candidate(params, opts \\ []) when is_map(params) and is_list(opts) do
    guarded(fn ->
      Authority.issue(
        "candidate.transform.set",
        1,
        Map.put(params, "mode", "lift"),
        with_generation(opts)
      )
    end)
  end

  @doc """
  M6-G1: issues `candidate.transform.set` v2 in mode `step_y` — the compiled +0.25 world-y
  displacement of the compiled candidate, computed natively from the freshly validated snapshot
  (every other world word copied; world y is not a model-relative direction). `opts` and the
  authority's checks are exactly `lift_candidate/2`'s: ONE completed exact inspection named by
  `:inspection_command_id` and verified by the authority from its own journal, `:expected_generation`
  required, the expectation groups derived from that evidence, a token-verified link that
  advertised `candidate.transform.set/2`, fresh effectful arming, and the ONE forward budget this
  authority shares between the v1 lift and the v2 step. A supplied target, axis, distance or
  restore binding is refused. The step is a limited experimental exposure with unknown engine
  consequences; its clearance is not measured.
  """
  def step_candidate(params, opts \\ []) when is_map(params) and is_list(opts) do
    guarded(fn ->
      Authority.issue(
        "candidate.transform.set",
        2,
        Map.put(params, "mode", "step_y"),
        with_generation(opts)
      )
    end)
  end

  @doc """
  M6-F: plans the restoration of an applied lift (M6-G1: or v2 step) from the verified journal
  file (`Command.TransformRestore`), cross-checked against the authority's record; the plan carries
  the forward's journaled `version`. Performs nothing.
  """
  def plan_transform_restore(command_id) when is_binary(command_id) do
    guarded(fn ->
      journal = Journal.status()
      s = Authority.status()

      TransformRestore.plan(journal.path, command_id,
        record: Authority.command(command_id),
        journal_status: journal.status,
        audit: if(s.audit == :intact, do: :intact, else: :degraded)
      )
    end)
  end

  @doc """
  M6-F: issues the planned restoration of the lift `command_id` — `candidate.transform.set` v1 in
  mode `restore`, whose `target_world` is the lift's journaled preimage world group and whose
  expectation is the later exact inspection's words. `opts` must carry `:inspection_command_id`
  (a completed `relay.inspect.candidate_transform/1` that `TransformRestore.verify_inspection/4`
  accepts: the current adapter and link, the plan's generation, a clean cache, words equal to the
  lift's postimage, later than the lift, within `reversal_inspection_max_age_ms`) and
  `:expected_generation` (the live attempt's; it must equal the plan's). `{:error,
  :already_at_baseline}` means the engine already shows the preimage: no restoration call is
  needed and none is submitted. These checks here give the operator an early answer; the issuing
  authority repeats the plan and the inspection check itself from its own journal (M6-F1a binding
  correction) — only the inspection id crosses, never a binding. Needs its own effectful arming;
  nothing restores automatically; the native side revalidates against its own operation record
  before the one setter call.
  Restoring observed transform values is not a rollback of physics, perception, script, animation
  or other gameplay consequences.
  M6-G1: the restoration is issued at the plan's verified version — v1 for a v1 lift, v2 for a v2
  step — never a default literal and never a caller's choice; the authority compares that version
  with the journaled original again, and the native gate before its setter.
  """
  def restore_candidate(command_id, opts) when is_binary(command_id) and is_list(opts) do
    guarded(fn ->
      status = Authority.status()
      journal = Journal.status()

      with {:ok, plan} <- plan_transform_restore(command_id),
           {:ok, read} <- Journal.read(journal.path),
           {:ok, binding} <-
             TransformRestore.verify_inspection(
               read.entries,
               plan,
               Keyword.get(opts, :inspection_command_id),
               now_mono_ms: journal.elapsed_ms,
               link_generation: status.link && status.link.generation,
               max_age_ms: status.effectful.reversal_inspection_max_age_ms
             ),
           :ok <- confirm_generation(plan, Keyword.get(opts, :expected_generation)) do
        Authority.issue(
          "candidate.transform.set",
          plan.version,
          %{
            "mode" => "restore",
            "expect_world" => binding.expect_world,
            "expect_local" => binding.expect_local,
            "expect_parent" => binding.expect_parent,
            "target_world" => plan.target_world,
            "restore_of" => command_id
          },
          opts
          |> Keyword.put(:reversal_of, command_id)
          |> with_generation()
        )
      end
    end)
  end

  defp confirm_generation(plan, generation) do
    cond do
      not is_binary(generation) ->
        {:error, :expected_generation_required}

      generation != plan.mission_generation ->
        {:error, {:generation_mismatch, plan.mission_generation}}

      true ->
        :ok
    end
  end

  @doc """
  M5 C-2A: records the operator's telemetry attestation (the adapter identity read from the
  observer out of band, with `observed_at`, `basis`, `evidence_ref` and `max_age_ms`). Required,
  fresh, before effectful arming. Never derived from the command peer's own messages. Freshness
  (M5 C-2C N1) is a dual-clock rule: `observed_at` is bounded against this node's UTC clock
  (`telemetry_observation_stale` / `telemetry_observation_future`) when submitted and again when
  arming, and the monotonic time since receipt is bounded (`telemetry_corroboration_stale`);
  `observed_at` stays an operator claim, never an authenticated clock reading.
  """
  def attest_telemetry(attestation) when is_map(attestation),
    do: guarded(fn -> Authority.attest_telemetry(attestation) end)

  @doc """
  M5 C-2A: one-shot, time-bounded effectful arming. `opts`: `:ttl_ms`, `:ownership` (the
  operator-supplied socket-ownership evidence map; required). Consumed by the first effectful
  issuance; expires; revoked by `disarm/0`, link loss or audit degradation.
  """
  def arm_effectful(opts \\ []), do: guarded(fn -> Authority.arm_effectful(opts) end)

  @doc """
  M5 C-2A: issues `player.outfit.set` v2 with the complete tuple. `params`:
  `%{"disguise_repository_id", "charset", "variation", "expect_current" => %{the same three}}`;
  `opts`: `:expected_generation` (required by the entry), `:ttl_ms`, `:reversal_of`. Refused
  unless the link is token-verified, the entry was advertised to the peer and effectful arming is
  held; a target equal to `expect_current` is refused as a no-op.
  """
  def set_outfit(params, opts \\ []) when is_map(params) and is_list(opts),
    do: guarded(fn -> Authority.issue("player.outfit.set", 2, params, with_generation(opts)) end)

  @doc """
  M5 C-2A: plans the reversal of an applied `player.outfit.set` v2 from the verified journal file
  (`Command.Reversal`), cross-checked against the authority's record. Performs nothing.
  """
  def plan_reversal(command_id) when is_binary(command_id) do
    guarded(fn ->
      journal = Journal.status()
      s = Authority.status()

      Reversal.plan(journal.path, command_id,
        record: Authority.command(command_id),
        journal_status: journal.status,
        audit: if(s.audit == :intact, do: :intact, else: :degraded)
      )
    end)
  end

  @doc """
  M5 C-2A, bound to an inspection by the pre-C-3 hardening (correction C): issues the planned
  reversal of `command_id`. `opts` must carry `:inspection_command_id` — a completed
  `relay.inspect.outfit/1` whose journaled evidence `Reversal.verify_inspection/4` accepts:
  the current adapter instance and link, the plan's mission generation, an observed hero tuple
  equal to the plan's `expect_current`, a native frame later than the original command's, and a
  terminal received within the configured `reversal_inspection_max_age_ms` (60 s by default: an
  attended local research experiment) — and `:expected_generation` (the live attempt's
  generation; it must equal the plan's). An operator-supplied `:confirmed_current` is optional
  and, when given, must equal the plan's `expect_current`; it never substitutes for the
  inspection. The inspection is evidence of the state at its frame, not proof the outfit is
  unchanged since; the native applying-frame gate stays the final protection. Needs its own
  effectful arming; nothing reverses automatically. The accepted entry journals the binding.
  """
  def reverse(command_id, opts) when is_binary(command_id) and is_list(opts) do
    guarded(fn ->
      status = Authority.status()
      journal = Journal.status()

      with {:ok, plan} <- plan_reversal(command_id),
           {:ok, read} <- Journal.read(journal.path),
           {:ok, binding} <-
             Reversal.verify_inspection(
               read.entries,
               plan,
               Keyword.get(opts, :inspection_command_id),
               now_mono_ms: journal.elapsed_ms,
               link_generation: status.link && status.link.generation,
               max_age_ms: status.effectful.reversal_inspection_max_age_ms
             ),
           :ok <-
             confirm(
               plan,
               Keyword.get(opts, :confirmed_current),
               Keyword.get(opts, :expected_generation)
             ) do
        Authority.issue(
          "player.outfit.set",
          2,
          plan.params,
          opts
          |> Keyword.drop([:confirmed_current, :inspection_command_id])
          |> Keyword.put(:reversal_of, command_id)
          |> Keyword.put(
            :reversal_inspection,
            Map.take(binding, [:inspection_command_id, :frame, :age_ms])
          )
          |> with_generation()
        )
      end
    end)
  end

  defp confirm(plan, confirmed, generation) do
    cond do
      is_map(confirmed) and confirmed != plan.params["expect_current"] ->
        {:error, {:confirmed_current_mismatch, plan.params["expect_current"]}}

      not is_binary(generation) ->
        {:error, :expected_generation_required}

      generation != plan.mission_generation ->
        {:error, {:generation_mismatch, plan.mission_generation}}

      true ->
        :ok
    end
  end

  @doc """
  M5 C-2A: attaches an operator observation (testimony) to a command: `type` one of
  `visual_confirmation`, `visual_no_change`, `later_frame_read_back` (`:inspection_command_id`),
  `engine_consistent` (`:envelope`), `note`; bounded `text`; `:at` optional. Journaled first.
  """
  def observe(command_id, type, text, opts \\ []),
    do: guarded(fn -> Authority.observe(command_id, type, text, opts) end)

  @doc "The authority's status, or `{:error, :command_disabled}`."
  def status, do: guarded(fn -> Authority.status() end)

  @doc "One command's record by id."
  def command(id), do: guarded(fn -> Authority.command(id) end)

  defp with_generation(opts) do
    {expected, opts} = Keyword.pop(opts, :expected_generation)

    if expected,
      do: Keyword.put(opts, :preconditions, %{"mission_generation" => expected}),
      else: opts
  end

  defp guarded(fun), do: if(enabled?(), do: fun.(), else: {:error, :command_disabled})
end
