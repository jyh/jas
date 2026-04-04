from absl.testing import absltest

from document import Document
from element import (
    ArcTo, Circle, ClosePath, Color, CurveTo, Ellipse, Fill, Group, Layer,
    Line, LineCap, LineJoin, LineTo, MoveTo, Path, Polygon, Polyline,
    QuadTo, Rect, SmoothCurveTo, SmoothQuadTo, Stroke, Text, Transform,
)
from svg import document_to_svg


# 1 pt = 96/72 px = 4/3 px
_S = 96.0 / 72.0


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
                 stroke=Stroke(color=Color(0, 0, 0))),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        # 72pt -> 96px, 36pt -> 48px
        self.assertIn('x2="96"', svg)
        self.assertIn('y2="48"', svg)

    def test_rect_with_fill_and_stroke(self):
        layer = Layer(children=(
            Rect(x=0, y=0, width=72, height=72,
                 fill=Fill(color=Color(1, 0, 0)),
                 stroke=Stroke(color=Color(0, 0, 0))),
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
            Circle(cx=36, cy=36, r=18, fill=Fill(color=Color(0, 0, 1))),
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
                    stroke=Stroke(color=Color(0, 0, 0))),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('<polygon', svg)
        self.assertIn('0,0 96,0 48,96', svg)

    def test_polyline(self):
        layer = Layer(children=(
            Polyline(points=((0, 0), (36, 72)),
                     stroke=Stroke(color=Color(0, 0, 0))),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('<polyline', svg)
        self.assertIn('0,0 48,96', svg)

    def test_path(self):
        layer = Layer(children=(
            Path(d=(MoveTo(0, 0), LineTo(72, 72), ClosePath()),
                 stroke=Stroke(color=Color(0, 0, 0))),
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
            ), stroke=Stroke(color=Color(0, 0, 0))),
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
                 font_size=12, fill=Fill(color=Color(0, 0, 0))),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('<text', svg)
        self.assertIn('font-family="Arial"', svg)
        self.assertIn('>Hello</text>', svg)

    def test_text_escaping(self):
        layer = Layer(children=(
            Text(x=0, y=0, content="<b>&amp;</b>"),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('&lt;b&gt;&amp;amp;&lt;/b&gt;', svg)

    def test_no_fill(self):
        layer = Layer(children=(
            Rect(x=0, y=0, width=72, height=72,
                 stroke=Stroke(color=Color(0, 0, 0))),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('fill="none"', svg)

    def test_no_stroke(self):
        layer = Layer(children=(
            Rect(x=0, y=0, width=72, height=72,
                 fill=Fill(color=Color(1, 1, 1))),
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
                 stroke=Stroke(color=Color(0, 0, 0),
                               linecap=LineCap.ROUND,
                               linejoin=LineJoin.BEVEL)),
        ))
        svg = document_to_svg(Document(layers=(layer,)))
        self.assertIn('stroke-linecap="round"', svg)
        self.assertIn('stroke-linejoin="bevel"', svg)

    def test_color_alpha(self):
        layer = Layer(children=(
            Rect(x=0, y=0, width=72, height=72,
                 fill=Fill(color=Color(1, 0, 0, 0.5))),
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
                 stroke=Stroke(color=Color(0, 0, 0))),
        ))
        layer2 = Layer(name="L2", children=(
            Circle(cx=36, cy=36, r=18),
        ))
        svg = document_to_svg(Document(layers=(layer1, layer2)))
        self.assertIn('inkscape:label="L1"', svg)
        self.assertIn('inkscape:label="L2"', svg)


if __name__ == "__main__":
    absltest.main()
