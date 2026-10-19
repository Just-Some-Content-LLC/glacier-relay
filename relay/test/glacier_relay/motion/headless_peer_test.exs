defmodule GlacierRelay.Motion.HeadlessPeerTest do
  @moduledoc """
  M7-B1: the headless peer starts nothing of a game host (design section 9; ADR 0010 as amended,
  decision 4): its tree is a trace, its driver and one listening endpoint — no command authority,
  no motion link, no hub, no engine-writing path — and its source labels every stream synthetic.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.HeadlessPeer
  alias GlacierRelay.Peer.Endpoint
  alias GlacierRelay.Test.PeerCredentials

  test "the headless peer's tree: trace, driver, endpoint; nothing of the command or motion subtrees" do
    dir = Path.join(System.tmp_dir!(), "glacier-relay-hp-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    c = PeerCredentials.pair()

    start_supervised!(
      {HeadlessPeer,
       port: 0,
       credentials: fn -> c.headless end,
       label: "headless-test",
       expected: %{label: "host-test", client_kind: "game"},
       trace_dir: dir}
    )

    ids = HeadlessPeer |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.reverse()
    assert ids == [GlacierRelay.Motion.Trace, GlacierRelay.HeadlessPeer.Driver, Endpoint]

    for name <- [
          GlacierRelay.Command.Supervisor,
          GlacierRelay.Command.Authority,
          GlacierRelay.Command.Listener,
          GlacierRelay.Motion.Supervisor,
          GlacierRelay.Motion.Hub,
          GlacierRelay.Motion.Listener
        ] do
      assert Process.whereis(name) == nil, "#{inspect(name)} runs in a headless peer"
    end

    %{address: {{127, 0, 0, 1}, port}, role: :listen, local: %{client_kind: "headless"}} =
      Endpoint.status(HeadlessPeer.endpoint())

    assert port > 0

    for p <- [4749, 4750] do
      assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, p, [:binary], 500)
    end

    # without a connected game host the source starts nothing
    assert {:error, :no_peer} =
             GlacierRelay.HeadlessPeer.Driver.start_course(
               GlacierRelay.Motion.Course.out_and_back(GlacierRelay.Test.FakeMotionNative.anchor_words())
             )
  end
end
