defmodule GlacierRelay.Test.FakeMotionNative do
  @moduledoc """
  M7-B1 test support: a fake native adapter for the motion contract (`docs/design/M7_NETWORK_GHOST.md`
  section 15.5). It holds a version-2, token-attested command link (`127.0.0.1:<command port>`) and
  a bound motion link (`127.0.0.1:<motion port>`), answers the exact inspection, the share, the
  motion session's open and restore, and the M6 v2 step, and models the native rules in a process
  of its own: a 10 ms frame timer, one pending target slot, at most one apply per frame and per
  40 ms, the pre-call checks (sequence, untouched words equal to the opening snapshot's, area,
  displacement from the last applied postimage), `skipped_identical`, uncertain post-calls, a
  report every 250 ms after the first target, and the **autonomous closes** — duration, target
  silence, either link's loss, a generation change — which keep running when the relay's
  processes are suspended.

  M7-B1 correction: a successful restore answers with the restoration-result contract's typed
  fields (`docs/design/M7_NETWORK_GHOST.md` section 15.4; the same field names as the M6 transform
  result) — requested and observed world words, observed parent-relative words, parent, dirty
  state, entity and generation continuity, the control comparison, invocation and effect — each of
  which a test can replace or omit (`{:restore_field, key, value | :omit}`), or answer with another
  status (`{:restore_status, status}`). Every `ghost.target` line read from the motion socket is
  logged (`{:target_line, session_id, seq, fake_ms}`), so a test can show which target bytes
  reached the native; `:hold_motion_out` queues every line the fake would write on the motion link
  until `release_motion_out/1` (in order; `hold_motion_out/1` sets it and answers the share's last
  written sequence number in one step, and `release_motion_out/2` writes only the first `n` held
  lines and keeps holding — M7-L1 correction: a test's explicit control of which sample the relay
  sees, and when); `{:share_overrun_ms, ms}` keeps the fake's share
  sampling past its own duration, and `{:session_overrun_ms, ms}` its session open past its own
  duration (a native whose own close comes late).

  It is test tooling only and **never evidence of native game execution**: every result it
  writes is fake-native evidence, and that its timers close a session says nothing about the DLL
  (whose native enforcement is M7-B2's). Faults are injected with `fault/2`.
  """

  use GenServer

  alias GlacierRelay.Command.{Schema, TransformWords}
  alias GlacierRelay.Motion.Codec
  alias GlacierRelay.Test.FakeNative

  @frame_ms 10
  @report_ms 250
  @gen "2516099488895124066-977411ea-01df-435f-b375-efa4cf625963"
  @brick "007c57a6ea581f8c"
  @entity "feede715906f747f"
  # M6-E3's words: the candidate at P, its parent-relative group, the local hero beside it
  @pre "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,c2b2fae1,416d47ae,bfc2d6ba"
  @local "c2b2fae1,416d47ae,bfc2d6ba,80000000,00000000,80000000,3f800000"
  @hero_world "3e2b7674,bf7c62bd,00000000,3f7c62bd,3e2b7674,00000000,00000000,00000000,3f800000,c2a77ccf,416b27e8,bfc2d6ba"
  @hero_local "c2a77ccf,416b27e8,bfc2d6ba,80000000,00000000,3f252b92,3f43969f"
  @caps [
    "relay.probe/1",
    "relay.inspect.candidate_transform/1",
    "candidate.transform.set/1",
    "candidate.transform.set/2",
    "player.pose.share/1",
    "candidate.motion.session/1"
  ]

  def generation, do: @gen
  def pre, do: @pre
  def anchor_words, do: {0xC2B2FAE1, 0x416D47AE}
  def capabilities, do: @caps

  # -- API -------------------------------------------------------------------------------------------

  @doc """
  Connects and binds. `opts`: `:command_port`, `:motion_port`, `:token`, `:adapter_id`,
  `:capabilities`, `:world` (the candidate's 12 words), `:bind_motion` (default true),
  `:hero_step_m` (the fake hero's x step per sample; default 0.05).
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def status(pid), do: GenServer.call(pid, :status)
  def events(pid), do: pid |> status() |> Map.fetch!(:events)
  def fault(pid, fault), do: GenServer.call(pid, {:fault, fault})
  def clear_fault(pid, fault), do: GenServer.call(pid, {:clear_fault, fault})
  def set_world(pid, world), do: GenServer.call(pid, {:set_world, world})
  def set_generation(pid, gen), do: GenServer.call(pid, {:set_generation, gen})
  def drop_motion(pid), do: GenServer.call(pid, :drop_motion)
  def drop_command(pid), do: GenServer.call(pid, :drop_command)
  def bind_motion(pid), do: GenServer.call(pid, :bind_motion)
  def release_motion_out(pid), do: GenServer.call(pid, :release_motion_out)
  def release_motion_out(pid, n), do: GenServer.call(pid, {:release_motion_out, n})

  @doc "Sets `:hold_motion_out`; answers `{:ok, last_seq}`, the share's last WRITTEN sample (or nil)."
  def hold_motion_out(pid), do: GenServer.call(pid, :hold_motion_out)
  def stop(pid), do: GenServer.stop(pid)

  @doc "An observed read-back field object (for `{:restore_field, key, value}`)."
  def obs(value), do: f(value)

  @doc "The candidate's parent-relative words and parent in the fake's results."
  def local, do: @local
  def parent, do: @brick

  # -- raw helpers for binding tests -------------------------------------------------------------------

  def connect_line(port) do
    {:ok, s} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [
        :binary,
        packet: :line,
        active: false,
        packet_size: 8_192
      ])

    s
  end

  def recv_line(socket, timeout \\ 1_000) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, line} -> {:ok, line |> String.trim_trailing("\n") |> JSON.decode!()}
      error -> error
    end
  end

  def motion_hello(adapter, command_generation),
    do:
      Codec.encode_from_native("motion.hello", %{
        "adapter_instance_id" => adapter,
        "command_link_generation" => command_generation
      })

  def motion_attest(token, welcome, command_generation, adapter, overrides \\ %{}) do
    mg = welcome["motion_link_generation"]

    Codec.encode_from_native(
      "motion.attest",
      Map.merge(
        %{
          "motion_link_generation" => mg,
          "command_link_generation" => command_generation,
          "adapter_instance_id" => adapter,
          "mac" =>
            Schema.motion_attest_mac(token, welcome["nonce"], mg, command_generation, adapter)
        },
        overrides
      )
    )
  end

  @doc "A qualifying exact-inspection read-back for `world` (the transform tests' fixture)."
  def qualifying(world, overrides \\ %{}) do
    Map.merge(
      %{
        "generation_fresh" => f(@gen),
        "targets" => f("#{@brick},#{@entity}"),
        "snapshot_version" => f(1),
        "cand_brick_present" => f(true),
        "cand_index_check" => f("in_range"),
        "cand_resolved" => f(true),
        "cand_hitman5" => f(true),
        "cand_id_match" => f(true),
        "cand_distinct" => f(true),
        "cand_brick_owner" => f(@brick),
        "cand_spatial" => f(true),
        "cand_spatial_distinct" => f(true),
        "registry_slots" => f("0:local,1:empty,2:empty,3:empty"),
        "cand_in_registry" => f(false),
        "cand_world_words" => f(world),
        "cand_local_words" => f(@local),
        "cand_dirty" => f(false),
        "cand_parent" => f(@brick),
        "cand_world" =>
          f(TransformWords.translation_text(elem(TransformWords.decode_world(world), 1))),
        "hero_entity_id" => f("69bdf7f855ea15e0"),
        "hero_world_words" => f(@hero_world),
        "hero_local_words" => f(@hero_local),
        "hero_dirty" => f(false),
        "hero_parent" => f("00b6cedd6778f19c"),
        "reads_on_frame" => f(true)
      },
      overrides
    )
  end

  defp f(value), do: FakeNative.field("observed", value)

  # -- the process -----------------------------------------------------------------------------------

  @impl true
  def init(opts) do
    token = Keyword.fetch!(opts, :token)
    adapter = Keyword.get(opts, :adapter_id, Schema.uuid4())
    caps = Keyword.get(opts, :capabilities, @caps)
    cmd = connect_line(Keyword.fetch!(opts, :command_port))

    :ok =
      :gen_tcp.send(
        cmd,
        JSON.encode!(%{
          "command_protocol_version" => 2,
          "kind" => "hello",
          "adapter_instance_id" => adapter,
          "native_at" => "2026-10-19T00:00:00.000Z",
          "mission_generation" => @gen,
          "capabilities" => caps
        }) <> "\n"
      )

    {:ok, welcome} = recv_line(cmd)
    :ok = :gen_tcp.send(cmd, JSON.encode!(FakeNative.attest(welcome, adapter, token)) <> "\n")
    :inet.setopts(cmd, active: :once)
    timer = :timer.send_interval(@frame_ms, :frame)

    state = %{
      cmd: cmd,
      motion: nil,
      motion_port: Keyword.fetch!(opts, :motion_port),
      token: token,
      adapter: adapter,
      command_generation: welcome["link_generation"],
      motion_generation: nil,
      welcome: welcome,
      world: words(Keyword.get(opts, :world, @pre)),
      hero_x:
        elem(TransformWords.decode_world(@hero_world), 1)
        |> Enum.at(9)
        |> TransformWords.to_float(),
      hero_step_m: Keyword.get(opts, :hero_step_m, 0.05),
      t0: System.monotonic_time(:millisecond),
      gen: @gen,
      frame: 1_000,
      frame_timer: timer,
      m6_ledger: :idle,
      session: nil,
      closed_sessions: %{},
      share: nil,
      faults: [],
      reading_motion: true,
      held_out: [],
      events: []
    }

    state = if Keyword.get(opts, :bind_motion, true), do: do_bind(state), else: state
    {:ok, state}
  end

  defp do_bind(state) do
    m = connect_line(state.motion_port)
    :ok = :gen_tcp.send(m, motion_hello(state.adapter, state.command_generation))
    {:ok, w} = recv_line(m)
    "motion.welcome" = w["kind"]
    :ok = :gen_tcp.send(m, motion_attest(state.token, w, state.command_generation, state.adapter))
    :inet.setopts(m, active: :once)
    %{state | motion: m, motion_generation: w["motion_link_generation"]}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       adapter: state.adapter,
       command_generation: state.command_generation,
       motion_generation: state.motion_generation,
       world: TransformWords.encode(state.world),
       session: state.session && Map.drop(state.session, [:pending]),
       closed_sessions: state.closed_sessions,
       share: state.share,
       held_motion_out: length(state.held_out),
       m6_ledger: state.m6_ledger,
       events: Enum.reverse(state.events)
     }, state}
  end

  def handle_call({:fault, fault}, _from, state) do
    state = %{state | faults: [fault | state.faults]}

    state =
      case fault do
        :stop_reading_motion ->
          # cancel a read already armed, so nothing more is read from now on
          if state.motion, do: :inet.setopts(state.motion, active: false)
          %{state | reading_motion: false}

        _ ->
          state
      end

    {:reply, :ok, state}
  end

  def handle_call({:clear_fault, fault}, _from, state) do
    state = %{state | faults: List.delete(state.faults, fault)}
    state = if fault == :stop_reading_motion, do: %{state | reading_motion: true}, else: state

    if fault == :stop_reading_motion and state.motion,
      do: :inet.setopts(state.motion, active: :once)

    {:reply, :ok, state}
  end

  def handle_call({:set_generation, gen}, _from, state), do: {:reply, :ok, %{state | gen: gen}}

  def handle_call({:set_world, world}, _from, state),
    do: {:reply, :ok, %{state | world: words(world)}}

  def handle_call(:drop_motion, _from, state) do
    if state.motion, do: :gen_tcp.close(state.motion)
    {:reply, :ok, motion_lost(%{state | motion: nil}, :motion_link_dropped_by_fake)}
  end

  def handle_call(:drop_command, _from, state) do
    :gen_tcp.close(state.cmd)
    if state.motion, do: :gen_tcp.close(state.motion)
    {:reply, :ok, motion_lost(%{state | motion: nil}, :command_link_dropped_by_fake)}
  end

  def handle_call(:bind_motion, _from, state), do: {:reply, :ok, do_bind(state)}

  def handle_call(:release_motion_out, _from, state) do
    held = state.held_out
    state = %{state | held_out: [], faults: List.delete(state.faults, :hold_motion_out)}
    if state.motion, do: Enum.each(held, &:gen_tcp.send(state.motion, &1))
    {:reply, length(held), log(state, {:released_motion_out, length(held)})}
  end

  def handle_call({:release_motion_out, n}, _from, state) do
    {now, later} = Enum.split(state.held_out, n)
    if state.motion, do: Enum.each(now, &:gen_tcp.send(state.motion, &1))
    {:reply, length(now), log(%{state | held_out: later}, {:released_motion_out, length(now)})}
  end

  # every share sample up to the answered sequence number was written; every later one is held
  def handle_call(:hold_motion_out, _from, state) do
    state = %{state | faults: [:hold_motion_out | List.delete(state.faults, :hold_motion_out)]}
    {:reply, {:ok, state.share && state.share.seq}, state}
  end

  @impl true
  def handle_info({:tcp, s, line}, %{cmd: s} = state) do
    state = command(JSON.decode!(String.trim_trailing(line, "\n")), state)
    :inet.setopts(s, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp, s, line}, %{motion: s} = state) do
    {:ok, msg} = Codec.decode_from_beam(String.trim_trailing(line, "\n"))
    state = motion_in(msg, state)
    if state.reading_motion and state.motion, do: :inet.setopts(s, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, s}, %{motion: s} = state),
    do: {:noreply, motion_lost(%{state | motion: nil}, :motion_link_lost)}

  def handle_info({:tcp_closed, s}, %{cmd: s} = state) do
    if state.motion, do: :gen_tcp.close(state.motion)
    {:noreply, motion_lost(%{state | motion: nil}, :command_link_lost)}
  end

  def handle_info(:frame, state), do: {:noreply, frame(%{state | frame: state.frame + 1})}
  def handle_info({:run_command, c}, state), do: {:noreply, run_command(c, state)}

  def handle_info({:late_reply, c, status, fields}, state) do
    reply(state, c, status, fields)
    {:noreply, state}
  end

  def handle_info(:share_tick, state), do: {:noreply, share_tick(state)}
  def handle_info(_msg, state), do: {:noreply, state}

  # -- commands -------------------------------------------------------------------------------------------

  defp command(%{"kind" => "command"} = c, state) do
    delay =
      Enum.find_value(state.faults, fn
        {:delay_commands, ms} -> ms
        _ -> nil
      end)

    cond do
      fault?(state, :hold_commands) ->
        log(state, {:held_command, c["name"], c["command_id"]})

      delay != nil ->
        Process.send_after(self(), {:run_command, c}, delay)
        state

      true ->
        run_command(c, state)
    end
  end

  defp command(_other, state), do: state

  defp run_command(c, state) do
    swallow = fault?(state, :swallow_results)
    unless swallow, do: reply(state, c, "received", %{})
    {status, fields, state} = execute(c["name"], c["version"], c["params"], c, state)

    terminal_delay =
      Enum.find_value(state.faults, fn
        {:delay_terminal, ms} -> ms
        _ -> nil
      end)

    cond do
      # :swallow_results: the command is executed, but no answer ever leaves (an unknown outcome)
      swallow ->
        :ok

      terminal_delay != nil ->
        Process.send_after(self(), {:late_reply, c, status, fields}, terminal_delay)

      true ->
        reply(state, c, status, fields)
    end

    log(state, {:command, c["name"], c["params"]["mode"], status, fields["reason"]})
  end

  defp execute("relay.inspect.candidate_transform", 1, _p, _c, state),
    do:
      {"applied",
       %{
         "observed" =>
           qualifying(TransformWords.encode(state.world), %{"generation_fresh" => f(state.gen)}),
         "frame" => state.frame,
         "mission_generation" => state.gen
       }, state}

  defp execute("player.pose.share", 1, p, _c, state) do
    cond do
      state.share != nil ->
        {"rejected", %{"reason" => "share_open"}, state}

      p["motion_link_generation"] != state.motion_generation ->
        {"precondition_failed", %{"reason" => "motion_link"}, state}

      true ->
        timer = Process.send_after(self(), :share_tick, p["interval_ms"])

        share = %{
          id: p["share_id"],
          interval: p["interval_ms"],
          duration: p["duration_ms"],
          opened: now(state),
          seq: 0,
          sent: 0,
          timer: timer
        }

        {"applied",
         %{
           "observed" => %{"share_open" => f(true), "interval_ms" => f(p["interval_ms"])},
           "frame" => state.frame,
           "mission_generation" => @gen
         }, %{state | share: share}}
    end
  end

  defp execute("candidate.motion.session", 1, %{"mode" => "open"} = p, _c, state) do
    world = TransformWords.encode(state.world)

    cond do
      fault?(state, :refuse_open) ->
        {"precondition_failed", %{"reason" => "fault"}, state}

      state.session != nil ->
        {"rejected", %{"reason" => "session_open"}, state}

      state.m6_ledger != :idle ->
        {"precondition_failed", %{"reason" => "m6_ledger"}, state}

      p["motion_link_generation"] != state.motion_generation ->
        {"precondition_failed", %{"reason" => "motion_link"}, state}

      p["expect_world"] != world ->
        {"precondition_failed", %{"reason" => "expectation"}, state}

      true ->
        t = now(state)

        anchor =
          {TransformWords.to_float(Enum.at(state.world, 9)),
           TransformWords.to_float(Enum.at(state.world, 10))}

        session = %{
          id: p["session_id"],
          params: p,
          opening: state.world,
          anchor: anchor,
          opened: t,
          last_target: t,
          last_apply: nil,
          last_applied_seq: 0,
          last_seq: 0,
          pending: nil,
          first_target: nil,
          next_report: nil,
          report_seq: 0,
          uncertain: false,
          counts: %{received: 0, applied: 0, skipped: 0, refused: 0, uncertain: 0, superseded: 0}
        }

        observed = %{
          "session_open" => f(true),
          "opening_world" => f(world),
          "opening_local" => f(@local),
          "motion_link_generation" => f(state.motion_generation)
        }

        {"applied",
         %{"observed" => observed, "frame" => state.frame, "mission_generation" => @gen},
         %{state | session: session}}
    end
  end

  defp execute("candidate.motion.session", 1, %{"mode" => "restore"} = p, _c, state) do
    closed = state.closed_sessions[p["session_id"]]
    world = TransformWords.encode(state.world)

    cond do
      state.session != nil ->
        {"rejected", %{"reason" => "session_open"}, state}

      closed == nil or not closed.clean or closed.restored ->
        {"precondition_failed", %{"reason" => "not_restorable"}, state}

      p["expect_world"] != world ->
        {"precondition_failed", %{"reason" => "expectation"}, state}

      p["target_world"] != TransformWords.encode(closed.opening) ->
        {"precondition_failed", %{"reason" => "target"}, state}

      true ->
        post =
          if fault?(state, :restore_inexact), do: bump_y(closed.opening), else: closed.opening

        target = TransformWords.encode(closed.opening)
        post_text = TransformWords.encode(post)

        # the restoration-result contract (M7-B1 correction): typed fields, each a test may vary
        observed =
          %{
            "mode" => f("restore"),
            "restore_of" => f(p["restore_of"]),
            "generation_fresh" => f(state.gen),
            "generation_post" => f(state.gen),
            "preimage_world_words" => f(world),
            "preimage_local_words" => f(@local),
            "preimage_parent" => f(@brick),
            "preimage_dirty" => f(false),
            "requested_world_words" => f(target),
            "postimage_world_words" => f(post_text),
            "postimage_local_words" => f(@local),
            "postimage_parent" => f(@brick),
            "postimage_dirty" => f(false),
            "post_same_entity" => f(true),
            "world_match" => f(if(post_text == target, do: "target", else: "neither")),
            "local_match" => f("unchanged"),
            "hero_control" => f("unchanged"),
            "setter_called" => f(true),
            "apply_log" => f("written"),
            "invocation" => f("called"),
            "effect" => f("changed"),
            "precondition_ok" => f(true)
          }
          |> restore_faults(state)

        status =
          Enum.find_value(state.faults, "applied", fn
            {:restore_status, s} -> s
            _ -> nil
          end)

        state = %{
          state
          | world: post,
            closed_sessions:
              Map.put(state.closed_sessions, p["session_id"], %{closed | restored: true})
        }

        {status, %{"observed" => observed, "frame" => state.frame, "mission_generation" => @gen},
         state}
    end
  end

  defp execute("candidate.transform.set", 2, %{"mode" => "step_y"} = p, _c, state) do
    cond do
      state.session != nil ->
        {"rejected", %{"reason" => "motion_session_open"}, state}

      p["expect_world"] != TransformWords.encode(state.world) ->
        {"precondition_failed", %{"reason" => "expectation"}, state}

      true ->
        pre = TransformWords.encode(state.world)
        stepped = TransformWords.step_y_target(state.world)
        post = TransformWords.encode(stepped)

        {"applied",
         %{
           "observed" => step_observed(pre, post),
           "frame" => state.frame,
           "mission_generation" => @gen
         }, %{state | world: stepped, m6_ledger: :forward_invoked}}
    end
  end

  defp execute(_name, _version, _p, _c, state),
    do: {"rejected", %{"reason" => "not_in_fake"}, state}

  defp restore_faults(observed, state) do
    Enum.reduce(state.faults, observed, fn
      {:restore_field, key, :omit}, acc -> Map.delete(acc, key)
      {:restore_field, key, value}, acc -> Map.put(acc, key, value)
      _, acc -> acc
    end)
  end

  defp step_observed(pre, post),
    do: %{
      "mode" => f("step_y"),
      "generation_fresh" => f(@gen),
      "generation_post" => f(@gen),
      "preimage_world_words" => f(pre),
      "preimage_local_words" => f(@local),
      "preimage_parent" => f(@brick),
      "preimage_dirty" => f(false),
      "requested_world_words" => f(post),
      "postimage_world_words" => f(post),
      "postimage_local_words" => f(@local),
      "postimage_parent" => f(@brick),
      "postimage_dirty" => f(false),
      "post_same_entity" => f(true),
      "world_match" => f("target"),
      "local_match" => f("unchanged"),
      "hero_control" => f("unchanged"),
      "setter_called" => f(true),
      "apply_log" => f("written"),
      "invocation" => f("called"),
      "effect" => f("changed"),
      "precondition_ok" => f(true),
      "budget_remaining" => f(0)
    }

  defp reply(state, c, status, fields) do
    line =
      Map.merge(
        %{
          "command_protocol_version" => 2,
          "kind" => "command.result",
          "command_id" => c["command_id"],
          "link_generation" => c["link_generation"],
          "adapter_instance_id" => state.adapter,
          "status" => status,
          "reason" => nil,
          "native_at" => "2026-10-19T00:00:01.000Z",
          "frame" => state.frame,
          "observed" => nil,
          "mission_generation" => nil
        },
        fields
      )

    :gen_tcp.send(state.cmd, JSON.encode!(line) <> "\n")
  end

  # -- the motion link ------------------------------------------------------------------------------------

  defp motion_in({:ghost_target, t}, state) do
    # every target line read from the motion socket, whatever the session state
    motion_target(t, log(state, {:target_line, t.session_id, t.seq, now(state)}))
  end

  defp motion_in({:ghost_close, c}, %{session: %{id: id}} = state) when c.session_id == id,
    do: close_session(state, "beam:" <> c.reason)

  defp motion_in({:ghost_close, c}, state), do: log(state, {:close_without_session, c.session_id})

  defp motion_in({:share_close, c}, %{share: %{id: id}} = state) when c.share_id == id,
    do: close_share(state, "beam:" <> c.reason)

  defp motion_in(other, state), do: log(state, {:unexpected, other})

  defp motion_target(t, %{session: %{id: id} = s} = state) when t.session_id == id do
    s = %{s | counts: Map.update!(s.counts, :received, &(&1 + 1)), last_target: now(state)}

    s =
      cond do
        s.pending != nil ->
          %{s | pending: t, counts: Map.update!(s.counts, :superseded, &(&1 + 1))}

        true ->
          %{s | pending: t}
      end

    s =
      if s.first_target == nil,
        do: %{s | first_target: now(state), next_report: now(state) + @report_ms},
        else: s

    %{state | session: s}
  end

  defp motion_target(t, state),
    do: log(state, {:target_without_session, t.session_id, t.seq})

  defp motion_lost(state, why) do
    state = if state.session, do: close_session(state, Atom.to_string(why), false), else: state
    if state.share, do: close_share(state, Atom.to_string(why), false), else: state
  end

  # -- frames -----------------------------------------------------------------------------------------------

  defp frame(state) do
    state
    |> frame_faults()
    |> session_frame()
  end

  defp frame_faults(state) do
    Enum.reduce(state.faults, state, fn
      {:z_drift_at_frame, fr}, st when st.frame == fr ->
        log(
          %{st | world: List.replace_at(st.world, 11, Enum.at(st.world, 11) + 1)},
          {:engine_changed_z, fr}
        )

      {:generation_change_at_frame, fr}, st when st.frame == fr and st.session != nil ->
        close_session(st, "generation_changed")

      _, st ->
        st
    end)
  end

  defp session_frame(%{session: nil} = state), do: state

  defp session_frame(%{session: s} = state) do
    p = s.params
    t = now(state)

    overrun =
      Enum.find_value(state.faults, 0, fn
        {:session_overrun_ms, ms} -> ms
        _ -> nil
      end)

    cond do
      t >= s.opened + p["duration_ms"] + overrun ->
        close_session(state, "duration")

      t >= s.last_target + p["silence_close_ms"] ->
        close_session(state, "target_silence")

      s.pending != nil and (s.last_apply == nil or t - s.last_apply >= p["min_apply_interval_ms"]) and
          not fault?(state, :stop_acks) ->
        state |> apply_target() |> maybe_report()

      true ->
        maybe_report(state)
    end
  end

  defp apply_target(%{session: s} = state) do
    target = s.pending
    s = %{s | pending: nil}
    state = %{state | session: s}
    {:ok, [xw, yw]} = TransformWords.decode(target.pos, 2)
    x = TransformWords.to_float(xw)
    y = TransformWords.to_float(yw)
    p = s.params
    {ax, ay} = s.anchor

    {lx, ly} =
      {TransformWords.to_float(Enum.at(state.world, 9)),
       TransformWords.to_float(Enum.at(state.world, 10))}

    half = p["half_extent_mm"] / 1_000
    step_cap = p["max_speed_mmps"] * p["credit_ms"] / 1_000_000
    untouched = fn w -> w |> List.delete_at(10) |> List.delete_at(9) end

    cond do
      target.seq <= s.last_applied_seq ->
        refuse(state, target, "duplicate_or_older")

      untouched.(state.world) != untouched.(s.opening) ->
        refuse(state, target, "untouched_field_changed")

      abs(x - ax) > half or abs(y - ay) > half ->
        refuse(state, target, "outside_area")

      :math.sqrt(:math.pow(x - lx, 2) + :math.pow(y - ly, 2)) > step_cap ->
        refuse(state, target, "displacement")

      fault?(state, {:refuse_at_seq, target.seq}) ->
        refuse(state, target, "fault")

      xw == Enum.at(state.world, 9) and yw == Enum.at(state.world, 10) ->
        ack(state, target, "skipped_identical", nil, nil)

      # the post-call faults hit the first real setter call at or after their sequence number
      from?(state, :uncertain_from_seq, target.seq) ->
        state = put_in(state.session.uncertain, true)
        state = ack(state, target, "uncertain", "read_back_unavailable", nil)
        close_session(state, "uncertain")

      true ->
        requested = state.world |> List.replace_at(9, xw) |> List.replace_at(10, yw)

        post =
          if from?(state, :postimage_mismatch_from_seq, target.seq),
            do: bump_y(requested),
            else: requested

        exact = post == requested

        state = %{state | world: post}
        s = state.session

        state = %{
          state
          | session: %{
              s
              | last_apply: now(state),
                last_applied_seq: target.seq,
                uncertain: s.uncertain or not exact
            }
        }

        state =
          log(
            state,
            {:applied, target.seq, state.frame,
             TransformWords.encode([Enum.at(post, 9), Enum.at(post, 10)])}
          )

        state =
          ack(
            state,
            target,
            "applied",
            nil,
            TransformWords.encode([Enum.at(post, 9), Enum.at(post, 10)]),
            exact
          )

        if exact, do: state, else: close_session(state, "postimage_mismatch")
    end
  end

  defp refuse(state, target, reason) do
    state = ack(state, target, "refused", reason, nil)
    close_session(state, "refused:" <> reason)
  end

  defp ack(state, target, outcome, reason, post, exact \\ nil) do
    key =
      case outcome do
        "applied" -> :applied
        "skipped_identical" -> :skipped
        "refused" -> :refused
        "uncertain" -> :uncertain
      end

    state = update_in(state.session.counts[key], &(&1 + 1))

    send_motion(state, "ghost.applied", %{
      "session_id" => state.session.id,
      "seq" => target.seq,
      "frame" => state.frame,
      "native_mono_ms" => now(state),
      "outcome" => outcome,
      "reason" => reason,
      "post" => post,
      "exact" => exact
    })
  end

  defp maybe_report(%{session: %{next_report: nr} = s} = state) when is_integer(nr) do
    if now(state) >= nr do
      skip = fault?(state, {:skip_report, s.report_seq + 1})
      seq = s.report_seq + if(skip, do: 2, else: 1)
      c = s.counts
      lie = if fault?(state, :report_disagrees), do: 1, else: 0

      state =
        send_motion(state, "ghost.report", %{
          "session_id" => s.id,
          "report_seq" => seq,
          "native_mono_ms" => now(state),
          "frame" => state.frame,
          "received" => c.received,
          "applied" => c.applied + lie,
          "skipped" => c.skipped,
          "refused" => c.refused,
          "uncertain" => c.uncertain,
          "superseded" => c.superseded,
          "last_applied_seq" => s.last_applied_seq
        })

      put_in(state.session, %{state.session | report_seq: seq, next_report: nr + @report_ms})
    else
      state
    end
  end

  defp maybe_report(state), do: state

  defp close_session(%{session: s} = state, reason, send? \\ true) do
    state =
      if s.pending && send? do
        ack(state, s.pending, "refused", "session_closed", nil)
      else
        state
      end

    clean = not s.uncertain

    state =
      if send? do
        send_motion(state, "ghost.closed", %{
          "session_id" => s.id,
          "reason" => reason,
          "native_mono_ms" => now(state),
          "clean" => clean,
          "final_world" => TransformWords.encode(state.world),
          "last_applied_seq" => s.last_applied_seq,
          "applied" => s.counts.applied
        })
      else
        state
      end

    closed = %{
      clean: clean,
      opening: s.opening,
      final: state.world,
      restored: false,
      reason: reason
    }

    %{state | session: nil, closed_sessions: Map.put(state.closed_sessions, s.id, closed)}
    |> log({:session_closed, s.id, reason, clean})
  end

  # -- the share ---------------------------------------------------------------------------------------------

  defp share_tick(%{share: nil} = state), do: state

  defp share_tick(%{share: sh} = state) do
    t = now(state)

    overrun =
      Enum.find_value(state.faults, 0, fn
        {:share_overrun_ms, ms} -> ms
        _ -> nil
      end)

    if t >= sh.opened + sh.duration + overrun do
      close_share(state, "duration")
    else
      seq = sh.seq + 1
      x = state.hero_x + seq * state.hero_step_m
      {:ok, hw} = TransformWords.decode_world(@hero_world)
      pos = TransformWords.encode([TransformWords.to_word(x), Enum.at(hw, 10), Enum.at(hw, 11)])

      state =
        send_motion(state, "hero.sample", %{
          "share_id" => sh.id,
          "seq" => seq,
          "frame" => state.frame,
          "native_mono_ms" => t,
          "pos" => pos,
          "dirty" => fault?(state, {:dirty_hero_seq, seq})
        })

      timer = Process.send_after(self(), :share_tick, sh.interval)
      %{state | share: %{sh | seq: seq, sent: sh.sent + 1, timer: timer}}
    end
  end

  defp close_share(%{share: sh} = state, reason, send? \\ true) do
    Process.cancel_timer(sh.timer)

    state =
      if send?,
        do:
          send_motion(state, "share.closed", %{
            "share_id" => sh.id,
            "reason" => reason,
            "last_seq" => sh.seq,
            "sent" => sh.sent
          }),
        else: state

    %{state | share: nil} |> log({:share_closed, sh.id, reason})
  end

  # -- helpers -----------------------------------------------------------------------------------------------

  defp send_motion(%{motion: nil} = state, _kind, _fields), do: state

  defp send_motion(state, kind, fields) do
    line = Codec.encode_from_native(kind, fields)

    cond do
      # :mute_motion: a native that neither reads nor answers (its own timers still run)
      fault?(state, :mute_motion) ->
        state

      # :hold_motion_out: written later, in order, by release_motion_out/1
      fault?(state, :hold_motion_out) ->
        %{state | held_out: state.held_out ++ [line]}

      true ->
        _ = :gen_tcp.send(state.motion, line)
        state
    end
  end

  defp fault?(state, fault), do: fault in state.faults
  defp from?(state, tag, seq), do: Enum.any?(state.faults, &match?({^tag, n} when seq >= n, &1))
  defp now(state), do: System.monotonic_time(:millisecond) - state.t0
  defp words(text), do: elem(TransformWords.decode_world(text), 1)
  defp bump_y(words), do: List.replace_at(words, 10, Enum.at(words, 10) + 1)
  defp log(state, event), do: %{state | events: [event | state.events]}
end
