defmodule GlacierRelay.Motion.Admission do
  @moduledoc """
  M7-L3 source-sequence admission correction (`docs/design/M7_NETWORK_GHOST.md` sections 29.3–29.4):
  the optional `stationary_prefix` admission of a destination session, fixed in the operator's
  local approval with the rest of it and never supplied or changed by a peer. Pure.

  Fields (`validate/1`): `:kind` (`"stationary_prefix"`); `:anchor`, the opening anchor's
  horizontal words (`"x,y"`, which the authority compares with the qualified inspection's x / y and
  the hub with the native-confirmed opening snapshot's); `:course`, the declared `course` text the
  stream must carry (exact, 1 … 256 bytes); `:max_open_seq` (1 … `max_activation_seq`), the highest
  observed sequence number allowed at preparation; `:max_activation_seq` (… `first_changing_seq` −
  1), the highest allowed when the native-open result is processed; `:first_changing_seq` (… 100,000),
  the course's first sample that leaves the anchor. Every bound is inclusive as written. It applies
  only to a `synthetic` stream, and its numbers belong to that one opted-in course, not to motion in
  general (M7-L3: 55 / 61 / 82).

  `evaluate/3` reads a stream's own record in the hub (`Motion.StreamProgress`) at the moment it is
  called: the stream open and not reopened, declared `synthetic` with exactly `course`, with
  progress whose highest sample is qualified, at exactly `anchor` and at most the phase's bound. It
  returns the verdict and compact evidence for the trace and the journal. The first-target rule is
  `Motion.Destination`'s acquisition.
  """

  alias GlacierRelay.Command.TransformWords

  @fields [:kind, :anchor, :course, :max_open_seq, :max_activation_seq, :first_changing_seq]
  @max_seq 100_000
  @course_bytes 256

  @doc "Validates an admission (`nil` is no admission). `{:ok, admission | nil}` or `{:error, reason}`."
  def validate(nil), do: {:ok, nil}

  def validate(%{} = a) do
    with [] <- Map.keys(a) -- @fields,
         true <- a[:kind] == "stationary_prefix" or {:error, {:admission_kind, a[:kind]}},
         {:ok, anchor} <- anchor(a[:anchor]),
         true <- course?(a[:course]) or {:error, :admission_course_invalid},
         true <- seq_order?(a) or {:error, :admission_sequence_bounds} do
      {:ok, %{a | anchor: anchor}}
    else
      unknown when is_list(unknown) -> {:error, {:admission_unknown_fields, unknown}}
      error -> error
    end
  end

  def validate(_), do: {:error, :admission_not_a_map}

  # TransformWords' text is strict (lowercase, eight digits per word), so an accepted anchor is in
  # the canonical form every later comparison uses, word for word
  defp anchor(text) when is_binary(text) do
    case TransformWords.decode(text, 2) do
      {:ok, _words} -> {:ok, text}
      _ -> {:error, :admission_anchor_invalid}
    end
  end

  defp anchor(_), do: {:error, :admission_anchor_invalid}

  defp course?(c),
    do:
      is_binary(c) and String.valid?(c) and byte_size(c) in 1..@course_bytes and
        not String.contains?(c, ["\n", "\r"])

  defp seq_order?(%{max_open_seq: o, max_activation_seq: a, first_changing_seq: f})
       when is_integer(o) and is_integer(a) and is_integer(f),
       do: o >= 1 and a >= o and f > a and f <= @max_seq

  defp seq_order?(_), do: false

  @doc """
  The admission at `phase` (`:prepare` or `:activation`) for `stream` — the hub's record of the
  approved stream on the current connection, or nil — and, at activation, the native-confirmed
  opening snapshot (12 words as text). Returns `{:ok | {:error, why}, evidence}`.
  """
  def evaluate(adm, stream, phase, opening_world \\ nil) do
    max = if phase == :prepare, do: adm.max_open_seq, else: adm.max_activation_seq
    high = stream && stream.progress.high

    verdict =
      cond do
        stream == nil ->
          {:error, :stream_not_open}

        stream[:reopened] == true ->
          {:error, :stream_reopened}

        stream.source_kind != "synthetic" ->
          {:error, :stream_not_synthetic}

        stream.course != adm.course ->
          {:error, :course_mismatch}

        phase == :activation and opening_xy(opening_world) != adm.anchor ->
          {:error, :anchor_not_the_opening}

        high == nil ->
          {:error, :no_progress}

        high.qualified != true ->
          {:error, {:progress_unqualified, high.seq}}

        high.xy != adm.anchor ->
          {:error, {:progress_off_anchor, high.seq}}

        high.seq > max ->
          {:error, {:progress_beyond, high.seq, max}}

        true ->
          :ok
      end

    {verdict, evidence(stream, phase, max, verdict)}
  end

  @doc "A refusal reason as text."
  def why_text({:progress_beyond, seq, max}), do: "progress_beyond:#{seq}>#{max}"
  def why_text({tag, seq}) when is_atom(tag), do: "#{tag}:#{seq}"
  def why_text(why) when is_atom(why), do: Atom.to_string(why)

  defp opening_xy(world) when is_binary(world) do
    case TransformWords.decode_world(world) do
      {:ok, words} -> TransformWords.encode([Enum.at(words, 9), Enum.at(words, 10)])
      _ -> nil
    end
  end

  defp opening_xy(_), do: nil

  defp evidence(stream, phase, max, verdict) do
    p = stream && stream.progress
    h = p && p.high

    %{
      "phase" => Atom.to_string(phase),
      "verdict" => if(verdict == :ok, do: "met", else: why_text(elem(verdict, 1))),
      "max_seq" => max,
      "high_seq" => h && h.seq,
      "high_xy" => h && h.xy,
      "high_qualified" => h && h.qualified,
      "high_src_mono_ms" => h && h.src_mono_ms,
      "high_received_mono_ms" => h && h.received_mono_ms,
      "received" => p && p.received,
      "advanced" => p && p.advanced,
      "not_advanced" => p && p.not_advanced,
      "first_seq" => p && p.first_seq,
      "index_gaps" => p && p.index_gaps
    }
  end
end
