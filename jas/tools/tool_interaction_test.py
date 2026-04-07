"""Tool interaction tests: verify tool state machines without a GUI.

Tests exercise on_press/on_move/on_release sequences and verify the
resulting document state.
"""

from absl.testing import absltest

from document.controller import Controller
from document.document import Document, ElementSelection, ElementPath
from document.model import Model
from geometry.element import (
    Color, CurveTo, Element, Fill, Layer, Line, LineTo, MoveTo, Path, Polygon, Rect, Stroke,
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


class RoundedRectToolTest(absltest.TestCase):
    def test_draw_rounded_rect(self):
        """Press-drag-release creates a Rect with rx/ry set to default radius."""
        from tools.drawing import RoundedRectTool, ROUNDED_RECT_RADIUS
        tool = RoundedRectTool()
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
        self.assertEqual(elem.rx, ROUNDED_RECT_RADIUS)
        self.assertEqual(elem.ry, ROUNDED_RECT_RADIUS)

    def test_zero_size_not_created(self):
        """Press and release at same point => no element created."""
        from tools.drawing import RoundedRectTool
        tool = RoundedRectTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 10, 20)
        tool.on_release(ctx, 10, 20)
        children = _layer_children(model)
        self.assertEqual(len(children), 0)

    def test_radius_default_is_ten(self):
        from tools.drawing import ROUNDED_RECT_RADIUS
        self.assertEqual(ROUNDED_RECT_RADIUS, 10.0)


class StarToolTest(absltest.TestCase):
    def test_draw_star(self):
        """Press-drag-release creates a Polygon with 2 * STAR_POINTS vertices."""
        from tools.drawing import StarTool, STAR_POINTS
        tool = StarTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 10, 20)
        tool.on_release(ctx, 110, 120)
        children = _layer_children(model)
        self.assertEqual(len(children), 1)
        elem = children[0]
        self.assertIsInstance(elem, Polygon)
        self.assertEqual(len(elem.points), 2 * STAR_POINTS)

    def test_zero_size_not_created(self):
        """Press and release at same point => no element created."""
        from tools.drawing import StarTool
        tool = StarTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 10, 20)
        tool.on_release(ctx, 10, 20)
        children = _layer_children(model)
        self.assertEqual(len(children), 0)

    def test_first_vertex_at_top(self):
        """First vertex of the star should be at the top center of the box."""
        from tools.drawing import StarTool
        tool = StarTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 0, 0)
        tool.on_release(ctx, 100, 100)
        elem = _layer_children(model)[0]
        x, y = elem.points[0]
        self.assertAlmostEqual(x, 50.0)
        self.assertAlmostEqual(y, 0.0)

    def test_negative_drag_normalizes(self):
        """A drag from a high to a low corner still produces a valid star."""
        from tools.drawing import StarTool
        tool = StarTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 100, 100)
        tool.on_release(ctx, 0, 0)
        elem = _layer_children(model)[0]
        self.assertEqual(len(elem.points), 10)
        x, y = elem.points[0]
        self.assertAlmostEqual(x, 50.0)
        self.assertAlmostEqual(y, 0.0)

    def test_star_points_default_is_five(self):
        from tools.drawing import STAR_POINTS
        self.assertEqual(STAR_POINTS, 5)


class TypeToolTest(absltest.TestCase):
    def test_drag_creates_empty_area_text_and_session(self):
        """Drag larger than DRAG_THRESHOLD creates an empty area Text and starts an editing session."""
        from tools.type_tool import TypeTool
        from geometry.element import Text
        tool = TypeTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 10, 20)
        tool.on_release(ctx, 110, 70)
        children = _layer_children(model)
        self.assertEqual(len(children), 1)
        elem = children[0]
        self.assertIsInstance(elem, Text)
        self.assertEqual(elem.x, 10)
        self.assertEqual(elem.y, 20)
        self.assertEqual(elem.width, 100)
        self.assertEqual(elem.height, 50)
        self.assertEqual(elem.content, "")
        self.assertIsNotNone(tool.session)

    def test_click_creates_empty_point_text(self):
        """Click without drag creates an empty point text and starts an editing session."""
        from tools.type_tool import TypeTool
        from geometry.element import Text
        tool = TypeTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 30, 40)
        tool.on_release(ctx, 30, 40)
        children = _layer_children(model)
        self.assertEqual(len(children), 1)
        elem = children[0]
        self.assertIsInstance(elem, Text)
        self.assertEqual(elem.x, 30)
        self.assertEqual(elem.y, 40)
        self.assertEqual(elem.content, "")
        self.assertIsNotNone(tool.session)

    def test_click_on_existing_text_starts_session(self):
        """Click on existing text starts an in-place editing session on it."""
        from tools.type_tool import TypeTool
        from geometry.element import Text
        # Place an existing Text in the model so the tool's recursive
        # hit-test (which walks the document) finds it.
        existing = Text(x=0, y=0, content="hello",
                        fill=Fill(Color(0, 0, 0)))
        layer = Layer(name="L", children=(existing,))
        model = Model(document=Document(layers=(layer,)))
        ctx, model, ctrl = _make_ctx(model)
        tool = TypeTool()
        tool.on_press(ctx, 5, 5)
        tool.on_release(ctx, 5, 5)
        # No new element added
        self.assertEqual(len(_layer_children(model)), 1)
        self.assertIsNotNone(tool.session)
        self.assertEqual(tool.session.content, "hello")

    def test_typing_into_session_updates_model(self):
        """Keystrokes inside an open session are reflected in the model."""
        from tools.type_tool import TypeTool
        from tools.tool import KeyMods
        from geometry.element import Text
        tool = TypeTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 10, 10)
        tool.on_release(ctx, 10, 10)
        tool.on_key_event(ctx, "a", KeyMods())
        tool.on_key_event(ctx, "b", KeyMods())
        elem = _layer_children(model)[0]
        self.assertEqual(elem.content, "ab")

    def test_escape_ends_session_keeps_element(self):
        from tools.type_tool import TypeTool
        from tools.tool import KeyMods
        tool = TypeTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 10, 10)
        tool.on_release(ctx, 10, 10)
        tool.on_key_event(ctx, "Escape", KeyMods())
        self.assertIsNone(tool.session)
        # Empty element remains in the document.
        self.assertEqual(len(_layer_children(model)), 1)

    def test_idle_after_drag_release(self):
        """After drag-create the tool is in an editing session, drag state is None."""
        from tools.type_tool import TypeTool
        tool = TypeTool()
        ctx, model, ctrl = _make_ctx()
        self.assertIsNone(tool._drag)
        tool.on_press(ctx, 10, 20)
        self.assertIsNotNone(tool._drag)
        tool.on_release(ctx, 50, 60)
        self.assertIsNone(tool._drag)

    def test_move_without_press_is_noop(self):
        from tools.type_tool import TypeTool
        tool = TypeTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_move(ctx, 50, 60, dragging=True)
        self.assertIsNone(tool._drag)


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
        sel = frozenset({ElementSelection.all((0, 0))})
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
        from document.document import _SelectionAll
        layer = Layer(name="L", children=(path_elem,))
        # Select the path as a whole.
        sel = frozenset({ElementSelection.all((0, 0))})
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
        # Selection was `.all` and stays `.all` — the new anchor is included.
        es = model.document.get_element_selection((0, 0))
        self.assertIsNotNone(es)
        self.assertIsInstance(es.kind, _SelectionAll)

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


    def test_space_repositions_anchor_during_drag(self):
        """Holding Space during drag repositions the anchor instead of adjusting handles."""
        from tools.add_anchor_point import AddAnchorPointTool
        tool = AddAnchorPointTool()
        path_elem = Path(
            d=(MoveTo(0, 0), CurveTo(33, 0, 67, 0, 100, 0)),
            stroke=Stroke(Color(0, 0, 0), 1.0),
        )
        layer = Layer(name="L", children=(path_elem,))
        doc = Document(layers=(layer,), selection=frozenset())
        model = Model(document=doc)
        ctx, model, ctrl = _make_ctx(model)
        ctx.hit_test_path_curve = lambda x, y: ((0, 0), path_elem) if abs(y) < 20 else None

        # Insert point at midpoint
        tool.on_press(ctx, 50, 0)
        # Verify anchor is near (50, 0)
        self.assertIsNotNone(tool._drag)
        self.assertAlmostEqual(tool._drag.anchor_x, 50.0, delta=1.0)
        self.assertAlmostEqual(tool._drag.anchor_y, 0.0, delta=1.0)

        # Simulate Space key press, then drag to reposition
        from PySide6.QtCore import Qt
        tool.on_key(ctx, Qt.Key.Key_Space)
        tool.on_move(ctx, 60, 10, dragging=True)

        # Anchor should have moved by the delta (10, 10)
        self.assertAlmostEqual(tool._drag.anchor_x, 60.0, delta=1.0)
        self.assertAlmostEqual(tool._drag.anchor_y, 10.0, delta=1.0)

        # The new anchor command's endpoint should match
        path = _layer_children(model)[0]
        new_cmd = path.d[tool._drag.first_cmd_idx]
        self.assertIsInstance(new_cmd, CurveTo)
        self.assertAlmostEqual(new_cmd.x, 60.0, delta=1.0)
        self.assertAlmostEqual(new_cmd.y, 10.0, delta=1.0)

        # Release Space, drag further — should adjust handles, not reposition
        tool.on_key_release(ctx, Qt.Key.Key_Space)
        tool.on_move(ctx, 70, 20, dragging=True)

        # Anchor should NOT have moved
        self.assertAlmostEqual(tool._drag.anchor_x, 60.0, delta=1.0)
        self.assertAlmostEqual(tool._drag.anchor_y, 10.0, delta=1.0)

        # But the outgoing handle (x1 of next cmd) should reflect the drag
        path = _layer_children(model)[0]
        out_cmd = path.d[tool._drag.first_cmd_idx + 1]
        self.assertIsInstance(out_cmd, CurveTo)
        self.assertAlmostEqual(out_cmd.x1, 70.0, delta=1.0)
        self.assertAlmostEqual(out_cmd.y1, 20.0, delta=1.0)

        tool.on_release(ctx, 70, 20)


class PencilToolTest(absltest.TestCase):
    def test_freehand_draw_creates_path(self):
        """Dragging creates a path with MoveTo + CurveTo segments."""
        from tools.pencil import PencilTool
        tool = PencilTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 0, 0)
        for i in range(1, 21):
            tool.on_move(ctx, i * 5.0, (i * 0.1) * 20.0, dragging=True)
        tool.on_release(ctx, 100, 0)
        children = _layer_children(model)
        self.assertEqual(len(children), 1)
        elem = children[0]
        self.assertIsInstance(elem, Path)
        self.assertGreaterEqual(len(elem.d), 2)
        self.assertIsInstance(elem.d[0], MoveTo)
        for cmd in elem.d[1:]:
            self.assertIsInstance(cmd, CurveTo)

    def test_click_without_drag_creates_degenerate_path(self):
        """Press+release at same point still produces a path."""
        from tools.pencil import PencilTool
        tool = PencilTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 10, 20)
        tool.on_release(ctx, 10, 20)
        children = _layer_children(model)
        self.assertEqual(len(children), 1)

    def test_path_has_stroke(self):
        """Pencil paths have a stroke and no fill."""
        from tools.pencil import PencilTool
        tool = PencilTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 0, 0)
        tool.on_move(ctx, 50, 50, dragging=True)
        tool.on_release(ctx, 100, 0)
        children = _layer_children(model)
        elem = children[0]
        self.assertIsNotNone(elem.stroke)
        self.assertIsNone(elem.fill)

    def test_move_without_press_is_noop(self):
        """Moving without pressing doesn't start drawing."""
        from tools.pencil import PencilTool
        tool = PencilTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_move(ctx, 50, 60, dragging=True)
        self.assertFalse(tool._drawing)

    def test_release_without_press_is_noop(self):
        """Releasing without pressing creates nothing."""
        from tools.pencil import PencilTool
        tool = PencilTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_release(ctx, 50, 60)
        children = _layer_children(model)
        self.assertEqual(len(children), 0)

    def test_drawing_state_transitions(self):
        """Drawing flag tracks press/release correctly."""
        from tools.pencil import PencilTool
        tool = PencilTool()
        ctx, model, ctrl = _make_ctx()
        self.assertFalse(tool._drawing)
        tool.on_press(ctx, 0, 0)
        self.assertTrue(tool._drawing)
        tool.on_move(ctx, 50, 50, dragging=True)
        self.assertTrue(tool._drawing)
        tool.on_release(ctx, 100, 0)
        self.assertFalse(tool._drawing)

    def test_points_accumulate_during_draw(self):
        """Points grow during drag, cleared after finish."""
        from tools.pencil import PencilTool
        tool = PencilTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 0, 0)
        self.assertEqual(len(tool._points), 1)
        tool.on_move(ctx, 10, 10, dragging=True)
        self.assertEqual(len(tool._points), 2)
        tool.on_move(ctx, 20, 20, dragging=True)
        self.assertEqual(len(tool._points), 3)
        tool.on_release(ctx, 30, 30)
        self.assertEqual(len(tool._points), 0)

    def test_path_starts_at_press_point(self):
        """MoveTo uses the initial press coordinates."""
        from tools.pencil import PencilTool
        tool = PencilTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 15, 25)
        tool.on_move(ctx, 50, 50, dragging=True)
        tool.on_release(ctx, 100, 0)
        children = _layer_children(model)
        elem = children[0]
        self.assertIsInstance(elem.d[0], MoveTo)
        self.assertEqual(elem.d[0].x, 15)
        self.assertEqual(elem.d[0].y, 25)


class PathEraserToolTest(absltest.TestCase):
    def _make_line_path(self, x1, y1, x2, y2):
        return Path(
            d=(MoveTo(x1, y1), LineTo(x2, y2)),
            stroke=Stroke(Color(0, 0, 0), 1.0),
        )

    def _make_long_path(self):
        return Path(
            d=(MoveTo(0, 0), LineTo(50, 0), LineTo(100, 0), LineTo(150, 0)),
            stroke=Stroke(Color(0, 0, 0), 1.0),
        )

    def _make_closed_path(self):
        from geometry.element import ClosePath as CP
        return Path(
            d=(MoveTo(0, 0), LineTo(100, 0), LineTo(100, 100),
               LineTo(0, 100), CP()),
            fill=Fill(Color(0, 0, 0)),
            stroke=Stroke(Color(0, 0, 0), 1.0),
        )

    def test_erase_deletes_small_path(self):
        """A path with bbox smaller than eraser size is deleted entirely."""
        from tools.path_eraser import PathEraserTool
        tool = PathEraserTool()
        small = self._make_line_path(0, 0, 1, 1)
        layer = Layer(name="L", children=(small,))
        doc = Document(layers=(layer,), selection=frozenset())
        model = Model(document=doc)
        ctx, model, ctrl = _make_ctx(model)
        tool.on_press(ctx, 0.5, 0.5)
        tool.on_release(ctx, 0.5, 0.5)
        self.assertEqual(len(_layer_children(model)), 0)

    def test_erase_splits_open_path(self):
        """Erasing a segment of an open path splits it into two paths."""
        from tools.path_eraser import PathEraserTool
        tool = PathEraserTool()
        path = self._make_long_path()
        layer = Layer(name="L", children=(path,))
        doc = Document(layers=(layer,), selection=frozenset())
        model = Model(document=doc)
        ctx, model, ctrl = _make_ctx(model)
        tool.on_press(ctx, 75.0, 0.0)
        tool.on_release(ctx, 75.0, 0.0)
        children = _layer_children(model)
        self.assertEqual(len(children), 2, "open path should split into 2 parts")

    def test_erase_opens_closed_path(self):
        """Erasing a segment of a closed path opens it."""
        from tools.path_eraser import PathEraserTool
        tool = PathEraserTool()
        path = self._make_closed_path()
        layer = Layer(name="L", children=(path,))
        doc = Document(layers=(layer,), selection=frozenset())
        model = Model(document=doc)
        ctx, model, ctrl = _make_ctx(model)
        tool.on_press(ctx, 50.0, 0.0)
        tool.on_release(ctx, 50.0, 0.0)
        children = _layer_children(model)
        self.assertEqual(len(children), 1, "closed path should become one open path")
        self.assertIsInstance(children[0], Path)
        from geometry.element import ClosePath as CP
        self.assertFalse(
            any(isinstance(c, CP) for c in children[0].d),
            "result should not be closed")

    def test_erase_miss_does_nothing(self):
        """Erasing far from a path does not modify it."""
        from tools.path_eraser import PathEraserTool
        tool = PathEraserTool()
        path = self._make_long_path()
        layer = Layer(name="L", children=(path,))
        doc = Document(layers=(layer,), selection=frozenset())
        model = Model(document=doc)
        ctx, model, ctrl = _make_ctx(model)
        tool.on_press(ctx, 75.0, 50.0)
        tool.on_release(ctx, 75.0, 50.0)
        self.assertEqual(len(_layer_children(model)), 1)

    def test_release_without_press_is_noop(self):
        """Releasing without pressing does nothing."""
        from tools.path_eraser import PathEraserTool
        tool = PathEraserTool()
        path = self._make_long_path()
        layer = Layer(name="L", children=(path,))
        doc = Document(layers=(layer,), selection=frozenset())
        model = Model(document=doc)
        ctx, model, ctrl = _make_ctx(model)
        tool.on_release(ctx, 75.0, 0.0)
        self.assertEqual(len(_layer_children(model)), 1)

    def test_move_without_press_is_noop(self):
        """Moving without pressing does nothing."""
        from tools.path_eraser import PathEraserTool
        tool = PathEraserTool()
        path = self._make_long_path()
        layer = Layer(name="L", children=(path,))
        doc = Document(layers=(layer,), selection=frozenset())
        model = Model(document=doc)
        ctx, model, ctrl = _make_ctx(model)
        tool.on_move(ctx, 75.0, 0.0, dragging=True)
        self.assertEqual(len(_layer_children(model)), 1)

    def test_erasing_state_transitions(self):
        """Erasing flag tracks press/release correctly."""
        from tools.path_eraser import PathEraserTool
        tool = PathEraserTool()
        ctx, model, ctrl = _make_ctx()
        self.assertFalse(tool._erasing)
        tool.on_press(ctx, 0.0, 0.0)
        self.assertTrue(tool._erasing)
        tool.on_release(ctx, 0.0, 0.0)
        self.assertFalse(tool._erasing)

    def test_locked_path_not_erased(self):
        """A locked path is not affected by the eraser."""
        from tools.path_eraser import PathEraserTool
        tool = PathEraserTool()
        small = Path(
            d=(MoveTo(0, 0), LineTo(1, 1)),
            stroke=Stroke(Color(0, 0, 0), 1.0),
            locked=True,
        )
        layer = Layer(name="L", children=(small,))
        doc = Document(layers=(layer,), selection=frozenset())
        model = Model(document=doc)
        ctx, model, ctrl = _make_ctx(model)
        tool.on_press(ctx, 0.5, 0.5)
        tool.on_release(ctx, 0.5, 0.5)
        self.assertEqual(len(_layer_children(model)), 1,
                         "locked path should not be erased")

    def test_split_endpoints_hug_eraser(self):
        """Split endpoints should be at the eraser boundary, not at command boundaries."""
        from tools.path_eraser import PathEraserTool
        tool = PathEraserTool()
        # Horizontal path (0,0)→(100,0)→(200,0).
        # Erase at x=50 with ERASER_SIZE=2 => eraser rect x=[48,52].
        path = Path(
            d=(MoveTo(0, 0), LineTo(100, 0), LineTo(200, 0)),
            stroke=Stroke(Color(0, 0, 0), 1.0),
        )
        layer = Layer(name="L", children=(path,))
        doc = Document(layers=(layer,), selection=frozenset())
        model = Model(document=doc)
        ctx, model, ctrl = _make_ctx(model)
        tool.on_press(ctx, 50.0, 0.0)
        tool.on_release(ctx, 50.0, 0.0)
        children = _layer_children(model)
        self.assertEqual(len(children), 2, "should split into 2 parts")
        # Part 1 should end near x=48.
        last_cmd = children[0].d[-1]
        self.assertAlmostEqual(last_cmd.x, 48.0, delta=0.5,
                               msg=f"part1 end x={last_cmd.x} should be near 48")
        # Part 2 should start near x=52.
        first_cmd = children[1].d[0]
        self.assertIsInstance(first_cmd, MoveTo)
        self.assertAlmostEqual(first_cmd.x, 52.0, delta=0.5,
                               msg=f"part2 start x={first_cmd.x} should be near 52")

    def test_split_preserves_curves(self):
        """Splitting a cubic Bezier should produce CurveTo, not LineTo."""
        from tools.path_eraser import PathEraserTool
        tool = PathEraserTool()
        # Cubic curve from (0,0) to (200,0) arching upward.
        path = Path(
            d=(MoveTo(0, 0), CurveTo(50, -100, 150, -100, 200, 0)),
            stroke=Stroke(Color(0, 0, 0), 1.0),
        )
        layer = Layer(name="L", children=(path,))
        doc = Document(layers=(layer,), selection=frozenset())
        model = Model(document=doc)
        ctx, model, ctrl = _make_ctx(model)
        # Erase near the top of the arc.
        tool.on_press(ctx, 100.0, -75.0)
        tool.on_release(ctx, 100.0, -75.0)
        children = _layer_children(model)
        self.assertEqual(len(children), 2, "should split into 2 parts")
        # Both parts should end/contain CurveTo, not LineTo.
        self.assertIsInstance(children[0].d[-1], CurveTo,
                             f"part1 should end with CurveTo, got {type(children[0].d[-1])}")
        self.assertGreaterEqual(len(children[1].d), 2)
        self.assertIsInstance(children[1].d[1], CurveTo,
                             f"part2 should contain CurveTo, got {type(children[1].d[1])}")
        # The second part's CurveTo should end at the original endpoint (200, 0).
        self.assertAlmostEqual(children[1].d[1].x, 200.0, delta=0.01)
        self.assertAlmostEqual(children[1].d[1].y, 0.0, delta=0.01)

    def test_de_casteljau_split_exact(self):
        """De Casteljau split at t=0.5 on a symmetric curve gives the midpoint."""
        from tools.path_eraser import _split_cubic_at
        first, second = _split_cubic_at(
            (0.0, 0.0), 0.0, 100.0, 100.0, 100.0, 100.0, 0.0, 0.5
        )
        self.assertAlmostEqual(first.x, 50.0, delta=0.01,
                               msg=f"first half endpoint x={first.x}")
        self.assertAlmostEqual(first.y, 75.0, delta=0.01,
                               msg=f"first half endpoint y={first.y}")
        self.assertAlmostEqual(second.x, 100.0, delta=0.01,
                               msg=f"second half endpoint x={second.x}")
        self.assertAlmostEqual(second.y, 0.0, delta=0.01,
                               msg=f"second half endpoint y={second.y}")


class TypeOnPathToolTest(absltest.TestCase):
    def test_new_tool_is_idle(self):
        from tools.type_on_path import TypeOnPathTool
        tool = TypeOnPathTool()
        self.assertIsNone(tool._drag_start)
        self.assertIsNone(tool._control)
        self.assertFalse(tool._offset_dragging)

    def test_press_starts_drag_create(self):
        from tools.type_on_path import TypeOnPathTool
        tool = TypeOnPathTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 12, 34)
        self.assertEqual(tool._drag_start, (12, 34))
        self.assertEqual(tool._drag_end, (12, 34))
        # No control point yet — only set once dist > DRAG_THRESHOLD.
        self.assertIsNone(tool._control)

    def test_move_after_press_sets_control_point(self):
        from tools.type_on_path import TypeOnPathTool
        tool = TypeOnPathTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 10, 20)
        tool.on_move(ctx, 50, 60, dragging=True)
        self.assertEqual(tool._drag_end, (50, 60))
        # Distance ≈ 56 > DRAG_THRESHOLD, so a control point is set.
        self.assertIsNotNone(tool._control)

    def test_tiny_move_does_not_set_control_point(self):
        from tools.type_on_path import TypeOnPathTool
        tool = TypeOnPathTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 10, 20)
        tool.on_move(ctx, 11, 21, dragging=True)
        self.assertIsNone(tool._control)

    def test_move_without_press_is_noop(self):
        from tools.type_on_path import TypeOnPathTool
        tool = TypeOnPathTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_move(ctx, 50, 60, dragging=True)
        self.assertIsNone(tool._drag_start)
        self.assertIsNone(tool._control)

    def test_drag_creates_textpath_with_curve(self):
        """Drag creates an empty TextPath with a CurveTo and starts an editing session."""
        from tools.type_on_path import TypeOnPathTool
        from geometry.element import TextPath
        tool = TypeOnPathTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 10, 20)
        tool.on_move(ctx, 50, 60, dragging=True)
        tool.on_release(ctx, 50, 60)
        children = _layer_children(model)
        self.assertEqual(len(children), 1)
        elem = children[0]
        self.assertIsInstance(elem, TextPath)
        self.assertEqual(elem.content, "")
        self.assertIsInstance(elem.d[0], MoveTo)
        self.assertEqual((elem.d[0].x, elem.d[0].y), (10, 20))
        self.assertIsInstance(elem.d[1], CurveTo)
        self.assertEqual((elem.d[1].x, elem.d[1].y), (50, 60))
        self.assertIsNotNone(tool.session)

    def test_click_on_path_converts_to_textpath(self):
        """Click without drag on a Path converts it to an empty TextPath
        and starts an editing session."""
        from tools.type_on_path import TypeOnPathTool
        from geometry.element import TextPath
        tool = TypeOnPathTool()
        existing = Path(
            d=(MoveTo(0, 0), LineTo(100, 0)),
            stroke=Stroke(Color(0, 0, 0), 1.0),
        )
        layer = Layer(name="L", children=(existing,))
        model = Model(document=Document(layers=(layer,)))
        ctx, model, ctrl = _make_ctx(model)
        tool.on_press(ctx, 50, 0)
        tool.on_release(ctx, 50, 0)
        elem = _layer_children(model)[0]
        self.assertIsInstance(elem, TextPath)
        self.assertEqual(elem.content, "")
        self.assertIsNotNone(tool.session)

    def test_click_on_empty_canvas_does_nothing(self):
        """A click (no drag) on empty canvas does NOT create a TextPath."""
        from tools.type_on_path import TypeOnPathTool
        tool = TypeOnPathTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 10, 20)
        tool.on_release(ctx, 10, 20)
        self.assertEqual(len(_layer_children(model)), 0)
        self.assertIsNone(tool.session)

    def test_idle_after_release(self):
        from tools.type_on_path import TypeOnPathTool
        tool = TypeOnPathTool()
        ctx, model, ctrl = _make_ctx()
        tool.on_press(ctx, 10, 20)
        tool.on_release(ctx, 50, 60)
        self.assertIsNone(tool._drag_start)
        self.assertIsNone(tool._drag_end)
        self.assertIsNone(tool._control)


if __name__ == '__main__':
    absltest.main()
