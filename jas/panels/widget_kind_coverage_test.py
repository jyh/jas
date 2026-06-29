"""Widget-kind coverage gate (TESTING_STRATEGY.md §4, Rec 1).

Every widget node in a panel's content tree must declare a `type:` drawn from
the canonical widget-kind vocabulary below. An unknown kind (e.g. a typo like
bare `number` for `number_input`) silently renders as a placeholder box in all
apps, so this gate catches it as data — no rendering required.

Scope note: this checks the *vocabulary* (is the kind known?), which catches
typos that no app handles. It does NOT yet check *per-app coverage* (is the kind
handled by every app's dispatch) — that is the broader cross-app gate tracked in
TESTING_STRATEGY.md. The canonical set below is the seed of the schema-declared
vocabulary called for in Rec 1; promote it to a shared module when the compiler
gains `type:` validation.

`type:` is also used as a *data-type* on state-field declarations (e.g.
`color.yaml` `h: {type: number, default: 0}`). Those live under `state:`, never
under `content:`, so walking only the content tree excludes them — `number` is a
valid *data type* there and an invalid *widget kind* in content.
"""

import json
from pathlib import Path

# Canonical widget-kind vocabulary: single-sourced in the shared interpreter lib
# (workspace_interpreter.widget_tree), which the widget-tree snapshot pass also
# uses for its `kind` field, so the vocabulary and the snapshot can never drift.
from workspace_interpreter.widget_tree import CANONICAL_WIDGET_KINDS

_WORKSPACE_JSON = Path(__file__).resolve().parents[2] / "workspace" / "workspace.json"


def _widget_types(node):
    """Yield every widget `type:` reachable from a panel content tree.

    Mirrors the renderer's descent: a widget is a dict with a string `type`;
    containers nest their children under `children`.
    """
    if isinstance(node, list):
        for child in node:
            yield from _widget_types(child)
    elif isinstance(node, dict):
        kind = node.get("type")
        if isinstance(kind, str):
            yield kind
        yield from _widget_types(node.get("children"))
        # Some widgets nest a subtree under "content" (panel / tab pages)
        # rather than "children" — descend it too so a non-canonical kind
        # can't hide inside a tab page or panel wrapper.
        yield from _widget_types(node.get("content"))


def test_every_panel_widget_kind_is_canonical():
    workspace = json.loads(_WORKSPACE_JSON.read_text())
    panels = workspace["panels"]

    offenders = {}
    for name, panel in panels.items():
        unknown = {
            kind for kind in _widget_types(panel.get("content"))
            if kind not in CANONICAL_WIDGET_KINDS
        }
        if unknown:
            offenders[name] = sorted(unknown)

    assert not offenders, (
        "Panels declare widget kinds outside the canonical vocabulary "
        "(these render as placeholder boxes in every app):\n"
        + "\n".join(f"  {name}: {kinds}" for name, kinds in sorted(offenders.items()))
        + "\nFix the YAML to use a canonical kind, or add the kind to "
          "CANONICAL_WIDGET_KINDS + every app's renderer if it is genuinely new."
    )


def test_every_dialog_widget_kind_is_canonical():
    """Same vocabulary gate, applied to modal/non-modal DIALOG content trees.

    Dialogs were previously NOT walked — which is how `radio` (used by the
    Scale / Shear option dialogs) silently rendered as a placeholder in every
    app for so long. Walking them here closes that gap as data.
    """
    workspace = json.loads(_WORKSPACE_JSON.read_text())
    dialogs = workspace.get("dialogs", {})

    offenders = {}
    for name, dialog in dialogs.items():
        unknown = {
            kind for kind in _widget_types(dialog.get("content"))
            if kind not in CANONICAL_WIDGET_KINDS
        }
        if unknown:
            offenders[name] = sorted(unknown)

    assert not offenders, (
        "Dialogs declare widget kinds outside the canonical vocabulary "
        "(these render as placeholder boxes in every app):\n"
        + "\n".join(f"  {name}: {kinds}" for name, kinds in sorted(offenders.items()))
        + "\nFix the YAML to use a canonical kind, or add the kind to "
          "CANONICAL_WIDGET_KINDS + every app's renderer if it is genuinely new."
    )
