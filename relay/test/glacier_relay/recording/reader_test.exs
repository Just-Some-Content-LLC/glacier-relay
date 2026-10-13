defmodule GlacierRelay.Recording.ReaderTest do
  @moduledoc """
  The recording reader on damaged copies of real recordings (M4-B): every anomaly is reported,
  nothing is repaired, duplicates and conflicts across segments are resolved conservatively.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.MissionSession
  alias GlacierRelay.Recording.{Reader, Replay}
  alias GlacierRelay.Test.RecordingFixtures, as: F

  setup_all do
    :ok = MissionSession.subscribe()
    base = F.record_fixture("b2_probe")
    rolled = F.rolled_recording()
    %{base: base, rolled: rolled}
  end

  defp read!(dir) do
    {:ok, r} = Reader.read(dir)
    r
  end

  test "a clean recording: verified, chained, footer, marker, no issues", %{base: base} do
    r = read!(base.dir)
    assert r.recording_id == base.summary.recording_id and r.format == [1]
    assert [%{status: :verified, number: 1, header_only: false, corrupt_tail: nil}] = r.segments

    assert r.closed_marker and r.footer["reason"] == "close" and
             r.footer["boundary"] == r.last_record_no

    assert r.issues == [] and r.missing_segments == [] and r.unexplained_missing == []
    assert r.duplicates == [] and r.conflicts == [] and r.ambiguous == []
    assert Enum.all?(r.records, &(&1.authority == :verified))
    assert Enum.map(r.records, & &1.no) == Enum.to_list(r.first_record_no..r.last_record_no)
    # Read-only: the files are untouched.
    before = File.ls!(base.dir) |> Enum.sort()
    read!(base.dir)
    assert File.ls!(base.dir) |> Enum.sort() == before
  end

  test "missing CLOSED marker", %{base: base} do
    dir = F.copy(base.dir)
    File.rm!(Path.join(dir, "CLOSED"))
    r = read!(dir)
    refute r.closed_marker
    assert {:footer_without_closed_marker, "segment-000001.ndjson"} in r.issues
    {:ok, replay} = Replay.replay(dir)
    assert replay.completeness.finalization == :unclosed
    refute replay.completeness.recorder_authoritative?
  end

  test "missing footer", %{base: base} do
    dir = F.copy(base.dir)
    F.edit_lines(F.segment(dir, 1), &Enum.drop(&1, -1))
    F.rehash(dir)
    r = read!(dir)
    assert r.footer == nil and {:closed_marker_without_footer, "CLOSED"} in r.issues

    assert Replay.replay(dir) |> elem(1) |> Map.fetch!(:completeness) |> Map.fetch!(:finalization) ==
             :unclosed
  end

  test "corrupt partial final line", %{base: base} do
    dir = F.copy(base.dir)
    path = F.segment(dir, 1)
    bytes = File.read!(path)
    File.write!(path, binary_part(bytes, 0, byte_size(bytes) - 25))
    F.rehash(dir)
    r = read!(dir)
    assert [%{corrupt_tail: tail}] = r.segments
    assert is_integer(tail) and tail > 0
    assert r.corrupt_tails == ["segment-000001.ndjson"] and r.footer == nil
    assert {:corrupt_tail, "segment-000001.ndjson", tail} in r.issues

    refute Replay.replay(dir)
           |> elem(1)
           |> Map.fetch!(:completeness)
           |> Map.fetch!(:recorder_authoritative?)
  end

  test "corrupt middle line: the record is missing and unexplained", %{base: base} do
    dir = F.copy(base.dir)
    F.edit_lines(F.segment(dir, 1), fn lines -> List.replace_at(lines, 3, "{\"r\":garbage") end)
    F.rehash(dir)
    r = read!(dir)
    assert r.corrupt_lines == 1
    missing = r.first_record_no + 2
    assert r.unexplained_missing == [{missing, missing}]
    assert Enum.any?(r.issues, &match?({:error, "segment-000001.ndjson", 4, _}, &1))
    {:ok, replay} = Replay.replay(dir)

    assert Enum.any?(
             replay.completeness.limitations,
             &String.contains?(&1, "missing record number")
           )

    refute replay.completeness.recorder_authoritative?
  end

  test "missing segment in a rolled recording", %{rolled: rolled} do
    dir = F.copy(rolled.dir)
    File.rm!(F.segment(dir, 2))
    r = read!(dir)
    assert r.missing_segments == [2]
    assert {:missing_segment, 2} in r.issues
    # Segment 3's header still names segment 2 as its predecessor (the chain is consistent; the
    # file is what is missing), and the records segment 2 held are unexplained missing numbers.
    refute Enum.any?(r.issues, &match?({:chain_mismatch, _, _}, &1))
    assert r.unexplained_missing != []
    {:ok, replay} = Replay.replay(dir)
    assert replay.completeness.segments.missing == [2]
    refute replay.completeness.recorder_authoritative?
  end

  test "hash mismatch is treated as unverified and reported", %{base: base} do
    dir = F.copy(base.dir)
    path = Path.join(dir, "sha256.txt")
    text = File.read!(path)
    <<c, rest::binary>> = text
    File.write!(path, <<if(c == ?0, do: ?1, else: ?0)>> <> rest)
    r = read!(dir)
    assert [%{status: :hash_mismatch}] = r.segments
    assert {:hash_mismatch, "segment-000001.ndjson"} in r.issues
    assert Enum.all?(r.records, &(&1.authority == :unverified))
    {:ok, replay} = Replay.replay(dir)
    assert replay.completeness.segments.hash_mismatch == ["segment-000001.ndjson"]
    assert replay.completeness.evidence == :includes_unverified
    refute replay.completeness.recorder_authoritative?
  end

  test "no sha256.txt at all: every record is unverified evidence", %{base: base} do
    dir = F.copy(base.dir)
    File.rm!(Path.join(dir, "sha256.txt"))
    r = read!(dir)
    assert r.hashes_file == nil and {:no_hashes_file, "sha256.txt"} in r.issues
    assert Enum.all?(r.records, &(&1.authority == :unverified))
  end

  test "identical duplicates across an unverified and a verified segment are noted, not folded twice",
       %{base: base} do
    dir = F.copy(base.dir)
    seg1 = F.lines(F.segment(dir, 1))
    [header | rest] = seg1
    records = Enum.filter(rest, &String.starts_with?(&1, "{\"r\":"))

    header2 =
      header
      |> String.replace("\"segment\":1", "\"segment\":2")
      |> String.replace(
        "\"previous_segment\":null",
        "\"previous_segment\":\"segment-000001.ndjson\""
      )
      |> String.replace("\"previous_unverified\":false", "\"previous_unverified\":true")

    # Segment 2 repeats every record and carries the footer; segment 1 is marked unverified.
    footer = List.last(seg1)
    File.write!(F.segment(dir, 2), Enum.join([header2 | records] ++ [footer], "\n") <> "\n")
    F.edit_lines(F.segment(dir, 1), &Enum.drop(&1, -1))
    F.rehash(dir)
    F.mark_unverified(dir, "segment-000001.ndjson")
    r = read!(dir)
    assert length(r.duplicates) == length(records) and r.conflicts == [] and r.ambiguous == []

    assert Enum.all?(
             r.records,
             &(&1.segment == "segment-000002.ndjson" and &1.authority == :verified)
           )

    assert length(r.records) == length(records)
    {:ok, replay} = Replay.replay(dir)
    assert replay.completeness.records.duplicates == length(records)
    assert replay.completeness.evidence == :authoritative
    assert replay.instances == base.live.instances
  end

  test "conflicting duplicates: the authoritative copy wins and the conflict is reported; without authority the number is withheld",
       %{base: base} do
    dir = F.copy(base.dir)
    seg1 = F.lines(F.segment(dir, 1))
    [header | rest] = seg1
    records = Enum.filter(rest, &String.starts_with?(&1, "{\"r\":"))
    target = Enum.find(records, &String.contains?(&1, "\"event_type\":\"contract.started\""))
    altered = String.replace(target, "\"difficulty_level\":2", "\"difficulty_level\":3")
    assert altered != target

    header2 =
      header
      |> String.replace("\"segment\":1", "\"segment\":2")
      |> String.replace(
        "\"previous_segment\":null",
        "\"previous_segment\":\"segment-000001.ndjson\""
      )

    File.write!(F.segment(dir, 2), Enum.join([header2, altered], "\n") <> "\n")
    F.rehash(dir)
    F.mark_unverified(dir, "segment-000002.ndjson")
    r = read!(dir)
    {:ok, %{"r" => no}} = GlacierRelay.Recording.Codec.decode_line(target)
    assert r.conflicts == [{no, "segment-000002.ndjson"}] and r.ambiguous == []
    assert Enum.find(r.records, &(&1.no == no)).segment == "segment-000001.ndjson"
    {:ok, replay} = Replay.replay(dir)
    assert replay.completeness.records.conflicts == 1 and replay.instances == base.live.instances
    refute replay.completeness.recorder_authoritative?

    # Both unverified: ambiguous, withheld.
    F.mark_unverified(dir, "segment-000001.ndjson")
    r = read!(dir)

    assert r.ambiguous == [no] and
             r.conflicts == [{no, ["segment-000001.ndjson", "segment-000002.ndjson"]}]

    refute Enum.any?(r.records, &(&1.no == no))
    {:ok, replay} = Replay.replay(dir)

    assert replay.completeness.evidence == :ambiguous and
             replay.completeness.records.ambiguous == [no]

    assert replay.instances != base.live.instances
    assert Enum.any?(replay.completeness.limitations, &String.contains?(&1, "withheld"))
  end

  test "header-only segment, unknown record kind, unsupported format", %{base: base} do
    dir = F.copy(base.dir)
    header = F.lines(F.segment(dir, 1)) |> hd()

    header2 =
      header
      |> String.replace("\"segment\":1", "\"segment\":2")
      |> String.replace(
        "\"previous_segment\":null",
        "\"previous_segment\":\"segment-000001.ndjson\""
      )

    File.write!(F.segment(dir, 2), header2 <> "\n")

    F.edit_lines(F.segment(dir, 1), fn lines ->
      List.insert_at(lines, -2, "{\"k\":\"future.kind\",\"x\":1}")
    end)

    F.rehash(dir)
    r = read!(dir)
    assert Enum.find(r.segments, &(&1.number == 2)).header_only
    assert r.unknown_kinds == %{"future.kind" => 1}
    assert Enum.any?(r.issues, &match?({:footer_not_last, "segment-000001.ndjson", _}, &1))
    {:ok, replay} = Replay.replay(dir)
    assert replay.completeness.segments.header_only == ["segment-000002.ndjson"]
    assert replay.completeness.unknown_kinds == %{"future.kind" => 1}
    refute replay.completeness.recorder_authoritative?

    dir = F.copy(base.dir)

    F.edit_lines(F.segment(dir, 1), fn [h | t] ->
      [String.replace(h, "\"format\":1", "\"format\":2") | t]
    end)

    F.rehash(dir)
    r = read!(dir)
    assert {:unsupported_format, 2} in r.issues and r.format == [2]
    assert r.records != []
    {:ok, replay} = Replay.replay(dir)
    assert replay.completeness.format == {:unsupported, [2]}
    refute replay.completeness.recorder_authoritative?
  end

  test "a malformed session record is skipped and counted; an oversized line is corrupt", %{
    base: base
  } do
    dir = F.copy(base.dir)

    F.edit_lines(F.segment(dir, 1), fn lines ->
      lines
      |> List.insert_at(-2, "{\"r\":999999,\"k\":\"envelope\",\"at\":null,\"conn\":\"x\"}")
      |> List.insert_at(
        -2,
        "{\"k\":\"recorder.gap\",\"from\":1,\"to\":\"" <>
          String.duplicate("a", 1_100_000) <> "\"}"
      )
    end)

    F.rehash(dir)
    r = read!(dir)
    assert r.malformed_records == 1 and r.corrupt_lines == 1
    assert Enum.any?(r.issues, &match?({:malformed, _, _, _}, &1))
    assert Enum.any?(r.issues, &match?({:error, _, _, ":line_too_long"}, &1))
    refute Enum.any?(r.records, &(&1.no == 999_999))
  end

  test "a directory without segments is an error, not a crash" do
    dir =
      Path.join(System.tmp_dir!(), "glacier-relay-empty-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(dir) end)
    File.mkdir_p!(dir)
    assert {:error, {:no_segments, ^dir}} = Reader.read(dir)
    assert {:error, {:enoent, _}} = Reader.read(dir <> "-missing")
  end
end
