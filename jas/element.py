"""Immutable document elements conforming to SVG element types.

All elements are immutable value objects. To modify an element, create a new
one with the desired changes. Element types and attributes follow the SVG 1.1
specification.
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from enum import Enum
from typing import Tuple


# SVG presentation attributes

@dataclass(frozen=True)
class Color:
    """RGBA color with components in [0, 1]."""
    r: float
    g: float
    b: float
    a: float = 1.0


class LineCap(Enum):
    """SVG stroke-linecap."""
    BUTT = "butt"
    ROUND = "round"
    SQUARE = "square"


class LineJoin(Enum):
    """SVG stroke-linejoin."""
    MITER = "miter"
    ROUND = "round"
    BEVEL = "bevel"


@dataclass(frozen=True)
class Fill:
    """SVG fill presentation attribute. None means fill='none'."""
    color: Color


@dataclass(frozen=True)
class Stroke:
    """SVG stroke presentation attributes."""
    color: Color
    width: float = 1.0
    linecap: LineCap = LineCap.BUTT
    linejoin: LineJoin = LineJoin.MITER


@dataclass(frozen=True)
class Transform:
    """SVG transform as a 2D affine matrix [a b c d e f].

    Represents the matrix:
        | a c e |
        | b d f |
        | 0 0 1 |
    Default is the identity transform.
    """
    a: float = 1.0
    b: float = 0.0
    c: float = 0.0
    d: float = 1.0
    e: float = 0.0
    f: float = 0.0

    @staticmethod
    def translate(tx: float, ty: float) -> "Transform":
        return Transform(e=tx, f=ty)

    @staticmethod
    def scale(sx: float, sy: float | None = None) -> "Transform":
        if sy is None:
            sy = sx
        return Transform(a=sx, d=sy)

    @staticmethod
    def rotate(angle_deg: float) -> "Transform":
        import math
        rad = math.radians(angle_deg)
        cos_a = math.cos(rad)
        sin_a = math.sin(rad)
        return Transform(a=cos_a, b=sin_a, c=-sin_a, d=cos_a)


# SVG path commands (the 'd' attribute)

@dataclass(frozen=True)
class MoveTo:
    """M x y"""
    x: float
    y: float


@dataclass(frozen=True)
class LineTo:
    """L x y"""
    x: float
    y: float


@dataclass(frozen=True)
class CurveTo:
    """C x1 y1 x2 y2 x y (cubic Bezier)"""
    x1: float
    y1: float
    x2: float
    y2: float
    x: float
    y: float


@dataclass(frozen=True)
class SmoothCurveTo:
    """S x2 y2 x y (smooth cubic Bezier)"""
    x2: float
    y2: float
    x: float
    y: float


@dataclass(frozen=True)
class QuadTo:
    """Q x1 y1 x y (quadratic Bezier)"""
    x1: float
    y1: float
    x: float
    y: float


@dataclass(frozen=True)
class SmoothQuadTo:
    """T x y (smooth quadratic Bezier)"""
    x: float
    y: float


@dataclass(frozen=True)
class ArcTo:
    """A rx ry x-rotation large-arc-flag sweep-flag x y"""
    rx: float
    ry: float
    x_rotation: float
    large_arc: bool
    sweep: bool
    x: float
    y: float


@dataclass(frozen=True)
class ClosePath:
    """Z"""
    pass


# Union type for path commands
PathCommand = MoveTo | LineTo | CurveTo | SmoothCurveTo | QuadTo | SmoothQuadTo | ArcTo | ClosePath


# SVG Elements

class Element(ABC):
    """Abstract base class for all SVG document elements.

    Elements are immutable. All concrete subclasses use frozen dataclasses.
    """

    @abstractmethod
    def bounds(self) -> Tuple[float, float, float, float]:
        """Return the bounding box as (x, y, width, height)."""
        ...


@dataclass(frozen=True)
class Line(Element):
    """SVG <line> element."""
    x1: float
    y1: float
    x2: float
    y2: float
    stroke: Stroke | None = None
    opacity: float = 1.0
    transform: Transform | None = None

    def bounds(self) -> Tuple[float, float, float, float]:
        min_x = min(self.x1, self.x2)
        min_y = min(self.y1, self.y2)
        return (min_x, min_y,
                abs(self.x2 - self.x1), abs(self.y2 - self.y1))


@dataclass(frozen=True)
class Rect(Element):
    """SVG <rect> element."""
    x: float
    y: float
    width: float
    height: float
    rx: float = 0.0
    ry: float = 0.0
    fill: Fill | None = None
    stroke: Stroke | None = None
    opacity: float = 1.0
    transform: Transform | None = None

    def bounds(self) -> Tuple[float, float, float, float]:
        return (self.x, self.y, self.width, self.height)


@dataclass(frozen=True)
class Circle(Element):
    """SVG <circle> element."""
    cx: float
    cy: float
    r: float
    fill: Fill | None = None
    stroke: Stroke | None = None
    opacity: float = 1.0
    transform: Transform | None = None

    def bounds(self) -> Tuple[float, float, float, float]:
        return (self.cx - self.r, self.cy - self.r,
                self.r * 2, self.r * 2)


@dataclass(frozen=True)
class Ellipse(Element):
    """SVG <ellipse> element."""
    cx: float
    cy: float
    rx: float
    ry: float
    fill: Fill | None = None
    stroke: Stroke | None = None
    opacity: float = 1.0
    transform: Transform | None = None

    def bounds(self) -> Tuple[float, float, float, float]:
        return (self.cx - self.rx, self.cy - self.ry,
                self.rx * 2, self.ry * 2)


@dataclass(frozen=True)
class Polyline(Element):
    """SVG <polyline> element (open shape of straight segments)."""
    points: tuple[tuple[float, float], ...]
    fill: Fill | None = None
    stroke: Stroke | None = None
    opacity: float = 1.0
    transform: Transform | None = None

    def bounds(self) -> Tuple[float, float, float, float]:
        if not self.points:
            return (0, 0, 0, 0)
        xs = [p[0] for p in self.points]
        ys = [p[1] for p in self.points]
        min_x, min_y = min(xs), min(ys)
        return (min_x, min_y, max(xs) - min_x, max(ys) - min_y)


@dataclass(frozen=True)
class Polygon(Element):
    """SVG <polygon> element (closed shape of straight segments)."""
    points: tuple[tuple[float, float], ...]
    fill: Fill | None = None
    stroke: Stroke | None = None
    opacity: float = 1.0
    transform: Transform | None = None

    def bounds(self) -> Tuple[float, float, float, float]:
        if not self.points:
            return (0, 0, 0, 0)
        xs = [p[0] for p in self.points]
        ys = [p[1] for p in self.points]
        min_x, min_y = min(xs), min(ys)
        return (min_x, min_y, max(xs) - min_x, max(ys) - min_y)


@dataclass(frozen=True)
class Path(Element):
    """SVG <path> element defined by path commands (the 'd' attribute)."""
    d: tuple[PathCommand, ...]
    fill: Fill | None = None
    stroke: Stroke | None = None
    opacity: float = 1.0
    transform: Transform | None = None

    def bounds(self) -> Tuple[float, float, float, float]:
        """Approximate bounds from command endpoints (ignores control points)."""
        xs: list[float] = []
        ys: list[float] = []
        for cmd in self.d:
            match cmd:
                case MoveTo(x, y) | LineTo(x, y) | SmoothQuadTo(x, y):
                    xs.append(x); ys.append(y)
                case CurveTo(_, _, _, _, x, y) | SmoothCurveTo(_, _, x, y):
                    xs.append(x); ys.append(y)
                case QuadTo(_, _, x, y):
                    xs.append(x); ys.append(y)
                case ArcTo(_, _, _, _, _, x, y):
                    xs.append(x); ys.append(y)
                case ClosePath():
                    pass
        if not xs:
            return (0, 0, 0, 0)
        min_x, min_y = min(xs), min(ys)
        return (min_x, min_y, max(xs) - min_x, max(ys) - min_y)


@dataclass(frozen=True)
class Text(Element):
    """SVG <text> element."""
    x: float
    y: float
    content: str
    font_family: str = "sans-serif"
    font_size: float = 16.0
    fill: Fill | None = None
    stroke: Stroke | None = None
    opacity: float = 1.0
    transform: Transform | None = None

    def bounds(self) -> Tuple[float, float, float, float]:
        # Approximate: actual bounds require font metrics
        approx_width = len(self.content) * self.font_size * 0.6
        return (self.x, self.y - self.font_size, approx_width, self.font_size)


@dataclass(frozen=True)
class Group(Element):
    """SVG <g> element."""
    children: tuple[Element, ...] = ()
    opacity: float = 1.0
    transform: Transform | None = None

    def bounds(self) -> Tuple[float, float, float, float]:
        if not self.children:
            return (0, 0, 0, 0)
        all_bounds = [c.bounds() for c in self.children]
        min_x = min(b[0] for b in all_bounds)
        min_y = min(b[1] for b in all_bounds)
        max_x = max(b[0] + b[2] for b in all_bounds)
        max_y = max(b[1] + b[3] for b in all_bounds)
        return (min_x, min_y, max_x - min_x, max_y - min_y)


@dataclass(frozen=True)
class Layer(Group):
    """A named group (layer) of elements."""
    name: str = "Layer"


def move_control_points(elem: Element, indices: frozenset[int],
                        dx: float, dy: float) -> Element:
    """Return a new element with the specified control points moved by (dx, dy)."""
    from dataclasses import replace
    match elem:
        case Line(x1=x1, y1=y1, x2=x2, y2=y2):
            return replace(elem,
                x1=x1 + dx if 0 in indices else x1,
                y1=y1 + dy if 0 in indices else y1,
                x2=x2 + dx if 1 in indices else x2,
                y2=y2 + dy if 1 in indices else y2)
        case Rect(x=x, y=y, width=w, height=h):
            if indices >= frozenset({0, 1, 2, 3}):
                return replace(elem, x=x + dx, y=y + dy)
            pts = [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
            for i in range(4):
                if i in indices:
                    pts[i] = (pts[i][0] + dx, pts[i][1] + dy)
            return Polygon(points=tuple(pts),
                           fill=elem.fill, stroke=elem.stroke,
                           opacity=elem.opacity, transform=elem.transform)
        case Circle(cx=cx, cy=cy, r=r):
            if indices >= frozenset({0, 1, 2, 3}):
                return replace(elem, cx=cx + dx, cy=cy + dy)
            cps = [(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)]
            for i in range(4):
                if i in indices:
                    cps[i] = (cps[i][0] + dx, cps[i][1] + dy)
            ncx = (cps[1][0] + cps[3][0]) / 2
            ncy = (cps[0][1] + cps[2][1]) / 2
            nr = max(abs(cps[1][0] - ncx), abs(cps[0][1] - ncy))
            return replace(elem, cx=ncx, cy=ncy, r=nr)
        case Ellipse(cx=cx, cy=cy, rx=rx, ry=ry):
            if indices >= frozenset({0, 1, 2, 3}):
                return replace(elem, cx=cx + dx, cy=cy + dy)
            cps = [(cx, cy - ry), (cx + rx, cy), (cx, cy + ry), (cx - rx, cy)]
            for i in range(4):
                if i in indices:
                    cps[i] = (cps[i][0] + dx, cps[i][1] + dy)
            ncx = (cps[1][0] + cps[3][0]) / 2
            ncy = (cps[0][1] + cps[2][1]) / 2
            return replace(elem, cx=ncx, cy=ncy,
                           rx=abs(cps[1][0] - ncx), ry=abs(cps[0][1] - ncy))
        case Polygon(points=pts):
            new_pts = list(pts)
            for i in range(len(new_pts)):
                if i in indices:
                    new_pts[i] = (new_pts[i][0] + dx, new_pts[i][1] + dy)
            return replace(elem, points=tuple(new_pts))
        case _:
            return elem


def control_point_count(elem: Element) -> int:
    """Return the number of control points for an element."""
    if isinstance(elem, Line):
        return 2
    if isinstance(elem, (Rect, Circle, Ellipse)):
        return 4
    if isinstance(elem, Polygon):
        return len(elem.points)
    return 4  # bounding box corners


def control_points(elem: Element) -> list[tuple[float, float]]:
    """Return the (x, y) positions of each control point for an element."""
    match elem:
        case Line(x1=x1, y1=y1, x2=x2, y2=y2):
            return [(x1, y1), (x2, y2)]
        case Rect(x=x, y=y, width=w, height=h):
            return [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
        case Circle(cx=cx, cy=cy, r=r):
            return [(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)]
        case Ellipse(cx=cx, cy=cy, rx=rx, ry=ry):
            return [(cx, cy - ry), (cx + rx, cy), (cx, cy + ry), (cx - rx, cy)]
        case Polygon(points=pts):
            return list(pts)
        case _:
            bx, by, bw, bh = elem.bounds()
            return [(bx, by), (bx + bw, by), (bx + bw, by + bh), (bx, by + bh)]
