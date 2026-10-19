defmodule GlacierRelay.Motion.Hub do
  @moduledoc """
  M7-B1: the game host's motion data plane (`docs/design/M7_NETWORK_GHOST.md` sections 15.3–15.6),
  one process: the bound motion link (`Motion.Link`), the one peer connection (`Peer.Connection`,
  for which it is the handler), at most one share (`Motion.Source`) and at most one destination
  session (`Motion.Destination`), their timers and the motion trace (`Motion.Trace`).

  It never opens, extends, widens or restores anything. A share or a session becomes active only
  when **`Command.Authority`** reports the native's confirmation of the command it issued under
  local arming (`share_result/3`, `session_result/3`), for an id the operator facade prepared here
  first (`prepare_share/1`, `prepare_session/1`), with the binding the approval named — the peer's
  connection generation, boot and stream (`source_kind` included), the motion link generation —
  still current; otherwise the confirmed session is closed at once. Peer messages are data:
  samples of the bound stream go to the destination; samples of any other stream are counted and
  dropped; a peer ends only its own bound stream.

  Calls and casts flow one way so nothing can deadlock: the facade, `Motion.Link` and the peer
  connection call the hub; the hub never calls the authority (it casts `Authority.motion_event/1`
  for the journal), and the authority only casts to the hub. Writes to the motion link happen here
  with the link's 200 ms send deadline; a write that fails drops the link, which the native treats
  as a close. Trace loss, audit degradation and either link's loss close the share and the session;
  close itself never waits for anything but the native's answer, and gives up after 1,000 ms
  (`unknown`).
  """

  use GenServer
  require Logger

  alias GlacierRelay.Command.Authority
  alias GlacierRelay.Motion.{Clock, Codec, Destination, Source, Trace}
  alias GlacierRelay.Peer.Connection

  @history 16

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # -- facade API -----------------------------------------------------------------------------------

  @doc "The hub's view: link, peer, streams, share, session, history, counters, trace health."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Prepares a share for the authority to issue (`statement`: `:share_id`, `:motion_link_generation`,
  `:duration_ms`, `:interval_ms`, `:peer` — `%{connection_generation, boot_id}` — and `:label`).
  `{:ok, statement}` or `{:error, reason}`.
  """
  def prepare_share(statement), do: GenServer.call(__MODULE__, {:prepare_share, statement})

  @doc """
  Prepares a destination session for the authority to issue (`approval`: `:session_id`, `:peer`
  — `%{connection_generation, boot_id, label, pin}` — `:stream_id`, `:source_kind`,
  `:motion_link_generation`, `:limits`). `{:ok, approval}` or `{:error, reason}`.
  """
  def prepare_session(approval), do: GenServer.call(__MODULE__, {:prepare_session, approval})

  @doc "Forgets a prepared share or session that the authority did not accept."
  def abandon(id), do: GenServer.call(__MODULE__, {:abandon, id})

  @doc "Ends the destination session (no arming)."
  def close_session(reason \\ :operator), do: GenServer.call(__MODULE__, {:close_session, reason})

  @doc "Ends the share (no arming)."
  def close_share(reason \\ :operator), do: GenServer.call(__MODULE__, {:close_share, reason})

  # -- the authority's notifications (casts only) -------------------------------------------------------

  @doc false
  def share_result(share_id, status, facts),
    do: GenServer.cast(__MODULE__, {:share_result, share_id, status, facts})

  @doc false
  def session_result(session_id, status, facts),
    do: GenServer.cast(__MODULE__, {:session_result, session_id, status, facts})

  @doc false
  def command_link_lost(generation),
    do: GenServer.cast(__MODULE__, {:command_link_lost, generation})

  @doc false
  def audit_degraded, do: GenServer.cast(__MODULE__, :audit_degraded)

  # -- the motion link -----------------------------------------------------------------------------------

  @doc false
  def link_bound(info), do: GenServer.call(__MODULE__, {:link_bound, info}, 500)

  @doc false
  def native(generation, message, timeout),
    do: GenServer.call(__MODULE__, {:native, generation, message}, timeout)

  # -- the peer handler ------------------------------------------------------------------------------------

  @doc false
  def peer_event(server, event, timeout), do: GenServer.call(server, {:peer, event}, timeout)

  @doc false
  def peer_notify(server, event), do: GenServer.cast(server, {:peer_notify, event})

  # -- state ---------------------------------------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %{
       trace: Keyword.get(opts, :trace, GlacierRelay.Motion.Trace),
       trace_ok: true,
       link: nil,
       peer: nil,
       share: nil,
       session: nil,
       history: [],
       timer: nil,
       counts: %{
         unrouted_samples: 0,
         unknown_ids: 0,
         native_messages: 0,
         peer_samples: 0,
         send_failures: 0
       }
     }}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, status_map(state), state}

  def handle_call({:link_bound, info}, _from, state) do
    state = if state.link, do: lose_link(state, :replaced), else: state
    ref = Process.monitor(info.pid)
    link = Map.put(info, :ref, ref)

    state =
      trace(state, [%{"event" => "hub.link_bound", "motion_link_generation" => info.generation}])

    {:reply, :ok, %{state | link: link}}
  end

  def handle_call(
        {:native, generation, message},
        _from,
        %{link: %{generation: generation}} = state
      ) do
    state = bump(state, :native_messages)
    {:reply, :ok, native(message, state) |> reschedule()}
  end

  def handle_call({:native, _generation, _message}, _from, state),
    do: {:reply, {:close, :not_the_bound_link}, state}

  def handle_call({:prepare_share, st}, _from, state) do
    cond do
      not state.trace_ok ->
        {:reply, {:error, :trace_unhealthy}, state}

      state.share != nil and state.share.status != :done ->
        {:reply, {:error, :share_exists}, state}

      state.link == nil ->
        {:reply, {:error, :no_bound_motion_link}, state}

      st.motion_link_generation != state.link.generation ->
        {:reply, {:error, :motion_link_not_current}, state}

      not peer_matches?(state, st.peer) ->
        {:reply, {:error, :peer_not_current}, state}

      true ->
        {:reply, {:ok, st},
         %{state | share: %{id: st.share_id, statement: st, status: :pending, src: nil}}}
    end
  end

  def handle_call({:prepare_session, ap}, _from, state) do
    stream = state.peer && Map.get(state.peer.streams, ap.stream_id)

    cond do
      not state.trace_ok ->
        {:reply, {:error, :trace_unhealthy}, state}

      state.session != nil and state.session.status != :done ->
        {:reply, {:error, :session_exists}, state}

      state.link == nil ->
        {:reply, {:error, :no_bound_motion_link}, state}

      ap.motion_link_generation != state.link.generation ->
        {:reply, {:error, :motion_link_not_current}, state}

      not peer_matches?(state, ap.peer) ->
        {:reply, {:error, :peer_not_current}, state}

      stream == nil ->
        {:reply, {:error, :stream_not_open}, state}

      stream.source_kind != ap.source_kind ->
        {:reply, {:error, {:source_kind_mismatch, stream.source_kind}}, state}

      true ->
        {:reply, {:ok, ap},
         %{state | session: %{id: ap.session_id, approval: ap, status: :pending, dest: nil}}}
    end
  end

  def handle_call({:abandon, id}, _from, state) do
    state =
      cond do
        (state.session && state.session.id == id) and state.session.status == :pending ->
          %{state | session: nil}

        (state.share && state.share.id == id) and state.share.status == :pending ->
          %{state | share: nil}

        true ->
          state
      end

    {:reply, :ok, state}
  end

  def handle_call({:close_session, reason}, _from, %{session: %{status: :active}} = state) do
    {:reply, :ok, state |> dest(&Destination.close(&1, reason, now())) |> reschedule()}
  end

  def handle_call({:close_session, _reason}, _from, state),
    do: {:reply, {:error, :no_active_session}, state}

  def handle_call({:close_share, reason}, _from, %{share: %{status: :active}} = state) do
    {:reply, :ok, state |> src(&Source.close(&1, reason, now())) |> reschedule()}
  end

  def handle_call({:close_share, _reason}, _from, state),
    do: {:reply, {:error, :no_active_share}, state}

  def handle_call({:peer, event}, _from, state) do
    {reply, state} = peer(event, state)
    {:reply, reply, reschedule(state)}
  end

  @impl true
  def handle_cast(
        {:share_result, id, status, facts},
        %{share: %{id: id, status: :pending}} = state
      ) do
    st = state.share.statement

    state =
      case status do
        :applied ->
          src =
            Source.new(%{
              share_id: id,
              interval_ms: st.interval_ms,
              duration_ms: st.duration_ms,
              opened_at: now(),
              label: st[:label]
            })

          state = %{state | share: %{state.share | status: :active, src: src}}

          cond do
            not peer_matches?(state, st.peer) or state.link == nil or
                state.link.generation != st.motion_link_generation ->
              src(state, &Source.close(&1, :binding_lost_before_activation, now()))

            true ->
              state
              |> send_peer_control("stream.open", Source.stream_open(src))
              |> event(%{"event" => "motion.share.activated", "share_id" => id, "facts" => facts})
          end

        other ->
          state
          |> event(%{
            "event" => "motion.share.not_opened",
            "share_id" => id,
            "status" => to_string(other)
          })
          |> Map.put(:share, %{state.share | status: :done})
      end

    {:noreply, reschedule(state)}
  end

  def handle_cast({:share_result, id, status, _facts}, state) do
    {:noreply,
     state
     |> bump(:unknown_ids)
     |> event(%{
       "event" => "motion.share.result_unmatched",
       "share_id" => id,
       "status" => to_string(status)
     })}
  end

  def handle_cast(
        {:session_result, id, status, facts},
        %{session: %{id: id, status: :pending}} = state
      ) do
    ap = state.session.approval

    state =
      case status do
        :applied ->
          dest =
            Destination.new(%{
              session_id: id,
              stream_id: ap.stream_id,
              limits: ap.limits,
              opening_world: facts.opening_world,
              opened_at: now()
            })

          state = %{state | session: %{state.session | status: :active, dest: dest}}

          state =
            event(state, %{
              "event" => "motion.session.activated",
              "session_id" => id,
              "stream_id" => ap.stream_id,
              "opening_world" => facts.opening_world
            })

          stream = state.peer && Map.get(state.peer.streams, ap.stream_id)

          if peer_matches?(state, ap.peer) and stream != nil and
               stream.source_kind == ap.source_kind and
               state.link != nil and state.link.generation == ap.motion_link_generation do
            state
          else
            dest(state, &Destination.close(&1, :binding_lost_before_activation, now()))
          end

        other ->
          state
          |> event(%{
            "event" => "motion.session.not_opened",
            "session_id" => id,
            "status" => to_string(other)
          })
          |> Map.put(:session, %{state.session | status: :done})
      end

    {:noreply, reschedule(state)}
  end

  def handle_cast({:session_result, id, status, _facts}, state) do
    {:noreply,
     state
     |> bump(:unknown_ids)
     |> event(%{
       "event" => "motion.session.result_unmatched",
       "session_id" => id,
       "status" => to_string(status)
     })}
  end

  def handle_cast({:command_link_lost, _generation}, state) do
    {:noreply, state |> lose_link(:command_link_lost) |> reschedule()}
  end

  def handle_cast(:audit_degraded, state) do
    {:noreply,
     state
     |> dest(&Destination.close(&1, :audit_degraded, now()))
     |> src(&Source.close(&1, :audit_degraded, now()))
     |> reschedule()}
  end

  def handle_cast({:peer_notify, {:rtt, info, rtt}}, state) do
    {:noreply,
     trace(state, [
       %{
         "event" => "peer.rtt",
         "connection_generation" => info.generation,
         "ping_seq" => rtt.ping_seq,
         "rtt_ms" => rtt.rtt_ms,
         "label" => "round trip on this node's clock only; not a one-way latency"
       }
     ])}
  end

  def handle_cast({:peer_notify, {:down, info, reason}}, state) do
    {:noreply, state |> peer_lost(info.generation, reason) |> reschedule()}
  end

  @impl true
  def handle_info(:tick, state) do
    t = now()

    state =
      %{state | timer: nil}
      |> dest(&Destination.tick(&1, t))
      |> src(&Source.tick(&1, t))

    {:noreply, reschedule(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{link: %{ref: ref}} = state) do
    {:noreply,
     %{state | link: Map.put(state.link, :ref, nil)}
     |> lose_link({:link_down, reason})
     |> reschedule()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{peer: %{ref: ref}} = state) do
    {:noreply,
     state |> peer_lost(state.peer.info.generation, {:connection_down, reason}) |> reschedule()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- native messages ----------------------------------------------------------------------------------

  defp native({:hero_sample, hs}, state) do
    case state.share do
      %{id: id, status: :active} when id == hs.share_id ->
        src(state, &Source.hero_sample(&1, hs, now()))

      _ ->
        unknown_id(state, "hero.sample", hs.share_id)
    end
  end

  defp native({:share_closed, c}, state) do
    case state.share do
      %{id: id, status: s} when id == c.share_id and s in [:active, :pending] ->
        if s == :active,
          do: src(state, &Source.native_closed(&1, c, now())),
          else:
            event(state, %{
              "event" => "motion.share.closed_before_activation",
              "share_id" => id,
              "reason" => c.reason
            })

      _ ->
        unknown_id(state, "share.closed", c.share_id)
    end
  end

  defp native({kind, m}, state) when kind in [:ghost_applied, :ghost_report, :ghost_closed] do
    case state.session do
      %{id: id, status: :active} when id == m.session_id ->
        t = now()

        case kind do
          :ghost_applied -> dest(state, &Destination.applied(&1, m, t))
          :ghost_report -> dest(state, &Destination.report(&1, m, t))
          :ghost_closed -> dest(state, &Destination.native_closed(&1, m, t))
        end

      %{id: id, status: :pending} when id == m.session_id and kind == :ghost_closed ->
        event(state, %{
          "event" => "motion.session.closed_before_activation",
          "session_id" => id,
          "reason" => m.reason
        })

      _ ->
        unknown_id(state, Atom.to_string(kind), m.session_id)
    end
  end

  defp unknown_id(state, kind, id) do
    state
    |> bump(:unknown_ids)
    |> trace([%{"event" => "hub.unknown_id", "kind" => kind, "id" => id}])
  end

  # -- peer events ------------------------------------------------------------------------------------------

  defp peer({:up, info}, state) do
    state =
      if state.peer, do: peer_lost(state, state.peer.info.generation, :replaced), else: state

    ref = Process.monitor(info.connection)

    state =
      trace(state, [
        %{
          "event" => "peer.up",
          "connection_generation" => info.generation,
          "label" => info.label,
          "client_kind" => info.client_kind,
          "boot_id" => info.boot_id,
          "pin" => info.pin
        }
      ])

    {:ok, %{state | peer: %{info: info, ref: ref, streams: %{}}}}
  end

  defp peer({:stream_open, info, f}, state) do
    if current_peer?(state, info) do
      stream = %{
        source_kind: f.source_kind,
        interval_ms: f.interval_ms,
        src_clock: f.src_clock,
        label: f.label,
        course: f.course,
        opened_at: now(),
        received: 0
      }

      state = put_in(state.peer.streams[f.stream_id], stream)

      {:ok,
       trace(state, [
         %{
           "event" => "peer.stream_open",
           "stream_id" => f.stream_id,
           "source_kind" => f.source_kind,
           "src_clock" => f.src_clock,
           "label" => f.label,
           "course" => f.course
         }
       ])}
    else
      {{:close, :not_the_current_peer}, state}
    end
  end

  defp peer({:sample, info, f}, state) do
    state = bump(state, :peer_samples)

    cond do
      not current_peer?(state, info) ->
        {{:close, :not_the_current_peer}, state}

      bound_stream?(state, info, f.stream_id) ->
        {:ok, dest(state, &Destination.sample(&1, f, now()))}

      true ->
        {:ok, bump(state, :unrouted_samples)}
    end
  end

  defp peer({:stream_end, info, f}, state) do
    state =
      if current_peer?(state, info),
        do: update_in(state.peer.streams, &Map.delete(&1, f.stream_id)),
        else: state

    state =
      trace(state, [
        %{
          "event" => "peer.stream_end",
          "stream_id" => f.stream_id,
          "reason" => f.reason,
          "last_seq" => f.last_seq,
          "sent" => f.sent
        }
      ])

    state =
      if bound_stream?(state, info, f.stream_id),
        do:
          dest(
            state,
            &Destination.close(&1, {:stream_end, f.reason}, now())
          )
          |> event(%{
            "event" => "motion.session.stream_ended",
            "session_id" => state.session.id,
            "stream_id" => f.stream_id,
            "source_last_seq" => f.last_seq,
            "source_sent" => f.sent
          }),
        else: state

    {:ok, state}
  end

  defp current_peer?(state, info),
    do: state.peer != nil and state.peer.info.generation == info.generation

  defp bound_stream?(%{session: %{status: :active, approval: ap}}, info, stream_id),
    do: ap.stream_id == stream_id and ap.peer.connection_generation == info.generation

  defp bound_stream?(_state, _info, _stream_id), do: false

  defp peer_matches?(%{peer: %{info: info}}, %{connection_generation: g, boot_id: b}),
    do: info.generation == g and info.boot_id == b

  defp peer_matches?(_state, _wanted), do: false

  defp peer_lost(%{peer: %{info: %{generation: g}}} = state, g, reason) do
    if state.peer.ref, do: Process.demonitor(state.peer.ref, [:flush])

    state
    |> Map.put(:peer, nil)
    |> trace([
      %{"event" => "peer.down", "connection_generation" => g, "reason" => inspect(reason)}
    ])
    |> dest(&Destination.close(&1, :peer_link_lost, now()))
    |> src(&Source.close(&1, :peer_link_lost, now()))
  end

  defp peer_lost(state, _generation, _reason), do: state

  defp lose_link(%{link: nil} = state, _reason), do: state

  defp lose_link(state, reason) do
    link = state.link
    if link.ref, do: Process.demonitor(link.ref, [:flush])
    if Process.alive?(link.pid), do: Process.exit(link.pid, {:shutdown, :dropped_by_hub})
    t = now()

    %{state | link: nil}
    |> trace([
      %{
        "event" => "hub.link_lost",
        "motion_link_generation" => link.generation,
        "reason" => inspect(reason)
      }
    ])
    |> dest(&Destination.link_lost(&1, t))
    |> src(&Source.link_lost(&1, t))
  end

  # -- running the pure machines ------------------------------------------------------------------------

  defp dest(%{session: %{status: :active, dest: d}} = state, fun) do
    {d, actions} = fun.(d)
    state = put_in(state.session.dest, d)
    run(state, actions, :session)
  end

  defp dest(state, _fun), do: state

  defp src(%{share: %{status: :active, src: s}} = state, fun) do
    {s, actions} = fun.(s)
    state = put_in(state.share.src, s)
    run(state, actions, :share)
  end

  defp src(state, _fun), do: state

  defp run(state, actions, owner) do
    {state, traces} =
      Enum.reduce(actions, {state, []}, fn
        {:trace, rec}, {st, tr} -> {st, [rec | tr]}
        action, {st, tr} -> {act(action, st, owner), tr}
      end)

    trace(state, Enum.reverse(traces))
  end

  defp act({:send_target, t}, state, :session) do
    case write(state, Codec.target(t.session_id, t.seq, t.pos)) do
      {:ok, state} -> state
      {:error, state} -> lose_link(state, :target_not_written)
    end
  end

  defp act({:send_close, reason}, state, :session) do
    case write(state, Codec.close_session(state.session.id, Destination.reason_text(reason))) do
      {:ok, state} -> dest(state, &Destination.close_transmitted(&1, now()))
      {:error, state} -> lose_link(state, :close_not_written)
    end
  end

  defp act({:send_share_close, reason}, state, :share) do
    case write(state, Codec.close_share(state.share.id, Destination.reason_text(reason))) do
      {:ok, state} -> state
      {:error, state} -> lose_link(state, :share_close_not_written)
    end
  end

  defp act({:send_peer, "pose.sample", fields}, state, :share) do
    case state.peer && Connection.send_sample(state.peer.info, fields) do
      :ok -> state
      _ -> put_in(state.share.src, Source.send_dropped(state.share.src))
    end
  end

  defp act({:send_peer, kind, fields}, state, _owner), do: send_peer_control(state, kind, fields)

  defp act({:drop_link, reason}, state, _owner), do: lose_link(state, reason)

  defp act({:closed, summary}, state, :session) do
    session = %{state.session | status: :done}

    %{
      state
      | session: session,
        history: Enum.take([{:session, summary} | state.history], @history)
    }
    |> event(%{
      "event" => "motion.session.closed",
      "session_id" => summary.session_id,
      "summary" => summary
    })
  end

  defp act({:closed, summary}, state, :share) do
    %{
      state
      | share: %{state.share | status: :done},
        history: Enum.take([{:share, summary} | state.history], @history)
    }
    |> event(%{
      "event" => "motion.share.closed",
      "share_id" => summary.share_id,
      "summary" => summary
    })
  end

  defp send_peer_control(state, kind, fields) do
    if state.peer, do: Connection.send_control(state.peer.info, kind, fields)
    state
  end

  defp write(%{link: nil} = state, _line), do: {:error, bump(state, :send_failures)}

  defp write(state, line) do
    case :gen_tcp.send(state.link.socket, line) do
      :ok -> {:ok, state}
      {:error, _} -> {:error, bump(state, :send_failures)}
    end
  end

  # the trace is required: a refused append closes the share and the session
  defp trace(state, []), do: state

  defp trace(state, records) do
    case safe_append(state.trace, records) do
      :ok ->
        state

      {:error, health} ->
        Logger.error(
          "motion hub: trace unhealthy (#{inspect(health)}); closing share and session"
        )

        t = now()

        if state.trace_ok do
          %{state | trace_ok: false}
          |> dest(&Destination.close(&1, :trace_unhealthy, t))
          |> src(&Source.close(&1, :trace_unhealthy, t))
        else
          state
        end
    end
  end

  defp safe_append(trace, records) do
    Trace.append(trace, records)
  catch
    :exit, reason -> {:error, {:trace_unavailable, reason}}
  end

  # a journal entry for the authority to write (a cast: the hub never waits for the journal)
  defp event(state, entry) do
    Authority.motion_event(entry)
    state
  end

  defp reschedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    next =
      [
        state.session && state.session.status == :active &&
          Destination.next_deadline(state.session.dest),
        state.share && state.share.status == :active && Source.next_deadline(state.share.src)
      ]
      |> Enum.filter(&is_integer/1)
      |> Enum.min(fn -> nil end)

    timer = if next, do: Process.send_after(self(), :tick, max(next - now(), 0)), else: nil
    %{state | timer: timer}
  end

  defp bump(state, key), do: %{state | counts: Map.update!(state.counts, key, &(&1 + 1))}
  defp now, do: Clock.now_ms()

  defp status_map(state) do
    %{
      link:
        state.link &&
          Map.take(state.link, [:generation, :adapter_instance_id, :command_link_generation]),
      peer:
        state.peer &&
          %{
            connection_generation: state.peer.info.generation,
            label: state.peer.info.label,
            client_kind: state.peer.info.client_kind,
            boot_id: state.peer.info.boot_id,
            pin: state.peer.info.pin,
            streams:
              Map.new(state.peer.streams, fn {id, s} ->
                {id, Map.take(s, [:source_kind, :src_clock, :label, :course])}
              end)
          },
      share:
        state.share &&
          %{
            id: state.share.id,
            status: state.share.status,
            summary: state.share.src && Source.summary(state.share.src)
          },
      session:
        state.session &&
          %{
            id: state.session.id,
            status: state.session.status,
            summary: state.session.dest && Destination.summary(state.session.dest)
          },
      history: state.history,
      trace_ok: state.trace_ok,
      counts: state.counts
    }
  end
end
