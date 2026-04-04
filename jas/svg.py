"""Convert a Document to SVG format.

Internal coordinates are in points (pt). SVG coordinates are in pixels (px).
The conversion factor is 96/72 (CSS px per pt at 96 DPI).
"""

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
        f' viewBox="{vb}"'
        f' width="{_fmt(_px(bw))}" height="{_fmt(_px(bh))}">',
    ]
    for layer in doc.layers:
        lines.append(_element_svg(layer, "  "))
    lines.append("</svg>")
    return "\n".join(lines)
