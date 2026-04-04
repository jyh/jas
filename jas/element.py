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
    """SVG <text> element.

    When width and height are set (> 0), the text wraps within that area
    (area text). Otherwise it is point text (single line).
    """
    x: float
    y: float
    content: str
    font_family: str = "sans-serif"
    font_size: float = 16.0
    width: float = 0.0
    height: float = 0.0
    fill: Fill | None = None
    stroke: Stroke | None = None
    opacity: float = 1.0
    transform: Transform | None = None

    @property
    def is_area_text(self) -> bool:
        return self.width > 0 and self.height > 0

    def bounds(self) -> Tuple[float, float, float, float]:
        if self.is_area_text:
            return (self.x, self.y, self.width, self.height)
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
        case Path(d=d):
            # Map each anchor index to its command index
            new_cmds = list(d)
            anchor_idx = 0
            for ci, cmd in enumerate(d):
                if isinstance(cmd, ClosePath):
                    continue
                if anchor_idx in indices:
                    match cmd:
                        case MoveTo(x, y):
                            new_cmds[ci] = MoveTo(x + dx, y + dy)
                            # Move outgoing handle (x1,y1 of next CurveTo)
                            if ci + 1 < len(d) and isinstance(d[ci + 1], CurveTo):
                                nc = d[ci + 1]
                                new_cmds[ci + 1] = CurveTo(nc.x1 + dx, nc.y1 + dy,
                                                            nc.x2, nc.y2, nc.x, nc.y)
                        case CurveTo(x1, y1, x2, y2, x, y):
                            # Move anchor and incoming handle together
                            new_cmds[ci] = CurveTo(x1, y1, x2 + dx, y2 + dy,
                                                    x + dx, y + dy)
                            # Move outgoing handle (x1,y1 of next CurveTo)
                            if ci + 1 < len(d) and isinstance(d[ci + 1], CurveTo):
                                nc = d[ci + 1]
                                new_cmds[ci + 1] = CurveTo(nc.x1 + dx, nc.y1 + dy,
                                                            nc.x2, nc.y2, nc.x, nc.y)
                        case LineTo(x, y):
                            new_cmds[ci] = LineTo(x + dx, y + dy)
                        case _:
                            pass
                anchor_idx += 1
            return replace(elem, d=tuple(new_cmds))
        case _:
            return elem


def _path_anchor_points(d: tuple[PathCommand, ...]) -> list[tuple[float, float]]:
    """Extract anchor points from path commands."""
    pts: list[tuple[float, float]] = []
    for cmd in d:
        match cmd:
            case MoveTo(x, y):
                pts.append((x, y))
            case LineTo(x, y):
                pts.append((x, y))
            case CurveTo(_, _, _, _, x, y):
                pts.append((x, y))
            case SmoothCurveTo(_, _, x, y):
                pts.append((x, y))
            case QuadTo(_, _, x, y):
                pts.append((x, y))
            case SmoothQuadTo(x, y):
                pts.append((x, y))
            case ArcTo(_, _, _, _, _, x, y):
                pts.append((x, y))
            case ClosePath():
                pass
    return pts


def path_handle_positions(d: tuple[PathCommand, ...],
                          anchor_idx: int
                          ) -> tuple[tuple[float, float] | None,
                                     tuple[float, float] | None]:
    """Return (incoming_handle, outgoing_handle) for a path anchor.

    Returns None for a handle that doesn't exist or coincides with its anchor.
    """
    # Map anchor indices to command indices (skip ClosePath)
    cmd_indices: list[int] = []
    for ci, cmd in enumerate(d):
        if not isinstance(cmd, ClosePath):
            cmd_indices.append(ci)
    if anchor_idx < 0 or anchor_idx >= len(cmd_indices):
        return (None, None)
    ci = cmd_indices[anchor_idx]
    cmd = d[ci]
    # Anchor position
    match cmd:
        case MoveTo(x, y) | LineTo(x, y):
            ax, ay = x, y
        case CurveTo(_, _, _, _, x, y):
            ax, ay = x, y
        case _:
            return (None, None)
    # Incoming handle: (x2, y2) of this CurveTo
    h_in = None
    if isinstance(cmd, CurveTo):
        if abs(cmd.x2 - ax) > 0.01 or abs(cmd.y2 - ay) > 0.01:
            h_in = (cmd.x2, cmd.y2)
    # Outgoing handle: (x1, y1) of next CurveTo
    h_out = None
    if ci + 1 < len(d) and isinstance(d[ci + 1], CurveTo):
        nc = d[ci + 1]
        if abs(nc.x1 - ax) > 0.01 or abs(nc.y1 - ay) > 0.01:
            h_out = (nc.x1, nc.y1)
    return (h_in, h_out)


def _reflect_handle_keep_distance(ax: float, ay: float,
                                  new_hx: float, new_hy: float,
                                  opp_hx: float, opp_hy: float
                                  ) -> tuple[float, float]:
    """Rotate the opposite handle to be collinear with (ax,ay)→(new_hx,new_hy),
    but preserve the opposite handle's original distance from the anchor."""
    import math
    dist_new = math.hypot(new_hx - ax, new_hy - ay)
    dist_opp = math.hypot(opp_hx - ax, opp_hy - ay)
    if dist_new < 1e-6:
        return (opp_hx, opp_hy)
    # Direction from anchor toward moved handle, then negate for opposite
    scale = -dist_opp / dist_new
    return (ax + (new_hx - ax) * scale, ay + (new_hy - ay) * scale)


def move_path_handle(elem: Path, anchor_idx: int, handle_type: str,
                     dx: float, dy: float) -> Path:
    """Move a specific handle ('in' or 'out') of a path anchor by (dx, dy)."""
    d = elem.d
    cmd_indices: list[int] = []
    for ci, cmd in enumerate(d):
        if not isinstance(cmd, ClosePath):
            cmd_indices.append(ci)
    if anchor_idx < 0 or anchor_idx >= len(cmd_indices):
        return elem
    ci = cmd_indices[anchor_idx]
    cmd = d[ci]
    # Get anchor position
    match cmd:
        case MoveTo(x, y) | LineTo(x, y):
            ax, ay = x, y
        case CurveTo(_, _, _, _, x, y):
            ax, ay = x, y
        case _:
            return elem
    new_cmds = list(d)
    if handle_type == 'in':
        if isinstance(cmd, CurveTo):
            new_hx = cmd.x2 + dx
            new_hy = cmd.y2 + dy
            new_cmds[ci] = CurveTo(cmd.x1, cmd.y1,
                                   new_hx, new_hy, cmd.x, cmd.y)
            # Rotate opposite (out) handle to stay collinear, keep its distance
            if ci + 1 < len(d) and isinstance(d[ci + 1], CurveTo):
                nc = d[ci + 1]
                new_cmds[ci + 1] = CurveTo(
                    *_reflect_handle_keep_distance(ax, ay, new_hx, new_hy, nc.x1, nc.y1),
                    nc.x2, nc.y2, nc.x, nc.y)
    elif handle_type == 'out':
        if ci + 1 < len(d) and isinstance(d[ci + 1], CurveTo):
            nc = d[ci + 1]
            new_hx = nc.x1 + dx
            new_hy = nc.y1 + dy
            new_cmds[ci + 1] = CurveTo(new_hx, new_hy,
                                       nc.x2, nc.y2, nc.x, nc.y)
            # Rotate opposite (in) handle to stay collinear, keep its distance
            if isinstance(cmd, CurveTo):
                rx, ry = _reflect_handle_keep_distance(ax, ay, new_hx, new_hy, cmd.x2, cmd.y2)
                new_cmds[ci] = CurveTo(cmd.x1, cmd.y1, rx, ry, cmd.x, cmd.y)
    return replace(elem, d=tuple(new_cmds))


def control_point_count(elem: Element) -> int:
    """Return the number of control points for an element."""
    if isinstance(elem, Line):
        return 2
    if isinstance(elem, (Rect, Circle, Ellipse)):
        return 4
    if isinstance(elem, Polygon):
        return len(elem.points)
    if isinstance(elem, Path):
        return len(_path_anchor_points(elem.d))
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
        case Path(d=d):
            return _path_anchor_points(d)
        case _:
            bx, by, bw, bh = elem.bounds()
            return [(bx, by), (bx + bw, by), (bx + bw, by + bh), (bx, by + bh)]
