defmodule GlacierRelay.Recording.Recorder do
  @moduledoc """
  The mission recorder (M4-A, ADR 0008): a dedicated process outside the ingestion path that
  subscribes to `GlacierRelay.MissionSession` for recording-grade records and appends them, in
  the session's record order, to segmented NDJSON files. It never holds evidence of its own,
  never derives a fact, never assigns a substitute record number, and never blocks the session.

  Guarantees and their limits (design sections 6, 7 and 16):

  - **Order**: lines carrying `r` appear in increasing session record number; a hole is missing
    recording evidence, written as a `recorder.gap` with its cause when directly known.
  - **Durability**: only a successful `datasync` moves the *durable boundary* (the last session
    record number known to be on disk). A kill or VM crash loses an unverifiable tail of unknown
    size; `flush_ms` bounds nothing when the writer stalls.
  - **Overload**: a soft policy. The mailbox is measured when a record is handled; above
    `mailbox_high` records are drained and discarded down to `mailbox_low`, and the exact
    discarded ranges are written. During a stalled write nothing is measured and the mailbox is
    unbounded. No lossless behaviour under arbitrary load is claimed.
  - **Clean close**: the seven-step protocol of `close/2`; success is reported only when the
    footer, the hashes and the `CLOSED` marker are synced. Otherwise the recording stays
    explicitly unclosed. `terminate/2` calls the same protocol on a supervisor shutdown (exits
    are trapped) and is not relied on for a kill.
  - **Restart**: a crashed recorder resumes the same recording from the durable boundary kept in
    `:persistent_term` (lost with the VM: a new VM is a new recording), never reads or appends to
    the previous segment, and reports the detected hole only once a later record bounds it.
  - **Continuation headers**: every segment after the first states why it was opened
    (`continuation`: `roll`, `restart` or `write_failure`), the segment before it, whether that
    segment is unverified, and the durable boundary established at that moment — the last record
    number a successful sync covered, whichever segment held it (M4-B correction A). Nothing past
    a successful sync is ever stated as durable.
  - **Budget**: at the configured byte budget the recording is finalized with `reason: "budget"`
    and the recorder stops accepting; nothing is deleted.
  """

  use GenServer
  require Logger

  alias GlacierRelay.MissionSession
  alias GlacierRelay.Recording.{Codec, Record, Segment}

  @defaults [
    dir: nil,
    flush_ms: 100,
    batch_bytes: 262_144,
    segment_bytes: 64 * 1024 * 1024,
    budget_bytes: 1024 * 1024 * 1024,
    mailbox_high: 10_000,
    mailbox_low: 1_000,
    writer: {GlacierRelay.Recording.FileWriter, []}
  ]

  @transient [:recording, :degraded]

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      # The close protocol needs time to drain, flush, sync and finalize.
      shutdown: 15_000
    }
  end

  @doc "Counters, latencies, boundaries, gaps and the current status (read-only)."
  def health(server \\ __MODULE__), do: GenServer.call(server, :health)

  @doc "Flushes the buffer now (write + sync) and returns the health (diagnostics and tests)."
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush, 30_000)

  @doc """
  The clean-close protocol: boundary, drain, flush, sync, footer, hashes and marker. Returns
  `{:ok, summary}` only when every step succeeded; otherwise `{:error, reason}` and the recording
  stays explicitly unclosed (status `:degraded`). Records the session issues afterwards are
  counted, not recorded.
  """
  def close(server \\ __MODULE__, reason \\ :close),
    do: GenServer.call(server, {:close, reason}, 60_000)

  @doc "The default recordings directory: `$XDG_STATE_HOME/glacier-relay/recordings` or `~/.local/state/glacier-relay/recordings`."
  def default_dir do
    base = System.get_env("XDG_STATE_HOME") || Path.expand("~/.local/state")
    Path.join([base, "glacier-relay", "recordings"])
  end

  # -- init -----------------------------------------------------------------------------------

  @impl true
  def init(opts) do
    # Trapping exits makes a supervisor shutdown reach terminate/2 (the close protocol).
    Process.flag(:trap_exit, true)

    config =
      @defaults
      |> Keyword.merge(Application.get_env(:glacier_relay, :recording, []))
      |> Keyword.merge(opts)

    name = Keyword.get(opts, :name, __MODULE__)
    :ok = MissionSession.subscribe(detail: :records)

    state = %{
      name: name,
      key: {__MODULE__, name},
      config: config,
      status: :starting,
      recording_id: nil,
      recording_dir: nil,
      segment: nil,
      segment_hashes: [],
      unverified_segments: [],
      pending: [],
      pending_count: 0,
      pending_bytes: 0,
      pending_last_no: nil,
      timer: nil,
      last_no: nil,
      durable_boundary: 0,
      resume: nil,
      discarding: nil,
      degraded: nil,
      unrecorded_after_close: nil,
      stats: new_stats()
    }

    {:ok, open_recording(state)}
  end

  # -- calls ----------------------------------------------------------------------------------

  @impl true
  def handle_call(:health, _from, state), do: {:reply, health_map(state), state}

  def handle_call(:flush, _from, state) do
    state = state |> cancel_timer() |> close_discard_run() |> do_flush()
    {:reply, health_map(state), state}
  end

  def handle_call({:close, reason}, _from, state) do
    {result, state} = do_close(state, reason)
    {:reply, result, state}
  end

  # -- records --------------------------------------------------------------------------------

  @impl true
  def handle_info({:relay_record, %Record{} = rec}, %{status: status} = state)
      when status in @transient do
    state =
      state
      |> note_received(rec)
      |> restart_gap(rec)
      |> accept_or_discard(rec)
      |> overflow_policy()
      |> flush_or_schedule()

    {:noreply, state}
  end

  def handle_info({:relay_record, %Record{} = rec}, state) do
    # Closed, stopped or closing: counted, never recorded, never renumbered.
    {:noreply, state |> note_received(rec) |> note_unrecorded(rec.no)}
  end

  def handle_info(:flush, state) do
    {:noreply, state |> Map.put(:timer, nil) |> close_discard_run() |> do_flush()}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{status: status} = state) when status in @transient do
    case do_close(state, :shutdown) do
      {{:ok, _}, _} ->
        Logger.info("recorder: closed on shutdown")

      {{:error, why}, _} ->
        Logger.error(
          "recorder: could not close on shutdown: #{inspect(why)}; recording left unclosed"
        )
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- opening and resuming ---------------------------------------------------------------------

  defp open_recording(state) do
    dir = state.config[:dir] || default_dir()

    if Path.type(dir) != :absolute do
      stop_with(state, {:invalid_dir, dir})
    else
      if String.starts_with?(dir, "/mnt/"),
        do:
          Logger.warning("recorder: #{dir} is a mounted path; the WSL2 filesystem is recommended")

      case :persistent_term.get(state.key, nil) do
        nil -> open_new(state, dir)
        saved -> resume(state, saved)
      end
    end
  end

  defp open_new(state, dir) do
    id = uuid()
    rdir = Path.join(dir, id)

    with :ok <- mkdir(dir),
         :ok <- budget_check(dir, state.config[:budget_bytes]),
         :ok <- mkdir(rdir) do
      state = %{state | recording_id: id, recording_dir: rdir, status: :recording}
      Logger.info("recorder: recording #{id} in #{rdir}")

      case open_segment(state, 1, nil, false, nil) do
        {:ok, state} -> state
        {:error, reason, state} -> degrade(state, reason)
      end
    else
      {:error, reason} -> stop_with(state, reason)
    end
  end

  defp resume(state, saved) do
    # The segment that was open at the crash is unverified past the durable boundary: it is
    # never read or appended to. A new segment continues the same recording.
    previous = Segment.name(saved.segment)
    unverified = Enum.uniq(saved.unverified_segments ++ [previous])

    state = %{
      state
      | recording_id: saved.recording_id,
        recording_dir: saved.recording_dir,
        segment_hashes: saved.segment_hashes,
        unverified_segments: unverified,
        durable_boundary: saved.durable_boundary,
        status: :recording,
        resume: %{
          durable_boundary: saved.durable_boundary,
          previous_segment: previous,
          gap_written: false
        }
    }

    Logger.warning(
      "recorder: resuming recording #{saved.recording_id} after a restart; durable boundary r=#{saved.durable_boundary}; #{previous} unverified"
    )

    case open_segment(state, next_segment_number(state), previous, true, :restart) do
      {:ok, state} -> state
      {:error, reason, state} -> degrade(state, reason)
    end
  end

  # Opens segment `n` and writes its header, synced, so a segment file always starts with a
  # synced header. On failure the header is taken back out of the buffer (the next attempt
  # pushes its own) and the state is returned for the caller to degrade. `continuation` says
  # why a segment after the first was opened (`:roll`, `:restart`, `:write_failure`).
  defp open_segment(state, n, previous, previous_unverified, continuation) do
    case Segment.open(state.recording_dir, n, state.config[:writer]) do
      {:ok, seg} ->
        # The header is written alone, ahead of whatever the buffer holds (after a failure the
        # buffer still carries earlier records, which must follow the header, not precede it).
        buffered = Map.take(state, [:pending, :pending_count, :pending_bytes, :pending_last_no])
        empty = %{pending: [], pending_count: 0, pending_bytes: 0, pending_last_no: nil}
        state = state |> Map.merge(empty) |> Map.put(:segment, seg)
        header = header_line(state, n, previous, previous_unverified, continuation)
        state = push_line(state, header, nil)

        case write_pending(state) do
          {:ok, state} ->
            {:ok, Map.merge(state, buffered)}

          {:error, reason, state} ->
            {:error, reason, state |> Map.merge(buffered) |> drop_if_empty(seg)}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # A segment file whose header could not be written holds nothing: it is removed so that a
  # long outage does not leave one empty file per retry. A file with bytes in it is evidence of
  # the failure and stays, listed as unverified.
  defp drop_if_empty(state, %Segment{} = seg) do
    case File.stat(seg.path) do
      {:ok, %File.Stat{size: 0}} ->
        _ = File.rm(seg.path)
        %{state | unverified_segments: List.delete(state.unverified_segments, seg.name)}

      _ ->
        state
    end
  end

  # The first segment of a recording states no boundary (nothing of it has been synced). Every
  # continuation states the boundary established when it opened: the last record number a
  # successful sync covered, in whichever segment — after a restart the one kept in the
  # persistent term, after a write or sync failure the last sync before the failure, at a roll
  # the last record of the segment just closed. Never the last record received.
  defp header_line(state, n, previous, previous_unverified, continuation) do
    listener =
      case Application.get_env(:glacier_relay, GlacierRelay.Wire.Listener) do
        nil -> nil
        cfg -> %{"ip" => ip_text(cfg[:ip]), "port" => cfg[:port]}
      end

    origin = Application.get_env(:glacier_relay, :dashboard, [])[:source] || :live

    Codec.encode_diagnostic("recording.opened", DateTime.utc_now(), [
      {"format", Codec.format()},
      {"recording_id", state.recording_id},
      {"segment", n},
      {"previous_segment", previous},
      {"previous_unverified", previous_unverified},
      {"resumed", continuation == :restart},
      {"continuation", continuation && Atom.to_string(continuation)},
      {"durable_boundary", if(continuation, do: state.durable_boundary, else: nil)},
      {"node", Atom.to_string(node())},
      {"app",
       %{
         "name" => "glacier_relay",
         "vsn" => to_string(Application.spec(:glacier_relay, :vsn) || "")
       }},
      {"otp", to_string(:erlang.system_info(:otp_release))},
      {"elixir", System.version()},
      {"listener", listener},
      {"origin", Atom.to_string(origin)},
      {"transport", "recorded"}
    ])
  end

  # -- accepting records ------------------------------------------------------------------------

  defp note_received(state, %Record{no: no}) do
    state
    |> update_in([:stats, :records_received], &(&1 + 1))
    |> Map.put(:last_no, no)
  end

  # After a restart the first record bounds the hole: durable boundary + 1 .. first seen − 1.
  defp restart_gap(%{resume: %{gap_written: false} = r} = state, %Record{no: no}) do
    state = %{state | resume: %{r | gap_written: true}}

    if no > r.durable_boundary + 1 do
      gap(state, r.durable_boundary + 1, no - 1, "restart", [
        {"durable_boundary", r.durable_boundary},
        {"note",
         "records in this range may exist unverified at the tail of #{r.previous_segment}; none is claimed"}
      ])
    else
      state
    end
  end

  defp restart_gap(state, _rec), do: state

  # Closing after a restart without having seen a record: whether anything was issued since the
  # durable boundary is unknown, so the hole is written open-ended, never with an invented end.
  defp open_ended_restart_gap(%{resume: %{gap_written: false} = r} = state) do
    gap(%{state | resume: %{r | gap_written: true}}, r.durable_boundary + 1, nil, "restart", [
      {"durable_boundary", r.durable_boundary},
      {"note",
       "no later record bounds this range; the tail of #{r.previous_segment} is unverified"}
    ])
  end

  defp open_ended_restart_gap(state), do: state

  # While degraded with a full buffer, incoming records are not kept; the run of discarded
  # numbers is closed into one gap line when a record is accepted again or at the next flush.
  defp accept_or_discard(state, %Record{no: no} = rec) do
    if state.status == :degraded and state.pending_count >= state.config[:mailbox_high] do
      extend_discard_run(state, no, "write_failure")
    else
      state |> close_discard_run() |> push_line(Codec.encode_record(rec), no)
    end
  end

  defp extend_discard_run(%{discarding: nil} = state, no, cause),
    do: %{state | discarding: %{from: no, to: no, cause: cause}}

  defp extend_discard_run(%{discarding: d} = state, no, _cause),
    do: %{state | discarding: %{d | to: no}}

  defp close_discard_run(%{discarding: nil} = state), do: state

  defp close_discard_run(%{discarding: d} = state),
    do: gap(%{state | discarding: nil}, d.from, d.to, d.cause, [])

  defp push_line(state, line, no) do
    bytes = IO.iodata_length(line)

    %{
      state
      | pending: [line | state.pending],
        pending_count: state.pending_count + 1,
        pending_bytes: state.pending_bytes + bytes,
        pending_last_no: no || state.pending_last_no
    }
  end

  # The soft overload policy: measured here, when a record is handled, and nowhere else.
  defp overflow_policy(state) do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)
    state = update_in(state.stats.mailbox_max, &max(&1, len))

    if len > state.config[:mailbox_high] do
      discarded = drain(len, state.config[:mailbox_low], [])
      ranges = ranges(discarded)

      Logger.warning(
        "recorder: mailbox #{len} above #{state.config[:mailbox_high]}; discarded #{length(discarded)} records #{inspect(ranges)}"
      )

      state = update_in(state.stats.overflow_events, &(&1 + 1))
      Enum.reduce(ranges, state, fn {from, to}, s -> gap(s, from, to, "overflow", []) end)
    else
      state
    end
  end

  defp drain(len, low, acc) when len <= low, do: Enum.reverse(acc)

  defp drain(len, low, acc) do
    receive do
      {:relay_record, %Record{no: no}} -> drain(len - 1, low, [no | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp ranges([]), do: []

  defp ranges([first | rest]) do
    rest
    |> Enum.reduce([{first, first}], fn n, [{from, to} | tail] = acc ->
      if n == to + 1, do: [{from, n} | tail], else: [{n, n} | acc]
    end)
    |> Enum.reverse()
  end

  defp gap(state, from, to, cause, extra) do
    entry = %{from: from, to: to, cause: cause}
    Logger.warning("recorder: gap r=#{from}..#{inspect(to)} (#{cause})")

    line =
      Codec.encode_diagnostic(
        "recorder.gap",
        DateTime.utc_now(),
        [{"from", from}, {"to", to}, {"cause", cause}] ++ extra
      )

    state
    |> update_in([:stats, :gaps], &(&1 ++ [entry]))
    |> update_in(
      [:stats, :records_discarded],
      &(&1 + if(is_integer(to), do: to - from + 1, else: 0))
    )
    |> push_line(line, nil)
  end

  defp note_unrecorded(state, no) do
    case state.unrecorded_after_close do
      nil -> %{state | unrecorded_after_close: %{from: no, to: no}}
      %{from: from} -> %{state | unrecorded_after_close: %{from: from, to: no}}
    end
  end

  # -- flushing ---------------------------------------------------------------------------------

  defp flush_or_schedule(%{pending_count: 0} = state), do: state

  defp flush_or_schedule(state) do
    if state.pending_bytes >= state.config[:batch_bytes],
      do: state |> cancel_timer() |> do_flush(),
      else: schedule(state)
  end

  # While degraded the retry interval backs off (doubling from flush_ms up to 5 s) so that a
  # persistent failure does not retry, log and create files every window.
  defp schedule(%{timer: nil} = state) do
    ms =
      case state.degraded do
        nil -> state.config[:flush_ms]
        %{backoff_ms: backoff} -> backoff
      end

    %{state | timer: Process.send_after(self(), :flush, ms)}
  end

  defp schedule(state), do: state

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: ref} = state) do
    Process.cancel_timer(ref)

    receive do
      :flush -> :ok
    after
      0 -> :ok
    end

    %{state | timer: nil}
  end

  defp do_flush(%{pending_count: 0} = state), do: state

  defp do_flush(%{status: status} = state) when status in @transient do
    state = if state.segment == nil, do: reopen_after_failure(state), else: state

    case state.segment do
      nil ->
        state

      _ ->
        case write_pending(state) do
          {:ok, state} -> state |> recovered_if_degraded() |> maybe_roll()
          {:error, reason, state} -> degrade(state, reason)
        end
    end
  end

  defp do_flush(state), do: state

  # Write the buffer, sync it, move the durable boundary. A write that succeeds but does not
  # sync is not durable: the segment is then abandoned as unverified (the bytes may or may not
  # be on disk) and the buffer is kept for the next segment.
  defp write_pending(state) do
    lines = Enum.reverse(state.pending)
    {write_us, appended} = :timer.tc(fn -> Segment.append(state.segment, lines) end)

    with {:ok, seg} <- appended,
         {sync_us, :ok} <- :timer.tc(fn -> Segment.sync(seg) end) do
      boundary = state.pending_last_no || state.durable_boundary

      state =
        %{
          state
          | segment: seg,
            pending: [],
            pending_count: 0,
            pending_bytes: 0,
            pending_last_no: nil,
            durable_boundary: boundary
        }
        |> update_in([:stats, :flushes], &(&1 + 1))
        |> update_in([:stats, :lines_written], &(&1 + length(lines)))
        |> update_in([:stats, :bytes_written], &(&1 + IO.iodata_length(lines)))
        |> update_in([:stats, :write_us], &latency(&1, write_us))
        |> update_in([:stats, :sync_us], &latency(&1, sync_us))

      persist(state)
      {:ok, state}
    else
      {:error, reason} -> {:error, reason, abandon_segment(state)}
      {_us, {:error, reason}} -> {:error, reason, abandon_segment(state)}
    end
  end

  defp abandon_segment(%{segment: nil} = state), do: state

  defp abandon_segment(%{segment: seg} = state) do
    _ = Segment.close(seg)

    %{
      state
      | segment: nil,
        unverified_segments: Enum.uniq(state.unverified_segments ++ [seg.name])
    }
  end

  defp degrade(state, reason) do
    Logger.error("recorder: write failed: #{inspect(reason)}; degraded, buffer kept, retrying")

    state
    |> Map.put(:status, :degraded)
    |> Map.update!(:degraded, fn
      nil ->
        %{
          since: DateTime.utc_now(),
          error: reason,
          attempts: 1,
          backoff_ms: state.config[:flush_ms]
        }

      d ->
        %{d | error: reason, attempts: d.attempts + 1, backoff_ms: min(d.backoff_ms * 2, 5_000)}
    end)
    |> update_in([:stats, :write_errors], &(&1 + 1))
    |> put_in([:stats, :last_error], reason)
    |> schedule()
  end

  defp reopen_after_failure(state) do
    previous = List.last(state.unverified_segments)

    case open_segment(state, next_segment_number(state), previous, true, :write_failure) do
      {:ok, state} -> state
      {:error, reason, state} -> degrade(state, reason)
    end
  end

  defp next_segment_number(state),
    do: length(state.segment_hashes) + length(state.unverified_segments) + 1

  defp recovered_if_degraded(%{status: :degraded, degraded: d} = state) do
    Logger.info("recorder: recovered after #{d.attempts} failed attempt(s)")

    line =
      Codec.encode_diagnostic("recorder.recovered", DateTime.utc_now(), [
        {"error", inspect(d.error)},
        {"failed_since", d.since},
        {"attempts", d.attempts}
      ])

    state = %{state | status: :recording, degraded: nil} |> push_line(line, nil)

    case write_pending(state) do
      {:ok, state} -> state
      {:error, reason, state} -> degrade(state, reason)
    end
  end

  defp recovered_if_degraded(state), do: state

  defp maybe_roll(%{segment: %Segment{} = seg} = state) do
    if seg.bytes >= state.config[:segment_bytes] do
      dir = state.config[:dir] || default_dir()

      case budget_check(dir, state.config[:budget_bytes]) do
        :ok ->
          roll(state)

        {:error, {:budget, _} = why} ->
          {_, state} = close_recording(state, :budget)
          stop_with(state, why)
      end
    else
      state
    end
  end

  defp maybe_roll(state), do: state

  defp roll(%{segment: seg} = state) do
    case Segment.close(seg) do
      {:ok, hash} ->
        state = %{
          state
          | segment: nil,
            segment_hashes: state.segment_hashes ++ [{seg.name, hash}]
        }

        case open_segment(state, next_segment_number(state), seg.name, false, :roll) do
          {:ok, state} -> state
          {:error, reason, state} -> degrade(state, reason)
        end

      {:error, reason} ->
        degrade(abandon_segment(state), reason)
    end
  end

  # -- the close protocol -----------------------------------------------------------------------

  defp do_close(%{status: status} = state, _reason) when status not in @transient,
    do: {{:error, {:not_open, status}}, state}

  defp do_close(state, reason) do
    # 1. boundary: nothing issued after this point is recorded; 2. drain what was already sent.
    state = %{state | status: :closing} |> cancel_timer() |> drain_mailbox()

    # 3–4. flush and sync everything accepted (an unbounded restart hole first, if no record
    # ever bounded it).
    state = state |> open_ended_restart_gap() |> close_discard_run() |> flush_for_close()

    if state.segment == nil or state.pending_count > 0 do
      {{:error, {:unclosed, state.stats.last_error}}, %{state | status: :degraded}}
    else
      close_recording(state, reason)
    end
  end

  # 5–6: the footer (synced), then the hashes and the marker. Assumes an open segment and an
  # empty buffer.
  defp close_recording(state, reason) do
    boundary = state.last_no || state.durable_boundary

    footer =
      Codec.encode_diagnostic("recording.closed", DateTime.utc_now(), [
        {"boundary", boundary},
        {"records", state.stats.records_received},
        {"lines", state.stats.lines_written + 1},
        {"bytes", state.stats.bytes_written},
        {"reason", Atom.to_string(reason)}
      ])

    state = push_line(state, footer, nil)

    case write_pending(state) do
      {:ok, state} -> finalize(state, reason)
      {:error, why, state} -> {{:error, {:unclosed, why}}, degrade(state, why)}
    end
  end

  defp drain_mailbox(state) do
    receive do
      {:relay_record, %Record{} = rec} ->
        state
        |> note_received(rec)
        |> restart_gap(rec)
        |> accept_or_discard(rec)
        |> drain_mailbox()
    after
      0 -> state
    end
  end

  defp flush_for_close(%{pending_count: 0} = state), do: state

  defp flush_for_close(state) do
    state = if state.segment == nil, do: reopen_after_failure(state), else: state

    case state.segment do
      nil ->
        state

      _ ->
        case write_pending(state) do
          {:ok, state} -> recovered_if_degraded(state)
          {:error, reason, state} -> degrade(state, reason)
        end
    end
  end

  defp finalize(state, reason) do
    with {:ok, hash} <- Segment.close(state.segment),
         hashes = state.segment_hashes ++ [{state.segment.name, hash}],
         :ok <-
           write_synced(
             Path.join(state.recording_dir, "sha256.txt"),
             hashes_text(hashes, state.unverified_segments)
           ),
         :ok <- write_synced(Path.join(state.recording_dir, "CLOSED"), "") do
      :persistent_term.erase(state.key)

      Logger.info(
        "recorder: recording #{state.recording_id} closed (#{reason}); boundary r=#{state.durable_boundary}"
      )

      summary = %{
        recording_id: state.recording_id,
        recording_dir: state.recording_dir,
        boundary: state.durable_boundary,
        segments: hashes,
        unverified_segments: state.unverified_segments,
        reason: reason
      }

      {{:ok, summary}, %{state | status: :closed, segment: nil, segment_hashes: hashes}}
    else
      {:error, why} -> {{:error, {:unclosed, why}}, degrade(%{state | segment: nil}, why)}
    end
  end

  defp hashes_text(hashes, unverified) do
    Enum.map_join(hashes, "", fn {name, hash} -> "#{hash}  #{name}\n" end) <>
      Enum.map_join(unverified, "", fn name -> "unverified  #{name}\n" end)
  end

  defp write_synced(path, content) do
    with {:ok, fd} <- :file.open(path, [:write, :exclusive, :raw, :binary]),
         :ok <- :file.write(fd, content),
         :ok <- :file.datasync(fd) do
      :file.close(fd)
    end
  end

  # -- stopping ---------------------------------------------------------------------------------

  defp stop_with(state, reason) do
    Logger.error("recorder: stopped: #{inspect(reason)}")
    %{state | status: :stopped} |> put_in([:stats, :last_error], reason)
  end

  defp budget_check(dir, budget) do
    bytes = dir_bytes(dir)
    if bytes >= budget, do: {:error, {:budget, bytes}}, else: :ok
  end

  defp dir_bytes(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reduce(0, fn path, acc ->
      case File.stat(path) do
        {:ok, %File.Stat{type: :regular, size: size}} -> acc + size
        _ -> acc
      end
    end)
  end

  defp mkdir(dir) do
    with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
  end

  defp persist(state) do
    :persistent_term.put(state.key, %{
      recording_id: state.recording_id,
      recording_dir: state.recording_dir,
      segment: state.segment.number,
      durable_boundary: state.durable_boundary,
      segment_hashes: state.segment_hashes,
      unverified_segments: state.unverified_segments
    })
  end

  # -- health -----------------------------------------------------------------------------------

  defp health_map(state) do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)

    Map.merge(state.stats, %{
      status: state.status,
      recording_id: state.recording_id,
      recording_dir: state.recording_dir,
      segment: state.segment && state.segment.number,
      segment_bytes: state.segment && state.segment.bytes,
      segments_closed: Enum.map(state.segment_hashes, &elem(&1, 0)),
      unverified_segments: state.unverified_segments,
      last_record_no: state.last_no,
      durable_boundary: state.durable_boundary,
      pending_count: state.pending_count,
      pending_bytes: state.pending_bytes,
      mailbox_len: len,
      discarding: state.discarding,
      degraded: state.degraded,
      resumed: state.resume != nil,
      unrecorded_after_close: state.unrecorded_after_close
    })
  end

  defp new_stats do
    %{
      records_received: 0,
      records_discarded: 0,
      lines_written: 0,
      bytes_written: 0,
      flushes: 0,
      write_errors: 0,
      overflow_events: 0,
      mailbox_max: 0,
      last_error: nil,
      gaps: [],
      write_us: %{last: 0, max: 0, total: 0},
      sync_us: %{last: 0, max: 0, total: 0}
    }
  end

  defp latency(l, us), do: %{last: us, max: max(l.max, us), total: l.total + us}

  defp ip_text(ip) when is_tuple(ip), do: ip |> Tuple.to_list() |> Enum.join(".")
  defp ip_text(other), do: to_string(other)

  defp uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::32, b::16, 4::4, c::12, 2::2, d::14, e::48>>, case: :lower)
    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> = hex
    "#{p1}-#{p2}-#{p3}-#{p4}-#{p5}"
  end
end
