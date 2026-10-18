#!/usr/bin/env python3
"""readiness.py - one explicit readiness record per controlled run, and the gate an installer runs against ONE named
record pinned by its sha256 (never "the latest" record).

  readiness.py check <manifest.json> <record-out.json> <record-out.txt> [--cache-in C]... [--cache-out C] [--work DIR]
  readiness.py gate <record.json> --sha256 HEX64 [--max-age-s N] [--not-before ISO-8601-UTC | @file-whose-mtime-is-used]
  readiness.py selfhash

What a record establishes, and what it does not. Each check states how it was performed (now / reused / cached), its
input identity, its result (ok / FAIL / INVALIDATED) and the input changes that would invalidate it. "file", "git",
"manifest" and "command" checks are performed now; "command" is for time-sensitive facts (processes, ports,
installation state) and is never cached; no git fetch is made. A "manifest" check always verifies the manifest's own
bytes; the files it lists are re-hashed only with verify_listed true, and the record says which. A "reuse" check
verifies an earlier result file's bytes and a pattern in it, and that the checks it depended on still have the named
identities; the original check is not repeated. A "cached" check reuses an earlier ok result only for an identical key
(validator bytes and version, argv, expectations, current input identities); a file name is never a key, and an input
whose identity is marked partial (a dirty tree not required clean, a manifest whose listed files were not re-verified)
means no cache entry is used or stored. Hashing a record verifies that record's bytes, not the files it lists.
Identities: file "<sha256>:<size>"; git "<commit>", "<commit> <path>=<tree>", or "<path>=<tree>" for a TREE-ONLY git
check ("commit": "*" with a "tree": any commit on the branch, keyed to that tree's content alone — so a result that depends
only on relay/lib, say, stays reusable across commits that do not touch it); manifest = its sha256; reuse = the
record file's sha256; cached = the cache key; command = the sha256 of <work>/<id>.out.
Outputs are created exclusively (absent, or an existing EMPTY regular file); nothing is truncated, renamed or deleted;
use a fresh --work directory per invocation. A file whose basename is 'token' is never read.
Exit: 0 every check ok; 1 a check FAIL or INVALIDATED (record written); 2 usage, refusal or unreadable manifest.
Python 3.8, standard library only; run with python3 -I.
"""
import argparse, datetime, hashlib, json, os, re, stat, subprocess, sys

TOOL_VERSION = "readiness/1"
SCHEMA_IN, SCHEMA_REC = "glacier-relay.run-readiness/1", "glacier-relay.run-readiness-record/1"
SCHEMA_CACHE, KEY_SCHEMA = "glacier-relay.run-readiness-cache/1", "glacier-relay.run-readiness-cache-key/1"
ID_RE = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
OBJ_RE = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")   # a full git object name (SHA-1 or SHA-256 repository)
SUM_LINE = re.compile(r"([0-9a-fA-F]{64}) [ *](.+)\Z")    # sha256sum output: "<hex>  <path>" or "<hex> *<path>"
TIMEOUT_S = 600
EPOCH = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)
KINDS = {  # kind -> (required keys besides id/kind, optional keys)
    "file": (("path", "sha256"), ("size",)),
    "git": (("repo", "branch", "commit"), ("require_clean", "require_remote", "tree")),
    "manifest": (("root", "manifest", "manifest_sha256", "verify_listed"), ()),
    "reuse": (("record", "record_sha256", "expect", "covers", "requires"), ("evidence_manifest",)),
    "cached": (("argv", "validator", "validator_version", "inputs"), ("expect_exit", "expect")),
    "command": (("argv",), ("expect_exit", "expect")),
}

class Refused(Exception):
    """usage error or refusal: exit 2"""

def utc_now(): return datetime.datetime.now(datetime.timezone.utc)
def iso(t): return t.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
def sha256_bytes(b): return hashlib.sha256(b).hexdigest()

def need(cond, where, what):
    if not cond: raise Refused("%s: %s" % (where, what))

def parse_iso(s):
    t = datetime.datetime.fromisoformat(s[:-1] + "+00:00" if s.endswith("Z") else s)   # 3.8 does not accept "Z"
    if t.tzinfo is None: raise ValueError("timestamp without a time zone: %s" % s)
    return t

def no_token(path):
    # compared case-insensitively (the Windows-side file systems are), on the given and on the resolved name
    for p in (path, os.path.realpath(path)):
        if os.path.basename(os.path.normpath(p)).lower() == "token":
            raise Refused("a path whose basename is 'token' is never read: %s" % path)

def regular(path):
    no_token(path)
    if not os.path.isfile(path):
        raise OSError("%s: %s" % ("not a regular file" if os.path.exists(path) else "missing", path))

def read_regular(path):
    regular(path)
    with open(path, "rb") as f:
        return f.read()

def sha256_file(path):
    regular(path)
    h, n = hashlib.sha256(), 0
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
            n += len(b)
    return h.hexdigest(), n

def self_sha():
    with open(os.path.abspath(__file__), "rb") as f:
        return sha256_bytes(f.read())

def _pairs(pairs):   # a JSON object with a repeated key is refused rather than silently resolved
    keys = [k for k, _ in pairs]
    if len(set(keys)) != len(keys): raise ValueError("duplicate key in %s" % sorted(keys))
    return dict(pairs)

def _strings(v):
    if isinstance(v, str): yield v
    for x in (list(v) + list(v.values()) if isinstance(v, dict) else v if isinstance(v, list) else ()):
        yield from _strings(x)

def load_json(path, what):
    try:
        raw = read_regular(path)
        obj = json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs)
        for s in _strings(obj):   # refused here, not as a crash later when a path is used or the record is encoded
            s.encode("utf-8")      # a lone surrogate (a \ud800 escape) raises UnicodeEncodeError, a ValueError
            if "\x00" in s: raise ValueError("a string holds a NUL character")
        return raw, obj
    except (OSError, ValueError, RecursionError) as e:
        raise Refused("%s unreadable: %s" % (what, e))

def precheck_out(path):
    """an output must be absent, or an existing EMPTY regular file (the evidence guard pre-creates one, no-clobber);
    a non-empty file, a directory or a symlink is refused before anything is written"""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        need(os.path.isdir(os.path.dirname(os.path.abspath(path))), path, "the output's directory does not exist")
        return
    except OSError as e:   # e.g. a parent that is a file, or a name too long: a refusal (exit 2), not a crash
        raise Refused("output %s cannot be examined: %s" % (path, e))
    need(stat.S_ISREG(st.st_mode) and st.st_size == 0, path, "exists and is not an empty regular file (not touched)")

def write_out(path, data):
    """exclusive create, or a write into the pre-created empty file, re-checked on the open descriptor (no O_TRUNC)"""
    try:
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except FileExistsError:
            fd = os.open(path, os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0))
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_size != 0:
                os.close(fd)
                raise Refused("output %s became non-empty or irregular before the write (refused)" % path)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
    except OSError as e:
        raise Refused("output %s could not be written exclusively: %s" % (path, e))

# ---- manifest validation: everything refusable is refused here, before any check runs or anything is written

def _m(rx): return lambda v: isinstance(v, str) and rx.match(v) is not None
def _text(v): return isinstance(v, str) and v.strip() != ""
def _rel(v): return _text(v) and v != "." and not os.path.isabs(v) and "\\" not in v and ".." not in v.split("/")

def _rx(v):
    try:
        return isinstance(v, str) and re.compile(v) is not None
    except re.error:
        return False

ABS = (lambda v: isinstance(v, str) and os.path.isabs(v), "an absolute path")
HEX = (_m(HEX64), "a full hex digest (64 digits)")
OBJ = (_m(OBJ_RE), "a full git object name")
REL = (_rel, "a relative path inside its root, without '..'")
BOOL = (lambda v: type(v) is bool, "true or false")
COMMIT = (lambda v: v == "*" or OBJ[0](v), "a full git object name, or \"*\" with a tree (a tree-only identity)")
FIELD = {"path": ABS, "repo": ABS, "root": ABS, "record": ABS, "validator": ABS, "manifest": REL, "commit": COMMIT,
         "sha256": HEX, "manifest_sha256": HEX, "record_sha256": HEX, "require_clean": BOOL, "verify_listed": BOOL,
         "size": (lambda v: type(v) is int and v >= 0, "a non-negative integer"),
         "expect_exit": (lambda v: type(v) is int, "an integer"), "expect": (_rx, "a valid regex"),
         "branch": (_m(re.compile(r"[A-Za-z0-9_][A-Za-z0-9._/-]*\Z")), "a branch name"),
         "require_remote": (_m(re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")), "a remote name"),
         "covers": (_text, "a text saying what the reused result established"), "validator_version": (_text, "a text"),
         "argv": (lambda v: isinstance(v, list) and len(v) > 0 and all(_text(x) for x in v), "a list of strings"),
         "requires": (lambda v: isinstance(v, dict) and all(_text(x) for x in v.values()), "{check id: identity}"),
         "inputs": (lambda v: isinstance(v, list) and all(isinstance(x, str) for x in v) and len(set(v)) == len(v),
                    "a list of distinct check ids")}
TREE_FIELD = {"path": REL, "hash": OBJ}
LOWER = ("sha256", "manifest_sha256", "record_sha256", "commit", "hash")   # hex accepted in either case, stored lower

def fields(obj, req, opt, where):
    need(isinstance(obj, dict), where, "not a JSON object")
    miss, unk = sorted(set(req) - set(obj)), sorted(set(obj) - set(req) - set(opt))
    need(not miss and not unk, where, "missing keys %s, unknown keys %s" % (miss, unk))

def typed(obj, where, table):
    for k in list(obj):
        if k in LOWER and isinstance(obj[k], str): obj[k] = obj[k].lower()
        if k in table: need(table[k][0](obj[k]), where, "%s must be %s" % (k, table[k][1]))
        if table.get(k) is ABS: no_token(obj[k])
    if "manifest" in obj and "root" in obj: no_token(os.path.join(obj["root"], obj["manifest"]))

def validate(m):
    fields(m, ("schema", "run_id", "roots", "checks"), ("notes",), "manifest")
    need(m["schema"] == SCHEMA_IN, "manifest", "schema must be %s" % SCHEMA_IN)
    need(_text(m["run_id"]) and isinstance(m.get("notes", ""), str), "manifest", "run_id (and notes) must be strings")
    fields(m["roots"], ("evidence", "state"), (), "roots")
    for k in ("evidence", "state"):
        need(ABS[0](m["roots"][k]), "roots." + k, "must be an absolute path")
    need(isinstance(m["checks"], list) and m["checks"], "manifest", "checks must be a non-empty list")
    seen = []
    for i, c in enumerate(m["checks"]):
        kind = c.get("kind") if isinstance(c, dict) else None
        need(isinstance(kind, str) and kind in KINDS, "checks[%d]" % i, "unknown or missing kind %r" % (kind,))
        fields(c, ("id", "kind") + KINDS[kind][0], KINDS[kind][1], "checks[%d]" % i)
        w = "check %r" % (c["id"],)
        need(isinstance(c["id"], str) and ID_RE.match(c["id"]), w, "id must match [a-z0-9][a-z0-9._-]{0,63}")
        need(c["id"] not in seen, w, "duplicate id")
        typed(c, w, FIELD)
        for sub, req, table in (("tree", ("path", "hash"), TREE_FIELD),
                                ("evidence_manifest", ("root", "manifest", "manifest_sha256"), FIELD)):
            if sub in c:
                fields(c[sub], req, (), w + "." + sub)
                typed(c[sub], w + "." + sub, table)
        need(c.get("commit") != "*" or "tree" in c, w, 'commit "*" (a tree-only identity) requires a "tree"')
        for rid in list(c.get("requires", ())) + list(c.get("inputs", ())):
            need(rid in seen, w, "%r is not a check appearing earlier" % (rid,))
        seen.append(c["id"])

# ---- the checks; each returns one record entry

def rec(c, performed, result, ident, detail, inv, **extra):
    detail = " | ".join(x for x in detail.replace("\r", "\n").split("\n") if x)   # one line per check in the text form
    r = {"id": c["id"], "kind": c["kind"], "performed": performed, "result": result, "input_identity": ident,
         "detail": detail, "invalidated_by": inv}
    r.update(extra)
    return r

def do_file(c, ctx):
    inv = ["the file bytes (sha256%s)" % (", size" if "size" in c else "")]
    try:
        h, n = sha256_file(c["path"])
    except OSError as e:
        return rec(c, "now", "FAIL", None, "unreadable: %s" % e, inv)
    bad = [] if h == c["sha256"] else ["sha256 is %s, expected %s" % (h, c["sha256"])]
    bad += ["size is %d, expected %d" % (n, c["size"])] if "size" in c and n != c["size"] else []
    good = "sha256%s match" % (" and size" if "size" in c else "")
    return rec(c, "now", "FAIL" if bad else "ok", "%s:%d" % (h, n), "%s: %s" % (c["path"], "; ".join(bad) or good), inv)

def git(repo, *args):
    env = dict((k, v) for k, v in os.environ.items() if not k.startswith("GIT_"))
    env.update(GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0", LC_ALL="C")   # status must not rewrite the index
    try:
        p = subprocess.run(["git", "-C", repo] + list(args), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, env=env, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, "", str(e)
    return p.returncode, p.stdout.decode("utf-8", "replace").strip("\n"), p.stderr.decode("utf-8", "replace").strip()

def do_git(c, ctx):
    repo, br, want, tree, remote = c["repo"], c["branch"], c["commit"], c.get("tree"), c.get("require_remote")
    clean = c.get("require_clean", True)
    any_commit = want == "*"
    inv = (["the branch checked out" if any_commit else "HEAD (the checked-out commit and branch)"]
           + (["the working tree and index (any uncommitted or untracked change)"] if clean else [])
           + (["the remote-tracking ref %s/%s" % (remote, br)] if remote else [])
           + (["the tree HEAD:%s" % tree["path"]] if tree else []))
    rc, head, err = git(repo, "rev-parse", "--verify", "-q", "HEAD^{commit}")
    if rc != 0 or not OBJ_RE.match(head):
        return rec(c, "now", "FAIL", None, "no readable HEAD in %s: %s" % (repo, err or "rev-parse failed"), inv)
    ident, bad, notes, extra = head, [], [], {}
    if not any_commit and head != want: bad.append("HEAD is %s, expected %s" % (head, want))
    if any_commit: notes.append("any commit (tree-only identity): HEAD %s" % head[:12])
    # the full ref is compared: "--short" may print "heads/<branch>" when a tag or remote ref has the same name
    rc, cur, _ = git(repo, "symbolic-ref", "-q", "HEAD")
    if rc != 0 or cur != "refs/heads/" + br:
        bad.append("%s, expected refs/heads/%s" % ("HEAD is detached" if rc != 0 else "HEAD is " + cur, br))
    rc, st, err = git(repo, "status", "--porcelain=v1", "--untracked-files=normal")
    dirty = [x for x in st.splitlines() if x.strip()]
    if rc != 0:
        bad.append("git status failed: %s" % err)
    elif dirty and clean:
        bad.append("working tree not clean: %d entries (first: %s)" % (len(dirty), dirty[0].strip()))
    elif dirty:   # a cached check does not use or store a cache entry for an identity marked partial
        extra["identity_partial"] = "%d uncommitted/untracked entries" % len(dirty)
        notes.append("%d uncommitted/untracked entries; not required clean, and the identity does not cover them"
                     % len(dirty))
    else:
        notes.append("working tree clean")
    if remote:
        rc, r, _ = git(repo, "rev-parse", "--verify", "-q", "refs/remotes/%s/%s^{commit}" % (remote, br))
        if rc != 0 or r != (head if any_commit else want):
            bad.append("%s/%s is %s, expected %s" % (remote, br, r if rc == 0 else "missing", head if any_commit else want))
        notes.append("no fetch was performed by this tool: %s/%s is the ref as last fetched" % (remote, br))
    if tree:   # "HEAD:<path>^{tree}" does not peel after a path, so the object type is asked separately
        rc, t, _ = git(repo, "rev-parse", "--verify", "-q", "HEAD:" + tree["path"])
        rc2, typ, _ = git(repo, "cat-file", "-t", t) if rc == 0 else (1, "", "")
        t = t if rc == 0 and rc2 == 0 and typ == "tree" else "missing"
        ident = "%s=%s" % (tree["path"], t) if any_commit else "%s %s=%s" % (head, tree["path"], t)
        if t != tree["hash"]: bad.append("tree HEAD:%s is %s, expected %s" % (tree["path"], t, tree["hash"]))
    if bad: return rec(c, "now", "FAIL", ident, "; ".join(bad + notes), inv, **extra)
    return rec(c, "now", "ok", ident, "HEAD %s on %s%s; %s" % (head[:12], br, "; tree matches" if tree else "",
                                                                 "; ".join(notes)), inv, **extra)

def manifest_bytes(root, name, want):
    """reads root/name ONCE: the bytes that were hashed are the bytes that are parsed"""
    path = os.path.join(root, name)
    try:
        raw = read_regular(path)
    except OSError as e:
        return path, None, None, "manifest unreadable: %s" % e
    h = sha256_bytes(raw)
    prob = "manifest %s bytes do not match: sha256 %s, expected %s" % (path, h, want)
    return path, raw, h, None if h == want else prob

def listed(root, raw):
    real_root, entries, refused = os.path.realpath(root), [], []
    for i, line in enumerate(raw.decode("utf-8", "replace").splitlines(), 1):
        m = SUM_LINE.match(line)
        rel = m.group(2) if m else ""
        full = os.path.join(root, rel)
        if not m:
            refused.append("line %d is not '<sha256>  <path>'" % i)
        elif not _rel(rel):
            refused.append("line %d: %s is absolute or leaves the root" % (i, rel))
        elif not os.path.realpath(full).startswith(real_root + os.sep):
            refused.append("line %d: %s resolves outside the root" % (i, rel))
        elif "token" in (os.path.basename(full).lower(), os.path.basename(os.path.realpath(full)).lower()):
            refused.append("line %d: a file named 'token' is never read" % i)
        else:
            entries.append((m.group(1).lower(), rel, full))
    return entries, refused

def do_manifest(c, ctx):
    inv = ["the manifest file bytes"] + (["the bytes of any listed file"] if c["verify_listed"] else [])
    path, raw, h, prob = manifest_bytes(c["root"], c["manifest"], c["manifest_sha256"])
    if prob: return rec(c, "now", "FAIL", h, prob + "; listed files not examined", inv, listed_files_verified=False)
    if not c["verify_listed"]:
        return rec(c, "now", "ok", h, "manifest bytes verified; listed files NOT re-verified (%s)" % path, inv,
                   listed_files_verified=False, identity_partial="the listed files (not re-verified)")
    entries, refused = listed(c["root"], raw)
    if refused or not entries:   # an empty listing would make "listed files verified" vacuous
        return rec(c, "now", "FAIL", h, "manifest bytes verified; listing refused, no listed file read: %s"
                   % ("; ".join(refused[:3]) or "the manifest lists no files"), inv, listed_files_verified=False)
    bad = []
    for want, rel, full in entries:
        try:
            got = sha256_file(full)[0]
        except OSError:
            got = None
        if got != want: bad.append("%s %s" % (rel, "missing or unreadable" if got is None else "changed"))
    counts = {"listed": len(entries), "ok": len(entries) - len(bad), "not_ok": len(bad)}
    detail = "manifest bytes verified; %d listed files re-hashed now: %d ok, %d not ok" % (
        len(entries), counts["ok"], len(bad))
    return rec(c, "now", "FAIL" if bad else "ok", h, detail + (" (%s)" % "; ".join(bad[:5]) if bad else ""), inv,
               listed_files_verified=not bad, listed_counts=counts)

def do_reuse(c, ctx):
    req = c["requires"]
    inv = sorted(req)
    try:
        raw = read_regular(c["record"])
    except OSError as e:
        return rec(c, "reused", "FAIL", None, "the reused record is unreadable: %s" % e, inv)
    h, fails, notes, changed, partial = sha256_bytes(raw), [], [], [], []
    if h != c["record_sha256"]:
        fails.append("the record's bytes changed: sha256 %s, expected %s" % (h, c["record_sha256"]))
    elif not re.search(c["expect"], raw.decode("utf-8", "replace"), re.M):
        fails.append("expect /%s/ does not match the record" % c["expect"])
    em = c.get("evidence_manifest")
    if em:
        path, _, _, prob = manifest_bytes(em["root"], em["manifest"], em["manifest_sha256"])
        if prob: fails.append("evidence " + prob)
        else: notes.append("evidence manifest %s: manifest bytes verified; listed files NOT re-verified" % path)
    for rid in inv:
        d = ctx["done"][rid]
        if d["result"] != "ok" or d["input_identity"] != req[rid]:
            changed.append("%s: required %s, now %s%s" % (rid, req[rid], d["input_identity"],
                                                          "" if d["result"] == "ok" else " (result %s)" % d["result"]))
        elif "identity_partial" in d:
            notes.append("note: the identity of %s does not cover %s" % (rid, d["identity_partial"]))
            partial.append(rid)
    # a partial input is carried on, so a cached check keyed on this reuse does not use the cache either
    extra = {"identity_partial": "via " + ", ".join(partial)} if partial else {}
    if not req: notes.append("requires is empty: no current input is tied to this reuse")
    changed = ["changed inputs: " + "; ".join(changed)] if changed else []
    if fails: return rec(c, "reused", "FAIL", h, "; ".join(fails + changed), inv)
    if changed:
        return rec(c, "reused", "INVALIDATED", h, "%s; the reused result (%s) no longer applies; the original "
                   "check was not repeated" % (changed[0], c["covers"]), inv)
    return rec(c, "reused", "ok", h, "; ".join(["reused: %s; the record's bytes verified; the original check was not "
                                                "repeated" % c["covers"]] + notes), inv, **extra)

def run_argv(c, work):
    """runs argv now (no shell, cwd unchanged, stdin closed) and stores exit, stdout and stderr in <work>/<id>.out;
    the expect regex is matched against stdout only"""
    out = os.path.abspath(os.path.join(work, c["id"] + ".out"))
    rc, err, so, se = None, None, b"", b""
    try:
        p = subprocess.run(c["argv"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=TIMEOUT_S)
        rc, so, se = p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired as e:
        err, so, se = "timed out after %d s" % TIMEOUT_S, e.stdout or b"", e.stderr or b""
    except OSError as e:
        err = "could not start: %s" % e
    head = "# readiness.py check %s argv %s exit %s%s\n" % (c["id"], json.dumps(c["argv"]), rc,
                                                           " (%s)" % err if err else "")
    data = head.encode("utf-8") + b"# stdout %d bytes\n" % len(so) + so + b"\n# stderr %d bytes\n" % len(se) + se
    write_out(out, data)
    probs = [err] if err else []
    if not err and rc != c.get("expect_exit", 0): probs.append("exit %d, expected %d" % (rc, c.get("expect_exit", 0)))
    if not err and "expect" in c and not re.search(c["expect"], so.decode("utf-8", "replace"), re.M):
        probs.append("stdout does not match /%s/" % c["expect"])
    good = "exit %s%s" % (rc, ", stdout matches /%s/" % c["expect"] if "expect" in c else "")
    return ("FAIL" if probs else "ok"), ("; ".join(probs) or good), out, sha256_bytes(data), rc

def do_command(c, ctx):
    res, detail, out, osha, _ = run_argv(c, ctx["work"])
    return rec(c, "now", res, osha, "performed now: %s; output %s" % (detail, out), ["always re-run (time-sensitive)"],
               output=out)

def do_cached(c, ctx):
    inv = list(c["inputs"]) + ["the validator file bytes", "validator_version", "argv", "expect_exit / expect"]
    notok = [i for i in c["inputs"] if ctx["done"][i]["result"] != "ok"]
    if notok: return rec(c, "now", "FAIL", None, "not run: input check(s) not ok: %s" % ", ".join(notok), inv)
    try:
        vsha = sha256_file(c["validator"])[0]
    except OSError as e:
        return rec(c, "now", "FAIL", None, "not run: validator unreadable: %s" % e, inv)
    key_obj = {"schema": KEY_SCHEMA, "validator_sha256": vsha, "validator_version": c["validator_version"],
               "argv": c["argv"], "expect_exit": c.get("expect_exit", 0), "expect": c.get("expect"),
               "inputs": sorted([i, ctx["done"][i]["input_identity"]] for i in c["inputs"])}
    key = sha256_bytes(json.dumps(key_obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii"))
    # an input whose identity does not cover its content (a dirty tree not required clean, a manifest whose listed
    # files were not re-verified) cannot key a cache: no entry is used or stored, and the validator runs now
    partial = [i for i in c["inputs"] if "identity_partial" in ctx["done"][i]]
    why = ("cache not used: the identity of %s does not cover it; " % ", ".join(
        "%s (%s)" % (i, ctx["done"][i]["identity_partial"]) for i in partial) if partial else "cache miss, ")
    for path, fsha, entries in ([] if partial else ctx["cache_in"]):
        e = entries.get(key)
        if isinstance(e, dict) and e.get("key") == key and e.get("result") == "ok":
            ctx["cache_out"][key] = e
            return rec(c, "cached", "ok", key, "cache hit in %s (file sha256 %s): entry produced %s; the validator was "
                       "not run now" % (path, fsha[:16], e.get("produced_utc")), inv, cache_file=path)
    if not ctx["work"]: return rec(c, "now", "FAIL", key, why + "and no --work given: not run", inv)
    produced = iso(utc_now())
    res, detail, out, osha, rc = run_argv(c, ctx["work"])
    if res == "ok" and not partial:   # only ok results are stored: a failed result is never reused
        ctx["cache_out"][key] = {"key": key, "id": c["id"], "result": "ok", "produced_utc": produced,
                                 "run_id": ctx["run_id"], "tool_version": TOOL_VERSION, "key_inputs": key_obj,
                                 "validator": c["validator"], "exit": rc, "output": out, "output_sha256": osha}
    extra = {"identity_partial": "via " + ", ".join(partial)} if partial else {}   # carried on to later checks
    return rec(c, "now", res, key, "%srun now: %s; output %s" % (why, detail, out), inv, output=out, **extra)

DO = {"file": do_file, "git": do_git, "manifest": do_manifest, "reuse": do_reuse, "cached": do_cached,
      "command": do_command}

def load_cache(path):
    raw, obj = load_json(path, "cache file")
    need(isinstance(obj, dict) and obj.get("schema") == SCHEMA_CACHE and isinstance(obj.get("entries"), dict), path,
         "not a %s file" % SCHEMA_CACHE)
    return os.path.abspath(path), sha256_bytes(raw), obj["entries"]

def short(s):
    s = "-" if s is None else s
    return s if len(s) <= 16 else s[:16] + "…"

def render(r):
    rows = [("PERFORMED", "RESULT", "ID", "IDENTITY", "DETAIL")]
    rows += [(x["performed"].upper(), x["result"], x["id"], short(x["input_identity"]), x["detail"])
             for x in r["checks"]]
    w = [max(len(row[i]) for row in rows) for i in range(4)]
    s = r["summary"]
    lines = ["run readiness record: run %s" % r["run_id"], "tool %s sha256 %s" % (r["tool_version"], r["tool_sha256"]),
             "manifest %s sha256 %s" % (r["manifest_path"], r["manifest_sha256"]),
             "roots: evidence %s; state %s (as declared)" % (r["roots"]["evidence"], r["roots"]["state"]),
             "created %s, finished %s" % (r["created_utc"], r["finished_utc"]),
             "hashing this record verifies its own bytes only; REUSED and CACHED rows were not performed now", ""]
    lines += ["  ".join(row[i].ljust(w[i]) for i in range(4)) + "  " + row[4] for row in rows]
    lines += ["", "summary: ok %d, FAIL %d, INVALIDATED %d; performed now %d, reused %d, cached %d" % (
        s["ok"], s["fail"], s["invalidated"], s["performed_now"], s["reused"], s["cached"]), "RESULT: %s" % r["RESULT"]]
    return "\n".join(lines) + "\n"

def cmd_check(a):
    mraw, m = load_json(a.manifest, "readiness manifest")
    validate(m)
    checks = m["checks"]
    need(a.work is None or os.path.isdir(a.work), "--work", "%s is not an existing directory" % a.work)
    need(a.work is not None or all(c["kind"] != "command" for c in checks), "--work", "command checks need --work")
    caches = [load_cache(p) for p in a.cache_in]
    outs = [a.record_json, a.record_txt] + ([a.cache_out] if a.cache_out else [])
    if a.work: outs += [os.path.join(a.work, c["id"] + ".out") for c in checks if c["kind"] in ("command", "cached")]
    reals = [os.path.realpath(p) for p in outs]
    need(len(set(reals)) == len(reals) and not set(reals) & set(os.path.realpath(p) for p in [a.manifest] + a.cache_in),
         "outputs", "the output paths must differ from each other and from the inputs")
    for p in outs:
        precheck_out(p)
    tool_sha, created = self_sha(), iso(utc_now())   # created = before the first check (conservative for the gate)
    ctx = {"done": {}, "work": a.work, "cache_in": caches, "cache_out": {}, "run_id": m["run_id"]}
    for c in checks:
        ctx["done"][c["id"]] = DO[c["kind"]](c, ctx)
    results = [ctx["done"][c["id"]] for c in checks]
    count = lambda k, v: sum(1 for x in results if x[k] == v)   # noqa: E731
    summary = {"ok": count("result", "ok"), "fail": count("result", "FAIL"),
               "invalidated": count("result", "INVALIDATED"), "performed_now": count("performed", "now"),
               "reused": count("performed", "reused"), "cached": count("performed", "cached")}
    record = {"schema": SCHEMA_REC, "tool_version": TOOL_VERSION, "tool_sha256": tool_sha,
              "manifest_path": os.path.abspath(a.manifest), "manifest_sha256": sha256_bytes(mraw),
              "run_id": m["run_id"],
              "roots": m["roots"], "created_utc": created, "finished_utc": iso(utc_now()),
              "cache_in": [{"path": p, "sha256": h} for p, h, _ in caches],
              "cache_out": os.path.abspath(a.cache_out) if a.cache_out else None,
              "work": os.path.abspath(a.work) if a.work else None, "checks": results, "summary": summary,
              "RESULT": "ok" if summary["ok"] == len(results) else "not ready"}
    if "notes" in m: record["notes"] = m["notes"]
    text = render(record)
    write_out(a.record_json, (json.dumps(record, indent=1, ensure_ascii=False) + "\n").encode("utf-8"))
    write_out(a.record_txt, text.encode("utf-8"))
    if a.cache_out:
        cache = {"schema": SCHEMA_CACHE, "tool_version": TOOL_VERSION, "created_utc": iso(utc_now()),
                 "run_id": m["run_id"], "entries": ctx["cache_out"]}
        write_out(a.cache_out, (json.dumps(cache, indent=1, sort_keys=True) + "\n").encode("utf-8"))
    sys.stdout.write(text)
    return 0 if record["RESULT"] == "ok" else 1

def not_before(v):
    try:
        if v.startswith("@"):
            ns = os.stat(v[1:]).st_mtime_ns   # rounded UP to the microsecond: never earlier than the real mtime
            return EPOCH + datetime.timedelta(microseconds=-(-ns // 1000))
        return parse_iso(v).astimezone(datetime.timezone.utc)   # printed with "Z" below, so held in UTC
    except (OSError, ValueError) as e:
        raise Refused("--not-before: %s" % e)

def gate_line(name, good, text):
    print("gate %-10s %-7s %s" % (name, "ok" if good else "REFUSED", text))
    return good

def cmd_gate(a):
    pin = a.sha256.lower()
    need(HEX64.match(pin), "--sha256", "must be 64 hex digits")
    need(a.max_age_s is None or a.max_age_s >= 0, "--max-age-s", "must be >= 0")
    nb = not_before(a.not_before) if a.not_before is not None else None
    try:
        raw = read_regular(a.record)
    except OSError as e:
        raise Refused("record unreadable: %s" % e)
    now, h = utc_now(), sha256_bytes(raw)
    if not gate_line("pin", h == pin, "record %s sha256 %s; pinned %s" % (a.record, h, pin)):
        print("gate: REFUSED (no other condition evaluated: this file is not the pinned record)")
        return 2
    try:
        r = json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs)
        created, s = parse_iso(r["created_utc"]), r["summary"]
        res_ok = (r["schema"] == SCHEMA_REC and r["RESULT"] == "ok" and s["fail"] == 0 and s["invalidated"] == 0
                  and all(x["result"] == "ok" for x in r["checks"]))
        res_text = "schema %s, RESULT %s, fail %s, invalidated %s, %d checks" % (
            r["schema"], r["RESULT"], s["fail"], s["invalidated"], len(r["checks"]))
    except (ValueError, KeyError, TypeError, AttributeError) as e:
        gate_line("record", False, "not a readable readiness record: %r" % (e,))
        return 2
    good = [gate_line("result", res_ok, res_text)]
    if a.max_age_s is not None:
        age = (now - created).total_seconds()
        good.append(gate_line("max-age", -60 <= age <= a.max_age_s, "created %s: age %.1f s, allowed 0..%d s (and at "
                              "most 60 s in the future)" % (r["created_utc"], age, a.max_age_s)))
    if nb is not None:
        good.append(gate_line("not-before", created > nb, "created %s must be later than %s"
                              % (r["created_utc"], iso(nb))))
    print("gate: %s for run %s" % ("PASS" if all(good) else "REFUSED", r.get("run_id")))
    return 0 if all(good) else 2

def main(argv):
    try:
        sys.stdout.reconfigure(errors="backslashreplace")
    except AttributeError:
        pass
    ap = argparse.ArgumentParser(prog="readiness.py", description="see the module docstring", allow_abbrev=False)
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("check", allow_abbrev=False)
    for name in ("manifest", "record_json", "record_txt"):
        p.add_argument(name)
    p.add_argument("--cache-in", action="append", default=[])
    p.add_argument("--cache-out")
    p.add_argument("--work")
    g = sub.add_parser("gate", allow_abbrev=False)
    g.add_argument("record")
    g.add_argument("--sha256", required=True)
    g.add_argument("--max-age-s", type=int)
    g.add_argument("--not-before")
    sub.add_parser("selfhash", allow_abbrev=False)
    a = ap.parse_args(argv)
    try:
        if a.cmd == "check": return cmd_check(a)
        if a.cmd == "gate": return cmd_gate(a)
        if a.cmd == "selfhash":
            print("%s  %s\nTOOL_VERSION %s" % (self_sha(), os.path.abspath(__file__), TOOL_VERSION))
            return 0
        ap.print_usage(sys.stderr)
        return 2
    except Refused as e:
        print("readiness.py: REFUSED: %s" % e, file=sys.stderr)
        return 2

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
