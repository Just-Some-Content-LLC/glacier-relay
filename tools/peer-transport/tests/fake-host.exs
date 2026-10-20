# M7-L3 — a STAND-IN game host for game-peer.exs's focused tests (tests/game-peer-test.sh), on loopback only. NOT the relay's game
# host: no Motion.Hub, no authority, no native. It is the peer protocol's game-kind connector, built from the relay's own
# Peer.Endpoint / Connection (connect role, the lan_ipv4 profile on 127.0.0.1, one attempt, no reconnection), with a small handler
# that records what the game-facing peer sends. It can send one labelled share-like stream (source_kind game, src_clock native),
# as Motion.Source's stream.open does; its positions are test values, never a real player's. Driven over standard input, one JSON
# request per line; it answers "@@<json>" lines on standard output and halts when standard input closes.
#   elixir -pa <bundle>/ebin/glacier_relay tests/fake-host.exs <port> <cert> <key> <peer_ca> <peer_pin> <label> <expected_label>
#   requests: {"op":"wait_up","ms":N} | {"op":"share","n":N,"end":bool} | {"op":"wait_course","ms":N} | {"op":"close"} | {"op":"status"}
alias GlacierRelay.Peer.{Connection, Endpoint}
alias GlacierRelay.Command.TransformWords

defmodule FakeHost do
  use GenServer
  def start_link, do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def peer_event(server, event, timeout), do: GenServer.call(server, {:peer, event}, timeout)
  def peer_notify(server, event), do: GenServer.cast(server, {:notify, event})
  def get, do: GenServer.call(__MODULE__, :get)

  @impl true
  def init(_), do: {:ok, %{info: nil, streams: %{}, ended: [], down: nil}}
  @impl true
  def handle_call(:get, _f, s), do: {:reply, s, s}
  def handle_call({:peer, {:up, info}}, _f, s), do: {:reply, :ok, %{s | info: info}}
  def handle_call({:peer, {:stream_open, _i, f}}, _f, s), do: {:reply, :ok, put_in(s.streams[f.stream_id], %{open: f, samples: []})}
  def handle_call({:peer, {:sample, _i, f}}, _f, s), do: {:reply, :ok, update_in(s.streams[f.stream_id].samples, &[f | &1])}
  def handle_call({:peer, {:stream_end, _i, f}}, _f, s), do: {:reply, :ok, %{s | ended: [f | s.ended]}}
  def handle_call({:peer, _other}, _f, s), do: {:reply, :ok, s}
  @impl true
  def handle_cast({:notify, {:down, _info, reason}}, s), do: {:noreply, %{s | down: inspect(reason), info: nil}}
  def handle_cast({:notify, _}, s), do: {:noreply, s}
end

[port, cert, key, ca, pin, label, expected] = System.argv()
:logger.remove_handler(:default)
{:ok, _} = Application.ensure_all_started(:ssl)
{:ok, _} = FakeHost.start_link()
{:ok, ep} =
  Endpoint.start_link(
    role: :connect,
    network: [profile: :lan_ipv4, prefix_length: 24, connect: {"127.0.0.1", String.to_integer(port)}],
    credentials: [cert_file: cert, key_file: key, peer_ca_file: ca, peer_pin: pin],
    local: %{label: label, client_kind: "game"},
    expected: %{label: expected, client_kind: "headless"},
    handler: {FakeHost, FakeHost}
  )

emit = fn m -> IO.puts("@@" <> JSON.encode!(m)) end
wait = fn fun, ms -> Enum.find_value(1..max(div(ms, 20), 1), false, fn _ -> fun.() || (Process.sleep(20) && false) end) end
emit.(%{"event" => "ready", "os_pid" => System.pid(), "distributed" => Node.alive?()})

loop = fn loop ->
  case IO.gets("") do
    line when is_binary(line) ->
      r = JSON.decode!(line)
      res =
        case r["op"] do
          "wait_up" -> %{"up" => wait.(fn -> FakeHost.get().info != nil end, r["ms"])}
          "share" ->
            info = FakeHost.get().info
            id = GlacierRelay.Command.Schema.uuid4()
            :ok = Connection.send_control(info, "stream.open", %{"stream_id" => id, "source_kind" => "game", "interval_ms" => 50, "src_clock" => "native", "label" => "fake host share (test values)", "course" => nil})
            for k <- 1..r["n"] do
              pos = TransformWords.encode([TransformWords.to_word(-83.5 + k * 0.01), TransformWords.to_word(15.0), TransformWords.to_word(-1.52)])
              :ok = Connection.send_sample(info, %{"stream_id" => id, "seq" => k, "src_mono_ms" => 1000 + k * 50, "src_frame" => 100 + k, "pos" => pos, "qualified" => true, "reason" => nil})
              Process.sleep(50)
            end
            if r["end"], do: :ok = Connection.send_control(info, "stream.end", %{"stream_id" => id, "reason" => "duration", "last_seq" => r["n"], "sent" => r["n"]})
            %{"stream_id" => id, "sent" => r["n"], "ended" => r["end"]}
          "wait_course" ->
            ended = wait.(fn -> FakeHost.get().ended != [] end, r["ms"])
            s = FakeHost.get()
            case Map.values(s.streams) do
              [st] ->
                ss = Enum.reverse(st.samples)
                lines = Enum.map_join(ss, fn x -> [xw, yw, _] = String.split(x.pos, ","); "#{x.seq}\t#{(x.seq - 1) * 50}\t#{xw},#{yw}\n" end)
                %{"ended" => ended != false, "open" => Map.new(st.open, fn {k, v} -> {to_string(k), v} end), "received" => length(ss),
                  "seqs_contiguous" => Enum.map(ss, & &1.seq) == Enum.to_list(1..length(ss)), "digest" => Base.encode16(:crypto.hash(:sha256, lines), case: :lower),
                  "stream_end" => s.ended |> List.first() |> then(&(&1 && Map.new(&1, fn {k, v} -> {to_string(k), v} end)))}
              other -> %{"ended" => false, "streams" => length(other)}
            end
          "close" ->
            case FakeHost.get().info do
              nil -> %{"closed" => false}
              info -> Connection.close(info, :run_complete); %{"closed" => true}
            end
          "status" -> %{"endpoint" => inspect(Endpoint.status(ep) |> Map.take([:counts, :connection])), "down" => FakeHost.get().down}
        end
      emit.(Map.put(res, "id", r["id"]))
      loop.(loop)
    _ -> System.halt(0)
  end
end

loop.(loop)
