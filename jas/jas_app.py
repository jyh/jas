import sys

from PySide6.QtCore import Qt, QSize
from PySide6.QtGui import QColor, QKeySequence, QShortcut, QAction
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QMdiArea, QMdiSubWindow, QDockWidget,
)

from canvas import CanvasWidget
from toolbar import Tool, Toolbar


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Jas")

        # Menubar
        self._create_menus()

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

    def _create_menus(self):
        menubar = self.menuBar()

        # File menu
        file_menu = menubar.addMenu("&File")

        new_action = file_menu.addAction("&New")
        new_action.setShortcut(QKeySequence.New)
        new_action.triggered.connect(lambda: print("New file"))

        open_action = file_menu.addAction("&Open...")
        open_action.setShortcut(QKeySequence.Open)
        open_action.triggered.connect(lambda: print("Open file"))

        save_action = file_menu.addAction("&Save")
        save_action.setShortcut(QKeySequence.Save)
        save_action.triggered.connect(lambda: print("Save file"))

        save_as_action = file_menu.addAction("Save &As...")
        save_as_action.setShortcut(QKeySequence.SaveAs)
        save_as_action.triggered.connect(lambda: print("Save as"))

        file_menu.addSeparator()

        quit_action = file_menu.addAction("&Quit")
        quit_action.setShortcut(QKeySequence.Quit)
        quit_action.triggered.connect(self.close)

        # Edit menu
        edit_menu = menubar.addMenu("&Edit")

        undo_action = edit_menu.addAction("&Undo")
        undo_action.setShortcut(QKeySequence.Undo)
        undo_action.triggered.connect(lambda: print("Undo"))

        redo_action = edit_menu.addAction("&Redo")
        redo_action.setShortcut(QKeySequence.Redo)
        redo_action.triggered.connect(lambda: print("Redo"))

        edit_menu.addSeparator()

        cut_action = edit_menu.addAction("Cu&t")
        cut_action.setShortcut(QKeySequence.Cut)
        cut_action.triggered.connect(lambda: print("Cut"))

        copy_action = edit_menu.addAction("&Copy")
        copy_action.setShortcut(QKeySequence.Copy)
        copy_action.triggered.connect(lambda: print("Copy"))

        paste_action = edit_menu.addAction("&Paste")
        paste_action.setShortcut(QKeySequence.Paste)
        paste_action.triggered.connect(lambda: print("Paste"))

        select_all_action = edit_menu.addAction("Select &All")
        select_all_action.setShortcut(QKeySequence.SelectAll)
        select_all_action.triggered.connect(lambda: print("Select all"))

        # View menu
        view_menu = menubar.addMenu("&View")

        zoom_in_action = view_menu.addAction("Zoom &In")
        zoom_in_action.setShortcut(QKeySequence.ZoomIn)
        zoom_in_action.triggered.connect(lambda: print("Zoom in"))

        zoom_out_action = view_menu.addAction("Zoom &Out")
        zoom_out_action.setShortcut(QKeySequence.ZoomOut)
        zoom_out_action.triggered.connect(lambda: print("Zoom out"))

        fit_action = view_menu.addAction("&Fit in Window")
        fit_action.setShortcut(QKeySequence("Ctrl+0"))
        fit_action.triggered.connect(lambda: print("Fit in window"))


def main():
    app = QApplication([])
    window = MainWindow()
    window.resize(1200, 900)
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
