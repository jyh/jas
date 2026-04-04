from enum import Enum, auto

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QPainter, QColor, QPen, QPainterPath
from PySide6.QtWidgets import QWidget, QVBoxLayout, QGridLayout, QToolButton, QButtonGroup


class Tool(Enum):
    SELECTION = auto()
    DIRECT_SELECTION = auto()
    LINE = auto()


class ToolButton(QToolButton):
    """A toolbar button that draws a tool icon."""

    ICON_SIZE = 28
    BUTTON_SIZE = 32

    def __init__(self, tool, parent=None):
        super().__init__(parent)
        self.tool = tool
        self.setCheckable(True)
        self.setFixedSize(self.BUTTON_SIZE, self.BUTTON_SIZE)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)

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
        elif self.tool == Tool.LINE:
            self._draw_line_icon(painter)

    def _draw_selection_arrow(self, painter):
        """Filled arrow pointing upper-right."""
        path = QPainterPath()
        path.moveTo(5, 2)
        path.lineTo(5, 24)
        path.lineTo(10, 18)
        path.lineTo(15, 26)
        path.lineTo(18, 24)
        path.lineTo(13, 16)
        path.lineTo(20, 16)
        path.closeSubpath()
        painter.setPen(QPen(QColor("#cccccc"), 1.0))
        painter.setBrush(QColor("#cccccc"))
        painter.drawPath(path)

    def _draw_direct_selection_arrow(self, painter):
        """Outline arrow pointing upper-right."""
        path = QPainterPath()
        path.moveTo(5, 2)
        path.lineTo(5, 24)
        path.lineTo(10, 18)
        path.lineTo(15, 26)
        path.lineTo(18, 24)
        path.lineTo(13, 16)
        path.lineTo(20, 16)
        path.closeSubpath()
        painter.setPen(QPen(QColor("#cccccc"), 1.5))
        painter.setBrush(Qt.NoBrush)
        painter.drawPath(path)


    def _draw_line_icon(self, painter):
        """Diagonal line from bottom-left to upper-right."""
        painter.setPen(QPen(QColor("#cccccc"), 2.0))
        painter.drawLine(4, 24, 24, 4)


class Toolbar(QWidget):
    """Vertical toolbar with tool icons in a 2-column grid."""

    tool_changed = Signal(Tool)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.current_tool = Tool.SELECTION

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
        tools = [
            (Tool.SELECTION, 0, 0),
            (Tool.DIRECT_SELECTION, 0, 1),
            (Tool.LINE, 1, 0),
        ]
        for tool, row, col in tools:
            btn = ToolButton(tool)
            self.buttons[tool] = btn
            self.button_group.addButton(btn)
            grid.addWidget(btn, row, col)

        self.buttons[Tool.SELECTION].setChecked(True)
        self.button_group.buttonClicked.connect(self._on_button_clicked)

    def _on_button_clicked(self, btn):
        self.current_tool = btn.tool
        self.tool_changed.emit(btn.tool)

    def select_tool(self, tool):
        self.buttons[tool].setChecked(True)
        self.current_tool = tool
        self.tool_changed.emit(tool)
