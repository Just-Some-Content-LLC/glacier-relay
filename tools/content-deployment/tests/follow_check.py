# M6-F2a: the follow-matrix's checker of one lift-follow outcome (follow-matrix.sh). Reads <label>-follow-result.json and the
# action's output; judges the scenario's expected stop and request count (python expressions over the result `d`), the class of
# every classified slot, the follow's own limits (the critical EVIDENCE lines), the EVIDENCE line count and — per phase — the
# early-sample targets: "fast" phases must meet them (first request within its target after the observed terminal, a later-frame
# first read, the first later observation within its native-clock target); "slow" phases must meet the request target and show
# the observation target missed (the 700 ms fake frames make it unreachable — the check proves the target is really judged);
# "none" (an original that is not followed) has no read to judge. Prints one "ok: ..." / "FAIL: ..." line per check and exits
# 0 only when it printed every line it should and none of them failed; a crash or a malformed input exits non-zero.
#   python3 -I follow_check.py <follow-result.json> <op output> <phase> <stop expression> <requests expression> <class|-> <fast|slow|none>
import json
import re
import sys

fr, opout, ph, stop_x, req_x, cls, timing = sys.argv[1:8]
d = json.load(open(fr))
txt = open(opout).read()
out = []


def chk(name, ok):
    out.append(("ok: " if ok else "FAIL: ") + ph + ": " + name)


def line(name):
    m = re.search(r"EVIDENCE follow\." + re.escape(name) + r": (ok|NOT)", txt)
    return m.group(1) if m else None


chk("the follow stop satisfies [%s] (stop %r)" % (stop_x, d["stop"]), bool(eval(stop_x, {"d": d})))
chk("the requests satisfy [%s] (%s request(s), %s missed)" % (req_x, d["requests"], d["missed"]), bool(eval(req_x, {"d": d})))
if cls != "-":
    got = [s.get("class") for s in d["slots"] if s["outcome"] == "requested"]
    chk("every classified slot is %s (%s)" % (cls, got), all(c == cls for c in got if c is not None) and any(c == cls for c in got))
crit = ["at-most-six-requests", "one-in-flight", "no-catch-up", "only-reads-after-the-lift", "classes-committed", "journal-agrees",
        "plan-armed-before-lift", "observations-journaled"]
bad = [c for c in crit if line(c) != "ok"]
chk("the follow's own limits held (%s; not ok: %s)" % (" / ".join(crit), bad), bad == [])
n = len(re.findall(r"EVIDENCE follow\.", txt))
chk("14 follow EVIDENCE lines (%d)" % n, n == 14)
t = {k: line(k) for k in ("first-request-within-target", "first-observation-later-frame", "first-observation-within-target")}
if timing == "fast":
    chk("the early-sample targets are met (%s)" % t, all(v == "ok" for v in t.values()))
elif timing == "slow":
    chk("slow frames: the request target met, a later-frame first read, the observation target MISSED as expected (%s)" % t,
        t["first-request-within-target"] == "ok" and t["first-observation-later-frame"] == "ok" and t["first-observation-within-target"] == "NOT")
elif timing == "none":
    chk("no read to judge: the timing lines are NOT (%s)" % t, all(v == "NOT" for v in t.values()))
else:
    raise SystemExit("unknown timing expectation %r" % timing)
expected = 6 if cls != "-" else 5
print("\n".join(out))
sys.exit(0 if len(out) == expected and not any(x.startswith("FAIL") for x in out) else 1)
