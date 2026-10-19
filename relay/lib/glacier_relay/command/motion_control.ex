defmodule GlacierRelay.Command.MotionControl do
  @moduledoc """
  M7-B1: the authority's motion rules (`docs/design/M7_NETWORK_GHOST.md` sections 15.3–15.5; ADR
  0010 as amended), pure functions over `Command.Authority`'s state, called only from inside it.

  **Issuance.** `player.pose.share/1` (inert arming) and `candidate.motion.session/1` (`open`,
  `restore`; one-shot effectful arming) pass the authority's ordinary checks first; here: the
  motion link bound for the current token-verified command link, the operator's statement or
  approval (built by the `GlacierRelay.Motion` facade and journaled in the accepted entry), the
  canonical parameters derived from that approval and — for `open` and `restore` — from one fresh
  exact inspection verified from the authority's own journal (`TransformBinding.qualify/2`).
  Nothing a peer sends takes part.

  **Exclusivity.** `candidate.transform.set` v1 / v2 — forward and restore — is refused while any
  motion session of this authority is not `restored` (or never opened: `not_opened`). A motion
  `open` is refused while an M6 forward has consumed the one-forward budget without a confirmed
  restoration, while any earlier session is not restored, and once `max_sessions` sessions
  (default 1) have been opened. Neither budget is ever reset.

  **Restoration.** `restore` is issuable only for a session whose close the journal records as
  native-confirmed and clean (`motion.session.closed` with `restorable: true` and its final words),
  against a qualifying exact inspection journaled after that close, on the session's adapter, whose
  candidate words equal the final words. Words equal to the opening preimage mean
  `already_at_baseline`: nothing is submitted. The target is the opening preimage the native
  confirmed at open (the open's journaled terminal). A session whose candidate a later qualifying
  inspection shows already at that preimage is released by `confirm_baseline/4` (journaled
  `motion.session.at_baseline`) instead: nothing is submitted.

  Session states: `accepted` → `open` | `not_opened` | `open_failed` | `open_unknown` |
  `open_unverified`; `open` → `closed_clean` | `closed_unclean` | `close_unknown`; `closed_clean` →
  `restoring` → `restored` | `restore_not_exact` | `restore_unknown` (a verified non-application
  returns it to `closed_clean`); `closed_clean` → `at_baseline`. Only `not_opened`, `restored` and
  `at_baseline` release the exclusivity.
  """

  alias GlacierRelay.Command.{Schema, TransformBinding, TransformReadback, TransformWords}
  alias GlacierRelay.Motion.Destination

  @native_limits %{min_apply_interval_ms: 40, silence_close_ms: 1_000}
  @releasing [:not_opened, :restored, :at_baseline]

  def initial(config) do
    %{
      enabled: Keyword.get(config, :motion, false) == true,
      max_sessions: Keyword.get(config, :max_motion_sessions, 1),
      link: nil,
      next_generation: 1,
      sessions: %{},
      session_order: [],
      shares: %{}
    }
  end

  def native_limits, do: @native_limits

  # -- the motion link ----------------------------------------------------------------------------------

  @doc "Checks a motion link's hello against the current command link."
  def hello_verdict(state, adapter, command_generation) do
    m = state.motion
    link = state.link

    cond do
      not m.enabled -> {:error, :motion_disabled}
      state.audit != :intact -> {:error, :audit_degraded}
      link == nil or link.identity != :identified -> {:error, :no_identified_command_link}
      not link.token_verified -> {:error, :command_link_not_token_verified}
      link.generation != command_generation -> {:error, :command_link_generation_mismatch}
      link.adapter_instance_id != adapter -> {:error, :adapter_mismatch}
      m.link != nil -> {:error, :busy}
      true -> :ok
    end
  end

  @doc "Checks a motion link's attest before the MAC is verified."
  def attest_verdict(state, generation, a) do
    ml = state.motion.link
    link = state.link

    cond do
      ml == nil or ml.generation != generation ->
        {:error, :unknown_motion_link}

      ml.attempted ->
        {:error, :second_attest}

      a.motion_link_generation != generation ->
        {:error, :generation_mismatch}

      a.command_link_generation != ml.command_generation ->
        {:error, :command_generation_mismatch}

      a.adapter_instance_id != ml.adapter ->
        {:error, :adapter_mismatch}

      link == nil or link.generation != ml.command_generation or not link.token_verified ->
        {:error, :command_link_not_current}

      true ->
        :ok
    end
  end

  # -- exclusivity ---------------------------------------------------------------------------------------

  @doc "Whether an M6 transform command may be issued (`:ok`) or a motion session holds the candidate."
  def transform_allowed(state) do
    case Enum.find(
           state.motion.session_order,
           &(state.motion.sessions[&1].state not in @releasing)
         ) do
      nil -> :ok
      sid -> {:error, {:motion_session_not_restored, sid, state.motion.sessions[sid].state}}
    end
  end

  # -- issuance -------------------------------------------------------------------------------------------

  @doc """
  The motion entries' part of `prepare`: `{:ok, canonical_params, meta}` or `{:error, reason}`.
  `ctx_fun` builds the verified-journal context (the authority's `binding_context/2`);
  `m6_unrestored` is the id of an M6 forward without a confirmed restoration, or nil.
  """
  def prepare(state, %{effect: :share} = entry, params, opts, _ctx_fun, _m6) do
    st = Keyword.get(opts, :share_statement)

    with true <- is_map(st) or {:error, :share_statement_required},
         {:ok, valid} <- Schema.validate_params(entry, params),
         :ok <- bound_link(state, valid["motion_link_generation"]),
         true <- valid["share_id"] == st[:share_id] or {:error, :statement_mismatch},
         true <-
           (valid["duration_ms"] == st[:duration_ms] and valid["interval_ms"] == st[:interval_ms]) or
             {:error, :statement_mismatch},
         true <-
           not Enum.any?(state.motion.shares, fn {_, s} -> s.state in [:accepted, :open] end) or
             {:error, :share_exists} do
      {:ok, valid,
       %{
         kind: :share_open,
         id: valid["share_id"],
         record: %{
           "share_id" => valid["share_id"],
           "peer" => stringify(st[:peer]),
           "label" => st[:label],
           "label_note" =>
             "operator share statement; samples leave this machine to the named peer only"
         }
       }}
    end
  end

  def prepare(state, %{effect: :motion} = entry, params, opts, ctx_fun, m6_unrestored) do
    with {:ok, supplied} <- Schema.validate_supplied(entry, params) do
      case supplied["mode"] do
        "open" -> prepare_open(state, entry, supplied, opts, ctx_fun, m6_unrestored)
        "restore" -> prepare_restore(state, entry, supplied, opts, ctx_fun)
        _ -> {:error, {:invalid_param, "mode", :missing}}
      end
    end
  end

  defp prepare_open(state, entry, supplied, opts, ctx_fun, m6_unrestored) do
    ap = Keyword.get(opts, :motion_approval)
    m = state.motion

    with true <- is_map(ap) or {:error, :motion_approval_required},
         true <- not Map.has_key?(supplied, "target_world") or {:error, :open_carries_no_target},
         true <- not Map.has_key?(supplied, "restore_of") or {:error, :open_carries_no_target},
         true <- supplied["session_id"] == ap[:session_id] or {:error, :approval_mismatch},
         true <- ap[:mapping] == "identity" or {:error, {:mapping_not_supported, ap[:mapping]}},
         true <- ap[:source_kind] in ["game", "synthetic"] or {:error, :source_kind_invalid},
         {:ok, limits} <- Destination.limits(ap[:limits] || %{}),
         :ok <- bound_link(state, ap[:motion_link_generation]),
         true <-
           supplied["motion_link_generation"] in [nil, ap[:motion_link_generation]] or
             {:error, :approval_mismatch},
         true <- m6_unrestored == nil or {:error, {:m6_forward_unrestored, m6_unrestored}},
         :ok <- earlier_sessions_restored(m),
         true <-
           opened_count(m) < m.max_sessions or
             {:error, {:motion_session_budget_exhausted, m.max_sessions}},
         true <- not Map.has_key?(m.sessions, ap[:session_id]) or {:error, :session_id_reused},
         {:ok, ctx} <- ctx_fun.(),
         {:ok, q} <- TransformBinding.qualify(ctx, Keyword.get(opts, :inspection_command_id)),
         canonical =
           Map.merge(expectations(q), %{
             "mode" => "open",
             "session_id" => ap[:session_id],
             "motion_link_generation" => ap[:motion_link_generation],
             "duration_ms" => limits.duration_ms,
             "half_extent_mm" => limits.half_extent_mm,
             "max_speed_mmps" => limits.max_speed_mmps,
             "credit_ms" => limits.credit_ms,
             "min_apply_interval_ms" => @native_limits.min_apply_interval_ms,
             "silence_close_ms" => @native_limits.silence_close_ms
           }),
         :ok <- compare(supplied, canonical),
         {:ok, valid} <- Schema.validate_params(entry, canonical) do
      {:ok, valid,
       %{
         kind: :session_open,
         id: ap[:session_id],
         binding: binding_of(q),
         record: %{
           "session_id" => ap[:session_id],
           "peer" => stringify(ap[:peer]),
           "stream_id" => ap[:stream_id],
           "source_kind" => ap[:source_kind],
           "mapping" => "identity",
           "limits" => stringify(limits),
           "label" =>
             "local operator approval; fixed before application; no peer message can open, extend or widen it"
         }
       }}
    end
  end

  defp prepare_restore(state, entry, supplied, opts, ctx_fun) do
    sid = supplied["session_id"]
    rec = state.motion.sessions[sid]

    with true <- rec != nil or {:error, {:unknown_motion_session, sid}},
         true <- rec.state == :closed_clean or {:error, {:session_not_restorable, rec.state}},
         true <-
           not Map.has_key?(supplied, "motion_link_generation") or
             {:error, :restore_carries_no_limits},
         {:ok, ctx} <- ctx_fun.(),
         {:ok, facts} <- journal_facts(ctx.journal.entries, sid, rec.open_command_id),
         {:ok, q} <- TransformBinding.qualify(ctx, Keyword.get(opts, :inspection_command_id)),
         true <- q.journal_seq > facts.closed_seq or {:error, :inspection_not_after_close},
         true <- q.adapter == facts.adapter or {:error, :inspection_adapter_mismatch},
         :ok <- restore_state(q.world, facts),
         canonical =
           Map.merge(expectations(q), %{
             "mode" => "restore",
             "session_id" => sid,
             "target_world" => facts.preimage,
             "restore_of" => rec.open_command_id
           }),
         :ok <- compare(supplied, canonical),
         {:ok, valid} <- Schema.validate_params(entry, canonical) do
      {:ok, valid,
       %{
         kind: :session_restore,
         id: sid,
         binding:
           Map.merge(binding_of(q), %{
             "restore_of_session" => sid,
             "closed_journal_seq" => facts.closed_seq,
             "final_world" => facts.final,
             "target_world" => facts.preimage
           }),
         record: %{"session_id" => sid}
       }}
    end
  end

  @doc """
  The release of a cleanly closed session whose candidate is already at its opening preimage: the
  same history and inspection rules as a restore, with the inspection's words equal to the
  preimage. `{:ok, binding}` for the journal entry, or `{:error, reason}`.
  """
  def confirm_baseline(state, sid, inspection_id, ctx_fun) do
    rec = state.motion.sessions[sid]

    with true <- rec != nil or {:error, {:unknown_motion_session, sid}},
         true <- rec.state == :closed_clean or {:error, {:session_not_restorable, rec.state}},
         {:ok, ctx} <- ctx_fun.(),
         {:ok, facts} <- journal_facts(ctx.journal.entries, sid, rec.open_command_id),
         {:ok, q} <- TransformBinding.qualify(ctx, inspection_id),
         true <- q.journal_seq > facts.closed_seq or {:error, :inspection_not_after_close},
         true <- q.adapter == facts.adapter or {:error, :inspection_adapter_mismatch},
         true <- TransformWords.encode(q.world) == facts.preimage or {:error, :not_at_baseline} do
      {:ok, Map.merge(binding_of(q), %{"session_id" => sid, "preimage" => facts.preimage})}
    end
  end

  defp restore_state(words, facts) do
    text = TransformWords.encode(words)

    cond do
      text == facts.preimage -> {:error, :already_at_baseline}
      text != facts.final -> {:error, :candidate_moved_since_close}
      true -> :ok
    end
  end

  # the session's opening preimage (its open's journaled terminal) and its native-confirmed clean
  # close (the hub's journaled summary): lost or uncertain history is never eligible
  defp journal_facts(entries, sid, open_id) do
    terminal =
      Enum.filter(entries, &(&1["event"] == "command.terminal" and &1["command_id"] == open_id))

    accepted =
      Enum.filter(entries, &(&1["event"] == "command.accepted" and &1["command_id"] == open_id))

    closed =
      Enum.filter(
        entries,
        &(&1["event"] == "motion.session.closed" and &1["session_id"] == sid)
      )

    with [t] <- terminal,
         [a] <- accepted,
         "applied" <- t["status"],
         {:ok, preimage} <- observed_text(t["observed"], "opening_world"),
         true <- preimage == a["params"]["expect_world"],
         [c | _] <- Enum.reverse(closed),
         %{"restorable" => true, "native_close" => %{"final_world" => final}}
         when is_binary(final) <-
           c["summary"],
         {:ok, adapter} <- adapter_of(entries, a["link_generation"]) do
      {:ok, %{preimage: preimage, final: final, closed_seq: c["seq"], adapter: adapter}}
    else
      _ -> {:error, :session_history_not_restorable}
    end
  end

  defp adapter_of(entries, generation) do
    case Enum.filter(
           entries,
           &(&1["event"] == "peer.identified" and &1["link_generation"] == generation)
         ) do
      [%{"adapter_instance_id" => id}] -> {:ok, id}
      _ -> {:error, :adapter_identity_not_journaled}
    end
  end

  defp observed_text(observed, key) when is_map(observed) do
    case Schema.observed_value(observed[key]) do
      {:ok, v} when is_binary(v) -> {:ok, v}
      _ -> :error
    end
  end

  defp observed_text(_, _), do: :error

  defp bound_link(state, generation) do
    ml = state.motion.link

    cond do
      not state.motion.enabled -> {:error, :motion_disabled}
      ml == nil or not ml.bound -> {:error, :motion_link_not_bound}
      ml.generation != generation -> {:error, :motion_link_not_current}
      ml.command_generation != state.link.generation -> {:error, :motion_link_not_current}
      true -> :ok
    end
  end

  defp earlier_sessions_restored(m) do
    case Enum.find(m.session_order, &(m.sessions[&1].state not in @releasing)) do
      nil -> :ok
      sid -> {:error, {:earlier_session_not_restored, sid, m.sessions[sid].state}}
    end
  end

  defp opened_count(m), do: Enum.count(m.sessions, fn {_, s} -> s.state != :not_opened end)

  defp expectations(q),
    do: %{
      "expect_world" => TransformWords.encode(q.world),
      "expect_local" => TransformWords.encode(q.local),
      "expect_parent" => if(q.parent == :none, do: "none", else: q.parent)
    }

  defp compare(supplied, canonical) do
    case Enum.find(Map.keys(supplied), &(supplied[&1] != canonical[&1])) do
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
      "verified_by" => "authority"
    }

  defp stringify(nil), do: nil
  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # -- registry transitions -----------------------------------------------------------------------------

  @doc "The command was transmitted: the share or session is `accepted` (or `restoring`)."
  def on_transmitted(state, %{motion: %{kind: kind, id: id}} = cmd) do
    m = state.motion

    m =
      case kind do
        :share_open ->
          put_in(m.shares[id], %{state: :accepted, command_id: cmd.id})

        :session_open ->
          %{
            m
            | sessions:
                Map.put(m.sessions, id, %{state: :accepted, open_command_id: cmd.id, summary: nil}),
              session_order: m.session_order ++ [id]
          }

        :session_restore ->
          update_in(
            m.sessions[id],
            &Map.merge(&1, %{state: :restoring, restore_command_id: cmd.id})
          )
      end

    %{state | motion: m}
  end

  def on_transmitted(state, _cmd), do: state

  @doc """
  A terminal result for a motion command: the registry transition and the facts for the hub
  (`{:share | :session, id, status, facts}`), or nil.
  """
  def on_terminal(state, %{motion: %{kind: kind, id: id}} = cmd, result) do
    status = Schema.status_atom(result.status)
    nonapplication = Schema.nonapplication?(result.status)
    m = state.motion

    case kind do
      :share_open ->
        new =
          if status == :applied,
            do: :open,
            else: if(nonapplication, do: :not_opened, else: :open_failed)

        {%{state | motion: put_in(m.shares[id].state, new)}, {:share, id, status, %{}}}

      :session_open ->
        opening = observed_text(result.observed, "opening_world")

        {new, notify} =
          cond do
            status == :applied and opening == {:ok, cmd.params["expect_world"]} ->
              {:open, :applied}

            status == :applied ->
              {:open_unverified, :open_unverified}

            nonapplication ->
              {:not_opened, status}

            true ->
              {:open_failed, status}
          end

        facts = %{opening_world: elem_or_nil(opening)}
        {%{state | motion: put_in(m.sessions[id].state, new)}, {:session, id, notify, facts}}

      :session_restore ->
        target = cmd.params["target_world"]

        post =
          case TransformReadback.words(
                 result.observed && result.observed["postimage_world_words"],
                 :world
               ) do
            {:ok, words} -> TransformWords.encode(words)
            _ -> nil
          end

        new =
          cond do
            status == :applied and post == target -> :restored
            status == :applied -> :restore_not_exact
            nonapplication -> :closed_clean
            true -> :restore_unknown
          end

        {%{state | motion: put_in(m.sessions[id].state, new)}, nil}
    end
  end

  def on_terminal(state, _cmd, _result), do: {state, nil}

  @doc "An unknown outcome for a motion command (possible effect): never released."
  def on_unknown(state, %{motion: %{kind: kind, id: id}}) do
    m = state.motion

    case kind do
      :share_open ->
        {%{state | motion: put_in(m.shares[id].state, :open_unknown)},
         {:share, id, :unknown, %{}}}

      :session_open ->
        {%{state | motion: put_in(m.sessions[id].state, :open_unknown)},
         {:session, id, :unknown, %{}}}

      :session_restore ->
        {%{state | motion: put_in(m.sessions[id].state, :restore_unknown)}, nil}
    end
  end

  def on_unknown(state, _cmd), do: {state, nil}

  @doc "A hub event (journaled by the authority first): the registry transition it implies."
  def on_event(state, %{"event" => "motion.session.closed", "session_id" => sid, "summary" => s}) do
    case state.motion.sessions[sid] do
      %{state: :open} ->
        new =
          cond do
            s.restorable == true -> :closed_clean
            s.close && s.close.state == :unknown -> :close_unknown
            true -> :closed_unclean
          end

        put_in(state.motion.sessions[sid], %{state.motion.sessions[sid] | state: new, summary: s})

      _ ->
        state
    end
  end

  def on_event(state, %{"event" => "motion.share.closed", "share_id" => id}) do
    case state.motion.shares[id] do
      %{state: :open} -> put_in(state.motion.shares[id].state, :closed)
      _ -> state
    end
  end

  def on_event(state, _entry), do: state

  defp elem_or_nil({:ok, v}), do: v
  defp elem_or_nil(_), do: nil

  @doc "The motion part of the authority's status (no secret: the nonce is not shown)."
  def status(state) do
    m = state.motion

    %{
      enabled: m.enabled,
      max_sessions: m.max_sessions,
      link:
        m.link &&
          %{
            generation: m.link.generation,
            bound: m.link.bound,
            command_generation: m.link.command_generation,
            adapter_instance_id: m.link.adapter
          },
      sessions:
        Enum.map(m.session_order, fn sid ->
          s = m.sessions[sid]
          %{session_id: sid, state: s.state, open_command_id: s.open_command_id}
        end),
      shares: Enum.map(m.shares, fn {id, s} -> %{share_id: id, state: s.state} end),
      exclusivity: transform_allowed(state)
    }
  end
end
