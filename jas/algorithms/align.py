"""Align and distribute operations — Python port of
jas_dioxus/src/algorithms/align.rs. See transcripts/ALIGN.md.

This module owns the geometry of the 14 Align panel buttons.
Each operation reads a list of (path, element) pairs plus an
AlignReference (selection bbox, artboard rectangle, or designated
key object) and returns a list of AlignTranslation values for
the caller to apply.

The module is side-effect free. Callers are responsible for
taking a document snapshot, pre-pending each element's transform
with the returned (dx, dy), and committing the transaction.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum, auto
from typing import Callable, Optional

from geometry.element import Element


Bounds = tuple[float, float, float, float]
ElementPath = tuple[int, ...]


@dataclass(frozen=True)
class AlignReference:
    """Fixed reference a single Align / Distribute / Distribute
    Spacing operation consults.

    Use one of the three constructor helpers (selection, artboard,
    key_object) rather than instantiating directly so the tag /
    path invariants are enforced.
    """
    kind: str  # "selection" | "artboard" | "key_object"
    bbox: Bounds
    key_path: Optional[ElementPath] = None

    @staticmethod
    def selection(bbox: Bounds) -> "AlignReference":
        return AlignReference(kind="selection", bbox=bbox)

    @staticmethod
    def artboard(bbox: Bounds) -> "AlignReference":
        return AlignReference(kind="artboard", bbox=bbox)

    @staticmethod
    def key_object(bbox: Bounds, path: ElementPath) -> "AlignReference":
        return AlignReference(kind="key_object", bbox=bbox, key_path=tuple(path))


@dataclass(frozen=True)
class AlignTranslation:
    """Per-element translation emitted by an Align operation."""
    path: ElementPath
    dx: float
    dy: float


# Bounds-lookup function.
BoundsFn = Callable[[Element], Bounds]


def preview_bounds(e: Element) -> Bounds:
    """Preview bounds — stroke-inclusive. Used when Use Preview
    Bounds is checked in the panel menu."""
    return e.bounds()


def geometric_bounds(e: Element) -> Bounds:
    """Geometric bounds — ignore stroke inflation. Default when
    Use Preview Bounds is off, per ALIGN.md."""
    return e.geometric_bounds()


def union_bounds(elements: list[Element], bounds_fn: BoundsFn) -> Bounds:
    """Union the bounding boxes of an element list. Returns
    (0, 0, 0, 0) for an empty list."""
    if not elements:
        return (0.0, 0.0, 0.0, 0.0)
    min_x = float("inf")
    min_y = float("inf")
    max_x = float("-inf")
    max_y = float("-inf")
    for e in elements:
        x, y, w, h = bounds_fn(e)
        if x < min_x: min_x = x
        if y < min_y: min_y = y
        if x + w > max_x: max_x = x + w
        if y + h > max_y: max_y = y + h
    return (min_x, min_y, max_x - min_x, max_y - min_y)


class Axis(Enum):
    HORIZONTAL = auto()
    VERTICAL = auto()


class AxisAnchor(Enum):
    MIN = auto()
    CENTER = auto()
    MAX = auto()


def axis_extent(bbox: Bounds, axis: Axis) -> tuple[float, float, float]:
    """Return (lo, hi, mid) along the given axis."""
    x, y, w, h = bbox
    if axis == Axis.HORIZONTAL:
        return (x, x + w, x + w / 2.0)
    return (y, y + h, y + h / 2.0)


def anchor_position(bbox: Bounds, axis: Axis, anchor: AxisAnchor) -> float:
    lo, hi, mid = axis_extent(bbox, axis)
    if anchor == AxisAnchor.MIN: return lo
    if anchor == AxisAnchor.MAX: return hi
    return mid
