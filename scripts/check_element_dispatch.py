#!/usr/bin/env python3
"""Every function that dispatches on Element kind must account for CONTAINERS.

WHY THIS EXISTS
---------------
`Element` is a sum type. Its LEAF kinds (Rect, Circle, Ellipse, Polygon,
Polyline, Path, Line, Text, TextPath) carry geometry and paint; its CONTAINER
kinds (Group, Layer) carry children. A function that switches on element kind,
lists the leaves, and lets Group/Layer fall to a catch-all is *container-blind*.

Five defects with exactly that shape were found in one week, every one of them
invisible in Rust and live in JasSwift:

  1. `move_control_points` had no container arm -- a selected group WOULD NOT
     MOVE. You could not drag a group in JasSwift at all.
  2. `copy_selection` mishandled the shape -- duplicating a marquee selection
     DAMAGED THE SOURCE, leaving a group with four children instead of two.
  3. `drawElementOverlay` returned early -- a selected group showed NO HIGHLIGHT.
  4. `with_fill` returned a container unchanged -- selecting a group and
     clicking a swatch DID NOTHING, the commonest operation in the application.
  5. `with_stroke`, the same, and both gradient siblings with it.

They hid in Rust because `doc.set_selection` EXPANDS a named container to all
its descendants (`interpreter/effects.rs`), so the MEMBERS were in the selection
and got operated on. JasSwift does not expand. LAYER_STRUCTURE.md §20 rules the
expansion away, at which point every remaining site goes live in Rust too.

THE DISTINCTION THAT MATTERS, because it is what made #4 and #5 so long-lived:
*"a container has no fill of its own"* is TRUE OF THE DATA MODEL and FALSE OF
THE ARTIST'S INTENT. Both ports named Group and Layer **explicitly** in an arm
that returned them unchanged, so being explicit about containers is not evidence
of correctness. The question is always what the ARTIST expects.

WHAT THIS GATE IS -- A LEDGER, NOT A REACHABILITY PROVER
--------------------------------------------------------
It does NOT try to decide whether a selection loop can reach a function. That
would be a multi-hop call-graph claim, and a gate that guesses is worse than no
gate (`kenai_watch`'s lesson, learned on a different instrument: an instrument
that lies is worse than none).

Instead it asserts a SYNTACTIC property -- "this function dispatches on element
kind and has no container arm" -- and requires every such site to be classified
ONCE, by a human or a review, in `element_dispatch_ledger.json`:

  * `leaf_only`  -- the container case IS handled: somewhere else by name (the
    eyedropper's caller recurses into a group and applies to every leaf), or by
    this function's own catch-all deliberately (a Group's four bounding-box
    corners are what DOCUMENT.md's table asks for). The row must say WHERE.
  * `unhandled`  -- the container case has NO answer anywhere, and nothing
    reaches here today only because something upstream declines to pass one, or
    because the feature has no production caller at all. The row must name what
    keeps it unreached. **This is not a decision to reject containers** -- it is
    an unfinished feature with a note saying so, and it becomes `owed` the day
    that gate moves or the feature is wired.
  * `owed`       -- a container DOES reach here, and the result is wrong or
    silently nothing. Known debt: recorded, counted, and NOT failed on, so the
    ledger can carry honest work-in-progress rather than tempting anyone to
    mislabel it.

The distinction between the first two is the one that earns its keep. Both leave
this function never seeing a container, but for OPPOSITE reasons: the eyedropper
unwraps the group and does the work, while shape recognition gives up. Writing
`leaf_only` on the second tells the next reader "containers: handled, nothing to
do" -- and they ship the silent no-op.

A NEW site fails until classified. A ledger row whose site is gone also fails --
debt that was repaired must be struck, or the ledger slowly becomes fiction.

WHAT IT DOES NOT COVER
----------------------
* It is syntactic. A function that takes an element and dispatches indirectly
  (through a helper, a trait, a table) is invisible here.
* `leaf_only` is a claim by whoever wrote the row. This gate checks that a claim
  EXISTS, never that it is true.
* Frozen ports are out of scope by policy, as everywhere else.
"""

import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
LEDGER_PATH = REPO / "scripts" / "element_dispatch_ledger.json"

# A function must name at least this many distinct LEAF kinds before we call it
# "dispatching on element kind". Below it, a match on one or two kinds is
# ordinary special-casing, not a dispatch table, and demanding a container arm
# would be noise.
MIN_LEAF_KINDS = 3

# Anti-vacuity floors. A scan that found nothing reports no unclassified sites,
# which is indistinguishable from a scan that found everything in order.
MIN_FILES = 40
MIN_SITES = 15

VALID_VERDICTS = {"leaf_only", "unhandled", "owed"}

LEAF_RUST = re.compile(
    r"Element::(Rect|Circle|Ellipse|Polygon|Polyline|Path|Line|Text|TextPath)\b")
CONT_RUST = re.compile(r"Element::(Group|Layer)\b")
LEAF_SWIFT = re.compile(
    r"case\s+\.(rect|circle|ellipse|polygon|polyline|path|line|text|textPath)\b")
# Swift containers appear as `case .group`, `case .group(let g)`, or the
# `if case .group = elem` form that defect #3 used to return early.
CONT_SWIFT = re.compile(r"(?:case\s+\.(?:group|layer)\b|case\s+\.(?:group|layer)\s*\()")


def _strip_noise(src):
    """Blank out string literals and line comments, preserving length and
    newlines so offsets and line numbers stay valid.

    Only needed so brace counting is not thrown by a `{` inside a string or a
    comment. Character-for-character replacement keeps every later index true.
    """
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                if src[j] == "\\":
                    j += 1
                j += 1
            for k in range(i, min(j + 1, n)):
                if out[k] != "\n":
                    out[k] = " "
            i = j + 1
        elif c == "/" and i + 1 < n and src[i + 1] == "/":
            j = src.find("\n", i)
            j = n if j == -1 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        else:
            i += 1
    return "".join(out)


def _split_fns(src, header):
    """Yield (name, body, line) for each function, body delimited by BRACE
    MATCHING from the signature's opening brace.

    An earlier version ran each body to the next function at the same indent.
    That silently swallowed everything between a ONE-LINE function and the next
    one -- `private func nowMs() -> Double { textEditNowMs() }` absorbed the
    whole struct below it and was reported as an element-dispatching function
    that returns a timestamp. Twelve of the first thirty-seven findings were
    that bug. A gate that cries wolf is one nobody reads, so the body is now
    delimited by the language rather than by a guess.
    """
    clean = _strip_noise(src)
    out = []
    for m in re.finditer(header, clean, re.M):
        name = m.group(2)
        open_at = clean.find("{", m.end())
        if open_at == -1:
            continue
        # A BODY-LESS declaration (a Rust trait method, a Swift protocol
        # requirement) ends at a semicolon or newline with no brace of its own,
        # and the next `{` belongs to something else entirely.
        #
        # The test is "which comes first, a brace or a semicolon" -- NOT "does
        # the signature span lines". An earlier guard skipped any signature
        # containing a newline before its brace, which silently dropped every
        # MULTI-LINE SIGNATURE in the tree: `fn build_element(` with its
        # parameters on following lines, and Swift's
        # `private func rebuildWithOpacityAndBlend(` likewise. Both are ordinary
        # functions and both vanished from the scan -- a false negative, which
        # for a gate is worse than the noise it was written to remove.
        semi = clean.find(";", m.end())
        if semi != -1 and semi < open_at:
            continue
        depth, i, n = 0, open_at, len(clean)
        while i < n:
            if clean[i] == "{":
                depth += 1
            elif clean[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        end = min(i + 1, n)
        out.append((name, src[m.start():end], src[:m.start()].count("\n") + 1))
    return out


RUST_HEADER = r"^(\s*)(?:pub(?:\([^)]*\))?\s+)?fn\s+(\w+)"
SWIFT_HEADER = r"^(\s*)(?:(?:public|private|internal|fileprivate|static|final|override)\s+)*func\s+(\w+)"


def _swift_dispatches_on_element(body):
    """True when a Swift `case .rect` switch is really about an ELEMENT.

    Swift case labels are bare (`case .rect`), so the leaf pattern also matches
    switches over OTHER enums that happen to share names -- `Tool` has `.rect`,
    `.ellipse`, `.line` and `.text` cases too, and `toolYamlId` was reported as
    element-dispatching for exactly that reason.

    Two accepted forms, and the second is why this is not simply "mentions
    Element": a method inside `extension Element` switches on `self` and can
    name the type NOWHERE in its own text. Requiring the token alone would drop
    every such method -- a false negative, which for a gate is worse than noise.
    """
    return "Element" in body or re.search(r"switch\s+self\b", body) is not None


def scan(sources):
    """sources: {relpath: text} -> sorted list of site dicts."""
    sites = []
    for rel, src in sorted(sources.items()):
        if rel.startswith("jas_dioxus/"):
            fns, leaf, cont = _split_fns(src, RUST_HEADER), LEAF_RUST, CONT_RUST
            lang = "rust"
        elif rel.startswith("JasSwift/"):
            fns, leaf, cont = _split_fns(src, SWIFT_HEADER), LEAF_SWIFT, CONT_SWIFT
            lang = "swift"
        else:
            continue
        for name, body, line in fns:
            if len(set(leaf.findall(body))) < MIN_LEAF_KINDS:
                continue
            if cont.search(body):
                continue
            if lang == "swift" and not _swift_dispatches_on_element(body):
                continue
            sites.append({"lang": lang, "file": rel, "line": line, "fn": name})
    return sites


def key(site):
    """Stable identity for a site: path + function, NEVER the line number.

    Keyed on `as_posix()` paths. A `str(Path)` here would yield backslashes on
    Windows and miss every row both ways at once -- the exact defect the
    jas/windows seat found in `check_swift_copy_sites.py`, which ran only on
    ubuntu and so could not fail where paths differ.
    """
    return f"{site['lang']}:{site['file']}::{site['fn']}"


def tracked_sources(repo_root):
    """Git-tracked Rust/Swift sources in the ACTIVE ports, tests excluded.

    `git ls-files` emits POSIX separators on every platform, so these keys are
    already separator-clean.
    """
    import subprocess
    try:
        out = subprocess.run(
            ["git", "ls-files", "jas_dioxus/src", "JasSwift/Sources"],
            cwd=repo_root, capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return {}
    sources = {}
    for rel in out.splitlines():
        if not rel.endswith((".rs", ".swift")):
            continue
        if "test" in pathlib.PurePosixPath(rel).name.lower():
            continue
        try:
            sources[rel] = (repo_root / rel).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
    return sources


def below_floor(n_files, n_sites):
    return n_files < MIN_FILES or n_sites < MIN_SITES


def load_ledger():
    if not LEDGER_PATH.exists():
        return None
    return json.loads(LEDGER_PATH.read_text(encoding="utf-8"))


# --------------------------------------------------------------------------
# self-test
# --------------------------------------------------------------------------

def self_test():
    """Prove the gate goes RED on each class it claims to cover.

    A gate is trusted for its RED. Every case is a way this check can be wrong,
    including the two shapes that produced real defects.
    """
    failures = []

    rect = "Element::Rect(e) => e.x,"
    circ = "Element::Circle(e) => e.cx,"
    elli = "Element::Ellipse(e) => e.cx,"
    corpus = {
        # (a) THE DEFECT SHAPE: three leaf kinds, catch-all, no container arm.
        #     `with_fill`'s exact form.
        "jas_dioxus/src/a.rs":
            f"pub fn paint(e: &Element) -> f64 {{ match e {{ {rect} {circ} {elli} _ => 0.0 }} }}\n",
        # (b) HANDLED: a container arm present, even one that does nothing, is a
        #     decision on the record and is NOT this gate's business.
        "jas_dioxus/src/b.rs":
            f"pub fn paint(e: &Element) -> f64 {{ match e {{ {rect} {circ} {elli} "
            f"Element::Group(_) => 0.0, _ => 0.0 }} }}\n",
        # (c) BELOW THE FLOOR: two leaf kinds is special-casing, not a dispatch
        #     table. Demanding a container arm here would be noise.
        "jas_dioxus/src/c.rs":
            f"pub fn paint(e: &Element) -> f64 {{ match e {{ {rect} {circ} _ => 0.0 }} }}\n",
        # (d) Swift's defect shape.
        "JasSwift/Sources/d.swift":
            "func paint(_ e: Element) -> Double { switch e {\n"
            "case .rect(let v): return v.x\ncase .circle(let v): return v.cx\n"
            "case .ellipse(let v): return v.cx\ndefault: return 0 } }\n",
        # (e) Swift, container handled.
        "JasSwift/Sources/e.swift":
            "func paint(_ e: Element) -> Double { switch e {\n"
            "case .rect(let v): return v.x\ncase .circle(let v): return v.cx\n"
            "case .ellipse(let v): return v.cx\ncase .group: return 0\ndefault: return 0 } }\n",
        # (f) THE EARLY-RETURN FORM. Defect #3 (`drawElementOverlay`) did not
        #     use a `case .group` ARM -- it wrote `if case .group = elem
        #     { return }`. A checker that only understood switch arms would
        #     have called this container-blind forever.
        "JasSwift/Sources/f.swift":
            "func paint(_ e: Element) -> Double {\n"
            "  if case .group = e { return 0 }\n"
            "  switch e {\ncase .rect(let v): return v.x\ncase .circle(let v): return v.cx\n"
            "case .ellipse(let v): return v.cx\ndefault: return 0 } }\n",
        # (g) TWO functions in one file, only the second blind -- attribution
        #     must not smear one function's container arm onto its neighbour.
        "jas_dioxus/src/g.rs":
            f"pub fn ok(e: &Element) -> f64 {{ match e {{ {rect} {circ} {elli} "
            f"Element::Layer(_) => 1.0, _ => 0.0 }} }}\n"
            f"pub fn blind(e: &Element) -> f64 {{ match e {{ {rect} {circ} {elli} _ => 0.0 }} }}\n",
        # (h) FROZEN + non-port paths are out of scope entirely.
        "jas/x.rs": f"pub fn paint(e: &Element) -> f64 {{ match e {{ {rect} {circ} {elli} _ => 0.0 }} }}\n",
        # (i) THE ONE-LINE FUNCTION. This is the bug that made twelve of the
        #     first thirty-seven findings false: a body delimited by "the next
        #     function at the same indent" made `nowMs` swallow the struct
        #     below it, so a function returning a timestamp was reported as
        #     element-dispatching. `nowMs` must stay SILENT while the genuinely
        #     blind function after it is still found.
        "JasSwift/Sources/i.swift":
            "private func nowMs() -> Double { textEditNowMs() }\n"
            "\n"
            "private struct Render {\n"
            "    let d: [PathCommand]\n"
            "}\n"
            "\n"
            "func paint(_ e: Element) -> Double { switch e {\n"
            "case .rect(let v): return v.x\ncase .circle(let v): return v.cx\n"
            "case .ellipse(let v): return v.cx\ndefault: return 0 } }\n",
        # (k) A MULTI-LINE SIGNATURE is an ordinary function. A guard that
        #     skipped any signature spanning lines dropped `fn build_element(`
        #     and Swift's `rebuildWithOpacityAndBlend(` from the scan entirely
        #     -- a FALSE NEGATIVE, which for a gate is worse than noise. The
        #     test is brace-before-semicolon, not newline-before-brace.
        "jas_dioxus/src/k.rs":
            "fn wide(\n    e: &Element,\n    other: usize,\n) -> f64 {\n"
            f"    match e {{ {rect} {circ} {elli} _ => 0.0 }}\n}}\n",
        # (l) A BODY-LESS declaration really does have no body: the brace that
        #     follows belongs to the next item, and attributing it here would
        #     smear that item's arms onto this name.
        "jas_dioxus/src/l.rs":
            "trait T {\n    fn decl(&self) -> f64;\n}\n"
            "fn after(e: &Element) -> f64 {\n"
            f"    match e {{ {rect} {circ} {elli} _ => 0.0 }}\n}}\n",
        # (m) A SWITCH OVER A DIFFERENT ENUM. Swift case labels are bare, and
        #     `Tool` has `.rect`, `.ellipse`, `.line` and `.text` cases of its
        #     own -- `toolYamlId` was reported as element-dispatching for that
        #     reason alone. Must be SILENT.
        "JasSwift/Sources/m.swift":
            "func toolYamlId(_ tool: Tool) -> String? { switch tool {\n"
            "case .rect: return \"rect\"\ncase .ellipse: return \"ellipse\"\n"
            "case .line: return \"line\"\ndefault: return nil } }\n",
        # (n) …but a method inside `extension Element` switches on `self` and
        #     may name the type NOWHERE in its own text. It must still be FOUND,
        #     or the discriminator above trades noise for a false negative.
        "JasSwift/Sources/n.swift":
            "extension Element {\n"
            "    func area() -> Double { switch self {\n"
            "    case .rect(let v): return v.width\ncase .circle(let v): return v.r\n"
            "    case .ellipse(let v): return v.rx\ndefault: return 0 } }\n}\n",
        # (j) A BRACE INSIDE A STRING must not end the body early, or the
        #     dispatch below it becomes invisible.
        "jas_dioxus/src/j.rs":
            "pub fn paint(e: &Element) -> f64 {\n"
            '    let _ = "a } brace in a string";\n'
            f"    match e {{ {rect} {circ} {elli} _ => 0.0 }}\n"
            "}\n",
    }
    found = {key(s) for s in scan(corpus)}
    expected = {
        "rust:jas_dioxus/src/a.rs::paint",
        "swift:JasSwift/Sources/d.swift::paint",
        "rust:jas_dioxus/src/g.rs::blind",
        "swift:JasSwift/Sources/i.swift::paint",
        "rust:jas_dioxus/src/j.rs::paint",
        "rust:jas_dioxus/src/k.rs::wide",
        "rust:jas_dioxus/src/l.rs::after",
        "swift:JasSwift/Sources/n.swift::area",
    }
    silent = {
        "rust:jas_dioxus/src/b.rs::paint",
        "rust:jas_dioxus/src/c.rs::paint",
        "swift:JasSwift/Sources/e.swift::paint",
        "swift:JasSwift/Sources/f.swift::paint",
        "rust:jas_dioxus/src/g.rs::ok",
        "rust:jas/x.rs::paint",
        "swift:JasSwift/Sources/i.swift::nowMs",
        "rust:jas_dioxus/src/l.rs::decl",
        "swift:JasSwift/Sources/m.swift::toolYamlId",
    }
    for k in expected - found:
        failures.append(f"  MISSED a container-blind site: {k}")
    for k in silent & found:
        failures.append(f"  FALSE POSITIVE, this site is fine: {k}")

    # The anti-vacuity floor is itself a class this gate must get right.
    for nf, ns, want_rejected in [
        (0, 0, True),                        # git failed / not a checkout
        (1, 100, True),                      # a truncated file scan
        (100, 1, True),                      # a scanner that stopped matching
        (MIN_FILES - 1, MIN_SITES, True),    # just under on files
        (MIN_FILES, MIN_SITES - 1, True),    # just under on sites
        (MIN_FILES, MIN_SITES, False),       # exactly at both lines
        (300, 25, False),                    # the real tree, 2026-07-29
    ]:
        if below_floor(nf, ns) != want_rejected:
            verb = "reject" if want_rejected else "accept"
            failures.append(f"  floor: {nf} files / {ns} sites should {verb}")

    # A ledger row must carry a verdict AND a reason. A bare name is not a
    # classification, and an unexplained `leaf_only` is how a defect stops
    # being looked for.
    for row, ok in [
        ({"verdict": "leaf_only", "reason": "containers handled in map_paintable"}, True),
        ({"verdict": "owed", "reason": "a scaled group leaves member strokes alone"}, True),
        ({"verdict": "unhandled", "reason": "no container answer",
          "unreached_because": "recognize_element returns None"}, True),
        # An `unhandled` row WITHOUT its gate named is the whole point of the
        # verdict lost -- it becomes leaf_only with extra words.
        ({"verdict": "unhandled", "reason": "no container answer"}, False),
        ({"verdict": "unhandled", "reason": "no container answer",
          "unreached_because": "   "}, False),
        ({"verdict": "leaf_only", "reason": ""}, False),
        ({"verdict": "leaf_only"}, False),
        ({"verdict": "maybe", "reason": "hmm"}, False),
        ({"reason": "no verdict"}, False),
    ]:
        if row_valid(row) != ok:
            failures.append(f"  ledger-row validity wrong for {row}")

    if failures:
        print("SELF-TEST FAILED -- the gate does not detect what it claims:")
        print("\n".join(failures))
        return 1
    print(f"self-test: {len(expected)} blind shapes detected (match-arm, switch-arm, "
          f"and the early-return form defect #3 used), {len(silent)} handled/out-of-scope "
          f"shapes silent, per-function attribution holds, ledger-row validity holds, "
          f"anti-vacuity floor holds at {MIN_FILES} files / {MIN_SITES} sites "
          f"-- gate proven RED where it must be.")
    return 0


def row_valid(row):
    if not isinstance(row, dict):
        return False
    if row.get("verdict") not in VALID_VERDICTS:
        return False
    if not isinstance(row.get("reason"), str) or not row["reason"].strip():
        return False
    # An `unhandled` row is only useful if it names what keeps containers away.
    # Without that the next reader cannot tell whether the gate still holds, and
    # the row degrades into "leaf_only with extra words".
    if row["verdict"] == "unhandled":
        why = row.get("unreached_because")
        if not isinstance(why, str) or not why.strip():
            return False
    return True


def main():
    if "--self-test" in sys.argv:
        return self_test()

    sources = tracked_sources(REPO)
    sites = scan(sources)

    if below_floor(len(sources), len(sites)):
        print(f"ERROR: scanned {len(sources)} tracked source file(s) and found "
              f"{len(sites)} dispatch site(s), below the anti-vacuity floor of "
              f"{MIN_FILES}/{MIN_SITES}.", file=sys.stderr)
        print(file=sys.stderr)
        print("This is not a pass. A scan that finds nothing reports no", file=sys.stderr)
        print("unclassified sites, which is indistinguishable from a clean tree.", file=sys.stderr)
        print("Likely causes: run from outside the repo; git unavailable; the", file=sys.stderr)
        print("source layout moved; or the scanner stopped matching.", file=sys.stderr)
        return 1

    ledger = load_ledger()
    if ledger is None:
        print(f"ERROR: no ledger at {LEDGER_PATH.relative_to(REPO).as_posix()}.", file=sys.stderr)
        return 1

    rows = ledger.get("sites", {})
    bad_rows = sorted(k for k, r in rows.items() if not row_valid(r))
    live = {key(s): s for s in sites}
    unclassified = sorted(set(live) - set(rows))
    stale = sorted(set(rows) - set(live))

    if not (unclassified or stale or bad_rows):
        counts = {v: sum(1 for r in rows.values() if r["verdict"] == v)
                  for v in sorted(VALID_VERDICTS)}
        # HEADLINE-SUM INVARIANT: the per-verdict counts must account for every
        # row. A verdict added to VALID_VERDICTS but forgotten here would report
        # a headline that silently omits a whole category -- which is how the
        # first run of this gate reported "14 leaf-only, 3 owed" over 22 rows
        # and said nothing about the five `unhandled` ones.
        if sum(counts.values()) != len(rows):
            print(f"ERROR: verdict counts {counts} sum to {sum(counts.values())} "
                  f"but the ledger holds {len(rows)} rows -- a verdict is not "
                  f"being counted.", file=sys.stderr)
            return 1
        summary = ", ".join(f"{n} {v.replace('_', '-')}" for v, n in counts.items() if n)
        print(f"element dispatch: {len(sites)} container-blind site(s) across "
              f"{len(sources)} source file(s), all classified -- {summary}.")
        return 0

    print("ERROR: the element-dispatch ledger does not match the tree.", file=sys.stderr)
    print(file=sys.stderr)
    if unclassified:
        print(f"{len(unclassified)} UNCLASSIFIED site(s) -- a function that dispatches on",
              file=sys.stderr)
        print("element kind with no container arm, and no row saying whether that", file=sys.stderr)
        print("is correct:", file=sys.stderr)
        for k in unclassified:
            print(f"  {k}  (line {live[k]['line']})", file=sys.stderr)
        print(file=sys.stderr)
        print('Add a row: "leaf_only" WITH a reason saying where the container', file=sys.stderr)
        print('case is handled instead, or "owed" saying what the artist sees go', file=sys.stderr)
        print("wrong. Do not guess -- five real defects wore this shape.", file=sys.stderr)
    if stale:
        print(f"\n{len(stale)} STALE row(s) -- classified, but the site is gone",
              file=sys.stderr)
        print("(repaired, renamed, or it gained a container arm). Strike the row,", file=sys.stderr)
        print("or the ledger becomes fiction:", file=sys.stderr)
        for k in stale:
            print(f"  {k}", file=sys.stderr)
    if bad_rows:
        print(f"\n{len(bad_rows)} MALFORMED row(s) -- every row needs a verdict of",
              file=sys.stderr)
        print(f"{sorted(VALID_VERDICTS)} and a non-empty reason:", file=sys.stderr)
        for k in bad_rows:
            print(f"  {k}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
