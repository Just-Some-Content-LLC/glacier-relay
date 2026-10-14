defmodule GlacierRelay.Test.FakeNative do
  @moduledoc """
  A fake native peer for the command link (M5-A; M5 C-2A version 2): a raw loopback TCP client
  that speaks the command protocol the way the eventual native adapter would — it connects, says
  hello (version 1 or 2), reads the welcome, attests with an ephemeral test token when asked,
  receives command lines and writes result lines exactly as the test scripts them. It is test
  tooling only and is never evidence of native game execution; every assertion it makes is
  fake-native evidence.
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

  @doc "A hello line's map (`:version` 1 by default)."
  def hello(adapter_id \\ Schema.uuid4(), opts \\ []) do
    %{
      "command_protocol_version" => Keyword.get(opts, :version, 1),
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

  @doc "An attest line for a version-2 welcome, computed with `token` (the shared MAC definition)."
  def attest(welcome, adapter_id, token, overrides \\ %{}) do
    Map.merge(
      %{
        "command_protocol_version" => 2,
        "kind" => "attest",
        "link_generation" => welcome["link_generation"],
        "adapter_instance_id" => adapter_id,
        "mac" =>
          Schema.attest_mac(token, welcome["nonce"], welcome["link_generation"], adapter_id)
      },
      overrides
    )
  end

  @doc """
  A version-2 handshake: connect, hello (version 2, the given capabilities), read the welcome,
  attest with `token`. Returns `{socket, adapter_id, welcome}`; the caller checks the authority's
  trust state (the attest has no reply line of its own).
  """
  def handshake_v2(port, token, opts \\ []) do
    adapter_id = Keyword.get(opts, :adapter_id, Schema.uuid4())

    caps =
      Keyword.get(opts, :capabilities, [
        "relay.probe/1",
        "relay.inspect.outfit/1",
        "player.outfit.set/2"
      ])

    {socket, ^adapter_id, welcome} =
      handshake(
        port,
        adapter_id,
        Keyword.merge([version: 2, capabilities: caps], Keyword.take(opts, [:mission_generation]))
      )

    if token, do: send_json(socket, attest(welcome, adapter_id, token))
    {socket, adapter_id, welcome}
  end

  @doc "A result for a received command map; `fields` override status, reason, observed, frame and the rest."
  def result(command, adapter_id, status, fields \\ %{}) do
    Map.merge(
      %{
        "command_protocol_version" => command["command_protocol_version"] || 1,
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

  @doc "A read-back field object as the native encoder writes it."
  def field(status, value \\ nil, reason \\ nil) do
    %{"status" => status}
    |> then(&if(value != nil, do: Map.put(&1, "value", value), else: &1))
    |> then(&if(reason, do: Map.put(&1, "reason", reason), else: &1))
  end

  @doc """
  A fake apply read-back for `player.outfit.set` v2: the previous and current tuples, the
  setter-called flag and the effect classification, with the generations. Fake-native evidence.
  """
  def apply_observed(previous, current, effect, opts \\ []) do
    generation = Keyword.get(opts, :generation, "gen")
    requested = Keyword.get(opts, :requested, current)

    %{
      "mission_playing" => field("observed", true),
      "frame" => field("observed", Keyword.get(opts, :frame, 20_000)),
      "generation_expected" => field("observed", generation),
      "generation_at_receipt" => field("observed", generation),
      "generation_cached" => field("observed", generation),
      "generation_fresh" => field("observed", generation),
      "generation_post" => field("observed", Keyword.get(opts, :generation_post, generation)),
      "relay_transition_epoch" => field("observed", 1),
      "epoch_post" => field("observed", 1),
      "previous_outfit_id" => field("observed", previous["disguise_repository_id"]),
      "previous_charset" => field("observed", previous["charset"]),
      "previous_variation" => field("observed", previous["variation"]),
      "requested_outfit_id" => tuple_field(requested, "disguise_repository_id"),
      "requested_charset" => tuple_field(requested, "charset"),
      "requested_variation" => tuple_field(requested, "variation"),
      "current_outfit_id" => tuple_field(current, "disguise_repository_id"),
      "current_charset" => tuple_field(current, "charset"),
      "current_variation" => tuple_field(current, "variation"),
      "set_outfit_available" => field("observed", true),
      "link_generation_at_call" => field("observed", Keyword.get(opts, :link_generation, 1)),
      "setter_called" => field("observed", Keyword.get(opts, :setter_called, true)),
      "effect" => field("observed", effect),
      "precondition_ok" => field("observed", true),
      "precondition_reasons" => field("observed")
    }
  end

  defp tuple_field(nil, _key), do: field("unavailable", nil, "read-back after fault")
  defp tuple_field(tuple, key), do: field("observed", tuple[key])

  def close(socket), do: :gen_tcp.close(socket)
end
