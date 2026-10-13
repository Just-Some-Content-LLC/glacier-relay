defmodule GlacierRelay.Dashboard.Projection do
  @moduledoc """
  The read-only projection (M3-B, ADR 0007): the single normal web-side subscriber of
  `GlacierRelay.MissionSession`, and the owner of cached presentation snapshots.

  It never holds evidence of its own. A session notification is a change signal, not a snapshot:
  on each coalescing window the projection reads the session's current state (`state/0`,
  `unidentified/0`, after the fold that produced the notification), rebuilds the report entries
  of the instances whose fingerprint changed (`Summary.report/1`, the B7 data unchanged), and
  publishes a snapshot with a monotonically increasing revision on `"dashboard:snapshot"`.
  Envelopes and transport notices are forwarded at once on `"dashboard:events"`, distinct from
  each other and from snapshots.

  Startup (and restart): subscribe, read, build, publish, then handle notifications. Nothing is
  assumed to be in the mailbox; a restart recovers the current state from the session.
  """

  use GenServer
  require Logger

  alias GlacierRelay.{Lifecycle, MissionSession, Summary}
  alias GlacierRelay.Wire.Envelope

  @snapshot_topic "dashboard:snapshot"
  @events_topic "dashboard:events"
  @revision_key {__MODULE__, :revision}
  @sources [:live, :replay]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The current snapshot (read-only; the same value the last broadcast carried)."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Counters and latencies for measurement (read-only)."
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc "Forces a recompute now and returns the new snapshot (diagnostics and tests; read-only)."
  def refresh, do: GenServer.call(__MODULE__, :refresh)

  def snapshot_topic, do: @snapshot_topic
  def events_topic, do: @events_topic

  # -- pure -----------------------------------------------------------------------------------

  @doc """
  Builds a snapshot from session-owned values: the instance map, the unidentified connections,
  previously computed report entries (reused when an instance's fingerprint is unchanged) and
  metadata. Returns `{snapshot, reports, recomputed_ids}`. Pure; used by the process and by tests.
  """
  def build(instances, unidentified, reports, meta) when is_map(instances) do
    {reports, recomputed} = refresh_reports(reports, instances)

    entries =
      instances
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map(fn {id, inst} -> instance_entry(inst, Map.fetch!(reports, id).report) end)

    snapshot = %{
      revision: Map.fetch!(meta, :revision),
      source: Map.fetch!(meta, :source),
      listener: Map.get(meta, :listener, :not_configured),
      built_at: Map.get(meta, :built_at),
      focus: focus(entries),
      instances: entries,
      unidentified: unidentified,
      report_text: Summary.render_report(instances, unidentified)
    }

    {snapshot, reports, recomputed}
  end

  # An instance's report is recomputed only when the evidence it is built from changed: the
  # counters the session keeps (received, last sequence), the transport evidence, and the
  # anomaly count (an envelope can add an anomaly without changing the first two).
  defp fingerprint(%Lifecycle.Instance{} = inst),
    do: {inst.received, inst.last_sequence, inst.connections, length(inst.anomalies)}

  defp refresh_reports(reports, instances) do
    Enum.reduce(instances, {%{}, []}, fn {id, inst}, {acc, recomputed} ->
      fp = fingerprint(inst)

      case reports do
        %{^id => %{fingerprint: ^fp} = cached} ->
          {Map.put(acc, id, cached), recomputed}

        _ ->
          [report] = Summary.report(%{id => inst})
          {Map.put(acc, id, %{fingerprint: fp, report: report}), [id | recomputed]}
      end
    end)
    |> then(fn {acc, recomputed} -> {acc, Enum.reverse(recomputed)} end)
  end

  defp instance_entry(%Lifecycle.Instance{} = inst, report) do
    current = Lifecycle.current_attempt(inst)
    latest = List.last(inst.attempts)

    %{
      id: inst.id,
      observation: Lifecycle.observation(inst),
      received: inst.received,
      last_sequence: inst.last_sequence,
      gaps: inst.gaps,
      connections: report.connections,
      last_event: last_event(inst.last_event),
      current_attempt: current && current.number,
      latest_attempt: latest && latest.number,
      report: report
    }
  end

  defp last_event(nil), do: nil

  defp last_event(%Envelope{} = e),
    do: %{sequence: e.sequence, event_type: e.event_type, timestamp: e.timestamp}

  # Focus: an instance with a live connection, else the one heard from most recently (Relay
  # publication time of its last envelope; the native clock, as a string in one format).
  defp focus([]), do: nil

  defp focus(entries) do
    live = Enum.filter(entries, &(&1.observation == :live))

    pool = if live == [], do: entries, else: live

    pool
    |> Enum.max_by(&((&1.last_event && &1.last_event.timestamp) || ""), fn -> hd(pool) end)
    |> Map.fetch!(:id)
  end

  # -- process ----------------------------------------------------------------------------------

  @impl true
  def init(opts) do
    config = Application.get_env(:glacier_relay, :dashboard, [])
    source = Keyword.get(opts, :source, Keyword.get(config, :source, :live))

    if source not in @sources, do: raise(ArgumentError, "unknown source #{inspect(source)}")

    coalesce_ms = Keyword.get(opts, :coalesce_ms, Keyword.get(config, :coalesce_ms, 50))

    # Subscribe first, then read: an event folded between the two is both notified (a later
    # recompute) and already in the state read (idempotent), so none is missed.
    :ok = MissionSession.subscribe()

    state = %{
      source: source,
      coalesce_ms: coalesce_ms,
      reports: %{},
      dirty: MapSet.new(),
      timer: nil,
      snapshot: nil,
      stats: new_stats()
    }

    {:ok, recompute(state)}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}
  def handle_call(:stats, _from, state), do: {:reply, state.stats, state}

  def handle_call(:refresh, _from, state) do
    state = recompute(cancel_timer(state))
    {:reply, state.snapshot, state}
  end

  @impl true
  def handle_info({:relay_event, %Envelope{} = envelope}, state) do
    broadcast(@events_topic, {:event, envelope.adapter_instance_id, envelope})

    state =
      state
      |> update_in([:stats, :events_seen], &(&1 + 1))
      |> mark_dirty(envelope.adapter_instance_id)
      |> schedule()

    {:noreply, state}
  end

  def handle_info({:relay_connection, kind, info}, state) do
    instance_id = Map.get(info, :instance_id)
    broadcast(@events_topic, {:transport, instance_id, kind, info})

    state =
      state
      |> update_in([:stats, :transport_seen], &(&1 + 1))
      |> mark_dirty(instance_id || :unidentified)
      |> schedule()

    {:noreply, state}
  end

  def handle_info(:coalesce, state), do: {:noreply, recompute(%{state | timer: nil})}

  def handle_info(_other, state), do: {:noreply, state}

  defp mark_dirty(state, id), do: %{state | dirty: MapSet.put(state.dirty, id)}

  # At most one pending timer.
  defp schedule(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :coalesce, state.coalesce_ms)}

  defp schedule(state), do: state

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: ref} = state) do
    Process.cancel_timer(ref)

    receive do
      :coalesce -> :ok
    after
      0 -> :ok
    end

    %{state | timer: nil}
  end

  defp recompute(state) do
    {read_us, {instances, unidentified}} =
      :timer.tc(fn -> {MissionSession.state(), MissionSession.unidentified()} end)

    meta = %{
      revision: next_revision(),
      source: state.source,
      listener: listener(),
      built_at: DateTime.utc_now()
    }

    {compute_us, {snapshot, reports, recomputed}} =
      :timer.tc(fn -> build(instances, unidentified, state.reports, meta) end)

    broadcast(@snapshot_topic, {:snapshot, snapshot})

    stats =
      state.stats
      |> Map.update!(:recomputes, &(&1 + 1))
      |> Map.update!(:snapshots_published, &(&1 + 1))
      |> Map.put(:last_revision, snapshot.revision)
      |> Map.put(:dirty_ids_last, MapSet.to_list(state.dirty))
      |> Map.put(:recomputed_instances_last, recomputed)
      |> Map.update!(:recomputed_instances_total, &(&1 + length(recomputed)))
      |> Map.update!(:read_us, &latency(&1, read_us))
      |> Map.update!(:compute_us, &latency(&1, compute_us))

    %{state | snapshot: snapshot, reports: reports, dirty: MapSet.new(), stats: stats}
  end

  defp new_stats do
    %{
      recomputes: 0,
      snapshots_published: 0,
      events_seen: 0,
      transport_seen: 0,
      last_revision: 0,
      dirty_ids_last: [],
      recomputed_instances_last: [],
      recomputed_instances_total: 0,
      read_us: %{last: 0, max: 0, total: 0},
      compute_us: %{last: 0, max: 0, total: 0}
    }
  end

  defp latency(l, us), do: %{last: us, max: max(l.max, us), total: l.total + us}

  # Revisions keep increasing across projection restarts within one VM.
  defp next_revision do
    revision = :persistent_term.get(@revision_key, 0) + 1
    :persistent_term.put(@revision_key, revision)
    revision
  end

  # The wire listener's configured bind, for the header; read from configuration, never by
  # calling the listener.
  defp listener do
    case Application.get_env(:glacier_relay, GlacierRelay.Wire.Listener) do
      nil ->
        :not_configured

      config ->
        %{ip: Keyword.get(config, :ip), port: Keyword.get(config, :port), basis: :configured}
    end
  end

  defp broadcast(topic, message),
    do: Phoenix.PubSub.broadcast(GlacierRelay.PubSub, topic, message)
end
