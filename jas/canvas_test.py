from absl.testing import absltest

from toolbar import Tool
from canvas import BoundingBox, CanvasWidget
from document import Document
from model import Model
from PySide6.QtWidgets import QApplication


class ToolbarTest(absltest.TestCase):

    def test_tool_enum_has_two_values(self):
        tools = list(Tool)
        self.assertEqual(len(tools), 2)
        self.assertIn(Tool.SELECTION, tools)
        self.assertIn(Tool.DIRECT_SELECTION, tools)

    def test_tool_selection_value(self):
        self.assertEqual(Tool.SELECTION.value, 1)

    def test_tool_direct_selection_value(self):
        self.assertEqual(Tool.DIRECT_SELECTION.value, 2)


class BoundingBoxTest(absltest.TestCase):

    def test_default_bbox(self):
        bbox = BoundingBox(0, 0, 800, 600)
        self.assertEqual(bbox.x, 0)
        self.assertEqual(bbox.y, 0)
        self.assertEqual(bbox.width, 800)
        self.assertEqual(bbox.height, 600)

    def test_custom_bbox(self):
        bbox = BoundingBox(10, 20, 1024, 768)
        self.assertEqual(bbox.x, 10)
        self.assertEqual(bbox.y, 20)
        self.assertEqual(bbox.width, 1024)
        self.assertEqual(bbox.height, 768)

    def test_bbox_immutable(self):
        bbox = BoundingBox(0, 0, 800, 600)
        with self.assertRaises(AttributeError):
            bbox.width = 1024


class CanvasWidgetTest(absltest.TestCase):

    @classmethod
    def setUpClass(cls):
        if not QApplication.instance():
            cls.app = QApplication([])
        else:
            cls.app = QApplication.instance()

    def test_default_bbox(self):
        model = Model()
        canvas = CanvasWidget(model=model)
        self.assertEqual(canvas.bbox.width, 800)
        self.assertEqual(canvas.bbox.height, 600)

    def test_registers_with_model(self):
        model = Model()
        canvas = CanvasWidget(model=model)
        # Changing the document should not raise
        model.document = Document(title="Test")


if __name__ == "__main__":
    absltest.main()
