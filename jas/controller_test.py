from absl.testing import absltest

from controller import Controller
from document import Document
from element import Group, Layer, Line, Rect
from model import Model


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
        sel = frozenset({(0, 0)})
        self.ctrl.set_selection(sel)
        self.assertEqual(self.ctrl.document.selection, sel)

    def test_set_selection_clears(self):
        self.ctrl.set_selection(frozenset({(0, 0)}))
        self.ctrl.set_selection(frozenset())
        self.assertEqual(self.ctrl.document.selection, frozenset())

    def test_select_element_direct_child(self):
        """Clicking a direct child of a layer selects only that element."""
        self.ctrl.select_element((0, 0))
        self.assertEqual(self.ctrl.document.selection, frozenset({(0, 0)}))

    def test_select_element_in_group(self):
        """Clicking an element inside a Group selects all group children."""
        self.ctrl.select_element((0, 1, 0))
        self.assertEqual(
            self.ctrl.document.selection,
            frozenset({(0, 1, 0), (0, 1, 1)}),
        )

    def test_select_element_in_group_other_child(self):
        """Clicking a different child of the same Group selects the same set."""
        self.ctrl.select_element((0, 1, 1))
        self.assertEqual(
            self.ctrl.document.selection,
            frozenset({(0, 1, 0), (0, 1, 1)}),
        )

    def test_select_element_notifies_model(self):
        received = []
        self.model.on_document_changed(lambda doc: received.append(doc.selection))
        self.ctrl.select_element((0, 0))
        self.assertEqual(len(received), 1)
        self.assertEqual(received[0], frozenset({(0, 0)}))

    def test_select_element_layer_path(self):
        """Selecting a layer itself (path length 1) selects just the layer."""
        self.ctrl.select_element((0,))
        self.assertEqual(self.ctrl.document.selection, frozenset({(0,)}))

    def test_select_rect_hits_element(self):
        """Marquee covering the rect selects it."""
        self.ctrl.select_rect(-1, -1, 12, 12)
        self.assertIn((0, 0), self.ctrl.document.selection)

    def test_select_rect_misses_element(self):
        """Marquee outside all elements selects nothing."""
        self.ctrl.select_rect(100, 100, 10, 10)
        self.assertEqual(self.ctrl.document.selection, frozenset())

    def test_select_rect_group_expansion(self):
        """Marquee hitting one group child selects all group children."""
        # Layer has rect(0,0,10,10) and group(line(0,0→5,5), line(1,1→2,2)).
        # Use a rect that only hits the group lines (beyond rect's bounds).
        # line(0,0→5,5) has bounds (0,0,5,5), so a box at (10.5,0,5,5) misses
        # the rect but we need a box that hits only group children.
        # Actually, the rect and lines overlap at origin. Use a new setUp doc.
        rect_far = Rect(x=100, y=100, width=10, height=10)
        line1 = Line(x1=0, y1=0, x2=5, y2=5)
        line2 = Line(x1=1, y1=1, x2=2, y2=2)
        group = Group(children=(line1, line2))
        layer = Layer(children=(rect_far, group), name="L0")
        doc = Document(layers=(layer,))
        model = Model(document=doc)
        ctrl = Controller(model=model)
        # Marquee covers only the group lines, not the far rect
        ctrl.select_rect(-1, -1, 7, 7)
        self.assertEqual(
            ctrl.document.selection,
            frozenset({(0, 1, 0), (0, 1, 1)}),
        )

    def test_select_rect_replaces_previous(self):
        """Marquee selection replaces any prior selection."""
        self.ctrl.set_selection(frozenset({(0, 0)}))
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
        # Box crossing the diagonal
        ctrl.select_rect(40, 40, 20, 20)
        self.assertIn((0, 0), ctrl.document.selection)

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
        from element import Fill, Color
        rect = Rect(x=0, y=0, width=100, height=100,
                    fill=Fill(color=Color(1, 0, 0)))
        layer = Layer(children=(rect,), name="L0")
        doc = Document(layers=(layer,))
        ctrl = Controller(model=Model(document=doc))
        ctrl.select_rect(30, 30, 10, 10)
        self.assertIn((0, 0), ctrl.document.selection)

    def test_select_rect_multiple_elements(self):
        """Marquee covering both the rect and the group selects all."""
        self.ctrl.select_rect(-1, -1, 20, 20)
        self.assertIn((0, 0), self.ctrl.document.selection)
        self.assertIn((0, 1, 0), self.ctrl.document.selection)
        self.assertIn((0, 1, 1), self.ctrl.document.selection)


if __name__ == "__main__":
    absltest.main()
