defmodule GlacierRelayWeb.TextController do
  @moduledoc """
  The two M3-A diagnostic text routes.

  Stage-limited exception (ADR 0007, M3-A refinement): these routes call the existing read-only
  `MissionSession` presentation API directly (`report_text/0`, `summary_text/0`) because the
  M3-B projection does not exist yet. They are on-demand reads of OTP-owned state; they never
  deliver evidence, never cast, and never reach the wire. M3-B decides whether they move to
  projection-owned cached data or stay as explicitly justified on-demand diagnostic reads.
  """

  use Phoenix.Controller, formats: []

  alias GlacierRelay.MissionSession

  @known_paths ["report.txt", "summary.txt"]

  def report(conn, _params), do: text_response(conn, MissionSession.report_text())

  def summary(conn, _params), do: text_response(conn, MissionSession.summary_text())

  # Any other method on a known path is 405; anything else is 404. Nothing is read or changed.
  def fallback(conn, _params) do
    case conn.path_info do
      [path] when path in @known_paths ->
        conn
        |> put_resp_header("allow", "GET, HEAD")
        |> text_response("method not allowed", 405)

      _ ->
        text_response(conn, "not found", 404)
    end
  end

  defp text_response(conn, body, status \\ 200) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end
end
