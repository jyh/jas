"""Immutable document elements conforming to SVG element types.

All elements are immutable value objects. To modify an element, create a new
one with the desired changes. Element types and attributes follow the SVG 1.1
specification.
"""

from __future__ import annotations

import math
from abc import ABC, abstractmethod
import dataclasses
from dataclasses import dataclass
from enum import Enum


# Geometry constants
FLATTEN_STEPS = 20  # line segments per Bezier curve when flattening paths
APPROX_CHAR_WIDTH_FACTOR = 0.6  # average character width as a fraction of font size

# SVG presentation attributes

class Color:
    """Color with support for RGB, HSB, and CMYK color spaces."""

    @staticmethod
    def rgb(r: float, g: float, b: float, a: float = 1.0) -> "Color":
        return RgbColor(r, g, b, a)

    @staticmethod
    def hsb(h: float, s: float, b: float, a: float = 1.0) -> "Color":
        return HsbColor(h, s, b, a)

    @staticmethod
    def cmyk(c: float, m: float, y: float, k: float, a: float = 1.0) -> "Color":
        return CmykColor(c, m, y, k, a)

    @property
    def alpha(self) -> float:
        return self.a

    def with_alpha(self, a: float) -> "Color":
        """Return a copy of this color with the alpha component replaced."""
        raise NotImplementedError

    def to_rgba(self) -> tuple[float, float, float, float]:
        raise NotImplementedError

    def to_hsba(self) -> tuple[float, float, float, float]:
        raise NotImplementedError

    def to_cmyka(self) -> tuple[float, float, float, float, float]:
        raise NotImplementedError

    def to_hex(self) -> str:
        """Convert to 6-char lowercase hex string (no #)."""
        r, g, b, _a = self.to_rgba()
        ri = max(0, min(255, round(r * 255)))
        gi = max(0, min(255, round(g * 255)))
        bi = max(0, min(255, round(b * 255)))
        return f"{ri:02x}{gi:02x}{bi:02x}"

    @staticmethod
    def from_hex(s: str) -> "Color | None":
        """Parse 6-char hex string (optional # prefix). Returns None on invalid."""
        s = s.lstrip("#")
        if len(s) != 6:
            return None
        try:
            ri = int(s[0:2], 16)
            gi = int(s[2:4], 16)
            bi = int(s[4:6], 16)
        except ValueError:
            return None
        return RgbColor(ri / 255.0, gi / 255.0, bi / 255.0)


@dataclass(frozen=True)
class RgbColor(Color):
    """RGBA color with components in [0, 1]."""
    r: float
    g: float
    b: float
    a: float = 1.0

    def with_alpha(self, a: float) -> "RgbColor":
        return RgbColor(self.r, self.g, self.b, a)

    def to_rgba(self) -> tuple[float, float, float, float]:
        return (self.r, self.g, self.b, self.a)

    def to_hsba(self) -> tuple[float, float, float, float]:
        r, g, b = self.r, self.g, self.b
        max_c = max(r, g, b)
        min_c = min(r, g, b)
        delta = max_c - min_c
        brightness = max_c
        saturation = 0.0 if max_c == 0.0 else delta / max_c
        if delta == 0.0:
            hue = 0.0
        elif max_c == r:
            hue = 60.0 * (((g - b) / delta) % 6.0)
        elif max_c == g:
            hue = 60.0 * (((b - r) / delta) + 2.0)
        else:
            hue = 60.0 * (((r - g) / delta) + 4.0)
        if hue < 0.0:
            hue += 360.0
        return (hue, saturation, brightness, self.a)

    def to_cmyka(self) -> tuple[float, float, float, float, float]:
        r, g, b = self.r, self.g, self.b
        k = 1.0 - max(r, g, b)
        if k >= 1.0:
            return (0.0, 0.0, 0.0, 1.0, self.a)
        c = (1.0 - r - k) / (1.0 - k)
        m = (1.0 - g - k) / (1.0 - k)
        y = (1.0 - b - k) / (1.0 - k)
        return (c, m, y, k, self.a)


@dataclass(frozen=True)
class HsbColor(Color):
    """HSB/HSV color. h in [0, 360), s and b in [0, 1]."""
    h: float
    s: float
    b: float
    a: float = 1.0

    def with_alpha(self, a: float) -> "HsbColor":
        return HsbColor(self.h, self.s, self.b, a)

    def to_rgba(self) -> tuple[float, float, float, float]:
        h, s, v = self.h, self.s, self.b
        if s == 0.0:
            return (v, v, v, self.a)
        hi = int(h / 60.0) % 6
        f = h / 60.0 - int(h / 60.0)
        p = v * (1.0 - s)
        q = v * (1.0 - s * f)
        t = v * (1.0 - s * (1.0 - f))
        if hi == 0:
            r, g, b = v, t, p
        elif hi == 1:
            r, g, b = q, v, p
        elif hi == 2:
            r, g, b = p, v, t
        elif hi == 3:
            r, g, b = p, q, v
        elif hi == 4:
            r, g, b = t, p, v
        else:
            r, g, b = v, p, q
        return (r, g, b, self.a)

    def to_hsba(self) -> tuple[float, float, float, float]:
        return (self.h, self.s, self.b, self.a)

    def to_cmyka(self) -> tuple[float, float, float, float, float]:
        r, g, b, a = self.to_rgba()
        return RgbColor(r, g, b, a).to_cmyka()


@dataclass(frozen=True)
class CmykColor(Color):
    """CMYK color with components in [0, 1]."""
    c: float
    m: float
    y: float
    k: float
    a: float = 1.0

    def with_alpha(self, a: float) -> "CmykColor":
        return CmykColor(self.c, self.m, self.y, self.k, a)

    def to_rgba(self) -> tuple[float, float, float, float]:
        r = (1.0 - self.c) * (1.0 - self.k)
        g = (1.0 - self.m) * (1.0 - self.k)
        b = (1.0 - self.y) * (1.0 - self.k)
        return (r, g, b, self.a)

    def to_hsba(self) -> tuple[float, float, float, float]:
        r, g, b, a = self.to_rgba()
        return RgbColor(r, g, b, a).to_hsba()

    def to_cmyka(self) -> tuple[float, float, float, float, float]:
        return (self.c, self.m, self.y, self.k, self.a)


# Convenience constants
Color.BLACK = RgbColor(0.0, 0.0, 0.0)
Color.WHITE = RgbColor(1.0, 1.0, 1.0)


class Visibility(Enum):
    """Per-element visibility mode.

    Ordered from minimum visibility (INVISIBLE) to maximum (PREVIEW)
    by integer value, so ``min(a, b)`` picks the more restrictive of
    two modes — the rule used to combine an element's own visibility
    with the cap inherited from its parent Group or Layer.

    - PREVIEW: the element is fully drawn.
    - OUTLINE: drawn as a thin black outline (stroke 0, no fill).
      Hit detection ignores fill and stroke width. Text is the single
      exception and still renders as PREVIEW.
    - INVISIBLE: not drawn and not hittable.

    This state is runtime-only — it is not persisted to SVG.
    """
    INVISIBLE = 0
    OUTLINE = 1
    PREVIEW = 2

    def __lt__(self, other: "Visibility") -> bool:
        if not isinstance(other, Visibility):
            return NotImplemented
        return self.value < other.value

    def __le__(self, other: "Visibility") -> bool:
        if not isinstance(other, Visibility):
            return NotImplemented
        return self.value <= other.value


class BlendMode(Enum):
    """Blend mode for compositing an element against its parent layer.

    Values mirror the Opacity panel mode dropdown. Default is ``NORMAL``.
    String values are snake_case for cross-language JSON equivalence
    (match ``opacity.yaml`` mode ids and the BlendMode enum in
    jas_dioxus, JasSwift, jas_ocaml).
    """
    NORMAL       = "normal"
    DARKEN       = "darken"
    MULTIPLY     = "multiply"
    COLOR_BURN   = "color_burn"
    LIGHTEN      = "lighten"
    SCREEN       = "screen"
    COLOR_DODGE  = "color_dodge"
    OVERLAY      = "overlay"
    SOFT_LIGHT   = "soft_light"
    HARD_LIGHT   = "hard_light"
    DIFFERENCE   = "difference"
    EXCLUSION    = "exclusion"
    HUE          = "hue"
    SATURATION   = "saturation"
    COLOR        = "color"
    LUMINOSITY   = "luminosity"


@dataclass(frozen=True)
class Mask:
    """Opacity mask attached to an element. See OPACITY.md § Document model.

    Storage-only in Phase 3a — renderer wiring and the mask UI controls
    (MAKE_MASK_BUTTON, CLIP_CHECKBOX, INVERT_MASK_CHECKBOX, LINK_INDICATOR)
    land in Phase 3b.

    Fields:
      subtree:          artwork whose luminance drives the owning element's alpha.
      clip:             also clip the element to the mask bounds.
      invert:           invert the luminance mapping.
      disabled:         element renders as if no mask were attached; subtree preserved.
      linked:           when true, mask follows element's transform; when false
                        it uses ``unlink_transform`` as its fixed baseline.
      unlink_transform: captured at unlink time; cleared on relink.
    """
    subtree: "Element"
    clip: bool = True
    invert: bool = False
    disabled: bool = False
    linked: bool = True
    unlink_transform: "Transform | None" = None


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


class StrokeAlign(Enum):
    """Stroke alignment relative to the path."""
    CENTER = "center"
    INSIDE = "inside"
    OUTSIDE = "outside"


class Arrowhead(Enum):
    """Arrowhead shape for stroke start/end."""
    NONE = "none"
    SIMPLE_ARROW = "simple_arrow"
    OPEN_ARROW = "open_arrow"
    CLOSED_ARROW = "closed_arrow"
    STEALTH_ARROW = "stealth_arrow"
    BARBED_ARROW = "barbed_arrow"
    HALF_ARROW_UPPER = "half_arrow_upper"
    HALF_ARROW_LOWER = "half_arrow_lower"
    CIRCLE = "circle"
    OPEN_CIRCLE = "open_circle"
    SQUARE = "square"
    OPEN_SQUARE = "open_square"
    DIAMOND = "diamond"
    OPEN_DIAMOND = "open_diamond"
    SLASH = "slash"

    @classmethod
    def from_string(cls, s: str) -> "Arrowhead":
        for member in cls:
            if member.value == s:
                return member
        return cls.NONE

    @property
    def name_str(self) -> str:
        return self.value


class ArrowAlign(Enum):
    """Arrowhead alignment mode."""
    TIP_AT_END = "tip_at_end"
    CENTER_AT_END = "center_at_end"


class GradientType(Enum):
    """Gradient type. See transcripts/GRADIENT.md §Gradient types."""
    LINEAR = "linear"
    RADIAL = "radial"
    FREEFORM = "freeform"


class GradientMethod(Enum):
    """Gradient interpolation / topology method. classic / smooth apply
    to linear/radial; points / lines apply to freeform."""
    CLASSIC = "classic"
    SMOOTH = "smooth"
    POINTS = "points"
    LINES = "lines"


class StrokeSubMode(Enum):
    """Stroke sub-mode: how a gradient on a stroke maps onto the path."""
    WITHIN = "within"
    ALONG = "along"
    ACROSS = "across"


@dataclass(frozen=True)
class GradientStop:
    """A single color stop inside a linear/radial gradient.

    Color is stored as a hex string (e.g. "#rrggbb") to match the wire
    format used by the Rust, Swift, and OCaml ports.
    """
    color: str
    location: float
    opacity: float = 100.0
    midpoint_to_next: float = 50.0


@dataclass(frozen=True)
class GradientNode:
    """A single node of a freeform gradient."""
    x: float
    y: float
    color: str
    opacity: float = 100.0
    spread: float = 25.0


@dataclass(frozen=True)
class Gradient:
    """A gradient value usable as a fill or stroke. See GRADIENT.md
    §Document model."""
    type: GradientType = GradientType.LINEAR
    angle: float = 0.0
    aspect_ratio: float = 100.0
    method: GradientMethod = GradientMethod.CLASSIC
    dither: bool = False
    stroke_sub_mode: StrokeSubMode = StrokeSubMode.WITHIN
    stops: tuple[GradientStop, ...] = ()
    nodes: tuple[GradientNode, ...] = ()

    def to_json(self) -> dict:
        return {
            "type": self.type.value,
            "angle": self.angle,
            "aspect_ratio": self.aspect_ratio,
            "method": self.method.value,
            "dither": self.dither,
            "stroke_sub_mode": self.stroke_sub_mode.value,
            "stops": [
                {
                    "color": s.color,
                    "opacity": s.opacity,
                    "location": s.location,
                    "midpoint_to_next": s.midpoint_to_next,
                }
                for s in self.stops
            ],
            "nodes": [
                {
                    "x": n.x, "y": n.y,
                    "color": n.color, "opacity": n.opacity, "spread": n.spread,
                }
                for n in self.nodes
            ],
        }

    @classmethod
    def from_json(cls, data: dict) -> "Gradient":
        return cls(
            type=GradientType(data.get("type", "linear")),
            angle=float(data.get("angle", 0)),
            aspect_ratio=float(data.get("aspect_ratio", 100)),
            method=GradientMethod(data.get("method", "classic")),
            dither=bool(data.get("dither", False)),
            stroke_sub_mode=StrokeSubMode(data.get("stroke_sub_mode", "within")),
            stops=tuple(
                GradientStop(
                    color=s["color"],
                    location=float(s["location"]),
                    opacity=float(s.get("opacity", 100)),
                    midpoint_to_next=float(s.get("midpoint_to_next", 50)),
                )
                for s in data.get("stops") or []
            ),
            nodes=tuple(
                GradientNode(
                    x=float(n["x"]),
                    y=float(n["y"]),
                    color=n["color"],
                    opacity=float(n.get("opacity", 100)),
                    spread=float(n.get("spread", 25)),
                )
                for n in data.get("nodes") or []
            ),
        )


@dataclass(frozen=True)
class Fill:
    """SVG fill presentation attribute. None means fill='none'."""
    color: Color
    opacity: float = 1.0


@dataclass(frozen=True)
class Stroke:
    """SVG stroke presentation attributes."""
    color: Color
    width: float = 1.0
    linecap: LineCap = LineCap.BUTT
    linejoin: LineJoin = LineJoin.MITER
    opacity: float = 1.0
    miter_limit: float = 10.0
    align: StrokeAlign = StrokeAlign.CENTER
    dash_pattern: tuple[float, ...] = ()
    start_arrow: Arrowhead = Arrowhead.NONE
    end_arrow: Arrowhead = Arrowhead.NONE
    start_arrow_scale: float = 100.0
    end_arrow_scale: float = 100.0
    arrow_align: ArrowAlign = ArrowAlign.TIP_AT_END


@dataclass(frozen=True)
class StrokeWidthPoint:
    """A width control point for variable-width stroke profiles."""
    t: float
    width_left: float
    width_right: float


def profile_to_width_points(profile: str, width: float, flipped: bool) -> tuple[StrokeWidthPoint, ...]:
    """Convert a named profile preset to width control points."""
    hw = width / 2.0
    if profile == "taper_both":
        pts = (StrokeWidthPoint(t=0, width_left=0, width_right=0),
               StrokeWidthPoint(t=0.5, width_left=hw, width_right=hw),
               StrokeWidthPoint(t=1, width_left=0, width_right=0))
    elif profile == "taper_start":
        pts = (StrokeWidthPoint(t=0, width_left=0, width_right=0),
               StrokeWidthPoint(t=1, width_left=hw, width_right=hw))
    elif profile == "taper_end":
        pts = (StrokeWidthPoint(t=0, width_left=hw, width_right=hw),
               StrokeWidthPoint(t=1, width_left=0, width_right=0))
    elif profile == "bulge":
        pts = (StrokeWidthPoint(t=0, width_left=hw, width_right=hw),
               StrokeWidthPoint(t=0.5, width_left=hw * 1.5, width_right=hw * 1.5),
               StrokeWidthPoint(t=1, width_left=hw, width_right=hw))
    elif profile == "pinch":
        pts = (StrokeWidthPoint(t=0, width_left=hw, width_right=hw),
               StrokeWidthPoint(t=0.5, width_left=hw * 0.5, width_right=hw * 0.5),
               StrokeWidthPoint(t=1, width_left=hw, width_right=hw))
    else:
        return ()  # "uniform" or unknown
    if flipped:
        return tuple(StrokeWidthPoint(t=1.0 - p.t, width_left=p.width_left,
                                       width_right=p.width_right)
                     for p in reversed(pts))
    return pts


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
        rad = math.radians(angle_deg)
        cos_a = math.cos(rad)
        sin_a = math.sin(rad)
        return Transform(a=cos_a, b=sin_a, c=-sin_a, d=cos_a)

    def apply_point(self, x: float, y: float) -> tuple[float, float]:
        """Apply this transform to a point."""
        return (self.a * x + self.c * y + self.e,
                self.b * x + self.d * y + self.f)

    def inverse(self) -> Transform | None:
        """Return the inverse transform, or None if the matrix is singular."""
        det = self.a * self.d - self.b * self.c
        if abs(det) < 1e-12:
            return None
        inv_det = 1.0 / det
        return Transform(
            a=self.d * inv_det,
            b=-self.b * inv_det,
            c=-self.c * inv_det,
            d=self.a * inv_det,
            e=(self.c * self.f - self.d * self.e) * inv_det,
            f=(self.b * self.e - self.a * self.f) * inv_det,
        )


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


def _inflate_bounds(bbox: tuple[float, float, float, float],
                    stroke: "Stroke | None") -> tuple[float, float, float, float]:
    """Expand bounding box (x, y, w, h) by half-stroke-width on each side."""
    if stroke is None:
        return bbox
    half = stroke.width / 2.0
    return (bbox[0] - half, bbox[1] - half, bbox[2] + 2 * half, bbox[3] + 2 * half)


# SVG Elements

class Element(ABC):
    """Abstract base class for all SVG document elements.

    Elements are immutable. All concrete subclasses use frozen dataclasses.
    """
    locked: bool

    @abstractmethod
    def bounds(self) -> tuple[float, float, float, float]:
        """Return the bounding box as (x, y, width, height)."""
        ...

    def geometric_bounds(self) -> tuple[float, float, float, float]:
        """Geometric bounding box — bbox of the path / shape geometry
        alone, ignoring stroke width and any fill bleed. Align
        operations read it when Use Preview Bounds is off, the default
        per ALIGN.md §Bounding box selection.

        Default implementation falls back to bounds() — correct for
        text-like variants that carry no stroke. Shape variants
        override to skip stroke inflation.
        """
        return self.bounds()


@dataclass(frozen=True)
class Line(Element):
    """SVG <line> element."""
    x1: float
    y1: float
    x2: float
    y2: float
    stroke: Stroke | None = None
    width_points: tuple[StrokeWidthPoint, ...] = ()
    opacity: float = 1.0
    transform: Transform | None = None
    locked: bool = False
    visibility: Visibility = Visibility.PREVIEW
    blend_mode: BlendMode = BlendMode.NORMAL
    mask: "Mask | None" = None
    stroke_gradient: Gradient | None = None

    def bounds(self) -> tuple[float, float, float, float]:
        min_x = min(self.x1, self.x2)
        min_y = min(self.y1, self.y2)
        return _inflate_bounds(
            (min_x, min_y, abs(self.x2 - self.x1), abs(self.y2 - self.y1)),
            self.stroke)

    def geometric_bounds(self) -> tuple[float, float, float, float]:
        min_x = min(self.x1, self.x2)
        min_y = min(self.y1, self.y2)
        return (min_x, min_y, abs(self.x2 - self.x1), abs(self.y2 - self.y1))


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
    locked: bool = False
    visibility: Visibility = Visibility.PREVIEW
    blend_mode: BlendMode = BlendMode.NORMAL
    mask: "Mask | None" = None
    fill_gradient: Gradient | None = None
    stroke_gradient: Gradient | None = None

    def bounds(self) -> tuple[float, float, float, float]:
        return _inflate_bounds((self.x, self.y, self.width, self.height), self.stroke)

    def geometric_bounds(self) -> tuple[float, float, float, float]:
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
    locked: bool = False
    visibility: Visibility = Visibility.PREVIEW
    blend_mode: BlendMode = BlendMode.NORMAL
    mask: "Mask | None" = None
    fill_gradient: Gradient | None = None
    stroke_gradient: Gradient | None = None

    def bounds(self) -> tuple[float, float, float, float]:
        return _inflate_bounds(
            (self.cx - self.r, self.cy - self.r, self.r * 2, self.r * 2),
            self.stroke)

    def geometric_bounds(self) -> tuple[float, float, float, float]:
        return (self.cx - self.r, self.cy - self.r, self.r * 2, self.r * 2)


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
    locked: bool = False
    visibility: Visibility = Visibility.PREVIEW
    blend_mode: BlendMode = BlendMode.NORMAL
    mask: "Mask | None" = None
    fill_gradient: Gradient | None = None
    stroke_gradient: Gradient | None = None

    def bounds(self) -> tuple[float, float, float, float]:
        return _inflate_bounds(
            (self.cx - self.rx, self.cy - self.ry, self.rx * 2, self.ry * 2),
            self.stroke)

    def geometric_bounds(self) -> tuple[float, float, float, float]:
        return (self.cx - self.rx, self.cy - self.ry, self.rx * 2, self.ry * 2)


@dataclass(frozen=True)
class Polyline(Element):
    """SVG <polyline> element (open shape of straight segments)."""
    points: tuple[tuple[float, float], ...]
    fill: Fill | None = None
    stroke: Stroke | None = None
    opacity: float = 1.0
    transform: Transform | None = None
    locked: bool = False
    visibility: Visibility = Visibility.PREVIEW
    blend_mode: BlendMode = BlendMode.NORMAL
    mask: "Mask | None" = None
    fill_gradient: Gradient | None = None
    stroke_gradient: Gradient | None = None

    def bounds(self) -> tuple[float, float, float, float]:
        if not self.points:
            return (0, 0, 0, 0)
        xs = [p[0] for p in self.points]
        ys = [p[1] for p in self.points]
        min_x, min_y = min(xs), min(ys)
        return _inflate_bounds(
            (min_x, min_y, max(xs) - min_x, max(ys) - min_y), self.stroke)

    def geometric_bounds(self) -> tuple[float, float, float, float]:
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
    locked: bool = False
    visibility: Visibility = Visibility.PREVIEW
    blend_mode: BlendMode = BlendMode.NORMAL
    mask: "Mask | None" = None
    fill_gradient: Gradient | None = None
    stroke_gradient: Gradient | None = None

    def bounds(self) -> tuple[float, float, float, float]:
        if not self.points:
            return (0, 0, 0, 0)
        xs = [p[0] for p in self.points]
        ys = [p[1] for p in self.points]
        min_x, min_y = min(xs), min(ys)
        return _inflate_bounds(
            (min_x, min_y, max(xs) - min_x, max(ys) - min_y), self.stroke)

    def geometric_bounds(self) -> tuple[float, float, float, float]:
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
    width_points: tuple[StrokeWidthPoint, ...] = ()
    opacity: float = 1.0
    transform: Transform | None = None
    locked: bool = False
    visibility: Visibility = Visibility.PREVIEW
    blend_mode: BlendMode = BlendMode.NORMAL
    mask: "Mask | None" = None
    fill_gradient: Gradient | None = None
    stroke_gradient: Gradient | None = None

    def bounds(self) -> tuple[float, float, float, float]:
        return _inflate_bounds(_path_bounds(self.d), self.stroke)

    def geometric_bounds(self) -> tuple[float, float, float, float]:
        return _path_bounds(self.d)


def _cubic_extrema(p0: float, p1: float, p2: float, p3: float) -> list[float]:
    """Return the t-values in (0,1) where a cubic Bezier is at an extremum.

    The derivative of the cubic B(t) = (1-t)^3*p0 + 3(1-t)^2*t*p1 +
    3(1-t)*t^2*p2 + t^3*p3 is a quadratic at^2 + bt + c where:
      a = -3p0 + 9p1 - 9p2 + 3p3
      b =  6p0 - 12p1 + 6p2
      c = -3p0 + 3p1
    """
    a = -3*p0 + 9*p1 - 9*p2 + 3*p3
    b = 6*p0 - 12*p1 + 6*p2
    c = -3*p0 + 3*p1
    ts: list[float] = []
    if abs(a) < 1e-12:
        if abs(b) > 1e-12:
            t = -c / b
            if 0 < t < 1:
                ts.append(t)
    else:
        disc = b*b - 4*a*c
        if disc >= 0:
            sq = math.sqrt(disc)
            for t in ((-b + sq) / (2*a), (-b - sq) / (2*a)):
                if 0 < t < 1:
                    ts.append(t)
    return ts


def _quadratic_extremum(p0: float, p1: float, p2: float) -> list[float]:
    """Return the t-value in (0,1) where a quadratic Bezier is at an extremum."""
    denom = p0 - 2*p1 + p2
    if abs(denom) < 1e-12:
        return []
    t = (p0 - p1) / denom
    return [t] if 0 < t < 1 else []


def _cubic_eval(p0: float, p1: float, p2: float, p3: float, t: float) -> float:
    """Evaluate cubic Bezier at parameter t."""
    u = 1 - t
    return u*u*u*p0 + 3*u*u*t*p1 + 3*u*t*t*p2 + t*t*t*p3


def _quadratic_eval(p0: float, p1: float, p2: float, t: float) -> float:
    """Evaluate quadratic Bezier at parameter t."""
    u = 1 - t
    return u*u*p0 + 2*u*t*p1 + t*t*p2


def _path_bounds(d) -> tuple[float, float, float, float]:
    """Compute tight bounds by finding Bezier extrema."""
    xs: list[float] = []
    ys: list[float] = []
    cx, cy = 0.0, 0.0  # current point
    sx, sy = 0.0, 0.0  # subpath start (for ClosePath)
    prev_x2, prev_y2 = 0.0, 0.0  # previous CurveTo control point (for Smooth)
    prev_cmd = None
    for cmd in d:
        match cmd:
            case MoveTo(x, y):
                xs.append(x); ys.append(y)
                cx, cy = x, y
                sx, sy = x, y
            case LineTo(x, y):
                xs.append(x); ys.append(y)
                cx, cy = x, y
            case CurveTo(x1, y1, x2, y2, x, y):
                # Endpoints
                xs.extend((cx, x)); ys.extend((cy, y))
                # Extrema
                for t in _cubic_extrema(cx, x1, x2, x):
                    xs.append(_cubic_eval(cx, x1, x2, x, t))
                for t in _cubic_extrema(cy, y1, y2, y):
                    ys.append(_cubic_eval(cy, y1, y2, y, t))
                prev_x2, prev_y2 = x2, y2
                cx, cy = x, y
            case SmoothCurveTo(x2, y2, x, y):
                # Reflected control point
                if isinstance(prev_cmd, (CurveTo, SmoothCurveTo)):
                    rx1, ry1 = 2*cx - prev_x2, 2*cy - prev_y2
                else:
                    rx1, ry1 = cx, cy
                xs.extend((cx, x)); ys.extend((cy, y))
                for t in _cubic_extrema(cx, rx1, x2, x):
                    xs.append(_cubic_eval(cx, rx1, x2, x, t))
                for t in _cubic_extrema(cy, ry1, y2, y):
                    ys.append(_cubic_eval(cy, ry1, y2, y, t))
                prev_x2, prev_y2 = x2, y2
                cx, cy = x, y
            case QuadTo(x1, y1, x, y):
                xs.extend((cx, x)); ys.extend((cy, y))
                for t in _quadratic_extremum(cx, x1, x):
                    xs.append(_quadratic_eval(cx, x1, x, t))
                for t in _quadratic_extremum(cy, y1, y):
                    ys.append(_quadratic_eval(cy, y1, y, t))
                cx, cy = x, y
            case SmoothQuadTo(x, y):
                xs.append(x); ys.append(y)
                cx, cy = x, y
            case ArcTo(_, _, _, _, _, x, y):
                # TODO: compute true arc extrema
                xs.append(x); ys.append(y)
                cx, cy = x, y
            case ClosePath():
                cx, cy = sx, sy
        prev_cmd = cmd
    if not xs:
        return (0, 0, 0, 0)
    min_x, min_y = min(xs), min(ys)
    return (min_x, min_y, max(xs) - min_x, max(ys) - min_y)


@dataclass(frozen=True)
class Text(Element):
    """SVG <text> element.

    When width and height are set (> 0), the text wraps within that area
    (area text). Otherwise it is point text (single line).

    The 11 Character-panel attribute fields (``text_transform``,
    ``font_variant``, ``baseline_shift``, ``line_height``,
    ``letter_spacing``, ``xml_lang``, ``aa_mode``, ``rotate``,
    ``horizontal_scale``, ``vertical_scale``, ``kerning``) mirror the
    Rust ``TextElem`` shape. Empty string means "omit / inherit
    default" per CHARACTER.md's identity-omission rule.

    Carries an ordered, non-empty ``tspans`` tuple per TSPAN.md.
    Invariant at construction time: ``concat_content(tspans) ==
    content``; ``__post_init__`` derives a single-tspan tuple from
    ``content`` when the caller omits the field. Record-updates that
    only change ``content`` currently leave ``tspans`` stale — call
    ``sync_tspans_from_content`` when consistency is required.
    """
    x: float
    y: float
    content: str
    font_family: str = "sans-serif"
    font_size: float = 16.0
    font_weight: str = "normal"
    font_style: str = "normal"
    text_decoration: str = "none"
    text_transform: str = ""
    font_variant: str = ""
    baseline_shift: str = ""
    line_height: str = ""
    letter_spacing: str = ""
    xml_lang: str = ""
    aa_mode: str = ""
    rotate: str = ""
    horizontal_scale: str = ""
    vertical_scale: str = ""
    kerning: str = ""
    width: float = 0.0
    height: float = 0.0
    fill: Fill | None = None
    stroke: Stroke | None = None
    opacity: float = 1.0
    transform: Transform | None = None
    locked: bool = False
    visibility: Visibility = Visibility.PREVIEW
    blend_mode: BlendMode = BlendMode.NORMAL
    mask: "Mask | None" = None
    # Sentinel default: an empty tuple means "derive from content in
    # __post_init__". Late-import avoids the geometry.element <->
    # geometry.tspan circular dep.
    tspans: tuple = ()

    def __post_init__(self):
        if not self.tspans:
            from geometry.tspan import tspans_from_content
            object.__setattr__(self, "tspans", tspans_from_content(self.content))

    @property
    def is_area_text(self) -> bool:
        return self.width > 0 and self.height > 0

    def bounds(self) -> tuple[float, float, float, float]:
        if self.is_area_text:
            return (self.x, self.y, self.width, self.height)
        # Treat self.y as the top of the run (matching the in-place
        # editor's rendering of (e.x, e.y) at the layout origin). Width
        # is the widest "\n"-separated line measured with the real font
        # (Qt's QFontMetricsF) so the selection bbox hugs the rendered
        # glyphs instead of a 0.6 * font_size stub. Falls back to the
        # stub if QtGui is unavailable (no DOM / headless test env).
        lines = self.content.split('\n') if self.content else [""]
        try:
            from PySide6.QtGui import QFont, QFontMetricsF
            font = QFont(self.font_family, int(self.font_size))
            if self.font_weight == "bold":
                font.setBold(True)
            if self.font_style == "italic":
                font.setItalic(True)
            fm = QFontMetricsF(font)
            max_width = max((fm.horizontalAdvance(l) for l in lines), default=0.0)
        except (ImportError, RuntimeError):
            max_chars = max((len(l) for l in lines), default=0)
            max_width = max_chars * self.font_size * APPROX_CHAR_WIDTH_FACTOR
        height = len(lines) * self.font_size
        return (self.x, self.y, max_width, height)


@dataclass(frozen=True)
class TextPath(Element):
    """SVG <text><textPath> element — text rendered along a path.

    See ``Text`` for the 11 Character-panel attribute fields and the
    ``tspans`` invariant.
    """
    d: tuple[MoveTo | LineTo | CurveTo | QuadTo | SmoothCurveTo
             | SmoothQuadTo | ArcTo | ClosePath, ...] = ()
    content: str = "Lorem Ipsum"
    start_offset: float = 0.0
    font_family: str = "sans-serif"
    font_size: float = 16.0
    font_weight: str = "normal"
    font_style: str = "normal"
    text_decoration: str = "none"
    text_transform: str = ""
    font_variant: str = ""
    baseline_shift: str = ""
    line_height: str = ""
    letter_spacing: str = ""
    xml_lang: str = ""
    aa_mode: str = ""
    rotate: str = ""
    horizontal_scale: str = ""
    vertical_scale: str = ""
    kerning: str = ""
    fill: Fill | None = None
    stroke: Stroke | None = None
    opacity: float = 1.0
    transform: Transform | None = None
    locked: bool = False
    visibility: Visibility = Visibility.PREVIEW
    blend_mode: BlendMode = BlendMode.NORMAL
    mask: "Mask | None" = None
    tspans: tuple = ()

    def __post_init__(self):
        if not self.tspans:
            from geometry.tspan import tspans_from_content
            object.__setattr__(self, "tspans", tspans_from_content(self.content))

    def bounds(self) -> tuple[float, float, float, float]:
        # Approximate from path bounds
        return _inflate_bounds(_path_bounds(self.d), self.stroke)

    def geometric_bounds(self) -> tuple[float, float, float, float]:
        return _path_bounds(self.d)


@dataclass(frozen=True)
class Group(Element):
    """SVG <g> element."""
    children: tuple[Element, ...] = ()
    opacity: float = 1.0
    transform: Transform | None = None
    locked: bool = False
    visibility: Visibility = Visibility.PREVIEW
    blend_mode: BlendMode = BlendMode.NORMAL
    mask: "Mask | None" = None
    # Opacity panel "Page Isolated Blending" flag. Storage-only in Phase 2;
    # renderer support is deferred. Inherited by Layer.
    isolated_blending: bool = False
    # Opacity panel "Page Knockout Group" flag. Storage-only in Phase 2;
    # renderer support is deferred. Inherited by Layer.
    knockout_group: bool = False

    def bounds(self) -> tuple[float, float, float, float]:
        if not self.children:
            return (0, 0, 0, 0)
        all_bounds = [c.bounds() for c in self.children]
        min_x = min(b[0] for b in all_bounds)
        min_y = min(b[1] for b in all_bounds)
        max_x = max(b[0] + b[2] for b in all_bounds)
        max_y = max(b[1] + b[3] for b in all_bounds)
        return (min_x, min_y, max_x - min_x, max_y - min_y)

    def geometric_bounds(self) -> tuple[float, float, float, float]:
        if not self.children:
            return (0, 0, 0, 0)
        all_bounds = [c.geometric_bounds() for c in self.children]
        min_x = min(b[0] for b in all_bounds)
        min_y = min(b[1] for b in all_bounds)
        max_x = max(b[0] + b[2] for b in all_bounds)
        max_y = max(b[1] + b[3] for b in all_bounds)
        return (min_x, min_y, max_x - min_x, max_y - min_y)


@dataclass(frozen=True)
class Layer(Group):
    """A named group (layer) of elements."""
    name: str = "Layer"


# ─── LiveElement framework ─────────────────────────────────────
# See transcripts/BOOLEAN.md § Live element framework. CompoundShape
# is the first conformer (non-destructive boolean over an operand
# tree). Future Live Effects (drop shadow, blend, ...) add a new
# subclass of LiveElement.

class CompoundOperation(Enum):
    """Which boolean operation a CompoundShape evaluates to. Only
    the four Shape Mode operations can be compound."""
    UNION = "union"
    SUBTRACT_FRONT = "subtract_front"
    INTERSECTION = "intersection"
    EXCLUDE = "exclude"


class LiveElement(Element):
    """Abstract base for non-destructive element kinds that store
    source inputs and evaluate them on demand. Subclasses implement
    ``bounds`` and any kind-specific rendering.

    See BOOLEAN.md § Live element framework.
    """
    pass


@dataclass(frozen=True)
class CompoundShape(LiveElement):
    """A live, non-destructive boolean element: stores the operation
    and its operand tree; evaluates to a polygon set on demand.
    See BOOLEAN.md § Compound shape data model.
    """
    operation: CompoundOperation = CompoundOperation.UNION
    operands: tuple[Element, ...] = ()
    fill: Fill | None = None
    stroke: Stroke | None = None
    opacity: float = 1.0
    transform: Transform | None = None
    locked: bool = False
    visibility: Visibility = Visibility.PREVIEW
    blend_mode: BlendMode = BlendMode.NORMAL
    mask: "Mask | None" = None

    def evaluate(self, precision: float):
        """Flatten operands to polygon sets, apply the boolean
        operation, return the result. Pure — no cache today.
        """
        from geometry.live import apply_operation, element_to_polygon_set
        operand_sets = [
            element_to_polygon_set(op, precision) for op in self.operands
        ]
        return apply_operation(self.operation, operand_sets)

    def bounds(self) -> tuple[float, float, float, float]:
        """Bounding box of the evaluated geometry."""
        from geometry.live import DEFAULT_PRECISION, bounds_of_polygon_set
        return bounds_of_polygon_set(self.evaluate(DEFAULT_PRECISION))

    def expand(self, precision: float) -> list["Element"]:
        """Replace the compound shape with static Polygon element(s)
        derived from its evaluated geometry. Each emitted polygon
        carries the compound shape's own fill / stroke / common
        props; the operand tree is discarded. Rings with fewer than
        3 points are dropped. See BOOLEAN.md § Expand and Release
        semantics.
        """
        ps = self.evaluate(precision)
        return [
            Polygon(
                points=tuple(ring),
                fill=self.fill,
                stroke=self.stroke,
                opacity=self.opacity,
                transform=self.transform,
                locked=self.locked,
                visibility=self.visibility,
            )
            for ring in ps if len(ring) >= 3
        ]

    def release(self) -> tuple["Element", ...]:
        """Return the operand tree as independent elements (inverse
        of Make). Each operand keeps its own paint; the compound
        shape's paint is discarded.
        """
        return self.operands


def sync_tspans_from_content(element: Element) -> Element:
    """Rebuild a Text / TextPath element's ``tspans`` field from its
    ``content`` field. The resulting tuple has a single entry with
    empty overrides (the plain-text base case). Non-Text elements
    pass through unchanged. Mirrors the OCaml / Rust / Swift helpers.
    """
    if not isinstance(element, (Text, TextPath)):
        return element
    from geometry.tspan import tspans_from_content
    return dataclasses.replace(element, tspans=tspans_from_content(element.content))


def with_fill(element: Element, fill: Fill | None) -> Element:
    """Return a copy of element with fill replaced. Line/Group/Layer unchanged."""
    if isinstance(element, (Line, Group)):
        return element
    if hasattr(element, 'fill'):
        return dataclasses.replace(element, fill=fill)
    return element


def with_stroke(element: Element, stroke: Stroke | None) -> Element:
    """Return a copy of element with stroke replaced. Group/Layer unchanged."""
    if isinstance(element, Group):
        return element
    if hasattr(element, 'stroke'):
        return dataclasses.replace(element, stroke=stroke)
    return element


def with_width_points(element: Element, width_points: tuple[StrokeWidthPoint, ...]) -> Element:
    """Return a copy of element with width_points replaced.

    Only Line and Path support width points; others are returned unchanged.
    """
    if isinstance(element, (Line, Path)):
        return dataclasses.replace(element, width_points=width_points)
    return element


def with_mask(element: Element, mask: Mask | None) -> Element:
    """Return a copy of element with its opacity mask replaced.

    Passing ``None`` removes the mask; passing a ``Mask`` sets or replaces it.
    Preserves every other field via ``dataclasses.replace``. Storage-only in
    Phase 3a / 3b; renderer support lands in a later phase.
    """
    return dataclasses.replace(element, mask=mask)


def element_fill(element: Element) -> Fill | None:
    """Return the element's fill, or None if it has no fill field."""
    return getattr(element, 'fill', None)


def element_stroke(element: Element) -> Stroke | None:
    """Return the element's stroke, or None if it has no stroke field."""
    return getattr(element, 'stroke', None)


def move_control_points(elem: Element, kind, dx: float, dy: float) -> Element:
    """Return a new element with the specified control points moved by (dx, dy).

    `kind` is a `SelectionKind` (`.all` or `.partial(SortedCps)`). For
    Rect/Circle/Ellipse, `.all` translates the primitive in place;
    `.partial` (even if it covers every CP) converts to a polygon for
    Rect, since "I selected each CP individually" is a different intent
    than "I selected the element as a whole".

    `.partial(empty)` — "element selected, no CPs highlighted" — is a
    no-op: the element is returned unchanged. Without this guard, the
    Rect/Circle/Ellipse branches would fall through to their polygon-
    conversion path (since ``is_all`` is false for an empty set) and
    silently change the primitive type without any visible movement.
    """
    from dataclasses import replace
    from document.document import (
        _SelectionPartial,
        selection_kind_contains as _contains,
        selection_kind_is_all as _is_all,
    )
    if isinstance(kind, _SelectionPartial) and len(kind.cps) == 0:
        return elem
    match elem:
        case Line(x1=x1, y1=y1, x2=x2, y2=y2):
            return replace(elem,
                x1=x1 + dx if _contains(kind, 0) else x1,
                y1=y1 + dy if _contains(kind, 0) else y1,
                x2=x2 + dx if _contains(kind, 1) else x2,
                y2=y2 + dy if _contains(kind, 1) else y2)
        case Rect(x=x, y=y, width=w, height=h):
            if _is_all(kind, 4):
                return replace(elem, x=x + dx, y=y + dy)
            pts = [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
            for i in range(4):
                if _contains(kind, i):
                    pts[i] = (pts[i][0] + dx, pts[i][1] + dy)
            return Polygon(points=tuple(pts),
                           fill=elem.fill, stroke=elem.stroke,
                           opacity=elem.opacity, transform=elem.transform)
        case Circle(cx=cx, cy=cy, r=r):
            if _is_all(kind, 4):
                return replace(elem, cx=cx + dx, cy=cy + dy)
            cps = [(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)]
            for i in range(4):
                if _contains(kind, i):
                    cps[i] = (cps[i][0] + dx, cps[i][1] + dy)
            ncx = (cps[1][0] + cps[3][0]) / 2
            ncy = (cps[0][1] + cps[2][1]) / 2
            nr = max(abs(cps[1][0] - ncx), abs(cps[0][1] - ncy))
            return replace(elem, cx=ncx, cy=ncy, r=nr)
        case Ellipse(cx=cx, cy=cy, rx=rx, ry=ry):
            if _is_all(kind, 4):
                return replace(elem, cx=cx + dx, cy=cy + dy)
            cps = [(cx, cy - ry), (cx + rx, cy), (cx, cy + ry), (cx - rx, cy)]
            for i in range(4):
                if _contains(kind, i):
                    cps[i] = (cps[i][0] + dx, cps[i][1] + dy)
            ncx = (cps[1][0] + cps[3][0]) / 2
            ncy = (cps[0][1] + cps[2][1]) / 2
            return replace(elem, cx=ncx, cy=ncy,
                           rx=abs(cps[1][0] - ncx), ry=abs(cps[0][1] - ncy))
        case Polygon(points=pts):
            new_pts = list(pts)
            for i in range(len(new_pts)):
                if _contains(kind, i):
                    new_pts[i] = (new_pts[i][0] + dx, new_pts[i][1] + dy)
            return replace(elem, points=tuple(new_pts))
        case Path(d=d) | TextPath(d=d):
            # Map each anchor index to its command index
            new_cmds = list(d)
            anchor_idx = 0
            for ci, cmd in enumerate(d):
                if isinstance(cmd, ClosePath):
                    continue
                if _contains(kind, anchor_idx):
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
    from dataclasses import replace
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


def move_path_handle_independent(elem: Path, anchor_idx: int, handle_type: str,
                                 dx: float, dy: float) -> Path:
    """Move a single handle without reflecting the opposite handle (cusp)."""
    from dataclasses import replace
    d = elem.d
    cmd_indices: list[int] = []
    for ci, cmd in enumerate(d):
        if not isinstance(cmd, ClosePath):
            cmd_indices.append(ci)
    if anchor_idx < 0 or anchor_idx >= len(cmd_indices):
        return elem
    ci = cmd_indices[anchor_idx]
    new_cmds = list(d)
    if handle_type == 'in':
        cmd = d[ci]
        if isinstance(cmd, CurveTo):
            new_cmds[ci] = CurveTo(cmd.x1, cmd.y1,
                                   cmd.x2 + dx, cmd.y2 + dy, cmd.x, cmd.y)
    elif handle_type == 'out':
        if ci + 1 < len(d) and isinstance(d[ci + 1], CurveTo):
            nc = d[ci + 1]
            new_cmds[ci + 1] = CurveTo(nc.x1 + dx, nc.y1 + dy,
                                       nc.x2, nc.y2, nc.x, nc.y)
    return replace(elem, d=tuple(new_cmds))


def is_smooth_point(d: tuple[PathCommand, ...], anchor_idx: int) -> bool:
    """True if a path anchor has at least one non-degenerate handle."""
    h_in, h_out = path_handle_positions(d, anchor_idx)
    return h_in is not None or h_out is not None


def convert_corner_to_smooth(elem: Path, anchor_idx: int,
                             hx: float, hy: float) -> Path:
    """Convert a corner anchor to a smooth one. The outgoing handle is
    placed at (hx, hy) and the incoming handle is reflected through the
    anchor."""
    from dataclasses import replace
    d = elem.d
    cmd_indices: list[int] = []
    for ci, cmd in enumerate(d):
        if not isinstance(cmd, ClosePath):
            cmd_indices.append(ci)
    if anchor_idx < 0 or anchor_idx >= len(cmd_indices):
        return elem
    ci = cmd_indices[anchor_idx]
    cmd = d[ci]
    match cmd:
        case MoveTo(x, y) | LineTo(x, y):
            ax, ay = x, y
        case CurveTo(_, _, _, _, x, y):
            ax, ay = x, y
        case _:
            return elem
    rhx = 2.0 * ax - hx
    rhy = 2.0 * ay - hy
    new_cmds = list(d)
    # Set incoming handle (x2, y2) on this command.
    if isinstance(cmd, LineTo):
        # Need x1, y1 from the previous anchor.
        px, py = cmd.x, cmd.y
        if ci > 0:
            prev = d[ci - 1]
            if isinstance(prev, (MoveTo, LineTo)):
                px, py = prev.x, prev.y
            elif isinstance(prev, CurveTo):
                px, py = prev.x, prev.y
        new_cmds[ci] = CurveTo(px, py, rhx, rhy, cmd.x, cmd.y)
    elif isinstance(cmd, CurveTo):
        new_cmds[ci] = CurveTo(cmd.x1, cmd.y1, rhx, rhy, cmd.x, cmd.y)
    # MoveTo has no incoming handle to set.
    # Set outgoing handle (x1, y1) on the next command.
    if ci + 1 < len(d):
        nc = d[ci + 1]
        if isinstance(nc, LineTo):
            new_cmds[ci + 1] = CurveTo(hx, hy, nc.x, nc.y, nc.x, nc.y)
        elif isinstance(nc, CurveTo):
            new_cmds[ci + 1] = CurveTo(hx, hy, nc.x2, nc.y2, nc.x, nc.y)
    return replace(elem, d=tuple(new_cmds))


def convert_smooth_to_corner(elem: Path, anchor_idx: int) -> Path:
    """Convert a smooth anchor to a corner by collapsing both handles to
    the anchor position."""
    from dataclasses import replace
    d = elem.d
    cmd_indices: list[int] = []
    for ci, cmd in enumerate(d):
        if not isinstance(cmd, ClosePath):
            cmd_indices.append(ci)
    if anchor_idx < 0 or anchor_idx >= len(cmd_indices):
        return elem
    ci = cmd_indices[anchor_idx]
    cmd = d[ci]
    match cmd:
        case MoveTo(x, y) | LineTo(x, y):
            ax, ay = x, y
        case CurveTo(_, _, _, _, x, y):
            ax, ay = x, y
        case _:
            return elem
    new_cmds = list(d)
    if isinstance(cmd, CurveTo):
        new_cmds[ci] = CurveTo(cmd.x1, cmd.y1, ax, ay, cmd.x, cmd.y)
    if ci + 1 < len(d) and isinstance(d[ci + 1], CurveTo):
        nc = d[ci + 1]
        new_cmds[ci + 1] = CurveTo(ax, ay, nc.x2, nc.y2, nc.x, nc.y)
    return replace(elem, d=tuple(new_cmds))


def control_point_count(elem: Element) -> int:
    """Return the number of control points for an element."""
    if isinstance(elem, Line):
        return 2
    if isinstance(elem, (Rect, Circle, Ellipse)):
        return 4
    if isinstance(elem, Polygon):
        return len(elem.points)
    if isinstance(elem, (Path, TextPath)):
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
        case Path(d=d) | TextPath(d=d):
            return _path_anchor_points(d)
        case _:
            bx, by, bw, bh = elem.bounds()
            return [(bx, by), (bx + bw, by), (bx + bw, by + bh), (bx, by + bh)]


# ---------------------------------------------------------------------------
# Path geometry utilities
# ---------------------------------------------------------------------------

def flatten_path_commands(d: tuple) -> list[tuple[float, float]]:
    """Flatten path commands into a polyline by evaluating Bezier curves."""
    pts: list[tuple[float, float]] = []
    cx, cy = 0.0, 0.0
    steps = FLATTEN_STEPS
    for cmd in d:
        match cmd:
            case MoveTo(x, y):
                pts.append((x, y))
                cx, cy = x, y
            case LineTo(x, y):
                pts.append((x, y))
                cx, cy = x, y
            case CurveTo(x1, y1, x2, y2, x, y):
                for i in range(1, steps + 1):
                    t = i / steps
                    mt = 1.0 - t
                    px = mt**3 * cx + 3 * mt**2 * t * x1 + 3 * mt * t**2 * x2 + t**3 * x
                    py = mt**3 * cy + 3 * mt**2 * t * y1 + 3 * mt * t**2 * y2 + t**3 * y
                    pts.append((px, py))
                cx, cy = x, y
            case QuadTo(x1, y1, x, y):
                for i in range(1, steps + 1):
                    t = i / steps
                    mt = 1.0 - t
                    px = mt**2 * cx + 2 * mt * t * x1 + t**2 * x
                    py = mt**2 * cy + 2 * mt * t * y1 + t**2 * y
                    pts.append((px, py))
                cx, cy = x, y
            case ClosePath():
                if pts:
                    pts.append(pts[0])
            case _:
                # SmoothCurveTo, SmoothQuadTo, ArcTo — approximate as line
                if hasattr(cmd, 'x') and hasattr(cmd, 'y'):
                    pts.append((cmd.x, cmd.y))
                    cx, cy = cmd.x, cmd.y
    return pts


def _arc_lengths(pts: list[tuple[float, float]]) -> list[float]:
    """Compute cumulative arc lengths for a polyline."""
    lengths = [0.0]
    for i in range(1, len(pts)):
        dx = pts[i][0] - pts[i - 1][0]
        dy = pts[i][1] - pts[i - 1][1]
        lengths.append(lengths[-1] + math.sqrt(dx * dx + dy * dy))
    return lengths


def path_point_at_offset(d: tuple, t: float) -> tuple[float, float]:
    """Return the (x, y) point at fraction t (0..1) along the path."""
    pts = flatten_path_commands(d)
    if len(pts) < 2:
        return pts[0] if pts else (0.0, 0.0)
    lengths = _arc_lengths(pts)
    total = lengths[-1]
    if total == 0:
        return pts[0]
    target = max(0.0, min(1.0, t)) * total
    for i in range(1, len(lengths)):
        if lengths[i] >= target:
            seg_len = lengths[i] - lengths[i - 1]
            if seg_len == 0:
                return pts[i]
            frac = (target - lengths[i - 1]) / seg_len
            x = pts[i - 1][0] + frac * (pts[i][0] - pts[i - 1][0])
            y = pts[i - 1][1] + frac * (pts[i][1] - pts[i - 1][1])
            return (x, y)
    return pts[-1]


def path_closest_offset(d: tuple, px: float, py: float) -> float:
    """Return the offset (0..1) of the closest point on the path to (px, py)."""
    pts = flatten_path_commands(d)
    if len(pts) < 2:
        return 0.0
    lengths = _arc_lengths(pts)
    total = lengths[-1]
    if total == 0:
        return 0.0
    best_dist = float('inf')
    best_offset = 0.0
    for i in range(1, len(pts)):
        ax, ay = pts[i - 1]
        bx, by = pts[i]
        dx, dy = bx - ax, by - ay
        seg_len_sq = dx * dx + dy * dy
        if seg_len_sq == 0:
            continue
        t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / seg_len_sq))
        qx = ax + t * dx
        qy = ay + t * dy
        dist = math.sqrt((px - qx) ** 2 + (py - qy) ** 2)
        if dist < best_dist:
            best_dist = dist
            seg_arc = lengths[i - 1] + t * (lengths[i] - lengths[i - 1])
            best_offset = seg_arc / total
    return best_offset


def path_distance_to_point(d: tuple, px: float, py: float) -> float:
    """Return the minimum distance from point (px, py) to the path curve."""
    pts = flatten_path_commands(d)
    if len(pts) < 2:
        if pts:
            return math.sqrt((px - pts[0][0]) ** 2 + (py - pts[0][1]) ** 2)
        return float('inf')
    best_dist = float('inf')
    for i in range(1, len(pts)):
        ax, ay = pts[i - 1]
        bx, by = pts[i]
        dx, dy = bx - ax, by - ay
        seg_len_sq = dx * dx + dy * dy
        if seg_len_sq == 0:
            continue
        t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / seg_len_sq))
        qx = ax + t * dx
        qy = ay + t * dy
        dist = math.sqrt((px - qx) ** 2 + (py - qy) ** 2)
        if dist < best_dist:
            best_dist = dist
    return best_dist
