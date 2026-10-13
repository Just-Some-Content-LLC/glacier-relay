defmodule GlacierRelayWeb.ReportLiveTest do
  @moduledoc """
  M3-B report page: the structured panels and the verbatim text, equal to the session's own
  report text at the same state, with every standing limitation and the established wording
  checks; collapsing changes presentation only.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import GlacierRelay.Test.RenderingChecks

  alias GlacierRelay.MissionSession
  alias GlacierRelay.Dashboard.Projection
  alias GlacierRelay.Test.FixturePlayer, as: Player

  @endpoint GlacierRelayWeb.Endpoint

  setup do
    start_supervised!(GlacierRelayWeb.Supervisor)
    :ok = MissionSession.subscribe()
    %{conn: build_conn()}
  end

  defp pre_text(html) do
    [_, inner] = Regex.run(~r/<pre class="report" id="report-text">([\s\S]*?)<\/pre>/, html)
    unescape(inner)
  end

  test "the page carries the B7 report data and the verbatim text of the same state", %{
    conn: conn
  } do
    id = Player.unique_id("rep")
    Player.play("b5_run1", id)
    Player.await(id, 45)
    Player.await_closed(id)
    snapshot = Projection.refresh()

    {:ok, view, html} = live(conn, "/report")
    assert html =~ "adapter #{id}"
    assert html =~ "mission overview"
    assert html =~ "actor outcomes"
    assert html =~ "Viktor Novikov"
    assert html =~ "Dalia Margolis"
    assert html =~ "accident/accident_explosion"
    assert html =~ "uncertainty and limitations"

    assert html =~
             "whether the mission ended in success or failure is not observable on this stream"

    assert html =~ "ContractEnd is a name only"
    assert html =~ "an absent outcome is not evidence of survival"
    assert html =~ "not a continuously verified current state"
    assert html =~ "occurrence counts, not an actor count"
    assert html =~ "first observed"

    assert pre_text(html) == snapshot.report_text
    assert snapshot.report_text == MissionSession.report_text()
    assert_conservative(html)

    before = MissionSession.state()
    html = render_click(view, "toggle", %{"section" => "text"})
    refute html =~ ~s(id="report-text")
    html = render_click(view, "toggle", %{"section" => "text"})
    assert html =~ ~s(id="report-text")
    html = render_click(view, "toggle", %{"section" => id})
    refute html =~ ~s(id="instance-#{id}")
    assert MissionSession.state() == before
  end

  test "a later snapshot updates the page", %{conn: conn} do
    {:ok, view, _} = live(conn, "/report")
    id = Player.unique_id("rep2")
    Player.play("stage1", id)
    Player.await(id, 3)
    Player.await_closed(id)
    html = Player.wait_until(fn -> (h = render(view)) =~ "adapter #{id}" && h end)
    assert html =~ "attempt 3"
    assert_conservative(html)
  end
end
