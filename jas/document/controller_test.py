from absl.testing import absltest

from document.controller import Controller
from document.document import Document, ElementSelection
from geometry.element import Circle, Ellipse, Group, Layer, Line, Polygon, Rect, control_points, move_control_points
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
        self.assertEqual(ctrl.document.title, "Untitled")
        self.assertEqual(len(ctrl.document.layers), 1)

    def test_initial_document(self):
        doc = Document(title="Test")
        model = Model(document=doc)
        ctrl = Controller(model=model)
        self.assertEqual(ctrl.document.title, "Test")

    def test_set_title(self):
        ctrl = Controller()
        ctrl.set_title("New Title")
        self.assertEqual(ctrl.document.title, "New Title")

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
        new_doc = Document(title="Replaced")
        ctrl.set_document(new_doc)
        self.assertEqual(ctrl.document.title, "Replaced")

    def test_mutations_notify_model(self):
        model = Model()
        ctrl = Controller(model=model)
        received = []
        model.on_document_changed(lambda doc: received.append(doc.title))
        ctrl.set_title("Changed")
        self.assertEqual(received, ["Changed"])

    def test_model_immutability(self):
        ctrl = Controller()
        doc_before = ctrl.document
        ctrl.set_title("New")
        doc_after = ctrl.document
        self.assertEqual(doc_before.title, "Untitled")
        self.assertEqual(doc_after.title, "New")


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
            frozenset({(0, 1, 0), (0, 1, 1)}),
        )

    def test_select_element_in_group_other_child(self):
        """Clicking a different child of the same Group selects the same set."""
        self.ctrl.select_element((0, 1, 1))
        self.assertEqual(
            _sel_paths(self.ctrl.document.selection),
            frozenset({(0, 1, 0), (0, 1, 1)}),
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
            frozenset({(0, 1, 0), (0, 1, 1)}),
        )

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
        from geometry.element import Fill, Color
        rect = Rect(x=0, y=0, width=100, height=100,
                    fill=Fill(color=Color(1, 0, 0)))
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
        """Selecting a control point creates an ElementSelection with that cp."""
        self.ctrl.select_control_point((0, 0), 1)
        sel = self.ctrl.document.selection
        self.assertEqual(len(sel), 1)
        es = next(iter(sel))
        self.assertEqual(es.path, (0, 0))
        self.assertEqual(es.control_points, frozenset({1}))

    def test_default_element_selection_flags(self):
        """select_element produces entries with all control points."""
        self.ctrl.select_element((0, 0))
        es = next(iter(self.ctrl.document.selection))
        # Rect has 4 control points
        self.assertEqual(es.control_points, frozenset({0, 1, 2, 3}))


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
        self.assertEqual(es.control_points, frozenset({0}))

    def test_direct_select_rect_no_cps_when_none_in_rect(self):
        """If the element intersects but no CPs are in the rect, no CPs are selected."""
        # Line from (0,0) to (100,100) — CPs at endpoints
        line = Line(x1=0, y1=0, x2=100, y2=100)
        layer = Layer(children=(line,), name="L0")
        ctrl = Controller(model=Model(document=Document(layers=(layer,))))
        # Marquee in the middle of the line — no endpoints inside
        ctrl.direct_select_rect(40, 40, 20, 20)
        sel = ctrl.document.selection
        self.assertEqual(len(sel), 1)
        es = next(iter(sel))
        self.assertEqual(es.control_points, frozenset())

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
        """Group selection always selects all control points."""
        rect = Rect(x=0, y=0, width=100, height=100)
        layer = Layer(children=(rect,), name="L0")
        ctrl = Controller(model=Model(document=Document(layers=(layer,))))
        ctrl.group_select_rect(-5, -5, 10, 10)
        sel = ctrl.document.selection
        self.assertEqual(len(sel), 1)
        es = next(iter(sel))
        self.assertEqual(es.control_points, frozenset({0, 1, 2, 3}))

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
        # Rect at (0,0) size 10x10 — CPs at (0,0), (10,0), (10,10), (0,10)
        rect = Rect(x=0, y=0, width=10, height=10)
        layer = Layer(children=(rect,), name="L0")
        ctrl = Controller(model=Model(document=Document(layers=(layer,))))
        # Direct select top-left corner CP 0 at (0,0)
        ctrl.direct_select_rect(-1, -1, 2, 2)
        sel = list(ctrl.document.selection)
        self.assertEqual(len(sel), 1)
        self.assertEqual(sel[0].control_points, frozenset({0}))
        # Shift-direct-select top-right corner CP 1 at (10,0) — should add CP
        ctrl.direct_select_rect(9, -1, 2, 2, extend=True)
        sel = list(ctrl.document.selection)
        self.assertEqual(len(sel), 1)
        self.assertEqual(sel[0].control_points, frozenset({0, 1}))
        # Shift-direct-select top-left again — should remove CP 0, keep CP 1
        ctrl.direct_select_rect(-1, -1, 2, 2, extend=True)
        sel = list(ctrl.document.selection)
        self.assertEqual(len(sel), 1)
        self.assertEqual(sel[0].control_points, frozenset({1}))

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

    def test_move_line_both_cps(self):
        line = Line(x1=10, y1=20, x2=30, y2=40)
        moved = move_control_points(line, frozenset({0, 1}), 5.0, -3.0)
        self.assertEqual((moved.x1, moved.y1), (15.0, 17.0))
        self.assertEqual((moved.x2, moved.y2), (35.0, 37.0))

    def test_move_line_one_cp(self):
        line = Line(x1=0, y1=0, x2=10, y2=10)
        moved = move_control_points(line, frozenset({1}), 5.0, 5.0)
        self.assertEqual((moved.x1, moved.y1), (0, 0))
        self.assertEqual((moved.x2, moved.y2), (15.0, 15.0))

    def test_move_rect_all_cps(self):
        rect = Rect(x=10, y=20, width=30, height=40)
        moved = move_control_points(rect, frozenset({0, 1, 2, 3}), 5.0, -5.0)
        self.assertEqual((moved.x, moved.y, moved.width, moved.height),
                         (15.0, 15.0, 30.0, 40.0))

    def test_move_rect_one_corner(self):
        rect = Rect(x=0, y=0, width=10, height=10)
        moved = move_control_points(rect, frozenset({2}), 5.0, 5.0)
        # CP2 is bottom-right (10,10) → (15,15); partial CP move converts to Polygon
        self.assertIsInstance(moved, Polygon)
        self.assertEqual(moved.points,
                         ((0.0, 0.0), (10.0, 0.0), (15.0, 15.0), (0.0, 10.0)))

    def test_move_circle_all_cps(self):
        circle = Circle(cx=50, cy=50, r=10)
        moved = move_control_points(circle, frozenset({0, 1, 2, 3}), 10.0, -10.0)
        self.assertEqual((moved.cx, moved.cy, moved.r), (60.0, 40.0, 10.0))

    def test_move_ellipse_all_cps(self):
        ellipse = Ellipse(cx=50, cy=50, rx=20, ry=10)
        moved = move_control_points(ellipse, frozenset({0, 1, 2, 3}), -5.0, 5.0)
        self.assertEqual((moved.cx, moved.cy, moved.rx, moved.ry),
                         (45.0, 55.0, 20.0, 10.0))


class MoveSelectionTest(absltest.TestCase):

    def test_move_selected_line(self):
        line = Line(x1=10, y1=20, x2=30, y2=40)
        layer = Layer(children=(line,))
        doc = Document(layers=(layer,),
                       selection=frozenset({ElementSelection(
                           path=(0, 0), control_points=frozenset({0, 1}))}))
        ctrl = Controller(model=Model(document=doc))
        ctrl.move_selection(5.0, -3.0)
        moved = ctrl.document.layers[0].children[0]
        self.assertEqual((moved.x1, moved.y1, moved.x2, moved.y2),
                         (15.0, 17.0, 35.0, 37.0))

    def test_move_selected_rect(self):
        rect = Rect(x=0, y=0, width=20, height=10)
        layer = Layer(children=(rect,))
        doc = Document(layers=(layer,),
                       selection=frozenset({ElementSelection(
                           path=(0, 0), control_points=frozenset({0, 1, 2, 3}))}))
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
                       selection=frozenset({ElementSelection(
                           path=(0, 0), control_points=frozenset({0}))}))
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
                           ElementSelection(path=(0, 0), control_points=frozenset({0, 1})),
                           ElementSelection(path=(0, 1), control_points=frozenset({0, 1, 2, 3})),
                       }))
        ctrl = Controller(model=Model(document=doc))
        ctrl.move_selection(3.0, 4.0)
        moved_line = ctrl.document.layers[0].children[0]
        moved_rect = ctrl.document.layers[0].children[1]
        self.assertEqual((moved_line.x1, moved_line.y1, moved_line.x2, moved_line.y2),
                         (3.0, 4.0, 13.0, 14.0))
        self.assertEqual((moved_rect.x, moved_rect.y), (23.0, 24.0))


if __name__ == "__main__":
    absltest.main()
