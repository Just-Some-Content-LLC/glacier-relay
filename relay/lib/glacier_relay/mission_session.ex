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

  Since M4-B the folding itself is the pure `GlacierRelay.Session.Fold`, shared with the offline
  replay; this process owns what only a process can: the connection pids and their monitors, the
  session-assigned connection and record numbers, the subscribers, the notifications and the
  logging. The fold's state is what `state/0` and `unidentified/0` return.

  Subscribers receive `{:relay_event, %Envelope{}}` for every event and
  `{:relay_connection, :opened | :identified | :closed, info}` for connection evidence.
  No gameplay authority, no persistence.

  Recording-grade subscription (M4-A, ADR 0008): `subscribe(detail: :records)` delivers
  `{:relay_record, %GlacierRelay.Recording.Record{}}` instead — one record per evidence item
  (connection opened, identified or re-attributed, envelope, connection closed), carrying the
  session's record number (one counter, incremented for every item whether or not anyone
  listens), the session-assigned connection number, the validated envelope with its wire
  object, the evidence's own time (the envelope's BEAM receipt time; the connection's open or
  close time) and the close reason. Records are sent at the same points as the ordinary
  notifications, by `send/2`, never acknowledged, and nothing here touches a disk.
  """

  use GenServer
  require Logger

  alias GlacierRelay.Recording.Record
  alias GlacierRelay.Session.Fold
  alias GlacierRelay.Summary
  alias GlacierRelay.Wire.Envelope

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

  @doc """
  The caller's process receives evidence notifications from now on. `detail: :events` (the
  default) delivers `{:relay_event, _}` / `{:relay_connection, _, _}`; `detail: :records`
  delivers `{:relay_record, %Record{}}` (M4-A).
  """
  def subscribe(opts \\ []) do
    detail = Keyword.get(opts, :detail, :events)

    if detail not in [:events, :records],
      do: raise(ArgumentError, "unknown detail #{inspect(detail)}")

    GenServer.call(__MODULE__, {:subscribe, self(), detail})
  end

  @doc "Per-instance lifecycle state, keyed by adapter instance id."
  def state, do: GenServer.call(__MODULE__, :state)

  @doc "The event-derived summary as data (`GlacierRelay.Summary.build/1`)."
  def summary, do: GenServer.call(__MODULE__, :summary)

  @doc "The event-derived summary as text."
  def summary_text, do: GenServer.call(__MODULE__, :summary_text)

  @doc "The mission-oriented report as data (`GlacierRelay.Summary.report/1`, M2 B7)."
  def report, do: GenServer.call(__MODULE__, :report)

  @doc "The mission-oriented report as text (M2 B7)."
  def report_text, do: GenServer.call(__MODULE__, :report_text)

  @doc """
  Connections that closed before delivering an envelope that named an instance (bounded, newest
  first). Transport evidence only; a read for presentations (M3-B projection).
  """
  def unidentified, do: GenServer.call(__MODULE__, :unidentified)

  @impl true
  def init(_opts) do
    {:ok,
     %{
       fold: Fold.new(),
       # pid => %{conn: session connection number, monitor: ref}
       pids: %{},
       subscribers: MapSet.new(),
       # M4-A: record subscribers and the two session-owned counters (records, connections).
       record_subscribers: MapSet.new(),
       record_no: 0,
       conn_no: 0
     }}
  end

  @impl true
  def handle_call({:subscribe, pid, :events}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call({:subscribe, pid, :records}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | record_subscribers: MapSet.put(state.record_subscribers, pid)}}
  end

  def handle_call(:state, _from, state), do: {:reply, state.fold.instances, state}

  def handle_call(:summary, _from, state),
    do: {:reply, Summary.build(state.fold.instances), state}

  def handle_call(:summary_text, _from, state),
    do: {:reply, Summary.render(state.fold.instances, state.fold.unidentified), state}

  def handle_call(:report, _from, state),
    do: {:reply, Summary.report(state.fold.instances), state}

  def handle_call(:report_text, _from, state),
    do: {:reply, Summary.render_report(state.fold.instances, state.fold.unidentified), state}

  def handle_call(:unidentified, _from, state), do: {:reply, state.fold.unidentified, state}

  @impl true
  def handle_cast({:connection_opened, pid, peer, at}, state) do
    ref = Process.monitor(pid)
    no = state.conn_no + 1
    {fold, []} = Fold.connection_opened(state.fold, no, peer, at)

    state = %{
      state
      | fold: fold,
        conn_no: no,
        pids: Map.put(state.pids, pid, %{conn: no, monitor: ref})
    }

    notify(state, {:relay_connection, :opened, %{peer: peer, at: at}})
    {:noreply, record(state, :connection_opened, %{conn: no, peer: peer, at: at})}
  end

  def handle_cast({:event, pid, %Envelope{} = envelope, received_at}, state) do
    id = envelope.adapter_instance_id
    conn = connection_no(state, pid)
    {fold, effects} = Fold.event(state.fold, conn, envelope, received_at)
    state = Enum.reduce(effects, %{state | fold: fold}, &apply_effect/2)

    Logger.info(
      "relay: #{envelope.event_type} ##{envelope.sequence} from #{id} at #{envelope.timestamp}: #{inspect(envelope.payload)}"
    )

    notify(state, {:relay_event, envelope})

    state =
      record(state, :envelope, %{
        conn: conn,
        peer: connection_peer(state, conn),
        instance: id,
        envelope: envelope,
        at: received_at
      })

    {:noreply, state}
  end

  def handle_cast({:connection_closed, pid, reason, at}, state) do
    {:noreply, close_connection(state, pid, reason, at)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    state =
      if Map.has_key?(state.pids, pid),
        do: close_connection(state, pid, {:down, reason}, DateTime.utc_now()),
        else: state

    {:noreply,
     %{
       state
       | subscribers: MapSet.delete(state.subscribers, pid),
         record_subscribers: MapSet.delete(state.record_subscribers, pid)
     }}
  end

  # -- internals -----------------------------------------------------------------------------

  defp connection_no(state, pid), do: state.pids[pid] && state.pids[pid].conn
  defp connection_peer(_state, nil), do: nil

  defp connection_peer(state, conn),
    do: state.fold.connections[conn] && state.fold.connections[conn].peer

  defp close_connection(state, pid, reason, at) do
    case Map.pop(state.pids, pid) do
      {nil, _} ->
        state

      {%{conn: conn, monitor: ref}, pids} ->
        Process.demonitor(ref, [:flush])
        {fold, effects} = Fold.connection_closed(state.fold, conn, reason, at)
        Enum.reduce(effects, %{state | fold: fold, pids: pids}, &apply_effect/2)
    end
  end

  # The fold's effects, in order: notify, record and log what it decided.
  defp apply_effect({:identified, info}, state) do
    notify(
      state,
      {:relay_connection, :identified,
       %{peer: info.peer, instance_id: info.instance, at: info.at}}
    )

    record(state, :connection_identified, info)
  end

  defp apply_effect({:reattributed, info}, state) do
    Logger.warning(
      "relay: #{info.peer} delivered instance #{info.instance} after #{info.previous_instance}"
    )

    record(state, :connection_identified, info)
  end

  defp apply_effect({:note, id, note}, state) do
    log_note(id, note)
    state
  end

  defp apply_effect({:closed, info}, state) do
    notify(
      state,
      {:relay_connection, :closed,
       %{peer: info.peer, instance_id: info.instance, at: info.at, reason: info.reason}}
    )

    state =
      record(state, :connection_closed, Map.take(info, [:conn, :peer, :instance, :reason, :at]))

    if info.playing_attempt do
      Logger.warning(
        "relay: connection for #{info.instance} closed (#{inspect(info.reason)}) while attempt #{info.playing_attempt} is last known playing; no mission.stopped observed"
      )
    end

    state
  end

  defp apply_effect({:unknown_connection, conn}, state) do
    # Cannot happen live (every connection number comes from this process); kept for the fold's
    # contract with the replay.
    Logger.error("relay: evidence named unknown connection #{inspect(conn)}")
    state
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

  defp log_note(id, {:unattributed_disguise_event, sequence}),
    do:
      Logger.warning(
        "relay: #{id}: disguise event ##{sequence} arrived with no open attempt; kept as unattributed"
      )

  defp log_note(id, {:unattributed_item_event, sequence}),
    do:
      Logger.warning(
        "relay: #{id}: item event ##{sequence} arrived with no open attempt; kept as unattributed"
      )

  defp log_note(id, {:unattributed_player_state_event, sequence}),
    do:
      Logger.warning(
        "relay: #{id}: player state event ##{sequence} arrived with no open attempt; kept as unattributed"
      )

  defp log_note(id, {:unattributed_objective_event, sequence, :no_open_attempt}),
    do:
      Logger.warning(
        "relay: #{id}: objective event ##{sequence} arrived with no open attempt; kept as unattributed"
      )

  defp log_note(
         id,
         {:unattributed_objective_event, sequence,
          {:session_contradiction, attempt, attempt_session, occurrence_session}}
       ),
       do:
         Logger.warning(
           "relay: #{id}: objective event ##{sequence} names session #{occurrence_session} while attempt #{attempt} is paired with #{attempt_session}; kept as unattributed, not attached"
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

  # One record per evidence item: the counter advances whether or not anyone is subscribed, so
  # the numbering is the session's and never depends on a listener.
  defp record(state, kind, fields) do
    no = state.record_no + 1

    record =
      struct!(
        Record,
        fields
        |> Map.take(Record.__struct__() |> Map.keys())
        |> Map.put(:no, no)
        |> Map.put(:kind, kind)
      )

    for pid <- state.record_subscribers, do: send(pid, {:relay_record, record})
    %{state | record_no: no}
  end
end
