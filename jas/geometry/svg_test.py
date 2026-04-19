from absl.testing import absltest

from document.document import Document
from dataclasses import replace

# Text.bounds() uses QFontMetricsF for accurate widths; it requires
# a QGuiApplication. Instantiate one at import time so the svg tests
# don't depend on another test module having done it first.
try:
    from PySide6.QtWidgets import QApplication
    if QApplication.instance() is None:
        _qapp_for_svg_tests = QApplication([])
except ImportError:
    pass

from geometry.element import (
    ArcTo, Circle, ClosePath, RgbColor, CurveTo, Ellipse, Fill, Group, Layer,
    Line, LineCap, LineJoin, LineTo, MoveTo, Path, Polygon, Polyline,
    QuadTo, Rect, SmoothCurveTo, SmoothQuadTo, Stroke, Text, TextPath,
    Transform,
)
from geometry.svg import document_to_svg, svg_to_document
from geometry.tspan import Tspan


# 1 pt = 96/72 px = 4/3 px
_S = 96.0 / 72.0

def _pt(px: float) -> float:
    """Convert px to pt (matching the import conversion)."""
    return px * 72.0 / 96.0


class SvgTest(absltest.TestCase):

    def test_empty_document(self):
        doc = Document(layers=(Layer(),))
        svg = document_to_svg(doc)
        self.assertIn('<?xml version="1.0"', svg)
        self.assertIn('<svg xmlns=', svg)
        self.assertIn('</svg>', svg)

    def test_line_coordinates_converted(self):
        layer = Layer(children=(
            Line(x1=0, y1=0, x2=72, y2=36,
                 stroke=Stroke(color=RgbColor(0, 0, 0))),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        # 72pt -> 96px, 36pt -> 48px
        self.assertIn('x2="96"', svg)
        self.assertIn('y2="48"', svg)

    def test_rect_with_fill_and_stroke(self):
        layer = Layer(children=(
            Rect(x=0, y=0, width=72, height=72,
                 fill=Fill(color=RgbColor(1, 0, 0)),
                 stroke=Stroke(color=RgbColor(0, 0, 0))),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('<rect', svg)
        self.assertIn('fill="rgb(255,0,0)"', svg)
        self.assertIn('stroke="rgb(0,0,0)"', svg)
        self.assertIn('width="96"', svg)

    def test_rect_rounded(self):
        layer = Layer(children=(
            Rect(x=0, y=0, width=72, height=72, rx=6, ry=6),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('rx="8"', svg)
        self.assertIn('ry="8"', svg)

    def test_circle(self):
        layer = Layer(children=(
            Circle(cx=36, cy=36, r=18, fill=Fill(color=RgbColor(0, 0, 1))),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('cx="48"', svg)
        self.assertIn('r="24"', svg)
        self.assertIn('fill="rgb(0,0,255)"', svg)

    def test_ellipse(self):
        layer = Layer(children=(
            Ellipse(cx=36, cy=36, rx=24, ry=12),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('<ellipse', svg)
        self.assertIn('rx="32"', svg)
        self.assertIn('ry="16"', svg)

    def test_polygon(self):
        layer = Layer(children=(
            Polygon(points=((0, 0), (72, 0), (36, 72)),
                    stroke=Stroke(color=RgbColor(0, 0, 0))),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('<polygon', svg)
        self.assertIn('0,0 96,0 48,96', svg)

    def test_polyline(self):
        layer = Layer(children=(
            Polyline(points=((0, 0), (36, 72)),
                     stroke=Stroke(color=RgbColor(0, 0, 0))),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('<polyline', svg)
        self.assertIn('0,0 48,96', svg)

    def test_path(self):
        layer = Layer(children=(
            Path(d=(MoveTo(0, 0), LineTo(72, 72), ClosePath()),
                 stroke=Stroke(color=RgbColor(0, 0, 0))),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('<path', svg)
        self.assertIn('M0,0', svg)
        self.assertIn('L96,96', svg)
        self.assertIn('Z', svg)

    def test_path_curve_commands(self):
        layer = Layer(children=(
            Path(d=(
                MoveTo(0, 0),
                CurveTo(0, 36, 36, 72, 72, 72),
                SmoothCurveTo(108, 72, 144, 0),
                QuadTo(36, 36, 72, 0),
                SmoothQuadTo(144, 0),
                ArcTo(36, 36, 0, True, False, 72, 72),
            ), stroke=Stroke(color=RgbColor(0, 0, 0))),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('C0,48 48,96 96,96', svg)
        self.assertIn('S144,96 192,0', svg)
        self.assertIn('Q48,48 96,0', svg)
        self.assertIn('T192,0', svg)
        self.assertIn('A48,48 0 1,0 96,96', svg)

    def test_text(self):
        layer = Layer(children=(
            Text(x=10, y=20, content="Hello", font_family="Arial",
                 font_size=12, fill=Fill(color=RgbColor(0, 0, 0))),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('<text', svg)
        self.assertIn('font-family="Arial"', svg)
        self.assertIn('>Hello</text>', svg)

    def test_text_y_round_trip_preserves_top(self):
        # Internally `text.y` is the top of the layout box. Round-tripping
        # through SVG (where `y` is the baseline) must put us back at the
        # same top-of-box position.
        layer = Layer(children=(
            Text(x=10, y=20, content="Hi", font_family="Arial",
                 font_size=16, fill=Fill(color=RgbColor(0, 0, 0))),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        from geometry.svg import svg_to_document
        doc2 = svg_to_document(svg)
        t2 = doc2.layers[0].children[0]
        self.assertAlmostEqual(t2.y, 20.0, places=3)
        self.assertAlmostEqual(t2.x, 10.0, places=3)

    def test_flat_text_has_no_tspan_wrapper(self):
        """A Text with a single no-override tspan round-trips as flat
        SVG — no <tspan> wrapper, no xml:space="preserve"."""
        layer = Layer(children=(Text(x=0, y=0, content="Hello"),))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertNotIn("<tspan", svg)
        self.assertNotIn("xml:space", svg)
        self.assertIn(">Hello</text>", svg)

    def test_multi_tspan_text_emits_tspan_children(self):
        """Two tspans with distinct overrides round-trip as <tspan>
        children + xml:space="preserve" on the parent <text>."""
        t = Text(x=0, y=0, content="Hello world")
        t = replace(t, tspans=(
            Tspan(id=0, content="Hello "),
            Tspan(id=1, content="world", font_weight="bold"),
        ))
        svg = document_to_svg(Document(layers=(Layer(children=(t,)),)))
        self.assertIn('xml:space="preserve"', svg)
        self.assertIn("<tspan>Hello </tspan>", svg)
        self.assertIn('<tspan font-weight="bold">world</tspan>', svg)

    def test_tspan_round_trip_preserves_overrides(self):
        """Round-trip a two-tspan text: content, override attributes,
        and tspan count survive."""
        t = Text(x=0, y=0, content="AB")
        t = replace(t, tspans=(
            Tspan(id=0, content="A"),
            Tspan(id=1, content="B", font_family="Courier",
                  font_weight="bold",
                  text_decoration=("line-through", "underline")),
        ))
        doc = Document(layers=(Layer(children=(t,)),))
        doc2 = svg_to_document(document_to_svg(doc))
        t2 = doc2.layers[0].children[0]
        self.assertEqual(len(t2.tspans), 2)
        self.assertEqual(t2.tspans[0].content, "A")
        self.assertTrue(t2.tspans[0].has_no_overrides())
        self.assertEqual(t2.tspans[1].content, "B")
        self.assertEqual(t2.tspans[1].font_family, "Courier")
        self.assertEqual(t2.tspans[1].font_weight, "bold")
        self.assertEqual(t2.tspans[1].text_decoration,
                         ("line-through", "underline"))

    def test_text_path_tspan_round_trip(self):
        tp = TextPath(d=(MoveTo(0, 0), LineTo(100, 0)), content="foo bar")
        tp = replace(tp, tspans=(
            Tspan(id=0, content="foo "),
            Tspan(id=1, content="bar", font_style="italic"),
        ))
        doc = Document(layers=(Layer(children=(tp,)),))
        svg = document_to_svg(doc)
        self.assertIn("<tspan>foo </tspan>", svg)
        self.assertIn('<tspan font-style="italic">bar</tspan>', svg)
        doc2 = svg_to_document(svg)
        tp2 = doc2.layers[0].children[0]
        self.assertEqual(len(tp2.tspans), 2)
        self.assertEqual(tp2.tspans[1].font_style, "italic")

    def test_text_escaping(self):
        layer = Layer(children=(
            Text(x=0, y=0, content="<b>&amp;</b>"),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('&lt;b&gt;&amp;amp;&lt;/b&gt;', svg)

    def test_no_fill(self):
        layer = Layer(children=(
            Rect(x=0, y=0, width=72, height=72,
                 stroke=Stroke(color=RgbColor(0, 0, 0))),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('fill="none"', svg)

    def test_no_stroke(self):
        layer = Layer(children=(
            Rect(x=0, y=0, width=72, height=72,
                 fill=Fill(color=RgbColor(1, 1, 1))),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('stroke="none"', svg)

    def test_opacity(self):
        layer = Layer(children=(
            Rect(x=0, y=0, width=72, height=72, opacity=0.5),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('opacity="0.5"', svg)

    def test_full_opacity_omitted(self):
        layer = Layer(children=(
            Rect(x=0, y=0, width=72, height=72, opacity=1.0),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertNotIn('opacity=', svg)

    def test_transform(self):
        layer = Layer(children=(
            Rect(x=0, y=0, width=72, height=72,
                 transform=Transform.translate(36, 18)),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        # translate(36pt, 18pt) -> matrix with e=48, f=24
        self.assertIn('transform="matrix(1,0,0,1,48,24)"', svg)

    def test_stroke_linecap_linejoin(self):
        layer = Layer(children=(
            Line(x1=0, y1=0, x2=72, y2=72,
                 stroke=Stroke(color=RgbColor(0, 0, 0),
                               linecap=LineCap.ROUND,
                               linejoin=LineJoin.BEVEL)),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('stroke-linecap="round"', svg)
        self.assertIn('stroke-linejoin="bevel"', svg)

    def test_color_alpha(self):
        layer = Layer(children=(
            Rect(x=0, y=0, width=72, height=72,
                 fill=Fill(color=RgbColor(1, 0, 0, 0.5))),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('rgba(255,0,0,0.5)', svg)

    def test_group(self):
        layer = Layer(children=(
            Group(children=(
                Rect(x=0, y=0, width=72, height=72),
                Circle(cx=36, cy=36, r=18),
            )),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('<g>', svg)  # inner group
        self.assertEqual(svg.count('</g>'), 2)  # group + layer

    def test_layer_name(self):
        layer = Layer(name="Background", children=(
            Rect(x=0, y=0, width=72, height=72),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('inkscape:label="Background"', svg)

    def test_viewbox(self):
        layer = Layer(children=(
            Rect(x=10, y=20, width=72, height=36),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        # bounds: (10,20,72,36) in pt -> (13.3333,26.6667,96,48) in px
        self.assertIn('viewBox="13.3333 26.6667 96 48"', svg)

    def test_multiple_layers(self):
        layer1 = Layer(name="L1", children=(
            Line(x1=0, y1=0, x2=72, y2=72,
                 stroke=Stroke(color=RgbColor(0, 0, 0))),
        ))
        layer2 = Layer(name="L2", children=(
            Circle(cx=36, cy=36, r=18),
        ))
        svg = document_to_svg(Document(layers=(layer1, layer2)))
        self.assertIn('inkscape:label="L1"', svg)
        self.assertIn('inkscape:label="L2"', svg)


class SvgImportTest(absltest.TestCase):

    def _roundtrip(self, doc):
        """Export to SVG, re-import, compare."""
        svg = document_to_svg(doc)
        return svg_to_document(svg)

    def test_roundtrip_empty(self):
        doc = Document(layers=(Layer(),))
        doc2 = self._roundtrip(doc)
        self.assertEqual(len(doc2.layers), 1)

    def test_roundtrip_line(self):
        layer = Layer(children=(
            Line(x1=0, y1=0, x2=72, y2=36,
                 stroke=Stroke(color=RgbColor(0, 0, 0))),
        ))
        doc2 = self._roundtrip(Document(layers=(layer,)))
        elem = doc2.layers[0].children[0]
        self.assertIsInstance(elem, Line)
        self.assertAlmostEqual(elem.x2, 72, places=2)
        self.assertAlmostEqual(elem.y2, 36, places=2)

    def test_roundtrip_rect(self):
        layer = Layer(children=(
            Rect(x=10, y=20, width=72, height=36,
                 fill=Fill(color=RgbColor(1, 0, 0)),
                 stroke=Stroke(color=RgbColor(0, 0, 0))),
        ))
        doc2 = self._roundtrip(Document(layers=(layer,)))
        elem = doc2.layers[0].children[0]
        self.assertIsInstance(elem, Rect)
        self.assertAlmostEqual(elem.width, 72, places=2)
        self.assertAlmostEqual(elem.height, 36, places=2)
        self.assertIsNotNone(elem.fill)
        self.assertAlmostEqual(elem.fill.color.r, 1.0, places=1)

    def test_roundtrip_circle(self):
        layer = Layer(children=(
            Circle(cx=36, cy=36, r=18,
                   fill=Fill(color=RgbColor(0, 0, 1))),
        ))
        doc2 = self._roundtrip(Document(layers=(layer,)))
        elem = doc2.layers[0].children[0]
        self.assertIsInstance(elem, Circle)
        self.assertAlmostEqual(elem.r, 18, places=2)

    def test_roundtrip_ellipse(self):
        layer = Layer(children=(
            Ellipse(cx=36, cy=36, rx=24, ry=12),
        ))
        doc2 = self._roundtrip(Document(layers=(layer,)))
        elem = doc2.layers[0].children[0]
        self.assertIsInstance(elem, Ellipse)
        self.assertAlmostEqual(elem.rx, 24, places=2)
        self.assertAlmostEqual(elem.ry, 12, places=2)

    def test_roundtrip_polygon(self):
        layer = Layer(children=(
            Polygon(points=((0, 0), (72, 0), (36, 72)),
                    stroke=Stroke(color=RgbColor(0, 0, 0))),
        ))
        doc2 = self._roundtrip(Document(layers=(layer,)))
        elem = doc2.layers[0].children[0]
        self.assertIsInstance(elem, Polygon)
        self.assertEqual(len(elem.points), 3)
        self.assertAlmostEqual(elem.points[1][0], 72, places=2)

    def test_roundtrip_path(self):
        layer = Layer(children=(
            Path(d=(MoveTo(0, 0), LineTo(72, 72), ClosePath()),
                 stroke=Stroke(color=RgbColor(0, 0, 0))),
        ))
        doc2 = self._roundtrip(Document(layers=(layer,)))
        elem = doc2.layers[0].children[0]
        self.assertIsInstance(elem, Path)
        self.assertEqual(len(elem.d), 3)
        self.assertIsInstance(elem.d[0], MoveTo)
        self.assertIsInstance(elem.d[1], LineTo)
        self.assertAlmostEqual(elem.d[1].x, 72, places=2)

    def test_roundtrip_path_curves(self):
        layer = Layer(children=(
            Path(d=(
                MoveTo(0, 0),
                CurveTo(0, 36, 36, 72, 72, 72),
                SmoothCurveTo(108, 72, 144, 0),
                QuadTo(36, 36, 72, 0),
                SmoothQuadTo(144, 0),
                ArcTo(36, 36, 0, True, False, 72, 72),
            ), stroke=Stroke(color=RgbColor(0, 0, 0))),
        ))
        doc2 = self._roundtrip(Document(layers=(layer,)))
        elem = doc2.layers[0].children[0]
        self.assertIsInstance(elem, Path)
        self.assertEqual(len(elem.d), 6)
        self.assertIsInstance(elem.d[1], CurveTo)
        self.assertIsInstance(elem.d[4], SmoothQuadTo)
        self.assertIsInstance(elem.d[5], ArcTo)
        self.assertTrue(elem.d[5].large_arc)
        self.assertFalse(elem.d[5].sweep)

    def test_roundtrip_text(self):
        layer = Layer(children=(
            Text(x=10, y=20, content="Hello", font_family="Arial",
                 font_size=12, fill=Fill(color=RgbColor(0, 0, 0))),
        ))
        doc2 = self._roundtrip(Document(layers=(layer,)))
        elem = doc2.layers[0].children[0]
        self.assertIsInstance(elem, Text)
        self.assertEqual(elem.content, "Hello")
        self.assertEqual(elem.font_family, "Arial")

    def test_roundtrip_opacity(self):
        layer = Layer(children=(
            Rect(x=0, y=0, width=72, height=72, opacity=0.5),
        ))
        doc2 = self._roundtrip(Document(layers=(layer,)))
        elem = doc2.layers[0].children[0]
        self.assertAlmostEqual(elem.opacity, 0.5, places=2)

    def test_roundtrip_transform(self):
        layer = Layer(children=(
            Rect(x=0, y=0, width=72, height=72,
                 transform=Transform.translate(36, 18)),
        ))
        doc2 = self._roundtrip(Document(layers=(layer,)))
        elem = doc2.layers[0].children[0]
        self.assertIsNotNone(elem.transform)
        self.assertAlmostEqual(elem.transform.e, 36, places=2)
        self.assertAlmostEqual(elem.transform.f, 18, places=2)

    def test_roundtrip_layer_name(self):
        doc = Document(layers=(
            Layer(name="Background", children=(
                Rect(x=0, y=0, width=72, height=72),
            )),
        ))
        doc2 = self._roundtrip(doc)
        self.assertEqual(doc2.layers[0].name, "Background")

    def test_roundtrip_multiple_layers(self):
        doc = Document(layers=(
            Layer(name="L1", children=(
                Line(x1=0, y1=0, x2=72, y2=72,
                     stroke=Stroke(color=RgbColor(0, 0, 0))),
            )),
            Layer(name="L2", children=(
                Circle(cx=36, cy=36, r=18),
            )),
        ))
        doc2 = self._roundtrip(doc)
        self.assertEqual(len(doc2.layers), 2)
        self.assertEqual(doc2.layers[0].name, "L1")
        self.assertEqual(doc2.layers[1].name, "L2")

    def test_roundtrip_color_alpha(self):
        layer = Layer(children=(
            Rect(x=0, y=0, width=72, height=72,
                 fill=Fill(color=RgbColor(1, 0, 0, 0.5))),
        ))
        doc2 = self._roundtrip(Document(layers=(layer,)))
        elem = doc2.layers[0].children[0]
        # After roundtrip + normalization, alpha moves to fill.opacity
        self.assertAlmostEqual(elem.fill.color.a, 1.0, places=2)
        self.assertAlmostEqual(elem.fill.opacity, 0.5, places=1)

    def test_roundtrip_group(self):
        layer = Layer(children=(
            Group(children=(
                Rect(x=0, y=0, width=72, height=72),
                Circle(cx=36, cy=36, r=18),
            )),
        ))
        doc2 = self._roundtrip(Document(layers=(layer,)))
        elem = doc2.layers[0].children[0]
        self.assertIsInstance(elem, Group)
        self.assertEqual(len(elem.children), 2)

    def test_import_relative_path_commands(self):
        """Relative (lowercase) path commands are converted to absolute."""
        # m 10,20 l 30,0 l 0,40 z => absolute M 10,20 L 40,20 L 40,60 Z
        svg = ('<svg xmlns="http://www.w3.org/2000/svg">'
               '<g><path d="m 10,20 l 30,0 l 0,40 z" '
               'stroke="rgb(0,0,0)" stroke-width="1"/></g></svg>')
        doc = svg_to_document(svg)
        elem = doc.layers[0].children[0]
        self.assertIsInstance(elem, Path)
        self.assertEqual(len(elem.d), 4)
        self.assertIsInstance(elem.d[0], MoveTo)
        self.assertAlmostEqual(elem.d[0].x, _pt(10), places=2)
        self.assertAlmostEqual(elem.d[0].y, _pt(20), places=2)
        self.assertIsInstance(elem.d[1], LineTo)
        self.assertAlmostEqual(elem.d[1].x, _pt(40), places=2)
        self.assertAlmostEqual(elem.d[1].y, _pt(20), places=2)
        self.assertIsInstance(elem.d[2], LineTo)
        self.assertAlmostEqual(elem.d[2].x, _pt(40), places=2)
        self.assertAlmostEqual(elem.d[2].y, _pt(60), places=2)
        self.assertIsInstance(elem.d[3], ClosePath)

    def test_import_relative_curve(self):
        """Relative cubic Bezier curve (c command)."""
        svg = ('<svg xmlns="http://www.w3.org/2000/svg">'
               '<g><path d="M 0,0 c 10,20 30,40 50,60" '
               'stroke="rgb(0,0,0)" stroke-width="1"/></g></svg>')
        doc = svg_to_document(svg)
        elem = doc.layers[0].children[0]
        self.assertIsInstance(elem.d[1], CurveTo)
        self.assertAlmostEqual(elem.d[1].x1, _pt(10), places=2)
        self.assertAlmostEqual(elem.d[1].y1, _pt(20), places=2)
        self.assertAlmostEqual(elem.d[1].x, _pt(50), places=2)
        self.assertAlmostEqual(elem.d[1].y, _pt(60), places=2)

    def test_import_h_v_commands(self):
        """H/h/V/v horizontal and vertical lineto commands."""
        svg = ('<svg xmlns="http://www.w3.org/2000/svg">'
               '<g><path d="M 10,10 H 50 V 80 h -20 v -30" '
               'stroke="rgb(0,0,0)" stroke-width="1"/></g></svg>')
        doc = svg_to_document(svg)
        elem = doc.layers[0].children[0]
        self.assertEqual(len(elem.d), 5)
        # H 50 => LineTo(50, 10)
        self.assertAlmostEqual(elem.d[1].x, _pt(50), places=2)
        self.assertAlmostEqual(elem.d[1].y, _pt(10), places=2)
        # V 80 => LineTo(50, 80)
        self.assertAlmostEqual(elem.d[2].x, _pt(50), places=2)
        self.assertAlmostEqual(elem.d[2].y, _pt(80), places=2)
        # h -20 => LineTo(30, 80)
        self.assertAlmostEqual(elem.d[3].x, _pt(30), places=2)
        self.assertAlmostEqual(elem.d[3].y, _pt(80), places=2)
        # v -30 => LineTo(30, 50)
        self.assertAlmostEqual(elem.d[4].x, _pt(30), places=2)
        self.assertAlmostEqual(elem.d[4].y, _pt(50), places=2)

    def test_import_hex_color_6(self):
        """Import #RRGGBB hex color."""
        svg = ('<svg xmlns="http://www.w3.org/2000/svg">'
               '<g><rect x="0" y="0" width="96" height="96" fill="#ff8000"/></g></svg>')
        doc = svg_to_document(svg)
        elem = doc.layers[0].children[0]
        self.assertIsInstance(elem, Rect)
        self.assertIsNotNone(elem.fill)
        self.assertAlmostEqual(elem.fill.color.r, 1.0, places=2)
        self.assertAlmostEqual(elem.fill.color.g, 128 / 255.0, places=2)
        self.assertAlmostEqual(elem.fill.color.b, 0.0, places=2)

    def test_import_hex_color_3(self):
        """Import #RGB shorthand hex color."""
        svg = ('<svg xmlns="http://www.w3.org/2000/svg">'
               '<g><rect x="0" y="0" width="96" height="96" fill="#f00"/></g></svg>')
        doc = svg_to_document(svg)
        elem = doc.layers[0].children[0]
        self.assertIsNotNone(elem.fill)
        self.assertAlmostEqual(elem.fill.color.r, 1.0, places=2)
        self.assertAlmostEqual(elem.fill.color.g, 0.0, places=2)
        self.assertAlmostEqual(elem.fill.color.b, 0.0, places=2)

    def test_import_hex_stroke(self):
        """Import hex color on stroke attribute."""
        svg = ('<svg xmlns="http://www.w3.org/2000/svg">'
               '<g><line x1="0" y1="0" x2="96" y2="96" stroke="#0000ff" stroke-width="2"/></g></svg>')
        doc = svg_to_document(svg)
        elem = doc.layers[0].children[0]
        self.assertIsNotNone(elem.stroke)
        self.assertAlmostEqual(elem.stroke.color.b, 1.0, places=2)

    def test_roundtrip_stroke_linecap_linejoin(self):
        layer = Layer(children=(
            Line(x1=0, y1=0, x2=72, y2=72,
                 stroke=Stroke(color=RgbColor(0, 0, 0),
                               linecap=LineCap.ROUND,
                               linejoin=LineJoin.BEVEL)),
        ))
        doc2 = self._roundtrip(Document(layers=(layer,)))
        elem = doc2.layers[0].children[0]
        self.assertEqual(elem.stroke.linecap, LineCap.ROUND)
        self.assertEqual(elem.stroke.linejoin, LineJoin.BEVEL)


    def test_roundtrip_arc_large_sweep(self):
        """Arc with large_arc=True, sweep=True."""
        layer = Layer(children=(
            Path(d=(
                MoveTo(0, 0),
                ArcTo(rx=36, ry=36, x_rotation=0, large_arc=True, sweep=True, x=72, y=0),
            ), stroke=Stroke(color=RgbColor(0, 0, 0))),
        ))
        doc2 = self._roundtrip(Document(layers=(layer,)))
        elem = doc2.layers[0].children[0]
        self.assertIsInstance(elem.d[1], ArcTo)
        self.assertTrue(elem.d[1].large_arc)
        self.assertTrue(elem.d[1].sweep)
        self.assertAlmostEqual(elem.d[1].rx, 36, places=1)
        self.assertAlmostEqual(elem.d[1].x, 72, places=1)

    def test_roundtrip_arc_small_nosweep(self):
        """Arc with large_arc=False, sweep=False."""
        layer = Layer(children=(
            Path(d=(
                MoveTo(0, 0),
                ArcTo(rx=36, ry=18, x_rotation=30, large_arc=False, sweep=False, x=72, y=36),
            ), stroke=Stroke(color=RgbColor(0, 0, 0))),
        ))
        doc2 = self._roundtrip(Document(layers=(layer,)))
        elem = doc2.layers[0].children[0]
        self.assertIsInstance(elem.d[1], ArcTo)
        self.assertFalse(elem.d[1].large_arc)
        self.assertFalse(elem.d[1].sweep)
        self.assertAlmostEqual(elem.d[1].ry, 18, places=1)
        self.assertAlmostEqual(elem.d[1].x_rotation, 30, places=1)

    def test_import_named_color(self):
        """Named SVG colors like 'red', 'steelblue'."""
        svg = ('<svg xmlns="http://www.w3.org/2000/svg">'
               '<g><rect x="0" y="0" width="96" height="96" fill="red"/></g></svg>')
        doc = svg_to_document(svg)
        elem = doc.layers[0].children[0]
        self.assertAlmostEqual(elem.fill.color.r, 1.0, places=2)
        self.assertAlmostEqual(elem.fill.color.g, 0.0, places=2)

    def test_import_named_color_steelblue(self):
        svg = ('<svg xmlns="http://www.w3.org/2000/svg">'
               '<g><rect x="0" y="0" width="96" height="96" fill="steelblue"/></g></svg>')
        doc = svg_to_document(svg)
        elem = doc.layers[0].children[0]
        self.assertAlmostEqual(elem.fill.color.r, 70 / 255, places=2)
        self.assertAlmostEqual(elem.fill.color.g, 130 / 255, places=2)
        self.assertAlmostEqual(elem.fill.color.b, 180 / 255, places=2)

    # ── Tspan rotate roundtrip (multi-value handling) ───────────────

    def _svg_with_tspan(self, markup: str) -> str:
        return ('<?xml version="1.0" encoding="UTF-8"?>'
                '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">'
                f'<text x="0" y="20" font-size="12">{markup}</text>'
                '</svg>')

    def test_svg_single_value_tspan_rotate_roundtrip(self):
        svg = self._svg_with_tspan('<tspan rotate="30">abc</tspan>')
        doc = svg_to_document(svg)
        elem = doc.layers[0].children[0]
        self.assertEqual(len(elem.tspans), 1)
        self.assertEqual(elem.tspans[0].content, "abc")
        self.assertEqual(elem.tspans[0].rotate, 30.0)

    def test_svg_multi_value_tspan_rotate_splits_per_glyph(self):
        svg = self._svg_with_tspan('<tspan rotate="45 90 0">abc</tspan>')
        doc = svg_to_document(svg)
        elem = doc.layers[0].children[0]
        self.assertEqual(len(elem.tspans), 3)
        self.assertEqual(elem.tspans[0].content, "a")
        self.assertEqual(elem.tspans[0].rotate, 45.0)
        self.assertEqual(elem.tspans[1].content, "b")
        self.assertEqual(elem.tspans[1].rotate, 90.0)
        self.assertEqual(elem.tspans[2].content, "c")
        self.assertEqual(elem.tspans[2].rotate, 0.0)
        self.assertEqual(elem.tspans[0].id, 0)
        self.assertEqual(elem.tspans[1].id, 1)
        self.assertEqual(elem.tspans[2].id, 2)

    def test_svg_multi_value_tspan_rotate_reuses_last_angle(self):
        svg = self._svg_with_tspan('<tspan rotate="45 90">abcd</tspan>')
        doc = svg_to_document(svg)
        elem = doc.layers[0].children[0]
        self.assertEqual(len(elem.tspans), 4)
        self.assertEqual(elem.tspans[0].rotate, 45.0)
        self.assertEqual(elem.tspans[1].rotate, 90.0)
        self.assertEqual(elem.tspans[2].rotate, 90.0)
        self.assertEqual(elem.tspans[3].rotate, 90.0)

    def test_svg_per_glyph_tspan_rotate_full_roundtrip(self):
        from geometry.element import Layer, Text
        from geometry.tspan import Tspan
        t = Text(
            x=10, y=20, content="abc",
            tspans=(
                Tspan(id=0, content="a", rotate=45.0),
                Tspan(id=1, content="b", rotate=90.0),
                Tspan(id=2, content="c", rotate=0.0),
            ))
        layer = Layer(children=(t,))
        doc = Document(layers=(layer,))
        doc2 = self._roundtrip(doc)
        elem = doc2.layers[0].children[0]
        self.assertEqual(len(elem.tspans), 3)
        self.assertEqual(elem.tspans[0].rotate, 45.0)
        self.assertEqual(elem.tspans[1].rotate, 90.0)
        self.assertEqual(elem.tspans[2].rotate, 0.0)

    def test_svg_jas_role_emitted_on_tspan(self):
        # Phase 1a: a wrapper Tspan with jas_role="paragraph" emits
        # urn:jas:1:role="paragraph" on the <tspan> element. Full
        # document round-trip through ElementTree is verified by the
        # next test below; this one just locks down the emission.
        from geometry.element import Layer, Text
        t = Text(
            x=10, y=20, content="hello",
            tspans=(
                Tspan(id=0, content="", jas_role="paragraph"),
                Tspan(id=1, content="hello"),
            ))
        layer = Layer(children=(t,))
        doc = Document(layers=(layer,))
        svg = document_to_svg(doc)
        self.assertIn('urn:jas:1:role="paragraph"', svg)
        self.assertIn(">hello</tspan>", svg)

    def test_svg_phase1b1_paragraph_attrs_emitted_on_tspan(self):
        # text-align / text-align-last / text-indent serialise as bare
        # CSS-style attribute names; jas:space-before / jas:space-after
        # use the urn:jas:1: prefix to keep XML namespace-friendly.
        from geometry.element import Layer, Text
        t = Text(
            x=10, y=20, content="X",
            tspans=(
                Tspan(id=0, content="", jas_role="paragraph",
                      text_align="justify", text_align_last="left",
                      text_indent=-12.0,
                      jas_space_before=6.0, jas_space_after=3.0),
                Tspan(id=1, content="X"),
            ))
        layer = Layer(children=(t,))
        doc = Document(layers=(layer,))
        svg = document_to_svg(doc)
        self.assertIn('text-align="justify"', svg)
        self.assertIn('text-align-last="left"', svg)
        self.assertIn('text-indent="-12"', svg)
        self.assertIn('urn:jas:1:space-before="6"', svg)
        self.assertIn('urn:jas:1:space-after="3"', svg)

    # Full document SVG round-trip through ElementTree is deferred to
    # Phase 1b alongside the xmlns:jas namespace work — Python's
    # XML parser, like Foundation's XMLDocument and OCaml's Xmlm,
    # rejects colon-prefixed attribute names without an explicit
    # namespace declaration on the SVG root.


if __name__ == "__main__":
    absltest.main()
