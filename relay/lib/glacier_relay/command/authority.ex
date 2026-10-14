defmodule GlacierRelay.Command.Authority do
  @moduledoc """
  The single owner of command issuance (M5-A, ADR 0009). It holds the one command link and its
  handshake state, the arming state, the one in-flight command and the record of every command of
  this boot; it writes every decision to `Command.Journal` before acting on it, and refuses to act
  when the journal cannot persist the entry.

  Trust states, never equated (ADR 0009 reconciliation): `transport` connected; `protocol`
  negotiated (a hello with the supported version); `peer` identified (the hello's claimed
  `adapter_instance_id`, labelled *identified*, never authenticated — local arming is not peer
  authentication and a claimed id establishes nothing by itself); `authenticated` is reserved and
  unreachable in M5-A (no credential is provisioned); `armed` is the operator's statement about
  this authority; `ready` is identified and armed with nothing in flight and the journal open.

  Issuance rules: disarmed by default; arming requires an identified link and is undone by
  disarm or by any link loss (a reconnect needs a new arming); one in-flight command; no command
  id reused; unknown names and versions refused; an entry whose trust requirement the peer does
  not meet is refused (every effectful entry requires an authenticated peer, so none is issuable in
  M5-A); no automatic retry after an unknown outcome and no automatic reversal.

  Status ladder of a command: `accepted` (journaled) → `transmitted` → `received` → a terminal
  native status (`applied`, `rejected`, `busy`, `duplicate`, `expired`, `precondition_failed`,
  `unavailable`, `failed`), or `unknown` after a missed acknowledgement, a missed terminal result or
  a link loss. `observed` is `:none` or `:native` (the result carried a read-back; the fake or real
  peer's own report, never independent evidence); an independently observed semantic effect is a
  separate stage that M5-A has no source for and therefore never sets. A result is correlated by
  command id, link generation and (when the peer stated one) adapter identity; anything else is an
  anomaly, journaled and ignored. Timeouts use the monotonic clock only.
  """

  use GenServer
  require Logger

  alias GlacierRelay.Command.{Journal, Link, Schema}

  @defaults [
    ack_timeout_ms: 2_000,
    grace_ms: 1_000,
    default_ttl_ms: 5_000,
    max_ttl_ms: 10_000,
    min_ttl_ms: 100
  ]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # -- operator API ------------------------------------------------------------------------------

  @doc "Arms the authority for the current link. Refused without an identified link or a working journal."
  def arm, do: GenServer.call(__MODULE__, :arm)

  @doc "Disarms the authority: no new command may be issued until armed again."
  def disarm, do: GenServer.call(__MODULE__, :disarm)

  @doc """
  Issues an allowlisted command. `opts`: `:ttl_ms`, `:command_id` (tests only; a fresh UUID v4
  by default). Returns `{:ok, command_id}` or `{:error, reason}`; the ladder is read with
  `command/1`.
  """
  def issue(name, version, params \\ %{}, opts \\ [])
      when is_binary(name) and is_integer(version) and is_map(params),
      do: GenServer.call(__MODULE__, {:issue, name, version, params, opts})

  @doc "The authority's status: trust states, arming, link, in-flight command, counters."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "One command's record (ladder, result, observation), or nil."
  def command(command_id), do: GenServer.call(__MODULE__, {:command, command_id})

  # -- link-facing API (called by Command.Link only) -------------------------------------------------

  @doc false
  def link_opened(pid, peer), do: GenServer.call(__MODULE__, {:link_opened, pid, peer})
  @doc false
  def peer_hello(generation, hello),
    do: GenServer.call(__MODULE__, {:peer_hello, generation, hello})

  @doc false
  def result(generation, result), do: GenServer.cast(__MODULE__, {:result, generation, result})
  @doc false
  def link_closed(generation, reason),
    do: GenServer.cast(__MODULE__, {:link_closed, generation, reason})

  # -- state -------------------------------------------------------------------------------------

  @impl true
  def init(opts) do
    config = Keyword.merge(@defaults, opts)

    {:ok,
     %{
       config: config,
       journal: Keyword.get(opts, :journal, Journal),
       link: nil,
       next_generation: 1,
       armed: false,
       in_flight: nil,
       commands: %{},
       order: [],
       counters: %{issued: 0, refused: 0, anomalies: 0, links: 0, unknown: 0}
     }}
  end

  @impl true
  def handle_call({:link_opened, pid, peer}, _from, %{link: nil} = state) do
    generation = state.next_generation
    ref = Process.monitor(pid)

    link = %{
      pid: pid,
      ref: ref,
      generation: generation,
      peer: peer,
      transport: :connected,
      protocol: :not_negotiated,
      identity: :unidentified,
      authenticated: false,
      adapter_instance_id: nil,
      mission_generation: nil,
      native_at: nil,
      capabilities: [],
      opened_mono: mono()
    }

    state = %{
      state
      | link: link,
        next_generation: generation + 1,
        counters: bump(state.counters, :links)
    }

    journal(state, %{"event" => "link.connected", "link_generation" => generation, "peer" => peer})

    {:reply, {:ok, generation}, state}
  end

  def handle_call({:link_opened, _pid, peer}, _from, state) do
    journal(state, %{
      "event" => "link.refused",
      "peer" => peer,
      "reason" => "busy",
      "current_link_generation" => state.link.generation
    })

    {:reply, {:error, :busy}, state}
  end

  def handle_call(
        {:peer_hello, generation, hello},
        _from,
        %{link: %{generation: generation} = link} = state
      ) do
    link = %{
      link
      | protocol: :negotiated,
        identity: :identified,
        adapter_instance_id: hello.adapter_instance_id,
        mission_generation: hello.mission_generation,
        native_at: hello.native_at,
        capabilities: hello.capabilities
    }

    state = %{state | link: link}

    journal(state, %{
      "event" => "peer.identified",
      "link_generation" => generation,
      "adapter_instance_id" => hello.adapter_instance_id,
      "mission_generation" => hello.mission_generation,
      "native_at" => hello.native_at,
      "capabilities" => hello.capabilities,
      "trust" => "identified (claimed; not authenticated)"
    })

    {:reply, {:ok, Schema.encode_welcome(generation, node())}, state}
  end

  def handle_call({:peer_hello, generation, _hello}, _from, state) do
    anomaly(state, %{"event" => "anomaly.hello_on_unknown_link", "link_generation" => generation})
    {:reply, {:error, :unknown_link}, state}
  end

  def handle_call(:arm, _from, state) do
    cond do
      state.armed ->
        {:reply, {:error, :already_armed}, state}

      state.link == nil or state.link.identity != :identified ->
        {:reply, {:error, :no_identified_link}, state}

      true ->
        case journal(state, %{
               "event" => "authority.armed",
               "link_generation" => state.link.generation,
               "adapter_instance_id" => state.link.adapter_instance_id
             }) do
          :ok -> {:reply, :ok, %{state | armed: true}}
          {:error, reason} -> {:reply, {:error, {:journal_unavailable, reason}}, state}
        end
    end
  end

  def handle_call(:disarm, _from, state) do
    _ =
      journal(state, %{
        "event" => "authority.disarmed",
        "by" => "operator",
        "in_flight" => state.in_flight && state.in_flight.id
      })

    {:reply, :ok, %{state | armed: false}}
  end

  def handle_call({:issue, name, version, params, opts}, _from, state) do
    case prepare(state, name, version, params, opts) do
      {:ok, cmd} ->
        case journal(
               state,
               entry(cmd, "command.accepted", %{
                 "name" => name,
                 "version" => version,
                 "params" => params,
                 "ttl_ms" => cmd.ttl_ms
               })
             ) do
          :ok -> transmit(state, cmd)
          {:error, reason} -> refuse(state, name, version, {:journal_unavailable, reason})
        end

      {:error, reason} ->
        refuse(state, name, version, reason)
    end
  end

  def handle_call(:status, _from, state), do: {:reply, status_map(state), state}
  def handle_call({:command, id}, _from, state), do: {:reply, Map.get(state.commands, id), state}

  @impl true
  def handle_cast({:result, generation, result}, state) do
    {:noreply, correlate(state, generation, result)}
  end

  def handle_cast({:link_closed, generation, reason}, %{link: %{generation: generation}} = state) do
    {:noreply, lose_link(state, reason)}
  end

  def handle_cast({:link_closed, generation, reason}, state) do
    # A close reported for a link that is no longer the current one: evidence, not an error.
    journal(state, %{
      "event" => "link.closed_late",
      "link_generation" => generation,
      "reason" => inspect(reason)
    })

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{link: %{ref: ref}} = state),
    do: {:noreply, lose_link(state, {:down, reason})}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:ack_timeout, id}, %{in_flight: %{id: id, status: :transmitted}} = state),
    do: {:noreply, unknown(state, :ack_timeout)}

  def handle_info({:terminal_timeout, id}, %{in_flight: %{id: id} = cmd} = state)
      when cmd.status in [:transmitted, :received],
      do: {:noreply, unknown(state, :terminal_timeout)}

  def handle_info({_timer, _id}, state), do: {:noreply, state}

  # -- issuance ------------------------------------------------------------------------------------

  defp prepare(state, name, version, params, opts) do
    entry = Schema.entry(name, version)
    link = state.link
    ttl = Keyword.get(opts, :ttl_ms, state.config[:default_ttl_ms])
    id = Keyword.get(opts, :command_id) || Schema.uuid4()

    cond do
      entry == nil ->
        {:error, {:unknown_command, name, version}}

      not entry.issuable ->
        {:error, {:not_issuable, name, version}}

      not state.armed ->
        {:error, :disarmed}

      link == nil ->
        {:error, :no_link}

      link.identity != :identified ->
        {:error, :peer_not_identified}

      entry.trust == :authenticated and not link.authenticated ->
        {:error, :peer_not_authenticated}

      state.in_flight != nil ->
        {:error, {:in_flight, state.in_flight.id}}

      not is_integer(ttl) or ttl < state.config[:min_ttl_ms] or ttl > state.config[:max_ttl_ms] ->
        {:error, {:ttl_out_of_range, ttl}}

      not Schema.uuid?(id) ->
        {:error, {:invalid_command_id, id}}

      Map.has_key?(state.commands, id) ->
        {:error, {:duplicate_command_id, id}}

      true ->
        with(
          {:ok, valid} <- Schema.validate_params(entry, params),
          do: {:ok, build(state, entry, valid, id, ttl)}
        )
    end
  end

  defp build(state, entry, params, id, ttl) do
    %{
      id: id,
      name: entry.name,
      version: entry.version,
      params: params,
      preconditions: %{},
      link_generation: state.link.generation,
      adapter_instance_id: state.link.adapter_instance_id,
      ttl_ms: ttl,
      issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      issued_mono: mono(),
      status: :accepted,
      stages: [{:accepted, 0}],
      result: nil,
      observed: :none,
      independent_observation: :not_available,
      unknown_reason: nil,
      ack_timer: nil,
      terminal_timer: nil
    }
  end

  defp transmit(state, cmd) do
    line =
      Schema.encode_command(%{
        command_id: cmd.id,
        link_generation: cmd.link_generation,
        issued_at: cmd.issued_at,
        ttl_ms: cmd.ttl_ms,
        name: cmd.name,
        version: cmd.version,
        params: cmd.params,
        preconditions: cmd.preconditions
      })

    case Link.send_line(state.link.pid, line) do
      :ok ->
        ack = Process.send_after(self(), {:ack_timeout, cmd.id}, state.config[:ack_timeout_ms])

        terminal =
          Process.send_after(
            self(),
            {:terminal_timeout, cmd.id},
            cmd.ttl_ms + state.config[:grace_ms]
          )

        cmd = cmd |> stage(:transmitted) |> Map.merge(%{ack_timer: ack, terminal_timer: terminal})
        journal(state, entry(cmd, "command.transmitted", %{"bytes" => byte_size(line)}))

        state =
          %{state | in_flight: cmd, counters: bump(state.counters, :issued)} |> remember(cmd)

        {:reply, {:ok, cmd.id}, state}

      {:error, reason} ->
        cmd = cmd |> stage(:unknown) |> Map.put(:unknown_reason, {:send_failed, reason})

        journal(
          state,
          entry(cmd, "command.unknown", %{"reason" => "send failed: #{inspect(reason)}"})
        )

        state =
          %{state | counters: state.counters |> bump(:issued) |> bump(:unknown)} |> remember(cmd)

        {:reply, {:error, {:send_failed, reason}}, state}
    end
  end

  defp refuse(state, name, version, reason) do
    journal(state, %{
      "event" => "command.refused",
      "name" => name,
      "version" => version,
      "reason" => inspect(reason)
    })

    {:reply, {:error, reason}, %{state | counters: bump(state.counters, :refused)}}
  end

  # -- results -------------------------------------------------------------------------------------

  defp correlate(%{link: nil} = state, generation, result),
    do:
      anomaly(state, %{
        "event" => "anomaly.result_without_link",
        "link_generation" => generation,
        "command_id" => result.command_id,
        "status" => result.status
      })

  defp correlate(state, generation, result) do
    link = state.link
    cmd = state.in_flight

    cond do
      generation != link.generation or result.link_generation != link.generation ->
        anomaly(state, %{
          "event" => "anomaly.stale_result",
          "link_generation" => result.link_generation,
          "current_link_generation" => link.generation,
          "command_id" => result.command_id,
          "status" => result.status
        })

      result.adapter_instance_id != nil and result.adapter_instance_id != link.adapter_instance_id ->
        anomaly(state, %{
          "event" => "anomaly.foreign_result",
          "link_generation" => generation,
          "command_id" => result.command_id,
          "adapter_instance_id" => result.adapter_instance_id,
          "expected" => link.adapter_instance_id
        })

      (cmd == nil or cmd.id != result.command_id) and
          Map.has_key?(state.commands, result.command_id) ->
        # A result for a command that already reached its end on this link (a late acknowledgement
        # or a second terminal result): evidence of the peer's behaviour, never a state change.
        anomaly(state, %{
          "event" => "anomaly.late_result",
          "link_generation" => generation,
          "command_id" => result.command_id,
          "status" => result.status,
          "command_status" => to_string(state.commands[result.command_id].status)
        })

      cmd == nil or cmd.id != result.command_id ->
        anomaly(state, %{
          "event" => "anomaly.unmatched_result",
          "link_generation" => generation,
          "command_id" => result.command_id,
          "status" => result.status,
          "in_flight" => cmd && cmd.id
        })

      result.status == "received" and cmd.status == :transmitted ->
        cancel(cmd.ack_timer)
        cmd = cmd |> stage(:received) |> Map.put(:ack_timer, nil)

        journal(
          state,
          entry(cmd, "command.received", %{
            "native_at" => result.native_at,
            "frame" => result.frame
          })
        )

        %{state | in_flight: cmd} |> remember(cmd)

      result.status == "received" ->
        anomaly(state, %{
          "event" => "anomaly.late_acknowledgement",
          "command_id" => cmd.id,
          "command_status" => to_string(cmd.status)
        })

      Schema.terminal?(result.status) ->
        cancel(cmd.ack_timer)
        cancel(cmd.terminal_timer)
        status = String.to_existing_atom(result.status)
        observed = if result.observed != nil, do: :native, else: :none

        cmd =
          cmd
          |> stage(status)
          |> Map.merge(%{result: result, observed: observed, ack_timer: nil, terminal_timer: nil})

        journal(
          state,
          entry(cmd, "command.terminal", %{
            "status" => result.status,
            "reason" => result.reason,
            "native_at" => result.native_at,
            "frame" => result.frame,
            "observed" => result.observed,
            "observed_label" => to_string(observed),
            "mission_generation" => result.mission_generation,
            "independent_observation" => "not_available"
          })
        )

        %{state | in_flight: nil} |> remember(cmd)
    end
  end

  defp unknown(%{in_flight: cmd} = state, why) do
    cancel(cmd.ack_timer)
    cancel(cmd.terminal_timer)

    cmd =
      cmd
      |> stage(:unknown)
      |> Map.merge(%{unknown_reason: why, ack_timer: nil, terminal_timer: nil})

    journal(
      state,
      entry(cmd, "command.unknown", %{
        "reason" => to_string(why),
        "last_stage" => cmd.stages |> Enum.at(-2) |> elem(0) |> to_string()
      })
    )

    %{state | in_flight: nil, counters: bump(state.counters, :unknown)} |> remember(cmd)
  end

  defp lose_link(state, reason) do
    link = state.link
    Process.demonitor(link.ref, [:flush])
    state = if state.in_flight, do: unknown(state, :link_lost), else: state

    journal(state, %{
      "event" => "link.closed",
      "link_generation" => link.generation,
      "reason" => inspect(reason),
      "armed_before" => state.armed
    })

    if state.armed,
      do:
        journal(state, %{
          "event" => "authority.disarmed",
          "by" => "link_loss",
          "link_generation" => link.generation
        })

    %{state | link: nil, armed: false}
  end

  # -- helpers ---------------------------------------------------------------------------------------

  defp stage(cmd, status),
    do: %{cmd | status: status, stages: cmd.stages ++ [{status, mono() - cmd.issued_mono}]}

  defp remember(state, cmd) do
    public = Map.drop(cmd, [:ack_timer, :terminal_timer])

    order =
      if Map.has_key?(state.commands, cmd.id), do: state.order, else: state.order ++ [cmd.id]

    %{state | commands: Map.put(state.commands, cmd.id, public), order: order}
  end

  defp entry(cmd, event, fields),
    do:
      Map.merge(fields, %{
        "event" => event,
        "command_id" => cmd.id,
        "link_generation" => cmd.link_generation,
        "name" => cmd.name,
        "version" => cmd.version
      })

  defp anomaly(state, fields) do
    journal(state, fields)
    %{state | counters: bump(state.counters, :anomalies)}
  end

  defp journal(state, entry) do
    case Journal.append(state.journal, entry) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.error(
          "command authority: journal entry #{entry["event"]} not persisted: #{inspect(reason)}"
        )

        error
    end
  end

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)

  defp bump(counters, key), do: Map.update!(counters, key, &(&1 + 1))
  defp mono, do: System.monotonic_time(:millisecond)

  defp status_map(state) do
    link = state.link
    journal_status = safe_journal_status(state.journal)
    identified = link != nil and link.identity == :identified

    %{
      enabled: true,
      trust: %{
        transport: if(link, do: :connected, else: :none),
        protocol: if(link, do: link.protocol, else: :none),
        peer: if(link, do: link.identity, else: :none),
        authenticated: false,
        armed: state.armed,
        ready: identified and state.armed and state.in_flight == nil and journal_status == :open
      },
      link:
        link &&
          Map.take(link, [
            :generation,
            :peer,
            :adapter_instance_id,
            :mission_generation,
            :native_at,
            :capabilities
          ]),
      next_generation: state.next_generation,
      in_flight:
        state.in_flight &&
          Map.take(state.in_flight, [:id, :name, :version, :status, :link_generation]),
      commands:
        Enum.map(
          state.order,
          &Map.take(state.commands[&1], [
            :id,
            :name,
            :version,
            :status,
            :link_generation,
            :observed,
            :unknown_reason
          ])
        ),
      counters: state.counters,
      journal: journal_status,
      allowlist:
        Enum.map(Schema.allowlist(), fn {{n, v}, e} ->
          %{name: n, version: v, issuable: e.issuable, trust: e.trust, effect: e.effect}
        end)
        |> Enum.sort_by(& &1.name)
    }
  end

  defp safe_journal_status(journal) do
    case Journal.status(journal) do
      %{status: s} -> s
    end
  catch
    :exit, _ -> :unavailable
  end
end
