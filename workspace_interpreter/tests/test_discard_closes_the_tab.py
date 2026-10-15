"""Save Changes' Discard removes the tab the dialog asked about.

Before this, Discard ran `close_without_saving` (close the dialog, log), so an
edited tab could never close through the YAML route: the dialog went away and
the tab stayed. `close_tab` now passes the tab's `index` into the dialog,
Discard passes it on as its action's own param, and `discard_and_close_tab`
closes the dialog and dispatches `remove_tab`. The index must travel as the
ACTION's param: the dialog's params are gone once it closes (measured in all
three runners, design 2026-10-14 §10).

These tests drive the SHIPPED workspace (`workspace.json`). The host's tab
removal is the `remove_child` platform effect, recorded here.
"""

import json
import pathlib

from workspace_interpreter.effects import run_effects
from workspace_interpreter.state_store import StateStore

WORKSPACE = json.loads(
    (pathlib.Path(__file__).resolve().parents[2] / "workspace" / "workspace.json").read_text(encoding="utf-8"))
ACTIONS = WORKSPACE["actions"]
DIALOGS = WORKSPACE["dialogs"]


def _button(dialog_id, label):
    """The button labelled `label` in the dialog's content."""
    def walk(node):
        if isinstance(node, dict):
            if node.get("type") == "button" and node.get("label") == label:
                return node
            for v in node.values():
                hit = walk(v)
                if hit:
                    return hit
        elif isinstance(node, list):
            for v in node:
                hit = walk(v)
                if hit:
                    return hit
        return None
    return walk(DIALOGS[dialog_id]["content"])


def _click(store, button, platform):
    """A click on a button with a node-level `action` (SCHEMA.md): dispatch it
    with the button's `params`, which are expressions in the dialog's scope."""
    dispatch = {"action": button["action"]}
    if "params" in button:
        dispatch["params"] = button["params"]
    run_effects([{"dispatch": dispatch}], {}, store, actions=ACTIONS,
                dialogs=DIALOGS, platform_effects=platform)


def _edited_tab_asks(index):
    store = StateStore(defaults={"tab_count": 3, "active_tab": index})
    removed = []
    platform = {"remove_child": lambda arg, ctx, st: removed.append(
        (arg, (ctx.get("param") or {}).get("index")))}
    ctx = {"active_document": {"is_modified": True, "filename": "Untitled-2"}}
    run_effects([{"dispatch": {"action": "close_tab", "params": {"index": str(index)}}}],
                ctx, store, actions=ACTIONS, dialogs=DIALOGS, platform_effects=platform)
    return store, platform, removed


def test_close_tab_passes_the_index_into_the_dialog():
    store, _, removed = _edited_tab_asks(1)
    assert store.get_dialog_id() == "save_changes_tab"
    assert store.eval_context()["param"]["index"] == 1
    assert removed == [], "an edited tab is not removed before the person answers"


def test_discard_closes_the_dialog_and_removes_that_tab():
    store, platform, removed = _edited_tab_asks(1)
    _click(store, _button("save_changes_tab", "Discard"), platform)
    assert store.get_dialog_id() is None, "the dialog closed"
    assert len(removed) == 1, removed
    assert removed[0][1] == 1, f"the tab the dialog asked about: {removed}"
    assert store.get("tab_count") == 2


def test_cancel_keeps_the_tab():
    store, platform, removed = _edited_tab_asks(1)
    _click(store, _button("save_changes_tab", "Cancel"), platform)
    assert store.get_dialog_id() is None
    assert removed == []
    assert store.get("tab_count") == 3


def test_the_window_dialog_still_closes_without_removing_a_tab():
    """`save_changes_window`'s Don't Save keeps `close_without_saving`: closing
    the window is not removing a tab."""
    button = _button("save_changes_window", "Don't Save")
    assert button["action"] == "close_without_saving"
