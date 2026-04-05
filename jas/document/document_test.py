from absl.testing import absltest

from geometry.element import Group, Layer, Line, Rect, Circle
from document.document import Document


class DocumentTest(absltest.TestCase):

    def test_default_title(self):
        doc = Document()
        self.assertEqual(doc.title, "Untitled")

    def test_custom_title(self):
        doc = Document(title="My Drawing")
        self.assertEqual(doc.title, "My Drawing")

    def test_empty_document(self):
        doc = Document()
        self.assertEqual(doc.bounds(), (0, 0, 0, 0))

    def test_single_layer(self):
        layer = Layer(children=(Rect(x=0, y=0, width=10, height=10),), name="Layer 1")
        doc = Document(layers=(layer,))
        self.assertEqual(doc.bounds(), (0, 0, 10, 10))

    def test_multiple_layers(self):
        l1 = Layer(children=(Rect(x=0, y=0, width=10, height=10),), name="Background")
        l2 = Layer(children=(Circle(cx=50, cy=50, r=5),), name="Foreground")
        doc = Document(layers=(l1, l2))
        self.assertEqual(doc.bounds(), (0, 0, 55, 55))

    def test_document_immutable(self):
        doc = Document(layers=())
        with self.assertRaises(AttributeError):
            doc.layers = ()

    def test_document_layers_accessible(self):
        l1 = Layer(children=(), name="A")
        l2 = Layer(children=(), name="B")
        doc = Document(layers=(l1, l2))
        self.assertEqual(len(doc.layers), 2)
        self.assertEqual(doc.layers[0].name, "A")
        self.assertEqual(doc.layers[1].name, "B")


class SelectionTest(absltest.TestCase):

    def setUp(self):
        rect = Rect(x=0, y=0, width=10, height=10)
        circle = Circle(cx=50, cy=50, r=5)
        group = Group(children=(Line(x1=0, y1=0, x2=1, y2=1),))
        self.layer0 = Layer(children=(rect, circle, group), name="L0")
        self.layer1 = Layer(children=(rect,), name="L1")
        self.doc = Document(layers=(self.layer0, self.layer1))

    def test_default_selection_empty(self):
        self.assertEqual(self.doc.selection, frozenset())

    def test_selection_immutable(self):
        with self.assertRaises(AttributeError):
            self.doc.selection = frozenset()

    def test_selection_with_paths(self):
        sel = frozenset({(0, 0), (0, 1)})
        doc = Document(layers=self.doc.layers, selection=sel)
        self.assertEqual(doc.selection, sel)

    # get_element

    def test_get_element_layer(self):
        elem = self.doc.get_element((0,))
        self.assertIs(elem, self.layer0)

    def test_get_element_child(self):
        elem = self.doc.get_element((0, 1))
        self.assertIsInstance(elem, Circle)

    def test_get_element_nested(self):
        elem = self.doc.get_element((0, 2, 0))
        self.assertIsInstance(elem, Line)

    def test_get_element_empty_path_raises(self):
        with self.assertRaises(ValueError):
            self.doc.get_element(())

    # replace_element

    def test_replace_element_child(self):
        new_rect = Rect(x=5, y=5, width=20, height=20)
        doc2 = self.doc.replace_element((0, 0), new_rect)
        self.assertEqual(doc2.get_element((0, 0)), new_rect)
        # original unchanged
        self.assertEqual(self.doc.get_element((0, 0)), Rect(x=0, y=0, width=10, height=10))

    def test_replace_element_nested(self):
        new_line = Line(x1=1, y1=2, x2=3, y2=4)
        doc2 = self.doc.replace_element((0, 2, 0), new_line)
        self.assertEqual(doc2.get_element((0, 2, 0)), new_line)

    def test_replace_element_preserves_other_children(self):
        new_rect = Rect(x=99, y=99, width=1, height=1)
        doc2 = self.doc.replace_element((0, 0), new_rect)
        self.assertIsInstance(doc2.get_element((0, 1)), Circle)
        self.assertIsInstance(doc2.get_element((0, 2)), Group)

    def test_replace_element_preserves_other_layers(self):
        new_rect = Rect(x=99, y=99, width=1, height=1)
        doc2 = self.doc.replace_element((0, 0), new_rect)
        self.assertEqual(doc2.layers[1], self.layer1)

    def test_replace_element_preserves_selection(self):
        sel = frozenset({(0, 1)})
        doc = Document(layers=self.doc.layers, selection=sel)
        doc2 = doc.replace_element((0, 0), Rect(x=1, y=1, width=2, height=2))
        self.assertEqual(doc2.selection, sel)

    def test_replace_element_empty_path_raises(self):
        with self.assertRaises(ValueError):
            self.doc.replace_element((), Rect(x=0, y=0, width=1, height=1))

    def test_replace_element_returns_layer_type(self):
        new_rect = Rect(x=1, y=1, width=2, height=2)
        doc2 = self.doc.replace_element((0, 0), new_rect)
        self.assertIsInstance(doc2.layers[0], Layer)


if __name__ == "__main__":
    absltest.main()
