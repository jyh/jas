import sys

from PySide6.QtCore import Qt, QSize
from PySide6.QtGui import QColor, QKeySequence, QShortcut
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QMdiArea, QMdiSubWindow, QDockWidget,
)

from canvas import CanvasWidget
from toolbar import Tool, Toolbar


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Jas")

        # Toolbar
        self.toolbar = Toolbar()
        dock = QDockWidget("Tools", self)
        dock.setWidget(self.toolbar)
        dock.setFeatures(QDockWidget.DockWidgetMovable)
        dock.setAllowedAreas(Qt.LeftDockWidgetArea | Qt.RightDockWidgetArea)
        self.addDockWidget(Qt.LeftDockWidgetArea, dock)

        # Workspace
        self.mdi_area = QMdiArea()
        self.mdi_area.setBackground(QColor("#3c3c3c"))
        self.setCentralWidget(self.mdi_area)

        # Canvas subwindow
        self.canvas = CanvasWidget()
        self.sub_window = QMdiSubWindow()
        self.sub_window.setWidget(self.canvas)
        self.sub_window.setWindowTitle("Untitled")
        self.mdi_area.addSubWindow(self.sub_window)
        self.sub_window.resize(820, 640)
        self.sub_window.show()

        # Keyboard shortcuts
        QShortcut(QKeySequence("V"), self,
                  lambda: self.toolbar.select_tool(Tool.SELECTION))
        QShortcut(QKeySequence("A"), self,
                  lambda: self.toolbar.select_tool(Tool.DIRECT_SELECTION))


def main():
    app = QApplication([])
    window = MainWindow()
    window.resize(1200, 900)
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
