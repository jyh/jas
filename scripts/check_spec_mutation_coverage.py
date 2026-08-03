#!/usr/bin/env python3
"""Which clauses of the LAW does the corpus actually exercise?

WHY THIS EXISTS
---------------
`docs/CHECKERS.md` names both this instrument and the question it leaves open:

    Extend the mutant set to `spec/` -- one mutant per clause of the denotation,
    each with a declared floor -- and a collinear corpus reports itself as "the
    half_diag mutant is rejected on 0 vectors, floor 4": a red with a name, at
    authoring time, instead of an audit finding. ... **Its own boundary, stated:
    a clause nobody wrote a mutant for is still unwatched.** Making *that* total
    is a coverage question about `spec/` ... and it is not answered here.

Zero clauses of `spec/` had a mutant. The three that exist in
`cross_language_algorithms.py` mutate a checker's BEHAVIOUR, not the analytic
tier, and that file says of them: "a REGRESSION floor, not a discovery
instrument."

The question this answers is not "is the law right" -- `spec/geometry/tests/`
does that, with hand-derived expectations. It is the complementary one: **when
the corpus rules a port with this law, which clauses of the law is it actually
leaning on?** A clause no vector can distinguish is a clause the corpus is not
testing, however green the lane is.

HOW IT MEASURES
---------------
For every corpus vector, the operation's membership law is evaluated at the
vector's OWN pinned sample points, twice: once under `spec/geometry/region.py`
and once under a single-clause mutation of it. If the two ever disagree, that
vector DISCRIMINATES that clause. The count of discriminating vectors is
compared against a floor declared per mutant, with a reason.

The right-hand side is computed from the OPERANDS, exactly as the shipped
checker does -- `a point is in A u B iff it is in A or in B` -- so this measures
the same reading of the plane the lane relies on.

WHAT IT CANNOT SEE, and this is a real boundary rather than a caveat
-------------------------------------------------------------------
Only the MEMBERSHIP clauses. `ring_defect`, `laminarity_defect`,
`containment_defect` and `segments_meet` all read the port's OUTPUT rings, and
the corpus stores no output rings -- it stores `area`, `ring_count` and sample
points. So the structural half of the law is unreachable from a static corpus
read, and can only be exercised by a live port run.

That is worth stating plainly: **this gate measures coverage of roughly half the
law, and names which half.** The other half's coverage question is open, and
pretending otherwise would make this the kind of instrument it exists to find.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
REGION = REPO / "spec" / "geometry" / "region.py"
FIXTURES = REPO / "test_fixtures" / "algorithms"

# ---------------------------------------------------------------------------
# The mutants: ONE CLAUSE EACH, and every one against a real code line.
#
# A mutant that edits a comment changes nothing and reports a clean result. That
# is not hypothetical here: the first mutation sweep run against this module
# (SPECUNTESTED) reported two false survivors because the pattern it replaced
# appears in this file only inside a DOCSTRING. Every `find` below was checked
# to occur in executable code.
# ---------------------------------------------------------------------------
MUTANTS = [
    {
        "name": "crossings_half_open",
        "clause": "crossings: which end of an edge's y-span counts",
        "find": "if (y1 <= py) == (y2 <= py):",
        "repl": "if (y1 < py) == (y2 < py):",
        "floor": 0,
        "why": "MEASURED unobservable off the boundary: across four shapes and "
               "~27,000 point/rule combinations, every input separating this "
               "mutant from the real law lies EXACTLY ON a ring. Corpus sample "
               "points are interior or exterior by construction, so a floor "
               "above 0 would be demanding a vector that cannot exist without "
               "asking the law a question it does not define.",
    },
    {
        "name": "crossings_ray_origin",
        "clause": "crossings: whether a crossing at the ray's own x counts",
        "find": "if xc <= px:",
        "repl": "if xc < px:",
        "floor": 0,
        "why": "Same boundary argument as crossings_half_open, measured the "
               "same way (708 discriminating inputs, all of them on a ring).",
    },
    {
        "name": "crossings_orientation",
        "clause": "crossings: the SIGN a crossing contributes (winding)",
        "find": "signed += 1 if y2 > y1 else -1",
        "repl": "signed += 1",
        "floor": 1,
        # DECLARED DEBT: the obligation is 1 and the corpus delivers 0. Held as
        # a recorded number rather than a lowered floor, so the gap stays
        # visible and a REGRESSION is still impossible.
        "debt": 0,
        "why": "Only the non-zero rule reads the sign, and only where winding "
               "CANCELS -- which needs a ring set containing both windings. "
               "MEASURED: the boolean corpus contains ZERO such sets across all "
               "19 vectors, so no vector can distinguish this clause. Closing "
               "it needs one vector whose operand carries an opposite-wound "
               "hole; that is a test_fixtures/ edit, and test_fixtures/ is held "
               "by the other seat's unmerged R3 (114 files). Queued, not "
               "excused -- the floor stays 1 so paying it retires this row.",
    },
    {
        "name": "contains_parity",
        "clause": "contains: even-odd reads an ODD crossing count as inside",
        "find": "return (signed != 0) if rule == NON_ZERO else (unsigned % 2 == 1)",
        "repl": "return (signed != 0) if rule == NON_ZERO else (unsigned % 2 == 0)",
        "floor": 8,
        "why": "The default rule's core. Any vector with an interior and an "
               "exterior sample point separates it, so a low count here would "
               "mean the corpus had stopped sampling both sides.",
    },
    {
        "name": "contains_rules_swapped",
        "clause": "contains: which total each fill rule reads",
        "find": "return (signed != 0) if rule == NON_ZERO else (unsigned % 2 == 1)",
        "repl": "return (unsigned % 2 == 1) if rule == NON_ZERO else (signed != 0)",
        "floor": 1,
        "why": "Separated only where the two rules DISAGREE, which needs "
               "same-orientation nesting or overlap. The count is the honest "
               "measure of how much non-zero geometry the corpus carries.",
    },
]

MIN_MUTANTS = 4          # fail closed: a derivation that empties proves nothing
MIN_VECTORS = 10         # ditto for the corpus side


def load_region(source: str):
    """Execute `source` as a standalone module namespace.

    `region.py` imports nothing from this repository -- the property the TCB
    gate enforces -- so a bare exec is sufficient and keeps the mutant fully
    isolated from the real module in `sys.modules`.
    """
    # `.as_posix()`, not `str()`: this filename is DATA -- it lands in
    # tracebacks and in the compiled code object -- and `str(Path)` yields
    # backslashes on Windows, which is the divergence check_path_keying.py
    # exists to catch. It caught this one.
    name = REGION.as_posix()
    ns: dict = {"__name__": "region_variant", "__file__": name}
    exec(compile(source, name, "exec"), ns)
    return ns


def combine(fn: str, in_a: bool, in_b: bool) -> bool:
    """The membership law per operation -- the checker's own right-hand side."""
    if fn == "union":
        return in_a or in_b
    if fn == "intersect":
        return in_a and in_b
    if fn == "subtract":
        return in_a and not in_b
    if fn == "exclude":
        return in_a != in_b
    raise KeyError(fn)


def boolean_vectors() -> list[dict]:
    """Corpus vectors carrying operands AND pinned sample points."""
    data = json.loads((FIXTURES / "boolean.json").read_text(encoding="utf-8"))
    vs = data.get("vectors", data) if isinstance(data, dict) else data
    return [v for v in vs
            if v.get("expected", {}).get("sample_points") and "a" in v and "b" in v]


def rings(raw) -> list:
    return [[(float(p[0]), float(p[1])) for p in ring] for ring in raw]


def discriminating(vectors, base_ns, mut_ns) -> list[str]:
    """Names of vectors whose own sample points separate the two laws."""
    hits = []
    for v in vectors:
        a, b = rings(v["a"]), rings(v["b"])
        rule_a = v.get("a_fill_rule")
        for sp in v["expected"]["sample_points"]:
            px, py = float(sp["point"][0]), float(sp["point"][1])
            out = []
            for ns in (base_ns, mut_ns):
                ra = rule_a or ns["DEFAULT_FILL_RULE"]
                out.append(combine(v["function"],
                                   ns["contains"](a, (px, py), ra),
                                   ns["contains"](b, (px, py), ns["DEFAULT_FILL_RULE"])))
            if out[0] != out[1]:
                hits.append(v["name"])
                break
    return hits


def _floor_breach(count: int, floor: int) -> bool:
    """The rule, as a function, so the self-test can prove it."""
    return count < floor


def _debt_is_paid(m: dict, count: int) -> bool:
    """A declared-debt row whose count has reached its obligation."""
    return "debt" in m and count >= m["floor"]


def self_test() -> int:
    """Prove the failures FIRST: an empty mutant set, an empty corpus, a floor
    breach, and a mutant whose pattern does not occur in executable code."""
    failures = []

    if not _floor_breach(0, 1):
        failures.append("0 below floor 1 must breach")
    # A PAID DEBT MUST RED. Without this the retirement branch is unreachable
    # code that looks like diligence -- the decorative-instrument fault this
    # repository has now shipped three times.
    if not _debt_is_paid({"floor": 1, "debt": 0}, 2):
        failures.append("a debt row whose count reached its floor must red")
    if _debt_is_paid({"floor": 3, "debt": 0}, 1):
        failures.append("a debt row still below its floor must NOT red as paid")
    if _debt_is_paid({"floor": 1}, 5):
        failures.append("a row with no debt key can never be a paid debt")
    if _floor_breach(3, 3):
        failures.append("a count equal to its floor must NOT breach")
    if len(MUTANTS) < MIN_MUTANTS:
        failures.append(f"only {len(MUTANTS)} mutants declared")

    src = REGION.read_text(encoding="utf-8")

    # EVERY mutant must hit a real code line. A `find` that matches only prose
    # -- or matches nothing -- is a mutant that changes no behaviour and reports
    # a clean result, which is the exact fault the SPECUNTESTED sweep shipped.
    import io, tokenize
    prose = set()
    try:
        for tok in tokenize.generate_tokens(io.StringIO(src).readline):
            if tok.type in (tokenize.COMMENT, tokenize.STRING):
                for ln in range(tok.start[0], tok.end[0] + 1):
                    prose.add(ln)
    except Exception:
        pass
    lines = src.splitlines()
    for m in MUTANTS:
        hit_lines = [i + 1 for i, l in enumerate(lines) if m["find"] in l]
        if not hit_lines:
            failures.append(f"{m['name']}: pattern occurs nowhere in region.py")
        elif all(ln in prose for ln in hit_lines):
            failures.append(f"{m['name']}: pattern occurs ONLY in prose "
                            f"(lines {hit_lines}) -- it would mutate a comment")

    # A mutant must actually change the module's behaviour somewhere, or it is
    # not a mutant. Proven on a shape of the law's own choosing, not the corpus.
    base = load_region(src)
    square = [[(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]]
    inner = [[(3.0, 3.0), (7.0, 3.0), (7.0, 7.0), (3.0, 7.0)]]
    # REVERSED, and it is not decoration. Dropping the winding SIGN changes no
    # answer unless some ring winds the other way -- with same-orientation
    # nesting the signed total is +-2 either way, and non-zero says "inside"
    # both times. The first draft of this self-test omitted it and duly
    # reported that the orientation mutant "changes no answer at all", which
    # was a true statement about a probe set too weak to ask the question.
    inner_rev = [list(reversed(inner[0]))]
    shapes = (square, square + inner, square + inner_rev)
    probes = [(5.0, 5.0), (1.0, 1.0), (50.0, 50.0), (0.0, 0.0), (10.0, 5.0)]
    for m in MUTANTS:
        mut = load_region(src.replace(m["find"], m["repl"], 1))
        differs = any(
            base["contains"](r, p, rule) != mut["contains"](r, p, rule)
            for r in shapes
            for p in probes
            for rule in (base["EVEN_ODD"], base["NON_ZERO"])
        )
        if not differs:
            failures.append(f"{m['name']}: mutation changes no answer at all")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print(f"check_spec_mutation_coverage SELF-TEST: OK (floor rule proven both "
          f"ways first; all {len(MUTANTS)} mutants hit executable code and each "
          f"changes an answer)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()

    if len(MUTANTS) < MIN_MUTANTS:
        print(f"FAIL: only {len(MUTANTS)} mutants declared, floor {MIN_MUTANTS}.")
        return 1

    src = REGION.read_text(encoding="utf-8")
    base = load_region(src)
    vectors = boolean_vectors()
    if len(vectors) < MIN_VECTORS:
        print(f"FAIL: derived only {len(vectors)} usable corpus vector(s), floor "
              f"{MIN_VECTORS}. An empty corpus read is not a clean one.")
        return 1

    breaches, rows = [], []
    for m in MUTANTS:
        if m["find"] not in src:
            print(f"FAIL: {m['name']}'s pattern is gone from region.py — the "
                  f"clause was renamed or removed and this mutant now mutates "
                  f"nothing. Re-point it rather than deleting it.")
            return 1
        mut = load_region(src.replace(m["find"], m["repl"], 1))
        hits = discriminating(vectors, base, mut)
        rows.append((m, len(hits)))
        target = m.get("debt", m["floor"])
        if _floor_breach(len(hits), target):
            breaches.append((m, hits, target))
        # A DEBT ROW THAT HAS BEEN PAID MUST BE RETIRED, or the ledger rots into
        # a list of numbers nobody re-reads. This is the `improves: up` lesson
        # from check_default_variance, where the first cut hard-coded a
        # direction and reported a corpus that had LOST coverage as healthy.
        elif _debt_is_paid(m, len(hits)):
            breaches.append((m, hits, None))

    width = max(len(m["name"]) for m in MUTANTS)
    for m, n in rows:
        note = f"floor {m['floor']}"
        if "debt" in m:
            note += f", DECLARED DEBT {m['debt']}"
        print(f"   {m['name']:<{width}}  rejected on {n:>2} / "
              f"{len(vectors)} vectors  ({note})")

    if breaches:
        print(f"\nFAIL: {len(breaches)} clause row(s) need attention.\n")
        for m, hits, target in breaches:
            if target is None:
                print(f"  {m['name']}: DEBT PAID — rejected on {len(hits)}, "
                      f"floor {m['floor']}. Delete the `debt` key; a debt row "
                      f"that has been paid and left in place is a stale claim.")
            else:
                print(f"  {m['name']}: {m['clause']}")
                print(f"      target {target}, rejected on {len(hits)}")
                print(f"      {m['why']}")
        return 1

    debt = [m for m in MUTANTS if "debt" in m]
    met = len(MUTANTS) - len(debt)
    summary = (f"\ncheck_spec_mutation_coverage: OK over {len(vectors)} corpus "
               f"vectors — {met} of {len(MUTANTS)} membership clauses meet their "
               f"floor")
    if debt:
        names = ", ".join(m["name"] for m in debt)
        verb = "carries" if len(debt) == 1 else "carry"
        summary += (f"; {len(debt)} {verb} DECLARED DEBT ({names}) — held at a "
                    f"MEASURED value, not excused, and reds if it is paid and "
                    f"left in place")
    print(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
