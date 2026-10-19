defmodule GlacierRelay.Command.EffectfulTest do
  @moduledoc """
  M5 C-2A: the effectful authority against the fake native peer — the version-2 handshake and
  attestation (fresh nonce, HMAC, constant-time compare, binding to generation and identity, one
  attest per link, every failure closing the link with no fallback), version pinning and explicit
  version-1 inert-only compatibility, the effectful configuration default, operator-supplied
  telemetry corroboration and socket-ownership evidence, one-shot effectful arming with its TTL
  and revocations, the complete-tuple schema and the same-kit refusal, the effectful ladder with
  the peer-reported effect classification, the late non-application refinement, operator
  observations, the reversal through the facade, and the observer's indifference. Every
  assertion the fake peer makes is fake-native evidence; nothing here touches Glacier.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.Command
  alias GlacierRelay.Command.{Journal, Listener, Schema}
  alias GlacierRelay.MissionSession
  alias GlacierRelay.Test.{FakeNative, FixturePlayer, StubWriter}

  # An ephemeral test credential: never a real run token, never written outside the test VM.
  @token "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  @other_token "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
  @suit "874c4c48-0a8b-49e9-883e-49fc5f1fb051"
  @target "4fc9396e-2619-4e66-a51e-2bd366230da7"
  @gen "2516103519921974492-5fd4f3e1-0fa5-408f-bce8-b58923581360"
  @previous %{"disguise_repository_id" => @suit, "charset" => 0, "variation" => 0}
  @current %{"disguise_repository_id" => @target, "charset" => 0, "variation" => 0}
  @ack 300
  @grace 200
  @ttl 500

  setup context do
    dir =
      Path.join(
        System.tmp_dir!(),
        "glacier-relay-effectful-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)

    writer =
      if context[:stub_writer], do: [writer: {StubWriter, elem(StubWriter.start(), 1)}], else: []

    opts =
      [
        port: 0,
        journal_dir: dir,
        ack_timeout_ms: @ack,
        grace_ms: @grace,
        default_ttl_ms: @ttl,
        min_ttl_ms: 50,
        hello_timeout_ms: 400,
        effectful: Map.get(context, :effectful, true),
        token: Map.get(context, :token, @token),
        effectful_ttl_max_ms: 120_000,
        evidence_max_age_ms: 120_000
      ] ++ writer

    start_supervised!({Command.Supervisor, opts})
    %{port: Listener.port(), dir: dir, agent: writer[:writer] && elem(writer[:writer], 1)}
  end

  defp wait(fun), do: FixturePlayer.wait_until(fun, 100, 10)

  defp journal_entries do
    %{path: path} = Journal.status()
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  defp journal_events, do: Enum.map(journal_entries(), & &1["event"])
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp ownership(overrides \\ %{}) do
    Map.merge(
      %{
        "collected_at" => now(),
        "owner_pid" => 46604,
        "executable" => "HITMAN3.exe",
        "local_port" => 51234,
        "remote_port" => 4749,
        "connections" => 1,
        "validation" => "exactly_one_hitman",
        "source" => "Get-NetTCPConnection -RemotePort 4749 -State Established",
        "max_age_ms" => 60_000
      },
      overrides
    )
  end

  defp attestation(adapter, overrides \\ %{}) do
    Map.merge(
      %{
        "adapter_instance_id" => adapter,
        "observed_at" => now(),
        "basis" => "MissionSession.state/0 over RPC (operator tooling)",
        "evidence_ref" => "r2-check.txt",
        "max_age_ms" => 60_000
      },
      overrides
    )
  end

  # A token-verified version-2 peer.
  defp v2_peer(port, opts \\ []) do
    {socket, adapter, welcome} = FakeNative.handshake_v2(port, @token, opts)
    assert wait(fn -> Command.status().trust.token_verified end)
    {socket, adapter, welcome}
  end

  defp arm_eff(adapter, opts \\ []) do
    assert :ok = Command.attest_telemetry(attestation(adapter))
    assert :ok = Command.arm_effectful(Keyword.merge([ownership: ownership()], opts))
  end

  defp set_outfit(target \\ @current, current \\ @previous, opts \\ []) do
    Command.set_outfit(
      Map.put(target, "expect_current", current),
      Keyword.merge([expected_generation: @gen], opts)
    )
  end

  # A fake inspection reporting `hero` at `frame` in the test generation; returns its id.
  defp inspect_hero(socket, adapter, hero, frame) do
    {:ok, insp} =
      Command.inspect_outfit(%{"disguise_repository_id" => @target}, expected_generation: @gen)

    {:ok, icmd} = FakeNative.recv(socket)

    FakeNative.respond(socket, icmd, adapter, "applied", %{
      "observed" => %{
        "hero_outfit_id" => FakeNative.field("observed", hero["disguise_repository_id"]),
        "hero_charset" => FakeNative.field("observed", hero["charset"]),
        "hero_variation" => FakeNative.field("observed", hero["variation"])
      },
      "frame" => frame,
      "mission_generation" => @gen
    })

    assert wait(fn -> Command.command(insp).status == :applied end)
    insp
  end

  defp applied(socket, cmd, adapter, previous, current, effect, opts \\ []) do
    FakeNative.respond(socket, cmd, adapter, "applied", %{
      "observed" =>
        FakeNative.apply_observed(
          previous,
          current,
          effect,
          Keyword.merge([generation: @gen], opts)
        ),
      "frame" => Keyword.get(opts, :frame, 20_000),
      "mission_generation" => @gen
    })
  end

  # -- version 2 handshake and attestation --------------------------------------------------------

  test "a version-2 hello gets a welcome with a fresh bounded nonce; the effectful entry is listed only when advertised; a valid attest makes the link token_verified; the token never reaches the journal",
       %{port: port, dir: dir} do
    {socket, adapter, welcome} =
      FakeNative.handshake(port, Schema.uuid4(), version: 2, capabilities: ["relay.probe/1"])

    assert welcome["command_protocol_version"] == 2 and welcome["attest_required"] == true and
             Schema.nonce?(welcome["nonce"])

    assert welcome["allowlist"] == Schema.issuable()

    assert Map.keys(welcome) |> Enum.sort() ==
             ~w(allowlist attest_required command_protocol_version kind link_generation node nonce)

    assert wait(fn -> Command.status().trust.peer == :identified end)
    s = Command.status()

    assert s.trust.protocol_version == 2 and s.trust.token_verified == false and
             s.link.advertised == Schema.issuable()

    assert {:error, :peer_not_token_verified} = Command.arm_effectful(ownership: ownership())

    FakeNative.send_json(socket, FakeNative.attest(welcome, adapter, @token))
    assert wait(fn -> Command.status().trust.token_verified end)

    assert %{trust: %{authenticated: false, token_verified: true, protocol_version: 2}} =
             Command.status()

    verified = Enum.find(journal_entries(), &(&1["event"] == "peer.token_verified"))
    assert verified["nonce"] == welcome["nonce"] and verified["link_generation"] == 1
    assert verified["trust"] =~ "not process identity"
    refute Map.has_key?(verified, "mac")
    FakeNative.close(socket)

    # a second peer advertising the capability sees the entry; nonces are fresh per link
    {socket2, _adapter2, welcome2} = v2_peer(port)
    assert %{"name" => "player.outfit.set", "version" => 2} in welcome2["allowlist"]
    assert welcome2["nonce"] != welcome["nonce"]

    refute Enum.any?(
             welcome2["allowlist"],
             &(&1 == %{"name" => "player.outfit.set", "version" => 1})
           )

    [path] = Path.wildcard(Path.join(dir, "commands-*.ndjson"))
    refute File.read!(path) =~ @token
    FakeNative.close(socket2)
  end

  test "every attestation failure closes the link with a journaled reason and no fallback: wrong token, reused nonce, wrong generation, wrong identity, second attest, replay, attest on a version-1 link, attest before hello",
       %{port: port} do
    failures = [
      {"wrong token", fn w, a -> FakeNative.attest(w, a, @other_token) end, "mac_mismatch"},
      {"wrong generation",
       fn w, a ->
         FakeNative.attest(w, a, @token, %{"link_generation" => w["link_generation"] + 1})
       end, "generation_mismatch"},
      {"wrong identity",
       fn w, _a ->
         FakeNative.attest(
           Map.put(w, "link_generation", w["link_generation"]),
           Schema.uuid4(),
           @token
         )
         |> Map.put("adapter_instance_id", Schema.uuid4())
       end, "adapter_mismatch"},
      {"reused nonce",
       fn w, a ->
         FakeNative.attest(Map.put(w, "nonce", String.duplicate("0", 32)), a, @token)
       end, "mac_mismatch"}
    ]

    for {label, make, reason} <- failures do
      before = Command.status().counters.attest_failures
      {socket, adapter, welcome} = FakeNative.handshake_v2(port, nil)
      assert wait(fn -> Command.status().trust.peer == :identified end), label
      FakeNative.send_json(socket, make.(welcome, adapter))
      assert {:error, :closed} = FakeNative.recv(socket, 1_000), label
      assert wait(fn -> Command.status().link == nil end), label
      assert Command.status().counters.attest_failures == before + 1, label

      failed =
        journal_entries() |> Enum.filter(&(&1["event"] == "peer.attest_failed")) |> List.last()

      assert failed["reason"] == reason, label
      refute Map.has_key?(failed, "mac"), label
      closed = journal_entries() |> Enum.filter(&(&1["event"] == "link.closed")) |> List.last()
      assert closed["reason"] =~ "attest_failed", label
      refute Command.status().trust.token_verified, label
    end

    # a second attest on one link (a replay of the valid one) closes it
    {socket, adapter, welcome} = v2_peer(port)
    FakeNative.send_json(socket, FakeNative.attest(welcome, adapter, @token))
    assert {:error, :closed} = FakeNative.recv(socket, 1_000)
    assert wait(fn -> Command.status().link == nil end)

    assert List.last(Enum.filter(journal_entries(), &(&1["event"] == "peer.attest_failed")))[
             "reason"
           ] == "second_attest"

    # a replay of that attest on a new link: new generation and nonce, so the MAC is stale
    {socket2, _adapter2, _welcome2} = FakeNative.handshake_v2(port, nil, adapter_id: adapter)
    assert wait(fn -> Command.status().trust.peer == :identified end)
    FakeNative.send_json(socket2, FakeNative.attest(welcome, adapter, @token))
    assert {:error, :closed} = FakeNative.recv(socket2, 1_000)
    assert wait(fn -> Command.status().link == nil end)

    # an attest on a version-1 link, and one before any hello
    {socket3, adapter3, _} = FakeNative.handshake(port)
    assert wait(fn -> Command.status().trust.peer == :identified end)

    FakeNative.send_json(
      socket3,
      FakeNative.attest(
        %{"link_generation" => 1, "nonce" => String.duplicate("0", 32)},
        adapter3,
        @token
      )
    )

    assert {:error, :closed} = FakeNative.recv(socket3, 1_000)
    assert wait(fn -> Command.status().link == nil end)
    socket4 = FakeNative.connect(port)
    assert wait(fn -> Command.status().trust.transport == :connected end)

    FakeNative.send_json(
      socket4,
      FakeNative.attest(
        %{"link_generation" => 1, "nonce" => String.duplicate("0", 32)},
        Schema.uuid4(),
        @token
      )
    )

    assert {:error, :closed} = FakeNative.recv(socket4, 1_000)
    assert wait(fn -> Command.status().link == nil end)

    closes =
      journal_entries()
      |> Enum.filter(&(&1["event"] == "link.closed"))
      |> Enum.map(& &1["reason"])

    assert Enum.any?(closes, &(&1 =~ "attest_on_version_1_link"))
    assert Enum.any?(closes, &(&1 =~ "attest_before_handshake"))

    # after every failure a proper version-2 attest still works (a new nonce), and a version-1
    # reconnect is explicitly inert-only, never a fallback that carries any trust
    {socket5, _adapter5, _} = v2_peer(port)
    FakeNative.close(socket5)
    assert wait(fn -> Command.status().link == nil end)
    {socket6, _adapter6, welcome6} = FakeNative.handshake(port)
    assert welcome6["command_protocol_version"] == 1 and not Map.has_key?(welcome6, "nonce")
    assert wait(fn -> Command.status().trust.peer == :identified end)
    refute Command.status().trust.token_verified
    assert {:error, :peer_protocol_version_1} = Command.arm_effectful(ownership: ownership())
    FakeNative.close(socket6)
  end

  test "the negotiated version is pinned: a line of the other version is a violation", %{
    port: port
  } do
    {socket, adapter, welcome} = v2_peer(port)
    assert :ok = Command.arm()
    assert {:ok, id} = Command.probe()
    assert {:ok, cmd} = FakeNative.recv(socket)

    assert cmd["command_protocol_version"] == 2 and
             cmd["link_generation"] == welcome["link_generation"]

    FakeNative.send_json(
      socket,
      FakeNative.result(cmd, adapter, "received", %{"command_protocol_version" => 1})
    )

    assert {:error, :closed} = FakeNative.recv(socket, 1_000)
    assert wait(fn -> Command.status().link == nil end)
    assert Command.command(id).status == :unknown

    assert List.last(Enum.filter(journal_entries(), &(&1["event"] == "link.closed")))["reason"] =~
             "version_mismatch"

    {socket2, adapter2, _} = FakeNative.handshake(port)
    assert wait(fn -> Command.status().trust.peer == :identified end)
    assert :ok = Command.arm()
    assert {:ok, _} = Command.probe()
    assert {:ok, cmd2} = FakeNative.recv(socket2)
    assert cmd2["command_protocol_version"] == 1

    FakeNative.send_json(
      socket2,
      FakeNative.result(cmd2, adapter2, "received", %{"command_protocol_version" => 2})
    )

    assert {:error, :closed} = FakeNative.recv(socket2, 1_000)
    assert wait(fn -> Command.status().link == nil end)
  end

  @tag effectful: false
  test "with the effectful configuration off nothing effectful is advertised, armable or issuable, whatever the peer attests",
       %{port: port} do
    {socket, adapter, welcome} = v2_peer(port)
    refute Enum.any?(welcome["allowlist"], &(&1["name"] == "player.outfit.set"))
    assert :ok = Command.attest_telemetry(attestation(adapter))
    assert {:error, :effectful_disabled} = Command.arm_effectful(ownership: ownership())
    assert {:error, :effectful_disabled} = set_outfit()
    assert Command.status().effectful.enabled == false
    assert {:error, :timeout} = FakeNative.recv(socket, 200)
    FakeNative.close(socket)
  end

  @tag token: nil
  test "without a configured token no peer can become token_verified and an attest closes the link",
       %{port: port} do
    {socket, _adapter, _welcome} = FakeNative.handshake_v2(port, @token)
    assert {:error, :closed} = FakeNative.recv(socket, 1_000)
    assert wait(fn -> Command.status().link == nil end)

    assert List.last(Enum.filter(journal_entries(), &(&1["event"] == "peer.attest_failed")))[
             "reason"
           ] == "no_token_configured"

    assert Command.status().effectful.token_configured == false
    {socket2, _, _} = FakeNative.handshake_v2(port, nil)
    assert wait(fn -> Command.status().trust.peer == :identified end)
    assert {:error, :no_token_configured} = Command.arm_effectful(ownership: ownership())
    FakeNative.close(socket2)
  end

  # -- effectful arming ---------------------------------------------------------------------------

  test "effectful arming needs fresh operator corroboration and ownership evidence, is distinct from inert arming, is one-shot and bounded",
       %{port: port} do
    {socket, adapter, _} = v2_peer(port)

    # inert arming never implies effectful arming
    assert :ok = Command.arm()
    assert %{trust: %{armed: true, effectful_armed: false}} = Command.status()
    assert {:error, :not_armed_effectful} = set_outfit()

    # corroboration: missing, invalid, mismatched, stale
    assert {:error, :telemetry_corroboration_missing} =
             Command.arm_effectful(ownership: ownership())

    assert {:error, {:invalid_attestation, {:unknown_keys, ["hello"]}}} =
             Command.attest_telemetry(attestation(adapter, %{"hello" => 1}))

    assert {:error, {:invalid_attestation, :observed_at_invalid}} =
             Command.attest_telemetry(attestation(adapter, %{"observed_at" => "now"}))

    assert {:error, :adapter_identity_mismatch} =
             Command.attest_telemetry(attestation(Schema.uuid4()))

    assert Command.status().effectful.corroboration == nil
    # M5 C-2C N1: the attestation's own allowance also bounds observed_at against the wall clock
    # at submission, so a 1 ms allowance could refuse the submission itself; 50 ms keeps the
    # submission fresh and lets the monotonic receipt window expire before arming
    assert :ok = Command.attest_telemetry(attestation(adapter, %{"max_age_ms" => 50}))
    Process.sleep(60)

    assert {:error, :telemetry_corroboration_stale} =
             Command.arm_effectful(ownership: ownership())

    assert :ok = Command.attest_telemetry(attestation(adapter))
    attested = Enum.filter(journal_entries(), &(&1["event"] == "operator.telemetry_attested"))
    assert Enum.map(attested, & &1["matches_link_identity"]) == [false, true, true]
    assert hd(attested)["label"] =~ "operator-provided"

    # ownership: missing, invalid, stale, rejected
    assert {:error, :ownership_evidence_missing} = Command.arm_effectful()

    assert {:error, {:ownership_evidence_invalid, {:unknown_keys, ["signature"]}}} =
             Command.arm_effectful(ownership: ownership(%{"signature" => "x"}))

    assert {:error, {:ownership_evidence_invalid, :collected_at_invalid}} =
             Command.arm_effectful(ownership: ownership(%{"collected_at" => "earlier"}))

    assert {:error, :ownership_evidence_stale} =
             Command.arm_effectful(
               ownership: ownership(%{"collected_at" => "2026-10-14T03:00:00Z"})
             )

    assert {:error, {:ownership_evidence_rejected, "two_clients"}} =
             Command.arm_effectful(ownership: ownership(%{"validation" => "two_clients"}))

    assert {:error, {:ownership_evidence_rejected, "connections 2"}} =
             Command.arm_effectful(ownership: ownership(%{"connections" => 2}))

    assert {:error, {:ttl_out_of_range, 500}} =
             Command.arm_effectful(ownership: ownership(), ttl_ms: 500)

    assert {:error, {:ttl_out_of_range, 500_000}} =
             Command.arm_effectful(ownership: ownership(), ttl_ms: 500_000)

    # nothing in flight
    assert {:ok, id} = Command.probe()
    assert {:error, {:in_flight, ^id}} = Command.arm_effectful(ownership: ownership())
    assert {:ok, cmd} = FakeNative.recv(socket)
    FakeNative.respond(socket, cmd, adapter, "applied")
    assert wait(fn -> Command.command(id).status == :applied end)

    assert :ok = Command.arm_effectful(ownership: ownership(), ttl_ms: 5_000)
    assert {:error, :already_armed_effectful} = Command.arm_effectful(ownership: ownership())
    s = Command.status()

    assert s.trust.effectful_armed and s.effectful.armed.ttl_ms == 5_000 and
             s.effectful.armed.remaining_ms <= 5_000

    armed = Enum.find(journal_entries(), &(&1["event"] == "authority.armed_effectful"))
    assert armed["one_shot"] == true and armed["ownership"]["executable"] == "HITMAN3.exe"
    assert armed["ownership"]["label"] =~ "operator-provided evidence"

    assert is_integer(armed["ownership"]["age_ms_at_arming"]) and
             armed["corroboration"]["evidence_ref"] == "r2-check.txt"

    # disarm clears both modes
    assert :ok = Command.disarm()
    assert %{trust: %{armed: false, effectful_armed: false}} = Command.status()

    assert Enum.find(journal_entries(), &(&1["event"] == "authority.disarmed"))[
             "effectful_was_armed"
           ] == true

    FakeNative.close(socket)
  end

  test "effectful arming expires after its TTL, is revoked by link loss (with the corroboration), and is never persisted across a restart",
       %{port: port, dir: dir} do
    {socket, adapter, _} = v2_peer(port)
    arm_eff(adapter, ttl_ms: 1_000)
    assert wait(fn -> not Command.status().trust.effectful_armed end)
    assert "authority.effectful_expired" in journal_events()
    assert {:error, :not_armed_effectful} = set_outfit()

    arm_eff(adapter)
    FakeNative.close(socket)
    assert wait(fn -> Command.status().link == nil end)
    refute Command.status().trust.effectful_armed
    assert Command.status().effectful.corroboration == nil

    disarmed =
      journal_entries() |> Enum.filter(&(&1["event"] == "authority.disarmed")) |> List.last()

    assert disarmed["by"] == "link_loss" and disarmed["effectful_was_armed"] == true

    {socket2, _adapter2, _} = v2_peer(port)

    assert {:error, :telemetry_corroboration_missing} =
             Command.arm_effectful(ownership: ownership())

    FakeNative.close(socket2)

    stop_supervised!(Command.Supervisor)

    start_supervised!(
      {Command.Supervisor, port: 0, journal_dir: dir, effectful: true, token: @token}
    )

    assert %{trust: %{effectful_armed: false, armed: false}} = Command.status()
  end

  # -- the effectful command ---------------------------------------------------------------------

  test "the effectful ladder: the complete tuple on the wire, the one-shot arming consumed before acceptance, the peer's effect classification recorded as fake-native evidence, consequences unknown, the observer untouched",
       %{port: port} do
    :ok = MissionSession.subscribe()
    before_session = MissionSession.state()
    {socket, adapter, welcome} = v2_peer(port)
    arm_eff(adapter)

    # refusals that do not consume the arming
    assert {:error, :same_as_current} = set_outfit(@previous, @previous)

    assert {:error, :mission_generation_required} =
             Command.set_outfit(Map.put(@current, "expect_current", @previous))

    assert {:error, {:invalid_param, "charset", {:not_an_integer_within, 0, 15}}} =
             set_outfit(Map.put(@current, "charset", 16))

    assert {:error, {:invalid_param, "expect_current", :missing}} =
             Command.set_outfit(@current, expected_generation: @gen)

    assert {:error,
            {:invalid_param, "expect_current",
             {:invalid_object, {:unknown_params, ["kit_pointer"]}}}} =
             set_outfit(@current, Map.put(@previous, "kit_pointer", "0x1"))

    assert {:error, {:not_issuable, "player.outfit.set", 1}} =
             Command.Authority.issue("player.outfit.set", 1, %{
               "disguise_repository_id" => @target
             })

    assert Command.status().trust.effectful_armed
    assert {:error, :timeout} = FakeNative.recv(socket, 100)

    assert {:ok, id} = set_outfit()
    refute Command.status().trust.effectful_armed
    assert {:ok, cmd} = FakeNative.recv(socket)

    assert cmd["name"] == "player.outfit.set" and cmd["version"] == 2 and
             cmd["command_protocol_version"] == 2 and
             cmd["link_generation"] == welcome["link_generation"]

    assert cmd["params"] == Map.put(@current, "expect_current", @previous)
    assert cmd["preconditions"] == %{"mission_generation" => @gen}
    assert {:error, :not_armed_effectful} = set_outfit()

    events =
      journal_events()
      |> Enum.filter(
        &(&1 in ~w(authority.effectful_consumed command.accepted command.transmitted))
      )

    assert events == ~w(authority.effectful_consumed command.accepted command.transmitted)

    accepted =
      Enum.find(
        journal_entries(),
        &(&1["event"] == "command.accepted" and &1["command_id"] == id)
      )

    assert accepted["effectful"] == true and accepted["params"]["expect_current"] == @previous

    applied(socket, cmd, adapter, @previous, @current, "changed")
    assert wait(fn -> Command.command(id).status == :applied end)
    c = Command.command(id)

    assert c.effect == %{
             invocation: :reported,
             effect: :changed,
             read_back: :native_same_frame,
             read_back_later: nil,
             engine_consistent: false,
             operator: nil
           }

    assert c.consequences == :unknown and c.observed == :native and
             c.independent_observation == :not_available

    assert c.effectful and c.restored == nil and c.reversal_of == nil

    terminal =
      Enum.find(
        journal_entries(),
        &(&1["event"] == "command.terminal" and &1["command_id"] == id)
      )

    assert terminal["effect"] == "changed" and terminal["invocation"] == "reported" and
             terminal["read_back"] == "native_same_frame" and
             terminal["consequences"] == "unknown" and
             terminal["observed_label"] == "native" and
             terminal["independent_observation"] == "not_available"

    assert Map.delete(MissionSession.state(), :never) == before_session
    FakeNative.close(socket)
  end

  test "the peer's other outcomes are recorded as said: unchanged, uncertain without a read-back, failed with a possible effect, none",
       %{port: port} do
    {socket, adapter, _} = v2_peer(port)

    outcomes = [
      {"applied", @previous, @previous, "unchanged",
       %{effect: :unchanged, read_back: :native_same_frame, invocation: :reported}},
      {"applied", @previous, nil, "uncertain",
       %{effect: :uncertain, read_back: :none, invocation: :reported}},
      {"failed", @previous, nil, "uncertain",
       %{effect: :uncertain, read_back: :none, invocation: :reported}},
      {"precondition_failed", @previous, @previous, "none",
       %{effect: :none, read_back: :native_same_frame, invocation: :not_called}}
    ]

    for {status, previous, current, effect, expected} <- outcomes do
      arm_eff(adapter)
      assert {:ok, id} = set_outfit()
      assert {:ok, cmd} = FakeNative.recv(socket)
      setter = if status == "precondition_failed", do: false, else: true

      FakeNative.respond(socket, cmd, adapter, status, %{
        "observed" =>
          FakeNative.apply_observed(previous, current, effect,
            generation: @gen,
            setter_called: setter
          ),
        "mission_generation" => @gen
      })

      assert wait(fn -> Command.command(id).status == String.to_atom(status) end)
      c = Command.command(id)

      assert Map.take(c.effect, [:effect, :read_back, :invocation]) == expected,
             "#{status}/#{effect}"

      assert c.consequences == :unknown
    end

    FakeNative.close(socket)
  end

  @tag :stub_writer
  test "a journal failure while consuming the arming refuses the command, consumes the arming anyway and degrades; nothing is transmitted",
       %{port: port, agent: agent} do
    {socket, adapter, _} = v2_peer(port)
    arm_eff(adapter)
    StubWriter.mode(agent, {:fail_sync, :eio})
    assert {:error, {:journal_unavailable, :eio}} = set_outfit()
    assert {:error, :timeout} = FakeNative.recv(socket, 200)
    s = Command.status()
    refute s.trust.effectful_armed
    assert %{degraded: true, failed_event: "authority.effectful_consumed"} = s.audit

    assert {:error, {:audit_degraded, "authority.effectful_consumed"}} =
             Command.arm_effectful(ownership: ownership())

    FakeNative.close(socket)
  end

  # -- late results ---------------------------------------------------------------------------------

  test "a late non-application terminal refines an unknown additively; a contradiction and a duplicate are anomalies; a late applied only marks a claim",
       %{port: port} do
    {socket, adapter, _} = v2_peer(port)
    arm_eff(adapter)
    assert {:ok, id} = set_outfit()
    assert {:ok, cmd} = FakeNative.recv(socket)
    assert wait(fn -> Command.command(id).status == :unknown end)
    assert Command.command(id).unknown_reason == :ack_timeout

    unknown =
      Enum.find(journal_entries(), &(&1["event"] == "command.unknown" and &1["command_id"] == id))

    assert unknown["possible_effect"] == true

    # a late expired from another adapter identity is foreign, not a refinement
    FakeNative.send_json(socket, FakeNative.result(cmd, Schema.uuid4(), "expired"))
    assert wait(fn -> Command.status().counters.anomalies == 1 end)
    assert Command.command(id).refinement == nil

    FakeNative.send_json(
      socket,
      FakeNative.result(cmd, adapter, "expired", %{"reason" => "ttl elapsed", "frame" => 77})
    )

    assert wait(fn -> Command.command(id).refinement != nil end)
    c = Command.command(id)

    assert c.status == :unknown and c.refinement.native_terminal == "expired" and
             c.refinement.reason == "ttl elapsed"

    refined = Enum.find(journal_entries(), &(&1["event"] == "command.unknown_refined"))

    assert refined["status_after"] == "unknown" and refined["text"] =~ "not applied" and
             refined["frame"] == 77

    assert Command.status().counters.anomalies == 1

    FakeNative.send_json(socket, FakeNative.result(cmd, adapter, "rejected"))
    assert wait(fn -> Command.status().counters.anomalies == 2 end)

    assert Command.command(id).refinement.conflict == "rejected" and
             Command.command(id).status == :unknown

    assert "anomaly.conflicting_refinement" in journal_events()

    FakeNative.send_json(socket, FakeNative.result(cmd, adapter, "expired"))
    assert wait(fn -> Command.status().counters.anomalies == 3 end)
    assert "anomaly.duplicate_refinement" in journal_events()

    FakeNative.send_json(socket, FakeNative.result(cmd, adapter, "applied"))
    assert wait(fn -> Command.status().counters.anomalies == 4 end)
    c = Command.command(id)
    assert c.status == :unknown and c.late_applied_claim == true

    late =
      journal_entries() |> Enum.filter(&(&1["event"] == "anomaly.late_result")) |> List.last()

    assert late["late_applied_claim"] == true
    assert Command.status().counters.issued == 1
    FakeNative.close(socket)
  end

  # -- operator observations -------------------------------------------------------------------------

  test "operator observations are journaled first and labelled testimony; a later-frame read-back compares two native read-backs; an engine-consistent note needs the pure rule to hold",
       %{port: port} do
    {socket, adapter, _} = v2_peer(port)
    assert :ok = Command.arm()
    arm_eff(adapter)
    assert {:ok, id} = set_outfit()
    assert {:ok, cmd} = FakeNative.recv(socket)
    applied(socket, cmd, adapter, @previous, @current, "changed", frame: 20_000)
    assert wait(fn -> Command.command(id).status == :applied end)

    assert {:error, :unknown_command_id} = Command.observe(Schema.uuid4(), "note", "x")
    assert {:error, {:unknown_observation_type, "feeling"}} = Command.observe(id, "feeling", "x")
    assert {:error, :text_too_long} = Command.observe(id, "note", String.duplicate("x", 501))
    assert {:error, :at_invalid} = Command.observe(id, "note", "x", at: "yesterday")

    assert {:error, :inspection_command_id_required} =
             Command.observe(id, "later_frame_read_back", "x")

    assert {:error, :envelope_required} = Command.observe(id, "engine_consistent", "x")

    assert {:ok, note} =
             Command.observe(id, "visual_confirmation", "the suit changed on screen",
               at: "2026-10-14T03:34:25Z"
             )

    assert note["type"] == "visual_confirmation" and note["at"] == "2026-10-14T03:34:25Z"
    obs = Enum.find(journal_entries(), &(&1["event"] == "operator.observation"))
    assert obs["label"] =~ "operator testimony" and obs["command_id"] == id
    assert Command.command(id).effect.operator == :confirmed

    # a later-frame inspection whose hero tuple equals the reported current tuple
    assert {:ok, insp} =
             Command.inspect_outfit(%{"disguise_repository_id" => @target},
               expected_generation: @gen
             )

    assert {:ok, icmd} = FakeNative.recv(socket)

    hero = %{
      "hero_outfit_id" => FakeNative.field("observed", @target),
      "hero_charset" => FakeNative.field("observed", 0),
      "hero_variation" => FakeNative.field("observed", 0)
    }

    FakeNative.respond(socket, icmd, adapter, "applied", %{
      "observed" => hero,
      "frame" => 20_300,
      "mission_generation" => @gen
    })

    assert wait(fn -> Command.command(insp).status == :applied end)

    assert {:ok, later} =
             Command.observe(id, "later_frame_read_back", "inspected 3 s later",
               inspection_command_id: insp
             )

    assert later["conclusion"] == "consistent" and later["evidence_class"] =~ "not independent"
    assert Command.command(id).effect.read_back_later == "consistent"

    # M5 C-2B correction: a failed command whose setter was invoked (a possible effect) accepts the
    # later-frame observation; without a current tuple the hero is compared with the requested and
    # the prior tuples; a refused command (never invoked) does not.
    arm_eff(adapter)
    assert {:ok, fid} = set_outfit(@current, @previous)
    assert {:ok, fcmd} = FakeNative.recv(socket)

    FakeNative.respond(socket, fcmd, adapter, "failed", %{
      "observed" =>
        FakeNative.apply_observed(@previous, nil, "uncertain",
          generation: @gen,
          frame: 20_400,
          requested: @current
        ),
      "frame" => 20_400,
      "mission_generation" => @gen,
      "reason" => "fault inside the setter"
    })

    assert wait(fn -> Command.command(fid).status == :failed end)

    assert {:ok, insp2} =
             Command.inspect_outfit(%{"disguise_repository_id" => @target},
               expected_generation: @gen
             )

    assert {:ok, icmd2} = FakeNative.recv(socket)

    FakeNative.respond(socket, icmd2, adapter, "applied", %{
      "observed" => hero,
      "frame" => 20_500,
      "mission_generation" => @gen
    })

    assert wait(fn -> Command.command(insp2).status == :applied end)

    assert {:ok, after_fault} =
             Command.observe(fid, "later_frame_read_back", "after the fault",
               inspection_command_id: insp2
             )

    assert after_fault["conclusion"] == "matches_requested"
    assert Command.command(fid).effect.read_back_later == "matches_requested"
    assert {:error, {:not_applied, "failed"}} = Command.plan_reversal(fid)

    arm_eff(adapter)
    assert {:ok, rid} = set_outfit(@current, @previous)
    assert {:ok, rcmd} = FakeNative.recv(socket)

    FakeNative.respond(socket, rcmd, adapter, "precondition_failed", %{
      "observed" =>
        FakeNative.apply_observed(@previous, @previous, "none",
          generation: @gen,
          setter_called: false
        ),
      "frame" => 20_600,
      "mission_generation" => @gen
    })

    assert wait(fn -> Command.command(rid).status == :precondition_failed end)

    assert {:error, :command_not_applied} =
             Command.observe(rid, "later_frame_read_back", "x", inspection_command_id: insp2)

    # the same inspection against a command applied on a later frame is not a later frame
    assert {:error, :inspection_unknown} =
             Command.observe(id, "later_frame_read_back", "x",
               inspection_command_id: Schema.uuid4()
             )

    envelope = %{
      "adapter_instance_id" => adapter,
      "event_type" => "disguise.equipped",
      "native_at" => "2026-10-13T20:00:03.000Z",
      "sequence" => 4,
      "payload" => %{
        "kind" => "change",
        "disguise_repository_id" => @target,
        "contract_session_id" => @gen
      }
    }

    assert {:ok, consistent} =
             Command.observe(id, "engine_consistent", "disguise.equipped #4", envelope: envelope)

    assert consistent["conclusion"] == "engine_consistent" and
             consistent["wording"] =~ "causality not established"

    assert Command.command(id).effect.engine_consistent == true

    assert {:error, {:not_consistent, reasons}} =
             Command.observe(id, "engine_consistent", "x",
               envelope: put_in(envelope, ["payload", "kind"], "initial")
             )

    assert :not_a_change in reasons
    assert length(Command.command(id).operator_observations) == 3
    assert Command.status().counters.observations == 4
    FakeNative.close(socket)
  end

  @tag :stub_writer
  test "an observation that cannot be journaled is not attached", %{port: port, agent: agent} do
    {socket, adapter, _} = v2_peer(port)
    assert :ok = Command.arm()
    assert {:ok, id} = Command.probe()
    assert {:ok, cmd} = FakeNative.recv(socket)
    FakeNative.respond(socket, cmd, adapter, "applied")
    assert wait(fn -> Command.command(id).status == :applied end)
    StubWriter.mode(agent, {:fail_sync, :eio})
    assert {:error, {:journal_unavailable, :eio}} = Command.observe(id, "note", "x")
    assert Command.command(id).operator_observations == []
    FakeNative.close(socket)
  end

  # -- reversal ---------------------------------------------------------------------------------------

  test "the reversal is planned from the journal, needs a fresh confirmation, the live generation and its own arming, and its terminal reports restoration natively",
       %{port: port} do
    {socket, adapter, _} = v2_peer(port)
    arm_eff(adapter)
    assert {:ok, id} = set_outfit()
    assert {:ok, cmd} = FakeNative.recv(socket)
    assert {:error, :command_not_in_journal} = Command.plan_reversal(Schema.uuid4())
    assert {:error, {:received_entries, 0}} = Command.plan_reversal(id)
    applied(socket, cmd, adapter, @previous, @current, "changed")
    assert wait(fn -> Command.command(id).status == :applied end)

    assert {:ok, plan} = Command.plan_reversal(id)

    assert plan.params == Map.put(@previous, "expect_current", @current) and
             plan.mission_generation == @gen

    assert plan.adapter_instance_id == adapter and plan.reversal_of == id and
             plan.frame == 20_000

    # correction C: an operator-supplied map alone never issues a reversal; a qualifying
    # inspection must be named
    assert {:error, :inspection_command_id_required} =
             Command.reverse(id, confirmed_current: @current, expected_generation: @gen)

    assert {:error, :inspection_not_in_journal} =
             Command.reverse(id,
               inspection_command_id: Schema.uuid4(),
               expected_generation: @gen
             )

    # an inspection from BEFORE the apply (an earlier frame, the prior tuple) does not qualify
    assert :ok = Command.arm()
    earlier = inspect_hero(socket, adapter, @previous, 19_500)

    assert {:error, {:inspection_tuple_mismatch, @previous}} =
             Command.reverse(id, inspection_command_id: earlier, expected_generation: @gen)

    # a later inspection showing the right tuple qualifies; the other checks still apply
    insp = inspect_hero(socket, adapter, @current, 20_300)

    assert {:error, {:confirmed_current_mismatch, @current}} =
             Command.reverse(id,
               inspection_command_id: insp,
               confirmed_current: @previous,
               expected_generation: @gen
             )

    assert {:error, :expected_generation_required} =
             Command.reverse(id, inspection_command_id: insp)

    assert {:error, {:generation_mismatch, @gen}} =
             Command.reverse(id, inspection_command_id: insp, expected_generation: "other")

    assert {:error, :not_armed_effectful} =
             Command.reverse(id, inspection_command_id: insp, expected_generation: @gen)

    assert {:error, :timeout} = FakeNative.recv(socket, 100)

    arm_eff(adapter)

    assert {:ok, rid} =
             Command.reverse(id, inspection_command_id: insp, expected_generation: @gen)

    assert {:ok, rcmd} = FakeNative.recv(socket)

    assert rcmd["params"] == plan.params and
             rcmd["preconditions"] == %{"mission_generation" => @gen}

    assert Command.command(rid).reversal_of == id

    accepted_entry =
      Enum.find(
        journal_entries(),
        &(&1["event"] == "command.accepted" and &1["command_id"] == rid)
      )

    assert accepted_entry["reversal_of"] == id and
             accepted_entry["reversal_inspection"]["inspection_command_id"] == insp and
             accepted_entry["reversal_inspection"]["frame"] == 20_300

    applied(socket, rcmd, adapter, @current, @previous, "changed", frame: 21_000)
    assert wait(fn -> Command.command(rid).status == :applied end)
    r = Command.command(rid)

    assert r.restored == :native_same_frame and r.effect.effect == :changed and
             r.consequences == :unknown

    terminal =
      Enum.find(
        journal_entries(),
        &(&1["event"] == "command.terminal" and &1["command_id"] == rid)
      )

    assert terminal["restored"] == "native_same_frame" and terminal["reversal_of"] == id and
             terminal["consequences"] == "unknown"

    # a reversal of the reversal that lands elsewhere is not restored (its own inspection first)
    insp2 = inspect_hero(socket, adapter, @previous, 21_300)
    arm_eff(adapter)

    assert {:ok, r2} =
             Command.reverse(rid, inspection_command_id: insp2, expected_generation: @gen)

    assert {:ok, r2cmd} = FakeNative.recv(socket)

    elsewhere = %{
      "disguise_repository_id" => "2018db77-aa8a-4bf9-9afb-56bdaa161156",
      "charset" => 0,
      "variation" => 0
    }

    applied(socket, r2cmd, adapter, @previous, elsewhere, "changed", frame: 22_000)
    assert wait(fn -> Command.command(r2).status == :applied end)
    assert Command.command(r2).restored == :not_restored

    # an unchanged effect and an unknown outcome are not planable
    assert {:error, :effect_unchanged} =
             (fn ->
                arm_eff(adapter)
                {:ok, u} = set_outfit(@current, elsewhere)
                {:ok, ucmd} = FakeNative.recv(socket)
                applied(socket, ucmd, adapter, elsewhere, elsewhere, "unchanged")
                wait(fn -> Command.command(u).status == :applied end)
                Command.plan_reversal(u)
              end).()

    FakeNative.close(socket)
  end
end
