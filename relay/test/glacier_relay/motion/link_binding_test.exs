defmodule GlacierRelay.Motion.LinkBindingTest do
  @moduledoc """
  M7-B1: the local motion link's binding (design section 15.5; ADR 0010 as amended, decision 2)
  against raw loopback sockets: accepted only for the current, token-verified command link's
  adapter and generation, attested by the run token's HMAC over a fresh nonce and both link
  generations, refused for anything else, ended with its command link; loopback access or a UUID
  alone binds nothing; the token never travels. The M6 welcome is unchanged for a peer that does
  not advertise the motion entries.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.Command
  alias GlacierRelay.Command.{Authority, Listener, Schema}
  alias GlacierRelay.Motion.{Codec, Hub}
  alias GlacierRelay.Test.{FakeMotionNative, FakeNative, FixturePlayer}

  @token "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  @caps FakeMotionNative.capabilities()

  defp wait(fun), do: FixturePlayer.wait_until(fun, 300, 10)

  setup context do
    dir = Path.join(System.tmp_dir!(), "glacier-relay-m7b1-bind-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    start_supervised!(
      {Command.Supervisor,
       port: 0,
       journal_dir: dir,
       hello_timeout_ms: 1_000,
       effectful: true,
       token: @token,
       motion: [enabled: Map.get(context, :motion, true), port: 0, trace_dir: Path.join(dir, "trace")]}
    )

    %{port: Listener.port()}
  end

  defp motion_port, do: GlacierRelay.Motion.Listener.port()

  # a version-2 command link, attested or not
  defp command_link(port, attest \\ true) do
    {socket, adapter, welcome} =
      FakeNative.handshake_v2(port, if(attest, do: @token, else: nil), capabilities: @caps)

    if attest, do: wait(fn -> Command.status().trust.token_verified end)
    {socket, adapter, welcome["link_generation"]}
  end

  defp hello(m, adapter, gen) do
    :ok = :gen_tcp.send(m, FakeMotionNative.motion_hello(adapter, gen))
    FakeMotionNative.recv_line(m)
  end

  defp closed?(m), do: match?({:error, :closed}, :gen_tcp.recv(m, 0, 1_500))

  test "the binding: hello for the current link, welcome with a nonce, attest; then the hub has it", %{port: port} do
    {_c, adapter, gen} = command_link(port)
    m = FakeMotionNative.connect_line(motion_port())
    {:ok, w} = hello(m, adapter, gen)
    assert w["kind"] == "motion.welcome" and Schema.nonce?(w["nonce"])
    attest = FakeMotionNative.motion_attest(@token, w, gen, adapter)
    refute attest =~ @token
    :ok = :gen_tcp.send(m, attest)
    wait(fn -> Hub.status().link != nil end)
    assert %{generation: 1, adapter_instance_id: ^adapter, command_link_generation: ^gen} = Hub.status().link
    assert %{bound: true, generation: 1} = Command.status().motion.link
    journal = Command.Journal.status().path |> File.read!()
    assert journal =~ "motion.link.bound"
    refute journal =~ @token
    refute journal =~ w["nonce"] <> "x"
  end

  test "a wrong adapter, a wrong command-link generation or an unattested command link is refused", %{port: port} do
    {_c, adapter, gen} = command_link(port)

    for {a, g, reason} <- [
          {Schema.uuid4(), gen, "adapter_mismatch"},
          {adapter, gen + 1, "command_link_generation_mismatch"}
        ] do
      m = FakeMotionNative.connect_line(motion_port())
      assert {:ok, %{"kind" => "motion.refused", "reason" => ^reason}} = hello(m, a, g)
      assert closed?(m)
    end

    assert Hub.status().link == nil
  end

  test "before the command link is token-verified nothing binds", %{port: port} do
    {_c, adapter, gen} = command_link(port, false)
    m = FakeMotionNative.connect_line(motion_port())
    assert {:ok, %{"kind" => "motion.refused", "reason" => "command_link_not_token_verified"}} = hello(m, adapter, gen)
  end

  test "a wrong MAC, a MAC for other generations or the command link's own MAC is refused; one attempt", %{port: port} do
    {_c, adapter, gen} = command_link(port)

    for make <- [
          fn w -> FakeMotionNative.motion_attest(String.duplicate("f", 64), w, gen, adapter) end,
          fn w -> FakeMotionNative.motion_attest(@token, Map.put(w, "motion_link_generation", w["motion_link_generation"] + 7), gen, adapter) end,
          # the command link's attestation formula over the same nonce: domain-separated, refused
          fn w ->
            Codec.encode_from_native("motion.attest", %{
              "motion_link_generation" => w["motion_link_generation"],
              "command_link_generation" => gen,
              "adapter_instance_id" => adapter,
              "mac" => Schema.attest_mac(@token, w["nonce"], gen, adapter)
            })
          end
        ] do
      m = FakeMotionNative.connect_line(motion_port())
      {:ok, w} = hello(m, adapter, gen)
      :ok = :gen_tcp.send(m, make.(w))
      assert {:ok, %{"kind" => "motion.refused"}} = FakeMotionNative.recv_line(m)
      assert closed?(m)
    end

    assert Hub.status().link == nil
    assert Command.Journal.status().path |> File.read!() |> String.contains?("motion.link.attest_failed")
  end

  test "messages before the binding, a second attest and a second motion link are refused", %{port: port} do
    {_c, adapter, gen} = command_link(port)

    # data before the binding
    m0 = FakeMotionNative.connect_line(motion_port())

    :ok =
      :gen_tcp.send(
        m0,
        Codec.encode_from_native("ghost.closed", %{"session_id" => Schema.uuid4(), "reason" => "x", "native_mono_ms" => 1, "clean" => true, "applied" => 0})
      )

    assert closed?(m0)

    m = FakeMotionNative.connect_line(motion_port())
    {:ok, w} = hello(m, adapter, gen)
    :ok = :gen_tcp.send(m, FakeMotionNative.motion_attest(@token, w, gen, adapter))
    wait(fn -> Hub.status().link != nil end)

    # a second link while one is bound
    m2 = FakeMotionNative.connect_line(motion_port())
    assert {:ok, %{"kind" => "motion.refused", "reason" => "busy"}} = hello(m2, adapter, gen)

    # a second attest on the bound link is a violation that drops it
    :ok = :gen_tcp.send(m, FakeMotionNative.motion_attest(@token, w, gen, adapter))
    assert closed?(m)
    wait(fn -> Hub.status().link == nil and Command.status().motion.link == nil end)
  end

  test "the binding ends with its command link", %{port: port} do
    {c, adapter, gen} = command_link(port)
    m = FakeMotionNative.connect_line(motion_port())
    {:ok, w} = hello(m, adapter, gen)
    :ok = :gen_tcp.send(m, FakeMotionNative.motion_attest(@token, w, gen, adapter))
    wait(fn -> Hub.status().link != nil end)
    :gen_tcp.close(c)
    assert closed?(m)
    wait(fn -> Hub.status().link == nil and Command.status().motion.link == nil end)
  end

  test "a bound link's data naming no known share or session changes nothing", %{port: port} do
    {_c, adapter, gen} = command_link(port)
    m = FakeMotionNative.connect_line(motion_port())
    {:ok, w} = hello(m, adapter, gen)
    :ok = :gen_tcp.send(m, FakeMotionNative.motion_attest(@token, w, gen, adapter))
    wait(fn -> Hub.status().link != nil end)

    :ok =
      :gen_tcp.send(
        m,
        Codec.encode_from_native("ghost.applied", %{"session_id" => Schema.uuid4(), "seq" => 1, "frame" => 1, "native_mono_ms" => 1, "outcome" => "applied", "post" => "c2b2fae1,416d47ae", "exact" => true})
      )

    wait(fn -> Hub.status().counts.unknown_ids == 1 end)
    assert Hub.status().session == nil and Hub.status().link != nil
  end

  test "an M6 peer that does not advertise the motion entries sees the welcome it saw before" do
    caps = ["relay.probe/1", "relay.inspect.candidate_transform/1", "candidate.transform.set/1", "candidate.transform.set/2"]
    assert Schema.issuable_for(2, caps, true, true) == Schema.issuable_for(2, caps, true)
    assert Schema.issuable_for(1, @caps, true, true) == Schema.issuable()

    assert Enum.map(Schema.issuable(), &{&1["name"], &1["version"]}) == [
             {"relay.inspect.candidate", 1},
             {"relay.inspect.candidate_transform", 1},
             {"relay.inspect.entity", 1},
             {"relay.inspect.outfit", 1},
             {"relay.inspect.players", 1},
             {"relay.probe", 1}
           ]

    motion = Schema.issuable_for(2, @caps, true, true) -- Schema.issuable_for(2, @caps, true, false)
    assert Enum.sort(Enum.map(motion, & &1["name"])) == ["candidate.motion.session", "player.pose.share"]
    # with the effectful setting off only the inert motion entry can be listed
    assert Schema.issuable_for(2, @caps, false, true) -- Schema.issuable() == [%{"name" => "player.pose.share", "version" => 1}]
  end

  @tag motion: false
  test "with motion off nothing of it runs and no motion link is accepted", %{port: port} do
    assert Process.whereis(GlacierRelay.Motion.Supervisor) == nil
    assert Process.whereis(Hub) == nil
    assert {:error, :motion_disabled} = GlacierRelay.Motion.status()
    {_c, adapter, gen} = command_link(port)
    assert {:error, :motion_disabled} = Authority.motion_hello(self(), adapter, gen)
    # a motion entry is never listed nor issuable with motion off
    refute Enum.any?(Command.status().link.advertised, &(&1["name"] in ["player.pose.share", "candidate.motion.session"]))
    :ok = Command.arm()
    assert {:error, :motion_disabled} = Authority.issue("player.pose.share", 1, %{}, [])
  end
end
