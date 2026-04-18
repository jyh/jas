"""Convert between Document and SVG format.

Internal coordinates are in points (pt). SVG coordinates are in pixels (px).
The conversion factor is 96/72 (CSS px per pt at 96 DPI).
"""

import dataclasses
import re
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

from document.document import Document
from geometry.normalize import normalize_document
from geometry.element import (
    APPROX_CHAR_WIDTH_FACTOR,
    ArcTo, Circle, ClosePath, Color, RgbColor, CurveTo, Element, Ellipse, Fill,
    Group, Layer, Line, LineCap, LineJoin, LineTo, MoveTo, Path,
    PathCommand, Polygon, Polyline, QuadTo, Rect, SmoothCurveTo,
    SmoothQuadTo, Stroke, Text, TextPath, Transform,
)

_PT_TO_PX = 96.0 / 72.0


def _px(v: float) -> float:
    """Convert a point value to px."""
    return v * _PT_TO_PX


def _fmt(v: float) -> str:
    """Format a float, stripping trailing zeros."""
    s = f"{v:.4f}"
    s = s.rstrip("0").rstrip(".")
    return s


def _color_str(c: Color) -> str:
    r_val, g_val, b_val, a_val = c.to_rgba()
    r = int(round(r_val * 255))
    g = int(round(g_val * 255))
    b = int(round(b_val * 255))
    if a_val < 1.0:
        return f"rgba({r},{g},{b},{_fmt(a_val)})"
    return f"rgb({r},{g},{b})"


def _fill_attrs(fill: Fill | None) -> str:
    if fill is None:
        return ' fill="none"'
    s = f' fill="{_color_str(fill.color)}"'
    if fill.opacity < 1.0:
        s += f' fill-opacity="{_fmt(fill.opacity)}"'
    return s


def _stroke_attrs(stroke: Stroke | None) -> str:
    if stroke is None:
        return ' stroke="none"'
    parts = [f' stroke="{_color_str(stroke.color)}"']
    parts.append(f' stroke-width="{_fmt(_px(stroke.width))}"')
    if stroke.linecap != LineCap.BUTT:
        parts.append(f' stroke-linecap="{stroke.linecap.value}"')
    if stroke.linejoin != LineJoin.MITER:
        parts.append(f' stroke-linejoin="{stroke.linejoin.value}"')
    if stroke.opacity < 1.0:
        parts.append(f' stroke-opacity="{_fmt(stroke.opacity)}"')
    return "".join(parts)


def _transform_attr(t: Transform | None) -> str:
    if t is None:
        return ""
    # Scale the translation components to px
    return (f' transform="matrix({_fmt(t.a)},{_fmt(t.b)},{_fmt(t.c)},'
            f'{_fmt(t.d)},{_fmt(_px(t.e))},{_fmt(_px(t.f))})"')


def _opacity_attr(opacity: float) -> str:
    if opacity >= 1.0:
        return ""
    return f' opacity="{_fmt(opacity)}"'


def _tspan_svg(t) -> str:
    """Emit a single Tspan as an SVG ``<tspan ...>content</tspan>``.
    Only overridden attributes are emitted (inherited values are absent).
    Matches the Rust / Swift / OCaml ``tspan_svg`` — the 5 attributes
    that round-trip natively via SVG: font-family, font-size,
    font-weight, font-style, text-decoration.
    """
    attrs = ""
    if t.font_family is not None:
        attrs += f' font-family="{escape(t.font_family)}"'
    if t.font_size is not None:
        attrs += f' font-size="{_fmt(_px(t.font_size))}"'
    if t.font_weight is not None:
        attrs += f' font-weight="{escape(t.font_weight)}"'
    if t.font_style is not None:
        attrs += f' font-style="{escape(t.font_style)}"'
    if t.text_decoration is not None and t.text_decoration:
        joined = " ".join(t.text_decoration)
        attrs += f' text-decoration="{escape(joined)}"'
    return f"<tspan{attrs}>{escape(t.content)}</tspan>"


def _text_extra_attrs(elem) -> str:
    """Build the attribute-string fragment for the 11 Character-panel
    attributes on a ``<text>`` element. Emits each attribute only
    when non-empty (per CHARACTER.md's identity-omission rule).
    """
    def attr(name: str, v: str) -> str:
        return f' {name}="{escape(v)}"' if v else ""
    return "".join([
        attr("text-transform", elem.text_transform),
        attr("font-variant", elem.font_variant),
        attr("baseline-shift", elem.baseline_shift),
        attr("line-height", elem.line_height),
        attr("letter-spacing", elem.letter_spacing),
        attr("xml:lang", elem.xml_lang),
        attr("urn:jas:1:aa-mode", elem.aa_mode),
        attr("rotate", elem.rotate),
        attr("horizontal-scale", elem.horizontal_scale),
        attr("vertical-scale", elem.vertical_scale),
        attr("urn:jas:1:kerning-mode", elem.kerning),
    ])


def _path_data(commands: tuple[PathCommand, ...]) -> str:
    parts: list[str] = []
    for cmd in commands:
        match cmd:
            case MoveTo(x, y):
                parts.append(f"M{_fmt(_px(x))},{_fmt(_px(y))}")
            case LineTo(x, y):
                parts.append(f"L{_fmt(_px(x))},{_fmt(_px(y))}")
            case CurveTo(x1, y1, x2, y2, x, y):
                parts.append(f"C{_fmt(_px(x1))},{_fmt(_px(y1))} "
                             f"{_fmt(_px(x2))},{_fmt(_px(y2))} "
                             f"{_fmt(_px(x, ))},{_fmt(_px(y))}")
            case SmoothCurveTo(x2, y2, x, y):
                parts.append(f"S{_fmt(_px(x2))},{_fmt(_px(y2))} "
                             f"{_fmt(_px(x))},{_fmt(_px(y))}")
            case QuadTo(x1, y1, x, y):
                parts.append(f"Q{_fmt(_px(x1))},{_fmt(_px(y1))} "
                             f"{_fmt(_px(x))},{_fmt(_px(y))}")
            case SmoothQuadTo(x, y):
                parts.append(f"T{_fmt(_px(x))},{_fmt(_px(y))}")
            case ArcTo(rx, ry, rotation, large_arc, sweep, x, y):
                la = 1 if large_arc else 0
                sw = 1 if sweep else 0
                parts.append(f"A{_fmt(_px(rx))},{_fmt(_px(ry))} "
                             f"{_fmt(rotation)} {la},{sw} "
                             f"{_fmt(_px(x))},{_fmt(_px(y))}")
            case ClosePath():
                parts.append("Z")
    return " ".join(parts)


def element_svg(elem: Element, indent: str = "") -> str:
    """Public: Render a single element as an SVG fragment (recursive for groups/layers)."""
    return _element_svg(elem, indent)


def _element_svg(elem: Element, indent: str) -> str:
    """Render an element as SVG XML."""
    match elem:
        case Line(x1=x1, y1=y1, x2=x2, y2=y2,
                  stroke=stroke, opacity=opacity, transform=transform):
            return (f'{indent}<line x1="{_fmt(_px(x1))}" y1="{_fmt(_px(y1))}"'
                    f' x2="{_fmt(_px(x2))}" y2="{_fmt(_px(y2))}"'
                    f'{_stroke_attrs(stroke)}'
                    f'{_opacity_attr(opacity)}{_transform_attr(transform)}/>')

        case Rect(x=x, y=y, width=w, height=h, rx=rx, ry=ry,
                  fill=fill, stroke=stroke, opacity=opacity, transform=transform):
            rxy = ""
            if rx > 0:
                rxy += f' rx="{_fmt(_px(rx))}"'
            if ry > 0:
                rxy += f' ry="{_fmt(_px(ry))}"'
            return (f'{indent}<rect x="{_fmt(_px(x))}" y="{_fmt(_px(y))}"'
                    f' width="{_fmt(_px(w))}" height="{_fmt(_px(h))}"'
                    f'{rxy}'
                    f'{_fill_attrs(fill)}{_stroke_attrs(stroke)}'
                    f'{_opacity_attr(opacity)}{_transform_attr(transform)}/>')

        case Circle(cx=cx, cy=cy, r=r,
                    fill=fill, stroke=stroke, opacity=opacity, transform=transform):
            return (f'{indent}<circle cx="{_fmt(_px(cx))}" cy="{_fmt(_px(cy))}"'
                    f' r="{_fmt(_px(r))}"'
                    f'{_fill_attrs(fill)}{_stroke_attrs(stroke)}'
                    f'{_opacity_attr(opacity)}{_transform_attr(transform)}/>')

        case Ellipse(cx=cx, cy=cy, rx=rx, ry=ry,
                     fill=fill, stroke=stroke, opacity=opacity, transform=transform):
            return (f'{indent}<ellipse cx="{_fmt(_px(cx))}" cy="{_fmt(_px(cy))}"'
                    f' rx="{_fmt(_px(rx))}" ry="{_fmt(_px(ry))}"'
                    f'{_fill_attrs(fill)}{_stroke_attrs(stroke)}'
                    f'{_opacity_attr(opacity)}{_transform_attr(transform)}/>')

        case Polyline(points=pts, fill=fill, stroke=stroke,
                      opacity=opacity, transform=transform):
            ps = " ".join(f"{_fmt(_px(x))},{_fmt(_px(y))}" for x, y in pts)
            return (f'{indent}<polyline points="{ps}"'
                    f'{_fill_attrs(fill)}{_stroke_attrs(stroke)}'
                    f'{_opacity_attr(opacity)}{_transform_attr(transform)}/>')

        case Polygon(points=pts, fill=fill, stroke=stroke,
                     opacity=opacity, transform=transform):
            ps = " ".join(f"{_fmt(_px(x))},{_fmt(_px(y))}" for x, y in pts)
            return (f'{indent}<polygon points="{ps}"'
                    f'{_fill_attrs(fill)}{_stroke_attrs(stroke)}'
                    f'{_opacity_attr(opacity)}{_transform_attr(transform)}/>')

        case Path(d=cmds, fill=fill, stroke=stroke,
                  opacity=opacity, transform=transform):
            return (f'{indent}<path d="{_path_data(cmds)}"'
                    f'{_fill_attrs(fill)}{_stroke_attrs(stroke)}'
                    f'{_opacity_attr(opacity)}{_transform_attr(transform)}/>')

        case TextPath():
            # Destructure via attribute access to avoid an even wider
            # match pattern now that Text/TextPath carry 11 extra
            # character-panel fields.
            elem_tp = elem
            offset_attr = (f' startOffset="{_fmt(elem_tp.start_offset * 100)}%"'
                           if elem_tp.start_offset > 0 else "")
            fw_attr = f' font-weight="{elem_tp.font_weight}"' if elem_tp.font_weight != "normal" else ""
            fst_attr = f' font-style="{elem_tp.font_style}"' if elem_tp.font_style != "normal" else ""
            td_attr = (f' text-decoration="{elem_tp.text_decoration}"'
                       if elem_tp.text_decoration not in ("none", "") else "")
            extra = _text_extra_attrs(elem_tp)
            # Pre-Tspan-compatible emission: a single no-override tspan
            # round-trips as a flat <textPath>content</textPath> (no
            # <tspan> wrapper). Multi-tspan or any override carries
            # xml:space="preserve" so inter-tspan whitespace is byte-
            # stable across round-trips (TSPAN.md SVG serialization).
            tp_is_flat = len(elem_tp.tspans) == 1 and elem_tp.tspans[0].has_no_overrides()
            if tp_is_flat:
                tp_body = escape(elem_tp.content)
                tp_space = ""
            else:
                tp_body = "".join(_tspan_svg(t) for t in elem_tp.tspans)
                tp_space = ' xml:space="preserve"'
            return (f'{indent}<text'
                    f'{_fill_attrs(elem_tp.fill)}{_stroke_attrs(elem_tp.stroke)}'
                    f' font-family="{escape(elem_tp.font_family)}"'
                    f' font-size="{_fmt(_px(elem_tp.font_size))}"'
                    f'{fw_attr}{fst_attr}{td_attr}{extra}'
                    f'{_opacity_attr(elem_tp.opacity)}{_transform_attr(elem_tp.transform)}>'
                    f'<textPath path="{_path_data(elem_tp.d)}"{offset_attr}{tp_space}>'
                    f'{tp_body}</textPath></text>')

        case Text():
            # See TextPath: attribute-access destructure.
            elem_t = elem
            area_attrs = ""
            if elem_t.width > 0 and elem_t.height > 0:
                area_attrs = (f' style="inline-size: {_fmt(_px(elem_t.width))}px;'
                              f' white-space: pre-wrap;"')
            fw_attr = f' font-weight="{elem_t.font_weight}"' if elem_t.font_weight != "normal" else ""
            fst_attr = f' font-style="{elem_t.font_style}"' if elem_t.font_style != "normal" else ""
            td_attr = (f' text-decoration="{elem_t.text_decoration}"'
                       if elem_t.text_decoration not in ("none", "") else "")
            extra = _text_extra_attrs(elem_t)
            # SVG `y` is the baseline of the first line; internally `y`
            # is the *top* of the layout box, so add the ascent (0.8 *
            # font_size, the same value `text_layout` uses).
            svg_y = elem_t.y + elem_t.font_size * 0.8
            is_flat = len(elem_t.tspans) == 1 and elem_t.tspans[0].has_no_overrides()
            if is_flat:
                body = escape(elem_t.content)
                space_attr = ""
            else:
                body = "".join(_tspan_svg(t) for t in elem_t.tspans)
                space_attr = ' xml:space="preserve"'
            return (f'{indent}<text x="{_fmt(_px(elem_t.x))}" y="{_fmt(_px(svg_y))}"'
                    f' font-family="{escape(elem_t.font_family)}"'
                    f' font-size="{_fmt(_px(elem_t.font_size))}"'
                    f'{fw_attr}{fst_attr}{td_attr}{extra}'
                    f'{area_attrs}'
                    f'{_fill_attrs(elem_t.fill)}{_stroke_attrs(elem_t.stroke)}'
                    f'{_opacity_attr(elem_t.opacity)}{_transform_attr(elem_t.transform)}{space_attr}>'
                    f'{body}</text>')

        case Layer(children=children, name=name, opacity=opacity, transform=transform):
            label = f' inkscape:label="{escape(name)}"' if name else ""
            lines = [f'{indent}<g{label}{_opacity_attr(opacity)}{_transform_attr(transform)}>']
            for child in children:
                lines.append(_element_svg(child, indent + "  "))
            lines.append(f'{indent}</g>')
            return "\n".join(lines)

        case Group(children=children, opacity=opacity, transform=transform):
            lines = [f'{indent}<g{_opacity_attr(opacity)}{_transform_attr(transform)}>']
            for child in children:
                lines.append(_element_svg(child, indent + "  "))
            lines.append(f'{indent}</g>')
            return "\n".join(lines)

    return ""


def document_to_svg(doc: Document) -> str:
    """Convert a Document to an SVG string."""
    bx, by, bw, bh = doc.bounds()
    vb = (f"{_fmt(_px(bx))} {_fmt(_px(by))} "
          f"{_fmt(_px(bw))} {_fmt(_px(bh))}")
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg"'
        f' xmlns:inkscape="{_INKSCAPE_NS}"'
        f' viewBox="{vb}"'
        f' width="{_fmt(_px(bw))}" height="{_fmt(_px(bh))}">',
    ]
    for layer in doc.layers:
        lines.append(_element_svg(layer, "  "))
    lines.append("</svg>")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# SVG Import: parse SVG XML string back to a Document
# ---------------------------------------------------------------------------

_PX_TO_PT = 72.0 / 96.0


def _pt(v: float) -> float:
    """Convert a px value to pt."""
    return v * _PX_TO_PT


def _safe_float(s: str | None, default: float = 0.0) -> float:
    """Parse a string as float, returning default on failure."""
    if s is None:
        return default
    try:
        return float(s)
    except (ValueError, TypeError):
        return default


_NAMED_COLORS: dict[str, tuple[int, int, int]] = {
    "black": (0, 0, 0), "white": (255, 255, 255), "red": (255, 0, 0),
    "green": (0, 128, 0), "blue": (0, 0, 255), "yellow": (255, 255, 0),
    "cyan": (0, 255, 255), "magenta": (255, 0, 255), "gray": (128, 128, 128),
    "grey": (128, 128, 128), "silver": (192, 192, 192), "maroon": (128, 0, 0),
    "olive": (128, 128, 0), "lime": (0, 255, 0), "aqua": (0, 255, 255),
    "teal": (0, 128, 128), "navy": (0, 0, 128), "fuchsia": (255, 0, 255),
    "purple": (128, 0, 128), "orange": (255, 165, 0), "pink": (255, 192, 203),
    "brown": (165, 42, 42), "coral": (255, 127, 80), "crimson": (220, 20, 60),
    "gold": (255, 215, 0), "indigo": (75, 0, 130), "ivory": (255, 255, 240),
    "khaki": (240, 230, 140), "lavender": (230, 230, 250), "plum": (221, 160, 221),
    "salmon": (250, 128, 114), "sienna": (160, 82, 45), "tan": (210, 180, 140),
    "tomato": (255, 99, 71), "turquoise": (64, 224, 208), "violet": (238, 130, 238),
    "wheat": (245, 222, 179), "steelblue": (70, 130, 180), "skyblue": (135, 206, 235),
    "slategray": (112, 128, 144), "slategrey": (112, 128, 144),
    "darkgray": (169, 169, 169), "darkgrey": (169, 169, 169),
    "lightgray": (211, 211, 211), "lightgrey": (211, 211, 211),
    "darkblue": (0, 0, 139), "darkgreen": (0, 100, 0), "darkred": (139, 0, 0),
}


def _parse_color(s: str) -> Color | None:
    """Parse color string: rgb()/rgba(), #RRGGBB, #RGB, named colors, or 'none'."""
    s = s.strip()
    if s == "none":
        return None
    # Named SVG colors
    named = _NAMED_COLORS.get(s.lower())
    if named is not None:
        return RgbColor(named[0] / 255.0, named[1] / 255.0, named[2] / 255.0)
    # Hex colors: #RGB, #RGBA, #RRGGBB, #RRGGBBAA
    if s.startswith("#"):
        h = s[1:]
        if len(h) == 3:
            r = int(h[0] + h[0], 16) / 255.0
            g = int(h[1] + h[1], 16) / 255.0
            b = int(h[2] + h[2], 16) / 255.0
            return RgbColor(r, g, b)
        if len(h) == 4:
            r = int(h[0] + h[0], 16) / 255.0
            g = int(h[1] + h[1], 16) / 255.0
            b = int(h[2] + h[2], 16) / 255.0
            a = int(h[3] + h[3], 16) / 255.0
            return RgbColor(r, g, b, a)
        if len(h) == 6:
            r = int(h[0:2], 16) / 255.0
            g = int(h[2:4], 16) / 255.0
            b = int(h[4:6], 16) / 255.0
            return RgbColor(r, g, b)
        if len(h) == 8:
            r = int(h[0:2], 16) / 255.0
            g = int(h[2:4], 16) / 255.0
            b = int(h[4:6], 16) / 255.0
            a = int(h[6:8], 16) / 255.0
            return RgbColor(r, g, b, a)
        return None
    # rgb()/rgba() functional notation
    m = re.match(r"rgba?\(([^)]+)\)", s)
    if m:
        parts = m.group(1).split(",")
        r = int(parts[0].strip()) / 255.0
        g = int(parts[1].strip()) / 255.0
        b = int(parts[2].strip()) / 255.0
        a = float(parts[3].strip()) if len(parts) > 3 else 1.0
        return RgbColor(r, g, b, a)
    import logging
    logging.warning("Unrecognized SVG color value: %s", s)
    return None


def _parse_fill(node: ET.Element) -> Fill | None:
    val = node.get("fill")
    if val is None or val == "none":
        return None
    c = _parse_color(val)
    if c is None:
        return None
    opacity = _safe_float(node.get("fill-opacity"), 1.0)
    return Fill(c, opacity)


def _parse_stroke(node: ET.Element) -> Stroke | None:
    val = node.get("stroke")
    if val is None or val == "none":
        return None
    c = _parse_color(val)
    if c is None:
        return None
    width = _safe_float(node.get("stroke-width"), 1.0) * _PX_TO_PT
    lc_str = node.get("stroke-linecap", "butt")
    lj_str = node.get("stroke-linejoin", "miter")
    lc = {"butt": LineCap.BUTT, "round": LineCap.ROUND, "square": LineCap.SQUARE}.get(lc_str, LineCap.BUTT)
    lj = {"miter": LineJoin.MITER, "round": LineJoin.ROUND, "bevel": LineJoin.BEVEL}.get(lj_str, LineJoin.MITER)
    opacity = _safe_float(node.get("stroke-opacity"), 1.0)
    return Stroke(c, width, lc, lj, opacity)


def _parse_transform(node: ET.Element) -> Transform | None:
    val = node.get("transform")
    if val is None:
        return None
    m = re.match(r"matrix\(([^)]+)\)", val)
    if m:
        parts = [float(x) for x in m.group(1).split(",")]
        return Transform(a=parts[0], b=parts[1], c=parts[2],
                         d=parts[3], e=_pt(parts[4]), f=_pt(parts[5]))
    m = re.match(r"translate\(([^)]+)\)", val)
    if m:
        parts = [float(x) for x in m.group(1).split(",")]
        ty = parts[1] if len(parts) > 1 else 0.0
        return Transform.translate(_pt(parts[0]), _pt(ty))
    m = re.match(r"rotate\(([^)]+)\)", val)
    if m:
        return Transform.rotate(float(m.group(1)))
    m = re.match(r"scale\(([^)]+)\)", val)
    if m:
        parts = [float(x) for x in m.group(1).split(",")]
        sy = parts[1] if len(parts) > 1 else parts[0]
        return Transform.scale(parts[0], sy)
    return None


def _parse_opacity(node: ET.Element) -> float:
    return _safe_float(node.get("opacity"), 1.0)


def _parse_points(s: str) -> tuple[tuple[float, float], ...]:
    """Parse a points attribute like '0,0 96,0 48,96'."""
    result = []
    for pair in s.strip().split():
        parts = pair.split(",")
        result.append((_pt(float(parts[0])), _pt(float(parts[1]))))
    return tuple(result)


# Path d-attribute tokenizer
_PATH_CMD_RE = re.compile(r"([MmLlHhVvCcSsQqTtAaZz])|([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)")


def _parse_path_d(d: str) -> tuple[PathCommand, ...]:
    """Parse an SVG path d attribute into PathCommands.

    Supports both absolute (uppercase) and relative (lowercase) commands,
    including H/h (horizontal lineto) and V/v (vertical lineto).
    All commands are converted to absolute coordinates.
    """
    tokens = _PATH_CMD_RE.findall(d)
    commands: list[PathCommand] = []
    i = 0
    cur_x = cur_y = 0.0  # current point (in px, before pt conversion)
    start_x = start_y = 0.0  # subpath start (for Z)

    def _next_num() -> float:
        nonlocal i
        while i < len(tokens) and tokens[i][0]:
            i += 1
        if i >= len(tokens):
            raise ValueError("unexpected end of path data")
        v = float(tokens[i][1])
        i += 1
        return v

    def _update(x: float, y: float) -> None:
        nonlocal cur_x, cur_y
        cur_x, cur_y = x, y

    while i < len(tokens):
        cmd_str, num_str = tokens[i]
        if cmd_str:
            cmd = cmd_str
            i += 1
        elif num_str:
            pass  # implicit repeat of previous command
        else:
            i += 1
            continue

        if cmd in ("Z", "z"):
            commands.append(ClosePath())
            cur_x, cur_y = start_x, start_y
        elif cmd == "M":
            x, y = _next_num(), _next_num()
            commands.append(MoveTo(_pt(x), _pt(y)))
            _update(x, y)
            start_x, start_y = x, y
        elif cmd == "m":
            x, y = cur_x + _next_num(), cur_y + _next_num()
            commands.append(MoveTo(_pt(x), _pt(y)))
            _update(x, y)
            start_x, start_y = x, y
        elif cmd == "L":
            x, y = _next_num(), _next_num()
            commands.append(LineTo(_pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "l":
            x, y = cur_x + _next_num(), cur_y + _next_num()
            commands.append(LineTo(_pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "H":
            x = _next_num()
            commands.append(LineTo(_pt(x), _pt(cur_y)))
            cur_x = x
        elif cmd == "h":
            x = cur_x + _next_num()
            commands.append(LineTo(_pt(x), _pt(cur_y)))
            cur_x = x
        elif cmd == "V":
            y = _next_num()
            commands.append(LineTo(_pt(cur_x), _pt(y)))
            cur_y = y
        elif cmd == "v":
            y = cur_y + _next_num()
            commands.append(LineTo(_pt(cur_x), _pt(y)))
            cur_y = y
        elif cmd == "C":
            x1, y1 = _next_num(), _next_num()
            x2, y2 = _next_num(), _next_num()
            x, y = _next_num(), _next_num()
            commands.append(CurveTo(_pt(x1), _pt(y1), _pt(x2), _pt(y2),
                                    _pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "c":
            x1, y1 = cur_x + _next_num(), cur_y + _next_num()
            x2, y2 = cur_x + _next_num(), cur_y + _next_num()
            x, y = cur_x + _next_num(), cur_y + _next_num()
            commands.append(CurveTo(_pt(x1), _pt(y1), _pt(x2), _pt(y2),
                                    _pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "S":
            x2, y2 = _next_num(), _next_num()
            x, y = _next_num(), _next_num()
            commands.append(SmoothCurveTo(_pt(x2), _pt(y2), _pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "s":
            x2, y2 = cur_x + _next_num(), cur_y + _next_num()
            x, y = cur_x + _next_num(), cur_y + _next_num()
            commands.append(SmoothCurveTo(_pt(x2), _pt(y2), _pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "Q":
            x1, y1 = _next_num(), _next_num()
            x, y = _next_num(), _next_num()
            commands.append(QuadTo(_pt(x1), _pt(y1), _pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "q":
            x1, y1 = cur_x + _next_num(), cur_y + _next_num()
            x, y = cur_x + _next_num(), cur_y + _next_num()
            commands.append(QuadTo(_pt(x1), _pt(y1), _pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "T":
            x, y = _next_num(), _next_num()
            commands.append(SmoothQuadTo(_pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "t":
            x, y = cur_x + _next_num(), cur_y + _next_num()
            commands.append(SmoothQuadTo(_pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "A":
            rx, ry = _next_num(), _next_num()
            rotation = _next_num()
            large_arc = _next_num() != 0
            sweep = _next_num() != 0
            x, y = _next_num(), _next_num()
            commands.append(ArcTo(_pt(rx), _pt(ry), rotation, large_arc, sweep,
                                  _pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "a":
            rx, ry = _next_num(), _next_num()
            rotation = _next_num()
            large_arc = _next_num() != 0
            sweep = _next_num() != 0
            x, y = cur_x + _next_num(), cur_y + _next_num()
            commands.append(ArcTo(_pt(rx), _pt(ry), rotation, large_arc, sweep,
                                  _pt(x), _pt(y)))
            _update(x, y)
        else:
            i += 1  # skip unsupported commands

    return tuple(commands)


_SVG_NS = "http://www.w3.org/2000/svg"
_INKSCAPE_NS = "http://www.inkscape.org/namespaces/inkscape"


def _parse_tspan(node, tspan_id: int):
    """Parse an SVG ``<tspan>`` child node into a Tspan. Only attributes
    present on the node become non-None overrides; absent attributes
    remain None (tspan inherits from the parent element). Mirrors the
    Rust / Swift / OCaml ``parse_tspan``.
    """
    from geometry.tspan import Tspan
    content = node.text or ""
    font_family = node.get("font-family")
    fs_str = node.get("font-size")
    font_size = _pt(float(fs_str)) if fs_str else None
    font_weight = node.get("font-weight")
    font_style = node.get("font-style")
    raw_decor = node.get("text-decoration")
    if raw_decor is not None:
        parts = [t for t in raw_decor.split() if t and t != "none"]
        parts.sort()
        decoration: tuple[str, ...] | None = tuple(parts)
    else:
        decoration = None
    return Tspan(
        id=tspan_id, content=content,
        font_family=font_family, font_size=font_size,
        font_style=font_style, font_weight=font_weight,
        text_decoration=decoration,
    )


def _collect_tspan_children(node):
    """Collect ``<tspan>`` children from an ElementTree node, in
    document order. Returns an empty tuple when none are present —
    the caller falls back to flat-content parsing.
    """
    result = []
    next_id = 0
    for child in node:
        if _strip_ns(child.tag) == "tspan":
            result.append(_parse_tspan(child, next_id))
            next_id += 1
    return tuple(result)


def _strip_ns(tag: str) -> str:
    """Strip namespace from an XML tag."""
    if tag.startswith("{"):
        return tag.split("}", 1)[1]
    return tag


def _parse_element(node: ET.Element) -> Element | None:
    """Parse an SVG XML element into a document Element."""
    tag = _strip_ns(node.tag)
    fill = _parse_fill(node)
    stroke = _parse_stroke(node)
    opacity = _parse_opacity(node)
    transform = _parse_transform(node)

    if tag == "line":
        return Line(
            x1=_pt(_safe_float(node.get("x1"))),
            y1=_pt(_safe_float(node.get("y1"))),
            x2=_pt(_safe_float(node.get("x2"))),
            y2=_pt(_safe_float(node.get("y2"))),
            stroke=stroke, opacity=opacity, transform=transform)

    if tag == "rect":
        return Rect(
            x=_pt(_safe_float(node.get("x"))),
            y=_pt(_safe_float(node.get("y"))),
            width=_pt(_safe_float(node.get("width"))),
            height=_pt(_safe_float(node.get("height"))),
            rx=_pt(_safe_float(node.get("rx"))),
            ry=_pt(_safe_float(node.get("ry"))),
            fill=fill, stroke=stroke, opacity=opacity, transform=transform)

    if tag == "circle":
        return Circle(
            cx=_pt(_safe_float(node.get("cx"))),
            cy=_pt(_safe_float(node.get("cy"))),
            r=_pt(_safe_float(node.get("r"))),
            fill=fill, stroke=stroke, opacity=opacity, transform=transform)

    if tag == "ellipse":
        return Ellipse(
            cx=_pt(_safe_float(node.get("cx"))),
            cy=_pt(_safe_float(node.get("cy"))),
            rx=_pt(_safe_float(node.get("rx"))),
            ry=_pt(_safe_float(node.get("ry"))),
            fill=fill, stroke=stroke, opacity=opacity, transform=transform)

    if tag == "polyline":
        pts = _parse_points(node.get("points", ""))
        return Polyline(points=pts, fill=fill, stroke=stroke,
                        opacity=opacity, transform=transform)

    if tag == "polygon":
        pts = _parse_points(node.get("points", ""))
        return Polygon(points=pts, fill=fill, stroke=stroke,
                       opacity=opacity, transform=transform)

    if tag == "path":
        d = _parse_path_d(node.get("d", ""))
        return Path(d=d, fill=fill, stroke=stroke,
                    opacity=opacity, transform=transform)

    if tag == "text":
        ff = node.get("font-family", "sans-serif")
        fs = _pt(_safe_float(node.get("font-size"), 16.0))
        fw = node.get("font-weight", "normal")
        fst = node.get("font-style", "normal")
        td = node.get("text-decoration", "none")
        tt = node.get("text-transform", "")
        fv = node.get("font-variant", "")
        bs = node.get("baseline-shift", "")
        lh = node.get("line-height", "")
        ls = node.get("letter-spacing", "")
        lang = (node.get("{http://www.w3.org/XML/1998/namespace}lang")
                or node.get("xml:lang")
                or node.get("lang")
                or "")
        aa = node.get("urn:jas:1:aa-mode", "")
        rotate = node.get("rotate", "")
        hs = node.get("horizontal-scale", "")
        vs = node.get("vertical-scale", "")
        kern = node.get("urn:jas:1:kerning-mode", "")
        # Check for <textPath> child
        for child in node:
            ctag = _strip_ns(child.tag)
            if ctag == "textPath":
                d_str = child.get("path") or child.get("d") or ""
                d = _parse_path_d(d_str)
                # Prefer <tspan> children inside the <textPath>; fall
                # back to flat string content when none are present.
                tp_tspans = _collect_tspan_children(child)
                tp_content = (
                    "".join(t.content for t in tp_tspans)
                    if tp_tspans else (child.text or "")
                )
                offset_str = child.get("startOffset", "0")
                start_offset = 0.0
                if offset_str.endswith("%"):
                    start_offset = _safe_float(offset_str[:-1]) / 100.0
                else:
                    start_offset = _safe_float(offset_str)
                tp = TextPath(
                    d=d, content=tp_content, start_offset=start_offset,
                    font_family=ff, font_size=fs,
                    font_weight=fw, font_style=fst, text_decoration=td,
                    text_transform=tt, font_variant=fv, baseline_shift=bs,
                    line_height=lh, letter_spacing=ls, xml_lang=lang,
                    aa_mode=aa, rotate=rotate, horizontal_scale=hs,
                    vertical_scale=vs, kerning=kern,
                    fill=fill, stroke=stroke, opacity=opacity, transform=transform)
                if tp_tspans:
                    # Override the seeded-from-content tspans with the
                    # parsed children so per-range overrides survive.
                    tp = dataclasses.replace(tp, tspans=tp_tspans)
                return tp
        tspan_children = _collect_tspan_children(node)
        if tspan_children:
            content = "".join(t.content for t in tspan_children)
        else:
            content = node.text or ""
        tw = 0.0
        style = node.get("style", "")
        if style:
            import re
            m = re.search(r'inline-size:\s*([\d.]+)px', style)
            if m:
                tw = _pt(float(m.group(1)))
        # Estimate height from inline-size and content length
        th = 0.0
        if tw > 0:
            lines = max(1, int(len(content) * fs * APPROX_CHAR_WIDTH_FACTOR / tw) + 1)
            th = lines * fs * 1.2
        # SVG `y` is the baseline of the first line; convert it to the
        # layout-box top by subtracting the ascent (0.8 * fs).
        svg_y = _pt(_safe_float(node.get("y")))
        t = Text(
            x=_pt(_safe_float(node.get("x"))),
            y=svg_y - fs * 0.8,
            content=content, font_family=ff, font_size=fs,
            font_weight=fw, font_style=fst, text_decoration=td,
            text_transform=tt, font_variant=fv, baseline_shift=bs,
            line_height=lh, letter_spacing=ls, xml_lang=lang,
            aa_mode=aa, rotate=rotate, horizontal_scale=hs,
            vertical_scale=vs, kerning=kern,
            width=tw, height=th,
            fill=fill, stroke=stroke, opacity=opacity, transform=transform)
        if tspan_children:
            t = dataclasses.replace(t, tspans=tspan_children)
        return t

    if tag == "g":
        children = []
        for child in node:
            elem = _parse_element(child)
            if elem is not None:
                children.append(elem)
        # Check for inkscape:label to determine Layer vs Group
        label = node.get(f"{{{_INKSCAPE_NS}}}label") or node.get("inkscape:label")
        if label:
            return Layer(children=tuple(children), name=label,
                         opacity=opacity, transform=transform)
        return Group(children=tuple(children),
                     opacity=opacity, transform=transform)

    return None


def svg_to_document(svg: str) -> Document:
    """Parse an SVG string and return a Document.

    Returns an empty document if the SVG is malformed, logging a warning.
    """
    import logging
    try:
        root = ET.fromstring(svg)
    except ET.ParseError as e:
        logging.warning("Failed to parse SVG: %s", e)
        return Document(layers=(Layer(children=()),))
    layers: list[Layer] = []
    for child in root:
        elem = _parse_element(child)
        if elem is None:
            continue
        if isinstance(elem, Layer):
            layers.append(elem)
        elif isinstance(elem, Group):
            # Promote top-level groups to layers
            layers.append(Layer(children=elem.children, name="",
                                opacity=elem.opacity, transform=elem.transform))
        else:
            # Wrap standalone elements in a default layer
            if not layers or layers[-1].name:
                layers.append(Layer(children=(elem,), name=""))
            else:
                layers[-1] = Layer(
                    children=layers[-1].children + (elem,),
                    name="", opacity=layers[-1].opacity,
                    transform=layers[-1].transform)
    if not layers:
        layers = [Layer(children=())]
    return normalize_document(Document(layers=tuple(layers)))
