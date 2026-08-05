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
     python scripts/check_path_b_exclusions.py --self-test

WHY --self-test EXISTS
----------------------
This gate is a regex scraper pointed at four files in four languages. Its
failure mode is not a wrong answer, it is a SILENT EMPTY one: a syntax change
moves the declaration, the marker stops matching or the block bound stops
bounding, and the extractor returns a set that is empty (or full of ids that
are not in the declaration at all). Comparing two empty sets says they agree.
`main` already guards the empty case; until 2026-08-05 nothing proved that
guard, or the four markers, could fire.

`--self-test` therefore parses synthetic sources in all four syntaxes using the
REAL marker patterns declared below — not copies — so a marker that stops
matching its own language is caught here rather than by a frozen port drifting
unnoticed. It also asserts the block bound holds: an id sitting AFTER the
closing delimiter must not be scraped in.

Until 2026-08-05 this script parsed no arguments, so any flag was ignored and
exited 0.
"""

import argparse
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


def extract_from_text(text: str, start_re: str, end_char: str,
                      where: str = "<text>") -> frozenset:
    """Scrape the exclusion set out of one source's declaration block.

    Split from `extract` so the parse can be exercised on synthetic sources
    with no files involved — the file read was the only reason this logic was
    untestable.
    """
    m = re.search(start_re, text)
    if not m:
        raise SystemExit(f"FAIL: exclusion-set marker not found in {where} "
                         f"(pattern {start_re!r}) — did the declaration move?")
    rest = text[m.end():]
    end = rest.find(end_char)
    block = rest if end < 0 else rest[:end]
    return frozenset(_ID.findall(block))


def extract(path: str, start_re: str, end_char: str) -> frozenset:
    text = open(os.path.join(ROOT, path), encoding="utf-8").read()
    return extract_from_text(text, start_re, end_char, where=path)


# Synthetic declarations in each of the four syntaxes. Each carries the same
# two panels inside its block and a THIRD id, `leaked_panel_content`, placed
# after the closing delimiter — so a scraper whose block bound stopped bounding
# names itself instead of quietly widening the set.
_PROBE_SOURCES = {
    "rust": '''
let path_b_unsupported = matches!(
    id,
    "color_panel_content" | "layers_panel_content"
);
let unrelated = "leaked_panel_content";
''',
    "swift": '''
private let pathBExcluded: Set<String> = [
    "color_panel_content",
    "layers_panel_content",
]
let unrelated = "leaked_panel_content"
''',
    "ocaml": '''
let path_b_excluded = [
  "color_panel_content";
  "layers_panel_content";
]
let unrelated = "leaked_panel_content"
''',
    "python": '''
_PATH_B_UNSUPPORTED = {
    "color_panel_content",
    "layers_panel_content",
}
UNRELATED = "leaked_panel_content"
''',
}

_PROBE_EXPECTED = frozenset({"color_panel_content", "layers_panel_content"})


def _self_test() -> int:
    """Prove the gate can still REJECT. Opens no source file."""
    failures = []
    markers = {label: (start_re, end_char)
               for (label, _path, start_re, end_char)
               in ACTIVE_SOURCES + FROZEN_SOURCES}

    # 1. A SILENTLY EMPTY SCRAPE IS FATAL, and it is checked first: if the
    #    extractor returned nothing, every set comparison below would be
    #    "two empty sets agree" and this self-test would prove nothing.
    first = extract_from_text(_PROBE_SOURCES["rust"], *markers["rust"])
    if not first:
        print("SELF-TEST FAIL: the extractor scraped NOTHING from a synthetic "
              "declaration containing two panels. Every comparison below would "
              "be between empty sets.", file=sys.stderr)
        return 1

    # 2. All four language markers still match their own syntax, and the block
    #    bound still bounds — `leaked_panel_content` sits past the delimiter.
    for label, source in _PROBE_SOURCES.items():
        if label not in markers:
            failures.append(f"no marker declared for {label}")
            continue
        try:
            got = extract_from_text(source, *markers[label], where=f"probe:{label}")
        except SystemExit:
            failures.append(f"the {label} marker no longer matches {label} syntax")
            continue
        if "leaked_panel_content" in got:
            failures.append(f"the {label} block bound leaked an id from AFTER "
                            f"the closing delimiter")
        elif got != _PROBE_EXPECTED:
            failures.append(f"the {label} extractor returned {sorted(got)}, "
                            f"expected {sorted(_PROBE_EXPECTED)}")

    # 3. A MISSING marker must raise, not return an empty set. A scraper that
    #    returns empty when it cannot find the declaration is the exact false
    #    green this gate exists to avoid.
    try:
        extract_from_text("nothing here at all", *markers["rust"], where="probe:absent")
        failures.append("a missing marker returned quietly instead of raising")
    except SystemExit:
        pass

    # 4. A DIVERGENCE between two active sets is detectable — the thing the
    #    gate is actually for. One port dropping a panel must not compare equal.
    dropped = extract_from_text(
        _PROBE_SOURCES["rust"].replace(' | "layers_panel_content"', ""),
        *markers["rust"])
    if dropped == _PROBE_EXPECTED:
        failures.append("dropping a panel from one port's set compared EQUAL")

    # 5. The frozen tier compares against its tag-pinned constant, so that
    #    constant must not be empty — an empty FROZEN_EXPECTED would make every
    #    frozen port's drift undetectable.
    if not FROZEN_EXPECTED:
        failures.append("FROZEN_EXPECTED is empty; frozen drift is undetectable")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}", file=sys.stderr)
    if failures:
        return 1
    print(f"check_path_b_exclusions SELF-TEST: OK (empty scrape fatal proven "
          f"FIRST; all {len(_PROBE_SOURCES)} language markers match their own "
          f"syntax; block bounds hold against an id past the delimiter; a "
          f"missing marker raises; a dropped panel compares UNEQUAL).")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Path B panel exclusion-set gate.")
    ap.add_argument("--self-test", action="store_true",
                    help="prove the gate can still reject; opens no source file")
    if ap.parse_args().self_test:
        return _self_test()

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
