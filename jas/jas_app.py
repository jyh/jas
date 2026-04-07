import sys

from PySide6.QtCore import Qt
from PySide6.QtGui import QKeySequence, QShortcut
from PySide6.QtWidgets import (
    QApplication, QHBoxLayout, QMainWindow, QMessageBox, QTabWidget, QWidget,
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
        self.tab_widget.setTabsClosable(True)
        self.tab_widget.tabCloseRequested.connect(self._close_tab)
        layout.addWidget(self.tab_widget, stretch=1)

        self.setCentralWidget(central)

        # Keyboard shortcuts
        QShortcut(QKeySequence("V"), self,
                  lambda: self.toolbar.select_tool(Tool.SELECTION))
        QShortcut(QKeySequence("A"), self,
                  lambda: self.toolbar.select_tool(Tool.DIRECT_SELECTION))
        QShortcut(QKeySequence("P"), self,
                  lambda: self.toolbar.select_tool(Tool.PEN))
        QShortcut(QKeySequence("="), self,
                  lambda: self.toolbar.select_tool(Tool.ADD_ANCHOR_POINT))
        QShortcut(QKeySequence("+"), self,
                  lambda: self.toolbar.select_tool(Tool.ADD_ANCHOR_POINT))
        QShortcut(QKeySequence("-"), self,
                  lambda: self.toolbar.select_tool(Tool.DELETE_ANCHOR_POINT))
        QShortcut(QKeySequence("T"), self,
                  lambda: self.toolbar.select_tool(Tool.TYPE))
        QShortcut(QKeySequence("\\"), self,
                  lambda: self.toolbar.select_tool(Tool.LINE))
        QShortcut(QKeySequence("M"), self,
                  lambda: self.toolbar.select_tool(Tool.RECT))
        QShortcut(QKeySequence("Shift+E"), self,
                  lambda: self.toolbar.select_tool(Tool.PATH_ERASER))
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

    def _close_tab(self, index: int) -> None:
        """Close a canvas tab, prompting to save if modified.

        If the user chooses Save, we reuse the menu's _save function which
        handles both named files and the Save-As flow for untitled documents.
        After saving, we re-check is_modified: if it's still True the user
        cancelled the Save-As dialog and the tab should remain open.
        """
        canvas = self.tab_widget.widget(index)
        if not isinstance(canvas, CanvasWidget):
            self.tab_widget.removeTab(index)
            return
        model = canvas._model
        if model.is_modified:
            reply = QMessageBox.question(
                self, "Save Changes",
                f'Do you want to save changes to "{model.filename}"?',
                QMessageBox.Save | QMessageBox.Discard | QMessageBox.Cancel,
                QMessageBox.Save,
            )
            if reply == QMessageBox.Cancel:
                return
            if reply == QMessageBox.Save:
                from menu.menu import _save
                _save(self, model)
                if model.is_modified:
                    return  # Save was cancelled (e.g. Save-As dialog dismissed)
        self.tab_widget.removeTab(index)

    def closeEvent(self, event):
        """Intercept window close to prompt for unsaved changes.

        Collects all modified models across tabs. If any are modified, shows
        a dialog with Cancel / Don't Save / Save / Save All. Save saves
        only the active model; Save All saves every modified model. If any
        Save-As dialog is cancelled (model still modified), the close is
        aborted.
        """
        modified = []
        for i in range(self.tab_widget.count()):
            canvas = self.tab_widget.widget(i)
            if isinstance(canvas, CanvasWidget) and canvas._model.is_modified:
                modified.append(canvas._model)
        if not modified:
            event.accept()
            return
        names = ", ".join(f'"{m.filename}"' for m in modified)
        box = QMessageBox(self)
        box.setWindowTitle("Save Changes")
        box.setText(f"Do you want to save changes to {names}?")
        box.setStandardButtons(
            QMessageBox.Save | QMessageBox.Discard | QMessageBox.Cancel)
        save_all_btn = box.addButton("Save All", QMessageBox.AcceptRole)
        box.setDefaultButton(QMessageBox.Save)
        box.exec()
        clicked = box.clickedButton()
        if clicked == save_all_btn:
            from menu.menu import _save
            for m in modified:
                _save(self, m)
                if m.is_modified:
                    event.ignore()
                    return
            event.accept()
        elif box.standardButton(clicked) == QMessageBox.Save:
            from menu.menu import _save
            active = self.active_model()
            if active and active.is_modified:
                _save(self, active)
                if active.is_modified:
                    event.ignore()
                    return
            event.accept()
        elif box.standardButton(clicked) == QMessageBox.Discard:
            event.accept()
        else:
            event.ignore()

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
