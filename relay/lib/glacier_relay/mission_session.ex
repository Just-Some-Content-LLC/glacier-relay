defmodule GlacierRelay.MissionSession do
  @moduledoc """
  Where evidence lands inside BEAM. Holds one `Lifecycle.Instance` per adapter instance id and
  routes three kinds of evidence into it without mixing them (M2 design):

  - validated semantic envelopes from `Wire.Connection` (game lifecycle evidence),
  - the adapter instance id each envelope names (adapter/process evidence),
  - connection open/close from `Wire.Connection` (transport evidence).

  A connection is attributed to an instance only once it has delivered a valid envelope naming
  one; until then it is an unidentified connection, and if it closes first it stays that way. A
  connection closing never asserts anything about a mission; see `GlacierRelay.Lifecycle`.

  Subscribers receive `{:relay_event, %Envelope{}}` for every event and
  `{:relay_connection, :opened | :identified | :closed, info}` for connection evidence.
  No gameplay authority, no persistence.
  """

  use GenServer
  require Logger

  alias GlacierRelay.{Lifecycle, Summary}
  alias GlacierRelay.Wire.Envelope

  @max_unidentified 32

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Called by a connection process when its socket has been accepted."
  def connection_opened(peer, at \\ DateTime.utc_now()),
    do: GenServer.cast(__MODULE__, {:connection_opened, self(), peer, at})

  @doc "Delivers a validated envelope from the calling connection process."
  def handle_event(%Envelope{} = envelope, received_at \\ DateTime.utc_now()),
    do: GenServer.cast(__MODULE__, {:event, self(), envelope, received_at})

  @doc "Called by a connection process when its socket closed or failed."
  def connection_closed(reason, at \\ DateTime.utc_now()),
    do: GenServer.cast(__MODULE__, {:connection_closed, self(), reason, at})

  @doc "The caller's process receives evidence notifications from now on."
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  @doc "Per-instance lifecycle state, keyed by adapter instance id."
  def state, do: GenServer.call(__MODULE__, :state)

  @doc "The event-derived summary as data (`GlacierRelay.Summary.build/1`)."
  def summary, do: GenServer.call(__MODULE__, :summary)

  @doc "The event-derived summary as text."
  def summary_text, do: GenServer.call(__MODULE__, :summary_text)

  @impl true
  def init(_opts) do
    {:ok, %{instances: %{}, connections: %{}, unidentified: [], subscribers: MapSet.new()}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call(:state, _from, state), do: {:reply, state.instances, state}
  def handle_call(:summary, _from, state), do: {:reply, Summary.build(state.instances), state}

  def handle_call(:summary_text, _from, state),
    do: {:reply, Summary.render(state.instances, state.unidentified), state}

  @impl true
  def handle_cast({:connection_opened, pid, peer, at}, state) do
    ref = Process.monitor(pid)
    connection = %{peer: peer, opened_at: at, instance_id: nil, monitor: ref}
    notify(state, {:relay_connection, :opened, %{peer: peer, at: at}})
    {:noreply, put_in(state.connections[pid], connection)}
  end

  def handle_cast({:event, pid, %Envelope{} = envelope, received_at}, state) do
    id = envelope.adapter_instance_id
    instance = Map.get_lazy(state.instances, id, fn -> Lifecycle.new(id) end)

    {state, instance} = identify(state, pid, id, instance, received_at)
    {instance, notes} = Lifecycle.apply_event(instance, envelope, received_at)

    for note <- notes, do: log_note(id, note)

    Logger.info(
      "relay: #{envelope.event_type} ##{envelope.sequence} from #{id} at #{envelope.timestamp}: #{inspect(envelope.payload)}"
    )

    notify(state, {:relay_event, envelope})
    {:noreply, put_in(state.instances[id], instance)}
  end

  def handle_cast({:connection_closed, pid, reason, at}, state) do
    {:noreply, close_connection(state, pid, reason, at)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    state =
      if Map.has_key?(state.connections, pid),
        do: close_connection(state, pid, {:down, reason}, DateTime.utc_now()),
        else: state

    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  # -- internals -----------------------------------------------------------------------------

  # Attributes the connection to the instance on its first valid envelope. A connection that was
  # never announced (direct callers in tests) is treated as opened at identification time.
  defp identify(state, pid, id, instance, at) do
    case state.connections[pid] do
      %{instance_id: ^id} ->
        {state, instance}

      %{instance_id: nil} = connection ->
        instance =
          Lifecycle.connection_identified(instance, connection.peer, connection.opened_at, at)

        notify(
          state,
          {:relay_connection, :identified, %{peer: connection.peer, instance_id: id, at: at}}
        )

        {put_in(state.connections[pid], %{connection | instance_id: id}), instance}

      %{instance_id: other} = connection ->
        # The same socket switched instance ids: not something the native adapter does, but it is
        # evidence, so record it as a new attribution rather than drop the event.
        Logger.warning("relay: #{connection.peer} delivered instance #{id} after #{other}")

        instance =
          Lifecycle.connection_identified(instance, connection.peer, connection.opened_at, at)

        {put_in(state.connections[pid], %{connection | instance_id: id}), instance}

      nil ->
        {state, instance}
    end
  end

  defp close_connection(state, pid, reason, at) do
    case Map.pop(state.connections, pid) do
      {nil, _} ->
        state

      {%{monitor: ref} = connection, connections} ->
        Process.demonitor(ref, [:flush])
        state = %{state | connections: connections}

        notify(
          state,
          {:relay_connection, :closed,
           %{peer: connection.peer, instance_id: connection.instance_id, at: at, reason: reason}}
        )

        case connection.instance_id do
          nil ->
            record = %{
              peer: connection.peer,
              opened_at: connection.opened_at,
              closed_at: at,
              close_reason: reason
            }

            %{state | unidentified: Enum.take([record | state.unidentified], @max_unidentified)}

          id ->
            instance = Lifecycle.connection_closed(state.instances[id], at, reason)

            if Lifecycle.current_attempt(instance) do
              Logger.warning(
                "relay: connection for #{id} closed (#{inspect(reason)}) while attempt #{Lifecycle.current_attempt(instance).number} is last known playing; no mission.stopped observed"
              )
            end

            put_in(state.instances[id], instance)
        end
    end
  end

  defp log_note(id, {:gap, expected, got}),
    do: Logger.warning("relay: sequence gap for #{id}: expected #{expected}, got #{got}")

  defp log_note(id, {:superseded, old, new}),
    do:
      Logger.warning(
        "relay: #{id}: attempt #{old} superseded by attempt #{new}; its stop was not observed"
      )

  defp log_note(id, {:unmatched_stop, sequence}),
    do: Logger.warning("relay: #{id}: mission.stopped ##{sequence} with no open attempt")

  defp log_note(id, {:unattributed_outcome, sequence}),
    do:
      Logger.warning(
        "relay: #{id}: actor outcome ##{sequence} arrived with no open attempt; kept as unattributed"
      )

  defp log_note(id, {:contract_started_again, session_id, sequence}),
    do:
      Logger.warning(
        "relay: #{id}: contract.started ##{sequence} for session #{session_id}, which had already started"
      )

  defp log_note(id, {:contract_pending_multiple, ids}),
    do:
      Logger.warning(
        "relay: #{id}: #{length(ids)} contract sessions started with no attempt to pair: #{inspect(ids)}"
      )

  defp log_note(id, {:contract_pairing_ambiguous, number, ids}),
    do:
      Logger.warning(
        "relay: #{id}: attempt #{number} opened with #{length(ids)} waiting contract sessions; none paired: #{inspect(ids)}"
      )

  defp log_note(id, {:attempt_disposition, number, disposition, relative}),
    do:
      Logger.info(
        "relay: #{id}: attempt #{number} disposition #{inspect(disposition)} from contract.ended (#{relative})"
      )

  defp log_note(id, {:unmatched_contract_end, sequence, session_id}),
    do:
      Logger.warning(
        "relay: #{id}: contract.ended ##{sequence} for session #{session_id} with no open contract session; kept unmatched"
      )

  defp log_note(id, {:contract_end_ambiguous, sequence, session_id}),
    do:
      Logger.warning(
        "relay: #{id}: contract.ended ##{sequence} matches several open sessions #{session_id}; kept unmatched"
      )

  defp log_note(id, {:fall_scene_differs, number, rise, fall}),
    do:
      Logger.warning(
        "relay: #{id}: attempt #{number} rose on #{inspect(rise)} and fell on #{inspect(fall)}"
      )

  defp notify(state, message) do
    for pid <- state.subscribers, do: send(pid, message)
  end
end
