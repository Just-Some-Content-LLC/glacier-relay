defmodule GlacierRelay.Motion.TwoProcessTest do
  @moduledoc """
  M7-B1: two ordinary local BEAM processes over the explicit peer TLS link (design sections 9 and
  15.7): this VM is the game host (command and motion subtrees, the fake native) and connects out
  to the headless peer running in a **second operating-system process**
  (`Test.HeadlessHarness`), each in each direction and both at once on the one link. Neither node is
  distributed: no `--sname`, no epmd, no Erlang distribution between them; the child is driven over
  its standard input and output only, listens on loopback only and halts with its input.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.Command
  alias GlacierRelay.Motion
  alias GlacierRelay.Motion.Hub
  alias GlacierRelay.Peer.Endpoint
  alias GlacierRelay.Test.{FakeMotionNative, HeadlessHarness, MotionStack, PeerCredentials}

  @moduletag :two_process
  @gen FakeMotionNative.generation()

  setup do
    creds = PeerCredentials.pair()

    dir =
      Path.join(System.tmp_dir!(), "glacier-relay-m7b1-2p-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(dir) end)
    files = PeerCredentials.write_files(creds.headless, Path.join(dir, "child-creds"), "headless")

    {port, ready} =
      HeadlessHarness.start_child(%{
        "credentials" => Map.new(files, fn {k, v} -> {Atom.to_string(k), v} end),
        "label" => "headless-test",
        "expected_label" => "host-test",
        "trace_dir" => Path.join(dir, "child-trace"),
        "port" => 0
      })

    on_exit(fn -> HeadlessHarness.close(port, ready["os_pid"]) end)
    st = MotionStack.start(headless: false, peer_port: ready["port"], creds: creds)
    MotionStack.wait(fn -> Hub.status().peer != nil end, 500)
    %{child: port, ready: ready, st: st, dir: dir}
  end

  defp child_status(child) do
    {:ok, %{"status" => s}} = HeadlessHarness.request(child, %{"op" => "status"})
    s
  end

  defp course(child, extra \\ %{}) do
    {ax, ay} = FakeMotionNative.anchor_words()

    {:ok, %{"ok" => true, "stream_id" => stream}} =
      HeadlessHarness.request(child, %{
        "op" => "start_course",
        "profile" => "out_and_back",
        "origin" => [ax, ay],
        "opts" =>
          Map.merge(
            %{"prefix_ms" => 1_200, "distance_m" => 0.2, "speed_mps" => 0.5, "hold_ms" => 200},
            extra
          )
      })

    MotionStack.wait(fn -> Map.has_key?(Hub.status().peer.streams, stream) end)
    stream
  end

  test "neither node is distributed; the child listens on loopback only; it is a separate OS process",
       %{ready: ready} do
    assert ready["distributed"] == false and ready["node"] == "nonode@nohost"
    refute Node.alive?()
    assert ready["os_pid"] != System.pid()
    {out, 0} = System.cmd("ss", ["-H", "-ltnp"])

    mine =
      out
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.contains?(&1, "pid=#{ready["os_pid"]},"))

    assert [line] = mine, inspect(mine)
    # columns: state, recv-q, send-q, LOCAL address:port, peer address:port, process
    assert Enum.at(String.split(line), 3) == "127.0.0.1:#{ready["port"]}"
    {out6, 0} = System.cmd("ss", ["-H", "-ltnp6"])
    refute out6 =~ "pid=#{ready["os_pid"]},"
    # and this VM's own peer endpoint only connects out: no listener of its own
    assert Endpoint.status(GlacierRelay.Motion.PeerEndpoint).role == :connect
  end

  test "game host → headless: the share reaches the other process's sink, labelled and reconciled",
       %{child: child} do
    :ok = MotionStack.arm()

    {:ok, %{share_id: share}} =
      Motion.open_share(
        duration_ms: 1_000,
        expected_generation: @gen,
        label: "B1 fake native — not a game"
      )

    MotionStack.wait(fn -> child_status(child)["sink_done"] != [] end, 300)
    [done] = child_status(child)["sink_done"]

    assert done["stream_id"] == share and done["source_kind"] == "game" and
             done["src_clock"] == "native"

    r = done["reconciliation"]
    assert r["received"] == r["source_sent"] and r["last_seq_received"] == r["source_last_seq"]
  end

  test "headless → game host: the other process's synthetic course drives the fake native", %{
    child: child,
    st: st
  } do
    stream = course(child)
    {_sid, _} = MotionStack.open_session(st.adapter, stream)
    MotionStack.wait(fn -> match?(%{status: :done}, Hub.status().session) end, 800)
    s = Hub.status().session.summary
    assert s.close.state == :confirmed and s.counts.applied > 5 and s.counts.uncertain == 0
    assert s.close.reason =~ "stream_end"
    [src] = child_status(child)["sources_done"]
    assert src["stream_id"] == stream and src["sent"] == s.last_seq
    # everything the other process sent arrived, in order: before the session the hub counted it
    # unrouted, from the approval on the session received it
    assert Hub.status().counts.unrouted_samples + s.counts.received == src["sent"]
    assert s.last_seq == src["last_seq"]
    assert s.counts.refused.duplicate == 0 and s.counts.refused.older == 0
  end

  test "duplex on one link: a share out and a session in at the same time", %{
    child: child,
    st: st
  } do
    stream = course(child, %{"prefix_ms" => 800})
    {_sid, _} = MotionStack.open_session(st.adapter, stream)
    :ok = MotionStack.arm()
    {:ok, %{share_id: share}} = Motion.open_share(duration_ms: 1_200, expected_generation: @gen)
    MotionStack.wait(fn -> match?(%{status: :done}, Hub.status().session) end, 800)

    MotionStack.wait(
      fn -> Enum.any?(child_status(child)["sink_done"], &(&1["stream_id"] == share)) end,
      300
    )

    s = Hub.status().session.summary
    assert s.close.state == :confirmed and s.counts.applied > 0
    [done] = Enum.filter(child_status(child)["sink_done"], &(&1["stream_id"] == share))
    assert done["reconciliation"]["received"] == done["reconciliation"]["source_sent"]
    assert Endpoint.status(GlacierRelay.Motion.PeerEndpoint).counts.connections == 1
  end

  test "delayed traffic in the other process's buffers is not played out after a stall", %{
    child: child,
    st: st
  } do
    stream = course(child, %{"prefix_ms" => 400, "distance_m" => 0.4, "hold_ms" => 1_500})
    {_sid, _} = MotionStack.open_session(st.adapter, stream)
    Process.sleep(200)

    {:ok, %{"ok" => true}} =
      HeadlessHarness.request(child, %{"op" => "suspend_connection", "ms" => 800})

    MotionStack.wait(fn -> match?(%{status: :done}, Hub.status().session) end, 400)
    assert Hub.status().session.summary.close.reason == "stall"
    applied = length(for {:applied, _, _, _} <- FakeMotionNative.events(st.fake), do: 1)
    Process.sleep(1_200)
    assert length(for {:applied, _, _, _} <- FakeMotionNative.events(st.fake), do: 1) == applied
    assert Command.status().motion.sessions |> hd() |> Map.get(:state) == :closed_clean
  end
end
