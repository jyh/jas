"""Tests for binary document serialization (MessagePack + deflate)."""

import os
import struct

from absl.testing import absltest

from document.document import (
    Document, ElementSelection, SortedCps,
    _SelectionAll, _SelectionPartial,
)
from geometry.element import (
    Line, Rect, Circle, Ellipse, Polyline, Polygon,
    Path, Text, TextPath, Group, Layer,
    RgbColor, HsbColor, CmykColor,
    Fill, Stroke, Transform, Visibility,
    LineCap, LineJoin,
    MoveTo, LineTo as LineToCmd, CurveTo, SmoothCurveTo,
    QuadTo, SmoothQuadTo, ArcTo, ClosePath,
)
from geometry.binary import document_to_binary, binary_to_document, MAGIC, VERSION
from geometry.test_json import document_to_test_json, test_json_to_document

_FIXTURES = os.path.join(os.path.dirname(__file__), "..", "..", "test_fixtures")


def _read_fixture(path: str) -> str:
    full = os.path.join(_FIXTURES, path)
    with open(full) as f:
        return f.read().strip()


def _wrap(elem):
    """Wrap a single element in a Layer/Document for round-trip testing."""
    layer = Layer(children=(elem,))
    return Document(layers=(layer,), selected_layer=0, selection=frozenset())


def _roundtrip(doc):
    """Serialize to binary and back, return the deserialized Document."""
    data = document_to_binary(doc)
    return binary_to_document(data)


class BinaryHeaderTest(absltest.TestCase):

    def test_header_magic_bytes(self):
        doc = Document()
        data = document_to_binary(doc)
        self.assertEqual(data[:4], b"JAS\x00")

    def test_header_version(self):
        doc = Document()
        data = document_to_binary(doc)
        version = struct.unpack_from("<H", data, 4)[0]
        self.assertEqual(version, 1)

    def test_header_flags_deflate(self):
        doc = Document()
        data = document_to_binary(doc, compress=True)
        flags = struct.unpack_from("<H", data, 6)[0]
        self.assertEqual(flags & 0x03, 1)

    def test_header_flags_no_compression(self):
        doc = Document()
        data = document_to_binary(doc, compress=False)
        flags = struct.unpack_from("<H", data, 6)[0]
        self.assertEqual(flags & 0x03, 0)

    def test_invalid_magic_rejected(self):
        doc = Document()
        data = bytearray(document_to_binary(doc))
        data[0:4] = b"XXX\x00"
        with self.assertRaises(ValueError):
            binary_to_document(bytes(data))

    def test_unsupported_version_rejected(self):
        doc = Document()
        data = bytearray(document_to_binary(doc))
        struct.pack_into("<H", data, 4, 99)
        with self.assertRaises(ValueError):
            binary_to_document(bytes(data))

    def test_unsupported_compression_rejected(self):
        doc = Document()
        data = bytearray(document_to_binary(doc))
        struct.pack_into("<H", data, 6, 3)
        with self.assertRaises(ValueError):
            binary_to_document(bytes(data))

    def test_truncated_data_rejected(self):
        with self.assertRaises(ValueError):
            binary_to_document(b"JAS\x00\x01")


class BinaryRoundtripTest(absltest.TestCase):

    def _assert_roundtrip(self, doc):
        """Assert binary round-trip produces identical test JSON."""
        expected = document_to_test_json(doc)
        doc2 = _roundtrip(doc)
        actual = document_to_test_json(doc2)
        self.assertEqual(actual, expected)

    # -- Basic element types --

    def test_roundtrip_empty_document(self):
        self._assert_roundtrip(Document())

    def test_roundtrip_line(self):
        self._assert_roundtrip(_wrap(
            Line(x1=10.0, y1=20.0, x2=30.0, y2=40.0,
                 stroke=Stroke(color=RgbColor(1.0, 0.0, 0.0),
                               width=2.0))))

    def test_roundtrip_rect(self):
        self._assert_roundtrip(_wrap(
            Rect(x=5.0, y=10.0, width=100.0, height=50.0,
                 rx=3.0, ry=3.0,
                 fill=Fill(color=RgbColor(0.0, 0.0, 1.0)),
                 stroke=Stroke(color=RgbColor(0.0, 0.0, 0.0),
                               width=1.0))))

    def test_roundtrip_circle(self):
        self._assert_roundtrip(_wrap(
            Circle(cx=50.0, cy=50.0, r=25.0,
                   fill=Fill(color=RgbColor(0.0, 1.0, 0.0)))))

    def test_roundtrip_ellipse(self):
        self._assert_roundtrip(_wrap(
            Ellipse(cx=50.0, cy=50.0, rx=30.0, ry=20.0,
                    fill=Fill(color=RgbColor(1.0, 1.0, 0.0)))))

    def test_roundtrip_polyline(self):
        self._assert_roundtrip(_wrap(
            Polyline(points=((0.0, 0.0), (10.0, 20.0), (30.0, 10.0)),
                     stroke=Stroke(color=RgbColor(0.0, 0.0, 0.0),
                                   width=1.0))))

    def test_roundtrip_polygon(self):
        self._assert_roundtrip(_wrap(
            Polygon(points=((0.0, 0.0), (50.0, 0.0), (25.0, 40.0)),
                    fill=Fill(color=RgbColor(0.5, 0.5, 0.5)))))

    def test_roundtrip_path_all_commands(self):
        self._assert_roundtrip(_wrap(
            Path(d=(
                MoveTo(10.0, 20.0),
                LineToCmd(30.0, 40.0),
                CurveTo(1.0, 2.0, 3.0, 4.0, 5.0, 6.0),
                SmoothCurveTo(7.0, 8.0, 9.0, 10.0),
                QuadTo(11.0, 12.0, 13.0, 14.0),
                SmoothQuadTo(15.0, 16.0),
                ArcTo(20.0, 20.0, 0.0, True, False, 50.0, 50.0),
                ClosePath(),
            ), fill=Fill(color=RgbColor(0.0, 0.0, 0.0)),
               stroke=Stroke(color=RgbColor(1.0, 0.0, 0.0), width=1.0))))

    def test_roundtrip_text(self):
        self._assert_roundtrip(_wrap(
            Text(x=10.0, y=20.0, content="Hello World",
                 font_family="Helvetica", font_size=12.0,
                 font_weight="normal", font_style="normal",
                 text_decoration="none",
                 width=0.0, height=0.0,
                 fill=Fill(color=RgbColor(0.0, 0.0, 0.0)))))

    def test_roundtrip_text_path(self):
        self._assert_roundtrip(_wrap(
            TextPath(d=(MoveTo(0.0, 0.0), LineToCmd(100.0, 0.0)),
                     content="On a path",
                     start_offset=0.0,
                     font_family="Arial", font_size=14.0,
                     font_weight="bold", font_style="italic",
                     text_decoration="underline",
                     fill=Fill(color=RgbColor(0.0, 0.0, 0.0)))))

    def test_roundtrip_group(self):
        self._assert_roundtrip(_wrap(
            Group(children=(
                Rect(x=0.0, y=0.0, width=10.0, height=10.0),
                Circle(cx=5.0, cy=5.0, r=3.0),
            ))))

    def test_roundtrip_nested_group(self):
        inner = Group(children=(
            Line(x1=0.0, y1=0.0, x2=10.0, y2=10.0),))
        outer = Group(children=(inner,))
        self._assert_roundtrip(_wrap(outer))

    # -- Edge cases --

    def test_roundtrip_nil_transform(self):
        self._assert_roundtrip(_wrap(
            Rect(x=0.0, y=0.0, width=10.0, height=10.0, transform=None)))

    def test_roundtrip_with_transform(self):
        self._assert_roundtrip(_wrap(
            Rect(x=0.0, y=0.0, width=10.0, height=10.0,
                 transform=Transform(1.0, 0.0, 0.0, 1.0, 10.0, 20.0))))

    def test_roundtrip_nil_fill_nil_stroke(self):
        self._assert_roundtrip(_wrap(
            Rect(x=0.0, y=0.0, width=10.0, height=10.0,
                 fill=None, stroke=None)))

    def test_roundtrip_hsb_color(self):
        self._assert_roundtrip(_wrap(
            Rect(x=0.0, y=0.0, width=10.0, height=10.0,
                 fill=Fill(color=HsbColor(120.0, 0.8, 0.9, 0.5)))))

    def test_roundtrip_cmyk_color(self):
        self._assert_roundtrip(_wrap(
            Rect(x=0.0, y=0.0, width=10.0, height=10.0,
                 fill=Fill(color=CmykColor(0.1, 0.2, 0.3, 0.4, 0.75)))))

    def test_roundtrip_multi_layer(self):
        layer1 = Layer(name="Layer 1", children=(
            Rect(x=0.0, y=0.0, width=10.0, height=10.0),))
        layer2 = Layer(name="Layer 2", children=(
            Circle(cx=5.0, cy=5.0, r=3.0),))
        doc = Document(layers=(layer1, layer2), selected_layer=1)
        self._assert_roundtrip(doc)

    def test_roundtrip_selection_all(self):
        layer = Layer(children=(
            Rect(x=0.0, y=0.0, width=10.0, height=10.0),))
        sel = frozenset([ElementSelection.all((0, 0))])
        doc = Document(layers=(layer,), selection=sel)
        self._assert_roundtrip(doc)

    def test_roundtrip_selection_partial(self):
        layer = Layer(children=(
            Path(d=(MoveTo(0.0, 0.0), LineToCmd(10.0, 10.0))),))
        sel = frozenset([ElementSelection.partial((0, 0), [0, 1])])
        doc = Document(layers=(layer,), selection=sel)
        self._assert_roundtrip(doc)

    def test_roundtrip_selection_empty(self):
        doc = Document(selection=frozenset())
        self._assert_roundtrip(doc)

    def test_roundtrip_locked_invisible(self):
        self._assert_roundtrip(_wrap(
            Rect(x=0.0, y=0.0, width=10.0, height=10.0,
                 locked=True, visibility=Visibility.INVISIBLE)))

    def test_roundtrip_visibility_outline(self):
        self._assert_roundtrip(_wrap(
            Rect(x=0.0, y=0.0, width=10.0, height=10.0,
                 visibility=Visibility.OUTLINE)))

    def test_roundtrip_linecap_linejoin_variants(self):
        for cap in LineCap:
            for join in LineJoin:
                self._assert_roundtrip(_wrap(
                    Rect(x=0.0, y=0.0, width=10.0, height=10.0,
                         stroke=Stroke(color=RgbColor(0.0, 0.0, 0.0),
                                       width=1.0,
                                       linecap=cap, linejoin=join))))

    def test_roundtrip_empty_points(self):
        self._assert_roundtrip(_wrap(Polyline(points=())))

    def test_roundtrip_empty_path(self):
        self._assert_roundtrip(_wrap(Path(d=())))

    def test_roundtrip_arc_flags(self):
        self._assert_roundtrip(_wrap(
            Path(d=(
                MoveTo(0.0, 0.0),
                ArcTo(10.0, 10.0, 45.0, True, False, 20.0, 20.0),
                ArcTo(10.0, 10.0, 0.0, False, True, 30.0, 30.0),
            ))))


class BinaryJsonCrossFormatTest(absltest.TestCase):
    """Round-trip through binary and verify against canonical JSON fixtures."""

    _FIXTURE_NAMES = [
        "line_basic", "rect_basic", "rect_with_stroke",
        "circle_basic", "ellipse_basic",
        "polyline_basic", "polygon_basic", "path_all_commands",
        "text_basic", "text_path_basic",
        "group_nested", "transform_translate", "transform_rotate",
        "multi_layer", "complex_document",
    ]

    def test_binary_json_roundtrip_all_fixtures(self):
        for name in self._FIXTURE_NAMES:
            with self.subTest(name=name):
                expected = _read_fixture(f"expected/{name}.json")
                doc = test_json_to_document(expected)
                binary_data = document_to_binary(doc)
                doc2 = binary_to_document(binary_data)
                actual = document_to_test_json(doc2)
                self.assertEqual(actual, expected,
                    f"Binary round-trip '{name}' failed")


class BinaryCompressionTest(absltest.TestCase):

    def test_compressed_smaller_than_uncompressed(self):
        expected = _read_fixture("expected/complex_document.json")
        doc = test_json_to_document(expected)
        compressed = document_to_binary(doc, compress=True)
        uncompressed = document_to_binary(doc, compress=False)
        self.assertLess(len(compressed), len(uncompressed))

    def test_uncompressed_roundtrip(self):
        expected = _read_fixture("expected/complex_document.json")
        doc = test_json_to_document(expected)
        data = document_to_binary(doc, compress=False)
        doc2 = binary_to_document(data)
        actual = document_to_test_json(doc2)
        self.assertEqual(actual, expected)


if __name__ == "__main__":
    absltest.main()
