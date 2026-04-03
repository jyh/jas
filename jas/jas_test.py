from absl.testing import absltest

from jas_app import CanvasWidget, MainWindow


class CanvasTest(absltest.TestCase):

    def test_canvas_widget_minimum_size(self):
        widget = CanvasWidget()
        self.assertEqual(widget.minimumWidth(), 320)
        self.assertEqual(widget.minimumHeight(), 240)

    def test_canvas_widget_size_hint(self):
        widget = CanvasWidget()
        hint = widget.sizeHint()
        self.assertEqual(hint.width(), 800)
        self.assertEqual(hint.height(), 600)

    def test_main_window_title(self):
        window = MainWindow()
        self.assertEqual(window.windowTitle(), "Jas")

    def test_main_window_has_mdi_area(self):
        window = MainWindow()
        from PySide6.QtWidgets import QMdiArea
        self.assertIsInstance(window.centralWidget(), QMdiArea)

    def test_canvas_is_in_subwindow(self):
        window = MainWindow()
        self.assertIsInstance(window.canvas, CanvasWidget)
        self.assertEqual(window.sub_window.windowTitle(), "Untitled")
        self.assertEqual(window.sub_window.widget(), window.canvas)


if __name__ == "__main__":
    absltest.main()
