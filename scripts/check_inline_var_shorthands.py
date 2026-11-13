#!/usr/bin/env python3
"""No inline style in the web app writes a `var()` value inside a SHORTHAND.

WHY THIS EXISTS
---------------
dioxus-interpreter-js 0.7.10 updates a changed `style` attribute in three
moves (`setAttributeInner`, case "style"): it saves every old LONGHAND's value,
calls `setAttribute` with the new string, then calls
`style.setProperty(prop, old)` for every longhand that now reads empty. A
longhand of a shorthand whose value holds `var()` ALWAYS reads "" (it is
pending substitution), so that restore REMOVES it, and the whole shorthand
declaration goes with it. Measured 2026-11-13 on main 4abab25a (STATUS-jas row
120): at boot every pane drew with no background and no border, because row
116's boot re-layout is one style update; a window resize brought them back,
because the next update has nothing to restore. A bare-page replay of the
three moves loses a `var()` shorthand and keeps a `var()` longhand and a
literal shorthand.

So a `var()` colour is written as a LONGHAND (`background-color`,
`border-width` + `border-style` + `border-color`, and the side and `outline`
forms). The generic renderer expands the YAML's own shorthands
(`renderer::longhand_var_shorthands`).

WHAT IT ASSERTS
---------------
Over `jas_dioxus/src/**/*.rs`, code lines only (a line whose first non-blank
characters are `//` is skipped): ZERO occurrences of `background:`,
`border:`, `border-<side>:` or `outline:` whose value (up to `;` or `"`)
holds `var(--` or `{THEME_X}`, where THEME_X is any `theme.rs` constant
whose value holds `var(` -- DERIVED from that file at run time, never listed.

Anti-vacuity: the derived theme set must be non-empty, and the scan must read
at least one `.rs` file that uses a `{THEME_` constant, the population this
gate is about (a glob that reached no styles would otherwise read OK).

WHAT IT DOES NOT COVER
----------------------
* A style built by `format!` from a property NAME held in a variable.
* A `var()` value passed through a non-THEME constant or a variable.
* CSS outside inline styles: a `style { r#"..."# }` stylesheet block is
  SKIPPED (the interpreter never patches its rules, so a `var()` shorthand
  there is fine).

    python3 scripts/check_inline_var_shorthands.py --self-test
    python3 scripts/check_inline_var_shorthands.py
"""
import argparse
import glob
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "jas_dioxus", "src")
THEME = os.path.join(SRC, "workspace", "theme.rs")
SHORTHAND = r"(?<![a-z-])(background|border|border-(?:top|right|bottom|left)|outline)\s*:\s*([^;\"]*)"


def var_themes(theme_text):
    """THEME_ constants whose value holds var(), derived from theme.rs."""
    return {m.group(1) for m in re.finditer(r'const\s+(THEME_[A-Z0-9_]+)\s*:\s*&str\s*=\s*"([^"]*)"', theme_text)
            if "var(" in m.group(2)}


def findings(text, themes, name="<text>"):
    out = []
    in_sheet = False
    for n, line in enumerate(text.splitlines(), 1):
        # A `style { r#" ... "# }` element is a STYLESHEET: the interpreter
        # never patches its rules, so a var() shorthand there is fine.
        if in_sheet:
            if '"#' in line:
                in_sheet = False
            continue
        if re.search(r'\bstyle\s*\{\s*r#"', line):
            in_sheet = '"#' not in line.split('r#"', 1)[1]
            continue
        if line.lstrip().startswith("//"):
            continue
        for m in re.finditer(SHORTHAND, line):
            val = m.group(2)
            hits_theme = any("{" + t + "}" in val for t in themes)
            if "var(--" in val or hits_theme:
                out.append(f"{name}:{n}: `{m.group(1)}:` holds a var() value: {m.group(0).strip()[:80]}")
    return out


def self_test():
    themes = var_themes('pub(crate) const THEME_BG: &str = "var(--jas-pane-bg,#3c3c3c)";\n'
                        'pub(crate) const THEME_PLAIN: &str = "#123";\n')
    assert themes == {"THEME_BG"}, themes
    bad = [
        'style: "left:{x}px; background:{THEME_BG}; z-index:3"',
        'style: "border:1px solid var(--jas-border,#555);"',
        'style: "border-bottom:1px solid {THEME_BG}"',
        'style: "outline: 2px solid var(--jas-accent,#4a90d9)"',
        'format!("background: var(--jas-check-bg,#fff)")',
    ]
    good = [
        'style: "background-color:{THEME_BG}; border-width:1px; border-style:solid; border-color:var(--jas-border,#555)"',
        'style: "border:1px solid #555; background:#333"',
        'style: "background:{THEME_PLAIN}"',
        '// a comment: background:{THEME_BG}',
        'style: "border-bottom-color:{THEME_BG}"',
    ]
    for s in bad:
        assert len(findings(s, themes)) == 1, ("missed", s, findings(s, themes))
    for s in good:
        assert findings(s, themes) == [], ("false hit", s, findings(s, themes))
    sheet = 'style { r#"\n  .x { background: var(--jas-check-bg) }\n"# }\nstyle: "background:{THEME_BG}"'
    got = findings(sheet, themes)
    assert len(got) == 1 and got[0].startswith("<text>:4:"), ("stylesheet block", got)
    two = 'style: "background:{THEME_BG}; border:1px solid {THEME_BG}"'
    assert len(findings(two, themes)) == 2, findings(two, themes)
    print(f"check_inline_var_shorthands SELF-TEST: OK ({len(bad)} planted shapes caught, {len(good)} clean shapes passed, one two-hit line counted twice, a stylesheet block skipped and the line after it caught)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        self_test()
        return 0
    themes = var_themes(open(THEME, encoding="utf-8").read())
    if not themes:
        print("check_inline_var_shorthands: REFUSED -- no var() THEME constant derived from theme.rs; the gate would be vacuous")
        return 2
    files = sorted(glob.glob(os.path.join(SRC, "**", "*.rs"), recursive=True))
    allf, longhand_files = [], 0
    for f in files:
        t = open(f, encoding="utf-8").read()
        if "{THEME_" in t:
            longhand_files += 1
        allf += findings(t, themes, os.path.relpath(f, REPO))
    if longhand_files == 0:
        print(f"check_inline_var_shorthands: REFUSED -- {len(files)} files read and none uses a `{{THEME_` constant; the scan did not reach the styles it is about")
        return 2
    for x in allf:
        print("  " + x)
    verdict = "OK" if not allf else f"FAIL ({len(allf)})"
    print(f"check_inline_var_shorthands: {verdict} -- {len(files)} .rs files, {len(themes)} var() THEME constants derived; "
          f"{longhand_files} file(s) use a THEME constant. NOT COVERED: a property name held in a variable; "
          f"a var() value through a non-THEME constant or a variable; stylesheet CSS")
    return 0 if not allf else 1


if __name__ == "__main__":
    sys.exit(main())
