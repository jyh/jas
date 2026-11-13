#!/usr/bin/env python3
"""A conditional inline-style fragment states its OFF value; it is never empty.

WHY THIS EXISTS
---------------
dioxus-interpreter-js 0.7.10 updates a changed `style` attribute by saving
every old longhand, setting the new string, then `style.setProperty(prop, old)`
for every longhand that now reads empty. So a property the NEW string drops is
RESTORED from the old one. A fragment like

    let row_bg = if selected { "background:rgba(51,122,183,0.4);" } else { "" };

therefore sticks once it has been on. Measured 2026-11-13 on main (STATUS-jas
row 121): select a Layers row, then another, and BOTH stay highlighted; turn
Layer Options' Show off and on again, and Preview stays dimmed at 0.4. The fix
is to state the off value (`background-color:transparent;`, `opacity:1;`).

WHAT IT ASSERTS
---------------
Over `jas_dioxus/src/**/*.rs` except `geometry/` (SVG export text, not DOM
styles): ZERO conditional fragments whose ON branch is a CSS declaration
string (starts `<property>:`) and whose OTHER branch is `""` or
`String::new()`, in either shape:

    = if c { "<css>" } else { "" };                    (one line)
    = if c {                                          (multi-line; the on
        "<css>"  |  "<css>".to_string()  |  format!("<css>")    branch may be a
    } else {                                           `&str`, a `String`
        ""  |  String::new()                           or a `format!`)
    };

A fragment whose condition never changes for one element (a row-vs-column
reset, `cursor:pointer` on an interactive element) is exempt when the `let`
line or the line above carries `// style-fragment: fixed per element`; the
verdict prints how many it exempted.

WHAT IT DOES NOT COVER
----------------------
* Two branches that set DIFFERENT properties (`if a { "x:1" } else { "y:1" }`):
  `x` sticks when the second applies. Each such fragment must state both.
* A fragment chosen by `match`, or built inside a closure or a loop variable.
* A fragment whose OFF value is a variable that can be empty.

    python3 scripts/check_style_fragment_off_values.py --self-test
    python3 scripts/check_style_fragment_off_values.py
"""
import argparse
import glob
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "jas_dioxus", "src")
MARK = "// style-fragment: fixed per element"
CSS = r'"\s*-?-?[a-z][a-z-]*\s*:[^"]*"'
ON = r'(?:' + CSS + r'(?:\.to_string\(\))?|format!\(' + CSS + r'[^)]*\))'
OFF = r'(?:""|String::new\(\))'
ONE = re.compile(r'=\s*if\b[^{]*\{\s*' + ON + r'\s*\}\s*else\s*\{\s*' + OFF + r'\s*\}')


def findings(text, name="<text>"):
    out, exempt = [], 0
    L = text.split("\n")
    for i, line in enumerate(L):
        if line.lstrip().startswith("//"):
            continue
        hit = bool(ONE.search(line))
        if not hit and re.search(r'=\s*if\b[^{]*\{\s*$', line) and i + 4 < len(L):
            on, els, off, end = (L[i + 1].strip(), L[i + 2].strip(), L[i + 3].strip(), L[i + 4].strip())
            hit = (re.fullmatch(ON, on) is not None and els == "} else {"
                   and re.fullmatch(OFF, off) is not None and end.startswith("}"))
        if not hit:
            continue
        if MARK in line or (i > 0 and MARK in L[i - 1]):
            exempt += 1
            continue
        out.append(f"{name}:{i + 1}: a conditional style fragment with an empty other branch: {line.strip()[:90]}")
    return out, exempt


def self_test():
    bad = [
        'let a = if c { "opacity:0.4;" } else { "" };',
        'let a = if c { "background:rgba(1,2,3,0.4);" } else { String::new() };',
        'let a = if c {\n    "opacity:0.35;pointer-events:none;"\n} else {\n    ""\n};',
        'let a = if c {\n    "background-color:var(--x);".to_string()\n} else {\n    String::new()\n};',
        'let a = if let Some(w) = d.get("w") {\n    format!("width:{w}px;")\n} else {\n    String::new()\n};',
        'let a = if c { "--bs-gutter-x:0;" } else { "" };',
    ]
    good = [
        'let a = if c { "opacity:0.4;" } else { "opacity:1;" };',
        'let a = if c {\n    "background:red;"\n} else {\n    "background-color:transparent;"\n};',
        'let a = if c { "jas-menu-item" } else { "" };',
        'let a = if c { " font-weight=\\"bold\\"" } else { "" };',
        '// let a = if c { "opacity:0.4;" } else { "" };',
        MARK + '\nlet a = if c { "cursor:pointer;" } else { "" };',
        'let a = if c { "cursor:pointer;" } else { "" }; ' + MARK,
    ]
    for s in bad:
        f, _ = findings(s)
        assert len(f) == 1, ("missed", s, f)
    for s in good:
        f, _ = findings(s)
        assert f == [], ("false hit", s, f)
    _, ex = findings(good[5] + "\n" + good[6])
    assert ex == 2, ex
    print(f"check_style_fragment_off_values SELF-TEST: OK ({len(bad)} planted shapes caught, {len(good)} clean shapes passed, 2 marked fragments exempted and counted)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true")
    if ap.parse_args().self_test:
        self_test()
        return 0
    files = [f for f in sorted(glob.glob(os.path.join(SRC, "**", "*.rs"), recursive=True))
             if os.sep + "geometry" + os.sep not in f]
    allf, exempt, styled = [], 0, 0
    for f in files:
        t = open(f, encoding="utf-8").read()
        styled += t.count('style: "')
        got, ex = findings(t, os.path.relpath(f, REPO).replace(os.sep, "/"))
        allf += got
        exempt += ex
    if styled == 0:
        print(f"check_style_fragment_off_values: REFUSED -- {len(files)} files read and none has a `style: \"` attribute; the scan did not reach the views")
        return 2
    for x in allf:
        print("  " + x)
    verdict = "OK" if not allf else f"FAIL ({len(allf)})"
    print(f"check_style_fragment_off_values: {verdict} -- {len(files)} .rs files ({styled} `style:` attributes); {exempt} fragment(s) exempted as `{MARK}`. "
          "NOT COVERED: branches setting different properties; a fragment chosen by match or built in a closure; an off value held in a variable")
    return 0 if not allf else 1


if __name__ == "__main__":
    sys.exit(main())
