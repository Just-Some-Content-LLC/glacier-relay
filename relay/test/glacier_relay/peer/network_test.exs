defmodule GlacierRelay.Peer.NetworkTest do
  @moduledoc """
  M7-L1: the peer endpoint's address policy (design section 20) as pure inputs, and the endpoint's
  start with it. Without a profile B1's loopback acceptance and refusal are unchanged; the
  `lan_ipv4` profile's role, address, prefix and port rules; every refusal happens before any
  socket exists; and an accepted non-loopback profile makes exactly the declared listen or connect
  call — seen through an injected socket module that records the call and touches nothing. No LAN
  address is bound or contacted by this file.
  """
  use ExUnit.Case, async: false

  alias GlacierRelay.Peer.{Endpoint, Network}
  alias GlacierRelay.Test.{FixturePlayer, PeerCredentials}

  defmodule NoNet do
    @moduledoc false
    # the injected socket module: records the endpoint's one call and fails it; no socket, ever
    def listen(port, opts) do
      send(:persistent_term.get({__MODULE__, :owner}), {:nonet_listen, port, opts})
      {:error, :injected_no_network}
    end

    def connect(ip, port, opts, timeout) do
      send(:persistent_term.get({__MODULE__, :owner}), {:nonet_connect, ip, port, opts, timeout})
      {:error, :injected_no_network}
    end
  end

  @headless %{label: "h", client_kind: "headless"}

  defp wait(fun), do: FixturePlayer.wait_until(fun, 300, 10)
  @game %{label: "g", client_kind: "game"}

  defp listen_net(ip, port \\ 4760, initiator \\ {192, 168, 1, 10}, p \\ 24),
    do: [profile: :lan_ipv4, prefix_length: p, listen: {ip, port}, initiator: initiator]

  defp connect_net(ip, port \\ 4760, p \\ 24),
    do: [profile: :lan_ipv4, prefix_length: p, connect: {ip, port}]

  defp plan(role, net, extra \\ []),
    do: Network.plan([role: role, network: net, local: @headless] ++ extra)

  defp refused(role, net, extra \\ []) do
    assert {:error, {:network_profile, reason}} = plan(role, net, extra)
    reason
  end

  setup do
    :persistent_term.put({NoNet, :owner}, self())
    on_exit(fn -> :persistent_term.erase({NoNet, :owner}) end)
    %{c: PeerCredentials.pair()}
  end

  defp start(c, opts) do
    Endpoint.start_link(
      Keyword.merge(
        [
          credentials: fn -> c.headless end,
          local: @headless,
          expected: @game,
          handler: {__MODULE__, :none},
          socket_module: NoNet
        ],
        opts
      )
    )
  end

  describe "without a profile (B1's rule, unchanged)" do
    test "loopback is the default and the only address; the port passes through as before" do
      for role <- [:listen, :connect] do
        assert {:ok, %{profile: :loopback, ip: {127, 0, 0, 1}, port: 4760, initiator: nil}} =
                 Network.plan(role: role)

        assert {:ok, %{port: 0}} = Network.plan(role: role, port: 0)
        assert {:ok, %{ip: {127, 0, 0, 1}}} = Network.plan(role: role, ip: {127, 0, 0, 1})
      end
    end

    test "every other address is refused as {:not_loopback, ip}, strings included" do
      for ip <- [
            {0, 0, 0, 0},
            {0, 0, 0, 0, 0, 0, 0, 0},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {192, 168, 1, 10},
            {127, 0, 0, 2},
            "127.0.0.1",
            ~c"127.0.0.1"
          ],
          role <- [:listen, :connect] do
        assert {:error, {:not_loopback, ^ip}} = Network.plan(role: role, ip: ip)
      end
    end

    test "the endpoint's refusal is the same and comes before any socket call", %{c: c} do
      Process.flag(:trap_exit, true)

      for role <- [:listen, :connect] do
        assert {:error, {:not_loopback, {192, 168, 1, 10}}} =
                 start(c, role: role, ip: {192, 168, 1, 10}, port: 0)
      end

      refute_received {:nonet_listen, _, _}
      refute_received {:nonet_connect, _, _, _, _}
    end

    test "the same call site: a loopback listener asks for exactly 127.0.0.1", %{c: c} do
      Process.flag(:trap_exit, true)

      assert {:error, {:listen_failed, :injected_no_network}} =
               start(c, role: :listen, port: 0)

      # since the M7-L1 correction the loopback listener accepts TCP itself as the profile's does:
      # its listen call carries socket options only (the TLS options go to the upgrade)
      assert_received {:nonet_listen, 0, opts}
      assert for({:ip, v} <- opts, do: v) == [{127, 0, 0, 1}]
      assert :binary in opts and {:active, false} in opts and {:backlog, 2} in opts
      assert for({k, _} when k in [:cert, :key, :cacerts] <- opts, do: k) == []
    end
  end

  describe "the lan_ipv4 profile: accepted plans" do
    test "a headless listener with its initiator; a connector with its destination" do
      assert {:ok,
              %{
                profile: :lan_ipv4,
                role: :listen,
                ip: {192, 168, 1, 20},
                port: 4760,
                initiator: {192, 168, 1, 10},
                prefix_length: 24
              } = l} = plan(:listen, listen_net({192, 168, 1, 20}))

      assert Network.describe(l) == "lan_ipv4 192.168.1.20:4760/24, initiator 192.168.1.10"

      assert {:ok, %{role: :connect, ip: {192, 168, 1, 20}, port: 4760, initiator: nil} = c} =
               plan(:connect, connect_net({192, 168, 1, 20}))

      assert Network.describe(c) == "lan_ipv4 192.168.1.20:4760/24"
    end

    test "strict dotted quads, maps, the three private ranges, 127.0.0.1 and the port bounds" do
      assert {:ok, %{ip: {192, 168, 1, 20}, initiator: {192, 168, 1, 10}}} =
               plan(:listen, listen_net("192.168.1.20", 4760, ~c"192.168.1.10"))

      assert {:ok, %{ip: {10, 1, 2, 3}}} =
               plan(:connect, Map.new(connect_net({10, 1, 2, 3}, 1024, 8)))

      assert {:ok, %{ip: {172, 16, 4, 2}}} =
               plan(:connect, connect_net({172, 16, 4, 2}, 65_535, 12))

      assert {:ok, %{ip: {172, 31, 255, 254}}} =
               plan(:connect, connect_net({172, 31, 255, 254}, 4760, 12))

      assert {:ok, %{ip: {127, 0, 0, 1}, initiator: {127, 0, 0, 1}}} =
               plan(:listen, listen_net({127, 0, 0, 1}, 4760, {127, 0, 0, 1}, 8))

      assert {:ok, _} = plan(:connect, connect_net({127, 0, 0, 1}, 4760, 8))
    end

    test "an accepted connect profile makes exactly the declared call, once, with the TLS policy",
         %{c: c} do
      {:ok, ep} =
        start(c,
          role: :connect,
          network: connect_net({192, 168, 1, 20}),
          local: @game,
          expected: @headless
        )

      assert_receive {:nonet_connect, {192, 168, 1, 20}, 4760, opts, 5_000}, 1_000
      assert opts[:versions] == [:"tlsv1.3"] and opts[:verify] == :verify_peer
      assert opts[:server_name_indication] == :disable and opts[:session_tickets] == :disabled
      refute Keyword.has_key?(opts, :ip)
      wait(fn -> Endpoint.status(ep).counts.connect_failures == 1 end)
      # no reconnect unless asked
      refute_receive {:nonet_connect, _, _, _, _}, 300

      assert %{address: {{192, 168, 1, 20}, 4760}, network: "lan_ipv4 192.168.1.20:4760/24"} =
               Endpoint.status(ep)

      GenServer.stop(ep)
    end

    test "an accepted listen profile binds exactly the declared address and port — no wildcard",
         %{c: c} do
      Process.flag(:trap_exit, true)

      assert {:error, {:listen_failed, :injected_no_network}} =
               start(c, role: :listen, network: listen_net({192, 168, 1, 20}))

      # the profile listener accepts TCP itself: its listen call carries socket options only
      assert_received {:nonet_listen, 4760, opts}
      assert for({:ip, v} <- opts, do: v) == [{192, 168, 1, 20}]
      assert :binary in opts and {:active, false} in opts and {:backlog, 2} in opts
      refute inspect(opts, limit: :infinity) =~ "{0, 0, 0, 0}"
      assert for({k, _} when k in [:cert, :key, :cacerts] <- opts, do: k) == []
    end

    test "the upgrade carries the unchanged TLS policy (pure)", %{c: c} do
      {:ok, creds} = GlacierRelay.Peer.TLS.credentials(fn -> c.headless end)
      up = GlacierRelay.Peer.TLS.upgrade_options(creds)
      listen = GlacierRelay.Peer.TLS.listen_options(creds, {127, 0, 0, 1})

      for k <- [
            :versions,
            :verify,
            :cacerts,
            :cert,
            :key,
            :verify_fun,
            :session_tickets,
            :fail_if_no_peer_cert
          ] do
        assert up[k] == listen[k], inspect(k)
      end

      assert up[:versions] == [:"tlsv1.3"] and up[:fail_if_no_peer_cert] == true
      refute Keyword.has_key?(up, :ip) or Keyword.has_key?(up, :reuseaddr)
    end
  end

  describe "the lan_ipv4 profile: refusals (pure, and before any socket)" do
    test "addresses outside the private unicast ranges" do
      for {ip, why} <- [
            {{0, 0, 0, 0}, :unspecified},
            {{0, 1, 2, 3}, :unspecified},
            {{127, 0, 0, 2}, :loopback_other_than_127_0_0_1},
            {{127, 1, 1, 1}, :loopback_other_than_127_0_0_1},
            {{224, 0, 0, 1}, :multicast},
            {{239, 255, 255, 250}, :multicast},
            {{255, 255, 255, 255}, :limited_broadcast},
            {{240, 0, 0, 1}, :reserved},
            {{169, 254, 1, 1}, :link_local},
            {{8, 8, 8, 8}, :not_private},
            {{100, 64, 0, 1}, :not_private},
            {{192, 0, 2, 1}, :not_private},
            {{172, 15, 0, 1}, :not_private},
            {{172, 32, 0, 1}, :not_private},
            {{192, 169, 0, 1}, :not_private}
          ] do
        assert {^why, ^ip} = refused(:connect, connect_net(ip)), inspect(ip)
        assert {^why, ^ip} = refused(:listen, listen_net(ip)), inspect(ip)
      end
    end

    test "the network address and the directed broadcast of the declared prefix" do
      assert {:network_address, {192, 168, 1, 0}, 24} =
               refused(:connect, connect_net({192, 168, 1, 0}))

      assert {:subnet_broadcast, {192, 168, 1, 255}, 24} =
               refused(:connect, connect_net({192, 168, 1, 255}))

      assert {:subnet_broadcast, {10, 255, 255, 255}, 8} =
               refused(:connect, connect_net({10, 255, 255, 255}, 4760, 8))

      assert {:network_address, {10, 1, 0, 0}, 16} =
               refused(:connect, connect_net({10, 1, 0, 0}, 4760, 16))

      # the same address is an ordinary host under a wider prefix
      assert {:ok, _} = plan(:connect, connect_net({192, 168, 1, 255}, 4760, 16))

      assert {:subnet_broadcast, {192, 168, 1, 255}, 24} =
               refused(:listen, listen_net({192, 168, 1, 20}, 4760, {192, 168, 1, 255}))
    end

    test "malformed addresses, hostnames and IPv6" do
      for a <- [
            "192.168.1",
            "192.168.001.020",
            "192.168.1.2 ",
            " 192.168.1.2",
            "mac.local",
            "localhost",
            "0x7f.0.0.1",
            {256, 0, 0, 1},
            {1, 2, 3},
            :any,
            nil,
            ~c"abc",
            <<0xFF, 0xFE>>
          ] do
        assert {:malformed_address, ^a} = refused(:connect, connect_net(a)), inspect(a)
      end

      for a <- [{0, 0, 0, 0, 0, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 0}, "::1", "::", "fe80::1"] do
        assert {:unsupported_family, :inet6} = refused(:connect, connect_net(a)), inspect(a)

        assert {:unsupported_family, :inet6} =
                 refused(:listen, listen_net({192, 168, 1, 20}, 4760, a))
      end
    end

    test "ports and prefix lengths" do
      for p <- [0, 80, 1023, 65_536, -1, "4760", nil, 4760.0] do
        assert {:invalid_port, ^p} = refused(:connect, connect_net({192, 168, 1, 20}, p)),
               inspect(p)

        assert {:invalid_port, ^p} = refused(:listen, listen_net({192, 168, 1, 20}, p))
      end

      for p <- [nil, 7, 31, 32, 0, "24", 24.0] do
        assert {:invalid_prefix_length, ^p} =
                 refused(:connect, Keyword.put(connect_net({192, 168, 1, 20}), :prefix_length, p))
      end
    end

    test "the role, the shape and the declaration" do
      ip = {192, 168, 1, 20}
      assert {:role_mismatch, :connect} = refused(:connect, listen_net(ip))
      assert {:role_mismatch, :listen} = refused(:listen, connect_net(ip))

      assert :listen_and_connect_both_given =
               refused(:listen, listen_net(ip) ++ [connect: {ip, 4760}])

      assert {:no_socket_for_role, :connect} =
               refused(:connect, profile: :lan_ipv4, prefix_length: 24)

      assert :initiator_missing = refused(:listen, Keyword.delete(listen_net(ip), :initiator))

      assert :initiator_given_to_a_connector =
               refused(:connect, connect_net(ip) ++ [initiator: {192, 168, 1, 10}])

      assert {:initiator_outside_prefix, {192, 168, 2, 10}, 24} =
               refused(:listen, listen_net(ip, 4760, {192, 168, 2, 10}))

      assert {:initiator_outside_prefix, {127, 0, 0, 1}, 24} =
               refused(:listen, listen_net(ip, 4760, {127, 0, 0, 1}))

      assert {:initiator_is_the_listener, ^ip} = refused(:listen, listen_net(ip, 4760, ip))

      assert {:malformed_socket, ^ip} =
               refused(:connect, Keyword.put(connect_net(ip), :connect, ip))

      assert :address_given_twice = refused(:connect, connect_net(ip), ip: ip)
      assert :address_given_twice = refused(:connect, connect_net(ip), port: 4760)
      assert {:unknown_option, :bind_any} = refused(:connect, connect_net(ip) ++ [bind_any: true])

      for p <- [:lan_ipv6, "lan_ipv4", nil, :loopback] do
        assert {:unsupported_profile, ^p} =
                 refused(:connect, Keyword.put(connect_net(ip), :profile, p))
      end

      for net <- [:lan, "lan_ipv4", [1, 2], connect_net(ip) ++ [prefix_length: 16]] do
        assert :not_a_profile = refused(:connect, net), inspect(net)
      end
    end

    test "only a headless endpoint may listen under the profile" do
      net = listen_net({192, 168, 1, 20})

      assert {:error, {:network_profile, {:listener_must_be_headless, "game"}}} =
               Network.plan(role: :listen, network: net, local: @game)

      assert {:error, {:network_profile, {:listener_must_be_headless, nil}}} =
               Network.plan(role: :listen, network: net)

      assert {:ok, _} =
               Network.plan(role: :connect, network: connect_net({192, 168, 1, 20}), local: @game)
    end

    test "the endpoint stops with the refusal before any socket call", %{c: c} do
      Process.flag(:trap_exit, true)

      for {role, net, local} <- [
            {:listen, listen_net({0, 0, 0, 0}), @headless},
            {:listen, listen_net({192, 168, 1, 255}), @headless},
            {:listen, listen_net({192, 168, 1, 20}), @game},
            {:connect, connect_net({224, 0, 0, 1}), @game},
            {:connect, connect_net("::1"), @game},
            {:connect, connect_net({192, 168, 1, 20}, 0), @game},
            {:connect, listen_net({192, 168, 1, 20}), @game}
          ] do
        assert {:error, {:network_profile, _}} = start(c, role: role, network: net, local: local)
      end

      assert {:error, {:network_profile, :address_given_twice}} =
               start(c,
                 role: :connect,
                 network: connect_net({192, 168, 1, 20}),
                 port: 0,
                 local: @game
               )

      refute_received {:nonet_listen, _, _}
      refute_received {:nonet_connect, _, _, _, _}
    end
  end

  describe "admission and socket checks" do
    test "under the profile only the initiator is admitted; B1's plan admits as before" do
      {:ok, l} = plan(:listen, listen_net({192, 168, 1, 20}))
      assert Network.initiator_allowed?(l, {192, 168, 1, 10})
      refute Network.initiator_allowed?(l, {192, 168, 1, 11})
      refute Network.initiator_allowed?(l, {192, 168, 1, 20})
      {:ok, b1} = Network.plan(role: :listen)
      assert Network.initiator_allowed?(b1, {127, 0, 0, 1})
    end

    test "a bound or contacted socket other than the declared one is a profile refusal" do
      {:ok, c} = plan(:connect, connect_net({192, 168, 1, 20}))
      assert :ok = Network.check_socket(c, :peer, {:ok, {{192, 168, 1, 20}, 4760}})

      assert {:error, {:network_profile, {:peer_mismatch, {:ok, {{192, 168, 1, 21}, 4760}}}}} =
               Network.check_socket(c, :peer, {:ok, {{192, 168, 1, 21}, 4760}})

      assert {:error, {:network_profile, {:bound_mismatch, {:ok, {{0, 0, 0, 0}, 4760}}}}} =
               Network.check_socket(c, :bound, {:ok, {{0, 0, 0, 0}, 4760}})

      assert {:error, {:network_profile, {:peer_mismatch, {:error, :enotconn}}}} =
               Network.check_socket(c, :peer, {:error, :enotconn})

      {:ok, b1} = Network.plan(role: :listen, port: 0)
      assert :ok = Network.check_socket(b1, :bound, {:ok, {{127, 0, 0, 1}, 40_001}})
    end
  end
end
