defmodule GlacierRelay.Peer.Codec do
  @moduledoc """
  M7-B1: the BEAM-to-BEAM peer protocol, version 1 (`docs/design/M7_NETWORK_GHOST.md` sections
  15.2 and 15.6), carried inside the mutually authenticated TLS connection (`Peer.TLS`). Lines of at
  most 1,024 bytes, strict (`Motion.LineCodec`); the same messages in both directions.

      {"peer_protocol_version":1,"kind":"hello","peer_label":"<text>","client_kind":"game|headless",
       "boot_id":"<uuid>","capabilities":["pose/1"]}
      {"peer_protocol_version":1,"kind":"stream.open","stream_id":"<uuid>","source_kind":"game|synthetic",
       "interval_ms":N,"src_clock":"native|beam","label":"<text>|null","course":"<text>|null"}
      {"peer_protocol_version":1,"kind":"pose.sample","stream_id":"<uuid>","seq":N,"src_mono_ms":N,
       "src_frame":N|null,"pos":"x,y,z","qualified":bool,"reason":"<text>|null"}
      {"peer_protocol_version":1,"kind":"stream.end","stream_id":"<uuid>","reason":"<text>","last_seq":N|null,"sent":N}
      {"peer_protocol_version":1,"kind":"ping","ping_seq":N,"sender_mono_ms":N}
      {"peer_protocol_version":1,"kind":"pong","ping_seq":N,"echo_mono_ms":N}
      {"peer_protocol_version":1,"kind":"bye","reason":"<text>"}

  Nothing on this link authorizes anything (ADR 0010 decision 3): a destination session is opened,
  bounded and closed only by the local authority and the local native. Adapter ids, link
  generations and mission generations are never sent. `src_mono_ms` is the source's own clock
  (`src_clock` says which), never comparable with the receiver's; `pong` echoes the pinger's clock,
  so an RTT is measured on one clock only.
  """

  alias GlacierRelay.Motion.LineCodec

  @max_line_bytes 1_024
  @version 1

  @specs %{
    "hello" =>
      {:hello,
       [
         {"peer_label", :peer_label, {:text, 64}, :required},
         {"client_kind", :client_kind, {:enum, ["game", "headless"]}, :required},
         {"boot_id", :boot_id, :uuid, :required},
         {"capabilities", :capabilities, {:list_of_text, 8, 32}, :required}
       ]},
    "stream.open" =>
      {:stream_open,
       [
         {"stream_id", :stream_id, :uuid, :required},
         {"source_kind", :source_kind, {:enum, ["game", "synthetic"]}, :required},
         {"interval_ms", :interval_ms, {:integer, 50, 1_000}, :required},
         {"src_clock", :src_clock, {:enum, ["native", "beam"]}, :required},
         {"label", :label, {:text, 64}, :optional},
         {"course", :course, {:text, 200}, :optional}
       ]},
    "pose.sample" =>
      {:pose_sample,
       [
         {"stream_id", :stream_id, :uuid, :required},
         {"seq", :seq, :pos_integer, :required},
         {"src_mono_ms", :src_mono_ms, :non_neg_integer, :required},
         {"src_frame", :src_frame, :non_neg_integer, :optional},
         {"pos", :pos, {:words, 3}, :required},
         {"qualified", :qualified, :boolean, :required},
         {"reason", :reason, {:text, 32}, :optional}
       ]},
    "stream.end" =>
      {:stream_end,
       [
         {"stream_id", :stream_id, :uuid, :required},
         {"reason", :reason, {:text, 64}, :required},
         {"last_seq", :last_seq, :non_neg_integer, :optional},
         {"sent", :sent, :non_neg_integer, :required}
       ]},
    "ping" =>
      {:ping,
       [
         {"ping_seq", :ping_seq, :pos_integer, :required},
         {"sender_mono_ms", :sender_mono_ms, :non_neg_integer, :required}
       ]},
    "pong" =>
      {:pong,
       [
         {"ping_seq", :ping_seq, :pos_integer, :required},
         {"echo_mono_ms", :echo_mono_ms, :non_neg_integer, :required}
       ]},
    "bye" => {:bye, [{"reason", :reason, {:text, 64}, :required}]}
  }

  @codec %{
    max_bytes: @max_line_bytes,
    version_key: "peer_protocol_version",
    versions: [@version],
    specs: @specs
  }

  @capabilities ["pose/1"]

  def max_line_bytes, do: @max_line_bytes
  def version, do: @version
  def capabilities, do: @capabilities

  @doc "Decodes one line from the peer (strict)."
  def decode(line), do: LineCodec.decode(line, @codec)

  @doc "Encodes one line (with its newline)."
  def encode(kind, fields) when is_map_key(@specs, kind),
    do: LineCodec.encode(@codec, @version, kind, fields)

  def hello(label, client_kind, boot_id),
    do:
      encode("hello", %{
        "peer_label" => label,
        "client_kind" => client_kind,
        "boot_id" => boot_id,
        "capabilities" => @capabilities
      })
end
