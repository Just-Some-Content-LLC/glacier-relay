defmodule GlacierRelay.Wire.Framing do
  @moduledoc """
  NDJSON framing: splits a byte stream into lines without ever buffering more than
  `max_line_bytes` of an unterminated line. Pure; the connection process owns the state.

  A trailing `\\r` before the newline is tolerated and removed. Empty lines are dropped.
  """

  @type t :: %__MODULE__{buffer: binary(), max_line_bytes: pos_integer()}
  defstruct buffer: <<>>, max_line_bytes: 65_536

  @spec new(pos_integer()) :: t()
  def new(max_line_bytes) when is_integer(max_line_bytes) and max_line_bytes > 0 do
    %__MODULE__{max_line_bytes: max_line_bytes}
  end

  @doc """
  Appends bytes and returns the complete lines they finish, in order.

  Returns `{:error, :line_too_long}` as soon as an unterminated line exceeds the limit; the
  connection cannot resynchronise after that and should close.
  """
  @spec push(t(), binary()) :: {:ok, [binary()], t()} | {:error, :line_too_long}
  def push(%__MODULE__{} = state, bytes) when is_binary(bytes) do
    split(state.buffer <> bytes, state.max_line_bytes, [])
    |> case do
      {:ok, lines, rest} -> {:ok, Enum.reverse(lines), %{state | buffer: rest}}
      {:error, _} = error -> error
    end
  end

  defp split(data, max, acc) do
    case :binary.split(data, "\n") do
      [line, rest] when byte_size(line) <= max ->
        split(rest, max, prepend_line(line, acc))

      [_line, _rest] ->
        {:error, :line_too_long}

      [partial] when byte_size(partial) <= max ->
        {:ok, acc, partial}

      [_partial] ->
        {:error, :line_too_long}
    end
  end

  defp prepend_line(line, acc) do
    case String.trim_trailing(line, "\r") do
      "" -> acc
      trimmed -> [trimmed | acc]
    end
  end
end
