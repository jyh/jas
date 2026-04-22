"""Gradient panel selection-driven state — Phase 4.

Reads the active fill or stroke gradient (per ``state.fill_on_top``)
from the current selection and pushes the values into the state store
so the gradient panel reflects the selection.

Mirrors:
  - Rust ``AppState::sync_gradient_panel_from_selection``
  - Swift ``syncGradientPanelFromSelection``
  - OCaml ``Effects.sync_gradient_panel_from_selection``

Behavior per GRADIENT.md §Multi-selection and §Fill-type coupling:

  - Empty selection: no-op (the panel keeps its session defaults).
  - Mixed selection (different gradients across elements, or some
    gradient and some solid/none): set ``gradient_preview_state =
    False`` and leave the other panel fields untouched. The renderer
    handles blank-vs-uniform display per the multi-selection table.
  - Uniform with gradient: populate every gradient panel field from
    the shared gradient.
  - Uniform without gradient (every selected element has solid/none
    on the active attribute): seed a preview gradient with first-stop
    color = the current solid color and second-stop color = white,
    set ``gradient_preview_state = True``. The first edit (Phase 5)
    will materialise this onto the elements via the fill-type
    coupling rule.

Like the paragraph sync, this function is currently unwired in the
Python app — selection-change observer hookup follows when the panel
write pipeline lands in Phase 5.
"""

from __future__ import annotations

from geometry.element import (
    Circle, Ellipse, Line, Path, Polygon, Polyline, Rect,
)


_FILL_VARIANTS = (Rect, Circle, Ellipse, Polyline, Polygon, Path)
_STROKE_VARIANTS = (Line,) + _FILL_VARIANTS


def _fill_gradient_of(elem):
    if isinstance(elem, _FILL_VARIANTS):
        return elem.fill_gradient
    return None


def _stroke_gradient_of(elem):
    if isinstance(elem, _STROKE_VARIANTS):
        return elem.stroke_gradient
    return None


def _fill_color_of(elem):
    fill = getattr(elem, "fill", None)
    return fill.color if fill is not None else None


def _stroke_color_of(elem):
    stroke = getattr(elem, "stroke", None)
    return stroke.color if stroke is not None else None


def sync_gradient_panel_from_selection(store, model) -> None:
    """Push ``gradient_*`` keys to the state store from the selection."""
    if model is None:
        return
    doc = getattr(model, "document", None)
    if doc is None or not doc.selection:
        return

    fill_on_top_val = store.get("fill_on_top")
    fill_on_top = True if fill_on_top_val is None else bool(fill_on_top_val)

    elements = []
    for es in doc.selection:
        path = getattr(es, "path", None)
        if path is None:
            continue
        elem = doc.get_element(path)
        if elem is not None:
            elements.append(elem)
    if not elements:
        return

    pick_g = _fill_gradient_of if fill_on_top else _stroke_gradient_of
    pick_solid = _fill_color_of if fill_on_top else _stroke_color_of

    gradients = [pick_g(e) for e in elements]
    first = gradients[0]
    mixed = any(g != first for g in gradients[1:])
    if mixed:
        store.set("gradient_preview_state", False)
        return

    if first is not None:
        # Uniform with gradient — populate panel.
        store.set("gradient_type", first.type.value)
        store.set("gradient_angle", first.angle)
        store.set("gradient_aspect_ratio", first.aspect_ratio)
        store.set("gradient_method", first.method.value)
        store.set("gradient_dither", first.dither)
        store.set("gradient_stroke_sub_mode", first.stroke_sub_mode.value)
        store.set("gradient_stops_count", len(first.stops))
        store.set("gradient_preview_state", False)
        return

    # Uniform without gradient — seed preview from solid color.
    seed_color = next((pick_solid(e) for e in elements if pick_solid(e) is not None), None)
    if seed_color is not None:
        seed_hex = "#" + seed_color.to_hex()
    else:
        seed_hex = "#000000"
    store.set("gradient_type", "linear")
    store.set("gradient_angle", 0.0)
    store.set("gradient_aspect_ratio", 100.0)
    store.set("gradient_method", "classic")
    store.set("gradient_dither", False)
    store.set("gradient_stroke_sub_mode", "within")
    store.set("gradient_seed_first_color", seed_hex)
    store.set("gradient_preview_state", True)
