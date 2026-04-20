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


def align_along_axis(
    elements: list[tuple[ElementPath, Element]],
    reference: AlignReference,
    axis: Axis,
    anchor: AxisAnchor,
    bounds_fn: BoundsFn,
) -> list[AlignTranslation]:
    """Generic alignment driver used by the six Align operations.

    For each selected element whose bbox anchor differs from the
    reference's along the axis, emit a translation to the target.
    Elements matching reference.key_path are skipped (the key
    never moves, per ALIGN.md). Zero-delta translations are
    omitted per the identity-value rule.
    """
    target = anchor_position(reference.bbox, axis, anchor)
    key_path = reference.key_path
    out: list[AlignTranslation] = []
    for path, elem in elements:
        if key_path is not None and tuple(path) == key_path:
            continue
        pos = anchor_position(bounds_fn(elem), axis, anchor)
        delta = target - pos
        if delta == 0:
            continue
        if axis == Axis.HORIZONTAL:
            out.append(AlignTranslation(path=tuple(path), dx=delta, dy=0))
        else:
            out.append(AlignTranslation(path=tuple(path), dx=0, dy=delta))
    return out


def align_left(elements, reference, bounds_fn):
    """ALIGN_LEFT_BUTTON."""
    return align_along_axis(elements, reference, Axis.HORIZONTAL, AxisAnchor.MIN, bounds_fn)


def align_horizontal_center(elements, reference, bounds_fn):
    """ALIGN_HORIZONTAL_CENTER_BUTTON."""
    return align_along_axis(elements, reference, Axis.HORIZONTAL, AxisAnchor.CENTER, bounds_fn)


def align_right(elements, reference, bounds_fn):
    """ALIGN_RIGHT_BUTTON."""
    return align_along_axis(elements, reference, Axis.HORIZONTAL, AxisAnchor.MAX, bounds_fn)


def align_top(elements, reference, bounds_fn):
    """ALIGN_TOP_BUTTON."""
    return align_along_axis(elements, reference, Axis.VERTICAL, AxisAnchor.MIN, bounds_fn)


def align_vertical_center(elements, reference, bounds_fn):
    """ALIGN_VERTICAL_CENTER_BUTTON."""
    return align_along_axis(elements, reference, Axis.VERTICAL, AxisAnchor.CENTER, bounds_fn)


def align_bottom(elements, reference, bounds_fn):
    """ALIGN_BOTTOM_BUTTON."""
    return align_along_axis(elements, reference, Axis.VERTICAL, AxisAnchor.MAX, bounds_fn)


def distribute_along_axis(
    elements: list[tuple[ElementPath, Element]],
    reference: AlignReference,
    axis: Axis,
    anchor: AxisAnchor,
    bounds_fn: BoundsFn,
) -> list[AlignTranslation]:
    """Generic driver for the six Distribute operations.

    Sorts the selection by current anchor position along the axis,
    determines the span from the reference (extremal anchor for
    Selection / KeyObject, axis extent for Artboard), and emits
    translations placing each element's anchor at an evenly-spaced
    position within the span. Requires at least 3 elements; fewer
    yields an empty list. Elements matching reference.key_path are
    skipped. Zero-delta translations are omitted. Output is sorted
    by path.
    """
    n = len(elements)
    if n < 3:
        return []
    indexed = [
        (i, anchor_position(bounds_fn(e), axis, anchor))
        for i, (_, e) in enumerate(elements)
    ]
    indexed.sort(key=lambda pair: pair[1])

    if reference.kind == "artboard":
        lo, hi, _ = axis_extent(reference.bbox, axis)
        min_anchor, max_anchor = lo, hi
    else:
        min_anchor = indexed[0][1]
        max_anchor = indexed[-1][1]

    key_path = reference.key_path
    out: list[AlignTranslation] = []
    for sorted_idx, (original_idx, current_anchor) in enumerate(indexed):
        t = sorted_idx / (n - 1)
        new_anchor = min_anchor + (max_anchor - min_anchor) * t
        delta = new_anchor - current_anchor
        if delta == 0:
            continue
        path, _ = elements[original_idx]
        if key_path is not None and tuple(path) == key_path:
            continue
        if axis == Axis.HORIZONTAL:
            out.append(AlignTranslation(path=tuple(path), dx=delta, dy=0))
        else:
            out.append(AlignTranslation(path=tuple(path), dx=0, dy=delta))
    out.sort(key=lambda t: t.path)
    return out


def distribute_left(elements, reference, bounds_fn):
    """DISTRIBUTE_LEFT_BUTTON."""
    return distribute_along_axis(elements, reference, Axis.HORIZONTAL, AxisAnchor.MIN, bounds_fn)


def distribute_horizontal_center(elements, reference, bounds_fn):
    """DISTRIBUTE_HORIZONTAL_CENTER_BUTTON."""
    return distribute_along_axis(elements, reference, Axis.HORIZONTAL, AxisAnchor.CENTER, bounds_fn)


def distribute_right(elements, reference, bounds_fn):
    """DISTRIBUTE_RIGHT_BUTTON."""
    return distribute_along_axis(elements, reference, Axis.HORIZONTAL, AxisAnchor.MAX, bounds_fn)


def distribute_top(elements, reference, bounds_fn):
    """DISTRIBUTE_TOP_BUTTON."""
    return distribute_along_axis(elements, reference, Axis.VERTICAL, AxisAnchor.MIN, bounds_fn)


def distribute_vertical_center(elements, reference, bounds_fn):
    """DISTRIBUTE_VERTICAL_CENTER_BUTTON."""
    return distribute_along_axis(elements, reference, Axis.VERTICAL, AxisAnchor.CENTER, bounds_fn)


def distribute_bottom(elements, reference, bounds_fn):
    """DISTRIBUTE_BOTTOM_BUTTON."""
    return distribute_along_axis(elements, reference, Axis.VERTICAL, AxisAnchor.MAX, bounds_fn)


def distribute_spacing_along_axis(
    elements: list[tuple[ElementPath, Element]],
    reference: AlignReference,
    axis: Axis,
    explicit_gap: Optional[float],
    bounds_fn: BoundsFn,
) -> list[AlignTranslation]:
    """Generic driver for the two Distribute Spacing operations.

    Sorts the selection along the axis by min-edge and equalises the
    gaps between consecutive bboxes.

    - explicit_gap=None (average mode): extremals hold, interior gaps
      average to (span − Σ sizes) / (n − 1). Used when no key object.
    - explicit_gap=g (explicit mode): key object holds; others placed
      so each consecutive pair has exactly `g` pts of space. Requires
      reference.key_path; returns [] otherwise.

    Fewer than 3 elements yields []. Keys are skipped. Zero-deltas
    omitted. Output sorted by path.
    """
    n = len(elements)
    if n < 3:
        return []

    sorted_list: list[tuple[int, float, float]] = []
    for i, (_, e) in enumerate(elements):
        lo, hi, _ = axis_extent(bounds_fn(e), axis)
        sorted_list.append((i, lo, hi))
    sorted_list.sort(key=lambda t: t[1])

    if explicit_gap is not None:
        key_path = reference.key_path
        if key_path is None:
            return []
        key_original_idx = next(
            (i for i, (p, _) in enumerate(elements) if tuple(p) == key_path), None)
        if key_original_idx is None:
            return []
        key_sorted_idx = next(
            (i for i, (oi, _, _) in enumerate(sorted_list) if oi == key_original_idx), None)
        if key_sorted_idx is None:
            return []
        positions = [0.0] * n
        positions[key_sorted_idx] = sorted_list[key_sorted_idx][1]
        # Walk forward from key.
        for i in range(key_sorted_idx + 1, n):
            prev_size = sorted_list[i - 1][2] - sorted_list[i - 1][1]
            positions[i] = positions[i - 1] + prev_size + explicit_gap
        # Walk backward from key.
        for i in range(key_sorted_idx - 1, -1, -1):
            size = sorted_list[i][2] - sorted_list[i][1]
            positions[i] = positions[i + 1] - explicit_gap - size
    else:
        total_span = sorted_list[-1][2] - sorted_list[0][1]
        total_sizes = sum(hi - lo for _, lo, hi in sorted_list)
        gap = (total_span - total_sizes) / (n - 1)
        positions = []
        cursor = sorted_list[0][1]
        for _, lo, hi in sorted_list:
            positions.append(cursor)
            cursor += (hi - lo) + gap

    key_path = reference.key_path
    out: list[AlignTranslation] = []
    for sorted_idx, (original_idx, old_min, _) in enumerate(sorted_list):
        delta = positions[sorted_idx] - old_min
        if delta == 0:
            continue
        path, _ = elements[original_idx]
        if key_path is not None and tuple(path) == key_path:
            continue
        if axis == Axis.HORIZONTAL:
            out.append(AlignTranslation(path=tuple(path), dx=delta, dy=0))
        else:
            out.append(AlignTranslation(path=tuple(path), dx=0, dy=delta))
    out.sort(key=lambda t: t.path)
    return out


def distribute_vertical_spacing(elements, reference, explicit_gap, bounds_fn):
    """DISTRIBUTE_VERTICAL_SPACING_BUTTON."""
    return distribute_spacing_along_axis(
        elements, reference, Axis.VERTICAL, explicit_gap, bounds_fn)


def distribute_horizontal_spacing(elements, reference, explicit_gap, bounds_fn):
    """DISTRIBUTE_HORIZONTAL_SPACING_BUTTON."""
    return distribute_spacing_along_axis(
        elements, reference, Axis.HORIZONTAL, explicit_gap, bounds_fn)
