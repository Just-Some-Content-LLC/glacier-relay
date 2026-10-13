defmodule GlacierRelayWeb.ReportLive do
  @moduledoc """
  The mission report page (M3-B): every instance and attempt of the projection's snapshot laid
  out with the same components as the dashboard, and the verbatim report text (`Report.render/2`
  over the same state) below it. Read-only; the only interaction collapses or expands sections.
  """

  use Phoenix.LiveView

  import GlacierRelayWeb.Components

  alias GlacierRelay.Dashboard.Projection
  alias GlacierRelay.Report

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: :ok = Phoenix.PubSub.subscribe(GlacierRelay.PubSub, Projection.snapshot_topic())

    {:ok, assign(socket, snapshot: Projection.snapshot(), collapsed: MapSet.new())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.top_header snapshot={@snapshot} />
    <main>
      <p :if={@snapshot.instances == []} class="empty">
        no adapter instance has delivered an event <.tag tag={:not_observed} />
      </p>
      <section :for={i <- @snapshot.instances} class="panel">
        <h2>
          adapter {i.id}
          <.toggle section={i.id} collapsed={@collapsed} />
        </h2>
        <p class="note">
          {i.received} event(s), last sequence {i.last_sequence}, gaps {inspect(i.gaps)}, observation {i.observation}
          <.tag tag={:transport} />
        </p>
        <ul class="lines">
          <li :for={c <- i.report.connections}>{String.trim_leading(Report.connection_line(c))}</li>
        </ul>
        <div :if={not MapSet.member?(@collapsed, i.id)} id={"instance-" <> i.id}>
          <p :if={i.report.attempts == []} class="empty">
            no mission attempt observed <.tag tag={:not_observed} />
          </p>
          <div :for={a <- i.report.attempts}>
            <h2>attempt {a.overview.number}</h2>
            <.attempt_status instance={i} attempt={a} />
            <h2>mission overview</h2>
            <.overview overview={a.overview} />
            <h2>actor outcomes</h2>
            <.outcomes attempt={a} />
            <h2>gameplay activity</h2>
            <.activity attempt={a} pane={:disguises} />
            <h2>timeline</h2>
            <p class="note">{a.timeline.policy}</p>
            <.timeline lines={a.timeline.lines} />
            <h2>uncertainty and limitations</h2>
            <.uncertainty items={a.uncertainty} />
          </div>
          <.strays report={i.report} />
        </div>
      </section>
      <section class="panel">
        <h2>
          report text (verbatim; the same bytes as /report.txt for this snapshot)
          <.toggle section="text" collapsed={@collapsed} />
        </h2>
        <pre :if={not MapSet.member?(@collapsed, "text")} class="report" id="report-text">{@snapshot.report_text}</pre>
      </section>
      <.legend />
    </main>
    """
  end

  @impl true
  def handle_info({:snapshot, %{revision: r} = snapshot}, socket) do
    if r > socket.assigns.snapshot.revision,
      do: {:noreply, assign(socket, snapshot: snapshot)},
      else: {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle", %{"section" => section}, socket) do
    collapsed = socket.assigns.collapsed

    collapsed =
      if MapSet.member?(collapsed, section),
        do: MapSet.delete(collapsed, section),
        else: MapSet.put(collapsed, section)

    {:noreply, assign(socket, collapsed: collapsed)}
  end

  def handle_event(_other, _params, socket), do: {:noreply, socket}
end
