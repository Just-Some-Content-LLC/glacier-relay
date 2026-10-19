defmodule GlacierRelay.Peer.TLS do
  @moduledoc """
  M7-B1: the peer link's TLS policy (`docs/design/M7_NETWORK_GHOST.md` section 15.7; ADR 0010 as
  amended, decision 6). TLS 1.3 only, mutual: each side presents a leaf certificate issued by its
  own per-experiment private CA, trusts **exactly** the other side's CA (`cacerts`), requires the
  other side's certificate (`fail_if_no_peer_cert`) and pins the other side's leaf — the SHA-256 of
  its DER, lowercase hex. The verification callback only narrows OTP's verdict: it never overrides
  a `bad_cert` (an unknown issuer, an expired, a self-signed or a malformed certificate fail as OTP
  decides), lets OTP judge extensions, and accepts the peer leaf (`valid_peer`) only on the exact
  pin; the pin is checked again on the DER the connection actually received (`check_peer/2`).
  There is no trust on first use, no session resumption, no early data and no hostname check (the
  pin is the identity).

  Credentials (`credentials/1`): `:cert` (the leaf's DER), `:key` (an `{:ECPrivateKey | :RSAPrivateKey
  | :PrivateKeyInfo, der}` tuple), `:peer_ca` (the other side's CA certificate, DER) and `:peer_pin`;
  or the same as files (`:cert_file`, `:key_file`, `:peer_ca_file`, PEM), or a 0-arity function
  returning either. Private keys are never logged or returned by any status function, and the
  endpoint's state is redacted in crash reports.

  B1 binds loopback only: `bind_allowed?/1` accepts `{127, 0, 0, 1}` and nothing else — not
  `{0, 0, 0, 0}`, not `::`, not a LAN address.
  """

  @pin ~r/^[0-9a-f]{64}$/
  @handshake_timeout_ms 5_000

  def handshake_timeout_ms, do: @handshake_timeout_ms

  @doc "B1's bind policy: loopback IPv4 only."
  def bind_allowed?({127, 0, 0, 1}), do: true
  def bind_allowed?(_), do: false

  @doc "The pin of a certificate's DER: SHA-256, lowercase hex."
  def pin(der) when is_binary(der), do: :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)

  def pin?(value), do: is_binary(value) and Regex.match?(@pin, value)

  @doc """
  Loads and validates credentials; `{:ok, creds}` or `{:error, reason}` (never the key). `opts` may
  be a 0-arity function returning them, so that no child specification or crash report carries the
  material itself.
  """
  def credentials(fun) when is_function(fun, 0), do: credentials(fun.())

  def credentials(opts) when is_list(opts) or is_map(opts) do
    opts = Map.new(opts)

    with {:ok, cert} <- der(opts, :cert, :cert_file, :Certificate),
         {:ok, key} <- key(opts),
         {:ok, ca} <- der(opts, :peer_ca, :peer_ca_file, :Certificate),
         pin when is_binary(pin) <- Map.get(opts, :peer_pin),
         true <- pin?(pin) or {:error, :peer_pin_invalid} do
      {:ok, %{cert: cert, key: key, peer_ca: ca, peer_pin: pin, own_pin: pin(cert)}}
    else
      nil -> {:error, :peer_pin_missing}
      {:error, _} = error -> error
    end
  end

  defp der(opts, key, file_key, type) do
    cond do
      is_binary(Map.get(opts, key)) ->
        {:ok, Map.fetch!(opts, key)}

      is_binary(Map.get(opts, file_key)) ->
        with {:ok, pem} <- File.read(Map.fetch!(opts, file_key)),
             [{^type, der, :not_encrypted} | _] <- :public_key.pem_decode(pem) do
          {:ok, der}
        else
          _ -> {:error, {:unreadable, file_key}}
        end

      true ->
        {:error, {:missing, key}}
    end
  end

  defp key(opts) do
    case {Map.get(opts, :key), Map.get(opts, :key_file)} do
      {{type, der}, _} when type in [:ECPrivateKey, :RSAPrivateKey, :PrivateKeyInfo] and
                              is_binary(der) ->
        {:ok, {type, der}}

      {nil, file} when is_binary(file) ->
        with {:ok, pem} <- File.read(file),
             [{type, der, :not_encrypted} | _]
             when type in [:ECPrivateKey, :RSAPrivateKey, :PrivateKeyInfo] <-
               :public_key.pem_decode(pem) do
          {:ok, {type, der}}
        else
          _ -> {:error, {:unreadable, :key_file}}
        end

      _ ->
        {:error, {:missing, :key}}
    end
  end

  defp common(creds) do
    [
      versions: [:"tlsv1.3"],
      verify: :verify_peer,
      cacerts: [creds.peer_ca],
      cert: creds.cert,
      key: creds.key,
      verify_fun: {&verify/3, creds.peer_pin},
      session_tickets: :disabled,
      log_level: :warning,
      mode: :binary,
      packet: :raw,
      active: false,
      send_timeout: 500,
      send_timeout_close: true
    ]
  end

  @doc "Listen options (the acceptor side)."
  def listen_options(creds, ip),
    do: common(creds) ++ [fail_if_no_peer_cert: true, ip: ip, reuseaddr: true, backlog: 2]

  @doc "Options for `:ssl.handshake/3` on an accepted transport socket (none beyond the listen set)."
  def handshake_options(_creds), do: []

  @doc "Connect options (the initiator side)."
  def connect_options(creds), do: common(creds) ++ [server_name_indication: :disable]

  @doc false
  # Narrowing only: OTP's failures stand; extensions are OTP's to judge; the peer leaf passes only
  # on the exact pin. An intermediate or the trusted CA reaching `valid` is OTP's own verdict.
  def verify(_cert, {:bad_cert, _} = reason, _pin), do: {:fail, reason}
  def verify(_cert, {:extension, _}, pin), do: {:unknown, pin}
  def verify(_cert, :valid, pin), do: {:valid, pin}

  def verify(cert, :valid_peer, pin) do
    der = :public_key.pkix_encode(:OTPCertificate, cert, :otp)
    if pin(der) == pin, do: {:valid, pin}, else: {:fail, :pin_mismatch}
  end

  def verify(_cert, other, _pin), do: {:fail, {:unexpected_verification_event, other}}

  @doc """
  The post-handshake check on the DER the connection received: `:ok` when it is the pinned leaf and
  the protocol is TLS 1.3, else `{:error, reason}`.
  """
  def check_peer(socket, pin) do
    with {:ok, der} <- :ssl.peercert(socket),
         true <- pin(der) == pin or {:error, :pin_mismatch},
         {:ok, [protocol: :"tlsv1.3"]} <- :ssl.connection_information(socket, [:protocol]) do
      :ok
    else
      {:ok, [protocol: other]} -> {:error, {:protocol, other}}
      {:error, _} = error -> error
      other -> {:error, other}
    end
  end
end
