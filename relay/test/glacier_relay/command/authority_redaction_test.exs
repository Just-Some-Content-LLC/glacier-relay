defmodule GlacierRelay.Command.AuthorityRedactionTest do
  @moduledoc """
  M6-F1a token-guard correction: the run token never reaches a diagnostic of the command
  authority's failures. Every test starts the command subtree from a FRESH file-backed token
  (`:token_file`, the live provisioning path: the configuration carries the file's path; the
  token is generated per test and never printed) and causes ONE failure carrying a unique
  marker, then checks every channel that failure reaches, at `:debug` (Elixir's translator
  prints a GenServer's `State:` and client sections only at `:debug` — the level of a dev /
  `mix run` node; the test environment runs at `:warning`):

  - the translated log text (`ExUnit.CaptureLog`);
  - the raw structured `:logger` events, unmodified (`Test.LogCapture`): the gen_server
    terminate report, the proc_lib crash report and the supervisor's child_terminated report;
  - the caller's exit reason (for a call) and a monitor's DOWN reason;
  - `:sys.get_state` (real absence, not presentation masking) and `:sys.get_status`.

  The failures: an unmatched call (`handle_call/3`), an unmatched cast (`handle_cast/2`) and an
  unmatched info message (`handle_info/2`, a 3-tuple: its 2-tuple catch-all `{_timer, _id}`
  absorbs 2-tuples) — function-clause errors whose top stack frame carries the callback's
  arguments, the whole state among them (OTP 28.4.2 `gen_server:error_info/7` reports the
  formatted reason with the ORIGINAL stacktrace and `terminate/9` re-raises it) — and the
  control error whose reason carries no state. An empty or missing report is a failure, not a
  secrecy pass: each channel must hold the failure's marker.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  require Logger

  alias GlacierRelay.Command
  alias GlacierRelay.Command.{Authority, Journal, Listener}
  alias GlacierRelay.Test.{FakeNative, FixturePlayer, LogCapture}

  @caps ["relay.probe/1", "relay.inspect.candidate_transform/1", "candidate.transform.set/1"]

  setup context do
    token = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    dir =
      Path.join(
        System.tmp_dir!(),
        "tg-auth-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    file = Path.join(dir, "token")
    File.write!(file, Map.get(context, :file_contents, token) <> "\n")
    File.chmod!(file, 0o600)
    on_exit(fn -> File.rm_rf(dir) end)

    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    # The isolated test configuration: Elixir's primary translator filter drops the [otp, sasl]
    # domain (the proc_lib crash and supervisor reports) while `handle_sasl_reports` is false — the
    # setting of the test, dev and live run configurations, where those reports reach no handler.
    # Here they are let through for the test's duration so that they can be checked; nothing is
    # filtered or modified; the filter is restored afterwards.
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

    start_supervised!(
      {Command.Supervisor,
       port: 0,
       journal_dir: Path.join(dir, "commands"),
       hello_timeout_ms: 400,
       effectful: true,
       token_file: file,
       effectful_ttl_max_ms: 120_000,
       evidence_max_age_ms: 120_000}
    )

    %{port: Listener.port(), token: token, token_path: file}
  end

  defp wait(fun), do: FixturePlayer.wait_until(fun, 100, 10)
  defp full(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)
  defp clean?(term, token), do: not String.contains?(full(term), token)

  # The names of the channels that carry the token. Assertions compare this list with [] so that a
  # failure prints channel names, never the token (ExUnit prints a failing call's arguments).
  defp leaks(named, token), do: for({name, term} <- named, not clean?(term, token), do: name)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp peer(port, token) do
    {socket, adapter, _} = FakeNative.handshake_v2(port, token, capabilities: @caps)
    assert wait(fn -> Command.status().trust.token_verified end)
    {socket, adapter}
  end

  defp arm_both(adapter) do
    assert :ok = Command.arm()

    assert :ok =
             Command.attest_telemetry(%{
               "adapter_instance_id" => adapter,
               "observed_at" => now(),
               "basis" => "test",
               "evidence_ref" => "test",
               "max_age_ms" => 60_000
             })

    assert :ok =
             Command.arm_effectful(
               ownership: %{
                 "collected_at" => now(),
                 "owner_pid" => 4711,
                 "executable" => "HITMAN3.exe",
                 "local_port" => 50_000,
                 "remote_port" => 4749,
                 "connections" => 1,
                 "validation" => "exactly_one_hitman",
                 "source" => "test",
                 "max_age_ms" => 60_000
               }
             )
  end

  # ONE failure of the authority, every channel collected: the translated log, the raw events,
  # the trigger's own result, the DOWN reason, the old and the restarted pids.
  defp crash(trigger) do
    before = Process.whereis(Authority)
    ref = Process.monitor(before)
    handler = :"tg_capture_#{System.unique_integer([:positive])}"
    LogCapture.attach(handler)
    test = self()

    log =
      try do
        capture_log(fn ->
          result = trigger.()

          down =
            receive do
              {:DOWN, ^ref, :process, ^before, reason} -> reason
            after
              5_000 -> :no_down
            end

          wait(fn ->
            pid = Process.whereis(Authority)
            pid != nil and pid != before
          end)

          Process.sleep(300)
          send(test, {:collected, result, down})
        end)
      after
        LogCapture.detach(handler)
      end

    {result, down} =
      receive do
        {:collected, result, down} -> {result, down}
      after
        1_000 -> {:not_collected, :not_collected}
      end

    %{
      result: result,
      down: down,
      log: log,
      events: LogCapture.drain(),
      before: before,
      after: Process.whereis(Authority)
    }
  end

  defp report(events, label) do
    Enum.find(events, fn
      %{msg: {:report, %{label: ^label}}} -> true
      _ -> false
    end)
  end

  defp assert_no_token_anywhere(c, token, marker) do
    terminate = report(c.events, {:gen_server, :terminate})
    crash_report = report(c.events, {:proc_lib, :crash})
    supervisor = report(c.events, {:supervisor, :child_terminated})

    # the failure happened and each channel is about it (an empty channel is never a pass)
    assert c.log =~ "GenServer GlacierRelay.Command.Authority terminating"
    assert c.log =~ "State: "
    assert c.log =~ marker
    assert terminate != nil and full(terminate) =~ marker
    assert crash_report != nil and full(crash_report) =~ marker
    assert supervisor != nil and full(supervisor) =~ marker
    assert full(c.down) =~ marker

    # and none of them carries the token
    assert leaks(
             [
               translated_log: c.log,
               gen_server_terminate_report: terminate,
               proc_lib_crash_report: crash_report,
               supervisor_report: supervisor,
               every_captured_event: c.events,
               down_reason: c.down,
               caller_result: c.result
             ],
             token
           ) == []

    # the supervisor report names the child's start arguments: the token file's path, not the token
    assert full(supervisor) =~ "token_file"
  end

  defp assert_restarted_clean(c, token) do
    assert is_pid(c.after) and c.after != c.before
    state = :sys.get_state(Authority)

    assert leaks([restarted_state: state, restarted_status: :sys.get_status(Authority)], token) ==
             []

    refute Keyword.has_key?(state.config, :token)
    assert is_reference(state.credential) and state.token_source == :file
    s = Command.status()
    # a restart re-reads the file under the same policy; it carries no arming and no link
    assert s.effectful.token_configured
    assert s.trust.armed == false and s.trust.effectful_armed == false and s.link == nil
    assert s.effectful.transform_lift_budget == 1
  end

  test "an unmatched call: the function-clause frame carries the state, which holds no token; every channel checked",
       %{port: port, token: token} do
    {socket, adapter} = peer(port, token)
    arm_both(adapter)
    marker = "tg-call-#{System.unique_integer([:positive])}"

    c = crash(fn -> catch_exit(GenServer.call(Authority, {:token_guard_probe, marker})) end)

    assert c.log =~ "no function clause matching in GlacierRelay.Command.Authority.handle_call/3"
    # the caller's exit reason carries the stack frame with the callback's arguments
    assert {{:function_clause, [{Authority, :handle_call, [_, _, _], _} | _]}, _} = c.result
    assert_no_token_anywhere(c, token, marker)
    assert_restarted_clean(c, token)
    FakeNative.close(socket)
  end

  test "an unmatched cast: the same channels, no caller", %{port: port, token: token} do
    {socket, adapter} = peer(port, token)
    arm_both(adapter)
    marker = "tg-cast-#{System.unique_integer([:positive])}"

    c = crash(fn -> GenServer.cast(Authority, {:token_guard_probe, marker}) end)

    assert c.log =~ "no function clause matching in GlacierRelay.Command.Authority.handle_cast/2"
    assert {:function_clause, [{Authority, :handle_cast, [_, _], _} | _]} = c.down
    assert_no_token_anywhere(c, token, marker)
    assert_restarted_clean(c, token)
    FakeNative.close(socket)
  end

  test "an unmatched info message (a 3-tuple; 2-tuples meet the timer catch-all): the same channels",
       %{port: port, token: token} do
    {socket, adapter} = peer(port, token)
    arm_both(adapter)
    marker = "tg-info-#{System.unique_integer([:positive])}"

    c = crash(fn -> send(Authority, {:token_guard_probe, :info, marker}) end)

    assert c.log =~ "no function clause matching in GlacierRelay.Command.Authority.handle_info/2"
    assert {:function_clause, [{Authority, :handle_info, [_, _], _} | _]} = c.down
    assert_no_token_anywhere(c, token, marker)
    assert_restarted_clean(c, token)
    FakeNative.close(socket)
  end

  test "the control failure whose reason carries no state: the same channels", %{
    port: port,
    token: token
  } do
    {socket, _adapter} = peer(port, token)
    marker = "tg-control-#{System.unique_integer([:positive])}"

    c =
      crash(fn ->
        catch_exit(
          GenServer.call(Authority, {:issue, "relay.probe", 1, %{}, {:tg_control, marker}})
        )
      end)

    assert c.log =~ "no function clause matching in Keyword.get/3"
    assert_no_token_anywhere(c, token, marker)
    assert_restarted_clean(c, token)
    FakeNative.close(socket)
  end

  test "before any failure: the token is absent from :sys.get_state itself, from :sys.get_status, from the supervisor's child specifications and from the application environment",
       %{port: port, token: token} do
    {socket, _adapter} = peer(port, token)
    state = :sys.get_state(Authority)
    refute Keyword.has_key?(state.config, :token)
    assert is_reference(state.credential) and state.token_source == :file

    assert leaks(
             [
               sys_get_state: state,
               sys_get_status: :sys.get_status(Authority),
               supervisor_child_specs: :sys.get_state(Command.Supervisor),
               status_api: Command.status(),
               application_env: Application.get_all_env(:glacier_relay)
             ],
             token
           ) == []

    FakeNative.close(socket)
  end

  test "the private holder: unreadable from another process, owned by the authority, destroyed with it; the restarted authority has a new one and stays disarmed until a fresh link, attestation and arming",
       %{port: port, token: token} do
    {socket, adapter} = peer(port, token)
    arm_both(adapter)
    old = :sys.get_state(Authority).credential
    owner = Process.whereis(Authority)
    assert :ets.info(old, :owner) == owner and :ets.info(old, :protection) == :private
    assert :ets.info(old, :heir) == :none
    assert_raise ArgumentError, fn -> :ets.lookup(old, :token) end

    marker = "tg-lifetime-#{System.unique_integer([:positive])}"
    c = crash(fn -> catch_exit(GenServer.call(Authority, {:token_guard_probe, marker})) end)
    assert :ets.info(old) == :undefined
    new = :sys.get_state(Authority).credential
    assert new != old and :ets.info(new, :owner) == c.after
    assert_restarted_clean(c, token)

    # a fresh link (the listener restarted with the authority: a new port) re-attests against the
    # token the new holder read from the file; nothing is armed
    {socket2, adapter2} = peer(Listener.port(), token)
    s = Command.status()
    assert s.trust.token_verified and s.trust.armed == false and s.trust.effectful_armed == false
    assert {:error, :disarmed} = Command.probe()
    assert {:error, :telemetry_corroboration_missing} = Command.arm_effectful(ownership: %{})
    arm_both(adapter2)
    assert Command.status().trust.effectful_armed

    # the command records of the old authority are gone with it: nothing to retry, lift or restore
    assert Command.status().commands == []
    FakeNative.close(socket)
    FakeNative.close(socket2)
  end

  @tag file_contents: "not a token"
  test "an invalid token file fails closed: no attestation, no effectful arming, stable non-secret reasons",
       %{port: port} do
    state = :sys.get_state(Authority)
    assert state.token_source == :invalid
    refute Command.status().effectful.token_configured
    # the peer attests with some token; the authority holds none
    any = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    {socket, _adapter, _} = FakeNative.handshake_v2(port, any, capabilities: @caps)
    assert wait(fn -> Command.status().counters.attest_failures == 1 end)
    refute Command.status().trust.token_verified

    %{path: path} = Journal.status()

    entries =
      path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert Enum.any?(
             entries,
             &(&1["event"] == "peer.attest_failed" and &1["reason"] == "no_token_configured")
           )

    assert {:error, :no_token_configured} = Command.arm_effectful(ownership: %{})
    FakeNative.close(socket)
  end
end
