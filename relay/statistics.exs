# Read-only statistics over recordings (M4-C), in the style of replay.exs: no application start,
# no listener, no dashboard, nothing of the game.
#
#     elixir -S mix run --no-start statistics.exs [--json <file>] [--group-by k1,k2] <input>...
#
# Each input is a recording directory (replayed by GlacierRelay.Recording.Replay) or an
# envelope-only .ndjson file (a legacy fixture, imported under its documented limits). Prints the
# statistics text of every input and, with more than one input, the comparison grouped by the
# given keys (default scene_resource). With --json, writes the structured result(s) as
# deterministic JSON (one recording: its statistics; several: {"recordings": [...],
# "comparison": {...}}). The inputs are never written.
alias GlacierRelay.Recording.Replay
alias GlacierRelay.Statistics
alias GlacierRelay.Statistics.{Comparison, Text}

{opts, inputs, invalid} =
  OptionParser.parse(System.argv(), strict: [json: :string, group_by: :string])

if invalid != [] or inputs == [] do
  IO.puts(
    "usage: statistics.exs [--json <file>] [--group-by k1,k2] <recording-dir | fixture.ndjson>..."
  )

  System.halt(2)
end

group_by =
  case opts[:group_by] do
    nil -> [:scene_resource]
    text -> text |> String.split(",", trim: true) |> Enum.map(&String.to_existing_atom/1)
  end

replays =
  Enum.map(inputs, fn input ->
    path = Path.expand(input)

    cond do
      File.dir?(path) ->
        case Replay.replay(path) do
          {:ok, r} ->
            r

          {:error, reason} ->
            IO.puts("cannot read #{input}: #{inspect(reason)}")
            System.halt(2)
        end

      File.regular?(path) ->
        lines = path |> File.read!() |> String.split("\n", trim: true)
        Replay.from_envelopes(lines, name: Path.basename(path, ".ndjson"))

      true ->
        IO.puts("no such input: #{input}")
        System.halt(2)
    end
  end)

stats = Enum.map(replays, &Statistics.of_replay/1)

for s <- stats do
  IO.puts(Text.render(s))
  IO.puts("")
end

comparison = if length(stats) > 1, do: Comparison.compare(stats, group_by: group_by)
if comparison, do: IO.puts(Text.render_comparison(comparison))

if opts[:json] do
  payload =
    case stats do
      [one] -> one
      many -> %{recordings: many, comparison: comparison}
    end

  File.write!(Path.expand(opts[:json]), Statistics.JSON.encode(payload) <> "\n")
  IO.puts("json written to #{opts[:json]}")
end
