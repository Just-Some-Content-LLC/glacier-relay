defmodule GlacierRelay.Test.CountingWriter do
  @moduledoc """
  A `GlacierRelay.Command.Journal.Writer` for the journal-hardening tests: delegates to the
  production file writer until the controlling agent's budget of successful syncs is exhausted,
  after which every sync fails with the configured reason. `fail_after(agent, n, reason)` lets a
  test choose the exact journal entry that fails (the n-th sync counted from the moment the budget
  is set), so a failure can be placed after acceptance, after transmission, on the acknowledgement,
  on the terminal result, on a disarm or on a link loss.
  """
  @behaviour GlacierRelay.Command.Journal.Writer

  alias GlacierRelay.Command.Journal.FileWriter

  def start, do: Agent.start_link(fn -> %{remaining: :infinity, reason: :eio, synced: 0} end)

  @doc "After `n` more successful syncs, every sync fails with `reason`."
  def fail_after(agent, n, reason \\ :eio),
    do: Agent.update(agent, &%{&1 | remaining: n, reason: reason})

  @doc "The number of successful syncs so far."
  def synced(agent), do: Agent.get(agent, & &1.synced)

  @impl true
  def open(path, _agent), do: FileWriter.open(path, [])

  @impl true
  def append(fd, iodata, _agent), do: FileWriter.append(fd, iodata, [])

  @impl true
  def sync(fd, agent) do
    decision =
      Agent.get_and_update(agent, fn
        %{remaining: 0} = s -> {{:fail, s.reason}, s}
        %{remaining: :infinity} = s -> {:ok, %{s | synced: s.synced + 1}}
        %{remaining: n} = s -> {:ok, %{s | remaining: n - 1, synced: s.synced + 1}}
      end)

    case decision do
      :ok -> FileWriter.sync(fd, [])
      {:fail, reason} -> {:error, reason}
    end
  catch
    # The controlling agent is linked to the test process; a journal closing after the test ended
    # falls back to the production sync rather than raising from a dead agent.
    :exit, _ -> FileWriter.sync(fd, [])
  end

  @impl true
  def close(fd, _agent), do: FileWriter.close(fd, [])
end
