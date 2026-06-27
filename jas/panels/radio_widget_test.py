"""Tests for the `radio` widget in panels/yaml_renderer.py.

The transform option dialogs (Scale / Shear) use a bare `radio` widget for
their mode selector (Uniform / Non-Uniform; Horizontal / Vertical / Custom):
a circular indicator filled when `bind.checked` is truthy, plus a label, that
runs its `on_check` effects on click. None of the apps implemented `radio`
before this — it fell through to a placeholder, so the dialogs rendered
without a mode selector.

Also covers the companion fix: `set: { dialog.X: ... }` must route to the
DIALOG scope (set_by_scoped_target gained a `dialog.` arm) so the radio's
on_check actually switches modes (it previously wrote a bogus global key).
"""
from __future__ import annotations

from absl.testing import absltest
from PySide6.QtWidgets import QApplication, QWidget, QLabel

from panels.yaml_renderer import render_element
from workspace_interpreter.state_store import StateStore
from workspace_interpreter.effects import run_effects, _set_by_scoped_target


class _Dispatch:
    def __call__(self, action, params):  # minimal dispatch_fn
        pass


class DialogSetRoutingTest(absltest.TestCase):
    """set: { dialog.X } routes to the dialog scope, not global state."""

    def _store(self):
        store = StateStore()
        store.init_dialog("scale_options", {"uniform": True})
        return store

    def test_set_by_scoped_target_routes_dialog(self):
        store = self._store()
        _set_by_scoped_target(store, "dialog.uniform", False)
        self.assertEqual(store.get_dialog("uniform"), False)
        # The bogus global key must NOT be written.
        self.assertIsNone(store.get("dialog.uniform"))

    def test_run_effects_set_dialog(self):
        # Set values are expression strings (the dialog convention; a bare
        # YAML bool stringifies to "True"/"False" which the expr lang rejects).
        store = self._store()
        run_effects([{"set": {"dialog.uniform": "false"}}],
                    store.eval_context({}), store)
        self.assertEqual(store.get_dialog("uniform"), False)

    def test_set_dialog_noop_without_open_dialog(self):
        store = StateStore()  # no dialog open
        _set_by_scoped_target(store, "dialog.uniform", False)  # must not raise
        self.assertIsNone(store.get_dialog("uniform"))


class RadioWidgetTest(absltest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def _store(self, uniform=True):
        store = StateStore()
        store.init_dialog("scale_options", {"uniform": uniform})
        return store

    def _radio(self, checked_expr, set_value, disabled=None):
        # set_value is an expression STRING ("true" / "false"), matching the
        # bundle convention (see scale_options.yaml on_check).
        el = {
            "type": "radio",
            "label": "Uniform:",
            "bind": {"checked": checked_expr},
            "on_check": [{"set": {"dialog.uniform": set_value}}],
        }
        if disabled is not None:
            el["bind"]["disabled"] = disabled
        return el

    def _click(self, widget):
        from PySide6.QtCore import Qt, QPoint, QEvent
        from PySide6.QtGui import QMouseEvent
        ev = QMouseEvent(QEvent.Type.MouseButtonPress, QPoint(2, 2),
                         Qt.MouseButton.LeftButton, Qt.MouseButton.LeftButton,
                         Qt.KeyboardModifier.NoModifier)
        widget.mousePressEvent(ev)

    def test_renders_a_real_widget_not_placeholder(self):
        store = self._store(True)
        w = render_element(self._radio("dialog.uniform", True), store, {}, _Dispatch())
        self.assertIsInstance(w, QWidget)
        # The label is rendered as a child QLabel (proves it is the radio, not
        # the placeholder fallback).
        labels = [l.text() for l in w.findChildren(QLabel)]
        self.assertIn("Uniform:", labels)

    def test_click_runs_on_check_and_switches_mode(self):
        store = self._store(True)
        # The Non-Uniform radio: checked when NOT uniform, sets uniform=False.
        w = render_element(self._radio("not dialog.uniform", "false"), store, {}, _Dispatch())
        self.assertEqual(store.get_dialog("uniform"), True)
        self._click(w)
        self.assertEqual(store.get_dialog("uniform"), False)

    def test_disabled_radio_does_not_switch(self):
        store = self._store(True)
        w = render_element(
            self._radio("not dialog.uniform", "false", disabled="true"),
            store, {}, _Dispatch())
        self._click(w)
        self.assertEqual(store.get_dialog("uniform"), True)  # unchanged


if __name__ == "__main__":
    absltest.main()
