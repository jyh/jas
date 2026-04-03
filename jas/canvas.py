from dataclasses import dataclass

from PySide6.QtCore import QSize
from PySide6.QtGui import QPainter, QColor
from PySide6.QtWidgets import QWidget

from document import Document
from model import Model


@dataclass(frozen=True)
class BoundingBox:
    """Axis-aligned bounding box in px."""
    x: float
    y: float
    width: float
    height: float


class CanvasWidget(QWidget):
    """The canvas view. Receives document updates from the Model."""

    def __init__(self, model: Model, bbox: BoundingBox = BoundingBox(0, 0, 800, 600)):
        super().__init__()
        self._model = model
        self._bbox = bbox
        self.setMinimumSize(320, 240)
        self.setMouseTracking(True)
        model.on_document_changed(self._on_document_changed)

    @property
    def bbox(self) -> BoundingBox:
        return self._bbox

    def _on_document_changed(self, document: Document) -> None:
        self.update()

    def sizeHint(self):
        return QSize(int(self._bbox.width), int(self._bbox.height))

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.fillRect(self.rect(), QColor("white"))
