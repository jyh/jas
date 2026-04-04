"""Canvas tool implementations."""

from tool import CanvasTool
from toolbar import Tool

from tools.selection import SelectionTool, DirectSelectionTool, GroupSelectionTool
from tools.drawing import LineTool, RectTool, PolygonTool
from tools.pen import PenTool
from tools.text import TextTool


def create_tools() -> dict[Tool, CanvasTool]:
    """Create one instance of each tool, keyed by Tool enum."""
    return {
        Tool.SELECTION: SelectionTool(),
        Tool.DIRECT_SELECTION: DirectSelectionTool(),
        Tool.GROUP_SELECTION: GroupSelectionTool(),
        Tool.PEN: PenTool(),
        Tool.TEXT: TextTool(),
        Tool.LINE: LineTool(),
        Tool.RECT: RectTool(),
        Tool.POLYGON: PolygonTool(),
    }
