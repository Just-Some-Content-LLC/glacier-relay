defmodule GlacierRelay.Command.TransformWords do
  @moduledoc """
  M6-F: the canonical float-word codec (`docs/design/M6D2_NEXT_STEP_DESIGN.md` section 12.3),
  the BEAM half of the native `FloatWords`. One stored IEEE-754 binary32 value travels as its exact
  bit pattern — eight lowercase hex digits, most significant nibble first — and a group is its
  words joined by `","` with no spaces: the world group `W12` (`m_mTransform` in its declared
  order: `XAxis.xyz, YAxis.xyz, ZAxis.xyz, Trans.xyz`, 107 bytes) and the parent-relative group
  `L7` (`m_vObjectToParentTranslation.xyz, m_vObjectToParentRotation.xyzw`, 62 bytes).

  Decoding is strict: the exact word count, exactly eight lowercase hex digits per word, every
  word finite (an exponent field of `0xff` — NaN and the infinities — is refused); a signed zero
  is a valid, distinct word (`00000000` ≠ `80000000`). The float value of a word is a bit copy
  (`<<w::32>>` ↔ `<<f::float-32>>`), never a parse of rounded text; the seven-significant-digit
  text (`format7/1`, the native `%.7g`) is for reading only and never a decision. The declared
  comparison tolerance (section 12.8) is `1.0e-4` per world word; agreement within it is never
  called equality. The compiled displacement is replicated here only so the operator tooling can
  cross-check the native `requested_world_words` (preimage z + 0.25 in binary32); the native side
  is the one that computes the target the setter receives.
  """

  @world_words 12
  @local_words 7
  @tolerance 1.0e-4
  @lift_z 0.25
  @step_y 0.25
  @word ~r/^[0-9a-f]{8}$/

  def world_words, do: @world_words
  def local_words, do: @local_words
  def tolerance, do: @tolerance
  def lift_z, do: @lift_z
  def step_y, do: @step_y

  @doc "Decodes a world group (12 words) strictly: `{:ok, [word]}` or `{:error, reason}`."
  def decode_world(text), do: decode(text, @world_words)

  @doc "Decodes a parent-relative group (7 words) strictly."
  def decode_local(text), do: decode(text, @local_words)

  @doc "Decodes a group of exactly `count` words; every word eight lowercase hex digits and finite."
  def decode(text, count) when is_binary(text) and is_integer(count) and count > 0 do
    parts = String.split(text, ",")

    cond do
      length(parts) != count ->
        {:error, {:word_count, length(parts), count}}

      true ->
        parts
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {part, i}, {:ok, acc} ->
          cond do
            not Regex.match?(@word, part) ->
              {:halt, {:error, {:not_a_word, i}}}

            true ->
              word = String.to_integer(part, 16)

              if finite?(word),
                do: {:cont, {:ok, [word | acc]}},
                else: {:halt, {:error, {:not_finite, i}}}
          end
        end)
        |> case do
          {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
          error -> error
        end
    end
  end

  def decode(_text, _count), do: {:error, :not_text}

  @doc "The canonical text of a list of words."
  def encode(words) when is_list(words) do
    words
    |> Enum.map(fn w when is_integer(w) and w >= 0 and w <= 0xFFFFFFFF ->
      w |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(8, "0")
    end)
    |> Enum.join(",")
  end

  @doc "True when the word's exponent field is not all ones (neither NaN nor an infinity)."
  def finite?(word) when is_integer(word), do: Bitwise.band(Bitwise.bsr(word, 23), 0xFF) != 0xFF

  @doc "The binary32 value of a word, by bit copy."
  def to_float(word) when is_integer(word) do
    <<f::float-32>> = <<word::32>>
    f
  end

  @doc "The word of a binary32 value, by bit copy (the float is rounded to binary32 first)."
  def to_word(f) when is_float(f) or is_integer(f) do
    <<w::32>> = <<f * 1.0::float-32>>
    w
  end

  @doc "The float values of a word list."
  def floats(words) when is_list(words), do: Enum.map(words, &to_float/1)

  @doc "The translation (words 9..11) of a world group as floats."
  def translation(words) when is_list(words) and length(words) == @world_words,
    do: words |> Enum.drop(9) |> floats()

  @doc """
  The seven-significant-digit rendering the native side uses for its human texts (`%.7g`):
  reading only, never a decision; two different words may share one rendering.
  """
  def format7(f) when is_float(f) do
    cond do
      f == 0.0 ->
        if match?(<<1::1, _::bitstring>>, <<f::float-64>>), do: "-0", else: "0"

      true ->
        exp = f |> abs() |> :math.log10() |> :math.floor() |> trunc()
        digits = :erlang.float_to_binary(f, [{:scientific, 6}])
        [mantissa, e] = String.split(digits, "e")
        e = String.to_integer(e)
        # the exponent after rounding to 7 significant digits is the one %g judges
        if e < -4 or e >= 7, do: sci(mantissa, e), else: fixed(f, e, exp)
    end
  end

  defp sci(mantissa, e) do
    m = mantissa |> String.trim_trailing("0") |> String.trim_trailing(".")
    sign = if e < 0, do: "-", else: "+"
    "#{m}e#{sign}#{e |> abs() |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp fixed(f, e, _exp) do
    decimals = max(6 - e, 0)
    f |> :erlang.float_to_binary([{:decimals, decimals}]) |> trim_fixed()
  end

  defp trim_fixed(text) do
    if String.contains?(text, "."),
      do: text |> String.trim_trailing("0") |> String.trim_trailing("."),
      else: text
  end

  @doc "The native `*_world` human text of a world group: `\"x,y,z\"` of the translation."
  def translation_text(words) when is_list(words),
    do: words |> translation() |> Enum.map_join(",", &format7/1)

  @doc "The native `*_local` human text of a parent-relative group: `\"tx,ty,tz|qx,qy,qz,qw\"`."
  def local_text(words) when is_list(words) and length(words) == @local_words do
    {t, q} = Enum.split(floats(words), 3)
    Enum.map_join(t, ",", &format7/1) <> "|" <> Enum.map_join(q, ",", &format7/1)
  end

  @doc "Bit equality of two word lists (the only basis for changed / held / restored)."
  def equal?(a, b) when is_list(a) and is_list(b), do: a == b

  @doc """
  The declared tolerance: every word of both groups finite and `|a - b| <= tolerance` as floats.
  Agreement within it is `near_*` / `within_tolerance`, never equality.
  """
  def within_tolerance?(a, b, tolerance \\ @tolerance)
      when is_list(a) and is_list(b) and length(a) == length(b) do
    Enum.all?(a, &finite?/1) and Enum.all?(b, &finite?/1) and
      Enum.zip(floats(a), floats(b)) |> Enum.all?(fn {x, y} -> abs(x - y) <= tolerance end)
  end

  @doc """
  The compiled displacement replicated for cross-checks only: every word copied, `Trans.z`
  replaced by `z + 0.25` rounded to binary32 (the native side's binary32 addition). Never a
  target sent to the native side, which computes its own.
  """
  def lift_target(words) when is_list(words) and length(words) == @world_words do
    z = to_float(Enum.at(words, 11))
    List.replace_at(words, 11, to_word(z + @lift_z))
  end

  @doc """
  M6-G1: the v2 compiled displacement replicated for cross-checks only: every word copied, `Trans.y`
  (word 10) replaced by `y + 0.25` rounded to binary32. Never a target sent to the native side,
  which computes its own; world y is not a model-relative direction.
  """
  def step_y_target(words) when is_list(words) and length(words) == @world_words do
    y = to_float(Enum.at(words, 10))
    List.replace_at(words, 10, to_word(y + @step_y))
  end

  @doc "M6-G1: the compiled forward target of a `{version, mode}` pair (v1 lift, v2 step_y), or nil."
  def forward_target(1, "lift", words), do: lift_target(words)
  def forward_target(2, "step_y", words), do: step_y_target(words)
  def forward_target(_version, _mode, _words), do: nil
end
