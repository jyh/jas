"""Convert between Document and SVG format.

Internal coordinates are in points (pt). SVG coordinates are in pixels (px).
The conversion factor is 96/72 (CSS px per pt at 96 DPI).
"""

import re
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

from document import Document
from element import (
    ArcTo, Circle, ClosePath, Color, CurveTo, Element, Ellipse, Fill,
    Group, Layer, Line, LineCap, LineJoin, LineTo, MoveTo, Path,
    PathCommand, Polygon, Polyline, QuadTo, Rect, SmoothCurveTo,
    SmoothQuadTo, Stroke, Text, Transform,
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
    r = int(round(c.r * 255))
    g = int(round(c.g * 255))
    b = int(round(c.b * 255))
    if c.a < 1.0:
        return f"rgba({r},{g},{b},{_fmt(c.a)})"
    return f"rgb({r},{g},{b})"


def _fill_attrs(fill: Fill | None) -> str:
    if fill is None:
        return ' fill="none"'
    return f' fill="{_color_str(fill.color)}"'


def _stroke_attrs(stroke: Stroke | None) -> str:
    if stroke is None:
        return ' stroke="none"'
    parts = [f' stroke="{_color_str(stroke.color)}"']
    parts.append(f' stroke-width="{_fmt(_px(stroke.width))}"')
    if stroke.linecap != LineCap.BUTT:
        parts.append(f' stroke-linecap="{stroke.linecap.value}"')
    if stroke.linejoin != LineJoin.MITER:
        parts.append(f' stroke-linejoin="{stroke.linejoin.value}"')
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

        case Text(x=x, y=y, content=content, font_family=ff, font_size=fs,
                  fill=fill, stroke=stroke, opacity=opacity, transform=transform):
            return (f'{indent}<text x="{_fmt(_px(x))}" y="{_fmt(_px(y))}"'
                    f' font-family="{escape(ff)}" font-size="{_fmt(_px(fs))}"'
                    f'{_fill_attrs(fill)}{_stroke_attrs(stroke)}'
                    f'{_opacity_attr(opacity)}{_transform_attr(transform)}>'
                    f'{escape(content)}</text>')

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


def _parse_color(s: str) -> Color | None:
    """Parse rgb(r,g,b) or rgba(r,g,b,a) or 'none'."""
    s = s.strip()
    if s == "none":
        return None
    m = re.match(r"rgba?\(([^)]+)\)", s)
    if m:
        parts = m.group(1).split(",")
        r = int(parts[0].strip()) / 255.0
        g = int(parts[1].strip()) / 255.0
        b = int(parts[2].strip()) / 255.0
        a = float(parts[3].strip()) if len(parts) > 3 else 1.0
        return Color(r, g, b, a)
    return None


def _parse_fill(node: ET.Element) -> Fill | None:
    val = node.get("fill")
    if val is None or val == "none":
        return None
    c = _parse_color(val)
    return Fill(c) if c else None


def _parse_stroke(node: ET.Element) -> Stroke | None:
    val = node.get("stroke")
    if val is None or val == "none":
        return None
    c = _parse_color(val)
    if c is None:
        return None
    width = float(node.get("stroke-width", "1")) * _PX_TO_PT
    lc_str = node.get("stroke-linecap", "butt")
    lj_str = node.get("stroke-linejoin", "miter")
    lc = {"butt": LineCap.BUTT, "round": LineCap.ROUND, "square": LineCap.SQUARE}.get(lc_str, LineCap.BUTT)
    lj = {"miter": LineJoin.MITER, "round": LineJoin.ROUND, "bevel": LineJoin.BEVEL}.get(lj_str, LineJoin.MITER)
    return Stroke(c, width, lc, lj)


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
    return float(node.get("opacity", "1"))


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
    """Parse an SVG path d attribute into PathCommands (absolute only)."""
    tokens = _PATH_CMD_RE.findall(d)
    commands: list[PathCommand] = []
    i = 0

    def _next_num() -> float:
        nonlocal i
        while i < len(tokens) and tokens[i][0]:
            i += 1
        if i >= len(tokens):
            raise ValueError("unexpected end of path data")
        v = float(tokens[i][1])
        i += 1
        return v

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
        elif cmd == "M":
            commands.append(MoveTo(_pt(_next_num()), _pt(_next_num())))
        elif cmd == "L":
            commands.append(LineTo(_pt(_next_num()), _pt(_next_num())))
        elif cmd == "C":
            x1, y1 = _pt(_next_num()), _pt(_next_num())
            x2, y2 = _pt(_next_num()), _pt(_next_num())
            x, y = _pt(_next_num()), _pt(_next_num())
            commands.append(CurveTo(x1, y1, x2, y2, x, y))
        elif cmd == "S":
            x2, y2 = _pt(_next_num()), _pt(_next_num())
            x, y = _pt(_next_num()), _pt(_next_num())
            commands.append(SmoothCurveTo(x2, y2, x, y))
        elif cmd == "Q":
            x1, y1 = _pt(_next_num()), _pt(_next_num())
            x, y = _pt(_next_num()), _pt(_next_num())
            commands.append(QuadTo(x1, y1, x, y))
        elif cmd == "T":
            commands.append(SmoothQuadTo(_pt(_next_num()), _pt(_next_num())))
        elif cmd == "A":
            rx, ry = _pt(_next_num()), _pt(_next_num())
            rotation = _next_num()
            large_arc = _next_num() != 0
            sweep = _next_num() != 0
            x, y = _pt(_next_num()), _pt(_next_num())
            commands.append(ArcTo(rx, ry, rotation, large_arc, sweep, x, y))
        else:
            i += 1  # skip unsupported commands

    return tuple(commands)


_SVG_NS = "http://www.w3.org/2000/svg"
_INKSCAPE_NS = "http://www.inkscape.org/namespaces/inkscape"


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
            x1=_pt(float(node.get("x1", "0"))),
            y1=_pt(float(node.get("y1", "0"))),
            x2=_pt(float(node.get("x2", "0"))),
            y2=_pt(float(node.get("y2", "0"))),
            stroke=stroke, opacity=opacity, transform=transform)

    if tag == "rect":
        return Rect(
            x=_pt(float(node.get("x", "0"))),
            y=_pt(float(node.get("y", "0"))),
            width=_pt(float(node.get("width", "0"))),
            height=_pt(float(node.get("height", "0"))),
            rx=_pt(float(node.get("rx", "0"))),
            ry=_pt(float(node.get("ry", "0"))),
            fill=fill, stroke=stroke, opacity=opacity, transform=transform)

    if tag == "circle":
        return Circle(
            cx=_pt(float(node.get("cx", "0"))),
            cy=_pt(float(node.get("cy", "0"))),
            r=_pt(float(node.get("r", "0"))),
            fill=fill, stroke=stroke, opacity=opacity, transform=transform)

    if tag == "ellipse":
        return Ellipse(
            cx=_pt(float(node.get("cx", "0"))),
            cy=_pt(float(node.get("cy", "0"))),
            rx=_pt(float(node.get("rx", "0"))),
            ry=_pt(float(node.get("ry", "0"))),
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
        content = node.text or ""
        ff = node.get("font-family", "sans-serif")
        fs = _pt(float(node.get("font-size", "16")))
        return Text(
            x=_pt(float(node.get("x", "0"))),
            y=_pt(float(node.get("y", "0"))),
            content=content, font_family=ff, font_size=fs,
            fill=fill, stroke=stroke, opacity=opacity, transform=transform)

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
    """Parse an SVG string and return a Document."""
    root = ET.fromstring(svg)
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
    return Document(layers=tuple(layers))
