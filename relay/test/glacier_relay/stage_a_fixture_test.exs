defmodule GlacierRelay.StageAFixtureTest do
  @moduledoc """
  The six envelopes the native pipeline (MissionObserver -> RelayAdapter -> TcpRelaySink) produced
  in the M2 Stage A standalone wire test on 2026-10-06 (wire probe, `stage1` replay of the M1
  scene timeline), taken from the native `published` log lines. Both edges, as the DLL would send.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.Lifecycle
  alias GlacierRelay.Lifecycle.Attempt
  alias GlacierRelay.Wire.Envelope

  @lines File.read!("test/stage_a_probe_envelopes.ndjson") |> String.split("\n", trim: true)

  test "every native envelope decodes and the types alternate" do
    decoded = Enum.map(@lines, &Envelope.decode/1)
    assert Enum.all?(decoded, &match?({:ok, _}, &1))
    envelopes = Enum.map(decoded, fn {:ok, e} -> e end)
    assert Enum.map(envelopes, & &1.sequence) == [1, 2, 3, 4, 5, 6]

    assert Enum.map(envelopes, & &1.event_type) ==
             ~w(mission.playing mission.stopped mission.playing mission.stopped mission.playing mission.stopped)

    assert Enum.all?(envelopes, &(&1.schema_version == 1 and &1.protocol_version == 1))

    assert Enum.uniq(Enum.map(envelopes, & &1.adapter_instance_id)) == [
             "cba1b5ec-bec1-4f61-8123-84376e3bd157"
           ]

    # The probe's timeline supplied a session id on the rise frames only; the fall frames carried none.
    assert Enum.map(envelopes, &(&1.payload.game_session_id != nil)) == [
             true,
             false,
             true,
             false,
             true,
             false
           ]
  end

  test "folding them yields three bounded attempts, nothing open, nothing superseded" do
    instance =
      Enum.reduce(@lines, Lifecycle.new("cba1b5ec-bec1-4f61-8123-84376e3bd157"), fn line, inst ->
        {:ok, envelope} = Envelope.decode(line)
        {inst, []} = Lifecycle.apply_event(inst, envelope, nil)
        inst
      end)

    assert [%Attempt{mission: :stopped}, %Attempt{mission: :stopped}, %Attempt{mission: :stopped}] =
             instance.attempts

    assert Enum.map(instance.attempts, & &1.codename_hint) == ["Peacock", "Peacock", "Octopus"]
    assert Enum.map(instance.attempts, &Lifecycle.duration_ms/1) == [204, 203, 202]
    assert instance.gaps == [] and instance.unmatched_stops == []
    assert Lifecycle.current_attempt(instance) == nil
  end
end
