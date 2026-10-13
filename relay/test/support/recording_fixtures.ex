defmodule GlacierRelay.Test.RecordingFixtures do
  @moduledoc """
  Recordings for the reader and replay tests (M4-B): a fixture played through the real listener
  into a test recorder, closed, with the live session state captured at the recording boundary;
  plus read-only edits of copies (never of the original) to produce damaged recordings.
  """

  alias GlacierRelay.{MissionSession, Summary}
  alias GlacierRelay.Recording.Recorder
  alias GlacierRelay.Test.FixturePlayer

  @doc "Starts a test recorder on a fresh temporary directory; returns its name."
  def start_recorder(opts \\ []) do
    name = :"recorder_#{System.unique_integer([:positive])}"
    dir = tmp_path("glacier-relay-replay")
    opts = Keyword.merge([name: name, dir: dir, flush_ms: 20], opts)
    pid = Recorder.start_link(opts) |> elem(1)
    Process.unlink(pid)
    {name, pid, dir}
  end

  # A fresh temporary path, unique across VMs (an earlier run's directory of the same name would
  # otherwise be merged into by cp_r), removed when the test (or, from setup_all, the module) exits.
  defp tmp_path(prefix) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.pid()}-#{suffix}")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(path) end)
    path
  end

  @doc """
  Flushes a recorder after a session call: the call returns only after the session finished its
  current cast, so every record it sent is already in the recorder's mailbox ahead of the flush.
  """
  def flush(name) do
    _ = MissionSession.unidentified()
    Recorder.flush(name)
  end

  @doc "Stops a recorder started by `start_recorder/1` without closing it (a crash)."
  def kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      5_000 -> raise "recorder did not die"
    end
  end

  @doc """
  The live session's outputs restricted to `ids`, taken now (the equivalence boundary): the
  instances, the unidentified list, the summary and report data and texts over that subset.
  """
  def capture(ids) do
    state = MissionSession.state()
    unidentified = MissionSession.unidentified()
    sub = Map.take(state, ids)

    %{
      instances: sub,
      unidentified: unidentified,
      summary: Summary.build(sub),
      report: Summary.report(sub),
      summary_text: fn n -> Summary.render(sub, Enum.take(unidentified, n)) end,
      report_text: fn n -> Summary.render_report(sub, Enum.take(unidentified, n)) end
    }
  end

  @doc "Plays a fixture under a fresh id through the listener and waits for its close."
  def play(name, prefix \\ "rp") do
    id = FixturePlayer.unique_id(prefix)
    :closed = FixturePlayer.play(name, id)
    FixturePlayer.await_closed(id)
    id
  end

  @doc "Records one fixture cleanly: returns the closed recording's directory, the id and the live capture."
  def record_fixture(name, opts \\ []) do
    {rec, _pid, _dir} = start_recorder(opts)
    id = play(name)
    live = capture([id])
    {:ok, summary} = Recorder.close(rec)
    %{dir: summary.recording_dir, id: id, live: live, summary: summary}
  end

  @doc "A recording rolled into several segments: the B5 fixture in flushed chunks."
  def rolled_recording(segment_bytes \\ 3_000) do
    {rec, _pid, _dir} = start_recorder(segment_bytes: segment_bytes)
    id = FixturePlayer.unique_id("roll")
    lines = FixturePlayer.lines("b5_run1") |> FixturePlayer.with_instance(id)
    socket = FixturePlayer.connect()

    for {chunk, i} <- Enum.with_index(Enum.chunk_every(lines, 9), 1) do
      FixturePlayer.send_lines(socket, chunk)
      FixturePlayer.await(id, i * 9)
      Recorder.flush(rec)
    end

    :gen_tcp.close(socket)
    FixturePlayer.await_closed(id)
    live = capture([id])
    {:ok, summary} = Recorder.close(rec)
    %{dir: summary.recording_dir, id: id, live: live, summary: summary}
  end

  @doc "A copy of a recording directory to damage (the original stays as it was)."
  def copy(dir) do
    dest = tmp_path("glacier-relay-copy")
    File.cp_r!(dir, dest)
    dest
  end

  @doc "Rewrites sha256.txt from the segment files, keeping entries marked unverified."
  def rehash(dir) do
    path = Path.join(dir, "sha256.txt")

    unverified =
      case File.read(path) do
        {:ok, t} ->
          t
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.starts_with?(&1, "unverified"))
          |> Enum.map(&String.replace_prefix(&1, "unverified  ", ""))

        _ ->
          []
      end

    segments =
      dir
      |> Path.join("segment-*.ndjson")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&Path.basename/1)

    text =
      Enum.map_join(segments, "", fn name ->
        if name in unverified do
          "unverified  #{name}\n"
        else
          hash =
            :crypto.hash(:sha256, File.read!(Path.join(dir, name))) |> Base.encode16(case: :lower)

          "#{hash}  #{name}\n"
        end
      end)

    File.write!(path, text)
    dir
  end

  @doc "Marks a segment as unverified in sha256.txt."
  def mark_unverified(dir, name) do
    path = Path.join(dir, "sha256.txt")

    text =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        if String.ends_with?(line, "  " <> name), do: "unverified  " <> name, else: line
      end)
      |> Enum.join("\n")

    File.write!(path, text <> "\n")
    dir
  end

  def lines(path), do: path |> File.read!() |> String.split("\n", trim: true)

  @doc "Applies `fun` to the list of lines of a segment and writes them back (with a final newline)."
  def edit_lines(path, fun) do
    File.write!(path, path |> lines() |> fun.() |> Enum.join("\n") |> Kernel.<>("\n"))
    path
  end

  def segment(dir, n), do: Path.join(dir, GlacierRelay.Recording.Segment.name(n))
end
