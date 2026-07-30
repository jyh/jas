#!/usr/bin/env python3
"""A gate that honours an exemption must also ask whether it is still needed.

WHY THIS EXISTS -- and it is Flask's finding, not mine
------------------------------------------------------
`check_widget_kind_dispatch.py` iterated GAPS and asked "is this excused?". It
never iterated EXEMPTIONS and asked "is this still NEEDED?" A row whose
condition had closed was never VISITED, so no claim on it could ever fire, and
`swift:dropdown` asserted JasSwift "has neither the state nor the filtering" for
months after JasSwift shipped both. Flask found that by reading, from another
continent (letter 11 §2), and named the repair: a second loop, ten lines.

Then something more useful happened. I had ALREADY written that loop -- a
`retired` check in `check_action_implementations.py`, the day before, one
directory listing away -- and never back-ported it. Same person, same week, same
idea, two files.

Flask's reading of that, which is why this file exists (letter 13 §3):

    "It says the mechanism is not 'people do not know' -- it is that NOBODY WAS
     LOOKING ACROSS THE GATES. That is a different and much more tractable
     problem, and it argues for a periodic sweep asking which gates have a loop
     the others lack."

This is that sweep, made continuous. The whole premise-expiry thread was chasing
"a claim nobody rechecks"; the tractable core turned out to be narrower and
duller: A MECHANISM ONE GATE HAS AND ITS SIBLINGS DO NOT.

WHAT IT ASSERTS
---------------
Every gate with a NON-EMPTY exemption ledger also asks, somewhere, whether each
row is still needed. An empty ledger is exempt by construction -- there is
nothing to go stale.

The check is deliberately coarse: it looks for the QUESTION being asked at all,
not for a particular spelling of it. THREE shipping implementations differ
(`stale_exemptions` walks the kinds; `retired` diffs two sets; `stale` diffs two
sets under another name) and all three are correct, so demanding a shape would
be demanding conformity rather than coverage.

THE PRICE OF THAT COARSENESS, MEASURED ON THE FIRST LIVE RUN
------------------------------------------------------------
It flagged two gates. ONE WAS A FALSE POSITIVE: `check_element_dispatch.py`
computes `stale = set(rows) - set(live)` and reports it, which is exactly the
loop -- it simply did not use a word this file recognised. So the honest score
of the first run is one real gap, one gate accused of lacking a mechanism it
had. That is the same shape as the defect this gate exists to catch, pointed the
other way, and the vocabulary below is wider now because of it.

A substring sweep cannot distinguish HAVING the loop from MENTIONING it, in
either direction. The self-test pins all three shipping implementations so a
rename cannot quietly satisfy the rule; nothing here can stop a gate from
passing on prose. That trade is accepted, not overlooked.

WHAT IT DOES NOT COVER
----------------------
* One mechanism, not all of them. Other cross-gate asymmetries exist -- derived
  floors, live-tree self-test arms, refusal on a vanished anchor -- and each
  would need its own rule. This one is here because it has a proven defect
  behind it and the others do not, yet.
* It reads a gate's SOURCE, not its behaviour. A loop that runs but never reds
  reads as present.
"""

import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = REPO / "scripts"

# Any of these means the gate asks the question. Deliberately several: the three
# shipping answers differ, and all three are right. `stale` is here bare rather
# than as `stale_exemptions` because the narrower spelling produced a FALSE
# POSITIVE against check_element_dispatch.py, which had the loop all along.
ASKS = ("stale", "retired", "no longer a gap", "no longer hold",
        "obsolete", "no longer needed", "delete the row", "vanished")

# The real answers, as shipped. Pinned so a rename cannot quietly satisfy the
# rule, and COUNTED in the self-test summary so adding a fourth cannot leave the
# prose asserting there are three -- which is the class this gate polices.
SHIPPING_SPELLINGS = (
    "stale_exemptions(kinds, per_port, ex)",   # check_widget_kind_dispatch.py
    "retired = set(known) - set(live)",        # check_action_implementations.py
    "stale = sorted(set(rows) - set(live))",   # check_element_dispatch.py
)

LEDGER_REF = re.compile(r'"?([a-z_]+(?:exemptions|ledger)\.json)"?')


def ledger_rows(name):
    """How many rows a ledger JSON declares, across its row-bearing sections."""
    p = SCRIPTS / name
    try:
        d = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    n = 0
    for key, v in d.items():
        if key.startswith("_"):
            continue
        if isinstance(v, dict):
            n += len(v)
        elif isinstance(v, list):
            n += len(v)
    return n


def scan(sources):
    """[(gate, ledger, rows)] for gates with a non-empty ledger and no question."""
    gaps = []
    for name, text in sorted(sources.items()):
        m = LEDGER_REF.search(text)
        if not m:
            continue
        ledger = m.group(1)
        rows = ledger_rows(ledger)
        if not rows:                     # missing or empty -- nothing to go stale
            continue
        if any(a in text for a in ASKS):
            continue
        gaps.append((name, ledger, rows))
    return gaps


def load_sources():
    out = {}
    for p in sorted(SCRIPTS.glob("check_*.py")):
        if p.name == pathlib.Path(__file__).name:
            continue
        try:
            out[p.name] = p.read_text(encoding="utf-8")
        except OSError:
            continue
    return out


def self_test():
    failures = []

    # (a) A gate with rows and no question is a GAP -- the shape Flask found.
    if not scan({"g.py": 'LEDGER = "widget_dispatch_exemptions.json"\nif ex.get(k): pass\n'}):
        failures.append("  a: a ledger-honouring gate with no staleness question must be flagged")

    # (b) ANY of the three shipping spellings satisfies it. Demanding one shape
    #     would be demanding conformity rather than coverage -- and the third
    #     entry is here because demanding the FIRST one accused the gate that
    #     wrote it of not having it.
    for spell in SHIPPING_SPELLINGS:
        if scan({"g.py": f'LEDGER = "widget_dispatch_exemptions.json"\n{spell}\n'}):
            failures.append(f"  b: {spell!r} should satisfy the rule")

    # (c) An EMPTY ledger cannot go stale, so it is exempt by construction --
    #     otherwise every gate would be forced to carry a loop over nothing.
    if scan({"g.py": 'LEDGER = "path_keying_exemptions.json"\n'}):
        failures.append("  c: a gate whose ledger is empty must not be flagged")

    # (d) A gate with no ledger at all is not in scope.
    if scan({"g.py": "def main(): return 0\n"}):
        failures.append("  d: a gate with no ledger must not be flagged")

    # (e) The live tree must be clean, or production is the first anyone hears.
    live = scan(load_sources())
    if live:
        failures.append(f"  e: the shipping gates have unswept ledgers: {live}")

    if failures:
        print("SELF-TEST FAILED -- the gate does not detect what it claims:")
        print("\n".join(failures))
        return 1
    print(f"self-test: a ledger-honouring gate with no staleness question is "
          f"flagged; all {len(SHIPPING_SPELLINGS)} shipping spellings satisfy "
          f"it; an empty ledger and a gate with no ledger are correctly out of "
          f"scope; every shipping gate asks the question.")
    return 0


def main():
    if "--self-test" in sys.argv:
        return self_test()

    gaps = scan(load_sources())
    if not gaps:
        print("gate consistency: every gate with a non-empty exemption ledger "
              "also asks whether each row is still needed.")
        return 0

    print(f"ERROR: {len(gaps)} gate(s) honour an exemption ledger without ever "
          f"asking whether a row is still needed.", file=sys.stderr)
    print(file=sys.stderr)
    for name, ledger, rows in gaps:
        print(f"  {name}: honours {ledger} ({rows} row(s)), no staleness check",
              file=sys.stderr)
    print(file=sys.stderr)
    print("A row whose condition has CLOSED is never visited by a gate that only", file=sys.stderr)
    print("iterates its findings, so no claim on that row can ever fire. That is", file=sys.stderr)
    print("how one exemption asserted a port lacked a feature it had shipped", file=sys.stderr)
    print("months earlier, and cost a seat an evening rebuilding it.", file=sys.stderr)
    print(file=sys.stderr)
    print("Add the second loop: after computing findings, walk the ledger and", file=sys.stderr)
    print("red on any row whose condition no longer holds.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
