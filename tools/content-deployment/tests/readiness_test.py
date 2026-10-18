"""Tests for ../readiness.py. The tool runs as a subprocess (python3 -I <tool>) against fixtures created in a fresh
temporary directory that is removed afterwards; nothing outside that directory is read or written by the fixtures.

  python3 -I -m unittest discover -s <this directory> -p 'readiness_test.py' -v
"""
import datetime, hashlib, json, os, re, shutil, subprocess, sys, tempfile, unittest

TOOL = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "readiness.py")
PY = sys.executable
SCHEMA = "glacier-relay.run-readiness/1"


def sha(b):
    return hashlib.sha256(b).hexdigest()


def fsha(path):
    with open(path, "rb") as f:
        return sha(f.read())


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


class Base(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="readiness-test-")
        self.addCleanup(shutil.rmtree, self.d)   # runs even when a subclass setUp (e.g. the git fixture) fails
        self.n = 0

    def write(self, rel, data):
        p = os.path.join(self.d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data if isinstance(data, bytes) else data.encode("utf-8"))
        return p

    def tool(self, *args):
        return subprocess.run([PY, "-I", TOOL] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              encoding="utf-8")

    def check(self, checks, *extra, work=True, prep=None, top=None):
        """writes a manifest into a fresh run directory and runs `check`; returns (process, record or None, run dir)"""
        self.n += 1
        run = os.path.join(self.d, "run%d" % self.n)
        os.mkdir(run)
        m = {"schema": SCHEMA, "run_id": "test-%d" % self.n, "checks": checks,
             "roots": {"evidence": run, "state": os.path.join(self.d, "st")}}
        m.update(top or {})
        mp = os.path.join(run, "manifest.json")
        with open(mp, "w") as f:
            json.dump(m, f)
        args = ["check", mp, os.path.join(run, "record.json"), os.path.join(run, "record.txt")] + list(extra)
        if work:
            os.mkdir(os.path.join(run, "work"))
            args += ["--work", os.path.join(run, "work")]
        if prep:
            prep(run)
        p = self.tool(*args)
        rj = os.path.join(run, "record.json")
        rec = None
        if p.returncode != 2 and os.path.isfile(rj) and not os.path.islink(rj) and os.path.getsize(rj):
            with open(rj) as f:
                rec = json.load(f)
            self.invariants(p, rec, run)
        return p, rec, run

    def invariants(self, p, rec, run):
        """what every written record must hold, whatever the test is about"""
        n = {}
        for c in rec["checks"]:
            self.assertIn(c["performed"], ("now", "reused", "cached"), c)
            self.assertIn(c["result"], ("ok", "FAIL", "INVALIDATED"), c)
            self.assertIsInstance(c["invalidated_by"], list, c)
            self.assertTrue(c["invalidated_by"] or c["kind"] == "reuse", c)   # reuse: its requires ids, maybe none
            self.assertEqual(c["performed"] == "reused", c["kind"] == "reuse", c)
            for k in (c["performed"], c["result"]):
                n[k] = n.get(k, 0) + 1
        s = rec["summary"]
        self.assertEqual((s["ok"], s["fail"], s["invalidated"], s["performed_now"], s["reused"], s["cached"]),
                         tuple(n.get(k, 0) for k in ("ok", "FAIL", "INVALIDATED", "now", "reused", "cached")))
        self.assertEqual(rec["RESULT"], "ok" if s["ok"] == len(rec["checks"]) else "not ready")
        self.assertEqual(p.returncode, 0 if rec["RESULT"] == "ok" else 1)
        with open(os.path.join(run, "record.txt"), encoding="utf-8") as t:
            text = t.read()
        self.assertTrue(text.endswith("RESULT: %s\n" % rec["RESULT"]), text[-200:])
        for c in rec["checks"]:
            self.assertRegex(text, r"(?m)^%s +%s +%s " % (c["performed"].upper(), c["result"], re.escape(c["id"])))

    def assertNothingWritten(self, run):
        for name in ("record.json", "record.txt"):
            self.assertFalse(os.path.exists(os.path.join(run, name)), name)

    def one(self, rec, cid):
        return [c for c in rec["checks"] if c["id"] == cid][0]

    def file_check(self, cid, path, **kw):
        c = {"id": cid, "kind": "file", "path": path, "sha256": fsha(path)}
        c.update(kw)
        return c


class FileChecks(Base):
    def test_ok(self):
        f = self.write("a.bin", b"hello")
        p, rec, run = self.check([self.file_check("a", f, size=5)])
        self.assertEqual(p.returncode, 0, p.stderr)
        c = self.one(rec, "a")
        self.assertEqual((c["result"], c["performed"], c["input_identity"]), ("ok", "now", sha(b"hello") + ":5"))
        self.assertEqual(rec["RESULT"], "ok")
        self.assertEqual(rec["manifest_sha256"], fsha(os.path.join(run, "manifest.json")))
        self.assertEqual(rec["tool_sha256"], fsha(TOOL))
        with open(os.path.join(run, "record.txt"), encoding="utf-8") as t:
            text = t.read()
        self.assertIn("RESULT: ok", text)
        self.assertIn(sha(b"hello")[:16] + "…", text)

    def test_hash_mismatch(self):
        f = self.write("a.bin", b"hello")
        p, rec, _ = self.check([self.file_check("a", f, sha256=sha(b"other"))])
        self.assertEqual(p.returncode, 1)
        self.assertEqual(self.one(rec, "a")["result"], "FAIL")
        self.assertEqual(rec["RESULT"], "not ready")

    def test_size_mismatch(self):
        f = self.write("a.bin", b"hello")
        p, rec, _ = self.check([self.file_check("a", f, size=6)])
        self.assertEqual(p.returncode, 1)
        self.assertIn("size is 5, expected 6", self.one(rec, "a")["detail"])

    def test_missing_file_fails(self):
        p, rec, _ = self.check([{"id": "a", "kind": "file", "path": os.path.join(self.d, "nope"), "sha256": "0" * 64}])
        self.assertEqual(p.returncode, 1)
        self.assertIn("missing", self.one(rec, "a")["detail"])

    def test_token_basename_refused(self):
        f = self.write("sub/token", b"secret-value")
        link = os.path.join(self.d, "innocent-name")
        os.symlink(f, link)   # refused on the resolved name too
        for path in (f, link):
            with self.subTest(path=path):
                p, rec, run = self.check([{"id": "t", "kind": "file", "path": path, "sha256": "0" * 64}])
                self.assertEqual(p.returncode, 2)
                self.assertIn("basename is 'token' is never read", p.stderr)
                self.assertNotIn("secret-value", p.stdout + p.stderr)
                self.assertNothingWritten(run)


class GitChecks(Base):
    def g(self, *args):
        env = dict((k, v) for k, v in os.environ.items() if not k.startswith("GIT_"))
        env.update(HOME=self.d, GIT_CONFIG_NOSYSTEM="1")   # the fixture's git ignores the user's global configuration
        return subprocess.run(["git", "-C", self.repo] + list(args), env=env, check=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, encoding="utf-8").stdout.strip()

    def setUp(self):
        Base.setUp(self)
        self.repo = os.path.join(self.d, "repo")
        os.mkdir(self.repo)
        self.g("init", "-q")
        self.g("symbolic-ref", "HEAD", "refs/heads/main")
        self.g("config", "user.name", "readiness test")
        self.g("config", "user.email", "readiness-test@example.invalid")
        self.g("config", "commit.gpgsign", "false")
        self.write("repo/relay/lib/a.ex", "one\n")
        self.g("add", "-A")
        self.g("commit", "-q", "-m", "one")
        self.c1, self.t1 = self.g("rev-parse", "HEAD"), self.g("rev-parse", "HEAD:relay/lib")
        self.write("repo/relay/lib/a.ex", "two\n")
        self.g("commit", "-q", "-am", "two")
        self.c2, self.t2 = self.g("rev-parse", "HEAD"), self.g("rev-parse", "HEAD:relay/lib")

    def gc(self, **kw):
        c = {"id": "g", "kind": "git", "repo": self.repo, "branch": "main", "commit": self.c2}
        c.update(kw)
        return c

    def test_head_ok(self):
        p, rec, _ = self.check([self.gc()])
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.one(rec, "g")["input_identity"], self.c2)

    def test_wrong_commit_fails(self):
        p, rec, _ = self.check([self.gc(commit=self.c1)])
        self.assertEqual(p.returncode, 1)
        self.assertIn("HEAD is %s, expected %s" % (self.c2, self.c1), self.one(rec, "g")["detail"])

    def test_wrong_branch_fails(self):
        p, rec, _ = self.check([self.gc(branch="relay/m2")])
        self.assertEqual(p.returncode, 1)
        self.assertIn("HEAD is refs/heads/main, expected refs/heads/relay/m2", self.one(rec, "g")["detail"])

    def test_tag_named_like_the_branch(self):
        self.g("tag", "main")   # "symbolic-ref --short" would print "heads/main" here
        p, rec, _ = self.check([self.gc()])
        self.assertEqual(p.returncode, 0, p.stdout)

    def test_dirty_tree(self):
        p, rec, _ = self.check([self.gc(require_clean=False)])
        self.assertNotIn("identity_partial", self.one(rec, "g"))   # clean: the identity covers the tree
        self.write("repo/relay/lib/a.ex", "edited\n")
        p, rec, _ = self.check([self.gc()])
        self.assertEqual(p.returncode, 1)
        self.assertIn("not clean", self.one(rec, "g")["detail"])
        p, rec, _ = self.check([self.gc(require_clean=False)])
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertIn("identity does not cover them", self.one(rec, "g")["detail"])
        self.assertEqual(self.one(rec, "g")["identity_partial"], "1 uncommitted/untracked entries")

    def test_untracked_file_is_dirty(self):
        self.write("repo/new.txt", "x")
        p, rec, _ = self.check([self.gc()])
        self.assertEqual(p.returncode, 1)

    def test_tree_ok_and_changed(self):
        p, rec, _ = self.check([self.gc(tree={"path": "relay/lib", "hash": self.t2})])
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertEqual(self.one(rec, "g")["input_identity"], "%s relay/lib=%s" % (self.c2, self.t2))
        p, rec, _ = self.check([self.gc(tree={"path": "relay/lib", "hash": self.t1})])
        self.assertEqual(p.returncode, 1)
        self.assertIn("tree HEAD:relay/lib is %s, expected %s" % (self.t2, self.t1), self.one(rec, "g")["detail"])

    def test_remote_tracking_ref(self):
        self.g("update-ref", "refs/remotes/origin/main", self.c2)
        p, rec, _ = self.check([self.gc(require_remote="origin")])
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertIn("no fetch was performed", self.one(rec, "g")["detail"])
        self.g("update-ref", "refs/remotes/origin/main", self.c1)
        p, rec, _ = self.check([self.gc(require_remote="origin")])
        self.assertEqual(p.returncode, 1)

    def test_tree_only_identity(self):
        # "commit": "*" with a tree: any commit on the branch; the identity is the tree alone
        c = self.gc(commit="*", tree={"path": "relay/lib", "hash": self.t2})
        p, rec, _ = self.check([c])
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.one(rec, "g")["input_identity"], "relay/lib=%s" % self.t2)
        self.assertIn("tree-only identity", self.one(rec, "g")["detail"])
        # a commit that does not touch relay/lib keeps the identity (a reuse keyed to it stays valid) ...
        self.write("repo/docs.md", "docs\n")
        self.g("add", "-A")
        self.g("commit", "-q", "-m", "docs only")
        p, rec, _ = self.check([c, {"id": "r", "kind": "reuse", "record": self.write("q.txt", "RESULT: 0\n"),
                                    "record_sha256": hashlib.sha256(b"RESULT: 0\n").hexdigest(), "expect": "RESULT: 0",
                                    "covers": "a qualification of relay/lib", "requires": {"g": "relay/lib=%s" % self.t2}}])
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.one(rec, "r")["result"], "ok")
        # ... a commit that changes relay/lib changes it: the tree check fails and the reuse is not valid
        self.write("repo/relay/lib/a.ex", "three\n")
        self.g("commit", "-q", "-am", "three")
        p, rec, _ = self.check([c])
        self.assertEqual(p.returncode, 1)
        self.assertIn("tree HEAD:relay/lib is", self.one(rec, "g")["detail"])

    def test_tree_only_requires_a_tree(self):
        p, rec, _ = self.check([self.gc(commit="*")])
        self.assertEqual(p.returncode, 2)
        self.assertIn('commit "*" (a tree-only identity) requires a "tree"', p.stderr)
        self.assertIsNone(rec)

    def test_tree_only_remote_compares_head(self):
        c = self.gc(commit="*", tree={"path": "relay/lib", "hash": self.t2}, require_remote="origin")
        self.g("update-ref", "refs/remotes/origin/main", self.c2)
        p, rec, _ = self.check([c])
        self.assertEqual(p.returncode, 0, p.stdout)
        self.g("update-ref", "refs/remotes/origin/main", self.c1)
        p, rec, _ = self.check([c])
        self.assertEqual(p.returncode, 1)
        self.assertIn("origin/main is %s, expected %s" % (self.c1, self.c2), self.one(rec, "g")["detail"])


class ManifestChecks(Base):
    def setUp(self):
        Base.setUp(self)
        self.root = os.path.join(self.d, "content")
        x, y = self.write("content/x.txt", "x\n"), self.write("content/sub/y.txt", "y\n")
        self.mf = self.write("content/MANIFEST.sha256", "%s  x.txt\n%s  sub/y.txt\n" % (fsha(x), fsha(y)))

    def mc(self, **kw):
        c = {"id": "m", "kind": "manifest", "root": self.root, "manifest": "MANIFEST.sha256",
             "manifest_sha256": fsha(self.mf), "verify_listed": False}
        c.update(kw)
        return c

    def test_bytes_only(self):
        self.write("content/sub/y.txt", "changed\n")   # not detected: the listed files are not re-verified
        p, rec, _ = self.check([self.mc()])
        self.assertEqual(p.returncode, 0, p.stdout)
        c = self.one(rec, "m")
        self.assertIn("manifest bytes verified; listed files NOT re-verified", c["detail"])
        self.assertIs(c["listed_files_verified"], False)
        self.assertIn("identity_partial", c)

    def test_empty_listing_fails(self):
        mf = self.write("content/EMPTY.sha256", b"")
        p, rec, _ = self.check([self.mc(manifest="EMPTY.sha256", manifest_sha256=fsha(mf), verify_listed=True)])
        self.assertEqual(p.returncode, 1)
        c = self.one(rec, "m")
        self.assertIn("the manifest lists no files", c["detail"])
        self.assertIs(c["listed_files_verified"], False)

    def test_verify_listed_ok(self):
        p, rec, _ = self.check([self.mc(verify_listed=True)])
        self.assertEqual(p.returncode, 0, p.stdout)
        c = self.one(rec, "m")
        self.assertIs(c["listed_files_verified"], True)
        self.assertEqual(c["listed_counts"], {"listed": 2, "ok": 2, "not_ok": 0})

    def test_verify_listed_changed_file_fails(self):
        self.write("content/sub/y.txt", "changed\n")
        p, rec, _ = self.check([self.mc(verify_listed=True)])
        self.assertEqual(p.returncode, 1)
        c = self.one(rec, "m")
        self.assertIn("sub/y.txt changed", c["detail"])
        self.assertIs(c["listed_files_verified"], False)

    def test_manifest_bytes_mismatch_fails(self):
        p, rec, _ = self.check([self.mc(manifest_sha256="1" * 64, verify_listed=True)])
        self.assertEqual(p.returncode, 1)
        self.assertIn("bytes do not match", self.one(rec, "m")["detail"])
        self.assertIs(self.one(rec, "m")["listed_files_verified"], False)

    def test_dotdot_listed_path_refused(self):
        out = self.write("outside.txt", "o\n")
        mf = self.write("content/BAD.sha256", "%s  ../outside.txt\n" % fsha(out))
        p, rec, _ = self.check([self.mc(manifest="BAD.sha256", manifest_sha256=fsha(mf), verify_listed=True)])
        self.assertEqual(p.returncode, 1)
        c = self.one(rec, "m")
        self.assertIn("leaves the root", c["detail"])
        self.assertIs(c["listed_files_verified"], False)

    def test_dotdot_manifest_name_refused(self):
        p, rec, run = self.check([self.mc(manifest="../MANIFEST.sha256")])
        self.assertEqual(p.returncode, 2)
        self.assertIn("manifest must be a relative path inside its root", p.stderr)
        self.assertNothingWritten(run)


class ReuseChecks(Base):
    def setUp(self):
        Base.setUp(self)
        self.inp = self.write("inp.txt", b"v1")
        self.ident = sha(b"v1") + ":2"
        self.rec = self.write("earlier/m0-result.txt", "M0 qualification: PASS 26/26\n")

    def rc(self, **kw):
        c = {"id": "q", "kind": "reuse", "record": self.rec, "record_sha256": fsha(self.rec), "expect": r"PASS 26/26$",
             "covers": "M0 26/26 qualification", "requires": {"inp": self.ident}}
        c.update(kw)
        return c

    def test_valid(self):
        root = os.path.join(self.d, "earlier")
        mf = self.write("earlier/MANIFEST.sha256", "%s  m0-result.txt\n" % fsha(self.rec))
        em = {"root": root, "manifest": "MANIFEST.sha256", "manifest_sha256": fsha(mf)}
        p, rec, run = self.check([self.file_check("inp", self.inp), self.rc(evidence_manifest=em)])
        self.assertEqual(p.returncode, 0, p.stdout)
        c = self.one(rec, "q")
        self.assertEqual((c["performed"], c["result"]), ("reused", "ok"))
        self.assertIn("reused: M0 26/26 qualification; the record's bytes verified; "
                      "the original check was not repeated", c["detail"])
        self.assertIn("listed files NOT re-verified", c["detail"])
        self.assertEqual(c["invalidated_by"], ["inp"])
        self.assertEqual(rec["summary"]["reused"], 1)
        with open(os.path.join(run, "record.txt"), encoding="utf-8") as t:
            self.assertIn("REUSED", t.read())

    def test_record_bytes_changed_fails(self):
        c = self.rc()
        self.write("earlier/m0-result.txt", "M0 qualification: PASS 26/26 \n")
        p, rec, _ = self.check([self.file_check("inp", self.inp), c])
        self.assertEqual(p.returncode, 1)
        self.assertIn("the record's bytes changed", self.one(rec, "q")["detail"])
        self.assertEqual(self.one(rec, "q")["result"], "FAIL")

    def test_expect_not_matching_fails(self):
        p, rec, _ = self.check([self.file_check("inp", self.inp), self.rc(expect="PASS 25/26")])
        self.assertEqual(p.returncode, 1)
        self.assertIn("does not match the record", self.one(rec, "q")["detail"])

    def test_required_identity_changed_invalidates(self):
        self.write("inp.txt", b"v2")
        p, rec, _ = self.check([self.file_check("inp", self.inp), self.rc()])
        self.assertEqual(p.returncode, 1)
        c = self.one(rec, "q")
        self.assertEqual(c["result"], "INVALIDATED")
        self.assertIn("inp: required %s, now %s" % (self.ident, sha(b"v2") + ":2"), c["detail"])
        self.assertEqual(rec["summary"]["invalidated"], 1)

    def test_required_check_failing_invalidates(self):
        p, rec, _ = self.check([self.file_check("inp", self.inp, sha256="2" * 64), self.rc()])
        self.assertEqual(self.one(rec, "q")["result"], "INVALIDATED")
        self.assertIn("(result FAIL)", self.one(rec, "q")["detail"])

    def test_partial_required_identity_is_noted_and_carried(self):
        mf = self.write("earlier/MANIFEST.sha256", "%s  m0-result.txt\n" % fsha(self.rec))
        m = {"id": "m", "kind": "manifest", "root": os.path.join(self.d, "earlier"), "manifest": "MANIFEST.sha256",
             "manifest_sha256": fsha(mf), "verify_listed": False}
        p, rec, _ = self.check([m, self.rc(requires={"m": fsha(mf)})])
        self.assertEqual(p.returncode, 0, p.stdout)
        c = self.one(rec, "q")
        self.assertIn("note: the identity of m does not cover the listed files", c["detail"])
        self.assertEqual(c["identity_partial"], "via m")

    def test_requires_later_or_unknown_id_refused(self):
        for checks in ([self.rc(), self.file_check("inp", self.inp)],
                       [self.file_check("inp", self.inp), self.rc(requires={"nope": "x"})]):
            p, rec, run = self.check(checks)
            self.assertEqual(p.returncode, 2)
            self.assertIn("not a check appearing earlier", p.stderr)
            self.assertNothingWritten(run)


VALIDATOR = """import sys
with open(sys.argv[1], "a") as f:
    f.write("run\\n")
print("VALIDATOR OK")
"""


class CachedChecks(Base):
    def setUp(self):
        Base.setUp(self)
        self.val = self.write("val.py", VALIDATOR)
        self.counter = os.path.join(self.d, "counter.txt")
        self.inp = self.write("inp.txt", b"v1")

    def runs(self):
        if not os.path.exists(self.counter):
            return 0
        with open(self.counter) as f:
            return len(f.read().splitlines())

    def checks(self, version="1", extra=()):
        return [self.file_check("inp", self.inp),
                {"id": "scan", "kind": "cached", "argv": [PY, "-I", self.val, self.counter] + list(extra),
                 "validator": self.val, "validator_version": version, "inputs": ["inp"], "expect": "^VALIDATOR OK$"}]

    def first(self):
        cache = os.path.join(self.d, "cache1.json")
        p, rec, _ = self.check(self.checks(), "--cache-out", cache)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        return cache, rec

    def test_miss_then_hit(self):
        cache, rec = self.first()
        c = self.one(rec, "scan")
        self.assertEqual((c["performed"], c["result"], self.runs()), ("now", "ok", 1))
        with open(cache) as f:
            entries = json.load(f)["entries"]
        self.assertEqual(list(entries), [c["input_identity"]])
        cache2, cache_sha = os.path.join(self.d, "cache2.json"), fsha(cache)
        p, rec, run = self.check(self.checks(), "--cache-in", cache, "--cache-out", cache2)
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertEqual(fsha(cache), cache_sha)   # the --cache-in file is not rewritten
        c2 = self.one(rec, "scan")
        self.assertEqual((c2["performed"], c2["result"], c2["input_identity"]), ("cached", "ok", c["input_identity"]))
        self.assertEqual(self.runs(), 1)   # the validator was not run
        self.assertIn(cache, c2["detail"])
        self.assertEqual(rec["summary"]["cached"], 1)
        with open(cache2) as f:
            self.assertEqual(list(json.load(f)["entries"]), [c["input_identity"]])
        with open(os.path.join(run, "record.txt"), encoding="utf-8") as t:
            self.assertIn("CACHED", t.read())

    def test_each_key_change_is_a_miss(self):
        cache, rec = self.first()
        key = self.one(rec, "scan")["input_identity"]

        def changed_validator():
            self.write("val.py", VALIDATOR + "# changed\n")
            return self.checks()

        def changed_input():
            self.write("inp.txt", b"v2")
            return self.checks()
        # each variant starts from the state the entry was produced in and changes ONE key input; the control
        # (no change) must be a hit, so a miss below is caused by that one change alone
        variants = [("none (control)", self.checks), ("validator file", changed_validator),
                    ("validator_version", lambda: self.checks(version="2")), ("input identity", changed_input),
                    ("argv", lambda: self.checks(extra=["--extra"]))]
        for name, make in variants:
            with self.subTest(change=name):
                self.write("val.py", VALIDATOR)
                self.write("inp.txt", b"v1")
                before = self.runs()
                p, rec, _ = self.check(make(), "--cache-in", cache)
                c = self.one(rec, "scan")
                self.assertEqual((p.returncode, c["result"]), (0, "ok"), p.stdout)
                if name == "none (control)":
                    self.assertEqual((c["performed"], c["input_identity"], self.runs()), ("cached", key, before))
                else:
                    self.assertEqual(c["performed"], "now")
                    self.assertNotEqual(c["input_identity"], key)
                    self.assertEqual(self.runs(), before + 1)

    def test_partial_input_identity_bypasses_the_cache(self):
        root = os.path.join(self.d, "content")
        x = self.write("content/x.txt", "x\n")
        mf = self.write("content/MANIFEST.sha256", "%s  x.txt\n" % fsha(x))

        def checks(verify):   # scan2 is keyed on scan: the partial identity must carry through
            return [{"id": "m", "kind": "manifest", "root": root, "manifest": "MANIFEST.sha256",
                     "manifest_sha256": fsha(mf), "verify_listed": verify},
                    {"id": "scan", "kind": "cached", "argv": [PY, "-I", self.val, self.counter],
                     "validator": self.val, "validator_version": "1", "inputs": ["m"]},
                    {"id": "scan2", "kind": "cached", "argv": [PY, "-I", self.val, self.counter, "second"],
                     "validator": self.val, "validator_version": "1", "inputs": ["scan"]}]
        verified, unverified = os.path.join(self.d, "verified.json"), os.path.join(self.d, "unverified.json")
        p, rec, _ = self.check(checks(True), "--cache-out", verified)   # listed files re-hashed: entries are stored
        self.assertEqual((p.returncode, self.runs()), (0, 2), p.stdout)
        with open(verified) as f:
            entries = json.load(f)["entries"]
        keys = [self.one(rec, i)["input_identity"] for i in ("scan", "scan2")]
        self.assertEqual(sorted(entries), sorted(keys))
        # the same keys, but the listed files are not re-verified now: no entry is used and none is stored
        p, rec, _ = self.check(checks(False), "--cache-in", verified, "--cache-out", unverified)
        self.assertEqual(p.returncode, 0, p.stdout)
        c, c2 = self.one(rec, "scan"), self.one(rec, "scan2")
        self.assertEqual([(x["performed"], x["input_identity"]) for x in (c, c2)], [("now", k) for k in keys])
        self.assertEqual(self.runs(), 4)
        self.assertIn("cache not used: the identity of m (the listed files (not re-verified))", c["detail"])
        self.assertIn("cache not used: the identity of scan (via m)", c2["detail"])
        with open(unverified) as f:
            self.assertEqual(json.load(f)["entries"], {})

    def test_cache_out_same_as_cache_in_refused(self):
        cache, _ = self.first()
        before = fsha(cache)
        p, rec, run = self.check(self.checks(), "--cache-in", cache, "--cache-out", cache)
        self.assertEqual(p.returncode, 2)
        self.assertIn("must differ", p.stderr)
        self.assertEqual(fsha(cache), before)
        self.assertNothingWritten(run)

    def test_input_not_ok_fails_without_running(self):
        checks = self.checks()
        checks[0]["sha256"] = "3" * 64
        p, rec, _ = self.check(checks)
        self.assertEqual(p.returncode, 1)
        self.assertIn("not run", self.one(rec, "scan")["detail"])
        self.assertEqual(self.runs(), 0)

    def test_miss_without_work_fails(self):
        p, rec, _ = self.check(self.checks(), work=False)
        self.assertEqual(p.returncode, 1)
        self.assertIn("no --work", self.one(rec, "scan")["detail"])
        self.assertEqual(self.runs(), 0)


class CommandChecks(Base):
    def cmd(self, code, **kw):
        c = {"id": "c", "kind": "command", "argv": [PY, "-I", "-c", code]}
        c.update(kw)
        return c

    def test_ok(self):
        p, rec, run = self.check([self.cmd("print('port 32123 free')", expect=r"^port \d+ free$")])
        self.assertEqual(p.returncode, 0, p.stdout)
        c = self.one(rec, "c")
        out = os.path.join(run, "work", "c.out")
        self.assertEqual((c["performed"], c["input_identity"], c["output"]), ("now", fsha(out), out))
        self.assertEqual(c["invalidated_by"], ["always re-run (time-sensitive)"])

    def test_nonzero_exit(self):
        p, rec, _ = self.check([self.cmd("import sys; sys.exit(3)")])
        self.assertEqual(p.returncode, 1)
        self.assertIn("exit 3, expected 0", self.one(rec, "c")["detail"])
        p, rec, _ = self.check([self.cmd("import sys; sys.exit(3)", expect_exit=3)])
        self.assertEqual(p.returncode, 0, p.stdout)

    def test_regex_miss(self):
        p, rec, _ = self.check([self.cmd("print('port in use')", expect="free")])
        self.assertEqual(p.returncode, 1)
        self.assertIn("does not match", self.one(rec, "c")["detail"])

    def test_cannot_start(self):
        p, rec, _ = self.check([{"id": "c", "kind": "command", "argv": [os.path.join(self.d, "no-such-program")]}])
        self.assertEqual(p.returncode, 1)
        self.assertIn("could not start", self.one(rec, "c")["detail"])

    def test_command_without_work_refused(self):
        p, rec, run = self.check([self.cmd("print(1)")], work=False)
        self.assertEqual(p.returncode, 2)
        self.assertNothingWritten(run)


class Outputs(Base):
    def setUp(self):
        Base.setUp(self)
        self.f = self.write("a.bin", b"hello")

    def test_non_empty_output_refused_and_unchanged(self):
        def prep(run):
            with open(os.path.join(run, "record.json"), "wb") as f:
                f.write(b"keep me")
        p, rec, run = self.check([self.file_check("a", self.f)], prep=prep)
        self.assertEqual(p.returncode, 2)
        with open(os.path.join(run, "record.json"), "rb") as f:
            self.assertEqual(f.read(), b"keep me")
        self.assertFalse(os.path.exists(os.path.join(run, "record.txt")))

    def test_empty_output_accepted(self):
        def prep(run):
            for name in ("record.json", "record.txt"):
                open(os.path.join(run, name), "wb").close()
        p, rec, run = self.check([self.file_check("a", self.f)], prep=prep)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(rec["RESULT"], "ok")
        self.assertGreater(os.path.getsize(os.path.join(run, "record.txt")), 0)

    def test_symlink_output_refused(self):
        target = self.write("target.txt", b"")

        def prep(run):
            os.symlink(target, os.path.join(run, "record.txt"))
        p, rec, run = self.check([self.file_check("a", self.f)], prep=prep)
        self.assertEqual(p.returncode, 2)
        self.assertEqual(os.path.getsize(target), 0)
        self.assertFalse(os.path.exists(os.path.join(run, "record.json")))

    def test_unexaminable_output_refused(self):
        self.n += 1
        run = os.path.join(self.d, "run%d" % self.n)
        mp = self.write("run%d/manifest.json" % self.n, json.dumps(
            {"schema": SCHEMA, "run_id": "r", "roots": {"evidence": run, "state": run},
             "checks": [self.file_check("a", self.f)]}))
        for out in (os.path.join(self.f, "record.txt"), os.path.join(run, "x" * 300)):   # under a file; too long
            with self.subTest(out=out[-20:]):
                p = self.tool("check", mp, os.path.join(run, "record.json"), out)
                self.assertEqual(p.returncode, 2, p.stderr)
                self.assertIn("REFUSED", p.stderr)
                self.assertNothingWritten(run)

    def test_existing_work_output_refused_before_anything_runs(self):
        def prep(run):
            with open(os.path.join(run, "work", "c.out"), "w") as f:
                f.write("earlier")
        marker = os.path.join(self.d, "ran")
        c = {"id": "c", "kind": "command", "argv": [PY, "-I", "-c", "open(%r, 'w').close()" % marker]}
        p, rec, run = self.check([c], prep=prep)
        self.assertEqual(p.returncode, 2)
        self.assertFalse(os.path.exists(marker))
        self.assertFalse(os.path.exists(os.path.join(run, "record.json")))


class Validation(Base):
    def refused(self, checks, top=None, reason=""):
        p, rec, run = self.check(checks, top=top)
        self.assertEqual(p.returncode, 2, p.stdout + p.stderr)
        self.assertIn(reason, p.stderr)
        self.assertNothingWritten(run)

    def test_refusals(self):
        f = self.write("a.bin", b"hello")
        ok = {"id": "a", "kind": "file", "path": f, "sha256": fsha(f)}
        cases = {
            "unknown kind": ([dict(ok, kind="scan")], None, "unknown or missing kind 'scan'"),
            "unhashable kind": ([dict(ok, kind=["file"])], None, "unknown or missing kind ['file']"),
            "lone surrogate": ([dict(ok, path=f + "\ud800")], None, "surrogates not allowed"),
            "NUL in argv": ([{"id": "c", "kind": "command", "argv": ["echo", "a\x00b"]}], None, "NUL character"),
            "unknown check key": ([dict(ok, colour="blue")], None, "unknown keys ['colour']"),
            "unknown top-level key": ([ok], {"extra": 1}, "unknown keys ['extra']"),
            "duplicate id": ([ok, dict(ok)], None, "duplicate id"),
            "bad id": ([dict(ok, id="Bad Id")], None, "id must match"),
            "wrong schema": ([ok], {"schema": "glacier-relay.run-readiness/2"}, "schema must be"),
            "no checks": ([], None, "non-empty list"),
            "relative path": ([dict(ok, path="a.bin")], None, "absolute path"),
            "short hash": ([dict(ok, sha256="abc")], None, "full hex digest"),
            "relative root": ([ok], {"roots": {"evidence": "ev", "state": "/st"}}, "roots.evidence"),
        }
        for name, (checks, top, reason) in cases.items():
            with self.subTest(case=name):
                self.refused(checks, top, reason)

    def test_unreadable_manifest_refused(self):
        self.n += 1
        run = os.path.join(self.d, "bad%d" % self.n)
        os.mkdir(run)
        mp = self.write("bad%d/manifest.json" % self.n, '{"schema": "x", "schema": "y"}')
        p = self.tool("check", mp, os.path.join(run, "record.json"), os.path.join(run, "record.txt"))
        self.assertEqual(p.returncode, 2)
        self.assertIn("duplicate key", p.stderr)
        self.assertNothingWritten(run)


class Gate(Base):
    def record(self, good=True):
        f = self.write("a.bin", b"hello")
        p, rec, run = self.check([self.file_check("a", f, sha256=fsha(f) if good else "4" * 64)])
        return os.path.join(run, "record.json"), rec

    def altered(self, rec, **kw):
        rec = dict(rec, **kw)
        self.n += 1
        return self.write("altered%d.json" % self.n, json.dumps(rec))

    def test_correct_pin(self):
        path, _ = self.record()
        p = self.tool("gate", path, "--sha256", fsha(path), "--max-age-s", "3600")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("gate: PASS", p.stdout)

    def test_wrong_pin_refused(self):
        path, _ = self.record()
        p = self.tool("gate", path, "--sha256", "5" * 64)
        self.assertEqual(p.returncode, 2)
        self.assertIn("not the pinned record", p.stdout)

    def test_not_ready_refused(self):
        path, rec = self.record(good=False)
        self.assertEqual(rec["RESULT"], "not ready")
        p = self.tool("gate", path, "--sha256", fsha(path))
        self.assertEqual(p.returncode, 2)
        self.assertIn("result     REFUSED", p.stdout)

    def test_age(self):
        _, rec = self.record()
        old = self.altered(rec, created_utc="2020-01-01T00:00:00.000000Z")
        p = self.tool("gate", old, "--sha256", fsha(old), "--max-age-s", "3600")
        self.assertEqual(p.returncode, 2)
        self.assertIn("max-age    REFUSED", p.stdout)
        future = iso(datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=1))
        fut = self.altered(rec, created_utc=future)
        p = self.tool("gate", fut, "--sha256", fsha(fut), "--max-age-s", "86400")
        self.assertEqual(p.returncode, 2)
        self.assertIn("max-age    REFUSED", p.stdout)
        self.assertIn("result     ok", p.stdout)

    def test_not_before_iso(self):
        path, rec = self.record()
        later = iso(datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1))
        p = self.tool("gate", path, "--sha256", fsha(path), "--not-before", later)
        self.assertEqual(p.returncode, 2)
        self.assertIn("not-before REFUSED", p.stdout)
        p = self.tool("gate", path, "--sha256", fsha(path), "--not-before", "2020-01-01T00:00:00Z")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        p = self.tool("gate", path, "--sha256", fsha(path), "--not-before", "2020-01-01T02:00:00+02:00")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("later than 2020-01-01T00:00:00.000000Z", p.stdout)   # an offset is shown converted to UTC

    def test_not_before_file_mtime(self):
        path, rec = self.record()
        ref = self.write("checkpoint", b"")
        os.utime(ref, (1577836800, 1577836800))   # 2020-01-01: before the record
        self.assertEqual(self.tool("gate", path, "--sha256", fsha(path), "--not-before", "@" + ref).returncode, 0)
        t = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1)).timestamp()
        os.utime(ref, (t, t))                       # after the record
        p = self.tool("gate", path, "--sha256", fsha(path), "--not-before", "@" + ref)
        self.assertEqual(p.returncode, 2)
        self.assertIn("not-before REFUSED", p.stdout)

    def test_bad_arguments_refused(self):
        path, _ = self.record()
        self.assertEqual(self.tool("gate", path, "--sha256", "xyz").returncode, 2)
        self.assertEqual(self.tool("gate", path, "--sha256", fsha(path), "--not-before", "yesterday").returncode, 2)


class SelfHash(Base):
    def test_selfhash(self):
        p = self.tool("selfhash")
        self.assertEqual(p.returncode, 0)
        self.assertIn(fsha(TOOL), p.stdout)
        self.assertIn("TOOL_VERSION readiness/1", p.stdout)


if __name__ == "__main__":
    unittest.main()
