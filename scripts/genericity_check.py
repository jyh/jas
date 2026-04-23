#!/usr/bin/env python3
"""Genericity compliance metric + no-regression lint.

Counts native-code signatures per app, compares to the committed
baseline in `scripts/genericity_baseline.json`. Fails (exit 1) if any
count has increased relative to the baseline; passes (exit 0) if
counts are unchanged or decreased.

Usage:
    python scripts/genericity_check.py             # check against baseline
    python scripts/genericity_check.py --update-baseline
                                                   # regenerate the baseline
                                                   # (commit this in the
                                                   # same PR as the reduction)
    python scripts/genericity_check.py --json      # emit current counts as JSON

See POLICY.md §2 for the enforced policy and NATIVE_BOUNDARY.md for
legitimate-native exceptions.
"""

import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BASELINE_PATH = REPO / "scripts" / "genericity_baseline.json"


# Per-app, per-category patterns to count.
#
# Each category declares:
#   kind:        "files" (count matching file paths)
#             or "regex_count" (sum of regex matches across matching files)
#   glob:        repo-relative glob
#   regex:       regex applied in MULTILINE mode (for kind="regex_count")
#   exclude_pattern: regex applied to the full path; matching files are dropped
#
# New patterns can be added here at any time. Adding a pattern requires
# running `--update-baseline` in the same PR to seed a starting count.
PATTERNS = {
    "rust": {
        "tool_files": {
            "kind": "files",
            "glob": "jas_dioxus/src/tools/*_tool.rs",
            # yaml_tool.rs is the generic YAML-driven tool runtime —
            # infrastructure, not per-tool code. Excluding it keeps the
            # counter honest as individual tools migrate from native
            # impls into workspace/tools/*.yaml: each migrated tool
            # deletes its _tool.rs and drops the count by 1, regardless
            # of whether yaml_tool.rs itself exists.
            "exclude_pattern": r"/yaml_tool\.rs$",
        },
        "panel_menu_items": {
            "kind": "regex_count",
            "glob": "jas_dioxus/src/panels/*_panel.rs",
            "regex": r"PanelMenuItem::(Action|Toggle|Radio)\b",
        },
        "hardcoded_panel_labels": {
            "kind": "regex_count",
            "glob": "jas_dioxus/src/panels/*_panel.rs",
            "regex": r"^\s*pub const LABEL\s*:",
        },
    },
    "swift": {
        "tool_files": {
            "kind": "files",
            "glob": "JasSwift/Sources/Tools/*Tool.swift",
            # YamlTool.swift is the generic YAML-driven tool runtime —
            # infrastructure, not per-tool code. Excluding keeps the
            # counter honest in the same way yaml_tool.rs is excluded
            # from the Rust count. Toolbar.swift is a panel, not a
            # canvas tool.
            "exclude_pattern": r"/(Toolbar|YamlTool)\.swift$",
        },
        "panel_menu_items": {
            "kind": "regex_count",
            "glob": "JasSwift/Sources/Panels/*Panel.swift",
            "regex": r"\.action\(label:|\.toggle\(label:|\.radio\(label:",
        },
        "hardcoded_panel_labels": {
            "kind": "regex_count",
            "glob": "JasSwift/Sources/Panels/*Panel.swift",
            "regex": r"^\s*public static let label\s*=",
        },
    },
    "ocaml": {
        "tool_files": {
            "kind": "files",
            "glob": "jas_ocaml/lib/tools/*_tool.ml",
        },
        "panel_menu_items": {
            "kind": "regex_count",
            "glob": "jas_ocaml/lib/panels/panel_menu.ml",
            "regex": r"\b(Action|Toggle|Radio)\s*\{\s*label",
        },
    },
    "python": {
        "tool_files": {
            "kind": "files",
            "glob": "jas/tools/*_tool.py",
            "exclude_pattern": r"_test\.py$",
        },
        "panel_menu_items": {
            "kind": "regex_count",
            "glob": "jas/panels/panel_menu.py",
            "regex": r"PanelMenuItem\.(action|toggle|radio)\(",
        },
    },
    "flask": {
        # The _PANEL_LABELS dict was removed on codebase-review-tier1;
        # keeping the pattern as a tripwire against reintroduction.
        "panel_name_dicts": {
            "kind": "regex_count",
            "glob": "jas_flask/renderer.py",
            "regex": r"^_PANEL_LABELS\s*=",
        },
        # JAS_ JS globals were renamed to APP_ on codebase-review-tier1.
        # Tripwire against new jas-specific globals.
        "jas_prefixed_globals": {
            "kind": "regex_count",
            "glob": "jas_flask/static/js/*.js",
            "regex": r"\bJAS_[A-Z][A-Z0-9_]*\b",
        },
        # Remaining known leak — renderer.py reaches into the
        # swatch_libraries workspace key by name. Tracked for future
        # removal via the expose_as_data refactor.
        "swatch_library_reachin": {
            "kind": "regex_count",
            "glob": "jas_flask/renderer.py",
            "regex": r"['\"]swatch_libraries['\"]",
        },
    },
}


def measure(repo: Path = REPO, patterns: dict = PATTERNS) -> dict:
    """Walk patterns and compute the per-app, per-category counts.

    repo and patterns are injectable so tests can exercise the logic
    against temp fixtures instead of the real repo.
    """
    report = {}
    for app, categories in patterns.items():
        app_report = {}
        for cat_name, spec in categories.items():
            files = sorted(repo.glob(spec["glob"]))
            excl = spec.get("exclude_pattern")
            if excl:
                exclude_re = re.compile(excl)
                files = [f for f in files if not exclude_re.search(str(f))]
            if spec["kind"] == "files":
                app_report[cat_name] = len(files)
            elif spec["kind"] == "regex_count":
                count = 0
                rx = re.compile(spec["regex"], re.MULTILINE)
                for f in files:
                    try:
                        text = f.read_text(encoding="utf-8")
                    except (OSError, UnicodeDecodeError):
                        continue
                    count += len(rx.findall(text))
                app_report[cat_name] = count
        report[app] = app_report
    return report


def diff(current: dict, baseline: dict) -> tuple[list[str], list[str]]:
    """Return (regressions, improvements) against baseline."""
    regressions = []
    improvements = []
    for app in sorted(current.keys() | baseline.keys()):
        cats = current.get(app, {})
        prev_cats = baseline.get(app, {})
        for cat in sorted(cats.keys() | prev_cats.keys()):
            now = cats.get(cat, 0)
            prev = prev_cats.get(cat, 0)
            if now > prev:
                regressions.append(
                    f"{app}/{cat}: {prev} → {now} (+{now - prev})")
            elif now < prev:
                improvements.append(
                    f"{app}/{cat}: {prev} → {now} (-{prev - now})")
    return regressions, improvements


def format_report(report: dict) -> str:
    lines = ["Current counts:"]
    for app in sorted(report):
        lines.append(f"  {app}:")
        for cat in sorted(report[app]):
            lines.append(f"    {cat}: {report[app][cat]}")
    return "\n".join(lines)


REGRESSION_GUIDANCE = """
Either:
  - Express the new behavior in workspace/*.yaml instead, or
  - If the native code fits a category in NATIVE_BOUNDARY.md, cite
    the category in the PR description and update
    scripts/genericity_baseline.json in the same commit (only after
    the category-fit has been confirmed in review), or
  - If it's a novel legitimate-native category, extend
    NATIVE_BOUNDARY.md with a new entry in the same commit.

See POLICY.md §2 for the policy."""


def main() -> int:
    args = sys.argv[1:]
    update_baseline = "--update-baseline" in args
    json_out = "--json" in args

    current = measure()

    if update_baseline:
        BASELINE_PATH.write_text(
            json.dumps(current, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(f"Baseline updated: {BASELINE_PATH}", file=sys.stderr)
        if json_out:
            print(json.dumps(current, indent=2, sort_keys=True))
        return 0

    if json_out:
        print(json.dumps(current, indent=2, sort_keys=True))
        return 0

    if not BASELINE_PATH.exists():
        print(
            f"Baseline missing at {BASELINE_PATH}.",
            file=sys.stderr,
        )
        print(
            "Seed it with: python scripts/genericity_check.py --update-baseline",
            file=sys.stderr,
        )
        return 2

    baseline = json.loads(BASELINE_PATH.read_text(encoding="utf-8"))
    regressions, improvements = diff(current, baseline)

    print(format_report(current))

    if improvements:
        print("\nImprovements (counts decreased):")
        for i in improvements:
            print(f"  {i}")
        print(
            "\nIf these reductions are intentional, commit the updated\n"
            "baseline in the same PR:\n"
            "  python scripts/genericity_check.py --update-baseline"
        )

    if regressions:
        print("\nREGRESSIONS — native code increased:", file=sys.stderr)
        for r in regressions:
            print(f"  {r}", file=sys.stderr)
        print(REGRESSION_GUIDANCE, file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
