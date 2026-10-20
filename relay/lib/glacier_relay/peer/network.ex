defmodule GlacierRelay.Peer.Network do
  @moduledoc """
  M7-L1: the peer endpoint's address policy (`docs/design/M7_NETWORK_GHOST.md` section 20; ADR 0010
  amendment 14). Pure: it validates the endpoint's options and returns the one socket the endpoint
  may bind or contact; nothing here opens, binds, resolves or contacts anything.

  **Default (no `:network` option): B1's loopback rule, unchanged.** `:ip` defaults to `{127, 0, 0, 1}`
  and anything else is refused as `{:not_loopback, ip}` (`Peer.TLS.bind_allowed?/1`); `:port`
  defaults to 4760 and is passed through as before (0 picks one when listening).

  **The one opt-in profile, `lan_ipv4`**, names one concrete IPv4 socket for the endpoint's role:

      network: [profile: :lan_ipv4, prefix_length: 24, listen: {{192, 168, 1, 20}, 4760},
                initiator: {192, 168, 1, 10}]                     # a headless listener
      network: [profile: :lan_ipv4, prefix_length: 24, connect: {{192, 168, 1, 20}, 4760}]

  - the role in the profile (`listen` or `connect`) must be the endpoint's role, and `:ip` / `:port`
    must not be given as well (one declaration, no fallback);
  - an address is a 4-tuple or a strict dotted quad (`:inet.parse_ipv4strict_address/1`): no
    hostname, no resolution, no shorthand, no IPv6 (`{:unsupported_family, :inet6}`);
  - allowed: `127.0.0.1` (owned local tests and rehearsals of the same wiring) and RFC 1918 private
    unicast; refused: 0/8, the rest of 127/8, multicast, reserved, the limited broadcast,
    link-local and every other range;
  - `prefix_length` (8–30) is declared, never discovered: the network address and the directed
    broadcast of the prefix are refused, the initiator must lie inside the listener's prefix, and a
    private initiator may not be the listener's own address;
  - ports 1024–65535 only (no 0, no privileged port);
  - only a `client_kind: "headless"` endpoint may listen under the profile (the game host only
    connects out).

  Every refusal of the profile is `{:network_profile, reason}`. An allowed address is never
  authentication: TLS, the pins and the `hello` rules apply unchanged (`Peer.TLS`,
  `Peer.Connection`).
  """

  import Bitwise

  alias GlacierRelay.Peer.TLS

  @keys [:profile, :prefix_length, :listen, :connect, :initiator]

  @type plan :: %{
          profile: :loopback | :lan_ipv4,
          role: :listen | :connect,
          ip: :inet.ip4_address(),
          port: non_neg_integer(),
          initiator: :inet.ip4_address() | nil,
          prefix_length: 8..30 | nil
        }

  @doc """
  The endpoint's socket plan from its options (`:role` already checked): `{:ok, plan}` or
  `{:error, reason}`.
  """
  def plan(opts) when is_list(opts) do
    role = Keyword.fetch!(opts, :role)

    case Keyword.get(opts, :network) do
      nil -> loopback(opts, role)
      net -> lan(net, opts, role)
    end
  end

  defp loopback(opts, role) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})

    if TLS.bind_allowed?(ip),
      do:
        {:ok,
         %{
           profile: :loopback,
           role: role,
           ip: ip,
           port: Keyword.get(opts, :port, 4760),
           initiator: nil,
           prefix_length: nil
         }},
      else: {:error, {:not_loopback, ip}}
  end

  defp lan(net, opts, role) do
    with {:ok, net} <- options(net),
         :ok <- given_once(opts),
         :ok <- profile(net),
         {:ok, p} <- prefix_length(Map.get(net, :prefix_length)),
         {:ok, {ip, port}} <- socket(net, role),
         :ok <- usable(ip, p),
         {:ok, initiator} <- initiator(net, role, ip, p),
         :ok <- kind(role, Keyword.get(opts, :local)) do
      {:ok,
       %{
         profile: :lan_ipv4,
         role: role,
         ip: ip,
         port: port,
         initiator: initiator,
         prefix_length: p
       }}
    else
      {:error, reason} -> {:error, {:network_profile, reason}}
    end
  end

  defp options(net) when is_map(net), do: known(net)

  defp options(net) when is_list(net) do
    if Keyword.keyword?(net) and length(Keyword.keys(net) |> Enum.uniq()) == length(net),
      do: known(Map.new(net)),
      else: {:error, :not_a_profile}
  end

  defp options(_), do: {:error, :not_a_profile}

  defp known(net) do
    case Enum.find(Map.keys(net), &(&1 not in @keys)) do
      nil -> {:ok, net}
      k -> {:error, {:unknown_option, k}}
    end
  end

  defp given_once(opts) do
    if Keyword.has_key?(opts, :ip) or Keyword.has_key?(opts, :port),
      do: {:error, :address_given_twice},
      else: :ok
  end

  defp profile(%{profile: :lan_ipv4}), do: :ok
  defp profile(net), do: {:error, {:unsupported_profile, Map.get(net, :profile)}}

  defp prefix_length(p) when is_integer(p) and p >= 8 and p <= 30, do: {:ok, p}
  defp prefix_length(p), do: {:error, {:invalid_prefix_length, p}}

  defp socket(net, role) do
    case {role, Map.has_key?(net, :listen), Map.has_key?(net, :connect)} do
      {:listen, true, false} -> endpoint_socket(net.listen)
      {:connect, false, true} -> endpoint_socket(net.connect)
      {_, false, false} -> {:error, {:no_socket_for_role, role}}
      {_, true, true} -> {:error, :listen_and_connect_both_given}
      _ -> {:error, {:role_mismatch, role}}
    end
  end

  defp endpoint_socket({address, port}) do
    with {:ok, ip} <- address(address),
         :ok <- port(port),
         do: {:ok, {ip, port}}
  end

  defp endpoint_socket(other), do: {:error, {:malformed_socket, other}}

  defp port(p) when is_integer(p) and p >= 1024 and p <= 65_535, do: :ok
  defp port(p), do: {:error, {:invalid_port, p}}

  defp initiator(net, :listen, ip, p) do
    with {:ok, address} <- Map.fetch(net, :initiator) |> or_missing(),
         {:ok, init} <- address(address),
         :ok <- usable(init, p),
         :ok <- inside(init, ip, p),
         :ok <- not_self(init, ip) do
      {:ok, init}
    end
  end

  defp initiator(net, :connect, _ip, _p) do
    if Map.has_key?(net, :initiator),
      do: {:error, :initiator_given_to_a_connector},
      else: {:ok, nil}
  end

  defp or_missing(:error), do: {:error, :initiator_missing}
  defp or_missing(ok), do: ok

  defp kind(:listen, local) do
    case local && Map.new(local)[:client_kind] do
      "headless" -> :ok
      other -> {:error, {:listener_must_be_headless, other}}
    end
  end

  defp kind(:connect, _local), do: :ok

  @doc """
  Parses one IPv4 address: a 4-tuple of 0..255, or a strict dotted quad (string or charlist).
  `{:ok, ip}` or `{:error, reason}`.
  """
  def address({a, b, c, d} = ip) when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
    do: {:ok, ip}

  def address(ip) when is_tuple(ip) and tuple_size(ip) == 8,
    do: {:error, {:unsupported_family, :inet6}}

  def address(s) when is_binary(s) do
    if String.valid?(s),
      do: parse(String.to_charlist(s), s),
      else: {:error, {:malformed_address, s}}
  end

  def address(s) when is_list(s) do
    if Enum.all?(s, &(is_integer(&1) and &1 in 0..0x10FFFF)),
      do: parse(s, s),
      else: {:error, {:malformed_address, s}}
  end

  def address(other), do: {:error, {:malformed_address, other}}

  defp parse(chars, original) do
    case :inet.parse_ipv4strict_address(chars) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _} ->
        case :inet.parse_ipv6strict_address(chars) do
          {:ok, _} -> {:error, {:unsupported_family, :inet6}}
          {:error, _} -> {:error, {:malformed_address, original}}
        end
    end
  end

  @doc "The class of an IPv4 address under the profile: `:loopback`, `:private` or `{:refused, why}`."
  def class({127, 0, 0, 1}), do: :loopback
  def class({127, _, _, _}), do: {:refused, :loopback_other_than_127_0_0_1}
  def class({0, _, _, _}), do: {:refused, :unspecified}
  def class({255, 255, 255, 255}), do: {:refused, :limited_broadcast}
  def class({a, _, _, _}) when a in 224..239, do: {:refused, :multicast}
  def class({a, _, _, _}) when a >= 240, do: {:refused, :reserved}
  def class({169, 254, _, _}), do: {:refused, :link_local}
  def class({10, _, _, _}), do: :private
  def class({172, b, _, _}) when b in 16..31, do: :private
  def class({192, 168, _, _}), do: :private
  def class(_), do: {:refused, :not_private}

  defp usable(ip, p) do
    case class(ip) do
      {:refused, why} ->
        {:error, {why, ip}}

      _ ->
        n = int(ip)
        mask = mask(p)

        cond do
          n == band(n, mask) ->
            {:error, {:network_address, ip, p}}

          n == bor(band(n, mask), band(bnot(mask), 0xFFFFFFFF)) ->
            {:error, {:subnet_broadcast, ip, p}}

          true ->
            :ok
        end
    end
  end

  defp inside(init, ip, p) do
    if band(int(init), mask(p)) == band(int(ip), mask(p)),
      do: :ok,
      else: {:error, {:initiator_outside_prefix, init, p}}
  end

  defp not_self(ip, ip) when ip != {127, 0, 0, 1}, do: {:error, {:initiator_is_the_listener, ip}}
  defp not_self(_init, _ip), do: :ok

  defp int({a, b, c, d}), do: bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d
  defp mask(p), do: band(bsl(0xFFFFFFFF, 32 - p), 0xFFFFFFFF)

  @doc "Whether an accepted connection's remote address may proceed to the TLS handshake."
  def initiator_allowed?(%{profile: :loopback}, _remote_ip), do: true
  def initiator_allowed?(%{profile: :lan_ipv4, initiator: ip}, remote_ip), do: remote_ip == ip

  @doc """
  The bound or contacted socket against the plan: `:ok`, or `{:error, reason}` when a profile's
  socket is not exactly the declared one (B1's loopback plan accepts any port, as before).
  """
  def check_socket(%{profile: :loopback}, _which, _socket), do: :ok

  def check_socket(%{profile: :lan_ipv4, ip: ip, port: port}, _which, {:ok, {ip, port}}), do: :ok

  def check_socket(%{profile: :lan_ipv4}, which, other),
    do: {:error, {:network_profile, {:"#{which}_mismatch", other}}}

  @doc "One line for logs and status (no credential)."
  def describe(%{profile: :loopback}), do: "loopback"

  def describe(%{profile: :lan_ipv4, role: :listen} = p),
    do:
      "lan_ipv4 #{:inet.ntoa(p.ip)}:#{p.port}/#{p.prefix_length}, initiator #{:inet.ntoa(p.initiator)}"

  def describe(%{profile: :lan_ipv4, role: :connect} = p),
    do: "lan_ipv4 #{:inet.ntoa(p.ip)}:#{p.port}/#{p.prefix_length}"
end
