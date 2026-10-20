# M7-L3 — focused controls of PeerKit.Sockets (sockets.exs), on owned loopback sockets only; no LAN, no relay application.
#   elixir tools/peer-transport/tests/sockets_test.exs
# The VM branch and the Linux kernel branch (ss) are executed here. The macOS branch (lsof) is exercised only through its parser,
# on a synthetic field-format sample: it was not executed on a Mac.
Code.require_file("../sockets.exs", __DIR__)
ExUnit.start(seed: 0, trace: true)

defmodule PeerKit.SocketsTest do
  use ExUnit.Case, async: false
  alias PeerKit.Sockets

  # M7-L1's PeerKit.listeners(), verbatim, as the regression reference (M7-L2 record section 13)
  defp old_listeners do
    for p <- :erlang.ports(), Port.info(p)[:name] == ~c"tcp_inet", match?({:error, :enotconn}, :inet.peername(p)),
        {:ok, {ip, port}} <- [:inet.sockname(p)], do: "#{:inet.ntoa(ip)}:#{port}"
  end

  defp listen(backlog \\ 5) do
    {:ok, ls} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, backlog: backlog, active: false)
    {:ok, {_, port}} = :inet.sockname(ls)
    {ls, port}
  end

  defp linux?, do: :os.type() == {:unix, :linux}

  setup do
    # every socket of this VM is the test's own: none may be left from an earlier test
    for p <- :erlang.ports(), Port.info(p)[:name] == ~c"tcp_inet", do: Port.close(p)
    :ok
  end

  test "an actual listener: listening, with its owner; the kernel agrees; only_listener?" do
    {ls, port} = listen()
    o = Sockets.observe()
    assert o["status"] == "observed"
    assert o["listening"] == ["127.0.0.1:#{port}"]
    assert [%{"states" => states, "owner" => owner}] = o["vm"]["listening"]
    assert "listen" in states and is_binary(owner)
    if linux?(), do: assert(o["kernel"]["available"] and o["kernel"]["listening"] == ["127.0.0.1:#{port}"] and o["kernel_agrees"] == true)
    assert Sockets.only_listener?(o, "127.0.0.1:#{port}")
    refute Sockets.no_listener?(o)
    assert is_binary(JSON.encode!(o))
    :gen_tcp.close(ls)
  end

  test "a connecting client (SYN sent, no peer yet) is connecting, never a listener; M7-L1's heuristic listed it" do
    {ls, port} = listen(1)
    # fill the accept queue without accepting: Linux then drops the next SYN and the client stays in SYN-SENT
    _fill = for _ <- 1..3, do: :gen_tcp.connect({127, 0, 0, 1}, port, [active: false], 300)
    me = self()
    spawn(fn -> send(me, {:late, :gen_tcp.connect({127, 0, 0, 1}, port, [active: false], 2_000)}) end)
    Process.sleep(200)
    old = old_listeners()
    o = Sockets.observe()
    assert [%{"local" => local, "remote" => nil, "states" => states}] = o["vm"]["connecting"]
    assert "connecting" in states
    refute local in o["listening"]
    assert o["listening"] == ["127.0.0.1:#{port}"]
    # the regression: the old function lists the connecting socket as a listener (M7-L2's record)
    assert local in old
    if linux?() do
      assert o["kernel_agrees"] == true
      assert Enum.any?(o["kernel"]["other"], &(&1["state"] == "SYN-SENT" and &1["local"] == local))
    end
    assert_receive {:late, {:error, :timeout}}, 3_000
    :gen_tcp.close(ls)
  end

  test "an established connection: both ends connected; a VM with only a client socket has no listener" do
    {ls, port} = listen()
    {:ok, c} = :gen_tcp.connect({127, 0, 0, 1}, port, active: false)
    {:ok, a} = :gen_tcp.accept(ls)
    o = Sockets.observe()
    assert length(o["vm"]["connected"]) == 2
    assert Enum.all?(o["vm"]["connected"], &("connected" in &1["states"] and is_binary(&1["remote"])))
    :gen_tcp.close(ls)
    o2 = Sockets.observe()
    assert o2["status"] == "observed" and o2["listening"] == [] and Sockets.no_listener?(o2)
    assert length(o2["vm"]["connected"]) == 2
    :gen_tcp.close(c)
    :gen_tcp.close(a)
  end

  test "the closure race: a socket closed after the enumeration, or during its query, is counted, not classified" do
    {ls, _port} = listen()
    {ls2, _} = listen()
    ports = :erlang.ports()
    :gen_tcp.close(ls2)
    o = Sockets.observe(ports: fn -> ports end)
    assert o["status"] == "observed"
    assert length(o["listening"]) == 1
    # closed during the state query itself (a fake query that closes the socket first)
    {ls3, _} = listen()
    o3 = Sockets.observe(info: fn p -> if p == ls3, do: (:gen_tcp.close(ls3); :inet.info(p)), else: :inet.info(p) end)
    assert o3["vm"]["closed_during_observation"] == 1
    assert o3["status"] == "observed"
    :gen_tcp.close(ls)
  end

  test "an observation failure is unavailable, never an empty successful result" do
    {ls, _port} = listen()
    o = Sockets.observe(ports: fn -> raise "enumeration refused" end)
    assert o["status"] == "unavailable" and o["vm"]["complete"] == false
    refute Sockets.no_listener?(o)
    o2 = Sockets.observe(info: fn _ -> raise "query refused" end)
    assert o2["status"] == "unavailable" and o2["vm"]["errors"] != []
    refute Sockets.no_listener?(o2)
    o3 = Sockets.observe(info: fn _ -> :unexpected end)
    assert o3["status"] == "unavailable"
    :gen_tcp.close(ls)
  end

  test "a kernel listing that disagrees is ambiguous; a missing kernel listing leaves the VM's verdict" do
    {ls, port} = listen()
    o = Sockets.observe(kernel: fn _ -> %{"available" => true, "method" => "fake", "utc" => "t", "listening" => ["127.0.0.1:#{port}", "0.0.0.0:4760"], "other" => []} end)
    assert o["status"] == "ambiguous" and o["kernel_agrees"] == false
    refute Sockets.only_listener?(o, "127.0.0.1:#{port}")
    o2 = Sockets.observe(kernel: fn _ -> raise "no kernel listing" end)
    assert o2["status"] == "observed" and o2["kernel_agrees"] == nil and o2["kernel"]["available"] == false
    :gen_tcp.close(ls)
  end

  test "the ss parser keeps only this process's lines" do
    out = """
    LISTEN   0      5        127.0.0.1:4760      0.0.0.0:*     users:(("beam.smp",pid=111,fd=17))
    SYN-SENT 0      1        172.23.229.225:57294 192.168.1.17:4760 users:(("beam.smp",pid=111,fd=18))
    LISTEN   0      5        127.0.0.1:4749      0.0.0.0:*     users:(("beam.smp",pid=222,fd=17))
    TIME-WAIT 0     0        127.0.0.1:1         127.0.0.1:2
    """
    k = Sockets.parse_ss(out, "111")
    assert k["listening"] == ["127.0.0.1:4760"]
    assert k["other"] == [%{"state" => "SYN-SENT", "local" => "172.23.229.225:57294", "remote" => "192.168.1.17:4760"}]
  end

  test "the lsof field parser (macOS branch; parser only, not executed on a Mac)" do
    out = "p61051\nf17\nn192.168.1.17:4760\nTST=LISTEN\nTQR=0\nTQS=0\nf18\nn192.168.1.17:4760->192.168.1.11:57294\nTST=ESTABLISHED\nTQR=0\nTQS=0\n"
    k = Sockets.parse_lsof(out, "61051")
    assert k["listening"] == ["192.168.1.17:4760"]
    assert k["other"] == [%{"state" => "ESTABLISHED", "local" => "192.168.1.17:4760", "remote" => "192.168.1.11:57294"}]
    assert Sockets.parse_lsof(out, "9")["listening"] == []
  end
end
