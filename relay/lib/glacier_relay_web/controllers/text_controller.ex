defmodule GlacierRelayWeb.TextController do
  @moduledoc """
  The two diagnostic text routes, and the refusing fallback.

  Stage-limited exception (ADR 0007, refinement 2): these routes call the existing read-only
  `MissionSession` presentation API directly (`report_text/0`, `summary_text/0`). They are
  on-demand reads of OTP-owned state, outside the event path, kept in M3-B so that their bytes
  stay comparable with the headless tools (`final_state.exs`); they never deliver evidence,
  never cast, and never reach the wire.
  """

  use Phoenix.Controller, formats: []

  alias GlacierRelay.MissionSession

  # Paths that exist for GET (and HEAD) only.
  @known_paths [[], ["report"], ["report.txt"], ["summary.txt"]]

  def report(conn, _params), do: text_response(conn, MissionSession.report_text())

  def summary(conn, _params), do: text_response(conn, MissionSession.summary_text())

  # Any other method on a known path is 405; anything else is 404. Nothing is read or changed.
  def fallback(conn, _params) do
    if conn.path_info in @known_paths do
      conn
      |> put_resp_header("allow", "GET, HEAD")
      |> text_response("method not allowed", 405)
    else
      text_response(conn, "not found", 404)
    end
  end

  defp text_response(conn, body, status \\ 200) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end
end
