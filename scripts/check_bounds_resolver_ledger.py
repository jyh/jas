#!/usr/bin/env python3
"""BOUNDSLEDGER — every resolver-less bounds call in production must be DECLARED.

THE CLASS, which has now cost five separate fixes (RESOLVEDHIT, RESOLVEDALIGN,
FITPHANTOM, HANDLEPHANTOM, GROUPPHANTOM): *a bounds call with no resolver
behind it, on a path a symbol instance can reach.*

`Element::bounds()` / `geometric_bounds()` answer a zero box AT THE ORIGIN for
the reference / recorded / generated kinds — they measure their TARGET, and
these accessors have no resolver. The trait stays narrow on purpose (render,
hit-test and the panels all read it), so the fix is never "make bounds
resolve"; it is "this READER must ask the resolved twin". Which readers those
are is a judgement per site, and a judgement nobody wrote down is a judgement
that gets re-made wrongly.

So: this gate holds the verdicts. Every resolver-less call site in production
Rust is listed below with a reason. Add a new one and the gate REDS until you
declare it — which is the whole point, because the failure is silent: a zero
box at the origin looks like a rendering glitch, not like a wrong predicate.

Keyed on the SOURCE TEXT of the call line, not the line number, so ordinary
edits above a site do not churn the ledger.

Run: python3 scripts/check_bounds_resolver_ledger.py
"""

from __future__ import annotations

import ast
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "jas_dioxus" / "src"

# Receivers that cannot be a live element: the call sits inside a match arm for
# a concrete kind, or the receiver is a freshly-constructed concrete kind.
CONCRETE = re.compile(r"Element::(Path|Rect|Ellipse|Polygon|Polyline|Line|Text|TextPath)\s*\(")

CALL = re.compile(r"\.(bounds|geometric_bounds)\(\)")

# An assertion is not a production reader. Test modules live beside production
# code in Rust, so whole-file exclusion is too coarse for files that hold both.
ASSERTION = re.compile(r"^(debug_)?assert(_eq|_ne)?!\(")

# file -> {call-site source text: verdict}. A verdict beginning with "REACHABLE"
# means an instance can be the receiver AND the site has been converted or
# consciously left; anything else states why an instance cannot arrive.
def duplicate_ledger_keys(src: str) -> list[str]:
    """Keys written TWICE in the LEDGER literal — outer file or inner call text.

    ⛔ THIS FAILURE IS INVISIBLE TO EVERY RUNTIME CHECK, AND IT BIT FOR REAL.
    A duplicate key in a dict literal does not error: the later entry SILENTLY
    REPLACES the earlier one. Adding a second `"painter/element_render.rs"`
    block (2026-08-29, while declaring the A6 mask site) discarded that file's
    existing verdict, and the gate then reported an already-judged call as
    UNDECLARED — which reads as a new defect rather than as a clobbered ledger.

    By the time this module is imported the dict has already collapsed, so no
    amount of inspecting LEDGER can find it. The only witness is the SOURCE, so
    that is what this reads. A ledger that silently drops verdicts is worse than
    no ledger: it converts a recorded judgement back into an open question
    without anyone deciding to.
    """
    tree = ast.parse(src)
    for node in ast.walk(tree):
        targets = []
        if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            targets = [node.target.id]
        elif isinstance(node, ast.Assign):
            targets = [t.id for t in node.targets if isinstance(t, ast.Name)]
        if "LEDGER" not in targets or not isinstance(node.value, ast.Dict):
            continue
        dups = []
        outer = [k.value for k in node.value.keys if isinstance(k, ast.Constant)]
        dups += [f"LEDGER[{k!r}] appears {outer.count(k)} times"
                 for k in dict.fromkeys(outer) if outer.count(k) > 1]
        for kn, vn in zip(node.value.keys, node.value.values):
            if not isinstance(vn, ast.Dict) or not isinstance(kn, ast.Constant):
                continue
            inner = [k.value for k in vn.keys if isinstance(k, ast.Constant)]
            dups += [f"LEDGER[{kn.value!r}][{k!r}] appears {inner.count(k)} times"
                     for k in dict.fromkeys(inner) if inner.count(k) > 1]
        return dups
    # ANTI-VACUITY: no LEDGER literal found means this check examined nothing,
    # which must never read as "no duplicates".
    return ["LEDGER literal not found in this file -- the duplicate-key check "
            "examined NOTHING, which is not the same as finding nothing"]


LEDGER: dict[str, dict[str, str]] = {
    "interpreter/renderer.rs": {
        "let local = e.geometric_bounds();":
            "REACHABLE, UNCONVERTED — keyboard transform of the selection. An "
            "instance nudged by arrow key builds its new transform from a box "
            "at the origin. Its own stone: the transform must compose about "
            "the RESOLVED centre, which is more than swapping the accessor.",
        "let (x, y, w, h) = elem.bounds();":
            "REACHABLE, UNCONVERTED — the Layers-panel thumbnail "
            "(`tree_preview_svg`). An instance yields w=h=0 and the function "
            "returns an empty string, so instances show no thumbnail. MEASURED "
            "2026-08-05: resolving the box alone would NOT fix it. The body "
            "calls `geometry::svg::element_svg`, whose Reference arm emits "
            "`<use href=\"#id\"/>` — correct for a saved FILE (it round-trips "
            "back to a live reference, F-svg-use) and empty in a standalone "
            "thumbnail that carries no defs. So the thumbnail needs its own "
            "geometry path; widening the shared writer would bake the instance "
            "into every saved document. Feature-sized, and it touches the file "
            "format's boundary — not an accessor swap.",
    },
    "interpreter/effects.rs": {
        "let bounds = model.document().bounds();":
            "RESOLVED — `Document::bounds` resolves since FITPHANTOM.",
        "let b = model.document().bounds();":
            "RESOLVED — same.",
        "let bounds = child.bounds();":
            "REACHABLE, UNCONVERTED (x2: artboard containment on open and on "
            "paste). An instance is assigned to whichever artboard contains "
            "the ORIGIN rather than the one it is drawn on. Wants the "
            "artboard-membership rule settled first — ARTBOARDS.md is silent "
            "on which artboard owns an instance whose master lives elsewhere.",
        "let (min_x, min_y, w, h) = eye.bounds();":
            "TEST — an assertion inside `mod tests`, not a production reader.",
    },
    "interpreter/doc_primitives.rs": {
        "let (bx, by, bw, bh) = child.bounds();":
            "REACHABLE, UNCONVERTED — click hit-testing, and already on "
            "BOARD-urgent-two-regressions as half of the TRANSFORM family "
            "(it also ignores `common.transform`). Both halves are one stone; "
            "converting only the resolver half would leave it still wrong.",
        "let (bx, by, bw, bh) = elem.bounds();":
            "REACHABLE, UNCONVERTED — same function, recursive arm.",
    },
    "painter/element_render.rs": {
        "elem.bounds()":
            "NOT REACHABLE — `tuple_bounds`, called only from the "
            "`Element::Line` and `Element::Path` arms, where the receiver is "
            "that concrete kind.",
        "let (bx, by, bw, bh) = mask.subtree.bounds();":
            "REACHABLE, UNCONVERTED — and it is the SAME SITE as "
            "`canvas/render.rs`'s, deliberately. A6's element bracket lowers "
            "`(clip:false, invert:false)` to `AlphaRevealOutsideBbox { bbox }`, "
            "and §3.3 says a backend never computes bounds — so the PRODUCER "
            "must compute it, and it computes it the way the legacy arm does. "
            "A mask built from an instance therefore yields a rect at the "
            "origin on the seam too: the reveal law degenerates and the masked "
            "element is hidden, exactly as legacy hides it. THE PORT CARRIES "
            "THE LIMITATION RATHER THAN QUIETLY DIVERGING FROM IT — a seam that "
            "silently did something ELSE here would be a second behaviour to "
            "reconcile, not a fix. The open question is unchanged and belongs "
            "to the same stone: MASKS.md does not say whether an instance may "
            "BE a mask, and neither renderer should decide that by accident. "
            "⚠️ NOT YET LIVE: `element_needs_legacy` still routes every masked "
            "element to legacy (Canvas2dPainter's mask ops are unimplemented), "
            "so this site is reachable in the REFERENCE renderer today and "
            "becomes production-reachable only when PH4's backend lands.",
    },
    "tools/yaml_tool.rs": {
        "let (lx, ly, lw, lh) = elem.geometric_bounds(); // LOCAL geometry, no stroke":
            "REACHABLE, UNCONVERTED — a tool reading the selected element's "
            "local box. Pairs with the renderer's keyboard-transform site: "
            "both want the resolved box in LOCAL space, which the resolved "
            "twin gives, but both then compose a transform about it and that "
            "composition is what needs checking.",
    },
    # Converted files, kept as empty entries: a NEW narrow call here must be
    # declared rather than quietly rejoining the class.
    "workspace/app_state.rs": {},   # Align To key-object designation — resolved
    "document/document.rs": {},     # Document::bounds — resolved (FITPHANTOM)
    "canvas/render.rs": {
        "let (bx, by, bw, bh) = mask.subtree.bounds();":
            "REACHABLE, UNCONVERTED — the mask subtree's bbox clip. A mask "
            "built from an instance clips to a rect at the origin, i.e. hides "
            "the masked element entirely. Rare enough to want a repro before "
            "a fix, and MASKS.md does not say whether an instance may BE a "
            "mask at all.",
        "let b = elem.bounds();":
            "NOT REACHABLE — gradient bbox inside the `Element::Path` arm.",
        "crate::painter::element_render::path_painter_inputs(e, elem.bounds())":
            "NOT REACHABLE — same arm.",
        "let (bx, by, bw, bh) = elem.bounds();":
            "NOT REACHABLE — the text-like selection outline; guarded by "
            "`is_text_like` (Text | TextPath). The CONTAINER arm beside it "
            "was reachable and is resolved (GROUPPHANTOM, this stone).",
    },
}

# Files whose bounds calls are all inside `mod tests`, or which are test-only
# harnesses. Listed rather than skipped silently.
TEST_ONLY = {
    "algorithms/align.rs": "assertions in `mod tests`; the production readers "
                           "take a BoundsFn the caller supplies (RESOLVEDALIGN)",
    "algorithms/hit_test.rs": "`resolved_bounds`'s own fallback arm plus test "
                              "assertions — this file IS the resolved reader",
    "document/evaluated_bounds.rs": "assertions in `mod tests`; the production "
                                    "reader resolves",
    "document/controller.rs": "assertion in `mod tests`",
    "painter/element_render/tests.rs": "test module",
    "bin/algorithm_roundtrip.rs": "corpus-driving harness, not the app",
}


def scan(src_root: pathlib.Path) -> dict[str, set[str]]:
    """Every resolver-less bounds call under `src_root`, keyed file -> lines."""
    found: dict[str, set[str]] = {}
    for path in sorted(src_root.rglob("*.rs")):
        rel = path.relative_to(src_root).as_posix()
        if rel.startswith("geometry/"):
            continue  # the accessors' own home, and the resolved twins
        for raw in path.read_text(encoding="utf-8").split("\n"):
            line = raw.strip()
            if not CALL.search(line) or line.startswith("//") or line.startswith("///"):
                continue
            if CONCRETE.search(line) or ASSERTION.match(line):
                continue
            found.setdefault(rel, set()).add(line)
    return found


def self_test() -> int:
    """Prove the scan SEES an undeclared call and does not cry wolf on the
    three shapes it must ignore. A gate that cannot be shown to fail is not
    evidence that anything passed."""
    import tempfile

    # ⛔ THE DUPLICATE-KEY ARM, driven BOTH ways on fixtures. Written after a
    # real clobber (see `duplicate_ledger_keys`), so it is a repair with a
    # witness rather than a precaution.
    dup_src = """LEDGER: dict[str, dict[str, str]] = {
    "a.rs": {"call()": "one"},
    "b.rs": {"call()": "two"},
    "a.rs": {"other()": "three"},
}"""
    if len(duplicate_ledger_keys(dup_src)) != 1:
        print("SELF-TEST FAIL: a duplicated OUTER key must be caught")
        return 1
    dup_inner = """LEDGER: dict[str, dict[str, str]] = {
    "a.rs": {"call()": "one", "call()": "two"},
}"""
    if len(duplicate_ledger_keys(dup_inner)) != 1:
        print("SELF-TEST FAIL: a duplicated INNER key must be caught")
        return 1
    clean = """LEDGER: dict[str, dict[str, str]] = {
    "a.rs": {"call()": "one"},
    "b.rs": {"call()": "two"},
}"""
    if duplicate_ledger_keys(clean):
        print("SELF-TEST FAIL: a clean ledger must not be flagged")
        return 1
    if not duplicate_ledger_keys("X = 1"):
        print("SELF-TEST FAIL: a source with NO LEDGER must not read as clean")
        return 1
    # ...and THIS file, which is the object the production call reads.
    if duplicate_ledger_keys(pathlib.Path(__file__).read_text(encoding="utf-8")):
        print("SELF-TEST FAIL: this file's own LEDGER carries a duplicate key")
        return 1

    cases = [
        ("let b = child.bounds();", True, "a bare call on an arbitrary receiver"),
        ("let b = Element::Path(pe.clone()).bounds();", False,
         "a concrete kind cannot be a live element"),
        ("assert_eq!(doc.bounds(), (0.0, 0.0, 0.0, 0.0));", False,
         "an assertion is not a production reader"),
        ("/// the box `elem.bounds()` resolves gradients on", False,
         "a doc comment is prose"),
        ("let b = resolved_bounds_with(e, &r, Element::bounds);", False,
         "the resolved twin takes bounds as a FUNCTION, never calls it"),
    ]
    failures = 0
    for src, should_flag, why in cases:
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            (root / "probe.rs").write_text(f"fn f() {{\n    {src}\n}}\n",
                                           encoding="utf-8", newline="")
            flagged = bool(scan(root))
            if flagged != should_flag:
                failures += 1
                print(f"  self-test FAIL ({why}): expected "
                      f"{'a flag' if should_flag else 'silence'}, got the other\n"
                      f"      {src}")
    # And the real tree must be non-empty, or the keys have drifted.
    if not scan(SRC):
        failures += 1
        print("  self-test FAIL: the real scan found ZERO call sites")
    if failures:
        print(f"check_bounds_resolver_ledger --self-test: FAIL ({failures})")
        return 1
    print(f"check_bounds_resolver_ledger --self-test: OK "
          f"({len(cases)} discrimination cases + a non-empty real scan)")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    found = scan(SRC)

    problems: list[str] = []
    # The ledger's own integrity FIRST: a clobbered verdict makes every verdict
    # below unreliable, and the symptom is a site reported undeclared that
    # somebody already judged.
    problems += [f"LEDGER INTEGRITY: {d}" for d in
                 duplicate_ledger_keys(pathlib.Path(__file__).read_text(encoding="utf-8"))]
    declared = 0
    for rel, lines in sorted(found.items()):
        if rel in TEST_ONLY:
            continue
        known = LEDGER.get(rel)
        if known is None:
            problems.append(
                f"{rel}: reads bounds and is not in the ledger at all "
                f"({len(lines)} site(s)). Declare each one, or add the file to "
                f"TEST_ONLY with the reason."
            )
            continue
        for line in sorted(lines):
            if line in known:
                declared += 1
            else:
                problems.append(
                    f"{rel}: UNDECLARED resolver-less bounds call\n"
                    f"      {line}\n"
                    f"      Judge it: can a symbol instance be the receiver? "
                    f"If yes it answers a zero box AT THE ORIGIN. Add it to "
                    f"LEDGER with the verdict."
                )

    # Anti-vacuity: a ledger that matches nothing is not watching anything.
    if declared == 0:
        print("check_bounds_resolver_ledger: FAIL — the ledger matched ZERO "
              "call sites. The scan or the keys have drifted; it is not "
              "watching the code.")
        return 1

    stale = []
    for rel, entries in LEDGER.items():
        for line in entries:
            if line not in found.get(rel, set()):
                stale.append(f"{rel}: ledger entry no longer in the source\n      {line}")
    problems.extend(stale)

    if problems:
        print("check_bounds_resolver_ledger: FAIL")
        for p in problems:
            print(f"  - {p}")
        return 1

    reachable = sum(
        1 for e in LEDGER.values() for v in e.values() if v.startswith("REACHABLE")
    )
    converted = sum(
        1 for e in LEDGER.values() for v in e.values() if v.startswith("RESOLVED")
    )
    print(
        f"check_bounds_resolver_ledger: OK ({declared} call sites declared; "
        f"{converted} resolved, {reachable} reachable-and-judged, "
        f"{declared - converted - reachable} unreachable; "
        f"{len(TEST_ONLY)} test-only files)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
