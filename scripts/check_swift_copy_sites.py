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

WHICH TYPES IT WATCHES, and why that is not a list. Until 2026-07-28 this was a
hand-written dict of three container types (Group / Layer / Document), and the
class promptly landed somewhere else: `Controller.applyTextAttrs` /
`applyTextPathAttrs` rebuilt `Text` (27 of 31 stored properties) and `TextPath`
(26 of 30), losing `name`, `id`, `blendMode` and `mask` on every Character-panel
apply — an `id` loss, i.e. a direct violation of the ratified Preservation Law.
The gate could not see it, because Text and TextPath were not in the dict. A
gate against hand-maintained field lists that was itself a hand-maintained TYPE
list is the same defect one level up. So the watch list is now DERIVED: every
payload type of the `Element` enum (whatever those are today) plus `Document`.
Add a thirteenth element case and it is watched the moment it is declared.

BLIND SPOTS, stated plainly:
  * It is a REGEX scan, not a Swift parser. A rebuild that launders the source
    value through a local (`let o = g.opacity` on a previous line, then
    `opacity: o`) reads as a fresh construction and is NOT flagged.
  * The derived list covers the Element payload types and `Document`. Value
    types BELOW an element — `Tspan`, `Fill`, `Stroke`, `Mask`, `Gradient`,
    `StrokeWidthPoint` — are still unwatched, as are the panel/app-state
    structs. Those are a wider net than this gate has been measured against.
  * A payload type that is an ENUM rather than a struct (`LiveVariant`) has no
    stored-property list to count against and is skipped.
  * It cannot see a CROSS-TYPE conversion that is complete-by-count but wrong
    by meaning.
  * A construction that names every field is accepted even though it is still
    a list someone has to maintain -- the gate makes the list VISIBLE and
    counted, it does not remove it.

THE BASELINE, and why this gate is a ratchet rather than a wall. Deriving the
watch list turned 1 finding into 28: the class is not two sites, it is
twenty-eight construction sites across seven files, and several of them are
cross-TYPE conversions (`ShapeRecognize.swift` rebuilds a Polyline as a Rect)
whose correct preservation behaviour is a ruling, not a refactor. Fixing all of
them in one lane would be a large blind edit; tolerating them silently would
make the widening worthless. So the 25 that remain are ENUMERATED in
`scripts/swift_copy_sites_baseline.json`, keyed by file and constructed type,
carrying the exact set of fields each site drops. Any NEW site, any additional
site at a known key, and any newly-dropped field at a known key is a failure.
Repairing a site is also a failure until the baseline is lowered, so the ledger
can only shrink and shrinking it is a visible edit.

Usage:
    python3 scripts/check_swift_copy_sites.py            # scan JasSwift/Sources
    python3 scripts/check_swift_copy_sites.py --self-test
    python3 scripts/check_swift_copy_sites.py --write-baseline
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SOURCES = REPO / "JasSwift" / "Sources"
BASELINE = REPO / "scripts" / "swift_copy_sites_baseline.json"

# The files a watched type may be declared in. The LIST OF TYPES is derived
# (see `discover_types`), not written here; these are only the two files the
# derivation reads.
ELEMENT_SWIFT = SOURCES / "Geometry" / "Element.swift"
DOCUMENT_SWIFT = SOURCES / "Document" / "Document.swift"
DECL_FILES = [ELEMENT_SWIFT, DOCUMENT_SWIFT]

# Types that are NOT an `Element` payload but carry the same class. `Document`
# has already been rebuilt 7-of-8 (session restore, dropping every Symbol
# master) and 3-of-8 (Ungroup All, deleting every artboard).
ROOT_TYPES = ["Document"]

# NAME COLLISIONS. Widening the watch list to the element types puts `Text`,
# `Path`, `Rect` and `Circle` on it — names SwiftUI also uses, so `Text(m.name)`
# in a view body would otherwise read as a one-field rebuild of our `Text`
# (`name` is one of its stored properties). The filter is by CALL SHAPE, not a
# per-type carve-out: every watched type's memberwise initializer LABELS every
# parameter (`init_labels` proves that per type in the self-test), so a
# construction whose first argument carries no label is not one of them.

# The HEAD of a property declaration: `public let …`, `public internal(set) var …`,
# `public private(set) var …`. Everything after it is the declarator list, which
# `_declarators` splits — because Swift allows SEVERAL properties on one line
# (`public internal(set) var x: Double, y: Double`, which `Text`, `Line`, `Rect`,
# `Circle` and `Ellipse` all use). An earlier pattern captured only the FIRST
# name on such a line, so widening the watch list to the element types made the
# gate under-count `Text` by one, `Rect` by four and `Line` by three. Pinned by
# the self-test's init-label cross-check, which is what caught it.
DECL_HEAD_RE = re.compile(
    r"^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+)?"
    r"(?:(?:internal|private|fileprivate)\(set\)\s+)?"
    r"(?:let|var)\s+(.*)$"
)


def _declarators(rest: str) -> list[str]:
    """Property names in one declaration's declarator list.

    `x: Double, y: Double` -> [x, y]; `flagged: Bool = false` -> [flagged]. A
    `{` anywhere means a computed property or an observer, which is not stored.
    """
    if "{" in rest:
        return []
    out: list[str] = []
    for part in split_top(rest):
        pm = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*:", part)
        if pm:
            out.append(pm.group(1))
    return out


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


def element_payload_types(src: str) -> list[str]:
    """Payload type of every `case foo(Type)` in `public enum Element`.

    This is what replaces the old hand-written three-entry dict. `Element`'s
    case list is the project's own statement of what an element can be, so the
    watch list cannot fall behind it: declare a thirteenth case and the type it
    carries is scanned on the next run.
    """
    src = _strip_comments(src)
    m = re.search(r"public\s+enum\s+Element\s*:[^{]*\{", src)
    if not m:
        raise SystemExit("check_swift_copy_sites: cannot find `public enum Element`")
    body, _ = balanced_braces(src, m.end() - 1)
    out: list[str] = []
    for cm in re.finditer(r"^\s*case\s+[A-Za-z_][A-Za-z0-9_]*\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)",
                          body, flags=re.M):
        if cm.group(1) not in out:
            out.append(cm.group(1))
    if not out:
        raise SystemExit("check_swift_copy_sites: `enum Element` yielded no payload types")
    return out


def declaring_file(type_name: str) -> pathlib.Path | None:
    """The DECL_FILES entry that declares `struct type_name`, if any.

    Returns None for a payload type that is not a struct — `LiveVariant` is an
    enum, so it has no stored-property list to count a rebuild against. Stated
    rather than silently skipped: the caller reports what it dropped.
    """
    for p in DECL_FILES:
        if re.search(r"struct\s+" + type_name + r"\b[^{]*\{",
                     _strip_comments(p.read_text(encoding="utf-8"))):
            return p
    return None


def balanced_braces(src: str, open_idx: int):
    """(body text, index of the closing brace) for the braces at open_idx."""
    depth = 0
    i = open_idx
    while i < len(src):
        c = src[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return src[open_idx + 1:i], i
        i += 1
    return src[open_idx + 1:], None


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
        hm = DECL_HEAD_RE.match(line)
        if hm:
            out.extend(_declarators(hm.group(1)))
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
            # NAME COLLISION FILTER (see the header): every watched type labels
            # every initializer parameter, so an unlabeled first argument means
            # this is somebody else's `Text(...)` / `Path(...)`.
            if parts and not re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*:", parts[0]):
                continue
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


def discover_types() -> tuple[dict[str, pathlib.Path], list[str]]:
    """(watched type -> declaring file, skipped non-struct payload types)."""
    names = element_payload_types(ELEMENT_SWIFT.read_text(encoding="utf-8"))
    for t in ROOT_TYPES:
        if t not in names:
            names.append(t)
    decls: dict[str, pathlib.Path] = {}
    skipped: list[str] = []
    for t in names:
        p = declaring_file(t)
        if p is None:
            skipped.append(t)
        else:
            decls[t] = p
    return decls, skipped


def load_fields(decls: dict[str, pathlib.Path]) -> dict[str, list[str]]:
    return {
        t: stored_properties(p.read_text(encoding="utf-8"), t)
        for t, p in decls.items()
    }


def scan_all(fields_by_type: dict[str, list[str]]) -> list[dict]:
    findings: list[dict] = []
    for path in sorted(SOURCES.rglob("*.swift")):
        # as_posix(), not str(): str(Path) yields "\" separators on Windows, and
        # swift_copy_sites_baseline.json is keyed with POSIX paths. On Windows
        # every key therefore missed BOTH ways at once — each real site reported
        # as a NEW backslash-keyed row AND its forward-slash baseline row
        # reported as "repaired; remove the row" — so the gate failed wholesale
        # on a clean tree. It is wired into the ubuntu job (test.yml), which is
        # why CI stayed green: the only platform that exposes this never ran it.
        # Same defect and same fix as genericity_check.py's exclude matching.
        rel = path.relative_to(REPO).as_posix()
        findings += scan_text(rel, path.read_text(encoding="utf-8"), fields_by_type)
    return findings


def ledger(findings: list[dict]) -> dict[str, dict]:
    """Findings collapsed to `file::Type` -> {sites, missing}.

    LINE NUMBERS ARE DELIBERATELY NOT IN THE KEY. A ledger keyed by line would
    churn on every unrelated edit above a known site, and a churning baseline
    gets regenerated reflexively — which is how a ratchet stops ratcheting.
    """
    out: dict[str, dict] = {}
    for f in findings:
        key = f"{f['file']}::{f['type']}"
        row = out.setdefault(key, {"sites": 0, "missing": set()})
        row["sites"] += 1
        row["missing"] |= set(f["missing"])
    return {k: {"sites": v["sites"], "missing": sorted(v["missing"])}
            for k, v in sorted(out.items())}


BASELINE_DOC = [
    "THE COPY-SITE DEBT LEDGER. Every truncated rebuild that existed when",
    "scripts/check_swift_copy_sites.py widened its watch list from three",
    "hand-written container types to the DERIVED element-type list, keyed by",
    "file and constructed type and carrying the exact fields each site drops.",
    "",
    "This is a ratchet, not a permission slip. A new key, an extra site at a",
    "known key, or a newly-dropped field at a known key FAILS the gate; so does",
    "repairing a site without lowering the ledger, so the file can only shrink",
    "and shrinking it is a visible edit.",
    "",
    "The rows are NOT all the same defect, and three kinds are mixed here:",
    "",
    "  * ALREADY BANKED, deliberately. Normalize.swift's ten arms carry an",
    "    in-source note saying so: the fields they omit (blendMode, mask, the",
    "    gradients, the stroke brush) appear in zero expected golden, which is",
    "    the corpus manifest's `codec-optional-fields-unset` gap, so forwarding",
    "    them would be an unpinned change. That is a ruling waiting to happen,",
    "    not an oversight.",
    "  * A RULING, not a refactor. ShapeRecognize.swift rebuilds a Polyline as a",
    "    Rect -- a cross-TYPE conversion. Whether recognising a drawn shape",
    "    preserves the element's identity or mints a new one is an",
    "    EDIT_SEMANTICS_FREEZE.md question no one has answered.",
    "  * PLAIN DEBT. The rest are same-type copies that simply forget fields.",
]


def baseline_problems(current: dict[str, dict], known: dict[str, dict]) -> list[str]:
    problems: list[str] = []
    for key, row in current.items():
        base = known.get(key)
        if base is None:
            problems.append(
                f"NEW truncated-rebuild site: {key} "
                f"({row['sites']} site(s), drops {','.join(row['missing'])})")
            continue
        if row["sites"] > base["sites"]:
            problems.append(
                f"{key}: {row['sites']} sites, baseline says {base['sites']} "
                f"— a truncated rebuild was ADDED")
        elif row["sites"] < base["sites"]:
            problems.append(
                f"{key}: {row['sites']} sites, baseline says {base['sites']} "
                f"— a site was repaired; lower the baseline")
        grew = sorted(set(row["missing"]) - set(base["missing"]))
        if grew:
            problems.append(
                f"{key}: now also drops {','.join(grew)} — a field was added to "
                f"the type (or removed from the argument list) and this site "
                f"fell further behind")
        shrank = sorted(set(base["missing"]) - set(row["missing"]))
        if shrank:
            problems.append(
                f"{key}: no longer drops {','.join(shrank)} — narrow the "
                f"baseline")
    for key, base in known.items():
        if key not in current:
            problems.append(
                f"{key}: baseline expects {base['sites']} site(s), found none "
                f"— the site was repaired; remove the row")
    return problems


def check_baseline(findings: list[dict]) -> int:
    current = ledger(findings)
    if not BASELINE.exists():
        print(f"check_swift_copy_sites: no baseline at {BASELINE}")
        return 1
    known = json.loads(BASELINE.read_text(encoding="utf-8"))["sites"]
    problems = baseline_problems(current, known)
    if problems:
        print("\ncheck_swift_copy_sites: FAIL\n")
        for p in problems:
            print(f"  {p}")
        print("\nFix by clone-then-mutate (withChildren / withName / withLocked /")
        print("withVisibility / Document.replacing / `var v = x; v.f = ...`), NOT by")
        print("adding the missing arguments — see this file's header. Then run")
        print("--write-baseline and commit the shrunken ledger.")
        return 1
    print(f"check_swift_copy_sites: OK — {len(findings)} known site(s) in "
          f"{len(current)} ledger row(s), no new or worsened rebuild")
    return 0


def run(write_baseline: bool = False) -> int:
    decls, skipped = discover_types()
    fields_by_type = load_fields(decls)
    print(f"  watching {len(fields_by_type)} derived type(s):")
    for t, fs in fields_by_type.items():
        print(f"    {t}: {len(fs)} stored properties")
    if skipped:
        print(f"  not a struct, so not counted: {', '.join(skipped)}")
    findings = scan_all(fields_by_type)
    for f in findings:
        print(f"  {f['file']}:{f['line']}  {f['type']}  "
              f"names {f['named']}/{f['total']}  "
              f"missing={','.join(f['missing'])}  reads={f['reads']}")
    if write_baseline:
        BASELINE.write_text(
            json.dumps({"_doc": BASELINE_DOC, "sites": ledger(findings)},
                       indent=2) + "\n",
            encoding="utf-8", newline="")
        print(f"\nwrote {BASELINE} ({len(findings)} site(s))")
        return 0
    return check_baseline(findings)


SELF_TEST_DECL = """
public struct Widget: Equatable {
    public internal(set) var children: [Element]
    public internal(set) var name: String?
    // a comment that is not a field
    public internal(set) var locked: Bool
    // a stored property with an INLINE DEFAULT — an earlier pattern missed
    // this shape and under-counted the struct
    public internal(set) var flagged: Bool = false
    // TWO properties on ONE line — the shape every element struct uses for its
    // coordinates, and the one that made the field walk under-count Rect by four
    public internal(set) var x: Double, y: Double
    public init(children: [Element], name: String? = nil, locked: Bool = false,
                flagged: Bool = false, x: Double = 0, y: Double = 0) {
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
                  flagged: w.flagged, x: w.x, y: w.y)
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

# SwiftUI's `Text(m.name)` reads a field name that our `Text` also declares.
# The unlabeled first argument is what tells the two apart.
SELF_TEST_FOREIGN = """
var body: some View {
    Widget(w.name)
}
"""

SELF_TEST_ENUM = """
public enum Element: Equatable {
    /// SVG \\<rect\\>
    case rect(Rect)
    case text(Text)
    case live(LiveVariant)
    public var bounds: BBox {
        switch self {
        case .rect(let v): return v.bounds
        }
    }
}
"""


def self_test() -> int:
    fails = []

    fields = stored_properties(SELF_TEST_DECL, "Widget")
    if fields != ["children", "name", "locked", "flagged", "x", "y"]:
        fails.append(f"field parse: expected 6 stored properties, got {fields}")

    fb = {"Widget": fields}

    bad = scan_text("t.swift", SELF_TEST_BAD, fb)
    if len(bad) != 1 or bad[0]["missing"] != ["locked", "flagged", "x", "y"]:
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

    foreign = scan_text("t.swift", SELF_TEST_FOREIGN, fb)
    if foreign:
        fails.append(
            f"a foreign construction with an unlabeled first argument was "
            f"flagged as a rebuild: {foreign}"
        )

    payloads = element_payload_types(SELF_TEST_ENUM)
    if payloads != ["Rect", "Text", "LiveVariant"]:
        fails.append(f"enum payload parse: got {payloads}")

    # THE RATCHET. Each of the four ways the ledger can be wrong must be a
    # failure — including a REPAIRED site, which must lower the ledger rather
    # than pass silently, or the file would drift into a stale permission slip.
    base = {"f.swift::Layer": {"sites": 2, "missing": ["id", "mask"]}}
    ratchet_cases = [
        ({"f.swift::Layer": {"sites": 2, "missing": ["id", "mask"]}}, 0, "unchanged"),
        ({"f.swift::Layer": {"sites": 3, "missing": ["id", "mask"]}}, 1, "site added"),
        ({"f.swift::Layer": {"sites": 1, "missing": ["id", "mask"]}}, 1, "site repaired"),
        ({"f.swift::Layer": {"sites": 2, "missing": ["id", "mask", "name"]}}, 1,
         "another field dropped"),
        ({}, 1, "whole row repaired"),
        ({"f.swift::Layer": {"sites": 2, "missing": ["id", "mask"]},
          "g.swift::Group": {"sites": 1, "missing": ["id"]}}, 1, "new key"),
    ]
    for current, want, label in ratchet_cases:
        got = len(baseline_problems(current, base))
        if (got > 0) != (want > 0):
            fails.append(f"ratchet '{label}': {got} problem(s), wanted {want and 'some' or 'none'}")

    if ledger([{"file": "a.swift", "type": "Text", "missing": ["id"]},
               {"file": "a.swift", "type": "Text", "missing": ["mask"]}]) != {
            "a.swift::Text": {"sites": 2, "missing": ["id", "mask"]}}:
        fails.append("ledger did not collapse two sites at one key into a union")

    # the real sources must parse, and the DERIVED list must actually contain
    # the types the class has already landed on
    try:
        decls, skipped = discover_types()
        real = load_fields(decls)
    except SystemExit as e:
        fails.append(str(e))
        decls, skipped, real = {}, [], {}
    for must in ("Group", "Layer", "Document", "Text", "TextPath"):
        if must not in real:
            fails.append(
                f"the derived watch list omits {must} — every one of these has "
                f"already carried a truncated rebuild in this repo"
            )
    if len(real) < 12:
        fails.append(f"derived watch list has only {len(real)} types; expected >= 12")

    # Independent second opinion: the memberwise init must be able to set every
    # stored property, so the two lists must agree as SETS. Catches a silently
    # truncated field walk (which is exactly how this gate first shipped blind
    # to Document, reading 4 of its 8 fields).
    for t, p in decls.items():
        src = p.read_text(encoding="utf-8")
        got = set(real.get(t, []))
        want = set(init_labels(src, t))
        if got != want:
            fails.append(
                f"{t}: stored properties {sorted(got)} disagree with init "
                f"labels {sorted(want)} — the field walk is truncating"
            )
        # The name-collision filter rests on this: no watched type takes an
        # unlabeled initializer parameter. If one ever does, the filter starts
        # hiding real rebuilds of it and must be revisited.
        if "_" in want:
            fails.append(
                f"{t}'s initializer has an UNLABELED parameter — the "
                f"name-collision filter would now hide real rebuilds of it"
            )

    if fails:
        for f in fails:
            print(f"SELF-TEST FAIL: {f}")
        return 1
    print("check_swift_copy_sites --self-test: OK")
    for t, fs in real.items():
        print(f"  parsed {t}: {len(fs)} stored properties")
    if skipped:
        print(f"  skipped (not a struct): {', '.join(skipped)}")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(self_test())
    sys.exit(run(write_baseline="--write-baseline" in sys.argv))
