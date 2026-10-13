defmodule GlacierRelay.Recording.Reader do
  @moduledoc """
  The read-only, deterministic reader of format-1 recordings (M4-B, ADR 0008). It inspects a
  recording directory — segments, headers and their chain, `sha256.txt`, `CLOSED`, the footer,
  every line — and resolves the session records conservatively by record number, segment
  provenance and the durable boundaries the headers state. It never writes, repairs, deletes or
  overwrites anything, never creates an atom from the file's strings, and bounds what it keeps
  about malformed input.

  Record precedence (design section 18):

  1. **authoritative** — a record in a verified segment (its hash equals the one in
     `sha256.txt`), or in an unverified segment at or below the durable boundary that the next
     segment's resume header states;
  2. **unverified** — a parseable record in an unverified segment beyond any stated boundary;
  3. a **duplicate** is a record number seen again with identical content (kept as a note);
  4. a **conflict** is the same number with different content; an authoritative record wins
     over an unverified one (reported, never silent); two differing candidates with no
     authority between them are **ambiguous** and the number is withheld from replay;
  5. a **missing** number is one between the first and the last that no segment holds; it is
     explained when a `recorder.gap` covers it, unexplained otherwise;
  6. an **unverifiable tail** is a partial last line, or an unverified segment with no later
     boundary to judge it by.
  """

  alias GlacierRelay.Recording.{Codec, Segment}

  @session_kinds ~w(connection.opened connection.identified envelope connection.closed)
  @diagnostic_kinds ~w(recording.opened recorder.gap recorder.recovered recording.closed)
  @max_line_bytes 1_048_576
  @max_examples 20

  defmodule Result do
    @moduledoc "What the reader established about one recording directory."
    defstruct dir: nil,
              recording_id: nil,
              format: nil,
              segments: [],
              missing_segments: [],
              hashes_file: nil,
              closed_marker: false,
              footer: nil,
              gaps: [],
              recovered: [],
              records: [],
              duplicates: [],
              conflicts: [],
              ambiguous: [],
              first_record_no: nil,
              last_record_no: nil,
              unexplained_missing: [],
              open_ended_gaps: [],
              unknown_kinds: %{},
              malformed_records: 0,
              corrupt_lines: 0,
              corrupt_tails: [],
              issues: []
  end

  @doc "Reads and verifies a recording directory."
  @spec read(String.t()) :: {:ok, Result.t()} | {:error, term()}
  def read(dir) when is_binary(dir) do
    with {:ok, names} <- segment_names(dir) do
      hashes = read_hashes(Path.join(dir, "sha256.txt"))
      closed = File.exists?(Path.join(dir, "CLOSED"))
      segments = Enum.map(names, &read_segment(dir, &1, hashes))

      result =
        %Result{
          dir: dir,
          recording_id: Path.basename(dir),
          hashes_file: hashes,
          closed_marker: closed,
          segments: segments
        }
        |> check_chain()
        |> collect_diagnostics()
        |> resolve_records()
        |> check_footer()

      {:ok, result}
    end
  end

  # -- files ----------------------------------------------------------------------------------

  defp segment_names(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        names =
          entries |> Enum.filter(&Regex.match?(~r/^segment-\d{6}\.ndjson$/, &1)) |> Enum.sort()

        if names == [], do: {:error, {:no_segments, dir}}, else: {:ok, names}

      {:error, reason} ->
        {:error, {reason, dir}}
    end
  end

  # sha256.txt: "<hex>  <name>" or "unverified  <name>" per line. Absent → nil.
  defp read_hashes(path) do
    case File.read(path) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, "  ", parts: 2) do
            ["unverified", name] -> Map.put(acc, name, :unverified)
            [hex, name] when byte_size(hex) == 64 -> Map.put(acc, name, hex)
            _ -> acc
          end
        end)

      {:error, _} ->
        nil
    end
  end

  defp read_segment(dir, name, hashes) do
    path = Path.join(dir, name)
    number = name |> String.slice(8, 6) |> String.to_integer()
    bytes = File.read!(path)
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    listed = if hashes, do: Map.get(hashes, name, :unlisted), else: :unlisted

    status =
      cond do
        listed == hash -> :verified
        listed in [:unverified, :unlisted] -> :unverified
        true -> :hash_mismatch
      end

    {lines, tail} = split_lines(bytes)

    parsed =
      lines
      |> Enum.with_index(1)
      |> Enum.map(fn {line, n} -> {n, parse_line(line)} end)

    header =
      case parsed do
        [{1, {:ok, %{"k" => "recording.opened"} = h}} | _] -> h
        _ -> nil
      end

    %{
      name: name,
      number: number,
      path: path,
      bytes: byte_size(bytes),
      hash: hash,
      listed: listed,
      status: status,
      header: header,
      format: header && header["format"],
      lines: length(lines),
      parsed: parsed,
      corrupt_tail: tail,
      header_only: header != nil and length(lines) == 1 and tail == nil
    }
  end

  # Lines end in "\n"; bytes after the last newline are a partial (corrupt) tail.
  defp split_lines(bytes) do
    case String.split(bytes, "\n") do
      [] ->
        {[], nil}

      parts ->
        {init, [last]} = Enum.split(parts, -1)
        {init, if(last == "", do: nil, else: byte_size(last))}
    end
  end

  defp parse_line(line) when byte_size(line) > @max_line_bytes, do: {:error, :line_too_long}

  defp parse_line(line) do
    case Codec.decode_line(line) do
      {:ok, %{"k" => k} = map} when is_binary(k) ->
        cond do
          k in @session_kinds -> if session_record?(map), do: {:ok, map}, else: {:malformed, map}
          k in @diagnostic_kinds -> {:ok, map}
          true -> {:unknown, map}
        end

      {:ok, _} ->
        {:error, :no_kind}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp session_record?(%{"r" => r} = m) when is_integer(r) and r > 0 do
    conn_ok = is_nil(m["conn"]) or (is_integer(m["conn"]) and m["conn"] > 0)
    at_ok = is_nil(m["at"]) or is_binary(m["at"])

    kind_ok =
      case m["k"] do
        "envelope" ->
          is_map(m["envelope"]) and is_integer(m["sequence"]) and is_binary(m["event_type"])

        "connection.opened" ->
          is_integer(m["conn"]) and is_binary(m["peer"])

        "connection.identified" ->
          is_integer(m["conn"]) and is_binary(m["instance"])

        "connection.closed" ->
          is_integer(m["conn"])
      end

    conn_ok and at_ok and kind_ok
  end

  defp session_record?(_), do: false

  # -- chain --------------------------------------------------------------------------------------

  defp check_chain(%Result{segments: segments} = r) do
    numbers = Enum.map(segments, & &1.number)
    max = Enum.max(numbers)
    missing = Enum.to_list(1..max) -- numbers

    ids =
      segments
      |> Enum.map(&(&1.header && &1.header["recording_id"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    formats = segments |> Enum.map(& &1.format) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    issues =
      Enum.flat_map(segments, fn seg ->
        h = seg.header

        cond do
          h == nil -> [{:no_header, seg.name}]
          h["segment"] != seg.number -> [{:header_segment_mismatch, seg.name, h["segment"]}]
          true -> []
        end ++
          case {h, seg.number} do
            {nil, _} ->
              []

            {%{"previous_segment" => nil}, 1} ->
              []

            {%{"previous_segment" => prev}, n} when n > 1 ->
              if prev == Segment.name(n - 1), do: [], else: [{:chain_mismatch, seg.name, prev}]

            {_, n} when n > 1 ->
              [{:chain_mismatch, seg.name, nil}]

            _ ->
              []
          end ++
          if(seg.status == :hash_mismatch, do: [{:hash_mismatch, seg.name}], else: []) ++
          if(seg.corrupt_tail, do: [{:corrupt_tail, seg.name, seg.corrupt_tail}], else: [])
      end) ++
        Enum.map(missing, &{:missing_segment, &1}) ++
        if(length(ids) > 1, do: [{:recording_id_mismatch, ids}], else: []) ++
        if(r.hashes_file == nil, do: [{:no_hashes_file, "sha256.txt"}], else: []) ++
        Enum.flat_map(formats, fn f ->
          if f == Codec.format(), do: [], else: [{:unsupported_format, f}]
        end)

    recording_id = List.first(ids) || r.recording_id

    %{
      r
      | missing_segments: missing,
        issues: r.issues ++ issues,
        recording_id: recording_id,
        format: if(formats == [], do: nil, else: formats)
    }
  end

  # -- diagnostics ---------------------------------------------------------------------------------

  defp collect_diagnostics(%Result{segments: segments} = r) do
    all = for seg <- segments, {n, parsed} <- seg.parsed, do: {seg, n, parsed}

    gaps =
      for {seg, _n, {:ok, %{"k" => "recorder.gap"} = g}} <- all,
          do: Map.put(g, "segment", seg.name)

    recovered =
      for {seg, _n, {:ok, %{"k" => "recorder.recovered"} = g}} <- all,
          do: Map.put(g, "segment", seg.name)

    unknown =
      all
      |> Enum.filter(&match?({_, _, {:unknown, _}}, &1))
      |> Enum.reduce(%{}, fn {_, _, {:unknown, m}}, acc ->
        Map.update(acc, m["k"], 1, &(&1 + 1))
      end)

    corrupt = Enum.count(all, &match?({_, _, {:error, _}}, &1))
    malformed = Enum.count(all, &match?({_, _, {:malformed, _}}, &1))

    examples =
      all
      |> Enum.filter(&match?({_, _, {kind, _}} when kind in [:error, :malformed], &1))
      |> Enum.take(@max_examples)
      |> Enum.map(fn {seg, n, {kind, detail}} ->
        {kind, seg.name, n, detail |> inspect() |> String.slice(0, 120)}
      end)

    %{
      r
      | gaps: gaps,
        recovered: recovered,
        unknown_kinds: unknown,
        corrupt_lines: corrupt,
        malformed_records: malformed,
        corrupt_tails: for(seg <- segments, seg.corrupt_tail, do: seg.name),
        issues: r.issues ++ examples
    }
  end

  # -- record resolution ---------------------------------------------------------------------------

  defp resolve_records(%Result{segments: segments} = r) do
    boundaries = boundaries(segments)

    candidates =
      for seg <- segments,
          {_n, {:ok, %{"r" => no} = map}} <- seg.parsed,
          map["k"] in @session_kinds do
        authority =
          cond do
            seg.status == :verified -> :verified
            is_integer(boundaries[seg.number]) and no <= boundaries[seg.number] -> :durable
            true -> :unverified
          end

        {no, %{segment: seg.name, authority: authority, map: map}}
      end
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    {records, duplicates, conflicts, ambiguous} =
      candidates
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce({[], [], [], []}, fn {no, cands}, {recs, dups, confs, ambs} ->
        authoritative = Enum.filter(cands, &(&1.authority != :unverified))
        unverified = Enum.filter(cands, &(&1.authority == :unverified))

        distinct = fn list -> list |> Enum.map(& &1.map) |> Enum.uniq() |> length() end

        cond do
          authoritative != [] and distinct.(authoritative) > 1 ->
            {recs, dups, [{no, Enum.map(authoritative, & &1.segment)} | confs], [no | ambs]}

          authoritative != [] ->
            chosen = hd(authoritative)
            others = tl(authoritative) ++ unverified
            {same, differ} = Enum.split_with(others, &(&1.map == chosen.map))

            {[
               %{
                 no: no,
                 kind: chosen.map["k"],
                 map: chosen.map,
                 segment: chosen.segment,
                 authority: chosen.authority
               }
               | recs
             ], Enum.map(same, &{no, &1.segment}) ++ dups,
             Enum.map(differ, &{no, &1.segment}) ++ confs, ambs}

          distinct.(unverified) == 1 ->
            chosen = hd(unverified)

            {[
               %{
                 no: no,
                 kind: chosen.map["k"],
                 map: chosen.map,
                 segment: chosen.segment,
                 authority: :unverified
               }
               | recs
             ], Enum.map(tl(unverified), &{no, &1.segment}) ++ dups, confs, ambs}

          true ->
            {recs, dups, [{no, Enum.map(unverified, & &1.segment)} | confs], [no | ambs]}
        end
      end)

    records = Enum.reverse(records)
    numbers = Enum.map(records, & &1.no) ++ ambiguous
    {first, last} = if numbers == [], do: {nil, nil}, else: {Enum.min(numbers), Enum.max(numbers)}

    present = MapSet.new(numbers)
    explained = gap_cover(r.gaps)
    open_ended = Enum.filter(r.gaps, &is_nil(&1["to"]))

    missing =
      if first do
        first..last
        |> Enum.reject(
          &(MapSet.member?(present, &1) or MapSet.member?(explained, &1) or
              open_from?(open_ended, &1))
        )
        |> ranges()
      else
        []
      end

    %{
      r
      | records: records,
        duplicates: Enum.reverse(duplicates),
        conflicts: Enum.reverse(conflicts),
        ambiguous: Enum.sort(ambiguous),
        first_record_no: first,
        last_record_no: last,
        unexplained_missing: missing,
        open_ended_gaps: open_ended
    }
  end

  # The durable boundary a later resume header states for the segment before it.
  defp boundaries(segments) do
    for seg <- segments,
        seg.header,
        seg.header["resumed"] == true,
        is_integer(seg.header["durable_boundary"]),
        seg.number > 1,
        into: %{} do
      {seg.number - 1, seg.header["durable_boundary"]}
    end
  end

  defp gap_cover(gaps) do
    for g <- gaps,
        is_integer(g["from"]),
        is_integer(g["to"]),
        g["to"] >= g["from"],
        n <- g["from"]..g["to"],
        into: MapSet.new(),
        do: n
  end

  defp open_from?(open_ended, n),
    do: Enum.any?(open_ended, &(is_integer(&1["from"]) and n >= &1["from"]))

  defp ranges([]), do: []

  defp ranges([first | rest]) do
    rest
    |> Enum.reduce([{first, first}], fn n, [{from, to} | tail] = acc ->
      if n == to + 1, do: [{from, n} | tail], else: [{n, n} | acc]
    end)
    |> Enum.reverse()
  end

  # -- footer ------------------------------------------------------------------------------------

  defp check_footer(%Result{segments: segments} = r) do
    last = List.last(segments)

    footer =
      case List.last(last.parsed) do
        {_n, {:ok, %{"k" => "recording.closed"} = f}} when is_nil(last.corrupt_tail) -> f
        _ -> nil
      end

    stray =
      for seg <- segments,
          {n, {:ok, %{"k" => "recording.closed"}}} <- seg.parsed,
          seg != last or n != last.lines do
        {:footer_not_last, seg.name, n}
      end

    issues =
      stray ++
        if(r.closed_marker and footer == nil,
          do: [{:closed_marker_without_footer, "CLOSED"}],
          else: []
        ) ++
        if(footer != nil and not r.closed_marker,
          do: [{:footer_without_closed_marker, last.name}],
          else: []
        )

    %{r | footer: footer, issues: r.issues ++ issues}
  end
end
