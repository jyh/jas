"""LiveElement framework helpers.

Shared infrastructure for non-destructive element kinds that store
source inputs and evaluate them on demand. `CompoundShape` (defined
in `geometry.element`) is the first conformer; this module provides
the geometry-bridge helper (`element_to_polygon_set`), the boolean
dispatcher (`apply_operation`), bounds helper, and the evaluate
function that CompoundShape calls.

See `transcripts/BOOLEAN.md` § Live element framework.
"""

from __future__ import annotations

import math
from typing import TYPE_CHECKING

from algorithms.boolean import (
    PolygonSet,
    boolean_exclude,
    boolean_intersect,
    boolean_subtract,
    boolean_union,
)

if TYPE_CHECKING:
    from document.document import Document
    from geometry.element import (
        CompoundOperation,
        Element,
        ElementRef,
        ElementResolver,
    )


# Default geometric tolerance in points. Matches the Precision default
# in the Boolean Options dialog (BOOLEAN.md § Boolean Options dialog).
# Equals 0.01 mm.
DEFAULT_PRECISION: float = 0.0283


def element_to_polygon_set(elem: "Element", precision: float) -> PolygonSet:
    """Flatten a document element into a polygon set suitable for the
    boolean algorithm.

    Convenience wrapper that resolves no references (a NullResolver):
    existing call sites stay behavior-identical. See
    ``element_to_polygon_set_with`` for the resolver-aware form used
    when an element subtree may contain by-id references.

    - Rect / Polygon / Polyline / Circle / Ellipse: direct conversion.
      Polyline is implicitly closed for even-odd fill.
    - Group / Layer: recursively concatenate children's rings.
    - CompoundShape: recursively evaluate.
    - Reference: resolve target (through the resolver) and evaluate.
    - Path / TextPath: flatten Bezier commands to rings per subpath.
    - Line / Text: empty (zero area or glyph-outline flattening
      deferred to a font-outline pipeline).
    """
    from geometry.element import NullResolver

    return element_to_polygon_set_with(elem, precision, NullResolver(), set())


def element_to_polygon_set_with(
    elem: "Element",
    precision: float,
    resolver: "ElementResolver",
    visiting: set,
) -> PolygonSet:
    """Resolver-aware flattening. Identical to ``element_to_polygon_set``
    except by-id references resolve through ``resolver``, with
    ``visiting`` breaking cycles. Mirrors the Rust
    ``element_to_polygon_set_with``.
    """
    from geometry.element import (
        Circle,
        CompoundShape,
        Ellipse,
        Group,
        Layer,
        Line,
        Path,
        Polygon,
        Polyline,
        Rect,
        ReferenceElem,
        Text,
        TextPath,
    )

    if isinstance(elem, Rect):
        return [[
            (elem.x, elem.y),
            (elem.x + elem.width, elem.y),
            (elem.x + elem.width, elem.y + elem.height),
            (elem.x, elem.y + elem.height),
        ]]
    if isinstance(elem, Polygon):
        return [list(elem.points)] if elem.points else []
    if isinstance(elem, Polyline):
        return [list(elem.points)] if elem.points else []
    if isinstance(elem, Circle):
        return [_circle_to_ring(elem.cx, elem.cy, elem.r, precision)]
    if isinstance(elem, Ellipse):
        return [_ellipse_to_ring(elem.cx, elem.cy, elem.rx, elem.ry, precision)]
    if isinstance(elem, (Group, Layer)):
        out: PolygonSet = []
        for child in elem.children:
            out.extend(
                element_to_polygon_set_with(child, precision, resolver, visiting)
            )
        return out
    # ReferenceElem must precede CompoundShape: both are LiveElement, but
    # only CompoundShape carries operands. (They are unrelated leaf kinds,
    # so order is not strictly required, but the explicit case keeps the
    # dispatch parallel to the Rust LiveVariant match.)
    if isinstance(elem, ReferenceElem):
        return elem.evaluate_with(precision, resolver, visiting)
    if isinstance(elem, CompoundShape):
        return elem.evaluate_with(precision, resolver, visiting)
    if isinstance(elem, (Path, TextPath)):
        return flatten_path_to_rings(elem.d)
    # Line has zero area; Text glyph flattening deferred.
    if isinstance(elem, (Line, Text)):
        return []
    return []


def apply_operation(
    op: "CompoundOperation", operand_sets: list[PolygonSet]
) -> PolygonSet:
    """Dispatch a boolean operation across an arbitrary number of
    operands. Binary ops fold left-to-right; SubtractFront consumes
    the last operand as the cutter and unions the remaining survivors
    after each has the cutter removed.
    """
    from geometry.element import CompoundOperation

    if not operand_sets:
        return []
    if op == CompoundOperation.UNION:
        result = operand_sets[0]
        for b in operand_sets[1:]:
            result = boolean_union(result, b)
        return result
    if op == CompoundOperation.INTERSECTION:
        result = operand_sets[0]
        for b in operand_sets[1:]:
            result = boolean_intersect(result, b)
        return result
    if op == CompoundOperation.SUBTRACT_FRONT:
        if len(operand_sets) < 2:
            return operand_sets[0]
        cutter = operand_sets[-1]
        survivors = operand_sets[:-1]
        acc: PolygonSet = []
        for s in survivors:
            acc = boolean_union(acc, boolean_subtract(s, cutter))
        return acc
    if op == CompoundOperation.EXCLUDE:
        result = operand_sets[0]
        for b in operand_sets[1:]:
            result = boolean_exclude(result, b)
        return result
    return []


def bounds_of_polygon_set(
    ps: PolygonSet,
) -> tuple[float, float, float, float]:
    """Tight bounding box of a polygon set. Returns (0, 0, 0, 0) for
    empty input.
    """
    min_x = math.inf
    min_y = math.inf
    max_x = -math.inf
    max_y = -math.inf
    for ring in ps:
        for x, y in ring:
            if x < min_x:
                min_x = x
            if y < min_y:
                min_y = y
            if x > max_x:
                max_x = x
            if y > max_y:
                max_y = y
    if not math.isfinite(min_x):
        return (0.0, 0.0, 0.0, 0.0)
    return (min_x, min_y, max_x - min_x, max_y - min_y)


# ── Reference resolution (REFERENCE_GRAPH.md Phase 1b) ─────────────


class DictResolver:
    """An ``ElementResolver`` backed by a flat id→element dict.

    Mirrors the Rust render-scoped ``RenderResolver`` reading a
    per-paint id→element index: a missing id resolves to ``None``
    (dangling, never an error). Built by ``resolver_from_document``;
    the canvas render builds one per paint and threads it through
    ``evaluate_with`` so by-id references resolve and draw.
    """

    def __init__(self, index: dict[str, "Element"]):
        self._index = index

    def resolve(self, ref: "ElementRef") -> "Element | None":
        return self._index.get(ref)


def _collect_ref_ids(elem: "Element", out: dict[str, "Element"]) -> None:
    """Index ``elem`` (and its descendants) by stable id into ``out``.

    First-occurrence wins (the unique-id invariant means there are no
    collisions in practice; this just makes the build deterministic).
    Recurses through Group / Layer ``children``. Mirrors the Rust
    ``collect_ref_ids``.
    """
    eid = getattr(elem, "id", None)
    if eid is not None and eid not in out:
        out[eid] = elem
    children = getattr(elem, "children", None)
    if children is not None:
        for child in children:
            _collect_ref_ids(child, out)


def resolver_from_document(doc: "Document") -> DictResolver:
    """Build an ``ElementResolver`` (id→element) from ``doc``.

    Indexes id-bearing descendants of every layer (which are the
    Phase-1 reference targets). Top-level layer ids are intentionally
    excluded — references target shapes, not layers — matching the
    Rust ``register_ref_index``. The canvas render rebuilds this each
    paint (the rebuild strategy; the persistent-incremental index is
    Phase 4, REFERENCE_GRAPH.md §2.4).

    Also indexes ``doc.symbols`` (SYMBOLS.md §2): each master is walked
    with the same operands-opaque discipline so a ``ReferenceElem``
    instance can resolve a master by its ``id``. Unlike layers, a
    master's OWN id is a valid target (a master is reached only through a
    reference), so each master is indexed directly (its own id +
    id-bearing descendants), not skipped like a top-level layer. Masters
    live off-canvas (not in ``layers``), so indexing them here makes them
    resolvable WITHOUT ever making them painted — the whole point of the
    off-canvas store. Masters are sorted by id before indexing so a
    duplicate-id master resolves deterministically (first-by-id wins),
    matching the §2 deterministic-order rule (the unique-id invariant
    means there are no collisions in a well-formed document).
    """
    index: dict[str, "Element"] = {}
    for layer in doc.layers:
        children = getattr(layer, "children", None)
        if children is not None:
            for child in children:
                _collect_ref_ids(child, index)
    sorted_masters = sorted(
        doc.symbols, key=lambda m: getattr(m, "id", None) or "")
    for master in sorted_masters:
        _collect_ref_ids(master, index)
    return DictResolver(index)


# ── Internal helpers ──────────────────────────────────────────────


def _segments_for_arc(radius: float, precision: float) -> int:
    """Number of segments to approximate a circle of the given radius
    so the max perpendicular distance to the true arc is at most
    `precision`. Error per segment ≈ r(1 − cos(π/n)); solving for n
    yields n ≥ π·√(r / (2·precision)).
    """
    if radius <= 0.0 or precision <= 0.0:
        return 32
    n = math.ceil(math.pi * math.sqrt(radius / (2.0 * precision)))
    return max(n, 8)


def _circle_to_ring(
    cx: float, cy: float, r: float, precision: float
) -> list[tuple[float, float]]:
    n = _segments_for_arc(r, precision)
    return [
        (cx + r * math.cos(2.0 * math.pi * i / n),
         cy + r * math.sin(2.0 * math.pi * i / n))
        for i in range(n)
    ]


def _ellipse_to_ring(
    cx: float, cy: float, rx: float, ry: float, precision: float
) -> list[tuple[float, float]]:
    n = _segments_for_arc(max(rx, ry), precision)
    return [
        (cx + rx * math.cos(2.0 * math.pi * i / n),
         cy + ry * math.sin(2.0 * math.pi * i / n))
        for i in range(n)
    ]


def flatten_path_to_rings(d) -> PolygonSet:
    """Flatten path commands into one ring per subpath. MoveTo starts
    a new ring; ClosePath finalizes the current ring. Open subpaths
    are finalized at the next MoveTo or end-of-commands. Rings with
    fewer than 3 points are dropped.

    Exposed so path_ops can bridge PathCommand lists into the boolean
    module's PolygonSet shape, per BLOB_BRUSH_TOOL.md Commit pipeline.
    """
    from geometry.element import (
        ArcTo,
        ClosePath,
        CurveTo,
        LineTo,
        MoveTo,
        QuadTo,
        SmoothCurveTo,
        SmoothQuadTo,
    )

    rings: PolygonSet = []
    cur: list[tuple[float, float]] = []
    cx = cy = 0.0
    FLATTEN_STEPS = 20

    def flush():
        nonlocal cur
        if len(cur) >= 3:
            rings.append(cur)
        cur = []

    for cmd in d:
        if isinstance(cmd, MoveTo):
            flush()
            cur.append((cmd.x, cmd.y))
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, LineTo):
            cur.append((cmd.x, cmd.y))
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, CurveTo):
            for i in range(1, FLATTEN_STEPS + 1):
                t = i / FLATTEN_STEPS
                mt = 1.0 - t
                px = (mt ** 3 * cx + 3.0 * mt ** 2 * t * cmd.x1
                      + 3.0 * mt * t ** 2 * cmd.x2 + t ** 3 * cmd.x)
                py = (mt ** 3 * cy + 3.0 * mt ** 2 * t * cmd.y1
                      + 3.0 * mt * t ** 2 * cmd.y2 + t ** 3 * cmd.y)
                cur.append((px, py))
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, QuadTo):
            for i in range(1, FLATTEN_STEPS + 1):
                t = i / FLATTEN_STEPS
                mt = 1.0 - t
                px = mt ** 2 * cx + 2.0 * mt * t * cmd.x1 + t ** 2 * cmd.x
                py = mt ** 2 * cy + 2.0 * mt * t * cmd.y1 + t ** 2 * cmd.y
                cur.append((px, py))
            cx, cy = cmd.x, cmd.y
        elif isinstance(cmd, ClosePath):
            flush()
        elif isinstance(cmd, (SmoothCurveTo, SmoothQuadTo, ArcTo)):
            # Approximate as line-to-endpoint, matching existing
            # flatten_path_commands behavior.
            cur.append((cmd.x, cmd.y))
            cx, cy = cmd.x, cmd.y
    flush()
    return rings
