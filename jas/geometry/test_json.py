"""Canonical Test JSON serialization for cross-language equivalence testing.

See CROSS_LANGUAGE_TESTING.md at the repository root for the full
specification.  Every semantic document value has exactly one JSON
string representation, so byte-for-byte comparison of the output is a
valid equivalence check.
"""

import json
import math

from document.document import (
    Document, ElementSelection, SortedCps,
    _SelectionAll, _SelectionPartial,
)
from geometry.element import (
    Element, Line, Rect, Circle, Ellipse, Polyline, Polygon,
    Path, Text, TextPath, Group, Layer,
    Color, RgbColor, HsbColor, CmykColor,
    Fill, Stroke, Transform, Visibility,
    LineCap, LineJoin,
    MoveTo, LineTo as LineToCmd, CurveTo, SmoothCurveTo,
    QuadTo, SmoothQuadTo, ArcTo, ClosePath,
)

# ------------------------------------------------------------------ #
# Float formatting                                                    #
# ------------------------------------------------------------------ #

def _fmt(v: float) -> str:
    # Use math.floor(x + 0.5) instead of round() to avoid Python's
    # banker's rounding (round-half-to-even), matching the other languages.
    rounded = math.floor(v * 10000 + 0.5) / 10000
    if rounded == math.trunc(rounded) and rounded % 1 == 0:
        return f"{rounded:.1f}"
    s = f"{rounded:.4f}"
    # Strip trailing zeros but keep at least one digit after decimal.
    while s.endswith("0") and not s.endswith(".0"):
        s = s[:-1]
    return s

# ------------------------------------------------------------------ #
# JSON building helpers                                               #
# ------------------------------------------------------------------ #

class _JsonObj:
    def __init__(self):
        self._entries: list[tuple[str, str]] = []

    def str(self, key: str, v: str):
        escaped = v.replace("\\", "\\\\").replace('"', '\\"')
        self._entries.append((key, f'"{escaped}"'))

    def num(self, key: str, v: float):
        self._entries.append((key, _fmt(v)))

    def int_(self, key: str, v: int):
        self._entries.append((key, str(v)))

    def bool_(self, key: str, v: bool):
        self._entries.append((key, "true" if v else "false"))

    def null(self, key: str):
        self._entries.append((key, "null"))

    def empty_as_null(self, key: str, v: str):
        """Emit an empty string as null, otherwise as a JSON string.
        Matches the canonical-JSON rule that default / omitted
        attributes render as null.
        """
        if v == "":
            self.null(key)
        else:
            self.str(key, v)

    def raw(self, key: str, json: str):
        self._entries.append((key, json))

    def build(self) -> str:
        self._entries.sort(key=lambda e: e[0])
        pairs = [f'"{k}":{v}' for k, v in self._entries]
        return "{" + ",".join(pairs) + "}"


def _json_array(items: list[str]) -> str:
    return "[" + ",".join(items) + "]"


# ------------------------------------------------------------------ #
# Type serializers                                                    #
# ------------------------------------------------------------------ #

def _color_json(c: Color) -> str:
    o = _JsonObj()
    if isinstance(c, RgbColor):
        o.num("a", c.a)
        o.num("b", c.b)
        o.num("g", c.g)
        o.num("r", c.r)
        o.str("space", "rgb")
    elif isinstance(c, HsbColor):
        o.num("a", c.a)
        o.num("b", c.b)
        o.num("h", c.h)
        o.num("s", c.s)
        o.str("space", "hsb")
    elif isinstance(c, CmykColor):
        o.num("a", c.a)
        o.num("c", c.c)
        o.num("k", c.k)
        o.num("m", c.m)
        o.str("space", "cmyk")
        o.num("y", c.y)
    return o.build()


def _fill_json(fill: Fill | None) -> str:
    if fill is None:
        return "null"
    o = _JsonObj()
    o.raw("color", _color_json(fill.color))
    o.num("opacity", fill.opacity)
    return o.build()


def _stroke_json(stroke: Stroke | None) -> str:
    if stroke is None:
        return "null"
    o = _JsonObj()
    o.raw("color", _color_json(stroke.color))
    o.str("linecap", stroke.linecap.value)
    o.str("linejoin", stroke.linejoin.value)
    o.num("opacity", stroke.opacity)
    o.num("width", stroke.width)
    return o.build()


def _transform_json(t: Transform | None) -> str:
    if t is None:
        return "null"
    o = _JsonObj()
    o.num("a", t.a)
    o.num("b", t.b)
    o.num("c", t.c)
    o.num("d", t.d)
    o.num("e", t.e)
    o.num("f", t.f)
    return o.build()


def _visibility_str(v: Visibility) -> str:
    return {
        Visibility.INVISIBLE: "invisible",
        Visibility.OUTLINE: "outline",
        Visibility.PREVIEW: "preview",
    }[v]


def _common_fields(o: _JsonObj, elem: Element):
    o.bool_("locked", elem.locked)
    o.num("opacity", elem.opacity)
    o.raw("transform", _transform_json(elem.transform))
    o.str("visibility", _visibility_str(elem.visibility))


def _text_decoration_array_json(td: str) -> str:
    """Emit ``text_decoration`` as a sorted JSON array of CSS tokens.
    Empty string or ``"none"`` produces ``[]``. Matches Rust's
    canonical form."""
    tokens = sorted({t for t in td.split() if t and t != "none"})
    return "[" + ",".join(f'"{t}"' for t in tokens) + "]"


def _default_tspan_json(content: str) -> str:
    """Emit a single default tspan carrying ``content`` — id 0 and
    every override ``null``. Used to derive the canonical ``tspans``
    array from the flat ``content`` string on emit."""
    o = _JsonObj()
    o.null("baseline_shift")
    o.str("content", content)
    o.null("dx")
    o.null("font_family")
    o.null("font_size")
    o.null("font_style")
    o.null("font_variant")
    o.null("font_weight")
    o._entries.append(("id", "0"))
    o.null("jas_aa_mode")
    o.null("jas_fractional_widths")
    o.null("jas_kerning_mode")
    o.null("jas_no_break")
    o.null("letter_spacing")
    o.null("line_height")
    o.null("rotate")
    o.null("style_name")
    o.null("text_decoration")
    o.null("text_rendering")
    o.null("text_transform")
    o.null("transform")
    o.null("xml_lang")
    return o.build()


def _tspan_json(t) -> str:
    """Emit a full Tspan as a canonical JSON object. Override fields
    that are ``None`` serialize as ``null``. ``text_decoration`` is
    a sorted array of CSS tokens when present."""
    o = _JsonObj()
    o._entries.append(("baseline_shift",
        _null_or_num(t.baseline_shift)))
    o.str("content", t.content)
    o._entries.append(("dx", _null_or_num(t.dx)))
    o._entries.append(("font_family", _null_or_str(t.font_family)))
    o._entries.append(("font_size", _null_or_num(t.font_size)))
    o._entries.append(("font_style", _null_or_str(t.font_style)))
    o._entries.append(("font_variant", _null_or_str(t.font_variant)))
    o._entries.append(("font_weight", _null_or_str(t.font_weight)))
    o._entries.append(("id", str(int(t.id))))
    o._entries.append(("jas_aa_mode", _null_or_str(t.jas_aa_mode)))
    o._entries.append(("jas_fractional_widths", _null_or_bool(t.jas_fractional_widths)))
    o._entries.append(("jas_kerning_mode", _null_or_str(t.jas_kerning_mode)))
    o._entries.append(("jas_no_break", _null_or_bool(t.jas_no_break)))
    o._entries.append(("letter_spacing", _null_or_num(t.letter_spacing)))
    o._entries.append(("line_height", _null_or_num(t.line_height)))
    o._entries.append(("rotate", _null_or_num(t.rotate)))
    o._entries.append(("style_name", _null_or_str(t.style_name)))
    if t.text_decoration is None:
        o.null("text_decoration")
    else:
        members = sorted(t.text_decoration)
        o._entries.append(("text_decoration",
            "[" + ",".join(f'"{m}"' for m in members) + "]"))
    o._entries.append(("text_rendering", _null_or_str(t.text_rendering)))
    o._entries.append(("text_transform", _null_or_str(t.text_transform)))
    o.null("transform")  # transform on tspan omitted for now
    o._entries.append(("xml_lang", _null_or_str(t.xml_lang)))
    return o.build()


def _null_or_num(v):
    return "null" if v is None else _fmt(v)


def _null_or_str(v):
    return "null" if v is None else f'"{v}"'


def _null_or_bool(v):
    return "null" if v is None else ("true" if v else "false")


def _path_command_json(cmd) -> str:
    o = _JsonObj()
    if isinstance(cmd, MoveTo):
        o.str("cmd", "M")
        o.num("x", cmd.x)
        o.num("y", cmd.y)
    elif isinstance(cmd, LineToCmd):
        o.str("cmd", "L")
        o.num("x", cmd.x)
        o.num("y", cmd.y)
    elif isinstance(cmd, CurveTo):
        o.str("cmd", "C")
        o.num("x", cmd.x)
        o.num("x1", cmd.x1)
        o.num("x2", cmd.x2)
        o.num("y", cmd.y)
        o.num("y1", cmd.y1)
        o.num("y2", cmd.y2)
    elif isinstance(cmd, SmoothCurveTo):
        o.str("cmd", "S")
        o.num("x", cmd.x)
        o.num("x2", cmd.x2)
        o.num("y", cmd.y)
        o.num("y2", cmd.y2)
    elif isinstance(cmd, QuadTo):
        o.str("cmd", "Q")
        o.num("x", cmd.x)
        o.num("x1", cmd.x1)
        o.num("y", cmd.y)
        o.num("y1", cmd.y1)
    elif isinstance(cmd, SmoothQuadTo):
        o.str("cmd", "T")
        o.num("x", cmd.x)
        o.num("y", cmd.y)
    elif isinstance(cmd, ArcTo):
        o.str("cmd", "A")
        o.bool_("large_arc", cmd.large_arc)
        o.num("rx", cmd.rx)
        o.num("ry", cmd.ry)
        o.bool_("sweep", cmd.sweep)
        o.num("x", cmd.x)
        o.num("x_rotation", cmd.x_rotation)
        o.num("y", cmd.y)
    elif isinstance(cmd, ClosePath):
        o.str("cmd", "Z")
    return o.build()


def _points_json(points) -> str:
    items = [f"[{_fmt(x)},{_fmt(y)}]" for x, y in points]
    return _json_array(items)


# ------------------------------------------------------------------ #
# Element serializer                                                  #
# ------------------------------------------------------------------ #

def _element_json(elem: Element) -> str:
    o = _JsonObj()
    if isinstance(elem, Layer):
        # Layer must be checked before Group since Layer extends Group.
        o.str("type", "layer")
        _common_fields(o, elem)
        children = [_element_json(c) for c in elem.children]
        o.raw("children", _json_array(children))
        o.str("name", elem.name)
    elif isinstance(elem, Group):
        o.str("type", "group")
        _common_fields(o, elem)
        children = [_element_json(c) for c in elem.children]
        o.raw("children", _json_array(children))
    elif isinstance(elem, Line):
        o.str("type", "line")
        _common_fields(o, elem)
        o.raw("stroke", _stroke_json(elem.stroke))
        o.num("x1", elem.x1)
        o.num("x2", elem.x2)
        o.num("y1", elem.y1)
        o.num("y2", elem.y2)
    elif isinstance(elem, Rect):
        o.str("type", "rect")
        _common_fields(o, elem)
        o.raw("fill", _fill_json(elem.fill))
        o.num("height", elem.height)
        o.num("rx", elem.rx)
        o.num("ry", elem.ry)
        o.raw("stroke", _stroke_json(elem.stroke))
        o.num("width", elem.width)
        o.num("x", elem.x)
        o.num("y", elem.y)
    elif isinstance(elem, Circle):
        o.str("type", "circle")
        _common_fields(o, elem)
        o.num("cx", elem.cx)
        o.num("cy", elem.cy)
        o.raw("fill", _fill_json(elem.fill))
        o.num("r", elem.r)
        o.raw("stroke", _stroke_json(elem.stroke))
    elif isinstance(elem, Ellipse):
        o.str("type", "ellipse")
        _common_fields(o, elem)
        o.num("cx", elem.cx)
        o.num("cy", elem.cy)
        o.raw("fill", _fill_json(elem.fill))
        o.num("rx", elem.rx)
        o.num("ry", elem.ry)
        o.raw("stroke", _stroke_json(elem.stroke))
    elif isinstance(elem, Polyline):
        o.str("type", "polyline")
        _common_fields(o, elem)
        o.raw("fill", _fill_json(elem.fill))
        o.raw("points", _points_json(elem.points))
        o.raw("stroke", _stroke_json(elem.stroke))
    elif isinstance(elem, Polygon):
        o.str("type", "polygon")
        _common_fields(o, elem)
        o.raw("fill", _fill_json(elem.fill))
        o.raw("points", _points_json(elem.points))
        o.raw("stroke", _stroke_json(elem.stroke))
    elif isinstance(elem, Path):
        o.str("type", "path")
        _common_fields(o, elem)
        cmds = [_path_command_json(c) for c in elem.d]
        o.raw("d", _json_array(cmds))
        o.raw("fill", _fill_json(elem.fill))
        o.raw("stroke", _stroke_json(elem.stroke))
    elif isinstance(elem, Text):
        o.str("type", "text")
        _common_fields(o, elem)
        # Extended element-wide attribute slots. Still-null slots are
        # placeholders until Text grows per-element override fields
        # (see TSPAN.md Attribute Home).
        o.empty_as_null("baseline_shift", elem.baseline_shift)
        o.null("dx")
        o.raw("fill", _fill_json(elem.fill))
        o.str("font_family", elem.font_family)
        o.num("font_size", elem.font_size)
        o.str("font_style", elem.font_style)
        o.empty_as_null("font_variant", elem.font_variant)
        o.str("font_weight", elem.font_weight)
        o.num("height", elem.height)
        o.empty_as_null("horizontal_scale", elem.horizontal_scale)
        o.empty_as_null("jas_aa_mode", elem.aa_mode)
        o.null("jas_fractional_widths")
        o.empty_as_null("jas_kerning_mode", elem.kerning)
        o.null("jas_no_break")
        o.empty_as_null("letter_spacing", elem.letter_spacing)
        o.empty_as_null("line_height", elem.line_height)
        o.empty_as_null("rotate", elem.rotate)
        o.raw("stroke", _stroke_json(elem.stroke))
        o.null("style_name")
        o.raw("text_decoration", _text_decoration_array_json(elem.text_decoration))
        o.null("text_rendering")
        o.empty_as_null("text_transform", elem.text_transform)
        o.raw("tspans", _json_array([_tspan_json(t) for t in elem.tspans]))
        o.empty_as_null("vertical_scale", elem.vertical_scale)
        o.num("width", elem.width)
        o.num("x", elem.x)
        o.empty_as_null("xml_lang", elem.xml_lang)
        o.num("y", elem.y)
    elif isinstance(elem, TextPath):
        o.str("type", "text_path")
        _common_fields(o, elem)
        o.empty_as_null("baseline_shift", elem.baseline_shift)
        cmds = [_path_command_json(c) for c in elem.d]
        o.raw("d", _json_array(cmds))
        o.null("dx")
        o.raw("fill", _fill_json(elem.fill))
        o.str("font_family", elem.font_family)
        o.num("font_size", elem.font_size)
        o.str("font_style", elem.font_style)
        o.empty_as_null("font_variant", elem.font_variant)
        o.str("font_weight", elem.font_weight)
        o.empty_as_null("horizontal_scale", elem.horizontal_scale)
        o.empty_as_null("jas_aa_mode", elem.aa_mode)
        o.null("jas_fractional_widths")
        o.empty_as_null("jas_kerning_mode", elem.kerning)
        o.null("jas_no_break")
        o.empty_as_null("letter_spacing", elem.letter_spacing)
        o.empty_as_null("line_height", elem.line_height)
        o.empty_as_null("rotate", elem.rotate)
        o.num("start_offset", elem.start_offset)
        o.raw("stroke", _stroke_json(elem.stroke))
        o.null("style_name")
        o.raw("text_decoration", _text_decoration_array_json(elem.text_decoration))
        o.null("text_rendering")
        o.empty_as_null("text_transform", elem.text_transform)
        o.raw("tspans", _json_array([_tspan_json(t) for t in elem.tspans]))
        o.empty_as_null("vertical_scale", elem.vertical_scale)
        o.empty_as_null("xml_lang", elem.xml_lang)
    return o.build()


# ------------------------------------------------------------------ #
# Selection serializer                                                #
# ------------------------------------------------------------------ #

def _selection_json(sel: frozenset[ElementSelection]) -> str:
    entries = []
    for es in sel:
        o = _JsonObj()
        if isinstance(es.kind, _SelectionAll):
            o.str("kind", "all")
        elif isinstance(es.kind, _SelectionPartial):
            indices = ",".join(str(i) for i in es.kind.cps)
            o.raw("kind", f'{{"partial":[{indices}]}}')
        path = ",".join(str(i) for i in es.path)
        o.raw("path", f"[{path}]")
        entries.append((list(es.path), o.build()))
    # Sort by path lexicographically.
    entries.sort(key=lambda e: e[0])
    items = [json for _, json in entries]
    return _json_array(items)


# ------------------------------------------------------------------ #
# Document serializer (public API)                                    #
# ------------------------------------------------------------------ #

def _artboard_json(ab):
    o = _JsonObj()
    o.str("id", ab.id)
    o.str("name", ab.name)
    o.num("x", ab.x)
    o.num("y", ab.y)
    o.num("width", ab.width)
    o.num("height", ab.height)
    o.str("fill", ab.fill)
    o.bool("show_center_mark", ab.show_center_mark)
    o.bool("show_cross_hairs", ab.show_cross_hairs)
    o.bool("show_video_safe_areas", ab.show_video_safe_areas)
    o.num("video_ruler_pixel_aspect_ratio", ab.video_ruler_pixel_aspect_ratio)
    return o.build()


def _artboards_json(artboards):
    return "[" + ",".join(_artboard_json(a) for a in artboards) + "]"


def _artboard_options_json(opts):
    o = _JsonObj()
    o.bool("fade_region_outside_artboard", opts.fade_region_outside_artboard)
    o.bool("update_while_dragging", opts.update_while_dragging)
    return o.build()


def document_to_test_json(doc: Document) -> str:
    """Serialize a Document to canonical test JSON.

    The output is a compact JSON string with sorted keys and normalized
    floats, suitable for byte-for-byte cross-language comparison.

    Artboards and artboard_options are omitted from the output when
    they carry defaults (empty list, default options) so the byte-for-
    byte contract with legacy fixtures (which predate artboards) still
    holds.
    """
    from document.artboard import ArtboardOptions
    layers = [_element_json(l) for l in doc.layers]
    o = _JsonObj()
    if doc.artboard_options != ArtboardOptions():
        o.raw("artboard_options", _artboard_options_json(doc.artboard_options))
    if len(doc.artboards) > 0:
        o.raw("artboards", _artboards_json(doc.artboards))
    o.raw("layers", _json_array(layers))
    o.int_("selected_layer", doc.selected_layer)
    o.raw("selection", _selection_json(doc.selection))
    return o.build()


# ------------------------------------------------------------------ #
# JSON parser helpers                                                 #
# ------------------------------------------------------------------ #

_LINECAP_MAP = {v.value: v for v in LineCap}
_LINEJOIN_MAP = {v.value: v for v in LineJoin}
_VISIBILITY_MAP = {"invisible": Visibility.INVISIBLE,
                   "outline": Visibility.OUTLINE,
                   "preview": Visibility.PREVIEW}


def _parse_color(d: dict) -> Color:
    space = d.get("space", "rgb")
    if space == "rgb":
        return RgbColor(r=d["r"], g=d["g"], b=d["b"], a=d["a"])
    elif space == "hsb":
        return HsbColor(h=d["h"], s=d["s"], b=d["b"], a=d["a"])
    elif space == "cmyk":
        return CmykColor(c=d["c"], m=d["m"], y=d["y"], k=d["k"], a=d["a"])
    raise ValueError(f"Unknown color space: {space}")


def _parse_fill(d) -> Fill | None:
    if d is None:
        return None
    return Fill(color=_parse_color(d["color"]), opacity=d.get("opacity", 1.0))


def _parse_stroke(d) -> Stroke | None:
    if d is None:
        return None
    return Stroke(
        color=_parse_color(d["color"]),
        width=d["width"],
        linecap=_LINECAP_MAP[d["linecap"]],
        linejoin=_LINEJOIN_MAP[d["linejoin"]],
        opacity=d.get("opacity", 1.0),
    )


def _parse_transform(d) -> Transform | None:
    if d is None:
        return None
    return Transform(a=d["a"], b=d["b"], c=d["c"],
                     d=d["d"], e=d["e"], f=d["f"])


def _parse_common(d: dict) -> dict:
    """Extract the common Element fields shared by all element types."""
    return dict(
        locked=d["locked"],
        opacity=d["opacity"],
        transform=_parse_transform(d["transform"]),
        visibility=_VISIBILITY_MAP[d["visibility"]],
    )


def _parse_path_command(d: dict):
    """Parse a single path command dict into its PathCommand dataclass."""
    cmd = d["cmd"]
    if cmd == "M":
        return MoveTo(x=d["x"], y=d["y"])
    elif cmd == "L":
        return LineToCmd(x=d["x"], y=d["y"])
    elif cmd == "C":
        return CurveTo(x1=d["x1"], y1=d["y1"], x2=d["x2"], y2=d["y2"],
                        x=d["x"], y=d["y"])
    elif cmd == "S":
        return SmoothCurveTo(x2=d["x2"], y2=d["y2"], x=d["x"], y=d["y"])
    elif cmd == "Q":
        return QuadTo(x1=d["x1"], y1=d["y1"], x=d["x"], y=d["y"])
    elif cmd == "T":
        return SmoothQuadTo(x=d["x"], y=d["y"])
    elif cmd == "A":
        return ArcTo(rx=d["rx"], ry=d["ry"], x_rotation=d["x_rotation"],
                     large_arc=d["large_arc"], sweep=d["sweep"],
                     x=d["x"], y=d["y"])
    elif cmd == "Z":
        return ClosePath()
    raise ValueError(f"Unknown path command: {cmd}")


def _parse_points(lst: list) -> tuple[tuple[float, float], ...]:
    return tuple((p[0], p[1]) for p in lst)


def _parse_content_or_tspans(d: dict) -> str:
    """Parse the Text / TextPath ``content`` field. Accepts the
    canonical ``tspans`` array (concatenates each tspan's content) or
    the legacy ``content: "..."`` string."""
    tspans = d.get("tspans")
    if tspans is not None:
        return "".join(t.get("content", "") for t in tspans)
    return d.get("content", "")


def _parse_tspan(d: dict):
    """Parse a single tspan dict from canonical JSON. Every override
    field is optional; missing / null values stay as None so the
    tspan inherits from the parent Text."""
    from geometry.tspan import Tspan
    from geometry.element import Transform as TransformT
    decor_raw = d.get("text_decoration")
    decor = tuple(decor_raw) if isinstance(decor_raw, list) else None
    tr_raw = d.get("transform")
    if isinstance(tr_raw, dict):
        transform = TransformT(
            a=tr_raw.get("a", 1.0), b=tr_raw.get("b", 0.0),
            c=tr_raw.get("c", 0.0), d=tr_raw.get("d", 1.0),
            e=tr_raw.get("e", 0.0), f=tr_raw.get("f", 0.0))
    else:
        transform = None
    return Tspan(
        id=int(d.get("id", 0)),
        content=d.get("content", ""),
        baseline_shift=d.get("baseline_shift"),
        dx=d.get("dx"),
        font_family=d.get("font_family"),
        font_size=d.get("font_size"),
        font_style=d.get("font_style"),
        font_variant=d.get("font_variant"),
        font_weight=d.get("font_weight"),
        jas_aa_mode=d.get("jas_aa_mode"),
        jas_fractional_widths=d.get("jas_fractional_widths"),
        jas_kerning_mode=d.get("jas_kerning_mode"),
        jas_no_break=d.get("jas_no_break"),
        letter_spacing=d.get("letter_spacing"),
        line_height=d.get("line_height"),
        rotate=d.get("rotate"),
        style_name=d.get("style_name"),
        text_decoration=decor,
        text_rendering=d.get("text_rendering"),
        text_transform=d.get("text_transform"),
        transform=transform,
        xml_lang=d.get("xml_lang"),
    )


def _parse_tspans_field(d: dict):
    """Return a tuple of parsed Tspans when the JSON has a ``tspans``
    array, else ``None`` so the caller can let ``Text.__post_init__``
    derive a single-tspan default from content."""
    tspans = d.get("tspans")
    if tspans is None:
        return None
    return tuple(_parse_tspan(t) for t in tspans)


def _parse_text_decoration_field(v) -> str:
    """Accept the canonical text_decoration shape (a sorted array of
    CSS tokens) or the legacy CSS string. Returns the space-separated
    CSS string the ``Text.text_decoration: str`` field stores."""
    if isinstance(v, list):
        return " ".join(v) if v else "none"
    if isinstance(v, str):
        return v
    return "none"


# ------------------------------------------------------------------ #
# Element parser                                                      #
# ------------------------------------------------------------------ #

def _parse_element(d: dict) -> Element:
    """Parse a JSON dict into an Element."""
    typ = d["type"]
    common = _parse_common(d)

    if typ == "layer":
        children = tuple(_parse_element(c) for c in d["children"])
        return Layer(name=d["name"], children=children, **common)
    elif typ == "group":
        children = tuple(_parse_element(c) for c in d["children"])
        return Group(children=children, **common)
    elif typ == "line":
        return Line(x1=d["x1"], y1=d["y1"], x2=d["x2"], y2=d["y2"],
                    stroke=_parse_stroke(d["stroke"]), **common)
    elif typ == "rect":
        return Rect(x=d["x"], y=d["y"], width=d["width"], height=d["height"],
                    rx=d["rx"], ry=d["ry"],
                    fill=_parse_fill(d["fill"]),
                    stroke=_parse_stroke(d["stroke"]), **common)
    elif typ == "circle":
        return Circle(cx=d["cx"], cy=d["cy"], r=d["r"],
                      fill=_parse_fill(d["fill"]),
                      stroke=_parse_stroke(d["stroke"]), **common)
    elif typ == "ellipse":
        return Ellipse(cx=d["cx"], cy=d["cy"], rx=d["rx"], ry=d["ry"],
                       fill=_parse_fill(d["fill"]),
                       stroke=_parse_stroke(d["stroke"]), **common)
    elif typ == "polyline":
        return Polyline(points=_parse_points(d["points"]),
                        fill=_parse_fill(d["fill"]),
                        stroke=_parse_stroke(d["stroke"]), **common)
    elif typ == "polygon":
        return Polygon(points=_parse_points(d["points"]),
                       fill=_parse_fill(d["fill"]),
                       stroke=_parse_stroke(d["stroke"]), **common)
    elif typ == "path":
        cmds = tuple(_parse_path_command(c) for c in d["d"])
        return Path(d=cmds,
                    fill=_parse_fill(d["fill"]),
                    stroke=_parse_stroke(d["stroke"]), **common)
    elif typ == "text":
        tspans = _parse_tspans_field(d)
        tspans_kw = {"tspans": tspans} if tspans is not None else {}
        return Text(x=d["x"], y=d["y"],
                    content=_parse_content_or_tspans(d),
                    font_family=d["font_family"], font_size=d["font_size"],
                    font_weight=d["font_weight"], font_style=d["font_style"],
                    text_decoration=_parse_text_decoration_field(d.get("text_decoration")),
                    text_transform=d.get("text_transform") or "",
                    font_variant=d.get("font_variant") or "",
                    baseline_shift=d.get("baseline_shift") or "",
                    line_height=d.get("line_height") or "",
                    letter_spacing=d.get("letter_spacing") or "",
                    xml_lang=d.get("xml_lang") or "",
                    aa_mode=d.get("jas_aa_mode") or "",
                    rotate=d.get("rotate") or "",
                    horizontal_scale=d.get("horizontal_scale") or "",
                    vertical_scale=d.get("vertical_scale") or "",
                    kerning=d.get("jas_kerning_mode") or "",
                    width=d["width"], height=d["height"],
                    fill=_parse_fill(d["fill"]),
                    stroke=_parse_stroke(d["stroke"]), **tspans_kw, **common)
    elif typ == "text_path":
        cmds = tuple(_parse_path_command(c) for c in d["d"])
        tspans = _parse_tspans_field(d)
        tspans_kw = {"tspans": tspans} if tspans is not None else {}
        return TextPath(d=cmds,
                        content=_parse_content_or_tspans(d),
                        start_offset=d["start_offset"],
                        font_family=d["font_family"],
                        font_size=d["font_size"],
                        font_weight=d["font_weight"],
                        font_style=d["font_style"],
                        text_decoration=_parse_text_decoration_field(d.get("text_decoration")),
                        text_transform=d.get("text_transform") or "",
                        font_variant=d.get("font_variant") or "",
                        baseline_shift=d.get("baseline_shift") or "",
                        line_height=d.get("line_height") or "",
                        letter_spacing=d.get("letter_spacing") or "",
                        xml_lang=d.get("xml_lang") or "",
                        aa_mode=d.get("jas_aa_mode") or "",
                        rotate=d.get("rotate") or "",
                        horizontal_scale=d.get("horizontal_scale") or "",
                        vertical_scale=d.get("vertical_scale") or "",
                        kerning=d.get("jas_kerning_mode") or "",
                        fill=_parse_fill(d["fill"]),
                        stroke=_parse_stroke(d["stroke"]),
                        **tspans_kw, **common)
    raise ValueError(f"Unknown element type: {typ}")


# ------------------------------------------------------------------ #
# Selection parser                                                    #
# ------------------------------------------------------------------ #

def _parse_selection(lst: list) -> frozenset[ElementSelection]:
    entries: list[ElementSelection] = []
    for item in lst:
        path = tuple(item["path"])
        kind_val = item["kind"]
        if kind_val == "all":
            kind = _SelectionAll()
        else:
            # kind_val is {"partial": [indices...]}
            kind = _SelectionPartial(SortedCps.from_iter(kind_val["partial"]))
        entries.append(ElementSelection(path=path, kind=kind))
    return frozenset(entries)


# ------------------------------------------------------------------ #
# Document parser (public API)                                        #
# ------------------------------------------------------------------ #

def parse_element_json(d: dict) -> Element:
    """Parse a canonical test JSON element dict into an Element."""
    return _parse_element(d)


def _parse_artboard(d: dict):
    from document.artboard import Artboard
    raw_aspect = d.get("video_ruler_pixel_aspect_ratio", 1.0) or 1.0
    return Artboard(
        id=d.get("id", ""),
        name=d.get("name", ""),
        x=float(d.get("x", 0.0)),
        y=float(d.get("y", 0.0)),
        width=float(d.get("width", 0.0)),
        height=float(d.get("height", 0.0)),
        fill=d.get("fill", "transparent"),
        show_center_mark=d.get("show_center_mark", False),
        show_cross_hairs=d.get("show_cross_hairs", False),
        show_video_safe_areas=d.get("show_video_safe_areas", False),
        video_ruler_pixel_aspect_ratio=float(raw_aspect),
    )


def _parse_artboards(v):
    if not isinstance(v, list):
        return ()
    return tuple(_parse_artboard(a) for a in v)


def _parse_artboard_options(v):
    from document.artboard import ArtboardOptions
    if not isinstance(v, dict):
        return ArtboardOptions()
    return ArtboardOptions(
        fade_region_outside_artboard=v.get("fade_region_outside_artboard", True),
        update_while_dragging=v.get("update_while_dragging", True),
    )


def test_json_to_document(json_str: str) -> Document:
    """Parse canonical test JSON into a Document.

    This is the inverse of document_to_test_json: given a JSON string
    produced by the serializer (from any language), reconstruct the
    equivalent Document value.
    """
    d = json.loads(json_str)
    layers = tuple(_parse_element(l) for l in d["layers"])
    selected_layer = d["selected_layer"]
    selection = _parse_selection(d["selection"])
    artboards = _parse_artboards(d.get("artboards", []))
    artboard_options = _parse_artboard_options(d.get("artboard_options", None))
    return Document(layers=layers, selected_layer=selected_layer,
                    selection=selection,
                    artboards=artboards,
                    artboard_options=artboard_options)

# Prevent pytest from collecting this function as a test (the file name
# test_json.py matches pytest's test_*.py pattern).
test_json_to_document.__test__ = False  # type: ignore[attr-defined]
