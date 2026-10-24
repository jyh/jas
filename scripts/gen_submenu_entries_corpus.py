#!/usr/bin/env python3
"""Generate the dynamic-submenu corpus: test_fixtures/algorithms/submenu_entries.json.

Each case calls one of the reference's two dynamic-submenu functions
(`workspace_interpreter.menu_state.workspace_entries` and
`appearance_entries`, for menubar.yaml's `menu_workspace` and
`menu_appearance`) and records what it returns, so no expectation here is
typed by hand.

Consumers: the reference (workspace_interpreter/tests/test_submenu_entries.py,
which also checks this file is fresh), Rust (`menu_state::workspace_entries`,
cross_language_test.rs) and Swift (`MenuState.workspaceEntries`,
CrossLanguageTests.swift).

Regenerate: python scripts/gen_submenu_entries_corpus.py
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, ROOT.as_posix())

from workspace_interpreter.menu_state import appearance_entries, workspace_entries  # noqa: E402

OUT = ROOT / "test_fixtures" / "algorithms" / "submenu_entries.json"

APPEARANCES = [
    {"name": "dark_gray", "label": "Dark Gray"},
    {"name": "medium_gray", "label": "Medium Gray"},
    {"name": "light_gray", "label": "Light Gray"},
]

CASES = [
    # (name, submenu id, function, args)
    ("no_saved_layouts", "menu_workspace", "workspace_entries",
     {"saved": [], "active": "Workspace"}),
    ("the_default_layout_is_never_listed", "menu_workspace", "workspace_entries",
     {"saved": ["Workspace", "Painting", "Type"], "active": "Workspace"}),
    ("the_active_layout_is_checked", "menu_workspace", "workspace_entries",
     {"saved": ["Workspace", "Painting", "Type"], "active": "Type"}),
    ("saved_order_is_kept", "menu_workspace", "workspace_entries",
     {"saved": ["Zeta", "Alpha", "Workspace", "Mid"], "active": "Alpha"}),
    ("an_active_name_not_saved_checks_nothing", "menu_workspace", "workspace_entries",
     {"saved": ["Painting"], "active": "Gone"}),
    ("no_stored_appearance_means_the_default", "menu_appearance", "appearance_entries",
     {"appearances": APPEARANCES, "active": None}),
    ("the_active_appearance_is_checked", "menu_appearance", "appearance_entries",
     {"appearances": APPEARANCES, "active": "light_gray"}),
    ("an_unknown_appearance_checks_nothing", "menu_appearance", "appearance_entries",
     {"appearances": APPEARANCES, "active": "neon"}),
    ("labels_come_from_the_entry", "menu_appearance", "appearance_entries",
     {"appearances": [{"name": "custom_1", "label": "My Theme"}], "active": "custom_1"}),
]

FUNCTIONS = {"workspace_entries": lambda a: workspace_entries(a["saved"], a["active"]),
             "appearance_entries": lambda a: appearance_entries(a["appearances"], a["active"])}


def corpus() -> list[dict]:
    return [{"name": n, "submenu": s, "function": f, "args": a, "expected": FUNCTIONS[f](a)}
            for n, s, f, a in CASES]


def render() -> str:
    return json.dumps(corpus(), indent=1) + "\n"


if __name__ == "__main__":
    OUT.write_text(render(), encoding="utf-8", newline="")
    print(f"wrote {OUT.relative_to(ROOT)} ({len(CASES)} cases)")
