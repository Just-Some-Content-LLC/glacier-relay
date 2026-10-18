# M6-F2a: the bounded, read-only follow-up sampler of the M6-F transform experiment (loaded by cmd-m6f.exs; operator tooling, not
# production code). It is handed ONE already-issued lift's command id and a validated schedule, and it ONLY observes:
#
#   - it waits for the lift's authoritative terminal (the authority's command record, polled), notes the monotonic time at which
#     THIS process observed it, and follows only an `applied` terminal (failed / refused / expired / unknown / precondition_failed:
#     no read and no retry);
#   - it then issues at most six relay.inspect.candidate_transform/1 requests through the existing public Command API — the first as
#     early as practical, the others at deadlines after the observed terminal (default 0, 250 ms, 1 s, 2 s, 5 s, 10 s) — at most one
#     in flight, with a declared overall deadline; a request that cannot be sent within its slot's window is recorded as MISSED and
#     no substitute is issued (no catch-up burst, no queue, no continuous polling, no retry);
#   - each result is classified with the committed classes (Command.TransformReadback.classify_later/3: held, returned_to_baseline,
#     near_target, near_baseline, drifted, indeterminate, unavailable; a read on the lift's own or an earlier frame is
#     "not_a_later_frame", never relabelled) and journaled through Command.observe/4 ("later_frame_read_back"); one line per
#     sample is appended to the caller's evidence file as soon as the sample is complete;
#   - it stops at the first hard condition: an operator stop (also one written during a long terminal wait: no read then), a
#     changed identity (node, authority, journal, link generation, adapter), a degraded audit, a refused / withheld / not-applied
#     / reduced / malformed read, a result received after its bound (recorded, then result_late), a changed link / adapter /
#     generation context, an invalid identity, an aliased candidate, a qualification the read could not observe, a read not on
#     one frame, an RPC failure, or the overall deadline.
#
# What it never does: it holds no function that arms, lifts, restores, sets an outfit or reverses anything — the client map it
# is given contains exactly the keys below, and nothing here names an effectful API. A result (held, returned, drifted, ...) is an
# observation, never a trigger. Timing is kept on separate clocks: this process's monotonic clock for request / receipt / lateness;
# the native frame numbers and the native timestamps (one native process clock) for the observations; the authority's own stage
# ladder (its clock) as recorded by it. No difference between clocks of different processes is ever computed.
#
# The client (all functions; the tests pass a scripted fake with a virtual clock):
#   now_us.()                 this process's monotonic time in microseconds
#   sleep_ms.(ms)             sleep
#   inspect.(ttl_ms)          Command.inspect_candidate_transform(ttl_ms: ttl_ms)  -> {:ok, id} | {:error, reason} | other
#   command.(id)              Command.command(id)                                  -> record | nil | other
#   identity.()               a cheap identity snapshot (a map with @identity_keys and the state keys)
#   observe.(orig, insp, txt) Command.observe(orig, "later_frame_read_back", txt, inspection_command_id: insp)
#   stop?.()                  true when the operator's stop marker exists
#   emit.(map)                append one JSON line to the follow evidence file (best effort; its failure is recorded)
defmodule M6fFollow do
  @moduledoc false

  alias GlacierRelay.Command.TransformReadback

  @schedule_ms [0, 250, 1_000, 2_000, 5_000, 10_000]
  @max_requests 6
  @defaults %{
    schedule_ms: @schedule_ms,
    # a request sent no later than this after its deadline is on time; up to the slot's window it is delayed; beyond, missed
    on_time_ms: 25,
    # a slot's window: min(max_late_ms, half the gap to the next deadline); the last slot's window is max_late_ms
    max_late_ms: 250,
    # one request's result must be received within this (else: withheld, stop)
    request_timeout_ms: 2_000,
    # the TTL each inspection carries (the authority's own bounds still apply)
    inspection_ttl_ms: 2_000,
    # the polling interval for the lift's terminal and each result (one RPC per poll)
    poll_ms: 2,
    # the bound on the wait for the lift's terminal (as cmd-m6f.exs's lift wait)
    terminal_timeout_ms: 20_000,
    # the identity check before a later slot starts this long before its deadline
    identity_lead_ms: 15,
    # targets judged in the report (never used for control flow): the first request after the observed terminal (this
    # process's clock) and the first later native observation after the lift's native timestamp (the native clock)
    first_request_target_ms: 20,
    first_observation_target_ms: 150
  }
  @identity_keys [:node_os_pid, :authority_pid, :journal_pid, :journal_id, :link_generation, :adapter_instance_id]
  @pending [:accepted, :transmitted, :received]
  # the identity block of every later read must equal the binding inspection's
  @identity_fields ~w(targets cand_brick_owner cand_brick_present cand_index_check cand_resolved cand_hitman5 cand_id_match cand_spatial)
  @classes ~w(held returned_to_baseline near_target near_baseline drifted indeterminate unavailable)
  @client_keys [:now_us, :sleep_ms, :inspect, :command, :identity, :observe, :stop?, :emit]

  def defaults, do: @defaults
  def max_requests, do: @max_requests
  def identity_keys, do: @identity_keys
  def client_keys, do: @client_keys
  def classes, do: @classes

  @doc "Validates the options into a plan (before any lift is sent). {:ok, plan} | {:error, reason}."
  def plan(opts \\ []) do
    p = Map.merge(@defaults, Map.new(opts))
    s = p.schedule_ms
    int_in = fn v, lo, hi -> is_integer(v) and v >= lo and v <= hi end

    cond do
      Map.keys(p) -- Map.keys(@defaults) != [] -> {:error, {:unknown_options, Map.keys(p) -- Map.keys(@defaults)}}
      not is_list(s) or s == [] -> {:error, :schedule_empty}
      length(s) > @max_requests -> {:error, {:schedule_longer_than, @max_requests}}
      not Enum.all?(s, &int_in.(&1, 0, 60_000)) -> {:error, :schedule_values_out_of_range}
      s != Enum.uniq(Enum.sort(s)) -> {:error, :schedule_not_strictly_increasing}
      not int_in.(p.on_time_ms, 0, 1_000) -> {:error, :on_time_out_of_range}
      not int_in.(p.max_late_ms, p.on_time_ms, 1_000) -> {:error, :max_late_out_of_range}
      not int_in.(p.request_timeout_ms, 100, 10_000) -> {:error, :request_timeout_out_of_range}
      not int_in.(p.inspection_ttl_ms, 100, 10_000) -> {:error, :inspection_ttl_out_of_range}
      not int_in.(p.poll_ms, 1, 50) -> {:error, :poll_out_of_range}
      not int_in.(p.terminal_timeout_ms, 1_000, 60_000) -> {:error, :terminal_timeout_out_of_range}
      not int_in.(p.identity_lead_ms, 0, 100) -> {:error, :identity_lead_out_of_range}
      not int_in.(p.first_request_target_ms, 0, 60_000) -> {:error, :first_request_target_out_of_range}
      not int_in.(p.first_observation_target_ms, 0, 60_000) -> {:error, :first_observation_target_out_of_range}
      true ->
        w = windows(s, p.max_late_ms)
        {:ok, Map.merge(p, %{windows_ms: w, overall_deadline_ms: List.last(s) + List.last(w) + p.request_timeout_ms})}
    end
  end

  defp windows(s, max_late) do
    Enum.zip(s, tl(s) ++ [nil])
    |> Enum.map(fn
      {_, nil} -> max_late
      {a, b} -> min(max_late, div(b - a, 2))
    end)
  end

  @doc """
  Follows ONE issued lift. `ctx`: :original_id, :expected_generation, :link_generation and :adapter_instance_id (the status
  before the lift), :baseline_identity (an identity snapshot taken before the lift), :binding_observed (the binding inspection's
  observed map: the identity block and the local-hero control are compared against it), optional :after_first_request (called
  once, right after the first request is in flight or when the sequence ends without one; cmd-m6f.exs does not use it: it
  records the lift's issuance before calling run/3, so a crash during the terminal wait cannot hide an issued lift).
  Returns a map with :original, :terminal_observed_us, :slots, :stop (nil = the schedule ran to its end), :requests.
  """
  def run(c, plan, ctx) do
    missing = @client_keys -- Map.keys(c)
    if missing != [], do: raise(ArgumentError, "follow client lacks #{inspect(missing)}")
    Process.delete(:m6f_follow_emit_errors)
    t0 = c.now_us.()
    # the operator's stop marker is checked when the wait for the terminal begins (one file check costs milliseconds on the
    # Windows filesystem), every 250 ms while that wait lasts longer than 250 ms, and before every later slot — never between
    # the observed terminal and an immediate (0 ms) first request
    stopped_before = stop_check(c) != :ok

    case wait_terminal(c, plan, ctx.original_id, t0) do
      {:ok, orig, t_term, polls, stopped_during} when stopped_before or stopped_during ->
        ctx = Map.put(ctx, :first_fun, fn -> if is_function(ctx[:after_first_request], 0), do: safe(ctx.after_first_request) end)
        finish(c, ctx, plan, %{t0_us: t0, terminal_observed_us: t_term, terminal_polls: polls, terminal_wait_ms: ms(t_term - t0), original: summary(orig), slots: not_reached(indexed(plan)), stop: :operator_stop})

      {:ok, orig, t_term, polls, _} ->
        base = %{t0_us: t0, terminal_observed_us: t_term, terminal_polls: polls, terminal_wait_ms: ms(t_term - t0), original: summary(orig)}

        # the deferred work once the first request is in flight (or the sequence ends without one): the original's line, then
        # the caller's own writes (its command-id file and log line) — never between the observed terminal and the first request
        first = fn ->
          emit(c, %{"event" => "follow.original", "terminal_wait_ms" => base.terminal_wait_ms, "terminal_polls" => polls, "original" => jsonable(base.original)})
          if is_function(ctx[:after_first_request], 0), do: safe(ctx.after_first_request)
        end

        ctx = Map.put(ctx, :first_fun, first)

        case followable(orig, ctx) do
          {:ok, lift} ->
            {slots, stop} = slot_loop(indexed(plan), c, plan, ctx, lift, t_term, [], 0)
            finish(c, ctx, plan, Map.merge(base, %{slots: slots, stop: stop}))

          {:stop, reason} ->
            finish(c, ctx, plan, Map.merge(base, %{slots: not_reached(indexed(plan)), stop: reason}))
        end

      {:stop, reason, info} ->
        ctx = Map.put(ctx, :first_fun, fn -> if is_function(ctx[:after_first_request], 0), do: safe(ctx.after_first_request) end)
        finish(c, ctx, plan, %{t0_us: t0, terminal_observed_us: nil, terminal_polls: info[:polls], terminal_wait_ms: ms(c.now_us.() - t0), original: info[:last] && summary(info[:last]), slots: not_reached(indexed(plan)), stop: reason})
    end
  end

  defp indexed(plan), do: Enum.zip(plan.schedule_ms, plan.windows_ms) |> Enum.with_index() |> Enum.map(fn {{d, w}, i} -> {i, d, w} end)

  defp finish(c, ctx, plan, r) do
    requested = Enum.filter(r.slots, &(&1.outcome == "requested"))
    if requested == [], do: ctx.first_fun.()

    r =
      Map.merge(r, %{
        requests: length(requested),
        emit_errors: Enum.reverse(Process.get(:m6f_follow_emit_errors, [])),
        missed: Enum.count(r.slots, &(&1.outcome == "missed")),
        plan: Map.take(plan, [:schedule_ms, :windows_ms, :on_time_ms, :max_late_ms, :request_timeout_ms, :inspection_ttl_ms, :poll_ms, :overall_deadline_ms, :identity_lead_ms, :first_request_target_ms, :first_observation_target_ms])
      })

    emit(c, %{"event" => "follow.end", "stop" => text(r.stop), "requests" => r.requests, "missed" => r.missed, "slots" => length(r.slots),
      "terminal_wait_ms" => r.terminal_wait_ms, "classes" => Enum.map(r.slots, &(&1[:class])), "timing" => Enum.map(r.slots, &(&1[:timing]))})
    r
  end

  # ---- the lift's terminal -------------------------------------------------------------------------------------------------

  defp wait_terminal(c, plan, id, t0) do
    deadline = t0 + plan.terminal_timeout_ms * 1000
    poll_terminal(c, plan, id, deadline, 0, nil, t0, t0 + 250_000, false)
  end

  # `next_stop` is when the stop marker is next looked at (first after 250 ms of waiting, then every 250 ms): a stop seen during
  # the wait is kept, the terminal is still awaited (the lift's own record), and no read follows
  defp poll_terminal(c, plan, id, deadline, polls, last, t0, next_stop, stopped) do
    r = c.command.(id)
    now = c.now_us.()

    cond do
      is_map(r) and Map.get(r, :status) not in @pending -> {:ok, r, now, polls + 1, stopped}
      is_map(r) or r == nil ->
        last = if(is_map(r), do: r, else: last)
        {stopped, next_stop} = if now >= next_stop, do: {stopped or stop_check(c) != :ok, now + 250_000}, else: {stopped, next_stop}

        if now > deadline,
          do: {:stop, :original_terminal_timeout, %{polls: polls + 1, last: last}},
          else: (c.sleep_ms.(plan.poll_ms); poll_terminal(c, plan, id, deadline, polls + 1, last, t0, next_stop, stopped))
      true -> {:stop, {:rpc_failed, short(r)}, %{polls: polls + 1, last: last}}
    end
  end

  # Only an applied lift is followed; the lift's own groups are the classification references.
  defp followable(orig, ctx) do
    res = Map.get(orig, :result)

    cond do
      orig.status != :applied -> {:stop, {:original_not_applied, orig.status, res && res.reason}}
      res == nil or not is_integer(res.frame) or not is_binary(res.native_at) -> {:stop, :original_result_incomplete}
      res.mission_generation != ctx.expected_generation -> {:stop, {:original_context_changed, :mission_generation}}
      orig.link_generation != ctx.link_generation -> {:stop, {:original_context_changed, :link_generation}}
      res.adapter_instance_id != ctx.adapter_instance_id -> {:stop, {:original_context_changed, :adapter_instance_id}}
      true ->
        a = TransformReadback.decode_apply(res.observed || %{})

        with {:ok, pre} <- a.preimage.world_words, {:ok, req} <- a.requested_world_words do
          {:ok, %{frame: res.frame, native_at: res.native_at, generation: res.mission_generation, link_generation: orig.link_generation,
            adapter: res.adapter_instance_id, preimage: pre, requested: req, preimage_local: ok_value(a.preimage.local_words),
            postimage_local: ok_value(a.postimage.local_words), parent: ok_value(a.preimage.parent)}}
        else
          _ -> {:stop, :original_groups_unobserved}
        end
    end
  end

  # ---- the slots -----------------------------------------------------------------------------------------------------------

  defp slot_loop([], _c, _p, _ctx, _lift, _t, acc, _n), do: {Enum.reverse(acc), nil}

  defp slot_loop([{i, d, w} | rest] = slots, c, p, ctx, lift, t_term, acc, n) do
    target = t_term + d * 1000

    case prepare_slot(c, p, ctx, i, target, w, t_term) do
      {:missed, late_us} ->
        rec = %{slot: i, planned_ms: d, window_ms: w, outcome: "missed", timing: "missed", lateness_ms: ms(late_us), class: nil}
        emit(c, slot_line(rec))
        slot_loop(rest, c, p, ctx, lift, t_term, [rec | acc], n)

      {:send, now} ->
        {rec, stop} = request(c, p, ctx, lift, t_term, {i, d, w}, target, now, n)
        emit(c, slot_line(rec))
        if stop, do: {Enum.reverse([rec | acc]) ++ not_reached(rest), stop}, else: slot_loop(rest, c, p, ctx, lift, t_term, [rec | acc], n + 1)

      {:stop, reason} ->
        {Enum.reverse(acc) ++ not_reached(slots), reason}
    end
  end

  defp prepare_slot(c, p, ctx, i, target, w, t_term) do
    cond do
      c.now_us.() - target > w * 1000 -> {:missed, c.now_us.() - target}
      true ->
        # only an immediate (0 ms) first request skips the checks; every other slot, a later first slot included, makes them
        immediate = i == 0 and target == t_term
        with :ok <- wait_until(c, p, target - p.identity_lead_ms * 1000, t_term),
             :ok <- (if immediate, do: :ok, else: stop_check(c)),
             :ok <- (if immediate, do: :ok, else: identity_check(c, ctx.baseline_identity)),
             :ok <- wait_until(c, p, target, t_term) do
          now = c.now_us.()
          cond do
            now - target > w * 1000 -> {:missed, now - target}
            ms(now - t_term) > p.overall_deadline_ms -> {:stop, :overall_deadline}
            true -> {:send, now}
          end
        end
    end
  end

  # sleeps until `until` in chunks of at most 100 ms, checking the operator's stop marker between chunks
  defp wait_until(c, p, until, t_term) do
    now = c.now_us.()

    cond do
      now >= until -> :ok
      ms(now - t_term) > p.overall_deadline_ms -> {:stop, :overall_deadline}
      true ->
        chunk = min(100, max(1, div(until - now + 999, 1000)))
        c.sleep_ms.(chunk)
        if chunk == 100, do: (with :ok <- stop_check(c), do: wait_until(c, p, until, t_term)), else: wait_until(c, p, until, t_term)
    end
  end

  defp stop_check(c), do: if(safe(c.stop?) == true, do: {:stop, :operator_stop}, else: :ok)

  @doc "The identity comparison (public for the tests): :ok or {:stop, reason}."
  def identity_check(c, baseline) do
    now = safe(c.identity)

    cond do
      not is_map(now) -> {:stop, {:rpc_failed, short(now)}}
      Enum.any?(Map.values(now), &match?({:badrpc, _}, &1)) -> {:stop, {:rpc_failed, :identity}}
      true ->
        changed = for k <- @identity_keys, Map.get(baseline, k) != Map.get(now, k), do: k

        bad =
          [journal_open: Map.get(now, :journal_status) == :open, audit_intact: Map.get(now, :audit) == :intact, token_verified: Map.get(now, :token_verified) == true,
           protocol_v2: Map.get(now, :protocol_version) == 2, peer_identified: Map.get(now, :peer) == :identified]
          |> Enum.reject(&elem(&1, 1))
          |> Enum.map(&elem(&1, 0))

        cond do
          changed != [] -> {:stop, {:identity_changed, changed}}
          :audit_intact in bad -> {:stop, :audit_degraded}
          bad != [] -> {:stop, {:identity_state, bad}}
          true -> :ok
        end
    end
  end

  defp request(c, p, ctx, lift, t_term, {i, d, w}, target, now, n) do
    late = now - target
    timing = cond do
      late <= p.on_time_ms * 1000 -> "on_time"
      true -> "delayed"
    end

    rec0 = %{slot: i, planned_ms: d, window_ms: w, outcome: "requested", timing: timing, lateness_ms: ms(late), request_ms: ms(now - t_term),
      request_utc: DateTime.utc_now() |> DateTime.to_iso8601(), class: nil}

    case c.inspect.(p.inspection_ttl_ms) do
      {:ok, iid} when is_binary(iid) ->
        if n == 0, do: ctx.first_fun.()
        rec1 = Map.put(rec0, :inspection_id, iid)
        limit = min(now + p.request_timeout_ms * 1000, t_term + p.overall_deadline_ms * 1000)

        case poll_result(c, p, iid, limit, 0) do
          {:ok, r, t_res, polls} when t_res > limit ->
            # a poll that blocked past the bound returned the result: the observation is recorded as it is, the receipt is late,
            # and the sequence ends there (no later slot is run on a clock already past its bound)
            {rec, stop} = evaluate(c, ctx, lift, Map.merge(rec1, %{result_ms: ms(t_res - t_term), round_trip_ms: ms(t_res - now), result_polls: polls, late_receipt: true}), r)
            {rec, stop || {:result_late, ms(t_res - limit)}}

          {:ok, r, t_res, polls} -> evaluate(c, ctx, lift, Map.merge(rec1, %{result_ms: ms(t_res - t_term), round_trip_ms: ms(t_res - now), result_polls: polls}), r)
          {:withheld, last, polls} -> {Map.merge(rec1, %{status: text(last && Map.get(last, :status)), result_polls: polls}), :result_withheld}
          {:rpc_failed, r} -> {rec1, {:rpc_failed, short(r)}}
        end

      {:error, reason} -> {Map.merge(rec0, %{outcome: "refused", refusal: text(reason)}), {:request_refused, reason}}
      other -> {Map.merge(rec0, %{outcome: "refused", refusal: short(other)}), {:rpc_failed, short(other)}}
    end
  end

  defp poll_result(c, p, iid, limit, polls) do
    r = c.command.(iid)
    now = c.now_us.()

    cond do
      is_map(r) and Map.get(r, :status) not in @pending -> {:ok, r, now, polls + 1}
      is_map(r) or r == nil ->
        if now >= limit, do: {:withheld, if(is_map(r), do: r, else: nil), polls + 1}, else: (c.sleep_ms.(p.poll_ms); poll_result(c, p, iid, limit, polls + 1))
      true -> {:rpc_failed, r}
    end
  end

  # one later read: its context, identity, words and class; the journaled observation; the separate facts
  defp evaluate(c, ctx, lift, rec, r) do
    res = Map.get(r, :result)
    obs = (res && res.observed) || %{}
    rec = Map.merge(rec, %{status: text(r.status), reason: res && res.reason, frame: res && res.frame, native_at: res && res.native_at,
      mission_generation: res && res.mission_generation, link_generation: Map.get(r, :link_generation), adapter_instance_id: res && res.adapter_instance_id,
      authority_stages: Enum.map(Map.get(r, :stages, []), fn {k, v} -> [to_string(k), v] end)})

    cond do
      r.status != :applied -> {rec, {:inspection_not_applied, r.status}}
      not is_integer(res.frame) -> {rec, :result_malformed}
      Map.get(r, :link_generation) != lift.link_generation -> {rec, {:context_changed, :link_generation}}
      res.adapter_instance_id != lift.adapter -> {rec, {:context_changed, :adapter_instance_id}}
      res.mission_generation != lift.generation -> {rec, {:context_changed, :mission_generation}}
      obs["observed_reduced"] != nil -> {rec, :result_reduced}
      true -> classify(c, ctx, lift, rec, obs)
    end
  end

  defp classify(c, ctx, lift, rec, obs) do
    d = TransformReadback.decode_inspection(obs)
    cand = d.candidate
    binding = ctx[:binding_observed] || %{}
    ident_diff = for f <- @identity_fields, Map.get(binding, f) != Map.get(obs, f), do: f
    hero_before = TransformReadback.decode_inspection(binding).hero

    facts = %{
      frames_after_lift: rec.frame - lift.frame,
      native_ms_after_lift: native_ms(lift.native_at, rec.native_at),
      later_frame: rec.frame > lift.frame,
      words: %{world: field_value(obs["cand_world_words"]), local: field_value(obs["cand_local_words"]), parent: field_value(obs["cand_parent"]), dirty: field_value(obs["cand_dirty"])},
      local_vs_preimage: compare(ok_value(cand.local_words), lift.preimage_local),
      local_vs_postimage: compare(ok_value(cand.local_words), lift.postimage_local),
      parent_vs_preimage: compare(ok_value(cand.parent), lift.parent),
      cache: case cand.dirty do {:ok, true} -> "dirty"; {:ok, false} -> "clean"; other -> text(other) end,
      qualifications: Map.new(~w(cand_distinct cand_spatial_distinct cand_in_registry registry_slots reads_on_frame receipt_to_frame_ms), &{&1, field_value(obs[&1])}),
      identity_block: if(ident_diff == [], do: "equal to the binding inspection", else: "DIFFERS: #{Enum.join(ident_diff, ",")}"),
      hero_control: TransformReadback.classify_control(hero_before, d.hero) |> to_string()
    }

    rec = Map.merge(rec, facts)
    # a qualification the read could not establish (not observed) is a stop of its own, never relabelled as aliasing or malformed
    unobserved = for {k, v} <- [cand_distinct: d.cand_distinct, cand_spatial_distinct: d.cand_spatial_distinct, cand_in_registry: d.cand_in_registry, reads_on_frame: d.reads_on_frame], not match?({:ok, b} when is_boolean(b), v), do: k

    stop =
      cond do
        ident_diff != [] -> {:identity_invalid, ident_diff}
        unobserved != [] -> {:qualification_unobserved, unobserved}
        d.cand_distinct == {:ok, false} or d.cand_spatial_distinct == {:ok, false} -> :candidate_aliasing
        d.cand_in_registry == {:ok, true} -> {:identity_invalid, [:cand_in_registry]}
        d.reads_on_frame == {:ok, false} -> :reads_not_on_one_frame
        match?({:invalid, _}, cand.world_words) or match?({:invalid, _}, cand.local_words) -> :result_malformed
        true -> nil
      end

    class =
      cond do
        stop != nil -> nil
        not facts.later_frame -> "not_a_later_frame"
        true -> to_string(TransformReadback.classify_later(cand, lift.preimage, lift.requested))
      end

    rec = Map.put(rec, :class, class)

    if stop != nil do
      {rec, stop}
    else
      text = "M6-F2 follow slot #{rec.slot}: planned +#{rec.planned_ms} ms, requested +#{rec.request_ms} ms after the observed terminal (#{rec.timing})"

      case safe(fn -> c.observe.(ctx.original_id, rec.inspection_id, text) end) do
        {:ok, o} when is_map(o) ->
          {Map.merge(rec, %{conclusion: o["conclusion"], conclusion_agrees: o["conclusion"] == class}), nil}

        other ->
          {Map.merge(rec, %{conclusion: nil, conclusion_agrees: false, observe_error: short(other)}), nil}
      end
    end
  end

  # ---- helpers -------------------------------------------------------------------------------------------------------------

  defp summary(r) do
    res = Map.get(r, :result)
    obs = (res && res.observed) || %{}

    %{id: Map.get(r, :id), status: text(Map.get(r, :status)), reason: res && res.reason, frame: res && res.frame, native_at: res && res.native_at,
      mission_generation: res && res.mission_generation, link_generation: Map.get(r, :link_generation), adapter_instance_id: res && res.adapter_instance_id,
      authority_stages: Enum.map(Map.get(r, :stages, []), fn {k, v} -> [to_string(k), v] end),
      effect: field_value(obs["effect"]), world_match: field_value(obs["world_match"]), local_match: field_value(obs["local_match"]),
      setter_called: field_value(obs["setter_called"]), hero_control: field_value(obs["hero_control"])}
  end

  defp not_reached(slots), do: Enum.map(slots, fn {i, d, w} -> %{slot: i, planned_ms: d, window_ms: w, outcome: "not_reached", timing: "not_reached", class: nil} end)

  defp slot_line(rec) do
    rec
    |> Map.new(fn {k, v} -> {to_string(k), jsonable(v)} end)
    |> Map.put("event", "follow.slot")
  end

  defp emit(c, map) do
    case safe(fn -> c.emit.(map) end) do
      :ok -> :ok
      other -> Process.put(:m6f_follow_emit_errors, [short(other) | Process.get(:m6f_follow_emit_errors, [])])
    end
  end

  defp jsonable(v) when is_map(v), do: Map.new(v, fn {k, x} -> {to_string(k), jsonable(x)} end)
  defp jsonable(v) when is_list(v), do: Enum.map(v, &jsonable/1)
  defp jsonable(v) when is_tuple(v), do: inspect(v)
  defp jsonable(v) when is_atom(v) and v not in [nil, true, false], do: to_string(v)
  defp jsonable(v), do: v

  defp field_value(%{"status" => "observed", "value" => v}), do: v
  defp field_value(%{"status" => s} = f), do: "#{s}#{if f["reason"], do: " (" <> to_string(f["reason"]) <> ")", else: ""}"
  defp field_value(nil), do: "missing"
  defp field_value(other), do: inspect(other)

  defp ok_value({:ok, v}), do: v
  defp ok_value(_), do: nil

  defp compare(nil, _), do: "unobserved"
  defp compare(_, nil), do: "no reference"
  defp compare(a, b), do: if(a == b, do: "bit-equal", else: "different")

  defp native_ms(a, b) do
    with {:ok, ta, _} <- DateTime.from_iso8601(a || ""), {:ok, tb, _} <- DateTime.from_iso8601(b || "") do
      DateTime.diff(tb, ta, :millisecond)
    else
      _ -> nil
    end
  end

  defp ms(us) when is_integer(us), do: Float.round(us / 1000, 3)
  defp ms(_), do: nil

  def text(nil), do: nil
  def text(v) when is_binary(v), do: v
  def text(v) when is_atom(v), do: to_string(v)
  def text(v), do: inspect(v)

  defp short(v), do: v |> inspect() |> String.slice(0, 200)

  defp safe(f) do
    try do
      f.()
    rescue
      e -> {:raised, Exception.message(e) |> String.slice(0, 200)}
    catch
      kind, value -> {:caught, kind, inspect(value) |> String.slice(0, 200)}
    end
  end
end
