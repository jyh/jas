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


class LongPressAlternatesTest(absltest.TestCase):
    """Long-press on a multi-tool slot opens its alternates flyout.

    The bundle slot buttons carry mouse_down -> start_timer (nested
    open_dialog <slot>_alternates) and mouse_up -> cancel_timer
    behaviors. These tests cover the renderer gap closed in
    yaml_renderer: mouse_down/mouse_up are now dispatched (previously
    only click/change were), so the long-press timer starts on press,
    cancels on a quick release, and its open_dialog reaches the right
    <slot>_alternates dialog id. The actual Qt flyout appearing is
    GUI-only (verified manually); here we unit-test the timer +
    dialog-state plumbing without a live display."""

    def setUp(self):
        # Each test starts from a clean TimerManager so a leftover
        # timer from a prior test cannot leak into the assertions.
        from panels.timer_manager import TimerManager
        tm = TimerManager.shared()
        for tid in list(tm._timers.keys()):
            tm.cancel_timer(tid)

    def _slot(self, slot_id):
        bundle = _load_bundle()
        grid = _tool_grid(bundle)
        return dict(_icon_buttons(grid))[slot_id]

    def _dock_ctx(self, store):
        """A ctx carrying a behavior-effects runner like the one the
        dock supplies: it registers start_timer / cancel_timer platform
        effects so the slot's mouse_down/up effects plumb through, and
        records every dialog id that open_dialog wrote (standing in for
        _check_dialog_opened, which is GUI-only)."""
        from panels.timer_manager import TimerManager
        from workspace_interpreter.effects import run_effects

        _WORKSPACE_JSON_ws = json.load(open(_WORKSPACE_JSON))
        ws_actions = _WORKSPACE_JSON_ws.get("actions", {})
        ws_dialogs = _WORKSPACE_JSON_ws.get("dialogs", {})
        opened = []

        def _runner(effects, eval_ctx):
            def handle_start_timer(data, c, s):
                timer_id = data.get("id", "") if isinstance(data, dict) else ""
                delay_ms = data.get("delay_ms", 250) if isinstance(data, dict) else 250
                nested = data.get("effects", []) if isinstance(data, dict) else []
                TimerManager.shared().start_timer(timer_id, delay_ms, lambda: (
                    run_effects(nested, c, s, actions=ws_actions,
                                dialogs=ws_dialogs),
                    opened.append(s.get_dialog_id()),
                ))

            def handle_cancel_timer(data, c, s):
                timer_id = data if isinstance(data, str) else ""
                TimerManager.shared().cancel_timer(timer_id)

            run_effects(effects, eval_ctx, store, actions=ws_actions,
                        dialogs=ws_dialogs, platform_effects={
                            "start_timer": handle_start_timer,
                            "cancel_timer": handle_cancel_timer,
                        })

        return {"_panel_id": "toolbar_pane",
                "_run_behavior_effects": _runner}, opened

    def test_mouse_down_starts_long_press_timer(self):
        from panels.timer_manager import TimerManager
        store, _bundle = _make_store(active_tool="selection")
        ctx, _opened = self._dock_ctx(store)
        btn = render_element(self._slot("btn_arrow_slot"), store, ctx,
                             dispatch_fn=lambda *_: None)
        # Press -> the named long-press timer must be pending.
        btn.pressed.emit()
        self.assertIn("long_press_btn_arrow_slot",
                      TimerManager.shared()._timers)

    def test_mouse_up_cancels_long_press_timer(self):
        from panels.timer_manager import TimerManager
        store, _bundle = _make_store(active_tool="selection")
        ctx, _opened = self._dock_ctx(store)
        btn = render_element(self._slot("btn_arrow_slot"), store, ctx,
                             dispatch_fn=lambda *_: None)
        btn.pressed.emit()
        self.assertIn("long_press_btn_arrow_slot",
                      TimerManager.shared()._timers)
        # A quick release cancels the pending timer — no stray timer,
        # no flyout.
        btn.released.emit()
        self.assertNotIn("long_press_btn_arrow_slot",
                         TimerManager.shared()._timers)

    def test_long_press_opens_arrow_alternates(self):
        from panels.timer_manager import TimerManager
        store, _bundle = _make_store(active_tool="selection")
        ctx, opened = self._dock_ctx(store)
        btn = render_element(self._slot("btn_arrow_slot"), store, ctx,
                             dispatch_fn=lambda *_: None)
        btn.pressed.emit()
        # Fire the pending timer directly (no real 250 ms wait) and
        # assert the nested open_dialog reached arrow_alternates.
        timer = TimerManager.shared()._timers.get("long_press_btn_arrow_slot")
        self.assertIsNotNone(timer)
        TimerManager.shared()._on_fire("long_press_btn_arrow_slot",
                                       timer.timeout.emit)
        self.assertEqual(store.get_dialog_id(), "arrow_alternates")
        self.assertEqual(opened[-1], "arrow_alternates")
        store.close_dialog()

    def test_each_multitool_slot_opens_its_alternates(self):
        # Every slot whose mouse_down nests open_dialog must reach the
        # matching <slot>_alternates dialog id.
        from panels.timer_manager import TimerManager
        for slot_id, dlg_id in (
                ("btn_arrow_slot", "arrow_alternates"),
                ("btn_pen_slot", "pen_alternates"),
                ("btn_pencil_slot", "pencil_alternates"),
                ("btn_text_slot", "text_alternates"),
                ("btn_shape_slot", "shape_alternates"),
                ("btn_transform_slot", "scale_alternates"),
                ("btn_hand_slot", "hand_alternates")):
            store, _bundle = _make_store(active_tool="selection")
            ctx, opened = self._dock_ctx(store)
            el = self._slot(slot_id)
            btn = render_element(el, store, ctx, dispatch_fn=lambda *_: None)
            btn.pressed.emit()
            timer = TimerManager.shared()._timers.get(
                f"long_press_{slot_id}")
            self.assertIsNotNone(timer, f"{slot_id} started no timer")
            TimerManager.shared()._on_fire(
                f"long_press_{slot_id}", timer.timeout.emit)
            self.assertEqual(store.get_dialog_id(), dlg_id,
                             f"{slot_id} should open {dlg_id}")
            store.close_dialog()

    def test_single_tool_button_has_no_mouse_handlers(self):
        # A plain single-tool slot (Selection) declares no mouse_down,
        # so pressing it must not start any timer.
        from panels.timer_manager import TimerManager
        store, _bundle = _make_store(active_tool="pen")
        ctx, _opened = self._dock_ctx(store)
        sel = self._slot("btn_selection")
        btn = render_element(sel, store, ctx, dispatch_fn=lambda *_: None)
        btn.pressed.emit()
        self.assertEqual(
            [t for t in TimerManager.shared()._timers
             if t.startswith("long_press_btn_selection")], [])


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
