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

# Canonical widget-kind vocabulary: the union of kinds rendered by at least one
# app. Mirrors the Python `_RENDERERS` dispatch (jas/panels/yaml_renderer.py)
# plus `color_bar`, which Python registers dynamically at startup
# (color_bar_widget.register_color_bar) and Flask/Rust render generically.
# Keep in sync until a schema-declared vocabulary supersedes it (Rec 1).
CANONICAL_WIDGET_KINDS = frozenset({
    "container", "row", "col", "grid",
    "text", "button", "icon", "icon_button", "icon_select",
    "slider", "number_input", "text_input", "length_input",
    "toggle", "checkbox", "select", "combo_box", "dropdown",
    "color_swatch", "color_gradient", "color_hue_bar", "color_bar",
    "radio_group", "gradient_tile", "gradient_slider",
    "separator", "spacer", "disclosure", "panel",
    "fill_stroke_widget", "tree_view", "element_preview", "tabs",
    "placeholder",
})

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
