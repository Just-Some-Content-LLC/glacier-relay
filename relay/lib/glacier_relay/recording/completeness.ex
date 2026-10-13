defmodule GlacierRelay.Recording.Completeness do
  @moduledoc """
  The completeness account of a replay (M4-B, ADR 0008): what the recorder wrote, what it knows
  it missed, what is unverifiable, what the current code rejected, what the Relay stream itself
  lost, and what remains unknown — each kept apart, never collapsed into one boolean. The one
  boolean it does carry, `recorder_authoritative?`, says only that every record between the
  first and the boundary came from verified or durable (trusted-boundary) evidence, with no
  gap, no corruption, no ambiguity, no reader issue of any kind and a clean finalization; it
  says nothing about the Relay stream or the game, and nothing about type fidelity: a close
  reason the format could only record as text is listed under `close_reasons.qualified`, and
  term equality with the live session is not claimed for it.
  """

  alias GlacierRelay.Recording.Replay

  defstruct source: nil,
            format: nil,
            finalization: nil,
            closed_marker: false,
            footer_reason: nil,
            footer_boundary: nil,
            segments: %{
              verified: [],
              unverified: [],
              hash_mismatch: [],
              missing: [],
              header_only: []
            },
            records: %{
              first: nil,
              last: nil,
              resolved: 0,
              authoritative: 0,
              verified: 0,
              durable: 0,
              unverified_used: 0,
              duplicates: 0,
              conflicts: 0,
              ambiguous: []
            },
            boundaries: %{trusted: [], untrusted: [], unstated: []},
            close_reasons: %{exact: 0, qualified: []},
            recorder_gaps: [],
            open_ended_gaps: [],
            unexplained_missing: [],
            corrupt_lines: 0,
            corrupt_tails: [],
            malformed_records: 0,
            unknown_kinds: %{},
            rejected_by_current_validator: [],
            replay_issues: [],
            relay_sequence_gaps: %{},
            transport: nil,
            receipt_times: nil,
            native_drops: :unknown,
            evidence: nil,
            recorder_authoritative?: false,
            limitations: []

  @type t :: %__MODULE__{}

  @doc "Builds the account from a replay (its reader result, fold and issues)."
  @spec account(Replay.t()) :: t()
  def account(%Replay{source: :legacy} = replay) do
    gaps = sequence_gaps(replay.instances)

    %__MODULE__{
      source: :legacy,
      format: :legacy,
      finalization: :not_applicable,
      records: %{
        first: replay.first_record_no,
        last: replay.boundary,
        resolved: replay.boundary || 0,
        authoritative: 0,
        verified: 0,
        durable: 0,
        unverified_used: 0,
        duplicates: 0,
        conflicts: 0,
        ambiguous: []
      },
      close_reasons: %{exact: 0, qualified: []},
      rejected_by_current_validator: replay.rejected,
      relay_sequence_gaps: gaps,
      transport: :not_recorded,
      receipt_times: :unavailable,
      native_drops: :unknown,
      evidence: :legacy,
      recorder_authoritative?: false,
      limitations:
        [
          "legacy source: envelope values only; connection evidence was not recorded, so \"observation never\" means not recorded, not that no connection existed",
          "receipt times unavailable: every received_at is nil",
          "native-side drops unknown: no native evidence supplied"
        ] ++ rejected_limitation(replay.rejected) ++ gap_limitation(gaps)
    }
  end

  def account(%Replay{reader: r} = replay) do
    segments = %{
      verified: for(s <- r.segments, s.status == :verified, do: s.name),
      unverified: for(s <- r.segments, s.status == :unverified, do: s.name),
      hash_mismatch: for(s <- r.segments, s.status == :hash_mismatch, do: s.name),
      missing: r.missing_segments,
      header_only: for(s <- r.segments, s.header_only, do: s.name)
    }

    verified = Enum.count(r.records, &(&1.authority == :verified))
    durable = Enum.count(r.records, &(&1.authority == :durable))
    unverified_used = Enum.count(r.records, &(&1.authority == :unverified))

    records = %{
      first: r.first_record_no,
      last: r.last_record_no,
      resolved: length(r.records),
      authoritative: verified + durable,
      verified: verified,
      durable: durable,
      unverified_used: unverified_used,
      duplicates: length(r.duplicates),
      conflicts: length(r.conflicts),
      ambiguous: r.ambiguous
    }

    boundaries = %{
      trusted: for(b <- r.boundaries, b.trusted, do: b),
      untrusted: for(b <- r.boundaries, not b.trusted, do: b),
      # Continuation headers that state no boundary (format 1 before correction A): valid
      # historical evidence with reduced certainty; the preceding segment's records are not
      # elevated and nothing is inferred.
      unstated:
        for(
          s <- r.segments,
          s.number > 1,
          s.header != nil,
          Map.get(s.header, "durable_boundary") == nil,
          do: s.name
        )
    }

    closes = Enum.count(r.records, &(&1.kind == "connection.closed"))

    close_reasons = %{
      exact: closes - length(replay.qualified_reasons),
      qualified: replay.qualified_reasons
    }

    finalization =
      cond do
        r.footer == nil -> :unclosed
        r.footer["reason"] == "budget" -> :budget
        r.closed_marker -> :clean
        true -> :unclosed
      end

    format =
      case r.format do
        [1] -> 1
        nil -> :unknown
        other -> {:unsupported, other}
      end

    gaps =
      for g <- r.gaps,
          is_integer(g["to"]),
          do: %{from: g["from"], to: g["to"], cause: g["cause"], segment: g["segment"]}

    open_ended =
      for g <- r.open_ended_gaps, do: %{from: g["from"], cause: g["cause"], segment: g["segment"]}

    evidence =
      cond do
        r.ambiguous != [] -> :ambiguous
        unverified_used > 0 -> :includes_unverified
        true -> :authoritative
      end

    sequence_gaps = sequence_gaps(replay.instances)

    authoritative? =
      finalization == :clean and format == 1 and segments.hash_mismatch == [] and
        segments.missing == [] and
        evidence == :authoritative and gaps == [] and open_ended == [] and
        r.unexplained_missing == [] and
        r.corrupt_lines == 0 and r.corrupt_tails == [] and r.malformed_records == 0 and
        r.unknown_kinds == %{} and
        replay.rejected == [] and replay.issues == [] and r.issues == [] and r.conflicts == []

    %__MODULE__{
      source: :recording,
      format: format,
      finalization: finalization,
      closed_marker: r.closed_marker,
      footer_reason: r.footer && r.footer["reason"],
      footer_boundary: r.footer && r.footer["boundary"],
      segments: segments,
      records: records,
      boundaries: boundaries,
      close_reasons: close_reasons,
      recorder_gaps: gaps,
      open_ended_gaps: open_ended,
      unexplained_missing: r.unexplained_missing,
      corrupt_lines: r.corrupt_lines,
      corrupt_tails: r.corrupt_tails,
      malformed_records: r.malformed_records,
      unknown_kinds: r.unknown_kinds,
      rejected_by_current_validator: replay.rejected,
      replay_issues: replay.issues ++ r.issues,
      relay_sequence_gaps: sequence_gaps,
      transport: :recorded,
      receipt_times: :recorded,
      native_drops: :unknown,
      evidence: evidence,
      recorder_authoritative?: authoritative?,
      limitations:
        limitations(finalization, format, segments, records, gaps, open_ended, r, replay) ++
          boundary_limitations(boundaries) ++
          reason_limitation(replay.qualified_reasons) ++
          rejected_limitation(replay.rejected) ++
          gap_limitation(sequence_gaps) ++
          [
            "native-side drops unknown: no native evidence supplied; a recording cannot show them to be zero"
          ]
    }
  end

  defp sequence_gaps(instances) do
    for {id, inst} <- instances, inst.gaps != [], into: %{}, do: {id, Enum.reverse(inst.gaps)}
  end

  defp limitations(finalization, format, segments, records, gaps, open_ended, r, replay) do
    [
      case finalization do
        :clean ->
          nil

        :budget ->
          "finalized by the disk budget: the recording is not an account of session activity after record #{r.footer["boundary"]}"

        :unclosed ->
          "not cleanly closed: no footer and marker; the tail is unverifiable and the recording's end is not a session boundary"
      end,
      if(format != 1,
        do: "format #{inspect(format)} is not the supported format 1; best-effort inspection only"
      ),
      if(segments.hash_mismatch != [],
        do: "hash mismatch: #{Enum.join(segments.hash_mismatch, ", ")} (treated as unverified)"
      ),
      if(segments.missing != [], do: "missing segment(s): #{Enum.join(segments.missing, ", ")}"),
      if(segments.unverified != [],
        do: "unverified segment(s): #{Enum.join(segments.unverified, ", ")}"
      ),
      if(records.unverified_used > 0,
        do:
          "#{records.unverified_used} record(s) replayed from unverified evidence (no verified or durable copy)"
      ),
      if(records.ambiguous != [],
        do: "ambiguous record number(s) withheld from replay: #{inspect(records.ambiguous)}"
      ),
      if(records.conflicts > 0,
        do:
          "#{records.conflicts} conflicting duplicate(s) across segments (authoritative copy used where one exists)"
      ),
      if(gaps != [],
        do:
          "recorder gaps: " <> Enum.map_join(gaps, "; ", &"r=#{&1.from}..#{&1.to} (#{&1.cause})")
      ),
      if(open_ended != [],
        do:
          "open-ended recorder gap(s) from " <>
            Enum.map_join(open_ended, ", ", &"r=#{&1.from} (#{&1.cause})") <> ": extent unknown"
      ),
      if(r.unexplained_missing != [],
        do:
          "missing record number(s) with no gap record: " <>
            Enum.map_join(r.unexplained_missing, ", ", fn {a, b} -> "#{a}..#{b}" end)
      ),
      if(r.corrupt_lines > 0, do: "#{r.corrupt_lines} corrupt line(s) skipped"),
      if(r.corrupt_tails != [], do: "partial last line in: #{Enum.join(r.corrupt_tails, ", ")}"),
      if(r.malformed_records > 0,
        do: "#{r.malformed_records} malformed session record(s) skipped"
      ),
      if(r.unknown_kinds != %{},
        do: "unknown record kind(s) skipped: #{inspect(r.unknown_kinds)}"
      ),
      if(replay.issues != [] or r.issues != [],
        do:
          "#{length(replay.issues) + length(r.issues)} issue(s) reported by the reader or the replay"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp boundary_limitations(%{untrusted: untrusted, unstated: unstated}) do
    [
      if(untrusted != [],
        do:
          "durable boundary claim(s) not trusted (nothing elevated): " <>
            Enum.map_join(
              untrusted,
              "; ",
              &"#{&1.segment} states r=#{&1.boundary} (#{&1.reason})"
            )
      ),
      if(unstated != [],
        do:
          "continuation header(s) without a stated durable boundary (format 1 before correction A): " <>
            Enum.join(unstated, ", ") <> "; the preceding segment's records are not elevated"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp reason_limitation([]), do: []

  defp reason_limitation(qualified),
    do: [
      "#{length(qualified)} close reason(s) not reconstructed exactly (" <>
        Enum.map_join(qualified, ", ", &"r=#{&1.no} #{&1.why}") <>
        "): term equality with the live session is not claimed for those connections"
    ]

  defp rejected_limitation([]), do: []

  defp rejected_limitation(rejected),
    do: [
      "#{length(rejected)} recorded envelope(s) rejected by the current validator and not folded"
    ]

  defp gap_limitation(gaps) when gaps == %{}, do: []

  defp gap_limitation(gaps),
    do: [
      "Relay sequence gap(s) in the envelope stream (delivery or native loss, not recorder loss): " <>
        Enum.map_join(gaps, "; ", fn {id, g} -> "#{id}: #{inspect(g)}" end)
    ]
end
