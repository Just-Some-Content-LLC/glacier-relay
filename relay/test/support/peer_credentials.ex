defmodule GlacierRelay.Test.PeerCredentials do
  @moduledoc """
  M7-B1 test support: throwaway per-test TLS credentials for the peer link, generated with the
  installed OTP's `:public_key` test-data functions (ECDSA P-256, SHA-256). Each side gets its own
  private CA and a leaf issued by it; a side's `Peer.TLS.credentials/1` input trusts the other
  side's CA and pins the other side's leaf. Nothing here is a real credential, nothing is written
  outside a test-owned temporary directory, and no private key is ever printed.
  """

  alias GlacierRelay.Peer.TLS

  @conf [key: {:namedCurve, :secp256r1}, digest: :sha256]

  @doc "A fresh root CA (`%{cert: der, key: key}`)."
  def root(name), do: :public_key.pkix_test_root_cert(String.to_charlist(name), @conf)

  @doc "A leaf issued by `root` (`%{cert: der, key: {type, der}}`)."
  def leaf(root) do
    other = root("throwaway-other-#{System.unique_integer([:positive])}")

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{root: root, intermediates: [], peer: @conf},
        client_chain: %{root: other, intermediates: [], peer: @conf}
      })

    cfg = Map.new(data.server_config)
    %{cert: cfg.cert, key: cfg.key}
  end

  @doc """
  A matched pair: `%{host: opts, headless: opts, host_leaf: leaf, headless_leaf: leaf, host_root:
  root, headless_root: root}` where each `opts` is a `Peer.TLS.credentials/1` keyword list.
  """
  def pair do
    host_root = root("throwaway-host-ca-#{System.unique_integer([:positive])}")
    headless_root = root("throwaway-headless-ca-#{System.unique_integer([:positive])}")
    host_leaf = leaf(host_root)
    headless_leaf = leaf(headless_root)

    %{
      host: opts(host_leaf, headless_root, headless_leaf),
      headless: opts(headless_leaf, host_root, host_leaf),
      host_leaf: host_leaf,
      headless_leaf: headless_leaf,
      host_root: host_root,
      headless_root: headless_root
    }
  end

  @doc "`Peer.TLS.credentials/1` options: present `own`, trust `peer_root`, pin `peer_leaf`."
  def opts(own, peer_root, peer_leaf),
    do: [cert: own.cert, key: own.key, peer_ca: peer_root.cert, peer_pin: TLS.pin(peer_leaf.cert)]

  @doc "Writes `opts` as PEM files under `dir` (0600) and returns the file-based options."
  def write_files(opts, dir, prefix) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    cert = Path.join(dir, "#{prefix}-cert.pem")
    key = Path.join(dir, "#{prefix}-key.pem")
    ca = Path.join(dir, "#{prefix}-peer-ca.pem")
    {type, der} = opts[:key]
    write(cert, :public_key.pem_encode([{:Certificate, opts[:cert], :not_encrypted}]))
    write(key, :public_key.pem_encode([{type, der, :not_encrypted}]))
    write(ca, :public_key.pem_encode([{:Certificate, opts[:peer_ca], :not_encrypted}]))
    [cert_file: cert, key_file: key, peer_ca_file: ca, peer_pin: opts[:peer_pin]]
  end

  defp write(path, bytes) do
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
  end
end
