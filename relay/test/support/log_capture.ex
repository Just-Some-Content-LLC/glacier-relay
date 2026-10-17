defmodule GlacierRelay.Test.LogCapture do
  @moduledoc """
  A test-only `:logger` handler (M6-F1a token-guard correction): forwards every log event it
  receives, unmodified, to the process that attached it, so a test can inspect the raw
  structured reports (gen_server terminate, proc_lib crash, supervisor child_terminated) as well
  as the translated text. It filters nothing and changes nothing; the test adds and removes it.
  """

  @doc false
  def log(event, %{config: %{pid: pid}}), do: send(pid, {:log_event, event})

  @doc "Attaches a handler that forwards every event (all levels, no filters) to the caller."
  def attach(id) do
    :ok =
      :logger.add_handler(id, __MODULE__, %{
        config: %{pid: self()},
        level: :all,
        filter_default: :log,
        filters: []
      })
  end

  @doc "Removes the handler."
  def detach(id), do: :logger.remove_handler(id)

  @doc "Every forwarded event currently in the caller's mailbox."
  def drain(acc \\ []) do
    receive do
      {:log_event, event} -> drain([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
