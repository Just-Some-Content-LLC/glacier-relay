defmodule GlacierRelayWeb.Components do
  @moduledoc """
  Function components that lay out the projection's snapshot (M3-B). Every fact shown comes from
  the B7 report data unchanged; the wording is the report's own (`GlacierRelay.Report` helpers),
  and every fact carries the tag the data gives it. Nothing here derives, counts, infers or
  rewrites a fact.
  """

  use Phoenix.Component

  alias GlacierRelay.Report

  @panes [
    {:disguises, "disguises", :disguise},
    {:items, "items", :item},
    {:objectives, "objectives", :objective},
    {:player, "player state", :player_state}
  ]

  def panes, do: Enum.map(@panes, &elem(&1, 0))

  # -- the whole dashboard body (a function component so it can be rendered without a socket) ---

  attr :snapshot, :map, required: true
  attr :focus_id, :string, default: nil
  attr :instance, :map, default: nil
  attr :attempt, :map, default: nil
  attr :attempt_number, :integer, default: nil
  attr :pane, :atom, default: :disguises
  attr :collapsed, :any, default: MapSet.new()
  attr :events, :any, default: []
  attr :stream_limit, :integer, default: 200

  def dashboard_body(assigns) do
    ~H"""
    <.top_header snapshot={@snapshot} />
    <main>
      <p :if={@snapshot.instances == []} class="empty">
        no adapter instance has delivered an event <.tag tag={:not_observed} />
      </p>
      <div class="cards">
        <.instance_card
          :for={i <- @snapshot.instances}
          instance={i}
          focused={i.id == @focus_id}
        />
      </div>
      <div :if={@instance} class="grid">
        <div>
          <section class="panel">
            <h2>mission attempt</h2>
            <div class="attempts">
              <button
                :for={a <- @instance.report.attempts}
                class={a.overview.number == @attempt_number && "active"}
                phx-click="select_attempt"
                phx-value-number={a.overview.number}
              >
                attempt {a.overview.number}
              </button>
            </div>
            <.attempt_status instance={@instance} attempt={@attempt} />
            <.overview :if={@attempt} overview={@attempt.overview} />
          </section>
          <section :if={@attempt} class="panel">
            <h2>actor outcomes</h2>
            <.outcomes attempt={@attempt} />
          </section>
          <section :if={@attempt} class="panel">
            <h2>gameplay activity</h2>
            <.activity attempt={@attempt} pane={@pane} />
          </section>
          <section :if={@attempt} class="panel">
            <h2>
              timeline
              <.toggle section="timeline" collapsed={@collapsed} />
            </h2>
            <p class="note">{@attempt.timeline.policy}</p>
            <.timeline :if={not MapSet.member?(@collapsed, "timeline")} lines={@attempt.timeline.lines} />
          </section>
          <.strays report={@instance.report} />
        </div>
        <div>
          <section :if={@attempt} class="panel">
            <h2>uncertainty and limitations</h2>
            <.uncertainty items={@attempt.uncertainty} />
          </section>
          <section class="panel">
            <h2>
              recent Relay events
              <button class="small" phx-click="clear_events">clear view</button>
            </h2>
            <p class="note">
              bounded window: the newest {@stream_limit} rows this viewer received; a presentation limit, never evidence loss (the report keeps every record)
            </p>
            <.event_table events={@events} />
          </section>
        </div>
      </div>
      <.legend />
    </main>
    """
  end

  attr :snapshot, :map, required: true

  def top_header(assigns) do
    ~H"""
    <header class="top">
      <h1>Glacier Relay — live observability</h1>
      <span class="meta">wire listener {listener_text(@snapshot.listener)}</span>
      <span class="meta">
        snapshot r{@snapshot.revision} · source {@snapshot.source} · built {fmt(@snapshot.built_at)}
      </span>
      <span class="meta">
        <a href="/">dashboard</a> · <a href="/report">report</a> · <a href="/report.txt">report.txt</a>
        · <a href="/summary.txt">summary.txt</a>
      </span>
    </header>
    """
  end

  # -- instances ---------------------------------------------------------------------------------

  attr :instance, :map, required: true
  attr :focused, :boolean, default: false

  def instance_card(assigns) do
    ~H"""
    <div class={["card", @focused && "focused"]} phx-click="focus" phx-value-id={@instance.id}>
      <div class="id">adapter {@instance.id}</div>
      <div class={"obs #{@instance.observation}"}>
        observation {@instance.observation} <.tag tag={:transport} />
      </div>
      <div class="note">
        {@instance.received} event(s), last sequence {@instance.last_sequence}, gaps {inspect(
          @instance.gaps
        )}
      </div>
      <div :if={@instance.last_event} class="note">
        last envelope #{@instance.last_event.sequence} {@instance.last_event.event_type} at {@instance.last_event.timestamp}
      </div>
      <div class="note">{attempt_note(@instance)}</div>
    </div>
    """
  end

  defp attempt_note(%{current_attempt: n}) when is_integer(n),
    do: "attempt #{n} last known playing"

  defp attempt_note(%{latest_attempt: n}) when is_integer(n),
    do: "latest attempt #{n}, not playing"

  defp attempt_note(_), do: "no mission attempt observed"

  attr :instance, :map, required: true
  attr :attempt, :map, default: nil

  def attempt_status(assigns) do
    ~H"""
    <p :if={@attempt} class="status">
      attempt {@attempt.overview.number}: {mission_text(@attempt.overview)}
      <span class="qual">{observation_text(@instance.observation)}</span>
    </p>
    <p :if={!@attempt} class="status empty">
      no mission attempt observed <.tag tag={:not_observed} />
    </p>
    """
  end

  # The predicate's last observed state and the transport's state, side by side and never merged.
  defp mission_text(%{mission: :playing}),
    do: "last known playing (the predicate rose; no fall observed)"

  defp mission_text(%{mission: :stopped, stop: %{sequence: s}}),
    do: "stopped at ##{s} (the predicate fell)"

  defp mission_text(%{mission: :superseded, stop: %{reason: {:superseded, by}}}),
    do: "superseded by attempt #{by}; its stop was not observed"

  defp observation_text(:live), do: "; observation live (a connection is open)"

  defp observation_text(:lost),
    do: "; observation lost (the connection closed; no mission.stopped is implied)"

  defp observation_text(:never), do: "; no connection evidence for this instance"

  # -- attempt panels ----------------------------------------------------------------------------

  attr :overview, :map, required: true

  def overview(assigns) do
    ~H"""
    <ul class="lines">
      <li :for={l <- Report.overview_lines(@overview)}>{String.trim_leading(l)}</li>
    </ul>
    """
  end

  attr :attempt, :map, required: true

  def outcomes(assigns) do
    ~H"""
    <p class="note">
      engine telemetry; grouping by name and definition id is display only, never an actor identity
    </p>
    <p :if={@attempt.targets.groups == []} class="note">
      target outcomes observed: none in the stream; {@attempt.targets.note} <.tag tag={:not_observed} />
    </p>
    <div :if={@attempt.targets.groups != []}>
      <p class="note">target outcomes observed ({@attempt.targets.note}) <.tag tag={:engine} /></p>
      <ul class="lines">
        <li :for={l <- Enum.flat_map(@attempt.targets.groups, &Report.group_lines/1)}>
          {String.trim_leading(l)}
        </li>
      </ul>
    </div>
    <p :if={@attempt.non_targets.groups == []} class="note">
      non-target outcomes observed: none in the stream <.tag tag={:not_observed} />
    </p>
    <div :if={@attempt.non_targets.groups != []}>
      <p class="note">non-target outcomes observed <.tag tag={:engine} /></p>
      <ul class="lines">
        <li :for={l <- Enum.flat_map(@attempt.non_targets.groups, &Report.group_lines/1)}>
          {String.trim_leading(l)}
        </li>
      </ul>
    </div>
    <p class="note">
      counts: {Report.counts_text(@attempt.outcome_counts)} [engine classifications; occurrence counts, not an actor count]
    </p>
    """
  end

  attr :attempt, :map, required: true
  attr :pane, :atom, required: true

  def activity(assigns) do
    assigns =
      assign(assigns,
        panes: @panes,
        family: family(assigns.pane),
        lines: Report.activity_lines(assigns.attempt.activity)
      )

    ~H"""
    <ul class="lines">
      <li :for={l <- @lines}>{String.trim_leading(l)}</li>
    </ul>
    <div class="tabs">
      <button
        :for={{key, label, _} <- @panes}
        class={key == @pane && "active"}
        phx-click="select_pane"
        phx-value-pane={key}
      >
        {label}
      </button>
    </div>
    <ul class="lines">
      <li :for={l <- Enum.filter(@attempt.timeline.lines, &(&1.family == @family))}>
        {String.trim_leading(Report.line_text(l))}
      </li>
    </ul>
    <p :if={Enum.all?(@attempt.timeline.lines, &(&1.family != @family))} class="empty">
      no occurrence of this family in the attempt <.tag tag={:not_observed} />
    </p>
    """
  end

  defp family(pane) do
    case List.keyfind(@panes, pane, 0) do
      {_, _, family} -> family
      nil -> :disguise
    end
  end

  attr :lines, :list, required: true

  def timeline(assigns) do
    ~H"""
    <ul class="lines">
      <li :for={l <- @lines}>{String.trim_leading(Report.line_text(l))}</li>
    </ul>
    """
  end

  attr :items, :list, required: true

  def uncertainty(assigns) do
    ~H"""
    <ul class="lines">
      <li :for={u <- @items}>{u.detail} <.tag tag={u.tag} /></li>
    </ul>
    """
  end

  attr :report, :map, required: true

  def strays(assigns) do
    assigns =
      assign(assigns,
        lines:
          Report.stray_lines(assigns.report) ++
            Enum.map(assigns.report.anomalies, &"anomaly: #{inspect(&1)} [BEAM-derived]")
      )

    ~H"""
    <section :if={@lines != []} class="panel">
      <h2>instance-level evidence not attached to an attempt</h2>
      <ul class="lines">
        <li :for={l <- @lines}>{String.trim_leading(l)}</li>
      </ul>
    </section>
    """
  end

  # -- events ------------------------------------------------------------------------------------

  attr :events, :any, required: true

  def event_table(assigns) do
    ~H"""
    <table class="events">
      <thead>
        <tr>
          <th>seq</th>
          <th>Relay time</th>
          <th>instance</th>
          <th>event</th>
          <th>payload / notice</th>
        </tr>
      </thead>
      <tbody id="events" phx-update="stream">
        <.event_row :for={{dom_id, row} <- @events} id={dom_id} row={row} />
      </tbody>
    </table>
    """
  end

  attr :id, :string, required: true
  attr :row, :map, required: true

  def event_row(assigns) do
    ~H"""
    <tr id={@id} class={@row.kind}>
      <td>{if @row.sequence, do: "##{@row.sequence}", else: "—"}</td>
      <td>{@row.at}</td>
      <td>{short(@row.instance_id)}</td>
      <td>{@row.type} <.tag tag={@row.tag} /></td>
      <td>{@row.detail}</td>
    </tr>
    """
  end

  # -- tags and legend ---------------------------------------------------------------------------

  attr :tag, :atom, required: true

  def tag(assigns) do
    ~H"""
    <span class={"tag #{@tag}"}>{Report.tag_text(@tag)}</span>
    """
  end

  def legend(assigns) do
    ~H"""
    <p class="legend">
      provenance: <.tag tag={:engine} /> an engine-authored occurrence or the native observer's reading of engine scene state ·
      <.tag tag={:derived} /> a BEAM correlation or conservative reading · <.tag tag={:last_observed} /> the engine's last statement, never a current state ·
      <.tag tag={:not_observed} /> an absence, never evidence of the opposite · <.tag tag={:transport} /> connection evidence, never a mission fact
    </p>
    """
  end

  attr :section, :string, required: true
  attr :collapsed, :any, required: true

  def toggle(assigns) do
    ~H"""
    <button class="small" phx-click="toggle" phx-value-section={@section}>
      {if MapSet.member?(@collapsed, @section), do: "show", else: "hide"}
    </button>
    """
  end

  # -- helpers -----------------------------------------------------------------------------------

  def listener_text(%{ip: ip, port: port}) when is_tuple(ip),
    do: "#{Enum.join(Tuple.to_list(ip), ".")}:#{port} (configured)"

  def listener_text(other), do: inspect(other)

  def short(nil), do: "—"
  def short(id), do: Report.short(id)

  defp fmt(nil), do: "?"
  defp fmt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp fmt(other), do: to_string(other)
end
