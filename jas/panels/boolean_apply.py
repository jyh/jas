"""Boolean panel apply pipeline.

Python port of the Rust Controller::make_compound_shape /
release_compound_shape / expand_compound_shape family. Wired into
panel_dispatch so the Boolean panel's hamburger menu items can
mutate the document.

See transcripts/BOOLEAN.md § Compound shape data model.
"""

from __future__ import annotations

import dataclasses
import math
from dataclasses import dataclass, replace as dreplace

from algorithms.boolean import (
    boolean_exclude,
    boolean_intersect,
    boolean_subtract,
    boolean_union,
)
from document.document import ElementSelection
from geometry.element import (
    CompoundOperation,
    CompoundShape,
    Element,
    Polygon,
)
from geometry.live import (
    DEFAULT_PRECISION,
    apply_operation,
    element_to_polygon_set,
)


@dataclass(frozen=True)
class BooleanOptions:
    """Document-scoped boolean op settings. Mirrors Rust
    BooleanOptions per BOOLEAN.md §Boolean Options dialog.
    - precision: geometric tolerance (points) used for curve
      flattening and collinear-point collapse.
    - remove_redundant_points: if True, collapse collinear / near-
      duplicate points in output rings within [precision] of the
      line through their neighbors.
    - divide_remove_unpainted: if True, DIVIDE drops fragments with
      no fill and no stroke (keeps only painted artwork)."""
    precision: float = DEFAULT_PRECISION
    remove_redundant_points: bool = True
    divide_remove_unpainted: bool = False


def collapse_collinear_points(ring: list, tol: float) -> list:
    """Single-pass removal of points whose perpendicular distance to
    the line between their two neighbors is below [tol]. Returns the
    original ring if collapse would leave fewer than 3 points.
    Matches the Rust collapse_collinear_points reference."""
    n = len(ring)
    if n < 3:
        return ring
    keep = [True] * n
    for i in range(n):
        prev = ring[(i - 1) % n]
        cur = ring[i]
        nxt = ring[(i + 1) % n]
        dx = nxt[0] - prev[0]
        dy = nxt[1] - prev[1]
        seg_len = math.hypot(dx, dy)
        if seg_len == 0.0:
            keep[i] = False
            continue
        # Perpendicular distance from cur to segment prev→next.
        num = abs(dy * cur[0] - dx * cur[1] + nxt[0] * prev[1] - nxt[1] * prev[0])
        if num / seg_len < tol:
            keep[i] = False
    result = [p for p, k in zip(ring, keep) if k]
    if len(result) < 3:
        return ring
    return result


def _sorted_selection_paths(doc) -> list[tuple[int, ...]]:
    return sorted(es.path for es in doc.selection)


def _all_siblings(paths: list[tuple[int, ...]]) -> bool:
    if not paths:
        return False
    parent = paths[0][:-1]
    return all(p[:-1] == parent and len(p) == len(paths[0]) for p in paths)


def _frontmost_paint(frontmost: Element):
    """Return (fill, stroke, opacity, transform, locked, visibility)
    for the frontmost operand. Used at CompoundShape-creation time
    per BOOLEAN.md §Operand and paint rules."""
    return (
        getattr(frontmost, "fill", None),
        getattr(frontmost, "stroke", None),
        getattr(frontmost, "opacity", 1.0),
        getattr(frontmost, "transform", None),
        getattr(frontmost, "locked", False),
        getattr(frontmost, "visibility", None),
    )


def _replace_layer_children(doc, layer_idx: int, new_children: tuple):
    layer = doc.layers[layer_idx]
    new_layer = dreplace(layer, children=tuple(new_children))
    new_layers = doc.layers[:layer_idx] + (new_layer,) + doc.layers[layer_idx + 1:]
    return dreplace(doc, layers=tuple(new_layers))


# ── Make ────────────────────────────────────────────────────────

_COMPOUND_OP_BY_NAME = {
    "union": CompoundOperation.UNION,
    "subtract_front": CompoundOperation.SUBTRACT_FRONT,
    "intersection": CompoundOperation.INTERSECTION,
    "exclude": CompoundOperation.EXCLUDE,
}


def apply_make_compound_shape(model, operation: CompoundOperation = CompoundOperation.UNION) -> None:
    """Make a compound shape from the current selection using
    [operation]. Selected elements must be siblings; at least 2
    required. Paint inherits from the frontmost (last-in-path-order)
    operand. The new compound replaces its operands in place and
    becomes the selection. Default operation is UNION; Alt/Option+
    click on the four Shape Mode buttons dispatches the three
    non-UNION variants via apply_compound_creation.
    """
    doc = model.document
    if not doc.selection:
        return
    paths = _sorted_selection_paths(doc)
    if len(paths) < 2 or not _all_siblings(paths):
        return
    try:
        elements = tuple(doc.get_element(p) for p in paths)
    except (IndexError, ValueError):
        return

    frontmost = elements[-1]
    fill, stroke, opacity, transform, locked, visibility = _frontmost_paint(frontmost)

    fields = {
        "operation": operation,
        "operands": elements,
        "fill": fill,
        "stroke": stroke,
        "opacity": opacity,
        "transform": transform,
        "locked": locked,
    }
    if visibility is not None:
        fields["visibility"] = visibility
    compound = CompoundShape(**fields)

    model.snapshot()
    new_doc = doc
    # Delete selected elements in reverse order.
    for p in reversed(paths):
        new_doc = new_doc.delete_element(p)
    insert_path = paths[0]
    layer_idx, child_idx = insert_path[0], insert_path[1]
    layer = new_doc.layers[layer_idx]
    new_children = (
        layer.children[:child_idx] + (compound,) + layer.children[child_idx:]
    )
    new_doc = _replace_layer_children(new_doc, layer_idx, new_children)
    new_doc = dataclasses.replace(
        new_doc, selection=frozenset([ElementSelection.all(insert_path)])
    )
    model.document = new_doc


def apply_compound_creation(model, op_name: str) -> None:
    """Alt/Option+click variant on the four Shape Mode buttons.
    Creates a live compound shape with the chosen [op_name] instead
    of applying the destructive op. Unknown op names are no-ops. See
    BOOLEAN.md §Compound shapes."""
    operation = _COMPOUND_OP_BY_NAME.get(op_name)
    if operation is None:
        return
    apply_make_compound_shape(model, operation)


# ── Release ─────────────────────────────────────────────────────

def apply_release_compound_shape(model) -> None:
    """For every selected compound shape, replace it with its
    operand children. Each operand keeps its own paint; the
    compound shape's paint is discarded. Released operands become
    the new selection.
    """
    doc = model.document
    if not doc.selection:
        return
    cs_paths: list[tuple[int, ...]] = []
    for es in doc.selection:
        try:
            elem = doc.get_element(es.path)
        except (IndexError, ValueError):
            continue
        if isinstance(elem, CompoundShape):
            cs_paths.append(es.path)
    if not cs_paths:
        return
    cs_paths.sort()

    model.snapshot()
    orig_doc = doc
    new_doc = doc
    for cs_path in reversed(cs_paths):
        elem = new_doc.get_element(cs_path)
        if not isinstance(elem, CompoundShape):
            continue
        operands = elem.operands
        new_doc = new_doc.delete_element(cs_path)
        layer_idx, child_idx = cs_path[0], cs_path[1]
        layer = new_doc.layers[layer_idx]
        new_children = (
            layer.children[:child_idx] + operands + layer.children[child_idx:]
        )
        new_doc = _replace_layer_children(new_doc, layer_idx, new_children)

    # Build selection of released operands (forward pass).
    new_selection: set[ElementSelection] = set()
    offset = 0
    for cs_path in cs_paths:
        orig = orig_doc.get_element(cs_path)
        if not isinstance(orig, CompoundShape):
            continue
        n = len(orig.operands)
        layer_idx = cs_path[0]
        child_idx = cs_path[1] + offset
        for j in range(n):
            path = (layer_idx, child_idx + j)
            try:
                new_doc.get_element(path)
                new_selection.add(ElementSelection.all(path))
            except (IndexError, ValueError):
                pass
        offset += n - 1

    new_doc = dataclasses.replace(new_doc, selection=frozenset(new_selection))
    model.document = new_doc


# ── Destructive boolean operations ──────────────────────────────

def _polygon_from_ring(ring, fill, stroke, opacity, transform, locked, visibility):
    return Polygon(
        points=tuple(ring),
        fill=fill,
        stroke=stroke,
        opacity=opacity,
        transform=transform,
        locked=locked,
        visibility=visibility if visibility is not None else Polygon.__dataclass_fields__["visibility"].default,
    )


def _paint_of(elem):
    return (
        getattr(elem, "fill", None),
        getattr(elem, "stroke", None),
        getattr(elem, "opacity", 1.0),
        getattr(elem, "transform", None),
        getattr(elem, "locked", False),
        getattr(elem, "visibility", None),
    )


def _fills_merge_equal(a, b) -> bool:
    """MERGE predicate: two operands merge iff both have a fill and
    their fill colors are exactly equal. None / mismatched fills
    never merge (strict predicate per BOOLEAN.md §MERGE). Gradients
    and patterns never match — only solid-color fills compare here."""
    if a is None or b is None:
        return False
    return a.color == b.color


def apply_destructive_boolean(
    model, op_name: str, options: BooleanOptions | None = None
) -> None:
    """Destructively apply one of the nine boolean ops to the current
    selection. Supported: "union", "intersection", "exclude",
    "subtract_front", "subtract_back", "crop", "divide", "trim",
    "merge".

    [options] defaults to BooleanOptions() when not provided;
    callers who care about document-scoped precision / redundant-
    point removal / divide-remove-unpainted should pass their own.
    See BOOLEAN.md §Boolean Options dialog.

    Semantics per BOOLEAN.md §Operand and paint rules:
    - UNION / INTERSECTION / EXCLUDE: all operands consumed; result
      carries the frontmost operand's paint.
    - SUBTRACT_FRONT: frontmost (last in path order) is consumed as
      the cutter; each surviving element has the cutter subtracted
      and keeps its own paint.
    - SUBTRACT_BACK: backmost is consumed as the cutter.
    - CROP: frontmost is consumed as the mask; each survivor is
      clipped to the mask's interior.
    - DIVIDE: cut the union apart so no two fragments overlap; each
      fragment inherits the frontmost covering operand's paint.
    - TRIM: each operand minus the union of all later operands;
      frontmost is untouched.
    - MERGE: TRIM, then union touching survivors whose solid-color
      fills match exactly.
    """
    if options is None:
        options = BooleanOptions()
    doc = model.document
    if not doc.selection:
        return
    paths = _sorted_selection_paths(doc)
    if len(paths) < 2 or not _all_siblings(paths):
        return
    try:
        elements = tuple(doc.get_element(p) for p in paths)
    except (IndexError, ValueError):
        return

    precision = options.precision
    outputs = []  # list of (PolygonSet, fill, stroke, opacity, transform, locked, visibility)

    if op_name in ("union", "intersection", "exclude"):
        operand_sets = [element_to_polygon_set(e, precision) for e in elements]
        op_map = {
            "union": CompoundOperation.UNION,
            "intersection": CompoundOperation.INTERSECTION,
            "exclude": CompoundOperation.EXCLUDE,
        }
        result = apply_operation(op_map[op_name], operand_sets)
        outputs.append((result, *_paint_of(elements[-1])))
    elif op_name in ("subtract_front", "crop"):
        cutter = element_to_polygon_set(elements[-1], precision)
        for survivor in elements[:-1]:
            s_set = element_to_polygon_set(survivor, precision)
            res = (
                boolean_intersect(s_set, cutter) if op_name == "crop"
                else boolean_subtract(s_set, cutter)
            )
            outputs.append((res, *_paint_of(survivor)))
    elif op_name == "subtract_back":
        cutter = element_to_polygon_set(elements[0], precision)
        for survivor in elements[1:]:
            s_set = element_to_polygon_set(survivor, precision)
            res = boolean_subtract(s_set, cutter)
            outputs.append((res, *_paint_of(survivor)))
    elif op_name == "divide":
        # Walk operands back-to-front. Maintain a partition of the
        # union-so-far as a list of (region, frontmost-covering
        # operand index). Each incoming operand splits every existing
        # region into overlap / non-overlap; overlap relabels to the
        # incoming index (now frontmost).
        accumulator: list[tuple[list, int]] = []
        operand_sets = [element_to_polygon_set(e, precision) for e in elements]
        for i, op_set in enumerate(operand_sets):
            new_acc: list[tuple[list, int]] = []
            remaining = list(op_set)
            for existing_region, existing_idx in accumulator:
                overlap = boolean_intersect(existing_region, op_set)
                if overlap:
                    new_acc.append((overlap, i))
                non_overlap = boolean_subtract(existing_region, op_set)
                if non_overlap:
                    new_acc.append((non_overlap, existing_idx))
                remaining = boolean_subtract(remaining, existing_region)
            if remaining:
                new_acc.append((remaining, i))
            accumulator = new_acc
        for region, paint_idx in accumulator:
            outputs.append((region, *_paint_of(elements[paint_idx])))
    elif op_name in ("trim", "merge"):
        operand_sets = [element_to_polygon_set(e, precision) for e in elements]
        trimmed: list[tuple[list, object, object, float, object, bool, object]] = []
        for i in range(len(elements)):
            region = list(operand_sets[i])
            for later in operand_sets[i + 1:]:
                region = boolean_subtract(region, later)
            if region:
                trimmed.append((region, *_paint_of(elements[i])))
        if op_name == "trim":
            outputs.extend(trimmed)
        else:
            # MERGE: unify touching same-fill survivors. O(N^2) pass;
            # acceptable for panel-sized selections. Frontmost
            # contributor in the merged cluster keeps its stroke /
            # opacity / transform; its fill is already the cluster's
            # fill by predicate.
            consumed = [False] * len(trimmed)
            for i, (region_i, fill_i, stroke_i, opacity_i, transform_i, locked_i, vis_i) \
                    in enumerate(trimmed):
                if consumed[i]:
                    continue
                consumed[i] = True
                merged = list(region_i)
                stroke_w, opacity_w, transform_w, locked_w, vis_w = (
                    stroke_i, opacity_i, transform_i, locked_i, vis_i
                )
                if fill_i is not None:
                    for j in range(i + 1, len(trimmed)):
                        if consumed[j]:
                            continue
                        if _fills_merge_equal(fill_i, trimmed[j][1]):
                            merged = boolean_union(merged, trimmed[j][0])
                            # j > i in operand z-order → j is frontmost.
                            stroke_w = trimmed[j][2]
                            opacity_w = trimmed[j][3]
                            transform_w = trimmed[j][4]
                            locked_w = trimmed[j][5]
                            vis_w = trimmed[j][6]
                            consumed[j] = True
                outputs.append((merged, fill_i, stroke_w, opacity_w, transform_w, locked_w, vis_w))
    else:
        return  # unknown op

    # Flatten to Polygon elements; drop rings with < 3 points.
    # Optional per BooleanOptions:
    # - divide_remove_unpainted: drop unpainted DIVIDE fragments
    # - remove_redundant_points: collapse near-collinear points
    new_elements: list[Element] = []
    for ps, fill, stroke, opacity, transform, locked, visibility in outputs:
        if (op_name == "divide" and options.divide_remove_unpainted
                and fill is None and stroke is None):
            continue
        for ring in ps:
            r = ring
            if options.remove_redundant_points:
                r = collapse_collinear_points(r, options.precision)
            if len(r) >= 3:
                new_elements.append(_polygon_from_ring(
                    r, fill, stroke, opacity, transform, locked, visibility
                ))

    model.snapshot()
    new_doc = doc
    for p in reversed(paths):
        new_doc = new_doc.delete_element(p)
    insert_path = paths[0]
    layer_idx, child_idx = insert_path[0], insert_path[1]
    layer = new_doc.layers[layer_idx]
    new_children = (
        layer.children[:child_idx] + tuple(new_elements) + layer.children[child_idx:]
    )
    new_doc = _replace_layer_children(new_doc, layer_idx, new_children)

    new_selection: set[ElementSelection] = set()
    for i in range(len(new_elements)):
        path = (layer_idx, child_idx + i)
        try:
            new_doc.get_element(path)
            new_selection.add(ElementSelection.all(path))
        except (IndexError, ValueError):
            pass
    new_doc = dataclasses.replace(new_doc, selection=frozenset(new_selection))
    model.document = new_doc


# ── Expand ──────────────────────────────────────────────────────

def apply_expand_compound_shape(model) -> None:
    """For every selected compound shape, replace it with static
    Polygon elements derived from its evaluated geometry. Each
    expanded polygon carries the compound shape's own paint.
    Expanded polygons become the new selection.
    """
    doc = model.document
    if not doc.selection:
        return
    cs_paths: list[tuple[int, ...]] = []
    for es in doc.selection:
        try:
            elem = doc.get_element(es.path)
        except (IndexError, ValueError):
            continue
        if isinstance(elem, CompoundShape):
            cs_paths.append(es.path)
    if not cs_paths:
        return
    cs_paths.sort()

    model.snapshot()
    expanded_counts: list[int] = []
    new_doc = doc
    for cs_path in reversed(cs_paths):
        elem = new_doc.get_element(cs_path)
        if not isinstance(elem, CompoundShape):
            expanded_counts.append(0)
            continue
        expanded = tuple(elem.expand(DEFAULT_PRECISION))
        expanded_counts.append(len(expanded))
        new_doc = new_doc.delete_element(cs_path)
        layer_idx, child_idx = cs_path[0], cs_path[1]
        layer = new_doc.layers[layer_idx]
        new_children = (
            layer.children[:child_idx] + expanded + layer.children[child_idx:]
        )
        new_doc = _replace_layer_children(new_doc, layer_idx, new_children)
    expanded_counts.reverse()  # forward order

    # Build selection of expanded polygons.
    new_selection: set[ElementSelection] = set()
    offset = 0
    for cs_path, n in zip(cs_paths, expanded_counts):
        layer_idx = cs_path[0]
        child_idx = cs_path[1] + offset
        for j in range(n):
            path = (layer_idx, child_idx + j)
            try:
                new_doc.get_element(path)
                new_selection.add(ElementSelection.all(path))
            except (IndexError, ValueError):
                pass
        offset += n - 1

    new_doc = dataclasses.replace(new_doc, selection=frozenset(new_selection))
    model.document = new_doc


# ── Repeat + Reset ──────────────────────────────────────────────

# Op names whose "_compound" suffix indicates a compound-creating
# variant vs a destructive one. Matches the 13-value enum in
# BOOLEAN.md §Repeat state.
_COMPOUND_SUFFIX = "_compound"


def apply_repeat_boolean_operation(
    model, last_op: str | None, options: BooleanOptions | None = None
) -> None:
    """Re-apply the last destructive or compound-creating boolean op
    to the current selection. Reads [last_op] (the 13-value state
    enum from BOOLEAN.md §Repeat state) and dispatches to either
    apply_destructive_boolean or apply_compound_creation. No-op when
    last_op is None or empty."""
    if not last_op:
        return
    if last_op.endswith(_COMPOUND_SUFFIX):
        base = last_op[: -len(_COMPOUND_SUFFIX)]
        apply_compound_creation(model, base)
    else:
        apply_destructive_boolean(model, last_op, options)
