from absl.testing import absltest

from tools.toolbar import Tool
from canvas.canvas import BoundingBox, CanvasWidget, _draw_element, _build_path
from document.controller import Controller
from document.document import Document
from geometry.element import (
    Circle, RgbColor, CurveTo, ClosePath, Ellipse, Fill, Group, Layer, Line,
    LineTo, MoveTo, Path, Polygon, Polyline, QuadTo, Rect, SmoothCurveTo,
    SmoothQuadTo, Stroke, Text, TextPath, Transform,
)
from document.model import Model
from PySide6.QtCore import QPointF, Qt
from PySide6.QtGui import QImage, QPainter
from PySide6.QtWidgets import QApplication


class ToolbarTest(absltest.TestCase):

    def test_tool_enum_values(self):
        tools = list(Tool)
        self.assertEqual(len(tools), 29)
        self.assertIn(Tool.SELECTION, tools)
        self.assertIn(Tool.PARTIAL_SELECTION, tools)
        self.assertIn(Tool.INTERIOR_SELECTION, tools)
        self.assertIn(Tool.MAGIC_WAND, tools)
        self.assertIn(Tool.PEN, tools)
        self.assertIn(Tool.ADD_ANCHOR_POINT, tools)
        self.assertIn(Tool.DELETE_ANCHOR_POINT, tools)
        self.assertIn(Tool.ANCHOR_POINT, tools)
        self.assertIn(Tool.PENCIL, tools)
        self.assertIn(Tool.PAINTBRUSH, tools)
        self.assertIn(Tool.BLOB_BRUSH, tools)
        self.assertIn(Tool.PATH_ERASER, tools)
        self.assertIn(Tool.SMOOTH, tools)
        self.assertIn(Tool.TYPE, tools)
        self.assertIn(Tool.TYPE_ON_PATH, tools)
        self.assertIn(Tool.LINE, tools)
        self.assertIn(Tool.RECT, tools)
        self.assertIn(Tool.ROUNDED_RECT, tools)
        self.assertIn(Tool.POLYGON, tools)
        self.assertIn(Tool.STAR, tools)
        self.assertIn(Tool.LASSO, tools)
        self.assertIn(Tool.SCALE, tools)
        self.assertIn(Tool.ROTATE, tools)
        self.assertIn(Tool.SHEAR, tools)
        self.assertIn(Tool.HAND, tools)
        self.assertIn(Tool.ZOOM, tools)
        self.assertIn(Tool.EYEDROPPER, tools)



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
        model.set_document_unbracketed(Document(layers=()))

    def test_filename_on_model(self):
        model = Model()
        canvas = self._make_canvas(model)
        model.filename = "New Name"
        self.assertEqual(model.filename, "New Name")

    def test_set_tool(self):
        canvas = self._make_canvas()
        canvas.set_tool(Tool.LINE)
        self.assertEqual(canvas._current_tool_enum, Tool.LINE)
        canvas.set_tool(Tool.RECT)
        self.assertEqual(canvas._current_tool_enum, Tool.RECT)

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
        model.set_document_unbracketed(Document(
            layers=(Layer(name="L1", children=(
                Line(x1=0, y1=0, x2=1, y2=1, stroke=Stroke(color=RgbColor(0, 0, 0))),
            )),),
        ))
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
                              stroke=Stroke(color=RgbColor(0, 0, 0))))
        p.end()

    def test_draw_rect(self):
        p, _ = self._make_painter()
        _draw_element(p, Rect(x=10, y=10, width=30, height=20,
                              fill=Fill(color=RgbColor(1, 0, 0))))
        p.end()

    def test_draw_rect_rounded(self):
        p, _ = self._make_painter()
        _draw_element(p, Rect(x=10, y=10, width=30, height=20, rx=5, ry=5,
                              fill=Fill(color=RgbColor(0, 1, 0))))
        p.end()

    def test_draw_circle(self):
        p, _ = self._make_painter()
        _draw_element(p, Circle(cx=50, cy=50, r=20,
                                fill=Fill(color=RgbColor(0, 0, 1)),
                                stroke=Stroke(color=RgbColor(0, 0, 0))))
        p.end()

    def test_draw_ellipse(self):
        p, _ = self._make_painter()
        _draw_element(p, Ellipse(cx=50, cy=50, rx=30, ry=15,
                                 fill=Fill(color=RgbColor(1, 1, 0))))
        p.end()

    def test_draw_polyline(self):
        p, _ = self._make_painter()
        _draw_element(p, Polyline(points=((0, 0), (50, 25), (100, 0)),
                                  stroke=Stroke(color=RgbColor(0, 0, 0))))
        p.end()

    def test_draw_polygon(self):
        p, _ = self._make_painter()
        _draw_element(p, Polygon(points=((10, 10), (90, 10), (50, 90)),
                                 fill=Fill(color=RgbColor(0, 1, 1))))
        p.end()

    def test_draw_path(self):
        p, _ = self._make_painter()
        _draw_element(p, Path(d=(
            MoveTo(10, 10),
            LineTo(50, 10),
            CurveTo(60, 10, 70, 30, 50, 50),
            QuadTo(30, 70, 10, 50),
            ClosePath(),
        ), fill=Fill(color=RgbColor(0.5, 0.5, 0.5))))
        p.end()

    def test_draw_path_smooth(self):
        p, _ = self._make_painter()
        _draw_element(p, Path(d=(
            MoveTo(10, 50),
            CurveTo(20, 10, 40, 10, 50, 50),
            SmoothCurveTo(80, 90, 90, 50),
            QuadTo(70, 20, 50, 50),
            SmoothQuadTo(30, 50),
        ), stroke=Stroke(color=RgbColor(0, 0, 0))))
        p.end()

    def test_draw_text(self):
        p, _ = self._make_painter()
        _draw_element(p, Text(x=10, y=50, content="Hello",
                              fill=Fill(color=RgbColor(0, 0, 0))))
        p.end()

    def test_draw_group(self):
        p, _ = self._make_painter()
        _draw_element(p, Group(children=(
            Rect(x=0, y=0, width=20, height=20, fill=Fill(color=RgbColor(1, 0, 0))),
            Circle(cx=50, cy=50, r=10),
        )))
        p.end()

    def test_draw_layer(self):
        p, _ = self._make_painter()
        _draw_element(p, Layer(name="L1", children=(
            Line(x1=0, y1=0, x2=100, y2=100, stroke=Stroke(color=RgbColor(0, 0, 0))),
        )))
        p.end()

    def test_draw_with_transform(self):
        p, _ = self._make_painter()
        _draw_element(p, Rect(x=0, y=0, width=20, height=20,
                              fill=Fill(color=RgbColor(1, 0, 0)),
                              transform=Transform.translate(10, 10)))
        p.end()

    def test_draw_with_opacity(self):
        p, _ = self._make_painter()
        _draw_element(p, Rect(x=0, y=0, width=20, height=20,
                              fill=Fill(color=RgbColor(1, 0, 0)),
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


class MaskPlanTest(absltest.TestCase):
    """Test the _mask_plan helper from OPACITY.md §Rendering."""

    def _mask(self, clip, invert, disabled):
        from geometry.element import Mask, Group
        return Mask(
            subtree=Group(children=()),
            clip=clip, invert=invert, disabled=disabled,
            linked=True, unlink_transform=None,
        )

    def test_clip_not_inverted_is_clip_in(self):
        from canvas.canvas import _mask_plan, MaskPlan
        self.assertEqual(
            _mask_plan(self._mask(True, False, False)),
            MaskPlan.CLIP_IN,
        )

    def test_clip_inverted_is_clip_out(self):
        from canvas.canvas import _mask_plan, MaskPlan
        self.assertEqual(
            _mask_plan(self._mask(True, True, False)),
            MaskPlan.CLIP_OUT,
        )

    def test_disabled_is_none(self):
        # disabled overrides both clip and invert: falls back to no
        # mask rendering per OPACITY.md §States.
        from canvas.canvas import _mask_plan
        for clip, invert in [(True, False), (True, True),
                             (False, False), (False, True)]:
            self.assertIsNone(
                _mask_plan(self._mask(clip, invert, True)))

    def test_no_clip_no_invert_is_reveal_outside_bbox(self):
        # Phase 2: clip=false, invert=false keeps the element
        # visible outside the mask subtree's bounding box.
        from canvas.canvas import _mask_plan, MaskPlan
        self.assertEqual(
            _mask_plan(self._mask(False, False, False)),
            MaskPlan.REVEAL_OUTSIDE_BBOX,
        )

    def test_no_clip_inverted_collapses_to_clip_out(self):
        # Alpha-based mask: `clip: false, invert: true` gives the
        # same output as `clip: true, invert: true` because the
        # mask's outside-region alpha is zero either way.
        from canvas.canvas import _mask_plan, MaskPlan
        self.assertEqual(
            _mask_plan(self._mask(False, True, False)),
            MaskPlan.CLIP_OUT,
        )


class EffectiveMaskTransformTest(absltest.TestCase):
    """Test the _effective_mask_transform helper — Track C phase 3,
    OPACITY.md §Document model."""

    def _mask(self, linked, unlink):
        from geometry.element import Mask, Group
        return Mask(
            subtree=Group(children=()),
            clip=True, invert=False, disabled=False,
            linked=linked, unlink_transform=unlink,
        )

    def _xform(self, e, f):
        # Pure translation by (e, f) for easy identification.
        from geometry.element import Transform
        return Transform(a=1.0, b=0.0, c=0.0, d=1.0, e=e, f=f)

    def _rect(self, transform):
        return Rect(x=0, y=0, width=10, height=10, transform=transform)

    def test_linked_returns_element_transform(self):
        # linked=True: mask follows the element, so the renderer
        # should apply elem.transform.
        from canvas.canvas import _effective_mask_transform
        mask = self._mask(linked=True, unlink=None)
        elem = self._rect(self._xform(5, 7))
        t = _effective_mask_transform(mask, elem)
        self.assertIsNotNone(t)
        self.assertEqual(t.e, 5)
        self.assertEqual(t.f, 7)

    def test_linked_none_when_element_has_no_transform(self):
        # linked=True with no element transform: None.
        from canvas.canvas import _effective_mask_transform
        mask = self._mask(linked=True, unlink=None)
        elem = self._rect(None)
        self.assertIsNone(_effective_mask_transform(mask, elem))

    def test_unlinked_returns_captured_unlink_transform(self):
        # linked=False: mask stays frozen under unlink-time transform,
        # regardless of the element's current transform.
        from canvas.canvas import _effective_mask_transform
        mask = self._mask(linked=False, unlink=self._xform(3, 4))
        elem = self._rect(self._xform(100, 100))
        t = _effective_mask_transform(mask, elem)
        self.assertIsNotNone(t)
        self.assertEqual(t.e, 3)
        self.assertEqual(t.f, 4)

    def test_unlinked_none_when_unlink_missing(self):
        # linked=False with no captured transform: None.
        from canvas.canvas import _effective_mask_transform
        mask = self._mask(linked=False, unlink=None)
        elem = self._rect(self._xform(7, 8))
        self.assertIsNone(_effective_mask_transform(mask, elem))


class ArcToBeziersTest(absltest.TestCase):
    """Tests for _arc_to_beziers arc-to-cubic conversion."""

    def test_90_degree_arc_produces_segments(self):
        from canvas.canvas import _arc_to_beziers
        # Quarter circle: start at (10,0), end at (0,10), radius 10
        result = _arc_to_beziers(10, 0, 10, 10, 0, False, True, 0, 10)
        self.assertGreaterEqual(len(result), 1)

    def test_zero_radius_returns_empty(self):
        from canvas.canvas import _arc_to_beziers
        result = _arc_to_beziers(0, 0, 0, 0, 0, False, False, 10, 10)
        self.assertEqual(result, [])

    def test_segment_tuple_structure(self):
        from canvas.canvas import _arc_to_beziers
        result = _arc_to_beziers(10, 0, 10, 10, 0, False, True, 0, 10)
        for seg in result:
            self.assertIsInstance(seg, tuple)
            self.assertEqual(len(seg), 6)
            for coord in seg:
                self.assertIsInstance(coord, float)


class BuildPathTest(absltest.TestCase):
    """Tests for _build_path QPainterPath construction."""

    def test_moveto_lineto(self):
        path = _build_path((MoveTo(0, 0), LineTo(50, 50)))
        self.assertFalse(path.isEmpty())

    def test_curveto(self):
        path = _build_path((MoveTo(0, 0), CurveTo(10, 0, 20, 10, 30, 30)))
        self.assertFalse(path.isEmpty())

    def test_closepath(self):
        path = _build_path((
            MoveTo(0, 0), LineTo(50, 0), LineTo(50, 50), ClosePath(),
        ))
        self.assertFalse(path.isEmpty())


class VisibilityDrawTest(absltest.TestCase):
    """Smoke tests for visibility modes in _draw_element."""

    def _make_painter(self):
        img = QImage(100, 100, QImage.Format_ARGB32)
        painter = QPainter(img)
        return painter, img

    def test_draw_invisible_element(self):
        from geometry.element import Visibility
        p, _ = self._make_painter()
        elem = Rect(x=0, y=0, width=20, height=20,
                    fill=Fill(color=RgbColor(1, 0, 0)),
                    visibility=Visibility.INVISIBLE)
        _draw_element(p, elem)
        p.end()

    def test_draw_outline_element(self):
        from geometry.element import Visibility
        p, _ = self._make_painter()
        elem = Rect(x=0, y=0, width=20, height=20,
                    fill=Fill(color=RgbColor(1, 0, 0)),
                    visibility=Visibility.OUTLINE)
        _draw_element(p, elem)
        p.end()


class ArtboardDrawTest(absltest.TestCase):
    """Smoke tests for Phase D+E artboard Z-layer passes — ARTBOARDS.md
    §Canvas appearance. Verifies each draw helper executes without
    error against a synthetic document."""

    @classmethod
    def setUpClass(cls):
        # drawText needs a QApplication for font layout machinery.
        if not QApplication.instance():
            cls.app = QApplication([])

    def _make_painter(self):
        img = QImage(200, 200, QImage.Format_ARGB32)
        painter = QPainter(img)
        return painter, img

    def _doc_with_artboards(self, *artboards, fade=True):
        import dataclasses
        from document.artboard import ArtboardOptions
        return Document(
            artboards=tuple(artboards),
            artboard_options=ArtboardOptions(
                fade_region_outside_artboard=fade,
                update_while_dragging=True,
            ),
        )

    def test_draw_artboard_fills_transparent_skips(self):
        import dataclasses
        from canvas.canvas import _draw_artboard_fills
        from document.artboard import Artboard
        a = dataclasses.replace(Artboard.default_with_id("aaaa0001"),
                                 fill="transparent")
        doc = self._doc_with_artboards(a)
        p, _ = self._make_painter()
        _draw_artboard_fills(p, doc)
        p.end()

    def test_draw_artboard_fills_colored(self):
        import dataclasses
        from canvas.canvas import _draw_artboard_fills
        from document.artboard import Artboard
        a = dataclasses.replace(Artboard.default_with_id("aaaa0001"),
                                 fill="#ff0000", x=10, y=10,
                                 width=50, height=50)
        doc = self._doc_with_artboards(a)
        p, _ = self._make_painter()
        _draw_artboard_fills(p, doc)
        p.end()

    def test_draw_fade_overlay_on(self):
        import dataclasses
        from canvas.canvas import _draw_fade_overlay
        from document.artboard import Artboard
        a = dataclasses.replace(Artboard.default_with_id("aaaa0001"),
                                 x=20, y=20, width=100, height=100)
        doc = self._doc_with_artboards(a, fade=True)
        p, _ = self._make_painter()
        _draw_fade_overlay(p, doc, 200, 200)
        p.end()

    def test_draw_fade_overlay_off_noop(self):
        import dataclasses
        from canvas.canvas import _draw_fade_overlay
        from document.artboard import Artboard
        a = dataclasses.replace(Artboard.default_with_id("aaaa0001"),
                                 x=20, y=20, width=100, height=100)
        doc = self._doc_with_artboards(a, fade=False)
        p, _ = self._make_painter()
        _draw_fade_overlay(p, doc, 200, 200)
        p.end()

    def test_draw_artboard_borders(self):
        import dataclasses
        from canvas.canvas import _draw_artboard_borders
        from document.artboard import Artboard
        a = dataclasses.replace(Artboard.default_with_id("aaaa0001"),
                                 x=0, y=0, width=50, height=50)
        doc = self._doc_with_artboards(a)
        p, _ = self._make_painter()
        _draw_artboard_borders(p, doc)
        p.end()

    def test_draw_artboard_accent_selected(self):
        import dataclasses
        from canvas.canvas import _draw_artboard_accent
        from document.artboard import Artboard
        a = dataclasses.replace(Artboard.default_with_id("aaaa0001"),
                                 x=0, y=0, width=50, height=50)
        b = dataclasses.replace(Artboard.default_with_id("bbbb0002"),
                                 x=60, y=0, width=50, height=50)
        doc = self._doc_with_artboards(a, b)
        p, _ = self._make_painter()
        _draw_artboard_accent(p, doc, ["bbbb0002"])
        p.end()

    def test_draw_artboard_accent_empty_selection_noop(self):
        import dataclasses
        from canvas.canvas import _draw_artboard_accent
        from document.artboard import Artboard
        a = dataclasses.replace(Artboard.default_with_id("aaaa0001"),
                                 x=0, y=0, width=50, height=50)
        doc = self._doc_with_artboards(a)
        p, _ = self._make_painter()
        _draw_artboard_accent(p, doc, [])
        p.end()

    def test_draw_artboard_labels(self):
        import dataclasses
        from canvas.canvas import _draw_artboard_labels
        from document.artboard import Artboard
        a = dataclasses.replace(Artboard.default_with_id("aaaa0001"),
                                 name="Cover",
                                 x=20, y=20, width=80, height=80)
        doc = self._doc_with_artboards(a)
        p, _ = self._make_painter()
        _draw_artboard_labels(p, doc)
        p.end()

    def test_draw_artboard_display_marks_all_on(self):
        import dataclasses
        from canvas.canvas import _draw_artboard_display_marks
        from document.artboard import Artboard
        a = dataclasses.replace(
            Artboard.default_with_id("aaaa0001"),
            x=10, y=10, width=100, height=80,
            show_center_mark=True, show_cross_hairs=True,
            show_video_safe_areas=True,
        )
        doc = self._doc_with_artboards(a)
        p, _ = self._make_painter()
        _draw_artboard_display_marks(p, doc)
        p.end()


class SelectionHandleRectsTest(absltest.TestCase):
    """The selection control-point handles must be FIXED SIZE — the element's
    transform moves the handle positions but never scales the handle glyphs.
    `selection_handle_rects(doc, path)` returns document-space rects whose
    CENTER is the element-transformed control point and whose SIZE is the
    constant HANDLE_DRAW_SIZE (NOT multiplied by the element transform).
    """

    def _doc_with(self, elem):
        from document.document import Document, ElementSelection
        layer = Layer(children=(elem,), name="L0")
        sel = frozenset({ElementSelection.all((0, 0))})
        return Document(layers=(layer,), selection=sel)

    def test_identity_transform_handles_at_control_points(self):
        from canvas.canvas import selection_handle_rects, _HANDLE_SIZE
        rect = Rect(x=10, y=20, width=30, height=40)
        rects = selection_handle_rects(self._doc_with(rect), (0, 0))
        half = _HANDLE_SIZE / 2
        centers = sorted((x + half, y + half) for (x, y, w, h) in rects)
        self.assertEqual(
            centers, sorted([(10, 20), (40, 20), (40, 60), (10, 60)]))
        for (_x, _y, w, h) in rects:
            self.assertEqual((w, h), (_HANDLE_SIZE, _HANDLE_SIZE))

    def test_scaled_element_handles_move_but_do_not_grow(self):
        from canvas.canvas import selection_handle_rects, _HANDLE_SIZE
        # 100x100 rect at origin with a 2x scale transform.
        rect = Rect(x=0, y=0, width=100, height=100,
                    transform=Transform(2, 0, 0, 2, 0, 0))
        rects = selection_handle_rects(self._doc_with(rect), (0, 0))
        half = _HANDLE_SIZE / 2
        # Positions are the TRANSFORMED corners: (0,0),(200,0),(200,200),(0,200).
        centers = sorted((x + half, y + half) for (x, y, w, h) in rects)
        self.assertEqual(
            centers, sorted([(0, 0), (200, 0), (200, 200), (0, 200)]))
        # CRITICAL: each handle is still HANDLE_DRAW_SIZE, NOT 2x.
        for (_x, _y, w, h) in rects:
            self.assertEqual((w, h), (_HANDLE_SIZE, _HANDLE_SIZE))

    def test_no_handles_for_group(self):
        from canvas.canvas import selection_handle_rects
        from document.document import Document, ElementSelection
        grp = Group(children=(Rect(x=0, y=0, width=10, height=10),))
        layer = Layer(children=(grp,), name="L0")
        doc = Document(layers=(layer,),
                       selection=frozenset({ElementSelection.all((0, 0))}))
        self.assertEqual(selection_handle_rects(doc, (0, 0)), [])


class ElementStrokeCounterScaleTest(absltest.TestCase):
    """An element's own STROKE is drawn under the element transform, so the
    matrix would scale the stroke width (on top of any scale_strokes bake) —
    a double-scale. `_counter_scaled_element(elem, element_scale)` divides the
    stroke width by the combined element-transform scale (= element_scale *
    sqrt(|det|)) so the element transform never thickens the stroke (it stays
    zoom-scaled). `transform_scale_factor(t)` is the per-transform sqrt(|det|).
    """

    def test_transform_scale_factor(self):
        from canvas.canvas import transform_scale_factor
        self.assertEqual(transform_scale_factor(None), 1.0)
        self.assertEqual(transform_scale_factor(Transform(2, 0, 0, 2, 0, 0)), 2.0)
        # det = 2 * 8 = 16 -> sqrt = 4.
        self.assertEqual(transform_scale_factor(Transform(2, 0, 0, 8, 0, 0)), 4.0)

    def test_stroke_divided_by_element_scale(self):
        from canvas.canvas import _counter_scaled_element
        rect = Rect(x=0, y=0, width=100, height=100,
                    stroke=Stroke(color=RgbColor(0, 0, 0), width=4.0),
                    transform=Transform(2, 0, 0, 2, 0, 0))
        out, scale = _counter_scaled_element(rect, 1.0)
        self.assertEqual(scale, 2.0)
        self.assertEqual(out.stroke.width, 2.0)  # 4 / 2

    def test_no_transform_unchanged(self):
        from canvas.canvas import _counter_scaled_element
        rect = Rect(x=0, y=0, width=10, height=10,
                    stroke=Stroke(color=RgbColor(0, 0, 0), width=4.0))
        out, scale = _counter_scaled_element(rect, 1.0)
        self.assertEqual(scale, 1.0)
        self.assertIs(out, rect)  # no copy when there is no scale
        self.assertEqual(out.stroke.width, 4.0)

    def test_accumulates_with_parent_scale(self):
        from canvas.canvas import _counter_scaled_element
        # Stroked rect with its own 2x, inside a parent already at 3x.
        rect = Rect(x=0, y=0, width=10, height=10,
                    stroke=Stroke(color=RgbColor(0, 0, 0), width=12.0),
                    transform=Transform(2, 0, 0, 2, 0, 0))
        out, scale = _counter_scaled_element(rect, 3.0)
        self.assertEqual(scale, 6.0)        # 3 * 2
        self.assertEqual(out.stroke.width, 2.0)  # 12 / 6


class SelectionOutlineScaleTest(absltest.TestCase):
    """The selection OUTLINE + bezier handles are drawn under the element
    transform; their fixed pen widths / radii are divided by
    `selection_outline_scale(doc, path)` (= sqrt(|det|) of the combined
    transform) so the element transform never thickens them. 1x for no
    transform, 2x for a uniform 2x scale, geometric mean for non-uniform.
    """

    def _doc_with(self, elem):
        from document.document import Document, ElementSelection
        layer = Layer(children=(elem,), name="L0")
        return Document(layers=(layer,),
                        selection=frozenset({ElementSelection.all((0, 0))}))

    def test_identity_scale_is_one(self):
        from canvas.canvas import selection_outline_scale
        rect = Rect(x=0, y=0, width=10, height=10)
        self.assertEqual(
            selection_outline_scale(self._doc_with(rect), (0, 0)), 1.0)

    def test_uniform_2x_scale(self):
        from canvas.canvas import selection_outline_scale
        rect = Rect(x=0, y=0, width=10, height=10,
                    transform=Transform(2, 0, 0, 2, 0, 0))
        self.assertEqual(
            selection_outline_scale(self._doc_with(rect), (0, 0)), 2.0)

    def test_nonuniform_geometric_mean(self):
        from canvas.canvas import selection_outline_scale
        # det = 2 * 8 = 16 -> sqrt = 4.
        rect = Rect(x=0, y=0, width=10, height=10,
                    transform=Transform(2, 0, 0, 8, 0, 0))
        self.assertEqual(
            selection_outline_scale(self._doc_with(rect), (0, 0)), 4.0)


if __name__ == "__main__":
    absltest.main()
