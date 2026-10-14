defmodule GlacierRelay.Command.JournalTest do
  @moduledoc "The append-only command journal (M5-A): identity, format, durability contract, permissions, degradation."
  use ExUnit.Case, async: true

  alias GlacierRelay.Command.Journal
  alias GlacierRelay.Test.StubWriter

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "glacier-relay-journal-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp start(opts) do
    name = :"journal_#{System.unique_integer([:positive])}"
    {:ok, pid} = Journal.start_link(Keyword.merge([name: name, dir: tmp_dir()], opts))
    {name, pid}
  end

  defp entries(path),
    do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

  test "opens a versioned, identified journal with restrictive permissions and a synced header" do
    {name, _} = start([])
    s = Journal.status(name)
    assert s.version == "glacier-relay.command-journal/1" and s.status == :open and s.seq == 1
    assert String.ends_with?(s.path, "commands-#{s.journal_id}.ndjson")
    assert Bitwise.band(File.stat!(s.path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(s.path)).mode, 0o777) == 0o700
    [header] = entries(s.path)

    assert header["event"] == "journal.opened" and header["journal"] == s.version and
             header["journal_id"] == s.journal_id

    assert header["seq"] == 1 and is_binary(header["at"]) and is_integer(header["mono_ms"])
  end

  test "appends return :ok only after write and sync; entries carry sequence, time and monotonic offset" do
    {name, pid} = start([])
    assert :ok = Journal.append(name, %{"event" => "authority.armed", "link_generation" => 1})
    assert :ok = Journal.append(name, %{"event" => "command.accepted", "command_id" => "x"})
    s = Journal.status(name)
    assert s.seq == 3
    [_, a, b] = entries(s.path)
    assert a["event"] == "authority.armed" and a["seq"] == 2 and a["link_generation"] == 1
    assert b["event"] == "command.accepted" and b["seq"] == 3 and b["mono_ms"] >= a["mono_ms"]
    GenServer.stop(pid)
    assert List.last(entries(s.path))["event"] == "journal.closed"
  end

  test "a sync failure degrades the journal: the failed entry and every later one are refused" do
    {:ok, agent} = StubWriter.start()
    {name, _} = start(writer: {StubWriter, agent})
    assert :ok = Journal.append(name, %{"event" => "ok"})
    StubWriter.mode(agent, {:fail_sync, :eio})
    assert {:error, :eio} = Journal.append(name, %{"event" => "lost"})
    StubWriter.mode(agent, :ok)
    assert {:error, {:degraded, :eio}} = Journal.append(name, %{"event" => "after"})
    assert %{status: :degraded, last_error: :eio} = Journal.status(name)
  end

  test "an append failure degrades the same way" do
    {:ok, agent} = StubWriter.start()
    {name, _} = start(writer: {StubWriter, agent})
    StubWriter.mode(agent, {:fail_append, :enospc})
    assert {:error, :enospc} = Journal.append(name, %{"event" => "lost"})
    assert %{status: :degraded} = Journal.status(name)
  end

  test "never opens over an existing file and never writes a mission-recording line" do
    {name, _} = start([])
    s = Journal.status(name)
    assert {:error, :eexist} = Journal.FileWriter.open(s.path, [])
    refute Enum.any?(entries(s.path), &Map.has_key?(&1, "r"))
    refute Enum.any?(entries(s.path), &(&1["k"] in ["recording.opened", "envelope"]))
  end
end
