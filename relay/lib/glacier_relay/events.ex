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

  Actor outcomes (M2 B1, ADR 0006), normalized by the native adapter from Glacier's own telemetry:

  - `actor.died` v1: Glacier recorded a lethal outcome for an actor.
  - `actor.pacified` v1: Glacier recorded a non-lethal takedown.

  Same shape for both. Every field is the engine's observation or classification, carried as
  Relay-owned names; nothing here says who caused it. `engine_actor_id` and `repository_id` are
  observations, not identities (B0: the former is not stable across event kinds, the latter is
  shared by generic NPCs). BEAM never sees Glacier field names.
  """

  alias GlacierRelay.Wire.Envelope

  @mission_playing "mission.playing"
  @mission_stopped "mission.stopped"
  @actor_died "actor.died"
  @actor_pacified "actor.pacified"

  def mission_playing, do: @mission_playing
  def mission_stopped, do: @mission_stopped
  def actor_died, do: @actor_died
  def actor_pacified, do: @actor_pacified

  @doc "Event types that are actor outcomes."
  def actor_outcome?(type), do: type in [@actor_died, @actor_pacified]

  @spec validate(String.t(), pos_integer(), map()) :: {:ok, map()} | {:error, term()}
  def validate(@mission_playing, 1, payload),
    do: mission_scene_payload(payload, &Envelope.non_empty_string?/1)

  def validate(@mission_stopped, 1, payload), do: mission_scene_payload(payload, &is_binary/1)

  def validate(type, 1, payload) when type in [@actor_died, @actor_pacified],
    do: actor_outcome_payload(payload)

  def validate(type, version, _payload)
      when type in [@mission_playing, @mission_stopped, @actor_died, @actor_pacified],
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

  defp actor_outcome_payload(payload) do
    with {:ok, source} <- Envelope.field(payload, "source", &Envelope.non_empty_string?/1),
         {:ok, repository_id} <-
           Envelope.field(payload, "repository_id", &Envelope.non_empty_string?/1),
         {:ok, actor_name} <- Envelope.field(payload, "actor_name", &is_binary/1),
         {:ok, engine_actor_id} <- Envelope.field(payload, "engine_actor_id", &non_neg_integer?/1),
         {:ok, actor_type} <- Envelope.field(payload, "actor_type", &Envelope.non_empty_string?/1),
         {:ok, is_target} <- Envelope.field(payload, "is_target", &is_boolean/1),
         {:ok, death_type} <- Envelope.field(payload, "death_type", &Envelope.non_empty_string?/1),
         {:ok, death_context} <-
           Envelope.field(payload, "death_context", &Envelope.non_empty_string?/1),
         {:ok, accident} <- Envelope.field(payload, "accident", &is_boolean/1),
         {:ok, kill_class} <- Envelope.field(payload, "kill_class", &is_binary/1),
         {:ok, method_broad} <- Envelope.field(payload, "method_broad", &is_binary/1),
         {:ok, method_strict} <- Envelope.field(payload, "method_strict", &is_binary/1),
         {:ok, damage_events} <- Envelope.field(payload, "damage_events", &string_list?/1),
         {:ok, actor_type_code} <- optional(payload, "actor_type_code", &is_integer/1),
         {:ok, death_type_code} <- optional(payload, "death_type_code", &is_integer/1),
         {:ok, death_context_code} <- optional(payload, "death_context_code", &is_integer/1),
         {:ok, item_repository_id} <- optional_string(payload, "item_repository_id"),
         {:ok, contract_session_id} <- optional_string(payload, "contract_session_id"),
         {:ok, engine_timestamp_s} <- optional(payload, "engine_timestamp_s", &is_number/1) do
      {:ok,
       %{
         source: source,
         repository_id: repository_id,
         actor_name: actor_name,
         engine_actor_id: engine_actor_id,
         actor_type: actor_type,
         actor_type_code: actor_type_code,
         is_target: is_target,
         death_type: death_type,
         death_type_code: death_type_code,
         death_context: death_context,
         death_context_code: death_context_code,
         accident: accident,
         kill_class: kill_class,
         method_broad: method_broad,
         method_strict: method_strict,
         damage_events: damage_events,
         item_repository_id: item_repository_id,
         contract_session_id: contract_session_id,
         engine_timestamp_s: engine_timestamp_s
       }}
    end
  end

  defp non_neg_integer?(value), do: is_integer(value) and value >= 0
  defp string_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)

  defp optional(payload, key, valid?) do
    case Map.fetch(payload, key) do
      :error -> {:ok, nil}
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}
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
