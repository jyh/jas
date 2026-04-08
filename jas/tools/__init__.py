"""Canvas tool implementations."""

from tools.tool import CanvasTool
from tools.toolbar import Tool

from tools.selection_tool import SelectionTool
from tools.direct_selection_tool import DirectSelectionTool
from tools.group_selection_tool import GroupSelectionTool
from tools.line_tool import LineTool
from tools.rect_tool import RectTool
from tools.rounded_rect_tool import RoundedRectTool
from tools.polygon_tool import PolygonTool
from tools.star_tool import StarTool
from tools.pen_tool import PenTool
from tools.add_anchor_point_tool import AddAnchorPointTool
from tools.delete_anchor_point_tool import DeleteAnchorPointTool
from tools.anchor_point_tool import AnchorPointTool
from tools.pencil_tool import PencilTool
from tools.path_eraser_tool import PathEraserTool
from tools.smooth_tool import SmoothTool
from tools.type_tool import TypeTool
from tools.type_on_path_tool import TypeOnPathTool


def create_tools() -> dict[Tool, CanvasTool]:
    """Create one instance of each tool, keyed by Tool enum."""
    return {
        Tool.SELECTION: SelectionTool(),
        Tool.DIRECT_SELECTION: DirectSelectionTool(),
        Tool.GROUP_SELECTION: GroupSelectionTool(),
        Tool.PEN: PenTool(),
        Tool.ADD_ANCHOR_POINT: AddAnchorPointTool(),
        Tool.DELETE_ANCHOR_POINT: DeleteAnchorPointTool(),
        Tool.ANCHOR_POINT: AnchorPointTool(),
        Tool.PENCIL: PencilTool(),
        Tool.PATH_ERASER: PathEraserTool(),
        Tool.SMOOTH: SmoothTool(),
        Tool.TYPE: TypeTool(),
        Tool.TYPE_ON_PATH: TypeOnPathTool(),
        Tool.LINE: LineTool(),
        Tool.RECT: RectTool(),
        Tool.ROUNDED_RECT: RoundedRectTool(),
        Tool.POLYGON: PolygonTool(),
        Tool.STAR: StarTool(),
    }
