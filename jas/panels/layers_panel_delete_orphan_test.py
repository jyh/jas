"""Tests for the Layers-panel delete reference-aware orphan confirm
(REFERENCE_GRAPH.md warn-then-orphan), extended from the main Edit>Delete.

Deleting elements from the Layers panel can orphan live references
(instances) exactly like the main Delete. Both panel delete sub-paths (the
context-menu "Delete Selection" item and the in-panel keyboard
Delete/Backspace) route through ``_confirm_panel_delete_if_orphans``, which
computes the SAME pinned predicate ``orphaned_references(doc, deletion_paths)``
on the PANEL selection (not ``doc.selection``):

- empty  -> proceed silently (True), no dialog (unchanged behavior);
- non-empty -> modal confirm with the safe-Cancel default; True only on Ok.

Wording reuses ``menu._orphan_warning_body`` so the body reads
"Deleting will leave N live instance(s) empty." identically to the main delete.
"""

from absl.testing import absltest

from PySide6.QtWidgets import QApplication

from document.document import Document, ElementSelection
from document.model import Model
from geometry.element import (
    RgbColor, Fill, Layer, Rect, ReferenceElem,
)
from panels.yaml_renderer import _confirm_panel_delete_if_orphans


def _make_rect(x=0, y=0, w=10, h=10, id=None):
    return Rect(x=x, y=y, width=w, height=h, id=id,
                fill=Fill(color=RgbColor(1, 0, 0)))


class ConfirmPanelDeleteIfOrphansTest(absltest.TestCase):
    """The panel-delete guard mirrors menu._confirm_delete_if_orphans but on
    the panel selection paths supplied by the caller."""

    @classmethod
    def setUpClass(cls):
        if not QApplication.instance():
            cls.app = QApplication([])
        else:
            cls.app = QApplication.instance()

    def _model_target_and_ref(self):
        """A layer with a referenced rect [0,0] and one live reference [0,1]
        pointing at it. Deleting the target would orphan the surviving
        reference."""
        target = _make_rect(id="t1")
        ref = ReferenceElem(target="t1", id="r1")
        layer = Layer(children=(target, ref), name="L0")
        # doc.selection deliberately EMPTY: the predicate must run on the
        # PANEL selection passed to the guard, not on doc.selection.
        doc = Document(layers=(layer,), selection=frozenset())
        return Model(document=doc)

    def test_no_orphans_returns_true_without_dialog(self):
        # Two plain rects, no references: empty orphan set -> proceed silently.
        layer = Layer(children=(_make_rect(), _make_rect(x=20)), name="L0")
        model = Model(document=Document(layers=(layer,)))
        called = []
        from PySide6.QtWidgets import QMessageBox
        orig_q = QMessageBox.question
        QMessageBox.question = staticmethod(
            lambda *a, **k: called.append(a) or QMessageBox.Ok)
        try:
            result = _confirm_panel_delete_if_orphans(
                model, [(0, 0), (0, 1)])
        finally:
            QMessageBox.question = orig_q
        self.assertTrue(result)
        self.assertEqual(called, [])  # no dialog shown

    def test_orphan_cancel_returns_false(self):
        model = self._model_target_and_ref()
        from PySide6.QtWidgets import QMessageBox
        orig_q = QMessageBox.question
        QMessageBox.question = staticmethod(lambda *a, **k: QMessageBox.Cancel)
        try:
            # Panel selection = the target only.
            result = _confirm_panel_delete_if_orphans(model, [(0, 0)])
        finally:
            QMessageBox.question = orig_q
        self.assertFalse(result)

    def test_orphan_ok_returns_true_with_delete_wording(self):
        model = self._model_target_and_ref()
        captured = {}
        from PySide6.QtWidgets import QMessageBox
        orig_q = QMessageBox.question

        def _fake_question(parent, title, body, *a, **k):
            captured["title"] = title
            captured["body"] = body
            return QMessageBox.Ok
        QMessageBox.question = staticmethod(_fake_question)
        try:
            result = _confirm_panel_delete_if_orphans(model, [(0, 0)])
        finally:
            QMessageBox.question = orig_q
        self.assertTrue(result)
        self.assertEqual(captured["title"], "Delete")
        self.assertEqual(
            captured["body"], "Deleting will leave 1 live instance empty.")

    def test_predicate_uses_panel_paths_not_doc_selection(self):
        # doc.selection is empty but panel selection targets the referenced
        # element: the guard must still detect the orphan (proving it uses the
        # passed paths, not doc.selection).
        model = self._model_target_and_ref()
        self.assertEqual(len(model.document.selection), 0)
        seen = {}
        from PySide6.QtWidgets import QMessageBox
        orig_q = QMessageBox.question

        def _fake_question(parent, title, body, *a, **k):
            seen["body"] = body
            return QMessageBox.Cancel
        QMessageBox.question = staticmethod(_fake_question)
        try:
            result = _confirm_panel_delete_if_orphans(model, [(0, 0)])
        finally:
            QMessageBox.question = orig_q
        self.assertFalse(result)
        self.assertEqual(
            seen["body"], "Deleting will leave 1 live instance empty.")

    def test_deleting_target_and_its_only_ref_is_silent(self):
        # Panel selection includes BOTH the target and its only referrer:
        # nothing survives to be orphaned -> empty set -> proceed silently.
        model = self._model_target_and_ref()
        called = []
        from PySide6.QtWidgets import QMessageBox
        orig_q = QMessageBox.question
        QMessageBox.question = staticmethod(
            lambda *a, **k: called.append(a) or QMessageBox.Ok)
        try:
            result = _confirm_panel_delete_if_orphans(
                model, [(0, 0), (0, 1)])
        finally:
            QMessageBox.question = orig_q
        self.assertTrue(result)
        self.assertEqual(called, [])


if __name__ == "__main__":
    absltest.main()
