"""YAML-driven panel menu builder.

Reads panel menu definitions from workspace YAML specs and builds
QMenu instances using the expression evaluator for checked_when
and enabled_when conditions.
"""

from __future__ import annotations

import os

from workspace_interpreter.loader import load_workspace
from workspace_interpreter.expr import evaluate

from workspace.workspace_layout import PanelKind


# Map PanelKind enum to YAML panel content IDs
PANEL_KIND_TO_CONTENT_ID = {
    PanelKind.LAYERS: "layers_panel_content",
    PanelKind.COLOR: "color_panel_content",
    PanelKind.SWATCHES: "swatches_panel_content",
    PanelKind.STROKE: "stroke_panel_content",
    PanelKind.PROPERTIES: "properties_panel_content",
    PanelKind.CHARACTER: "character_panel_content",
    PanelKind.PARAGRAPH: "paragraph_panel_content",
    PanelKind.ARTBOARDS: "artboards_panel_content",
    PanelKind.ALIGN: "align_panel_content",
    PanelKind.BOOLEAN: "boolean_panel_content",
    PanelKind.OPACITY: "opacity_panel_content",
    PanelKind.MAGIC_WAND: "magic_wand_panel_content",
}

# Module-level cache for loaded panel specs
_panel_specs: dict | None = None
_workspace_data: dict | None = None


def load_panel_specs(workspace_path: str) -> dict:
    """Load workspace and return the panels dict, keyed by content id."""
    global _panel_specs, _workspace_data
    ws = load_workspace(workspace_path)
    _panel_specs = ws.get("panels", {})
    _workspace_data = ws
    return _panel_specs


def get_panel_specs() -> dict:
    """Return cached panel specs. Call load_panel_specs first."""
    global _panel_specs
    if _panel_specs is None:
        workspace_path = os.path.join(
            os.path.dirname(__file__), "..", "..", "workspace"
        )
        load_panel_specs(workspace_path)
    return _panel_specs


def get_panel_spec(kind: PanelKind) -> dict | None:
    """Get the YAML spec for a panel kind."""
    content_id = PANEL_KIND_TO_CONTENT_ID.get(kind)
    if content_id is None:
        return None
    return get_panel_specs().get(content_id)


def get_workspace_data() -> dict | None:
    """Return the cached workspace data dict.

    Available after load_panel_specs or get_panel_specs has been called.
    """
    get_panel_specs()  # ensure loaded
    return _workspace_data


def build_menu_items(panel_spec: dict) -> list:
    """Extract menu items from a panel spec.

    Returns a list where each item is either:
    - "separator" (string)
    - A dict with at least "label" and optionally "action", "params",
      "checked_when", "enabled_when", "disabled"
    """
    return panel_spec.get("menu", [])


def panel_label_from_yaml(kind: PanelKind) -> str:
    """Get the panel label from YAML spec, falling back to kind name."""
    spec = get_panel_spec(kind)
    if spec:
        return spec.get("summary", kind.name.capitalize())
    return kind.name.capitalize()


def is_checked(item: dict, panel_state: dict, global_state: dict) -> bool:
    """Evaluate a menu item's checked_when expression."""
    expr = item.get("checked_when")
    if not expr:
        return False
    ctx = {"panel": panel_state, "state": global_state}
    result = evaluate(expr, ctx)
    return result.to_bool()


def is_enabled(item: dict, panel_state: dict, global_state: dict) -> bool:
    """Evaluate a menu item's enabled_when expression.

    Returns True if no enabled_when is specified (enabled by default).
    Returns False if the item has disabled: true.
    """
    if item.get("disabled"):
        return False
    expr = item.get("enabled_when")
    if not expr:
        return True
    ctx = {"panel": panel_state, "state": global_state}
    result = evaluate(expr, ctx)
    return result.to_bool()


def build_qmenu(panel_spec: dict, panel_state: dict, global_state: dict,
                 dispatch_fn, parent=None):
    """Build a QMenu from a panel's YAML menu spec.

    Args:
        panel_spec: The panel YAML spec dict.
        panel_state: Current panel-local state dict.
        global_state: Current global state dict.
        dispatch_fn: Callback(action_name, params) called when menu item triggered.
        parent: Parent QWidget for the menu.

    Returns:
        A QMenu ready to exec().
    """
    from PySide6.QtWidgets import QMenu

    menu = QMenu(parent)
    items = build_menu_items(panel_spec)

    for item in items:
        if item == "separator" or (isinstance(item, dict) and item.get("type") == "separator"):
            menu.addSeparator()
            continue

        if not isinstance(item, dict):
            continue

        label = item.get("label", "")
        action_name = item.get("action")
        params = item.get("params", {})

        qt_action = menu.addAction(label)

        # Checked state (for radio/toggle items)
        if "checked_when" in item:
            qt_action.setCheckable(True)
            qt_action.setChecked(is_checked(item, panel_state, global_state))

        # Enabled state
        if not is_enabled(item, panel_state, global_state):
            qt_action.setEnabled(False)

        # Connect action
        if action_name:
            a = action_name
            p = dict(params)
            qt_action.triggered.connect(lambda _, act=a, par=p: dispatch_fn(act, par))

    return menu
