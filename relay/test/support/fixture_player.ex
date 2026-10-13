defmodule GlacierRelay.Test.FixturePlayer do
  @moduledoc """
  Deterministic playback of committed envelope fixtures through the real wire listener, as any
  adapter would deliver them: a raw TCP socket, NDJSON lines, optional pacing from the envelopes'
  own publication timestamps, and the adapter instance id rewritten so that each test owns its
  instance in the shared `MissionSession`.
  """

  alias GlacierRelay.Wire.Listener

  def lines(name) do
    File.read!("test/#{name}_envelopes.ndjson") |> String.split("\n", trim: true)
  end

  @doc "The fixture's lines with their adapter instance id replaced."
  def with_instance(lines, id) do
    Enum.map(lines, fn line ->
      line |> JSON.decode!() |> Map.put("adapter_instance_id", id) |> JSON.encode!()
    end)
  end

  def unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  def connect do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, Listener.port(), [:binary, active: false])
    socket
  end

  def send_lines(socket, lines), do: :ok = :gen_tcp.send(socket, Enum.join(lines, "\n") <> "\n")

  @doc """
  Sends the lines one by one, sleeping between consecutive envelopes for their publication-time
  difference divided by `speed` (1.0 = the observed rate; larger = faster).
  """
  def send_paced(socket, lines, speed) do
    Enum.reduce(lines, nil, fn line, previous ->
      at = line |> JSON.decode!() |> Map.fetch!("timestamp") |> parse()

      if previous && at do
        delay_ms = DateTime.diff(at, previous, :millisecond) / speed
        if delay_ms > 0, do: Process.sleep(round(delay_ms))
      end

      :ok = :gen_tcp.send(socket, line <> "\n")
      at || previous
    end)

    :ok
  end

  defp parse(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  @doc """
  Plays a fixture under `id`. Options: `:keep` (leave the socket open and return it; default
  false, close it and return `:closed`), `:lines` (a subset), `:speed` (paced playback).
  """
  def play(name, id, opts \\ []) do
    lines = with_instance(Keyword.get(opts, :lines, lines(name)), id)
    socket = connect()

    case Keyword.get(opts, :speed) do
      nil -> send_lines(socket, lines)
      speed -> send_paced(socket, lines, speed)
    end

    if Keyword.get(opts, :keep, false) do
      socket
    else
      :gen_tcp.close(socket)
      :closed
    end
  end

  @doc "Waits for the subscribed caller to see the session notify sequence `seq` for `id`."
  def await(id, seq, timeout \\ 5_000) do
    receive do
      {:relay_event, %{adapter_instance_id: ^id, sequence: ^seq}} -> :ok
    after
      timeout -> raise "sequence #{seq} for #{id} not notified within #{timeout} ms"
    end
  end

  @doc "Waits for the subscribed caller to see the session notify the close for `id`."
  def await_closed(id, timeout \\ 5_000) do
    receive do
      {:relay_connection, :closed, %{instance_id: ^id}} -> :ok
    after
      timeout -> raise "close for #{id} not notified within #{timeout} ms"
    end
  end

  @doc "Polls `fun` until it returns a truthy value or the attempts run out."
  def wait_until(fun, attempts \\ 150, sleep_ms \\ 20) do
    cond do
      value = fun.() -> value
      attempts == 0 -> raise "condition not met"
      true -> Process.sleep(sleep_ms) && wait_until(fun, attempts - 1, sleep_ms)
    end
  end
end
