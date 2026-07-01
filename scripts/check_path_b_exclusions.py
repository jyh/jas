#!/usr/bin/env python3
"""Assert the four native apps' Path B panel exclusion sets stay identical
(codebase-review finding #17).

The set of panels excluded from the shared Path B absolute-layout pass
(color / gradient / layers / swatches / brushes — panels whose content the v1
box model cannot yet size) is hardcoded separately in each app, in four
different syntaxes. A green panel_layout gate does NOT catch a drift in these
sets: if one app dropped a panel from its exclusion list, that app alone would
route the panel through the (unsupported) shared pass. This gate pins them
equal.

Each app declares exactly the same five `*_panel_content` ids inside its
exclusion block; this extracts the quoted ids from each block and asserts all
four are byte-identical. Run: python scripts/check_path_b_exclusions.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (label, file, start-marker regex, closing delimiter that ends the block)
SOURCES = [
    ("rust", "jas_dioxus/src/interpreter/renderer.rs", r"path_b_unsupported\s*=\s*matches!", ")"),
    ("ocaml", "jas_ocaml/lib/interpreter/yaml_panel_view.ml", r"let path_b_excluded\s*=", "]"),
    ("swift", "JasSwift/Sources/Interpreter/YamlPanelBodyView.swift", r"pathBExcluded\s*:\s*Set<String>\s*=\s*\[", "]"),
    ("python", "jas/panels/yaml_renderer.py", r"_PATH_B_UNSUPPORTED\s*=\s*\{", "}"),
]

_ID = re.compile(r'"([a-z_]+_panel_content)"')


def extract(path: str, start_re: str, end_char: str) -> frozenset:
    text = open(os.path.join(ROOT, path), encoding="utf-8").read()
    m = re.search(start_re, text)
    if not m:
        raise SystemExit(f"FAIL: exclusion-set marker not found in {path} "
                         f"(pattern {start_re!r}) — did the declaration move?")
    rest = text[m.end():]
    end = rest.find(end_char)
    block = rest if end < 0 else rest[:end]
    return frozenset(_ID.findall(block))


def main() -> int:
    sets = {}
    for label, path, start_re, end_char in SOURCES:
        sets[label] = extract(path, start_re, end_char)

    reference = sets["rust"]
    ok = all(s == reference for s in sets.values())
    if not ok:
        print("FAIL: Path B panel exclusion sets diverge across apps:", file=sys.stderr)
        for label in sorted(sets):
            print(f"  {label}: {sorted(sets[label])}", file=sys.stderr)
        return 1

    if not reference:
        print("FAIL: extracted an EMPTY exclusion set — the extractor likely "
              "broke (a syntax change). Check the SOURCES markers.", file=sys.stderr)
        return 1

    print(f"OK: all 4 apps exclude the same {len(reference)} panels from Path B "
          f"({', '.join(sorted(reference))}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
