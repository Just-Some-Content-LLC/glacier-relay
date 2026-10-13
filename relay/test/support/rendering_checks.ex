defmodule GlacierRelay.Test.RenderingChecks do
  @moduledoc """
  The established wording checks (report_test.exs, player_state_test.exs) applied to rendered
  HTML: tags stripped, entities decoded, the labelled limitation lines excluded, every other line
  free of completion, success, survival, inventory, current-state and attribution claims.
  """

  import ExUnit.Assertions

  @forbidden ~r/complet|accomplish|all objectives|remaining|clean\b|undetected|\bsafe\b|silent assassin|inventory contents|holding|carried|owns|recovered|throws|surviv|unique|distinct actor|currently|is wearing|is trespassing|\bassassinat/i

  @excluded [
    "is not observable on this stream",
    "is not established",
    "is a name only",
    "not a continuously verified"
  ]

  def forbidden, do: @forbidden

  @doc "The visible text of an HTML document, one line per element text."
  def text_lines(html) do
    html
    |> String.replace(~r/<script[\s\S]*?<\/script>/, "")
    |> String.replace(~r/<[^>]+>/, "\n")
    |> unescape()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def unescape(text) do
    text
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end

  def assert_conservative(html) do
    # A line that is a JSON object is an envelope payload shown verbatim (the schema's own field
    # names, such as "holding"), not prose; the prose lines around it are checked.
    for line <- text_lines(html),
        not Enum.any?(@excluded, &String.contains?(line, &1)),
        not String.starts_with?(line, "{") do
      refute line =~ @forbidden, "forbidden wording in rendered line: #{line}"
    end

    :ok
  end
end
