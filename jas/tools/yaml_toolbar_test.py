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
        anchors = []
        self._last_anchors = anchors

        # ``anchor`` mirrors dock_panel.run_behavior_effects' signature:
        # the cursor coords captured at the slot button's mouse_down are
        # threaded in so the non-modal flyout lands next to the cursor.
        # The renderer passes it as a keyword arg, so the stub must accept
        # it; we record it alongside the opened dialog id.
        def _runner(effects, eval_ctx, anchor=None):
            anchors.append(anchor)

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
        # mouse_down captured the cursor's screen coords and threaded a
        # (x, y) anchor into the runner so the flyout can be placed next
        # to the cursor (mirrors Rust page_coordinates -> DialogState.anchor).
        self.assertTrue(self._last_anchors, "runner received no call")
        anchor = self._last_anchors[-1]
        self.assertIsInstance(anchor, tuple)
        self.assertEqual(len(anchor), 2)

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


class ToolOptionsDispatchLookupTest(absltest.TestCase):
    """The bundle-driven active-tool -> options lookup (tool_options_dispatch)
    resolves each tool's tool_options_panel / _action / _dialog in priority
    order, entirely from bundle["tools"] (nothing hardcoded). This is the
    pure logic behind the toolbar dblclick; the actual panel/dialog opening
    is GUI (user-verified)."""

    def test_dialog_tools_resolve_to_dialog(self):
        from jas_app import tool_options_dispatch
        bundle = _load_bundle()
        cases = {
            "paintbrush": "paintbrush_tool_options",
            "blob_brush": "blob_brush_tool_options",
            "scale": "scale_options",
            "rotate": "rotate_options",
            "shear": "shear_options",
            "eyedropper": "eyedropper_tool_options",
        }
        for tool, dialog_id in cases.items():
            kind, target = tool_options_dispatch(bundle, tool)
            self.assertEqual(kind, "dialog", f"{tool} should dispatch a dialog")
            self.assertEqual(target, dialog_id)

    def test_action_tools_resolve_to_action(self):
        from jas_app import tool_options_dispatch
        bundle = _load_bundle()
        cases = {
            "hand": "fit_active_artboard",
            "zoom": "zoom_to_actual_size",
            "artboard": "fit_all_artboards",
        }
        for tool, action in cases.items():
            kind, target = tool_options_dispatch(bundle, tool)
            self.assertEqual(kind, "action", f"{tool} should dispatch an action")
            self.assertEqual(target, action)

    def test_panel_tool_resolves_to_panel(self):
        from jas_app import tool_options_dispatch
        bundle = _load_bundle()
        kind, target = tool_options_dispatch(bundle, "magic_wand")
        self.assertEqual(kind, "panel")
        self.assertEqual(target, "magic_wand")

    def test_tool_without_options_is_noop(self):
        from jas_app import tool_options_dispatch
        bundle = _load_bundle()
        # Selection / Pen / Rect declare no tool_options_* field.
        for tool in ("selection", "pen", "rect"):
            self.assertEqual(tool_options_dispatch(bundle, tool), (None, None))

    def test_unknown_or_empty_tool_is_noop(self):
        from jas_app import tool_options_dispatch
        bundle = _load_bundle()
        self.assertEqual(tool_options_dispatch(bundle, "not_a_tool"), (None, None))
        self.assertEqual(tool_options_dispatch(bundle, ""), (None, None))
        self.assertEqual(tool_options_dispatch(bundle, None), (None, None))

    def test_panel_action_dialog_priority(self):
        # If a (synthetic) tool ever declares more than one field, panel
        # wins over action wins over dialog — the documented priority.
        from jas_app import tool_options_dispatch
        bundle = {
            "tools": {
                "multi": {
                    "tool_options_panel": "p",
                    "tool_options_action": "a",
                    "tool_options_dialog": "d",
                }
            }
        }
        self.assertEqual(tool_options_dispatch(bundle, "multi"), ("panel", "p"))
        del bundle["tools"]["multi"]["tool_options_panel"]
        self.assertEqual(tool_options_dispatch(bundle, "multi"), ("action", "a"))
        del bundle["tools"]["multi"]["tool_options_action"]
        self.assertEqual(tool_options_dispatch(bundle, "multi"), ("dialog", "d"))

    def test_every_tool_options_field_resolves(self):
        # Read the options-bearing tools straight from the bundle (no
        # hardcoded list) and confirm each resolves to a non-empty target.
        from jas_app import tool_options_dispatch
        bundle = _load_bundle()
        seen = 0
        for tool_id, spec in (bundle.get("tools") or {}).items():
            if not isinstance(spec, dict):
                continue
            if any(k in spec for k in ("tool_options_panel",
                                       "tool_options_action",
                                       "tool_options_dialog")):
                kind, target = tool_options_dispatch(bundle, tool_id)
                self.assertIn(kind, ("panel", "action", "dialog"))
                self.assertTrue(target)
                seen += 1
        # The bundle ships several options-bearing tools; guard against a
        # regression that silently drops them all.
        self.assertGreaterEqual(seen, 6)


class ToolButtonDblClickTest(absltest.TestCase):
    """The dblclick is wired ONLY on toolbar tool buttons (is_tool_button:
    those carrying bind.checked over state.active_tool), reads the ACTIVE
    tool from the store, and calls ctx["_open_tool_options"] with it. Panels
    and other icon_buttons get no dblclick. The host callback's panel/dialog
    opening is GUI (user-verified); here we verify the wiring + active-tool
    read."""

    def _grid_widget(self, store, opened):
        grid = _tool_grid(_load_bundle())
        ctx = {"_panel_id": "toolbar_pane",
               "_open_tool_options": lambda t: opened.append(t)}
        return render_element(grid, store, ctx, dispatch_fn=lambda *_: None)

    def _dbl(self, btn):
        from PySide6.QtCore import QEvent, QPointF, Qt
        from PySide6.QtGui import QMouseEvent
        ev = QMouseEvent(QEvent.Type.MouseButtonDblClick,
                         QPointF(1, 1), QPointF(1, 1),
                         Qt.MouseButton.LeftButton, Qt.MouseButton.LeftButton,
                         Qt.KeyboardModifier.NoModifier)
        btn.mouseDoubleClickEvent(ev)

    def test_dblclick_any_tool_button_opens_active_tool_options(self):
        # Active tool = magic_wand; dblclicking ANY tool slot (here the
        # Selection button) must open the ACTIVE tool's options, not the
        # button's own tool.
        store, _ = _make_store(active_tool="magic_wand")
        opened = []
        widget = self._grid_widget(store, opened)
        sel = next(b for b in widget.findChildren(QPushButton)
                   if b.isCheckable())
        self._dbl(sel)
        self.assertEqual(opened, ["magic_wand"])

    def test_dblclick_reads_live_active_tool(self):
        store, _ = _make_store(active_tool="selection")
        opened = []
        widget = self._grid_widget(store, opened)
        btn = next(b for b in widget.findChildren(QPushButton)
                   if b.isCheckable())
        # Change the active tool after render; the dblclick must read the
        # live store value, not a value baked in at render time.
        store.set("active_tool", "paintbrush")
        self._dbl(btn)
        self.assertEqual(opened, ["paintbrush"])

    def test_tool_buttons_have_dblclick_override(self):
        store, _ = _make_store(active_tool="selection")
        opened = []
        widget = self._grid_widget(store, opened)
        # Every checkable (is_tool_button) slot must carry the per-instance
        # dblclick override (an attribute on the instance, not the class).
        checkable = [b for b in widget.findChildren(QPushButton)
                     if b.isCheckable()]
        self.assertTrue(checkable)
        for b in checkable:
            self.assertIn("mouseDoubleClickEvent", b.__dict__,
                          "tool button missing dblclick override")

    def test_no_callback_means_no_dblclick_override(self):
        # Without ctx["_open_tool_options"], even tool buttons get no
        # per-instance dblclick override (silent no-op).
        store, _ = _make_store(active_tool="selection")
        grid = _tool_grid(_load_bundle())
        widget = render_element(grid, store, {"_panel_id": "toolbar_pane"},
                                dispatch_fn=lambda *_: None)
        for b in widget.findChildren(QPushButton):
            self.assertNotIn("mouseDoubleClickEvent", b.__dict__)


class OpenToolOptionsHostDispatchTest(absltest.TestCase):
    """MainWindow._open_tool_options routes the bundle-resolved kind to the
    matching host path (panel show / action dispatch / dialog open). We stub
    the host so the routing is testable without a live window; the concrete
    panel/dialog/window opening is GUI (user-verified)."""

    class _Host:
        # Minimal stand-in carrying just the attributes _open_tool_options
        # touches, so we can drive the real method unbound.
        def __init__(self):
            self.dispatched = []
            self.shown_panels = []

            class _Dock:
                def __init__(self, outer):
                    self._outer = outer

                def _dispatch_yaml_action(self, name, params):
                    self._outer.dispatched.append((name, params))

                def rebuild_all(self):
                    pass

            self.dock_panel = _Dock(self)
            self.workspace_layout = object()
            self._yaml_state = None

        def _panel_id_to_kind(self, panel_id):
            from jas_app import MainWindow
            return MainWindow._panel_id_to_kind(panel_id)

    def test_action_tool_dispatches_through_dock(self):
        from jas_app import MainWindow
        host = self._Host()
        MainWindow._open_tool_options(host, "zoom")
        self.assertIn(("zoom_to_actual_size", {}), host.dispatched)

    def test_hand_tool_dispatches_fit_active_artboard(self):
        from jas_app import MainWindow
        host = self._Host()
        MainWindow._open_tool_options(host, "hand")
        self.assertIn(("fit_active_artboard", {}), host.dispatched)

    def test_noop_tool_dispatches_nothing(self):
        from jas_app import MainWindow
        host = self._Host()
        MainWindow._open_tool_options(host, "selection")
        self.assertEqual(host.dispatched, [])

    def test_panel_tool_does_not_hit_action_path(self):
        # Magic Wand resolves to a panel, so the action dispatcher must
        # not fire (the panel show path is GUI; here we just confirm the
        # action branch is skipped). We patch layout_apply via the panel
        # show being a no-op on the stub's object workspace_layout — the
        # call is harmless and dispatched stays empty.
        from jas_app import MainWindow
        host = self._Host()
        try:
            MainWindow._open_tool_options(host, "magic_wand")
        except Exception:
            # The real op_show_panel needs a live layout; the object stub
            # may raise. What matters for this test is that the ACTION
            # dispatcher was never reached.
            pass
        self.assertEqual(host.dispatched, [])


if __name__ == "__main__":
    absltest.main()
