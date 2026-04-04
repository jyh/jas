from absl.testing import absltest

from toolbar import Tool
from canvas import BoundingBox, CanvasWidget, _draw_element, _build_path
from controller import Controller
from document import Document
from element import (
    Circle, Color, CurveTo, ClosePath, Ellipse, Fill, Group, Layer, Line,
    LineTo, MoveTo, Path, Polygon, Polyline, QuadTo, Rect, SmoothCurveTo,
    SmoothQuadTo, Stroke, Text, Transform,
)
from model import Model
from PySide6.QtCore import QPointF, Qt
from PySide6.QtGui import QImage, QPainter
from PySide6.QtWidgets import QApplication


class ToolbarTest(absltest.TestCase):

    def test_tool_enum_values(self):
        tools = list(Tool)
        self.assertEqual(len(tools), 7)
        self.assertIn(Tool.SELECTION, tools)
        self.assertIn(Tool.DIRECT_SELECTION, tools)
        self.assertIn(Tool.GROUP_SELECTION, tools)
        self.assertIn(Tool.TEXT, tools)
        self.assertIn(Tool.LINE, tools)
        self.assertIn(Tool.RECT, tools)
        self.assertIn(Tool.POLYGON, tools)

    def test_tool_selection_value(self):
        self.assertEqual(Tool.SELECTION.value, 1)

    def test_tool_direct_selection_value(self):
        self.assertEqual(Tool.DIRECT_SELECTION.value, 2)

    def test_tool_text_value(self):
        self.assertEqual(Tool.TEXT.value, 4)

    def test_tool_line_value(self):
        self.assertEqual(Tool.LINE.value, 5)

    def test_tool_rect_value(self):
        self.assertEqual(Tool.RECT.value, 6)


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

    def _make_canvas(self, model=None):
        model = model or Model()
        ctrl = Controller(model=model)
        return CanvasWidget(model=model, controller=ctrl)

    def test_default_bbox(self):
        canvas = self._make_canvas()
        self.assertEqual(canvas.bbox.width, 800)
        self.assertEqual(canvas.bbox.height, 600)

    def test_custom_bbox(self):
        model = Model()
        ctrl = Controller(model=model)
        canvas = CanvasWidget(model=model, controller=ctrl,
                              bbox=BoundingBox(0, 0, 1024, 768))
        self.assertEqual(canvas.bbox.width, 1024)
        self.assertEqual(canvas.bbox.height, 768)

    def test_registers_with_model(self):
        model = Model()
        canvas = self._make_canvas(model)
        model.document = Document(title="Test")

    def test_title_updates_via_model(self):
        model = Model()
        canvas = self._make_canvas(model)
        model.document = Document(title="New Title")
        self.assertEqual(model.document.title, "New Title")

    def test_set_tool(self):
        canvas = self._make_canvas()
        canvas.set_tool(Tool.LINE)
        self.assertEqual(canvas._current_tool, Tool.LINE)
        canvas.set_tool(Tool.RECT)
        self.assertEqual(canvas._current_tool, Tool.RECT)

    def test_line_tool_creates_line_element(self):
        """Simulate mouse press/release with the line tool."""
        model = Model()
        ctrl = Controller(model=model)
        canvas = CanvasWidget(model=model, controller=ctrl)
        canvas.set_tool(Tool.LINE)
        # Simulate drag from (10,20) to (50,60)
        from unittest.mock import MagicMock
        press_event = MagicMock()
        press_event.button.return_value = Qt.LeftButton
        press_event.position.return_value = QPointF(10, 20)
        canvas.mousePressEvent(press_event)
        release_event = MagicMock()
        release_event.button.return_value = Qt.LeftButton
        release_event.position.return_value = QPointF(50, 60)
        canvas.mouseReleaseEvent(release_event)
        # Should have created a layer with a Line element
        doc = model.document
        self.assertEqual(len(doc.layers), 1)
        child = doc.layers[0].children[0]
        self.assertIsInstance(child, Line)
        self.assertAlmostEqual(child.x1, 10)
        self.assertAlmostEqual(child.y1, 20)
        self.assertAlmostEqual(child.x2, 50)
        self.assertAlmostEqual(child.y2, 60)

    def test_rect_tool_creates_rect_element(self):
        """Simulate mouse press/release with the rect tool."""
        model = Model()
        ctrl = Controller(model=model)
        canvas = CanvasWidget(model=model, controller=ctrl)
        canvas.set_tool(Tool.RECT)
        from unittest.mock import MagicMock
        press_event = MagicMock()
        press_event.button.return_value = Qt.LeftButton
        press_event.position.return_value = QPointF(50, 60)
        canvas.mousePressEvent(press_event)
        release_event = MagicMock()
        release_event.button.return_value = Qt.LeftButton
        release_event.position.return_value = QPointF(10, 20)
        canvas.mouseReleaseEvent(release_event)
        doc = model.document
        self.assertEqual(len(doc.layers), 1)
        child = doc.layers[0].children[0]
        self.assertIsInstance(child, Rect)
        # Should normalize: min corner is (10,20), size is (40,40)
        self.assertAlmostEqual(child.x, 10)
        self.assertAlmostEqual(child.y, 20)
        self.assertAlmostEqual(child.width, 40)
        self.assertAlmostEqual(child.height, 40)

    def test_drawing_adds_to_existing_layer(self):
        """Drawing when a layer already exists appends to it."""
        model = Model()
        ctrl = Controller(model=model)
        model.document = Document(
            layers=(Layer(name="L1", children=(
                Line(x1=0, y1=0, x2=1, y2=1, stroke=Stroke(color=Color(0, 0, 0))),
            )),),
        )
        canvas = CanvasWidget(model=model, controller=ctrl)
        canvas.set_tool(Tool.LINE)
        from unittest.mock import MagicMock
        press_event = MagicMock()
        press_event.button.return_value = Qt.LeftButton
        press_event.position.return_value = QPointF(0, 0)
        canvas.mousePressEvent(press_event)
        release_event = MagicMock()
        release_event.button.return_value = Qt.LeftButton
        release_event.position.return_value = QPointF(99, 99)
        canvas.mouseReleaseEvent(release_event)
        doc = model.document
        self.assertEqual(len(doc.layers), 1)
        self.assertEqual(len(doc.layers[0].children), 2)

    def test_selection_tool_does_not_create_elements(self):
        """Selection tool drag should not create elements, only select."""
        model = Model()
        ctrl = Controller(model=model)
        canvas = CanvasWidget(model=model, controller=ctrl)
        canvas.set_tool(Tool.SELECTION)
        from unittest.mock import MagicMock
        press_event = MagicMock()
        press_event.button.return_value = Qt.MouseButton.LeftButton
        press_event.position.return_value = QPointF(10, 10)
        canvas.mousePressEvent(press_event)
        release_event = MagicMock()
        release_event.button.return_value = Qt.MouseButton.LeftButton
        release_event.position.return_value = QPointF(50, 50)
        canvas.mouseReleaseEvent(release_event)
        # No elements should be created
        self.assertEqual(len(model.document.layers[0].children), 0)


class DrawElementTest(absltest.TestCase):
    """Test that _draw_element renders each element type without error."""

    def _make_painter(self):
        img = QImage(100, 100, QImage.Format_ARGB32)
        painter = QPainter(img)
        return painter, img

    def test_draw_line(self):
        p, _ = self._make_painter()
        _draw_element(p, Line(x1=0, y1=0, x2=50, y2=50,
                              stroke=Stroke(color=Color(0, 0, 0))))
        p.end()

    def test_draw_rect(self):
        p, _ = self._make_painter()
        _draw_element(p, Rect(x=10, y=10, width=30, height=20,
                              fill=Fill(color=Color(1, 0, 0))))
        p.end()

    def test_draw_rect_rounded(self):
        p, _ = self._make_painter()
        _draw_element(p, Rect(x=10, y=10, width=30, height=20, rx=5, ry=5,
                              fill=Fill(color=Color(0, 1, 0))))
        p.end()

    def test_draw_circle(self):
        p, _ = self._make_painter()
        _draw_element(p, Circle(cx=50, cy=50, r=20,
                                fill=Fill(color=Color(0, 0, 1)),
                                stroke=Stroke(color=Color(0, 0, 0))))
        p.end()

    def test_draw_ellipse(self):
        p, _ = self._make_painter()
        _draw_element(p, Ellipse(cx=50, cy=50, rx=30, ry=15,
                                 fill=Fill(color=Color(1, 1, 0))))
        p.end()

    def test_draw_polyline(self):
        p, _ = self._make_painter()
        _draw_element(p, Polyline(points=((0, 0), (50, 25), (100, 0)),
                                  stroke=Stroke(color=Color(0, 0, 0))))
        p.end()

    def test_draw_polygon(self):
        p, _ = self._make_painter()
        _draw_element(p, Polygon(points=((10, 10), (90, 10), (50, 90)),
                                 fill=Fill(color=Color(0, 1, 1))))
        p.end()

    def test_draw_path(self):
        p, _ = self._make_painter()
        _draw_element(p, Path(d=(
            MoveTo(10, 10),
            LineTo(50, 10),
            CurveTo(60, 10, 70, 30, 50, 50),
            QuadTo(30, 70, 10, 50),
            ClosePath(),
        ), fill=Fill(color=Color(0.5, 0.5, 0.5))))
        p.end()

    def test_draw_path_smooth(self):
        p, _ = self._make_painter()
        _draw_element(p, Path(d=(
            MoveTo(10, 50),
            CurveTo(20, 10, 40, 10, 50, 50),
            SmoothCurveTo(80, 90, 90, 50),
            QuadTo(70, 20, 50, 50),
            SmoothQuadTo(30, 50),
        ), stroke=Stroke(color=Color(0, 0, 0))))
        p.end()

    def test_draw_text(self):
        p, _ = self._make_painter()
        _draw_element(p, Text(x=10, y=50, content="Hello",
                              fill=Fill(color=Color(0, 0, 0))))
        p.end()

    def test_draw_group(self):
        p, _ = self._make_painter()
        _draw_element(p, Group(children=(
            Rect(x=0, y=0, width=20, height=20, fill=Fill(color=Color(1, 0, 0))),
            Circle(cx=50, cy=50, r=10),
        )))
        p.end()

    def test_draw_layer(self):
        p, _ = self._make_painter()
        _draw_element(p, Layer(name="L1", children=(
            Line(x1=0, y1=0, x2=100, y2=100, stroke=Stroke(color=Color(0, 0, 0))),
        )))
        p.end()

    def test_draw_with_transform(self):
        p, _ = self._make_painter()
        _draw_element(p, Rect(x=0, y=0, width=20, height=20,
                              fill=Fill(color=Color(1, 0, 0)),
                              transform=Transform.translate(10, 10)))
        p.end()

    def test_draw_with_opacity(self):
        p, _ = self._make_painter()
        _draw_element(p, Rect(x=0, y=0, width=20, height=20,
                              fill=Fill(color=Color(1, 0, 0)),
                              opacity=0.5))
        p.end()

    def test_draw_empty_polyline(self):
        p, _ = self._make_painter()
        _draw_element(p, Polyline(points=()))
        p.end()

    def test_draw_empty_polygon(self):
        p, _ = self._make_painter()
        _draw_element(p, Polygon(points=()))
        p.end()

    def test_draw_empty_path(self):
        p, _ = self._make_painter()
        _draw_element(p, Path(d=()))
        p.end()

    def test_draw_no_fill_no_stroke(self):
        p, _ = self._make_painter()
        _draw_element(p, Rect(x=0, y=0, width=20, height=20))
        p.end()


if __name__ == "__main__":
    absltest.main()
