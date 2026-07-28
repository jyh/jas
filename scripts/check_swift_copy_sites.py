#!/usr/bin/env python3
"""Gate: the SWIFT COPY-SITE OMISSION CLASS.

Swift rebuilds structs field by field where Rust writes `..clone()` /
`children_mut()`. Every field a hand-written argument list forgets is silently
reset to its default -- no warning, no error, and whole-struct equality or a
`Mirror` walk cannot see it, because both sides get built through the same
truncated initializer.

The class has bitten this project repeatedly:

  * paste rebuilt the target Layer with 4 of 11 fields (LAYER_STRUCTURE.md 9.5)
  * Ungroup All rebuilt Group (4/11), Layer (5/11) and Document (3/8), so it
    DELETED every artboard and reset the Print dialog
  * the layers panel's `doc.set` rebuilt Layer with 6 of 11, so every lock
    toggle destroyed the layer's `id`
  * session restore rebuilt Document with 7 of 8, dropping every Symbol master
  * the SVG reader promoted a top-level <g> to a Layer with 5 of 11, a live
    divergence from Rust, which clones `common` wholesale

WHAT THIS GATE FLAGS. A REBUILD is a construction `T(...)` whose argument list
READS FIELDS OFF AN EXISTING VALUE (`g.opacity`, `layer.transform`,
`doc.symbols`) -- i.e. it is copying a value rather than making a fresh one.
When such a construction names FEWER labels than `T` has stored properties, it
is reported.

WHY IT CANNOT GO STALE. The stored-property lists are read out of the Swift
sources at run time, not hardcoded here. Add a twelfth field to `Layer` and
every 11-label construction of a Layer turns this gate RED on the next run
(measured) -- including the deliberate full-field Group->Layer conversion in
`Svg.swift`, which is written to read `g.<field>` so that it gets counted.
Note the asymmetry: a construction is counted against the type being
CONSTRUCTED, so a twelfth field on `Group` alone does NOT red that conversion.

HOW TO FIX A HIT. Do NOT add the missing arguments -- that is the repair that
has failed twice, because the next new field lands right back in the same
place. Clone-then-mutate instead: `Group.withChildren`, `Layer.withChildren` /
`withName` / `withLocked` / `withVisibility`, `Document.replacing(...)`, or a
plain `var v = x; v.field = ...`. Then there is no field list to fall behind.

BLIND SPOTS, stated plainly:
  * It is a REGEX scan, not a Swift parser. A rebuild that launders the source
    value through a local (`let o = g.opacity` on a previous line, then
    `opacity: o`) reads as a fresh construction and is NOT flagged.
  * It only knows the three container types below. The same class can land on
    any of the ~10 element structs; those are not scanned.
  * It cannot see a CROSS-TYPE conversion that is complete-by-count but wrong
    by meaning.
  * A construction that names every field is accepted even though it is still
    a list someone has to maintain -- the gate makes the list VISIBLE and
    counted, it does not remove it.

Usage:
    python3 scripts/check_swift_copy_sites.py            # scan JasSwift/Sources
    python3 scripts/check_swift_copy_sites.py --self-test
"""
from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SOURCES = REPO / "JasSwift" / "Sources"

# type name -> file that declares it
DECLS = {
    "Group": SOURCES / "Geometry" / "Element.swift",
    "Layer": SOURCES / "Geometry" / "Element.swift",
    "Document": SOURCES / "Document" / "Document.swift",
}

# `public let x: T`, `public internal(set) var x: T`, `public private(set) var x: T`,
# and the same with an inline default (`var x: Bool = false`). The `{` exclusion
# is what separates a STORED property from a computed one. The defaulted form
# was missed by an earlier version of this pattern, which made the gate silently
# under-count a struct's fields — pinned by the self-test.
FIELD_RE = re.compile(
    r"^\s*(?:public\s+)?(?:(?:internal|private|fileprivate)\(set\)\s+)?"
    r"(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*[^={]+(?:=[^{]+)?$"
)


def _strip_comments(src: str) -> str:
    """Blank out // line comments and /* */ blocks, preserving line count.

    Load-bearing: `Document`'s field block carries a doc comment that MENTIONS
    `init(rawLayers:...)`, and an un-stripped search for the first `init(`
    stopped the field walk four properties early — the gate then read Document
    as a 4-field struct and could not see a 7-of-8 rebuild at all.
    """
    src = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)),
                 src, flags=re.S)
    return re.sub(r"//[^\n]*", "", src)


def stored_properties(src: str, type_name: str) -> list[str]:
    """Stored properties of `struct type_name`, in declaration order.

    Reads from the opening brace to the first initializer DECLARATION:
    everything after that is initializers, computed properties and methods.
    """
    src = _strip_comments(src)
    m = re.search(r"struct\s+" + type_name + r"\b[^{]*\{", src)
    if not m:
        raise SystemExit(f"check_swift_copy_sites: cannot find struct {type_name}")
    body = src[m.end():]
    dm = re.search(r"^\s*(?:public\s+|internal\s+|private\s+)?init\s*\(",
                   body, flags=re.M)
    if dm:
        body = body[:dm.start()]
    out: list[str] = []
    for line in body.splitlines():
        fm = FIELD_RE.match(line)
        if fm:
            out.append(fm.group(1))
    return out


def init_labels(src: str, type_name: str) -> list[str]:
    """Parameter labels of `type_name`'s FIRST initializer declaration.

    An independent second opinion on ``stored_properties``: the memberwise init
    must be able to set every stored property, so the two lists must agree. If
    the field walk silently truncates again, this disagrees and the self-test
    reds.
    """
    src = _strip_comments(src)
    m = re.search(r"struct\s+" + type_name + r"\b[^{]*\{", src)
    if not m:
        raise SystemExit(f"check_swift_copy_sites: cannot find struct {type_name}")
    body = src[m.end():]
    dm = re.search(r"^\s*(?:public\s+|internal\s+|private\s+)?init\s*\(",
                   body, flags=re.M)
    if not dm:
        raise SystemExit(f"check_swift_copy_sites: {type_name} has no init")
    args, _ = balanced(body, dm.end() - 1)
    return [lm.group(1) for p in split_top(args or "")
            if (lm := re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*:", p))]


def balanced(src: str, open_idx: int):
    """(argument-list text, index of the closing paren) for parens at open_idx."""
    depth = 0
    i = open_idx
    in_str = False
    while i < len(src):
        c = src[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return src[open_idx + 1:i], i
        i += 1
    return None, None


def split_top(args: str) -> list[str]:
    """Split an argument list on TOP-LEVEL commas."""
    out: list[str] = []
    depth = 0
    cur = ""
    in_str = False
    for i, c in enumerate(args):
        if in_str:
            cur += c
            if c == '"' and args[i - 1] != "\\":
                in_str = False
            continue
        if c == '"':
            in_str = True
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if c == "," and depth == 0:
            out.append(cur)
            cur = ""
            continue
        cur += c
    if cur.strip():
        out.append(cur)
    return out


def scan_text(path: str, src: str, fields_by_type: dict[str, list[str]]) -> list[dict]:
    findings: list[dict] = []
    for tname, fields in fields_by_type.items():
        for m in re.finditer(r"(?<![A-Za-z0-9_.])" + tname + r"\(", src):
            args, _ = balanced(src, m.end() - 1)
            if args is None:
                continue
            parts = split_top(args)
            labels = []
            for p in parts:
                # strip // line comments so a documented argument still shows
                # its label to the scan
                p = re.sub(r"//[^\n]*", "", p)
                lm = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*:", p)
                if lm:
                    labels.append(lm.group(1))
            # REBUILD test: does any argument read a field of this same type
            # off some base value?
            reads = set()
            for p in parts:
                for bm in re.finditer(
                    r"([A-Za-z_][A-Za-z0-9_.\[\]]*)\.([A-Za-z_][A-Za-z0-9_]*)", p
                ):
                    if bm.group(2) in fields:
                        reads.add(bm.group(0))
            if not reads:
                continue
            missing = [f for f in fields if f not in labels]
            if not missing:
                continue
            findings.append({
                "file": path,
                "line": src[:m.start()].count("\n") + 1,
                "type": tname,
                "named": len(labels),
                "total": len(fields),
                "missing": missing,
                "reads": sorted(reads)[:3],
            })
    return findings


def load_fields() -> dict[str, list[str]]:
    return {
        t: stored_properties(p.read_text(), t) for t, p in DECLS.items()
    }


def run() -> int:
    fields_by_type = load_fields()
    for t, fs in fields_by_type.items():
        print(f"  {t}: {len(fs)} stored properties")
    findings: list[dict] = []
    for path in sorted(SOURCES.rglob("*.swift")):
        rel = str(path.relative_to(REPO))
        findings += scan_text(rel, path.read_text(), fields_by_type)
    if not findings:
        print("check_swift_copy_sites: OK — no truncated rebuilds")
        return 0
    print("\ncheck_swift_copy_sites: FAIL — truncated rebuild(s):\n")
    for f in findings:
        print(f"  {f['file']}:{f['line']}  {f['type']}  "
              f"names {f['named']}/{f['total']}  "
              f"missing={','.join(f['missing'])}  reads={f['reads']}")
    print("\nFix by clone-then-mutate (withChildren / withName / withLocked /")
    print("withVisibility / Document.replacing / `var v = x; v.f = ...`), NOT by")
    print("adding the missing arguments — see this file's header.")
    return 1


SELF_TEST_DECL = """
public struct Widget: Equatable {
    public internal(set) var children: [Element]
    public internal(set) var name: String?
    // a comment that is not a field
    public internal(set) var locked: Bool
    // a stored property with an INLINE DEFAULT — an earlier pattern missed
    // this shape and under-counted the struct
    public internal(set) var flagged: Bool = false
    public init(children: [Element], name: String? = nil, locked: Bool = false,
                flagged: Bool = false) {
        self.children = children
    }
    public var bounds: BBox { (0, 0, 0, 0) }
}
"""

SELF_TEST_BAD = """
func f(_ w: Widget) -> Widget {
    return Widget(children: w.children, name: w.name)
}
"""

SELF_TEST_FULL = """
func f(_ w: Widget) -> Widget {
    return Widget(children: w.children, name: w.name, locked: w.locked,
                  flagged: w.flagged)
}
"""

SELF_TEST_FRESH = """
func f() -> Widget {
    return Widget(children: [])
}
"""

SELF_TEST_LAUNDERED = """
func f(_ w: Widget) -> Widget {
    let n = w.name
    return Widget(children: [], name: n)
}
"""


def self_test() -> int:
    fails = []

    fields = stored_properties(SELF_TEST_DECL, "Widget")
    if fields != ["children", "name", "locked", "flagged"]:
        fails.append(f"field parse: expected 4 stored properties, got {fields}")

    fb = {"Widget": fields}

    bad = scan_text("t.swift", SELF_TEST_BAD, fb)
    if len(bad) != 1 or bad[0]["missing"] != ["locked", "flagged"]:
        fails.append(f"truncated rebuild not caught: {bad}")

    full = scan_text("t.swift", SELF_TEST_FULL, fb)
    if full:
        fails.append(f"complete rebuild wrongly flagged: {full}")

    fresh = scan_test = scan_text("t.swift", SELF_TEST_FRESH, fb)
    if fresh:
        fails.append(f"fresh construction wrongly flagged: {fresh}")

    # documented blind spot: laundering through a local hides the rebuild.
    # Pinned so the limitation is a measured fact, not a hope.
    laundered = scan_text("t.swift", SELF_TEST_LAUNDERED, fb)
    if laundered:
        fails.append(
            "blind-spot pin changed: a laundered rebuild is now detected — "
            "good news, but update the header's blind-spot list"
        )

    # the real sources must parse
    try:
        real = load_fields()
    except SystemExit as e:
        fails.append(str(e))
        real = {}
    # Independent second opinion: the memberwise init must be able to set every
    # stored property, so the two lists must agree as SETS. Catches a silently
    # truncated field walk (which is exactly how this gate first shipped blind
    # to Document, reading 4 of its 8 fields).
    for t, p in DECLS.items():
        src = p.read_text()
        got = set(real.get(t, []))
        want = set(init_labels(src, t))
        if got != want:
            fails.append(
                f"{t}: stored properties {sorted(got)} disagree with init "
                f"labels {sorted(want)} — the field walk is truncating"
            )

    if fails:
        for f in fails:
            print(f"SELF-TEST FAIL: {f}")
        return 1
    print("check_swift_copy_sites --self-test: OK")
    for t, fs in real.items():
        print(f"  parsed {t}: {len(fs)} stored properties")
    return 0


if __name__ == "__main__":
    sys.exit(self_test() if "--self-test" in sys.argv else run())
