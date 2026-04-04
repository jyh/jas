from enum import Enum, auto

from PySide6.QtCore import Qt, Signal, QTimer, QPoint
from PySide6.QtGui import QPainter, QColor, QPen, QPainterPath, QFont
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QGridLayout, QToolButton, QButtonGroup, QMenu,
)


class Tool(Enum):
    SELECTION = auto()
    DIRECT_SELECTION = auto()
    GROUP_SELECTION = auto()
    LINE = auto()
    RECT = auto()


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

        if self.has_alternates:
            self._draw_alternate_triangle(painter)

    def _draw_selection_arrow(self, painter):
        """Filled arrow."""
        path = _draw_arrow_path()
        painter.setPen(QPen(QColor("#cccccc"), 1.0))
        painter.setBrush(QColor("#cccccc"))
        painter.drawPath(path)

    def _draw_direct_selection_arrow(self, painter):
        """Outline arrow."""
        path = _draw_arrow_path()
        painter.setPen(QPen(QColor("#cccccc"), 1.0))
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.drawPath(path)

    def _draw_group_selection_arrow(self, painter):
        """Outline arrow with a '+' badge."""
        path = _draw_arrow_path()
        painter.setPen(QPen(QColor("#cccccc"), 1.0))
        painter.setBrush(Qt.BrushStyle.NoBrush)
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
_LONG_PRESS_MS = 500


class Toolbar(QWidget):
    """Vertical toolbar with tool icons in a 2-column grid."""

    tool_changed = Signal(Tool)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.current_tool = Tool.SELECTION
        # Which tool is visible in the shared arrow slot
        self._arrow_slot_tool = Tool.DIRECT_SELECTION

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
        tools = [
            (Tool.SELECTION, 0, 0),
            (Tool.DIRECT_SELECTION, 0, 1),
            (Tool.LINE, 1, 0),
            (Tool.RECT, 1, 1),
        ]
        for tool, row, col in tools:
            has_alt = tool in _ARROW_SLOT_TOOLS
            btn = ToolButton(tool, has_alternates=has_alt)
            self.buttons[tool] = btn
            self.button_group.addButton(btn)
            grid.addWidget(btn, row, col)

        # Create the hidden group selection button (not in grid, shares slot)
        self.buttons[Tool.GROUP_SELECTION] = ToolButton(Tool.GROUP_SELECTION, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.GROUP_SELECTION])

        self.buttons[Tool.SELECTION].setChecked(True)
        self.button_group.buttonClicked.connect(self._on_button_clicked)

        # Long-press timer for the arrow slot
        self._long_press_timer = QTimer(self)
        self._long_press_timer.setSingleShot(True)
        self._long_press_timer.setInterval(_LONG_PRESS_MS)
        self._long_press_timer.timeout.connect(self._show_arrow_slot_menu)

        # Install press/release handling on the arrow slot button
        arrow_btn = self.buttons[Tool.DIRECT_SELECTION]
        arrow_btn.pressed.connect(self._on_arrow_slot_pressed)
        arrow_btn.released.connect(self._on_arrow_slot_released)

    def _on_button_clicked(self, btn):
        self.current_tool = btn.tool
        self.tool_changed.emit(btn.tool)

    def _on_arrow_slot_pressed(self):
        self._long_press_timer.start()

    def _on_arrow_slot_released(self):
        if self._long_press_timer.isActive():
            self._long_press_timer.stop()

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

    def _switch_arrow_slot(self, tool: Tool):
        """Switch the arrow slot to show a different tool."""
        if tool == self._arrow_slot_tool:
            return
        self._arrow_slot_tool = tool
        # Update the visible button's tool identity and repaint
        arrow_btn = self.buttons[Tool.DIRECT_SELECTION]
        arrow_btn.tool = tool
        arrow_btn.update()
        # Select this tool
        self.select_tool(tool)

    def select_tool(self, tool):
        if tool in _ARROW_SLOT_TOOLS:
            # Make sure the slot shows this tool
            arrow_btn = self.buttons[Tool.DIRECT_SELECTION]
            arrow_btn.tool = tool
            arrow_btn.setChecked(True)
            arrow_btn.update()
            self._arrow_slot_tool = tool
        elif tool in self.buttons:
            self.buttons[tool].setChecked(True)
        self.current_tool = tool
        self.tool_changed.emit(tool)
