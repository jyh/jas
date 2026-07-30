#!/usr/bin/env python3
"""Every ACTIVE PORT must dispatch every canonical widget kind — or declare why not.

WHY THIS EXISTS
---------------
`workspace_interpreter/widget_tree.py` single-sources the canonical widget-kind
vocabulary, and `test_widget_kind_coverage.py` checks that every `type:` in the
workspace is drawn from it. That gate says its own limitation out loud:

    "It does NOT yet check *per-app coverage* (is the kind handled by every
     app's dispatch) -- that is the broader cross-app gate tracked in
     TESTING_STRATEGY.md."

This is that gate. On 2026-07-29 the jas/windows seat counted the dispatch arms
and found **jas_dioxus handling 38 kinds and JasSwift handling 35**. The three
missing were not hypothetical -- all three are declared in the shipping
workspace:

  * `dropdown`                -- workspace/panels/layers.yaml, the element-type filter
  * `icon_button_group`       -- workspace/dialogs/artboard_options.yaml, orientation
  * `reference_point_widget`  -- workspace/dialogs/artboard_options.yaml, the 3x3 anchor

JasSwift falls through to `renderPlaceholder()`, which renders the widget's
`summary` string. **So the Layers panel's filter control appeared as the literal
text "Filter by element type"** -- and that text was visible in a screenshot the
Captain sent this seat hours earlier. Nobody read it as a defect. A gate reading
the dispatch arms would have.

WHAT MAKES THIS WORTH A GATE RATHER THAN THREE FIXES
----------------------------------------------------
Chasing the three arms is the wrong lesson twice over.

FIRST: the arms were a SYMPTOM. Tracing them found that the ACTIONS behind two
of them are also absent from JasSwift (`set_artboard_reference_point`,
`toggle_artboard_orientation`), and that the third needs native filter state
plus tree filtering that JasSwift does not have. They are three unimplemented
FEATURES, not three missing switch cases -- so adding the arms alone would ship
controls that look functional and do nothing, which is strictly worse than a
placeholder. A placeholder is visibly not a control.

SECOND: **port six's dispatch table starts EMPTY.** D1 (ruled 2026-07-29) gives
port six a new native frontend over the shared Rust core. This gate is how that
frontend knows what it still owes, one line per kind, instead of discovering it
by screenshot.

WHAT IT DOES NOT COVER
----------------------
* It reads DISPATCH ARMS syntactically. A port that dispatches a kind to a stub
  passes here -- the arm exists. Whether the widget WORKS is not a syntactic
  property, and the two artboard kinds above are exactly why that caveat
  matters: an arm is necessary and nowhere near sufficient.
* It says nothing about the ACTIONS a widget's behaviour dispatches. That is a
  real adjacent gap (`check_action_refs.py` validates references, not per-port
  handlers) and it is what made the three arms misleading.
* Frozen ports are out of scope by policy.
"""

import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
LEDGER = REPO / "scripts" / "widget_dispatch_exemptions.json"

# Anti-vacuity floor: if the canonical set or a port's arm count collapses, the
# comparison reports no gaps, which is indistinguishable from full coverage.
MIN_KINDS = 30
MIN_ARMS = 25

PORTS = {
    # port: (file, regex capturing the dispatched kind)
    "rust": (
        "jas_dioxus/src/interpreter/renderer.rs",
        # `"kind" => render_x(...)` and `"a" | "b" => ...` in the widget match.
        # The group must capture the QUOTED list, not the bare kind: `dispatched`
        # re-extracts quoted strings from it so one code path serves both ports.
        # A first draft captured the bare name, `findall` then found no quotes in
        # it, and rust parsed as ZERO arms -- caught by the anti-vacuity floor
        # rather than reported as 38 gaps.
        re.compile(r'((?:"[a-z_]+"\s*\|\s*)*"[a-z_]+")\s*=>'),
    ),
    "swift": (
        "JasSwift/Sources/Interpreter/YamlPanelBodyView.swift",
        # `case "kind":` and `case "a", "b":`
        re.compile(r'case\s+((?:"[a-z_]+"\s*,\s*)*"[a-z_]+")\s*:'),
    ),
}


def canonical_kinds():
    src = (REPO / "workspace_interpreter" / "widget_tree.py").read_text(encoding="utf-8")
    m = re.search(r"CANONICAL_WIDGET_KINDS = frozenset\(\{(.*?)\}\)", src, re.S)
    if not m:
        return set()
    return set(re.findall(r'"([a-z_]+)"', m.group(1)))


def dispatched(port):
    rel, pattern = PORTS[port]
    src = (REPO / rel).read_text(encoding="utf-8")
    out = set()
    for m in pattern.finditer(src):
        out.update(re.findall(r'"([a-z_]+)"', m.group(1)))
    return out


def load_exemptions():
    if not LEDGER.exists():
        return {}
    return json.loads(LEDGER.read_text(encoding="utf-8")).get("exemptions", {})


def below_floor(n_kinds, arm_counts):
    return n_kinds < MIN_KINDS or any(n < MIN_ARMS for n in arm_counts)


def gaps(kinds, per_port, exemptions):
    """(port, kind) pairs a port does not dispatch and has not excused."""
    out = []
    for port, handled in sorted(per_port.items()):
        for kind in sorted(kinds - handled):
            if exemptions.get(f"{port}:{kind}"):
                continue
            out.append((port, kind))
    return out


# --------------------------------------------------------------------------
# self-test
# --------------------------------------------------------------------------

def self_test():
    """Prove the gate goes RED on each class it claims to cover."""
    failures = []
    kinds = {"text", "button", "slider", "dropdown", "grid"}

    # (a) A port missing a kind is a GAP.
    g = gaps(kinds, {"swift": {"text", "button", "slider", "grid"}}, {})
    if g != [("swift", "dropdown")]:
        failures.append(f"  missing kind not reported as a gap: {g}")

    # (b) FULL coverage is silent.
    if gaps(kinds, {"rust": set(kinds)}, {}):
        failures.append("  full coverage should be silent")

    # (c) An EXEMPTION excuses exactly one port+kind, not the kind everywhere.
    two = {"swift": kinds - {"dropdown"}, "rust": kinds - {"dropdown"}}
    g = gaps(kinds, two, {"swift:dropdown": "reason"})
    if g != [("rust", "dropdown")]:
        failures.append(f"  exemption must be per-PORT, not per-kind: {g}")

    # (d) An empty-string exemption does not excuse anything. A blank reason is
    #     how an exemption becomes a silent permanent hole.
    if gaps(kinds, {"swift": kinds - {"dropdown"}}, {"swift:dropdown": ""}) != [("swift", "dropdown")]:
        failures.append("  a blank exemption reason must NOT excuse the gap")

    # (e) THE REAL PARSE, both ports, against the live tree. This is the case
    #     that would have caught the shipped defect, and it doubles as a parser
    #     check: if either regex stops matching, the arm count collapses and the
    #     floor below rejects the run.
    real_kinds = canonical_kinds()
    real = {p: dispatched(p) for p in PORTS}
    if len(real_kinds) < MIN_KINDS:
        failures.append(f"  canonical set parsed as {len(real_kinds)} kinds")
    for p, handled in real.items():
        if len(handled) < MIN_ARMS:
            failures.append(f"  {p}: parsed only {len(handled)} dispatch arms")

    # (f) The anti-vacuity floor is itself a class this gate must get right.
    for nk, arms, want_rejected in [
        (0, [0], True),
        (MIN_KINDS - 1, [50], True),
        (MIN_KINDS, [MIN_ARMS - 1], True),
        (MIN_KINDS, [MIN_ARMS], False),
        (38, [38, 35], False),
    ]:
        if below_floor(nk, arms) != want_rejected:
            verb = "reject" if want_rejected else "accept"
            failures.append(f"  floor: {nk} kinds / {arms} arms should {verb}")

    if failures:
        print("SELF-TEST FAILED -- the gate does not detect what it claims:")
        print("\n".join(failures))
        return 1
    print(f"self-test: gap detection, full-coverage silence, PER-PORT exemption "
          f"scoping and blank-reason rejection all hold; both ports' dispatch "
          f"arms parse ({', '.join(f'{p}={len(k)}' for p, k in sorted(real.items()))}) "
          f"against {len(real_kinds)} canonical kinds; anti-vacuity floor holds "
          f"at {MIN_KINDS} kinds / {MIN_ARMS} arms -- gate proven RED where it "
          f"must be.")
    return 0


def main():
    if "--self-test" in sys.argv:
        return self_test()

    kinds = canonical_kinds()
    per_port = {p: dispatched(p) for p in PORTS}

    if below_floor(len(kinds), [len(v) for v in per_port.values()]):
        print(f"ERROR: parsed {len(kinds)} canonical kinds and "
              f"{ {p: len(v) for p, v in per_port.items()} } dispatch arms, below "
              f"the anti-vacuity floor of {MIN_KINDS}/{MIN_ARMS}.", file=sys.stderr)
        print(file=sys.stderr)
        print("This is not a pass. A comparison against an empty set reports no", file=sys.stderr)
        print("gaps, which is indistinguishable from full coverage. Most likely a", file=sys.stderr)
        print("dispatch switch moved and a regex stopped matching.", file=sys.stderr)
        return 1

    exemptions = load_exemptions()
    found = gaps(kinds, per_port, exemptions)

    if not found:
        counts = ", ".join(f"{p} {len(v)}" for p, v in sorted(per_port.items()))
        n_ex = sum(1 for v in exemptions.values() if v)
        print(f"widget-kind dispatch: {len(kinds)} canonical kinds, all dispatched "
              f"by every active port ({counts})"
              + (f", {n_ex} declared exemption(s)" if n_ex else "") + ".")
        return 0

    print(f"ERROR: {len(found)} widget kind(s) are declared in the workspace and "
          f"NOT dispatched by an active port.", file=sys.stderr)
    print(file=sys.stderr)
    for port, kind in found:
        print(f"  {port} does not dispatch \"{kind}\"", file=sys.stderr)
    print(file=sys.stderr)
    print("An undispatched kind falls through to a PLACEHOLDER, which renders the", file=sys.stderr)
    print("widget's `summary` text. That is how the Layers panel's element-type", file=sys.stderr)
    print("filter shipped as the words \"Filter by element type\" in JasSwift.", file=sys.stderr)
    print(file=sys.stderr)
    print("BEFORE ADDING A DISPATCH ARM, check that the ACTIONS its behaviour", file=sys.stderr)
    print("dispatches exist in that port. Two of the three kinds found in 2026-07", file=sys.stderr)
    print("had absent actions too, so an arm alone would have shipped a control", file=sys.stderr)
    print("that looks functional and does nothing -- worse than the placeholder.", file=sys.stderr)
    print(file=sys.stderr)
    print(f"If the gap is real and not yet scheduled, add a row to", file=sys.stderr)
    print(f"{LEDGER.relative_to(REPO).as_posix()} with a NON-EMPTY reason.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
