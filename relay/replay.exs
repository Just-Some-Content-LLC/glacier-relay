# Read-only replay of a recording directory (M4-B, ADR 0008), in the style of the run tools'
# final_state.exs: no application start, no listener, no dashboard, nothing of the game.
#
#     elixir -S mix run --no-start replay.exs <recording-directory>
#
# Prints the recording's identity and verification, the record and transport account, the
# recorder's gaps and corruption, the Relay sequence gaps, the native-drop status (unknown
# unless native evidence is reconciled separately), the replayed summary, the B7 mission report,
# and the explicit account with its limitations.
alias GlacierRelay.Recording.Replay

[dir] = System.argv()

case Replay.replay(Path.expand(dir)) do
  {:error, reason} ->
    IO.puts("cannot read #{dir}: #{inspect(reason)}")
    System.halt(2)

  {:ok, r} ->
    c = r.completeness
    reader = r.reader
    records = reader.records

    count = fn kind -> Enum.count(records, &(&1.kind == kind)) end

    IO.puts("== recording")
    IO.puts("directory: #{r.dir}")
    IO.puts("recording id: #{r.recording_id}; format: #{inspect(c.format)}; source: #{c.source}")

    for s <- reader.segments do
      h = s.header || %{}

      IO.puts(
        "segment #{s.name}: #{s.status}; #{s.lines} line(s), #{s.bytes} B; previous #{inspect(h["previous_segment"])}#{if h["previous_unverified"], do: " (unverified)"}#{if h["resumed"], do: "; resumed at durable boundary #{h["durable_boundary"]}"}#{if s.header_only, do: "; header only"}#{if s.corrupt_tail, do: "; partial last line (#{s.corrupt_tail} B)"}"
      )
    end

    IO.puts(
      "finalization: #{c.finalization}; CLOSED marker: #{c.closed_marker}; footer: #{inspect(c.footer_reason)} at boundary #{inspect(c.footer_boundary)}"
    )

    IO.puts("")
    IO.puts("== records")

    IO.puts(
      "first r=#{inspect(c.records.first)}, last r=#{inspect(c.records.last)}; resolved #{c.records.resolved} (authoritative #{c.records.authoritative}, unverified used #{c.records.unverified_used}); duplicates #{c.records.duplicates}; conflicts #{c.records.conflicts}; ambiguous #{inspect(c.records.ambiguous)}"
    )

    IO.puts("replay boundary: r=#{inspect(r.boundary)}")

    IO.puts(
      "transport evidence (#{c.transport}): opened #{count.("connection.opened")}, identified #{count.("connection.identified")}, closed #{count.("connection.closed")}; envelopes #{count.("envelope")}; unidentified connections at the boundary: #{length(r.unidentified)}"
    )

    IO.puts("receipt times: #{c.receipt_times}")
    IO.puts("")
    IO.puts("== recorder gaps and corruption")

    IO.puts(
      "gaps: #{inspect(c.recorder_gaps)}; open-ended: #{inspect(c.open_ended_gaps)}; unexplained missing: #{inspect(c.unexplained_missing)}"
    )

    IO.puts(
      "corrupt lines #{c.corrupt_lines}; partial tails #{inspect(c.corrupt_tails)}; malformed records #{c.malformed_records}; unknown kinds #{inspect(c.unknown_kinds)}"
    )

    IO.puts("rejected by the current validator: #{inspect(c.rejected_by_current_validator)}")
    IO.puts("issues: #{inspect(c.replay_issues)}")
    IO.puts("")
    IO.puts("== Relay stream")

    IO.puts(
      "sequence gaps: #{inspect(c.relay_sequence_gaps)}; lifecycle notes: #{inspect(r.notes)}"
    )

    IO.puts(
      "native-side drops: #{c.native_drops} (reconcile the native log separately with compare.py)"
    )

    IO.puts("")
    IO.puts("== summary")
    IO.puts(r.summary_text)
    IO.puts("")
    IO.puts("== report")
    IO.puts(r.report_text)
    IO.puts("")
    IO.puts("== account")

    IO.puts(
      "evidence: #{c.evidence}; recorder-level authoritative and cleanly finalized: #{c.recorder_authoritative?}"
    )

    for l <- c.limitations, do: IO.puts("  - #{l}")
    IO.puts("timings (us): #{inspect(r.timings_us)}")
end
