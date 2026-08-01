#!/usr/bin/env python3
"""One sanctioned spelling for each angle-unit conversion, in both ACTIVE ports.

THE RULE, and it is a CORRECTNESS rule rather than a style preference
---------------------------------------------------------------------
Degrees and radians differ by a ratio, and floating-point multiplication is not
associative. `(deg * PI) / 180` and `deg * (PI / 180)` are DIFFERENT DOUBLES.
So this repository sanctions exactly one grouping per direction -- multiply by
the RATIO, never multiply-then-divide:

    Rust    x.to_radians()                  NEVER  x * PI / 180.0
            x.to_degrees()                  NEVER  x * 180.0 / PI

    Swift   x * (Double.pi / 180)           NEVER  x * .pi / 180
            x * (180 / Double.pi)           NEVER  x * 180 / .pi

That grouping is not a coin toss. It is what THREE of this project's four
floating-point dialects already do, and the fourth was the outlier:

  * Rust's `f64::to_radians()` is literally `self * (consts::PI / 180.0)`
    and `to_degrees()` is `self * (180.0 / consts::PI)`.
  * CPython's `math.radians` / `math.degrees` -- which is what the LIVE
    REFERENCE `workspace_interpreter/` calls -- precompute `degToRad` and
    `radToDeg` and multiply. MEASURED over 7201 quarter-degrees:
    `math.radians(d)` is bit-identical to `d * (pi/180)` on all 7201 and
    differs from `(d*pi)/180` on 2080. Same shape for `degrees`: 0 and 1918.
  * `spec/geometry/linear_gradient.py`, the analytic tier, calls
    `math.radians` too.
  * JasSwift wrote `deg * .pi / 180` in 39 places, and five Rust sites wrote
    `angle_deg * std::f64::consts::PI / 180.0` rather than calling the method
    one line away.

WHAT IT COSTS -- MEASURED, NOT ASSUMED
--------------------------------------
Over integer degrees -720..720 (1441 values) the two deg->rad groupings differ
IN BITS on 384. Over the same angles the two rad->deg groupings differ on 348,
and over 1441 `atan2` outputs on 386. Worst absolute divergence through `tan`,
at quarter-degree steps up to the transform dialog's +/-89.9 clamp: 1.165e-11 --
`tan` amplifies hard near the clamp.

That reaches the SAVED FILE. Since MATRIXPRECISION (ruled 2026-07-31)
`geometry/svg.rs` writes matrix entries a/b/c/d at full shortest-round-trip
precision, so a rotate or shear typed into the Properties panel serialises
different BYTES in the two ports.

And nothing in the corpus could see it. Every tolerance in the algorithm
registry is 1e-4 or wider -- `transform_apply` is the tightest at 1e-12, chosen
deliberately four orders above this -- and the expression conformance corpus
compares at 1e-9. The difference is 1e-16. It was found by the Phase-3
`transform_apply` roundtrip family reporting BIT-EXACT matrix agreement and
getting 354 mismatches, not by any tolerance-based comparison.

WHY A SOURCE GATE RATHER THAN 39 UNIT TESTS
-------------------------------------------
A unit test per site pins the sites that exist. This pins the sites nobody has
written yet, which is the entire point: the defect is a SPELLING that a future
author will reach for exactly as naturally as the eleven authors who reached for
it already did.

SCOPE -- STATED HERE AND PRINTED WHERE IT REPORTS
-------------------------------------------------
This gate reads SOURCE TEXT, one line at a time, in `JasSwift/` and
`jas_dioxus/` only. Everything below is a thing it CANNOT SEE, and each is
listed because a gate whose blind spots are unknown is worse than no gate:

  * A GROUPING ASSEMBLED AT RUNTIME. `let k = Double.pi; ... deg * k / 180`
    spans two statements and reads clean. So does a ratio arriving as a
    function parameter, or read from a struct field.
  * A CONVERSION FROM A LIBRARY. `Angle(degrees:)` in SwiftUI, CoreGraphics
    helpers, `simd`, kurbo/Vello -- each has its own grouping and this gate
    never sees the arithmetic. Measured today: 0 such sites in scope, so the
    gate would not notice the first one.
  * A DIFFERENT LITERAL. `deg * 0.017453292519943295` is the same conversion
    written with the ratio inlined; it mentions neither `pi` nor `180`.
  * A CONVERSION SPLIT ACROSS LINES. The scan is line-by-line.
  * THE FROZEN PORTS (`jas/`, `jas_ocaml/`, POLICY.md section 1), the PYTHON
    REFERENCE, `spec/`, `jas_flask`, `prototypes/` and `scripts/benchmarks/`.
    The reference and `spec/` are correct today by calling `math.radians`;
    nothing here enforces that they keep doing so. Measured: 0 pi-and-180
    lines in `prototypes/` and `scripts/benchmarks/` today.
  * WHETHER THE CONVERSION IS RIGHT AT ALL. A site that converts when it
    should not, or uses the wrong direction, is perfectly sanctioned here.

FAIL-CLOSED CHOICES, so the blind spots above cannot be widened by accident:
a MULTI-LINE block comment is not modelled, and its contents are read as code --
which can only produce a FALSE POSITIVE (the gate reds, a human looks), never a
false pass. Raw/extended string literals (`r#"..."#`, `#"..."#`) are likewise
not modelled by the `//` stripper.

EXEMPTIONS live in `scripts/degree_radian_grouping_exemptions.json`, keyed
`path:line-ish-anchor`, each with a REASON. Empty today. The ledger is policed
BOTH WAYS: a row whose site has vanished, or whose site no longer violates, is
STALE and reds -- see check_gate_consistency.py, which exists because a
one-directional ledger asserted a missing feature for months after it shipped.
"""

import json
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
LEDGER = "degree_radian_grouping_exemptions.json"

# ---------------------------------------------------------------------------
# ANTI-VACUITY FLOORS. EXACT, NOT SLACK -- the house rule, bought by the
# jas/windows seat setting a test-count floor 1.6% below reality, gating six
# tests off, and watching the gate go green:
#
#   "A floor with slack is a floor with a hole exactly the size of the slack,
#    and the hole admits precisely the move the assertion exists to forbid."
#
# Two DIFFERENT quantities, because they fail differently. The FILE counts catch
# discovery going quiet (a bad pathspec, a run from outside the repo, no git).
# The CONVERSION counts catch the recogniser going quiet while discovery still
# works -- and for Rust that is the only witness there is, because after the
# sweep a correct Rust tree contains ZERO pi-and-180 lines, so "0 violations"
# and "read nothing" are the same output. `to_radians`/`to_degrees` call sites
# are the independent evidence that the port's angle code is still being read.
#
# Bump these in the same commit as a real addition or deletion. That friction is
# the feature: the number is a claim, and a claim nobody restates is a claim
# nobody rechecks.
MIN_SWIFT_FILES = 307
MIN_RUST_FILES = 149
MIN_SWIFT_CONVERSIONS = 39   # sanctioned `* (pi/180)` / `* (180/pi)` sites
MIN_RUST_CONVERSIONS = 36    # `.to_radians()` + `.to_degrees()` call sites

# ---------------------------------------------------------------------------
# Swift. `.pi` is spelled bare (type-inferred), or qualified by any of the three
# floating types. `M_PI` is the C spelling and would be just as wrong.
SWIFT_PI = r"(?:\bDouble\.pi\b|\bCGFloat\.pi\b|\bFloat\.pi\b|(?<![\w.)\]])\.pi\b|\bM_PI\b)"
SWIFT_PI_RE = re.compile(SWIFT_PI)
# The ONLY two legal shapes: multiply by a PARENTHESISED ratio, either way up.
SWIFT_OK_RE = re.compile(
    r"\*\s*\(\s*(?:"
    rf"{SWIFT_PI}\s*/\s*180(?:\.0+)?"          # deg -> rad
    rf"|180(?:\.0+)?\s*/\s*{SWIFT_PI}"          # rad -> deg
    r")\s*\)"
)

# Rust. There is no legal pi-and-180 line at all: the method exists, on the
# primitive, and is exactly this grouping.
RUST_PI_RE = re.compile(r"\bPI\b")
RUST_OK_RE = re.compile(r"\.to_radians\(\)|\.to_degrees\(\)")

PORTS = {
    "swift": {
        "root": "JasSwift/",
        "suffix": ".swift",
        "pi": SWIFT_PI_RE,
        "ok": SWIFT_OK_RE,
        "min_files": MIN_SWIFT_FILES,
        "min_conversions": MIN_SWIFT_CONVERSIONS,
        "fix": "x * (Double.pi / 180)   /   x * (180 / Double.pi)",
    },
    "rust": {
        "root": "jas_dioxus/",
        "suffix": ".rs",
        "pi": RUST_PI_RE,
        "ok": RUST_OK_RE,
        "min_files": MIN_RUST_FILES,
        "min_conversions": MIN_RUST_CONVERSIONS,
        "fix": "x.to_radians()   /   x.to_degrees()",
    },
}


def strip_comment(line):
    """Everything before an unquoted `//`.

    Both languages use `//`, and both put `//` inside string literals (a URL).
    Cutting at the first occurrence would silently DELETE code, which is a false
    pass, so the quote state is tracked. Escapes count. Raw and extended string
    literals are not modelled -- declared in the docstring.
    """
    out = []
    in_str = False
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if in_str:
            if c == "\\":
                out.append(c)
                if i + 1 < n:
                    out.append(line[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            out.append(c)
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and line[i + 1] == "/":
            break
        # A single-line /* ... */ is dropped. A MULTI-line one is not modelled
        # and its body is read as code -- fail-closed, see the docstring.
        out.append(c)
        i += 1
    return re.sub(r"/\*.*?\*/", " ", "".join(out))


def scan_text(port, path, text):
    """[(path, lineno, source_line)] for lines spelling a conversion illegally.

    A line is IN SCOPE when it mentions a pi token and the literal 180. It is
    LEGAL when removing every sanctioned spelling leaves no pi-and-180 pair
    behind -- so one line carrying two conversions is judged on both.
    """
    cfg = PORTS[port]
    bad = []
    for i, raw in enumerate(text.splitlines(), start=1):
        code = strip_comment(raw)
        if "180" not in code or not cfg["pi"].search(code):
            continue
        residue = cfg["ok"].sub(" ", code)
        if "180" in residue and cfg["pi"].search(residue):
            bad.append((path, i, raw.rstrip()))
    return bad


def count_conversions(port, text):
    """How many SANCTIONED conversion sites a file holds (the vacuity witness)."""
    return len(PORTS[port]["ok"].findall(text))


def tracked(port):
    cfg = PORTS[port]
    try:
        out = subprocess.run(
            ["git", "ls-files", f"*{cfg['suffix']}"],
            cwd=REPO, capture_output=True, text=True, encoding="utf-8",
            check=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        raise RuntimeError(
            f"cannot enumerate {port} sources: `git ls-files` is unavailable "
            f"({e}). Refusing to run rather than scanning nothing and calling "
            f"it clean.") from e
    return [p for p in out.splitlines() if p.startswith(cfg["root"])]


def load_ledger():
    p = REPO / "scripts" / LEDGER
    if not p.exists():
        return {}
    d = json.loads(p.read_text(encoding="utf-8"))
    return dict(d.get("sites", {}))


def anchor(path, line):
    return f"{path}:{line}"


def adjudicate(found, ex):
    """(violations, stale) — the ledger applied to a set of findings, BOTH WAYS.

    Pure, so the self-test can drive both directions without a violating file in
    the tree. `found` is [(port, path, line, src)].

    Direction 1: a finding named in the ledger is excused.
    Direction 2 — THE SECOND LOOP, and the whole reason this is separate: a row
    naming a site that produced NO finding is STALE. A gate that only iterates
    its findings never visits such a row, so no claim on it can ever fire; that
    is how one exemption asserted a port lacked a feature it had shipped months
    earlier.
    """
    seen = {anchor(p, ln) for _, p, ln, _ in found}
    violations = [v for v in found if anchor(v[1], v[2]) not in ex]
    stale = sorted(k for k in ex if k not in seen)
    return violations, stale


def run_live(ex=None):
    """(violations, stale_rows, stats) over the tracked tree.

    `ex` is injectable so the self-test can exercise the ledger against the real
    tree without editing a shipped file.
    """
    ex = load_ledger() if ex is None else ex
    found = []
    stats = {}
    for port in PORTS:
        files = tracked(port)
        n_conv = 0
        for rel in files:
            text = (REPO / rel).read_text(encoding="utf-8")
            n_conv += count_conversions(port, text)
            for path, ln, src in scan_text(port, rel, text):
                found.append((port, path, ln, src))
        stats[port] = (len(files), n_conv)
    violations, stale = adjudicate(found, ex)
    return violations, stale, stats


def report_scope():
    return (
        "SCOPE: this gate reads SOURCE TEXT, one line at a time, in JasSwift/ "
        "and jas_dioxus/ only.\n"
        "       It CANNOT see a grouping assembled at runtime (a ratio held in "
        "a variable,\n"
        "       a field or a parameter), a conversion arriving from a library "
        "(SwiftUI Angle,\n"
        "       CoreGraphics, simd, kurbo), the ratio inlined as a literal "
        "(x * 0.01745329...),\n"
        "       or a conversion split across lines. The frozen ports, "
        "workspace_interpreter/,\n"
        "       spec/, jas_flask and prototypes/ are out of scope."
    )


def self_test():
    f = []

    def swift(src):
        return scan_text("swift", "T.swift", src)

    def rust(src):
        return scan_text("rust", "t.rs", src)

    # (a) The spelling the sweep removed, in both directions, must be caught --
    #     bare `.pi`, qualified `Double.pi`, with and without `.0`.
    for src in ("let rad = deg * .pi / 180.0",
                "let rad = angleDeg * Double.pi / 180",
                "let d = atan2(y, x) * 180.0 / .pi",
                "let d = atan(k) * 180 / Double.pi",
                "let r = x * CGFloat.pi / 180.0",
                "let r = x * M_PI / 180.0"):
        if not swift(src):
            f.append(f"  a: Swift must refuse {src!r}")

    # (b) The sanctioned spellings must pass, both directions, both spacings.
    for src in ("let rad = angleDeg * (Double.pi / 180)",
                "let k = tan(angleDeg * (Double.pi / 180.0))",
                "let deg = r * (180 / Double.pi)",
                "let deg = r * ( 180.0 / .pi )"):
        if swift(src):
            f.append(f"  b: Swift must accept {src!r}")

    # (c) Rust has no legal pi-and-180 line: the method IS the grouping.
    if not rust("let rad = angle_deg * std::f64::consts::PI / 180.0;"):
        f.append("  c: Rust must refuse `angle_deg * std::f64::consts::PI / 180.0`")
    if not rust("let d = r * 180.0 / PI;"):
        f.append("  c: Rust must refuse `r * 180.0 / PI`")
    for src in ("let rad = angle_deg.to_radians();",
                "let d = r.to_degrees();",
                "let t = 2.0 * std::f64::consts::PI * i / n;",
                "arc(&mut pts, x, y, PI, 3.0 * PI / 2.0, n);"):
        if rust(src):
            f.append(f"  c: Rust must accept {src!r}")

    # (d) A COMMENT may quote the forbidden spelling -- the two swept sites
    #     document it in place, and a gate that reds on its own explanation
    #     teaches authors to delete the explanation.
    if swift("        // is `self * (PI / 180.0)`. Writing it as `deg * .pi / 180`"):
        f.append("  d: a // comment quoting the bad spelling must not be flagged")
    if swift("let rad = deg * (Double.pi / 180)  // not `deg * .pi / 180`"):
        f.append("  d: a trailing comment must not red a correct line")
    # ... but a `//` inside a STRING must not truncate the line, because that
    #     would delete code and pass.
    if not swift('log("http://x", deg * .pi / 180)'):
        f.append("  d: `//` inside a string literal must not hide the defect")

    # (e) TWO conversions on one line are judged on BOTH -- the residue rule.
    if swift("let a = x * (Double.pi / 180), b = y * (180 / Double.pi)"):
        f.append("  e: two sanctioned conversions on one line must pass")
    if not swift("let a = x * (Double.pi / 180), b = y * .pi / 180"):
        f.append("  e: one good and one bad conversion on a line must be caught")

    # (f) The vacuity witness must actually count the sanctioned population,
    #     because for Rust it is the ONLY evidence the scan read anything.
    if count_conversions("rust", "a.to_radians(); b.to_degrees();") != 2:
        f.append("  f: the Rust conversion counter must see to_radians/to_degrees")
    if count_conversions("swift", "x * (Double.pi / 180) + y * (180 / .pi)") != 2:
        f.append("  f: the Swift conversion counter must see both directions")

    # (g) THE LIVE TREE MUST BE CLEAN, or production is the first anyone hears.
    violations, stale, stats = run_live()
    if violations:
        f.append(f"  g: the shipping ports carry {len(violations)} unsanctioned "
                 f"spelling(s): {[f'{p}:{l}' for _, p, l, _ in violations[:6]]}")
    if stale:
        f.append(f"  g: stale exemption row(s) whose site no longer violates: {stale}")

    # (h) The anti-vacuity floors must be MET, and must be able to fail. A floor
    #     that cannot red is decoration.
    for port, (n_files, n_conv) in stats.items():
        cfg = PORTS[port]
        if n_files < cfg["min_files"]:
            f.append(f"  h: {port}: {n_files} files < floor {cfg['min_files']}")
        if n_conv < cfg["min_conversions"]:
            f.append(f"  h: {port}: {n_conv} sanctioned conversion sites < floor "
                     f"{cfg['min_conversions']}")
    if not scan_text("swift", "T.swift", "let r = deg * .pi / 180"):
        f.append("  h: the scanner itself has stopped recognising the defect")

    # (i) THE LEDGER, BOTH DIRECTIONS. The shipped ledger is EMPTY, so
    #     production exercises neither direction and both would rot unnoticed --
    #     which is the failure check_gate_consistency.py exists for, one level
    #     down. Driven through the real `adjudicate`, not a paraphrase of it.
    hit = [("swift", "A.swift", 7, "let r = deg * .pi / 180")]
    v, st = adjudicate(hit, {"A.swift:7": "a reason"})
    if v:
        f.append("  i: a finding named in the ledger must be excused")
    if st:
        f.append("  i: a row naming a LIVE finding must not be reported stale")
    v, st = adjudicate(hit, {"A.swift:9": "the line moved"})
    if len(v) != 1:
        f.append("  i: a row must excuse only the anchor it names")
    if st != ["A.swift:9"]:
        f.append(f"  i: a row whose site no longer violates must be STALE — got {st}")
    # And the anchor really is path:line, so a row can be written by hand from
    # the gate's own output.
    if [anchor(p, l) for p, l, _ in
            scan_text("swift", "F.swift", "\nlet r = deg * .pi / 180\n")] != ["F.swift:2"]:
        f.append("  i: the anchor must be path:line, matching the report")

    if f:
        print("SELF-TEST FAILED -- the gate does not detect what it claims:")
        print("\n".join(f))
        return 1
    print("self-test: both unsanctioned groupings are refused in both ports and "
          "both directions;\n"
          "           the parenthesised-ratio and to_radians/to_degrees "
          "spellings pass; a comment\n"
          "           quoting the defect does not red and a `//` inside a "
          "string does not hide it;\n"
          "           two conversions on one line are judged separately; the "
          "live tree is clean\n"
          f"           ({stats['swift'][1]} Swift + {stats['rust'][1]} Rust "
          f"conversion sites over {stats['swift'][0]} + {stats['rust'][0]} "
          "files, floors met).")
    print(report_scope())
    return 0


def main():
    if "--self-test" in sys.argv:
        return self_test()

    violations, stale, stats = run_live()
    ex = load_ledger()

    failed = False
    for port, (n_files, n_conv) in stats.items():
        cfg = PORTS[port]
        if n_files < cfg["min_files"]:
            print(f"ERROR: only {n_files} {port} files scanned, floor "
                  f"{cfg['min_files']} — the scan went quiet, so a clean "
                  f"report means nothing.", file=sys.stderr)
            failed = True
        if n_conv < cfg["min_conversions"]:
            print(f"ERROR: only {n_conv} sanctioned {port} conversion sites "
                  f"found, floor {cfg['min_conversions']} — either angle code "
                  f"was deleted (bump the floor in the same commit) or the "
                  f"recogniser stopped matching.", file=sys.stderr)
            failed = True

    if stale:
        print(f"ERROR: {len(stale)} exemption row(s) are STALE — the site no "
              f"longer exists, or no longer spells the conversion illegally:",
              file=sys.stderr)
        for k in stale:
            print(f"  {k}: {ex[k]}", file=sys.stderr)
        print("Delete the row. An exemption nobody rechecks is how one gate "
              "asserted a port\nlacked a feature it had shipped months earlier.",
              file=sys.stderr)
        failed = True

    if violations:
        print(f"ERROR: {len(violations)} unsanctioned degree/radian grouping(s).",
              file=sys.stderr)
        print(file=sys.stderr)
        for port, path, ln, src in violations:
            print(f"  {path}:{ln}", file=sys.stderr)
            print(f"      {src.strip()}", file=sys.stderr)
            print(f"      write it as: {PORTS[port]['fix']}", file=sys.stderr)
        print(file=sys.stderr)
        print("`(deg * PI) / 180` and `deg * (PI / 180)` are DIFFERENT DOUBLES: "
              "they disagree", file=sys.stderr)
        print("in bits on 384 of 1441 integer degrees, and since MATRIXPRECISION "
              "the saved SVG", file=sys.stderr)
        print("carries a/b/c/d at full precision — so the two ports write "
              "different BYTES for", file=sys.stderr)
        print("the same user action. No corpus tolerance is narrow enough to "
              "see it (the tightest", file=sys.stderr)
        print("is 1e-12; the difference is 1e-16).", file=sys.stderr)
        print(file=sys.stderr)
        print(f"If a site genuinely needs the other grouping, add it to "
              f"scripts/{LEDGER}", file=sys.stderr)
        print("with a reason. The ledger is policed both ways.", file=sys.stderr)
        failed = True

    if failed:
        return 1

    print(f"degree/radian grouping: {stats['swift'][1]} Swift and "
          f"{stats['rust'][1]} Rust conversion sites, every one in the "
          f"sanctioned grouping\n"
          f"  (Swift `x * (Double.pi / 180)`, Rust `x.to_radians()` — the same "
          f"double, and the same\n"
          f"  double CPython's math.radians produces for the live reference). "
          f"{len(ex)} exemption(s).")
    print(report_scope())
    return 0


if __name__ == "__main__":
    sys.exit(main())
