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

  # The tests that record for themselves wait on the session's notifications.
  setup do
    :ok = MissionSession.subscribe()
    :ok
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

  # -- durable boundaries (correction A) ---------------------------------------------------------

  defp record_numbers(r, instance),
    do: for(rec <- r.records, rec.map["instance"] == instance, do: rec.no)

  defp authority_of(r, no), do: Enum.find(r.records, &(&1.no == no)).authority
  defp at_or_below(r, boundary), do: for(rec <- r.records, rec.no <= boundary, do: rec.no)
  defp above(r, boundary), do: for(rec <- r.records, rec.no > boundary, do: rec.no)

  test "ordinary rollover: every continuation header states a trusted boundary, and a segment later marked unverified replays as durable",
       %{rolled: rolled} do
    r = read!(rolled.dir)
    assert length(r.segments) >= 3
    assert Enum.map(r.boundaries, & &1.continuation) |> Enum.uniq() == ["roll"]
    assert Enum.all?(r.boundaries, & &1.trusted)

    assert Enum.map(r.boundaries, & &1.applies_to_number) ==
             Enum.to_list(1..(length(r.segments) - 1))

    assert r.issues == [] and Enum.all?(r.records, &(&1.authority == :verified))

    # The hash of segment 2 lost (listed unverified): its records are durable by segment 3's
    # trusted boundary, nothing is unverified, and the replay still equals the live session.
    dir = F.copy(rolled.dir)
    F.mark_unverified(dir, "segment-000002.ndjson")
    r = read!(dir)
    seg2 = Enum.find(r.segments, &(&1.number == 2))
    assert seg2.status == :unverified
    in_seg2 = for rec <- r.records, rec.segment == "segment-000002.ndjson", do: rec
    assert in_seg2 != [] and Enum.all?(in_seg2, &(&1.authority == :durable))
    refute Enum.any?(r.records, &(&1.authority == :unverified))
    {:ok, replay} = Replay.replay(dir)
    c = replay.completeness
    assert c.records.durable == length(in_seg2) and c.records.unverified_used == 0

    assert c.evidence == :authoritative and c.boundaries.untrusted == [] and
             c.boundaries.unstated == []

    assert replay.instances == rolled.live.instances
    assert replay.report_text == rolled.live.report_text.(length(replay.unidentified))
  end

  test "recorder-process restart: the resume header's boundary is trusted and the records before it are durable" do
    {rec, pid, dir} = F.start_recorder()
    a = F.play("stage1", "db-a")
    boundary = F.flush(rec).durable_boundary
    F.kill(pid)
    {:ok, pid2} = GlacierRelay.Recording.Recorder.start_link(name: rec, dir: dir, flush_ms: 20)
    Process.unlink(pid2)
    b = F.play("stage1", "db-b")
    live = F.capture([a, b])
    {:ok, summary} = GlacierRelay.Recording.Recorder.close(rec)
    r = read!(summary.recording_dir)

    assert [%{continuation: "restart", boundary: ^boundary, trusted: true, applies_to_number: 1}] =
             r.boundaries

    assert Enum.all?(record_numbers(r, a), &(authority_of(r, &1) == :durable))
    assert Enum.all?(record_numbers(r, b), &(authority_of(r, &1) == :verified))
    {:ok, replay} = Replay.replay(summary.recording_dir)
    assert replay.instances == live.instances
    assert replay.completeness.evidence == :authoritative
    # No record was issued while the recorder was down, so no gap: the account is authoritative.
    assert replay.completeness.recorder_gaps == [] and replay.completeness.recorder_authoritative?
  end

  test "write failure after a successful sync: the failure-reopened header's boundary is trusted; the synced records are durable, the lost batch is rewritten verified" do
    %{dir: dir, a: a, b: b, boundary: boundary, live: live} =
      F.failed_writer_recording({:fail_append, :enospc})

    r = read!(dir)
    # Segment 1 (abandoned, holds a's synced records only), segment 2 (verified, recovered).
    assert Enum.map(r.segments, &{&1.number, &1.status}) == [{1, :unverified}, {2, :verified}]

    assert [
             %{
               continuation: "write_failure",
               boundary: ^boundary,
               trusted: true,
               applies_to_number: 1
             }
           ] =
             r.boundaries

    assert Enum.all?(record_numbers(r, a), &(authority_of(r, &1) == :durable))
    assert Enum.all?(record_numbers(r, b), &(authority_of(r, &1) == :verified))
    assert r.duplicates == [] and r.conflicts == [] and r.issues == []
    {:ok, replay} = Replay.replay(dir)
    c = replay.completeness

    assert c.records.durable == length(at_or_below(r, boundary)) and
             c.records.unverified_used == 0

    assert c.evidence == :authoritative and c.recorder_gaps == []
    assert c.segments.unverified == ["segment-000001.ndjson"]
    # Every record came from verified or durable evidence with no gap and a clean close: the
    # recorder-level account is authoritative (the unverified segment stays listed as such).
    assert c.recorder_authoritative?
    assert replay.instances == live.instances
  end

  test "sync failure with an unverified tail, a header-only abandoned segment, and the pending records rewritten in a later verified segment" do
    %{dir: dir, a: a, b: b, boundary: boundary, live: live} = F.failed_writer_recording()
    r = read!(dir)

    assert Enum.map(r.segments, &{&1.number, &1.status, &1.header_only}) ==
             [{1, :unverified, false}, {2, :unverified, true}, {3, :verified, false}]

    assert [
             %{segment: "segment-000002.ndjson", boundary: ^boundary, trusted: true},
             %{segment: "segment-000003.ndjson", boundary: ^boundary, trusted: true}
           ] = r.boundaries

    assert Enum.all?(r.boundaries, &(&1.continuation == "write_failure"))
    # a: at or below the boundary in the abandoned segment → durable there.
    a_nos = record_numbers(r, a)
    assert a_nos != [] and Enum.all?(a_nos, &(authority_of(r, &1) == :durable))

    assert Enum.all?(
             a_nos,
             &(Enum.find(r.records, fn x -> x.no == &1 end).segment == "segment-000001.ndjson")
           )

    # b: appended to segment 1 past the boundary (an unverified tail, never claimed) and
    # rewritten in segment 3 — the verified copy is chosen, the tail copies are duplicates.
    b_nos = above(r, boundary)
    assert record_numbers(r, b) != [] and Enum.all?(record_numbers(r, b), &(&1 in b_nos))

    assert Enum.all?(
             b_nos,
             &(Enum.find(r.records, fn x -> x.no == &1 end).segment == "segment-000003.ndjson" and
                 authority_of(r, &1) == :verified)
           )

    assert Enum.sort(r.duplicates) == Enum.sort(Enum.map(b_nos, &{&1, "segment-000001.ndjson"}))
    assert r.conflicts == [] and r.ambiguous == [] and r.issues == []
    {:ok, replay} = Replay.replay(dir)
    c = replay.completeness
    assert c.segments.header_only == ["segment-000002.ndjson"]

    assert c.records.durable == length(at_or_below(r, boundary)) and
             c.records.verified >= length(b_nos)

    assert c.records.unverified_used == 0 and c.records.duplicates == length(b_nos)
    assert c.evidence == :authoritative and c.recorder_authoritative?
    assert replay.instances == live.instances
  end

  test "an old format-1 continuation header with no durable boundary elevates nothing and is not an issue" do
    %{dir: orig, a: a, boundary: boundary} = F.failed_writer_recording()
    dir = F.copy(orig)

    for n <- [2, 3] do
      F.edit_header(
        dir,
        n,
        ~s("resumed":false,"continuation":"write_failure","durable_boundary":#{boundary}),
        ~s("resumed":false,"durable_boundary":null)
      )
    end

    F.rehash(dir)
    r = read!(dir)
    assert r.boundaries == [] and r.issues == []
    a_nos = record_numbers(r, a)
    assert a_nos != [] and Enum.all?(a_nos, &(authority_of(r, &1) == :unverified))
    {:ok, replay} = Replay.replay(dir)
    c = replay.completeness
    assert c.boundaries.unstated == ["segment-000002.ndjson", "segment-000003.ndjson"]

    assert c.records.unverified_used == length(at_or_below(r, boundary)) and
             c.records.durable == 0

    assert c.evidence == :includes_unverified
    refute c.recorder_authoritative?
    assert Enum.any?(c.limitations, &String.contains?(&1, "without a stated durable boundary"))
    refute Enum.any?(c.limitations, &String.contains?(&1, "not trusted"))
  end

  test "a contradictory or invalid durable boundary is reported and elevates nothing" do
    %{dir: orig, a: a, boundary: boundary} = F.failed_writer_recording()
    # Beyond the evidence: no segment before it holds such a record number (both continuation
    # headers raised alike, so the chain stays monotonic and the evidence check is what fails).
    dir = F.copy(orig)
    F.edit_header(dir, 2, ~s("durable_boundary":#{boundary}), ~s("durable_boundary":999999))
    F.edit_header(dir, 3, ~s("durable_boundary":#{boundary}), ~s("durable_boundary":999999))
    F.rehash(dir)
    r = read!(dir)

    assert {:untrusted_durable_boundary, "segment-000002.ndjson", 999_999, :beyond_evidence} in r.issues

    assert Enum.all?(record_numbers(r, a), &(authority_of(r, &1) == :unverified))
    {:ok, replay} = Replay.replay(dir)
    c = replay.completeness

    assert [%{boundary: 999_999, reason: :beyond_evidence}, %{reason: :beyond_evidence}] =
             c.boundaries.untrusted

    assert c.records.unverified_used == length(at_or_below(r, boundary)) and
             c.records.durable == 0

    refute c.recorder_authoritative?
    assert Enum.any?(c.limitations, &String.contains?(&1, "not trusted"))

    # Invalid: not a non-negative integer.
    for bad <- [~s("x"), "-1", "1.5", "true"] do
      dir = F.copy(orig)
      F.edit_header(dir, 2, ~s("durable_boundary":#{boundary}), ~s("durable_boundary":#{bad}))
      r = read!(dir)

      assert Enum.any?(
               r.issues,
               &match?({:invalid_durable_boundary, "segment-000002.ndjson", _}, &1)
             )

      assert Enum.all?(record_numbers(r, a), &(authority_of(r, &1) == :unverified))

      refute Replay.replay(dir)
             |> elem(1)
             |> Map.fetch!(:completeness)
             |> Map.fetch!(:recorder_authoritative?)
    end

    # Chain: the header names the wrong predecessor.
    dir = F.copy(orig)

    F.edit_header(
      dir,
      2,
      ~s("previous_segment":"segment-000001.ndjson"),
      ~s("previous_segment":"segment-000000.ndjson")
    )

    r = read!(dir)
    assert {:untrusted_durable_boundary, "segment-000002.ndjson", boundary, :chain} in r.issues
    assert Enum.any?(r.issues, &match?({:chain_mismatch, "segment-000002.ndjson", _}, &1))
    assert Enum.all?(record_numbers(r, a), &(authority_of(r, &1) == :unverified))

    # Beyond the footer's boundary.
    dir = F.copy(orig)
    footer_boundary = read!(dir).footer["boundary"]
    seg3 = F.lines(F.segment(dir, 3))

    max_present =
      seg3
      |> Enum.map(&elem(GlacierRelay.Recording.Codec.decode_line(&1), 1))
      |> Enum.map(& &1["r"])
      |> Enum.reject(&is_nil/1)
      |> Enum.max()

    assert footer_boundary == max_present
    # Lower the footer's boundary below the header's claim, keeping the claim within evidence.
    F.edit_lines(F.segment(dir, 3), fn lines ->
      List.update_at(
        lines,
        -1,
        &String.replace(&1, ~s("boundary":#{footer_boundary}), ~s("boundary":#{boundary - 1}))
      )
    end)

    F.rehash(dir)
    r = read!(dir)

    assert {:untrusted_durable_boundary, "segment-000002.ndjson", boundary, :beyond_footer} in r.issues
  end

  test "a boundary that decreases along the chain is not trusted on either side", %{
    rolled: rolled
  } do
    dir = F.copy(rolled.dir)
    h2 = F.header(dir, 2)
    h3 = F.header(dir, 3)
    assert h3["durable_boundary"] > h2["durable_boundary"]

    F.edit_header(
      dir,
      3,
      ~s("durable_boundary":#{h3["durable_boundary"]}),
      ~s("durable_boundary":#{h2["durable_boundary"] - 1})
    )

    F.rehash(dir)
    F.mark_unverified(dir, "segment-000002.ndjson")
    r = read!(dir)
    untrusted = for b <- r.boundaries, not b.trusted, do: {b.segment, b.reason}
    assert {"segment-000002.ndjson", :not_monotonic} in untrusted
    assert {"segment-000003.ndjson", :not_monotonic} in untrusted
    in_seg2 = for rec <- r.records, rec.segment == "segment-000002.ndjson", do: rec
    assert in_seg2 != [] and Enum.all?(in_seg2, &(&1.authority == :unverified))

    refute Replay.replay(dir)
           |> elem(1)
           |> Map.fetch!(:completeness)
           |> Map.fetch!(:recorder_authoritative?)
  end

  test "a boundary stated by a hash-mismatched segment is not trusted" do
    %{dir: orig, a: a} = F.failed_writer_recording({:fail_append, :enospc})
    dir = F.copy(orig)
    # Segment 2 verified in sha256.txt; alter one byte of its content (not its header) so the
    # hash no longer matches: the header it carries is then contradicted evidence.
    path = Path.join(dir, "sha256.txt")
    text = File.read!(path)
    [line | _] = String.split(text, "\n")
    <<c, rest::binary>> = line
    File.write!(path, String.replace(text, line, <<if(c == ?0, do: ?1, else: ?0)>> <> rest))
    r = read!(dir)
    assert Enum.find(r.segments, &(&1.number == 2)).status == :hash_mismatch
    assert [%{trusted: false, reason: :segment_hash_mismatch}] = r.boundaries
    assert Enum.all?(r.records, &(&1.authority == :unverified))
    assert record_numbers(r, a) != []
  end

  test "conflicting duplicates with authority established by a trusted boundary, then without" do
    %{dir: orig, a: a, live: live} = F.failed_writer_recording()
    dir = F.copy(orig)
    boundary = F.header(dir, 2)["durable_boundary"]
    # The durable copy of one of a's records in segment 1, altered, appended to the header-only
    # unverified segment 2; segment 3's header is made legacy (no boundary) so that segment 2's
    # copy is unverified while segment 1's stays durable by segment 2's header.
    target =
      F.lines(F.segment(dir, 1))
      |> Enum.find(
        &(String.contains?(&1, ~s("instance":"#{a}")) and String.contains?(&1, ~s("sequence":1,)))
      )

    {:ok, %{"r" => no}} = GlacierRelay.Recording.Codec.decode_line(target)
    assert no <= boundary
    altered = String.replace(target, ~s("codename_hint":"Peacock"), ~s("codename_hint":"Altered"))
    assert altered != target
    F.edit_lines(F.segment(dir, 2), &(&1 ++ [altered]))
    F.edit_header(dir, 3, ~s("durable_boundary":#{boundary}), ~s("durable_boundary":null))
    F.rehash(dir)
    r = read!(dir)
    assert r.conflicts == [{no, "segment-000002.ndjson"}] and r.ambiguous == []
    chosen = Enum.find(r.records, &(&1.no == no))
    assert chosen.segment == "segment-000001.ndjson" and chosen.authority == :durable
    {:ok, replay} = Replay.replay(dir)
    assert replay.instances[a] == live.instances[a]
    refute replay.completeness.recorder_authoritative?

    # Without authority on either side (segment 2's header made legacy too): ambiguous, withheld.
    F.edit_header(dir, 2, ~s("durable_boundary":#{boundary}), ~s("durable_boundary":null))
    r = read!(dir)

    assert r.ambiguous == [no] and
             r.conflicts == [{no, ["segment-000001.ndjson", "segment-000002.ndjson"]}]

    refute Enum.any?(r.records, &(&1.no == no))
    {:ok, replay} = Replay.replay(dir)
    assert replay.completeness.evidence == :ambiguous and replay.instances[a] != live.instances[a]
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
