defmodule GlacierRelay.Motion.Trace do
  @moduledoc """
  M7-B1: the per-node motion trace, `glacier-relay.motion-trace/1` (`docs/design/M7_NETWORK_GHOST.md`
  section 15.8): one NDJSON file per trace process, separate from the command journal and from
  mission recordings, holding the data plane's evidence — samples with their verdicts, forwards,
  acknowledgements, reports, closes, stream events and RTTs. Each record carries `trace_seq` and
  the writer's clock (`beam_mono_ms`); a value from another clock domain is labelled
  (`src_mono_ms`, `native_mono_ms`) and never subtracted across domains.

  Bounds: at most `max_records` records and `max_bytes` bytes per file (defaults 200,000 and
  32 MiB). Records are buffered and written with one datasync every `flush_ms` (100) and at close.
  Health: `:ok`; `:full` once the bound is reached (one `trace.truncated` record is written, later
  records are counted as dropped and refused); `{:failed, reason}` after a write or sync error.
  `append/2` answers `:ok` only while the health is `:ok` — the caller (a destination session or a
  share, for which the trace is required) stops further effects otherwise, without blocking stop.

  Incompleteness: a file without its `trace.closed` footer was not closed cleanly and may lack the
  records since its last sync. The file is created exclusively, `0600`, in a `0700` directory
  (default `$XDG_STATE_HOME/glacier-relay/motion`, else `~/.local/state/glacier-relay/motion`).
  """

  use GenServer
  require Logger

  alias GlacierRelay.Command.Schema

  @format "glacier-relay.motion-trace/1"

  def format, do: @format

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Appends records (maps with string keys). `:ok`, or `{:error, health}`."
  def append(server, records) when is_list(records), do: GenServer.call(server, {:append, records})

  @doc "The trace's identity, path, counts and health."
  def status(server), do: GenServer.call(server, :status)

  @doc "Writes the buffered records and syncs now."
  def flush(server), do: GenServer.call(server, :flush)

  def default_dir do
    base = System.get_env("XDG_STATE_HOME") || Path.expand("~/.local/state")
    Path.join([base, "glacier-relay", "motion"])
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    dir = Keyword.get(opts, :dir) || default_dir()
    id = Schema.uuid4()
    path = Path.join(dir, "motion-#{Keyword.get(opts, :role, "node")}-#{id}.ndjson")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, fd} <- :file.open(path, [:write, :exclusive, :raw, :binary]),
         :ok <- File.chmod(path, 0o600) do
      state = %{
        fd: fd,
        path: path,
        id: id,
        role: Keyword.get(opts, :role, "node"),
        max_records: Keyword.get(opts, :max_records, 200_000),
        max_bytes: Keyword.get(opts, :max_bytes, 32 * 1_048_576),
        flush_ms: Keyword.get(opts, :flush_ms, 100),
        seq: 0,
        bytes: 0,
        buffer: [],
        dropped: 0,
        health: :ok,
        timer: nil
      }

      state =
        put(state, %{
          "event" => "trace.opened",
          "format" => @format,
          "trace_id" => id,
          "role" => state.role,
          "node" => to_string(node()),
          "otp" => System.otp_release(),
          "bounds" => %{"max_records" => state.max_records, "max_bytes" => state.max_bytes}
        })

      case sync(state) do
        {:ok, state} -> {:ok, state}
        {:error, reason, _} -> {:stop, {:trace_open_failed, reason}}
      end
    else
      {:error, reason} -> {:stop, {:trace_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:append, records}, _from, %{health: :ok} = state) do
    state = Enum.reduce(records, state, &put(&2, &1))
    state = schedule(state)
    {:reply, if(state.health == :ok, do: :ok, else: {:error, state.health}), state}
  end

  def handle_call({:append, records}, _from, state),
    do: {:reply, {:error, state.health}, %{state | dropped: state.dropped + length(records)}}

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       format: @format,
       trace_id: state.id,
       path: state.path,
       records: state.seq,
       bytes: state.bytes,
       dropped: state.dropped,
       health: state.health
     }, state}
  end

  def handle_call(:flush, _from, state) do
    case sync(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    case sync(%{state | timer: nil}) do
      {:ok, state} -> {:noreply, state}
      {:error, _reason, state} -> {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    state =
      if state.health in [:ok, :full] do
        footer = %{
          "event" => "trace.closed",
          "reason" => inspect(reason),
          "records" => state.seq + 1,
          "dropped" => state.dropped,
          "health" => health_text(state.health)
        }

        line(state, footer)
      else
        state
      end

    _ = sync(state)
    :file.close(state.fd)
    :ok
  end

  # one record into the buffer, or — at the bound — the truncation marker and the health `:full`
  defp put(%{health: :ok} = state, record) do
    if state.seq + 2 > state.max_records or state.bytes + 4_096 > state.max_bytes do
      Logger.warning("motion trace #{state.id}: bound reached; truncated")

      marker = %{
        "event" => "trace.truncated",
        "records" => state.seq + 1,
        "bytes" => state.bytes
      }

      %{line(state, marker) | health: :full, dropped: state.dropped + 1}
    else
      line(state, record)
    end
  end

  defp put(state, _record), do: %{state | dropped: state.dropped + 1}

  defp line(state, record) do
    seq = state.seq + 1
    bytes = JSON.encode!(Map.merge(record, %{"trace_seq" => seq, "trace_id" => state.id})) <> "\n"
    %{state | seq: seq, bytes: state.bytes + byte_size(bytes), buffer: [state.buffer, bytes]}
  end

  defp schedule(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :flush, state.flush_ms)}

  defp schedule(state), do: state

  defp sync(%{buffer: []} = state), do: {:ok, state}

  defp sync(state) do
    with :ok <- :file.write(state.fd, state.buffer),
         :ok <- :file.datasync(state.fd) do
      {:ok, %{state | buffer: []}}
    else
      {:error, reason} ->
        Logger.error("motion trace #{state.id}: write or sync failed (#{inspect(reason)})")
        {:error, reason, %{state | buffer: [], health: {:failed, reason}}}
    end
  end

  defp health_text(:ok), do: "ok"
  defp health_text(:full), do: "full"
  defp health_text(other), do: inspect(other)
end
