defmodule GlacierRelay.Peer.NetworkTwoProcessTest do
  @moduledoc """
  M7-L1: the `lan_ipv4` profile across two ordinary, non-distributed BEAM operating-system
  processes on owned loopback sockets (design section 20; the second process is
  `Test.HeadlessHarness`, driven over its standard input and output only):

  - the game host (this VM: command and motion subtrees, the fake native) connects out under a
    connect profile to the headless child listening under a listen profile — the child's only
    listener is the declared `127.0.0.1` socket; a share goes out and a course comes in;
  - the M7-L2 shape: a headless child **connects out** under a connect profile to a headless peer in
    this VM listening under a listen profile; one finite synthetic course each way, both reconciled
    by their sinks, nothing reflected.

  Loopback stands in for the LAN here; it says nothing about a Mac, a LAN or a firewall.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.{HeadlessPeer, Motion}
  alias GlacierRelay.HeadlessPeer.Driver
  alias GlacierRelay.Motion.{Course, Hub}
  alias GlacierRelay.Peer.Endpoint
  alias GlacierRelay.Test.{FakeMotionNative, HeadlessHarness, MotionStack, PeerCredentials}

  @moduletag :two_process
  @gen FakeMotionNative.generation()

  defp tmp do
    dir =
      Path.join(System.tmp_dir!(), "glacier-relay-m7l1-2p-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp strs(files), do: Map.new(files, fn {k, v} -> {Atom.to_string(k), v} end)

  defp child_status(child) do
    {:ok, %{"status" => s}} = HeadlessHarness.request(child, %{"op" => "status"})
    s
  end

  defp listening(os_pid) do
    {out, 0} = System.cmd("ss", ["-H", "-ltnp"])

    out
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.contains?(&1, "pid=#{os_pid},"))
    |> Enum.map(&Enum.at(String.split(&1), 3))
  end

  test "game host → headless child under the profile: the child's one listener is the declared socket; data both ways" do
    creds = PeerCredentials.pair()
    dir = tmp()
    port = MotionStack.free_port()
    files = PeerCredentials.write_files(creds.headless, Path.join(dir, "child-creds"), "headless")

    {child, ready} =
      HeadlessHarness.start_child(%{
        "credentials" => strs(files),
        "label" => "headless-test",
        "expected_label" => "host-test",
        "trace_dir" => Path.join(dir, "child-trace"),
        "network" => %{
          "prefix_length" => 8,
          "listen" => ["127.0.0.1", port],
          "initiator" => "127.0.0.1"
        }
      })

    on_exit(fn -> HeadlessHarness.close(child, ready["os_pid"]) end)
    assert ready["distributed"] == false and ready["port"] == port
    assert listening(ready["os_pid"]) == ["127.0.0.1:#{port}"]

    st = MotionStack.start(headless: false, lan: true, peer_port: port, creds: creds)
    MotionStack.wait(fn -> Hub.status().peer != nil end, 500)
    assert Endpoint.status(Motion.PeerEndpoint).network == "lan_ipv4 127.0.0.1:#{port}/8"

    :ok = MotionStack.arm()
    {:ok, %{share_id: share}} = Motion.open_share(duration_ms: 1_000, expected_generation: @gen)

    MotionStack.wait(
      fn -> Enum.any?(child_status(child)["sink_done"], &(&1["stream_id"] == share)) end,
      300
    )

    [done] = Enum.filter(child_status(child)["sink_done"], &(&1["stream_id"] == share))
    assert done["reconciliation"]["complete"] == true

    {ax, ay} = FakeMotionNative.anchor_words()

    {:ok, %{"ok" => true, "stream_id" => stream}} =
      HeadlessHarness.request(child, %{
        "op" => "start_course",
        "profile" => "out_and_back",
        "origin" => [ax, ay],
        "opts" => %{
          "prefix_ms" => 1_200,
          "distance_m" => 0.2,
          "speed_mps" => 0.5,
          "hold_ms" => 200
        }
      })

    MotionStack.wait(fn -> Map.has_key?(Hub.status().peer.streams, stream) end)
    {_sid, _} = MotionStack.open_session(st.adapter, stream)
    MotionStack.wait(fn -> match?(%{status: :done}, Hub.status().session) end, 800)
    s = Hub.status().session.summary
    assert s.close.state == :confirmed and s.counts.applied > 0 and s.counts.uncertain == 0
  end

  test "the L2 shape: a headless child connects out; one finite synthetic course each way, reconciled" do
    creds = PeerCredentials.pair()
    dir = tmp()
    port = MotionStack.free_port()

    # this VM: the listening headless peer (the Mac's role in M7-L2)
    start_supervised!(
      {HeadlessPeer,
       network: MotionStack.lan_listen(port),
       credentials: fn -> creds.headless end,
       label: "l2-listener",
       expected: %{label: "l2-initiator", client_kind: "headless"},
       trace_dir: Path.join(dir, "listener-trace")}
    )

    # the other OS process: the initiating headless peer (the Windows host's role), outbound only
    files = PeerCredentials.write_files(creds.host, Path.join(dir, "child-creds"), "initiator")

    {child, ready} =
      HeadlessHarness.start_child(%{
        "credentials" => strs(files),
        "label" => "l2-initiator",
        "expected_label" => "l2-listener",
        "expected_kind" => "headless",
        "role" => "connect",
        "trace_dir" => Path.join(dir, "child-trace"),
        "network" => %{"prefix_length" => 8, "connect" => ["127.0.0.1", port]}
      })

    on_exit(fn -> HeadlessHarness.close(child, ready["os_pid"]) end)
    # the initiator listens on nothing
    assert listening(ready["os_pid"]) == []
    MotionStack.wait(fn -> Driver.status().peer != nil end, 500)

    assert Driver.status().peer.label == "l2-initiator" and
             Driver.status().peer.client_kind == "headless"

    # one finite course each way, at the same time
    {ax, ay} = FakeMotionNative.anchor_words()
    shape = %{"prefix_ms" => 500, "distance_m" => 0.2, "speed_mps" => 0.5, "hold_ms" => 200}

    {:ok, %{"ok" => true, "stream_id" => out, "samples" => n_out}} =
      HeadlessHarness.request(child, %{
        "op" => "start_course",
        "profile" => "out_and_back",
        "origin" => [ax, ay],
        "opts" => shape
      })

    {:ok, back} =
      Driver.start_course(
        Course.out_and_back({ax, ay},
          prefix_ms: 500,
          distance_m: 0.2,
          speed_mps: 0.5,
          hold_ms: 200
        ),
        label: "M7-L1 two-process test (synthetic)"
      )

    MotionStack.wait(fn -> Enum.any?(Driver.status().sink_done, &(&1.stream_id == out)) end, 600)

    MotionStack.wait(
      fn -> Enum.any?(child_status(child)["sink_done"], &(&1["stream_id"] == back)) end,
      600
    )

    [here] = Enum.filter(Driver.status().sink_done, &(&1.stream_id == out))
    assert here.source_kind == "synthetic" and here.reconciliation["complete"] == true
    assert here.reconciliation["received"] == n_out and here.duplicate == 0 and here.older == 0

    [there] = Enum.filter(child_status(child)["sink_done"], &(&1["stream_id"] == back))
    assert there["source_kind"] == "synthetic" and there["reconciliation"]["complete"] == true

    # the sinks only recorded: each side sent exactly one stream of its own
    [mine] = Driver.status().sources_done
    assert mine.stream_id == back and mine.reason == "course_complete" and mine.dropped == 0
    [theirs] = child_status(child)["sources_done"]
    assert theirs["stream_id"] == out and theirs["sent"] == n_out
    assert Endpoint.status(HeadlessPeer.endpoint()).counts.connections == 1
  end
end
