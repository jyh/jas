"""Tool enum + headless tool-state controller + fill/stroke widget.

The visible toolbar is rendered from the compiled bundle ``tool_grid``
(see jas_app._build_yaml_toolbar). What remains here is the part that is
still LIVE:

* ``Tool`` — the tool enum (canvas, keyboard shortcuts, bundle bridge).
* ``Toolbar`` — a HEADLESS tool-state controller. It no longer builds any
  grid of buttons. jas_app bridges state.active_tool -> select_tool ->
  the tool_changed signal -> canvas.set_tool, and keyboard shortcuts call
  select_tool directly. It also owns the fill/stroke widget that is added
  to the toolbar pane below the bundle grid.
* ``FillStrokeWidget`` — the fill/stroke indicator, still rendered.

The old native visual toolbar (the hand-drawn ToolButton glyphs, the
QGridLayout/QButtonGroup construction, the long-press QMenu alternates,
and the native dblclick plumbing) was deleted: the bundle toolbar, its
flyout, and the bundle dblclick supersede all of it.
"""

from enum import Enum, auto

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QPainter, QColor, QPen
from PySide6.QtWidgets import QWidget, QVBoxLayout


def _theme_qcolor(hex_str: str) -> QColor:
    """Convert a hex color string like '#cccccc' to a QColor."""
    return QColor(hex_str)


def _icon_color() -> QColor:
    from workspace.dock_panel import THEME_TEXT
    return _theme_qcolor(THEME_TEXT)


def _checked_bg() -> QColor:
    from workspace.dock_panel import THEME_BG_TAB
    return _theme_qcolor(THEME_BG_TAB)


class Tool(Enum):
    SELECTION = auto()
    PARTIAL_SELECTION = auto()
    INTERIOR_SELECTION = auto()
    MAGIC_WAND = auto()
    PEN = auto()
    ADD_ANCHOR_POINT = auto()
    DELETE_ANCHOR_POINT = auto()
    ANCHOR_POINT = auto()
    PENCIL = auto()
    PAINTBRUSH = auto()
    BLOB_BRUSH = auto()
    PATH_ERASER = auto()
    SMOOTH = auto()
    TYPE = auto()
    TYPE_ON_PATH = auto()
    LINE = auto()
    RECT = auto()
    ROUNDED_RECT = auto()
    ELLIPSE = auto()
    POLYGON = auto()
    STAR = auto()
    LASSO = auto()
    SCALE = auto()
    ROTATE = auto()
    SHEAR = auto()
    HAND = auto()
    ZOOM = auto()
    EYEDROPPER = auto()
    ARTBOARD = auto()


# Tools that share the partial/interior selection slot
_ARROW_SLOT_TOOLS = {Tool.PARTIAL_SELECTION, Tool.INTERIOR_SELECTION, Tool.MAGIC_WAND}
# Tools that share the pen/add-anchor-point slot
_PEN_SLOT_TOOLS = {Tool.PEN, Tool.ADD_ANCHOR_POINT, Tool.DELETE_ANCHOR_POINT, Tool.ANCHOR_POINT}
# Tools that share the pencil/path-eraser slot
_PENCIL_SLOT_TOOLS = {Tool.PENCIL, Tool.PAINTBRUSH, Tool.BLOB_BRUSH,
                      Tool.PATH_ERASER, Tool.SMOOTH}
# Tools that share the text/text-path slot
_TEXT_SLOT_TOOLS = {Tool.TYPE, Tool.TYPE_ON_PATH}
# Tools that share the rect/polygon slot
_SHAPE_SLOT_TOOLS = {Tool.RECT, Tool.ROUNDED_RECT, Tool.ELLIPSE, Tool.POLYGON, Tool.STAR}


class FillStrokeWidget(QWidget):
    """Fill/stroke indicator with overlapping squares, swap, and default buttons.

    Signals:
        fill_clicked: emitted when the fill square is clicked.
        stroke_clicked: emitted when the stroke square is clicked.
        fill_double_clicked: emitted when the fill square is double-clicked.
        stroke_double_clicked: emitted when the stroke square is double-clicked.
        swap_clicked: emitted when the swap arrow is clicked.
        default_clicked: emitted when the default reset button is clicked.
        fill_none_clicked: emitted when fill-none mode is chosen.
        stroke_none_clicked: emitted when stroke-none mode is chosen.
    """

    fill_clicked = Signal()
    stroke_clicked = Signal()
    fill_double_clicked = Signal()
    stroke_double_clicked = Signal()
    swap_clicked = Signal()
    default_clicked = Signal()
    fill_none_clicked = Signal()
    stroke_none_clicked = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._fill_color: QColor | None = QColor(255, 255, 255)
        self._stroke_color: QColor | None = QColor(0, 0, 0)
        self._fill_on_top = True
        self.setFixedSize(64, 80)

    def set_fill_color(self, color: QColor | None):
        self._fill_color = color
        self.update()

    def set_stroke_color(self, color: QColor | None):
        self._stroke_color = color
        self.update()

    def set_fill_on_top(self, on_top: bool):
        self._fill_on_top = on_top
        self.update()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        # Layout: two overlapping 28x28 squares
        # Fill is always top-left, stroke is always offset to bottom-right
        sq_size = 28
        fill_x, fill_y = 0, 0
        stroke_x, stroke_y = 10, 10

        # Draw back square first (behind), then front square (on top)
        if self._fill_on_top:
            self._draw_stroke_square(painter, stroke_x, stroke_y, sq_size)
            self._draw_fill_square(painter, fill_x, fill_y, sq_size)
        else:
            self._draw_fill_square(painter, fill_x, fill_y, sq_size)
            self._draw_stroke_square(painter, stroke_x, stroke_y, sq_size)

        # Swap arrow (top-right)
        painter.setPen(QPen(_icon_color(), 1))
        ax, ay = 44, 4
        # Curved arrow hint
        painter.drawLine(ax, ay, ax + 8, ay)
        painter.drawLine(ax + 8, ay, ax + 8, ay + 8)
        painter.drawLine(ax + 8, ay + 8, ax + 5, ay + 5)
        painter.drawLine(ax + 8, ay + 8, ax + 8 + 3, ay + 5)

        # Default reset (bottom-left, small icon)
        dx, dy = 0, 44
        # Small fill square (white)
        painter.setPen(QPen(QColor("#999"), 1))
        painter.setBrush(QColor(255, 255, 255))
        painter.drawRect(dx + 3, dy + 3, 8, 8)
        # Small stroke square (black border)
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.setPen(QPen(QColor(0, 0, 0), 2))
        painter.drawRect(dx, dy, 8, 8)

        # Mode buttons row: Color, None
        btn_y = 62
        # Color button
        painter.setPen(QPen(QColor("#999"), 1))
        painter.setBrush(QColor("#666"))
        painter.drawRect(2, btn_y, 14, 14)
        # Gradient button (disabled)
        painter.setPen(QPen(QColor("#555"), 1))
        painter.setBrush(QColor("#444"))
        painter.drawRect(20, btn_y, 14, 14)
        # None button (red line)
        painter.setPen(QPen(QColor("#555"), 1))
        painter.setBrush(QColor("#fff"))
        painter.drawRect(38, btn_y, 14, 14)
        painter.setPen(QPen(QColor(255, 0, 0), 1.5))
        painter.drawLine(39, btn_y + 13, 51, btn_y + 1)

    def _draw_fill_square(self, painter, x, y, size):
        """Draw the fill square (solid fill)."""
        if self._fill_color is not None:
            painter.setPen(QPen(QColor("#666"), 1))
            painter.setBrush(self._fill_color)
        else:
            painter.setPen(QPen(QColor("#666"), 1))
            painter.setBrush(QColor(255, 255, 255))
        painter.drawRect(x, y, size, size)
        if self._fill_color is None:
            # Draw red slash for "none"
            painter.setPen(QPen(QColor(255, 0, 0), 1.5))
            painter.drawLine(x + 1, y + size - 1, x + size - 1, y + 1)

    def _draw_stroke_square(self, painter, x, y, size):
        """Draw the stroke square (hollow with thick border, transparent center)."""
        if self._stroke_color is None:
            # None: white square with red diagonal
            painter.setPen(QPen(QColor(128, 128, 128), 1))
            painter.setBrush(QColor(255, 255, 255))
            painter.drawRect(x, y, size, size)
            painter.setPen(QPen(QColor(255, 0, 0), 1.5))
            painter.drawLine(x + 1, y + size - 1, x + size - 1, y + 1)
        else:
            # Hollow square: thick colored border, white center, thin outline
            bw = 6  # border width
            # Outer outline
            painter.setPen(QPen(QColor(128, 128, 128), 1))
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.drawRect(x, y, size, size)
            # Thick colored border
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(self._stroke_color)
            painter.drawRect(x + 1, y + 1, size - 1, bw)
            painter.drawRect(x + 1, y + size - bw, size - 1, bw)
            painter.drawRect(x + 1, y + bw, bw, size - 2 * bw)
            painter.drawRect(x + size - bw, y + bw, bw, size - 2 * bw)
            # White center
            painter.setBrush(QColor(255, 255, 255))
            painter.drawRect(x + bw + 1, y + bw + 1,
                             size - 2 * bw - 1, size - 2 * bw - 1)

    def _hit_square(self, x, y):
        """Return 'fill', 'stroke', or None based on click position.
        Check front square first (higher z-order), then back."""
        sq = 28
        fill_hit = 0 <= x <= sq and 0 <= y <= sq
        stroke_hit = 10 <= x <= 10 + sq and 10 <= y <= 10 + sq
        if self._fill_on_top:
            if fill_hit:
                return 'fill'
            if stroke_hit:
                return 'stroke'
        else:
            if stroke_hit:
                return 'stroke'
            if fill_hit:
                return 'fill'
        return None

    def mousePressEvent(self, event):
        x, y = event.position().x(), event.position().y()
        # Check swap arrow region (top-right)
        if 44 <= x <= 56 and 0 <= y <= 14:
            self.swap_clicked.emit()
            return
        # Check default reset region (bottom-left)
        if 0 <= x <= 14 and 42 <= y <= 56:
            self.default_clicked.emit()
            return
        # Check mode buttons
        if 62 <= y <= 76:
            if 38 <= x <= 52:
                if self._fill_on_top:
                    self.fill_none_clicked.emit()
                else:
                    self.stroke_none_clicked.emit()
                return
        # Check fill/stroke squares — click brings to front
        hit = self._hit_square(x, y)
        if hit == 'fill':
            self._fill_on_top = True
            self.fill_clicked.emit()
            self.update()
        elif hit == 'stroke':
            self._fill_on_top = False
            self.stroke_clicked.emit()
            self.update()

    def mouseDoubleClickEvent(self, event):
        x, y = event.position().x(), event.position().y()
        hit = self._hit_square(x, y)
        if hit == 'fill':
            self._fill_on_top = True
            self.update()
            self.fill_double_clicked.emit()
        elif hit == 'stroke':
            self._fill_on_top = False
            self.update()
            self.stroke_double_clicked.emit()


class Toolbar(QWidget):
    """Headless tool-state controller.

    This owns no visible grid of tool buttons anymore — the visible
    toolbar is the bundle ``tool_grid`` (jas_app._build_yaml_toolbar).
    What remains is the tool-state surface the rest of the app relies on:

    * ``current_tool`` — the active tool.
    * ``select_tool(tool)`` — set the active tool; keyboard shortcuts, the
      state<->canvas bridge, and the canvas tool-change callback all call
      this. It also tracks which tool occupies each shared slot so the
      slot bookkeeping stays coherent.
    * ``tool_changed`` — emitted on every selection; drives canvas.set_tool
      and the reverse bridge that mirrors the choice into state.active_tool
      (the bundle grid highlight).
    * ``tool_options_requested`` — re-exported for the bundle dblclick path
      (jas_app connects it to _open_tool_options_dialog). The bundle grid
      is the only emitter now.
    * ``fill_stroke_widget`` — the fill/stroke indicator, rendered below
      the bundle grid in the toolbar pane.

    It still subclasses QWidget (so the fill/stroke widget can parent to
    it and Qt signal machinery is available) but it is never added to a
    layout itself.
    """

    tool_changed = Signal(Tool)
    # Re-exported for the bundle dblclick path. jas_app connects this to
    # the open_dialog effect using the tool's workspace.json
    # tool_options_dialog field (PAINTBRUSH_TOOL.md §Tool options). The
    # bundle tool grid is the only emitter.
    tool_options_requested = Signal(object)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.current_tool = Tool.SELECTION
        # Which tool is visible in each shared slot. Kept coherent by
        # select_tool so the bundle grid highlight and the canvas tool
        # agree across slot switches.
        self._arrow_slot_tool = Tool.PARTIAL_SELECTION
        self._pen_slot_tool = Tool.PEN
        self._text_slot_tool = Tool.TYPE
        self._pencil_slot_tool = Tool.PENCIL
        self._shape_slot_tool = Tool.RECT

        # The fill/stroke indicator. Parented to this controller; jas_app
        # adds it to the toolbar pane below the bundle grid and syncs it.
        self.fill_stroke_widget = FillStrokeWidget()

    def select_tool(self, tool):
        """Make ``tool`` the active tool and broadcast the change.

        Updates the shared-slot bookkeeping so the occupant of each slot
        tracks the most recent selection, then emits ``tool_changed``.
        """
        if tool in _ARROW_SLOT_TOOLS:
            self._arrow_slot_tool = tool
        elif tool in _PEN_SLOT_TOOLS:
            self._pen_slot_tool = tool
        elif tool in _PENCIL_SLOT_TOOLS:
            self._pencil_slot_tool = tool
        elif tool in _TEXT_SLOT_TOOLS:
            self._text_slot_tool = tool
        elif tool in _SHAPE_SLOT_TOOLS:
            self._shape_slot_tool = tool
        self.current_tool = tool
        self.tool_changed.emit(tool)
