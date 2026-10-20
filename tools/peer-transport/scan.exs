# M7-L1 — the secret scan of a run's outputs (operator tooling; README.md). Run with `elixir`; no bundle needed.
#
#   scan.exs <dir> [<dir>...] [--known-key <key.pem>]...     scan every regular file under the directories
#   scan.exs --selftest <new-scratch-dir>                      plant positive and negative controls and require exactly the
#                                                              positives to be found, each by its class (it creates the directory;
#                                                              refuses one that exists); afterwards the planted key and the positive
#                                                              controls are removed, leaving their listing and the negatives
#
# A HIT is actual credential material, never a name or a pattern:
#   pem      a PEM private-key block — a "-----BEGIN ... PRIVATE KEY-----" armour that ends its line, then a base64 body, then
#            its END line — whose body decodes (:public_key.pem_decode, :public_key.der_decode) to a private key; looked for in
#            each file's text and in its JSON-unescaped view (a PEM inside a JSON string, with \n escapes);
#   known    the DER of each --known-key, as raw bytes, as base64 (whole, and every 64-character body line of its PEM), as
#            lowercase or uppercase hex, and as the comma-separated decimal byte list the BEAM prints (inspect / ~p / ~w, matched
#            on a whitespace-stripped view because ~p wraps lines); and, for an EC key, its private scalar in each of those forms —
#            what a crash report, a stack trace's arguments or a log line of the decoded key would show (verifier V1).
# Directories are walked (never globbed: a path may hold glob characters); symbolic links to files are read, to directories
# not entered. A directory with no file to scan is refused (exit 2): "0 hits" never means "nothing was read".
# Reported for information only, never as hits: armour-like text whose body is no key (a scanner's own pattern, a quotation, a
# certificate), and file NAMES containing key / token / secret / cred. Every count is computed from the files scanned now.
# Exit 0 no hits, 1 hits, 2 usage.

defmodule Scan do
  @moduledoc false
  # an armour line's end must close its line, but it may follow other text on the line (a PEM inside a JSON string, once
  # unescaped, starts after `{"x":"`); a block counts only if it decodes to a key, so pattern text is never a hit
  @armour ~r/-----BEGIN ([A-Z0-9 ]*)PRIVATE KEY-----\r?$/m
  @key_types [:ECPrivateKey, :RSAPrivateKey, :DSAPrivateKey, :PrivateKeyInfo]

  def files(dirs) do
    Enum.flat_map(dirs, fn d ->
      case walk(d, true) do
        [] -> (IO.puts("scan: REFUSED: no file to scan under #{d}"); System.halt(2))
        fs -> fs
      end
    end)
    |> Enum.sort()
  end

  defp walk(path, top) do
    case if(top, do: File.stat(path), else: File.lstat(path)) do
      {:ok, %{type: :directory}} -> path |> File.ls!() |> Enum.flat_map(&walk(Path.join(path, &1), false))
      {:ok, %{type: :regular}} -> [path]
      {:ok, %{type: :symlink}} -> if File.regular?(path), do: [path], else: []
      _ -> []
    end
  end

  def declist(bin), do: bin |> :binary.bin_to_list() |> Enum.join(",")

  def strip(bytes), do: for(<<c <- bytes>>, c not in [?\s, ?\t, ?\r, ?\n], into: "", do: <<c>>)

  def known(paths) do
    Enum.flat_map(paths, fn p ->
      for {t, der, _} <- :public_key.pem_decode(File.read!(p)), t in @key_types do
        b64 = Base.encode64(der)
        lines = for l <- String.split(:public_key.pem_encode([{t, der, :not_encrypted}]), "\n"), byte_size(l) == 64, do: l

        scalar =
          case t do
            :ECPrivateKey -> elem(:public_key.der_decode(t, der), 2)
            _ -> nil
          end

        forms = fn kind, b ->
          [{kind, b}, {kind <> "-base64", Base.encode64(b)}, {kind <> "-hex", Base.encode16(b, case: :lower)},
           {kind <> "-HEX", Base.encode16(b)}]
        end

        %{source: p,
          needles: [{"der", der}, {"base64", b64}, {"hex", Base.encode16(der, case: :lower)}, {"HEX", Base.encode16(der)}] ++
            Enum.map(lines, &{"base64-line", &1}) ++ if(scalar, do: forms.("scalar", scalar), else: []),
          # matched on the whitespace-stripped view of each file
          stripped: [{"declist", declist(der)}] ++ if(scalar, do: [{"scalar-declist", declist(scalar)}], else: [])}
      end
    end)
  end

  # PEM private-key material in one text view: every armour line, the block to its END line, decoded
  def pem_hits(text) do
    for [{start, _} | _] <- Regex.scan(@armour, text, return: :index), reduce: {[], 0} do
      {hits, near} ->
        block = binary_part(text, start, byte_size(text) - start)

        case Regex.run(~r/\A(-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----\r?\n(?:[A-Za-z0-9+\/=\r\n]|[A-Za-z-]+: [^\n]*\n)*?-----END [A-Z0-9 ]*PRIVATE KEY-----)/, block) do
          [pem | _] ->
            decoded = try do: :public_key.pem_decode(pem), rescue: (_ -> [])
            if Enum.any?(decoded, fn {t, der, _} -> t in @key_types and key?(t, der) end),
              do: {[:pem | hits], near},
              else: {hits, near + 1}

          nil ->
            {hits, near + 1}
        end
    end
  end

  defp key?(t, der) do
    _ = :public_key.der_decode(t, der)
    true
  rescue
    _ -> false
  end

  def unescape(text), do: text |> String.replace("\\r\\n", "\n") |> String.replace("\\n", "\n") |> String.replace("\\/", "/")

  def scan(dirs, known_paths) do
    ks = known(known_paths)
    files = files(dirs)

    results =
      for f <- files do
        bytes = File.read!(f)
        text = if String.valid?(bytes), do: bytes, else: :binary.bin_to_list(bytes) |> Enum.map(&if(&1 < 128, do: &1, else: ?.)) |> to_string()
        {p1, n1} = pem_hits(text)
        {p2, n2} = if String.contains?(text, "\\n-----"), do: pem_hits(unescape(text)), else: {[], 0}

        flat = if ks == [], do: "", else: strip(bytes)

        kh =
          (for k <- ks, {kind, needle} <- k.needles, :binary.match(bytes, needle) != :nomatch, do: "known-#{kind}") ++
            (for k <- ks, {kind, needle} <- k.stripped, :binary.match(flat, needle) != :nomatch, do: "known-#{kind}")
          |> Enum.uniq()

        name = Path.basename(f) |> String.downcase()
        %{file: f, pem: length(p1) + length(p2) > 0, known: kh, armour_without_material: n1 + n2,
          suggestive_name: Enum.any?(~w(key token secret cred), &String.contains?(name, &1))}
      end

    hits = Enum.filter(results, &(&1.pem or &1.known != []))
    for h <- hits, do: IO.puts("HIT #{h.file}: #{Enum.join((if h.pem, do: ["pem"], else: []) ++ h.known, ", ")}")
    near = Enum.filter(results, &(&1.armour_without_material > 0))
    for n <- near, n not in hits, do: IO.puts("info: armour-like text without key material in #{n.file} (#{n.armour_without_material})")
    names = Enum.filter(results, & &1.suggestive_name)
    for n <- names, do: IO.puts("info: suggestive file name (not a finding by itself): #{n.file}")

    IO.puts("scanned #{length(files)} files in #{inspect(dirs)}; known keys #{length(ks)} (#{Enum.map_join(ks, ", ", & &1.source)})")
    IO.puts("MATERIAL HITS: #{length(hits)} (pem #{Enum.count(hits, & &1.pem)}, known #{Enum.count(hits, &(&1.known != []))}); armour-like text without material: #{length(near)} file(s); suggestive names: #{length(names)} (information only)")
    hits
  end

  def selftest(dir) do
    if File.exists?(dir), do: (IO.puts("selftest: REFUSED: #{dir} exists"); System.halt(2))
    File.mkdir_p!(dir)
    # the positives sit in a directory whose name holds glob characters (verifier V1: it must still be read)
    pos = Path.join(dir, "positive[1]")
    neg = Path.join(dir, "negative")
    File.mkdir_p!(pos)
    File.mkdir_p!(neg)
    # the planted credential: a fresh throwaway P-256 key, generated here and nowhere else
    root = :public_key.pkix_test_root_cert(~c"scan-selftest-#{System.unique_integer([:positive])}", key: {:namedCurve, :secp256r1}, digest: :sha256)
    {t, der} = {:ECPrivateKey, :public_key.der_encode(:ECPrivateKey, root.key)}
    pem = :public_key.pem_encode([{t, der, :not_encrypted}])
    keyfile = Path.join(dir, "planted-key.pem")
    File.write!(keyfile, pem)
    body_line = pem |> String.split("\n") |> Enum.find(&(byte_size(&1) == 64))
    other = :public_key.pkix_test_root_cert(~c"scan-selftest-other", key: {:namedCurve, :secp256r1}, digest: :sha256)
    {ot, oder} = {:ECPrivateKey, :public_key.der_encode(:ECPrivateKey, other.key)}

    # each positive with the class that must find it (an unknown key can be found only as PEM material)
    unknown = :public_key.pem_encode([{ot, oder, :not_encrypted}])

    positives = %{
      "pem-in-log.txt" => {"a log line\n" <> pem <> "after\n", "pem"},
      "unknown-pem.txt" => {unknown, "pem"},
      "unknown-pem-in-json.json" => {JSON.encode!(%{"leaked" => unknown}), "pem"},
      "base64-in-prose.txt" => {"value=" <> Base.encode64(der) <> " end\n", "known-base64"},
      "hex-in-prose.txt" => {"k " <> Base.encode16(der, case: :lower) <> "\n", "known-hex"},
      "upper-hex-in-prose.txt" => {"K " <> Base.encode16(der) <> "\n", "known-HEX"},
      "raw.bin" => {:crypto.strong_rand_bytes(100) <> der <> :crypto.strong_rand_bytes(100), "known-der"},
      "one-body-line.txt" => {"fragment: #{body_line}\n", "known-base64-line"},
      # how the BEAM prints a key (verifier V1): inspect in full and at its default limit, Erlang ~p, the decoded record
      "inspect-full.txt" => {"** (MatchError) " <> inspect({t, der}, limit: :infinity) <> "\n", "known-declist"},
      "inspect-default.txt" => {"args: " <> inspect({t, der}) <> "\n", "known-scalar-declist"},
      "erlang-p.txt" => {IO.iodata_to_binary(:io_lib.format("~p~n", [{t, der}])), "known-scalar-declist"},
      "decoded-record.txt" => {inspect(:public_key.der_decode(t, der)) <> "\n", "known-scalar-declist"},
      "scalar-hex.txt" => {"d=" <> Base.encode16(elem(:public_key.der_decode(t, der), 2), case: :lower) <> "\n", "known-scalar-hex"}
    }

    negatives = %{
      "pattern.exs" => "~r/^-----BEGIN ([A-Z0-9 ]*)PRIVATE KEY-----$/ and the words PRIVATE KEY\n" <>
        "IO.puts(\"-----BEGIN EC PRIVATE KEY-----\")\n",
      "quoted-armour.txt" => "-----BEGIN EC PRIVATE KEY-----\nbm90IGEga2V5\n-----END EC PRIVATE KEY-----\n",
      "certificate.pem" => :public_key.pem_encode([{:Certificate, root.cert, :not_encrypted}]),
      "token-name.txt" => "nothing secret here\n",
      "numbers.txt" => inspect(:crypto.strong_rand_bytes(64), limit: :infinity) <> "\n",
      "key_file.json" => JSON.encode!(%{"key_file" => "/path/to/own-key.pem", "peer_pin" => String.duplicate("ab", 32)})
    }

    # every control a file of its own, also where names are case-insensitive (drvfs, macOS APFS by default): two names that
    # differ only by case would be one file there (kit rehearsal attempt 1)
    names = Map.keys(positives) ++ Map.keys(negatives)
    if length(Enum.uniq(Enum.map(names, &String.downcase/1))) != length(names),
      do: (IO.puts("selftest: REFUSED: control names collide when case is ignored"); System.halt(2))

    try do
      selfcheck(dir, pos, neg, positives, negatives, keyfile)
    after
      # nothing planted stays, whatever happened above: the key file and every positive control (each holds key material) are
      # removed (logical deletion); their names, sizes and digests are in positive-controls.txt, the negatives stay as they are
      for {n, _} <- positives, do: File.rm(Path.join(pos, n))
      File.rmdir(pos)
      File.rm(keyfile)
      IO.puts("selftest: the planted key and the #{map_size(positives)} positive controls were removed (listing: positive-controls.txt)")
    end
  end

  defp selfcheck(dir, pos, neg, positives, negatives, keyfile) do
    for {n, {b, _class}} <- positives, do: File.write!(Path.join(pos, n), b)
    for {n, b} <- negatives, do: File.write!(Path.join(neg, n), b)
    planted = length(File.ls!(pos)) + length(File.ls!(neg))
    IO.puts("selftest: planted #{map_size(positives)} positive and #{map_size(negatives)} negative controls in #{dir} (#{planted} files)")

    found =
      for h <- scan([pos], [keyfile]), into: %{},
          do: {Path.basename(h.file), (if h.pem, do: ["pem"], else: []) ++ h.known}

    ph = Map.keys(found) |> Enum.sort()
    nh = scan([neg], [keyfile]) |> Enum.map(&Path.basename(&1.file))
    missed = for {n, {_b, class}} <- positives, class not in Map.get(found, n, []), do: "#{n} (#{class})"
    fails = length(missed) + length(nh)
    IO.puts("selftest: positives found #{length(ph)} / #{map_size(positives)} (missed #{inspect(missed)}); negatives flagged #{length(nh)} (#{inspect(nh)})")
    listing =
      for {n, {b, class}} <- Enum.sort(positives),
          do: "#{n}\t#{byte_size(b)} B\tsha256 #{Base.encode16(:crypto.hash(:sha256, b), case: :lower)}\tmust be found as #{class}\tfound as #{Enum.join(Map.get(found, n, []), ",")}\n"

    File.write!(Path.join(dir, "positive-controls.txt"), listing)
    fails = fails + if(planted == map_size(positives) + map_size(negatives), do: 0, else: 1)
    IO.puts("SELFTEST RESULT: #{if fails == 0, do: "PASS", else: "FAIL"} (#{fails} failures)")
    # the result is printed here; the exit happens after the cleanup (System.halt would skip the `after`)
    send(self(), {:selftest_exit, if(fails == 0, do: 0, else: 1)})
  end
end

case System.argv() do
  ["--selftest", dir] ->
    Scan.selftest(dir)
    receive do: ({:selftest_exit, code} -> System.halt(code)), after: (0 -> System.halt(1))

  args when args != [] ->
    {known, dirs} =
      Enum.reduce(args, {[], [], nil}, fn
        "--known-key", {k, d, nil} -> {k, d, :key}
        p, {k, d, :key} -> {[p | k], d, nil}
        p, {k, d, nil} -> {k, [p | d], nil}
      end)
      |> then(fn {k, d, _} -> {Enum.reverse(k), Enum.reverse(d)} end)

    if dirs == [] or Enum.any?(dirs, &(not File.dir?(&1))), do: (IO.puts("scan: usage: scan.exs <dir>... [--known-key <key.pem>]..."); System.halt(2))
    System.halt(if Scan.scan(dirs, known) == [], do: 0, else: 1)

  _ ->
    IO.puts("scan: usage: scan.exs <dir>... [--known-key <key.pem>]... | --selftest <new-dir>")
    System.halt(2)
end
