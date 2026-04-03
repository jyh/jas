import sys

from PySide6.QtCore import Qt, QSize
from PySide6.QtGui import QPainter, QColor
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QMdiArea, QMdiSubWindow, QWidget,
)


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


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Jas")

        self.mdi_area = QMdiArea()
        self.mdi_area.setBackground(QColor("#3c3c3c"))
        self.setCentralWidget(self.mdi_area)

        self.canvas = CanvasWidget()
        self.sub_window = QMdiSubWindow()
        self.sub_window.setWidget(self.canvas)
        self.sub_window.setWindowTitle("Untitled")
        self.mdi_area.addSubWindow(self.sub_window)
        self.sub_window.resize(820, 640)
        self.sub_window.show()


def main():
    app = QApplication([])
    window = MainWindow()
    window.resize(1200, 900)
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
