"""Tests for the bundle-rendered (YAML) toolbar — Step A.

These exercise the generic renderer path that mounts the workspace
``toolbar_pane -> content -> tool_grid`` (mirroring Rust's
``YamlToolbarContent``) rather than the native ``tools.toolbar.Toolbar``
QPainter widget. They cover the three behaviours the Step A migration
must preserve:

  1. Clicking a tool icon_button dispatches ``select_tool`` which writes
     the tool string into ``state.active_tool``.
  2. ``bind.checked`` highlights the active tool (single-tool eq form and
     the slot ``mem(...)`` form), reactively as ``active_tool`` changes.
  3. The ``active_tool`` string round-trips with the native ``Tool`` enum
     via the id <-> enum maps, so the state bridge can drive the canvas.
"""

import json
import sys
from pathlib import Path

from absl.testing import absltest
from PySide6.QtWidgets import QApplication, QPushButton

# A QApplication must exist before any QWidget is created.
_app = QApplication.instance() or QApplication(sys.argv)

from workspace_interpreter.state_store import StateStore
from workspace_interpreter.loader import state_defaults
from panels.yaml_renderer import render_element
from tools.toolbar import Tool


_WORKSPACE_JSON = Path(__file__).resolve().parents[2] / "workspace" / "workspace.json"


def _load_bundle() -> dict:
    with open(_WORKSPACE_JSON) as f:
        return json.load(f)


def _find_toolbar_pane(layout):
    """Locate the toolbar_pane node in the compiled layout tree."""
    stack = [layout]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            if node.get("id") == "toolbar_pane":
                return node
            stack.extend(node.values())
        elif isinstance(node, list):
            stack.extend(node)
    return None


def _tool_grid(bundle):
    pane = _find_toolbar_pane(bundle["layout"])
    assert pane is not None, "toolbar_pane not found in compiled layout"
    content = pane.get("content", {})
    for child in content.get("children", []):
        if isinstance(child, dict) and child.get("id") == "tool_grid":
            return child
    raise AssertionError("tool_grid not found under toolbar_pane content")


def _icon_buttons(node):
    """Yield (id, el) for every icon_button reachable from a node."""
    if isinstance(node, dict):
        if node.get("type") == "icon_button":
            yield node.get("id"), node
        for v in node.get("children", []) or []:
            yield from _icon_buttons(v)
    elif isinstance(node, list):
        for v in node:
            yield from _icon_buttons(v)


def _make_store(active_tool="selection"):
    bundle = _load_bundle()
    store = StateStore(state_defaults(bundle.get("state", {})))
    store.set("active_tool", active_tool)
    return store, bundle


class BundleToolbarStructureTest(absltest.TestCase):
    """The compiled bundle exposes the toolbar grid the renderer mounts."""

    def test_tool_grid_present(self):
        bundle = _load_bundle()
        grid = _tool_grid(bundle)
        self.assertEqual(grid.get("type"), "grid")
        self.assertEqual(grid.get("cols"), 2)

    def test_grid_has_select_tool_buttons(self):
        bundle = _load_bundle()
        grid = _tool_grid(bundle)
        buttons = dict(_icon_buttons(grid))
        # The Selection slot must dispatch select_tool with tool=selection.
        sel = buttons.get("btn_selection")
        self.assertIsNotNone(sel)
        behaviors = sel.get("behavior", [])
        click = next(b for b in behaviors if b.get("event") == "click")
        self.assertEqual(click.get("action"), "select_tool")
        self.assertEqual(click.get("params", {}).get("tool"), "selection")
        self.assertEqual(sel.get("bind", {}).get("checked"),
                         'state.active_tool == "selection"')


class RenderToolGridTest(absltest.TestCase):
    """render_element builds a real Qt widget tree for the tool grid."""

    def test_renders_without_error(self):
        store, bundle = _make_store()
        grid = _tool_grid(bundle)
        widget = render_element(grid, store, {"_panel_id": "toolbar_pane"},
                                dispatch_fn=lambda *_: None)
        self.assertIsNotNone(widget)
        # At least the visible grid slots produce QPushButtons.
        buttons = widget.findChildren(QPushButton)
        self.assertGreaterEqual(len(buttons), 6)

    def test_icon_button_with_checked_bind_is_checkable(self):
        store, bundle = _make_store()
        grid = _tool_grid(bundle)
        widget = render_element(grid, store, {"_panel_id": "toolbar_pane"},
                                dispatch_fn=lambda *_: None)
        # Every button that has a bind.checked must be checkable so the
        # highlight can render — otherwise setChecked is a silent no-op.
        checkable = [b for b in widget.findChildren(QPushButton)
                     if b.isCheckable()]
        self.assertGreaterEqual(len(checkable), 6)


class CheckedHighlightTest(absltest.TestCase):
    """bind.checked tracks state.active_tool (initial + reactive)."""

    def _render_button(self, el, store):
        return render_element(el, store, {"_panel_id": "toolbar_pane"},
                              dispatch_fn=lambda *_: None)

    def test_selection_checked_when_active(self):
        store, bundle = _make_store(active_tool="selection")
        grid = _tool_grid(bundle)
        sel = dict(_icon_buttons(grid))["btn_selection"]
        btn = self._render_button(sel, store)
        self.assertTrue(btn.isChecked())

    def test_selection_unchecked_when_other_active(self):
        store, bundle = _make_store(active_tool="pen")
        grid = _tool_grid(bundle)
        sel = dict(_icon_buttons(grid))["btn_selection"]
        btn = self._render_button(sel, store)
        self.assertFalse(btn.isChecked())

    def test_checked_reactive_to_state_change(self):
        store, bundle = _make_store(active_tool="pen")
        grid = _tool_grid(bundle)
        sel = dict(_icon_buttons(grid))["btn_selection"]
        btn = self._render_button(sel, store)
        self.assertFalse(btn.isChecked())
        # Flip active_tool — the global subscription should re-check it.
        store.set("active_tool", "selection")
        self.assertTrue(btn.isChecked())

    def test_slot_mem_bind_checked(self):
        # btn_arrow_slot uses mem(state.active_tool, [...]) so it stays
        # highlighted for any tool sharing that slot.
        store, bundle = _make_store(active_tool="interior_selection")
        grid = _tool_grid(bundle)
        arrow = dict(_icon_buttons(grid))["btn_arrow_slot"]
        btn = self._render_button(arrow, store)
        self.assertTrue(btn.isChecked())
        store.set("active_tool", "rect")
        self.assertFalse(btn.isChecked())


class SelectToolDispatchTest(absltest.TestCase):
    """Clicking a tool icon dispatches select_tool -> store.active_tool."""

    def test_click_sets_active_tool(self):
        store, bundle = _make_store(active_tool="selection")
        grid = _tool_grid(bundle)
        pen = dict(_icon_buttons(grid))["btn_pen_slot"]

        captured = {}

        def dispatch(action, params):
            captured["action"] = action
            captured["params"] = params

        btn = render_element(pen, store, {"_panel_id": "toolbar_pane"},
                             dispatch_fn=dispatch)
        btn.click()
        self.assertEqual(captured.get("action"), "select_tool")
        self.assertEqual(captured.get("params", {}).get("tool"), "pen")


class ToolIdEnumBridgeTest(absltest.TestCase):
    """The active_tool string round-trips with the native Tool enum so the
    state bridge can drive canvas.set_tool from store writes (both the
    select_tool action and the alternates set:{active_tool} effect)."""

    def test_every_grid_tool_param_maps_to_an_enum(self):
        from jas_app import _TOOL_YAML_ID_TO_ENUM
        bundle = _load_bundle()
        grid = _tool_grid(bundle)
        for _id, el in _icon_buttons(grid):
            for b in el.get("behavior", []):
                if b.get("event") == "click" and b.get("action") == "select_tool":
                    tool_str = b.get("params", {}).get("tool")
                    self.assertIn(tool_str, _TOOL_YAML_ID_TO_ENUM,
                                  f"{tool_str} has no Tool enum mapping")

    def test_bridge_map_is_inverse_of_yaml_ids(self):
        from jas_app import MainWindow, _TOOL_YAML_ID_TO_ENUM
        for tool, yaml_id in MainWindow._TOOL_YAML_IDS.items():
            self.assertEqual(_TOOL_YAML_ID_TO_ENUM.get(yaml_id), tool,
                             f"{yaml_id} should map back to {tool}")

    def test_alternates_targets_map_to_enums(self):
        # The alternates flyout set:{active_tool: "X"} effect must also
        # resolve to a Tool so the bridge can switch the canvas.
        from jas_app import _TOOL_YAML_ID_TO_ENUM
        for slot_tool in ("interior_selection", "magic_wand", "type_on_path",
                          "rounded_rect", "ellipse", "polygon", "star",
                          "zoom", "shear"):
            self.assertIn(slot_tool, _TOOL_YAML_ID_TO_ENUM)


if __name__ == "__main__":
    absltest.main()
