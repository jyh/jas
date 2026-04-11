import dataclasses

from absl.testing import absltest

from document.controller import Controller
from document.document import Document, ElementSelection
from geometry.element import Circle, Ellipse, Fill, Group, Layer, Line, Polygon, RgbColor, Rect, Stroke, control_points, control_point_count, move_control_points
from document.model import Model


def _sel(*paths):
    """Helper: create a Selection (frozenset of ElementSelection) from paths."""
    return frozenset(ElementSelection(path=p) for p in paths)


def _sel_paths(selection):
    """Helper: extract the set of paths from a Selection."""
    return frozenset(es.path for es in selection)


class ControllerTest(absltest.TestCase):

    def test_default_document(self):
        ctrl = Controller()
        self.assertTrue(ctrl.model.filename.startswith("Untitled-"))
        self.assertEqual(len(ctrl.document.layers), 1)

    def test_initial_filename(self):
        model = Model(filename="Test")
        ctrl = Controller(model=model)
        self.assertEqual(ctrl.model.filename, "Test")

    def test_set_filename(self):
        ctrl = Controller()
        ctrl.set_filename("New Name")
        self.assertEqual(ctrl.model.filename, "New Name")

    def test_add_layer(self):
        ctrl = Controller()
        layer = Layer(children=(Rect(x=0, y=0, width=10, height=10),), name="L1")
        ctrl.add_layer(layer)
        self.assertEqual(len(ctrl.document.layers), 2)
        self.assertEqual(ctrl.document.layers[1].name, "L1")

    def test_remove_layer(self):
        l1 = Layer(children=(), name="A")
        l2 = Layer(children=(), name="B")
        model = Model(document=Document(layers=(l1, l2)))
        ctrl = Controller(model=model)
        ctrl.remove_layer(0)
        self.assertEqual(len(ctrl.document.layers), 1)
        self.assertEqual(ctrl.document.layers[0].name, "B")

    def test_set_document(self):
        ctrl = Controller()
        new_doc = Document(layers=())
        ctrl.set_document(new_doc)
        self.assertEqual(len(ctrl.document.layers), 0)

    def test_mutations_notify_model(self):
        model = Model()
        ctrl = Controller(model=model)
        received = []
        model.on_document_changed(lambda doc: received.append(len(doc.layers)))
        ctrl.set_filename("Changed")
        # set_filename doesn't change document, so no notification
        self.assertEqual(received, [])

    def test_set_document_notifies_model(self):
        model = Model()
        ctrl = Controller(model=model)
        received = []
        model.on_document_changed(lambda doc: received.append(len(doc.layers)))
        ctrl.set_document(Document(layers=()))
        self.assertEqual(received, [0])


class SelectionControllerTest(absltest.TestCase):

    def setUp(self):
        rect = Rect(x=0, y=0, width=10, height=10)
        line = Line(x1=0, y1=0, x2=5, y2=5)
        circle_line = Line(x1=1, y1=1, x2=2, y2=2)
        group = Group(children=(line, circle_line))
        layer = Layer(children=(rect, group), name="L0")
        doc = Document(layers=(layer,))
        self.model = Model(document=doc)
        self.ctrl = Controller(model=self.model)

    def test_set_selection(self):
        sel = _sel((0, 0))
        self.ctrl.set_selection(sel)
        self.assertEqual(self.ctrl.document.selection, sel)

    def test_set_selection_clears(self):
        self.ctrl.set_selection(_sel((0, 0)))
        self.ctrl.set_selection(frozenset())
        self.assertEqual(self.ctrl.document.selection, frozenset())

    def test_select_element_direct_child(self):
        """Clicking a direct child of a layer selects only that element."""
        self.ctrl.select_element((0, 0))
        self.assertEqual(_sel_paths(self.ctrl.document.selection), frozenset({(0, 0)}))

    def test_select_element_in_group(self):
        """Clicking an element inside a Group selects all group children."""
        self.ctrl.select_element((0, 1, 0))
        self.assertEqual(
            _sel_paths(self.ctrl.document.selection),
            frozenset({(0, 1), (0, 1, 0), (0, 1, 1)}),
        )

    def test_select_element_in_group_other_child(self):
        """Clicking a different child of the same Group selects the same set."""
        self.ctrl.select_element((0, 1, 1))
        self.assertEqual(
            _sel_paths(self.ctrl.document.selection),
            frozenset({(0, 1), (0, 1, 0), (0, 1, 1)}),
        )

    def test_select_element_notifies_model(self):
        received = []
        self.model.on_document_changed(lambda doc: received.append(doc.selection))
        self.ctrl.select_element((0, 0))
        self.assertEqual(len(received), 1)
        self.assertEqual(_sel_paths(received[0]), frozenset({(0, 0)}))

    def test_select_element_layer_path(self):
        """Selecting a layer itself (path length 1) selects just the layer."""
        self.ctrl.select_element((0,))
        self.assertEqual(_sel_paths(self.ctrl.document.selection), frozenset({(0,)}))

    def test_select_rect_hits_element(self):
        """Marquee covering the rect selects it."""
        self.ctrl.select_rect(-1, -1, 12, 12)
        self.assertIn((0, 0), _sel_paths(self.ctrl.document.selection))

    def test_select_rect_misses_element(self):
        """Marquee outside all elements selects nothing."""
        self.ctrl.select_rect(100, 100, 10, 10)
        self.assertEqual(self.ctrl.document.selection, frozenset())

    def test_select_rect_group_expansion(self):
        """Marquee hitting one group child selects all group children."""
        rect_far = Rect(x=100, y=100, width=10, height=10)
        line1 = Line(x1=0, y1=0, x2=5, y2=5)
        line2 = Line(x1=1, y1=1, x2=2, y2=2)
        group = Group(children=(line1, line2))
        layer = Layer(children=(rect_far, group), name="L0")
        doc = Document(layers=(layer,))
        model = Model(document=doc)
        ctrl = Controller(model=model)
        ctrl.select_rect(-1, -1, 7, 7)
        self.assertEqual(
            _sel_paths(ctrl.document.selection),
            frozenset({(0, 1), (0, 1, 0), (0, 1, 1)}),
        )

    def test_locked_group_not_selectable(self):
        """Locking a group prevents it from being selected again."""
        line1 = Line(x1=0, y1=0, x2=5, y2=5)
        line2 = Line(x1=1, y1=1, x2=2, y2=2)
        group = Group(children=(line1, line2))
        layer = Layer(children=(group,), name="L0")
        doc = Document(layers=(layer,))
        model = Model(document=doc)
        ctrl = Controller(model=model)
        # Select the group, then lock it
        ctrl.select_rect(-1, -1, 7, 7)
        self.assertTrue(len(ctrl.document.selection) > 0)
        ctrl.lock_selection()
        self.assertEqual(ctrl.document.selection, frozenset())
        # Verify the group and children are locked
        locked_group = ctrl.document.layers[0].children[0]
        self.assertTrue(locked_group.locked)
        self.assertTrue(locked_group.children[0].locked)
        self.assertTrue(locked_group.children[1].locked)
        # Try to select again — should fail
        ctrl.select_rect(-1, -1, 7, 7)
        self.assertEqual(ctrl.document.selection, frozenset())

    def test_select_rect_replaces_previous(self):
        """Marquee selection replaces any prior selection."""
        self.ctrl.set_selection(_sel((0, 0)))
        self.ctrl.select_rect(100, 100, 10, 10)
        self.assertEqual(self.ctrl.document.selection, frozenset())

    def test_select_rect_misses_diagonal_line_corner(self):
        """Marquee in the bounding box corner of a diagonal line should miss."""
        line = Line(x1=0, y1=0, x2=100, y2=100)
        layer = Layer(children=(line,), name="L0")
        doc = Document(layers=(layer,))
        ctrl = Controller(model=Model(document=doc))
        # Box in upper-right corner of bbox — far from the diagonal
        ctrl.select_rect(80, 0, 20, 20)
        self.assertEqual(ctrl.document.selection, frozenset())

    def test_select_rect_hits_diagonal_line(self):
        """Marquee crossing a diagonal line should select it."""
        line = Line(x1=0, y1=0, x2=100, y2=100)
        layer = Layer(children=(line,), name="L0")
        doc = Document(layers=(layer,))
        ctrl = Controller(model=Model(document=doc))
        ctrl.select_rect(40, 40, 20, 20)
        self.assertIn((0, 0), _sel_paths(ctrl.document.selection))

    def test_select_rect_stroke_only_rect_interior_misses(self):
        """Marquee inside a stroke-only rect should miss."""
        rect = Rect(x=0, y=0, width=100, height=100)
        layer = Layer(children=(rect,), name="L0")
        doc = Document(layers=(layer,))
        ctrl = Controller(model=Model(document=doc))
        ctrl.select_rect(30, 30, 10, 10)
        self.assertEqual(ctrl.document.selection, frozenset())

    def test_select_rect_filled_rect_interior_hits(self):
        """Marquee inside a filled rect should select it."""
        from geometry.element import Fill, RgbColor
        rect = Rect(x=0, y=0, width=100, height=100,
                    fill=Fill(color=RgbColor(1, 0, 0)))
        layer = Layer(children=(rect,), name="L0")
        doc = Document(layers=(layer,))
        ctrl = Controller(model=Model(document=doc))
        ctrl.select_rect(30, 30, 10, 10)
        self.assertIn((0, 0), _sel_paths(ctrl.document.selection))

    def test_select_rect_multiple_elements(self):
        """Marquee covering both the rect and the group selects all."""
        self.ctrl.select_rect(-1, -1, 20, 20)
        paths = _sel_paths(self.ctrl.document.selection)
        self.assertIn((0, 0), paths)
        self.assertIn((0, 1, 0), paths)
        self.assertIn((0, 1, 1), paths)

    def test_select_control_point(self):
        """Selecting a control point creates a partial ElementSelection."""
        from document.document import _SelectionPartial, SortedCps
        self.ctrl.select_control_point((0, 0), 1)
        sel = self.ctrl.document.selection
        self.assertEqual(len(sel), 1)
        es = next(iter(sel))
        self.assertEqual(es.path, (0, 0))
        self.assertEqual(es.kind, _SelectionPartial(SortedCps.from_iter([1])))

    def test_default_element_selection_flags(self):
        """select_element produces an `.all` entry."""
        from document.document import _SelectionAll
        self.ctrl.select_element((0, 0))
        es = next(iter(self.ctrl.document.selection))
        self.assertIsInstance(es.kind, _SelectionAll)


class DirectSelectionControllerTest(absltest.TestCase):

    def test_direct_select_rect_no_group_expansion(self):
        """Direct selection does NOT expand groups — only the hit child is selected."""
        line1 = Line(x1=0, y1=0, x2=5, y2=5)
        line2 = Line(x1=50, y1=50, x2=55, y2=55)
        group = Group(children=(line1, line2))
        layer = Layer(children=(group,), name="L0")
        ctrl = Controller(model=Model(document=Document(layers=(layer,))))
        ctrl.direct_select_rect(-1, -1, 7, 7)
        paths = _sel_paths(ctrl.document.selection)
        self.assertIn((0, 0, 0), paths)
        self.assertNotIn((0, 0, 1), paths)

    def test_direct_select_rect_selects_only_hit_cps(self):
        """Only control points inside the marquee are selected."""
        from document.document import _SelectionPartial, SortedCps
        # Rect at (0,0) 100x100 — CPs are corners: (0,0), (100,0), (100,100), (0,100)
        rect = Rect(x=0, y=0, width=100, height=100)
        layer = Layer(children=(rect,), name="L0")
        ctrl = Controller(model=Model(document=Document(layers=(layer,))))
        # Marquee covers only the top-left corner
        ctrl.direct_select_rect(-5, -5, 10, 10)
        sel = ctrl.document.selection
        self.assertEqual(len(sel), 1)
        es = next(iter(sel))
        self.assertEqual(es.path, (0, 0))
        # Only CP 0 (top-left at 0,0) should be selected
        self.assertEqual(es.kind, _SelectionPartial(SortedCps.from_iter([0])))

    def test_direct_select_rect_body_only_yields_partial_empty(self):
        """If the marquee crosses the body but hits no CPs, the element is
        selected with ``_SelectionPartial(empty)`` — not ``.all``. The
        Direct Selection tool must not promote "body intersects" to
        "every CP selected".
        """
        from document.document import _SelectionPartial
        # Line from (0,0) to (100,100) — CPs at endpoints
        line = Line(x1=0, y1=0, x2=100, y2=100)
        layer = Layer(children=(line,), name="L0")
        ctrl = Controller(model=Model(document=Document(layers=(layer,))))
        # Marquee in the middle of the line — no endpoints inside
        ctrl.direct_select_rect(40, 40, 20, 20)
        sel = ctrl.document.selection
        self.assertEqual(len(sel), 1)
        es = next(iter(sel))
        self.assertIsInstance(es.kind, _SelectionPartial)
        self.assertEqual(len(es.kind.cps), 0)

    def test_direct_select_rect_misses_element(self):
        """Direct selection marquee outside all elements selects nothing."""
        rect = Rect(x=0, y=0, width=10, height=10)
        layer = Layer(children=(rect,), name="L0")
        ctrl = Controller(model=Model(document=Document(layers=(layer,))))
        ctrl.direct_select_rect(200, 200, 10, 10)
        self.assertEqual(ctrl.document.selection, frozenset())

    def test_direct_select_rect_individual_in_group(self):
        """Direct selection can select individual elements inside a group."""
        rect1 = Rect(x=0, y=0, width=10, height=10)
        rect2 = Rect(x=50, y=50, width=10, height=10)
        group = Group(children=(rect1, rect2))
        layer = Layer(children=(group,), name="L0")
        ctrl = Controller(model=Model(document=Document(layers=(layer,))))
        # Marquee covers both group items
        ctrl.direct_select_rect(-5, -5, 70, 70)
        paths = _sel_paths(ctrl.document.selection)
        self.assertIn((0, 0, 0), paths)
        self.assertIn((0, 0, 1), paths)

    def test_toggle_selection_partial_xor_empty_keeps_element(self):
        """XOR of identical Partial CP sets yields ``Partial(empty)`` —
        the element must stay in the selection, not be dropped."""
        from document.document import _SelectionPartial, SortedCps
        rect = Rect(x=0, y=0, width=10, height=10)
        layer = Layer(children=(rect,), name="L0")
        ctrl = Controller(model=Model(document=Document(layers=(layer,))))
        a = frozenset({ElementSelection.partial((0, 0), [0, 1])})
        b = frozenset({ElementSelection.partial((0, 0), [0, 1])})
        result = Controller._toggle_selection(a, b)
        self.assertEqual(len(result), 1)
        es = next(iter(result))
        self.assertEqual(es.path, (0, 0))
        self.assertIsInstance(es.kind, _SelectionPartial)
        self.assertEqual(es.kind.cps, SortedCps.from_iter([]))

    def test_toggle_selection_all_xor_all_still_drops(self):
        """Two ``.all`` entries still cancel out — this is the element-
        level deselect gesture (shift-click an already-fully-selected
        element)."""
        a = frozenset({ElementSelection.all((0, 0))})
        b = frozenset({ElementSelection.all((0, 0))})
        self.assertEqual(Controller._toggle_selection(a, b), frozenset())

    def test_move_control_points_partial_empty_is_noop(self):
        """``move_control_points`` with ``Partial(empty)`` must return
        the element unchanged. Without the guard, Rect would silently
        convert to a Polygon (since is_all(4) is False)."""
        from document.document import selection_partial
        rect = Rect(x=1, y=2, width=10, height=20)
        moved = move_control_points(rect, selection_partial([]), 5.0, 7.0)
        self.assertEqual(moved, rect)
        self.assertIsInstance(moved, Rect)


class VisibilityControllerTest(absltest.TestCase):
    """Tests for the Visibility feature: Hide / Show All."""

    def _setup(self):
        from geometry.element import Line
        rect = Rect(x=0, y=0, width=10, height=10)
        line = Line(x1=0, y1=0, x2=5, y2=5)
        group = Group(children=(Line(x1=1, y1=1, x2=2, y2=2),
                                 Line(x1=3, y1=3, x2=4, y2=4)))
        layer = Layer(children=(rect, group, line), name="L0")
        return Controller(model=Model(document=Document(layers=(layer,))))

    def test_visibility_enum_ordering(self):
        from geometry.element import Visibility
        self.assertGreater(Visibility.PREVIEW.value, Visibility.OUTLINE.value)
        self.assertGreater(Visibility.OUTLINE.value, Visibility.INVISIBLE.value)
        self.assertEqual(
            min(Visibility.PREVIEW, Visibility.OUTLINE,
                key=lambda v: v.value),
            Visibility.OUTLINE,
        )
        self.assertEqual(
            min(Visibility.OUTLINE, Visibility.INVISIBLE,
                key=lambda v: v.value),
            Visibility.INVISIBLE,
        )

    def test_hide_selection_sets_invisible_and_clears_selection(self):
        from geometry.element import Visibility
        ctrl = self._setup()
        ctrl.select_element((0, 0))
        ctrl.hide_selection()
        self.assertEqual(ctrl.document.selection, frozenset())
        self.assertEqual(
            ctrl.document.get_element((0, 0)).visibility,
            Visibility.INVISIBLE,
        )

    def test_hidden_element_not_selectable_via_rect(self):
        ctrl = self._setup()
        ctrl.select_element((0, 0))
        ctrl.hide_selection()
        ctrl.select_rect(-1, -1, 12, 12)
        paths = _sel_paths(ctrl.document.selection)
        self.assertNotIn((0, 0), paths)

    def test_hidden_element_not_selectable_via_select_element(self):
        ctrl = self._setup()
        ctrl.select_element((0, 0))
        ctrl.hide_selection()
        ctrl.select_element((0, 0))
        self.assertEqual(ctrl.document.selection, frozenset())

    def test_invisible_group_caps_children(self):
        from geometry.element import Visibility
        ctrl = self._setup()
        ctrl.select_element((0, 1))
        # select_element on a group's child expands to the whole
        # group, but here (0,1) is a direct child of the layer, so
        # just the group itself is selected.
        ctrl.hide_selection()
        doc = ctrl.document
        self.assertEqual(
            doc.get_element((0, 1)).visibility, Visibility.INVISIBLE)
        # A child inside the hidden group: its own flag is unchanged,
        # but effective visibility is INVISIBLE.
        self.assertEqual(
            doc.get_element((0, 1, 0)).visibility, Visibility.PREVIEW)
        self.assertEqual(
            doc.effective_visibility((0, 1, 0)), Visibility.INVISIBLE)

    def test_show_all_resets_and_selects_newly_shown(self):
        from geometry.element import Visibility
        ctrl = self._setup()
        # Hide the rect and the line (indices 0 and 2).
        ctrl.set_selection(frozenset({
            ElementSelection.all((0, 0)),
            ElementSelection.all((0, 2)),
        }))
        ctrl.hide_selection()
        # Now Show All.
        ctrl.show_all()
        doc = ctrl.document
        self.assertEqual(
            doc.get_element((0, 0)).visibility, Visibility.PREVIEW)
        self.assertEqual(
            doc.get_element((0, 2)).visibility, Visibility.PREVIEW)
        paths = _sel_paths(doc.selection)
        self.assertIn((0, 0), paths)
        self.assertIn((0, 2), paths)
        self.assertEqual(len(paths), 2)

    def test_show_all_with_nothing_hidden_leaves_empty_selection(self):
        ctrl = self._setup()
        ctrl.show_all()
        self.assertEqual(ctrl.document.selection, frozenset())


class GroupSelectionControllerTest(absltest.TestCase):

    def test_group_select_rect_no_group_expansion(self):
        """Group selection does NOT expand groups — only the hit child is selected."""
        line1 = Line(x1=0, y1=0, x2=5, y2=5)
        line2 = Line(x1=50, y1=50, x2=55, y2=55)
        group = Group(children=(line1, line2))
        layer = Layer(children=(group,), name="L0")
        ctrl = Controller(model=Model(document=Document(layers=(layer,))))
        ctrl.group_select_rect(-1, -1, 7, 7)
        paths = _sel_paths(ctrl.document.selection)
        self.assertIn((0, 0, 0), paths)
        self.assertNotIn((0, 0, 1), paths)

    def test_group_select_rect_selects_all_cps(self):
        """Group selection always selects elements as a whole."""
        from document.document import _SelectionAll
        rect = Rect(x=0, y=0, width=100, height=100)
        layer = Layer(children=(rect,), name="L0")
        ctrl = Controller(model=Model(document=Document(layers=(layer,))))
        ctrl.group_select_rect(-5, -5, 10, 10)
        sel = ctrl.document.selection
        self.assertEqual(len(sel), 1)
        es = next(iter(sel))
        self.assertIsInstance(es.kind, _SelectionAll)

    def test_group_select_rect_misses_element(self):
        """Group selection marquee outside all elements selects nothing."""
        rect = Rect(x=0, y=0, width=10, height=10)
        layer = Layer(children=(rect,), name="L0")
        ctrl = Controller(model=Model(document=Document(layers=(layer,))))
        ctrl.group_select_rect(200, 200, 10, 10)
        self.assertEqual(ctrl.document.selection, frozenset())

    def test_group_select_rect_individual_in_group(self):
        """Group selection can select individual elements inside a group."""
        rect1 = Rect(x=0, y=0, width=10, height=10)
        rect2 = Rect(x=50, y=50, width=10, height=10)
        group = Group(children=(rect1, rect2))
        layer = Layer(children=(group,), name="L0")
        ctrl = Controller(model=Model(document=Document(layers=(layer,))))
        ctrl.group_select_rect(-5, -5, 70, 70)
        paths = _sel_paths(ctrl.document.selection)
        self.assertIn((0, 0, 0), paths)
        self.assertIn((0, 0, 1), paths)


class ExtendSelectionTest(absltest.TestCase):

    def test_extend_adds_new_element(self):
        """Shift-marquee adds a new element to the existing selection."""
        rect1 = Rect(x=0, y=0, width=10, height=10)
        rect2 = Rect(x=50, y=50, width=10, height=10)
        layer = Layer(children=(rect1, rect2), name="L0")
        ctrl = Controller(model=Model(document=Document(layers=(layer,))))
        # Select rect1
        ctrl.select_rect(-1, -1, 12, 12)
        self.assertEqual(_sel_paths(ctrl.document.selection), frozenset({(0, 0)}))
        # Shift-select rect2 — should add to selection
        ctrl.select_rect(49, 49, 12, 12, extend=True)
        self.assertEqual(_sel_paths(ctrl.document.selection), frozenset({(0, 0), (0, 1)}))

    def test_extend_removes_existing_element(self):
        """Shift-marquee removes an already-selected element."""
        rect1 = Rect(x=0, y=0, width=10, height=10)
        rect2 = Rect(x=50, y=50, width=10, height=10)
        layer = Layer(children=(rect1, rect2), name="L0")
        ctrl = Controller(model=Model(document=Document(layers=(layer,))))
        # Select both
        ctrl.select_rect(-1, -1, 70, 70)
        self.assertEqual(_sel_paths(ctrl.document.selection), frozenset({(0, 0), (0, 1)}))
        # Shift-select rect1 again — should remove it
        ctrl.select_rect(-1, -1, 12, 12, extend=True)
        self.assertEqual(_sel_paths(ctrl.document.selection), frozenset({(0, 1)}))

    def test_extend_direct_select(self):
        """Shift works with direct_select_rect too."""
        line1 = Line(x1=0, y1=0, x2=5, y2=5)
        line2 = Line(x1=50, y1=50, x2=55, y2=55)
        layer = Layer(children=(line1, line2), name="L0")
        ctrl = Controller(model=Model(document=Document(layers=(layer,))))
        ctrl.direct_select_rect(-1, -1, 7, 7)
        self.assertEqual(_sel_paths(ctrl.document.selection), frozenset({(0, 0)}))
        ctrl.direct_select_rect(49, 49, 7, 7, extend=True)
        self.assertEqual(_sel_paths(ctrl.document.selection), frozenset({(0, 0), (0, 1)}))

    def test_extend_direct_select_toggles_cps(self):
        """Shift-direct-select toggles control points, not entire elements."""
        from document.document import _SelectionPartial, SortedCps
        # Rect at (0,0) size 10x10 — CPs at (0,0), (10,0), (10,10), (0,10)
        rect = Rect(x=0, y=0, width=10, height=10)
        layer = Layer(children=(rect,), name="L0")
        ctrl = Controller(model=Model(document=Document(layers=(layer,))))
        # Direct select top-left corner CP 0 at (0,0)
        ctrl.direct_select_rect(-1, -1, 2, 2)
        sel = list(ctrl.document.selection)
        self.assertEqual(len(sel), 1)
        self.assertEqual(sel[0].kind, _SelectionPartial(SortedCps.from_iter([0])))
        # Shift-direct-select top-right corner CP 1 at (10,0) — should add CP
        ctrl.direct_select_rect(9, -1, 2, 2, extend=True)
        sel = list(ctrl.document.selection)
        self.assertEqual(len(sel), 1)
        self.assertEqual(sel[0].kind, _SelectionPartial(SortedCps.from_iter([0, 1])))
        # Shift-direct-select top-left again — should remove CP 0, keep CP 1
        ctrl.direct_select_rect(-1, -1, 2, 2, extend=True)
        sel = list(ctrl.document.selection)
        self.assertEqual(len(sel), 1)
        self.assertEqual(sel[0].kind, _SelectionPartial(SortedCps.from_iter([1])))

    def test_extend_group_select(self):
        """Shift works with group_select_rect too."""
        rect1 = Rect(x=0, y=0, width=10, height=10)
        rect2 = Rect(x=50, y=50, width=10, height=10)
        layer = Layer(children=(rect1, rect2), name="L0")
        ctrl = Controller(model=Model(document=Document(layers=(layer,))))
        ctrl.group_select_rect(-1, -1, 12, 12)
        self.assertEqual(_sel_paths(ctrl.document.selection), frozenset({(0, 0)}))
        ctrl.group_select_rect(49, 49, 12, 12, extend=True)
        self.assertEqual(_sel_paths(ctrl.document.selection), frozenset({(0, 0), (0, 1)}))


class ControlPointPositionsTest(absltest.TestCase):

    def test_line_control_points(self):
        line = Line(x1=10, y1=20, x2=30, y2=40)
        self.assertEqual(control_points(line), [(10, 20), (30, 40)])

    def test_rect_control_points(self):
        rect = Rect(x=5, y=10, width=20, height=30)
        self.assertEqual(control_points(rect),
                         [(5, 10), (25, 10), (25, 40), (5, 40)])

    def test_circle_control_points(self):
        circle = Circle(cx=50, cy=50, r=10)
        self.assertEqual(control_points(circle),
                         [(50, 40), (60, 50), (50, 60), (40, 50)])

    def test_ellipse_control_points(self):
        ellipse = Ellipse(cx=50, cy=50, rx=20, ry=10)
        self.assertEqual(control_points(ellipse),
                         [(50, 40), (70, 50), (50, 60), (30, 50)])


class MoveControlPointsTest(absltest.TestCase):

    def _all(self):
        from document.document import selection_all
        return selection_all()

    def _partial(self, cps):
        from document.document import selection_partial
        return selection_partial(cps)

    def test_move_line_both_cps(self):
        line = Line(x1=10, y1=20, x2=30, y2=40)
        moved = move_control_points(line, self._all(), 5.0, -3.0)
        self.assertEqual((moved.x1, moved.y1), (15.0, 17.0))
        self.assertEqual((moved.x2, moved.y2), (35.0, 37.0))

    def test_move_line_one_cp(self):
        line = Line(x1=0, y1=0, x2=10, y2=10)
        moved = move_control_points(line, self._partial([1]), 5.0, 5.0)
        self.assertEqual((moved.x1, moved.y1), (0, 0))
        self.assertEqual((moved.x2, moved.y2), (15.0, 15.0))

    def test_move_rect_all_cps(self):
        rect = Rect(x=10, y=20, width=30, height=40)
        moved = move_control_points(rect, self._all(), 5.0, -5.0)
        self.assertEqual((moved.x, moved.y, moved.width, moved.height),
                         (15.0, 15.0, 30.0, 40.0))

    def test_move_rect_one_corner(self):
        rect = Rect(x=0, y=0, width=10, height=10)
        moved = move_control_points(rect, self._partial([2]), 5.0, 5.0)
        # CP2 is bottom-right (10,10) → (15,15); partial CP move converts to Polygon
        self.assertIsInstance(moved, Polygon)
        self.assertEqual(moved.points,
                         ((0.0, 0.0), (10.0, 0.0), (15.0, 15.0), (0.0, 10.0)))

    def test_move_circle_all_cps(self):
        circle = Circle(cx=50, cy=50, r=10)
        moved = move_control_points(circle, self._all(), 10.0, -10.0)
        self.assertEqual((moved.cx, moved.cy, moved.r), (60.0, 40.0, 10.0))

    def test_move_ellipse_all_cps(self):
        ellipse = Ellipse(cx=50, cy=50, rx=20, ry=10)
        moved = move_control_points(ellipse, self._all(), -5.0, 5.0)
        self.assertEqual((moved.cx, moved.cy, moved.rx, moved.ry),
                         (45.0, 55.0, 20.0, 10.0))


class MoveSelectionTest(absltest.TestCase):

    def test_move_selected_line(self):
        line = Line(x1=10, y1=20, x2=30, y2=40)
        layer = Layer(children=(line,))
        doc = Document(layers=(layer,),
                       selection=frozenset({ElementSelection.all((0, 0))}))
        ctrl = Controller(model=Model(document=doc))
        ctrl.move_selection(5.0, -3.0)
        moved = ctrl.document.layers[0].children[0]
        self.assertEqual((moved.x1, moved.y1, moved.x2, moved.y2),
                         (15.0, 17.0, 35.0, 37.0))

    def test_move_selected_rect(self):
        rect = Rect(x=0, y=0, width=20, height=10)
        layer = Layer(children=(rect,))
        doc = Document(layers=(layer,),
                       selection=frozenset({ElementSelection.all((0, 0))}))
        ctrl = Controller(model=Model(document=doc))
        ctrl.move_selection(10.0, 10.0)
        moved = ctrl.document.layers[0].children[0]
        self.assertEqual((moved.x, moved.y, moved.width, moved.height),
                         (10.0, 10.0, 20.0, 10.0))

    def test_move_partial_cps(self):
        """Moving only one endpoint of a line."""
        line = Line(x1=0, y1=0, x2=10, y2=10)
        layer = Layer(children=(line,))
        doc = Document(layers=(layer,),
                       selection=frozenset({ElementSelection.partial((0, 0), [0])}))
        ctrl = Controller(model=Model(document=doc))
        ctrl.move_selection(5.0, 5.0)
        moved = ctrl.document.layers[0].children[0]
        self.assertEqual((moved.x1, moved.y1), (5.0, 5.0))
        self.assertEqual((moved.x2, moved.y2), (10.0, 10.0))

    def test_move_multiple_elements(self):
        line = Line(x1=0, y1=0, x2=10, y2=10)
        rect = Rect(x=20, y=20, width=10, height=10)
        layer = Layer(children=(line, rect))
        doc = Document(layers=(layer,),
                       selection=frozenset({
                           ElementSelection.all((0, 0)),
                           ElementSelection.all((0, 1)),
                       }))
        ctrl = Controller(model=Model(document=doc))
        ctrl.move_selection(3.0, 4.0)
        moved_line = ctrl.document.layers[0].children[0]
        moved_rect = ctrl.document.layers[0].children[1]
        self.assertEqual((moved_line.x1, moved_line.y1, moved_line.x2, moved_line.y2),
                         (3.0, 4.0, 13.0, 14.0))
        self.assertEqual((moved_rect.x, moved_rect.y), (23.0, 24.0))


class CopySelectionTest(absltest.TestCase):

    def _sel_all_cps(self, doc, *paths):
        """Create selection with each path selected as a whole."""
        return frozenset(ElementSelection.all(p) for p in paths)

    def test_copy_selection_duplicates_element(self):
        """copy_selection creates a copy offset from the original."""
        rect = Rect(x=10, y=20, width=30, height=40)
        layer = Layer(children=(rect,), name="L0")
        doc = Document(layers=(layer,))
        doc = dataclasses.replace(doc, selection=self._sel_all_cps(doc, (0, 0)))
        ctrl = Controller(model=Model(document=doc))
        ctrl.copy_selection(5.0, 5.0)
        self.assertEqual(len(ctrl.document.layers[0].children), 2)
        original = ctrl.document.layers[0].children[0]
        copy = ctrl.document.layers[0].children[1]
        self.assertEqual((original.x, original.y), (10, 20))
        self.assertEqual((copy.x, copy.y), (15, 25))

    def test_copy_selection_updates_selection_to_copy(self):
        """After copy, the new selection points to the copied element."""
        rect = Rect(x=0, y=0, width=10, height=10)
        layer = Layer(children=(rect,), name="L0")
        doc = Document(layers=(layer,))
        doc = dataclasses.replace(doc, selection=self._sel_all_cps(doc, (0, 0)))
        ctrl = Controller(model=Model(document=doc))
        ctrl.copy_selection(1.0, 1.0)
        paths = _sel_paths(ctrl.document.selection)
        self.assertIn((0, 1), paths)
        self.assertNotIn((0, 0), paths)

    def test_copy_selection_multiple_elements(self):
        """Copying multiple selected elements duplicates each one."""
        r1 = Rect(x=0, y=0, width=10, height=10)
        r2 = Rect(x=50, y=50, width=10, height=10)
        layer = Layer(children=(r1, r2), name="L0")
        doc = Document(layers=(layer,))
        doc = dataclasses.replace(doc, selection=self._sel_all_cps(doc, (0, 0), (0, 1)))
        ctrl = Controller(model=Model(document=doc))
        ctrl.copy_selection(2.0, 2.0)
        self.assertEqual(len(ctrl.document.layers[0].children), 4)


class DeleteSelectionNestedTest(absltest.TestCase):

    def test_delete_selection_simple(self):
        """Deleting a selected element removes it from the layer."""
        rect = Rect(x=0, y=0, width=10, height=10)
        circle = Circle(cx=50, cy=50, r=5)
        layer = Layer(children=(rect, circle), name="L0")
        doc = Document(layers=(layer,), selection=_sel((0, 0)))
        doc2 = doc.delete_selection()
        self.assertEqual(len(doc2.layers[0].children), 1)
        self.assertIsInstance(doc2.layers[0].children[0], Circle)
        self.assertEqual(doc2.selection, frozenset())

    def test_delete_selection_in_group(self):
        """Deleting an element nested inside a group removes only that element."""
        line1 = Line(x1=0, y1=0, x2=1, y2=1)
        line2 = Line(x1=2, y1=2, x2=3, y2=3)
        group = Group(children=(line1, line2))
        layer = Layer(children=(group,), name="L0")
        doc = Document(layers=(layer,), selection=_sel((0, 0, 0)))
        doc2 = doc.delete_selection()
        inner_group = doc2.layers[0].children[0]
        self.assertIsInstance(inner_group, Group)
        self.assertEqual(len(inner_group.children), 1)
        self.assertEqual(inner_group.children[0], line2)

    def test_delete_selection_nested_group(self):
        """Deleting an element in a nested group works correctly."""
        line = Line(x1=0, y1=0, x2=1, y2=1)
        rect = Rect(x=0, y=0, width=5, height=5)
        inner = Group(children=(line, rect))
        outer = Group(children=(inner,))
        layer = Layer(children=(outer,), name="L0")
        doc = Document(layers=(layer,), selection=_sel((0, 0, 0, 1)))
        doc2 = doc.delete_selection()
        inner2 = doc2.layers[0].children[0].children[0]
        self.assertIsInstance(inner2, Group)
        self.assertEqual(len(inner2.children), 1)
        self.assertEqual(inner2.children[0], line)

    def test_delete_multiple_from_same_group(self):
        """Deleting multiple elements from the same group handles index shifting."""
        l1 = Line(x1=0, y1=0, x2=1, y2=1)
        l2 = Line(x1=2, y1=2, x2=3, y2=3)
        l3 = Line(x1=4, y1=4, x2=5, y2=5)
        group = Group(children=(l1, l2, l3))
        layer = Layer(children=(group,), name="L0")
        doc = Document(layers=(layer,), selection=_sel((0, 0, 0), (0, 0, 2)))
        doc2 = doc.delete_selection()
        inner = doc2.layers[0].children[0]
        self.assertEqual(len(inner.children), 1)
        self.assertEqual(inner.children[0], l2)

    def test_delete_from_different_levels(self):
        """Deleting elements at different nesting levels works correctly."""
        rect = Rect(x=0, y=0, width=10, height=10)
        line = Line(x1=0, y1=0, x2=1, y2=1)
        group = Group(children=(line,))
        layer = Layer(children=(rect, group), name="L0")
        doc = Document(layers=(layer,), selection=_sel((0, 0), (0, 1, 0)))
        doc2 = doc.delete_selection()
        # rect removed, group's child removed -> empty group remains
        self.assertEqual(len(doc2.layers[0].children), 1)
        inner = doc2.layers[0].children[0]
        self.assertIsInstance(inner, Group)
        self.assertEqual(len(inner.children), 0)


class FillStrokeControllerTest(absltest.TestCase):

    def test_set_selection_fill_updates_rect(self):
        from geometry.element import Fill, Stroke
        rect = Rect(x=0, y=0, width=10, height=10)
        layer = Layer(children=(rect,))
        doc = Document(layers=(layer,))
        model = Model(document=doc)
        ctrl = Controller(model=model)
        # Select the rect
        ctrl.set_selection(frozenset({ElementSelection.all((0, 0))}))
        red_fill = Fill(RgbColor(1, 0, 0))
        ctrl.set_selection_fill(red_fill)
        updated = ctrl.document.layers[0].children[0]
        self.assertEqual(updated.fill, red_fill)

    def test_set_selection_stroke_updates_line(self):
        from geometry.element import Fill, Stroke
        line = Line(x1=0, y1=0, x2=10, y2=10)
        layer = Layer(children=(line,))
        doc = Document(layers=(layer,))
        model = Model(document=doc)
        ctrl = Controller(model=model)
        ctrl.set_selection(frozenset({ElementSelection.all((0, 0))}))
        blue_stroke = Stroke(RgbColor(0, 0, 1), width=2.0)
        ctrl.set_selection_stroke(blue_stroke)
        updated = ctrl.document.layers[0].children[0]
        self.assertEqual(updated.stroke, blue_stroke)

    def test_fill_summary_no_selection(self):
        from document.controller import selection_fill_summary, FillSummaryNoSelection
        doc = Document()
        summary = selection_fill_summary(doc)
        self.assertIsInstance(summary, FillSummaryNoSelection)

    def test_fill_summary_mixed(self):
        from geometry.element import Fill
        from document.controller import (
            selection_fill_summary, FillSummaryMixed,
        )
        r1 = Rect(x=0, y=0, width=10, height=10, fill=Fill(RgbColor(1, 0, 0)))
        r2 = Rect(x=20, y=20, width=10, height=10, fill=Fill(RgbColor(0, 1, 0)))
        layer = Layer(children=(r1, r2))
        doc = Document(layers=(layer,), selection=frozenset({
            ElementSelection.all((0, 0)),
            ElementSelection.all((0, 1)),
        }))
        summary = selection_fill_summary(doc)
        self.assertIsInstance(summary, FillSummaryMixed)

    def test_stroke_summary_uniform_none(self):
        from document.controller import (
            selection_stroke_summary, StrokeSummaryUniform,
        )
        rect = Rect(x=0, y=0, width=10, height=10)
        layer = Layer(children=(rect,))
        doc = Document(layers=(layer,), selection=frozenset({
            ElementSelection.all((0, 0)),
        }))
        summary = selection_stroke_summary(doc)
        self.assertIsInstance(summary, StrokeSummaryUniform)
        self.assertIsNone(summary.stroke)


if __name__ == "__main__":
    absltest.main()
