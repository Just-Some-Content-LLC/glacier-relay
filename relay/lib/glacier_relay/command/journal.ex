defmodule GlacierRelay.Command.Journal do
  @moduledoc """
  The append-only command journal (M5-A, ADR 0009): every decision of the command authority and
  every state of the command link, one JSON object per line, in its own file with its own
  identity and version — `glacier-relay.command-journal/1` — separate from mission recordings
  (format 1 is never written by this module) and from the game installation.

  Durability contract: `append/2` returns `:ok` only after the line was written and `datasync`
  succeeded; otherwise `{:error, reason}`, the journal is `:degraded`, and every later append
  fails until the process restarts (a new journal with a new identity). The authority refuses to
  arm or to issue when the required entry cannot be persisted; it never assumes an action was
  audited. Nothing in the observer path (`MissionSession`, the wire, the recorder) calls this
  process, so journal I/O can never block telemetry.

  Location: `dir` (configuration `:journal_dir`, `GLACIER_RELAY_COMMAND_JOURNAL_DIR`) or
  `$XDG_STATE_HOME/glacier-relay/commands` (default `~/.local/state/glacier-relay/commands`), on
  the WSL2 filesystem; the directory is created `0700` and the file `0600`; the file is opened
  exclusively (never over an existing file). On a clean stop a footer is written and synced; a
  journal that ends without a footer was not closed cleanly, and its last line may be partial.
  """

  use GenServer
  require Logger

  alias GlacierRelay.Command.Schema

  @version "glacier-relay.command-journal/1"

  defmodule Writer do
    @moduledoc "The file operations the journal needs; the production writer is `FileWriter`."
    @type fd :: term()
    @callback open(path :: String.t(), opts :: term()) :: {:ok, fd()} | {:error, term()}
    @callback append(fd(), iodata(), opts :: term()) :: :ok | {:error, term()}
    @callback sync(fd(), opts :: term()) :: :ok | {:error, term()}
    @callback close(fd(), opts :: term()) :: :ok | {:error, term()}
  end

  defmodule FileWriter do
    @moduledoc "Raw exclusive file, `datasync` for durability."
    @behaviour GlacierRelay.Command.Journal.Writer
    @impl true
    def open(path, _), do: :file.open(path, [:write, :exclusive, :raw, :binary])
    @impl true
    def append(fd, iodata, _), do: :file.write(fd, iodata)
    @impl true
    def sync(fd, _), do: :file.datasync(fd)
    @impl true
    def close(fd, _), do: :file.close(fd)
  end

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Appends one entry (a map of string keys; `event` names it). `:ok` only after write and datasync."
  @spec append(GenServer.server(), map()) :: :ok | {:error, term()}
  def append(server \\ __MODULE__, %{"event" => _} = entry),
    do: GenServer.call(server, {:append, entry}, 10_000)

  @doc "Status: identity, path, sequence, state and the last error."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  def version, do: @version

  @doc "The default journal directory."
  def default_dir do
    base = System.get_env("XDG_STATE_HOME") || Path.expand("~/.local/state")
    Path.join([base, "glacier-relay", "commands"])
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {writer, wopts} = Keyword.get(opts, :writer, {FileWriter, []})
    dir = Keyword.get(opts, :dir) || default_dir()
    id = Schema.uuid4()
    path = Path.join(dir, "commands-#{id}.ndjson")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, fd} <- writer.open(path, wopts),
         :ok <- File.chmod(path, 0o600) do
      state = %{
        writer: writer,
        wopts: wopts,
        fd: fd,
        path: path,
        id: id,
        seq: 0,
        status: :open,
        last_error: nil,
        opened_mono: mono()
      }

      header = %{
        "event" => "journal.opened",
        "node" => to_string(node()),
        "pid" => System.pid(),
        "otp" => System.otp_release()
      }

      case write(state, header) do
        {:ok, state} ->
          Logger.info("command journal: #{path}")
          {:ok, state}

        {:error, reason, _state} ->
          {:stop, {:journal_open_failed, reason}}
      end
    else
      {:error, reason} -> {:stop, {:journal_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:append, _entry}, _from, %{status: :degraded} = state),
    do: {:reply, {:error, {:degraded, state.last_error}}, state}

  def handle_call({:append, entry}, _from, state) do
    case write(state, entry) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       version: @version,
       journal_id: state.id,
       path: state.path,
       seq: state.seq,
       status: state.status,
       last_error: state.last_error
     }, state}
  end

  @impl true
  def terminate(reason, %{status: :open} = state) do
    _ = write(state, %{"event" => "journal.closed", "reason" => inspect(reason)})
    state.writer.close(state.fd, state.wopts)
    :ok
  end

  def terminate(_reason, state) do
    state.writer.close(state.fd, state.wopts)
    :ok
  end

  # One line: the entry plus the journal's own fields; written, then synced; any failure degrades.
  defp write(state, entry) do
    seq = state.seq + 1

    record =
      entry
      |> Map.merge(%{
        "journal" => @version,
        "journal_id" => state.id,
        "seq" => seq,
        "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "mono_ms" => mono() - state.opened_mono
      })

    line = JSON.encode!(record) <> "\n"

    with :ok <- state.writer.append(state.fd, line, state.wopts),
         :ok <- state.writer.sync(state.fd, state.wopts) do
      {:ok, %{state | seq: seq}}
    else
      {:error, reason} ->
        Logger.error("command journal: write or sync failed (#{inspect(reason)}); degraded")
        {:error, reason, %{state | status: :degraded, last_error: reason}}
    end
  end

  defp mono, do: System.monotonic_time(:millisecond)
end
