from absl.testing import absltest

from document.document import Document
from geometry.element import Layer, Rect
from document.model import Model


class ModelTest(absltest.TestCase):

    def test_default_document(self):
        model = Model()
        self.assertEqual(model.document.title, "Untitled")
        self.assertEqual(len(model.document.layers), 1)

    def test_initial_document(self):
        doc = Document(title="Test")
        model = Model(document=doc)
        self.assertEqual(model.document.title, "Test")

    def test_set_document_notifies(self):
        model = Model()
        received = []
        model.on_document_changed(lambda doc: received.append(doc.title))
        model.document = Document(title="Changed")
        self.assertEqual(received, ["Changed"])

    def test_multiple_listeners(self):
        model = Model()
        a, b = [], []
        model.on_document_changed(lambda doc: a.append(doc.title))
        model.on_document_changed(lambda doc: b.append(doc.title))
        model.document = Document(title="X")
        self.assertEqual(a, ["X"])
        self.assertEqual(b, ["X"])

    def test_listener_called_on_each_change(self):
        model = Model()
        count = []
        model.on_document_changed(lambda doc: count.append(len(doc.layers)))
        layer = Layer(children=(), name="L1")
        model.document = Document(layers=(layer,))
        model.document = Document(layers=(layer, layer))
        self.assertEqual(count, [1, 2])

    def test_immutability(self):
        model = Model()
        before = model.document
        model.document = Document(title="New")
        after = model.document
        self.assertEqual(before.title, "Untitled")
        self.assertEqual(after.title, "New")

    def test_undo_redo(self):
        model = Model()
        self.assertFalse(model.can_undo)
        model.snapshot()
        model.document = Document(title="A")
        self.assertTrue(model.can_undo)
        self.assertFalse(model.can_redo)
        model.undo()
        self.assertEqual(model.document.title, "Untitled")
        self.assertTrue(model.can_redo)
        model.redo()
        self.assertEqual(model.document.title, "A")

    def test_undo_clears_redo_on_new_edit(self):
        model = Model()
        model.snapshot()
        model.document = Document(title="A")
        model.snapshot()
        model.document = Document(title="B")
        model.undo()
        self.assertEqual(model.document.title, "A")
        self.assertTrue(model.can_redo)
        model.snapshot()
        model.document = Document(title="C")
        self.assertFalse(model.can_redo)

    def test_undo_empty_stack(self):
        model = Model()
        model.undo()
        self.assertEqual(model.document.title, "Untitled")

    def test_redo_empty_stack(self):
        model = Model()
        model.redo()
        self.assertEqual(model.document.title, "Untitled")


if __name__ == "__main__":
    absltest.main()
