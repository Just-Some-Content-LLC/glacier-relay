defmodule GlacierRelay.Test.MotionStack do
  @moduledoc """
  M7-B1 test support: one owned loopback topology for the motion tests (call from the test
  process). It starts, in this VM: an in-VM headless peer (`GlacierRelay.HeadlessPeer`, listening
  on an ephemeral loopback port), the game host's command subtree with the motion subtree (the
  motion link on an ephemeral loopback port, the peer endpoint connecting out to the headless peer)
  and the fake native (`Test.FakeMotionNative`), with throwaway credentials and an ephemeral test
  token in a test-owned temporary directory. Nothing leaves loopback; nothing is distributed.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1, on_exit: 1]

  alias GlacierRelay.Command
  alias GlacierRelay.Command.Listener
  alias GlacierRelay.HeadlessPeer
  alias GlacierRelay.Motion.{Course, Hub}
  alias GlacierRelay.Peer.Endpoint
  alias GlacierRelay.Test.{FakeMotionNative, FixturePlayer, PeerCredentials}

  @token "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

  def token, do: @token
  def generation, do: FakeMotionNative.generation()

  @doc """
  Starts the topology. `opts`: `:headless` (default true: start the in-VM headless peer; false
  with `:peer_port` connects the game host to a headless peer elsewhere, e.g. another OS process),
  `:creds` (a `PeerCredentials.pair/0`), `:lan` (M7-L1: both peer endpoints use the explicit
  `lan_ipv4` profile on `127.0.0.1` with a concrete port instead of B1's loopback default; with
  `headless: false` the other process's listener is at `:peer_port`),
  `:max_sessions`, `:bind_motion` (default true), `:command` (extra command-subtree options),
  `:fake` (extra fake-native options). Returns a map of the parts.
  """
  def start(opts \\ []) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "glacier-relay-m7b1-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    creds = Keyword.get(opts, :creds) || PeerCredentials.pair()

    lan = Keyword.get(opts, :lan, false)

    hport =
      if Keyword.get(opts, :headless, true) do
        lport = if lan, do: free_port(), else: 0
        address = if lan, do: [network: lan_listen(lport)], else: [port: 0]

        start_supervised!(
          {HeadlessPeer,
           address ++
             [
               credentials: fn -> creds.headless end,
               label: "headless-test",
               expected: %{label: "host-test", client_kind: "game"},
               trace_dir: Path.join(dir, "headless-trace"),
               sink_bounds: Keyword.get(opts, :sink_bounds)
             ]}
        )

        Endpoint.port(HeadlessPeer.endpoint())
      else
        Keyword.get(opts, :peer_port, 1)
      end

    command =
      Keyword.merge(
        [
          port: 0,
          journal_dir: Path.join(dir, "journal"),
          ack_timeout_ms: 500,
          grace_ms: 300,
          default_ttl_ms: 1_000,
          min_ttl_ms: 50,
          hello_timeout_ms: 1_000,
          effectful: true,
          token: @token,
          effectful_ttl_max_ms: 120_000,
          evidence_max_age_ms: 120_000,
          reversal_inspection_max_age_ms: 60_000,
          motion:
            [
              enabled: true,
              port: 0,
              trace_dir: Path.join(dir, "host-trace"),
              max_sessions: Keyword.get(opts, :max_sessions, 1),
              peer:
                if(lan,
                  do: [network: lan_connect(hport)],
                  else: [ip: {127, 0, 0, 1}, port: hport]
                ) ++
                  [
                    credentials: fn -> creds.host end,
                    local: %{label: "host-test", client_kind: "game"},
                    expected: %{label: "headless-test", client_kind: "headless"},
                    reconnect_ms: 200
                  ]
            ] ++ Keyword.get(opts, :motion_extra, [])
        ],
        Keyword.get(opts, :command, [])
      )

    start_supervised!({Command.Supervisor, command})

    fake =
      start_supervised!(
        {FakeMotionNative,
         Keyword.merge(
           [
             command_port: Listener.port(),
             motion_port: GlacierRelay.Motion.Listener.port(),
             token: @token,
             bind_motion: false
           ],
           Keyword.get(opts, :fake, [])
         )}
      )

    wait(fn -> Command.status().trust.token_verified end)

    if Keyword.get(opts, :bind_motion, true) do
      :ok = FakeMotionNative.bind_motion(fake)
      wait(fn -> Hub.status().link != nil end)
    end

    if Keyword.get(opts, :headless, true), do: wait(fn -> Hub.status().peer != nil end)

    %{
      dir: dir,
      creds: creds,
      fake: fake,
      adapter: FakeMotionNative.status(fake).adapter,
      headless_port: hport
    }
  end

  @doc "M7-L1: the `lan_ipv4` listen profile on `127.0.0.1:port` (initiator `127.0.0.1`)."
  def lan_listen(port),
    do: [
      profile: :lan_ipv4,
      prefix_length: 8,
      listen: {{127, 0, 0, 1}, port},
      initiator: {127, 0, 0, 1}
    ]

  @doc "M7-L1: the `lan_ipv4` connect profile to `127.0.0.1:port`."
  def lan_connect(port),
    do: [profile: :lan_ipv4, prefix_length: 8, connect: {{127, 0, 0, 1}, port}]

  @doc "A loopback port free at this moment (the profile takes concrete ports only)."
  def free_port do
    {:ok, s} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(s)
    :gen_tcp.close(s)
    port
  end

  def wait(fun, attempts \\ 300, sleep_ms \\ 10),
    do: FixturePlayer.wait_until(fun, attempts, sleep_ms)

  def now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  @doc "Inert arming (idempotent)."
  def arm do
    if Command.status().trust.armed, do: :ok, else: Command.arm()
  end

  @doc "One exact inspection answered by the fake; returns its id."
  def inspect_exact do
    :ok = arm()
    {:ok, id} = Command.inspect_candidate_transform()
    wait(fn -> Command.command(id).status == :applied end)
    id
  end

  @doc "The effectful arming (telemetry attestation + ownership evidence) for `adapter`."
  def arm_effectful(adapter) do
    :ok =
      Command.attest_telemetry(%{
        "adapter_instance_id" => adapter,
        "observed_at" => now_iso(),
        "basis" => "test: the fake adapter's identity",
        "evidence_ref" => "m7b1-test",
        "max_age_ms" => 60_000
      })

    Command.arm_effectful(
      ownership: %{
        "collected_at" => now_iso(),
        "owner_pid" => 4242,
        "executable" => "HITMAN3.exe",
        "local_port" => 50_000,
        "remote_port" => 4749,
        "connections" => 1,
        "validation" => "exactly_one_hitman",
        "source" => "test fixture (no game)",
        "max_age_ms" => 60_000
      }
    )
  end

  @doc "A short out-and-back course from the fake's anchor (test timing)."
  def short_course(opts \\ []) do
    Course.out_and_back(
      FakeMotionNative.anchor_words(),
      Keyword.merge([prefix_ms: 1_000, distance_m: 0.2, speed_mps: 0.5, hold_ms: 200], opts)
    )
  end

  @doc "Starts a course on the in-VM headless peer and waits until the host sees its stream."
  def start_course(course \\ short_course()) do
    {:ok, stream_id} =
      GlacierRelay.HeadlessPeer.Driver.start_course(course, label: "m7b1 test course")

    wait(fn -> Map.has_key?(Hub.status().peer.streams, stream_id) end)
    stream_id
  end

  @doc "Inspect, arm effectful and open a session on `stream_id`; returns `{session_id, command_id}`."
  def open_session(adapter, stream_id, opts \\ []) do
    insp = inspect_exact()
    :ok = arm_effectful(adapter)

    {:ok, %{session_id: sid, command_id: cid}} =
      GlacierRelay.Motion.open_session(
        Keyword.merge(
          [
            inspection_command_id: insp,
            expected_generation: generation(),
            stream_id: stream_id,
            source_kind: "synthetic",
            limits: %{duration_ms: 20_000}
          ],
          opts
        )
      )

    wait(fn -> Command.command(cid).status == :applied end)
    wait(fn -> match?(%{status: :active}, Hub.status().session) end)
    {sid, cid}
  end

  @doc "The journal's entries."
  def journal do
    %{path: path} = Command.Journal.status()
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  @doc "A trace file's records."
  def trace_records(path) do
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end
end
