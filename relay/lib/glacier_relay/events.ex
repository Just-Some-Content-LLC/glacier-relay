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

  Contract lifecycle (M2 B2, design section 27), normalized from Glacier's own telemetry:

  - `contract.started` v1: Glacier recorded the start of a contract session.
  - `contract.ended` v1: Glacier recorded the end of one, with the engine's reason string verbatim
    and Relay's reading of it (`reason_kind`: `restart`, `exit_to_menu` or `other`). The engine
    raises the same source event for a manual restart and for an exit to the menu, so neither
    this event nor its name says "failed", "completed" or anything about the player.

  `contract_session_id` is Glacier's identity for Glacier's session. It is not a Relay mission
  attempt identity; `Lifecycle` correlates the two from stream order and says how.

  Disguise (M2 B3, design section 30), normalized from Glacier's own telemetry; ids only:

  - `disguise.equipped` v1: Glacier asserted the player's worn outfit definition id. `kind` is
    Relay's: `initial` restates the outfit the attempt began in (at intro end), `change` says the
    worn outfit changed to this id. `engine_event` is provenance only.
  - `disguise.compromised` v1: Glacier recorded that this outfit definition was blown.
  - `disguise.compromise_cleared` v1: Glacier recorded that it no longer is.

  `disguise_repository_id` names an outfit *definition*, never an instance or a name. None of the
  three says who noticed, whether a compromise persists across a later outfit change, or anything
  about the worn outfit other than what the engine stated at that moment; `Disguise.derive/2`
  says what BEAM reads into them and how uncertain that reading is.
  """

  alias GlacierRelay.Wire.Envelope

  @mission_playing "mission.playing"
  @mission_stopped "mission.stopped"
  @actor_died "actor.died"
  @actor_pacified "actor.pacified"
  @contract_started "contract.started"
  @contract_ended "contract.ended"
  @disguise_equipped "disguise.equipped"
  @disguise_compromised "disguise.compromised"
  @disguise_compromise_cleared "disguise.compromise_cleared"
  @reason_kinds ["restart", "exit_to_menu", "other"]
  @equipped_kinds ["initial", "change"]

  def mission_playing, do: @mission_playing
  def mission_stopped, do: @mission_stopped
  def actor_died, do: @actor_died
  def actor_pacified, do: @actor_pacified
  def contract_started, do: @contract_started
  def contract_ended, do: @contract_ended
  def disguise_equipped, do: @disguise_equipped
  def disguise_compromised, do: @disguise_compromised
  def disguise_compromise_cleared, do: @disguise_compromise_cleared

  @doc "Event types that are actor outcomes."
  def actor_outcome?(type), do: type in [@actor_died, @actor_pacified]

  @doc "Event types that are contract lifecycle."
  def contract_event?(type), do: type in [@contract_started, @contract_ended]

  @doc "Event types that are disguise occurrences."
  def disguise_event?(type),
    do: type in [@disguise_equipped, @disguise_compromised, @disguise_compromise_cleared]

  @spec validate(String.t(), pos_integer(), map()) :: {:ok, map()} | {:error, term()}
  def validate(@mission_playing, 1, payload),
    do: mission_scene_payload(payload, &Envelope.non_empty_string?/1)

  def validate(@mission_stopped, 1, payload), do: mission_scene_payload(payload, &is_binary/1)

  def validate(type, 1, payload) when type in [@actor_died, @actor_pacified],
    do: actor_outcome_payload(payload)

  def validate(@contract_started, 1, payload), do: contract_started_payload(payload)
  def validate(@contract_ended, 1, payload), do: contract_ended_payload(payload)
  def validate(@disguise_equipped, 1, payload), do: disguise_payload(payload, :with_kind)

  def validate(type, 1, payload) when type in [@disguise_compromised, @disguise_compromise_cleared],
    do: disguise_payload(payload, :without_kind)

  def validate(type, version, _payload)
      when type in [
             @mission_playing,
             @mission_stopped,
             @actor_died,
             @actor_pacified,
             @contract_started,
             @contract_ended,
             @disguise_equipped,
             @disguise_compromised,
             @disguise_compromise_cleared
           ],
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

  defp contract_started_payload(payload) do
    with {:ok, source} <- Envelope.field(payload, "source", &Envelope.non_empty_string?/1),
         {:ok, engine_event} <- Envelope.field(payload, "engine_event", &Envelope.non_empty_string?/1),
         {:ok, contract_session_id} <-
           Envelope.field(payload, "contract_session_id", &Envelope.non_empty_string?/1),
         {:ok, contract_id} <- Envelope.field(payload, "contract_id", &is_binary/1),
         {:ok, location_id} <- Envelope.field(payload, "location_id", &is_binary/1),
         {:ok, contract_type} <- Envelope.field(payload, "contract_type", &is_binary/1),
         {:ok, difficulty_level} <- Envelope.field(payload, "difficulty_level", &is_integer/1),
         {:ok, starting_disguise_repository_id} <-
           Envelope.field(payload, "starting_disguise_repository_id", &is_binary/1),
         {:ok, is_hitman_suit} <- Envelope.field(payload, "is_hitman_suit", &is_boolean/1),
         {:ok, engine_timestamp_s} <- optional(payload, "engine_timestamp_s", &is_number/1) do
      {:ok,
       %{
         source: source,
         engine_event: engine_event,
         contract_session_id: contract_session_id,
         contract_id: contract_id,
         location_id: location_id,
         contract_type: contract_type,
         difficulty_level: difficulty_level,
         starting_disguise_repository_id: starting_disguise_repository_id,
         is_hitman_suit: is_hitman_suit,
         engine_timestamp_s: engine_timestamp_s
       }}
    end
  end

  defp contract_ended_payload(payload) do
    with {:ok, source} <- Envelope.field(payload, "source", &Envelope.non_empty_string?/1),
         {:ok, engine_event} <- Envelope.field(payload, "engine_event", &Envelope.non_empty_string?/1),
         {:ok, contract_session_id} <-
           Envelope.field(payload, "contract_session_id", &Envelope.non_empty_string?/1),
         {:ok, contract_id} <- Envelope.field(payload, "contract_id", &is_binary/1),
         {:ok, reason} <- Envelope.field(payload, "reason", &Envelope.non_empty_string?/1),
         {:ok, reason_kind} <- Envelope.field(payload, "reason_kind", &(&1 in @reason_kinds)),
         {:ok, engine_timestamp_s} <- optional(payload, "engine_timestamp_s", &is_number/1) do
      {:ok,
       %{
         source: source,
         engine_event: engine_event,
         contract_session_id: contract_session_id,
         contract_id: contract_id,
         reason: reason,
         reason_kind: reason_kind,
         engine_timestamp_s: engine_timestamp_s
       }}
    end
  end

  # The same shape for the three disguise types. `kind` is required on disguise.equipped and must
  # be absent on the other two: the event type is the fact, the kind qualifies only an assertion
  # of the worn outfit.
  defp disguise_payload(payload, kind_rule) do
    with {:ok, source} <- Envelope.field(payload, "source", &Envelope.non_empty_string?/1),
         {:ok, kind} <- disguise_kind(payload, kind_rule),
         {:ok, engine_event} <- Envelope.field(payload, "engine_event", &Envelope.non_empty_string?/1),
         {:ok, disguise_repository_id} <-
           Envelope.field(payload, "disguise_repository_id", &Envelope.non_empty_string?/1),
         {:ok, contract_session_id} <- optional_string(payload, "contract_session_id"),
         {:ok, engine_timestamp_s} <- optional(payload, "engine_timestamp_s", &is_number/1) do
      {:ok,
       %{
         source: source,
         kind: kind,
         engine_event: engine_event,
         disguise_repository_id: disguise_repository_id,
         contract_session_id: contract_session_id,
         engine_timestamp_s: engine_timestamp_s
       }}
    end
  end

  defp disguise_kind(payload, :with_kind), do: Envelope.field(payload, "kind", &(&1 in @equipped_kinds))

  defp disguise_kind(payload, :without_kind) do
    if Map.has_key?(payload, "kind"), do: {:error, {:unexpected_field, "kind"}}, else: {:ok, nil}
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
