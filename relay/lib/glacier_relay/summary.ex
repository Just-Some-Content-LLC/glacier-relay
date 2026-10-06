defmodule GlacierRelay.Summary do
  @moduledoc """
  An event-derived summary of what BEAM knows (M2 Stage A). Pure: built from `Lifecycle.Instance`
  values, which are themselves folded from evidence. Nothing here inspects the game; nothing here
  infers a gameplay outcome. Each line says what was observed, and "not observed" where it wasn't.
  """

  alias GlacierRelay.Lifecycle
  alias GlacierRelay.Lifecycle.{Attempt, Connection, Instance}

  @doc "Summary data, one map per instance, oldest attempt first."
  @spec build(%{String.t() => Instance.t()}) :: [map()]
  def build(instances) when is_map(instances) do
    instances
    |> Map.values()
    |> Enum.sort_by(&first_seen/1)
    |> Enum.map(&instance/1)
  end

  @doc "The same summary as text, for a log or an IEx session."
  @spec render(%{String.t() => Instance.t()}, [map()]) :: String.t()
  def render(instances, unidentified \\ []) do
    lines =
      case build(instances) do
        [] -> ["no adapter instance has delivered an event"]
        summaries -> Enum.flat_map(summaries, &render_instance/1)
      end

    extra =
      case unidentified do
        [] ->
          []

        list ->
          ["", "connections that closed before identifying an instance: #{length(list)}"] ++
            Enum.map(list, fn c ->
              "  #{c.peer} opened #{fmt(c.opened_at)} closed #{fmt(c.closed_at)} (#{inspect(c.close_reason)})"
            end)
      end

    Enum.join(lines ++ extra, "\n")
  end

  defp instance(%Instance{} = instance) do
    %{
      adapter_instance_id: instance.id,
      received: instance.received,
      last_sequence: instance.last_sequence,
      gaps: Enum.reverse(instance.gaps),
      observation: Lifecycle.observation(instance),
      connections: instance.connections |> Enum.reverse() |> Enum.map(&connection/1),
      attempts: Enum.map(instance.attempts, &attempt/1),
      unmatched_stops:
        Enum.map(instance.unmatched_stops, fn stray ->
          %{
            sequence: stray.observation.sequence,
            timestamp: stray.observation.timestamp,
            scene_resource: stray.payload.scene_resource
          }
        end)
    }
  end

  defp attempt(%Attempt{} = attempt) do
    %{
      number: attempt.number,
      scene_resource: attempt.scene_resource,
      scene_type: attempt.scene_type,
      codename_hint: attempt.codename_hint,
      mission: attempt.mission,
      open?: attempt.mission == :playing,
      playing_at: attempt.playing.timestamp,
      playing_sequence: attempt.playing.sequence,
      stopped_at: attempt.stopped && attempt.stopped.timestamp,
      stopped_sequence: attempt.stopped && attempt.stopped.sequence,
      duration_ms: Lifecycle.duration_ms(attempt),
      superseded_by: attempt.superseded_by,
      interrupted?: attempt.interruptions != [],
      interruptions: attempt.interruptions,
      game_session_id: %{
        playing: attempt.playing.game_session_id,
        stopped: attempt.stopped && attempt.stopped.game_session_id
      },
      stopped_scene: attempt.stopped_scene
    }
  end

  defp connection(%Connection{} = c) do
    %{
      peer: c.peer,
      opened_at: c.opened_at,
      identified_at: c.identified_at,
      closed_at: c.closed_at,
      close_reason: c.close_reason
    }
  end

  defp render_instance(s) do
    header =
      "adapter #{s.adapter_instance_id}: #{s.received} event(s), last sequence #{s.last_sequence}, " <>
        "gaps #{inspect(s.gaps)}, observation #{s.observation}"

    connections =
      Enum.map(s.connections, fn c ->
        closed =
          case c.closed_at do
            nil -> "still open"
            at -> "closed #{fmt(at)} (#{inspect(c.close_reason)})"
          end

        "  connection #{c.peer}: opened #{fmt(c.opened_at)}, identified #{fmt(c.identified_at)}, #{closed}"
      end)

    attempts =
      case s.attempts do
        [] -> ["  no mission attempt observed"]
        list -> Enum.map(list, &render_attempt/1)
      end

    strays =
      Enum.map(s.unmatched_stops, fn stray ->
        "  mission.stopped ##{stray.sequence} at #{stray.timestamp} with no open attempt (#{stray.scene_resource})"
      end)

    [header] ++ connections ++ attempts ++ strays
  end

  defp render_attempt(a) do
    name =
      if a.codename_hint in [nil, ""],
        do: a.scene_resource,
        else: "#{a.codename_hint} (#{a.scene_resource})"

    ending =
      case a.mission do
        :stopped ->
          "stopped #{a.stopped_at} (##{a.stopped_sequence}), duration #{fmt_duration(a.duration_ms)}"

        :playing ->
          "stop not observed; last known playing"

        :superseded ->
          "stop not observed; superseded by attempt #{a.superseded_by}"
      end

    interrupted =
      case a.interruptions do
        [] ->
          ""

        list ->
          "; observation lost " <>
            Enum.map_join(list, ", ", fn i -> "#{fmt(i.at)} (#{inspect(i.reason)})" end)
      end

    "  attempt #{a.number}: #{name}: playing #{a.playing_at} (##{a.playing_sequence}), #{ending}#{interrupted}"
  end

  defp first_seen(%Instance{attempts: [first | _]}), do: first.playing.timestamp
  defp first_seen(%Instance{last_event: %{timestamp: ts}}), do: ts
  defp first_seen(%Instance{}), do: ""

  defp fmt(nil), do: "?"
  defp fmt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp fmt(other), do: to_string(other)

  defp fmt_duration(nil), do: "unknown"
  defp fmt_duration(ms) when ms < 1_000, do: "#{ms} ms"
  defp fmt_duration(ms), do: "#{Float.round(ms / 1_000, 1)} s"
end
