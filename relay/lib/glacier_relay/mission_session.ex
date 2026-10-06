defmodule GlacierRelay.MissionSession do
  @moduledoc """
  Where decoded semantic events land inside BEAM. For M1 it keeps, per adapter instance, the last
  sequence seen, whether a mission is playing, the last event, and any sequence gaps, and tells
  subscribers about each event. No gameplay authority, no persistence.

  A gap (sequence not equal to last + 1) is recorded, not treated as an error: delivery is
  best-effort during a live connection, and a new instance id means the game process restarted.
  """

  use GenServer
  require Logger

  alias GlacierRelay.Wire.Envelope

  defmodule Instance do
    @moduledoc false
    defstruct last_sequence: 0, playing?: false, last_event: nil, received: 0, gaps: []
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Delivers a validated envelope. Called by connection processes."
  def handle_event(%Envelope{} = envelope), do: GenServer.cast(__MODULE__, {:event, envelope})

  @doc "The caller's process receives `{:relay_event, %Envelope{}}` for every event from now on."
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  def state, do: GenServer.call(__MODULE__, :state)

  @impl true
  def init(_opts), do: {:ok, %{instances: %{}, subscribers: MapSet.new()}}

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call(:state, _from, state), do: {:reply, state.instances, state}

  @impl true
  def handle_cast({:event, %Envelope{} = envelope}, state) do
    instance = Map.get(state.instances, envelope.adapter_instance_id, %Instance{})
    expected = instance.last_sequence + 1

    gaps =
      if envelope.sequence == expected or instance.last_sequence == 0 do
        instance.gaps
      else
        Logger.warning(
          "relay: sequence gap for #{envelope.adapter_instance_id}: expected #{expected}, got #{envelope.sequence}"
        )

        [{expected, envelope.sequence} | instance.gaps]
      end

    instance = %{
      instance
      | last_sequence: max(instance.last_sequence, envelope.sequence),
        playing?: envelope.event_type == GlacierRelay.Events.mission_playing(),
        last_event: envelope,
        received: instance.received + 1,
        gaps: gaps
    }

    Logger.info(
      "relay: #{envelope.event_type} ##{envelope.sequence} from #{envelope.adapter_instance_id} at #{envelope.timestamp}: #{inspect(envelope.payload)}"
    )

    for pid <- state.subscribers, do: send(pid, {:relay_event, envelope})

    {:noreply,
     %{state | instances: Map.put(state.instances, envelope.adapter_instance_id, instance)}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end
end
