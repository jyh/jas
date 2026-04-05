import sys

from PySide6.QtCore import Qt
from PySide6.QtGui import QKeySequence, QShortcut
from PySide6.QtWidgets import (
    QApplication, QHBoxLayout, QMainWindow, QTabWidget, QWidget,
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

        # Central layout: toolbar on the left, tab widget on the right
        central = QWidget()
        layout = QHBoxLayout(central)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # Toolbar
        self.toolbar = Toolbar()
        layout.addWidget(self.toolbar)

        # Tabbed canvas container
        self.tab_widget = QTabWidget()
        self.tab_widget.setTabsClosable(False)
        layout.addWidget(self.tab_widget, stretch=1)

        self.setCentralWidget(central)

        # First canvas
        self.add_canvas(Model())

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
        QShortcut(QKeySequence.StandardKey.Undo, self, self._undo)
        QShortcut(QKeySequence.StandardKey.Redo, self, self._redo)

    def add_canvas(self, model: Model) -> None:
        """Create a new canvas tab for the given model."""
        controller = Controller(model=model)
        canvas = CanvasWidget(model=model, controller=controller)
        self.toolbar.tool_changed.connect(canvas.set_tool)

        def tab_label(_=None):
            title = model.filename
            if model.is_modified:
                title += " *"
            idx = self.tab_widget.indexOf(canvas)
            if idx >= 0:
                self.tab_widget.setTabText(idx, title)

        idx = self.tab_widget.addTab(canvas, model.filename)
        self.tab_widget.setCurrentIndex(idx)
        model.on_document_changed(tab_label)
        model.on_filename_changed(tab_label)
        tab_label()

    def active_model(self) -> Model | None:
        """Return the model of the focused canvas tab."""
        canvas = self.tab_widget.currentWidget()
        return canvas._model if isinstance(canvas, CanvasWidget) else None

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
