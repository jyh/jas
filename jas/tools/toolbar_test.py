"""Tests for toolbar and tool definitions."""

import sys
import unittest

from PySide6.QtWidgets import QApplication

# A QApplication must exist before any QWidget is created.
_app = QApplication.instance() or QApplication(sys.argv)

from tools.toolbar import (
    Tool, Toolbar, ToolButton,
    _ARROW_SLOT_TOOLS, _TEXT_SLOT_TOOLS, _SHAPE_SLOT_TOOLS,
)
from tools.tool import (
    HIT_RADIUS, HANDLE_DRAW_SIZE, DRAG_THRESHOLD, PASTE_OFFSET,
    LONG_PRESS_MS, POLYGON_SIDES,
    CanvasTool, ToolContext,
)


class ToolEnumTest(unittest.TestCase):
    """Tests for the Tool enum."""

    def test_tool_count(self):
        self.assertEqual(len(Tool), 10)

    def test_all_tools_present(self):
        expected = {
            "SELECTION", "DIRECT_SELECTION", "GROUP_SELECTION",
            "PEN", "PENCIL", "TEXT", "TEXT_PATH",
            "LINE", "RECT", "POLYGON",
        }
        actual = {t.name for t in Tool}
        self.assertEqual(actual, expected)

    def test_tool_values_unique(self):
        values = [t.value for t in Tool]
        self.assertEqual(len(values), len(set(values)))


class ToolConstantsTest(unittest.TestCase):
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


class ToolProtocolTest(unittest.TestCase):
    """Tests for the CanvasTool ABC."""

    def test_canvas_tool_is_abstract(self):
        with self.assertRaises(TypeError):
            CanvasTool()

    def test_canvas_tool_abstract_methods(self):
        abstract_methods = CanvasTool.__abstractmethods__
        expected = {"on_press", "on_move", "on_release", "draw_overlay"}
        self.assertEqual(abstract_methods, expected)


class SharedSlotsTest(unittest.TestCase):
    """Tests for shared toolbar slot definitions."""

    def test_arrow_slot_tools(self):
        self.assertEqual(_ARROW_SLOT_TOOLS, {Tool.DIRECT_SELECTION, Tool.GROUP_SELECTION})

    def test_text_slot_tools(self):
        self.assertEqual(_TEXT_SLOT_TOOLS, {Tool.TEXT, Tool.TEXT_PATH})

    def test_shape_slot_tools(self):
        self.assertEqual(_SHAPE_SLOT_TOOLS, {Tool.RECT, Tool.POLYGON})

    def test_slot_tools_disjoint(self):
        self.assertFalse(_ARROW_SLOT_TOOLS & _TEXT_SLOT_TOOLS)
        self.assertFalse(_ARROW_SLOT_TOOLS & _SHAPE_SLOT_TOOLS)
        self.assertFalse(_TEXT_SLOT_TOOLS & _SHAPE_SLOT_TOOLS)

    def test_all_slot_tools_in_enum(self):
        all_slot = _ARROW_SLOT_TOOLS | _TEXT_SLOT_TOOLS | _SHAPE_SLOT_TOOLS
        for tool in all_slot:
            self.assertIsInstance(tool, Tool)


class ToolButtonTest(unittest.TestCase):
    """Tests for the ToolButton widget."""

    def test_button_creation(self):
        btn = ToolButton(Tool.SELECTION)
        self.assertEqual(btn.tool, Tool.SELECTION)
        self.assertTrue(btn.isCheckable())
        self.assertFalse(btn.has_alternates)

    def test_button_with_alternates(self):
        btn = ToolButton(Tool.DIRECT_SELECTION, has_alternates=True)
        self.assertTrue(btn.has_alternates)

    def test_button_size(self):
        btn = ToolButton(Tool.PEN)
        self.assertEqual(btn.width(), ToolButton.BUTTON_SIZE)
        self.assertEqual(btn.height(), ToolButton.BUTTON_SIZE)

    def test_icon_size_constant(self):
        self.assertEqual(ToolButton.ICON_SIZE, 28)

    def test_button_size_constant(self):
        self.assertEqual(ToolButton.BUTTON_SIZE, 32)


class ToolbarLayoutTest(unittest.TestCase):
    """Tests for toolbar grid layout."""

    def test_toolbar_default_tool(self):
        toolbar = Toolbar()
        self.assertEqual(toolbar.current_tool, Tool.SELECTION)

    def test_toolbar_has_all_buttons(self):
        toolbar = Toolbar()
        for tool in Tool:
            self.assertIn(tool, toolbar.buttons)

    def test_toolbar_visible_button_count(self):
        """7 visible slots in grid (3 hidden alternates)."""
        toolbar = Toolbar()
        # Grid has 7 slots: selection, direct, pen, pencil, text, line, rect
        visible = [Tool.SELECTION, Tool.DIRECT_SELECTION, Tool.PEN,
                   Tool.PENCIL, Tool.TEXT, Tool.LINE, Tool.RECT]
        for tool in visible:
            self.assertIn(tool, toolbar.buttons)

    def test_toolbar_select_tool(self):
        toolbar = Toolbar()
        toolbar.select_tool(Tool.PEN)
        self.assertEqual(toolbar.current_tool, Tool.PEN)

    def test_toolbar_select_arrow_slot_tool(self):
        toolbar = Toolbar()
        toolbar.select_tool(Tool.GROUP_SELECTION)
        self.assertEqual(toolbar.current_tool, Tool.GROUP_SELECTION)

    def test_toolbar_select_text_slot_tool(self):
        toolbar = Toolbar()
        toolbar.select_tool(Tool.TEXT_PATH)
        self.assertEqual(toolbar.current_tool, Tool.TEXT_PATH)

    def test_toolbar_select_shape_slot_tool(self):
        toolbar = Toolbar()
        toolbar.select_tool(Tool.POLYGON)
        self.assertEqual(toolbar.current_tool, Tool.POLYGON)

    def test_selection_button_checked_initially(self):
        toolbar = Toolbar()
        self.assertTrue(toolbar.buttons[Tool.SELECTION].isChecked())


if __name__ == "__main__":
    unittest.main()
