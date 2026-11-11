"""Every dialog gives at least one interactive leaf a widget id.

WHY: the widget id is the only key that joins a dialog's plan to what a shell
renders (TESTING.md section 5 item 2: the shell sets the id it is given, and
none when it has none). A dialog with no id on any interactive leaf has nothing
to compare, so its rendered-tree check can only read NOT RUN. Nine dialogs were
in that state (the seven tool-alternate flyouts and both save-changes
confirmations), and the fix is in the spec, not in a position-based join:
positions re-pair silently when a leaf is inserted or reordered.

A text leaf does not count: text is id-less across the dialogs by convention.
"""

import os

import pytest

from workspace_interpreter.loader import load_workspace

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Leaf types that carry no input and are not compared by id.
NON_INTERACTIVE = {"text", "container", "row", "column", "spacer", "separator", "divider"}


def _leaves(node):
    if isinstance(node, dict):
        if node.get("type") and "children" not in node:
            yield node
        for value in node.values():
            yield from _leaves(value)
    elif isinstance(node, list):
        for value in node:
            yield from _leaves(value)


@pytest.fixture(scope="module")
def dialogs():
    ws = load_workspace(os.path.join(REPO_ROOT, "workspace"))
    found = ws.get("dialogs") or {}
    # Anti-vacuity: the workspace has dozens of dialogs; an empty or tiny map
    # means the loader moved, not that every dialog passed.
    assert len(found) >= 30, f"only {len(found)} dialogs loaded"
    return found


def test_every_dialog_has_an_id_on_an_interactive_leaf(dialogs):
    missing = []
    for name, spec in sorted(dialogs.items()):
        interactive = [n for n in _leaves(spec.get("content")) if n["type"] not in NON_INTERACTIVE]
        if interactive and not any(n.get("id") for n in interactive):
            missing.append(f"{name} ({len(interactive)} interactive leaves, none with an id)")
    assert not missing, "dialogs the rendered tree cannot join:\n  " + "\n  ".join(missing)


def test_dialog_leaf_ids_are_unique_within_the_dialog(dialogs):
    dupes = []
    for name, spec in sorted(dialogs.items()):
        seen = {}
        for n in _leaves(spec.get("content")):
            i = n.get("id")
            if i:
                seen[i] = seen.get(i, 0) + 1
        dupes += [f"{name}: {i} x{c}" for i, c in seen.items() if c > 1]
    assert not dupes, "\n  ".join(dupes)
