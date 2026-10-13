defmodule GlacierRelay.Session.FoldTest do
  @moduledoc "The pure session fold (M4-B): transport identity, identification, re-attribution, closes, bounds, effects."
  use ExUnit.Case, async: true

  alias GlacierRelay.Lifecycle
  alias GlacierRelay.Session.Fold
  alias GlacierRelay.Wire.Envelope

  @at ~U[2026-10-13 07:00:00.000000Z]

  defp envelope(id, seq, type \\ "mission.playing") do
    {:ok, e} =
      Envelope.decode(
        JSON.encode!(%{
          "protocol_version" => 1,
          "adapter_instance_id" => id,
          "sequence" => seq,
          "timestamp" => "2026-10-13T07:00:00.000Z",
          "event_type" => type,
          "schema_version" => 1,
          "payload" => %{
            "scene_resource" => "assembly:/x.entity",
            "scene_type" => "mission",
            "codename_hint" => "T"
          }
        })
      )

    e
  end

  test "open, identify on the first envelope, close with an interruption; effects in order" do
    s = Fold.new()
    {s, []} = Fold.connection_opened(s, 1, "127.0.0.1:5", @at)
    assert s.connections == %{1 => %{peer: "127.0.0.1:5", opened_at: @at, instance_id: nil}}

    {s, effects} = Fold.event(s, 1, envelope("a", 1), @at)

    assert [
             {:identified,
              %{conn: 1, peer: "127.0.0.1:5", instance: "a", previous_instance: nil, at: @at}}
           ] = effects

    assert s.connections[1].instance_id == "a"

    assert [%Lifecycle.Connection{identified_at: @at, closed_at: nil}] =
             s.instances["a"].connections

    assert [%Lifecycle.Attempt{mission: :playing, playing: %{received_at: @at}}] =
             s.instances["a"].attempts

    {s, effects} = Fold.connection_closed(s, 1, :peer_closed, @at)

    assert [{:closed, %{conn: 1, instance: "a", reason: :peer_closed, playing_attempt: 1}}] =
             effects

    assert s.connections == %{}
    assert Lifecycle.observation(s.instances["a"]) == :lost

    assert [%Lifecycle.Attempt{mission: :playing, interruptions: [%{reason: :peer_closed}]}] =
             s.instances["a"].attempts
  end

  test "an unidentified close joins the bounded unidentified list, newest first" do
    s =
      Enum.reduce(1..40, Fold.new(), fn n, s ->
        {s, []} = Fold.connection_opened(s, n, "127.0.0.1:1", @at)

        {s, [{:closed, %{instance: nil, playing_attempt: nil}}]} =
          Fold.connection_closed(s, n, :peer_closed, @at)

        s
      end)

    assert length(s.unidentified) == 32

    assert hd(s.unidentified) == %{
             peer: "127.0.0.1:1",
             opened_at: @at,
             closed_at: @at,
             close_reason: :peer_closed
           }

    assert s.instances == %{}
  end

  test "re-attribution: the same connection naming another instance; the earlier record stays open (documented)" do
    s = Fold.new()
    {s, []} = Fold.connection_opened(s, 7, "p", @at)
    {s, [{:identified, _}]} = Fold.event(s, 7, envelope("a", 1), @at)
    {s, effects} = Fold.event(s, 7, envelope("b", 1), @at)
    assert [{:reattributed, %{conn: 7, instance: "b", previous_instance: "a"}}] = effects
    {s, [{:closed, %{instance: "b"}}]} = Fold.connection_closed(s, 7, :peer_closed, @at)
    assert Lifecycle.observation(s.instances["b"]) == :lost
    assert Lifecycle.observation(s.instances["a"]) == :live
  end

  test "lifecycle notes come back as effects; the fold never logs" do
    s = Fold.new()
    {s, []} = Fold.connection_opened(s, 1, "p", @at)
    {s, [{:identified, _}]} = Fold.event(s, 1, envelope("a", 1), @at)
    {s, effects} = Fold.event(s, 1, envelope("a", 5, "mission.stopped"), @at)
    assert {:note, "a", {:gap, 2, 5}} in effects
    assert s.instances["a"].gaps == [{2, 5}]
  end

  test "an envelope on no connection folds without identification; an unknown connection is an effect" do
    s = Fold.new()
    {s, []} = Fold.event(s, nil, envelope("a", 1), nil)
    assert Lifecycle.observation(s.instances["a"]) == :never
    {s, effects} = Fold.event(s, 9, envelope("a", 2), nil)
    assert {:unknown_connection, 9} in effects and {:note, "a", {:superseded, 1, 2}} in effects
    assert Lifecycle.observation(s.instances["a"]) == :never
    {^s, [{:unknown_connection, 9}]} = Fold.connection_closed(s, 9, :peer_closed, nil)
  end
end
