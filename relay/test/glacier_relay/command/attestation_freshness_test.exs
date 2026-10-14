defmodule GlacierRelay.Command.AttestationFreshnessTest do
  @moduledoc """
  M5 C-2C finding N1: the operator-supplied telemetry attestation's `observed_at` is bounded
  against this node's UTC clock when submitted and again when arming (the smaller of the
  attestation's `max_age_ms` and the configured `evidence_max_age_ms`; a future-dated claim is
  allowed only within the configured skew), and the monotonic time since receipt is bounded as
  before; both must hold to arm. The timestamp stays an operator claim — the rule bounds it, it
  never verifies it. The pure rule is tested exactly at its boundaries; the authority is tested
  against the fake native peer with margins around the boundaries.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.Command
  alias GlacierRelay.Command.{Authority, Journal, Listener}
  alias GlacierRelay.Test.{CountingWriter, FakeNative, FixturePlayer}

  # An ephemeral test credential: never a real run token, never written outside the test VM.
  @token "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

  setup context do
    dir =
      Path.join(
        System.tmp_dir!(),
        "glacier-relay-freshness-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, agent} = CountingWriter.start()

    start_supervised!(
      {Command.Supervisor,
       port: 0,
       journal_dir: dir,
       writer: {CountingWriter, agent},
       hello_timeout_ms: 400,
       effectful: true,
       token: @token,
       effectful_ttl_max_ms: 120_000,
       evidence_max_age_ms: Map.get(context, :evidence_max_age_ms, 120_000),
       evidence_clock_skew_ms: Map.get(context, :skew_ms, 5_000)}
    )

    %{port: Listener.port(), agent: agent}
  end

  defp wait(fun), do: FixturePlayer.wait_until(fun, 100, 10)

  defp journal_entries do
    %{path: path} = Journal.status()
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  defp last_attested,
    do:
      journal_entries()
      |> Enum.filter(&(&1["event"] == "operator.telemetry_attested"))
      |> List.last()

  defp at(offset_ms),
    do: DateTime.utc_now() |> DateTime.add(offset_ms, :millisecond) |> DateTime.to_iso8601()

  defp ownership do
    %{
      "collected_at" => at(0),
      "owner_pid" => 46604,
      "executable" => "HITMAN3.exe",
      "connections" => 1,
      "validation" => "exactly_one_hitman",
      "source" => "Get-NetTCPConnection -RemotePort 4749 -State Established",
      "max_age_ms" => 60_000
    }
  end

  defp attestation(adapter, observed_at, max_age_ms \\ 60_000) do
    %{
      "adapter_instance_id" => adapter,
      "observed_at" => observed_at,
      "basis" => "MissionSession.state/0 over RPC (operator tooling)",
      "evidence_ref" => "freshness-test",
      "max_age_ms" => max_age_ms
    }
  end

  defp v2_peer(port) do
    {socket, adapter, _welcome} = FakeNative.handshake_v2(port, @token, [])
    assert wait(fn -> Command.status().trust.token_verified end)
    {socket, adapter}
  end

  # -- the pure rule, exactly at its boundaries ---------------------------------------------------

  test "the pure freshness rule: equal to the bound is fresh, one past it is stale; equal to the skew is fresh, one past it is future" do
    assert Authority.observation_freshness(0, 60_000, 5_000) == :fresh
    assert Authority.observation_freshness(60_000, 60_000, 5_000) == :fresh
    assert Authority.observation_freshness(60_001, 60_000, 5_000) == :stale
    assert Authority.observation_freshness(600_000, 60_000, 5_000) == :stale
    assert Authority.observation_freshness(-5_000, 60_000, 5_000) == :fresh
    assert Authority.observation_freshness(-5_001, 60_000, 5_000) == :future
    assert Authority.observation_freshness(-600_000, 60_000, 5_000) == :future
    # the bound is the caller's min(max_age_ms, evidence_max_age_ms); a tiny bound still works
    assert Authority.observation_freshness(1, 1, 0) == :fresh
    assert Authority.observation_freshness(2, 1, 0) == :stale
    assert Authority.observation_freshness(-1, 1, 0) == :future
  end

  # -- submission --------------------------------------------------------------------------------

  test "a fresh attestation is accepted and journaled with its age, bound, skew and conclusion; arming then succeeds",
       %{port: port} do
    {socket, adapter} = v2_peer(port)
    assert :ok = Command.attest_telemetry(attestation(adapter, at(0)))
    entry = last_attested()

    assert entry["freshness"] == "fresh" and entry["accepted"] == true and
             entry["age_bound_ms"] == 60_000 and entry["clock_skew_allowance_ms"] == 5_000

    assert is_integer(entry["observed_age_ms"]) and entry["observed_age_ms"] in 0..2_000
    assert entry["label"] =~ "not verified"
    assert Command.status().effectful.corroboration.observed_age_ms in 0..2_000
    assert :ok = Command.arm_effectful(ownership: ownership())

    armed = journal_entries() |> Enum.find(&(&1["event"] == "authority.armed_effectful"))
    assert is_integer(armed["corroboration"]["observed_age_ms_at_arming"])
    assert armed["corroboration"]["label"] =~ "operator-claimed"
    FakeNative.close(socket)
  end

  test "near the age boundary: just inside is accepted, just beyond is refused as stale and journaled as such; nothing is retained after a refusal",
       %{port: port} do
    {socket, adapter} = v2_peer(port)
    # 60 s allowance: 59.5 s old is inside the bound, 60.5 s old is beyond it
    assert :ok = Command.attest_telemetry(attestation(adapter, at(-59_500)))
    assert last_attested()["freshness"] == "fresh"

    assert {:error, :telemetry_observation_stale} =
             Command.attest_telemetry(attestation(adapter, at(-60_500)))

    entry = last_attested()
    assert entry["freshness"] == "stale" and entry["accepted"] == false
    assert entry["observed_age_ms"] > 60_000
    # the refusal replaced the earlier fresh corroboration: fail closed
    assert Command.status().effectful.corroboration == nil

    assert {:error, :telemetry_corroboration_missing} =
             Command.arm_effectful(ownership: ownership())

    FakeNative.close(socket)
  end

  test "an observation ten minutes old with a one-minute allowance is refused (the C-2C N1 case)",
       %{port: port} do
    {socket, adapter} = v2_peer(port)

    assert {:error, :telemetry_observation_stale} =
             Command.attest_telemetry(attestation(adapter, at(-600_000), 60_000))

    assert last_attested()["observed_age_ms"] >= 600_000

    assert {:error, :telemetry_corroboration_missing} =
             Command.arm_effectful(ownership: ownership())

    FakeNative.close(socket)
  end

  test "a future-dated observation inside the permitted skew is accepted; beyond it is refused as future",
       %{port: port} do
    {socket, adapter} = v2_peer(port)
    assert :ok = Command.attest_telemetry(attestation(adapter, at(2_000)))
    entry = last_attested()
    assert entry["freshness"] == "fresh" and entry["observed_age_ms"] < 0

    assert {:error, :telemetry_observation_future} =
             Command.attest_telemetry(attestation(adapter, at(60_000)))

    assert last_attested()["freshness"] == "future"
    assert Command.status().effectful.corroboration == nil
    FakeNative.close(socket)
  end

  @tag skew_ms: 0
  test "the skew is configured: with zero skew any lead is future", %{port: port} do
    {socket, adapter} = v2_peer(port)

    assert {:error, :telemetry_observation_future} =
             Command.attest_telemetry(attestation(adapter, at(2_000)))

    assert last_attested()["clock_skew_allowance_ms"] == 0
    FakeNative.close(socket)
  end

  test "the bound is the smaller of the attestation's max_age_ms and the configured maximum: a generous max_age_ms does not widen it",
       %{port: port} do
    {socket, adapter} = v2_peer(port)
    # configured 120 s; the attestation claims 600 s: 130 s old is stale
    assert {:error, :telemetry_observation_stale} =
             Command.attest_telemetry(attestation(adapter, at(-130_000), 600_000))

    assert last_attested()["age_bound_ms"] == 120_000
    # the attestation's own tighter allowance applies when smaller
    assert {:error, :telemetry_observation_stale} =
             Command.attest_telemetry(attestation(adapter, at(-3_000), 2_000))

    assert last_attested()["age_bound_ms"] == 2_000
    FakeNative.close(socket)
  end

  @tag evidence_max_age_ms: 2_000
  test "a configured maximum below the attestation's max_age_ms applies", %{port: port} do
    {socket, adapter} = v2_peer(port)

    assert {:error, :telemetry_observation_stale} =
             Command.attest_telemetry(attestation(adapter, at(-3_000), 60_000))

    assert last_attested()["age_bound_ms"] == 2_000
    assert :ok = Command.attest_telemetry(attestation(adapter, at(-500), 60_000))
    FakeNative.close(socket)
  end

  test "an invalid timestamp is refused before any freshness conclusion and nothing is journaled for it",
       %{port: port} do
    {socket, adapter} = v2_peer(port)
    before = length(journal_entries())

    assert {:error, {:invalid_attestation, :observed_at_invalid}} =
             Command.attest_telemetry(attestation(adapter, "2026-10-14 17:00"))

    assert {:error, {:invalid_attestation, :observed_at_invalid}} =
             Command.attest_telemetry(attestation(adapter, "2026-10-14T17:00:00"))

    assert length(journal_entries()) == before
    assert Command.status().effectful.corroboration == nil
    FakeNative.close(socket)
  end

  test "an adapter mismatch is still refused, whatever the freshness", %{port: port} do
    {socket, _adapter} = v2_peer(port)

    assert {:error, :adapter_identity_mismatch} =
             Command.attest_telemetry(attestation(GlacierRelay.Command.Schema.uuid4(), at(0)))

    assert last_attested()["accepted"] == false
    FakeNative.close(socket)
  end

  # -- arming: the second application of both clocks ------------------------------------------

  test "fresh when submitted, stale by the wall clock when arming: refused as observation stale even though the monotonic window is open",
       %{port: port} do
    {socket, adapter} = v2_peer(port)

    # 2 s allowance; the observation is already 1.6 s old when submitted (fresh), 0.6 s later it is
    # beyond the bound by the wall clock while only 0.6 s have elapsed since receipt
    assert :ok = Command.attest_telemetry(attestation(adapter, at(-1_600), 2_000))
    Process.sleep(600)

    assert {:error, :telemetry_observation_stale} =
             Command.arm_effectful(ownership: ownership())

    refute Command.status().trust.effectful_armed
    FakeNative.close(socket)
  end

  test "the monotonic receipt window expired while the wall-clock observation is nominally fresh: refused as corroboration stale",
       %{port: port} do
    {socket, adapter} = v2_peer(port)
    # a claim 3 s in the future (inside the skew) with a 1 s allowance: after 1.1 s the time since
    # receipt exceeds the allowance while the claimed instant is still ahead of the clock
    assert :ok = Command.attest_telemetry(attestation(adapter, at(3_000), 1_000))
    Process.sleep(1_100)

    assert {:error, :telemetry_corroboration_stale} =
             Command.arm_effectful(ownership: ownership())

    refute Command.status().trust.effectful_armed
    FakeNative.close(socket)
  end

  test "link loss clears the corroboration; the new generation needs a new attestation and arming",
       %{port: port} do
    {socket, adapter} = v2_peer(port)
    assert :ok = Command.attest_telemetry(attestation(adapter, at(0)))
    assert :ok = Command.arm_effectful(ownership: ownership())
    FakeNative.close(socket)
    assert wait(fn -> Command.status().link == nil end)
    refute Command.status().trust.effectful_armed
    assert Command.status().effectful.corroboration == nil

    {socket2, adapter2} = v2_peer(port)
    assert Command.status().link.generation == 2

    assert {:error, :telemetry_corroboration_missing} =
             Command.arm_effectful(ownership: ownership())

    assert :ok = Command.attest_telemetry(attestation(adapter2, at(0)))
    assert :ok = Command.arm_effectful(ownership: ownership())
    FakeNative.close(socket2)
  end

  test "an old attestation resubmitted on the current link is refused and displaces the fresh one",
       %{port: port} do
    {socket, adapter} = v2_peer(port)
    old = attestation(adapter, at(0), 1_000)
    assert :ok = Command.attest_telemetry(old)
    Process.sleep(1_100)
    # the very same map, resubmitted: its observed_at is now beyond its own allowance
    assert {:error, :telemetry_observation_stale} = Command.attest_telemetry(old)
    assert Command.status().effectful.corroboration == nil

    assert {:error, :telemetry_corroboration_missing} =
             Command.arm_effectful(ownership: ownership())

    FakeNative.close(socket)
  end

  test "a degraded audit refuses the attestation's record and arming, whatever the freshness",
       %{port: port, agent: agent} do
    {socket, adapter} = v2_peer(port)
    CountingWriter.fail_after(agent, 0, :eio)

    assert {:error, {:journal_unavailable, :eio}} =
             Command.attest_telemetry(attestation(adapter, at(0)))

    assert Command.status().effectful.corroboration == nil
    assert {:error, {:audit_degraded, _}} = Command.arm_effectful(ownership: ownership())
    FakeNative.close(socket)
  end

  test "the ownership evidence uses the same configured skew for a future-dated collected_at",
       %{port: port} do
    {socket, adapter} = v2_peer(port)
    assert :ok = Command.attest_telemetry(attestation(adapter, at(0)))

    assert {:error, :ownership_evidence_from_the_future} =
             Command.arm_effectful(ownership: Map.put(ownership(), "collected_at", at(60_000)))

    assert :ok = Command.arm_effectful(ownership: Map.put(ownership(), "collected_at", at(2_000)))
    FakeNative.close(socket)
  end
end
