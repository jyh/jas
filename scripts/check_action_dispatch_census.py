#!/usr/bin/env python3
"""Which log-only actions does each port actually implement? (council O2.1)

WHY THIS EXISTS
---------------
RULED by JYH at the 2026-07-30 council, and queued to run EARLY: *"before the O1
divergence stones, since it likely finds more of them and finding first is
cheaper."* It was never built.

An action whose `workspace/actions.yaml` effect list is a bare `- log:` does
NOTHING by itself. It works only if a port carries a native arm for it. So for
every such action there are four possibilities, and only one of them is fine:

  native-both        both ports implement it
  native-rust-only   works in Rust, DOES NOTHING in Swift
  native-swift-only  the mirror
  dead-both          neither implements it — the action is a stub

The `(native)` log-string convention this replaces was wrong on 2 of its own 9
uses, which is why the census is derived rather than annotated.

THE REFUTER'S CAVEAT, CARRIED AND EARNED
----------------------------------------
The council recorded: *"regex extraction over two hand-written switches will
misread something, so the script's self-test must verify its classification
against known anchors before anyone acts on its output."*

It was right, twice, on the first two attempts:

* Scanning a hand-picked list of "the dispatch files" put `undo` in dead-both.
  `undo` dispatches from the MENU BAR, not the panel switch. The native surface
  is wider than any curated list, so this scans every port source file and the
  file list is not maintained by hand.
* The council's own `save_as = divergent` anchor now FAILS — because queue item
  O1.1, four bullets below it, repaired exactly that divergence. `menu_bar.rs`
  says so: *"Real handler as of council O1.1 ... File > Save As did nothing at
  all in this port while JasSwift implemented it fully."* A script validated
  against that anchor today would look broken while being correct.

Both anchors are kept below with their history, because an anchor that moved is
worth more than one that was always true.

WHAT THIS DELIBERATELY DOES NOT CLAIM
-------------------------------------
A name appearing as a string-literal arm is evidence the port MENTIONS the
action, not proof the arm does useful work. This gate is a DIVERGENCE detector,
not a correctness one: it is sound for "these two ports disagree about whether
this action exists" and says nothing about whether either implementation is
right. `dead-both` in particular is a claim about dispatch, not about intent —
several of those are deliberately unimplemented.
"""

from __future__ import annotations

import argparse
import collections
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
ACTIONS_YAML = REPO / "workspace" / "actions.yaml"

# A string literal used as a match/switch arm, in either language's spelling.
ARM = re.compile(r'(?:case\s+)?"([a-z0-9_]+)"\s*(?:\||=>|:)')

# Test sources are excluded: a fixture naming an action is not a port
# implementing it, and including them turned dead-both rows green.
RUST_SKIP = ("cross_language_test", "test_")

# Anchors, per the ruling. Each records what it was AND what it is, because two
# of the three moved between the ruling and the build.
ANCHORS = {
    # Dispatches from the menu bar in both ports. The anchor that caught a
    # curated file list.
    "undo": ("native-both", None),
    # Declared in the spec, implemented by neither. Still true.
    "toggle_artboard_orientation": ("dead-both", None),
    # WAS `divergent` when ruled; queue item O1.1 repaired it.
    "save_as": ("native-both",
                "was 'divergent' at the 2026-07-30 council; O1.1 wired the Rust "
                "half (see menu_bar.rs), so the anchor moved rather than broke"),
    # A CURRENTLY divergent action, so the divergent classification itself stays
    # proven. Verified by hand: absent from JasSwift/Sources entirely.
    "rearrange_artboards": ("native-rust-only", None),
}

MIN_LOG_ONLY = 63    # zero slack (council O3.3): the population, not a floor
MIN_RUST_ARMS = 500  # a scan that collapses is not a clean scan
MIN_SWIFT_ARMS = 300


def log_only_actions() -> list[str]:
    """Actions whose entire declared effect is `- log:` — they do nothing
    unless a port implements them."""
    import yaml
    data = yaml.safe_load(ACTIONS_YAML.read_text(encoding="utf-8"))
    acts = data.get("actions", data)
    out = []
    for name, body in acts.items():
        if not isinstance(body, dict):
            continue
        eff = body.get("effects") or []
        if isinstance(eff, list) and eff and all(
                isinstance(e, dict) and set(e) == {"log"} for e in eff):
            out.append(name)
    return sorted(out)


def arm_names(root: pathlib.Path, suffix: str, skip=()) -> set:
    names = set()
    for f in root.rglob("*" + suffix):
        # `.as_posix()`, not `str()`: this text is a COMPARISON subject and
        # `str(Path)` yields backslashes on Windows, so a skip rule keyed on
        # it would silently stop skipping there. check_path_keying.py caught
        # this — the second new file of mine it has caught this week.
        if any(s in f.as_posix() for s in skip):
            continue
        try:
            names |= set(ARM.findall(f.read_text(encoding="utf-8", errors="replace")))
        except OSError:
            continue
    return names


def classify(actions, rust, swift) -> dict:
    out = collections.defaultdict(list)
    for a in actions:
        r, s = a in rust, a in swift
        key = ("native-both" if r and s else
               "dead-both" if not r and not s else
               "native-rust-only" if r else "native-swift-only")
        out[key].append(a)
    return out


def self_test() -> int:
    """Prove the scan can FAIL first, then that it reproduces every anchor."""
    failures = []

    if _scan_is_fatal(0, MIN_RUST_ARMS):
        pass
    else:
        failures.append("an empty rust scan must be FATAL")
    if not _scan_is_fatal(MIN_RUST_ARMS - 1, MIN_RUST_ARMS):
        failures.append("an under-floor scan must be FATAL")
    if _scan_is_fatal(MIN_RUST_ARMS, MIN_RUST_ARMS):
        failures.append("a scan exactly at the floor must be accepted")

    actions = log_only_actions()
    rust = arm_names(REPO / "jas_dioxus" / "src", ".rs", RUST_SKIP)
    swift = arm_names(REPO / "JasSwift" / "Sources", ".swift")
    cls = classify(actions, rust, swift)
    where = {a: k for k, v in cls.items() for a in v}

    for anchor, (want, _note) in ANCHORS.items():
        got = where.get(anchor)
        if got is None:
            failures.append(f"anchor {anchor!r} is not a log-only action any "
                            f"more — the anchor moved and must be re-stated")
        elif got != want:
            failures.append(f"anchor {anchor!r}: classified {got}, ruling says "
                            f"{want}. Do not act on this census until the "
                            f"disagreement is explained.")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    if failures:
        return 1
    print(f"check_action_dispatch_census SELF-TEST: OK (empty and under-floor "
          f"scans proven FATAL first; all {len(ANCHORS)} ruling anchors "
          f"reproduced, including the one O1.1 moved)")
    return 0


def _scan_is_fatal(n: int, floor: int) -> bool:
    return n < floor


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--table", action="store_true", help="print the full table")
    args = ap.parse_args()
    if args.self_test:
        return self_test()

    actions = log_only_actions()
    rust = arm_names(REPO / "jas_dioxus" / "src", ".rs", RUST_SKIP)
    swift = arm_names(REPO / "JasSwift" / "Sources", ".swift")

    if _scan_is_fatal(len(actions), MIN_LOG_ONLY):
        print(f"FAIL: {len(actions)} log-only actions, floor {MIN_LOG_ONLY}. The "
              f"population shrank; lower this deliberately or find what broke.")
        return 1
    if _scan_is_fatal(len(rust), MIN_RUST_ARMS) or _scan_is_fatal(len(swift), MIN_SWIFT_ARMS):
        print(f"FAIL: scan collapsed (rust {len(rust)}, swift {len(swift)}). An "
              f"empty scan classifies everything as dead-both and reports it "
              f"calmly; this refuses to.")
        return 1

    cls = classify(actions, rust, swift)
    for k in ("native-both", "native-rust-only", "native-swift-only", "dead-both"):
        print(f"  {k:<20} {len(cls[k]):>3}")
    if args.table:
        for k in ("native-rust-only", "native-swift-only", "dead-both", "native-both"):
            if cls[k]:
                print(f"\n{k}:")
                for a in cls[k]:
                    print(f"  {a}")

    divergent = cls["native-rust-only"] + cls["native-swift-only"]
    print(f"\ncheck_action_dispatch_census: {len(actions)} log-only actions; "
          f"{len(divergent)} DIVERGENT — implemented by one port and doing "
          f"nothing in the other.")
    for a in cls["native-rust-only"]:
        print(f"  rust-only : {a}")
    for a in cls["native-swift-only"]:
        print(f"  swift-only: {a}")
    print("\nReported, not failed: this is a census, and each divergence is a "
          "stone someone must schedule (council O1). It reds only when the scan "
          "itself collapses or an anchor stops reproducing.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
