from enum import Enum, auto

from tools.tool import LONG_PRESS_MS

from PySide6.QtCore import Qt, Signal, QTimer, QPoint
from PySide6.QtGui import QPainter, QColor, QPen, QPainterPath, QFont
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QGridLayout, QToolButton, QButtonGroup, QMenu,
)


class Tool(Enum):
    SELECTION = auto()
    DIRECT_SELECTION = auto()
    GROUP_SELECTION = auto()
    PEN = auto()
    PENCIL = auto()
    TEXT = auto()
    TEXT_PATH = auto()
    LINE = auto()
    RECT = auto()
    POLYGON = auto()


def _draw_arrow_path() -> QPainterPath:
    """Return the shared arrow cursor path."""
    path = QPainterPath()
    path.moveTo(5, 2)
    path.lineTo(5, 24)
    path.lineTo(10, 18)
    path.lineTo(15, 26)
    path.lineTo(18, 24)
    path.lineTo(13, 16)
    path.lineTo(20, 16)
    path.closeSubpath()
    return path


class ToolButton(QToolButton):
    """A toolbar button that draws a tool icon."""

    ICON_SIZE = 28
    BUTTON_SIZE = 32

    def __init__(self, tool, parent=None, has_alternates=False):
        super().__init__(parent)
        self.tool = tool
        self.has_alternates = has_alternates
        self.setCheckable(True)
        self.setFixedSize(self.BUTTON_SIZE, self.BUTTON_SIZE)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        # Background on checked
        if self.isChecked():
            painter.fillRect(self.rect(), QColor("#505050"))

        # Center the icon
        ox = (self.width() - self.ICON_SIZE) / 2.0
        oy = (self.height() - self.ICON_SIZE) / 2.0
        painter.translate(ox, oy)

        pen = QPen(QColor("#cccccc"), 1.5)
        painter.setPen(pen)

        if self.tool == Tool.SELECTION:
            self._draw_selection_arrow(painter)
        elif self.tool == Tool.DIRECT_SELECTION:
            self._draw_direct_selection_arrow(painter)
        elif self.tool == Tool.GROUP_SELECTION:
            self._draw_group_selection_arrow(painter)
        elif self.tool == Tool.LINE:
            self._draw_line_tool(painter)
        elif self.tool == Tool.RECT:
            self._draw_rect_tool(painter)
        elif self.tool == Tool.PEN:
            self._draw_pen_tool(painter)
        elif self.tool == Tool.PENCIL:
            self._draw_pencil_tool(painter)
        elif self.tool == Tool.TEXT:
            self._draw_text_tool(painter)
        elif self.tool == Tool.TEXT_PATH:
            self._draw_text_path_tool(painter)
        elif self.tool == Tool.POLYGON:
            self._draw_polygon_tool(painter)

        if self.has_alternates:
            self._draw_alternate_triangle(painter)

    def _draw_selection_arrow(self, painter):
        """Black arrow with white border."""
        path = _draw_arrow_path()
        painter.setPen(QPen(QColor("#ffffff"), 1.0))
        painter.setBrush(QColor("#000000"))
        painter.drawPath(path)

    def _draw_direct_selection_arrow(self, painter):
        """White arrow with black border."""
        path = _draw_arrow_path()
        painter.setPen(QPen(QColor("#000000"), 1.0))
        painter.setBrush(QColor("#ffffff"))
        painter.drawPath(path)

    def _draw_group_selection_arrow(self, painter):
        """White arrow with black border and '+' badge."""
        path = _draw_arrow_path()
        painter.setPen(QPen(QColor("#000000"), 1.0))
        painter.setBrush(QColor("#ffffff"))
        painter.drawPath(path)
        # Draw '+' in the lower-right
        painter.setPen(QPen(QColor("#cccccc"), 1.5))
        painter.drawLine(20, 20, 27, 20)
        painter.drawLine(23.5, 16.5, 23.5, 23.5)

    def _draw_line_tool(self, painter):
        painter.setPen(QPen(QColor("#cccccc"), 1.5))
        painter.drawLine(4, self.ICON_SIZE - 4, self.ICON_SIZE - 4, 4)
        painter.drawEllipse(1, self.ICON_SIZE - 6, 6, 6)
        painter.drawEllipse(self.ICON_SIZE - 7, 1, 6, 6)

    def _draw_rect_tool(self, painter):
        painter.setPen(QPen(QColor("#cccccc"), 1.5))
        painter.drawRect(4, 4, self.ICON_SIZE - 8, self.ICON_SIZE - 8)

    def _draw_pen_tool(self, painter):
        # Pen icon from SVG paths (viewBox 0 0 256 256), scaled to 28x28.
        s = 28.0 / 256.0  # 0.109375
        ox = (self.ICON_SIZE - 28) / 2.0
        oy = (self.ICON_SIZE - 28) / 2.0
        painter.save()
        painter.translate(ox, oy)
        painter.scale(s, s)
        # Outer path (icon color)
        outer = QPainterPath()
        outer.moveTo(163.07, 190.51)
        outer.lineTo(175.61, 210.03)
        outer.lineTo(84.93, 255.99)
        outer.lineTo(72.47, 227.94)
        outer.cubicTo(58.86, 195.29, 32.68, 176.45, 0.13, 161.51)
        outer.lineTo(0, 4.58)
        outer.cubicTo(0, 2.38, 2.8, -0.28, 4.11, -0.37)
        outer.cubicTo(5.42, -0.46, 8.07, 0.08, 9.42, 0.97)
        outer.lineTo(94.84, 57.3)
        outer.lineTo(143.22, 89.45)
        outer.cubicTo(135.93, 124.03, 139.17, 161.04, 163.08, 190.51)
        outer.closeSubpath()
        # Inner cutout
        outer.moveTo(61.7, 49.58)
        outer.lineTo(23.48, 24.2)
        outer.lineTo(65.56, 102.31)
        outer.cubicTo(73.04, 102.48, 79.74, 105.2, 83.05, 111.1)
        outer.cubicTo(86.36, 117.0, 86.92, 124.26, 82.1, 129.97)
        outer.cubicTo(75.74, 137.51, 64.43, 138.54, 57.38, 133.01)
        outer.cubicTo(49.55, 126.87, 47.97, 116.88, 54.52, 108.06)
        outer.lineTo(12.09, 30.4)
        outer.lineTo(12.53, 100.36)
        outer.lineTo(12.24, 154.67)
        outer.cubicTo(37.86, 166.32, 59.12, 182.87, 73.77, 206.51)
        outer.lineTo(138.57, 173.27)
        outer.cubicTo(127.46, 148.19, 124.88, 122.64, 130.1, 95.08)
        outer.lineTo(61.7, 49.58)
        outer.closeSubpath()
        outer.setFillRule(Qt.FillRule.OddEvenFill)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QColor("#cccccc"))
        painter.drawPath(outer)
        painter.restore()

    def _draw_pencil_tool(self, painter):
        painter.setPen(QPen(QColor("#cccccc"), 1.5))
        painter.setBrush(Qt.BrushStyle.NoBrush)
        path = QPainterPath()
        # Pencil body (angled)
        path.moveTo(6, 22)
        path.lineTo(20, 8)
        path.lineTo(24, 4)
        path.lineTo(26, 6)
        path.lineTo(22, 10)
        path.lineTo(8, 24)
        path.closeSubpath()
        painter.drawPath(path)
        # Tip
        painter.drawLine(6, 22, 4, 26)
        painter.drawLine(4, 26, 8, 24)

    def _draw_text_tool(self, painter):
        painter.setPen(QPen(QColor("#cccccc"), 1.5))
        font = QFont("sans-serif", 18, QFont.Weight.Bold)
        painter.setFont(font)
        painter.drawText(4, 22, "T")

    def _draw_text_path_tool(self, painter):
        painter.setPen(QPen(QColor("#cccccc"), 1.5))
        font = QFont("sans-serif", 14, QFont.Weight.Bold)
        painter.setFont(font)
        painter.drawText(2, 18, "T")
        # Draw a small wavy path
        path = QPainterPath()
        path.moveTo(12, 20)
        path.cubicTo(16, 8, 22, 24, 26, 12)
        painter.setPen(QPen(QColor("#cccccc"), 1.0))
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.drawPath(path)

    def _draw_polygon_tool(self, painter):
        import math
        painter.setPen(QPen(QColor("#cccccc"), 1.5))
        painter.setBrush(Qt.BrushStyle.NoBrush)
        cx, cy, r = self.ICON_SIZE / 2, self.ICON_SIZE / 2, self.ICON_SIZE / 2 - 3
        n = 6
        path = QPainterPath()
        for i in range(n):
            angle = -math.pi / 2 + 2 * math.pi * i / n
            px = cx + r * math.cos(angle)
            py = cy + r * math.sin(angle)
            if i == 0:
                path.moveTo(px, py)
            else:
                path.lineTo(px, py)
        path.closeSubpath()
        painter.drawPath(path)

    def _draw_alternate_triangle(self, painter):
        """Small filled triangle in the lower-right corner indicating alternates."""
        tri = QPainterPath()
        s = 5
        tri.moveTo(self.ICON_SIZE, self.ICON_SIZE)
        tri.lineTo(self.ICON_SIZE - s, self.ICON_SIZE)
        tri.lineTo(self.ICON_SIZE, self.ICON_SIZE - s)
        tri.closeSubpath()
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QColor("#cccccc"))
        painter.drawPath(tri)


# Tools that share the direct/group selection slot
_ARROW_SLOT_TOOLS = {Tool.DIRECT_SELECTION, Tool.GROUP_SELECTION}
# Tools that share the text/text-path slot
_TEXT_SLOT_TOOLS = {Tool.TEXT, Tool.TEXT_PATH}
# Tools that share the rect/polygon slot
_SHAPE_SLOT_TOOLS = {Tool.RECT, Tool.POLYGON}
_LONG_PRESS_MS = LONG_PRESS_MS


class Toolbar(QWidget):
    """Vertical toolbar with tool icons in a 2-column grid."""

    tool_changed = Signal(Tool)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.current_tool = Tool.SELECTION
        # Which tool is visible in the shared arrow slot
        self._arrow_slot_tool = Tool.DIRECT_SELECTION
        # Which tool is visible in the shared text slot
        self._text_slot_tool = Tool.TEXT
        # Which tool is visible in the shared shape slot
        self._shape_slot_tool = Tool.RECT

        layout = QVBoxLayout(self)
        layout.setContentsMargins(2, 4, 2, 4)
        layout.setSpacing(0)

        grid = QGridLayout()
        grid.setSpacing(2)
        layout.addLayout(grid)
        layout.addStretch()

        self.button_group = QButtonGroup(self)
        self.button_group.setExclusive(True)

        self.buttons = {}
        # The arrow slot button starts as direct selection
        # The shape slot button starts as rect
        tools = [
            (Tool.SELECTION, 0, 0),
            (Tool.DIRECT_SELECTION, 0, 1),
            (Tool.PEN, 1, 0),
            (Tool.PENCIL, 1, 1),
            (Tool.TEXT, 2, 0),
            (Tool.LINE, 2, 1),
            (Tool.RECT, 3, 0),
        ]
        for tool, row, col in tools:
            has_alt = tool in _ARROW_SLOT_TOOLS or tool in _TEXT_SLOT_TOOLS or tool in _SHAPE_SLOT_TOOLS
            btn = ToolButton(tool, has_alternates=has_alt)
            self.buttons[tool] = btn
            self.button_group.addButton(btn)
            grid.addWidget(btn, row, col)

        # Create hidden alternate buttons (not in grid, share slots)
        self.buttons[Tool.GROUP_SELECTION] = ToolButton(Tool.GROUP_SELECTION, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.GROUP_SELECTION])
        self.buttons[Tool.TEXT_PATH] = ToolButton(Tool.TEXT_PATH, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.TEXT_PATH])
        self.buttons[Tool.POLYGON] = ToolButton(Tool.POLYGON, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.POLYGON])

        self.buttons[Tool.SELECTION].setChecked(True)
        self.button_group.buttonClicked.connect(self._on_button_clicked)

        # Long-press timer for the arrow slot
        self._long_press_timer = QTimer(self)
        self._long_press_timer.setSingleShot(True)
        self._long_press_timer.setInterval(_LONG_PRESS_MS)
        self._long_press_timer.timeout.connect(self._show_arrow_slot_menu)

        # Long-press timer for the text slot
        self._text_long_press_timer = QTimer(self)
        self._text_long_press_timer.setSingleShot(True)
        self._text_long_press_timer.setInterval(_LONG_PRESS_MS)
        self._text_long_press_timer.timeout.connect(self._show_text_slot_menu)

        # Long-press timer for the shape slot
        self._shape_long_press_timer = QTimer(self)
        self._shape_long_press_timer.setSingleShot(True)
        self._shape_long_press_timer.setInterval(_LONG_PRESS_MS)
        self._shape_long_press_timer.timeout.connect(self._show_shape_slot_menu)

        # Install press/release handling on the arrow slot button
        arrow_btn = self.buttons[Tool.DIRECT_SELECTION]
        arrow_btn.pressed.connect(self._on_arrow_slot_pressed)
        arrow_btn.released.connect(self._on_arrow_slot_released)

        # Install press/release handling on the text slot button
        text_btn = self.buttons[Tool.TEXT]
        text_btn.pressed.connect(self._on_text_slot_pressed)
        text_btn.released.connect(self._on_text_slot_released)

        # Install press/release handling on the shape slot button
        shape_btn = self.buttons[Tool.RECT]
        shape_btn.pressed.connect(self._on_shape_slot_pressed)
        shape_btn.released.connect(self._on_shape_slot_released)

    def _on_button_clicked(self, btn):
        self.current_tool = btn.tool
        self.tool_changed.emit(btn.tool)

    def _on_arrow_slot_pressed(self):
        self._long_press_timer.start()

    def _on_arrow_slot_released(self):
        if self._long_press_timer.isActive():
            self._long_press_timer.stop()

    def _on_text_slot_pressed(self):
        self._text_long_press_timer.start()

    def _on_text_slot_released(self):
        if self._text_long_press_timer.isActive():
            self._text_long_press_timer.stop()

    def _on_shape_slot_pressed(self):
        self._shape_long_press_timer.start()

    def _on_shape_slot_released(self):
        if self._shape_long_press_timer.isActive():
            self._shape_long_press_timer.stop()

    def _show_arrow_slot_menu(self):
        menu = QMenu(self)
        for tool in (Tool.DIRECT_SELECTION, Tool.GROUP_SELECTION):
            label = "Direct Selection" if tool == Tool.DIRECT_SELECTION else "Group Selection"
            action = menu.addAction(label)
            action.setCheckable(True)
            action.setChecked(tool == self._arrow_slot_tool)
            action.triggered.connect(lambda checked, t=tool: self._switch_arrow_slot(t))
        btn = self.buttons[self._arrow_slot_tool]
        menu.exec(btn.mapToGlobal(QPoint(0, btn.height())))

    def _show_text_slot_menu(self):
        menu = QMenu(self)
        for tool in (Tool.TEXT, Tool.TEXT_PATH):
            label = "Text" if tool == Tool.TEXT else "Text on Path"
            action = menu.addAction(label)
            action.setCheckable(True)
            action.setChecked(tool == self._text_slot_tool)
            action.triggered.connect(lambda checked, t=tool: self._switch_text_slot(t))
        btn = self.buttons[Tool.TEXT]
        menu.exec(btn.mapToGlobal(QPoint(0, btn.height())))

    def _show_shape_slot_menu(self):
        menu = QMenu(self)
        for tool in (Tool.RECT, Tool.POLYGON):
            label = "Rectangle" if tool == Tool.RECT else "Polygon"
            action = menu.addAction(label)
            action.setCheckable(True)
            action.setChecked(tool == self._shape_slot_tool)
            action.triggered.connect(lambda checked, t=tool: self._switch_shape_slot(t))
        btn = self.buttons[Tool.RECT]
        menu.exec(btn.mapToGlobal(QPoint(0, btn.height())))

    def _switch_arrow_slot(self, tool: Tool):
        """Switch the arrow slot to show a different tool."""
        if tool == self._arrow_slot_tool:
            return
        self._arrow_slot_tool = tool
        arrow_btn = self.buttons[Tool.DIRECT_SELECTION]
        arrow_btn.tool = tool
        arrow_btn.update()
        self.select_tool(tool)

    def _switch_text_slot(self, tool: Tool):
        """Switch the text slot to show a different tool."""
        if tool == self._text_slot_tool:
            return
        self._text_slot_tool = tool
        text_btn = self.buttons[Tool.TEXT]
        text_btn.tool = tool
        text_btn.update()
        self.select_tool(tool)

    def _switch_shape_slot(self, tool: Tool):
        """Switch the shape slot to show a different tool."""
        if tool == self._shape_slot_tool:
            return
        self._shape_slot_tool = tool
        shape_btn = self.buttons[Tool.RECT]
        shape_btn.tool = tool
        shape_btn.update()
        self.select_tool(tool)

    def select_tool(self, tool):
        if tool in _ARROW_SLOT_TOOLS:
            arrow_btn = self.buttons[Tool.DIRECT_SELECTION]
            arrow_btn.tool = tool
            arrow_btn.setChecked(True)
            arrow_btn.update()
            self._arrow_slot_tool = tool
        elif tool in _TEXT_SLOT_TOOLS:
            text_btn = self.buttons[Tool.TEXT]
            text_btn.tool = tool
            text_btn.setChecked(True)
            text_btn.update()
            self._text_slot_tool = tool
        elif tool in _SHAPE_SLOT_TOOLS:
            shape_btn = self.buttons[Tool.RECT]
            shape_btn.tool = tool
            shape_btn.setChecked(True)
            shape_btn.update()
            self._shape_slot_tool = tool
        elif tool in self.buttons:
            self.buttons[tool].setChecked(True)
        self.current_tool = tool
        self.tool_changed.emit(tool)
