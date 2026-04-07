"""Canvas tool implementations."""

from tools.tool import CanvasTool
from tools.toolbar import Tool

from tools.selection import SelectionTool, DirectSelectionTool, GroupSelectionTool
from tools.drawing import LineTool, RectTool, RoundedRectTool, PolygonTool
from tools.pen import PenTool
from tools.add_anchor_point import AddAnchorPointTool
from tools.delete_anchor_point import DeleteAnchorPointTool
from tools.pencil import PencilTool
from tools.path_eraser import PathEraserTool
from tools.smooth import SmoothTool
from tools.text import TextTool
from tools.text_path import TextPathTool


def create_tools() -> dict[Tool, CanvasTool]:
    """Create one instance of each tool, keyed by Tool enum."""
    return {
        Tool.SELECTION: SelectionTool(),
        Tool.DIRECT_SELECTION: DirectSelectionTool(),
        Tool.GROUP_SELECTION: GroupSelectionTool(),
        Tool.PEN: PenTool(),
        Tool.ADD_ANCHOR_POINT: AddAnchorPointTool(),
        Tool.DELETE_ANCHOR_POINT: DeleteAnchorPointTool(),
        Tool.PENCIL: PencilTool(),
        Tool.PATH_ERASER: PathEraserTool(),
        Tool.SMOOTH: SmoothTool(),
        Tool.TEXT: TextTool(),
        Tool.TEXT_PATH: TextPathTool(),
        Tool.LINE: LineTool(),
        Tool.RECT: RectTool(),
        Tool.ROUNDED_RECT: RoundedRectTool(),
        Tool.POLYGON: PolygonTool(),
    }
