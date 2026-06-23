"""Tests for toolbar and tool definitions."""

import sys

from absl.testing import absltest
from PySide6.QtWidgets import QApplication

# A QApplication must exist before any QWidget is created.
_app = QApplication.instance() or QApplication(sys.argv)

from tools.toolbar import (
    Tool, Toolbar,
    _ARROW_SLOT_TOOLS, _PEN_SLOT_TOOLS, _PENCIL_SLOT_TOOLS, _TEXT_SLOT_TOOLS, _SHAPE_SLOT_TOOLS,
)
from tools.tool import (
    HIT_RADIUS, HANDLE_DRAW_SIZE, DRAG_THRESHOLD, PASTE_OFFSET,
    LONG_PRESS_MS, POLYGON_SIDES,
    CanvasTool, ToolContext,
)


class ToolEnumTest(absltest.TestCase):
    """Tests for the Tool enum."""

    def test_tool_count(self):
        self.assertEqual(len(Tool), 29)

    def test_all_tools_present(self):
        expected = {
            "SELECTION", "PARTIAL_SELECTION", "INTERIOR_SELECTION", "MAGIC_WAND",
            "PEN", "ADD_ANCHOR_POINT", "DELETE_ANCHOR_POINT", "ANCHOR_POINT",
            "PENCIL", "PAINTBRUSH", "BLOB_BRUSH", "PATH_ERASER", "SMOOTH",
            "TYPE", "TYPE_ON_PATH",
            "LINE", "RECT", "ROUNDED_RECT", "ELLIPSE", "POLYGON", "STAR", "LASSO",
            "SCALE", "ROTATE", "SHEAR",
            "HAND", "ZOOM", "EYEDROPPER", "ARTBOARD",
        }
        actual = {t.name for t in Tool}
        self.assertEqual(actual, expected)

    def test_tool_values_unique(self):
        values = [t.value for t in Tool]
        self.assertEqual(len(values), len(set(values)))


class ToolConstantsTest(absltest.TestCase):
    """Tests for shared tool constants."""

    def test_hit_radius(self):
        self.assertEqual(HIT_RADIUS, 8.0)

    def test_handle_draw_size(self):
        self.assertEqual(HANDLE_DRAW_SIZE, 10.0)

    def test_drag_threshold(self):
        self.assertEqual(DRAG_THRESHOLD, 4.0)

    def test_paste_offset(self):
        self.assertEqual(PASTE_OFFSET, 24.0)

    def test_long_press_ms(self):
        self.assertEqual(LONG_PRESS_MS, 500)

    def test_polygon_sides(self):
        self.assertEqual(POLYGON_SIDES, 5)


class ToolProtocolTest(absltest.TestCase):
    """Tests for the CanvasTool ABC."""

    def test_canvas_tool_is_abstract(self):
        with self.assertRaises(TypeError):
            CanvasTool()

    def test_canvas_tool_abstract_methods(self):
        abstract_methods = CanvasTool.__abstractmethods__
        expected = {"on_press", "on_move", "on_release", "draw_overlay"}
        self.assertEqual(abstract_methods, expected)


class SharedSlotsTest(absltest.TestCase):
    """Tests for shared toolbar slot definitions."""

    def test_arrow_slot_tools(self):
        self.assertEqual(_ARROW_SLOT_TOOLS,
                         {Tool.PARTIAL_SELECTION, Tool.INTERIOR_SELECTION,
                          Tool.MAGIC_WAND})

    def test_text_slot_tools(self):
        self.assertEqual(_TEXT_SLOT_TOOLS, {Tool.TYPE, Tool.TYPE_ON_PATH})

    def test_pen_slot_tools(self):
        self.assertEqual(_PEN_SLOT_TOOLS, {Tool.PEN, Tool.ADD_ANCHOR_POINT, Tool.DELETE_ANCHOR_POINT, Tool.ANCHOR_POINT})

    def test_pencil_slot_tools(self):
        self.assertEqual(
            _PENCIL_SLOT_TOOLS,
            {Tool.PENCIL, Tool.PAINTBRUSH, Tool.BLOB_BRUSH,
             Tool.PATH_ERASER, Tool.SMOOTH})

    def test_shape_slot_tools(self):
        self.assertEqual(_SHAPE_SLOT_TOOLS,
                         {Tool.RECT, Tool.ROUNDED_RECT, Tool.ELLIPSE,
                          Tool.POLYGON, Tool.STAR})

    def test_slot_tools_disjoint(self):
        all_slots = [_ARROW_SLOT_TOOLS, _PEN_SLOT_TOOLS, _PENCIL_SLOT_TOOLS, _TEXT_SLOT_TOOLS, _SHAPE_SLOT_TOOLS]
        for i in range(len(all_slots)):
            for j in range(i + 1, len(all_slots)):
                self.assertFalse(all_slots[i] & all_slots[j])

    def test_all_slot_tools_in_enum(self):
        all_slot = _ARROW_SLOT_TOOLS | _PEN_SLOT_TOOLS | _PENCIL_SLOT_TOOLS | _TEXT_SLOT_TOOLS | _SHAPE_SLOT_TOOLS
        for tool in all_slot:
            self.assertIsInstance(tool, Tool)


class ToolbarStateTest(absltest.TestCase):
    """Tests for the headless tool-state controller.

    The Toolbar no longer builds a visible grid — the bundle tool_grid
    does. These cover the live tool-state surface: current_tool +
    select_tool (keyboard shortcuts, the state<->canvas bridge, and the
    canvas tool-change callback all drive it) including the shared-slot
    bookkeeping kept coherent across slot switches."""

    def test_toolbar_default_tool(self):
        toolbar = Toolbar()
        self.assertEqual(toolbar.current_tool, Tool.SELECTION)

    def test_toolbar_select_pen_slot_tool(self):
        toolbar = Toolbar()
        toolbar.select_tool(Tool.ADD_ANCHOR_POINT)
        self.assertEqual(toolbar.current_tool, Tool.ADD_ANCHOR_POINT)
        self.assertEqual(toolbar._pen_slot_tool, Tool.ADD_ANCHOR_POINT)

    def test_toolbar_select_tool(self):
        toolbar = Toolbar()
        toolbar.select_tool(Tool.PEN)
        self.assertEqual(toolbar.current_tool, Tool.PEN)

    def test_toolbar_select_arrow_slot_tool(self):
        toolbar = Toolbar()
        toolbar.select_tool(Tool.INTERIOR_SELECTION)
        self.assertEqual(toolbar.current_tool, Tool.INTERIOR_SELECTION)
        self.assertEqual(toolbar._arrow_slot_tool, Tool.INTERIOR_SELECTION)

    def test_toolbar_select_text_slot_tool(self):
        toolbar = Toolbar()
        toolbar.select_tool(Tool.TYPE_ON_PATH)
        self.assertEqual(toolbar.current_tool, Tool.TYPE_ON_PATH)
        self.assertEqual(toolbar._text_slot_tool, Tool.TYPE_ON_PATH)

    def test_toolbar_select_shape_slot_tool(self):
        toolbar = Toolbar()
        toolbar.select_tool(Tool.POLYGON)
        self.assertEqual(toolbar.current_tool, Tool.POLYGON)
        self.assertEqual(toolbar._shape_slot_tool, Tool.POLYGON)

    def test_toolbar_select_pencil_slot_tool(self):
        toolbar = Toolbar()
        toolbar.select_tool(Tool.SMOOTH)
        self.assertEqual(toolbar.current_tool, Tool.SMOOTH)
        self.assertEqual(toolbar._pencil_slot_tool, Tool.SMOOTH)

    def test_tool_changed_emitted_on_select(self):
        toolbar = Toolbar()
        seen = []
        toolbar.tool_changed.connect(seen.append)
        toolbar.select_tool(Tool.LINE)
        self.assertEqual(seen, [Tool.LINE])

    def test_owns_fill_stroke_widget(self):
        toolbar = Toolbar()
        self.assertIsNotNone(toolbar.fill_stroke_widget)


if __name__ == "__main__":
    absltest.main()
