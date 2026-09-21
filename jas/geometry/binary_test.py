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
        self.assertEqual(version, 2)  # v2: CommonProps id+name in common block

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

    def test_legacy_v1_rejected(self):
        # v1 used a different positional layout (no generic name/id slots),
        # so v2 readers must reject it rather than silently mis-parse.
        doc = Document()
        data = bytearray(document_to_binary(doc))
        struct.pack_into("<H", data, 4, 1)
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

    def test_roundtrip_round_ellipse(self):
        # ONE ROUND KIND (2026-07-30): a round shape is an Ellipse with
        # rx == ry. The legacy circle tag's read path has its own arm in the
        # corpus harness (a_legacy_circle_tag_still_reads_as_a_round_ellipse).
        self._assert_roundtrip(_wrap(
            Ellipse(cx=50.0, cy=50.0, rx=25.0, ry=25.0,
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
                Ellipse(cx=5.0, cy=5.0, rx=3.0, ry=3.0),
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
            Ellipse(cx=5.0, cy=5.0, rx=3.0, ry=3.0),))
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


class BinaryCommonExtensionTest(absltest.TestCase):
    """The per-tag trailing extension the ports write (jas_dioxus
    binary.rs, "the per-tag trailing common extension"): every tag carries
    [mode, mask, tool_origin] after its base slots; a path then carries its
    brush pair, a group or layer its blending pair. Read TOLERANTLY: an
    absent, nil or ill-typed slot is the field's default. VERSION stays 2.
    Measured by `codec_field_survival`; the slot layout by
    test_fixtures/expected/binary_wire.json."""

    def _rt(self, *children):
        doc = Document(layers=(Layer(name="L", children=tuple(children)),))
        return binary_to_document(document_to_binary(doc)).layers[0].children

    def _mask(self):
        from geometry.element import Mask
        return Mask(subtree=Rect(x=1, y=2, width=3, height=4),
                    clip=False, invert=True, disabled=True, linked=False,
                    unlink_transform=Transform.translate(9, 9))

    def test_mode_mask_and_tool_origin_round_trip_on_a_path(self):
        from geometry.element import BlendMode
        p = Path(d=(MoveTo(0, 0), LineToCmd(1, 1)), blend_mode=BlendMode.MULTIPLY,
                 mask=self._mask(), tool_origin="blob_brush")
        (back,) = self._rt(p)
        self.assertEqual(back.blend_mode, BlendMode.MULTIPLY)
        self.assertEqual(back.mask, p.mask)
        self.assertEqual(back.tool_origin, "blob_brush")

    def test_mode_and_mask_ride_every_tag(self):
        from geometry.element import (
            BlendMode, CompoundOperation, CompoundShape, GeneratedElem,
            RecordedElem, ReferenceElem)
        m = self._mask()
        kinds = (
            Line(x1=0, y1=0, x2=1, y2=1),
            Rect(x=0, y=0, width=1, height=1),
            Ellipse(cx=0, cy=0, rx=1, ry=2),
            Polyline(points=((0, 0), (1, 1))),
            Polygon(points=((0, 0), (1, 1), (2, 0))),
            Text(x=0, y=0, content="a"),
            TextPath(d=(MoveTo(0, 0), LineToCmd(1, 1)), content="a"),
            Group(children=()),
            CompoundShape(operation=CompoundOperation.UNION, operands=()),
            ReferenceElem(target="m1"),
            RecordedElem(inputs=(), ops=()),
            GeneratedElem(concept_id="spiral", params={}),
        )
        from dataclasses import replace
        kinds = tuple(replace(k, blend_mode=BlendMode.SCREEN, mask=m) for k in kinds)
        back = self._rt(*kinds)
        self.assertEqual([type(b).__name__ for b in back],
                         [type(k).__name__ for k in kinds])
        for k, b in zip(kinds, back):
            self.assertEqual((type(b).__name__, b.blend_mode, b.mask),
                             (type(k).__name__, BlendMode.SCREEN, m))

    def test_a_layer_carries_the_extension_too(self):
        from geometry.element import BlendMode
        doc = Document(layers=(Layer(name="L", blend_mode=BlendMode.HUE,
                                     mask=self._mask(), isolated_blending=True,
                                     knockout_group=True),))
        back = binary_to_document(document_to_binary(doc)).layers[0]
        self.assertEqual((back.blend_mode, back.mask), (BlendMode.HUE, self._mask()))
        self.assertEqual((back.isolated_blending, back.knockout_group), (True, True))

    def test_group_blending_pair_round_trips_independently(self):
        (a, b) = self._rt(Group(children=(), isolated_blending=True),
                          Group(children=(), knockout_group=True))
        self.assertEqual((a.isolated_blending, a.knockout_group), (True, False))
        self.assertEqual((b.isolated_blending, b.knockout_group), (False, True))

    def test_path_brush_pair_round_trips(self):
        p = Path(d=(MoveTo(0, 0), LineToCmd(1, 1)),
                 stroke_brush="basic/calligraphic_5",
                 stroke_brush_overrides='{"angle":30}')
        (back,) = self._rt(p)
        self.assertEqual((back.stroke_brush, back.stroke_brush_overrides),
                         ("basic/calligraphic_5", '{"angle":30}'))

    def test_path_writes_the_fill_rule_slot_the_extension_is_counted_from(self):
        # Rust and Swift carry fill_rule at slot 11, so a path's extension
        # starts at 12. This model does not hold a fill rule, so it writes
        # the one the ports read as the default (0, nonzero); without the
        # slot every later path slot would sit one index early.
        from geometry.binary import _pack_element
        arr = _pack_element(Path(d=(MoveTo(0, 0), LineToCmd(1, 1))))
        self.assertEqual(arr[11], 0)

    def test_tag_arity_matches_the_shared_wire_fixture(self):
        import json
        from geometry.binary import element_tag_label, packed_element_slot_count
        from geometry.element import (
            CompoundOperation, CompoundShape, GeneratedElem, RecordedElem,
            ReferenceElem)
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "..", "..", "test_fixtures", "expected",
                               "binary_wire.json"), encoding="utf-8") as f:
            arity = json.load(f)["tag_arity"]
        elems = (
            Layer(children=()), Group(children=()),
            Line(x1=0, y1=0, x2=1, y2=1), Rect(x=0, y=0, width=1, height=2),
            Ellipse(cx=0, cy=0, rx=1, ry=2),
            Polyline(points=((0, 0), (1, 1))),
            Polygon(points=((0, 0), (1, 1), (2, 0))),
            Path(d=(MoveTo(0, 0), LineToCmd(1, 1))),
            Text(x=1, y=2, content="hi"),
            TextPath(d=(MoveTo(0, 0), LineToCmd(1, 1)), content="hi"),
            CompoundShape(operation=CompoundOperation.UNION, operands=()),
            ReferenceElem(target="m1"), RecordedElem(inputs=(), ops=()),
            GeneratedElem(concept_id="spiral", params={}),
        )
        seen = set()
        for e in elems:
            label = element_tag_label(e)
            self.assertIn(label, arity)
            self.assertEqual(packed_element_slot_count(e), arity[label],
                             f"tag '{label}' packs a different slot count than the fixture")
            seen.add(label)
        self.assertEqual(seen, set(arity), "every tag the fixture declares must be reached")

    def test_a_blob_written_before_the_extension_reads_defaults(self):
        from geometry.binary import _pack_element, _unpack_element
        from geometry.element import BlendMode
        for e, base in ((Path(d=(MoveTo(0, 0), LineToCmd(1, 1))), 12),
                        (Group(children=()), 8),
                        (Rect(x=0, y=0, width=1, height=1), 15)):
            back = _unpack_element(_pack_element(e)[:base])
            self.assertEqual((back.blend_mode, back.mask), (BlendMode.NORMAL, None))
            if isinstance(back, Path):
                self.assertEqual((back.tool_origin, back.stroke_brush,
                                  back.stroke_brush_overrides), (None, None, None))
            if isinstance(back, Group):
                self.assertEqual((back.isolated_blending, back.knockout_group),
                                 (False, False))

    def test_ill_typed_extension_slots_read_as_defaults(self):
        from geometry.binary import _pack_element, _unpack_element
        from geometry.element import BlendMode
        arr = _pack_element(Path(d=(MoveTo(0, 0), LineToCmd(1, 1))))
        arr[12:17] = ["multiply", 5, 3, 7, ["x"]]   # mode mask tool brush overrides
        back = _unpack_element(arr)
        self.assertEqual((back.blend_mode, back.mask, back.tool_origin,
                          back.stroke_brush, back.stroke_brush_overrides),
                         (BlendMode.NORMAL, None, None, None, None))
        # A group's base is 8: mode 8, mask 9, tool_origin 10, then the pair.
        g = _pack_element(Group(children=()))
        self.assertEqual(len(g), 13)
        g[8] = True                  # a boolean is not a mode tag (True == 1)
        g[9] = [5, True]             # a mask whose subtree slot is not an element
        g[11:13] = ["yes", 1]        # the blending pair, not booleans
        back = _unpack_element(g)
        self.assertEqual((back.blend_mode, back.mask, back.isolated_blending,
                          back.knockout_group),
                         (BlendMode.NORMAL, None, False, False))

    def test_a_short_mask_array_takes_the_field_defaults(self):
        from geometry.binary import _pack_element, _unpack_element
        p = _pack_element(Path(d=(MoveTo(0, 0), LineToCmd(1, 1))))
        p[13] = [_pack_element(Rect(x=0, y=0, width=1, height=1))]   # subtree only
        m = _unpack_element(p).mask
        self.assertEqual((m.clip, m.invert, m.disabled, m.linked, m.unlink_transform),
                         (True, False, False, True, None))

    def test_blend_tags_follow_the_enum_declaration_order_the_ports_share(self):
        # The table is written by name so the enum cannot renumber files; the
        # two statements must still agree, because every port numbers its tags
        # in this declaration order. A swap of two tags no fixture uses would
        # otherwise round-trip symmetrically and pass everything else.
        from geometry.binary import _BLEND_MODE_TO_INT
        from geometry.element import BlendMode
        self.assertEqual(_BLEND_MODE_TO_INT, {m: i for i, m in enumerate(BlendMode)})


class BinaryFillRuleTest(absltest.TestCase):
    """A path's slot 11: 0 nonzero, 1 evenodd; absent or unrecognised reads
    nonzero. Mirrors jas_dioxus binary.rs `pack_fill_rule`."""

    def test_evenodd_rides_slot_eleven_and_round_trips(self):
        from geometry.binary import _pack_element
        from geometry.element import FillRule
        p = Path(d=(MoveTo(0, 0), LineToCmd(1, 1)), fill_rule=FillRule.EVENODD)
        self.assertEqual(_pack_element(p)[11], 1)
        doc = Document(layers=(Layer(children=(p,)),))
        (back,) = binary_to_document(document_to_binary(doc)).layers[0].children
        self.assertEqual(back.fill_rule, FillRule.EVENODD)

    def test_absent_or_unrecognised_reads_nonzero(self):
        from geometry.binary import _pack_element, _unpack_element
        from geometry.element import FillRule
        arr = _pack_element(Path(d=(MoveTo(0, 0), LineToCmd(1, 1)),
                                 fill_rule=FillRule.EVENODD))
        self.assertEqual(_unpack_element(arr[:11]).fill_rule, FillRule.NONZERO)
        for junk in (7, "evenodd", True, None):
            arr[11] = junk
            self.assertEqual(_unpack_element(arr).fill_rule, FillRule.NONZERO, repr(junk))


if __name__ == "__main__":
    absltest.main()
