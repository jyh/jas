#!/usr/bin/env python3
"""The BUILT web app carries no unformatted `{THEME_X}` placeholder.

WHY THIS EXISTS
---------------
A theme colour reaches a style through Rust formatting: rsx's `style: "..."`
and `format!` substitute `{THEME_ACCENT}`, but a PLAIN string literal does not.
`dock_panel.rs` held two such literals (`"height:3px; background:{THEME_ACCENT};
..."` in a plain `let`), interpolated later as `style: "{drop_indicator_style}"`,
which inserts the value without re-reading its braces. So the browser got
`background:{THEME_ACCENT}`, invalid CSS, and the dock's group drop indicator
had no colour from 2026-04-11 (the extraction) until STATUS-jas row 122 found
the literal in the shipped `.wasm` on 2026-11-13. No source search was
reliable here (a brace inside a format string is right, inside a plain one is
wrong); the BINARY says which survived.

WHAT IT ASSERTS
---------------
Over every `*.wasm` under the given directory: ZERO occurrences of the bytes
`{THEME_` followed by `[A-Z0-9_]+}`. Anti-vacuity: at least one `.wasm` is
read, and each holds `var(--jas-` (the resolved theme form), so the file read
is the app and not an empty or foreign binary.

WHAT IT DOES NOT COVER
----------------------
* Placeholders other than `THEME_` (`{size}`, `{id_prefix}` are YAML template
  fields the interpreter fills at run time, legitimately present).
* A `THEME_` value broken some other way (a wrong constant name in a format
  string fails to compile, so it cannot ship).

    python3 scripts/check_wasm_theme_placeholders.py --self-test
    python3 scripts/check_wasm_theme_placeholders.py <dir holding the built .wasm>
"""
import argparse
import glob
import os
import re
import sys
import tempfile

PAT = re.compile(rb"\{THEME_[A-Z0-9_]+\}")
ANCHOR = b"var(--jas-"


def scan(root):
    files = sorted(glob.glob(os.path.join(root, "**", "*.wasm"), recursive=True))
    if not files:
        return None, f"no .wasm under {root}"
    out = []
    for f in files:
        b = open(f, "rb").read()
        if ANCHOR not in b:
            return None, f"{f} holds no `var(--jas-`: not the app binary"
        for m in PAT.finditer(b):
            ctx = b[max(0, m.start() - 40):m.end() + 10].decode("ascii", "replace")
            out.append(f"{os.path.basename(f)}@{m.start()}: {m.group().decode()} in ...{ctx}...")
    return out, f"{len(files)} .wasm file(s)"


def self_test():
    with tempfile.TemporaryDirectory() as d:
        assert scan(d)[0] is None, "an empty dir must refuse"
        open(os.path.join(d, "x.wasm"), "wb").write(b"\x00asm junk")
        assert scan(d)[0] is None, "a binary without the anchor must refuse"
        open(os.path.join(d, "x.wasm"), "wb").write(b"\x00asm color:var(--jas-accent,#4a90d9); size {size} {id_prefix}")
        got, _ = scan(d)
        assert got == [], got
        open(os.path.join(d, "y.wasm"), "wb").write(b"\x00asm var(--jas-x) height:3px; background-color:{THEME_ACCENT}; and {THEME_BG}")
        got, _ = scan(d)
        assert len(got) == 2 and "THEME_ACCENT" in got[0], got
    print("check_wasm_theme_placeholders SELF-TEST: OK (empty dir and foreign binary refused; template fields passed; 2 planted placeholders caught)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root", nargs="?")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        self_test()
        return 0
    if not a.root:
        print("check_wasm_theme_placeholders: REFUSED -- name the directory holding the built .wasm")
        return 2
    got, what = scan(a.root)
    if got is None:
        print(f"check_wasm_theme_placeholders: REFUSED -- {what}")
        return 2
    for x in got:
        print("  " + x)
    print(f"check_wasm_theme_placeholders: {'OK' if not got else 'FAIL (%d)' % len(got)} -- {what} read. "
          "NOT COVERED: non-THEME placeholders (YAML template fields, legitimately present)")
    return 0 if not got else 1


if __name__ == "__main__":
    sys.exit(main())
