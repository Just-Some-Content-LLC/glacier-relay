defmodule GlacierRelay.Events do
  @moduledoc """
  Payload validation per event type and schema version. Unknown event types and unknown schema
  versions are errors, so a newer adapter cannot be misread by an older backend.

  Mission lifecycle (M2 design):

  - `mission.playing` v1: the native MissionPlaying predicate went false -> true.
  - `mission.stopped` v1: the same predicate went true -> false. It carries no claim about why.

  Both have the same payload shape. `mission.stopped` may carry empty scene fields: the native
  side reports what the fall frame showed, and if observability was lost on that frame the fields
  are empty. That is evidence worth keeping, not a malformed envelope.
  """

  alias GlacierRelay.Wire.Envelope

  @mission_playing "mission.playing"
  @mission_stopped "mission.stopped"

  def mission_playing, do: @mission_playing
  def mission_stopped, do: @mission_stopped

  @spec validate(String.t(), pos_integer(), map()) :: {:ok, map()} | {:error, term()}
  def validate(@mission_playing, 1, payload),
    do: mission_scene_payload(payload, &Envelope.non_empty_string?/1)

  def validate(@mission_stopped, 1, payload), do: mission_scene_payload(payload, &is_binary/1)

  def validate(type, version, _payload) when type in [@mission_playing, @mission_stopped],
    do: {:error, {:unsupported_schema_version, type, version}}

  def validate(event_type, _version, _payload), do: {:error, {:unknown_event_type, event_type}}

  defp mission_scene_payload(payload, scene_resource_valid?) do
    with {:ok, scene_resource} <- Envelope.field(payload, "scene_resource", scene_resource_valid?),
         {:ok, scene_type} <- Envelope.field(payload, "scene_type", &is_binary/1),
         {:ok, codename_hint} <- Envelope.field(payload, "codename_hint", &is_binary/1),
         {:ok, game_session_id} <- optional_string(payload, "game_session_id") do
      {:ok,
       %{
         scene_resource: scene_resource,
         scene_type: scene_type,
         codename_hint: codename_hint,
         # Observation only. Nothing is keyed on it (M1 design, section 3).
         game_session_id: game_session_id
       }}
    end
  end

  defp optional_string(payload, key) do
    case Map.fetch(payload, key) do
      :error -> {:ok, nil}
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _} -> {:error, {:invalid_field, key}}
    end
  end
end
