# M7-L1 — per-machine, per-run peer-link credentials (operator tooling; README.md). Run with the machine's own `elixir`, with the
# bundle on the code path (`elixir -pa <bundle>/ebin/glacier_relay <bundle>/kit/creds.exs ...`), from the kit's own directory.
#
#   creds.exs generate <state-dir> <side>                          a NEW <state-dir>/creds-<side>/ (0700): this machine's own private CA
#                                                                  and a leaf it issued (ECDSA P-256 / SHA-256, OTP :public_key test-data
#                                                                  functions, short validity); writes own-cert.pem and own-key.pem (0600),
#                                                                  own-ca.pem and own-identity.json (PUBLIC: the CA certificate, the leaf
#                                                                  pin and the CA digest). The CA's private key is never written: it exists
#                                                                  only in this process, so no later leaf can be issued under that CA.
#   creds.exs import <state-dir> <side> <peer-ca.pem> <peer-identity.json>
#                                                                  copies the OTHER machine's public CA certificate into the creds
#                                                                  directory (peer-ca.pem) and records its leaf pin (peer.json), after
#                                                                  checking the CA parses, is self-issued and matches the identity's
#                                                                  digest; prints the digest and the pin for comparison over a second
#                                                                  channel. Refuses an existing peer-ca.pem.
#
# Only the two PUBLIC files (own-ca.pem, own-identity.json) ever leave a machine. Private keys never do; none is ever printed.
# The run configuration then names own-cert.pem, own-key.pem, peer-ca.pem and the pin from peer.json. These are disposable
# credentials for one transport test, never the run token and never shared with any other run; the cleanup removes them
# (a logical deletion, not secure erasure).
alias GlacierRelay.Peer.TLS

defmodule Creds do
  @moduledoc false
  @conf [key: {:namedCurve, :secp256r1}, digest: :sha256]
  def say(msg), do: IO.puts("#{DateTime.utc_now() |> DateTime.to_iso8601()} creds: #{msg}")
  def fail(msg), do: (IO.puts("creds: REFUSED: #{msg}"); System.halt(2))
  def side!(s), do: (Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,31}\z/, s) || fail("side must match [a-z0-9][a-z0-9-]{0,31}"); s)
  def sha(der), do: :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)

  def write(path, bytes, mode) do
    :ok = File.write(path, bytes, [:exclusive])
    File.chmod!(path, mode)
  end

  def pem(entries), do: :public_key.pem_encode(entries)

  def generate(state, side) do
    side = side!(side)
    unless File.dir?(state) and Path.type(state) == :absolute, do: fail("the state directory must be an existing absolute directory")
    dir = Path.join(state, "creds-#{side}")
    if File.exists?(dir), do: fail("#{dir} already exists (one creds directory per run and side)")
    :ok = File.mkdir(dir)
    File.chmod!(dir, 0o700)
    tag = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    root = :public_key.pkix_test_root_cert(~c"glacier-relay-peer-transport-#{side}-ca-#{tag}", @conf)
    # a leaf issued by `root`: the server chain of the test-data generator (its other chain is discarded)
    other = :public_key.pkix_test_root_cert(~c"discarded-#{tag}", @conf)
    data = :public_key.pkix_test_data(%{server_chain: %{root: root, intermediates: [], peer: @conf},
                                        client_chain: %{root: other, intermediates: [], peer: @conf}})
    leaf = Map.new(data.server_config)
    {ktype, kder} = leaf.key
    write(Path.join(dir, "own-cert.pem"), pem([{:Certificate, leaf.cert, :not_encrypted}]), 0o600)
    write(Path.join(dir, "own-key.pem"), pem([{ktype, kder, :not_encrypted}]), 0o600)
    write(Path.join(dir, "own-ca.pem"), pem([{:Certificate, root.cert, :not_encrypted}]), 0o644)
    otp = :public_key.pkix_decode_cert(leaf.cert, :otp)
    {:Validity, nb, na} = elem(elem(otp, 1), 5)

    identity = %{
      "schema" => "glacier-relay.peer-transport-identity/1",
      "side" => side,
      "leaf_pin" => TLS.pin(leaf.cert),
      "ca_sha256" => sha(root.cert),
      "leaf_not_before" => inspect(nb),
      "leaf_not_after" => inspect(na),
      "created_utc" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "otp" => System.otp_release(),
      "note" => "PUBLIC: this side's leaf pin and CA digest; send this file and own-ca.pem to the other side. The CA private key was never written."
    }

    write(Path.join(dir, "own-identity.json"), JSON.encode!(identity) <> "\n", 0o644)
    say("generated #{dir}: own leaf pin #{identity["leaf_pin"]}, own CA sha256 #{identity["ca_sha256"]} (validity #{inspect(nb)} .. #{inspect(na)}); public files: own-ca.pem, own-identity.json")
    IO.puts("CREDS GENERATED")
  end

  def import(state, side, ca_file, identity_file) do
    side = side!(side)
    dir = Path.join(state, "creds-#{side}")
    unless File.dir?(dir), do: fail("no #{dir}: generate this side's credentials first")
    if File.exists?(Path.join(dir, "peer-ca.pem")), do: fail("#{dir}/peer-ca.pem already exists")

    der =
      case :public_key.pem_decode(File.read!(ca_file)) do
        [{:Certificate, der, :not_encrypted}] -> der
        _ -> fail("#{ca_file} is not exactly one PEM certificate")
      end

    cert = :public_key.pkix_decode_cert(der, :otp)
    unless :public_key.pkix_is_self_signed(cert), do: fail("the peer CA certificate is not self-issued")
    id = File.read!(identity_file) |> JSON.decode!()
    unless id["schema"] == "glacier-relay.peer-transport-identity/1", do: fail("not a peer-transport identity file")
    unless id["ca_sha256"] == sha(der), do: fail("the CA certificate's digest #{sha(der)} differs from the identity's #{inspect(id["ca_sha256"])}")
    unless TLS.pin?(id["leaf_pin"]), do: fail("the identity's leaf pin is not 64 lowercase hex characters")
    if id["side"] == side, do: fail("the identity is this side's own (#{side})")
    write(Path.join(dir, "peer-ca.pem"), pem([{:Certificate, der, :not_encrypted}]), 0o644)
    write(Path.join(dir, "peer.json"), JSON.encode!(%{"peer_side" => id["side"], "peer_leaf_pin" => id["leaf_pin"], "peer_ca_sha256" => id["ca_sha256"]}) <> "\n", 0o644)
    # this side's own files load together with the peer's: the same validation the endpoint runs at start
    {:ok, c} = TLS.credentials(cert_file: Path.join(dir, "own-cert.pem"), key_file: Path.join(dir, "own-key.pem"),
                               peer_ca_file: Path.join(dir, "peer-ca.pem"), peer_pin: id["leaf_pin"])
    say("imported the #{id["side"]} side into #{dir}: peer CA sha256 #{id["ca_sha256"]}, pinned peer leaf #{id["leaf_pin"]} (compare both over a second channel); own leaf #{c.own_pin}")
    IO.puts("CREDS IMPORTED")
  end
end

case System.argv() do
  ["generate", state, side] -> Creds.generate(state, side)
  ["import", state, side, ca, id] -> Creds.import(state, side, ca, id)
  _ -> Creds.fail("usage: creds.exs generate <state-dir> <side> | import <state-dir> <side> <peer-ca.pem> <peer-identity.json>")
end
