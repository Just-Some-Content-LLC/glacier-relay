defmodule GlacierRelay.Test.StubWriter do
  @moduledoc """
  A `GlacierRelay.Recording.Writer` for tests: delegates to the production file writer unless
  the controlling agent says otherwise. Modes: `:ok`; `{:fail_append, reason}`;
  `{:fail_sync, reason}`; `:stall` (the writer blocks inside `append` until the mode changes,
  polling the agent, so the recorder process stalls exactly as it would on a hung disk).
  """
  @behaviour GlacierRelay.Recording.Writer

  alias GlacierRelay.Recording.FileWriter

  def start, do: Agent.start_link(fn -> :ok end)
  def mode(agent, mode), do: Agent.update(agent, fn _ -> mode end)

  @impl true
  def open(path, _agent), do: FileWriter.open(path, [])

  @impl true
  def append(fd, iodata, agent) do
    case wait(agent) do
      {:fail_append, reason} -> {:error, reason}
      _ -> FileWriter.append(fd, iodata, [])
    end
  end

  @impl true
  def sync(fd, agent) do
    case Agent.get(agent, & &1) do
      {:fail_sync, reason} -> {:error, reason}
      _ -> FileWriter.sync(fd, [])
    end
  end

  @impl true
  def close(fd, _agent), do: FileWriter.close(fd, [])

  defp wait(agent) do
    case Agent.get(agent, & &1) do
      :stall ->
        Process.sleep(10)
        wait(agent)

      mode ->
        mode
    end
  end
end
