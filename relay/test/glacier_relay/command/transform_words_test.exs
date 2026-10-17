defmodule GlacierRelay.Command.TransformWordsTest do
  @moduledoc """
  M6-F: the float-word codec — bit-preserving round trips (native encoding → JSON text → BEAM
  words → text), signed zero, malformed words and counts, non-finite values, the seven-digit twin
  pair, the human renderings that must equal the native `%.7g`, the declared tolerance and the
  replicated lift target. Pure; no peer, no engine.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.Command.{Schema, TransformWords}

  @world "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,bfc5099e"
  @local "00000000,00000000,bfc5099e,00000000,00000000,00000000,3f800000"

  test "the world and local groups decode strictly and re-encode byte for byte" do
    assert {:ok, world} = TransformWords.decode_world(@world)
    assert length(world) == 12 and TransformWords.encode(world) == @world
    assert {:ok, local} = TransformWords.decode_local(@local)
    assert length(local) == 7 and TransformWords.encode(local) == @local

    assert Enum.at(world, 11) == 0xBFC5099E
    assert_in_delta TransformWords.to_float(0xBFC5099E), -1.539356, 1.0e-6
    [x, y, z] = TransformWords.translation(world)
    assert x == 0.0 and y == 0.0
    assert_in_delta z, -1.539356, 1.0e-6
    assert byte_size(@world) == 107 and byte_size(@local) == 62
  end

  test "signed zero is preserved as evidence and both zeros are finite" do
    assert {:ok, [0, 0x80000000 | _]} =
             TransformWords.decode_local(
               "00000000,80000000,bfc5099e,00000000,00000000,00000000,3f800000"
             )

    assert TransformWords.finite?(0) and TransformWords.finite?(0x80000000)
    assert TransformWords.to_word(-0.0) == 0x80000000 and TransformWords.to_word(0.0) == 0
    assert TransformWords.format7(TransformWords.to_float(0x80000000)) == "-0"
    assert TransformWords.format7(0.0) == "0"
  end

  test "malformed words and counts, uppercase, separators and non-finite values are refused whole" do
    assert {:error, {:word_count, 1, 12}} = TransformWords.decode_world("")
    assert {:error, {:word_count, 7, 12}} = TransformWords.decode_world(@local)
    assert {:error, {:word_count, 12, 7}} = TransformWords.decode_local(@world)
    assert {:error, {:word_count, 13, 12}} = TransformWords.decode_world(@world <> ",3f800000")

    assert {:error, {:not_a_word, 0}} =
             TransformWords.decode_world(
               String.replace(@world, "3f800000", "3F800000", global: false)
             )

    assert {:error, {:not_a_word, 1}} =
             TransformWords.decode_world(
               String.replace(@world, "00000000,", "0000000g,", global: false)
             )

    assert {:error, {:not_a_word, 0}} =
             TransformWords.decode_world("3f80000" <> String.slice(@world, 8..-1//1))

    assert {:error, {:not_finite, 0}} =
             TransformWords.decode_world(
               String.replace(@world, "3f800000", "7f800000", global: false)
             )

    assert {:error, {:not_finite, 11}} =
             TransformWords.decode_world(String.replace(@world, "bfc5099e", "7fc00001"))

    assert {:error, {:not_finite, 11}} =
             TransformWords.decode_world(String.replace(@world, "bfc5099e", "ff800000"))

    assert {:error, :not_text} = TransformWords.decode_world(nil)
    refute Schema.words12?(String.replace(@world, "bfc5099e", "7fc00001"))
    refute Schema.words12?(@local) and refute(Schema.words7?(@world))
    assert Schema.words12?(@world) and Schema.words7?(@local)

    refute TransformWords.finite?(0x7F800000) or TransformWords.finite?(0xFF800000) or
             TransformWords.finite?(0x7FC00000)

    assert TransformWords.finite?(0x7F7FFFFF)
  end

  test "the seven-digit twins: one rendering, two words, two states" do
    a = TransformWords.to_float(0xBFC5099E)
    b = TransformWords.to_float(0xBFC5099F)
    assert a != b
    assert TransformWords.format7(a) == "-1.539356" and TransformWords.format7(b) == "-1.539356"
    refute TransformWords.equal?([0xBFC5099E], [0xBFC5099F])
    assert TransformWords.within_tolerance?([0xBFC5099E], [0xBFC5099F])
  end

  test "the human renderings equal the native %.7g (reading only)" do
    renderings = [
      {-1.539356, "-1.539356"},
      {0.25, "0.25"},
      {1.0e10, "1e+10"},
      {14.69725, "14.69725"},
      {123_456_789.0, "1.234568e+08"},
      {9.9999999, "10"},
      {1.0e-5, "1e-05"},
      {0.4925565, "0.4925565"},
      {-24.293657, "-24.29366"},
      {-83.74377, "-83.74377"},
      {-1.289356, "-1.289356"}
    ]

    for {f, text} <- renderings do
      assert TransformWords.format7(TransformWords.to_float(TransformWords.to_word(f))) == text,
             inspect(f)
    end

    assert {:ok, world} = TransformWords.decode_world(@world)
    assert TransformWords.translation_text(world) == "0,0,-1.539356"
    assert {:ok, local} = TransformWords.decode_local(@local)
    assert TransformWords.local_text(local) == "0,0,-1.539356|0,0,0,1"
  end

  test "the declared tolerance is 1.0e-4 per word, never equality, never for non-finite words" do
    assert TransformWords.tolerance() == 1.0e-4
    {:ok, world} = TransformWords.decode_world(@world)
    near = List.replace_at(world, 11, TransformWords.to_word(-1.539356 + 5.0e-5))
    far = List.replace_at(world, 11, TransformWords.to_word(-1.539356 + 2.0e-4))

    assert TransformWords.within_tolerance?(world, near) and
             not TransformWords.equal?(world, near)

    refute TransformWords.within_tolerance?(world, far)
    refute TransformWords.within_tolerance?(world, List.replace_at(world, 0, 0x7FC00000), 1.0)
  end

  test "the replicated lift target copies every word and adds 0.25 to z in binary32" do
    {:ok, world} = TransformWords.decode_world(@world)
    target = TransformWords.lift_target(world)
    assert Enum.take(target, 11) == Enum.take(world, 11)
    assert TransformWords.encode(target) == String.replace(@world, "bfc5099e", "bfa5099e")
    assert TransformWords.format7(TransformWords.to_float(Enum.at(target, 11))) == "-1.289356"
    # a translation too large for the binary32 addition to move: the target equals the preimage
    huge = List.replace_at(world, 11, TransformWords.to_word(3.0e8))
    assert TransformWords.lift_target(huge) == huge
  end

  test "a round trip through JSON keeps the words (the journal and the wire carry the text unchanged)" do
    line = JSON.encode!(%{"expect_world" => @world, "expect_local" => @local})
    assert %{"expect_world" => w, "expect_local" => l} = JSON.decode!(line)
    assert {:ok, world} = TransformWords.decode_world(w)
    assert {:ok, local} = TransformWords.decode_local(l)
    assert TransformWords.encode(world) == @world and TransformWords.encode(local) == @local
  end
end
