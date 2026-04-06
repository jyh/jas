"""Tool interaction tests: verify tool state machines without a GUI.

Tests exercise on_press/on_move/on_release sequences and verify the
resulting document state.
"""

from absl.testing import absltest

from document.controller import Controller
from document.document import Document, ElementSelection, ElementPath
from document.model import Model
from geometry.element import (
    Color, Element, Fill, Layer, Line, Rect, Stroke,
    control_point_count,
)
from tools.tool import ToolContext


def _make_ctx(model: Model | None = None) -> tuple[ToolContext, Model, Controller]:
    """Create a ToolContext with a fresh model and controller."""
    if model is None:
        model = Model()
    ctrl = Controller(model)
    ctx = ToolContext(
        model=model,
        controller=ctrl,
        hit_test_selection=lambda x, y: False,
        hit_test_handle=lambda x, y: None,
        hit_test_text=lambda x, y: None,
        hit_test_path_curve=lambda x, y: None,
        request_update=lambda: None,
        start_text_edit=lambda path, elem: None,
        commit_text_edit=lambda: None,
    )
    return ctx, model, ctrl


def _layer_children(model: Model) -> tuple:
    return model.document.layers[0].children


class LineToolTest(absltest.TestCase):
    def test_draw_line(self):
        """Press at (10,20), release at (50,60) => creates a Line element."""
        from tools.drawing import LineTool
        tool = LineTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 10, 20)
        tool.on_move(ctx, 30, 40, dragging=True)
        tool.on_release(ctx, 50, 60)
        children = _layer_children(model)
        self.assertEqual(len(children), 1)
        elem = children[0]
        self.assertIsInstance(elem, Line)
        self.assertEqual(elem.x1, 10)
        self.assertEqual(elem.y1, 20)
        self.assertEqual(elem.x2, 50)
        self.assertEqual(elem.y2, 60)

    def test_zero_length_line_still_created(self):
        """Press and release at same point => degenerate line still created."""
        from tools.drawing import LineTool
        tool = LineTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 10, 20)
        tool.on_release(ctx, 10, 20)
        children = _layer_children(model)
        self.assertEqual(len(children), 1)
        elem = children[0]
        self.assertEqual(elem.x1, 10)
        self.assertEqual(elem.x2, 10)


class RectToolTest(absltest.TestCase):
    def test_draw_rect(self):
        """Press at (10,20), release at (110,70) => creates a Rect element."""
        from tools.drawing import RectTool
        tool = RectTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 10, 20)
        tool.on_release(ctx, 110, 70)
        children = _layer_children(model)
        self.assertEqual(len(children), 1)
        elem = children[0]
        self.assertIsInstance(elem, Rect)
        self.assertEqual(elem.x, 10)
        self.assertEqual(elem.y, 20)
        self.assertEqual(elem.width, 100)
        self.assertEqual(elem.height, 50)

    def test_zero_size_rect_still_created(self):
        """Press and release at same point => degenerate rect still created."""
        from tools.drawing import RectTool
        tool = RectTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 10, 20)
        tool.on_release(ctx, 10, 20)
        children = _layer_children(model)
        self.assertEqual(len(children), 1)
        self.assertEqual(children[0].width, 0)
        self.assertEqual(children[0].height, 0)

    def test_negative_drag_normalizes(self):
        """Dragging right-to-left and bottom-to-top normalizes coordinates."""
        from tools.drawing import RectTool
        tool = RectTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 100, 80)
        tool.on_release(ctx, 10, 20)
        children = _layer_children(model)
        self.assertEqual(len(children), 1)
        elem = children[0]
        self.assertEqual(elem.x, 10)
        self.assertEqual(elem.y, 20)
        self.assertEqual(elem.width, 90)
        self.assertEqual(elem.height, 60)


class SelectionToolTest(absltest.TestCase):
    def test_marquee_select(self):
        """Drag marquee over an element => element is selected."""
        from tools.selection import SelectionTool
        tool = SelectionTool()
        rect = Rect(x=50, y=50, width=20, height=20,
                    fill=Fill(Color(0, 0, 0)), stroke=None)
        layer = Layer(name="L", children=(rect,))
        doc = Document(layers=(layer,), selection=frozenset())
        model = Model(document=doc)
        ctx, model, ctrl = _make_ctx(model)
        # Marquee covering the rect
        tool.on_press(ctx, 45, 45)
        tool.on_release(ctx, 75, 75)
        self.assertGreater(len(model.document.selection), 0)

    def test_marquee_miss(self):
        """Drag marquee away from element => nothing selected."""
        from tools.selection import SelectionTool
        tool = SelectionTool()
        rect = Rect(x=50, y=50, width=20, height=20,
                    fill=Fill(Color(0, 0, 0)), stroke=None)
        layer = Layer(name="L", children=(rect,))
        doc = Document(layers=(layer,), selection=frozenset())
        model = Model(document=doc)
        ctx, model, ctrl = _make_ctx(model)
        tool.on_press(ctx, 0, 0)
        tool.on_release(ctx, 10, 10)
        self.assertEqual(len(model.document.selection), 0)

    def test_move_selection(self):
        """Press on selected element, drag => element moves."""
        from tools.selection import SelectionTool
        tool = SelectionTool()
        rect = Rect(x=50, y=50, width=20, height=20,
                    fill=Fill(Color(0, 0, 0)), stroke=None)
        layer = Layer(name="L", children=(rect,))
        sel = frozenset({ElementSelection(
            path=(0, 0), control_points=frozenset(range(4)))})
        doc = Document(layers=(layer,), selection=sel)
        model = Model(document=doc)
        # Hit test returns True when clicking on selection
        ctx, model, ctrl = _make_ctx(model)
        ctx.hit_test_selection = lambda x, y: True
        tool.on_press(ctx, 60, 60)
        tool.on_move(ctx, 70, 70, dragging=True)
        tool.on_release(ctx, 70, 70)
        moved = model.document.layers[0].children[0]
        self.assertEqual(moved.x, 60)
        self.assertEqual(moved.y, 60)


class ToolStateTest(absltest.TestCase):
    def test_idle_after_release(self):
        """Tool returns to idle state after release."""
        from tools.drawing import LineTool
        tool = LineTool()
        ctx, model, ctrl = _make_ctx()
        self.assertIsNone(tool._drag_start)
        tool.on_press(ctx, 10, 20)
        self.assertIsNotNone(tool._drag_start)
        tool.on_release(ctx, 50, 60)
        self.assertIsNone(tool._drag_start)

    def test_move_without_press_is_noop(self):
        """on_move without prior on_press does nothing."""
        from tools.drawing import LineTool
        tool = LineTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_move(ctx, 50, 60, dragging=True)
        self.assertIsNone(tool._drag_start)


class PolygonToolTest(absltest.TestCase):
    def test_draw_polygon(self):
        """Press-release creates a polygon."""
        from tools.drawing import PolygonTool
        from geometry.element import Polygon
        tool = PolygonTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 50, 50)
        tool.on_release(ctx, 100, 50)
        children = _layer_children(model)
        self.assertEqual(len(children), 1)
        self.assertIsInstance(children[0], Polygon)
        self.assertEqual(len(children[0].points), 5)  # default POLYGON_SIDES


if __name__ == '__main__':
    absltest.main()
