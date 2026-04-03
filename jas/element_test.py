from absl.testing import absltest

from element import (
    Color, Fill, Stroke, LineCap, LineJoin, Transform,
    MoveTo, LineTo, CurveTo, SmoothCurveTo, QuadTo, SmoothQuadTo, ArcTo, ClosePath,
    Line, Rect, Circle, Ellipse, Polyline, Polygon, Path, Text, Group, Layer,
)


class ElementTest(absltest.TestCase):
    """Test SVG-conforming immutable document elements."""

    def test_color_defaults(self):
        c = Color(1.0, 0.0, 0.0)
        self.assertEqual(c.a, 1.0)

    def test_color_immutable(self):
        c = Color(1.0, 0.0, 0.0)
        with self.assertRaises(AttributeError):
            c.r = 0.5

    def test_stroke_defaults(self):
        s = Stroke(Color(0, 0, 0))
        self.assertEqual(s.width, 1.0)
        self.assertEqual(s.linecap, LineCap.BUTT)
        self.assertEqual(s.linejoin, LineJoin.MITER)

    def test_transform_identity(self):
        t = Transform()
        self.assertEqual((t.a, t.b, t.c, t.d, t.e, t.f), (1, 0, 0, 1, 0, 0))

    def test_transform_translate(self):
        t = Transform.translate(10, 20)
        self.assertEqual(t.e, 10)
        self.assertEqual(t.f, 20)

    def test_transform_scale(self):
        t = Transform.scale(2, 3)
        self.assertEqual(t.a, 2)
        self.assertEqual(t.d, 3)

    def test_transform_rotate(self):
        t = Transform.rotate(90)
        self.assertAlmostEqual(t.a, 0, places=10)
        self.assertAlmostEqual(t.b, 1, places=10)

    def test_transform_scale_uniform(self):
        t = Transform.scale(3)
        self.assertEqual(t.a, 3)
        self.assertEqual(t.d, 3)

    def test_line_bounds(self):
        ln = Line(x1=0, y1=0, x2=10, y2=20)
        self.assertEqual(ln.bounds(), (0, 0, 10, 20))

    def test_line_reversed(self):
        ln = Line(x1=10, y1=20, x2=0, y2=0)
        self.assertEqual(ln.bounds(), (0, 0, 10, 20))

    def test_line_immutable(self):
        ln = Line(x1=0, y1=0, x2=10, y2=10)
        with self.assertRaises(AttributeError):
            ln.x1 = 5

    def test_rect_bounds(self):
        r = Rect(x=5, y=10, width=100, height=50)
        self.assertEqual(r.bounds(), (5, 10, 100, 50))

    def test_rect_rounded(self):
        r = Rect(x=0, y=0, width=10, height=10, rx=2, ry=2)
        self.assertEqual(r.rx, 2)
        self.assertEqual(r.ry, 2)

    def test_rect_immutable(self):
        r = Rect(x=0, y=0, width=10, height=10)
        with self.assertRaises(AttributeError):
            r.x = 5

    def test_circle_bounds(self):
        c = Circle(cx=50, cy=50, r=25)
        self.assertEqual(c.bounds(), (25, 25, 50, 50))

    def test_circle_with_fill_and_stroke(self):
        c = Circle(cx=50, cy=50, r=25,
                   fill=Fill(Color(0, 1, 0)),
                   stroke=Stroke(Color(0, 0, 0), width=3.0))
        self.assertEqual(c.fill.color.g, 1.0)
        self.assertEqual(c.stroke.width, 3.0)

    def test_ellipse_bounds(self):
        e = Ellipse(cx=50, cy=50, rx=25, ry=15)
        self.assertEqual(e.bounds(), (25, 35, 50, 30))

    def test_ellipse_with_fill_and_stroke(self):
        e = Ellipse(cx=50, cy=50, rx=25, ry=15,
                    fill=Fill(Color(0, 0, 1)),
                    stroke=Stroke(Color(1, 1, 1), linecap=LineCap.SQUARE))
        self.assertEqual(e.fill.color.b, 1.0)
        self.assertEqual(e.stroke.linecap, LineCap.SQUARE)

    def test_polyline_bounds(self):
        pl = Polyline(points=((0, 0), (10, 5), (20, 0)))
        self.assertEqual(pl.bounds(), (0, 0, 20, 5))

    def test_empty_polyline(self):
        pl = Polyline(points=())
        self.assertEqual(pl.bounds(), (0, 0, 0, 0))

    def test_polygon_bounds(self):
        pg = Polygon(points=((0, 0), (10, 0), (5, 10)))
        self.assertEqual(pg.bounds(), (0, 0, 10, 10))

    def test_empty_polygon(self):
        pg = Polygon(points=())
        self.assertEqual(pg.bounds(), (0, 0, 0, 0))

    def test_path_bounds(self):
        p = Path(d=(MoveTo(0, 0), LineTo(10, 20), LineTo(5, 15), ClosePath()))
        self.assertEqual(p.bounds(), (0, 0, 10, 20))

    def test_path_cubic_bezier(self):
        p = Path(d=(MoveTo(0, 0), CurveTo(5, 10, 15, 10, 20, 0)))
        self.assertEqual(p.bounds(), (0, 0, 20, 0))

    def test_path_smooth_curve_to(self):
        p = Path(d=(MoveTo(0, 0), CurveTo(1, 2, 3, 4, 5, 6), SmoothCurveTo(8, 9, 10, 12)))
        self.assertEqual(p.bounds(), (0, 0, 10, 12))

    def test_path_quad_to(self):
        p = Path(d=(MoveTo(0, 0), QuadTo(5, 10, 10, 0)))
        self.assertEqual(p.bounds(), (0, 0, 10, 0))

    def test_path_smooth_quad_to(self):
        p = Path(d=(MoveTo(0, 0), QuadTo(5, 10, 10, 0), SmoothQuadTo(20, 5)))
        self.assertEqual(p.bounds(), (0, 0, 20, 5))

    def test_path_arc_to(self):
        p = Path(d=(MoveTo(0, 0), ArcTo(rx=25, ry=25, x_rotation=0, large_arc=True, sweep=False, x=50, y=0)))
        self.assertEqual(p.bounds(), (0, 0, 50, 0))

    def test_path_empty(self):
        p = Path(d=())
        self.assertEqual(p.bounds(), (0, 0, 0, 0))

    def test_path_with_fill_and_stroke(self):
        fill = Fill(Color(1, 0, 0))
        stroke = Stroke(Color(0, 0, 0), width=2.0, linecap=LineCap.ROUND)
        p = Path(d=(MoveTo(0, 0), LineTo(10, 10), ClosePath()), fill=fill, stroke=stroke)
        self.assertEqual(p.fill.color.r, 1.0)
        self.assertEqual(p.stroke.width, 2.0)
        self.assertEqual(p.stroke.linecap, LineCap.ROUND)

    def test_text_bounds(self):
        t = Text(x=10, y=30, content="Hello")
        x, y, w, h = t.bounds()
        self.assertEqual(x, 10)
        self.assertEqual(y, 14)  # y - font_size
        self.assertGreater(w, 0)
        self.assertEqual(h, 16)

    def test_text_attributes(self):
        t = Text(x=0, y=0, content="Hi", font_family="monospace", font_size=24.0)
        self.assertEqual(t.font_family, "monospace")
        self.assertEqual(t.font_size, 24.0)

    def test_group_bounds(self):
        r = Rect(x=0, y=0, width=10, height=10)
        e = Ellipse(cx=100, cy=100, rx=5, ry=5)
        g = Group(children=(r, e))
        self.assertEqual(g.bounds(), (0, 0, 105, 105))

    def test_group_empty(self):
        g = Group(children=())
        self.assertEqual(g.bounds(), (0, 0, 0, 0))

    def test_nested_group(self):
        inner = Group(children=(Rect(x=10, y=10, width=5, height=5),))
        outer = Group(children=(Rect(x=0, y=0, width=1, height=1), inner))
        self.assertEqual(outer.bounds(), (0, 0, 15, 15))

    def test_group_with_transform(self):
        g = Group(children=(Rect(x=0, y=0, width=10, height=10),),
                  transform=Transform.translate(100, 200))
        self.assertIsNotNone(g.transform)
        self.assertEqual(g.transform.e, 100)

    def test_element_opacity(self):
        r = Rect(x=0, y=0, width=10, height=10, opacity=0.5)
        self.assertEqual(r.opacity, 0.5)

    def test_group_all_element_types(self):
        children = (
            Line(x1=0, y1=0, x2=10, y2=10),
            Rect(x=0, y=0, width=20, height=20),
            Circle(cx=50, cy=50, r=10),
            Ellipse(cx=50, cy=50, rx=10, ry=5),
            Polyline(points=((0, 0), (10, 10))),
            Polygon(points=((0, 0), (10, 0), (5, 10))),
            Path(d=(MoveTo(0, 0), LineTo(10, 10))),
            Text(x=0, y=20, content="test"),
        )
        g = Group(children=children)
        x, y, w, h = g.bounds()
        self.assertEqual(x, 0)
        self.assertEqual(y, 0)
        self.assertGreater(w, 0)
        self.assertGreater(h, 0)

    def test_deeply_nested_groups(self):
        inner = Group(children=(Rect(x=10, y=10, width=5, height=5),))
        mid = Group(children=(Rect(x=0, y=0, width=1, height=1), inner))
        outer = Group(children=(Rect(x=20, y=20, width=3, height=3), mid))
        x, y, w, h = outer.bounds()
        self.assertEqual(x, 0)
        self.assertEqual(y, 0)
        self.assertEqual(w, 23)
        self.assertEqual(h, 23)

    def test_layer_default_name(self):
        layer = Layer(children=(Rect(x=0, y=0, width=10, height=10),))
        self.assertEqual(layer.name, "Layer")

    def test_layer_custom_name(self):
        layer = Layer(children=(Rect(x=0, y=0, width=10, height=10),), name="Background")
        self.assertEqual(layer.name, "Background")

    def test_layer_bounds(self):
        layer = Layer(children=(
            Rect(x=0, y=0, width=10, height=10),
            Circle(cx=50, cy=50, r=5),
        ), name="Shapes")
        self.assertEqual(layer.bounds(), (0, 0, 55, 55))

    def test_layer_empty(self):
        layer = Layer(children=(), name="Empty")
        self.assertEqual(layer.bounds(), (0, 0, 0, 0))

    def test_layer_is_group(self):
        layer = Layer(children=(), name="Test")
        self.assertIsInstance(layer, Group)


if __name__ == "__main__":
    absltest.main()
