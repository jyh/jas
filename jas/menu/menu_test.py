from dataclasses import replace as dreplace

from absl.testing import absltest

from jas_app import MainWindow
from PySide6.QtWidgets import QApplication

from document.document import Document, ElementSelection
from document.model import Model
from geometry.element import (
    RgbColor, Fill, Group, Layer, Rect, Stroke, Visibility,
)
import menu.menu as menu_module
from menu.menu import (
    _group_selection, _ungroup_selection, _ungroup_all,
    _lock_selection, _unlock_all,
    _hide_selection, _show_all,
    _link_to_selection,
    _delete_selection,
    _cut_selection,
    _orphan_warning_body,
    _is_svg,
)


def _make_rect(x=0, y=0, w=10, h=10):
    """Create a simple Rect with a fill."""
    return Rect(x=x, y=y, width=w, height=h,
                fill=Fill(color=RgbColor(1, 0, 0)))


def _make_model_with_rects(n=2):
    """Create a Model with n rects in one layer, all selected."""
    rects = tuple(_make_rect(x=i * 20) for i in range(n))
    layer = Layer(children=rects, name="L0")
    selection = frozenset(
        ElementSelection.all((0, i)) for i in range(n)
    )
    doc = Document(layers=(layer,), selection=selection)
    return Model(document=doc)


class MenubarTest(absltest.TestCase):
    """Test the menubar structure in MainWindow."""

    @classmethod
    def setUpClass(cls):
        if not QApplication.instance():
            cls.app = QApplication([])
        else:
            cls.app = QApplication.instance()

    def setUp(self):
        self.window = MainWindow()

    def test_menubar_exists(self):
        menubar = self.window.menuBar()
        self.assertIsNotNone(menubar)

    def test_menubar_has_five_menus(self):
        menubar = self.window.menuBar()
        menu_actions = menubar.actions()
        self.assertEqual(len(menu_actions), 5)

    def test_menu_titles(self):
        menubar = self.window.menuBar()
        menu_actions = menubar.actions()
        menu_texts = [action.text() for action in menu_actions]
        self.assertEqual(menu_texts, ["&File", "&Edit", "&Object", "&View", "&Window"])

    def test_file_menu_exists(self):
        menubar = self.window.menuBar()
        file_action = menubar.actions()[0]
        file_menu = file_action.menu()
        self.assertIsNotNone(file_menu)

    def test_edit_menu_exists(self):
        menubar = self.window.menuBar()
        edit_action = menubar.actions()[1]
        edit_menu = edit_action.menu()
        self.assertIsNotNone(edit_menu)

    def test_view_menu_exists(self):
        menubar = self.window.menuBar()
        view_action = menubar.actions()[2]
        view_menu = view_action.menu()
        self.assertIsNotNone(view_menu)


class IsSvgTest(absltest.TestCase):
    """Tests for the _is_svg helper."""

    def test_svg_tag_returns_true(self):
        self.assertTrue(_is_svg("<svg></svg>"))

    def test_plain_text_returns_false(self):
        self.assertFalse(_is_svg("hello world"))

    def test_empty_string_returns_false(self):
        self.assertFalse(_is_svg(""))

    def test_xml_declaration_returns_true(self):
        self.assertTrue(_is_svg('<?xml version="1.0"?>'))


class GroupSelectionTest(absltest.TestCase):
    """Tests for _group_selection."""

    def test_group_two_rects(self):
        model = _make_model_with_rects(2)
        _group_selection(model)
        doc = model.document
        # Should have exactly 1 child in the layer now (the group)
        self.assertEqual(len(doc.layers[0].children), 1)
        group = doc.layers[0].children[0]
        self.assertIsInstance(group, Group)
        self.assertEqual(len(group.children), 2)


class UngroupSelectionTest(absltest.TestCase):
    """Tests for _ungroup_selection."""

    def test_ungroup_restores_children(self):
        model = _make_model_with_rects(2)
        _group_selection(model)
        # Now the group should be selected; ungroup it
        _ungroup_selection(model)
        doc = model.document
        self.assertEqual(len(doc.layers[0].children), 2)
        for child in doc.layers[0].children:
            self.assertIsInstance(child, Rect)


class UngroupAllTest(absltest.TestCase):
    """Tests for _ungroup_all (recursive ungrouping)."""

    def test_ungroup_all_flattens(self):
        r1, r2, r3 = _make_rect(x=0), _make_rect(x=20), _make_rect(x=40)
        inner = Group(children=(r2, r3))
        outer = Group(children=(r1, inner))
        layer = Layer(children=(outer,), name="L0")
        model = Model(document=Document(layers=(layer,)))
        _ungroup_all(model)
        doc = model.document
        # All groups should be flattened; 3 rects remain
        self.assertEqual(len(doc.layers[0].children), 3)
        for child in doc.layers[0].children:
            self.assertIsInstance(child, Rect)


class LockUnlockTest(absltest.TestCase):
    """Tests for _lock_selection / _unlock_all."""

    def test_lock_selection_locks_and_clears(self):
        model = _make_model_with_rects(2)
        _lock_selection(model)
        doc = model.document
        # Selection should be cleared
        self.assertEqual(len(doc.selection), 0)
        # Both elements should be locked
        for child in doc.layers[0].children:
            self.assertTrue(child.locked)

    def test_unlock_all_unlocks(self):
        model = _make_model_with_rects(2)
        _lock_selection(model)
        _unlock_all(model)
        doc = model.document
        for child in doc.layers[0].children:
            self.assertFalse(child.locked)


class HideShowTest(absltest.TestCase):
    """Tests for _hide_selection / _show_all."""

    def test_hide_selection_makes_invisible(self):
        model = _make_model_with_rects(2)
        _hide_selection(model)
        doc = model.document
        # Selection should be cleared
        self.assertEqual(len(doc.selection), 0)
        # Both elements should be invisible
        for child in doc.layers[0].children:
            self.assertEqual(child.visibility, Visibility.INVISIBLE)

    def test_show_all_restores_visibility(self):
        model = _make_model_with_rects(2)
        _hide_selection(model)
        _show_all(model)
        doc = model.document
        for child in doc.layers[0].children:
            self.assertEqual(child.visibility, Visibility.PREVIEW)


class OrphanWarningBodyTest(absltest.TestCase):
    """The reference-aware orphan warning body uses verbatim wording
    (identical across all apps) with singular/plural ``instance(s)``.
    The leading verb is supplied by the caller (Deleting / Cutting)."""

    def test_singular(self):
        self.assertEqual(
            _orphan_warning_body(1, "Deleting"),
            "Deleting will leave 1 live instance empty.")

    def test_plural(self):
        self.assertEqual(
            _orphan_warning_body(3, "Deleting"),
            "Deleting will leave 3 live instances empty.")

    def test_cut_verb_singular(self):
        self.assertEqual(
            _orphan_warning_body(1, "Cutting"),
            "Cutting will leave 1 live instance empty.")

    def test_cut_verb_plural(self):
        self.assertEqual(
            _orphan_warning_body(3, "Cutting"),
            "Cutting will leave 3 live instances empty.")


class DeleteSelectionTest(absltest.TestCase):
    """Tests for _delete_selection (reference-aware warn-then-orphan).

    No-orphan deletes proceed silently (unchanged behavior); deletes
    that would orphan a live reference go through a modal confirm whose
    OK proceeds and whose Cancel aborts (no snapshot, no delete).
    """

    def _model_target_and_ref(self):
        """A layer with a referenced rect [0,0] and one live reference
        [0,1] pointing at it; only the target rect is selected. Deleting
        the target would orphan the surviving reference."""
        from geometry.element import ReferenceElem
        target = Rect(x=0, y=0, width=10, height=10, id="t1",
                      fill=Fill(color=RgbColor(1, 0, 0)))
        ref = ReferenceElem(target="t1", id="r1")
        layer = Layer(children=(target, ref), name="L0")
        doc = Document(
            layers=(layer,),
            selection=frozenset({ElementSelection.all((0, 0))}))
        return Model(document=doc)

    def test_no_selection_is_noop(self):
        doc = Document(layers=(Layer(children=(), name="L0"),))
        model = Model(document=doc)
        _delete_selection(model)
        self.assertEqual(len(model.document.layers[0].children), 0)

    def test_no_orphans_deletes_without_dialog(self):
        # Two plain rects, both selected, no references anywhere: delete
        # proceeds with no dialog (unchanged behavior).
        model = _make_model_with_rects(2)
        called = []
        orig = menu_module.QMessageBox.question
        menu_module.QMessageBox.question = staticmethod(
            lambda *a, **k: called.append(a) or menu_module.QMessageBox.Ok)
        try:
            _delete_selection(model)
        finally:
            menu_module.QMessageBox.question = orig
        self.assertEqual(called, [])  # no dialog shown
        self.assertEqual(len(model.document.layers[0].children), 0)

    def test_orphan_cancel_aborts(self):
        model = self._model_target_and_ref()
        orig = menu_module.QMessageBox.question
        menu_module.QMessageBox.question = staticmethod(
            lambda *a, **k: menu_module.QMessageBox.Cancel)
        try:
            _delete_selection(model)
        finally:
            menu_module.QMessageBox.question = orig
        # Aborted: target still present, nothing deleted.
        self.assertEqual(len(model.document.layers[0].children), 2)

    def test_orphan_ok_deletes(self):
        model = self._model_target_and_ref()
        captured = {}
        orig = menu_module.QMessageBox.question

        def _fake_question(parent, title, body, *a, **k):
            captured["title"] = title
            captured["body"] = body
            return menu_module.QMessageBox.Ok
        menu_module.QMessageBox.question = staticmethod(_fake_question)
        try:
            _delete_selection(model)
        finally:
            menu_module.QMessageBox.question = orig
        # Confirmed: the target rect was deleted; the reference remains.
        self.assertEqual(len(model.document.layers[0].children), 1)
        self.assertEqual(captured["title"], "Delete")
        self.assertEqual(
            captured["body"], "Deleting will leave 1 live instance empty.")


class CutSelectionTest(absltest.TestCase):
    """Tests for _cut_selection (reference-aware warn-then-orphan).

    Cut = copy-to-clipboard + delete the selection, so it can orphan
    live references exactly like delete. No-orphan cuts proceed silently
    (unchanged behavior: copy + snapshot + delete); cuts that would
    orphan a live reference go through a modal confirm whose OK proceeds
    and whose Cancel aborts (no snapshot, no delete).
    """

    def _model_target_and_ref(self):
        """A layer with a referenced rect [0,0] and one live reference
        [0,1] pointing at it; only the target rect is selected. Cutting
        the target would orphan the surviving reference."""
        from geometry.element import ReferenceElem
        target = Rect(x=0, y=0, width=10, height=10, id="t1",
                      fill=Fill(color=RgbColor(1, 0, 0)))
        ref = ReferenceElem(target="t1", id="r1")
        layer = Layer(children=(target, ref), name="L0")
        doc = Document(
            layers=(layer,),
            selection=frozenset({ElementSelection.all((0, 0))}))
        return Model(document=doc)

    def test_no_orphans_cuts_without_dialog(self):
        # Two plain rects, both selected, no references anywhere: cut
        # proceeds with no dialog (unchanged behavior).
        model = _make_model_with_rects(2)
        called = []
        orig_q = menu_module.QMessageBox.question
        orig_clip = menu_module.QApplication.clipboard
        menu_module.QMessageBox.question = staticmethod(
            lambda *a, **k: called.append(a) or menu_module.QMessageBox.Ok)
        menu_module.QApplication.clipboard = staticmethod(
            lambda: _FakeClipboard())
        try:
            _cut_selection(model)
        finally:
            menu_module.QMessageBox.question = orig_q
            menu_module.QApplication.clipboard = orig_clip
        self.assertEqual(called, [])  # no dialog shown
        self.assertEqual(len(model.document.layers[0].children), 0)

    def test_orphan_cancel_aborts(self):
        model = self._model_target_and_ref()
        orig_q = menu_module.QMessageBox.question
        orig_clip = menu_module.QApplication.clipboard
        clip = _FakeClipboard()
        menu_module.QMessageBox.question = staticmethod(
            lambda *a, **k: menu_module.QMessageBox.Cancel)
        menu_module.QApplication.clipboard = staticmethod(lambda: clip)
        try:
            _cut_selection(model)
        finally:
            menu_module.QMessageBox.question = orig_q
            menu_module.QApplication.clipboard = orig_clip
        # Aborted: target still present, nothing deleted, clipboard
        # untouched.
        self.assertEqual(len(model.document.layers[0].children), 2)
        self.assertIsNone(clip.text_set)

    def test_orphan_ok_cuts(self):
        model = self._model_target_and_ref()
        captured = {}
        clip = _FakeClipboard()
        orig_q = menu_module.QMessageBox.question
        orig_clip = menu_module.QApplication.clipboard

        def _fake_question(parent, title, body, *a, **k):
            captured["title"] = title
            captured["body"] = body
            return menu_module.QMessageBox.Ok
        menu_module.QMessageBox.question = staticmethod(_fake_question)
        menu_module.QApplication.clipboard = staticmethod(lambda: clip)
        try:
            _cut_selection(model)
        finally:
            menu_module.QMessageBox.question = orig_q
            menu_module.QApplication.clipboard = orig_clip
        # Confirmed: the target rect was cut (deleted); reference remains.
        self.assertEqual(len(model.document.layers[0].children), 1)
        self.assertEqual(captured["title"], "Cut")
        self.assertEqual(
            captured["body"], "Cutting will leave 1 live instance empty.")
        # The selection was copied to the clipboard.
        self.assertIsNotNone(clip.text_set)


class _FakeClipboard:
    """Minimal stand-in for QApplication.clipboard() used by cut tests:
    records whatever text the copy step writes (None if nothing was)."""

    def __init__(self):
        self.text_set = None

    def setText(self, text):
        self.text_set = text


class LinkToSelectionTest(absltest.TestCase):
    """Tests for _link_to_selection (the Make Instance handler).

    Mirrors the Rust make_instance_creates_offset_selected_reference
    test: a single whole-element selection yields a reference targeting
    the source's id, offset by (PASTE_OFFSET, PASTE_OFFSET) via its
    transform and selected; the source keeps its position; the whole
    gesture is one snapshot (one undo).
    """

    def _single_selection_model(self):
        """A model with one rect at [0,0], selected as a whole."""
        rect = _make_rect(x=0, y=0)
        layer = Layer(children=(rect,), name="L0")
        doc = Document(
            layers=(layer,),
            selection=frozenset({ElementSelection.all((0, 0))}))
        return Model(document=doc)

    def test_make_instance_creates_offset_selected_reference(self):
        from geometry.element import ReferenceElem
        from tools.tool import PASTE_OFFSET
        model = self._single_selection_model()
        _link_to_selection(model)
        doc = model.document
        # Source rect untouched at (0, 0); it gained a stable id.
        source = doc.get_element((0, 0))
        self.assertIsInstance(source, Rect)
        self.assertEqual((source.x, source.y), (0.0, 0.0))
        self.assertIsNotNone(source.id)
        # A reference was appended at [0,1], targeting the source's id,
        # offset by (PASTE_OFFSET, PASTE_OFFSET) on its transform.
        ref = doc.get_element((0, 1))
        self.assertIsInstance(ref, ReferenceElem)
        self.assertEqual(ref.target, source.id)
        self.assertIsNotNone(ref.id)
        self.assertNotEqual(ref.id, source.id)
        self.assertIsNotNone(ref.transform)
        self.assertEqual(
            (ref.transform.e, ref.transform.f),
            (PASTE_OFFSET, PASTE_OFFSET))
        # The reference is the (single, whole-element) selection.
        self.assertEqual(len(doc.selection), 1)
        es = next(iter(doc.selection))
        self.assertEqual(es.path, (0, 1))
        # One snapshot => one undo restores the pre-gesture state.
        model.undo()
        doc = model.document
        self.assertEqual(len(doc.layers[0].children), 1)
        self.assertIsInstance(doc.layers[0].children[0], Rect)

    def test_make_instance_noop_without_single_selection(self):
        # Two selected elements: not a single-element selection, so the
        # gesture is a no-op (no reference appended).
        model = _make_model_with_rects(2)
        _link_to_selection(model)
        doc = model.document
        self.assertEqual(len(doc.layers[0].children), 2)
        for child in doc.layers[0].children:
            self.assertIsInstance(child, Rect)

    def test_make_instance_noop_on_partial_selection(self):
        # A control-point sub-selection (kind=partial) is not a whole-
        # element selection, so Make Instance is a no-op.
        rect = _make_rect(x=0, y=0)
        layer = Layer(children=(rect,), name="L0")
        doc = Document(
            layers=(layer,),
            selection=frozenset({ElementSelection.partial((0, 0), [0])}))
        model = Model(document=doc)
        _link_to_selection(model)
        self.assertEqual(len(model.document.layers[0].children), 1)


if __name__ == "__main__":
    absltest.main()
