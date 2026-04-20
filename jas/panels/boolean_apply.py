"""Boolean panel apply pipeline.

Python port of the Rust Controller::make_compound_shape /
release_compound_shape / expand_compound_shape family. Wired into
panel_dispatch so the Boolean panel's hamburger menu items can
mutate the document.

See transcripts/BOOLEAN.md § Compound shape data model.
"""

from __future__ import annotations

import dataclasses
from dataclasses import replace as dreplace

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

def apply_make_compound_shape(model) -> None:
    """Make a Union compound shape from the current selection.
    Selected elements must be siblings; at least 2 required. Paint
    inherits from the frontmost (last-in-path-order) operand. The
    new compound replaces its operands in place and becomes the
    selection.
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
        "operation": CompoundOperation.UNION,
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


def apply_destructive_boolean(model, op_name: str) -> None:
    """Destructively apply one of the six implemented boolean ops to
    the current selection. Supported: "union", "intersection",
    "exclude", "subtract_front", "subtract_back", "crop". DIVIDE /
    TRIM / MERGE live in phase 9e.

    Semantics per BOOLEAN.md §Operand and paint rules:
    - UNION / INTERSECTION / EXCLUDE: all operands consumed; result
      carries the frontmost operand's paint.
    - SUBTRACT_FRONT: frontmost (last in path order) is consumed as
      the cutter; each surviving element has the cutter subtracted
      and keeps its own paint.
    - SUBTRACT_BACK: backmost (first in path order) is consumed as
      the cutter.
    - CROP: frontmost is consumed as the mask; each survivor is
      clipped to the mask's interior and keeps its own paint.
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

    precision = DEFAULT_PRECISION
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
    else:
        return  # unknown op

    # Flatten to Polygon elements; drop rings with < 3 points.
    new_elements: list[Element] = []
    for ps, fill, stroke, opacity, transform, locked, visibility in outputs:
        for ring in ps:
            if len(ring) >= 3:
                new_elements.append(_polygon_from_ring(
                    ring, fill, stroke, opacity, transform, locked, visibility
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
