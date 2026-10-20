#!/bin/sh
# M7-L1 — the READ-ONLY compatibility check for a machine that would run the transport-only peer (operator tooling; README.md).
# Prepared in M7-L1 and run there only on the Windows/WSL host; NOT yet run on the MacBook (that needs its own authorization).
#   compat-check.sh [<bundle-dir>] [<port>]
# It changes nothing: no installation, no download, no file written, no socket opened (the TLS check is in memory), no firewall,
# shell-profile or runtime change, no `mix` (so no Mix or Hex home is read), and it never reads another project's files: it runs
# from this kit's own directory. It reports:
#   the OS and architecture; which `elixir` / `erl` the PATH resolves to (a version manager's shim is named as such); their
#   versions; the OTP release and ssl / crypto / public_key versions; TLS 1.3, P-256 and an in-memory ECDSA signature;
#   the OTP test-certificate functions the kit's creds.exs uses; Elixir's JSON module; whether this emulator would start
#   distributed; whether the Erlang flag variables are set (names only); with a bundle: whether its modules load here;
#   with a port: whether anything listens on it; the local IPv4 addresses (listed for a human to choose; nothing is selected);
#   on macOS the application firewall's state (read only); a user Erlang boot file (named only; start.sh refuses one).
# A version manager's shim is reported and NOT executed (it may read version files above this directory or install a runtime):
# then name the real elixir with GLACIER_PEER_ELIXIR (the same variable start.sh honours) and run this check again.
# Then MISSING PREREQUISITES (none, or each one named). Exit 0 always unless the arguments are wrong (2).
set -u
B=${1:-}; PORT=${2:-}
[ -z "$B" ] || [ -d "$B/ebin/glacier_relay" ] || { echo "compat-check: $B is not a peer-transport bundle" >&2; exit 2; }
[ -z "$B" ] || B=$(cd "$B" && pwd -P)
case "$PORT" in ''|[0-9]*) ;; *) echo "compat-check: the port must be a number" >&2; exit 2;; esac
cd "$(dirname "$0")" || exit 2
missing=""
note() { missing="$missing
  - $*"; }
echo "== compat-check $(date -u +%Y-%m-%dT%H:%M:%SZ) (read only)"
echo "os: $(uname -s) $(uname -r) $(uname -m)"
if [ "$(uname -s)" = Darwin ]; then echo "macos: $(sw_vers -productVersion 2>/dev/null) build $(sw_vers -buildVersion 2>/dev/null)"; fi
for v in ERL_AFLAGS ERL_FLAGS ERL_ZFLAGS ELIXIR_ERL_OPTIONS MIX_ENV MIX_HOME HEX_HOME; do
  eval "x=\${$v+set}"; [ "$x" = set ] && echo "environment: $v is set (start.sh removes the ERL_* / ELIXIR_ERL_OPTIONS ones for the peer)"
done
E=${GLACIER_PEER_ELIXIR:-$(command -v elixir 2>/dev/null || true)}; R=$(command -v erl 2>/dev/null || true)
echo "elixir to be used: ${E:-none}${GLACIER_PEER_ELIXIR:+ (from GLACIER_PEER_ELIXIR)}"; echo "erl on PATH: ${R:-none}"
shim=""
for p in "$E" "$R"; do
  [ -n "$p" ] || continue
  case "$p" in *asdf*|*mise*|*rtx*|*/shims/*) shim="$shim $p"; echo "  $p looks like a version manager's shim: NOT executed by this check";; esac
  [ -L "$p" ] && echo "  $p -> $(readlink "$p")"
done
for rc in "$HOME/.erlang" "${XDG_CONFIG_HOME:-$HOME/.config}/erlang/.erlang" "$HOME/Library/Application Support/erlang/.erlang"; do
  [ -e "$rc" ] && { echo "Erlang boot file present: $rc (not read; start.sh refuses to run while it exists)"; note "an Erlang boot file exists: $rc"; }
done
if [ -z "$E" ]; then note "elixir is not on PATH"; fi
if [ -n "$shim" ]; then note "a version manager's shim is on the path ($shim); name the real elixir with GLACIER_PEER_ELIXIR — the runtime was not examined"; fi
if [ -n "$E" ] && [ -z "$shim" ]; then
  echo "elixir --version:"; env -u ERL_AFLAGS -u ERL_FLAGS -u ERL_ZFLAGS -u ELIXIR_ERL_OPTIONS -u ERL_LIBS ERL_CRASH_DUMP_BYTES=0 "$E" --version 2>&1 | sed 's/^/  /'
  PA=""; [ -n "$B" ] && PA="-pa $B/ebin/glacier_relay"
  # shellcheck disable=SC2086
  [ -n "$B" ] && export M7L1_BUNDLE_GIVEN=1
  OUT=$(env -u ERL_AFLAGS -u ERL_FLAGS -u ERL_ZFLAGS -u ELIXIR_ERL_OPTIONS -u ERL_LIBS ERL_CRASH_DUMP_BYTES=0 "$E" $PA -e '
    say = fn k, v -> IO.puts("#{k}: #{v}") end
    otp = System.otp_release()
    say.("otp_release", otp)
    say.("erts", :erlang.system_info(:version))
    say.("elixir", System.version())
    for a <- [:ssl, :crypto, :public_key], do: (Application.load(a); say.("#{a}", Application.spec(a, :vsn) || "MISSING"))
    say.("crypto_library", inspect(:crypto.info_lib()))
    say.("distributed_at_start", Node.alive?())
    {:ok, _} = Application.ensure_all_started(:ssl)
    tls13 = :"tlsv1.3" in Keyword.get(:ssl.versions(), :supported, [])
    say.("tls1.3_supported", tls13)
    p256 = :secp256r1 in :crypto.ec_curves()
    say.("p256_curve", p256)
    ecdsa =
      try do
        {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
        sig = :crypto.sign(:ecdsa, :sha256, "m7l1", [priv, :secp256r1])
        :crypto.verify(:ecdsa, :sha256, "m7l1", sig, [pub, :secp256r1])
      rescue
        _ -> false
      end
    say.("ecdsa_p256_sign_verify_in_memory", ecdsa)
    testcerts =
      try do
        r = :public_key.pkix_test_root_cert(~c"compat", key: {:namedCurve, :secp256r1}, digest: :sha256)
        is_binary(r.cert)
      rescue
        _ -> false
      end
    say.("otp_test_certificates_in_memory", testcerts)
    json = Code.ensure_loaded?(JSON)
    say.("elixir_json_module", json)
    bundle = Code.ensure_loaded?(GlacierRelay.Peer.Network) and Code.ensure_loaded?(GlacierRelay.HeadlessPeer)
    say.("bundle_modules_load", bundle)
    miss =
      [{otp != "28", "OTP release #{otp}, the bundle is built and qualified on 28"},
       {not String.starts_with?(System.version(), "1.19."), "Elixir #{System.version()}, the bundle is built and qualified on 1.19.x"},
       {not tls13, "no TLS 1.3 in ssl"}, {not p256, "no P-256 curve in crypto"}, {not ecdsa, "ECDSA P-256 does not work in crypto"},
       {not testcerts, "the OTP test-certificate functions do not work"}, {not json, "no Elixir JSON module (Elixir >= 1.18 needed)"}]
    bundle_given = System.get_env("M7L1_BUNDLE_GIVEN") == "1"
    for {true, m} <- miss ++ [{bundle_given and not bundle, "the bundle'"'"'s modules do not load on this runtime"}], do: IO.puts("MISSING: " <> m)
  ' 2>&1)
  echo "$OUT" | grep -v '^MISSING: ' | sed 's/^/  /'
  m=$(echo "$OUT" | grep '^MISSING: ' | sed 's/^MISSING: //')
  [ -z "$m" ] || { old_ifs=$IFS; IFS='
'; for x in $m; do note "$x"; done; IFS=$old_ifs; }
  echo "$OUT" | grep -q '^tls1.3_supported: ' || note "the runtime check did not complete (output above)"
fi
if [ -n "$PORT" ]; then
  if command -v lsof >/dev/null 2>&1; then
    l=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | tail -n +2)
    echo "listeners on port $PORT: ${l:-none}"
  else
    echo "listeners on port $PORT: (no lsof; not checked)"
  fi
fi
echo "local IPv4 addresses (for a human to choose; nothing is selected here):"
if command -v ifconfig >/dev/null 2>&1; then ifconfig 2>/dev/null | awk '/^[a-z0-9]/{i=$1} /inet /{print "  " i " " $2}'
elif command -v ip >/dev/null 2>&1; then ip -4 -o addr show 2>/dev/null | awk '{print "  " $2 " " $4}'; fi
if [ "$(uname -s)" = Darwin ] && [ -x /usr/libexec/ApplicationFirewall/socketfilterfw ]; then
  echo "macos application firewall (read only): $(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>&1 | tr '\n' ' ')"
  echo "  stealth mode: $(/usr/libexec/ApplicationFirewall/socketfilterfw --getstealthmode 2>&1 | tr '\n' ' ')"
  echo "  note: an incoming connection to beam.smp may need the operator's consent in the firewall prompt; macOS may also ask for"
  echo "  Local Network access for the terminal that starts it. Neither is checked or granted here."
fi
echo "== MISSING PREREQUISITES:${missing:- none found by this check}"
echo "(this check reads only; anything missing is listed for a decision, never installed here)"
