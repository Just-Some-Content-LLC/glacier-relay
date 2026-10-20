defmodule GlacierRelay.Peer.NetworkEndpointTest do
  @moduledoc """
  M7-L1: the `lan_ipv4` profile's endpoints on owned loopback sockets (design section 20), in this
  VM with throwaway credentials: a TLS 1.3 round trip and one finite synthetic stream each way
  between two headless endpoints (the L2 shape: the initiator connects out, the other listens);
  the listener bound to exactly the declared socket; a connection from an address other than the
  initiator closed before its handshake; the unchanged authentication refusals under the profile; a
  bound-port conflict failing closed; no reconnect unless asked and a fresh boot after a restart;
  no private key in any status. Only `127.0.0.1` (and, as a refused source, `127.0.0.2`) is used.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.Command.Schema
  alias GlacierRelay.Peer.{Connection, Endpoint, TLS}
  alias GlacierRelay.Test.{FixturePlayer, MotionStack, PeerCredentials}

  defmodule Probe do
    @moduledoc false
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    def peer_event(server, event, timeout), do: GenServer.call(server, {:event, event}, timeout)
    def peer_notify(server, event), do: GenServer.cast(server, {:notify, event})
    def events(server), do: GenServer.call(server, :events)
    @impl true
    def init(_), do: {:ok, []}
    @impl true
    def handle_call({:event, ev}, _from, st), do: {:reply, :ok, [ev | st]}
    def handle_call(:events, _from, st), do: {:reply, Enum.reverse(st), st}
    @impl true
    def handle_cast({:notify, ev}, st), do: {:noreply, [ev | st]}
  end

  @l %{label: "l1-listener", client_kind: "headless"}
  @c %{label: "l1-initiator", client_kind: "headless"}

  defp wait(fun, attempts \\ 300), do: FixturePlayer.wait_until(fun, attempts, 10)

  defp listener(creds, port, opts \\ []) do
    start_supervised!({Probe, name: :nl_probe}, id: :nl_probe)

    start_supervised!(
      {Endpoint,
       Keyword.merge(
         [
           role: :listen,
           name: :nl_ep,
           network: MotionStack.lan_listen(port),
           credentials: fn -> creds end,
           local: @l,
           expected: @c,
           handler: {Probe, :nl_probe}
         ],
         opts
       )},
      id: :nl_ep
    )
  end

  defp initiator(creds, port, opts \\ []) do
    start_supervised!({Probe, name: :nc_probe}, id: :nc_probe)

    start_supervised!(
      {Endpoint,
       Keyword.merge(
         [
           role: :connect,
           name: :nc_ep,
           network: MotionStack.lan_connect(port),
           credentials: fn -> creds end,
           local: @c,
           expected: @l,
           handler: {Probe, :nc_probe}
         ],
         opts
       )},
      id: :nc_ep
    )
  end

  defp up(probe),
    do: Enum.find_value(Probe.events(probe), fn ev -> match?({:up, _}, ev) && elem(ev, 1) end)

  defp downs(probe), do: for({:down, _info, reason} <- Probe.events(probe), do: reason)

  defp stream(info, n) do
    id = Schema.uuid4()

    :ok =
      Connection.send_control(info, "stream.open", %{
        "stream_id" => id,
        "source_kind" => "synthetic",
        "interval_ms" => 50,
        "src_clock" => "beam",
        "label" => "M7-L1 loopback test (synthetic)",
        "course" => nil
      })

    for seq <- 1..n do
      :ok =
        Connection.send_sample(info, %{
          "stream_id" => id,
          "seq" => seq,
          "src_mono_ms" => seq * 50,
          "src_frame" => nil,
          "pos" => "00000000,00000000,00000000",
          "qualified" => true,
          "reason" => nil
        })

      Process.sleep(5)
    end

    :ok =
      Connection.send_control(info, "stream.end", %{
        "stream_id" => id,
        "reason" => "test_complete",
        "last_seq" => n,
        "sent" => n
      })

    id
  end

  defp received(probe, id) do
    evs = Probe.events(probe)

    open =
      Enum.count(evs, &match?({:stream_open, _, %{stream_id: ^id, source_kind: "synthetic"}}, &1))

    seqs = for {:sample, _, %{stream_id: ^id, seq: s}} <- evs, do: s
    ended = for {:stream_end, _, %{stream_id: ^id} = f} <- evs, do: {f.last_seq, f.sent}
    {open, seqs, ended}
  end

  setup do
    %{c: PeerCredentials.pair(), port: MotionStack.free_port()}
  end

  test "headless to headless under the profile: TLS 1.3, both identified, one finite stream each way",
       %{c: c, port: port} do
    listener(c.headless, port)
    initiator(c.host, port)
    wait(fn -> up(:nl_probe) && up(:nc_probe) end)
    li = up(:nl_probe)
    ci = up(:nc_probe)
    assert li.label == "l1-initiator" and li.client_kind == "headless" and li.generation == 1
    assert ci.label == "l1-listener" and ci.client_kind == "headless" and ci.generation == 1

    {:ok, [protocol: :"tlsv1.3"]} =
      :ssl.connection_information(:sys.get_state(li.connection).socket, [:protocol])

    out = stream(ci, 20)
    back = stream(li, 20)

    wait(fn ->
      match?({1, _, [_]}, received(:nl_probe, out)) and
        match?({1, _, [_]}, received(:nc_probe, back))
    end)

    assert {1, Enum.to_list(1..20), [{20, 20}]} == received(:nl_probe, out)
    assert {1, Enum.to_list(1..20), [{20, 20}]} == received(:nc_probe, back)

    assert %{
             role: :listen,
             address: {{127, 0, 0, 1}, ^port},
             network: "lan_ipv4 127.0.0.1:" <> _,
             counts: %{connections: 1, refused_address: 0, handshake_failures: 0}
           } = Endpoint.status(:nl_ep)

    assert %{role: :connect, address: {{127, 0, 0, 1}, ^port}, counts: %{connections: 1}} =
             Endpoint.status(:nc_ep)

    cs = Connection.status(li.connection)
    assert cs.counts.samples_in == 20 and cs.counts.samples_out == 20
  end

  test "the listener binds exactly the declared socket (no wildcard listener)", %{
    c: c,
    port: port
  } do
    listener(c.headless, port)
    {out, 0} = System.cmd("ss", ["-H", "-ltn"])
    lines = out |> String.split("\n", trim: true) |> Enum.filter(&(&1 =~ ":#{port} "))
    assert [line] = lines, inspect(lines)
    assert Enum.at(String.split(line), 3) == "127.0.0.1:#{port}"
  end

  test "a connection from an address other than the initiator is closed before its TLS handshake",
       %{c: c, port: port} do
    listener(c.headless, port)

    {:ok, raw} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, ip: {127, 0, 0, 2}], 1_000)

    assert {:error, :closed} = :gen_tcp.recv(raw, 0, 2_000)
    wait(fn -> Endpoint.status(:nl_ep).counts.refused_address == 1 end)
    assert Endpoint.status(:nl_ep).counts.handshake_failures == 0

    # a TLS client from the wrong source address gets no handshake either
    {:ok, creds} = TLS.credentials(fn -> c.host end)

    assert {:error, _} =
             :ssl.connect(
               {127, 0, 0, 1},
               port,
               TLS.connect_options(creds) ++ [ip: {127, 0, 0, 2}],
               2_000
             )

    wait(fn -> Endpoint.status(:nl_ep).counts.refused_address == 2 end)
    refute up(:nl_probe)
    # the listener keeps serving the declared initiator
    initiator(c.host, port)
    wait(fn -> up(:nl_probe) end)
  end

  test "one connection at a time: a second one is closed at once, before any TLS byte",
       %{c: c, port: port} do
    listener(c.headless, port)
    initiator(c.host, port)
    wait(fn -> up(:nl_probe) end)
    {:ok, raw} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    assert {:error, :closed} = :gen_tcp.recv(raw, 0, 2_000)
    wait(fn -> Endpoint.status(:nl_ep).counts.refused_busy == 1 end)
    assert Endpoint.status(:nl_ep).counts.connections == 1
    assert Endpoint.status(:nl_ep).counts.handshake_failures == 0
  end

  test "authentication is unchanged under the profile: pins, CAs and the hello identity",
       %{c: c, port: port} do
    listener(c.headless, port)
    other = PeerCredentials.pair()

    # the initiator pins a different leaf: it refuses the listener's certificate
    initiator(Keyword.put(c.host, :peer_pin, TLS.pin(other.headless_leaf.cert)), port)
    wait(fn -> Endpoint.status(:nc_ep).counts.connect_failures >= 1 end)
    refute up(:nl_probe) || up(:nc_probe)
    stop_supervised!(:nc_ep)
    stop_supervised!(:nc_probe)

    # a client certificate from a foreign CA, the initiator otherwise trusting and pinning the right
    # listener (verifier V8): the listener itself refuses the client's certificate
    initiator(PeerCredentials.opts(other.host_leaf, c.headless_root, c.headless_leaf), port)
    wait(fn -> Endpoint.status(:nl_ep).counts.handshake_failures >= 1 end)
    refute up(:nl_probe)
    stop_supervised!(:nc_ep)
    stop_supervised!(:nc_probe)

    # a client leaf from the right CA that is not the pinned one: refused by the listener's pin
    unpinned = PeerCredentials.leaf(c.host_root)
    initiator(PeerCredentials.opts(unpinned, c.headless_root, c.headless_leaf), port)
    wait(fn -> Endpoint.status(:nl_ep).counts.handshake_failures >= 2 end)
    refute up(:nl_probe)
    stop_supervised!(:nc_ep)
    stop_supervised!(:nc_probe)

    # the right credentials and a wrong label: the hello closes it
    initiator(c.host, port, local: %{label: "someone-else", client_kind: "headless"})
    wait(fn -> downs(:nc_probe) != [] or Endpoint.status(:nl_ep).counts.connections >= 1 end)
    wait(fn -> Endpoint.status(:nl_ep).connection == nil end)
    refute up(:nl_probe)
  end

  test "under the profile a client with no certificate, and a TLS 1.2 client, are refused at the handshake",
       %{c: c, port: port} do
    listener(c.headless, port)
    {:ok, creds} = TLS.credentials(fn -> c.host end)
    no_cert = Keyword.drop(TLS.connect_options(creds), [:cert, :key])

    r1 = :ssl.connect({127, 0, 0, 1}, port, no_cert, 3_000)
    assert match?({:error, _}, r1) or closed?(elem(r1, 1))
    wait(fn -> Endpoint.status(:nl_ep).counts.handshake_failures >= 1 end)

    tls12 =
      Keyword.merge(TLS.connect_options(creds),
        versions: [:"tlsv1.2"],
        ciphers: :ssl.cipher_suites(:default, :"tlsv1.2")
      )

    assert {:error, _} = :ssl.connect({127, 0, 0, 1}, port, tls12, 3_000)
    wait(fn -> Endpoint.status(:nl_ep).counts.handshake_failures >= 2 end)
    assert Endpoint.status(:nl_ep).counts.connections == 0
    refute up(:nl_probe)
  end

  # a TLS 1.3 client may see its handshake "succeed" before the server's verdict on its (missing)
  # certificate arrives; the server's alert then closes it at the first read
  defp closed?(socket) do
    case :ssl.recv(socket, 0, 2_000) do
      {:error, _} -> true
      _ -> false
    end
  end

  test "a handshake that exits (a key that does not decode) leaves the acceptor serving; non-initiators are still closed",
       %{c: c, port: port} do
    {_t, der} = c.headless[:key]
    bad = Keyword.put(c.headless, :key, {:ECPrivateKey, binary_part(der, 0, 60)})
    listener(bad, port)
    acceptor = :sys.get_state(:nl_ep).acceptor
    {:ok, creds} = TLS.credentials(fn -> c.host end)
    assert {:error, _} = :ssl.connect({127, 0, 0, 1}, port, TLS.connect_options(creds), 3_000)
    wait(fn -> Endpoint.status(:nl_ep).counts.handshake_failures >= 1 end)
    assert Process.alive?(acceptor)

    {:ok, raw} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, ip: {127, 0, 0, 2}], 1_000)

    assert {:error, :closed} = :gen_tcp.recv(raw, 0, 2_000)
    wait(fn -> Endpoint.status(:nl_ep).counts.refused_address == 1 end)
  end

  @tag :capture_log
  test "a profile listener whose acceptor dies stops and closes its socket", %{c: c, port: port} do
    Process.flag(:trap_exit, true)

    {:ok, ep} =
      Endpoint.start_link(
        role: :listen,
        network: MotionStack.lan_listen(port),
        credentials: fn -> c.headless end,
        local: @l,
        expected: @c,
        handler: {Probe, :none}
      )

    acceptor = :sys.get_state(ep).acceptor
    Process.exit(acceptor, :kill)
    assert_receive {:EXIT, ^ep, {:acceptor_exited, :killed}}, 2_000
    assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary], 1_000)
  end

  test "a bound-port conflict fails closed; nothing else is tried", %{c: c, port: port} do
    Process.flag(:trap_exit, true)
    {:ok, hold} = :gen_tcp.listen(port, ip: {127, 0, 0, 1})

    assert {:error, {:listen_failed, :eaddrinuse}} =
             Endpoint.start_link(
               role: :listen,
               network: MotionStack.lan_listen(port),
               credentials: fn -> c.headless end,
               local: @l,
               expected: @c,
               handler: {Probe, :none}
             )

    :gen_tcp.close(hold)
  end

  test "no reconnect unless asked; a restart is a fresh boot at generation 1", %{c: c, port: port} do
    listener(c.headless, port)
    initiator(c.host, port)
    wait(fn -> up(:nc_probe) end)
    boot1 = up(:nc_probe).boot_id
    stop_supervised!(:nl_ep)
    wait(fn -> Endpoint.status(:nc_ep).connection == nil end)
    Process.sleep(1_200)
    assert Endpoint.status(:nc_ep).counts.connect_failures == 0
    assert Endpoint.status(:nc_ep).counts.connections == 1

    stop_supervised!(:nl_probe)
    listener(c.headless, port)
    # nothing connects on its own: the initiator was not asked to reconnect
    Process.sleep(300)
    refute up(:nl_probe)
    Endpoint.connect(:nc_ep)
    wait(fn -> up(:nl_probe) end)
    assert Endpoint.status(:nc_ep).counts.connections == 2
    li = up(:nl_probe)
    # the listener is a new endpoint: its first connection, and a fresh boot of its own
    assert li.generation == 1
    wait(fn -> length(for({:up, _} <- Probe.events(:nc_probe), do: 1)) == 2 end)
    [^boot1, boot2] = for {:up, i} <- Probe.events(:nc_probe), do: i.boot_id
    assert boot2 != boot1
  end

  test "B1's loopback listener: the TLS listen socket (it embeds the key) is redacted from its status",
       %{c: c} do
    start_supervised!(
      {Endpoint,
       role: :listen,
       name: :b1_ep,
       port: 0,
       credentials: fn -> c.headless end,
       local: @l,
       expected: @c,
       handler: {Probe, :none}}
    )

    {_, key} = Keyword.fetch!(c.headless, :key)
    # the socket itself does hold the key (OTP keeps the TLS options in the listen socket's term)
    assert :binary.match(:erlang.term_to_binary(:sys.get_state(:b1_ep).listen_socket), key) !=
             :nomatch

    status = :sys.get_status(:b1_ep)
    assert :binary.match(:erlang.term_to_binary(status), key) == :nomatch
    refute inspect(status, limit: :infinity) =~ "PrivateKey"
  end

  test "no private key or key material in either side's status", %{c: c, port: port} do
    listener(c.headless, port)
    initiator(c.host, port)
    wait(fn -> up(:nl_probe) && up(:nc_probe) end)
    {_, host_key} = Keyword.fetch!(c.host, :key)
    {_, headless_key} = Keyword.fetch!(c.headless, :key)

    for ep <- [:nl_ep, :nc_ep] do
      text =
        inspect(Endpoint.status(ep), limit: :infinity) <>
          inspect(:sys.get_status(ep), limit: :infinity) <>
          inspect(Connection.status(Endpoint.status(ep).connection.pid), limit: :infinity)

      refute text =~ "PrivateKey"
      refute text =~ inspect(host_key, limit: :infinity)
      refute text =~ inspect(headless_key, limit: :infinity)
      refute text =~ Base.encode64(host_key) or text =~ Base.encode64(headless_key)
    end
  end
end
