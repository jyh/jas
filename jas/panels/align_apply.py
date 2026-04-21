"""Align panel apply pipeline and canvas-click intercept.

Python port of the OCaml Effects.apply_align_operation family (see
jas_ocaml/lib/interpreter/effects.ml §Align). Exposes four entry
points the host app wires in:

- reset_align_panel: zero the four align state keys.
- apply_align_operation: read align state + selection, build an
  AlignReference, dispatch to the algorithm, and apply the resulting
  translations by pre-pending a translate(dx, dy) to each moved
  element's transform.
- try_designate_align_key_object: canvas-click hook that runs before
  the active tool. Consumes the click when Align To is key_object.
- sync_align_key_object_from_selection: clears a dangling key path
  when the key is no longer part of the selection.

Artboard mode (Align To = artboard) references the current artboard's
bounds. Current = topmost panel-selected artboard, else artboard[0].
Falls back to selection bounds only when the document has no
artboards — see transcripts/ARTBOARDS.md §Align To and
transcripts/ALIGN.md §Align To target.
"""

from __future__ import annotations

import dataclasses
from typing import Optional

from algorithms import align as align_algo
from algorithms.align import (
    AlignReference, AlignTranslation, geometric_bounds, preview_bounds,
    union_bounds,
)
from document.controller import Controller
from document.document import ElementPath
from geometry.element import Element, Transform
from workspace_interpreter.state_store import StateStore


PANEL_ID = "align_panel_content"


# ── Path marker encoding ─────────────────────────────────────

def _decode_path_marker(v) -> Optional[ElementPath]:
    """Extract a tuple path from a {"__path__": [...]} dict marker.
    Matches the JSON encoding used by workspace_interpreter.expr_eval."""
    if isinstance(v, dict):
        arr = v.get("__path__")
        if isinstance(arr, (list, tuple)) and all(isinstance(i, int) for i in arr):
            return tuple(arr)
    return None


def _encode_path_marker(path: ElementPath) -> dict:
    return {"__path__": list(path)}


# ── Element transform helper ─────────────────────────────────

def _with_transform_translated(elem: Element, dx: float, dy: float) -> Element:
    """Return a copy of elem with (dx, dy) added to the translation
    slot (e, f) of its transform. Preserves rotation / scale; falls
    back to a simple translate when the element had no transform."""
    current = getattr(elem, "transform", None) or Transform()
    new = dataclasses.replace(current, e=current.e + dx, f=current.f + dy)
    return dataclasses.replace(elem, transform=new)


# ── Reset ────────────────────────────────────────────────────

def reset_align_panel(store: StateStore) -> None:
    """Restore the four Align state keys to their defaults in both
    the global store and the panel-local mirror."""
    store.set("align_to", "selection")
    store.set("align_key_object_path", None)
    store.set("align_distribute_spacing", 0)
    store.set("align_use_preview_bounds", False)
    store.set_panel(PANEL_ID, "align_to", "selection")
    store.set_panel(PANEL_ID, "key_object_path", None)
    store.set_panel(PANEL_ID, "distribute_spacing_value", 0)
    store.set_panel(PANEL_ID, "use_preview_bounds", False)


# ── Explicit-gap helper ──────────────────────────────────────

def _align_panel_explicit_gap(store: StateStore) -> Optional[float]:
    """Distribute Spacing explicit gap — returns the spacing value
    when the panel is in Key Object mode with a designated key,
    otherwise None (average mode)."""
    align_to = store.get("align_to") or "selection"
    key_path = _decode_path_marker(store.get("align_key_object_path"))
    if align_to == "key_object" and key_path is not None:
        v = store.get("align_distribute_spacing")
        return float(v) if isinstance(v, (int, float)) else 0.0
    return None


# ── Apply ────────────────────────────────────────────────────

_OPS = {
    "align_left": align_algo.align_left,
    "align_horizontal_center": align_algo.align_horizontal_center,
    "align_right": align_algo.align_right,
    "align_top": align_algo.align_top,
    "align_vertical_center": align_algo.align_vertical_center,
    "align_bottom": align_algo.align_bottom,
    "distribute_left": align_algo.distribute_left,
    "distribute_horizontal_center": align_algo.distribute_horizontal_center,
    "distribute_right": align_algo.distribute_right,
    "distribute_top": align_algo.distribute_top,
    "distribute_vertical_center": align_algo.distribute_vertical_center,
    "distribute_bottom": align_algo.distribute_bottom,
}
_SPACING_OPS = {
    "distribute_vertical_spacing": align_algo.distribute_vertical_spacing,
    "distribute_horizontal_spacing": align_algo.distribute_horizontal_spacing,
}


def apply_align_operation(store: StateStore, controller: Controller, op: str) -> None:
    """Execute one of the 14 Align panel operations by name. Reads
    align state, gathers the current selection, builds an
    AlignReference, calls the algorithm, and applies the resulting
    translations by rebuilding the document through
    Document.replace_element with a per-element transform update.

    No-op when fewer than 2 elements are selected (per ALIGN.md
    §Enable and disable rules)."""
    doc = controller.document
    paths = sorted(doc.selected_paths())
    if len(paths) < 2:
        return
    elements = [(p, doc.get_element(p)) for p in paths]

    use_preview = bool(store.get("align_use_preview_bounds"))
    bounds_fn = preview_bounds if use_preview else geometric_bounds
    just_elems = [e for _, e in elements]

    align_to = store.get("align_to") or "selection"
    if align_to == "artboard":
        # Phase G (ARTBOARDS.md §Align To): reference the current
        # artboard's bounds. Current = topmost panel-selected artboard,
        # else artboard at position 1. Fall back to selection bounds
        # when the document has no artboards (can only happen outside
        # the at-least-one-artboard invariant — e.g., a legacy doc not
        # yet repaired).
        artboards = doc.artboards
        current = None
        if artboards:
            ab_panel = store.get_panel_state("artboards")
            ab_sel = ab_panel.get("artboards_panel_selection", []) if isinstance(ab_panel, dict) else []
            selected_ids = set(ab_sel) if isinstance(ab_sel, list) else set()
            for a in artboards:
                if a.id in selected_ids:
                    current = a
                    break
            if current is None:
                current = artboards[0]
        if current is not None:
            reference = AlignReference.selection(
                (current.x, current.y, current.width, current.height)
            )
        else:
            reference = AlignReference.selection(union_bounds(just_elems, bounds_fn))
    elif align_to == "key_object":
        kp = _decode_path_marker(store.get("align_key_object_path"))
        if kp is None:
            reference = AlignReference.selection(union_bounds(just_elems, bounds_fn))
        else:
            key_elem = doc.get_element(kp)
            reference = AlignReference.key_object(bounds_fn(key_elem), kp)
    else:
        reference = AlignReference.selection(union_bounds(just_elems, bounds_fn))

    if op in _OPS:
        translations = _OPS[op](elements, reference, bounds_fn)
    elif op in _SPACING_OPS:
        gap = _align_panel_explicit_gap(store)
        translations = _SPACING_OPS[op](elements, reference, gap, bounds_fn)
    else:
        return

    if not translations:
        return
    new_doc = doc
    for t in translations:
        elem = new_doc.get_element(t.path)
        moved = _with_transform_translated(elem, t.dx, t.dy)
        new_doc = new_doc.replace_element(t.path, moved)
    controller.set_document(new_doc)


# ── Canvas click intercept ───────────────────────────────────

def try_designate_align_key_object(
    store: StateStore, controller: Controller, x: float, y: float,
) -> bool:
    """When Align To is key_object, hit-test (x, y) against the
    current selection:
    - hit on a non-key selected element → designate it as the key
    - hit on the current key → clear it (toggle)
    - hit outside the selection → clear it
    Returns True when the click was consumed (the active tool should
    not see it) and False otherwise."""
    align_to = store.get("align_to") or "selection"
    if align_to != "key_object":
        return False
    doc = controller.document
    hit: Optional[ElementPath] = None
    for path in sorted(doc.selected_paths()):
        elem = doc.get_element(path)
        bx, by, bw, bh = elem.bounds()
        if bx <= x <= bx + bw and by <= y <= by + bh:
            hit = path
            break
    current = _decode_path_marker(store.get("align_key_object_path"))
    if hit is not None and hit == current:
        store.set("align_key_object_path", None)
        store.set_panel(PANEL_ID, "key_object_path", None)
    elif hit is not None:
        marker = _encode_path_marker(hit)
        store.set("align_key_object_path", marker)
        store.set_panel(PANEL_ID, "key_object_path", marker)
    else:
        store.set("align_key_object_path", None)
        store.set_panel(PANEL_ID, "key_object_path", None)
    return True


# ── Selection-change hook ────────────────────────────────────

def sync_align_key_object_from_selection(store: StateStore, controller: Controller) -> None:
    """Clear the key-object path if the previously-designated key is
    no longer part of the current selection. Idempotent."""
    kp = _decode_path_marker(store.get("align_key_object_path"))
    if kp is None:
        return
    if kp not in controller.document.selected_paths():
        store.set("align_key_object_path", None)
        store.set_panel(PANEL_ID, "key_object_path", None)
