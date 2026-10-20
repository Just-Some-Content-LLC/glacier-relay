# M7-L1 — the transport-only peer launcher (operator tooling; docs/design/M7_NETWORK_GHOST.md section 20; README.md here).
#
#   elixir -pa <bundle>/ebin/glacier_relay <bundle>/kit/peer.exs <run-config.json> <run-config-sha256>
#
# ONE non-distributed BEAM process (nonode@nohost; no --sname, no epmd, no Erlang distribution) running ONE headless peer
# (GlacierRelay.HeadlessPeer) in the role its approved run configuration names — `listen` (the MacBook in M7-L2) or `connect`
# (the Windows host, outbound only) — for ONE finite synthetic exchange: once the peer is identified, each side sends one labelled
# synthetic course (source_kind synthetic), records the other side's course in its sink, and nothing it receives is ever sent
# anywhere. No game, no native, no command authority, no token, no motion link, no dashboard: the relay application is never started.
#
# Before ANY socket, and before :ssl starts, every input is checked and a failure refuses with exit 2:
#   - this node is not distributed;
#   - FIRST, before anything is decoded: the files under the bundle are exactly those its MANIFEST.sha256 lists, each with its
#     listed sha256 (code and kit identity; an unlisted file — a stray module that -pa would load first — is refused);
#   - the run configuration's bytes match the sha256 given on the command line (the approved, pinned configuration);
#   - its schema, the role and the network profile (GlacierRelay.Peer.Network: lan_ipv4, one concrete private IPv4 socket);
#   - the bundle manifest's sha256 is the configuration's pin;
#   - the runtime matches the configuration's pin (OTP release, Elixir version prefix);
#   - the credential files exist, the private key file is 0600, and the credentials load (the key decodes);
#   - when the configuration names an approval record: its verbatim operator reply is a standalone approval form (the WHOLE reply,
#     trimmed, equals one accepted form — never an occurrence inside a longer message), it names this configuration's and this
#     bundle's sha256, and it is not older than its maximum age;
#   - the output directory does not exist (it is created exclusively; nothing is ever overwritten).
# Then :ssl starts (no socket) and its TLS 1.3 support is checked (exit 2), still before the output directory exists. A SIGTERM
# trap is installed first of all, so a stop at any point ends through the run loop with its summary. Then: outputs <out>/peer.pid, <out>/events.ndjson, <out>/trace/ (the headless motion trace), <out>/summary.json; human lines on
# standard output. "Complete" means transport completeness: every inbound stream ended with everything its source reports having
# sent received, in order, with no duplicate or older sample; a sequence gap is a sample that SOURCE skipped itself (its 45 ms
# spacing, or a full queue: the other side's summary counts them as spaced / dropped), reconciled across the two summaries — not a
# loss. The run ends by itself: exchange complete (exit 0), no peer / lifetime expired (3), the connection lost before
# completion or identification (4), completed but not reconciled (5), stopped by SIGTERM (stop.sh; 6, after its summary), the
# endpoint could not start — e.g. the declared address or port not available (7, after its summary); a hard backstop halts at
# lifetime + 15 s (124). A connector retries its one
# destination every second only until a first connection is registered (within connect_window_s, counted by the endpoint itself);
# after a connection ends — identified or not — the run ends and never reconnects.
# No private key, CA key or certificate body is ever printed or written by this script.

alias GlacierRelay.HeadlessPeer
alias GlacierRelay.HeadlessPeer.Driver
alias GlacierRelay.Motion.Course
alias GlacierRelay.Peer.{Connection, Endpoint, Network, TLS}

defmodule PeerKit do
  @moduledoc false
  @schema "glacier-relay.peer-transport-run/1"
  @approval_schema "glacier-relay.peer-transport-approval/1"
  @top ~w(schema run_id side role network label expected_label credentials course limits out_dir bundle runtime approval)
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @id ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/

  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  def say(msg), do: IO.puts("#{now()} peer-kit: #{msg}")

  def refuse(msg) do
    IO.puts("#{now()} peer-kit: REFUSED (before any socket; ssl started: #{ssl_started?()}): #{msg}")
    System.halt(2)
  end

  def ssl_started?, do: Enum.any?(Application.started_applications(), fn {a, _, _} -> a == :ssl end)

  # everything the source reports having sent arrived, in order, nothing twice (the gaps are its own skips; see the header)
  def transport_complete?(s) do
    r = s.reconciliation
    r["received"] == r["source_sent"] and r["last_seq_received"] == r["source_last_seq"] and s.duplicate == 0 and s.older == 0
  end

  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  def text?(v, max), do: is_binary(v) and String.valid?(v) and byte_size(v) in 1..max and not String.contains?(v, ["\n", "\r"])

  # -- configuration ------------------------------------------------------------------------------------------------------------
  def config(path, expected_sha) do
    unless Regex.match?(@hex64, expected_sha), do: refuse("the configuration sha256 argument is not 64 lowercase hex characters")
    bytes = case File.read(path), do: ({:ok, b} -> b; {:error, r} -> refuse("cannot read the run configuration #{path}: #{inspect(r)}"))
    got = sha256(bytes)
    unless got == expected_sha, do: refuse("the run configuration's sha256 is #{got}, not the approved #{expected_sha}")

    cfg =
      try do
        JSON.decode!(bytes)
      rescue
        _ -> refuse("the run configuration is not JSON")
      end

    unless is_map(cfg), do: refuse("the run configuration is not a JSON object")
    case Map.keys(cfg) -- @top, do: ([] -> :ok; extra -> refuse("unknown configuration keys #{inspect(extra)}"))
    unless cfg["schema"] == @schema, do: refuse("schema must be #{@schema}")
    unless is_binary(cfg["run_id"]) and Regex.match?(@id, cfg["run_id"]), do: refuse("run_id must match #{inspect(@id.source)}")
    for k <- ~w(side label expected_label), not text?(cfg[k], 64), do: refuse("#{k} must be a single-line text of 1-64 bytes")
    role = case cfg["role"], do: ("listen" -> :listen; "connect" -> :connect; other -> refuse("role must be listen or connect, not #{inspect(other)}"))
    {cfg, bytes, role}
  end

  # the profile, mapped key by key (never String.to_atom on input), then judged by Peer.Network itself
  def network(%{"profile" => "lan_ipv4"} = n, role, local) do
    allowed = ~w(profile prefix_length listen connect initiator)
    case Map.keys(n) -- allowed, do: ([] -> :ok; extra -> refuse("unknown network keys #{inspect(extra)}"))
    socket = fn
      [ip, port] -> {ip, port}
      other -> other
    end

    net =
      [profile: :lan_ipv4, prefix_length: n["prefix_length"]] ++
        if(Map.has_key?(n, "listen"), do: [listen: socket.(n["listen"])], else: []) ++
        if(Map.has_key?(n, "initiator"), do: [initiator: n["initiator"]], else: []) ++
        if(Map.has_key?(n, "connect"), do: [connect: socket.(n["connect"])], else: [])

    case Network.plan(role: role, network: net, local: local) do
      {:ok, plan} -> {net, plan}
      {:error, reason} -> refuse("the network profile is refused: #{inspect(reason)}")
    end
  end

  def network(n, _role, _local),
    do: refuse("network must be an object with \"profile\": \"lan_ipv4\" (no other profile; no loopback default for this kit): #{inspect(n)}")

  # -- bundle identity ------------------------------------------------------------------------------------------------------------
  # verifier V4: run first, before any configuration is decoded; the files present must be exactly the listed ones
  def bundle(root) do
    mpath = Path.join(root, "MANIFEST.sha256")
    bytes = case File.read(mpath), do: ({:ok, b} -> b; _ -> refuse("no bundle manifest at #{mpath}"))

    entries =
      for line <- String.split(bytes, "\n", trim: true) do
        case Regex.run(~r/\A([0-9a-f]{64})  (\S.*)\z/, line) do
          [_, h, rel] -> {h, rel}
          _ -> refuse("malformed manifest line #{inspect(String.slice(line, 0, 120))}")
        end
      end

    bad =
      for {h, rel} <- entries,
          String.contains?(rel, "..") or String.starts_with?(rel, "/") or
            (case File.read(Path.join(root, rel)), do: ({:ok, b} -> sha256(b) != h; _ -> true)),
          do: rel

    unless bad == [], do: refuse("bundle files differ from the manifest: #{inspect(Enum.take(bad, 5))}")
    unless Enum.any?(entries, fn {_, rel} -> rel == "kit/peer.exs" end), do: refuse("the manifest does not list kit/peer.exs")
    present = walk(root, "") -- ["MANIFEST.sha256"]
    extra = present -- Enum.map(entries, &elem(&1, 1))
    unless extra == [], do: refuse("files in the bundle that its manifest does not list: #{inspect(Enum.take(extra, 5))}")
    {sha256(bytes), length(entries)}
  end

  # every non-directory entry under the bundle, relative; the root is followed, directories under it are entered, symbolic
  # links under it are not followed (they count as entries)
  defp walk(root, rel) do
    path = if rel == "", do: root, else: Path.join(root, rel)

    case if(rel == "", do: File.stat(path), else: File.lstat(path)) do
      {:ok, %{type: :directory}} -> path |> File.ls!() |> Enum.sort() |> Enum.flat_map(&walk(root, if(rel == "", do: &1, else: Path.join(rel, &1))))
      _ -> [rel]
    end
  end

  def bundle_pin(%{"manifest_sha256" => pin} = b, sha) when map_size(b) == 1 and is_binary(pin) do
    unless Regex.match?(@hex64, pin), do: refuse("bundle.manifest_sha256 must be 64 lowercase hex characters")
    unless sha == pin, do: refuse("the bundle manifest's sha256 is #{sha}, not the configuration's #{pin}")
    pin
  end

  def bundle_pin(other, _sha), do: refuse("bundle must be exactly {\"manifest_sha256\": <64 hex>}: #{inspect(other)}")

  def runtime(%{"otp_release" => otp, "elixir_version_prefix" => ex}) when is_binary(otp) and is_binary(ex) do
    unless System.otp_release() == otp, do: refuse("OTP release #{System.otp_release()} is not the configuration's #{otp}")
    unless String.starts_with?(System.version(), ex), do: refuse("Elixir #{System.version()} does not start with the configuration's #{ex}")
    :ok
  end

  def runtime(other), do: refuse("runtime must name otp_release and elixir_version_prefix: #{inspect(other)}")

  # -- credentials ----------------------------------------------------------------------------------------------------------------
  def credentials(%{"cert_file" => c, "key_file" => k, "peer_ca_file" => ca, "peer_pin" => pin} = m) when map_size(m) == 4 do
    for f <- [c, k, ca], not (is_binary(f) and Path.type(f) == :absolute and File.regular?(f)),
        do: refuse("credential file missing or not an absolute regular file: #{inspect(f)}")

    mode = File.stat!(k).mode |> Bitwise.band(0o777)
    unless mode == 0o600, do: refuse("the private key file must be mode 0600, not #{Integer.to_string(mode, 8)}")
    files = [cert_file: c, key_file: k, peer_ca_file: ca, peer_pin: pin]

    case TLS.credentials(files) do
      {:ok, creds} ->
        # verifier V3: a key that only PEM-decodes would fail inside every handshake; refuse it here
        {type, der} = creds.key
        decodes = try do: (_ = :public_key.der_decode(type, der); true), rescue: (_ -> false)
        unless decodes, do: refuse("the private key in #{k} does not decode")
        {files, creds.own_pin, creds.peer_pin}

      {:error, reason} ->
        refuse("the credentials do not load: #{inspect(reason)}")
    end
  end

  def credentials(_), do: refuse("credentials must be exactly cert_file, key_file, peer_ca_file, peer_pin")

  # -- approval (never inferred: the WHOLE verbatim reply must be one accepted standalone form) -------------------------------------
  def approval(nil, _cfg_sha, _bundle_sha), do: :none

  def approval(%{"file" => f, "max_age_s" => max, "accepted_replies" => forms}, cfg_sha, bundle_sha)
      when is_binary(f) and is_integer(max) and max in 60..86_400 and is_list(forms) and forms != [] do
    unless Enum.all?(forms, &text?(&1, 64)), do: refuse("approval.accepted_replies must be single-line texts")
    a =
      try do
        f |> File.read!() |> JSON.decode!()
      rescue
        _ -> refuse("the approval record #{f} is missing or not JSON")
      end

    keys = ~w(schema run_id gate presented_utc config_sha256 bundle_manifest_sha256 operator_reply_verbatim recorded_utc)
    unless is_map(a) and Enum.sort(Map.keys(a)) == Enum.sort(keys), do: refuse("the approval record must have exactly #{inspect(keys)}")
    unless a["schema"] == @approval_schema, do: refuse("approval schema must be #{@approval_schema}")
    unless a["config_sha256"] == cfg_sha, do: refuse("the approval names configuration #{inspect(a["config_sha256"])}, not #{cfg_sha}")
    unless a["bundle_manifest_sha256"] == bundle_sha, do: refuse("the approval names bundle #{inspect(a["bundle_manifest_sha256"])}, not #{bundle_sha}")

    reply = a["operator_reply_verbatim"]
    unless is_binary(reply), do: refuse("the approval's operator reply is not a text")

    unless standalone?(reply, forms),
      do: refuse("the recorded operator reply is not a standalone approval (the whole reply must be one of #{inspect(forms)}); ask the operator for one — nothing is manufactured from another message")

    with {:ok, recorded, _} <- DateTime.from_iso8601(to_string(a["recorded_utc"])),
         {:ok, presented, _} <- DateTime.from_iso8601(to_string(a["presented_utc"])) do
      age = DateTime.diff(DateTime.utc_now(), recorded)
      unless DateTime.compare(presented, recorded) != :gt, do: refuse("the approval was recorded before its presentation")
      unless age >= -5 and age <= max, do: refuse("the approval is #{age} s old (maximum #{max} s)")
      {:ok, reply}
    else
      _ -> refuse("the approval's times are not ISO-8601")
    end
  end

  def approval(other, _, _), do: refuse("approval must name file, max_age_s (60-86400) and accepted_replies: #{inspect(other)}")

  # the whole reply, trimmed, case-insensitive, with at most one trailing "." or "!", equals one accepted form
  def standalone?(reply, forms) do
    r = reply |> String.trim() |> String.replace(~r/[.!]\z/u, "") |> String.downcase()
    r != "" and Enum.any?(forms, &(String.downcase(&1) == r))
  end

  # -- course and limits ----------------------------------------------------------------------------------------------------------
  def course(%{"profile" => "out_and_back"} = c) do
    allowed = ~w(profile prefix_ms distance_m speed_mps hold_ms interval_ms)
    case Map.keys(c) -- allowed, do: ([] -> :ok; extra -> refuse("unknown course keys #{inspect(extra)}"))
    num = fn k, lo, hi -> v = c[k]; (is_number(v) and v >= lo and v <= hi) || refuse("course.#{k} must be a number in #{lo}..#{hi}"); v end
    opts = [
      prefix_ms: trunc(num.("prefix_ms", 0, 10_000)),
      distance_m: num.("distance_m", 0.01, 2.0) * 1.0,
      speed_mps: num.("speed_mps", 0.05, 1.0) * 1.0,
      hold_ms: trunc(num.("hold_ms", 0, 10_000)),
      interval_ms: trunc(num.("interval_ms", 50, 1_000))
    ]
    # a synthetic origin at (0.0, 0.0) (the float32 words 0, 0): these positions describe no game and no place
    Course.out_and_back({0, 0}, opts)
  end

  def course(other), do: refuse("course must be an out_and_back object: #{inspect(other)}")

  def limits(%{"lifetime_s" => l, "connect_window_s" => w, "start_after_up_ms" => s, "drain_ms" => d} = m)
      when map_size(m) == 4 and is_integer(l) and l in 10..900 and is_integer(w) and w in 0..900 and w <= l and
             is_integer(s) and s in 0..10_000 and is_integer(d) and d in 0..10_000,
      do: %{lifetime_ms: l * 1_000, connect_window_ms: w * 1_000, start_after_up_ms: s, drain_ms: d}

  def limits(other), do: refuse("limits must be exactly lifetime_s (10-900), connect_window_s (<= lifetime), start_after_up_ms, drain_ms: #{inspect(other)}")

  def out_dir(o) do
    unless is_binary(o) and Path.type(o) == :absolute, do: refuse("out_dir must be an absolute path")
    if File.exists?(o), do: refuse("out_dir already exists (a fresh directory per run; nothing is ever overwritten): #{o}")
    unless File.dir?(Path.dirname(o)), do: refuse("out_dir's parent does not exist: #{Path.dirname(o)}")
    o
  end

  # every TCP socket of this VM that listens, with its address (nothing is assumed)
  def listeners do
    for p <- :erlang.ports(), Port.info(p)[:name] == ~c"tcp_inet", match?({:error, :enotconn}, :inet.peername(p)),
        {:ok, {ip, port}} <- [:inet.sockname(p)], do: "#{:inet.ntoa(ip)}:#{port}"
  end
end

# ================================================================================================================================
[cfg_path, cfg_sha] =
  case System.argv() do
    [a, b] -> [a, b]
    _ -> PeerKit.refuse("usage: elixir -pa <bundle>/ebin/glacier_relay <bundle>/kit/peer.exs <run-config.json> <run-config-sha256>")
  end

# stop.sh's TERM ends the run through the loop, with its summary. The trap is installed before anything else, and it BLOCKS
# (bounded): the VM's own SIGTERM handling (a clean stop with status 0, "complete") runs only after the user traps return, so the
# loop's finish halts first (verifier V2)
me = self()

System.trap_signal(:sigterm, fn ->
  send(me, :sigterm)
  receive do: (:never -> :ok), after: (20_000 -> :ok)
end)

if Node.alive?(), do: PeerKit.refuse("this node is distributed (#{node()}); the peer must run without --sname / --name")
bundle_root = __ENV__.file |> Path.dirname() |> Path.dirname()
{manifest_sha, listed} = PeerKit.bundle(bundle_root)
{cfg, _bytes, role} = PeerKit.config(cfg_path, cfg_sha)
_ = PeerKit.bundle_pin(cfg["bundle"], manifest_sha)
local = %{label: cfg["label"], client_kind: "headless"}
{net, plan} = PeerKit.network(cfg["network"], role, local)
:ok = PeerKit.runtime(cfg["runtime"])
{cred_files, own_pin, peer_pin} = PeerKit.credentials(cfg["credentials"])
approval = PeerKit.approval(cfg["approval"], cfg_sha, manifest_sha)
course = PeerKit.course(cfg["course"])
lim = PeerKit.limits(cfg["limits"])
out = PeerKit.out_dir(cfg["out_dir"])

# ---- every input check passed: :ssl (no socket) and its TLS 1.3, then the outputs, then the one endpoint ---------------------
{:ok, _} = Application.ensure_all_started(:ssl)
Logger.configure(level: :info)
unless :"tlsv1.3" in Keyword.get(:ssl.versions(), :supported, []), do: PeerKit.refuse("this OTP's ssl does not support TLS 1.3")

:ok = File.mkdir(out)
File.chmod!(out, 0o700)
File.write!(Path.join(out, "peer.pid"), "#{System.pid()}\n#{cfg_path}\n", [:exclusive])
events = Path.join(out, "events.ndjson")
File.write!(events, "", [:exclusive])

ev = fn kind, fields ->
  File.write!(events, JSON.encode!(Map.merge(%{"utc" => PeerKit.now(), "event" => kind}, fields)) <> "\n", [:append])
end

PeerKit.say("run #{cfg["run_id"]}, side #{cfg["side"]}, role #{role}, #{Network.describe(plan)}; os pid #{System.pid()}; node #{node()} (distributed #{Node.alive?()}); OTP #{System.otp_release()}, Elixir #{System.version()}")
PeerKit.say("checked before any socket: configuration #{cfg_sha}; bundle manifest #{manifest_sha} (exactly its #{listed} files, verified); credentials loaded (own leaf #{own_pin}, pinned peer leaf #{peer_pin}); approval #{case approval, do: ({:ok, r} -> "standalone reply " <> inspect(r); :none -> "not required by this configuration")}")

ev.("checked", %{
  "run_id" => cfg["run_id"], "side" => cfg["side"], "role" => to_string(role), "network" => Network.describe(plan),
  "config_sha256" => cfg_sha, "bundle_manifest_sha256" => manifest_sha, "bundle_files_verified" => listed,
  "otp" => System.otp_release(), "elixir" => System.version(), "os_pid" => System.pid(), "node" => to_string(node()),
  "distributed" => Node.alive?(), "own_pin" => own_pin, "peer_pin" => peer_pin,
  "approval" => case(approval, do: ({:ok, r} -> %{"reply_verbatim" => r}; :none -> nil))
})

# the hard backstop: whatever happens, this OS process ends
spawn(fn -> Process.sleep(lim.lifetime_ms + 15_000); IO.puts("#{PeerKit.now()} peer-kit: BACKSTOP halt"); System.halt(124) end)

# exits are trapped only while the peer starts: a failed start then answers {:error, _} here instead of killing this process
Process.flag(:trap_exit, true)

sup =
  case HeadlessPeer.start_link(
         role: role,
         network: net,
         credentials: cred_files,
         label: cfg["label"],
         expected: %{label: cfg["expected_label"], client_kind: "headless"},
         trace_dir: Path.join(out, "trace")
       ) do
    {:ok, sup} ->
      Process.flag(:trap_exit, false)
      sup

    {:error, reason} ->
      # verifier V5: e.g. the declared address no longer this machine's, or the port taken — recorded, exit 7
      why = inspect(reason, limit: 20) |> String.slice(0, 400)
      File.write!(Path.join(out, "summary.json"), JSON.encode!(%{
        "schema" => "glacier-relay.peer-transport-summary/1", "run_id" => cfg["run_id"], "side" => cfg["side"],
        "role" => to_string(role), "network" => Network.describe(plan), "outcome" => "endpoint_failed",
        "reason" => why, "exit_status" => 7, "ended_utc" => PeerKit.now()}) <> "\n", [:exclusive])
      ev.("finished", %{"outcome" => "endpoint_failed", "exit_status" => 7, "reason" => why})
      PeerKit.say("FINISHED: endpoint_failed (exit 7): #{why}")
      System.halt(7)
  end

ep = HeadlessPeer.endpoint()
PeerKit.say("endpoint up: #{inspect(Endpoint.status(ep) |> Map.take([:role, :address, :network]))}; listening sockets of this VM: #{inspect(PeerKit.listeners())}")
ev.("endpoint", %{"status" => inspect(Endpoint.status(ep) |> Map.take([:role, :address, :network, :counts])), "listeners" => PeerKit.listeners()})

t0 = System.monotonic_time(:millisecond)
elapsed = fn -> System.monotonic_time(:millisecond) - t0 end

finish = fn outcome, code, st ->
  ds = Driver.status()
  es = Endpoint.status(ep)
  summary = %{
    "schema" => "glacier-relay.peer-transport-summary/1",
    "run_id" => cfg["run_id"], "side" => cfg["side"], "role" => to_string(role), "network" => Network.describe(plan),
    "outcome" => outcome, "exit_status" => code, "ended_utc" => PeerKit.now(), "elapsed_ms" => elapsed.(),
    "own" => %{"label" => cfg["label"], "boot_id" => es.local.boot_id, "pin" => es.own_pin},
    # the peer as identified (kept from its identification: by the end the connection may be gone)
    "peer_seen" => st.peer,
    "endpoint_counts" => Map.new(es.counts, fn {k, v} -> {to_string(k), v} end),
    "sources_done" => Enum.map(ds.sources_done, fn s -> Map.new(s, fn {k, v} -> {to_string(k), v} end) end),
    "sinks_done" =>
      Enum.map(ds.sink_done, fn s ->
        Map.new(s, fn {k, v} -> {to_string(k), if(is_atom(v) and v not in [nil, true, false], do: to_string(v), else: v)} end)
        |> Map.put("transport_complete", PeerKit.transport_complete?(s))
      end),
    "sinks_open" => map_size(ds.sink),
    "label" => "M7-L1 transport-only exchange of synthetic courses between two headless peers; no game, no native, no authority"
  }
  File.write!(Path.join(out, "summary.json"), JSON.encode!(summary) <> "\n", [:exclusive])
  ev.("finished", %{"outcome" => outcome, "exit_status" => code})
  PeerKit.say("FINISHED: #{outcome} (exit #{code}); sent #{Enum.map_join(ds.sources_done, ",", & &1.sent)}, received #{Enum.map_join(ds.sink_done, ",", & &1.received)}, transport complete #{Enum.map_join(ds.sink_done, ",", &PeerKit.transport_complete?/1)}, gaps #{Enum.map_join(ds.sink_done, ",", & &1.gaps)}")
  Supervisor.stop(sup, :normal)
  System.halt(code)
end

# ---- the bounded run loop -----------------------------------------------------------------------------------------------------
loop = fn loop, st ->
  ds = Driver.status()
  es = Endpoint.status(ep)
  # verifier V6: the endpoint's own count, not this loop's sampling, says whether a connection ever came
  seen = es.counts.connections >= 1
  t = elapsed.()
  signalled = receive do: (:sigterm -> true), after: (0 -> false)

  cond do
    signalled ->
      PeerKit.say("SIGTERM: stopping (the connection, if any, is closed with this process)")
      finish.("stopped_by_signal", 6, st)

    t >= lim.lifetime_ms ->
      finish.(if(st.up_at, do: "lifetime_expired_after_identification", else: "lifetime_expired_no_peer"), 3, st)

    st.up_at == nil and ds.peer != nil ->
      PeerKit.say("peer identified: #{inspect(Map.take(ds.peer, [:label, :client_kind, :boot_id, :generation, :pin]))}")
      peer = Map.new(ds.peer, fn {k, v} -> {to_string(k), v} end)
      ev.("peer_up", %{"peer" => peer, "elapsed_ms" => t})
      loop.(loop, %{st | up_at: t, peer: peer})

    st.up_at == nil and seen and ds.peer == nil and es.connection == nil ->
      ev.("connection_ended", %{"elapsed_ms" => t, "identified" => false})
      PeerKit.say("a connection came and went without an identification seen here; no reconnection")
      finish.("connection_ended_before_identification", 4, st)

    st.up_at != nil and ds.peer == nil ->
      complete = ds.sources_done != [] and ds.sink_done != []
      ev.("peer_down", %{"elapsed_ms" => t, "exchange_complete" => complete})
      PeerKit.say("the connection ended (#{if complete, do: "after", else: "BEFORE"} the exchange completed); no reconnection")
      cond do
        not complete -> finish.("disconnected_before_completion", 4, st)
        Enum.all?(ds.sink_done, &PeerKit.transport_complete?/1) -> finish.("complete", 0, st)
        true -> finish.("complete_unreconciled", 5, st)
      end

    st.up_at == nil and not seen and role == :connect and t < lim.connect_window_ms and t - st.last_try >= 1_000 ->
      if es.connection == nil, do: Endpoint.connect(ep)
      Process.sleep(50)
      loop.(loop, %{st | last_try: t})

    st.up_at != nil and not st.started and t - st.up_at >= lim.start_after_up_ms ->
      case Driver.start_course(course, label: "M7-L1 transport test (synthetic course; #{cfg["side"]})") do
        {:ok, id} ->
          PeerKit.say("course started: stream #{id}, #{length(Course.samples(course))} samples at #{course.interval_ms} ms")
          ev.("course_started", %{"stream_id" => id, "samples" => length(Course.samples(course)), "elapsed_ms" => t})
          loop.(loop, %{st | started: true})

        {:error, reason} ->
          ev.("course_refused", %{"reason" => inspect(reason)})
          loop.(loop, %{st | started: true})
      end

    st.started and st.done_at == nil and ds.source == nil and ds.sources_done != [] and ds.sink_done != [] and map_size(ds.sink) == 0 ->
      PeerKit.say("both directions ended (sent #{Enum.map_join(ds.sources_done, ",", & &1.sent)}, received #{Enum.map_join(ds.sink_done, ",", & &1.received)}); draining #{lim.drain_ms} ms")
      ev.("exchange_ended", %{"elapsed_ms" => t})
      loop.(loop, %{st | done_at: t})

    st.done_at != nil and role == :connect and t - st.done_at >= lim.drain_ms ->
      %{connection: conn} = Endpoint.status(ep)
      if conn, do: GenServer.cast(conn.pid, {:close, :exchange_complete})
      Process.sleep(100)
      loop.(loop, st)

    st.done_at != nil and role == :listen and t - st.done_at >= lim.drain_ms + 5_000 ->
      %{connection: conn} = Endpoint.status(ep)
      if conn, do: GenServer.cast(conn.pid, {:close, :exchange_complete_initiator_silent})
      Process.sleep(100)
      loop.(loop, st)

    true ->
      Process.sleep(50)
      loop.(loop, st)
  end
end

_ = Connection
loop.(loop, %{up_at: nil, peer: nil, started: false, done_at: nil, last_try: 0})
