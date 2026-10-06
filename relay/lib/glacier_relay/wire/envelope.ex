defmodule GlacierRelay.Wire.Envelope do
  @moduledoc """
  Envelope version 1 as the native adapter serializes it (glacier-relay M1 design, section 4):

      {"protocol_version":1,"adapter_instance_id":"<uuid>","sequence":N,"timestamp":"<ISO 8601>",
       "event_type":"mission.playing","schema_version":1,"payload":{...}}

  Decoding is strict about what M1 needs and nothing more. Anything that does not validate is an
  error for the sender's line only; the connection decides what to do with it.
  """

  @protocol_version 1

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          adapter_instance_id: String.t(),
          sequence: pos_integer(),
          timestamp: String.t(),
          event_type: String.t(),
          schema_version: pos_integer(),
          payload: map()
        }
  defstruct [
    :protocol_version,
    :adapter_instance_id,
    :sequence,
    :timestamp,
    :event_type,
    :schema_version,
    :payload
  ]

  def protocol_version, do: @protocol_version

  @doc "Decodes one NDJSON line into a validated envelope with a validated payload."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(line) when is_binary(line) do
    with {:ok, map} <- decode_json(line),
         {:ok, envelope} <- from_map(map),
         {:ok, payload} <-
           GlacierRelay.Events.validate(
             envelope.event_type,
             envelope.schema_version,
             envelope.payload
           ) do
      {:ok, %{envelope | payload: payload}}
    end
  end

  defp decode_json(line) do
    case JSON.decode(line) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, :not_an_object}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp from_map(map) do
    with {:ok, version} <- field(map, "protocol_version", &pos_integer?/1),
         :ok <- check_version(version),
         {:ok, instance_id} <- field(map, "adapter_instance_id", &non_empty_string?/1),
         {:ok, sequence} <- field(map, "sequence", &pos_integer?/1),
         {:ok, timestamp} <- field(map, "timestamp", &non_empty_string?/1),
         {:ok, event_type} <- field(map, "event_type", &non_empty_string?/1),
         {:ok, schema_version} <- field(map, "schema_version", &pos_integer?/1),
         {:ok, payload} <- field(map, "payload", &is_map/1) do
      {:ok,
       %__MODULE__{
         protocol_version: version,
         adapter_instance_id: instance_id,
         sequence: sequence,
         timestamp: timestamp,
         event_type: event_type,
         schema_version: schema_version,
         payload: payload
       }}
    end
  end

  defp check_version(@protocol_version), do: :ok
  defp check_version(other), do: {:error, {:unsupported_protocol_version, other}}

  @doc false
  def field(map, key, valid?) do
    case Map.fetch(map, key) do
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  @doc false
  def pos_integer?(value), do: is_integer(value) and value > 0

  @doc false
  def non_empty_string?(value), do: is_binary(value) and value != ""
end
