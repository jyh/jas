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


class BuildMenuModelTest(absltest.TestCase):
    """The menu bar is projected from the compiled bundle ``menubar``
    (menubar.yaml) so it can never drift from the spec. These tests pin
    the projected render model. Mirrors the Rust ``menu.rs`` model tests.
    """

    def _model(self):
        from menu.menu_model import build_menu_model
        return build_menu_model()

    def _actions(self, menu):
        from menu.menu_model import MenuAction
        return [e.action for e in menu.entries if isinstance(e, MenuAction)]

    def _find(self, model, label):
        return next(m for m in model if m.label == label)

    def test_model_has_five_menus_with_ampersand_titles(self):
        # Titles keep the & mnemonic markers verbatim (Qt consumes &).
        model = self._model()
        labels = [m.label for m in model]
        self.assertEqual(
            labels, ["&File", "&Edit", "&Object", "&View", "&Window"])

    def test_file_menu_has_print_and_export(self):
        model = self._model()
        actions = self._actions(self._find(model, "&File"))
        self.assertIn("open_print_dialog", actions)
        self.assertIn("export_to_pdf", actions)

    def test_file_menu_separators_present(self):
        from menu.menu_model import MenuSeparator
        model = self._model()
        file_menu = self._find(model, "&File")
        seps = [e for e in file_menu.entries if isinstance(e, MenuSeparator)]
        self.assertGreaterEqual(len(seps), 1)

    def test_view_menu_has_zoom_and_fit(self):
        model = self._model()
        actions = self._actions(self._find(model, "&View"))
        self.assertIn("zoom_in", actions)
        self.assertIn("zoom_out", actions)
        self.assertIn("zoom_to_actual_size", actions)
        self.assertIn("fit_active_artboard", actions)
        self.assertIn("fit_all_artboards", actions)
        self.assertIn("fit_in_window", actions)

    def test_window_menu_has_dynamic_submenus(self):
        from menu.menu_model import MenuSubmenu, SubmenuKind
        model = self._model()
        window = self._find(model, "&Window")
        kinds = [e.kind for e in window.entries if isinstance(e, MenuSubmenu)]
        self.assertIn(SubmenuKind.WORKSPACE, kinds)
        self.assertIn(SubmenuKind.APPEARANCE, kinds)

    def test_window_toggle_panel_carries_panel_param(self):
        from menu.menu_model import MenuAction
        model = self._model()
        window = self._find(model, "&Window")
        color = [e for e in window.entries
                 if isinstance(e, MenuAction)
                 and e.action == "toggle_panel"
                 and e.params.get("panel") == "color"]
        self.assertEqual(len(color), 1)

    def test_window_has_all_fourteen_panel_toggles(self):
        from menu.menu_model import MenuAction
        model = self._model()
        window = self._find(model, "&Window")
        panels = {e.params.get("panel") for e in window.entries
                  if isinstance(e, MenuAction) and e.action == "toggle_panel"}
        expected = {"artboards", "layers", "color", "swatches", "stroke",
                    "properties", "character", "paragraph", "align",
                    "boolean", "magic_wand", "opacity", "symbols", "concepts"}
        self.assertEqual(panels, expected)

    def test_shortcuts_passed_through_verbatim(self):
        from menu.menu_model import MenuAction
        model = self._model()
        edit = self._find(model, "&Edit")
        save_as = self._find(model, "&File")
        shortcuts = {e.action: e.shortcut for m in model for e in m.entries
                     if isinstance(e, MenuAction)}
        self.assertEqual(shortcuts["save_as"], "Ctrl+Shift+S")
        self.assertEqual(shortcuts["zoom_in"], "Ctrl+=")
        self.assertEqual(shortcuts["fit_all_artboards"], "Ctrl+Alt+0")


class MenuStructureFromBundleTest(absltest.TestCase):
    """The rendered Qt menus reflect the bundle structure. Runs under the
    shared offscreen QApplication established by :class:`MenubarTest`."""

    @classmethod
    def setUpClass(cls):
        if not QApplication.instance():
            cls.app = QApplication([])
        else:
            cls.app = QApplication.instance()
        cls.window = MainWindow()

    def _labels(self, idx):
        # Read via the stable references create_menus stashes on the window.
        # ``menuBar().actions()[i].menu()`` returns a transient QMenu wrapper
        # that PySide can report as an already-deleted C++ object once many
        # MainWindows have been constructed in-process (a PySide ownership
        # quirk, pre-existing and unrelated to the bundle projection); the
        # retained ``_menu_objects`` list is the durable handle.
        menu = self.window._menu_objects[idx]
        return [a.text() for a in menu.actions() if not a.isSeparator()]

    def test_view_menu_has_six_actions(self):
        # View menu now renders all six bundle items (previously only 3).
        self.assertEqual(self._labels(3), [
            "Zoom &In", "Zoom &Out", "Actual &Size",
            "Fit &Artboard in Window", "Fit A&ll in Window", "&Fit in Window",
        ])

    def test_window_menu_has_concepts_toggle(self):
        self.assertIn("Co&ncepts", self._labels(4))

    def test_top_level_menu_titles_keep_ampersands(self):
        titles = [self.window._menu_objects[i].title() for i in range(5)]
        self.assertEqual(
            titles, ["&File", "&Edit", "&Object", "&View", "&Window"])


class LiveMenuReflectionTest(absltest.TestCase):
    """Live-widget reflection gate (TESTING_STRATEGY.md chrome seam).

    The bundle gate (``scripts/check_menu_structure.py``) pins that the
    *compiled* ``menubar`` matches the golden. This test closes the
    complementary gap the bundle gate cannot see: that the *actual rendered
    QMenuBar* — the real QAction tree Qt builds in :func:`menu.menu.create_menus`
    — reflects that same bundle structure. It walks the live widget and
    byte-compares to ``test_fixtures/expected/menu_structure.json``.

    Catches render-step drift the bundle/model gates miss: a dropped or
    reordered item, a mis-stripped mnemonic, a wrong shortcut, an item wired
    to the wrong action name.

    Two contents are inherently user-state-dependent and NOT spec-pinned, so
    both this walk and the golden normalize them away:
      * the Workspace / Appearance dynamic submenu *contents* (saved layouts,
        appearances) — collapsed to a ``"dynamic"`` sentinel; only the submenu
        label is compared;
      * shortcut string formatting — both sides pass through
        ``QKeySequence(s).toString()`` so the gate pins shortcut *equivalence*,
        not Qt's display spelling.
    """

    @classmethod
    def setUpClass(cls):
        if not QApplication.instance():
            cls.app = QApplication([])
        else:
            cls.app = QApplication.instance()
        cls.window = MainWindow()

    @staticmethod
    def _golden_path():
        from pathlib import Path
        root = Path(__file__).resolve().parents[2]
        return root / "test_fixtures" / "expected" / "menu_structure.json"

    @staticmethod
    def _canonical(obj) -> str:
        # Same canonical discipline as scripts/check_menu_structure.py.
        import json
        return json.dumps(obj, sort_keys=True, separators=(",", ":"),
                          ensure_ascii=False)

    @staticmethod
    def _norm_shortcut(seq) -> str:
        from PySide6.QtGui import QKeySequence
        if isinstance(seq, str):
            seq = QKeySequence(seq)
        return seq.toString()

    def _walk_live(self):
        """Walk the live QMenuBar to the canonical menu-structure shape.

        Top-level menus are read via the durable ``_menu_objects`` handles
        :func:`create_menus` stashes on the window (``menuBar().actions()[i]
        .menu()`` can report an already-deleted C++ wrapper once several
        MainWindows exist in-process — a PySide ownership quirk). Items are
        classified WITHOUT ``QAction.menu()``: every real action carries its
        bundle action name via ``setData``, so a non-separator item with no
        data is a dynamic submenu.
        """
        menubar = self.window.menuBar()
        n_top = len(menubar.actions())
        menus = []
        for top in self.window._menu_objects[:n_top]:
            items = []
            for act in top.actions():
                if act.isSeparator():
                    items.append({"separator": True})
                elif not act.data():
                    items.append({"label": act.text(), "submenu": "dynamic"})
                else:
                    items.append({
                        "action": act.data(),
                        "label": act.text(),
                        "shortcut": self._norm_shortcut(act.shortcut()),
                    })
            menus.append({"label": top.title(), "items": items})
        return {"menus": menus}

    def _normalize_expected(self, golden):
        """Apply the same two normalizations to the golden so the byte-compare
        pins structure, not user-state or shortcut spelling."""
        menus = []
        for menu in golden["menus"]:
            items = []
            for it in menu["items"]:
                if "separator" in it:
                    items.append({"separator": True})
                elif "submenu" in it:
                    items.append({"label": it["label"], "submenu": "dynamic"})
                else:
                    items.append({
                        "action": it["action"],
                        "label": it["label"],
                        "shortcut": self._norm_shortcut(it["shortcut"]),
                    })
            menus.append({"label": menu["label"], "items": items})
        return {"menus": menus}

    def test_live_menubar_matches_bundle_golden(self):
        import json
        golden = json.loads(self._golden_path().read_text())
        expected = self._canonical(self._normalize_expected(golden))
        actual = self._canonical(self._walk_live())
        self.assertEqual(
            actual, expected,
            "The live QMenuBar drifted from the compiled menubar.\n"
            "  The rendered menu structure no longer matches "
            "test_fixtures/expected/menu_structure.json.\n"
            f"  live:     {actual}\n  expected: {expected}")


class LiveMenuStateWiringTest(absltest.TestCase):
    """The live menu APPLIES the bundle ``enabled_when`` / ``checked_when``
    through the shared evaluator (the behavior the cross-app ``menu_state`` gate
    pins). Seeds a window with a known document + layout, syncs, and asserts a
    few items' enabled / checked reflect that state — the behavior change from
    the prior "enabled_when carried but not evaluated" state."""

    @classmethod
    def setUpClass(cls):
        if not QApplication.instance():
            cls.app = QApplication([])
        else:
            cls.app = QApplication.instance()

    def setUp(self):
        self.window = MainWindow()

    def _by_data(self, name):
        for menu in self.window._menu_objects:
            for act in menu.actions():
                if act.data() == name:
                    return act
        return None

    def _by_label(self, label):
        for menu in self.window._menu_objects:
            for act in menu.actions():
                if act.text() == label:
                    return act
        return None

    def test_enabled_reflects_selection(self):
        # Two selected elements + an active document.
        self.window.add_canvas(_make_model_with_rects(2))
        self.window.sync_panel_menu_checks()  # apply enabled/checked now
        # selection_count >= 2 -> Group enabled; == 1 -> Make Instance disabled.
        self.assertTrue(self._by_data("group").isEnabled())
        self.assertFalse(self._by_data("make_instance").isEnabled())
        # tab_count > 0 -> Select All enabled.
        self.assertTrue(self._by_data("select_all").isEnabled())

    def test_single_selection_enables_make_instance(self):
        self.window.add_canvas(_make_model_with_rects(1))
        self.window.sync_panel_menu_checks()
        # Exactly one selected -> Make Instance enabled, Group disabled.
        self.assertTrue(self._by_data("make_instance").isEnabled())
        self.assertFalse(self._by_data("group").isEnabled())

    def test_toggle_checked_matches_layout(self):
        from workspace.workspace_layout import PanelKind
        self.window.add_canvas(_make_model_with_rects(1))
        self.window.sync_panel_menu_checks()
        layers = self._by_label("&Layers")
        self.assertIsNotNone(layers)
        self.assertTrue(layers.isCheckable())
        # checked_when "panels.layers" -> the live layout's visibility.
        self.assertEqual(
            layers.isChecked(),
            self.window.workspace_layout.is_panel_visible(PanelKind.LAYERS))


class ZoomRoutingTest(absltest.TestCase):
    """The View zoom/fit family mutates the active model's view state.
    Pins that the bundle-driven View entries reach working zoom handlers
    (kept native because the generic doc.zoom.* path cannot resolve
    ``preferences.viewport.zoom_step`` in the menu dispatch context)."""

    @classmethod
    def setUpClass(cls):
        if not QApplication.instance():
            cls.app = QApplication([])
        else:
            cls.app = QApplication.instance()

    def setUp(self):
        self.window = MainWindow()
        # MainWindow may open with no canvas; ensure an active model.
        if self.window.active_model() is None:
            self.window.add_canvas(_make_model_with_rects(1))

    def test_zoom_in_increases_zoom_level(self):
        model = self.window.active_model()
        self.assertIsNotNone(model)
        model.viewport_w = 800
        model.viewport_h = 600
        before = model.zoom_level
        menu_module._on_menu_action(self.window, "zoom_in", {})
        self.assertGreater(model.zoom_level, before)

    def test_actual_size_sets_zoom_to_one(self):
        model = self.window.active_model()
        model.viewport_w = 800
        model.viewport_h = 600
        model.zoom_level = 3.0
        menu_module._on_menu_action(self.window, "zoom_to_actual_size", {})
        self.assertEqual(model.zoom_level, 1.0)


class FifoActionRoutingTest(absltest.TestCase):
    """The test-only FIFO ``action <name>`` channel must route document-
    mutating actions through their NATIVE handlers, not the generic panel
    dispatcher. ``new_document`` / ``select_all`` / ``delete_selection``
    carry actions.yaml ``log`` stubs whose real behavior lives natively
    (see :func:`menu.menu._on_menu_action`), so the generic dispatcher
    would no-op them. These pin the live-GUI contract: a FIFO
    ``action select_all`` selects all, ``delete_selection`` deletes, and
    ``new_document`` switches to a fresh blank canvas — while a genuine
    panel action still falls through to the generic dispatcher.
    """

    @classmethod
    def setUpClass(cls):
        if not QApplication.instance():
            cls.app = QApplication([])
        else:
            cls.app = QApplication.instance()

    def setUp(self):
        self.window = MainWindow()

    def _add_model(self, *, selected: bool, n: int = 2) -> Model:
        """Add (and activate) a canvas with n rects; selected toggles
        whether they start selected."""
        rects = tuple(_make_rect(x=i * 20) for i in range(n))
        layer = Layer(children=rects, name="L0")
        sel = (frozenset(ElementSelection.all((0, i)) for i in range(n))
               if selected else frozenset())
        model = Model(document=Document(layers=(layer,), selection=sel))
        self.window.add_canvas(model)
        return model

    def test_fifo_select_all_selects_via_native_handler(self):
        model = self._add_model(selected=False, n=2)
        self.assertEqual(len(model.document.selection), 0)
        self.window._dispatch_action_by_name("select_all", {})
        # Native _select_all ran (NOT the log stub) -> both selected.
        self.assertEqual(len(model.document.selection), 2)

    def test_fifo_delete_selection_removes_selected(self):
        model = self._add_model(selected=True, n=2)
        self.assertEqual(len(model.document.layers[0].children), 2)
        self.window._dispatch_action_by_name("delete_selection", {})
        # Keyboard-only native delete ran -> both rects gone.
        self.assertEqual(len(model.document.layers[0].children), 0)

    def test_fifo_new_document_switches_to_fresh_canvas(self):
        model = self._add_model(selected=False, n=2)
        self.assertIs(self.window.active_model(), model)
        self.window._dispatch_action_by_name("new_document", {})
        new_m = self.window.active_model()
        # A genuinely different, blank canvas became active (the very
        # behavior that silently no-op'd over the FIFO before the fix).
        self.assertIsNot(new_m, model)
        self.assertEqual(
            sum(len(l.children) for l in new_m.document.layers), 0)

    def test_fifo_unknown_action_falls_through_to_panel_dispatcher(self):
        self._add_model(selected=False, n=1)
        calls = []
        orig = self.window.dock_panel._dispatch_yaml_action
        self.window.dock_panel._dispatch_yaml_action = (
            lambda name, params: calls.append((name, params)))
        try:
            self.window._dispatch_action_by_name("some_panel_action", {"k": 1})
        finally:
            self.window.dock_panel._dispatch_yaml_action = orig
        # Not a native action -> routed to the generic panel dispatcher.
        self.assertEqual(calls, [("some_panel_action", {"k": 1})])


if __name__ == "__main__":
    absltest.main()
