# M7-L3 — the headless peer that faces ONE game host (operator tooling; README.md "The game-facing peer"; design section 26).
#
#   elixir -pa <bundle>/ebin/glacier_relay <bundle>/kit/game-peer.exs <run-config.json> <run-config-sha256>
#   (through start.sh <bundle> <config> <sha256> game-peer.exs; an early stop is stop.sh <out_dir>; the one course is go.sh <out_dir>)
#
# ONE non-distributed BEAM process (nonode@nohost; no --sname, no epmd, no Erlang distribution) running ONE headless peer
# (GlacierRelay.HeadlessPeer) that LISTENS on one declared private IPv4 socket for the one declared game host (design section
# 20.2: the game host only connects out; only a headless peer listens). It is the MacBook's side of M7-L3's two sequential phases:
#   1. the share: it records, in its sink, the game host's real-player share stream (declared source_kind game); it sends nothing
#      back and nothing it receives ever reaches its source;
#   2. the destination course: on the operator's go (go.sh, once), and only then, it sends the ONE synthetic course of M7-C
#      (Motion.Course.out_and_back from the qualified P anchor's exact words, 1.0 m along negative world x at 0.5 m/s, a 4,000 ms
#      stationary prefix, 2,000 ms holds, 50 ms interval: compiled below, never configured), labelled synthetic.
# It never starts a course by itself after identification (transport-only peer.exs does: it is not a game peer). It refuses the go
# before identification, while an inbound stream (the share) is still open, or after a course has run: one go request per run,
# whatever its outcome (a refused go is final; there is no retry). It holds no run token, no authority API and no game state.
#
# Derived from peer.exs (the transport-only peer): the PeerKit module below is peer.exs's, byte for byte (tests/game-peer-test.sh
# checks it), so the bundle, configuration, network, runtime, credential, approval and output checks are the same code. What
# differs is in GamePeer and the main loop: the schema (glacier-relay.peer-game-run/1), the role (listen only), the expected peer
# kind (game), the course (compiled, with its anchor named and checked in the configuration), the limits (lifetime only), the go,
# and the end (the game host closes the connection; there is no exchange to complete).
#
# Before ANY socket, and before :ssl starts, every input is checked as in peer.exs, and also: the configuration's course names
# the profile "m7c_out_and_back" and the anchor words of P exactly; the generated course passes its own facts (241 samples,
# 12,000 ms, the first changing sample at 4,050 ms, 1.0 m along -x only, the y word constant, first and last samples at the
# anchor, Course.check against M7-C's session limits). Its sha256 digest (of its "seq<TAB>t_ms<TAB>x,y words" lines) is printed:
# the game host's course plan prints the same digest from its own inspection, and the operator compares the two.
# Outputs: <out>/peer.pid, <out>/events.ndjson, <out>/trace/ (the headless motion trace), <out>/summary.json, <out>/go.* (the go
# record). One socket observation (kit/sockets.exs) at the endpoint start, the identification, the go and the finish.
# Exit status: 0 ended by the game host after identification, every inbound stream ended and transport-complete, and the course,
# if one ran, ended by its own course_complete; 2 refused before any socket; 3 the lifetime ended (identified or not); 4 the connection ended before
# identification, or during the course; 5 ended by the game host with an inbound stream open or not transport-complete; 6 stopped
# by stop.sh (SIGTERM); 7 the endpoint could not start; 8 the connection's status read failed unexpectedly at the course's end (a
# timeout, an abnormal exit, a malformed reply: its class only is recorded); 124 the hard backstop (lifetime + 15 s). Never a
# reconnection. The summary's connection_counts_read says whether the connection's own counters were read: a host close between
# the endpoint's snapshot and the read leaves them unavailable (recorded with the reason), never zeros (M7-L3 record section 15).
# No private key, CA key or certificate body is ever printed or written by this script.

alias GlacierRelay.HeadlessPeer
alias GlacierRelay.HeadlessPeer.Driver
alias GlacierRelay.Motion.Course
alias GlacierRelay.Command.TransformWords
alias GlacierRelay.Peer.{Connection, Endpoint, Network, TLS}

# ---- PeerKit: peer.exs's module, byte for byte (tests/game-peer-test.sh compares it) ------------------------------------------
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
    unless Enum.any?(entries, fn {_, rel} -> rel == "kit/sockets.exs" end), do: refuse("the manifest does not list kit/sockets.exs")
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

  # one socket observation, compacted for the summary (the full one is in events.ndjson)
  def compact(at, o) do
    %{"at" => at, "utc" => o["vm"]["utc"], "status" => o["status"], "listening" => o["listening"], "kernel_agrees" => o["kernel_agrees"],
      "connecting" => Enum.map(o["vm"]["connecting"] || [], & &1["local"]),
      "connected" => Enum.map(o["vm"]["connected"] || [], &"#{&1["local"]}->#{&1["remote"]}")}
  end
end

defmodule GamePeer do
  @moduledoc false
  @schema "glacier-relay.peer-game-run/1"
  @top ~w(schema run_id side role network label expected_label credentials course limits out_dir bundle runtime approval)

  # P: Agent48's content-placed anchor (M6-E2 package 5ac64848…, matrix cd90df8d…), the world x / y words M7-C's course was planned
  # from and its native closed on (M7C record sections 4-5): x -89.49 (c2b2fae1), y 14.83 (416d47ae)
  @anchor {0xC2B2FAE1, 0x416D47AE}
  # M7-C's ONE course (cmd-m7c.exs, sealed in m7c-run1/kit): constants, never configuration
  @course_opts [distance_m: 1.0, speed_mps: 0.5, heading_rad: 0.0, direction: :reverse, prefix_ms: 4_000, hold_ms: 2_000, interval_ms: 50]
  # M7-C's session limits, against which the course is checked here (the game host enforces its own copy)
  @session_limits %{duration_ms: 20_000, half_extent_mm: 1_250, max_speed_mmps: 1_000, credit_ms: 100}
  @stream_label "M7-L3 synthetic course (Mac headless peer; not a player)"

  def anchor, do: @anchor
  def stream_label, do: @stream_label

  # the configuration's own checks beyond PeerKit.config/2 (which checks schema peer-transport-run/1 and refuses other keys)
  def config(path, expected_sha) do
    unless Regex.match?(~r/\A[0-9a-f]{64}\z/, expected_sha), do: PeerKit.refuse("the configuration sha256 argument is not 64 lowercase hex characters")
    bytes = case File.read(path), do: ({:ok, b} -> b; {:error, r} -> PeerKit.refuse("cannot read the run configuration #{path}: #{inspect(r)}"))
    got = PeerKit.sha256(bytes)
    unless got == expected_sha, do: PeerKit.refuse("the run configuration's sha256 is #{got}, not the approved #{expected_sha}")
    cfg = try do: JSON.decode!(bytes), rescue: (_ -> PeerKit.refuse("the run configuration is not JSON"))
    unless is_map(cfg), do: PeerKit.refuse("the run configuration is not a JSON object")
    case Map.keys(cfg) -- @top, do: ([] -> :ok; extra -> PeerKit.refuse("unknown configuration keys #{inspect(extra)}"))
    unless cfg["schema"] == @schema, do: PeerKit.refuse("schema must be #{@schema}")
    unless is_binary(cfg["run_id"]) and Regex.match?(~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/, cfg["run_id"]), do: PeerKit.refuse("run_id must be a short lowercase identifier")
    for k <- ~w(side label expected_label), not PeerKit.text?(cfg[k], 64), do: PeerKit.refuse("#{k} must be a single-line text of 1-64 bytes")
    unless cfg["role"] == "listen", do: PeerKit.refuse("role must be listen: the game host only connects out (design 20.2), not #{inspect(cfg["role"])}")
    {cfg, :listen}
  end

  # the course: the profile and the anchor are NAMED in the configuration (so the approval shows them) and must equal the
  # compiled ones; the parameters are never configurable
  def course(%{"profile" => "m7c_out_and_back", "anchor_words" => [x, y]} = c) when map_size(c) == 2 and is_binary(x) and is_binary(y) do
    words = for w <- [x, y], do: (case Integer.parse(w, 16), do: ({n, ""} when byte_size(w) == 8 -> n; _ -> PeerKit.refuse("course.anchor_words must be two 8-digit hex words")))
    unless List.to_tuple(words) == @anchor, do: PeerKit.refuse("course.anchor_words #{inspect([x, y])} are not P's (#{TransformWords.encode(Tuple.to_list(@anchor))})")
    course = Course.out_and_back(@anchor, @course_opts)
    facts = facts(course)
    bad = for {k, true} <- facts.failed, do: k
    unless bad == [], do: PeerKit.refuse("the generated course fails its own checks #{inspect(bad)}: #{inspect(Map.delete(facts, :samples))}")
    {course, facts}
  end

  def course(other), do: PeerKit.refuse("course must be exactly {\"profile\": \"m7c_out_and_back\", \"anchor_words\": [x, y]}: #{inspect(other)}")

  # the generator's own output, checked (never an imported count)
  def facts(course) do
    ss = Course.samples(course)
    {xw, yw} = course.origin_words
    x0 = TransformWords.to_float(xw)
    first_move = Enum.find(ss, &(&1.x_word != xw or &1.y_word != yw))
    max_dx = ss |> Enum.map(&abs(&1.x - x0)) |> Enum.max()
    check = Course.check(course, @session_limits)
    lines = Enum.map_join(ss, fn s -> "#{s.seq}\t#{s.t_ms}\t#{TransformWords.encode([s.x_word, s.y_word])}\n" end)

    %{
      samples: ss,
      n: length(ss),
      schedule_ms: List.last(ss).t_ms,
      first_changing_t_ms: first_move && first_move.t_ms,
      max_dx_m: max_dx,
      digest: PeerKit.sha256(lines),
      describe: Course.describe(course),
      check: inspect(check),
      failed: %{
        samples_not_241: length(ss) != 241,
        schedule_not_12000: List.last(ss).t_ms != 12_000,
        first_change_not_4050: (first_move && first_move.t_ms) != 4_050,
        not_1m_along_negative_x: not (abs(max_dx - 1.0) < 1.0e-5 and Enum.all?(ss, &(&1.x <= x0))),
        y_word_not_constant: not Enum.all?(ss, &(&1.y_word == yw)),
        first_or_last_not_anchor: not (hd(ss).x_word == xw and hd(ss).y_word == yw and List.last(ss).x_word == xw and List.last(ss).y_word == yw),
        check_failed: not match?({:ok, _}, check)
      }
    }
  end

  def limits(%{"lifetime_s" => l} = m) when map_size(m) == 1 and is_integer(l) and l in 60..900, do: %{lifetime_ms: l * 1_000}
  def limits(other), do: PeerKit.refuse("limits must be exactly {\"lifetime_s\": 60..900}: #{inspect(other)}")

  # the connection's own counters, read once after the course's stream ended, from the connection the endpoint's snapshot listed
  # (M7-L3 record section 15). The game host may close it between that snapshot and this read: its peer-close lands about 20 ms
  # after the stream's end (m7l3-admission dry-run-B-attempt1 / -2, where the read exited the run without its summary). The read
  # itself handles it: GenServer.call monitors the connection, so an exit before or during the read ends the wait at once, and
  # the library's call timeout (5,000 ms) bounds the rest. Only this read's exit is caught, and only its class is kept (never
  # the exit's term):
  #   {:ok, counts}                    read
  #   {:unavailable, "noproc"}         the connection had already ended          } expected: the host's close; counters
  #   {:unavailable, "ended_during"}   it ended (normal / shutdown) during it    } unavailable, never zeros or enqueue counts
  #   {:failed, "timeout" | "exit_abnormal" | "malformed_status"}   unexpected: the run ends as a failure (exit 8)
  def connection_counts(pid) do
    reply =
      try do
        Connection.status(pid)
      catch
        :exit, {reason, {GenServer, :call, [^pid | _]}} -> {:exit, reason}
      end

    case reply do
      {:exit, :noproc} -> {:unavailable, "noproc"}
      {:exit, r} when r in [:normal, :shutdown] -> {:unavailable, "ended_during"}
      {:exit, {:shutdown, _}} -> {:unavailable, "ended_during"}
      {:exit, :timeout} -> {:failed, "timeout"}
      {:exit, _} -> {:failed, "exit_abnormal"}
      %{counts: c} when is_map(c) -> {:ok, Map.new(c, fn {k, v} -> {to_string(k), v} end)}
      _ -> {:failed, "malformed_status"}
    end
  end
end

# ================================================================================================================================
[cfg_path, cfg_sha] =
  case System.argv() do
    [a, b] -> [a, b]
    _ -> PeerKit.refuse("usage: elixir -pa <bundle>/ebin/glacier_relay <bundle>/kit/game-peer.exs <run-config.json> <run-config-sha256>")
  end

# stop.sh's TERM ends the run through the loop, with its summary (as peer.exs: the trap blocks, bounded)
me = self()

System.trap_signal(:sigterm, fn ->
  send(me, :sigterm)
  receive do: (:never -> :ok), after: (20_000 -> :ok)
end)

if Node.alive?(), do: PeerKit.refuse("this node is distributed (#{node()}); the peer must run without --sname / --name")
bundle_root = __ENV__.file |> Path.dirname() |> Path.dirname()
{manifest_sha, listed} = PeerKit.bundle(bundle_root)
# the socket observation (PeerKit.Sockets): a bundle file verified just above, loaded only now
Code.require_file(Path.join(bundle_root, "kit/sockets.exs"))
{cfg, role} = GamePeer.config(cfg_path, cfg_sha)
_ = PeerKit.bundle_pin(cfg["bundle"], manifest_sha)
local = %{label: cfg["label"], client_kind: "headless"}
{net, plan} = PeerKit.network(cfg["network"], role, local)
:ok = PeerKit.runtime(cfg["runtime"])
{cred_files, own_pin, peer_pin} = PeerKit.credentials(cfg["credentials"])
approval = PeerKit.approval(cfg["approval"], cfg_sha, manifest_sha)
{course, facts} = GamePeer.course(cfg["course"])
lim = GamePeer.limits(cfg["limits"])
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

course_view = %{"profile" => "m7c_out_and_back", "anchor_words" => TransformWords.encode(Tuple.to_list(GamePeer.anchor())), "describe" => facts.describe,
  "samples" => facts.n, "schedule_ms" => facts.schedule_ms, "first_changing_t_ms" => facts.first_changing_t_ms, "max_dx_m" => facts.max_dx_m,
  "digest" => facts.digest, "check" => facts.check, "label" => GamePeer.stream_label()}

PeerKit.say("run #{cfg["run_id"]}, side #{cfg["side"]}, role #{role} (game-facing), #{Network.describe(plan)}; os pid #{System.pid()}; node #{node()} (distributed #{Node.alive?()}); OTP #{System.otp_release()}, Elixir #{System.version()}")
PeerKit.say("checked before any socket: configuration #{cfg_sha}; bundle manifest #{manifest_sha} (exactly its #{listed} files, verified); credentials loaded (own leaf #{own_pin}, pinned game-host leaf #{peer_pin}); approval #{case approval, do: ({:ok, r} -> "standalone reply " <> inspect(r); :none -> "not required by this configuration")}")
PeerKit.say("the ONE course (sent only on go.sh): #{facts.describe}; anchor #{course_view["anchor_words"]}; #{facts.n} samples over #{facts.schedule_ms} ms; first changing sample at #{facts.first_changing_t_ms} ms; 1.0 m along -x; COURSE DIGEST #{facts.digest}")

ev.("checked", %{
  "run_id" => cfg["run_id"], "side" => cfg["side"], "role" => to_string(role), "network" => Network.describe(plan),
  "config_sha256" => cfg_sha, "bundle_manifest_sha256" => manifest_sha, "bundle_files_verified" => listed,
  "otp" => System.otp_release(), "elixir" => System.version(), "os_pid" => System.pid(), "node" => to_string(node()),
  "distributed" => Node.alive?(), "own_pin" => own_pin, "peer_pin" => peer_pin, "course" => course_view,
  "approval" => case(approval, do: ({:ok, r} -> %{"reply_verbatim" => r}; :none -> nil))
})

# the hard backstop: whatever happens, this OS process ends
spawn(fn -> Process.sleep(lim.lifetime_ms + 15_000); IO.puts("#{PeerKit.now()} peer-kit: BACKSTOP halt"); System.halt(124) end)

Process.flag(:trap_exit, true)

sup =
  case HeadlessPeer.start_link(
         role: role,
         network: net,
         credentials: cred_files,
         label: cfg["label"],
         expected: %{label: cfg["expected_label"], client_kind: "game"},
         trace_dir: Path.join(out, "trace")
       ) do
    {:ok, sup} ->
      Process.flag(:trap_exit, false)
      sup

    {:error, reason} ->
      why = inspect(reason, limit: 20) |> String.slice(0, 400)
      File.write!(Path.join(out, "summary.json"), JSON.encode!(%{
        "schema" => "glacier-relay.peer-game-summary/1", "run_id" => cfg["run_id"], "side" => cfg["side"],
        "role" => to_string(role), "network" => Network.describe(plan), "outcome" => "endpoint_failed",
        "reason" => why, "exit_status" => 7, "ended_utc" => PeerKit.now()}) <> "\n", [:exclusive])
      ev.("finished", %{"outcome" => "endpoint_failed", "exit_status" => 7, "reason" => why})
      PeerKit.say("FINISHED: endpoint_failed (exit 7): #{why}")
      System.halt(7)
  end

ep = HeadlessPeer.endpoint()
obs0 = PeerKit.Sockets.observe()
PeerKit.say("endpoint up: #{inspect(Endpoint.status(ep) |> Map.take([:role, :address, :network]))}; #{PeerKit.Sockets.describe(obs0)}")
ev.("endpoint", %{"status" => inspect(Endpoint.status(ep) |> Map.take([:role, :address, :network, :counts])), "socket_observation" => obs0})
PeerKit.say("waiting for the game host (#{cfg["expected_label"]}); lifetime #{div(lim.lifetime_ms, 1000)} s. The course starts only on: sh <bundle>/kit/go.sh #{out}")

t0 = System.monotonic_time(:millisecond)
elapsed = fn -> System.monotonic_time(:millisecond) - t0 end
go_req = Path.join(out, "go.request")
go_taken = Path.join(out, "go.taken")

observe_at = fn at, st ->
  o = PeerKit.Sockets.observe()
  PeerKit.say("at #{at}: #{PeerKit.Sockets.describe(o)}")
  ev.("socket_observation", %{"at" => at, "observation" => o})
  %{st | obs: [PeerKit.compact(at, o) | st.obs]}
end

finish = fn outcome, code, st ->
  ds = Driver.status()
  es = Endpoint.status(ep)
  obs_end = PeerKit.Sockets.observe()
  PeerKit.say("at the finish: #{PeerKit.Sockets.describe(obs_end)}")
  ev.("socket_observation", %{"at" => "finish", "observation" => obs_end})
  summary = %{
    "schema" => "glacier-relay.peer-game-summary/1",
    "run_id" => cfg["run_id"], "side" => cfg["side"], "role" => to_string(role), "network" => Network.describe(plan),
    "outcome" => outcome, "exit_status" => code, "ended_utc" => PeerKit.now(), "elapsed_ms" => elapsed.(),
    "own" => %{"label" => cfg["label"], "boot_id" => es.local.boot_id, "pin" => es.own_pin},
    "peer_seen" => st.peer,
    "endpoint_counts" => Map.new(es.counts, fn {k, v} -> {to_string(k), v} end),
    "connection_counts" => st.conn_counts,
    "connection_counts_read" => st.conn_read || %{"available" => false, "reason" => "not_read", "why" => "no course stream ended while the endpoint listed the connection (no course, the connection ended first, or the run stopped)"},
    "course" => Map.merge(course_view, %{"go" => st.go}),
    "sources_done" => Enum.map(ds.sources_done, fn s -> Map.new(s, fn {k, v} -> {to_string(k), v} end) end),
    "sinks_done" =>
      Enum.map(ds.sink_done, fn s ->
        Map.new(s, fn {k, v} -> {to_string(k), if(is_atom(v) and v not in [nil, true, false], do: to_string(v), else: v)} end)
        |> Map.put("transport_complete", PeerKit.transport_complete?(s))
      end),
    "sinks_open" => map_size(ds.sink),
    "socket_observations" => Enum.reverse([PeerKit.compact("finish", obs_end) | st.obs]),
    "label" => "M7-L3 game-facing headless peer: it records the game host's share and sends one synthetic course on the operator's go; no game, no native, no authority"
  }
  File.write!(Path.join(out, "summary.json"), JSON.encode!(summary) <> "\n", [:exclusive])
  ev.("finished", %{"outcome" => outcome, "exit_status" => code})
  PeerKit.say("FINISHED: #{outcome} (exit #{code}); share streams received #{Enum.map_join(ds.sink_done, ",", & &1.received)} (transport complete #{Enum.map_join(ds.sink_done, ",", &PeerKit.transport_complete?/1)}; open #{map_size(ds.sink)}); course #{inspect(st.go && st.go["outcome"])}, sent #{Enum.map_join(ds.sources_done, ",", & &1.sent)}")
  Supervisor.stop(sup, :normal)
  System.halt(code)
end

# the one go request: taken once (renamed), judged, recorded in go.taken; a second request finds go.taken and go.sh refuses it
take_go = fn st, ds, t ->
  case File.rename(go_req, go_taken) do
    :ok ->
      reason =
        cond do
          st.up_at == nil -> "not identified: no game host connected"
          ds.source != nil or ds.sources_done != [] -> "a course has already run"
          map_size(ds.sink) != 0 -> "an inbound stream (the share) is still open: the phases never overlap"
          true -> nil
        end

      {outcome, st} =
        if reason do
          {"refused: " <> reason, st}
        else
          case Driver.start_course(course, label: GamePeer.stream_label()) do
            {:ok, id} -> {"started", Map.put(st, :stream_id, id)}
            {:error, why} -> {"refused: the driver answered #{inspect(why)}", st}
          end
        end

      go = %{"taken_utc" => PeerKit.now(), "elapsed_ms" => t, "outcome" => outcome, "stream_id" => Map.get(st, :stream_id)}
      File.write!(go_taken, JSON.encode!(go) <> "\n", [:append])
      ev.("go", go)
      PeerKit.say("GO #{outcome}#{if go["stream_id"], do: ": stream #{go["stream_id"]}, #{facts.n} samples at 50 ms (digest #{facts.digest})", else: " (one go per run: no retry)"}")
      st = %{st | go: go}
      if outcome == "started", do: observe_at.("go", st), else: st

    {:error, _} ->
      st
  end
end

# ---- the bounded run loop -----------------------------------------------------------------------------------------------------
loop = fn loop, st ->
  ds = Driver.status()
  es = Endpoint.status(ep)
  seen = es.counts.connections >= 1
  t = elapsed.()
  signalled = receive do: (:sigterm -> true), after: (0 -> false)

  cond do
    signalled ->
      PeerKit.say("SIGTERM: stopping (the connection, if any, is closed with this process)")
      finish.("stopped_by_signal", 6, st)

    t >= lim.lifetime_ms ->
      finish.(if(st.up_at, do: "lifetime_expired_after_identification", else: "lifetime_expired_no_peer"), 3, st)

    st.go == nil and File.exists?(go_req) ->
      st = take_go.(st, ds, t)
      Process.sleep(10)
      loop.(loop, st)

    st.up_at == nil and ds.peer != nil ->
      PeerKit.say("game host identified: #{inspect(Map.take(ds.peer, [:label, :client_kind, :boot_id, :generation, :pin]))}")
      peer = Map.new(ds.peer, fn {k, v} -> {to_string(k), v} end)
      ev.("peer_up", %{"peer" => peer, "elapsed_ms" => t})
      loop.(loop, observe_at.("peer_up", %{st | up_at: t, peer: peer}))

    st.up_at == nil and seen and ds.peer == nil and es.connection == nil ->
      ev.("connection_ended", %{"elapsed_ms" => t, "identified" => false})
      PeerKit.say("a connection came and went without an identification; no reconnection")
      finish.("connection_ended_before_identification", 4, st)

    # the connection's own counters, read once when the course's stream has ended while the endpoint lists the connection; the
    # host may close it in between (GamePeer.connection_counts/1): then they are unavailable, and the host's close ends the run
    # through the branch below, by the driver's and endpoint's own facts
    st.up_at != nil and st.conn_read == nil and ds.source == nil and ds.sources_done != [] and es.connection != nil ->
      read = GamePeer.connection_counts(es.connection.pid)

      {cc, rec} =
        case read do
          {:ok, cc} -> {cc, %{"available" => true, "elapsed_ms" => t}}
          {:unavailable, class} -> {nil, %{"available" => false, "reason" => "connection_ended_before_the_read", "class" => class, "elapsed_ms" => t}}
          {:failed, class} -> {nil, %{"available" => false, "reason" => "status_read_failed", "class" => class, "elapsed_ms" => t}}
        end

      ev.("course_ended", %{"elapsed_ms" => t, "sources_done" => Enum.map(ds.sources_done, fn s -> Map.new(s, fn {k, v} -> {to_string(k), v} end) end), "connection_counts" => cc, "connection_counts_read" => rec})
      st = %{st | conn_counts: cc, conn_read: rec}

      case read do
        {:ok, _} ->
          PeerKit.say("the course stream ended (sent #{Enum.map_join(ds.sources_done, ",", & &1.sent)}); waiting for the game host to close the connection")
          loop.(loop, st)

        {:unavailable, class} ->
          PeerKit.say("the course stream ended (sent #{Enum.map_join(ds.sources_done, ",", & &1.sent)}); the connection ended before its counters were read (#{class}): they are unavailable")
          loop.(loop, st)

        {:failed, class} ->
          PeerKit.say("the course stream ended (sent #{Enum.map_join(ds.sources_done, ",", & &1.sent)}); the connection's status read FAILED (#{class}): an unexpected failure, the run ends")
          finish.("connection_status_unreadable", 8, st)
      end

    st.up_at != nil and ds.peer == nil ->
      ev.("peer_down", %{"elapsed_ms" => t})
      PeerKit.say("the game host's connection ended; no reconnection")
      # the driver ends a running course itself when the link is lost (reason peer_link_lost): a course is complete only by its
      # own reason, course_complete (tests/game-peer-test.sh close-in-course)
      cut = ds.source != nil or Enum.any?(ds.sources_done, &(&1.reason != "course_complete"))
      cond do
        cut -> finish.("disconnected_during_course", 4, st)
        map_size(ds.sink) == 0 and Enum.all?(ds.sink_done, &PeerKit.transport_complete?/1) -> finish.("ended_by_host", 0, st)
        true -> finish.("ended_by_host_unreconciled", 5, st)
      end

    true ->
      Process.sleep(50)
      loop.(loop, st)
  end
end

loop.(loop, %{up_at: nil, peer: nil, go: nil, conn_counts: nil, conn_read: nil, obs: [PeerKit.compact("endpoint", obs0)]})
