defmodule GlacierRelayWeb.DashboardLiveTest do
  @moduledoc """
  M3-B dashboard over the real endpoint, projection, session and listener: the empty state, a
  replayed mission, transport and mission status kept apart, viewer selection that changes
  presentation only, several adapter cards, event-stream order and its bounded window, and the
  established wording checks over the rendered HTML.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import GlacierRelay.Test.RenderingChecks

  alias GlacierRelay.MissionSession
  alias GlacierRelay.Dashboard.Projection
  alias GlacierRelay.Test.FixturePlayer, as: Player
  alias GlacierRelayWeb.Components

  @endpoint GlacierRelayWeb.Endpoint

  setup do
    start_supervised!(GlacierRelayWeb.Supervisor)
    :ok = MissionSession.subscribe()
    %{conn: build_conn()}
  end

  defp until_rendered(view, text) do
    Player.wait_until(fn -> (html = render(view)) =~ text && html end)
  end

  # The session is shared with every other test: wait for this instance's card to show the
  # expected last sequence, then focus it so the panels are its own.
  defp focus_instance(view, id, last_sequence) do
    pattern = ~r/adapter #{Regex.escape(id)}[\s\S]{0,600}?last sequence #{last_sequence}\b/
    Player.wait_until(fn -> render(view) =~ pattern end)
    view |> element("div.card[phx-value-id='#{id}']") |> render_click()
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  test "the empty state says so and claims nothing" do
    {snapshot, _, _} =
      Projection.build(%{}, [], %{}, %{
        revision: 1,
        source: :live,
        listener: %{ip: {127, 0, 0, 1}, port: 4747}
      })

    html = render_component(&Components.dashboard_body/1, snapshot: snapshot)
    assert html =~ "no adapter instance has delivered an event"
    assert html =~ "wire listener 127.0.0.1:4747 (configured)"
    assert html =~ "source live"
    refute html =~ "attempt"
    assert_conservative(html)
  end

  test "a replayed mission is shown from the report data, newest events first, with its limitations",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    id = Player.unique_id("dash")
    Player.play("b6_run1", id)
    Player.await(id, 16)
    Player.await_closed(id)

    html = focus_instance(view, id, 16)
    assert html =~ "observation lost (the connection closed; no mission.stopped is implied)"
    assert html =~ "adapter #{id}"
    assert html =~ "attempt 1: stopped at #15 (the predicate fell)"
    assert html =~ "Peacock"
    assert html =~ "disposition: exited to menu"
    assert html =~ "target outcomes observed: none in the stream"
    assert html =~ "Michel Trier"
    assert html =~ "trespassing last observed false at #5"
    assert html =~ "ContractEnd is a name only"
    assert html =~ "player state is the engine&#39;s last statement"
    assert html =~ "evt-#{id}-16"
    assert html =~ "player.trespassing v1"
    assert html =~ "connection closed"

    # Newest first in the event pane.
    {i16, _} = :binary.match(html, "evt-#{id}-16")
    {i1, _} = :binary.match(html, "evt-#{id}-1\"")
    assert i16 < i1

    assert_conservative(html)
  end

  test "transport connectivity and the mission predicate are shown separately", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    id = Player.unique_id("split")
    lines = Player.lines("b6_run1")
    {head, tail} = Enum.split(lines, 5)

    socket = Player.play("b6_run1", id, lines: head, keep: true)
    Player.await(id, 5)
    html = focus_instance(view, id, 5)
    assert html =~ "observation live (a connection is open)"
    assert html =~ "last known playing (the predicate rose; no fall observed)"
    assert html =~ "observation live"

    :gen_tcp.close(socket)
    Player.await_closed(id)

    html =
      until_rendered(
        view,
        "observation lost (the connection closed; no mission.stopped is implied)"
      )

    assert html =~ "last known playing (the predicate rose; no fall observed)"
    refute html =~ "stopped at #"
    assert html =~ "the stop was not observed; the attempt is last known playing"

    socket = Player.play("b6_run1", id, lines: tail, keep: true)
    Player.await(id, 16)
    html = until_rendered(view, "stopped at #15 (the predicate fell)")
    assert html =~ "observation live (a connection is open)"
    assert html =~ "observation lost" or html =~ "observation lost 2026"
    :gen_tcp.close(socket)
    assert_conservative(html)
  end

  test "viewer choices change presentation only; session evidence is untouched", %{conn: conn} do
    id1 = Player.unique_id("sel-a")
    id2 = Player.unique_id("sel-b")
    Player.play("b6_run1", id1)
    Player.await(id1, 16)
    Player.await_closed(id1)
    Player.play("b2_probe", id2)
    Player.await_closed(id2)
    _ = Projection.refresh()
    flush()

    before = MissionSession.state()
    {:ok, view, html} = live(conn, "/")
    assert html =~ "adapter #{id1}"
    assert html =~ "adapter #{id2}"

    html = view |> element("div.card[phx-value-id='#{id2}']") |> render_click()
    assert html =~ ~s(class="card focused" phx-click="focus" phx-value-id="#{id2}")

    assert render_click(view, "select_attempt", %{"number" => "1"}) =~ "attempt 1:"
    html = render_click(view, "select_pane", %{"pane" => "items"})
    assert html =~ ~s(class="active" phx-click="select_pane" phx-value-pane="items")
    html = render_click(view, "toggle", %{"section" => "timeline"})
    assert html =~ ~r/>\s*show\s*</
    html = render_click(view, "clear_events", %{})
    refute html =~ "evt-#{id1}-"
    _ = render_click(view, "focus", %{"id" => "no-such-instance"})
    _ = render_click(view, "select_pane", %{"pane" => "no-such-pane"})

    flush()
    refute_receive {:relay_event, _}, 100
    assert MissionSession.state() == before
    assert_conservative(render(view))
  end

  test "the recent-event pane is a bounded window while the report keeps every record", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/")
    id = Player.unique_id("window")
    scene = "assembly:/_PRO/Scenes/Missions/Paris/_Scene_FashionShowHit_01.entity"

    lines =
      for seq <- 1..230 do
        type = if rem(seq, 2) == 1, do: "mission.playing", else: "mission.stopped"

        JSON.encode!(%{
          "protocol_version" => 1,
          "adapter_instance_id" => id,
          "sequence" => seq,
          "timestamp" =>
            "2026-10-12T22:#{String.pad_leading(Integer.to_string(div(seq, 60)), 2, "0")}:#{String.pad_leading(Integer.to_string(rem(seq, 60)), 2, "0")}.000Z",
          "event_type" => type,
          "schema_version" => 1,
          "payload" => %{
            "scene_resource" => scene,
            "scene_type" => "mission",
            "codename_hint" => "Peacock"
          }
        })
      end

    socket = Player.connect()
    Player.send_lines(socket, lines)
    Player.await(id, 230)
    :gen_tcp.close(socket)
    Player.await_closed(id)

    # 230 stream inserts into a page that also carries 115 attempts: allow a longer wait.
    html = Player.wait_until(fn -> (h = render(view)) =~ "last sequence 230" && h end, 500, 20)

    html =
      Player.wait_until(fn -> (h = render(view)) =~ "evt-#{id}-230" && h end, 500, 20) || html

    rows = Regex.scan(~r/id="evt-#{id}-\d+"/, html) |> length()
    assert rows <= 200
    assert html =~ "bounded window"
    assert html =~ "evt-#{id}-230"
    refute html =~ ~s(id="evt-#{id}-1")

    e = Enum.find(Projection.snapshot().instances, &(&1.id == id))
    assert length(e.report.attempts) == 115
    assert e.received == 230
  end
end
