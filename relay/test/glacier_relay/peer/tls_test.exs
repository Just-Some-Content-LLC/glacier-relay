defmodule GlacierRelay.Peer.TLSTest do
  @moduledoc """
  M7-B1: the peer link's authentication and bounds against the installed OTP (design sections
  15.6–15.7), in this VM over loopback with throwaway credentials: mutual TLS 1.3 with per-side CAs
  and pinned leaves; refusals of wrong pins, missing or foreign certificates, a same-CA foreign
  leaf, TLS 1.2, garbage handshakes, foreign or mis-kinded hellos, a self-connection and a second
  connection; strict post-handshake framing; loopback-only binds; bounded queues, stale drops,
  control overflow, a blocked send's deadline, the idle timeout and a slow handler.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.Command.Schema
  alias GlacierRelay.Peer.{Codec, Connection, Endpoint, TLS}
  alias GlacierRelay.Test.{FixturePlayer, PeerCredentials}

  defmodule Probe do
    @moduledoc false
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    def peer_event(server, event, timeout), do: GenServer.call(server, {:event, event}, timeout)
    def peer_notify(server, event), do: GenServer.cast(server, {:notify, event})
    def events(server), do: GenServer.call(server, :events)
    def set_delay(server, ms), do: GenServer.call(server, {:delay, ms})
    @impl true
    def init(_), do: {:ok, %{events: [], delay: 0}}
    @impl true
    def handle_call({:event, ev}, _from, st) do
      if st.delay > 0 and elem(ev, 0) == :sample, do: Process.sleep(st.delay)
      {:reply, :ok, %{st | events: [ev | st.events]}}
    end

    def handle_call(:events, _from, st), do: {:reply, Enum.reverse(st.events), st}
    def handle_call({:delay, ms}, _from, st), do: {:reply, :ok, %{st | delay: ms}}
    @impl true
    def handle_cast({:notify, ev}, st), do: {:noreply, %{st | events: [ev | st.events]}}
  end

  defp wait(fun, attempts \\ 300), do: FixturePlayer.wait_until(fun, attempts, 10)

  defp listener(creds, opts \\ []) do
    start_supervised!({Probe, name: :probe_l}, id: :probe_l)

    start_supervised!(
      {Endpoint,
       Keyword.merge(
         [
           role: :listen,
           name: :ep_l,
           port: 0,
           credentials: fn -> creds end,
           local: %{label: "headless-t", client_kind: "headless"},
           expected: %{label: "host-t", client_kind: "game"},
           handler: {Probe, :probe_l}
         ],
         opts
       )},
      id: :ep_l
    )

    Endpoint.port(:ep_l)
  end

  defp connector(creds, port, opts \\ []) do
    start_supervised!({Probe, name: :probe_c}, id: :probe_c)

    start_supervised!(
      {Endpoint,
       Keyword.merge(
         [
           role: :connect,
           name: :ep_c,
           port: port,
           credentials: fn -> creds end,
           local: %{label: "host-t", client_kind: "game"},
           expected: %{label: "headless-t", client_kind: "headless"},
           handler: {Probe, :probe_c}
         ],
         opts
       )},
      id: :ep_c
    )
  end

  defp up?(probe), do: Enum.any?(Probe.events(probe), &match?({:up, _}, &1))
  defp downs(probe), do: for({:down, _info, reason} <- Probe.events(probe), do: reason)
  defp conn(ep), do: Endpoint.status(ep).connection

  # one connection at a time: a client closed by the listener's connection is refused as busy until
  # the endpoint has seen that connection end (since the M7-L1 correction the refusal is a prompt
  # TCP closure), so a test's next client waits for that first
  defp idle(ep), do: wait(fn -> conn(ep) == nil end)

  setup do
    %{c: PeerCredentials.pair()}
  end

  test "mutual TLS 1.3 with pinned leaves: both sides identified; pins checked on the received DER",
       %{c: c} do
    port = listener(c.headless)
    connector(c.host, port)
    wait(fn -> up?(:probe_l) and up?(:probe_c) end)
    [{:up, li}] = for {:up, _} = e <- Probe.events(:probe_l), do: e
    [{:up, ci}] = for {:up, _} = e <- Probe.events(:probe_c), do: e

    assert li.label == "host-t" and li.client_kind == "game" and
             li.pin == TLS.pin(c.host_leaf.cert)

    assert ci.label == "headless-t" and ci.client_kind == "headless" and
             ci.pin == TLS.pin(c.headless_leaf.cert)

    assert li.boot_id != ci.boot_id
    # the endpoint's state never carries the credentials in a status or a crash report
    refute inspect(:sys.get_status(Process.whereis(:ep_l))) =~ "ECPrivateKey"
    refute inspect(Endpoint.status(:ep_l)) =~ "ECPrivateKey"
    # liveness: an RTT measured on the pinger's own clock
    wait(fn -> Enum.any?(Probe.events(:probe_c), &match?({:rtt, _, _}, &1)) end, 300)
  end

  test "a wrong pin on either side refuses the handshake; nothing is identified", %{c: c} do
    other = PeerCredentials.leaf(c.headless_root)
    port = listener(c.headless)
    connector(Keyword.put(c.host, :peer_pin, TLS.pin(other.cert)), port)
    wait(fn -> Endpoint.status(:ep_c).counts.connect_failures >= 1 end)
    refute up?(:probe_l) or up?(:probe_c)
    stop_supervised!(:ep_c)
    stop_supervised!(:probe_c)
    stop_supervised!(:ep_l)
    stop_supervised!(:probe_l)

    port =
      listener(
        Keyword.put(c.headless, :peer_pin, TLS.pin(PeerCredentials.leaf(c.host_root).cert))
      )

    connector(c.host, port)
    wait(fn -> Endpoint.status(:ep_l).counts.handshake_failures >= 1 end)
    refute up?(:probe_l)
  end

  test "missing, foreign-CA and same-CA-foreign-leaf client certificates and TLS 1.2 are refused",
       %{c: c} do
    port = listener(c.headless)

    base = [
      versions: [:"tlsv1.3"],
      verify: :verify_peer,
      cacerts: [c.headless_root.cert],
      server_name_indication: :disable,
      active: false
    ]

    # no client certificate
    r1 = :ssl.connect({127, 0, 0, 1}, port, base, 3_000)
    assert handshake_refused?(r1)

    # a leaf from a CA the listener does not trust
    foreign_root = PeerCredentials.root("throwaway-foreign")
    foreign = PeerCredentials.leaf(foreign_root)
    r2 = :ssl.connect({127, 0, 0, 1}, port, base ++ [cert: foreign.cert, key: foreign.key], 3_000)
    assert handshake_refused?(r2)

    # the trusted CA, but not the pinned leaf
    sibling = PeerCredentials.leaf(c.host_root)
    r3 = :ssl.connect({127, 0, 0, 1}, port, base ++ [cert: sibling.cert, key: sibling.key], 3_000)
    assert handshake_refused?(r3)

    # TLS 1.2 only, with the right certificate
    r4 =
      :ssl.connect(
        {127, 0, 0, 1},
        port,
        Keyword.put(base, :versions, [:"tlsv1.2"]) ++
          [cert: c.host_leaf.cert, key: c.host_leaf.key],
        3_000
      )

    assert match?({:error, _}, r4)

    wait(fn -> Endpoint.status(:ep_l).counts.handshake_failures >= 4 end)
    refute up?(:probe_l)
  end

  # TLS 1.3 may complete the client's side before the server's verdict arrives: a refused client
  # then sees the alert or the close on its first read
  defp handshake_refused?({:error, _}), do: true

  defp handshake_refused?({:ok, s}) do
    r = :ssl.recv(s, 0, 2_000)
    :ssl.close(s)
    match?({:error, _}, r)
  end

  test "a garbage handshake is refused and the listener keeps serving", %{c: c} do
    port = listener(c.headless)
    {:ok, raw} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(raw, String.duplicate("GET / HTTP/1.0\r\n", 4))

    assert {:error, _} =
             :gen_tcp.recv(raw, 0, 3_000)
             |> then(&if(match?({:ok, _}, &1), do: :gen_tcp.recv(raw, 0, 3_000), else: &1))

    :gen_tcp.close(raw)
    wait(fn -> Endpoint.status(:ep_l).counts.handshake_failures >= 1 end)
    connector(c.host, port)
    wait(fn -> up?(:probe_l) end)
  end

  defp raw_client(c, port) do
    {:ok, s} =
      :ssl.connect(
        {127, 0, 0, 1},
        port,
        TLS.connect_options(elem(TLS.credentials(fn -> c.host end), 1)),
        3_000
      )

    s
  end

  defp recv_line(s) do
    {:ok, data} = :ssl.recv(s, 0, 3_000)
    data |> String.split("\n", trim: true) |> hd() |> Codec.decode()
  end

  defp closed?(s) do
    case :ssl.recv(s, 0, 3_000) do
      {:error, :closed} ->
        true

      {:ok, data} ->
        String.contains?(data, "\"bye\"") and match?({:error, _}, :ssl.recv(s, 0, 3_000))

      _ ->
        true
    end
  end

  test "post-TLS identity: a foreign label, a wrong kind and a self-connection close the connection",
       %{c: c} do
    port = listener(c.headless)

    for hello <- [
          Codec.hello("someone-else", "game", Schema.uuid4()),
          Codec.hello("host-t", "headless", Schema.uuid4())
        ] do
      idle(:ep_l)
      s = raw_client(c, port)
      {:ok, {:hello, _}} = recv_line(s)
      :ok = :ssl.send(s, hello)
      assert closed?(s)
    end

    idle(:ep_l)
    s = raw_client(c, port)
    {:ok, {:hello, theirs}} = recv_line(s)
    :ok = :ssl.send(s, Codec.hello("host-t", "game", theirs.boot_id))
    assert closed?(s)
    refute up?(:probe_l)
  end

  test "strict framing after the handshake: early, oversized, malformed and unopened-stream messages close",
       %{c: c} do
    port = listener(c.headless)
    good = Codec.hello("host-t", "game", Schema.uuid4())
    sid = Schema.uuid4()

    sample =
      Codec.encode("pose.sample", %{
        "stream_id" => sid,
        "seq" => 1,
        "src_mono_ms" => 1,
        "pos" => "c2b2fae1,416d47ae,00000000",
        "qualified" => true
      })

    cases = [
      {nil, sample},
      {good, String.duplicate("x", 1_100) <> "\n"},
      {good, "{not json}\n"},
      {good, sample},
      {good,
       (Codec.encode("stream.open", %{
          "stream_id" => sid,
          "source_kind" => "game",
          "interval_ms" => 50,
          "src_clock" => "native"
        }) <> sample)
       |> String.replace("\"seq\":1", "\"seq\":0")}
    ]

    for {hello, msg} <- cases do
      idle(:ep_l)
      s = raw_client(c, port)
      {:ok, {:hello, _}} = recv_line(s)
      if hello, do: :ok = :ssl.send(s, hello)
      :ok = :ssl.send(s, msg)
      assert closed?(s), inspect(msg)
    end
  end

  test "a headless peer may not announce a game source", %{c: c} do
    # here the listener expects a HEADLESS client, and the client announces a game stream
    port =
      listener(c.headless,
        expected: %{label: "host-t", client_kind: "headless"}
      )

    s = raw_client(c, port)
    {:ok, {:hello, _}} = recv_line(s)
    :ok = :ssl.send(s, Codec.hello("host-t", "headless", Schema.uuid4()))
    wait(fn -> up?(:probe_l) end)

    :ok =
      :ssl.send(
        s,
        Codec.encode("stream.open", %{
          "stream_id" => Schema.uuid4(),
          "source_kind" => "game",
          "interval_ms" => 50,
          "src_clock" => "beam"
        })
      )

    assert closed?(s)
    wait(fn -> downs(:probe_l) != [] end)
    assert {:violation, :headless_peer_declared_game_source} in downs(:probe_l)
  end

  test "one connection at a time: a second one is closed before its handshake", %{c: c} do
    port = listener(c.headless)
    connector(c.host, port)
    wait(fn -> up?(:probe_l) end)

    r =
      :ssl.connect(
        {127, 0, 0, 1},
        port,
        TLS.connect_options(elem(TLS.credentials(fn -> c.host end), 1)),
        3_000
      )

    assert match?({:error, _}, r) or closed?(elem(r, 1))
    wait(fn -> Endpoint.status(:ep_l).counts.refused_busy >= 1 end)
  end

  test "B1 binds and connects loopback only (IPv4 any, IPv6 any, a LAN address)", %{c: c} do
    Process.flag(:trap_exit, true)

    for ip <- [
          {0, 0, 0, 0},
          {0, 0, 0, 0, 0, 0, 0, 0},
          {192, 168, 1, 10},
          {0, 0, 0, 0, 0, 0, 0, 1}
        ],
        role <- [:listen, :connect] do
      assert {:error, {:not_loopback, ^ip}} =
               Endpoint.start_link(
                 role: role,
                 ip: ip,
                 port: 0,
                 credentials: fn -> c.headless end,
                 local: %{label: "x", client_kind: "headless"},
                 expected: %{label: "y", client_kind: "game"},
                 handler: {Probe, :none}
               )
    end
  end

  describe "bounded sending" do
    setup %{c: c} do
      port = listener(c.headless)
      connector(c.host, port)
      wait(fn -> up?(:probe_l) and up?(:probe_c) end)
      [{:up, info}] = for {:up, _} = e <- Probe.events(:probe_c), do: e
      %{info: info}
    end

    defp sample(seq),
      do: %{
        "stream_id" => Schema.uuid4(),
        "seq" => seq,
        "src_mono_ms" => seq,
        "src_frame" => nil,
        "pos" => "c2b2fae1,416d47ae,00000000",
        "qualified" => true,
        "reason" => nil
      }

    test "at most 8 samples wait for a connection; older than 100 ms they are dropped as stale",
         %{info: info} do
      :sys.suspend(info.connection)
      results = for i <- 1..10, do: Connection.send_sample(info, sample(i))
      assert Enum.count(results, &(&1 == :ok)) == 8
      assert Enum.count(results, &(&1 == {:error, :backlog})) == 2
      Process.sleep(150)
      :sys.resume(info.connection)
      wait(fn -> Connection.status(info.connection).counts.samples_stale == 8 end)
      assert Connection.status(info.connection).counts.samples_out == 0
      assert Connection.status(info.connection).queued_samples == 0
    end

    test "a sample whose producer's bound is reached before its write is dropped, not written",
         %{info: info} do
      # M7-B1 correction A: a share's sample carries the share's bound (not_after); the connection
      # checks it again immediately before the TLS write
      sid = Schema.uuid4()

      :ok =
        Connection.send_control(info, "stream.open", %{
          "stream_id" => sid,
          "source_kind" => "game",
          "interval_ms" => 50,
          "src_clock" => "native",
          "label" => nil,
          "course" => nil
        })

      wait(fn -> Connection.status(info.connection).counts.controls_out == 1 end)
      :sys.suspend(info.connection)
      t = GlacierRelay.Motion.Clock.now_ms()
      :ok = Connection.send_sample(info, %{sample(1) | "stream_id" => sid}, t + 30)
      Process.sleep(60)
      :sys.resume(info.connection)
      wait(fn -> Connection.status(info.connection).counts.samples_expired == 1 end)
      # control: a sample inside its bound is written (queued after the resume: no stale margin)
      :ok = Connection.send_sample(info, %{sample(2) | "stream_id" => sid}, t + 10_000)
      wait(fn -> Connection.status(info.connection).counts.samples_out == 1 end)
      assert Connection.status(info.connection).counts.samples_stale == 0
    end

    test "a control overflow closes the connection (stop stays possible)", %{info: info} do
      :sys.suspend(info.connection)
      results = for _ <- 1..17, do: Connection.send_control(info, "bye", %{"reason" => "t"})
      assert List.last(results) == {:error, :control_overflow}
      refute Process.alive?(info.connection)
      wait(fn -> conn(:ep_c) == nil end)
    end

    test "a peer that stops reading: the 500 ms send deadline closes the connection", %{
      info: info
    } do
      # the listener side stops reading; this side's TLS sends block once the buffers fill (about
      # 200 KB on loopback); samples above the queue bound are dropped by their producer meanwhile
      %{pid: remote} = conn(:ep_l)
      :sys.suspend(remote)
      ref = Process.monitor(info.connection)
      me = self()

      spawn(fn ->
        dropped =
          Enum.reduce_while(1..2_000_000, 0, fn i, d ->
            cond do
              not Process.alive?(info.connection) -> {:halt, d}
              Connection.send_sample(info, sample(i)) == :ok -> {:cont, d}
              true -> {:cont, d + 1}
            end
          end)

        send(me, {:dropped, dropped})
      end)

      assert_receive {:DOWN, ^ref, :process, _, _}, 60_000
      assert_receive {:dropped, dropped}, 5_000
      assert dropped > 0
      wait(fn -> {:send_failed, :timeout} in downs(:probe_c) end)
      :sys.resume(remote)
    end

    test "three seconds without input close the connection (idle)", %{info: info} do
      %{pid: remote} = conn(:ep_l)
      :sys.suspend(remote)
      ref = Process.monitor(info.connection)
      assert_receive {:DOWN, ^ref, :process, _, _}, 6_000
      :sys.resume(remote)
      wait(fn -> :idle in downs(:probe_c) end)
    end

    test "a handler slower than 200 ms closes the connection", %{info: info} do
      Probe.set_delay(:probe_l, 400)
      sid = Schema.uuid4()

      :ok =
        Connection.send_control(info, "stream.open", %{
          "stream_id" => sid,
          "source_kind" => "game",
          "interval_ms" => 50,
          "src_clock" => "native",
          "label" => nil,
          "course" => nil
        })

      :ok = Connection.send_sample(info, %{sample(1) | "stream_id" => sid})
      wait(fn -> conn(:ep_l) == nil end)
    end
  end
end
