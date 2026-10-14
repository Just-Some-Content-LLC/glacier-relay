defmodule GlacierRelay.Test.FakeNative do
  @moduledoc """
  A fake native peer for the command link (M5-A): a raw loopback TCP client that speaks the
  command protocol the way the eventual native adapter would — it connects, says hello, reads
  the welcome, receives command lines and writes result lines exactly as the test scripts them.
  It is test tooling only and is never evidence of native game execution.
  """

  alias GlacierRelay.Command.Schema

  def connect(port) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [
        :binary,
        packet: :line,
        active: false,
        packet_size: 8_192
      ])

    socket
  end

  def send_json(socket, map), do: :ok = :gen_tcp.send(socket, JSON.encode!(map) <> "\n")
  def send_raw(socket, bytes), do: :ok = :gen_tcp.send(socket, bytes)

  @doc "Reads one line (without the newline) and decodes it as JSON."
  def recv(socket, timeout \\ 1_000) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, line} -> {:ok, line |> String.trim_trailing("\n") |> JSON.decode!()}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "A hello line's map."
  def hello(adapter_id \\ Schema.uuid4(), opts \\ []) do
    %{
      "command_protocol_version" => 1,
      "kind" => "hello",
      "adapter_instance_id" => adapter_id,
      "native_at" => Keyword.get(opts, :native_at, "2026-10-13T20:00:00.000Z"),
      "mission_generation" => Keyword.get(opts, :mission_generation),
      "capabilities" => Keyword.get(opts, :capabilities, ["relay.probe/1"])
    }
  end

  @doc "Connects, says hello and returns `{socket, adapter_id, welcome}`."
  def handshake(port, adapter_id \\ Schema.uuid4(), opts \\ []) do
    socket = connect(port)
    send_json(socket, hello(adapter_id, opts))
    {:ok, welcome} = recv(socket)
    {socket, adapter_id, welcome}
  end

  @doc "A result for a received command map; `fields` override status, reason, observed, frame and the rest."
  def result(command, adapter_id, status, fields \\ %{}) do
    Map.merge(
      %{
        "command_protocol_version" => 1,
        "kind" => "command.result",
        "command_id" => command["command_id"],
        "link_generation" => command["link_generation"],
        "adapter_instance_id" => adapter_id,
        "status" => status,
        "reason" => nil,
        "native_at" => "2026-10-13T20:00:01.000Z",
        "frame" => 1,
        "observed" => nil,
        "mission_generation" => nil
      },
      fields
    )
  end

  @doc "Sends `received` then the terminal `status` for a command, with an optional observation."
  def respond(socket, command, adapter_id, status, fields \\ %{}) do
    send_json(socket, result(command, adapter_id, "received"))
    send_json(socket, result(command, adapter_id, status, fields))
  end

  def close(socket), do: :gen_tcp.close(socket)
end
