defmodule GlacierRelay.Test.TraceProxy do
  @moduledoc """
  M7-B1 correction test support: a stand-in for the motion trace server, injected into
  `Motion.Hub`'s state by the test with `:sys.replace_state/2` (no production seam). It answers
  the hub's `Trace.append/3` calls by passing each batch to the real trace, except that, when armed
  with `hold_next/2`, it holds the next batch containing a record of the named event (for example
  `"destination.forward"`) — the hub waits in its required trace write — tells the test process
  `{:held, records, beam_mono_ms}`, and answers only on `release/1`. That is a controlled delay in
  the required trace path, released at a time the test chooses.
  """
  use GenServer

  alias GlacierRelay.Motion.Clock

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Holds the next append batch that contains a record whose \"event\" is `event`."
  def hold_next(pid, event), do: GenServer.call(pid, {:hold_next, event})

  @doc "Passes the held batch to the real trace and answers the hub. `:ok` or `:nothing_held`."
  def release(pid), do: GenServer.call(pid, :release)

  @impl true
  def init(opts),
    do:
      {:ok,
       %{
         real: Keyword.fetch!(opts, :real),
         notify: Keyword.fetch!(opts, :notify),
         armed: nil,
         held: nil
       }}

  @impl true
  def handle_call({:hold_next, event}, _from, state), do: {:reply, :ok, %{state | armed: event}}

  def handle_call(:release, _from, %{held: {from, records}} = state) do
    GenServer.reply(from, GenServer.call(state.real, {:append, records}))
    {:reply, :ok, %{state | held: nil}}
  end

  def handle_call(:release, _from, state), do: {:reply, :nothing_held, state}

  def handle_call({:append, records}, from, %{armed: event} = state) when is_binary(event) do
    if Enum.any?(records, &(&1["event"] == event)) do
      send(state.notify, {:held, records, Clock.now_ms()})
      {:noreply, %{state | armed: nil, held: {from, records}}}
    else
      {:reply, GenServer.call(state.real, {:append, records}), state}
    end
  end

  def handle_call({:append, records}, _from, state),
    do: {:reply, GenServer.call(state.real, {:append, records}), state}
end
