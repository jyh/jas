from absl.testing import absltest

from element import Layer, Rect, Circle
from document import Document


class DocumentTest(absltest.TestCase):

    def test_empty_document(self):
        doc = Document(layers=())
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


if __name__ == "__main__":
    absltest.main()
