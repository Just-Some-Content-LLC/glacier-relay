defmodule GlacierRelayWeb.ErrorText do
  @moduledoc """
  Renders an exception raised inside a request as a plain status line, as text. Routing never
  reaches this (the router's fallback answers 404/405 itself); it exists so that an unexpected
  error is a short text response rather than a missing error view.
  """

  def render(template, _assigns) do
    case Integer.parse(template) do
      {status, _} -> Plug.Conn.Status.reason_phrase(status)
      :error -> "error"
    end
  end
end
