"""The web channel's verdict on main, read where it lives (STATUS-jas row 271).

The web level-2 lane is ADVISORY: its job concludes success whatever its
receipt says, so a CI watcher that selects failed runs never sees a red
receipt. gradient.stop_location failed on the web on every run for four days
(11-21 08:55Z to 11-25) and nothing in the fleet read it. This tool reads the
verdict itself: the `web-l2` artifact's receipt (web-l2-receipt.txt, line 1)
from the latest completed `pages.yml` run on main, the workflow that runs the
lane on every push to main, and the run before it.

    python3 scripts/web_l2_main_verdict.py            # one line; rc 0 GREEN, 1 RED, 2 UNREAD
    python3 scripts/web_l2_main_verdict.py --self-test

The line:  WEB-L2 MAIN <GREEN|RED|UNREAD> run=<id> head=<sha8> age=<h>h prev=<GREEN|RED|UNREAD> [<why>]
UNREAD is its own verdict, never GREEN: no completed run, no artifact, no
receipt or a first line this tool cannot parse all read UNREAD, with the reason.
Two RED in a row (the verdict and prev) is a STATUS row the same day (the helm,
11-25); a single PR's red is the PR author's, and this tool does not read PRs.
"""
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile

REPO = "jyh/jas"
WORKFLOW = "pages.yml"
ARTIFACT = "web-l2"
RECEIPT = "web-l2-receipt.txt"
LINE_RE = re.compile(r"^UI-NIGHTLY v1 suite=web\.live verdict=(GREEN|RED\([^)]*\)|NOT RUN\([^)]*\)|[A-Z]+)")


def verdict_of(text):
    """(GREEN|RED|UNREAD, why) from a receipt's text. A NOT RUN reads RED: the
    lane did not run, which is not a green."""
    if text is None:
        return "UNREAD", "no receipt"
    first = text.splitlines()[0] if text.strip() else ""
    m = LINE_RE.match(first)
    if not m:
        return "UNREAD", f"line 1 is not a web.live receipt: {first[:80]!r}"
    v = m.group(1)
    if v == "GREEN":
        return "GREEN", ""
    return "RED", v


def _gh(args):
    r = subprocess.run(["gh"] + args, capture_output=True, text=True, encoding="utf-8")
    return r.stdout if r.returncode == 0 else None


def runs(n=2):
    out = _gh(["run", "list", "-R", REPO, "--workflow", WORKFLOW, "--branch", "main", "--status", "completed",
               "--limit", str(n), "--json", "databaseId,headSha,createdAt"])
    return json.loads(out) if out else None


def receipt_of(run_id):
    with tempfile.TemporaryDirectory() as d:
        if _gh(["run", "download", str(run_id), "-R", REPO, "-n", ARTIFACT, "-D", d]) is None:
            return None
        for root, _, files in os.walk(d):
            if RECEIPT in files:
                return open(os.path.join(root, RECEIPT), encoding="utf-8").read()
    return None


def line(now=None):
    rs = runs(2)
    if not rs:
        return "WEB-L2 MAIN UNREAD run=- head=- age=- prev=UNREAD (no completed pages.yml run on main could be listed)", 2
    v, why = verdict_of(receipt_of(rs[0]["databaseId"]))
    pv = verdict_of(receipt_of(rs[1]["databaseId"]))[0] if len(rs) > 1 else "UNREAD"
    now = now or datetime.datetime.now(datetime.timezone.utc)
    at = datetime.datetime.fromisoformat(rs[0]["createdAt"].replace("Z", "+00:00"))
    age = (now - at).total_seconds() / 3600
    text = (f"WEB-L2 MAIN {v} run={rs[0]['databaseId']} head={rs[0]['headSha'][:8]} age={age:.1f}h prev={pv}"
            + (f" ({why})" if why else ""))
    return text, {"GREEN": 0, "RED": 1}.get(v, 2)


def self_test():
    fails = []

    def check(cond, what):
        if not cond:
            fails.append(what)
    green = "UI-NIGHTLY v1 suite=web.live verdict=GREEN items=116/116 panels=- head=0dd13032 scope=full date=x\nLAYERS 5/5\n"
    red = "UI-NIGHTLY v1 suite=web.live verdict=RED(fail=1 refused=0) items=115/116 panels=- head=c6af3955 scope=full date=x\n"
    check(verdict_of(red) == ("RED", "RED(fail=1 refused=0)"), "a planted RED receipt reads RED (the red-first arm)")
    check(verdict_of(green) == ("GREEN", ""), "a GREEN receipt reads GREEN")
    check(verdict_of("UI-NIGHTLY v1 suite=web.live verdict=NOT RUN(the hook check failed) items=0/116")[0] == "RED",
          "a NOT RUN reads RED, never green")
    check(verdict_of(None)[0] == "UNREAD", "no receipt reads UNREAD")
    check(verdict_of("")[0] == "UNREAD", "an empty receipt reads UNREAD")
    check(verdict_of("UI-NIGHTLY v1 suite=mac.live verdict=GREEN items=116/116")[0] == "UNREAD",
          "another suite's receipt reads UNREAD, never its GREEN")
    check(verdict_of("LAYERS 5/5\n" + green)[0] == "UNREAD", "the verdict is line 1 only; a GREEN further down is not read")
    print(f"web_l2_main_verdict self-test: {7 - len(fails)} of 7 checks passed")
    for f in fails:
        print("  FAIL:", f)
    return 1 if fails else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    out, rc = line()
    print(out)
    sys.exit(rc)
