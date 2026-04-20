from absl.testing import absltest

from geometry.element import (
    Color, RgbColor, HsbColor, CmykColor,
    Fill, Stroke, LineCap, LineJoin, Transform,
    MoveTo, LineTo, CurveTo, SmoothCurveTo, QuadTo, SmoothQuadTo, ArcTo, ClosePath,
    Line, Rect, Circle, Ellipse, Polyline, Polygon, Path, Text, TextPath, Group, Layer,
    path_point_at_offset, path_closest_offset, path_distance_to_point,
    with_fill, with_stroke,
)


class ElementTest(absltest.TestCase):
    """Test SVG-conforming immutable document elements."""

    def test_color_defaults(self):
        c = RgbColor(1.0, 0.0, 0.0)
        self.assertEqual(c.a, 1.0)

    def test_color_immutable(self):
        c = RgbColor(1.0, 0.0, 0.0)
        with self.assertRaises(AttributeError):
            c.r = 0.5

    def test_stroke_defaults(self):
        s = Stroke(RgbColor(0, 0, 0))
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
                   fill=Fill(RgbColor(0, 1, 0)),
                   stroke=Stroke(RgbColor(0, 0, 0), width=3.0))
        self.assertEqual(c.fill.color.g, 1.0)
        self.assertEqual(c.stroke.width, 3.0)

    def test_ellipse_bounds(self):
        e = Ellipse(cx=50, cy=50, rx=25, ry=15)
        self.assertEqual(e.bounds(), (25, 35, 50, 30))

    def test_ellipse_with_fill_and_stroke(self):
        e = Ellipse(cx=50, cy=50, rx=25, ry=15,
                    fill=Fill(RgbColor(0, 0, 1)),
                    stroke=Stroke(RgbColor(1, 1, 1), linecap=LineCap.SQUARE))
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
        bx, by, bw, bh = p.bounds()
        self.assertAlmostEqual(bx, 0)
        self.assertAlmostEqual(by, 0)
        self.assertAlmostEqual(bw, 20)
        self.assertAlmostEqual(bh, 7.5)  # true Bezier extremum, not control point

    def test_path_smooth_curve_to(self):
        p = Path(d=(MoveTo(0, 0), CurveTo(1, 2, 3, 4, 5, 6), SmoothCurveTo(8, 9, 10, 12)))
        self.assertEqual(p.bounds(), (0, 0, 10, 12))

    def test_path_quad_to(self):
        p = Path(d=(MoveTo(0, 0), QuadTo(5, 10, 10, 0)))
        bx, by, bw, bh = p.bounds()
        self.assertAlmostEqual(bx, 0)
        self.assertAlmostEqual(by, 0)
        self.assertAlmostEqual(bw, 10)
        self.assertAlmostEqual(bh, 5.0)  # true Bezier extremum, not control point

    def test_path_smooth_quad_to(self):
        p = Path(d=(MoveTo(0, 0), QuadTo(5, 10, 10, 0), SmoothQuadTo(20, 5)))
        bx, by, bw, bh = p.bounds()
        self.assertAlmostEqual(bx, 0)
        self.assertAlmostEqual(by, 0)
        self.assertAlmostEqual(bw, 20)
        self.assertAlmostEqual(bh, 5.0)  # tight quadratic bounds

    def test_path_arc_to(self):
        p = Path(d=(MoveTo(0, 0), ArcTo(rx=25, ry=25, x_rotation=0, large_arc=True, sweep=False, x=50, y=0)))
        self.assertEqual(p.bounds(), (0, 0, 50, 0))

    def test_path_empty(self):
        p = Path(d=())
        self.assertEqual(p.bounds(), (0, 0, 0, 0))

    def test_path_with_fill_and_stroke(self):
        fill = Fill(RgbColor(1, 0, 0))
        stroke = Stroke(RgbColor(0, 0, 0), width=2.0, linecap=LineCap.ROUND)
        p = Path(d=(MoveTo(0, 0), LineTo(10, 10), ClosePath()), fill=fill, stroke=stroke)
        self.assertEqual(p.fill.color.r, 1.0)
        self.assertEqual(p.stroke.width, 2.0)
        self.assertEqual(p.stroke.linecap, LineCap.ROUND)

    def test_text_bounds(self):
        t = Text(x=10, y=30, content="Hello")
        x, y, w, h = t.bounds()
        self.assertEqual(x, 10)
        self.assertEqual(y, 30)  # y is treated as the top edge
        self.assertGreater(w, 0)
        self.assertEqual(h, 16)

    def test_text_bounds_multiline(self):
        t = Text(x=0, y=0, content="ab\nc")
        _, _, _, h = t.bounds()
        self.assertEqual(h, 32)

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


class ColorConversionTest(absltest.TestCase):
    """Tests for color space conversions."""

    # -- Factory methods --

    def test_color_rgb_factory(self):
        c = Color.rgb(1.0, 0.0, 0.0)
        self.assertIsInstance(c, RgbColor)
        self.assertEqual(c.r, 1.0)

    def test_color_hsb_factory(self):
        c = Color.hsb(120.0, 1.0, 1.0)
        self.assertIsInstance(c, HsbColor)
        self.assertEqual(c.h, 120.0)

    def test_color_cmyk_factory(self):
        c = Color.cmyk(1.0, 0.0, 0.0, 0.0)
        self.assertIsInstance(c, CmykColor)
        self.assertEqual(c.c, 1.0)

    # -- Constants --

    def test_color_black(self):
        self.assertEqual(Color.BLACK, RgbColor(0.0, 0.0, 0.0))

    def test_color_white(self):
        self.assertEqual(Color.WHITE, RgbColor(1.0, 1.0, 1.0))

    # -- Alpha property --

    def test_alpha_rgb(self):
        c = RgbColor(1.0, 0.0, 0.0, 0.5)
        self.assertEqual(c.alpha, 0.5)

    def test_alpha_hsb(self):
        c = HsbColor(0.0, 0.0, 0.0, 0.3)
        self.assertEqual(c.alpha, 0.3)

    def test_alpha_cmyk(self):
        c = CmykColor(0.0, 0.0, 0.0, 0.0, 0.7)
        self.assertEqual(c.alpha, 0.7)

    # -- RGB identity --

    def test_rgb_to_rgba(self):
        c = RgbColor(0.2, 0.4, 0.6, 0.8)
        self.assertEqual(c.to_rgba(), (0.2, 0.4, 0.6, 0.8))

    # -- RGB -> HSB -> RGB round-trip --

    def test_rgb_red_to_hsba(self):
        h, s, b, a = RgbColor(1.0, 0.0, 0.0).to_hsba()
        self.assertAlmostEqual(h, 0.0)
        self.assertAlmostEqual(s, 1.0)
        self.assertAlmostEqual(b, 1.0)
        self.assertAlmostEqual(a, 1.0)

    def test_rgb_green_to_hsba(self):
        h, s, b, a = RgbColor(0.0, 1.0, 0.0).to_hsba()
        self.assertAlmostEqual(h, 120.0)
        self.assertAlmostEqual(s, 1.0)
        self.assertAlmostEqual(b, 1.0)

    def test_rgb_blue_to_hsba(self):
        h, s, b, a = RgbColor(0.0, 0.0, 1.0).to_hsba()
        self.assertAlmostEqual(h, 240.0)
        self.assertAlmostEqual(s, 1.0)
        self.assertAlmostEqual(b, 1.0)

    def test_rgb_white_to_hsba(self):
        h, s, b, a = RgbColor(1.0, 1.0, 1.0).to_hsba()
        self.assertAlmostEqual(s, 0.0)
        self.assertAlmostEqual(b, 1.0)

    def test_rgb_black_to_hsba(self):
        h, s, b, a = RgbColor(0.0, 0.0, 0.0).to_hsba()
        self.assertAlmostEqual(s, 0.0)
        self.assertAlmostEqual(b, 0.0)

    # -- HSB -> RGB --

    def test_hsb_red_to_rgba(self):
        r, g, b, a = HsbColor(0.0, 1.0, 1.0).to_rgba()
        self.assertAlmostEqual(r, 1.0)
        self.assertAlmostEqual(g, 0.0)
        self.assertAlmostEqual(b, 0.0)

    def test_hsb_green_to_rgba(self):
        r, g, b, a = HsbColor(120.0, 1.0, 1.0).to_rgba()
        self.assertAlmostEqual(r, 0.0)
        self.assertAlmostEqual(g, 1.0)
        self.assertAlmostEqual(b, 0.0)

    def test_hsb_blue_to_rgba(self):
        r, g, b, a = HsbColor(240.0, 1.0, 1.0).to_rgba()
        self.assertAlmostEqual(r, 0.0)
        self.assertAlmostEqual(g, 0.0)
        self.assertAlmostEqual(b, 1.0)

    def test_hsb_gray_to_rgba(self):
        """Saturation 0 should produce gray."""
        r, g, b, a = HsbColor(0.0, 0.0, 0.5).to_rgba()
        self.assertAlmostEqual(r, 0.5)
        self.assertAlmostEqual(g, 0.5)
        self.assertAlmostEqual(b, 0.5)

    def test_hsb_yellow_to_rgba(self):
        r, g, b, a = HsbColor(60.0, 1.0, 1.0).to_rgba()
        self.assertAlmostEqual(r, 1.0)
        self.assertAlmostEqual(g, 1.0)
        self.assertAlmostEqual(b, 0.0)

    def test_hsb_cyan_to_rgba(self):
        r, g, b, a = HsbColor(180.0, 1.0, 1.0).to_rgba()
        self.assertAlmostEqual(r, 0.0)
        self.assertAlmostEqual(g, 1.0)
        self.assertAlmostEqual(b, 1.0)

    def test_hsb_magenta_to_rgba(self):
        r, g, b, a = HsbColor(300.0, 1.0, 1.0).to_rgba()
        self.assertAlmostEqual(r, 1.0)
        self.assertAlmostEqual(g, 0.0)
        self.assertAlmostEqual(b, 1.0)

    # -- HSB round-trip through RGB --

    def test_hsb_roundtrip(self):
        original = HsbColor(210.0, 0.7, 0.8, 0.9)
        r, g, b, a = original.to_rgba()
        h2, s2, b2, a2 = RgbColor(r, g, b, a).to_hsba()
        self.assertAlmostEqual(h2, 210.0, places=5)
        self.assertAlmostEqual(s2, 0.7, places=5)
        self.assertAlmostEqual(b2, 0.8, places=5)
        self.assertAlmostEqual(a2, 0.9, places=5)

    # -- RGB -> CMYK --

    def test_rgb_to_cmyka_red(self):
        c, m, y, k, a = RgbColor(1.0, 0.0, 0.0).to_cmyka()
        self.assertAlmostEqual(c, 0.0)
        self.assertAlmostEqual(m, 1.0)
        self.assertAlmostEqual(y, 1.0)
        self.assertAlmostEqual(k, 0.0)

    def test_rgb_to_cmyka_black(self):
        c, m, y, k, a = RgbColor(0.0, 0.0, 0.0).to_cmyka()
        self.assertAlmostEqual(k, 1.0)
        self.assertAlmostEqual(c, 0.0)
        self.assertAlmostEqual(m, 0.0)
        self.assertAlmostEqual(y, 0.0)

    def test_rgb_to_cmyka_white(self):
        c, m, y, k, a = RgbColor(1.0, 1.0, 1.0).to_cmyka()
        self.assertAlmostEqual(c, 0.0)
        self.assertAlmostEqual(m, 0.0)
        self.assertAlmostEqual(y, 0.0)
        self.assertAlmostEqual(k, 0.0)

    # -- CMYK -> RGB --

    def test_cmyk_to_rgba_cyan(self):
        r, g, b, a = CmykColor(1.0, 0.0, 0.0, 0.0).to_rgba()
        self.assertAlmostEqual(r, 0.0)
        self.assertAlmostEqual(g, 1.0)
        self.assertAlmostEqual(b, 1.0)

    def test_cmyk_to_rgba_black(self):
        r, g, b, a = CmykColor(0.0, 0.0, 0.0, 1.0).to_rgba()
        self.assertAlmostEqual(r, 0.0)
        self.assertAlmostEqual(g, 0.0)
        self.assertAlmostEqual(b, 0.0)

    def test_cmyk_to_rgba_white(self):
        r, g, b, a = CmykColor(0.0, 0.0, 0.0, 0.0).to_rgba()
        self.assertAlmostEqual(r, 1.0)
        self.assertAlmostEqual(g, 1.0)
        self.assertAlmostEqual(b, 1.0)

    # -- CMYK round-trip through RGB --

    def test_cmyk_roundtrip_via_rgb(self):
        """CMYK -> RGB -> CMYK -> RGB should produce the same RGB values."""
        original = CmykColor(0.3, 0.5, 0.7, 0.1, 0.8)
        r1, g1, b1, a1 = original.to_rgba()
        c2, m2, y2, k2, a2 = RgbColor(r1, g1, b1, a1).to_cmyka()
        r2, g2, b2, a3 = CmykColor(c2, m2, y2, k2, a2).to_rgba()
        self.assertAlmostEqual(r1, r2, places=10)
        self.assertAlmostEqual(g1, g2, places=10)
        self.assertAlmostEqual(b1, b2, places=10)
        self.assertAlmostEqual(a1, a3, places=10)

    # -- HSB identity --

    def test_hsb_to_hsba(self):
        c = HsbColor(90.0, 0.5, 0.8, 0.3)
        self.assertEqual(c.to_hsba(), (90.0, 0.5, 0.8, 0.3))

    # -- CMYK identity --

    def test_cmyk_to_cmyka(self):
        c = CmykColor(0.1, 0.2, 0.3, 0.4, 0.5)
        self.assertEqual(c.to_cmyka(), (0.1, 0.2, 0.3, 0.4, 0.5))

    # -- Cross-space conversions (HSB <-> CMYK via RGB) --

    def test_hsb_to_cmyka(self):
        c = HsbColor(0.0, 1.0, 1.0)  # red
        cm, m, y, k, a = c.to_cmyka()
        self.assertAlmostEqual(cm, 0.0)
        self.assertAlmostEqual(m, 1.0)
        self.assertAlmostEqual(y, 1.0)
        self.assertAlmostEqual(k, 0.0)

    def test_cmyk_to_hsba(self):
        c = CmykColor(1.0, 0.0, 0.0, 0.0)  # cyan
        h, s, b, a = c.to_hsba()
        self.assertAlmostEqual(h, 180.0)
        self.assertAlmostEqual(s, 1.0)
        self.assertAlmostEqual(b, 1.0)

    # -- Color is base class --

    def test_rgb_is_color(self):
        self.assertIsInstance(RgbColor(0, 0, 0), Color)

    def test_hsb_is_color(self):
        self.assertIsInstance(HsbColor(0, 0, 0), Color)

    def test_cmyk_is_color(self):
        self.assertIsInstance(CmykColor(0, 0, 0, 0), Color)

    # -- Immutability --

    def test_hsb_immutable(self):
        c = HsbColor(0.0, 0.0, 0.0)
        with self.assertRaises(AttributeError):
            c.h = 1.0

    def test_cmyk_immutable(self):
        c = CmykColor(0.0, 0.0, 0.0, 0.0)
        with self.assertRaises(AttributeError):
            c.c = 1.0


class PathOffsetTest(absltest.TestCase):
    """Tests for text-on-path offset calculation functions."""

    def _straight_path(self):
        """A straight horizontal path from (0,0) to (100,0)."""
        return (MoveTo(0, 0), LineTo(100, 0))

    def test_point_at_offset_start(self):
        x, y = path_point_at_offset(self._straight_path(), 0.0)
        self.assertAlmostEqual(x, 0.0)
        self.assertAlmostEqual(y, 0.0)

    def test_point_at_offset_end(self):
        x, y = path_point_at_offset(self._straight_path(), 1.0)
        self.assertAlmostEqual(x, 100.0)
        self.assertAlmostEqual(y, 0.0)

    def test_point_at_offset_midpoint(self):
        x, y = path_point_at_offset(self._straight_path(), 0.5)
        self.assertAlmostEqual(x, 50.0)
        self.assertAlmostEqual(y, 0.0)

    def test_point_at_offset_clamped_below(self):
        x, y = path_point_at_offset(self._straight_path(), -1.0)
        self.assertAlmostEqual(x, 0.0)
        self.assertAlmostEqual(y, 0.0)

    def test_point_at_offset_clamped_above(self):
        x, y = path_point_at_offset(self._straight_path(), 2.0)
        self.assertAlmostEqual(x, 100.0)
        self.assertAlmostEqual(y, 0.0)

    def test_point_at_offset_multi_segment(self):
        """L-shaped path: (0,0)->(100,0)->(100,100), midpoint at corner."""
        d = (MoveTo(0, 0), LineTo(100, 0), LineTo(100, 100))
        x, y = path_point_at_offset(d, 0.5)
        self.assertAlmostEqual(x, 100.0, places=1)
        self.assertAlmostEqual(y, 0.0, places=1)

    def test_closest_offset_on_line(self):
        """Point directly on the path should return the correct offset."""
        offset = path_closest_offset(self._straight_path(), 50.0, 0.0)
        self.assertAlmostEqual(offset, 0.5, places=2)

    def test_closest_offset_start(self):
        offset = path_closest_offset(self._straight_path(), -10.0, 0.0)
        self.assertAlmostEqual(offset, 0.0, places=2)

    def test_closest_offset_end(self):
        offset = path_closest_offset(self._straight_path(), 200.0, 0.0)
        self.assertAlmostEqual(offset, 1.0, places=2)

    def test_closest_offset_perpendicular(self):
        """Point perpendicular to midpoint projects to offset 0.5."""
        offset = path_closest_offset(self._straight_path(), 50.0, 30.0)
        self.assertAlmostEqual(offset, 0.5, places=2)

    def test_distance_to_point_on_path(self):
        dist = path_distance_to_point(self._straight_path(), 50.0, 0.0)
        self.assertAlmostEqual(dist, 0.0, places=5)

    def test_distance_to_point_perpendicular(self):
        dist = path_distance_to_point(self._straight_path(), 50.0, 30.0)
        self.assertAlmostEqual(dist, 30.0, places=5)

    def test_distance_to_point_beyond_end(self):
        """Distance to a point beyond the endpoint."""
        dist = path_distance_to_point(self._straight_path(), 100.0, 10.0)
        self.assertAlmostEqual(dist, 10.0, places=5)


class PenToolPathTest(absltest.TestCase):
    """Tests for pen tool path construction logic.

    These test the path command generation without requiring a GUI context.
    """

    def test_straight_line_two_points(self):
        """Two points with no handle drag produces CurveTo with control points at anchors."""
        from tools.pen_tool import PenPoint
        p0 = PenPoint(0, 0)
        p1 = PenPoint(100, 0)
        cmds = [MoveTo(p0.x, p0.y)]
        cmds.append(CurveTo(p0.hx_out, p0.hy_out, p1.hx_in, p1.hy_in, p1.x, p1.y))
        self.assertEqual(len(cmds), 2)
        self.assertIsInstance(cmds[0], MoveTo)
        self.assertIsInstance(cmds[1], CurveTo)
        self.assertEqual((cmds[1].x, cmds[1].y), (100, 0))

    def test_handle_drag_creates_smooth_curve(self):
        """Dragging a handle sets symmetric handles on the point."""
        from tools.pen_tool import PenPoint
        p = PenPoint(50, 50)
        # Simulate drag to (70, 50) — sets hx_out=70, hy_out=50, hx_in=30, hy_in=50
        p.hx_out = 70
        p.hy_out = 50
        p.hx_in = 2 * p.x - 70
        p.hy_in = 2 * p.y - 50
        self.assertEqual(p.hx_in, 30)
        self.assertEqual(p.hy_in, 50)

    def test_closed_path_has_close_command(self):
        """A closed pen path ends with CurveTo back to start and ClosePath."""
        from tools.pen_tool import PenPoint
        pts = [PenPoint(0, 0), PenPoint(100, 0), PenPoint(50, 50)]
        cmds = [MoveTo(pts[0].x, pts[0].y)]
        for i in range(1, len(pts)):
            prev, curr = pts[i - 1], pts[i]
            cmds.append(CurveTo(prev.hx_out, prev.hy_out,
                                curr.hx_in, curr.hy_in, curr.x, curr.y))
        last = pts[-1]
        cmds.append(CurveTo(last.hx_out, last.hy_out,
                            pts[0].hx_in, pts[0].hy_in, pts[0].x, pts[0].y))
        cmds.append(ClosePath())
        self.assertIsInstance(cmds[-1], ClosePath)
        self.assertEqual(len(cmds), 5)  # MoveTo + 2 CurveTo + CurveTo(close) + ClosePath

    def test_pen_point_default_handles_at_anchor(self):
        """New PenPoint has all handles at the anchor position."""
        from tools.pen_tool import PenPoint
        p = PenPoint(42, 99)
        self.assertEqual((p.hx_in, p.hy_in), (42, 99))
        self.assertEqual((p.hx_out, p.hy_out), (42, 99))
        self.assertFalse(p.smooth)


class WithFillStrokeTest(absltest.TestCase):
    """Tests for with_fill and with_stroke helper functions."""

    def test_with_fill_sets_fill_on_rect(self):
        from geometry.element import with_fill
        r = Rect(x=10, y=20, width=100, height=50)
        red_fill = Fill(RgbColor(1, 0, 0))
        r2 = with_fill(r, red_fill)
        self.assertEqual(r2.fill, red_fill)
        # Original unchanged
        self.assertIsNone(r.fill)

    def test_with_fill_on_line_is_noop(self):
        from geometry.element import with_fill
        line = Line(x1=0, y1=0, x2=100, y2=100,
                    stroke=Stroke(RgbColor(0, 0, 0)))
        line2 = with_fill(line, Fill(RgbColor(1, 0, 0)))
        self.assertEqual(line2, line)

    def test_with_stroke_sets_stroke(self):
        from geometry.element import with_stroke
        p = Path(d=(MoveTo(0, 0), LineTo(10, 10)))
        blue_stroke = Stroke(RgbColor(0, 0, 1), width=3.0)
        p2 = with_stroke(p, blue_stroke)
        self.assertEqual(p2.stroke, blue_stroke)
        self.assertIsNone(p.stroke)

    def test_with_fill_on_group_is_noop(self):
        from geometry.element import with_fill
        g = Group(children=())
        g2 = with_fill(g, Fill(RgbColor(1, 0, 0)))
        self.assertEqual(g2, g)


class ColorHexTest(absltest.TestCase):
    """Tests for Color.to_hex and Color.from_hex."""

    def test_color_to_hex_black(self):
        self.assertEqual(RgbColor(0, 0, 0).to_hex(), "000000")

    def test_color_to_hex_red(self):
        self.assertEqual(RgbColor(1, 0, 0).to_hex(), "ff0000")

    def test_color_from_hex_valid(self):
        c = Color.from_hex("ff0000")
        self.assertIsNotNone(c)
        self.assertIsInstance(c, RgbColor)
        r, g, b, a = c.to_rgba()
        self.assertEqual(r, 1.0)
        self.assertEqual(g, 0.0)
        self.assertEqual(b, 0.0)

    def test_color_from_hex_invalid(self):
        self.assertIsNone(Color.from_hex("xyz"))
        self.assertIsNone(Color.from_hex(""))
        self.assertIsNone(Color.from_hex("gg0000"))

    def test_color_hex_roundtrip(self):
        c = RgbColor(0.5, 0.25, 0.75)
        hex_str = c.to_hex()
        c2 = Color.from_hex(hex_str)
        self.assertIsNotNone(c2)
        r1, g1, b1, _ = c.to_rgba()
        r2, g2, b2, _ = c2.to_rgba()
        self.assertAlmostEqual(r1, r2, places=2)
        self.assertAlmostEqual(g1, g2, places=2)
        self.assertAlmostEqual(b1, b2, places=2)

    def test_color_from_hex_with_hash(self):
        c = Color.from_hex("#00ff00")
        self.assertIsNotNone(c)
        r, g, b, a = c.to_rgba()
        self.assertEqual(r, 0.0)
        self.assertEqual(g, 1.0)
        self.assertEqual(b, 0.0)


class GeometricBoundsTest(absltest.TestCase):
    """geometric_bounds skips stroke inflation — used by Align when
    Use Preview Bounds is off, the default per ALIGN.md."""

    def test_line_ignores_stroke_inflation(self):
        ln = Line(x1=0, y1=0, x2=50, y2=50,
                  stroke=Stroke(color=RgbColor(0, 0, 0), width=4.0))
        self.assertEqual(ln.geometric_bounds(), (0, 0, 50, 50))

    def test_rect_matches_raw_dimensions(self):
        r = Rect(x=10, y=20, width=30, height=40)
        self.assertEqual(r.geometric_bounds(), (10, 20, 30, 40))

    def test_circle(self):
        c = Circle(cx=50, cy=50, r=20)
        self.assertEqual(c.geometric_bounds(), (30, 30, 40, 40))

    def test_ellipse(self):
        e = Ellipse(cx=50, cy=50, rx=30, ry=15)
        self.assertEqual(e.geometric_bounds(), (20, 35, 60, 30))

    def test_group_unions_children_without_inflation(self):
        g = Group(children=(
            Rect(x=0, y=0, width=10, height=10),
            Rect(x=20, y=20, width=10, height=10),
        ))
        self.assertEqual(g.geometric_bounds(), (0, 0, 30, 30))

    def test_matches_bounds_for_unstroked_shapes(self):
        c = Circle(cx=50, cy=50, r=20)
        self.assertEqual(c.geometric_bounds(), c.bounds())

    def test_narrower_than_preview_for_stroked_line(self):
        ln = Line(x1=0, y1=0, x2=50, y2=50,
                  stroke=Stroke(color=RgbColor(0, 0, 0), width=4.0))
        _, _, gw, gh = ln.geometric_bounds()
        _, _, pw, ph = ln.bounds()
        self.assertGreater(pw, gw)
        self.assertGreater(ph, gh)


if __name__ == "__main__":
    absltest.main()
