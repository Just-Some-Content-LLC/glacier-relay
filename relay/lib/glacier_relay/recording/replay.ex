defmodule GlacierRelay.Recording.Replay do
  @moduledoc """
  Deterministic replay of a recording (M4-B, ADR 0008): the reader's resolved records, folded
  strictly in session record order by the same `GlacierRelay.Session.Fold` the live session
  runs, into `Lifecycle.Instance` values, the summary and the B7 report, with an explicit
  account of what the recording covers and what it does not. A function from files to values:
  no process, no socket, no session, nothing of the game.

  Envelopes are re-validated with the current `Envelope.decode/1`; one the current validator
  rejects is listed, never folded and never replaced. `connection.identified` records are the
  session's decisions and are checked against the fold's own; a difference is an issue, not a
  correction. Close reasons are decoded by `Codec.decode_reason/1`: exact where the typed
  vocabulary reconstructs the original term (`peer_closed`, `line_too_long`, allow-listed
  `tcp_error` and `down` reasons), otherwise a visibly qualified value (`{:recorded_text, _}`
  inside the kept category, or `{:unrecognized_reason, _}`) listed under `qualified_reasons` —
  so term equality with the live session is claimed only where the format provides it, and a
  difference is reported rather than repaired by an invented term.

  Legacy fixtures (envelope-only NDJSON) replay through `from_envelopes/2` under their documented
  semantics: no connection evidence (`transport: :not_recorded`), no receipt times, the direct
  fold of `Lifecycle.apply_event/3` with `received_at` nil, as the M2 fixture tests do.
  """

  alias GlacierRelay.Recording.{Codec, Completeness, Reader}
  alias GlacierRelay.Session.Fold
  alias GlacierRelay.Summary
  alias GlacierRelay.Wire.Envelope

  defstruct source: nil,
            dir: nil,
            recording_id: nil,
            first_record_no: nil,
            boundary: nil,
            fold: nil,
            instances: %{},
            unidentified: [],
            summary: [],
            report: [],
            summary_text: "",
            report_text: "",
            completeness: nil,
            reader: nil,
            issues: [],
            rejected: [],
            qualified_reasons: [],
            notes: %{},
            timings_us: %{}

  @type t :: %__MODULE__{}

  @doc "Reads and replays a recording directory."
  @spec replay(String.t()) :: {:ok, t()} | {:error, term()}
  def replay(dir) when is_binary(dir) do
    {read_us, read} = :timer.tc(fn -> Reader.read(dir) end)

    with {:ok, %Reader.Result{} = result} <- read do
      replay = replay_result(result)
      {:ok, %{replay | timings_us: Map.put(replay.timings_us, :read, read_us)}}
    end
  end

  @doc "Replays an already read recording."
  @spec replay_result(Reader.Result.t()) :: t()
  def replay_result(%Reader.Result{} = result) do
    {fold_us, {fold, issues, rejected, qualified, notes, boundary}} =
      :timer.tc(fn -> fold_records(result.records) end)

    {render_us, outputs} = :timer.tc(fn -> outputs(fold) end)

    replay = %__MODULE__{
      source: :recording,
      dir: result.dir,
      recording_id: result.recording_id,
      first_record_no: result.first_record_no,
      boundary: boundary,
      fold: fold,
      instances: fold.instances,
      unidentified: fold.unidentified,
      reader: result,
      issues: issues,
      rejected: rejected,
      qualified_reasons: qualified,
      notes: notes,
      timings_us: %{fold: fold_us, render: render_us}
    }

    replay = Map.merge(replay, outputs)
    %{replay | completeness: Completeness.account(replay)}
  end

  @doc """
  Replays envelope-only lines (the committed fixtures, `beam-events.ndjson`-style dumps) under
  the legacy semantics: no transport evidence, no receipt times. `opts`: `:name` (a label).
  """
  @spec from_envelopes([binary()], keyword()) :: t()
  def from_envelopes(lines, opts \\ []) when is_list(lines) do
    {fold_us, {fold, rejected, notes}} =
      :timer.tc(fn ->
        lines
        |> Enum.with_index(1)
        |> Enum.reduce({Fold.new(), [], %{}}, fn {line, i}, {fold, rejected, notes} ->
          case Envelope.decode(line) do
            {:ok, envelope} ->
              {fold, effects} = Fold.event(fold, nil, envelope, nil)
              {fold, rejected, count_notes(notes, effects)}

            {:error, reason} ->
              {fold, [%{line: i, reason: reason} | rejected], notes}
          end
        end)
      end)

    {render_us, outputs} = :timer.tc(fn -> outputs(fold) end)

    replay = %__MODULE__{
      source: :legacy,
      recording_id: Keyword.get(opts, :name),
      fold: fold,
      instances: fold.instances,
      unidentified: fold.unidentified,
      rejected: Enum.reverse(rejected),
      notes: notes,
      boundary: length(lines),
      first_record_no: if(lines == [], do: nil, else: 1),
      timings_us: %{fold: fold_us, render: render_us}
    }

    replay = Map.merge(replay, outputs)
    %{replay | completeness: Completeness.account(replay)}
  end

  # -- folding ------------------------------------------------------------------------------------

  defp fold_records(records) do
    init = %{
      fold: Fold.new(),
      issues: [],
      rejected: [],
      qualified: [],
      notes: %{},
      expected: %{},
      boundary: nil
    }

    acc = Enum.reduce(records, init, &fold_record/2)

    leftover =
      for {conn, %{no: no}} <- acc.expected, do: {:identification_without_envelope, no, conn}

    {acc.fold, Enum.reverse(acc.issues) ++ leftover, Enum.reverse(acc.rejected),
     Enum.reverse(acc.qualified), acc.notes, acc.boundary}
  end

  defp fold_record(%{kind: "connection.opened", map: m, no: no}, acc) do
    {at, acc} = time(m["at"], no, acc)
    {fold, effects} = Fold.connection_opened(acc.fold, m["conn"], m["peer"], at)
    %{acc | fold: fold, boundary: no} |> effects_issues(effects, no)
  end

  defp fold_record(%{kind: "connection.identified", map: m, no: no}, acc) do
    expected =
      Map.put(acc.expected, m["conn"], %{
        no: no,
        instance: m["instance"],
        previous: m["previous_instance"]
      })

    %{acc | expected: expected, boundary: no}
  end

  defp fold_record(%{kind: "envelope", map: m, no: no}, acc) do
    {at, acc} = time(m["at"], no, acc)

    case Envelope.decode(JSON.encode!(m["envelope"])) do
      {:ok, envelope} ->
        acc =
          if envelope.adapter_instance_id != m["instance"] or envelope.sequence != m["sequence"] or
               envelope.event_type != m["event_type"],
             do: issue(acc, {:frame_envelope_mismatch, no}),
             else: acc

        {fold, effects} = Fold.event(acc.fold, m["conn"], envelope, at)
        acc = %{acc | fold: fold, boundary: no, notes: count_notes(acc.notes, effects)}
        acc = check_identification(acc, m["conn"], effects, no)
        effects_issues(acc, effects, no)

      {:error, reason} ->
        rejected = %{
          no: no,
          event_type: m["event_type"],
          schema_version: m["envelope"]["schema_version"],
          sequence: m["sequence"],
          instance: m["instance"],
          reason: reason
        }

        %{acc | rejected: [rejected | acc.rejected], boundary: no}
    end
  end

  defp fold_record(%{kind: "connection.closed", map: m, no: no}, acc) do
    {at, acc} = time(m["at"], no, acc)

    {reason, acc} =
      case Codec.decode_reason(m["reason"]) do
        {:exact, reason} ->
          {reason, acc}

        {:qualified, reason, why} ->
          entry = %{no: no, conn: m["conn"], recorded: m["reason"], replayed: reason, why: why}
          {reason, %{acc | qualified: [entry | acc.qualified]}}
      end

    {fold, effects} = Fold.connection_closed(acc.fold, m["conn"], reason, at)
    %{acc | fold: fold, boundary: no} |> effects_issues(effects, no)
  end

  # The session's recorded identification decision against the fold's own.
  defp check_identification(acc, conn, effects, no) do
    decided =
      Enum.find_value(effects, fn
        {:identified, info} -> {info.instance, nil}
        {:reattributed, info} -> {info.instance, info.previous_instance}
        _ -> nil
      end)

    case {Map.pop(acc.expected, conn), decided} do
      {{nil, _}, nil} ->
        acc

      {{nil, _}, {instance, previous}} ->
        issue(acc, {:identification_not_recorded, no, conn, instance, previous})

      {{%{instance: i, previous: p}, expected}, {i, p}} ->
        %{acc | expected: expected}

      {{%{no: rno} = e, expected}, decided} ->
        %{acc | expected: expected}
        |> issue({:identification_mismatch, rno, no, {e.instance, e.previous}, decided})
    end
  end

  defp effects_issues(acc, effects, no) do
    Enum.reduce(effects, acc, fn
      {:unknown_connection, conn}, a -> issue(a, {:unknown_connection, no, conn})
      _, a -> a
    end)
  end

  defp count_notes(notes, effects) do
    Enum.reduce(effects, notes, fn
      {:note, _id, note}, acc -> Map.update(acc, elem(note, 0), 1, &(&1 + 1))
      _, acc -> acc
    end)
  end

  defp issue(acc, issue), do: %{acc | issues: [issue | acc.issues]}

  defp time(nil, _no, acc), do: {nil, acc}

  defp time(text, no, acc) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, 0} -> {dt, acc}
      _ -> {nil, issue(acc, {:bad_timestamp, no, text})}
    end
  end

  defp time(_other, no, acc), do: {nil, issue(acc, {:bad_timestamp, no, nil})}

  defp outputs(%Fold.State{} = fold) do
    %{
      summary: Summary.build(fold.instances),
      report: Summary.report(fold.instances),
      summary_text: Summary.render(fold.instances, fold.unidentified),
      report_text: Summary.render_report(fold.instances, fold.unidentified)
    }
  end
end
