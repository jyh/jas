"""The dynamic-submenu corpus (test_fixtures/algorithms/submenu_entries.json).

menubar.yaml's `menu_workspace` and `menu_appearance` list entries that are
not in the bundle: saved layouts and available appearances, each with a
check on the active one. `menu_state.json` walks only the static items, so
these lists were pinned by nothing. The corpus is generated from the
reference by scripts/gen_submenu_entries_corpus.py; this test holds the
file fresh and the reference to it, and the two active ports replay it.
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, (ROOT / "scripts").as_posix())

import gen_submenu_entries_corpus as gen  # noqa: E402
from workspace_interpreter.menu_state import appearance_entries, workspace_entries  # noqa: E402

GOLDEN = ROOT / "test_fixtures" / "algorithms" / "submenu_entries.json"


def test_the_corpus_is_fresh():
    assert GOLDEN.read_text(encoding="utf-8") == gen.render(), (
        "submenu_entries.json is stale: run python scripts/gen_submenu_entries_corpus.py")


def test_the_corpus_names_both_dynamic_submenus():
    cases = json.loads(GOLDEN.read_text(encoding="utf-8"))
    assert {c["submenu"] for c in cases} == {"menu_workspace", "menu_appearance"}


def test_the_default_layout_is_never_listed_and_the_active_is_checked():
    got = workspace_entries(["Workspace", "A", "B"], "B")
    assert [(e["name"], e["checked"]) for e in got] == [("A", False), ("B", True)]


def test_no_stored_appearance_checks_the_default():
    got = appearance_entries([{"name": "dark_gray", "label": "Dark Gray"},
                              {"name": "light_gray", "label": "Light Gray"}], None)
    assert [(e["label"], e["checked"]) for e in got] == [("Dark Gray", True), ("Light Gray", False)]
