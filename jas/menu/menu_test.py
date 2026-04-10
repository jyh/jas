from dataclasses import replace as dreplace

from absl.testing import absltest

from jas_app import MainWindow
from PySide6.QtWidgets import QApplication

from document.document import Document, ElementSelection
from document.model import Model
from geometry.element import (
    Color, Fill, Group, Layer, Rect, Stroke, Visibility,
)
from menu.menu import (
    _group_selection, _ungroup_selection, _ungroup_all,
    _lock_selection, _unlock_all,
    _hide_selection, _show_all,
    _is_svg,
)


def _make_rect(x=0, y=0, w=10, h=10):
    """Create a simple Rect with a fill."""
    return Rect(x=x, y=y, width=w, height=h,
                fill=Fill(color=Color(1, 0, 0)))


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


if __name__ == "__main__":
    absltest.main()
