from dataclasses import dataclass
from typing import Tuple

from PySide6.QtCore import QSize
from PySide6.QtGui import QPainter, QColor
from PySide6.QtWidgets import QWidget


@dataclass(frozen=True)
class BoundingBox:
    """Axis-aligned bounding box."""
    x: float
    y: float
    width: float
    height: float


class CanvasWidget(QWidget):
    """The main drawing canvas."""

    def __init__(self, bbox: BoundingBox = BoundingBox(0, 0, 800, 600)):
        super().__init__()
        self._bbox = bbox
        self.setMinimumSize(320, 240)
        self.setMouseTracking(True)

    @property
    def bbox(self) -> BoundingBox:
        return self._bbox

    def sizeHint(self):
        return QSize(int(self._bbox.width), int(self._bbox.height))

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.fillRect(self.rect(), QColor("white"))
