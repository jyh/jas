#!/usr/bin/env python3
"""A test function without `#[test]` is a test that has never run.

WHY THIS EXISTS
---------------
Found 2026-08-27 by mutating a lowering table and watching NOTHING go red.
`canvas/render.rs` carried `mask_plan_clip_not_inverted_is_clip_in()` — written,
committed, sitting between three neighbours that each had `#[test]` — with no
attribute of its own. So `(clip: true, invert: false)`, THE STANDARD OPACITY
MASK, had no coverage at all. A second, `svg.rs::roundtrip_rect`, had never
exercised SVG rect round-tripping.

⛔ RUSTC SAID SO THE WHOLE TIME: "function `…` is never used". It sat inside 52
warnings, which is the entire point — A WARNING NOBODY READS IS NOT A GATE. This
turns that one class into a red.

⚠️ THE DISCRIMINATOR IS "UNUSED", NOT "IN A TEST MODULE". A first cut flagged 430
functions, nearly all legitimate HELPERS (`rect`, `approx_eq`, `pair`) which live
in test modules and assert freely. What separates a helper from an unregistered
test is that a helper is CALLED. So the name must appear exactly once in the
file: its own definition.
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

FN = re.compile(r'^\s*(?:async\s+)?fn\s+(\w+)\s*\(')
# ⛔ THE ALTERNATION IS ANCHORED AT `#[`, so an attribute whose name merely
# CONTAINS `test` does not match — `#[wasm_bindgen_test]` was flagged as
# unregistered the first time the wasm harness landed, by this gate, on its
# author. A registration attribute is whatever the harness calls it, and a
# gate that only knows `#[test]` will red every alternative harness a repo
# ever adds. Listed explicitly rather than loosened to a substring: `test`
# anywhere in an attribute would also swallow `#[cfg(test)]` on a plain fn.
ATTR = re.compile(r'#\[\s*(test|bench|ignore|rstest|tokio::test|wasm_bindgen_test)\b')
# braces inside line comments and string literals are not structure; counting
# them is what made the module extent drift on a 4000-line file.
STRIP = re.compile(r'//.*$|"(?:\\.|[^"\\])*"')
CFG_TEST = re.compile(r'#\[\s*cfg\s*\((?:[^)]*\b)?test\b')
ASSERTION = re.compile(r'\b(assert(_eq|_ne)?|panic|unreachable|todo)\s*!\s*\(')


def scan_source(src: str) -> list[tuple[int, str]]:
    """(line, name) for every unregistered test in one file's text."""
    lines = src.split("\n")
    out, in_test, depth, td = [], False, 0, None
    for i, ln in enumerate(lines):
        # ⛔ ANY test-cfg FORM OPENS A TEST MODULE, not just the bare one.
        # `#[cfg(all(test, target_arch = "wasm32"))]` is how a wasm harness is
        # gated, and a literal "#[cfg(test)]" match misses it — which made this
        # scanner RIGHT BY ACCIDENT on render.rs: it caught the wasm tests only
        # because brace-counting had not closed the PRECEDING module. A fixture
        # with the same shape returned nothing. Two bugs cancelling is not a
        # working gate, so both are fixed.
        if CFG_TEST.search(ln):
            in_test, td = True, None
        if in_test and td is None and re.search(r"\bmod\s+\w+\s*\{", ln):
            td = depth
        code = STRIP.sub("", ln)
        depth += code.count("{") - code.count("}")
        if in_test and td is not None and depth <= td:
            in_test, td = False, None
        m = FN.match(ln)
        if not (in_test and m):
            continue
        name = m.group(1)
        # ⛔ WALK BACK ONLY OVER CONTIGUOUS ATTRIBUTES AND COMMENTS. A fixed
        # look-back window picks up the PREVIOUS function's `#[test]` — and that
        # is not hypothetical, it is the exact live shape this gate was written
        # for: the unregistered test sat directly beneath a registered one. My
        # own self-test caught it.
        j, attrs = i - 1, []
        while j >= 0:
            t = lines[j].strip()
            if not t:
                j -= 1
                continue
            if t.startswith("#[") or t.startswith("//") or t.startswith("#!["):
                attrs.append(t)
                j -= 1
                continue
            break
        if any(ATTR.search(a) for a in attrs):
            continue
        # ⛔ THE BODY IS ITS OWN BRACES, NOT A FIXED WINDOW. A 40-line slice
        # bleeds into the NEXT function and inherits its asserts — that produced
        # a false positive on `element.rs::path_elem`, a genuine helper with no
        # assertion of its own. Same class as the look-back bug above: a fixed
        # window that crosses a boundary it cannot see.
        d, body, started = 0, [], False
        for l in lines[i:]:
            body.append(l)
            d += l.count("{") - l.count("}")
            if l.count("{"):
                started = True
            if started and d <= 0:
                break
        body = "\n".join(body)
        # ⛔ MATCH THE MACRO INVOCATION, NOT THE SUBSTRING. `"assert" in body`
        # is true for a function merely NAMED `asserts_nothing` — my own
        # self-test fixture was called exactly that and defeated the check.
        # An assertion is `assert…!(`, and the `!` is what makes it one.
        if not ASSERTION.search(body):
            continue
        # A HELPER IS CALLED; an unregistered test is not. One occurrence of the
        # name in the whole file means the definition and nothing else.
        if len(re.findall(rf"\b{re.escape(name)}\b", src)) > 1:
            continue
        out.append((i + 1, name))
    return out


def tracked_rs() -> list[str]:
    out = subprocess.run(["git", "ls-files", "*.rs"], capture_output=True,
                         text=True, encoding="utf-8", check=True)
    return [p for p in out.stdout.split() if p]


def self_test() -> int:
    failures = []
    caught = """#[cfg(test)]
mod tests {
    #[test]
    fn registered() { assert!(true); }
    fn never_runs() { assert_eq!(1, 1); }
}"""
    if [n for _, n in scan_source(caught)] != ["never_runs"]:
        failures.append("an unregistered test with asserts must be CAUGHT")
    helper = """#[cfg(test)]
mod tests {
    fn approx(a: f64) -> bool { assert!(a > 0.0); true }
    #[test]
    fn uses_it() { approx(1.0); }
}"""
    if scan_source(helper):
        failures.append("a CALLED helper must not be flagged")
    no_assert = """#[cfg(test)]
mod tests {
    fn build() -> u8 { 7 }
    #[test]
    fn t() { assert_eq!(build(), 7); }
}"""
    if scan_source(no_assert):
        failures.append("a helper without asserts must not be flagged")
    # ⛔ THE ARM THE ASSERT REQUIREMENT ACTUALLY PROTECTS, added after a mutant
    # that deleted that requirement SURVIVED: an UNCALLED helper with NO
    # assertions is dead code, which is rustc's business, not this gate's. Only
    # an uncalled function that ASSERTS is a test nobody registered.
    dead_helper = """#[cfg(test)]
mod tests {
    fn never_called_and_asserts_nothing() -> u8 { 7 }
    #[test]
    fn t() { assert_eq!(1, 1); }
}"""
    if scan_source(dead_helper):
        failures.append("an uncalled helper with NO asserts is dead code, not an "
                        "unregistered test — this gate must not claim it")
    # ⛔ A NON-BARE cfg FORM MUST STILL OPEN A TEST MODULE, and production code
    # AFTER a closed test module must not be swept in. Both were wrong at once
    # and cancelled on the real file; this fixture holds them apart.
    two_mods = """#[cfg(test)]
mod tests { #[test] fn a() { assert!(true); } }

fn production_helper() { assert!(true); }

#[cfg(all(test, target_arch = "wasm32"))]
mod canvas_tests {
    fn unregistered() { assert!(true); }
}"""
    # ⛔ A STRAY BRACE IN A STRING OR COMMENT MUST NOT MOVE THE MODULE EXTENT.
    # This is what actually drifted on render.rs: a 4000-line file has plenty of
    # `{` inside format strings, and an unbalanced one leaks the test module over
    # everything that follows.
    drift = """#[cfg(test)]
mod tests {
    #[test]
    fn a() { let s = "an unbalanced brace { in a literal"; assert!(!s.is_empty()); }
}

fn production_after_a_drifting_module() { assert!(true); }"""
    got_drift = [n for _, n in scan_source(drift)]
    if got_drift:
        failures.append(f"a brace in a string/comment moved the module extent: "
                        f"flagged {got_drift} outside the test module")

    got = [n for _, n in scan_source(two_mods)]
    if got != ["unregistered"]:
        failures.append(f"cfg-form/module-extent: want ['unregistered'], got {got}")
    wasm = """#[cfg(all(test, target_arch = "wasm32"))]
mod canvas_tests {
    #[wasm_bindgen_test]
    fn browser_test() { assert!(true); }
}"""
    if scan_source(wasm):
        failures.append("#[wasm_bindgen_test] is a registration attribute — a gate "
                        "that knows only #[test] reds every alternative harness")
    outside = """fn helper_outside_tests() { assert!(true); }"""
    if scan_source(outside):
        failures.append("a function OUTSIDE a test module is not this gate's business")
    ignored = """#[cfg(test)]
mod tests {
    #[ignore = "tool"]
    fn tool() { assert!(true); }
}"""
    if scan_source(ignored):
        failures.append("an explicitly #[ignore]d function must not be flagged")
    # ⛔ ANTI-VACUITY: a scan with no files examined proves nothing.
    n = len(tracked_rs())
    if n < 50:
        failures.append(f"only {n} tracked .rs files — refusing to call that a scan")
    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print(f"check_unregistered_tests SELF-TEST: OK (catches an unregistered test; "
          f"a called helper, an assert-free helper, a function outside a test "
          f"module and an #[ignore]d one all pass; {n} tracked .rs files present "
          f"so the live scan is not vacuous)")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    files = tracked_rs()
    if len(files) < 50:
        print(f"FAIL: `git ls-files *.rs` returned {len(files)} files. "
              f"An empty or truncated scan is not a clean one.")
        return 1
    hits = []
    for f in files:
        try:
            src = pathlib.Path(f).read_text(encoding="utf-8")
        except OSError:
            continue
        hits += [(f, ln, name) for ln, name in scan_source(src)]
    if hits:
        print(f"FAIL: {len(hits)} test function(s) carry no #[test] and are never called.\n")
        for f, ln, name in hits:
            print(f"  {f}:{ln}  {name}")
        print("\nA test without #[test] has never run. Add the attribute, or if the")
        print("function is deliberately inert, mark it #[ignore] so it says so.")
        return 1
    print(f"check_unregistered_tests: OK ({len(files)} tracked .rs files; every "
          f"asserting, uncalled function in a test module carries #[test]).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
