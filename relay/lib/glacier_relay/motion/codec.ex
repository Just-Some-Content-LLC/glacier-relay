defmodule GlacierRelay.Motion.Codec do
  @moduledoc """
  M7-B1: the local motion link's protocol, version 1 (`127.0.0.1:4750`; native-initiated;
  `docs/design/M7_NETWORK_GHOST.md` sections 15.4–15.5). Lines of at most 1,024 bytes, strict
  (`Motion.LineCodec`). Positions are exact binary32 words (`Command.TransformWords`): `pos` is
  `x,y,z` on a hero sample and `x,y` on a target or a postimage.

  Native → BEAM:

      {"motion_protocol_version":1,"kind":"motion.hello","adapter_instance_id":"<uuid>","command_link_generation":N}
      {"motion_protocol_version":1,"kind":"motion.attest","motion_link_generation":M,"command_link_generation":N,
       "adapter_instance_id":"<uuid>","mac":"<64 hex>"}
      {"motion_protocol_version":1,"kind":"hero.sample","share_id":"<uuid>","seq":N,"frame":N,"native_mono_ms":N,
       "pos":"x,y,z","dirty":bool}
      {"motion_protocol_version":1,"kind":"share.closed","share_id":"<uuid>","reason":"<text>","last_seq":N|null,"sent":N}
      {"motion_protocol_version":1,"kind":"ghost.applied","session_id":"<uuid>","seq":N,"frame":N,"native_mono_ms":N,
       "outcome":"applied|skipped_identical|refused|uncertain","reason":"<text>|null","post":"x,y"|null,"exact":bool|null}
      {"motion_protocol_version":1,"kind":"ghost.report","session_id":"<uuid>","report_seq":N,"native_mono_ms":N,"frame":N,
       "received":N,"applied":N,"skipped":N,"refused":N,"uncertain":N,"superseded":N,"last_applied_seq":N|null}
      {"motion_protocol_version":1,"kind":"ghost.closed","session_id":"<uuid>","reason":"<text>","native_mono_ms":N,
       "clean":bool,"final_world":"<12 words>"|null,"last_applied_seq":N|null,"applied":N}

  BEAM → native:

      {"motion_protocol_version":1,"kind":"motion.welcome","motion_link_generation":M,"nonce":"<32 hex>"}
      {"motion_protocol_version":1,"kind":"motion.refused","reason":"<text>"}
      {"motion_protocol_version":1,"kind":"ghost.target","session_id":"<uuid>","seq":N,"pos":"x,y"}
      {"motion_protocol_version":1,"kind":"ghost.close","session_id":"<uuid>","reason":"<text>"}
      {"motion_protocol_version":1,"kind":"share.close","share_id":"<uuid>","reason":"<text>"}

  The BEAM → native decoder exists for the test fakes (the B2 native implements its own); nothing
  in this module is a function, an address or a pointer.
  """

  alias GlacierRelay.Motion.LineCodec

  @max_line_bytes 1_024
  @version 1
  @gen {:integer, 1, 2_147_483_647}

  @from_native %{
    "motion.hello" =>
      {:motion_hello,
       [
         {"adapter_instance_id", :adapter_instance_id, :uuid, :required},
         {"command_link_generation", :command_link_generation, @gen, :required}
       ]},
    "motion.attest" =>
      {:motion_attest,
       [
         {"motion_link_generation", :motion_link_generation, @gen, :required},
         {"command_link_generation", :command_link_generation, @gen, :required},
         {"adapter_instance_id", :adapter_instance_id, :uuid, :required},
         {"mac", :mac, :mac, :required}
       ]},
    "hero.sample" =>
      {:hero_sample,
       [
         {"share_id", :share_id, :uuid, :required},
         {"seq", :seq, :pos_integer, :required},
         {"frame", :frame, :non_neg_integer, :required},
         {"native_mono_ms", :native_mono_ms, :non_neg_integer, :required},
         {"pos", :pos, {:words, 3}, :required},
         {"dirty", :dirty, :boolean, :required}
       ]},
    "share.closed" =>
      {:share_closed,
       [
         {"share_id", :share_id, :uuid, :required},
         {"reason", :reason, {:text, 64}, :required},
         {"last_seq", :last_seq, :non_neg_integer, :optional},
         {"sent", :sent, :non_neg_integer, :required}
       ]},
    "ghost.applied" =>
      {:ghost_applied,
       [
         {"session_id", :session_id, :uuid, :required},
         {"seq", :seq, :pos_integer, :required},
         {"frame", :frame, :non_neg_integer, :required},
         {"native_mono_ms", :native_mono_ms, :non_neg_integer, :required},
         {"outcome", :outcome, {:enum, ~w(applied skipped_identical refused uncertain)},
          :required},
         {"reason", :reason, {:text, 64}, :optional},
         {"post", :post, {:words, 2}, :optional},
         {"exact", :exact, :boolean, :optional}
       ]},
    "ghost.report" =>
      {:ghost_report,
       [
         {"session_id", :session_id, :uuid, :required},
         {"report_seq", :report_seq, :pos_integer, :required},
         {"native_mono_ms", :native_mono_ms, :non_neg_integer, :required},
         {"frame", :frame, :non_neg_integer, :required},
         {"received", :received, :non_neg_integer, :required},
         {"applied", :applied, :non_neg_integer, :required},
         {"skipped", :skipped, :non_neg_integer, :required},
         {"refused", :refused, :non_neg_integer, :required},
         {"uncertain", :uncertain, :non_neg_integer, :required},
         {"superseded", :superseded, :non_neg_integer, :required},
         {"last_applied_seq", :last_applied_seq, :non_neg_integer, :optional}
       ]},
    "ghost.closed" =>
      {:ghost_closed,
       [
         {"session_id", :session_id, :uuid, :required},
         {"reason", :reason, {:text, 64}, :required},
         {"native_mono_ms", :native_mono_ms, :non_neg_integer, :required},
         {"clean", :clean, :boolean, :required},
         {"final_world", :final_world, {:words, 12}, :optional},
         {"last_applied_seq", :last_applied_seq, :non_neg_integer, :optional},
         {"applied", :applied, :non_neg_integer, :required}
       ]}
  }

  @from_beam %{
    "motion.welcome" =>
      {:motion_welcome,
       [
         {"motion_link_generation", :motion_link_generation, @gen, :required},
         {"nonce", :nonce, :hex32, :required}
       ]},
    "motion.refused" => {:motion_refused, [{"reason", :reason, {:text, 64}, :required}]},
    "ghost.target" =>
      {:ghost_target,
       [
         {"session_id", :session_id, :uuid, :required},
         {"seq", :seq, :pos_integer, :required},
         {"pos", :pos, {:words, 2}, :required}
       ]},
    "ghost.close" =>
      {:ghost_close,
       [
         {"session_id", :session_id, :uuid, :required},
         {"reason", :reason, {:text, 64}, :required}
       ]},
    "share.close" =>
      {:share_close,
       [
         {"share_id", :share_id, :uuid, :required},
         {"reason", :reason, {:text, 64}, :required}
       ]}
  }

  @native_codec %{
    max_bytes: @max_line_bytes,
    version_key: "motion_protocol_version",
    versions: [@version],
    specs: @from_native
  }
  @beam_codec %{@native_codec | specs: @from_beam}

  def max_line_bytes, do: @max_line_bytes
  def version, do: @version

  @doc "Decodes one line the native peer sent (strict)."
  def decode_from_native(line), do: LineCodec.decode(line, @native_codec)

  @doc "Decodes one line BEAM sent (strict; used by the test fakes)."
  def decode_from_beam(line), do: LineCodec.decode(line, @beam_codec)

  @doc "Encodes a BEAM → native line."
  def encode_to_native(kind, fields) when is_map_key(@from_beam, kind),
    do: LineCodec.encode(@beam_codec, @version, kind, fields)

  @doc "Encodes a native → BEAM line (the test fakes)."
  def encode_from_native(kind, fields) when is_map_key(@from_native, kind),
    do: LineCodec.encode(@native_codec, @version, kind, fields)

  @doc "The welcome line for a motion link generation and its nonce."
  def welcome(generation, nonce),
    do:
      encode_to_native("motion.welcome", %{
        "motion_link_generation" => generation,
        "nonce" => nonce
      })

  @doc "A refusal line (the link closes after it)."
  def refused(reason), do: encode_to_native("motion.refused", %{"reason" => to_text(reason)})

  @doc "A target line."
  def target(session_id, seq, pos),
    do:
      encode_to_native("ghost.target", %{"session_id" => session_id, "seq" => seq, "pos" => pos})

  @doc "A session close line."
  def close_session(session_id, reason),
    do:
      encode_to_native("ghost.close", %{"session_id" => session_id, "reason" => to_text(reason)})

  @doc "A share close line."
  def close_share(share_id, reason),
    do: encode_to_native("share.close", %{"share_id" => share_id, "reason" => to_text(reason)})

  @doc "A reason as bounded valid UTF-8 text (an atom's name or a term's inspection, at most 64 bytes)."
  def to_text(reason) when is_binary(reason) do
    reason
    |> String.replace_invalid()
    |> String.codepoints()
    |> Enum.reduce_while({0, []}, fn cp, {n, acc} ->
      if n + byte_size(cp) <= 64, do: {:cont, {n + byte_size(cp), [cp | acc]}}, else: {:halt, {n, acc}}
    end)
    |> then(fn {_n, acc} -> acc |> Enum.reverse() |> IO.iodata_to_binary() end)
  end

  def to_text(reason) when is_atom(reason), do: to_text(Atom.to_string(reason))
  def to_text(reason), do: to_text(inspect(reason))
end
