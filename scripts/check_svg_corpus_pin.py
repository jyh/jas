#!/usr/bin/env python3
"""The SVG corpus count pinned in `ffi_paint.rs` equals the corpus, on any lane.

`jas_dioxus/src/ffi_paint.rs::the_svg_corpus_presents_what_row_da_predicted`
walks `test_fixtures/svg/*.svg` and pins the count TWICE (`assert_eq!(total, N`
and `assert_eq!(total - refusing.len(), N`). That test runs only on the Windows
Direct2D lane, so every new SVG fixture went in green on every lane its author
can run and red on the one they cannot. Its own comment says so, and it still
happened at 70 -> 71, 71 -> 72, the first bump of which missed the second pin,
and again at 76 -> 77 (2026-10-11).

This gate reads both pins and the directory, and fails when they disagree, so
the count moves on the same lane the fixture is authored on. It does NOT replace
the Windows test: that one proves each document PRESENTS through Direct2D, and
this one only proves the number is current.

Usage: check_svg_corpus_pin.py [--root DIR] | --self-test
"""
import argparse
import os
import re
import sys
import tempfile

PIN_FILE = os.path.join("jas_dioxus", "src", "ffi_paint.rs")
SVG_DIR = os.path.join("test_fixtures", "svg")
PINS = (
    re.compile(r"assert_eq!\(\s*total\s*,\s*(\d+)\s*,"),
    re.compile(r"assert_eq!\(\s*total\s*-\s*refusing\.len\(\)\s*,\s*(\d+)\s*,"),
)


def check(root):
    """Return a list of problems; empty means the pins equal the corpus."""
    pin_path = os.path.join(root, PIN_FILE)
    svg_dir = os.path.join(root, SVG_DIR)
    try:
        src = open(pin_path, encoding="utf-8").read()
    except OSError as e:
        return [f"cannot read {PIN_FILE}: {e}"]
    try:
        count = sum(1 for n in os.listdir(svg_dir) if n.endswith(".svg"))
    except OSError as e:
        return [f"cannot list {SVG_DIR}: {e}"]
    if count == 0:
        return [f"{SVG_DIR} holds no .svg files; refusing to compare against an empty corpus"]
    problems = []
    for pat in PINS:
        found = pat.findall(src)
        if len(found) != 1:
            problems.append(f"expected exactly one pin matching {pat.pattern!r} in {PIN_FILE}, found {len(found)}")
            continue
        if int(found[0]) != count:
            problems.append(
                f"{PIN_FILE} pins {found[0]} ({pat.pattern!r}) but {SVG_DIR} holds {count} .svg files: "
                f"bump BOTH pins in one edit, and say which documents moved it in the comment above them")
    return problems


def self_test():
    rust = ('        assert_eq!(total, {a}, "the fixture corpus changed size");\n'
            '        assert_eq!(total - refusing.len(), {b}, "the whole corpus presents");\n')
    cases = [
        ("both pins equal the corpus", 3, 3, 3, 0),
        ("the first pin is stale", 4, 3, 4, 1),
        ("the second pin is stale (the bump that missed it)", 4, 4, 3, 1),
        ("both pins stale", 4, 3, 3, 2),
        ("an empty corpus is refused, never compared", 0, 0, 0, 1),
    ]
    failed = 0
    for name, n_svg, a, b, want in cases:
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, os.path.dirname(PIN_FILE)))
            os.makedirs(os.path.join(d, SVG_DIR))
            open(os.path.join(d, PIN_FILE), "w").write(rust.format(a=a, b=b))
            for i in range(n_svg):
                open(os.path.join(d, SVG_DIR, f"f{i}.svg"), "w").write("<svg/>")
            open(os.path.join(d, SVG_DIR, "not_an_svg.json"), "w").write("{}")
            got = len(check(d))
        ok = got == want
        failed += not ok
        print(f"  {'ok  ' if ok else 'FAIL'} {name}: {got} problem(s), expected {want}")
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, os.path.dirname(PIN_FILE)))
        os.makedirs(os.path.join(d, SVG_DIR))
        open(os.path.join(d, PIN_FILE), "w").write("// no pins at all\n")
        open(os.path.join(d, SVG_DIR, "a.svg"), "w").write("<svg/>")
        got = len(check(d))
        ok = got == 2
        failed += not ok
        print(f"  {'ok  ' if ok else 'FAIL'} a file with no pins is two problems, never a pass: {got}")
    if failed:
        print(f"check_svg_corpus_pin SELF-TEST FAILED: {failed} case(s)")
        return 1
    print("check_svg_corpus_pin SELF-TEST: OK (6 cases)")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    problems = check(args.root)
    if problems:
        for p in problems:
            print(f"ERROR: {p}")
        return 1
    print("check_svg_corpus_pin: OK -- both ffi_paint.rs pins equal the SVG corpus. "
          "SCOPE: the count only; whether each document PRESENTS is the Windows Direct2D lane's.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
