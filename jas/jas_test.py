from absl.testing import absltest

from toolbar import Tool
from element import (
    Point, Color, Fill, Stroke, StrokeAlignment,
    AnchorPoint, Path, Rect, Ellipse, Group,
)
from jas_app import MainWindow
from PySide6.QtWidgets import QApplication


class ToolbarTest(absltest.TestCase):

    def test_tool_enum_has_two_values(self):
        tools = list(Tool)
        self.assertEqual(len(tools), 2)
        self.assertIn(Tool.SELECTION, tools)
        self.assertIn(Tool.DIRECT_SELECTION, tools)

    def test_tool_selection_value(self):
        self.assertEqual(Tool.SELECTION.value, 1)

    def test_tool_direct_selection_value(self):
        self.assertEqual(Tool.DIRECT_SELECTION.value, 2)


class MenubarTest(absltest.TestCase):
    """Test the menubar structure in MainWindow."""

    @classmethod
    def setUpClass(cls):
        # Create QApplication once for all tests in this class
        if not QApplication.instance():
            cls.app = QApplication([])
        else:
            cls.app = QApplication.instance()

    def setUp(self):
        # Create a fresh MainWindow for each test
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
        # Verify File menu exists and has a submenu
        file_menu = file_action.menu()
        self.assertIsNotNone(file_menu)

    def test_edit_menu_exists(self):
        menubar = self.window.menuBar()
        edit_action = menubar.actions()[1]
        # Verify Edit menu exists and has a submenu
        edit_menu = edit_action.menu()
        self.assertIsNotNone(edit_menu)

    def test_view_menu_exists(self):
        menubar = self.window.menuBar()
        view_action = menubar.actions()[2]
        # Verify View menu exists and has a submenu
        view_menu = view_action.menu()
        self.assertIsNotNone(view_menu)


class ElementTest(absltest.TestCase):
    """Test immutable document elements."""

    def test_point_creation(self):
        p = Point(3.0, 4.0)
        self.assertEqual(p.x, 3.0)
        self.assertEqual(p.y, 4.0)

    def test_point_immutable(self):
        p = Point(1.0, 2.0)
        with self.assertRaises(AttributeError):
            p.x = 5.0

    def test_color_defaults(self):
        c = Color(1.0, 0.0, 0.0)
        self.assertEqual(c.a, 1.0)

    def test_color_immutable(self):
        c = Color(1.0, 0.0, 0.0)
        with self.assertRaises(AttributeError):
            c.r = 0.5

    def test_path_bounds(self):
        p = Path(anchors=(
            AnchorPoint(Point(0, 0)),
            AnchorPoint(Point(10, 20)),
            AnchorPoint(Point(5, 15)),
        ))
        tl, br = p.bounds()
        self.assertEqual(tl, Point(0, 0))
        self.assertEqual(br, Point(10, 20))

    def test_path_empty_bounds(self):
        p = Path(anchors=())
        tl, br = p.bounds()
        self.assertEqual(tl, Point(0, 0))
        self.assertEqual(br, Point(0, 0))

    def test_path_with_fill_and_stroke(self):
        fill = Fill(Color(1, 0, 0))
        stroke = Stroke(Color(0, 0, 0), width=2.0, alignment=StrokeAlignment.OUTSIDE)
        p = Path(
            anchors=(AnchorPoint(Point(0, 0)), AnchorPoint(Point(10, 10))),
            closed=True,
            fill=fill,
            stroke=stroke,
        )
        self.assertTrue(p.closed)
        self.assertEqual(p.fill.color.r, 1.0)
        self.assertEqual(p.stroke.width, 2.0)
        self.assertEqual(p.stroke.alignment, StrokeAlignment.OUTSIDE)

    def test_rect_bounds(self):
        r = Rect(origin=Point(5, 10), width=100, height=50)
        tl, br = r.bounds()
        self.assertEqual(tl, Point(5, 10))
        self.assertEqual(br, Point(105, 60))

    def test_ellipse_bounds(self):
        e = Ellipse(center=Point(50, 50), rx=25, ry=15)
        tl, br = e.bounds()
        self.assertEqual(tl, Point(25, 35))
        self.assertEqual(br, Point(75, 65))

    def test_group_bounds(self):
        r = Rect(origin=Point(0, 0), width=10, height=10)
        e = Ellipse(center=Point(100, 100), rx=5, ry=5)
        g = Group(children=(r, e))
        tl, br = g.bounds()
        self.assertEqual(tl, Point(0, 0))
        self.assertEqual(br, Point(105, 105))

    def test_group_empty_bounds(self):
        g = Group(children=())
        tl, br = g.bounds()
        self.assertEqual(tl, Point(0, 0))
        self.assertEqual(br, Point(0, 0))

    def test_nested_group(self):
        inner = Group(children=(Rect(origin=Point(10, 10), width=5, height=5),))
        outer = Group(children=(
            Rect(origin=Point(0, 0), width=1, height=1),
            inner,
        ))
        tl, br = outer.bounds()
        self.assertEqual(tl, Point(0, 0))
        self.assertEqual(br, Point(15, 15))

    def test_anchor_point_handles(self):
        a = AnchorPoint(Point(5, 5), handle_in=Point(3, 3), handle_out=Point(7, 7))
        self.assertEqual(a.handle_in, Point(3, 3))
        self.assertEqual(a.handle_out, Point(7, 7))

    def test_anchor_point_no_handles(self):
        a = AnchorPoint(Point(5, 5))
        self.assertIsNone(a.handle_in)
        self.assertIsNone(a.handle_out)


if __name__ == "__main__":
    absltest.main()
