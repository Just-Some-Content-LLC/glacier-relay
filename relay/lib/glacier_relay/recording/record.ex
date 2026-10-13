defmodule GlacierRelay.Recording.Record do
  @moduledoc """
  One recording-grade evidence item as `GlacierRelay.MissionSession` issues it (M4-A, ADR 0008):
  what the session saw, in the order it saw it, with the time the evidence carried when it
  reached BEAM. Built by the session, never by the recorder.

  - `no`: the session's record number — one monotonically increasing counter per session
    lifetime, incremented for every evidence item of any kind whether or not anyone subscribes.
    The only ordering source; a hole in it is missing recording evidence.
  - `kind`: `:connection_opened`, `:connection_identified`, `:envelope`, `:connection_closed`.
  - `at`: the evidence's own time as the session holds it — the connection's `opened_at` /
    `closed_at`, or the envelope's BEAM receipt time (`received_at`, stamped by the connection
    process). Never the recorder's clock.
  - `conn`: the session-assigned connection number (recording-local identity; peer addresses are
    descriptive and may repeat). Nil for an envelope delivered by a process that never announced
    a connection (direct callers in tests).
  - `peer`: the peer address string, descriptive only.
  - `instance`: the adapter instance id named (envelope, identification, close of an identified
    connection); nil for an unidentified close or an open.
  - `previous_instance`: on `:connection_identified`, the instance the same socket named before
    (the re-attribution path), else nil.
  - `envelope`: the validated `%GlacierRelay.Wire.Envelope{}` (with its `raw` wire object) on
    `:envelope`.
  - `reason`: the close reason on `:connection_closed`, as the connection reported it.
  """

  @type kind :: :connection_opened | :connection_identified | :envelope | :connection_closed

  @type t :: %__MODULE__{
          no: pos_integer(),
          kind: kind(),
          at: DateTime.t() | nil,
          conn: pos_integer() | nil,
          peer: String.t() | nil,
          instance: String.t() | nil,
          previous_instance: String.t() | nil,
          envelope: GlacierRelay.Wire.Envelope.t() | nil,
          reason: term()
        }

  defstruct [:no, :kind, :at, :conn, :peer, :instance, :previous_instance, :envelope, :reason]
end
