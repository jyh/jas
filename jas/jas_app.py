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

        # Menubar (uses active_model for focused canvas)
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
        self.toolbar_window.move(0, 0)
        self.toolbar_window.show()

        # Canvas subwindow (view) — placed right next to the toolbar
        self.add_canvas(Model(),
                        x=self.toolbar_window.frameGeometry().right() + 4, y=0)

    def add_canvas(self, model: Model, x: int = 100, y: int = 100) -> None:
        """Create a new canvas subwindow for the given model."""
        controller = Controller(model=model)
        canvas = CanvasWidget(model=model, controller=controller)
        sub_window = QMdiSubWindow()
        sub_window.model = model  # store for active_model lookup
        sub_window.setWidget(canvas)
        self.mdi_area.addSubWindow(sub_window)
        sub_window.resize(820, 640)
        sub_window.move(x, y)
        sub_window.show()
        self.toolbar.tool_changed.connect(canvas.set_tool)

        def update_title(_=None):
            title = model.filename
            if model.is_modified:
                title += " *"
            sub_window.setWindowTitle(title)

        update_title()
        model.on_document_changed(update_title)
        model.on_filename_changed(update_title)

        # Keyboard shortcuts (only register once)
        if not hasattr(self, '_shortcuts_registered'):
            self._shortcuts_registered = True
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
            QShortcut(QKeySequence.StandardKey.Undo, self, self._undo)
            QShortcut(QKeySequence.StandardKey.Redo, self, self._redo)

    def active_model(self) -> Model | None:
        """Return the model of the focused canvas subwindow."""
        sub = self.mdi_area.activeSubWindow()
        return getattr(sub, 'model', None) if sub else None

    def _undo(self):
        m = self.active_model()
        if m:
            m.undo()

    def _redo(self):
        m = self.active_model()
        if m:
            m.redo()

    def _delete_selection(self):
        m = self.active_model()
        if not m:
            return
        doc = m.document
        if doc.selection:
            m.snapshot()
            m.document = doc.delete_selection()


def main():
    app = QApplication([])
    window = MainWindow()
    window.resize(1200, 900)
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
