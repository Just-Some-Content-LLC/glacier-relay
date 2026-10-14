defmodule GlacierRelay.Command.Authority do
  @moduledoc """
  The single owner of command issuance (M5-A, ADR 0009; M5 C-2A effectful authority, M5 design
  sections 25–26). It holds the one command link and its handshake state, the arming states, the
  one in-flight command and the record of every command of this boot; it writes every decision
  to `Command.Journal` before acting on it, and fails closed when the journal cannot persist an
  entry.

  Trust states, never equated (ADR 0009 reconciliation): `transport` connected; `protocol`
  negotiated (a hello with a supported version, 1 or 2); `peer` identified (the hello's claimed
  `adapter_instance_id`, labelled *identified*, never authenticated — local arming is not peer
  authentication and a claimed id establishes nothing by itself); `token_verified` (M5 C-2A: a
  version-2 peer answered the welcome's fresh nonce with the HMAC of this run's token — possession
  of the run token shown over this link, never process identity); `authenticated` is reserved and
  unreachable (no credential proves process identity across the WSL2 loopback); `armed` is the
  operator's statement about this authority for inert commands; `effectful_armed` is a distinct,
  one-shot, time-bounded operator statement for one effectful command; `ready` is identified and
  armed with nothing in flight, the journal open and the audit trail intact.

  Issuance rules: disarmed by default; inert arming requires an identified link and is undone by
  disarm or by any link loss (a reconnect needs a new arming); one in-flight command; no command
  id reused; unknown names and versions refused; the reserved `player.outfit.set` v1 is never
  issuable; an `:effectful` entry (`player.outfit.set` v2) is issuable only when the effectful
  configuration is on, the link negotiated version 2 and is `token_verified`, the peer advertised
  the entry, the operator holds an unexpired, unconsumed effectful arming, the `mission_generation`
  precondition is present and the target tuple differs from `expect_current`; the arming is
  consumed (journaled) before acceptance. A successful inert arm never implies effectful arming.
  Effectful arming requires an intact audit, an open journal, nothing in flight, a fresh
  operator-supplied telemetry attestation naming the link's adapter id (section 26.1) and fresh
  operator-supplied socket-ownership evidence that validated; it expires after its TTL and is
  revoked by disarm, link loss or audit degradation; it is never persisted across a restart. No
  automatic retry after an unknown outcome and no automatic reversal.

  Audit trail (M5-B hardening): the `command.accepted` entry is persisted before transmission, so a
  failure there refuses the command and nothing is sent. A failure on any later entry
  (`transmitted`, `received`, `terminal`, `unknown`, `disarmed`, `link.closed`) cannot undo what
  already happened — a line may have been written to the peer, the peer may have applied it — so
  the transition is applied in memory as the evidence says, the command's record carries the
  unaudited stages (`audit: {:gap, stages}`), the authority's audit state becomes
  `{:degraded, ...}`, it disarms (both modes), and it refuses to arm or issue again for the rest
  of its life: a reconnect does not make it ready, only a restart of the subtree (a new journal)
  does.

  Status ladder of a command: `accepted` (journaled) → `transmitted` → `received` → a terminal
  native status (`applied`, `rejected`, `busy`, `duplicate`, `expired`, `precondition_failed`,
  `unavailable`, `failed`), or `unknown` after a missed acknowledgement, a missed terminal result or
  a link loss. `observed` is `:none` or `:native` (the result carried a read-back; the fake or real
  peer's own report, never independent evidence). For an effectful command the record also
  carries the peer-reported `effect` (`invocation` reported or not; `effect` changed / unchanged /
  uncertain / none / unreported; `read_back` native_same_frame or none), `consequences: :unknown`
  always, and the operator's observations (testimony, never engine-authored evidence). A late
  result for a command that already ended is an anomaly and never a state change, with one
  additive refinement: a late non-application terminal (rejected / expired / precondition_failed /
  unavailable) for an `unknown` command with the exact command, link and adapter identity is
  journaled as `command.unknown_refined` and recorded beside the status, which stays `unknown`;
  a contradictory refinement is an anomaly; a late `applied` only marks `late_applied_claim`.
  Timeouts use the monotonic clock only.
  """

  use GenServer
  require Logger

  alias GlacierRelay.Command.{Correlation, Journal, Link, Schema}

  @defaults [
    ack_timeout_ms: 2_000,
    grace_ms: 1_000,
    default_ttl_ms: 5_000,
    max_ttl_ms: 10_000,
    min_ttl_ms: 100,
    effectful: false,
    token: nil,
    token_file: nil,
    effectful_ttl_default_ms: 30_000,
    effectful_ttl_max_ms: 120_000,
    evidence_max_age_ms: 120_000
  ]

  @observation_types ~w(visual_confirmation visual_no_change later_frame_read_back engine_consistent note)
  @max_observation_text 500
  @token_hex ~r/^[0-9a-f]{64}$/

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # -- operator API ------------------------------------------------------------------------------

  @doc "Arms the authority for inert commands on the current link. Refused without an identified link, a working journal or an intact audit trail."
  def arm, do: GenServer.call(__MODULE__, :arm)

  @doc "Disarms the authority (both modes): no new command may be issued until armed again."
  def disarm, do: GenServer.call(__MODULE__, :disarm)

  @doc """
  M5 C-2A: arms the authority for exactly one effectful command. `opts`: `:ttl_ms` (bounded),
  `:ownership` (the operator-supplied socket-ownership evidence map, required). Requires the
  effectful configuration, a token-verified version-2 link, an open journal, an intact audit,
  nothing in flight and a fresh telemetry attestation for this link.
  """
  def arm_effectful(opts \\ []), do: GenServer.call(__MODULE__, {:arm_effectful, opts})

  @doc """
  M5 C-2A: records an operator-supplied telemetry attestation (section 26.1): the adapter
  identity the operator read from the observer out of band, with its freshness. Never derived
  from the command peer's own messages.
  """
  def attest_telemetry(attestation) when is_map(attestation),
    do: GenServer.call(__MODULE__, {:attest_telemetry, attestation})

  @doc """
  Issues an allowlisted command. `opts`: `:ttl_ms`, `:command_id` (tests only; a fresh UUID v4
  by default), `:preconditions`, `:reversal_of` (the id of the applied command this one
  reverses). Returns `{:ok, command_id}` or `{:error, reason}`; the ladder is read with
  `command/1`.
  """
  def issue(name, version, params \\ %{}, opts \\ [])
      when is_binary(name) and is_integer(version) and is_map(params),
      do: GenServer.call(__MODULE__, {:issue, name, version, params, opts})

  @doc """
  M5 C-2A: attaches an operator observation to an existing command. `type` is one of
  #{inspect(@observation_types)}; `text` is bounded (#{@max_observation_text} bytes); `opts`:
  `:at` (ISO-8601, default now), `:inspection_command_id` (for `later_frame_read_back`: an
  applied `relay.inspect.outfit` of this node whose hero tuple is compared with the command's
  reported current tuple), `:envelope` (for `engine_consistent`: the plain envelope map the
  operator fetched from the observer; the pure correlation rule must hold). The entry is journaled
  first; the record is updated only after the append succeeded. Operator testimony, never
  engine-authored evidence.
  """
  def observe(command_id, type, text, opts \\ [])
      when is_binary(command_id) and is_binary(type) and is_binary(text),
      do: GenServer.call(__MODULE__, {:observe, command_id, type, text, opts})

  @doc "The authority's status: trust states, arming, audit state, link, in-flight command, counters."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "One command's record (ladder, result, observation, audit), or nil."
  def command(command_id), do: GenServer.call(__MODULE__, {:command, command_id})

  # -- link-facing API (called by Command.Link only) -------------------------------------------------

  @doc false
  def link_opened(pid, peer), do: GenServer.call(__MODULE__, {:link_opened, pid, peer})
  @doc false
  def peer_hello(generation, hello),
    do: GenServer.call(__MODULE__, {:peer_hello, generation, hello})

  @doc false
  def peer_attest(generation, attest),
    do: GenServer.call(__MODULE__, {:peer_attest, generation, attest})

  @doc false
  def result(generation, result), do: GenServer.cast(__MODULE__, {:result, generation, result})
  @doc false
  def link_closed(generation, reason),
    do: GenServer.cast(__MODULE__, {:link_closed, generation, reason})

  # -- state -------------------------------------------------------------------------------------

  @impl true
  def init(opts) do
    config = Keyword.merge(@defaults, opts)
    {token, token_source} = load_token(config)

    {:ok,
     %{
       config: Keyword.put(config, :token, token),
       token_source: token_source,
       journal: Keyword.get(opts, :journal, Journal),
       link: nil,
       next_generation: 1,
       armed: false,
       effectful: nil,
       corroboration: nil,
       audit: :intact,
       in_flight: nil,
       commands: %{},
       order: [],
       counters: %{
         issued: 0,
         refused: 0,
         anomalies: 0,
         links: 0,
         unknown: 0,
         audit_failures: 0,
         attest_failures: 0,
         observations: 0
       }
     }}
  end

  # The run token: from `:token` (tests; an ephemeral value) or `:token_file` (64 lowercase hex
  # characters, read once, never logged). Anything else leaves the authority without a token:
  # no peer can become token_verified and nothing effectful is issuable.
  defp load_token(config) do
    cond do
      is_binary(config[:token]) and Regex.match?(@token_hex, config[:token]) ->
        {config[:token], :configured}

      is_binary(config[:token]) ->
        Logger.error(
          "command authority: the configured token is not 64 lowercase hex characters; ignored"
        )

        {nil, :invalid}

      is_binary(config[:token_file]) ->
        case File.read(config[:token_file]) do
          {:ok, bytes} ->
            value = String.trim(bytes)

            if Regex.match?(@token_hex, value),
              do: {value, :file},
              else:
                Logger.error(
                  "command authority: token file is not 64 lowercase hex characters; ignored"
                ) && {nil, :invalid}

          {:error, reason} ->
            Logger.error(
              "command authority: token file unreadable (#{inspect(reason)}); no token"
            )

            {nil, :unreadable}
        end

      true ->
        {nil, :none}
    end
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
      protocol_version: nil,
      identity: :unidentified,
      authenticated: false,
      token_verified: false,
      nonce: nil,
      attest_attempts: 0,
      adapter_instance_id: nil,
      mission_generation: nil,
      native_at: nil,
      capabilities: [],
      advertised: [],
      opened_mono: mono()
    }

    state = %{
      state
      | link: link,
        next_generation: generation + 1,
        counters: bump(state.counters, :links)
    }

    {state, _} =
      audit(state, %{"event" => "link.connected", "link_generation" => generation, "peer" => peer})

    {:reply, {:ok, generation}, state}
  end

  def handle_call({:link_opened, _pid, peer}, _from, state) do
    {state, _} =
      audit(state, %{
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
    version = hello.protocol_version
    nonce = if version == 2, do: Schema.nonce(), else: nil
    advertised = Schema.issuable_for(version, hello.capabilities, state.config[:effectful])

    link = %{
      link
      | protocol: :negotiated,
        protocol_version: version,
        nonce: nonce,
        identity: :identified,
        adapter_instance_id: hello.adapter_instance_id,
        mission_generation: hello.mission_generation,
        native_at: hello.native_at,
        capabilities: hello.capabilities,
        advertised: advertised
    }

    state = %{state | link: link}

    {state, _} =
      audit(state, %{
        "event" => "peer.identified",
        "link_generation" => generation,
        "protocol_version" => version,
        "adapter_instance_id" => hello.adapter_instance_id,
        "mission_generation" => hello.mission_generation,
        "native_at" => hello.native_at,
        "capabilities" => hello.capabilities,
        "advertised" => advertised,
        "attest_required" => version == 2,
        "trust" => "identified (claimed; not authenticated)"
      })

    welcome =
      case version do
        1 ->
          Schema.encode_welcome(generation, node())

        2 ->
          Schema.encode_welcome(generation, node(),
            version: 2,
            nonce: nonce,
            allowlist: advertised
          )
      end

    {:reply, {:ok, welcome}, state}
  end

  def handle_call({:peer_hello, generation, _hello}, _from, state) do
    state =
      anomaly(state, %{
        "event" => "anomaly.hello_on_unknown_link",
        "link_generation" => generation
      })

    {:reply, {:error, :unknown_link}, state}
  end

  def handle_call(
        {:peer_attest, generation, attest},
        _from,
        %{link: %{generation: generation} = link} = state
      ) do
    token = state.config[:token]

    verdict =
      cond do
        link.protocol_version != 2 ->
          {:error, :attest_on_version_1_link}

        link.identity != :identified ->
          {:error, :attest_before_hello}

        link.token_verified or link.attest_attempts > 0 ->
          {:error, :second_attest}

        token == nil ->
          {:error, :no_token_configured}

        attest.link_generation != generation ->
          {:error, :generation_mismatch}

        attest.adapter_instance_id != link.adapter_instance_id ->
          {:error, :adapter_mismatch}

        not Schema.mac_equal?(
          Schema.attest_mac(token, link.nonce, generation, link.adapter_instance_id),
          attest.mac
        ) ->
          {:error, :mac_mismatch}

        true ->
          :ok
      end

    link = %{link | attest_attempts: link.attest_attempts + 1}

    case verdict do
      :ok ->
        link = %{link | token_verified: true}
        state = %{state | link: link}

        {state, _} =
          audit(state, %{
            "event" => "peer.token_verified",
            "link_generation" => generation,
            "adapter_instance_id" => link.adapter_instance_id,
            "nonce" => link.nonce,
            "trust" =>
              "token_verified (possession of the run token shown over this link; not process identity; not authenticated)"
          })

        {:reply, :ok, state}

      {:error, reason} ->
        # The token and the MAC are never journaled or logged; the link closes (the link process
        # treats the refusal as a protocol violation) and nothing falls back to version 1.
        state = %{state | link: link, counters: bump(state.counters, :attest_failures)}

        {state, _} =
          audit(state, %{
            "event" => "peer.attest_failed",
            "link_generation" => generation,
            "adapter_instance_id" => link.adapter_instance_id,
            "reason" => to_string(reason)
          })

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:peer_attest, generation, _attest}, _from, state) do
    state =
      anomaly(state, %{
        "event" => "anomaly.attest_on_unknown_link",
        "link_generation" => generation
      })

    {:reply, {:error, :unknown_link}, state}
  end

  def handle_call(:arm, _from, state) do
    cond do
      state.audit != :intact ->
        {:reply, {:error, {:audit_degraded, elem(state.audit, 1)}}, state}

      state.armed ->
        {:reply, {:error, :already_armed}, state}

      state.link == nil or state.link.identity != :identified ->
        {:reply, {:error, :no_identified_link}, state}

      true ->
        # The arming entry must be durable before the authority is armed: a failure here leaves
        # it disarmed (and, as for every failed entry, degraded).
        case audit(state, %{
               "event" => "authority.armed",
               "link_generation" => state.link.generation,
               "adapter_instance_id" => state.link.adapter_instance_id,
               "mode" => "inert"
             }) do
          {state, :ok} -> {:reply, :ok, %{state | armed: true}}
          {state, {:error, reason}} -> {:reply, {:error, {:journal_unavailable, reason}}, state}
        end
    end
  end

  def handle_call(:disarm, _from, state) do
    # Disarming never depends on the journal: it is the fail-closed direction. The entry is
    # attempted; its failure degrades the audit state like any other.
    {state, _} =
      audit(state, %{
        "event" => "authority.disarmed",
        "by" => "operator",
        "in_flight" => state.in_flight && state.in_flight.id,
        "effectful_was_armed" => state.effectful != nil
      })

    {:reply, :ok, %{clear_effectful(state) | armed: false}}
  end

  def handle_call({:attest_telemetry, attestation}, _from, state) do
    case validate_telemetry_attestation(attestation) do
      {:ok, valid} ->
        link = state.link

        matches =
          link != nil and link.identity == :identified and
            valid.adapter_instance_id == link.adapter_instance_id

        {state, outcome} =
          audit(state, %{
            "event" => "operator.telemetry_attested",
            "adapter_instance_id" => valid.adapter_instance_id,
            "observed_at" => valid.observed_at,
            "basis" => valid.basis,
            "evidence_ref" => valid.evidence_ref,
            "max_age_ms" => valid.max_age_ms,
            "link_generation" => link && link.generation,
            "matches_link_identity" => matches,
            "label" => "operator-provided corroboration; not an authority observation"
          })

        case {outcome, matches} do
          {:ok, true} ->
            corroboration = %{
              attestation: valid,
              received_mono: mono(),
              link_generation: link.generation
            }

            {:reply, :ok, %{state | corroboration: corroboration}}

          {:ok, false} ->
            {:reply, {:error, :adapter_identity_mismatch}, %{state | corroboration: nil}}

          {{:error, reason}, _} ->
            {:reply, {:error, {:journal_unavailable, reason}}, %{state | corroboration: nil}}
        end

      {:error, reason} ->
        {:reply, {:error, {:invalid_attestation, reason}}, state}
    end
  end

  def handle_call({:arm_effectful, opts}, _from, state) do
    case check_arm_effectful(state, opts) do
      {:ok, ttl, ownership} ->
        ref = make_ref()

        entry = %{
          "event" => "authority.armed_effectful",
          "link_generation" => state.link.generation,
          "adapter_instance_id" => state.link.adapter_instance_id,
          "ttl_ms" => ttl,
          "one_shot" => true,
          "ownership" =>
            Map.put(ownership, "label", "operator-provided evidence; not cryptographic identity"),
          "corroboration" => %{
            "observed_at" => state.corroboration.attestation.observed_at,
            "evidence_ref" => state.corroboration.attestation.evidence_ref,
            "age_ms" => mono() - state.corroboration.received_mono
          }
        }

        case audit(state, entry) do
          {state, :ok} ->
            timer = Process.send_after(self(), {:effectful_expiry, ref}, ttl)

            effectful = %{
              ref: ref,
              timer: timer,
              ttl_ms: ttl,
              armed_mono: mono(),
              link_generation: state.link.generation,
              ownership: ownership
            }

            {:reply, :ok, %{state | effectful: effectful}}

          {state, {:error, reason}} ->
            {:reply, {:error, {:journal_unavailable, reason}}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:issue, name, version, params, opts}, _from, state) do
    case prepare(state, name, version, params, opts) do
      {:ok, cmd} ->
        # An effectful command consumes its one-shot arming first (durably), then is accepted
        # (durably), then transmitted. A failure anywhere before transmission refuses the command
        # and leaves the arming consumed: fail closed, never a second chance on the same arming.
        with {:ok, state} <- consume_effectful(state, cmd),
             {state, :ok} <-
               audit(
                 state,
                 entry(cmd, "command.accepted", %{
                   "name" => name,
                   "version" => version,
                   "params" => params,
                   "preconditions" => cmd.preconditions,
                   "ttl_ms" => cmd.ttl_ms,
                   "effectful" => cmd.effectful,
                   "reversal_of" => cmd.reversal_of
                 })
               ) do
          transmit(state, cmd)
        else
          {state, {:error, reason}} ->
            refuse(state, name, version, {:journal_unavailable, reason})

          {:error, state, reason} ->
            refuse(state, name, version, reason)
        end

      {:error, reason} ->
        refuse(state, name, version, reason)
    end
  end

  def handle_call({:observe, command_id, type, text, opts}, _from, state) do
    case Map.fetch(state.commands, command_id) do
      :error ->
        {:reply, {:error, :unknown_command_id}, state}

      {:ok, cmd} ->
        case build_observation(state, cmd, type, text, opts) do
          {:ok, observation} ->
            case audit(
                   state,
                   Map.merge(observation, %{
                     "event" => "operator.observation",
                     "command_id" => command_id,
                     "link_generation" => cmd.link_generation,
                     "name" => cmd.name,
                     "version" => cmd.version
                   })
                 ) do
              {state, :ok} ->
                cmd = apply_observation(cmd, observation)
                state = %{state | counters: bump(state.counters, :observations)} |> remember(cmd)
                {:reply, {:ok, Map.drop(observation, ["label"])}, state}

              {state, {:error, reason}} ->
                {:reply, {:error, {:journal_unavailable, reason}}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
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
    {state, _} =
      audit(state, %{
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

  def handle_info({:effectful_expiry, ref}, %{effectful: %{ref: ref}} = state) do
    {state, _} =
      audit(state, %{
        "event" => "authority.effectful_expired",
        "link_generation" => state.effectful.link_generation,
        "ttl_ms" => state.effectful.ttl_ms
      })

    {:noreply, %{state | effectful: nil}}
  end

  def handle_info({_timer, _id}, state), do: {:noreply, state}

  # -- effectful arming --------------------------------------------------------------------------

  defp check_arm_effectful(state, opts) do
    link = state.link
    ttl = Keyword.get(opts, :ttl_ms, state.config[:effectful_ttl_default_ms])
    max_age = state.config[:evidence_max_age_ms]

    cond do
      state.audit != :intact ->
        {:error, {:audit_degraded, elem(state.audit, 1)}}

      not state.config[:effectful] ->
        {:error, :effectful_disabled}

      state.config[:token] == nil ->
        {:error, :no_token_configured}

      link == nil or link.identity != :identified ->
        {:error, :no_identified_link}

      link.protocol_version != 2 ->
        {:error, :peer_protocol_version_1}

      not link.token_verified ->
        {:error, :peer_not_token_verified}

      safe_journal_status(state.journal) != :open ->
        {:error, :journal_not_open}

      state.in_flight != nil ->
        {:error, {:in_flight, state.in_flight.id}}

      state.effectful != nil ->
        {:error, :already_armed_effectful}

      not is_integer(ttl) or ttl < 1_000 or ttl > state.config[:effectful_ttl_max_ms] ->
        {:error, {:ttl_out_of_range, ttl}}

      state.corroboration == nil ->
        {:error, :telemetry_corroboration_missing}

      state.corroboration.link_generation != link.generation ->
        {:error, :telemetry_corroboration_for_other_link}

      mono() - state.corroboration.received_mono >
          min(state.corroboration.attestation.max_age_ms, max_age) ->
        {:error, :telemetry_corroboration_stale}

      state.corroboration.attestation.adapter_instance_id != link.adapter_instance_id ->
        {:error, :telemetry_corroboration_mismatch}

      true ->
        check_ownership(Keyword.get(opts, :ownership), max_age, ttl)
    end
  end

  @ownership_keys ~w(collected_at owner_pid executable local_port remote_port connections validation source max_age_ms)

  # The operator-supplied socket-ownership evidence: its schema, its freshness (the operator's
  # `collected_at` against the wall clock, bounded by its own `max_age_ms` and the configured
  # maximum) and its validation result. Labelled operator-provided evidence, never identity.
  defp check_ownership(%{} = o, max_age, ttl) do
    with :ok <- unknown_keys(o, @ownership_keys),
         {:ok, collected} <- iso(o["collected_at"], :collected_at_invalid),
         true <-
           (is_integer(o["owner_pid"]) and o["owner_pid"] > 0) or {:error, :owner_pid_invalid},
         true <-
           (is_binary(o["executable"]) and byte_size(o["executable"]) in 1..128) or
             {:error, :executable_invalid},
         true <-
           (is_integer(o["connections"]) and o["connections"] >= 0) or
             {:error, :connections_invalid},
         true <-
           (is_binary(o["validation"]) and byte_size(o["validation"]) in 1..64) or
             {:error, :validation_invalid},
         true <-
           (is_binary(o["source"]) and byte_size(o["source"]) in 1..128) or
             {:error, :source_invalid},
         true <-
           (is_integer(o["max_age_ms"]) and o["max_age_ms"] > 0) or {:error, :max_age_invalid},
         true <-
           ((is_nil(o["local_port"]) or is_integer(o["local_port"])) and
              (is_nil(o["remote_port"]) or is_integer(o["remote_port"]))) or
             {:error, :ports_invalid} do
      age = DateTime.diff(DateTime.utc_now(), collected, :millisecond)

      cond do
        age < -5_000 ->
          {:error, :ownership_evidence_from_the_future}

        age > min(o["max_age_ms"], max_age) ->
          {:error, :ownership_evidence_stale}

        o["validation"] != "exactly_one_hitman" ->
          {:error, {:ownership_evidence_rejected, o["validation"]}}

        o["connections"] != 1 ->
          {:error, {:ownership_evidence_rejected, "connections #{o["connections"]}"}}

        true ->
          {:ok, ttl, Map.put(o, "age_ms_at_arming", age)}
      end
    else
      {:error, reason} -> {:error, {:ownership_evidence_invalid, reason}}
    end
  end

  defp check_ownership(_, _max_age, _ttl), do: {:error, :ownership_evidence_missing}

  defp unknown_keys(map, allowed) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_keys, Enum.sort(unknown)}}
    end
  end

  defp iso(text, reason) do
    case is_binary(text) and DateTime.from_iso8601(text) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, reason}
    end
  end

  @attestation_keys ~w(adapter_instance_id observed_at basis evidence_ref max_age_ms)

  defp validate_telemetry_attestation(a) do
    with :ok <- unknown_keys(a, @attestation_keys),
         true <- Schema.uuid?(a["adapter_instance_id"]) or {:error, :adapter_instance_id_invalid},
         {:ok, _} <- iso(a["observed_at"], :observed_at_invalid),
         true <-
           (is_binary(a["basis"]) and byte_size(a["basis"]) in 1..200) or {:error, :basis_invalid},
         true <-
           (is_binary(a["evidence_ref"]) and byte_size(a["evidence_ref"]) in 1..200) or
             {:error, :evidence_ref_invalid},
         true <-
           (is_integer(a["max_age_ms"]) and a["max_age_ms"] in 1..600_000) or
             {:error, :max_age_invalid} do
      {:ok,
       %{
         adapter_instance_id: a["adapter_instance_id"],
         observed_at: a["observed_at"],
         basis: a["basis"],
         evidence_ref: a["evidence_ref"],
         max_age_ms: a["max_age_ms"]
       }}
    end
  end

  defp clear_effectful(%{effectful: nil} = state), do: state

  defp clear_effectful(%{effectful: e} = state) do
    cancel(e.timer)
    %{state | effectful: nil}
  end

  # The one-shot arming is consumed — durably — before the command is accepted; a journal failure
  # here refuses the command (nothing sent) and the arming is gone either way.
  defp consume_effectful(state, %{effectful: false}), do: {:ok, state}

  defp consume_effectful(state, cmd) do
    case audit(state, %{
           "event" => "authority.effectful_consumed",
           "link_generation" => state.link.generation,
           "command_id" => cmd.id,
           "armed_for_ms" => mono() - state.effectful.armed_mono
         }) do
      {state, :ok} ->
        {:ok, clear_effectful(state)}

      {state, {:error, reason}} ->
        {:error, clear_effectful(state), {:journal_unavailable, reason}}
    end
  end

  # -- issuance ------------------------------------------------------------------------------------

  defp prepare(state, name, version, params, opts) do
    entry = Schema.entry(name, version)
    link = state.link
    ttl = Keyword.get(opts, :ttl_ms, state.config[:default_ttl_ms])
    id = Keyword.get(opts, :command_id) || Schema.uuid4()
    preconditions = Keyword.get(opts, :preconditions, %{})
    effectful = entry != nil and entry.issuable == :effectful

    cond do
      state.audit != :intact ->
        {:error, {:audit_degraded, elem(state.audit, 1)}}

      entry == nil ->
        {:error, {:unknown_command, name, version}}

      entry.issuable == false ->
        {:error, {:not_issuable, name, version}}

      not effectful and not state.armed ->
        {:error, :disarmed}

      link == nil ->
        {:error, :no_link}

      link.identity != :identified ->
        {:error, :peer_not_identified}

      entry.trust == :authenticated and not link.authenticated ->
        {:error, :peer_not_authenticated}

      effectful and not state.config[:effectful] ->
        {:error, :effectful_disabled}

      effectful and link.protocol_version != 2 ->
        {:error, :peer_protocol_version_1}

      effectful and not link.token_verified ->
        {:error, :peer_not_token_verified}

      effectful and %{"name" => name, "version" => version} not in link.advertised ->
        {:error, :entry_not_advertised_to_peer}

      effectful and state.effectful == nil ->
        {:error, :not_armed_effectful}

      effectful and state.effectful.link_generation != link.generation ->
        {:error, :effectful_arming_for_other_link}

      state.in_flight != nil ->
        {:error, {:in_flight, state.in_flight.id}}

      not is_integer(ttl) or ttl < state.config[:min_ttl_ms] or ttl > state.config[:max_ttl_ms] ->
        {:error, {:ttl_out_of_range, ttl}}

      not Schema.uuid?(id) ->
        {:error, {:invalid_command_id, id}}

      Map.has_key?(state.commands, id) ->
        {:error, {:duplicate_command_id, id}}

      not valid_preconditions?(preconditions) ->
        {:error, {:invalid_preconditions, preconditions}}

      :mission_generation in entry.preconditions and
          not Map.has_key?(preconditions, "mission_generation") ->
        {:error, :mission_generation_required}

      true ->
        with {:ok, valid} <- Schema.validate_params(entry, params),
             :ok <- check_not_a_noop(entry, valid),
             :ok <- check_reversal_of(state, Keyword.get(opts, :reversal_of)) do
          {:ok,
           build(
             state,
             entry,
             valid,
             id,
             ttl,
             preconditions,
             effectful,
             Keyword.get(opts, :reversal_of)
           )}
        end
    end
  end

  # The same tuple as the current one is a no-op and never satisfies the effectful milestone.
  defp check_not_a_noop(%{effect: :outfit}, %{"expect_current" => current} = params) do
    if Map.take(params, ["disguise_repository_id", "charset", "variation"]) == current,
      do: {:error, :same_as_current},
      else: :ok
  end

  defp check_not_a_noop(_entry, _params), do: :ok

  defp check_reversal_of(_state, nil), do: :ok

  defp check_reversal_of(state, id) when is_binary(id) do
    if Map.has_key?(state.commands, id), do: :ok, else: {:error, {:reversal_of_unknown, id}}
  end

  defp check_reversal_of(_state, other), do: {:error, {:reversal_of_invalid, other}}

  # M5 C-1: the only precondition the protocol defines is `mission_generation` (text, at most 64
  # bytes); it is supplied by the operator with the command and judged on the native frame.
  defp valid_preconditions?(%{} = map) when map_size(map) == 0, do: true

  defp valid_preconditions?(%{"mission_generation" => gen} = map),
    do: map_size(map) == 1 and is_binary(gen) and byte_size(gen) in 1..64

  defp valid_preconditions?(_), do: false

  defp build(state, entry, params, id, ttl, preconditions, effectful, reversal_of) do
    %{
      id: id,
      name: entry.name,
      version: entry.version,
      params: params,
      preconditions: preconditions,
      effectful: effectful,
      reversal_of: reversal_of,
      link_generation: state.link.generation,
      protocol_version: state.link.protocol_version,
      adapter_instance_id: state.link.adapter_instance_id,
      ttl_ms: ttl,
      issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      issued_mono: mono(),
      status: :accepted,
      stages: [{:accepted, 0}],
      result: nil,
      observed: :none,
      independent_observation: :not_available,
      effect: nil,
      consequences: if(effectful, do: :unknown, else: :none),
      restored: nil,
      operator_observations: [],
      refinement: nil,
      late_applied_claim: false,
      unknown_reason: nil,
      audit: :intact,
      ack_timer: nil,
      terminal_timer: nil
    }
  end

  defp transmit(state, cmd) do
    line =
      Schema.encode_command(%{
        protocol_version: cmd.protocol_version,
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

        # The bytes are out; this entry's failure cannot be undone and must not be hidden: the
        # command stays in flight (uncertain, never "unapplied"), its record notes the gap, the
        # authority degrades and disarms.
        {state, cmd} =
          audit_stage(
            state,
            cmd,
            entry(cmd, "command.transmitted", %{"bytes" => byte_size(line)})
          )

        state =
          %{state | in_flight: cmd, counters: bump(state.counters, :issued)} |> remember(cmd)

        {:reply, {:ok, cmd.id}, state}

      {:error, reason} ->
        cmd = cmd |> stage(:unknown) |> Map.put(:unknown_reason, {:send_failed, reason})

        {state, cmd} =
          audit_stage(
            state,
            cmd,
            entry(cmd, "command.unknown", %{"reason" => "send failed: #{inspect(reason)}"})
          )

        state =
          %{state | counters: state.counters |> bump(:issued) |> bump(:unknown)} |> remember(cmd)

        {:reply, {:error, {:send_failed, reason}}, state}
    end
  end

  defp refuse(state, name, version, reason) do
    {state, _} =
      audit(state, %{
        "event" => "command.refused",
        "name" => name,
        "version" => version,
        "reason" => inspect(reason)
      })

    {:reply, {:error, reason}, %{state | counters: bump(state.counters, :refused)}}
  end

  # -- observations -------------------------------------------------------------------------------

  defp build_observation(state, cmd, type, text, opts) do
    at = Keyword.get(opts, :at, DateTime.utc_now() |> DateTime.to_iso8601())

    base = %{
      "type" => type,
      "text" => text,
      "at" => at,
      "label" => "operator testimony; not engine-authored evidence"
    }

    cond do
      type not in @observation_types ->
        {:error, {:unknown_observation_type, type}}

      byte_size(text) > @max_observation_text ->
        {:error, :text_too_long}

      not match?({:ok, _, _}, DateTime.from_iso8601(at)) ->
        {:error, :at_invalid}

      type == "later_frame_read_back" ->
        later_frame(state, cmd, base, Keyword.get(opts, :inspection_command_id))

      type == "engine_consistent" ->
        engine_consistent(cmd, base, Keyword.get(opts, :envelope), opts)

      true ->
        {:ok, base}
    end
  end

  # Two native read-backs compared by the authority: the command's reported current tuple and a
  # later applied inspection's hero tuple, same mission generation, later frame. Still native.
  defp later_frame(state, cmd, base, inspection_id) do
    with true <- is_binary(inspection_id) or {:error, :inspection_command_id_required},
         {:ok, inspection} <-
           Map.fetch(state.commands, inspection_id) |> ok_or(:inspection_unknown),
         true <-
           (inspection.name == "relay.inspect.outfit" and inspection.status == :applied) or
             {:error, :inspection_not_applied},
         true <- (cmd.status == :applied and cmd.result != nil) or {:error, :command_not_applied},
         {:ok, current} <-
           Schema.observed_tuple(cmd.result.observed, "current")
           |> ok_or(:current_tuple_unobserved),
         {:ok, hero} <-
           Schema.observed_tuple(inspection.result.observed, "hero")
           |> ok_or(:hero_tuple_unobserved) do
      same_generation = inspection.result.mission_generation == cmd.result.mission_generation

      later =
        is_integer(inspection.result.frame) and is_integer(cmd.result.frame) and
          inspection.result.frame > cmd.result.frame

      conclusion =
        cond do
          not same_generation -> "other_generation"
          not later -> "not_a_later_frame"
          hero == current -> "consistent"
          true -> "inconsistent"
        end

      {:ok,
       Map.merge(base, %{
         "inspection_command_id" => inspection_id,
         "inspection_frame" => inspection.result.frame,
         "command_frame" => cmd.result.frame,
         "conclusion" => conclusion,
         "evidence_class" =>
           "native_later_frame (the peer's own read-back on a later frame; not independent)"
       })}
    end
  end

  defp engine_consistent(cmd, base, envelope, opts) do
    with true <- is_map(envelope) or {:error, :envelope_required},
         true <- (cmd.status == :applied and cmd.result != nil) or {:error, :command_not_applied} do
      case Correlation.check(cmd, envelope, Keyword.take(opts, [:window_ms, :sequence_floor])) do
        {:consistent, details} ->
          {:ok,
           Map.merge(base, %{
             "conclusion" => "engine_consistent",
             "sequence" => details.sequence,
             "envelope_native_at" => details.native_at,
             "delay_ms" => details.delay_ms,
             "wording" => details.wording,
             "evidence_class" =>
               "engine-authored envelope referenced by the operator; correlated by the pure rule; causality not established"
           })}

        {:inconsistent, reasons} ->
          {:error, {:not_consistent, reasons}}
      end
    end
  end

  defp ok_or({:ok, v}, _reason), do: {:ok, v}
  defp ok_or(_, reason), do: {:error, reason}

  defp apply_observation(cmd, observation) do
    public = Map.drop(observation, ["label"])
    cmd = %{cmd | operator_observations: cmd.operator_observations ++ [public]}

    case observation do
      %{"type" => "later_frame_read_back", "conclusion" => c} ->
        update_effect(cmd, :read_back_later, c)

      %{"type" => "engine_consistent"} ->
        update_effect(cmd, :engine_consistent, true)

      %{"type" => "visual_confirmation"} ->
        update_effect(cmd, :operator, :confirmed)

      %{"type" => "visual_no_change"} ->
        update_effect(cmd, :operator, :no_change)

      _ ->
        cmd
    end
  end

  defp update_effect(%{effect: nil} = cmd, key, value),
    do: %{cmd | effect: Map.put(empty_effect(), key, value)}

  defp update_effect(cmd, key, value), do: %{cmd | effect: Map.put(cmd.effect, key, value)}

  defp empty_effect,
    do: %{
      invocation: :not_reported,
      effect: :unreported,
      read_back: :none,
      read_back_later: nil,
      engine_consistent: false,
      operator: nil
    }

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
        late_result(state, generation, result)

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

        {state, cmd} =
          audit_stage(
            state,
            cmd,
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
        status = Schema.status_atom(result.status)
        observed = if result.observed != nil, do: :native, else: :none
        effect = if cmd.effectful, do: classify_effect(result), else: nil
        restored = if cmd.reversal_of, do: classify_restoration(state, cmd, result), else: nil

        cmd =
          cmd
          |> stage(status)
          |> Map.merge(%{
            result: result,
            observed: observed,
            effect: effect,
            restored: restored,
            ack_timer: nil,
            terminal_timer: nil
          })

        {state, cmd} =
          audit_stage(
            state,
            cmd,
            entry(cmd, "command.terminal", %{
              "status" => result.status,
              "reason" => result.reason,
              "native_at" => result.native_at,
              "frame" => result.frame,
              "observed" => result.observed,
              "observed_label" => to_string(observed),
              "mission_generation" => result.mission_generation,
              "independent_observation" => "not_available",
              "effectful" => cmd.effectful,
              "invocation" => effect && to_string(effect.invocation),
              "effect" => effect && to_string(effect.effect),
              "read_back" => effect && to_string(effect.read_back),
              "consequences" => to_string(cmd.consequences),
              "reversal_of" => cmd.reversal_of,
              "restored" => restored && to_string(restored)
            })
          )

        %{state | in_flight: nil} |> remember(cmd)
    end
  end

  # A result for a command that already reached its end on this link: evidence of the peer's
  # behaviour, never a status change. One additive refinement (M5 C-2A, research section 8): a
  # late non-application terminal for an unknown command with the exact command, link and adapter
  # identity is journaled beside the unknown status; a contradictory one is an anomaly; a late
  # `applied` is an anomaly that also marks the record `late_applied_claim`.
  defp late_result(state, generation, result) do
    known = state.commands[result.command_id]

    exact_identity =
      known.link_generation == result.link_generation and known.link_generation == generation and
        known.adapter_instance_id == result.adapter_instance_id

    base = %{
      "link_generation" => generation,
      "command_id" => result.command_id,
      "status" => result.status,
      "command_status" => to_string(known.status)
    }

    cond do
      known.status == :unknown and exact_identity and Schema.nonapplication?(result.status) and
          known.refinement == nil ->
        refinement = %{
          native_terminal: result.status,
          reason: result.reason,
          native_at: result.native_at,
          frame: result.frame
        }

        {state, _} =
          audit(
            state,
            Map.merge(base, %{
              "event" => "command.unknown_refined",
              "native_terminal" => result.status,
              "reason" => result.reason,
              "native_at" => result.native_at,
              "frame" => result.frame,
              "status_after" => "unknown",
              "text" => "unknown; native later reported #{result.status} (not applied)"
            })
          )

        remember(state, %{known | refinement: refinement})

      known.status == :unknown and exact_identity and Schema.nonapplication?(result.status) ->
        if known.refinement.native_terminal == result.status do
          anomaly(state, Map.put(base, "event", "anomaly.duplicate_refinement"))
        else
          state =
            anomaly(
              state,
              Map.merge(base, %{
                "event" => "anomaly.conflicting_refinement",
                "first" => known.refinement.native_terminal
              })
            )

          remember(state, %{
            known
            | refinement: Map.put(known.refinement, :conflict, result.status)
          })
        end

      known.status == :unknown and result.status == "applied" ->
        state =
          anomaly(
            state,
            Map.merge(base, %{"event" => "anomaly.late_result", "late_applied_claim" => true})
          )

        remember(state, %{known | late_applied_claim: true})

      true ->
        anomaly(state, Map.put(base, "event", "anomaly.late_result"))
    end
  end

  # The peer's own classification of its effect, read strictly from the read-back field objects.
  # Every value here is fake-native or native evidence, never an independent observation.
  defp classify_effect(result) do
    observed = result.observed || %{}

    invocation =
      case Schema.observed_value(observed["setter_called"]) do
        {:ok, true} -> :reported
        {:ok, false} -> :not_called
        _ -> :not_reported
      end

    effect =
      case Schema.observed_value(observed["effect"]) do
        {:ok, "changed"} -> :changed
        {:ok, "unchanged"} -> :unchanged
        {:ok, "uncertain"} -> :uncertain
        {:ok, "none"} -> :none
        _ -> :unreported
      end

    read_back =
      case Schema.observed_tuple(observed, "current") do
        {:ok, _} -> :native_same_frame
        :unobserved -> :none
      end

    Map.merge(empty_effect(), %{invocation: invocation, effect: effect, read_back: read_back})
  end

  # A reversal's terminal: the reported current tuple against the original command's reported
  # previous tuple (native_same_frame), or not restored, or unreported.
  defp classify_restoration(state, cmd, result) do
    original = state.commands[cmd.reversal_of]

    with %{result: %{observed: observed}} when is_map(observed) <- original,
         {:ok, previous} <- Schema.observed_tuple(observed, "previous"),
         {:ok, current} <- Schema.observed_tuple(result.observed || %{}, "current") do
      if current == previous, do: :native_same_frame, else: :not_restored
    else
      _ -> :unreported
    end
  end

  defp unknown(%{in_flight: cmd} = state, why) do
    cancel(cmd.ack_timer)
    cancel(cmd.terminal_timer)

    cmd =
      cmd
      |> stage(:unknown)
      |> Map.merge(%{unknown_reason: why, ack_timer: nil, terminal_timer: nil})

    {state, cmd} =
      audit_stage(
        state,
        cmd,
        entry(cmd, "command.unknown", %{
          "reason" => to_string(why),
          "last_stage" => cmd.stages |> Enum.at(-2) |> elem(0) |> to_string(),
          "effectful" => cmd.effectful,
          "possible_effect" => cmd.effectful
        })
      )

    %{state | in_flight: nil, counters: bump(state.counters, :unknown)} |> remember(cmd)
  end

  defp lose_link(state, reason) do
    link = state.link
    Process.demonitor(link.ref, [:flush])
    state = if state.in_flight, do: unknown(state, :link_lost), else: state

    {state, _} =
      audit(state, %{
        "event" => "link.closed",
        "link_generation" => link.generation,
        "reason" => inspect(reason),
        "armed_before" => state.armed,
        "effectful_armed_before" => state.effectful != nil,
        "token_verified_before" => link.token_verified
      })

    {state, _} =
      if state.armed or state.effectful != nil,
        do:
          audit(state, %{
            "event" => "authority.disarmed",
            "by" => "link_loss",
            "link_generation" => link.generation,
            "effectful_was_armed" => state.effectful != nil
          }),
        else: {state, :ok}

    %{clear_effectful(state) | link: nil, armed: false, corroboration: nil}
  end

  # -- audit ---------------------------------------------------------------------------------------

  # Appends an entry. On failure the authority's audit state degrades once (with the event that
  # failed), it disarms (both modes), and it stays degraded for the rest of its life; the caller
  # decides what the failure means for the transition it was recording.
  defp audit(state, entry) do
    case append(state.journal, entry) do
      :ok ->
        {state, :ok}

      {:error, reason} = error ->
        Logger.error(
          "command authority: journal entry #{entry["event"]} not persisted (#{inspect(reason)}); audit degraded, disarmed"
        )

        state =
          case state.audit do
            :intact ->
              %{state | audit: {:degraded, entry["event"], reason, mono()}}

            degraded ->
              %{state | audit: degraded}
          end

        {%{
           clear_effectful(state)
           | armed: false,
             counters: bump(state.counters, :audit_failures)
         }, error}
    end
  end

  # A transition of an in-flight or ending command: applied in memory as the evidence says, and
  # marked on the command's record when its entry could not be persisted.
  defp audit_stage(state, cmd, entry) do
    case audit(state, entry) do
      {state, :ok} ->
        {state, cmd}

      {state, {:error, _}} ->
        gap =
          case cmd.audit do
            :intact -> {:gap, [cmd.status]}
            {:gap, stages} -> {:gap, stages ++ [cmd.status]}
          end

        {state, %{cmd | audit: gap}}
    end
  end

  # A journal process that is down (or a call that fails) is a failed append, never a crash of
  # the authority and never a silent success.
  defp append(journal, entry) do
    Journal.append(journal, entry)
  catch
    :exit, reason -> {:error, {:journal_unavailable, reason}}
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
    {state, _} = audit(state, fields)
    %{state | counters: bump(state.counters, :anomalies)}
  end

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)

  defp bump(counters, key), do: Map.update!(counters, key, &(&1 + 1))
  defp mono, do: System.monotonic_time(:millisecond)

  defp status_map(state) do
    link = state.link
    journal_status = safe_journal_status(state.journal)
    identified = link != nil and link.identity == :identified

    audit =
      case state.audit do
        :intact -> :intact
        {:degraded, event, reason, _} -> %{degraded: true, failed_event: event, reason: reason}
      end

    %{
      enabled: true,
      trust: %{
        transport: if(link, do: :connected, else: :none),
        protocol: if(link, do: link.protocol, else: :none),
        protocol_version: link && link.protocol_version,
        peer: if(link, do: link.identity, else: :none),
        token_verified: link != nil and link.token_verified,
        authenticated: false,
        armed: state.armed,
        effectful_armed: state.effectful != nil,
        ready:
          identified and state.armed and state.in_flight == nil and journal_status == :open and
            state.audit == :intact
      },
      effectful: %{
        enabled: state.config[:effectful] == true,
        token_configured: state.config[:token] != nil,
        token_source: state.token_source,
        armed:
          state.effectful &&
            %{
              link_generation: state.effectful.link_generation,
              ttl_ms: state.effectful.ttl_ms,
              remaining_ms: max(state.effectful.ttl_ms - (mono() - state.effectful.armed_mono), 0)
            },
        corroboration:
          state.corroboration &&
            %{
              adapter_instance_id: state.corroboration.attestation.adapter_instance_id,
              observed_at: state.corroboration.attestation.observed_at,
              evidence_ref: state.corroboration.attestation.evidence_ref,
              age_ms: mono() - state.corroboration.received_mono,
              link_generation: state.corroboration.link_generation,
              label: "operator-provided corroboration"
            }
      },
      audit: audit,
      link:
        link &&
          Map.take(link, [
            :generation,
            :peer,
            :protocol_version,
            :token_verified,
            :adapter_instance_id,
            :mission_generation,
            :native_at,
            :capabilities,
            :advertised
          ]),
      next_generation: state.next_generation,
      in_flight:
        state.in_flight &&
          Map.take(state.in_flight, [
            :id,
            :name,
            :version,
            :status,
            :link_generation,
            :audit,
            :effectful
          ]),
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
            :effectful,
            :effect,
            :restored,
            :reversal_of,
            :refinement,
            :late_applied_claim,
            :unknown_reason,
            :audit
          ])
        ),
      counters: state.counters,
      journal: journal_status,
      allowlist:
        Enum.map(Schema.allowlist(), fn {{n, v}, e} ->
          %{name: n, version: v, issuable: e.issuable, trust: e.trust, effect: e.effect}
        end)
        |> Enum.sort_by(&{&1.name, &1.version})
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
