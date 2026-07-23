#!/usr/bin/env python3
"""Assert the native apps' Path B panel exclusion sets stay consistent
(codebase-review finding #17).

The set of panels excluded from the shared Path B absolute-layout pass
(color / gradient / layers / swatches / brushes — panels whose content the v1
box model cannot yet size) is hardcoded separately in each app, in different
syntaxes. A green panel_layout gate does NOT catch a drift in these sets: if
one app dropped a panel from its exclusion list, that app alone would route
the panel through the (unsupported) shared pass.

Two tiers since the five-port-parity freeze (POLICY.md):
- ACTIVE apps (rust, swift) must stay byte-identical to each other — they
  evolve together.
- FROZEN apps (ocaml, python/Qt) are pinned to the exclusion set they carried
  at the five-port-parity tag; their sources must never drift from it (any
  change to a frozen tree is a bug by definition).

Run: python scripts/check_path_b_exclusions.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (label, file, start-marker regex, closing delimiter that ends the block)
ACTIVE_SOURCES = [
    ("rust", "jas_dioxus/src/interpreter/renderer.rs", r"path_b_unsupported\s*=\s*matches!", ")"),
    ("swift", "JasSwift/Sources/Interpreter/YamlPanelBodyView.swift", r"pathBExcluded\s*:\s*Set<String>\s*=\s*\[", "]"),
]

FROZEN_SOURCES = [
    ("ocaml", "jas_ocaml/lib/interpreter/yaml_panel_view.ml", r"let path_b_excluded\s*=", "]"),
    ("python", "jas/panels/yaml_renderer.py", r"_PATH_B_UNSUPPORTED\s*=\s*\{", "}"),
]

# The exclusion set as of the five-port-parity tag (2026-07-22). Frozen
# sources are compared against THIS, not against the live rust set, so the
# active pair can evolve without deadlocking CI on unfixable frozen trees.
FROZEN_EXPECTED = frozenset({
    "brushes_panel_content",
    "color_panel_content",
    "gradient_panel_content",
    "layers_panel_content",
    "swatches_panel_content",
})

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
    active = {}
    for label, path, start_re, end_char in ACTIVE_SOURCES:
        active[label] = extract(path, start_re, end_char)

    reference = active["rust"]
    if not all(s == reference for s in active.values()):
        print("FAIL: Path B panel exclusion sets diverge across ACTIVE apps:",
              file=sys.stderr)
        for label in sorted(active):
            print(f"  {label}: {sorted(active[label])}", file=sys.stderr)
        return 1

    if not reference:
        print("FAIL: extracted an EMPTY exclusion set — the extractor likely "
              "broke (a syntax change). Check the ACTIVE_SOURCES markers.",
              file=sys.stderr)
        return 1

    frozen_ok = True
    for label, path, start_re, end_char in FROZEN_SOURCES:
        got = extract(path, start_re, end_char)
        if got != FROZEN_EXPECTED:
            print(f"FAIL: frozen app {label} drifted from its "
                  f"five-port-parity exclusion set:", file=sys.stderr)
            print(f"  expected: {sorted(FROZEN_EXPECTED)}", file=sys.stderr)
            print(f"  found:    {sorted(got)}", file=sys.stderr)
            frozen_ok = False
    if not frozen_ok:
        return 1

    print(f"OK: active apps exclude the same {len(reference)} panels from "
          f"Path B ({', '.join(sorted(reference))}); frozen apps hold their "
          f"tag-pinned set.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
