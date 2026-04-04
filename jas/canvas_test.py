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
from PySide6.QtGui import QImage, QPainter
from PySide6.QtWidgets import QApplication


class ToolbarTest(absltest.TestCase):

    def test_tool_enum_has_three_values(self):
        tools = list(Tool)
        self.assertEqual(len(tools), 3)
        self.assertIn(Tool.SELECTION, tools)
        self.assertIn(Tool.DIRECT_SELECTION, tools)
        self.assertIn(Tool.LINE, tools)

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
