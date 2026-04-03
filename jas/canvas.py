from PySide6.QtCore import QSize
from PySide6.QtGui import QPainter, QColor
from PySide6.QtWidgets import QWidget


class CanvasWidget(QWidget):
    """The main drawing canvas."""

    def __init__(self):
        super().__init__()
        self.setMinimumSize(320, 240)
        self.setMouseTracking(True)

    def sizeHint(self):
        return QSize(800, 600)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.fillRect(self.rect(), QColor("white"))
