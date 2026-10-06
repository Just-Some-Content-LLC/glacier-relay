defmodule GlacierRelay.Wire.FramingTest do
  use ExUnit.Case, async: true

  alias GlacierRelay.Wire.Framing

  test "splits complete lines and keeps the partial tail" do
    f = Framing.new(100)
    assert {:ok, ["a", "b"], f} = Framing.push(f, "a\nb\nc")
    assert {:ok, ["cd"], f} = Framing.push(f, "d\n")
    assert {:ok, [], _} = Framing.push(f, "")
  end

  test "a line split across many chunks is reassembled" do
    f = Framing.new(100)
    {:ok, [], f} = Framing.push(f, "{\"a\":")
    {:ok, [], f} = Framing.push(f, "1")
    assert {:ok, ["{\"a\":1}"], _} = Framing.push(f, "}\n")
  end

  test "tolerates CRLF and drops empty lines" do
    f = Framing.new(100)
    assert {:ok, ["x", "y"], _} = Framing.push(f, "x\r\n\n\r\ny\n")
  end

  test "rejects an unterminated line over the limit without buffering it" do
    f = Framing.new(8)
    assert {:ok, [], f} = Framing.push(f, "12345678")
    assert {:error, :line_too_long} = Framing.push(f, "9")
  end

  test "rejects a terminated line over the limit" do
    f = Framing.new(8)
    assert {:error, :line_too_long} = Framing.push(f, "123456789\n")
  end
end
