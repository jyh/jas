"""Tests for the toolbar long-press tool-alternates FLYOUT positioning.

The toolbar's multi-tool slots open a non-modal ``<slot>_alternates``
dialog on a 250ms long-press. That flyout must appear NEXT TO the cursor
(the slot button), not centered in the window. Mirrors the Rust mechanism
(jas_dioxus dialog_view.rs): the at-cursor placement fires only when BOTH
``modal: false`` AND a runtime anchor (the cursor's screen coords captured
at the slot button's mouse_down) are present; modal dialogs with no anchor
stay centered.

These tests verify the Python (PySide6/Qt) port:

- A non-modal flyout dialog given an anchor places its top-left corner at
  the anchor coords (the cursor), not at Qt's default centered position.
- A non-modal flyout is a frameless Popup (compact bare container), matching
  Rust's ``show_title_bar = is_modal`` title-bar suppression.
- A modal dialog with NO anchor is left at Qt's default placement — it is
  NOT moved to the anchor, so the color picker / tool-options / print /
  artboard dialogs stay centered exactly as before.
"""

from __future__ import annotations

import os

from absl.testing import absltest
from PySide6.QtCore import Qt
from PySide6.QtGui import QGuiApplication
from PySide6.QtWidgets import QApplication

from panels.yaml_dialog_view import YamlDialogView
from workspace_interpreter.effects import run_effects
from workspace_interpreter.loader import load_workspace
from workspace_interpreter.state_store import StateStore

_WS_PATH = os.path.join(os.path.dirname(__file__), "..", "..", "workspace")


class ToolAlternatesFlyoutPositionTest(absltest.TestCase):

    @classmethod
    def setUpClass(cls):
        if not QApplication.instance():
            cls.app = QApplication([])
        else:
            cls.app = QApplication.instance()
        cls.ws = load_workspace(_WS_PATH)
        cls.dialogs = cls.ws.get("dialogs", {})

    def _open(self, dialog_id: str) -> StateStore:
        store = StateStore()
        run_effects([{"open_dialog": {"id": dialog_id}}], {}, store,
                    dialogs=self.dialogs)
        self.assertEqual(store.get_dialog_id(), dialog_id)
        return store

    # ── Non-modal flyout: placed AT the cursor ───────────────────────

    def test_flyout_is_non_modal(self):
        """tool_alternates.yaml sets modal: false — the precondition for
        the at-cursor branch (Rust: !is_modal AND anchor)."""
        store = self._open("arrow_alternates")
        dlg = YamlDialogView("arrow_alternates", store, anchor=(640, 480))
        self.assertFalse(dlg._is_modal)

    def test_flyout_renders_as_popup(self):
        """Non-modal flyout is a frameless Popup (compact bare container,
        no title bar) — mirrors Rust show_title_bar = is_modal."""
        store = self._open("arrow_alternates")
        dlg = YamlDialogView("arrow_alternates", store, anchor=(640, 480))
        wtype = dlg.windowFlags() & Qt.WindowType.WindowType_Mask
        self.assertEqual(wtype, Qt.WindowType.Popup)

    def test_flyout_positioned_at_anchor_not_centered(self):
        """The flyout's top-left corner is pinned to the anchor (cursor)
        coords, away from any centered position — NOT Qt's default."""
        # Pick an anchor well away from the screen centre so a centered
        # placement would be visibly different from the anchored one.
        geo = QGuiApplication.primaryScreen().availableGeometry()
        ax = geo.left() + 60
        ay = geo.top() + 60
        store = self._open("arrow_alternates")
        dlg = YamlDialogView("arrow_alternates", store, anchor=(ax, ay))
        dlg.show()
        self.app.processEvents()
        self.assertEqual(dlg.pos().x(), ax)
        self.assertEqual(dlg.pos().y(), ay)
        # And it is not sitting at the screen centre (the old behavior).
        centre_x = geo.left() + (geo.width() - dlg.width()) // 2
        self.assertNotEqual(dlg.pos().x(), centre_x)
        dlg.close()

    def test_flyout_clamped_on_screen_near_edge(self):
        """A long-press near the bottom-right edge keeps the flyout fully
        on-screen (grows up/left only enough to fit) — Qt's frameless
        Popup would otherwise run off the desktop."""
        geo = QGuiApplication.primaryScreen().availableGeometry()
        store = self._open("arrow_alternates")
        dlg = YamlDialogView("arrow_alternates", store,
                             anchor=(geo.right() - 5, geo.bottom() - 5))
        dlg.show()
        self.app.processEvents()
        self.assertLessEqual(dlg.pos().x() + dlg.width(), geo.right() + 1)
        self.assertLessEqual(dlg.pos().y() + dlg.height(), geo.bottom() + 1)
        dlg.close()

    # ── Modal dialogs: untouched, stay centered ──────────────────────

    def test_modal_dialog_not_repositioned(self):
        """A modal dialog (no anchor) keeps Qt's default centered-on-parent
        placement — it must NOT be moved to (0,0) or any anchor. Scoped
        strictly to modal:false flyouts."""
        store = self._open("boolean_options")
        dlg = YamlDialogView("boolean_options", store)  # no anchor
        self.assertTrue(dlg._is_modal)
        self.assertIsNone(dlg._anchor)
        dlg.show()
        self.app.processEvents()
        # The default placement is non-trivial (Qt centres it); the key
        # assertion is the flyout-positioning path did NOT run.
        self.assertFalse(dlg._anchor_applied)
        # Window type stays a real Dialog, not a Popup.
        wtype = dlg.windowFlags() & Qt.WindowType.WindowType_Mask
        self.assertEqual(wtype, Qt.WindowType.Dialog)
        dlg.close()

    def test_modal_dialog_with_no_anchor_ignores_positioning(self):
        """Even if a modal dialog were somehow handed an anchor, the
        positioning branch is gated on !is_modal, so it stays put."""
        store = self._open("boolean_options")
        dlg = YamlDialogView("boolean_options", store, anchor=(10, 10))
        dlg.show()
        self.app.processEvents()
        self.assertFalse(dlg._anchor_applied)
        # Not moved to the (10, 10) anchor.
        self.assertFalse(dlg.pos().x() == 10 and dlg.pos().y() == 10)
        dlg.close()


class FlyoutAnchorThreadingTest(absltest.TestCase):
    """The anchor (cursor coords captured at the slot button's mouse_down)
    must survive the path from ``run_behavior_effects`` through the
    long-press timer to ``_show_yaml_dialog`` — mirroring Rust threading
    the anchor through start_timer into the deferred open_dialog_at. A
    port that drops the anchor across the timer hop falls back to centered.
    """

    @classmethod
    def setUpClass(cls):
        if not QApplication.instance():
            cls.app = QApplication([])
        else:
            cls.app = QApplication.instance()

    def _make_widget(self):
        from workspace.dock_panel import DockPanelWidget
        from workspace.workspace_layout import DockEdge, WorkspaceLayout
        layout = WorkspaceLayout.default_layout()
        store = StateStore()
        return DockPanelWidget(layout, DockEdge.RIGHT,
                               get_model=lambda: None, state_store=store)

    def test_anchor_threads_immediate_open_dialog(self):
        """An immediate (non-timer) open_dialog batch forwards the anchor
        straight to _show_yaml_dialog."""
        w = self._make_widget()
        captured = {}
        w._show_yaml_dialog = lambda did, anchor=None: captured.update(
            id=did, anchor=anchor)
        w.run_behavior_effects(
            [{"open_dialog": {"id": "arrow_alternates"}}], {},
            anchor=(321, 654))
        self.assertEqual(captured.get("id"), "arrow_alternates")
        self.assertEqual(captured.get("anchor"), (321, 654))

    def test_anchor_survives_long_press_timer(self):
        """The anchor captured at press time is carried across the 250ms
        long-press timer into the deferred open_dialog (the live mouse
        event is gone by the time the timer fires)."""
        from panels.timer_manager import TimerManager
        from PySide6.QtCore import QEventLoop, QTimer
        w = self._make_widget()
        captured = {}
        w._show_yaml_dialog = lambda did, anchor=None: captured.update(
            id=did, anchor=anchor)
        # The arrow slot's mouse_down effects: a start_timer whose nested
        # effect opens the alternates flyout (mirrors layout.yaml).
        effects = [{
            "start_timer": {
                "id": "long_press_test_slot",
                "delay_ms": 20,
                "effects": [{"open_dialog": {"id": "arrow_alternates"}}],
            }
        }]
        w.run_behavior_effects(effects, {}, anchor=(111, 222))
        # Nothing yet — the timer hasn't fired.
        self.assertNotIn("anchor", captured)
        # Pump the event loop until the timer fires.
        loop = QEventLoop()
        QTimer.singleShot(80, loop.quit)
        loop.exec()
        TimerManager.shared().cancel_timer("long_press_test_slot")
        self.assertEqual(captured.get("id"), "arrow_alternates")
        self.assertEqual(captured.get("anchor"), (111, 222))


if __name__ == "__main__":
    absltest.main()
