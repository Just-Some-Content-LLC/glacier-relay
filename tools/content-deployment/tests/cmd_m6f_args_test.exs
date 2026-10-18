# M6-F2a: the argument parser of cmd-m6f.exs (cmd_m6f_args.exs), tested on its own — no node, no RPC. The M6-F1b finding it
# covers: the documented owner-only form `arm-effectful <owner>` raised before its RPC; every documented form must now supply the
# existing default TTL (30 000 ms) and an explicit TTL must stay validated (a plain millisecond count; the range is the
# authority's and is not judged here).
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
