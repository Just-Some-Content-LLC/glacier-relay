defmodule GlacierRelayWeb.DashboardLive do
  @moduledoc """
  The read-only dashboard (M3-B). Owns viewer choices only: which instance, which attempt, which
  activity pane, which sections are collapsed, and a bounded recent-event window. Everything
  shown is the projection's snapshot (the B7 report data unchanged) and the Relay envelopes and
  transport notices the projection forwards. No event here reaches `MissionSession`, the wire or
  the game.
  """

  use Phoenix.LiveView

  import GlacierRelayWeb.Components

  alias GlacierRelay.Dashboard.Projection

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Phoenix.PubSub.subscribe(GlacierRelay.PubSub, Projection.snapshot_topic())
      :ok = Phoenix.PubSub.subscribe(GlacierRelay.PubSub, Projection.events_topic())
    end

    socket =
      socket
      |> assign(
        focus_choice: nil,
        attempt_choice: nil,
        pane: :disguises,
        collapsed: MapSet.new(),
        stream_limit: stream_limit(),
        revision: 0
      )
      |> stream(:events, [])
      |> apply_snapshot(Projection.snapshot())

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_body
      snapshot={@snapshot}
      focus_id={@focus_id}
      instance={@instance}
      attempt={@attempt}
      attempt_number={@attempt_number}
      pane={@pane}
      collapsed={@collapsed}
      events={@streams.events}
      stream_limit={@stream_limit}
    />
    """
  end

  # -- projection messages -------------------------------------------------------------------

  @impl true
  def handle_info({:snapshot, %{revision: r} = snapshot}, socket) do
    if r > socket.assigns.revision,
      do: {:noreply, apply_snapshot(socket, snapshot)},
      else: {:noreply, socket}
  end

  def handle_info({:event, instance_id, envelope}, socket) when is_map(envelope) do
    {:noreply, insert_row(socket, event_row(instance_id, envelope))}
  end

  def handle_info({:transport, instance_id, kind, info}, socket) do
    {:noreply, insert_row(socket, transport_row(instance_id, kind, info))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # -- viewer choices (presentation only) ----------------------------------------------------

  @impl true
  def handle_event("focus", %{"id" => id}, socket) do
    socket = assign(socket, focus_choice: id, attempt_choice: nil)
    {:noreply, apply_snapshot(socket, socket.assigns.snapshot)}
  end

  def handle_event("select_attempt", %{"number" => number}, socket) do
    socket = assign(socket, attempt_choice: String.to_integer(number))
    {:noreply, apply_snapshot(socket, socket.assigns.snapshot)}
  end

  def handle_event("select_pane", %{"pane" => pane}, socket) do
    pane = Enum.find(panes(), :disguises, &(Atom.to_string(&1) == pane))
    {:noreply, assign(socket, pane: pane)}
  end

  def handle_event("toggle", %{"section" => section}, socket) do
    collapsed = socket.assigns.collapsed

    collapsed =
      if MapSet.member?(collapsed, section),
        do: MapSet.delete(collapsed, section),
        else: MapSet.put(collapsed, section)

    {:noreply, assign(socket, collapsed: collapsed)}
  end

  def handle_event("clear_events", _params, socket) do
    {:noreply, stream(socket, :events, [], reset: true)}
  end

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  # -- internals --------------------------------------------------------------------------------

  defp apply_snapshot(socket, snapshot) do
    a = socket.assigns
    ids = Enum.map(snapshot.instances, & &1.id)
    focus_id = choose(a.focus_choice, ids, snapshot.focus)
    instance = Enum.find(snapshot.instances, &(&1.id == focus_id))
    attempts = if instance, do: instance.report.attempts, else: []
    numbers = Enum.map(attempts, & &1.overview.number)
    default = instance && (instance.current_attempt || instance.latest_attempt)
    attempt_number = choose(a.attempt_choice, numbers, default)
    attempt = Enum.find(attempts, &(&1.overview.number == attempt_number))

    assign(socket,
      snapshot: snapshot,
      revision: snapshot.revision,
      focus_id: focus_id,
      instance: instance,
      attempt_number: attempt_number,
      attempt: attempt
    )
  end

  defp choose(choice, valid, default), do: if(choice in valid, do: choice, else: default)

  defp insert_row(socket, row),
    do: stream_insert(socket, :events, row, at: 0, limit: socket.assigns.stream_limit)

  defp event_row(instance_id, e) do
    %{
      id: "evt-#{instance_id}-#{e.sequence}",
      kind: :event,
      instance_id: instance_id,
      sequence: e.sequence,
      at: e.timestamp,
      type: "#{e.event_type} v#{e.schema_version}",
      detail: payload_text(e.payload),
      tag: :engine
    }
  end

  defp transport_row(instance_id, kind, info) do
    detail =
      case info do
        %{peer: peer, reason: reason} ->
          "#{peer} (#{inspect(reason)}); no mission fact is implied"

        %{peer: peer} ->
          "#{peer}; no mission fact is implied"

        _ ->
          "no mission fact is implied"
      end

    %{
      id: "tr-#{System.unique_integer([:positive, :monotonic])}",
      kind: :transport,
      instance_id: instance_id,
      sequence: nil,
      at: fmt(Map.get(info, :at)),
      type: "connection #{kind}",
      detail: detail,
      tag: :transport
    }
  end

  # The envelope's payload as the schema carries it, nothing interpreted; bounded for the row.
  defp payload_text(payload) do
    text = JSON.encode!(payload)
    if String.length(text) > 220, do: String.slice(text, 0, 220) <> "…", else: text
  end

  defp stream_limit do
    :glacier_relay
    |> Application.get_env(:dashboard, [])
    |> Keyword.get(:stream_limit, 200)
  end

  defp fmt(nil), do: "?"
  defp fmt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp fmt(other), do: to_string(other)
end
