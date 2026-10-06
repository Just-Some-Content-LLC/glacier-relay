defmodule GlacierRelay.Events do
  @moduledoc """
  Payload validation per event type and schema version. The only M1 event is `mission.playing`.
  Unknown event types and unknown schema versions are errors, so a newer adapter cannot be
  misread by an older backend.
  """

  alias GlacierRelay.Wire.Envelope

  @mission_playing "mission.playing"

  def mission_playing, do: @mission_playing

  @spec validate(String.t(), pos_integer(), map()) :: {:ok, map()} | {:error, term()}
  def validate(@mission_playing, 1, payload) do
    with {:ok, scene_resource} <-
           Envelope.field(payload, "scene_resource", &Envelope.non_empty_string?/1),
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

  def validate(@mission_playing, version, _payload),
    do: {:error, {:unsupported_schema_version, @mission_playing, version}}

  def validate(event_type, _version, _payload), do: {:error, {:unknown_event_type, event_type}}

  defp optional_string(payload, key) do
    case Map.fetch(payload, key) do
      :error -> {:ok, nil}
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _} -> {:error, {:invalid_field, key}}
    end
  end
end
