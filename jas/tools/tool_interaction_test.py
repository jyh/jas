"""Tool interaction tests: verify tool state machines without a GUI.

Tests exercise on_press/on_move/on_release sequences and verify the
resulting document state.
"""

from absl.testing import absltest

from document.controller import Controller
from document.document import Document, ElementSelection, ElementPath
from document.model import Model
from geometry.element import (
    Color, CurveTo, Element, Fill, Layer, Line, LineTo, MoveTo, Path, Rect, Stroke,
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


class AddAnchorPointToolTest(absltest.TestCase):
    def _make_path_doc(self):
        """Create a document with a single straight-line cubic path."""
        path_elem = Path(
            d=(MoveTo(0, 0), CurveTo(33, 0, 67, 0, 100, 0)),
            stroke=Stroke(Color(0, 0, 0), 1.0),
        )
        layer = Layer(name="L", children=(path_elem,))
        doc = Document(layers=(layer,), selection=frozenset())
        return doc

    def _make_ctx_with_path_hit(self, model, path_elem):
        """Create a ToolContext whose hit_test_path_curve returns the path."""
        ctx, model, ctrl = _make_ctx(model)
        ctx.hit_test_path_curve = lambda x, y: ((0, 0), path_elem) if abs(y) < 20 else None
        return ctx, model, ctrl

    def test_click_on_path_adds_point(self):
        """Clicking on a path splits the curve into two segments."""
        from tools.add_anchor_point import AddAnchorPointTool
        tool = AddAnchorPointTool()
        doc = self._make_path_doc()
        model = Model(document=doc)
        path_elem = model.document.layers[0].children[0]
        ctx, model, ctrl = self._make_ctx_with_path_hit(model, path_elem)
        # Click at midpoint of the path
        tool.on_press(ctx, 50, 0)
        tool.on_release(ctx, 50, 0)
        children = _layer_children(model)
        self.assertEqual(len(children), 1)
        path = children[0]
        self.assertIsInstance(path, Path)
        # Original: MoveTo + 1 CurveTo = 2 commands
        # After split: MoveTo + 2 CurveTos = 3 commands
        self.assertEqual(len(path.d), 3)
        self.assertIsInstance(path.d[0], MoveTo)
        self.assertIsInstance(path.d[1], CurveTo)
        self.assertIsInstance(path.d[2], CurveTo)

    def test_click_away_from_path_does_nothing(self):
        """Clicking far from any path does not modify the document."""
        from tools.add_anchor_point import AddAnchorPointTool
        tool = AddAnchorPointTool()
        doc = self._make_path_doc()
        model = Model(document=doc)
        path_elem = model.document.layers[0].children[0]
        ctx, model, ctrl = self._make_ctx_with_path_hit(model, path_elem)
        tool.on_press(ctx, 50, 100)  # far from the path at y=0
        tool.on_release(ctx, 50, 100)
        children = _layer_children(model)
        path = children[0]
        self.assertEqual(len(path.d), 2)  # unchanged

    def test_split_preserves_endpoints(self):
        """After splitting, the first segment ends near the click and the
        second segment ends at the original endpoint."""
        from tools.add_anchor_point import AddAnchorPointTool
        tool = AddAnchorPointTool()
        doc = self._make_path_doc()
        model = Model(document=doc)
        path_elem = model.document.layers[0].children[0]
        ctx, model, ctrl = self._make_ctx_with_path_hit(model, path_elem)
        tool.on_press(ctx, 50, 0)
        tool.on_release(ctx, 50, 0)
        path = _layer_children(model)[0]
        # First new CurveTo endpoint should be near (50, 0)
        self.assertAlmostEqual(path.d[1].x, 50.0, delta=1.0)
        self.assertAlmostEqual(path.d[1].y, 0.0, delta=1.0)
        # Second CurveTo endpoint should be (100, 0)
        self.assertAlmostEqual(path.d[2].x, 100.0, delta=0.01)
        self.assertAlmostEqual(path.d[2].y, 0.0, delta=0.01)

    def test_drag_adjusts_handles(self):
        """Press on path, drag to adjust handles, then release."""
        from tools.add_anchor_point import AddAnchorPointTool
        tool = AddAnchorPointTool()
        doc = self._make_path_doc()
        model = Model(document=doc)
        path_elem = model.document.layers[0].children[0]
        ctx, model, ctrl = self._make_ctx_with_path_hit(model, path_elem)
        # Press at midpoint to split, then drag upward
        tool.on_press(ctx, 50, 0)
        tool.on_move(ctx, 50, 20, dragging=True)
        tool.on_release(ctx, 50, 20)
        path = _layer_children(model)[0]
        self.assertEqual(len(path.d), 3)
        # Outgoing handle (x1, y1 of second CurveTo) should be at drag pos
        out_cmd = path.d[2]
        self.assertIsInstance(out_cmd, CurveTo)
        self.assertAlmostEqual(out_cmd.x1, 50.0, delta=0.01)
        self.assertAlmostEqual(out_cmd.y1, 20.0, delta=0.01)
        # Incoming handle (x2, y2 of first CurveTo) should be mirrored
        in_cmd = path.d[1]
        self.assertIsInstance(in_cmd, CurveTo)
        self.assertAlmostEqual(in_cmd.x2, 50.0, delta=0.01)
        self.assertAlmostEqual(in_cmd.y2, -20.0, delta=0.01)

    def test_drag_cusp_leaves_incoming_handle(self):
        """Alt+drag creates a cusp: only outgoing handle moves."""
        from tools.add_anchor_point import AddAnchorPointTool, _update_handles
        tool = AddAnchorPointTool()
        doc = self._make_path_doc()
        model = Model(document=doc)
        path_elem = model.document.layers[0].children[0]
        ctx, model, ctrl = self._make_ctx_with_path_hit(model, path_elem)
        # Press at midpoint to split the curve
        tool.on_press(ctx, 50, 0)
        # The split has happened; now test _update_handles with cusp=True
        path = _layer_children(model)[0]
        self.assertEqual(len(path.d), 3)
        # Record the incoming handle before the cusp update
        in_x2_before = path.d[1].x2
        in_y2_before = path.d[1].y2
        # Apply cusp update directly
        new_cmds = _update_handles(
            list(path.d), 1, 50.0, 0.0, 50.0, 20.0, cusp=True,
        )
        # Outgoing handle should be at drag position
        self.assertAlmostEqual(new_cmds[2].x1, 50.0, delta=0.01)
        self.assertAlmostEqual(new_cmds[2].y1, 20.0, delta=0.01)
        # Incoming handle should be unchanged (cusp)
        self.assertAlmostEqual(new_cmds[1].x2, in_x2_before, delta=0.01)
        self.assertAlmostEqual(new_cmds[1].y2, in_y2_before, delta=0.01)

    def test_insert_updates_selection_indices(self):
        """Inserting a point shifts selection CP indices so handles stay correct."""
        from tools.add_anchor_point import AddAnchorPointTool
        tool = AddAnchorPointTool()
        path_elem = Path(
            d=(MoveTo(0, 0), CurveTo(33, 0, 67, 0, 100, 0)),
            stroke=Stroke(Color(0, 0, 0), 1.0),
        )
        layer = Layer(name="L", children=(path_elem,))
        # Select the path with all CPs (indices 0 and 1)
        sel = frozenset({ElementSelection(
            path=(0, 0), control_points=frozenset({0, 1}))})
        doc = Document(layers=(layer,), selection=sel)
        model = Model(document=doc)
        ctx, model, ctrl = _make_ctx(model)
        ctx.hit_test_path_curve = lambda x, y: ((0, 0), path_elem) if abs(y) < 20 else None
        # Insert at midpoint
        tool.on_press(ctx, 50, 0)
        tool.on_release(ctx, 50, 0)
        # Path now has 3 anchors (indices 0, 1, 2)
        path = _layer_children(model)[0]
        self.assertEqual(len(path.d), 3)
        # Selection should have shifted: old {0,1} -> {0, 1(new), 2(was 1)}
        es = model.document.get_element_selection((0, 0))
        self.assertIsNotNone(es)
        self.assertEqual(es.control_points, frozenset({0, 1, 2}))

    def test_split_line_segment(self):
        """Splitting a LineTo segment produces two LineTos."""
        from tools.add_anchor_point import AddAnchorPointTool
        tool = AddAnchorPointTool()
        path_elem = Path(
            d=(MoveTo(0, 0), LineTo(100, 0)),
            stroke=Stroke(Color(0, 0, 0), 1.0),
        )
        layer = Layer(name="L", children=(path_elem,))
        doc = Document(layers=(layer,), selection=frozenset())
        model = Model(document=doc)
        ctx, model, ctrl = _make_ctx(model)
        ctx.hit_test_path_curve = lambda x, y: ((0, 0), path_elem) if abs(y) < 20 else None
        tool.on_press(ctx, 50, 0)
        tool.on_release(ctx, 50, 0)
        path = _layer_children(model)[0]
        self.assertEqual(len(path.d), 3)
        self.assertIsInstance(path.d[1], LineTo)
        self.assertIsInstance(path.d[2], LineTo)
        self.assertAlmostEqual(path.d[1].x, 50.0, delta=1.0)


if __name__ == '__main__':
    absltest.main()
