"""Binary document serialization using MessagePack + deflate.

Format:
    [Magic 4B "JAS\\0"] [Version u16 LE] [Flags u16 LE] [Payload]

    Flags bits 0-1: compression method (0=none, 1=raw deflate).
    Payload: MessagePack-encoded document using positional arrays.
"""

import struct
import zlib

import msgpack

from document.document import (
    Document, ElementSelection, SortedCps,
    _SelectionAll, _SelectionPartial,
)
from geometry.element import (
    Element, Line, Rect, Circle, Ellipse, Polyline, Polygon,
    Path, Text, TextPath, Group, Layer,
    Color, RgbColor, HsbColor, CmykColor,
    Fill, Stroke, Transform, Visibility,
    LineCap, LineJoin, StrokeAlign, Arrowhead, ArrowAlign,
    StrokeWidthPoint,
    MoveTo, LineTo as LineToCmd, CurveTo, SmoothCurveTo,
    QuadTo, SmoothQuadTo, ArcTo, ClosePath,
    CompoundOperation, CompoundShape, ReferenceElem,
)
from geometry.normalize import dedupe_element_ids

# -- Constants ---------------------------------------------------------------

MAGIC = b"JAS\x00"
# v2 (CommonProps id+name): every element array now carries name and id in
# the shared common block at fixed indices 5 and 6, with the type-specific
# payload shifted to index 7. v1 (name was Layer-only at index 5, no id) is a
# different positional layout and is NOT forward-readable — binary persistence
# is a deferred secondary format with no real-world v1 data, so the fixtures
# were regenerated to v2 rather than carrying a dual parse path.
VERSION = 2
MIN_VERSION = 2
HEADER_SIZE = 8  # 4 magic + 2 version + 2 flags

COMPRESS_NONE = 0
COMPRESS_DEFLATE = 1

# Element type tags.
_TAG_LAYER = 0
_TAG_LINE = 1
_TAG_RECT = 2
_TAG_CIRCLE = 3
_TAG_ELLIPSE = 4
_TAG_POLYLINE = 5
_TAG_POLYGON = 6
_TAG_PATH = 7
_TAG_TEXT = 8
_TAG_TEXT_PATH = 9
_TAG_GROUP = 10
# Live elements (REFERENCE_GRAPH.md Phase 2b): one tag for every
# LiveElement kind, disambiguated by a kind string at index 7.
_TAG_LIVE = 11

# Path command tags.
_CMD_MOVE_TO = 0
_CMD_LINE_TO = 1
_CMD_CURVE_TO = 2
_CMD_SMOOTH_CURVE_TO = 3
_CMD_QUAD_TO = 4
_CMD_SMOOTH_QUAD_TO = 5
_CMD_ARC_TO = 6
_CMD_CLOSE_PATH = 7

# Color space tags.
_SPACE_RGB = 0
_SPACE_HSB = 1
_SPACE_CMYK = 2

# Enum-to-int maps.
_LINECAP_TO_INT = {LineCap.BUTT: 0, LineCap.ROUND: 1, LineCap.SQUARE: 2}
_INT_TO_LINECAP = {v: k for k, v in _LINECAP_TO_INT.items()}

_LINEJOIN_TO_INT = {LineJoin.MITER: 0, LineJoin.ROUND: 1, LineJoin.BEVEL: 2}
_INT_TO_LINEJOIN = {v: k for k, v in _LINEJOIN_TO_INT.items()}

_VISIBILITY_TO_INT = {
    Visibility.INVISIBLE: 0, Visibility.OUTLINE: 1, Visibility.PREVIEW: 2,
}
_INT_TO_VISIBILITY = {v: k for k, v in _VISIBILITY_TO_INT.items()}

_STROKEALIGN_TO_INT = {
    StrokeAlign.CENTER: 0, StrokeAlign.INSIDE: 1, StrokeAlign.OUTSIDE: 2,
}
_INT_TO_STROKEALIGN = {v: k for k, v in _STROKEALIGN_TO_INT.items()}

_ARROWALIGN_TO_INT = {
    ArrowAlign.TIP_AT_END: 0, ArrowAlign.CENTER_AT_END: 1,
}
_INT_TO_ARROWALIGN = {v: k for k, v in _ARROWALIGN_TO_INT.items()}

# -- Pack (Document -> msgpack-ready structure) ------------------------------


def _pack_color(c: Color) -> list:
    if isinstance(c, RgbColor):
        return [_SPACE_RGB, c.r, c.g, c.b, 0.0, c.a]
    elif isinstance(c, HsbColor):
        return [_SPACE_HSB, c.h, c.s, c.b, 0.0, c.a]
    elif isinstance(c, CmykColor):
        return [_SPACE_CMYK, c.c, c.m, c.y, c.k, c.a]
    raise ValueError(f"Unknown color type: {type(c)}")


def _pack_fill(fill: Fill | None):
    if fill is None:
        return None
    return [_pack_color(fill.color), fill.opacity]


def _pack_stroke(stroke: Stroke | None):
    if stroke is None:
        return None
    dash = list(stroke.dash_pattern)
    return [
        _pack_color(stroke.color),
        stroke.width,
        _LINECAP_TO_INT[stroke.linecap],
        _LINEJOIN_TO_INT[stroke.linejoin],
        stroke.opacity,
        stroke.miter_limit,
        _STROKEALIGN_TO_INT[stroke.align],
        dash,
        stroke.start_arrow.value,
        stroke.end_arrow.value,
        stroke.start_arrow_scale,
        stroke.end_arrow_scale,
        _ARROWALIGN_TO_INT[stroke.arrow_align],
        # Element 13: dash_align_anchors (added with DASH_ALIGN.md).
        bool(stroke.dash_align_anchors),
    ]


def _pack_width_points(pts: tuple[StrokeWidthPoint, ...]):
    if not pts:
        return None
    return [[p.t, p.width_left, p.width_right] for p in pts]


def _pack_transform(t: Transform | None):
    if t is None:
        return None
    return [t.a, t.b, t.c, t.d, t.e, t.f]


def _pack_path_command(cmd) -> list:
    if isinstance(cmd, MoveTo):
        return [_CMD_MOVE_TO, cmd.x, cmd.y]
    elif isinstance(cmd, LineToCmd):
        return [_CMD_LINE_TO, cmd.x, cmd.y]
    elif isinstance(cmd, CurveTo):
        return [_CMD_CURVE_TO, cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.x, cmd.y]
    elif isinstance(cmd, SmoothCurveTo):
        return [_CMD_SMOOTH_CURVE_TO, cmd.x2, cmd.y2, cmd.x, cmd.y]
    elif isinstance(cmd, QuadTo):
        return [_CMD_QUAD_TO, cmd.x1, cmd.y1, cmd.x, cmd.y]
    elif isinstance(cmd, SmoothQuadTo):
        return [_CMD_SMOOTH_QUAD_TO, cmd.x, cmd.y]
    elif isinstance(cmd, ArcTo):
        return [_CMD_ARC_TO, cmd.rx, cmd.ry, cmd.x_rotation,
                cmd.large_arc, cmd.sweep, cmd.x, cmd.y]
    elif isinstance(cmd, ClosePath):
        return [_CMD_CLOSE_PATH]
    raise ValueError(f"Unknown path command: {type(cmd)}")


def _pack_tspan(t) -> list:
    """Pack a single Tspan as a compact 22-element list. Mirrors
    Rust's ``pack_tspan`` / Swift's ``packTspan`` / OCaml's
    ``pack_tspan``. Each override field is its typed value or
    ``None`` when unset; text_decoration is a list (or None);
    transform is a 6-float list (or None)."""
    decor = list(t.text_decoration) if t.text_decoration is not None else None
    if t.transform is not None:
        tr = t.transform
        transform = [tr.a, tr.b, tr.c, tr.d, tr.e, tr.f]
    else:
        transform = None
    return [
        t.id,
        t.content,
        t.baseline_shift,
        t.dx,
        t.font_family,
        t.font_size,
        t.font_style,
        t.font_variant,
        t.font_weight,
        t.jas_aa_mode,
        t.jas_fractional_widths,
        t.jas_kerning_mode,
        t.jas_no_break,
        t.letter_spacing,
        t.line_height,
        t.rotate,
        t.style_name,
        decor,
        t.text_rendering,
        t.text_transform,
        transform,
        t.xml_lang,
        t.jas_role,
        t.jas_left_indent,
        t.jas_right_indent,
        t.jas_hyphenate,
        t.jas_hanging_punctuation,
        t.jas_list_style,
        t.text_align,
        t.text_align_last,
        t.text_indent,
        t.jas_space_before,
        t.jas_space_after,
        t.jas_word_spacing_min,
        t.jas_word_spacing_desired,
        t.jas_word_spacing_max,
        t.jas_letter_spacing_min,
        t.jas_letter_spacing_desired,
        t.jas_letter_spacing_max,
        t.jas_glyph_scaling_min,
        t.jas_glyph_scaling_desired,
        t.jas_glyph_scaling_max,
        t.jas_auto_leading,
        t.jas_single_word_justify,
        t.jas_hyphenate_min_word,
        t.jas_hyphenate_min_before,
        t.jas_hyphenate_min_after,
        t.jas_hyphenate_limit,
        t.jas_hyphenate_zone,
        t.jas_hyphenate_bias,
        t.jas_hyphenate_capitalized,
    ]


def _unpack_tspan(v):
    """Inverse of ``_pack_tspan``. Tolerant of trailing field
    additions — missing indices fall back to None (default)."""
    from geometry.tspan import Tspan
    from geometry.element import Transform as TransformT
    def get(i):
        return v[i] if i < len(v) else None
    decor_raw = get(17)
    decor = tuple(decor_raw) if isinstance(decor_raw, list) else None
    tr_raw = get(20)
    if isinstance(tr_raw, list) and len(tr_raw) >= 6:
        transform = TransformT(a=tr_raw[0], b=tr_raw[1], c=tr_raw[2],
                               d=tr_raw[3], e=tr_raw[4], f=tr_raw[5])
    else:
        transform = None
    return Tspan(
        id=int(get(0) or 0),
        content=get(1) or "",
        baseline_shift=get(2),
        dx=get(3),
        font_family=get(4),
        font_size=get(5),
        font_style=get(6),
        font_variant=get(7),
        font_weight=get(8),
        jas_aa_mode=get(9),
        jas_fractional_widths=get(10),
        jas_kerning_mode=get(11),
        jas_no_break=get(12),
        letter_spacing=get(13),
        line_height=get(14),
        rotate=get(15),
        style_name=get(16),
        text_decoration=decor,
        text_rendering=get(18),
        text_transform=get(19),
        transform=transform,
        xml_lang=get(21),
        jas_role=get(22),
        jas_left_indent=get(23),
        jas_right_indent=get(24),
        jas_hyphenate=get(25),
        jas_hanging_punctuation=get(26),
        jas_list_style=get(27),
        text_align=get(28),
        text_align_last=get(29),
        text_indent=get(30),
        jas_space_before=get(31),
        jas_space_after=get(32),
        jas_word_spacing_min=get(33),
        jas_word_spacing_desired=get(34),
        jas_word_spacing_max=get(35),
        jas_letter_spacing_min=get(36),
        jas_letter_spacing_desired=get(37),
        jas_letter_spacing_max=get(38),
        jas_glyph_scaling_min=get(39),
        jas_glyph_scaling_desired=get(40),
        jas_glyph_scaling_max=get(41),
        jas_auto_leading=get(42),
        jas_single_word_justify=get(43),
        jas_hyphenate_min_word=get(44),
        jas_hyphenate_min_before=get(45),
        jas_hyphenate_min_after=get(46),
        jas_hyphenate_limit=get(47),
        jas_hyphenate_zone=get(48),
        jas_hyphenate_bias=get(49),
        jas_hyphenate_capitalized=get(50),
    )


def _pack_common(elem: Element) -> list:
    """The shared common block written for EVERY element (v2):
    [locked, opacity, visibility, transform, name, id] at array indices
    1..6. name and id are stored as msgpack value-or-nil (None -> nil), so
    every element type round-trips them uniformly — mirroring test_json's
    ``_common_fields``. The type-specific payload follows at index 7."""
    # name / id are read via getattr because not every element carries
    # both: CompoundShape (REFERENCE_GRAPH.md Phase 2b) has a stable id but
    # no name field, so name packs as nil while id packs through —
    # mirroring test_json's _common_fields.
    return [
        elem.locked,
        elem.opacity,
        _VISIBILITY_TO_INT[elem.visibility],
        _pack_transform(elem.transform),
        getattr(elem, "name", None),
        getattr(elem, "id", None),
    ]


def _pack_element(elem: Element) -> list:
    common = _pack_common(elem)

    # Layer must be checked before Group since Layer extends Group.
    if isinstance(elem, Layer):
        children = [_pack_element(c) for c in elem.children]
        return [_TAG_LAYER, *common, children]
    elif isinstance(elem, Group):
        children = [_pack_element(c) for c in elem.children]
        return [_TAG_GROUP, *common, children]
    elif isinstance(elem, Line):
        return [_TAG_LINE, *common,
                elem.x1, elem.y1, elem.x2, elem.y2,
                _pack_stroke(elem.stroke), _pack_width_points(elem.width_points)]
    elif isinstance(elem, Rect):
        return [_TAG_RECT, *common,
                elem.x, elem.y, elem.width, elem.height, elem.rx, elem.ry,
                _pack_fill(elem.fill), _pack_stroke(elem.stroke)]
    elif isinstance(elem, Circle):
        return [_TAG_CIRCLE, *common,
                elem.cx, elem.cy, elem.r,
                _pack_fill(elem.fill), _pack_stroke(elem.stroke)]
    elif isinstance(elem, Ellipse):
        return [_TAG_ELLIPSE, *common,
                elem.cx, elem.cy, elem.rx, elem.ry,
                _pack_fill(elem.fill), _pack_stroke(elem.stroke)]
    elif isinstance(elem, Polyline):
        points = [[x, y] for x, y in elem.points]
        return [_TAG_POLYLINE, *common,
                points, _pack_fill(elem.fill), _pack_stroke(elem.stroke)]
    elif isinstance(elem, Polygon):
        points = [[x, y] for x, y in elem.points]
        return [_TAG_POLYGON, *common,
                points, _pack_fill(elem.fill), _pack_stroke(elem.stroke)]
    elif isinstance(elem, Path):
        cmds = [_pack_path_command(c) for c in elem.d]
        return [_TAG_PATH, *common,
                cmds, _pack_fill(elem.fill), _pack_stroke(elem.stroke),
                _pack_width_points(elem.width_points)]
    elif isinstance(elem, Text):
        tspans = [_pack_tspan(t) for t in elem.tspans]
        return [_TAG_TEXT, *common,
                elem.x, elem.y, elem.content,
                elem.font_family, elem.font_size,
                elem.font_weight, elem.font_style, elem.text_decoration,
                elem.width, elem.height,
                _pack_fill(elem.fill), _pack_stroke(elem.stroke),
                tspans]
    elif isinstance(elem, TextPath):
        cmds = [_pack_path_command(c) for c in elem.d]
        tspans = [_pack_tspan(t) for t in elem.tspans]
        return [_TAG_TEXT_PATH, *common,
                cmds, elem.content, elem.start_offset,
                elem.font_family, elem.font_size,
                elem.font_weight, elem.font_style, elem.text_decoration,
                _pack_fill(elem.fill), _pack_stroke(elem.stroke),
                tspans]
    # Live elements (REFERENCE_GRAPH.md Phase 2b): a single _TAG_LIVE with
    # a kind string at index 7, then a kind-specific payload. Paint
    # (fill/stroke) is omitted in Phase 1 (references inherit; compound
    # carries none here), mirroring the test_json live codec.
    elif isinstance(elem, ReferenceElem):
        # [tag, common(1..6), kind(7), target(8), instance_transform(9)]
        # Symbols P4 (SYMBOLS.md §4 / Fork F2): the instance transform
        # (distinct from the render CTM packed at index 4) rides slot 9 via
        # _pack_transform; nil when None. Old 9-element .bin (no slot 9) still
        # decode TOLERANTLY to None on the read side.
        return [_TAG_LIVE, *common, "reference", elem.target,
                _pack_transform(elem.instance_transform)]
    elif isinstance(elem, CompoundShape):
        # [tag, common(1..6), kind(7), operation(8), operands(9)]
        operands = [_pack_element(c) for c in elem.operands]
        return [_TAG_LIVE, *common,
                "compound_shape", elem.operation.value, operands]
    raise ValueError(f"Unknown element type: {type(elem)}")


def _pack_selection(sel: frozenset[ElementSelection]) -> list:
    entries = []
    for es in sel:
        if isinstance(es.kind, _SelectionAll):
            kind = 0
        elif isinstance(es.kind, _SelectionPartial):
            kind = [1] + list(es.kind.cps)
        else:
            raise ValueError(f"Unknown selection kind: {type(es.kind)}")
        entries.append((list(es.path), kind))
    entries.sort(key=lambda e: e[0])
    return [list(e) for e in entries]


def _pack_document(doc: Document) -> list:
    layers = [_pack_element(l) for l in doc.layers]
    # Symbols (master store, SYMBOLS.md §5): appended to the positional
    # document array AFTER the existing fields, as a (possibly empty) element
    # array sorted by id (the §2 deterministic-order rule). Trailing position
    # keeps existing .bin fixtures (which predate symbols) decodable — unpack
    # tolerates the field's absence via arr index 3.
    sorted_masters = sorted(doc.symbols, key=lambda m: getattr(m, "id", None) or "")
    symbols = [_pack_element(m) for m in sorted_masters]
    return [layers, doc.selected_layer, _pack_selection(doc.selection), symbols]


# -- Unpack (msgpack structure -> Document) ----------------------------------


def _unpack_color(arr: list) -> Color:
    space = arr[0]
    if space == _SPACE_RGB:
        return RgbColor(r=arr[1], g=arr[2], b=arr[3], a=arr[5])
    elif space == _SPACE_HSB:
        return HsbColor(h=arr[1], s=arr[2], b=arr[3], a=arr[5])
    elif space == _SPACE_CMYK:
        return CmykColor(c=arr[1], m=arr[2], y=arr[3], k=arr[4], a=arr[5])
    raise ValueError(f"Unknown color space: {space}")


def _unpack_fill(v) -> Fill | None:
    if v is None:
        return None
    return Fill(color=_unpack_color(v[0]), opacity=v[1])


def _unpack_stroke(v) -> Stroke | None:
    if v is None:
        return None
    base = dict(
        color=_unpack_color(v[0]),
        width=v[1],
        linecap=_INT_TO_LINECAP[v[2]],
        linejoin=_INT_TO_LINEJOIN[v[3]],
        opacity=v[4],
    )
    # Extended fields (backward compatible: old files have 5 elements)
    if len(v) > 5:
        base['miter_limit'] = float(v[5])
        base['align'] = _INT_TO_STROKEALIGN.get(v[6], StrokeAlign.CENTER)
        base['dash_pattern'] = tuple(float(x) for x in v[7])
        base['start_arrow'] = Arrowhead.from_string(v[8])
        base['end_arrow'] = Arrowhead.from_string(v[9])
        base['start_arrow_scale'] = float(v[10])
        base['end_arrow_scale'] = float(v[11])
        base['arrow_align'] = _INT_TO_ARROWALIGN.get(v[12], ArrowAlign.TIP_AT_END)
    # Element 13: dash_align_anchors (added later — backward
    # compatible with older files that had 13 elements).
    if len(v) > 13:
        base['dash_align_anchors'] = bool(v[13])
    return Stroke(**base)


def _unpack_width_points(v) -> tuple[StrokeWidthPoint, ...]:
    if v is None:
        return ()
    return tuple(
        StrokeWidthPoint(t=float(p[0]), width_left=float(p[1]), width_right=float(p[2]))
        for p in v
    )


def _unpack_transform(v) -> Transform | None:
    if v is None:
        return None
    return Transform(a=v[0], b=v[1], c=v[2], d=v[3], e=v[4], f=v[5])


def _unpack_path_command(arr: list):
    tag = arr[0]
    if tag == _CMD_MOVE_TO:
        return MoveTo(x=arr[1], y=arr[2])
    elif tag == _CMD_LINE_TO:
        return LineToCmd(x=arr[1], y=arr[2])
    elif tag == _CMD_CURVE_TO:
        return CurveTo(x1=arr[1], y1=arr[2], x2=arr[3], y2=arr[4],
                        x=arr[5], y=arr[6])
    elif tag == _CMD_SMOOTH_CURVE_TO:
        return SmoothCurveTo(x2=arr[1], y2=arr[2], x=arr[3], y=arr[4])
    elif tag == _CMD_QUAD_TO:
        return QuadTo(x1=arr[1], y1=arr[2], x=arr[3], y=arr[4])
    elif tag == _CMD_SMOOTH_QUAD_TO:
        return SmoothQuadTo(x=arr[1], y=arr[2])
    elif tag == _CMD_ARC_TO:
        return ArcTo(rx=arr[1], ry=arr[2], x_rotation=arr[3],
                     large_arc=bool(arr[4]), sweep=bool(arr[5]),
                     x=arr[6], y=arr[7])
    elif tag == _CMD_CLOSE_PATH:
        return ClosePath()
    raise ValueError(f"Unknown path command tag: {tag}")


def _unpack_common(arr: list) -> dict:
    """Inverse of ``_pack_common``: reads the shared common block at
    indices 1..6 (locked, opacity, visibility, transform, name, id).
    Returned as kwargs spread into every element constructor."""
    return dict(
        locked=arr[1],
        opacity=float(arr[2]),
        visibility=_INT_TO_VISIBILITY[arr[3]],
        transform=_unpack_transform(arr[4]),
        name=arr[5],
        id=arr[6],
    )


def _unpack_element(arr: list) -> Element:
    tag = arr[0]
    common = _unpack_common(arr)
    # Type-specific payload begins at index 7 (after the common block).

    if tag == _TAG_LAYER:
        children = tuple(_unpack_element(c) for c in arr[7])
        return Layer(children=children, **common)
    elif tag == _TAG_GROUP:
        children = tuple(_unpack_element(c) for c in arr[7])
        return Group(children=children, **common)
    elif tag == _TAG_LINE:
        wp = _unpack_width_points(arr[12]) if len(arr) > 12 else ()
        return Line(x1=arr[7], y1=arr[8], x2=arr[9], y2=arr[10],
                    stroke=_unpack_stroke(arr[11]), width_points=wp, **common)
    elif tag == _TAG_RECT:
        return Rect(x=arr[7], y=arr[8], width=arr[9], height=arr[10],
                    rx=arr[11], ry=arr[12],
                    fill=_unpack_fill(arr[13]),
                    stroke=_unpack_stroke(arr[14]), **common)
    elif tag == _TAG_CIRCLE:
        return Circle(cx=arr[7], cy=arr[8], r=arr[9],
                      fill=_unpack_fill(arr[10]),
                      stroke=_unpack_stroke(arr[11]), **common)
    elif tag == _TAG_ELLIPSE:
        return Ellipse(cx=arr[7], cy=arr[8], rx=arr[9], ry=arr[10],
                       fill=_unpack_fill(arr[11]),
                       stroke=_unpack_stroke(arr[12]), **common)
    elif tag == _TAG_POLYLINE:
        points = tuple((p[0], p[1]) for p in arr[7])
        return Polyline(points=points,
                        fill=_unpack_fill(arr[8]),
                        stroke=_unpack_stroke(arr[9]), **common)
    elif tag == _TAG_POLYGON:
        points = tuple((p[0], p[1]) for p in arr[7])
        return Polygon(points=points,
                       fill=_unpack_fill(arr[8]),
                       stroke=_unpack_stroke(arr[9]), **common)
    elif tag == _TAG_PATH:
        cmds = tuple(_unpack_path_command(c) for c in arr[7])
        wp = _unpack_width_points(arr[10]) if len(arr) > 10 else ()
        return Path(d=cmds,
                    fill=_unpack_fill(arr[8]),
                    stroke=_unpack_stroke(arr[9]),
                    width_points=wp, **common)
    elif tag == _TAG_TEXT:
        # Prefer the trailing tspans field when present; otherwise
        # fall back to the single-default-tspan derived from content
        # in __post_init__ (blobs predating the tspan codec extension).
        tspans_raw = arr[19] if len(arr) > 19 else None
        tspans_kw = {}
        if isinstance(tspans_raw, list) and tspans_raw:
            tspans_kw["tspans"] = tuple(_unpack_tspan(t) for t in tspans_raw)
        return Text(x=arr[7], y=arr[8], content=arr[9],
                    font_family=arr[10], font_size=arr[11],
                    font_weight=arr[12], font_style=arr[13],
                    text_decoration=arr[14],
                    width=arr[15], height=arr[16],
                    fill=_unpack_fill(arr[17]),
                    stroke=_unpack_stroke(arr[18]),
                    **tspans_kw, **common)
    elif tag == _TAG_TEXT_PATH:
        cmds = tuple(_unpack_path_command(c) for c in arr[7])
        tspans_raw = arr[17] if len(arr) > 17 else None
        tspans_kw = {}
        if isinstance(tspans_raw, list) and tspans_raw:
            tspans_kw["tspans"] = tuple(_unpack_tspan(t) for t in tspans_raw)
        return TextPath(d=cmds, content=arr[8], start_offset=arr[9],
                        font_family=arr[10], font_size=arr[11],
                        font_weight=arr[12], font_style=arr[13],
                        text_decoration=arr[14],
                        fill=_unpack_fill(arr[15]),
                        stroke=_unpack_stroke(arr[16]),
                        **tspans_kw, **common)
    elif tag == _TAG_LIVE:
        # Live elements (REFERENCE_GRAPH.md Phase 2b): dispatch on the
        # kind string at index 7, mirroring the test_json live reader.
        kind = arr[7]
        if kind == "reference":
            # ReferenceElem is a first-class element with its own id /
            # name, so it takes the full common kwargs.
            #
            # Symbols P4: the instance transform rides slot 9, read TOLERANTLY
            # so existing 9-element .bin (no slot 9) decode to None (SYMBOLS.md
            # §4 / Fork F2).
            inst_t = _unpack_transform(arr[9]) if len(arr) > 9 else None
            return ReferenceElem(target=arr[8],
                                 instance_transform=inst_t, **common)
        elif kind == "compound_shape":
            # CompoundShape carries a stable id but no name field, so strip
            # name (it doesn't accept it) and pass id through. Unknown
            # operation strings default to union, matching the Rust reader.
            live_common = {k: v for k, v in common.items()
                           if k != "name"}
            try:
                op = CompoundOperation(arr[8])
            except ValueError:
                op = CompoundOperation.UNION
            operands = tuple(_unpack_element(c) for c in arr[9])
            return CompoundShape(operation=op, operands=operands,
                                 fill=None, stroke=None, **live_common)
        raise ValueError(f"Unknown live kind: {kind}")
    raise ValueError(f"Unknown element tag: {tag}")


def _unpack_selection(arr: list) -> frozenset[ElementSelection]:
    entries = []
    for item in arr:
        path = tuple(item[0])
        kind_val = item[1]
        if kind_val == 0:
            kind = _SelectionAll()
        else:
            kind = _SelectionPartial(SortedCps.from_iter(kind_val[1:]))
        entries.append(ElementSelection(path=path, kind=kind))
    return frozenset(entries)


def _unpack_document(arr: list) -> Document:
    layers = tuple(_unpack_element(l) for l in arr[0])
    selected_layer = arr[1]
    selection = _unpack_selection(arr[2])
    # Symbols (master store): a trailing element array at index 3. TOLERANT of
    # its absence — existing .bin fixtures predate symbols and decode to an
    # empty store. Present-but-empty arrays decode the same, so empty-symbols
    # docs round-trip unchanged.
    if len(arr) > 3 and isinstance(arr[3], list):
        symbols = tuple(_unpack_element(m) for m in arr[3])
    else:
        symbols = ()
    return Document(layers=layers, symbols=symbols,
                    selected_layer=selected_layer,
                    selection=selection)


# -- Public API --------------------------------------------------------------


def document_to_binary(doc: Document, *, compress: bool = True) -> bytes:
    """Serialize a Document to the JAS binary format.

    Returns bytes: [Magic][Version][Flags][Payload].
    The payload is MessagePack, optionally compressed with raw deflate.
    """
    obj = _pack_document(doc)
    raw = msgpack.packb(obj, use_bin_type=True)

    if compress:
        compressor = zlib.compressobj(zlib.Z_DEFAULT_COMPRESSION,
                                      zlib.DEFLATED, -15)
        payload = compressor.compress(raw) + compressor.flush()
        flags = COMPRESS_DEFLATE
    else:
        payload = raw
        flags = COMPRESS_NONE

    header = MAGIC + struct.pack("<HH", VERSION, flags)
    return header + payload


def binary_to_document(data: bytes) -> Document:
    """Deserialize a Document from the JAS binary format.

    Raises ValueError on invalid magic, unsupported version, or
    unsupported compression method.
    """
    if len(data) < HEADER_SIZE:
        raise ValueError(f"Data too short: {len(data)} bytes, need at least {HEADER_SIZE}")

    magic = data[:4]
    if magic != MAGIC:
        raise ValueError(f"Invalid magic: {magic!r}, expected {MAGIC!r}")

    version = struct.unpack_from("<H", data, 4)[0]
    if version > VERSION:
        raise ValueError(f"Unsupported version: {version}, max supported is {VERSION}")
    if version < MIN_VERSION:
        # v1 used a different positional layout (no generic name/id slots);
        # it is a clean break, not forward-readable. See VERSION comment.
        raise ValueError(
            f"Unsupported legacy version: {version}, min supported is {MIN_VERSION}")

    flags = struct.unpack_from("<H", data, 6)[0]
    compression = flags & 0x03

    payload_bytes = data[HEADER_SIZE:]

    if compression == COMPRESS_NONE:
        pass
    elif compression == COMPRESS_DEFLATE:
        payload_bytes = zlib.decompress(payload_bytes, -15)
    else:
        raise ValueError(f"Unsupported compression method: {compression}")

    try:
        obj = msgpack.unpackb(payload_bytes, raw=False)
    except Exception as e:
        raise ValueError(f"Failed to decode MessagePack payload: {e}") from e

    return dedupe_element_ids(_unpack_document(obj))
