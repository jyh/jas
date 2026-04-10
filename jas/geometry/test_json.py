"""Canonical Test JSON serialization for cross-language equivalence testing.

See CROSS_LANGUAGE_TESTING.md at the repository root for the full
specification.  Every semantic document value has exactly one JSON
string representation, so byte-for-byte comparison of the output is a
valid equivalence check.
"""

import math

from document.document import (
    Document, ElementSelection, SortedCps,
    _SelectionAll, _SelectionPartial,
)
from geometry.element import (
    Element, Line, Rect, Circle, Ellipse, Polyline, Polygon,
    Path, Text, TextPath, Group, Layer,
    Color, Fill, Stroke, Transform, Visibility,
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
    o.num("a", c.a)
    o.num("b", c.b)
    o.num("g", c.g)
    o.num("r", c.r)
    return o.build()


def _fill_json(fill: Fill | None) -> str:
    if fill is None:
        return "null"
    o = _JsonObj()
    o.raw("color", _color_json(fill.color))
    return o.build()


def _stroke_json(stroke: Stroke | None) -> str:
    if stroke is None:
        return "null"
    o = _JsonObj()
    o.raw("color", _color_json(stroke.color))
    o.str("linecap", stroke.linecap.value)
    o.str("linejoin", stroke.linejoin.value)
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
        o.str("content", elem.content)
        o.raw("fill", _fill_json(elem.fill))
        o.str("font_family", elem.font_family)
        o.num("font_size", elem.font_size)
        o.str("font_style", elem.font_style)
        o.str("font_weight", elem.font_weight)
        o.num("height", elem.height)
        o.raw("stroke", _stroke_json(elem.stroke))
        o.str("text_decoration", elem.text_decoration)
        o.num("width", elem.width)
        o.num("x", elem.x)
        o.num("y", elem.y)
    elif isinstance(elem, TextPath):
        o.str("type", "text_path")
        _common_fields(o, elem)
        o.str("content", elem.content)
        cmds = [_path_command_json(c) for c in elem.d]
        o.raw("d", _json_array(cmds))
        o.raw("fill", _fill_json(elem.fill))
        o.str("font_family", elem.font_family)
        o.num("font_size", elem.font_size)
        o.str("font_style", elem.font_style)
        o.str("font_weight", elem.font_weight)
        o.num("start_offset", elem.start_offset)
        o.raw("stroke", _stroke_json(elem.stroke))
        o.str("text_decoration", elem.text_decoration)
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

def document_to_test_json(doc: Document) -> str:
    """Serialize a Document to canonical test JSON.

    The output is a compact JSON string with sorted keys and normalized
    floats, suitable for byte-for-byte cross-language comparison.
    """
    layers = [_element_json(l) for l in doc.layers]
    o = _JsonObj()
    o.raw("layers", _json_array(layers))
    o.int_("selected_layer", doc.selected_layer)
    o.raw("selection", _selection_json(doc.selection))
    return o.build()
