#!/usr/bin/env python3
"""Nothing that COULD be verified natively may be hidden behind `web`.

WHY THIS EXISTS -- AND WHY IT REPLACES A COUNT
----------------------------------------------
`check_native_core_tests.py` used to carry `FLOOR`, an exact pin on the number
of tests in the native lib test target. The pin was the anti-vacuity half of
that gate: without it, "the native test target builds" is trivially satisfiable
by gating every offending test behind `web`.

The pin worked and it was the wrong instrument. It moved five times in two days
-- 1830, 1832, 1833, 1836, 1839 -- and each move was a hand-typed number in a
file nobody else was reading. Council O3.3 (DERIVEDFLOOR) had already ruled on
this species: *a floor computed from the tree cannot go slack, and this repo's
record on hand-typed floors is that two of four replacement numbers were wrong
on the first attempt.*

Then on 2026-07-30 the pin went 1839 -> 2024, and that jump is the argument in
one line. It was not drift and not a test anyone wrote: `lib.rs` had
`#[cfg(feature = "web")] pub mod workspace;`, so the whole workspace layer --
layout types, the layout-op dispatcher, pane geometry, key-chord resolution, the
menu structure, the fixture serializer -- was invisible to a
`--no-default-features` build, though nine of its seventeen submodules import
nothing from Dioxus, `web_sys`, or the app shell. 185 tests could always have
run natively and did not.

**A count could never have said so.** The most a count can report is "185 more
than yesterday". The property below NAMES them, on the day the module is gated.

WHAT IT ASSERTS
---------------
1. Every `web` gate on a MODULE declaration is declared in the ledger with a
   reason.
2. Every `web` gate on a TEST ITEM is declared in the ledger with a reason.
3. No ledger row is stale -- a row whose gate is gone must be deleted in the
   same commit that removes the gate. (The second loop `check_gate_consistency`
   requires of any gate with a non-empty exemption ledger.)
4. Every `#[cfg(...)]` attribute mentioning the web feature parses into a form
   this scanner recognises. A novel spelling REDS rather than being skipped.

WHY THERE IS NO NUMBER IN HERE
------------------------------
The anti-vacuity guard is DERIVED, not typed. If the scanner breaks and finds
nothing, every ledger row becomes stale and assertion (3) reds. The ledger is a
hand-written artifact and the scan reads source text, so the two are independent
oracles -- which is exactly what `FLOOR` could not be, since its oracle was the
same cargo invocation the gate itself made.

The guard holds only while the ledger is non-empty. That is stated rather than
hidden: an empty ledger plus a broken scanner is green and vacuous. Today the
ledger has rows and emptying it is a large, visible deletion.

WHAT IT DOES NOT COVER
----------------------
* It reads TEXT, not behaviour. A row can carry an eloquent reason that is
  false. What it prevents is a gate arriving with NO reason and nobody noticing
  -- which is how the workspace module sat gated for months.
* `kind: "debt"` rows are a promise, not a schedule. The gate makes the debt
  countable and named; it does not make anyone pay it.
* It says nothing about tests deleted outright. The old exact pin did catch
  that, and this does not; the trade was deliberate. Gating a test is a
  one-line attribute that leaves every lane green, which is the move that needs
  a machine. Deleting a test deletes test code, which review sees.
* Frozen ports are out of scope by POLICY.md section 1.
"""

import argparse
import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SRC = REPO / "jas_dioxus" / "src"
LEDGER = REPO / "scripts" / "native_test_gating_ledger.json"

CFG = re.compile(r"#\[cfg\((.*)\)\]\s*$")
MOD = re.compile(r"(?:pub(?:\(crate\))?\s+)?mod\s+(\w+)\s*;")
FN = re.compile(r"(?:pub(?:\(crate\))?\s+)?(?:async\s+)?fn\s+(\w+)")
TESTMOD = re.compile(r"(?:pub(?:\(crate\))?\s+)?mod\s+(\w+)\s*\{?")


def classifies_as_web_gate(cfg_body: str) -> bool:
    """Does this cfg REMOVE the item from a `--no-default-features` build?

    True for `feature = "web"` and `all(target_arch = "wasm32", feature =
    "web")`. False for the `not(...)` forms, which are the NATIVE arm and are
    present in the tree today.
    """
    body = re.sub(r"\s+", "", cfg_body)
    if 'feature="web"' not in body:
        return False
    return "not(" not in body


def mentions_web(cfg_body: str) -> bool:
    return 'feature="web"' in re.sub(r"\s+", "", cfg_body)


RECOGNISED = ('feature="web"', 'all(target_arch="wasm32",feature="web")',
              'not(all(target_arch="wasm32",feature="web"))', 'not(feature="web")')


def scan(files):
    """(module_gates, item_gates, unrecognised) over {relpath: text}."""
    modules, items, unknown = {}, {}, []
    for rel, text in sorted(files.items()):
        lines = text.splitlines()
        for i, ln in enumerate(lines):
            m = CFG.match(ln.strip())
            if not m or not mentions_web(m.group(1)):
                continue
            norm = re.sub(r"\s+", "", m.group(1))
            if norm not in RECOGNISED:
                unknown.append((rel, i + 1, m.group(1)))
                continue
            if not classifies_as_web_gate(m.group(1)):
                continue
            # walk forward past further attributes and comments to the item
            j, is_test = i + 1, False
            while j < len(lines):
                s = lines[j].strip()
                if s.startswith("#["):
                    if re.match(r"#\[test\]|#\[cfg\(test\)\]", s):
                        is_test = True
                    j += 1
                    continue
                if s.startswith("//") or not s:
                    j += 1
                    continue
                break
            if j >= len(lines):
                continue
            item = lines[j].strip()
            mm = MOD.match(item)
            if mm and not is_test:
                modules[f"{rel}::{mm.group(1)}"] = i + 1
                continue
            if not is_test:
                continue
            fm = FN.match(item)
            name = fm.group(1) if fm else None
            if name is None:
                tm = TESTMOD.match(item)
                name = f"mod {tm.group(1)}" if tm else item[:40]
            items[f"{rel}::{name}"] = i + 1
    return modules, items, unknown


def audit(modules, items, ledger):
    """[(severity, key, message)] -- undeclared gates and stale rows."""
    out = []
    lmod = ledger.get("modules", {})
    litem = ledger.get("items", {})

    for key, line in sorted(modules.items()):
        row = lmod.get(key)
        if row is None:
            out.append(("undeclared", f"{key}:{line}",
                        "a MODULE is gated behind `web` with no ledger row. Every "
                        "test inside it is invisible to a native build; say why, or "
                        "move the gate inward to the submodules that need it"))
        else:
            out.extend(_row_problems("modules", key, row))

    for key, line in sorted(items.items()):
        row = litem.get(key)
        if row is None:
            out.append(("undeclared", f"{key}:{line}",
                        "a TEST is gated behind `web` with no ledger row -- this is "
                        "the move that turns a native-build gate green while "
                        "reducing what is verified"))
        else:
            out.extend(_row_problems("items", key, row))

    out.extend(stale_exemptions(modules, items, ledger))
    return out


def stale_exemptions(modules, items, ledger):
    """THE SECOND LOOP: rows that have outlived the gate they excuse.

    An exemption ledger without this asks only "is every gate declared?" and
    never "is every declaration still needed?" -- so rows accumulate, and a row
    that was true when written quietly stops being true. That is the
    premise-expiry shape this project keeps finding in itself, and
    `check_gate_consistency.py` requires this loop of any gate carrying a
    non-empty ledger.

    It is also this gate's DERIVED anti-vacuity guard: a scanner that breaks and
    returns nothing makes every row stale, so the gate reds instead of passing.
    """
    out = []
    for key in sorted(set(ledger.get("modules", {})) - set(modules)):
        out.append(("stale", key,
                    "a ledger row for a module gate that no longer exists. If the "
                    "gate was removed, remove the row in the same commit"))
    for key in sorted(set(ledger.get("items", {})) - set(items)):
        out.append(("stale", key,
                    "a ledger row for a test gate that no longer exists -- delete "
                    "it, and enjoy having paid a debt"))
    return out


def _row_problems(section, key, row):
    out = []
    kind = row.get("kind")
    if kind not in ("frontend", "debt"):
        out.append(("malformed", key,
                    f"kind={kind!r}; must be 'frontend' (genuinely needs the "
                    f"frontend) or 'debt' (could come home, blocked by something)"))
    if not str(row.get("reason", "")).strip():
        out.append(("malformed", key, "no reason -- a row with no reason is a "
                                      "rubber stamp with extra steps"))
    if kind == "debt" and not str(row.get("blocked_by", "")).strip():
        out.append(("malformed", key, "kind='debt' must name `blocked_by`; debt "
                                      "nobody can find is not debt, it is a shrug"))
    return out


def load_ledger():
    try:
        return json.loads(LEDGER.read_text(encoding="utf-8"))
    except OSError:
        return None
    except json.JSONDecodeError as e:
        print(f"ERROR: {LEDGER.name} is not valid JSON: {e}", file=sys.stderr)
        sys.exit(1)


def load_sources():
    out = {}
    for p in sorted(SRC.rglob("*.rs")):
        try:
            out[p.relative_to(REPO).as_posix()] = p.read_text(encoding="utf-8")
        except OSError:
            continue
    return out


# --------------------------------------------------------------------------
# self-test -- prove the RED before trusting the green
# --------------------------------------------------------------------------

def self_test():
    failures = []

    def check(label, want, got):
        if want != got:
            failures.append(f"  {label}: expected {want}, got {got}")

    # (1) THE FOUR SPELLINGS PRESENT IN THE TREE, pinned. A fifth must be
    #     considered rather than silently skipped -- see (6).
    check("plain web gates out", True, classifies_as_web_gate('feature = "web"'))
    check("wasm+web gates out", True,
          classifies_as_web_gate('all(target_arch = "wasm32", feature = "web")'))
    check("not(web) is the NATIVE arm", False, classifies_as_web_gate('not(feature = "web")'))
    check("not(all(wasm,web)) is native", False,
          classifies_as_web_gate('not(all(target_arch = "wasm32", feature = "web"))'))
    check("whitespace does not matter", True, classifies_as_web_gate('feature="web"'))
    check("an unrelated cfg is not a web gate", False, classifies_as_web_gate('test'))

    # (2) A gated MODULE is found and keyed by declaring file.
    src = {"a/mod.rs": '#[cfg(feature = "web")]\npub mod views;\n'}
    mods, items, unk = scan(src)
    check("module gate found", ["a/mod.rs::views"], sorted(mods))
    check("no item gates here", [], sorted(items))

    # (3) A gated TEST is found -- through an interleaved comment and a second
    #     attribute, which is how they are actually written.
    src = {"t.rs": '#[cfg(feature = "web")]\n// why\n#[test]\nfn drives_the_shell() {}\n'}
    mods, items, unk = scan(src)
    check("test gate found", ["t.rs::drives_the_shell"], sorted(items))

    # (4) A NATIVE-arm item is not a gate. Getting this backwards would demand
    #     ledger rows for the very code that exists to run natively.
    src = {"n.rs": '#[cfg(not(feature = "web"))]\n#[test]\nfn native_only() {}\n'}
    mods, items, unk = scan(src)
    check("not(web) yields no gate", ([], []), (sorted(mods), sorted(items)))

    # (5) A gate on a NON-test, NON-module item is out of scope: this gate is
    #     about hidden VERIFICATION, not about conditional compilation at large.
    src = {"p.rs": '#[cfg(feature = "web")]\nfn helper() {}\n'}
    mods, items, unk = scan(src)
    check("plain fn is out of scope", ([], []), (sorted(mods), sorted(items)))

    # (6) A NOVEL SPELLING REDS. Assertion (4): a scanner that quietly skips
    #     what it cannot parse under-reports, and under-reporting here is
    #     indistinguishable from compliance.
    src = {"x.rs": '#[cfg(any(feature = "web", feature = "d2d"))]\n#[test]\nfn t() {}\n'}
    mods, items, unk = scan(src)
    check("novel spelling is reported", 1, len(unk))
    check("...and not silently gated", ([], []), (sorted(mods), sorted(items)))

    # (7) UNDECLARED gates red -- one per kind.
    mods = {"a/mod.rs::views": 1}
    items = {"t.rs::drives_the_shell": 3}
    probs = audit(mods, items, {"modules": {}, "items": {}})
    check("both undeclared red", 2, len(probs))
    check("both are 'undeclared'", {"undeclared"}, {p[0] for p in probs})

    # (8) Declared with a reason: silent.
    led = {"modules": {"a/mod.rs::views": {"kind": "frontend", "reason": "Dioxus views"}},
           "items": {"t.rs::drives_the_shell": {"kind": "frontend", "reason": "drives AppState"}}}
    check("declared is silent", [], audit(mods, items, led))

    # (9) STALE rows red. This is the second loop: a row that outlived its gate
    #     is the premise-expiry shape this project keeps finding in itself.
    probs = audit({}, {}, led)
    check("stale rows red", 2, len(probs))
    check("both are 'stale'", {"stale"}, {p[0] for p in probs})

    # (10) THE DERIVED ANTI-VACUITY GUARD. A scanner that breaks and returns
    #      nothing does not go green: every row goes stale. This is what
    #      replaces the hand-typed FLOOR, and it has no number in it.
    probs = audit({}, {}, led)
    if not probs:
        failures.append("  10: a broken scanner must red via stale rows, not pass")

    # (11) A row with no reason, or debt with no blocker, is refused.
    bad = {"modules": {"a/mod.rs::views": {"kind": "frontend", "reason": "  "}},
           "items": {"t.rs::drives_the_shell": {"kind": "debt", "reason": "later"}}}
    probs = audit({"a/mod.rs::views": 1}, {"t.rs::drives_the_shell": 3}, bad)
    check("blank reason and blockerless debt red", 2, len(probs))
    check("both 'malformed'", {"malformed"}, {p[0] for p in probs})

    # (12) An unknown kind is refused -- 'todo' must not become a third class
    #      by being typed.
    bad = {"modules": {"a/mod.rs::views": {"kind": "todo", "reason": "x"}}, "items": {}}
    probs = audit({"a/mod.rs::views": 1}, {}, bad)
    check("unknown kind red", 1, len(probs))

    # (13) THE LIVE TREE must be clean right now.
    ledger = load_ledger()
    if ledger is None:
        failures.append(f"  13: {LEDGER.name} is missing")
    else:
        m, i, u = scan(load_sources())
        live = audit(m, i, ledger)
        if live:
            failures.append(f"  13: the live tree has {len(live)} problem(s): {live[:3]}")
        if u:
            failures.append(f"  13: unrecognised cfg spelling(s): {u[:3]}")
        if not (ledger.get("modules") or ledger.get("items")):
            failures.append("  13: the ledger is EMPTY, so the derived anti-vacuity "
                            "guard in (10) has nothing to go stale")

    if failures:
        print("SELF-TEST FAILED -- the gate does not detect what it claims:",
              file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1
    m, i, _ = scan(load_sources())
    print(f"self-test OK: four cfg spellings classified (two of them the NATIVE "
          f"arm, which must NOT count), module and test gates found through "
          f"interleaved comments and attributes, a novel spelling REDS rather "
          f"than skipping, undeclared gates red, stale rows red -- which is also "
          f"the derived anti-vacuity guard, with no number in it -- and blank "
          f"reasons / blockerless debt / unknown kinds are refused. "
          f"Live: {len(m)} module gate(s), {len(i)} test gate(s).")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--self-test", action="store_true",
                    help="prove the gate's RED and exit")
    ap.add_argument("--dump", action="store_true",
                    help="list every web gate found, for authoring the ledger")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    modules, items, unknown = scan(load_sources())

    if args.dump:
        print(f"# {len(modules)} module gate(s)")
        for k, v in sorted(modules.items()):
            print(f"  {k}  (line {v})")
        print(f"# {len(items)} test-item gate(s)")
        for k, v in sorted(items.items()):
            print(f"  {k}  (line {v})")
        if unknown:
            print(f"# {len(unknown)} UNRECOGNISED cfg spelling(s)")
            for rel, line, body in unknown:
                print(f"  {rel}:{line}  cfg({body})")
        return 0

    ledger = load_ledger()
    if ledger is None:
        print(f"ERROR: {LEDGER.name} is missing. Without it every gate below is "
              f"undeclared and the derived anti-vacuity guard has nothing to "
              f"go stale.", file=sys.stderr)
        return 1

    problems = audit(modules, items, ledger)
    if unknown:
        for rel, line, body in unknown:
            problems.append(("unrecognised", f"{rel}:{line}",
                             f"cfg({body}) mentions the web feature in a form this "
                             f"scanner does not recognise. Teach it the spelling, or "
                             f"use one of the four already in the tree -- a scanner "
                             f"that skips what it cannot parse under-reports, and "
                             f"under-reporting here looks exactly like compliance"))

    if not problems:
        debt = sum(1 for r in ledger.get("items", {}).values() if r.get("kind") == "debt")
        debt += sum(1 for r in ledger.get("modules", {}).values() if r.get("kind") == "debt")
        print(f"native test gating: {len(modules)} module gate(s) and {len(items)} "
              f"test gate(s), all declared; no stale rows. "
              f"{debt} row(s) are recorded DEBT -- verification that could come home.")
        return 0

    print(f"ERROR: {len(problems)} problem(s) with `web` gating of verification.",
          file=sys.stderr)
    print(file=sys.stderr)
    for sev, key, why in problems:
        print(f"  [{sev}] {key}", file=sys.stderr)
        print(f"      {why}", file=sys.stderr)
    print(file=sys.stderr)
    print("A test behind `feature = \"web\"` does not run in a native build. D1 put",
          file=sys.stderr)
    print("a sixth port on this Rust core, so a shared law verified in only one",
          file=sys.stderr)
    print("build is a law with one witness -- which is how the text-width law",
          file=sys.stderr)
    print("drifted (CHARWIDTH) and how 185 workspace tests sat unrun for months.",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
