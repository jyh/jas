from absl.testing import absltest

from controller import Controller
from document import Document
from element import Layer, Rect
from model import Model


class ControllerTest(absltest.TestCase):

    def test_default_document(self):
        ctrl = Controller()
        self.assertEqual(ctrl.document.title, "Untitled")
        self.assertEqual(ctrl.document.layers, ())

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
        self.assertEqual(len(ctrl.document.layers), 1)
        self.assertEqual(ctrl.document.layers[0].name, "L1")

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


if __name__ == "__main__":
    absltest.main()
