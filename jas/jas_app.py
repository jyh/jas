import sys

from PySide6.QtCore import Qt, QSize
from PySide6.QtGui import QColor, QKeySequence, QShortcut
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QMdiArea, QMdiSubWindow,
)

from canvas import CanvasWidget
from controller import Controller
from menu import create_menus
from model import Model
from toolbar import Tool, Toolbar


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Jas")

        # Menubar
        create_menus(self)

        # Workspace
        self.mdi_area = QMdiArea()
        self.mdi_area.setBackground(QColor("#3c3c3c"))
        self.setCentralWidget(self.mdi_area)

        # Floating toolbar
        self.toolbar = Toolbar()
        self.toolbar_window = QMdiSubWindow()
        self.toolbar_window.setWidget(self.toolbar)
        self.toolbar_window.setWindowTitle("Tools")
        self.mdi_area.addSubWindow(self.toolbar_window)
        self.toolbar_window.resize(80, 100)
        self.toolbar_window.move(10, 10)
        self.toolbar_window.show()

        # Model and Controller
        self.model = Model()
        self.controller = Controller(model=self.model)

        # Canvas subwindow (view)
        self.canvas = CanvasWidget(model=self.model)
        self.sub_window = QMdiSubWindow()
        self.sub_window.setWidget(self.canvas)
        self.mdi_area.addSubWindow(self.sub_window)
        self.sub_window.resize(820, 640)
        self.sub_window.show()
        self.sub_window.setWindowTitle(self.model.document.title)

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
