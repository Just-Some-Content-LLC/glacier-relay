defmodule GlacierRelay.Peer.NetworkWiringTest do
  @moduledoc """
  M7-L1: the `lan_ipv4` profile in the application wiring (design section 20), on owned loopback
  sockets in this VM: the game host's motion subtree connects out under a connect profile to an
  in-VM headless peer listening under a listen profile; every other listener of the VM stays on
  `127.0.0.1`; a share goes out and a synthetic course comes in exactly as with B1's loopback
  wiring; and the host's peer endpoint refuses a listen profile (the game host never listens).
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.{HeadlessPeer, Motion}
  alias GlacierRelay.HeadlessPeer.Driver
  alias GlacierRelay.Motion.Hub
  alias GlacierRelay.Peer.Endpoint
  alias GlacierRelay.Test.{FakeMotionNative, MotionStack, PeerCredentials}

  @gen FakeMotionNative.generation()

  defp listeners do
    for p <- :erlang.ports(),
        Port.info(p)[:name] == ~c"tcp_inet",
        match?({:error, :enotconn}, :inet.peername(p)),
        {:ok, {ip, port}} <- [:inet.sockname(p)],
        do: {ip, port}
  end

  test "the host connects out under the profile; every other listener stays on loopback; data flows both ways" do
    st = MotionStack.start(lan: true)
    port = st.headless_port

    assert %{
             role: :connect,
             address: {{127, 0, 0, 1}, ^port},
             network: "lan_ipv4 127.0.0.1:" <> _
           } =
             Endpoint.status(Motion.PeerEndpoint)

    assert %{role: :listen, network: net} = Endpoint.status(HeadlessPeer.endpoint())
    assert net == "lan_ipv4 127.0.0.1:#{port}/8, initiator 127.0.0.1"

    ls = listeners()
    assert {{127, 0, 0, 1}, port} in ls
    assert Enum.all?(ls, fn {ip, _} -> ip == {127, 0, 0, 1} end), inspect(ls)

    # out: a share reaches the headless sink, reconciled
    :ok = MotionStack.arm()
    {:ok, %{share_id: share}} = Motion.open_share(duration_ms: 1_000, expected_generation: @gen)

    MotionStack.wait(
      fn -> Enum.any?(Driver.status().sink_done, &(&1.stream_id == share)) end,
      300
    )

    [done] = Enum.filter(Driver.status().sink_done, &(&1.stream_id == share))
    assert done.reconciliation["complete"] and done.source_kind == "game"

    # in: the headless peer's synthetic course drives the fake native inside a session
    stream = MotionStack.start_course()
    {_sid, _} = MotionStack.open_session(st.adapter, stream)
    MotionStack.wait(fn -> match?(%{status: :done}, Hub.status().session) end, 800)
    s = Hub.status().session.summary
    assert s.close.state == :confirmed and s.counts.applied > 0 and s.counts.uncertain == 0
    assert Endpoint.status(Motion.PeerEndpoint).counts.connections == 1
  end

  defmodule Boom do
    @moduledoc false
    def connect(_ip, _port, _opts, _timeout) do
      send(:persistent_term.get({__MODULE__, :owner}), :seam_used)
      {:error, :seam_used}
    end
  end

  test "configuration cannot inject the endpoint's test seam into the host (verifier V11)" do
    :persistent_term.put({Boom, :owner}, self())
    on_exit(fn -> :persistent_term.erase({Boom, :owner}) end)
    MotionStack.start(lan: true, peer_extra: [socket_module: Boom])
    assert Hub.status().peer != nil
    refute_received :seam_used

    assert :sys.get_state(Motion.PeerEndpoint).sock == nil
  end

  test "the game host's peer endpoint refuses a listen profile" do
    c = PeerCredentials.pair()
    Process.flag(:trap_exit, true)

    assert {:error,
            {{:shutdown, {:failed_to_start_child, GlacierRelay.Peer.Endpoint, reason}}, _}} =
             start_supervised(
               {Motion.Supervisor,
                port: 0,
                trace_dir:
                  Path.join(
                    System.tmp_dir!(),
                    "m7l1-wiring-#{System.unique_integer([:positive])}"
                  ),
                peer: [
                  network: MotionStack.lan_listen(MotionStack.free_port()),
                  credentials: fn -> c.host end,
                  local: %{label: "host-test", client_kind: "game"},
                  expected: %{label: "headless-test", client_kind: "headless"}
                ]}
             )

    assert reason == {:network_profile, {:role_mismatch, :connect}}
  end
end
