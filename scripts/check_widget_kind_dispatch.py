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
* It says nothing about the ACTIONS a widget's behaviour dispatches. That is
  still true of THIS gate, and it is what made the three arms misleading. It is
  NO LONGER an open gap: `check_action_implementations.py` -- added 2026-07-30,
  ONE DAY after this file -- parses per-port dispatch labels and classifies every
  log-only action as native in both ports, declared-bypassed, or divergent.
  `check_action_refs.py` validates references and not per-port handlers, which is
  why it was named here as insufficient and still is.
  (Corrected 2026-09-03: the sentence above read "that is a real adjacent gap"
  for five weeks after the gap closed. A caveat is written when a gap is open and
  is never re-read when it shuts, so it decays toward PESSIMISM -- and a phantom
  gap in a gate's own header invites redundant work while looking like rigour.)
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
MIN_KINDS = 38
#
# EXACT, NOT SLACK. This was a hand-set floor with room to spare until
# 2026-07-29, when the jas/windows seat proved the hole by mutation: it set a
# test-count floor 1.6% below reality, gated six tests off, and the gate went
# GREEN. Its sentence is the rule now --
#
#     "A floor with slack is a floor with a hole exactly the size of the slack,
#      and the hole admits precisely the move the assertion exists to forbid."
#
# The floor is the ONLY guard for the CANONICAL set: kinds the parse misses
# are never compared against any port, so a port missing one of them
# passes. (MIN_ARMS below keeps its slack deliberately -- a partial arm
# parse OVER-reports gaps, which is loud, not silent.)
#
# Adding to the set means raising this number in the same commit. That friction
# is the feature: the number is a claim about coverage, and a claim nobody has
# to restate is a claim nobody rechecks. (The model is
# check_preservation_corpus.py, whose floor is DERIVED from per-vector `n_min`
# declarations and therefore cannot drift at all -- prefer that shape where the
# data can declare itself.)
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
    raw = json.loads(LEDGER.read_text(encoding="utf-8")).get("exemptions", {})
    return {k: normalise_row(v) for k, v in raw.items()}


def normalise_row(row):
    """One shape for a row, whether it was written as a bare string or an object.

    The bare-string spelling is still accepted so a row can be added in a hurry,
    but it arrives with NO asserts and `verify_asserts` refuses that unless the
    row is declared permanent -- so the hurry is visible rather than silent.
    """
    if isinstance(row, str):
        return {"reason": row, "asserts": [], "permanent": False}
    return {
        "reason": row.get("reason", ""),
        "asserts": row.get("asserts", []),
        "permanent": bool(row.get("permanent", False)),
    }


def verify_asserts(exemptions, read_file):
    """Broken justifications, as `(key, description)` pairs.

    WHY A GATE CHECKS ITS OWN LEDGER'S PROSE. Every exemption is an argument
    that a gap is intended, and an argument rests on facts about the tree. The
    facts move; the prose does not. On 2026-07-29 the `swift:dropdown` row still
    asserted JasSwift had "neither the state nor the filtering" months after it
    had both -- and a seat read the row, believed it, and started rebuilding
    what already shipped. The false clause had also been copied into a source
    comment, so two places agreed and neither was checked.

    So each row states its argument as {file, contains|lacks} claims, and this
    verifies them on every run. The valuable direction is the one that fires
    when the gap CLOSES: an exemption must not outlive the condition it
    describes.
    """
    broken = []
    for key, row in sorted(exemptions.items()):
        claims = row["asserts"]
        if not claims:
            if not row["permanent"]:
                broken.append((
                    key,
                    "carries no `asserts` and is not declared `permanent` -- an "
                    "exemption whose reason cannot be checked is a hole that "
                    "outlives its argument"))
            continue
        if row["permanent"]:
            broken.append((key, "is declared `permanent` yet carries `asserts`; "
                                "a permanent exemption has nothing to falsify"))
        for i, claim in enumerate(claims):
            path = claim.get("file")
            if not path:
                broken.append((key, f"assert #{i} names no `file`"))
                continue
            src = read_file(path)
            if src is None:
                broken.append((key, f"assert #{i} names {path}, which is not readable"))
                continue
            if "contains" in claim and claim["contains"] not in src:
                broken.append((
                    key,
                    f"assert #{i} expects {path} to CONTAIN {claim['contains']!r} "
                    f"and it does not. {claim.get('why', '')}".rstrip()))
            if "lacks" in claim and claim["lacks"] in src:
                broken.append((
                    key,
                    f"assert #{i} expects {path} to LACK {claim['lacks']!r} "
                    f"and it is present. {claim.get('why', '')}".rstrip()))
            if "contains" not in claim and "lacks" not in claim:
                broken.append((
                    key, f"assert #{i} states neither `contains` nor `lacks`"))
    return broken


def read_repo_file(path):
    try:
        return (REPO / path).read_text(encoding="utf-8")
    except OSError:
        return None


def below_floor(n_kinds, arm_counts):
    return n_kinds < MIN_KINDS or any(n < MIN_ARMS for n in arm_counts)


def unexcused_kinds(kinds, per_port):
    """Every (port, kind) a port does not dispatch, BEFORE exemptions apply.

    Needed by `stale_exemptions`, which asks the question this gate could not
    previously ask at all.
    """
    return {
        (port, kind)
        for port, handled in per_port.items()
        for kind in kinds - handled
    }


def stale_exemptions(kinds, per_port, exemptions):
    """Exemption rows whose gap has CLOSED -- the port now dispatches the kind.

    FLASK'S FINDING (jas/windows, letter 11, 2026-07-30), and it is a hole no
    claim machinery could have covered:

        The gate iterates GAPS and asks "is this excused?". It never iterates
        EXEMPTIONS and asks "is this still needed?"

    A row whose condition has closed is never VISITED, because the kind stopped
    being a gap -- so its `asserts` are never evaluated and it can outlive its
    own justification indefinitely. That is exactly how `swift:dropdown` came to
    assert JasSwift "has neither the state nor the filtering" for months after
    JasSwift shipped both, and adding `{file, contains|lacks}` claims did not
    fix it: the claim was never reached to be checked.

    The repair is this second loop, and it needs no new vocabulary. Note the
    sentinel rows are unaffected by construction: `placeholder` is the fallback
    kind no port dispatches, so it never stops being a gap.

    Written after the same idea was independently built into the sibling gate
    (`retired`, check_action_implementations.py) and NOT back-ported here --
    which is its own small lesson about fixing an instance rather than a class.
    """
    open_gaps = unexcused_kinds(kinds, per_port)
    known_ports = set(per_port)
    out = []
    for key in sorted(exemptions):
        port, _, kind = key.partition(":")
        if port not in known_ports:
            continue          # a row for a port this run did not scan
        if (port, kind) not in open_gaps:
            out.append((key, f"{port} now dispatches \"{kind}\" -- the gap this "
                             f"row excuses has CLOSED, so the row is obsolete"))
    return out


def gaps(kinds, per_port, exemptions):
    """(port, kind) pairs a port does not dispatch and has not excused.

    A row excuses only via a NON-EMPTY reason. Normalising here as well as in
    `load_exemptions` keeps the row shape from mattering to callers -- and
    matters because a normalised row is a dict, which is truthy even when its
    reason is blank. Testing the container instead of the argument is precisely
    the kind of check that passes while meaning nothing.
    """
    out = []
    for port, handled in sorted(per_port.items()):
        for kind in sorted(kinds - handled):
            if normalise_row(exemptions.get(f"{port}:{kind}", ""))["reason"]:
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

    # (d2) The OBJECT spelling with a blank reason excuses nothing either. A
    #      normalised row is a dict, and a dict is truthy -- so a container test
    #      would pass here while meaning nothing.
    if gaps(kinds, {"swift": kinds - {"dropdown"}},
            {"swift:dropdown": {"reason": "", "asserts": []}}) != [("swift", "dropdown")]:
        failures.append("  a blank reason in OBJECT form must NOT excuse the gap")

    # ── The justification checks. Each row's reason is an argument about the
    #    tree, and these prove the gate notices when the argument stops holding.
    fake = {
        "a.swift": 'case "dropdown": renderDropdown()\nfunc layersTypeValue() {}\n',
        "b.rust": '"dropdown" => render_layers_filter_dropdown(el),\n',
    }
    read = lambda p: fake.get(p)

    def claims_red(name, row, want_red, want_substr=None):
        broken = verify_asserts({"swift:dropdown": normalise_row(row)}, read)
        if bool(broken) != want_red:
            verb = "RED" if want_red else "GREEN"
            failures.append(f"  {name}: expected {verb}, got {broken or 'GREEN'}")
        if want_substr and not any(want_substr in w for _, w in broken):
            failures.append(f"  {name}: message should mention {want_substr!r}, got {broken}")

    # (f) A `contains` claim that HOLDS is silent.
    claims_red("f/contains holds",
               {"reason": "r", "asserts": [
                   {"file": "a.swift", "contains": "func layersTypeValue"}]}, False)

    # (g) THE DIRECTION THAT MATTERS -- a `lacks` claim broken because the gap
    #     CLOSED. The exemption must not outlive the condition it describes,
    #     which is the whole failure this mechanism exists to prevent.
    claims_red("g/gap closed",
               {"reason": "r", "asserts": [
                   {"file": "a.swift", "lacks": 'case "dropdown"',
                    "why": "the arm landed"}]}, True, want_substr="the arm landed")

    # (h) A `contains` claim broken because the thing it cited was DELETED --
    #     the swift:dropdown row's own historical failure mode, where the
    #     reason described a state of the world that had moved on.
    claims_red("h/citation vanished",
               {"reason": "r", "asserts": [
                   {"file": "a.swift", "contains": "func neverExisted"}]}, True)

    # (i) An unreadable file is a BROKEN claim, not a passing one. A renamed
    #     file must not silently retire an argument.
    claims_red("i/file gone",
               {"reason": "r", "asserts": [
                   {"file": "nope.swift", "contains": "x"}]}, True)

    # (j) A row with NO asserts and no `permanent` flag is refused: an
    #     unfalsifiable reason is a hole that outlives its argument.
    claims_red("j/unfalsifiable", {"reason": "r", "asserts": []}, True)
    claims_red("j/legacy string", "a bare string reason", True)

    # (k) `permanent` excuses the absence of asserts -- the sentinel rows -- but
    #     may not carry them, so the two spellings cannot blur together.
    claims_red("k/permanent", {"reason": "r", "permanent": True, "asserts": []}, False)
    claims_red("k/permanent with claims",
               {"reason": "r", "permanent": True,
                "asserts": [{"file": "a.swift", "contains": "func layersTypeValue"}]}, True)

    # (l) A malformed claim is refused rather than skipped.
    claims_red("l/no file", {"reason": "r", "asserts": [{"contains": "x"}]}, True)
    claims_red("l/no predicate", {"reason": "r", "asserts": [{"file": "a.swift"}]}, True)

    # (n) FLASK'S CASE: an exemption whose gap has CLOSED. No assert can reach
    #     this -- the row is never visited once the kind stops being a gap --
    #     which is why it needs its own loop and its own self-test arm.
    closed = stale_exemptions(kinds, {"swift": set(kinds)},
                              {"swift:dropdown": normalise_row("a reason")})
    if not closed:
        failures.append("  n: an exemption whose port now dispatches the kind must be STALE")
    elif "CLOSED" not in closed[0][1]:
        failures.append(f"  n: message should say the gap closed, got {closed[0][1]}")
    #     ...and it must stay silent while the gap is genuinely open.
    if stale_exemptions(kinds, {"swift": kinds - {"dropdown"}},
                        {"swift:dropdown": normalise_row("a reason")}):
        failures.append("  n: an OPEN gap's exemption must not be called stale")
    #     The sentinel is safe by construction -- but ONLY because `placeholder`
    #     is itself a canonical kind that no port dispatches, so it never stops
    #     being a gap. The first draft of this arm used a `kinds` set without
    #     `placeholder` in it and the sentinel came back STALE, which is the
    #     honest warning: were `placeholder` ever dropped from the canonical
    #     set, both permanent rows would be reported obsolete every run.
    sentinel_kinds = kinds | {"placeholder"}
    if stale_exemptions(sentinel_kinds, {"swift": sentinel_kinds - {"placeholder"}},
                        {"swift:placeholder": normalise_row("THE SENTINEL")}):
        failures.append("  n: the sentinel row must never be reported stale")

    # (m) THE LIVE LEDGER's own justifications must hold right now. This is the
    #     production assertion, run here too so `--self-test` alone catches a
    #     row that has gone stale.
    if LEDGER.exists():
        live = verify_asserts(load_exemptions(), read_repo_file)
        if live:
            failures.append(f"  the shipping ledger has stale justifications: {live}")

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
          f"scoping and blank-reason rejection (both spellings) all hold; "
          f"exemption JUSTIFICATIONS are checked in every direction -- a closed "
          f"gap, a vanished citation, an unreadable file, an unfalsifiable row "
          f"and a malformed claim each go RED, and the shipping ledger's own "
          f"claims are verified here too; both ports' dispatch arms parse "
          f"({', '.join(f'{p}={len(k)}' for p, k in sorted(real.items()))}) "
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

    # An exemption's ARGUMENT is checked before its effect is honoured, because
    # a stale argument is worse than a missing one: it reads as a decision.
    # Flask's loop FIRST: a row whose gap has closed is obsolete whatever its
    # claims say, and it is the case no assert can reach.
    stale = stale_exemptions(kinds, per_port, exemptions) \
        + verify_asserts(exemptions, read_repo_file)
    if stale:
        print(f"ERROR: {len(stale)} exemption justification(s) in "
              f"{LEDGER.relative_to(REPO).as_posix()} no longer hold.",
              file=sys.stderr)
        print(file=sys.stderr)
        for key, why in stale:
            print(f"  {key}: {why}", file=sys.stderr)
        print(file=sys.stderr)
        print("An exemption is an ARGUMENT that a gap is intended, and an argument", file=sys.stderr)
        print("rests on facts about the tree. The facts move; the prose does not.", file=sys.stderr)
        print("This row's own claims say it is now out of date -- either the gap", file=sys.stderr)
        print("closed (delete the row) or the reason changed (rewrite it, with", file=sys.stderr)
        print("asserts that match the new argument).", file=sys.stderr)
        print(file=sys.stderr)
        print("Do NOT relax the asserts to make this pass. That is how the", file=sys.stderr)
        print("swift:dropdown row came to assert JasSwift lacked a filter it had", file=sys.stderr)
        print("shipped for months, and cost a seat an evening rebuilding it.", file=sys.stderr)
        return 1

    if not found:
        counts = ", ".join(f"{p} {len(v)}" for p, v in sorted(per_port.items()))
        n_ex = sum(1 for v in exemptions.values() if v["reason"])
        n_claims = sum(len(v["asserts"]) for v in exemptions.values())
        print(f"widget-kind dispatch: {len(kinds)} canonical kinds, all dispatched "
              f"by every active port ({counts})"
              + (f", {n_ex} declared exemption(s) whose {n_claims} justifying "
                 f"claim(s) all still hold" if n_ex else "") + ".")
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
