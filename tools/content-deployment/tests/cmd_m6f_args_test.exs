# M6-F2a / M6-F2b preparation: the small decisions of cmd-m6f.exs (cmd_m6f_args.exs), tested on its own — no node, no RPC
# (deterministic tool-level tests; the stop-marker case uses a scratch directory under the system temp directory, ext4). The M6-F1b finding it
# covers: the documented owner-only form `arm-effectful <owner>` raised before its RPC; every documented form must now supply the
# existing default TTL (30 000 ms) and an explicit TTL must stay validated (a plain millisecond count; the range is the
# authority's and is not judged here). Also the `lift-follow` arguments.
#
#   (cd relay && elixir -S mix run --no-start ../tools/content-deployment/tests/cmd_m6f_args_test.exs)
ExUnit.start(autorun: false)
Code.require_file("../cmd_m6f_args.exs", __DIR__)

defmodule CmdM6fArgsTest do
  use ExUnit.Case, async: true

  test "arm-effectful: the empty and the owner-only forms supply the existing default TTL" do
    assert CmdM6fArgs.arm_effectful([]) == {:ok, "HITMAN3.exe", 30_000}
    assert CmdM6fArgs.arm_effectful(["HITMAN3.exe"]) == {:ok, "HITMAN3.exe", 30_000}
    assert CmdM6fArgs.arm_effectful(["GlacierRelayCommandProbe.exe"]) == {:ok, "GlacierRelayCommandProbe.exe", 30_000}
    assert CmdM6fArgs.default_effectful_ttl_ms() == 30_000
  end

  test "arm-effectful: an explicit TTL is passed through as given (the authority judges its range)" do
    assert CmdM6fArgs.arm_effectful(["HITMAN3.exe", "30000"]) == {:ok, "HITMAN3.exe", 30_000}
    assert CmdM6fArgs.arm_effectful(["HITMAN3.exe", "1000"]) == {:ok, "HITMAN3.exe", 1_000}
    # out of the authority's range, still a well-formed count: passed on, refused there (ttl_out_of_range), not here
    assert CmdM6fArgs.arm_effectful(["HITMAN3.exe", "999999"]) == {:ok, "HITMAN3.exe", 999_999}
    assert CmdM6fArgs.arm_effectful(["HITMAN3.exe", "0"]) == {:ok, "HITMAN3.exe", 0}
  end

  test "arm-effectful: a malformed TTL is refused before anything is collected or sent" do
    for bad <- ["", "abc", "-1", "+30000", "30000 ", " 30000", "3e4", "30_000", "30000ms", "1234567890", "HITMAN3.exe"] do
      assert {:error, {:not_a_millisecond_count, ^bad}} = CmdM6fArgs.arm_effectful(["HITMAN3.exe", bad]), inspect(bad)
    end
  end

  test "arm-effectful: a TTL in the owner's place is not taken for an owner; extra arguments are refused" do
    assert {:error, {:not_an_image_name, "30000"}} = CmdM6fArgs.arm_effectful(["30000"])
    assert {:error, {:not_an_image_name, "HITMAN3"}} = CmdM6fArgs.arm_effectful(["HITMAN3"])
    assert {:error, {:not_an_image_name, "C:\\HITMAN3.exe"}} = CmdM6fArgs.arm_effectful(["C:\\HITMAN3.exe"])
    assert {:error, {:too_many_arguments, 3, _}} = CmdM6fArgs.arm_effectful(["HITMAN3.exe", "30000", "x"])
  end

  test "lift-follow: defaults, explicit values and the schedule" do
    assert {:ok, %{inspection: "i", generation: "g", lift_ttl_ms: 5_000, follow: []}} = CmdM6fArgs.lift_follow(["i", "g"])
    assert {:ok, %{lift_ttl_ms: 9_000, follow: []}} = CmdM6fArgs.lift_follow(["i", "g", "9000"])
    assert {:ok, %{lift_ttl_ms: 5_000, follow: [schedule_ms: [0, 250, 1000, 2000, 5000, 10000]]}} =
             CmdM6fArgs.lift_follow(["i", "g", "-", "0,250,1000,2000,5000,10000"])
    assert {:ok, %{follow: [schedule_ms: [0, 500], request_timeout_ms: 3000, inspection_ttl_ms: 2500]}} =
             CmdM6fArgs.lift_follow(["i", "g", "-", "0,500", "3000", "2500"])
  end

  test "lift-follow: malformed values and missing required arguments are refused" do
    assert {:error, {:usage, _}} = CmdM6fArgs.lift_follow([])
    assert {:error, {:usage, _}} = CmdM6fArgs.lift_follow(["i"])
    assert {:error, {:missing, :inspection_id}} = CmdM6fArgs.lift_follow(["-", "g"])
    assert {:error, {:missing, :expected_generation}} = CmdM6fArgs.lift_follow(["i", " "])
    assert {:error, {:not_a_millisecond_count, "5s"}} = CmdM6fArgs.lift_follow(["i", "g", "5s"])
    assert {:error, {:not_a_schedule, "0,,250"}} = CmdM6fArgs.lift_follow(["i", "g", "-", "0,,250"])
    assert {:error, {:not_a_schedule, "0;250"}} = CmdM6fArgs.lift_follow(["i", "g", "-", "0;250"])
    assert {:error, {:too_many_arguments, 7}} = CmdM6fArgs.lift_follow(["i", "g", "-", "-", "-", "-", "x"])
  end

  test "item A: the stop marker is looked at fail-closed (true / false only when affirmatively absent / an error otherwise)" do
    base = Path.join(System.tmp_dir!(), "m6f-stop-marker-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    try do
      assert CmdM6fArgs.stop_marker(base) == false
      File.write!(Path.join(base, "stop.marker"), "HARD STOP: test\n")
      assert CmdM6fArgs.stop_marker(base) == true
      File.rm!(Path.join(base, "stop.marker"))
      File.mkdir!(Path.join(base, "stop.marker"))
      assert CmdM6fArgs.stop_marker(base) == true, "a directory named stop.marker is a marker too"
      File.rmdir!(Path.join(base, "stop.marker"))
      # a vanished evidence directory: the marker's absence is NOT established
      assert {:error, {:evidence_directory, :enoent}} = CmdM6fArgs.stop_marker(Path.join(base, "gone"))
      # a file where the evidence directory should be
      File.write!(Path.join(base, "plain"), "x")
      assert {:error, _} = CmdM6fArgs.stop_marker(Path.join(base, "plain"))
      # an unreadable directory (ext4 test directory, mode 000): the marker cannot be looked at -> an error, never false
      locked = Path.join(base, "locked")
      File.mkdir!(locked)
      File.chmod!(locked, 0o000)
      r = CmdM6fArgs.stop_marker(Path.join(locked, "inner"))
      File.chmod!(locked, 0o700)
      if System.get_env("USER") != "root", do: assert({:error, _} = r)
    after
      File.rm_rf!(base)
    end
  end

  test "item A: cmd-m6f.exs takes its stop marker from CmdM6fArgs.stop_marker/1 for the guard and the follow client" do
    src = File.read!(Path.join(__DIR__, "../cmd-m6f.exs"))
    refute src =~ ~r/File\.exists\?\(Path\.join\(evid, "stop\.marker"\)\)/
    assert src =~ "stop_marker = fn -> CmdM6fArgs.stop_marker(evid) end"
    assert src =~ ~s|{"follow-no-stop-marker", stop_marker.() == false}|
    assert src =~ "stop?: stop_marker,"
  end

  test "item A: an issuance reply is issued, refused before transmission, or UNCERTAIN — a timeout is never a refusal" do
    assert CmdM6fArgs.issuance({:ok, "0f6c1d2e-0000-4000-8000-000000000001"}) == {:issued, "0f6c1d2e-0000-4000-8000-000000000001"}
    # the authority's refusals (decided before transmission; journaled command.refused) and Command's own local checks
    for reason <- [:not_armed_effectful, :lift_budget_consumed, :inspection_stale, :already_at_baseline, :command_disabled, {:journal_unavailable, :eio}, {:generation_mismatch, "g"}] do
      assert CmdM6fArgs.issuance({:error, reason}) == {:refused, reason}, inspect(reason)
    end
    # accepted, then the send failed: the authority itself records the outcome as unknown
    assert CmdM6fArgs.issuance({:error, {:send_failed, :closed}}) == {:uncertain, {:error, {:send_failed, :closed}}}
    # an RPC timeout, a lost node, a remote exit (the authority's own GenServer timeout), an unexpected shape
    for reply <- [{:badrpc, :timeout}, {:badrpc, :nodedown}, {:badrpc, {:EXIT, {:timeout, {GenServer, :call, []}}}}, {:ok, :not_an_id}, :ok, nil, {:ok, "a", :b}] do
      assert {:uncertain, ^reply} = CmdM6fArgs.issuance(reply), inspect(reply)
    end
    # the issuance bound sits below the authority's own 5 s GenServer call bound
    assert CmdM6fArgs.issue_timeout_ms() == 3_000 and CmdM6fArgs.issue_timeout_ms() < 5_000 and CmdM6fArgs.rpc_timeout_ms() == 10_000
  end

  test "item A: cmd-m6f.exs bounds and classifies every issuance; 'nothing transmitted' only in a refused branch" do
    src = File.read!(Path.join(__DIR__, "../cmd-m6f.exs"))
    assert length(Regex.scan(~r/call_t\.\(cmd, :lift_candidate, .*CmdM6fArgs\.issue_timeout_ms\(\)\)/, src)) == 2
    assert length(Regex.scan(~r/call_t\.\(cmd, :restore_candidate, .*CmdM6fArgs\.issue_timeout_ms\(\)\)/, src)) == 1
    assert length(Regex.scan(~r/call_t\.\(cmd, :inspect_candidate_transform, .*CmdM6fArgs\.issue_timeout_ms\(\)\)/, src)) == 1
    refute src =~ ~r/[^_]call\.\(cmd, :(lift_candidate|restore_candidate|inspect_candidate_transform)/
    assert length(Regex.scan(~r/CmdM6fArgs\.issuance\(/, src)) == 4
    # every "nothing transmitted" line sits directly in a {:refused, _} branch; every uncertain branch says the operation MAY have been sent
    lines = String.split(src, "\n")
    for {l, i} <- Enum.with_index(lines), l =~ "nothing transmitted", not String.starts_with?(String.trim_leading(l), "#") do
      assert Enum.at(lines, i - 1) =~ ~r/\{:refused, /, "line #{i + 1}: #{l}"
    end
    assert length(Regex.scan(~r/\{:uncertain, why\} ->/, src)) == 4
    assert length(Regex.scan(~r/MAY have been (accepted and )?transmitted/, src)) >= 4
    # the lift-follow path's own RPCs are bounded
    assert src =~ ~s|rpc_ms = if action == "lift-follow", do: CmdM6fArgs.rpc_timeout_ms(), else: :infinity|
  end

  test "cmd-m6f.exs dispatches arm-effectful through the parser (no list padding left)" do
    src = File.read!(Path.join(__DIR__, "../cmd-m6f.exs"))
    [arm] = Regex.run(~r/"arm-effectful" ->.*?\n\n  "/s, src)
    assert arm =~ "CmdM6fArgs.arm_effectful(rest)"
    refute arm =~ "rest ++"
    refute arm =~ "String.to_integer"
  end
end

result = ExUnit.run()
System.halt(if result.failures == 0, do: 0, else: 1)
