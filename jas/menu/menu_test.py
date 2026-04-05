from absl.testing import absltest

from jas_app import MainWindow
from PySide6.QtWidgets import QApplication


class MenubarTest(absltest.TestCase):
    """Test the menubar structure in MainWindow."""

    @classmethod
    def setUpClass(cls):
        if not QApplication.instance():
            cls.app = QApplication([])
        else:
            cls.app = QApplication.instance()

    def setUp(self):
        self.window = MainWindow()

    def test_menubar_exists(self):
        menubar = self.window.menuBar()
        self.assertIsNotNone(menubar)

    def test_menubar_has_three_menus(self):
        menubar = self.window.menuBar()
        menu_actions = menubar.actions()
        self.assertEqual(len(menu_actions), 3)

    def test_menu_titles(self):
        menubar = self.window.menuBar()
        menu_actions = menubar.actions()
        menu_texts = [action.text() for action in menu_actions]
        self.assertEqual(menu_texts, ["&File", "&Edit", "&View"])

    def test_file_menu_exists(self):
        menubar = self.window.menuBar()
        file_action = menubar.actions()[0]
        file_menu = file_action.menu()
        self.assertIsNotNone(file_menu)

    def test_edit_menu_exists(self):
        menubar = self.window.menuBar()
        edit_action = menubar.actions()[1]
        edit_menu = edit_action.menu()
        self.assertIsNotNone(edit_menu)

    def test_view_menu_exists(self):
        menubar = self.window.menuBar()
        view_action = menubar.actions()[2]
        view_menu = view_action.menu()
        self.assertIsNotNone(view_menu)


if __name__ == "__main__":
    absltest.main()
