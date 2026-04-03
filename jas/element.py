"""Immutable document elements for the Jas illustration app.

All elements are immutable value objects. To modify an element, create a new
one with the desired changes. This makes undo/redo straightforward and
enables safe sharing of elements across layers and groups.
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from enum import Enum
from typing import Tuple


# Basic value types

@dataclass(frozen=True)
class Point:
    """A 2D point."""
    x: float
    y: float


@dataclass(frozen=True)
class Color:
    """RGBA color with components in [0, 1]."""
    r: float
    g: float
    b: float
    a: float = 1.0


class StrokeAlignment(Enum):
    CENTER = "center"
    INSIDE = "inside"
    OUTSIDE = "outside"


@dataclass(frozen=True)
class Fill:
    """Fill style for a closed path."""
    color: Color


@dataclass(frozen=True)
class Stroke:
    """Stroke style for a path."""
    color: Color
    width: float = 1.0
    alignment: StrokeAlignment = StrokeAlignment.CENTER


# Path components

@dataclass(frozen=True)
class AnchorPoint:
    """An anchor point on a path, with optional control handles for curves."""
    position: Point
    handle_in: Point | None = None
    handle_out: Point | None = None


# Elements

class Element(ABC):
    """Abstract base class for all document elements.

    Elements are immutable. All concrete subclasses use frozen dataclasses.
    """

    @abstractmethod
    def bounds(self) -> Tuple[Point, Point]:
        """Return the bounding box as (top_left, bottom_right)."""
        ...


@dataclass(frozen=True)
class Path(Element):
    """A vector path defined by anchor points.

    An open path is a line; a closed path forms a shape.
    """
    anchors: tuple[AnchorPoint, ...]
    closed: bool = False
    fill: Fill | None = None
    stroke: Stroke | None = None

    def bounds(self) -> Tuple[Point, Point]:
        if not self.anchors:
            return (Point(0, 0), Point(0, 0))
        xs = [a.position.x for a in self.anchors]
        ys = [a.position.y for a in self.anchors]
        return (Point(min(xs), min(ys)), Point(max(xs), max(ys)))


@dataclass(frozen=True)
class Rect(Element):
    """A rectangle defined by origin and size."""
    origin: Point
    width: float
    height: float
    fill: Fill | None = None
    stroke: Stroke | None = None

    def bounds(self) -> Tuple[Point, Point]:
        return (self.origin,
                Point(self.origin.x + self.width, self.origin.y + self.height))


@dataclass(frozen=True)
class Ellipse(Element):
    """An ellipse defined by center and radii."""
    center: Point
    rx: float
    ry: float
    fill: Fill | None = None
    stroke: Stroke | None = None

    def bounds(self) -> Tuple[Point, Point]:
        return (Point(self.center.x - self.rx, self.center.y - self.ry),
                Point(self.center.x + self.rx, self.center.y + self.ry))


@dataclass(frozen=True)
class Group(Element):
    """A group of elements treated as a single unit."""
    children: tuple[Element, ...]

    def bounds(self) -> Tuple[Point, Point]:
        if not self.children:
            return (Point(0, 0), Point(0, 0))
        all_bounds = [c.bounds() for c in self.children]
        min_x = min(b[0].x for b in all_bounds)
        min_y = min(b[0].y for b in all_bounds)
        max_x = max(b[1].x for b in all_bounds)
        max_y = max(b[1].y for b in all_bounds)
        return (Point(min_x, min_y), Point(max_x, max_y))
