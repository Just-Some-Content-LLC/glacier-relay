defmodule GlacierRelay.Command.AuthorityRedactionTest do
  @moduledoc """
  M6-F1a binding correction (the review's redaction request): an ACTUAL crash report of the
  command authority, captured from the Logger, with a token generated for this test alone and
  never printed. The controlled failure carries no state in its reason (`Keyword.get/3` raises
  on opts that are not a list, inside the issue callback), so what the report shows of the state
  is what `Authority.format_status/1` produced. Elixir's Logger translator prints a GenServer's
  `State:` (and client) section only at the `:debug` level — the level a dev or `mix run` node
  runs at (no logger configuration outside the test environment) — so the test raises the level to
  `:debug` for its own duration; at the test environment's `:warning` the section is absent.

  Coverage limit, stated and not claimed here: a failure whose exception carries the state itself
  — a `FunctionClauseError` of an authority callback, whose top stack frame prints the callback's
  arguments — is NOT covered by `format_status/1`; the M6-F record's corrective review reports
  that path (evidence `m6f1a-binding/redaction-scope-probe`).
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  require Logger

  alias GlacierRelay.Command
  alias GlacierRelay.Command.{Authority, Listener}
  alias GlacierRelay.Test.{FakeNative, FixturePlayer}

  @caps ["relay.probe/1", "relay.inspect.candidate_transform/1", "candidate.transform.set/1"]

  setup do
    token = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    dir =
      Path.join(
        System.tmp_dir!(),
        "glacier-relay-redaction-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)

    start_supervised!(
      {Command.Supervisor,
       port: 0, journal_dir: dir, hello_timeout_ms: 400, effectful: true, token: token}
    )

    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
    %{port: Listener.port(), token: token}
  end

  defp wait(fun), do: FixturePlayer.wait_until(fun, 100, 10)

  test "a controlled authority failure: the captured crash report shows the state with the token redacted and never the token; :sys.get_status before and after the restart never carries it",
       %{port: port, token: token} do
    {socket, _adapter, _} = FakeNative.handshake_v2(port, token, capabilities: @caps)
    assert wait(fn -> Command.status().trust.token_verified end)
    before = Process.whereis(Authority)

    status_before =
      inspect(:sys.get_status(Authority), limit: :infinity, printable_limit: :infinity)

    log =
      capture_log(fn ->
        assert {{:function_clause, [{Keyword, :get, _, _} | _]}, _} =
                 catch_exit(
                   GenServer.call(
                     Authority,
                     {:issue, "relay.probe", 1, %{}, :controlled_failure_not_a_keyword_list}
                   )
                 )

        assert wait(fn ->
                 pid = Process.whereis(Authority)
                 pid != nil and pid != before
               end)

        Process.sleep(200)
      end)

    assert log =~ "GenServer GlacierRelay.Command.Authority terminating"
    assert log =~ "Last message"
    assert log =~ "State: "
    # since the token-guard correction the state holds no token to redact
    refute log =~ "token: "
    assert not String.contains?(log, token), "the generated token appears in the captured log"

    assert not String.contains?(status_before, token),
           "the generated token appears in :sys.get_status before the failure"

    refute Keyword.has_key?(:sys.get_state(Authority).config, :token)

    status_after =
      inspect(:sys.get_status(Authority), limit: :infinity, printable_limit: :infinity)

    assert not String.contains?(status_after, token),
           "the generated token appears in :sys.get_status after the restart"

    # the restarted authority has its token again (from its start arguments); still never shown
    assert Command.status().effectful.token_configured
    assert not String.contains?(inspect(Command.status(), limit: :infinity), token)
    FakeNative.close(socket)
  end
end
