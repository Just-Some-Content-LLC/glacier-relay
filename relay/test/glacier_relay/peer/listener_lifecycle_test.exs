defmodule GlacierRelay.Peer.ListenerLifecycleTest do
  @moduledoc """
  M7-L1 correction: the peer listener's refusal and acceptor lifecycle, for BOTH listeners — B1's
  loopback default (no `:network` option) and the `lan_ipv4` profile — on owned loopback sockets
  with throwaway credentials:

  - a second connection while the legitimate peer is up receives a real TCP closure, bounded,
    with no TLS byte, and the legitimate connection stays identified and keeps carrying data;
  - a handshake that returns an error closes its socket and the acceptor keeps serving (a
    legitimate connection succeeds afterwards); a handshake that takes the documented exit path
    (a private key that does not decode, verifier V3) closes its socket and the acceptor survives;
  - a lost acceptor stops its endpoint (closing its socket and its connection) and nothing
    unrelated; under `HeadlessPeer`'s supervisor only the endpoint is restarted, and it serves;
  - teardown, with a connection up or with a handshake in progress, leaves no acceptor,
    connection, listening or accepted TCP socket on the listener's port behind;
  - the disposable private key appears in none of the channels these tests read: the endpoint's
    `:sys.get_status/1` and `Endpoint.status/1`, its exit reason after an acceptor loss
    (`{:acceptor_exited, :killed}`, the one stop reason exercised), and the formatted log text
    captured during each case at `:debug` level with OTP's SASL reports let through (the
    refusals, both handshake-failure paths with the endpoint's info lines, the acceptor loss with
    its crash report and the endpoint's `State:`, teardown). In log text only the key's byte
    forms are checked: a SASL report legitimately names public_key's `:ECPrivateKey` ASN.1
    decoder in a stack frame. Raw report terms are not checked: OTP's ssl keeps the TLS options,
    the key included, in its connection supervisor's child start arguments, which reach a handler
    only with SASL reports enabled (`handle_sasl_reports` is false in every configuration). No
    other report, dump or diagnostic is covered here.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GlacierRelay.Command.Schema
  alias GlacierRelay.HeadlessPeer
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

  @l %{label: "lc-listener", client_kind: "headless"}
  @c %{label: "lc-initiator", client_kind: "game"}
  # the bound for a refusal's closure as the client sees it (B1's refusal left the connection
  # open: the client's read timed out)
  @closure_ms 1_000

  defp wait(fun, attempts \\ 300), do: FixturePlayer.wait_until(fun, attempts, 10)

  defp listen_address(:loopback), do: [port: 0]
  defp listen_address(:lan_ipv4), do: [network: MotionStack.lan_listen(MotionStack.free_port())]
  defp connect_address(:loopback, port), do: [port: port]
  defp connect_address(:lan_ipv4, port), do: [network: MotionStack.lan_connect(port)]

  # the listener, not restarted by the test supervisor (a stop is observed, never hidden)
  defp listener(mode, creds) do
    start_supervised!({Probe, name: :lc_lprobe}, id: :lc_lprobe)

    ep =
      start_supervised!(
        Supervisor.child_spec(
          {Endpoint,
           [
             role: :listen,
             name: :lc_ep,
             credentials: fn -> creds end,
             local: @l,
             expected: @c,
             handler: {Probe, :lc_lprobe}
           ] ++ listen_address(mode)},
          id: :lc_ep,
          restart: :temporary
        )
      )

    {ep, Endpoint.port(ep)}
  end

  defp connector(mode, creds, port, opts \\ []) do
    start_supervised!({Probe, name: :lc_cprobe}, id: :lc_cprobe)

    start_supervised!(
      Supervisor.child_spec(
        {Endpoint,
         [
           role: :connect,
           name: :lc_cep,
           credentials: fn -> creds end,
           local: @c,
           expected: @l,
           handler: {Probe, :lc_cprobe}
         ] ++ connect_address(mode, port) ++ opts},
        id: :lc_cep,
        restart: :temporary
      )
    )
  end

  defp up(probe),
    do: Enum.find_value(Probe.events(probe), fn ev -> match?({:up, _}, ev) && elem(ev, 1) end)

  defp acceptor(ep), do: :sys.get_state(ep).acceptor

  # the TCP sockets on this test's listener port in this VM — the listen socket, accepted sockets
  # (local port) and clients' (remote port) — never another test's, whose closes are asynchronous
  defp tcp_ports(port) do
    Enum.count(Port.list(), fn p ->
      Port.info(p, :name) == {:name, ~c"tcp_inet"} and
        (match?({:ok, {_, ^port}}, :inet.sockname(p)) or
           match?({:ok, {_, ^port}}, :inet.peername(p)))
    end)
  end

  # a TLS record header and the start of a ClientHello: a client that has begun TLS
  @client_hello_start <<22, 3, 1, 0, 200, 1, 0, 0, 196, 3, 3>>

  # a raw TCP client that starts TLS; returns how its connection ended (`:closed`, or the read's
  # 3 s timeout), every byte it received first, and after how long
  defp raw_attempt(port, send \\ @client_hello_start) do
    t0 = System.monotonic_time(:millisecond)
    {:ok, raw} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    :ok = :gen_tcp.send(raw, send)
    ended = read_end(raw)
    :gen_tcp.close(raw)
    {ended, System.monotonic_time(:millisecond) - t0}
  end

  defp read_end(raw, acc \\ <<>>) do
    case :gen_tcp.recv(raw, 0, 3_000) do
      {:ok, bytes} -> read_end(raw, acc <> bytes)
      {:error, reason} -> {reason, acc}
    end
  end

  defp stream(info, n) do
    id = Schema.uuid4()

    :ok =
      Connection.send_control(info, "stream.open", %{
        "stream_id" => id,
        "source_kind" => "synthetic",
        "interval_ms" => 50,
        "src_clock" => "beam",
        "label" => "M7-L1 correction test (synthetic)",
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
    end

    id
  end

  defp received(probe, id),
    do: for({:sample, _, %{stream_id: ^id, seq: s}} <- Probe.events(probe), do: s)

  # the disposable key's forms: its DER and (an EC key) its private scalar, raw, base64, hex, and the
  # decimal byte lists inspect and ~p / ~w print (the scalar's first twelve bytes)
  defp key_forms(creds) do
    {type, der} = Keyword.fetch!(creds, :key)
    scalar = if type == :ECPrivateKey, do: ec_scalar(der), else: nil
    head = :binary.bin_to_list(binary_part(scalar || der, 0, 12))

    for(
      b <- Enum.reject([der, scalar], &is_nil/1),
      f <- [b, Base.encode64(b), Base.encode16(b, case: :lower), Base.encode16(b)],
      do: f
    ) ++ [Enum.join(head, ", "), Enum.join(head, ",")]
  end

  # a key that does not decode (the exit-path fixture) has no scalar of its own: its DER is checked
  defp ec_scalar(der) do
    elem(:public_key.der_decode(:ECPrivateKey, der), 2)
  rescue
    _ -> nil
  end

  # never prints the material: a failure names the channel only
  defp refute_key(creds, channel, data) do
    text =
      if is_binary(data),
        do: data,
        else: inspect(data, limit: :infinity, printable_limit: :infinity)

    bin = if is_binary(data), do: data, else: :erlang.term_to_binary(data)

    leaked =
      Enum.any?(
        key_forms(creds),
        &(String.contains?(text, &1) or :binary.match(bin, &1) != :nomatch)
      )

    # a term's printed form must not name a private-key record either (the log text may: a SASL
    # report's stack frame names the :ECPrivateKey decoder module)
    refute leaked or (not is_binary(data) and text =~ "PrivateKey"), "key material in #{channel}"
  end

  setup do
    # the log channel at its widest (as Command.AuthorityRedactionTest): :debug, so the endpoint's
    # info lines and a crash report's State: are captured, and OTP's [otp, sasl] reports (the
    # proc_lib crash and supervisor reports) let through for the test's duration; both restored
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
    %{filters: filters} = :logger.get_primary_config()
    {translate, translator_config} = Keyword.fetch!(filters, :logger_translator)
    :ok = :logger.remove_primary_filter(:logger_translator)

    :ok =
      :logger.add_primary_filter(
        :logger_translator,
        {translate, %{translator_config | sasl: true}}
      )

    on_exit(fn ->
      :logger.remove_primary_filter(:logger_translator)
      :logger.add_primary_filter(:logger_translator, {translate, translator_config})
    end)

    %{c: PeerCredentials.pair()}
  end

  for mode <- [:loopback, :lan_ipv4] do
    @mode mode

    test "#{mode}: a second connection while the peer is up is closed at once, before any TLS byte; the peer stays healthy",
         %{c: c} do
      {ep, port} = listener(@mode, c.headless)
      connector(@mode, c.host, port)
      wait(fn -> up(:lc_lprobe) && up(:lc_cprobe) end)
      %{pid: conn, generation: gen} = Endpoint.status(ep).connection

      {{raw, raw_ms}, log1} = with_log(fn -> raw_attempt(port) end)
      # a real closure, no byte received (no ServerHello, no alert), well inside the bound
      assert raw == {:closed, <<>>} and raw_ms < @closure_ms, inspect({raw, raw_ms})

      {:ok, creds} = TLS.credentials(fn -> c.host end)
      t0 = System.monotonic_time(:millisecond)

      {tls, log2} =
        with_log(fn -> :ssl.connect({127, 0, 0, 1}, port, TLS.connect_options(creds), 3_000) end)

      tls_ms = System.monotonic_time(:millisecond) - t0
      assert tls == {:error, :closed} and tls_ms < @closure_ms, inspect({tls, tls_ms})

      wait(fn -> Endpoint.status(ep).counts.refused_busy == 2 end)
      s = Endpoint.status(ep)
      assert s.counts.connections == 1 and s.counts.handshake_failures == 0
      # the legitimate connection: the same process and generation, identified, carrying data
      assert s.connection == %{pid: conn, generation: gen}
      assert Connection.status(conn).phase == :identified
      id = stream(up(:lc_cprobe), 5)
      wait(fn -> received(:lc_lprobe, id) == [1, 2, 3, 4, 5] end)
      refute_key(c.headless, "the log of the refusals", log1 <> log2)
      refute_key(c.headless, "the endpoint's :sys.get_status", :sys.get_status(ep))
      refute_key(c.headless, "Endpoint.status", Endpoint.status(ep))
    end

    test "#{mode}: a handshake that fails closes its socket; the acceptor keeps serving and a legitimate peer connects",
         %{c: c} do
      {ep, port} = listener(@mode, c.headless)
      a = acceptor(ep)
      other = PeerCredentials.pair()

      {_, log} =
        with_log(fn ->
          # garbage instead of a ClientHello: the TLS server's alert, if any, then the closure
          assert {{:closed, _alert}, ms} =
                   raw_attempt(port, String.duplicate("GET / HTTP/1.0\r\n", 4))

          assert ms < @closure_ms

          # a client certificate from a foreign CA (the listener's own verdict)
          {:ok, foreign} =
            TLS.credentials(fn ->
              PeerCredentials.opts(other.host_leaf, c.headless_root, c.headless_leaf)
            end)

          r = :ssl.connect({127, 0, 0, 1}, port, TLS.connect_options(foreign), 3_000)
          assert match?({:error, _}, r) or closed?(elem(r, 1))
          wait(fn -> Endpoint.status(ep).counts.handshake_failures == 2 end)
        end)

      # on the listener's port: its listen socket only; the failed attempts' are closed
      wait(fn -> tcp_ports(port) == 1 end)
      assert log =~ "peer endpoint: handshake refused ("
      assert acceptor(ep) == a and Process.alive?(a)
      connector(@mode, c.host, port)
      wait(fn -> up(:lc_lprobe) end)
      assert Endpoint.status(ep).counts.connections == 1
      refute_key(c.headless, "the log of the failed handshakes", log)
    end

    test "#{mode}: a handshake that exits (a key that does not decode) closes its socket; the acceptor survives",
         %{c: c} do
      {_t, der} = c.headless[:key]
      bad = Keyword.put(c.headless, :key, {:ECPrivateKey, binary_part(der, 0, 60)})
      {ep, port} = listener(@mode, bad)
      a = acceptor(ep)
      {:ok, creds} = TLS.credentials(fn -> c.host end)

      {_, log} =
        with_log(fn ->
          for n <- 1..2 do
            t0 = System.monotonic_time(:millisecond)
            r = :ssl.connect({127, 0, 0, 1}, port, TLS.connect_options(creds), 3_000)
            ms = System.monotonic_time(:millisecond) - t0
            assert match?({:error, _}, r) and ms < @closure_ms, inspect({r, ms})
            wait(fn -> Endpoint.status(ep).counts.handshake_failures == n end)
          end
        end)

      assert acceptor(ep) == a and Process.alive?(a) and Process.alive?(ep)
      wait(fn -> tcp_ports(port) == 1 end)
      assert log =~ "peer endpoint: handshake refused ("
      # the truncated key, and the whole key it was cut from (its scalar lies inside the cut)
      for creds <- [bad, c.headless] do
        refute_key(creds, "the log of the exiting handshakes", log)
        refute_key(creds, "the endpoint's :sys.get_status", :sys.get_status(ep))
      end
    end

    test "#{mode}: a lost acceptor stops its endpoint, its socket and its connection — nothing unrelated",
         %{c: c} do
      {ep, port} = listener(@mode, c.headless)
      cep = connector(@mode, c.host, port)
      wait(fn -> up(:lc_lprobe) && up(:lc_cprobe) end)
      %{pid: conn} = Endpoint.status(ep).connection
      probe = Process.whereis(:lc_lprobe)
      refs = Map.new([ep: ep, conn: conn], fn {k, p} -> {Process.monitor(p), k} end)

      {_, log} =
        with_log(fn ->
          Process.exit(acceptor(ep), :kill)

          downs =
            for _ <- 1..2, into: %{} do
              assert_receive {:DOWN, ref, :process, _, reason}, 2_000
              {Map.fetch!(refs, ref), reason}
            end

          assert downs.ep == {:acceptor_exited, :killed}
          refute_key(c.headless, "the endpoint's exit reason", downs)
        end)

      assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary], 1_000)

      # unrelated: the listener's handler, the other side's endpoint (which saw its connection end)
      assert Process.alive?(probe) and Process.alive?(cep)
      wait(fn -> Endpoint.status(cep).connection == nil end)
      # the crash report, with the endpoint's (redacted) state, is in the text checked
      assert log =~ "{:acceptor_exited, :killed}" and log =~ "State:"
      refute_key(c.headless, "the log of the acceptor loss (with the crash report)", log)
    end

    test "#{mode}: under HeadlessPeer's supervisor a lost acceptor restarts the endpoint only, which serves again",
         %{c: c} do
      port = MotionStack.free_port()

      address =
        if @mode == :loopback,
          do: [port: port],
          else: [network: MotionStack.lan_listen(port)]

      dir =
        Path.join(System.tmp_dir!(), "glacier-relay-m7l1c-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      start_supervised!(
        {HeadlessPeer,
         address ++
           [
             credentials: fn -> c.headless end,
             label: "lc-listener",
             expected: @c,
             trace_dir: dir
           ]}
      )

      ep = Process.whereis(HeadlessPeer.endpoint())
      siblings = Enum.map([HeadlessPeer.trace(), HeadlessPeer.Driver], &Process.whereis/1)

      capture_log(fn ->
        Process.exit(acceptor(ep), :kill)

        wait(fn ->
          (p = Process.whereis(HeadlessPeer.endpoint())) != nil and p != ep and
            Endpoint.port(p) == port
        end)
      end)

      assert Enum.map([HeadlessPeer.trace(), HeadlessPeer.Driver], &Process.whereis/1) == siblings
      connector(@mode, c.host, port)
      wait(fn -> HeadlessPeer.Driver.status().peer != nil end)
    end

    test "#{mode}: teardown with a connection up leaves no acceptor, connection or socket of the endpoint",
         %{c: c} do
      {ep, port} = listener(@mode, c.headless)
      cep = connector(@mode, c.host, port)
      wait(fn -> up(:lc_lprobe) && up(:lc_cprobe) end)
      owned = [acceptor(ep), Endpoint.status(ep).connection.pid]
      refs = Enum.map(owned, &Process.monitor/1)

      {_, log} =
        with_log(fn ->
          stop_supervised!(:lc_ep)

          for ref <- refs,
              do: assert_receive({:DOWN, ^ref, :process, _, _}, 1_000)
        end)

      assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary], 1_000)
      wait(fn -> Endpoint.status(cep).connection == nil end)
      stop_supervised!(:lc_cep)
      # nothing of either endpoint is left on the listener's port
      wait(fn -> tcp_ports(port) == 0 end)
      refute_key(c.headless, "the log of the teardown", log)
    end

    test "#{mode}: teardown during a handshake ends it at once (it does not wait out its 5 s deadline)",
         %{c: c} do
      {ep, port} = listener(@mode, c.headless)
      a = acceptor(ep)
      # an admitted client that has begun TLS and then says nothing more: the acceptor waits in
      # its handshake
      {:ok, raw} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
      :ok = :gen_tcp.send(raw, @client_hello_start)
      # the acceptor waits on the TLS connection process doing its handshake (it monitors it)
      wait(fn ->
        {:monitors, ms} = Process.info(a, :monitors)
        Enum.any?(ms, &match?({:process, p} when p != ep, &1))
      end)

      ref = Process.monitor(a)
      t0 = System.monotonic_time(:millisecond)
      # a normal stop (not a supervisor's :shutdown, whose exit signal would also reach the linked
      # acceptor): the endpoint's own teardown must end the handshake
      :ok = GenServer.stop(ep)
      assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
      # the admitted client's connection is closed by the endpoint's teardown, well before the
      # handshake's own deadline
      # (the TLS connection process may send its user_canceled alert first)
      assert {:closed, _alert} = read_end(raw)
      assert System.monotonic_time(:millisecond) - t0 < @closure_ms
      :gen_tcp.close(raw)
      wait(fn -> tcp_ports(port) == 0 end)
    end
  end

  # a TLS 1.3 client may see its handshake "succeed" before the server's verdict on its
  # certificate arrives; the server's alert then closes it at the first read
  defp closed?(socket) do
    r = :ssl.recv(socket, 0, 2_000)
    :ssl.close(socket)
    match?({:error, _}, r)
  end
end
