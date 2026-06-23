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

    def test_flyout_renders_as_frameless_popover(self):
        """Non-modal flyout is a frameless borderless popover (compact bare
        container, no title bar) — mirrors Rust show_title_bar = is_modal.

        It is deliberately NOT a Qt.WindowType.Popup: a Popup's implicit
        mouse grab closes the window on the OPENING long-press release and
        hides it without clearing the store (blocking reopen). The flyout
        is a frameless Tool window dismissed by an explicit application
        event filter instead (see the dismiss-and-reopen test)."""
        store = self._open("arrow_alternates")
        dlg = YamlDialogView("arrow_alternates", store, anchor=(640, 480))
        flags = dlg.windowFlags()
        wtype = flags & Qt.WindowType.WindowType_Mask
        self.assertEqual(wtype, Qt.WindowType.Tool)
        self.assertTrue(bool(flags & Qt.WindowType.FramelessWindowHint))
        # Not a Popup (no implicit grab that would eat the opening release).
        self.assertNotEqual(wtype, Qt.WindowType.Popup)

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

    def test_flyout_is_compact_sized_to_content(self):
        """The non-modal flyout is a compact narrow icon column, NOT a
        wide ~380px box with the icons floating in empty space. Its
        items carry ``width: "100%"`` (Expanding) which, on a top-level
        QDialog with no width to fill, would otherwise stretch them to
        the platform's default minimum window width. The flyout must be
        pinned to its content's own sizeHint width instead. Mirrors the
        compact Swift/OCaml tool-alternate flyouts.
        """
        for did in ("arrow_alternates", "pen_alternates",
                    "pencil_alternates", "text_alternates",
                    "shape_alternates", "hand_alternates",
                    "scale_alternates"):
            store = self._open(did)
            dlg = YamlDialogView(did, store, anchor=(640, 480))
            content = dlg.layout().itemAt(0).widget()
            hint = content.sizeHint().width()
            dlg.show()
            self.app.processEvents()
            # Compact: comfortably under 200px (an icon-only column), and
            # exactly the content sizeHint — not a wide box.
            self.assertLess(
                dlg.width(), 200,
                f"{did} flyout is too wide ({dlg.width()}px) — should be a "
                f"compact icon column, not a wide empty box",
            )
            self.assertEqual(
                dlg.width(), hint,
                f"{did} flyout width {dlg.width()} != content sizeHint {hint}",
            )
            # Pinned to a fixed width (min == max) so it cannot re-expand.
            self.assertEqual(dlg.minimumWidth(), dlg.maximumWidth())
            dlg.close()

    def test_modal_dialog_keeps_declared_width(self):
        """The compact-width clamp is scoped to non-modal flyouts. A modal
        dialog that declares its own ``width`` keeps it — the flyout
        sizeHint clamp must not touch it."""
        store = self._open("boolean_options")
        dlg = YamlDialogView("boolean_options", store)  # modal, declares width
        self.assertTrue(dlg._is_modal)
        self.assertTrue(dlg._has_declared_width)
        dlg.show()
        self.app.processEvents()
        # boolean_options declares width: 360; it is not shrunk to a
        # narrow icon-column sizeHint.
        self.assertGreaterEqual(dlg.width(), 300)
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


class FlyoutOpenDismissReopenTest(absltest.TestCase):
    """End-to-end through the REAL open path (run_behavior_effects ->
    long-press timer -> _check_dialog_opened -> _show_yaml_dialog ->
    rebuild()): the non-modal flyout must (a) APPEAR (non-blocking),
    (b) dismiss on a GENUINE outside mouse-press but NOT on the opening
    long-press release, and (c) be re-openable afterward.

    Regression guard: a prior change shifted the non-modal branch from
    exec() to show() but left self.rebuild() running AFTER the show().
    The rebuild's toolbar re-render fired the freshly-shown popover's
    ``finished`` signal, tearing it down before it painted, so the flyout
    no longer appeared at all. The fix defers the show() to the next
    event-loop turn (so rebuild() finishes first) and dismisses via an
    application event filter rather than a Qt.Popup grab.
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
        w = DockPanelWidget(layout, DockEdge.RIGHT,
                            get_model=lambda: None, state_store=store)
        return w, store

    def _long_press_open(self, w, store, anchor):
        """Drive the real long-press path and pump until the flyout shows.

        Returns the live flyout dialog (w._flyout_dlg) once visible."""
        from PySide6.QtCore import QEventLoop, QTimer
        effects = [{
            "start_timer": {
                "id": "long_press_btn_arrow_slot",
                "delay_ms": 10,
                "effects": [{"open_dialog": {"id": "arrow_alternates"}}],
            }
        }]
        w.run_behavior_effects(effects, {}, anchor=anchor)
        # Pump until the 10ms long-press timer fires AND the deferred
        # (singleShot(0)) show() has run.
        loop = QEventLoop()
        QTimer.singleShot(60, loop.quit)
        loop.exec()
        self.app.processEvents()
        return getattr(w, "_flyout_dlg", None)

    def test_flyout_appears_via_real_path(self):
        """After a long-press the flyout is visible and non-modal, and the
        store still holds the dialog id (rebuild did not tear it down)."""
        w, store = self._make_widget()
        dlg = self._long_press_open(w, store, anchor=(200, 200))
        self.assertIsNotNone(dlg, "flyout was never created/shown")
        self.assertTrue(dlg.isVisible(), "flyout did not appear")
        self.assertFalse(dlg.isModal(), "flyout must be non-modal")
        self.assertEqual(store.get_dialog_id(), "arrow_alternates")
        dlg.close()
        self.app.processEvents()

    def test_outside_press_dismisses_but_opening_release_does_not(self):
        """The opening long-press RELEASE must not close the flyout; a
        later GENUINE outside mouse-press must. After dismissal the store's
        dialog id is cleared so the flyout can reopen."""
        from PySide6.QtCore import QEvent, QPoint, QPointF
        from PySide6.QtGui import QMouseEvent
        w, store = self._make_widget()
        dlg = self._long_press_open(w, store, anchor=(200, 200))
        self.assertTrue(dlg.isVisible())

        app = self.app

        def send(etype, global_pt):
            gp = QPointF(global_pt)
            ev = QMouseEvent(etype, QPointF(0, 0), gp,
                             Qt.LeftButton, Qt.LeftButton, Qt.NoModifier)
            app.sendEvent(app, ev)
            app.processEvents()

        # 1) The opening long-press release (the button was held through
        #    the long-press). It must NOT dismiss the flyout — it only arms.
        send(QEvent.Type.MouseButtonRelease, QPoint(200, 200))
        self.assertTrue(
            dlg.isVisible(),
            "opening long-press release wrongly dismissed the flyout")
        self.assertEqual(store.get_dialog_id(), "arrow_alternates")

        # 2) A genuine mouse PRESS well outside the flyout geometry must
        #    dismiss it and clear the store dialog id.
        geo = dlg.frameGeometry()
        outside = QPoint(geo.right() + 200, geo.bottom() + 200)
        self.assertFalse(geo.contains(outside))
        send(QEvent.Type.MouseButtonPress, outside)
        self.assertFalse(dlg.isVisible(), "outside press did not dismiss")
        self.assertIsNone(
            store.get_dialog_id(),
            "store dialog id not cleared on dismiss — reopen would be blocked")

        # 3) Reopen: a fresh long-press opens the same flyout again.
        dlg2 = self._long_press_open(w, store, anchor=(300, 300))
        self.assertIsNotNone(dlg2, "flyout did not reopen")
        self.assertTrue(dlg2.isVisible(), "reopened flyout not visible")
        self.assertFalse(dlg2.isModal())
        self.assertEqual(store.get_dialog_id(), "arrow_alternates")
        dlg2.close()
        self.app.processEvents()

    def test_inside_press_does_not_dismiss(self):
        """A mouse press INSIDE the flyout (an item pick) must not be
        treated as an outside dismissal."""
        from PySide6.QtCore import QEvent, QPoint, QPointF
        from PySide6.QtGui import QMouseEvent
        w, store = self._make_widget()
        dlg = self._long_press_open(w, store, anchor=(200, 200))
        self.assertTrue(dlg.isVisible())
        app = self.app
        # Arm via the opening release, then press inside the flyout.
        for etype, pt in (
            (QEvent.Type.MouseButtonRelease, QPoint(200, 200)),
            (QEvent.Type.MouseButtonPress, dlg.frameGeometry().center()),
        ):
            ev = QMouseEvent(etype, QPointF(0, 0), QPointF(pt),
                             Qt.LeftButton, Qt.LeftButton, Qt.NoModifier)
            app.sendEvent(app, ev)
            app.processEvents()
        self.assertTrue(dlg.isVisible(),
                        "press inside the flyout wrongly dismissed it")
        self.assertEqual(store.get_dialog_id(), "arrow_alternates")
        dlg.close()
        self.app.processEvents()


if __name__ == "__main__":
    absltest.main()
