import sys

from PySide6.QtCore import Qt, QSize
from PySide6.QtGui import QColor, QKeySequence, QShortcut
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QMdiArea, QMdiSubWindow,
)

from canvas.canvas import CanvasWidget
from document.controller import Controller
from menu.menu import create_menus
from document.model import Model
from tools.toolbar import Tool, Toolbar


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Jas")

        # Model and Controller
        self.model = Model()
        self.controller = Controller(model=self.model)

        # Menubar
        create_menus(self, self.model)

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
        self.toolbar_window.move(0, 0)
        self.toolbar_window.show()

        # Canvas subwindow (view) — placed right next to the toolbar
        self.canvas = CanvasWidget(model=self.model, controller=self.controller)
        self.sub_window = QMdiSubWindow()
        self.sub_window.setWidget(self.canvas)
        self.mdi_area.addSubWindow(self.sub_window)
        self.sub_window.resize(820, 640)
        self.sub_window.move(self.toolbar_window.frameGeometry().right() + 4, 0)
        self.sub_window.show()
        self.sub_window.setWindowTitle(self.model.document.title)

        # Connect toolbar to canvas
        self.toolbar.tool_changed.connect(self.canvas.set_tool)

        # Keyboard shortcuts
        QShortcut(QKeySequence("V"), self,
                  lambda: self.toolbar.select_tool(Tool.SELECTION))
        QShortcut(QKeySequence("A"), self,
                  lambda: self.toolbar.select_tool(Tool.DIRECT_SELECTION))
        QShortcut(QKeySequence("P"), self,
                  lambda: self.toolbar.select_tool(Tool.PEN))
        QShortcut(QKeySequence("T"), self,
                  lambda: self.toolbar.select_tool(Tool.TEXT))
        QShortcut(QKeySequence("\\"), self,
                  lambda: self.toolbar.select_tool(Tool.LINE))
        QShortcut(QKeySequence("M"), self,
                  lambda: self.toolbar.select_tool(Tool.RECT))
        QShortcut(QKeySequence(Qt.Key_Delete), self, self._delete_selection)
        QShortcut(QKeySequence(Qt.Key_Backspace), self, self._delete_selection)

    def _delete_selection(self):
        doc = self.model.document
        if doc.selection:
            self.model.document = doc.delete_selection()


def main():
    app = QApplication([])
    window = MainWindow()
    window.resize(1200, 900)
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
