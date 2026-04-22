"""Centralised construction of the ``active_document`` context
namespace for native-Python (jas) consumers.

Used by:
- Panel body rendering (dock_panel._create_panel_body) — drives
  bind.disabled / bind.visible expressions that read
  ``active_document.*``.
- Layers-panel action dispatch (panel_menu.dispatch_yaml_action) —
  evaluated against the same surface so action predicates and
  render-time predicates see the same values.

``panel_selection`` carries the layers-panel tree-selection so
computed fields like ``new_layer_insert_index`` and
``layers_panel_selection_count`` see live panel state. Pass ``None``
or ``[]`` from callers that don't have layers-panel context.
"""

from __future__ import annotations

from typing import Sequence


def build_active_document_view(
    model,
    panel_selection: Sequence[tuple[int, ...]] | None = None,
    artboards_panel_selection: Sequence[str] | None = None,
) -> dict:
    from geometry.element import Layer
    from workspace_interpreter.expr_types import Value
    from document.artboard import next_artboard_name

    panel_selection = list(panel_selection or [])
    panel_count = len(panel_selection)
    ab_sel = list(artboards_panel_selection or [])

    if model is None:
        return {
            "top_level_layers": [],
            "top_level_layer_paths": [],
            "next_layer_name": "Layer 1",
            "new_layer_insert_index": 0,
            "layers_panel_selection_count": panel_count,
            "has_selection": False,
            "selection_count": 0,
            "element_selection": [],
            "artboards": [],
            "artboard_options": {
                "fade_region_outside_artboard": True,
                "update_while_dragging": True,
            },
            "artboards_count": 0,
            "next_artboard_name": "Artboard 1",
            "current_artboard_id": None,
            "current_artboard": {},
            "artboards_panel_selection_ids": ab_sel,
        }

    doc = model.document
    layers = doc.layers

    top_level_layers = []
    top_level_layer_paths = []
    used_names: set[str] = set()
    for i, elem in enumerate(layers):
        if isinstance(elem, Layer):
            vis_str = elem.visibility.name.lower()
            path_val = Value.path((i,))
            top_level_layers.append({
                "kind": "Layer",
                "name": elem.name,
                "common": {"visibility": vis_str, "locked": elem.locked},
                "path": path_val,
            })
            top_level_layer_paths.append(path_val)
            used_names.add(elem.name)

    n = 1
    while f"Layer {n}" in used_names:
        n += 1
    next_layer_name = f"Layer {n}"

    top_level_selected_indices = [p[0] for p in panel_selection if len(p) == 1]
    new_layer_insert_index = (
        min(top_level_selected_indices) + 1
        if top_level_selected_indices
        else len(layers)
    )

    # Canvas selection: ordered list of paths. Native Python
    # Selection is a frozenset[ElementSelection]; sort by path for
    # deterministic output across runs.
    selection_paths = sorted(es.path for es in doc.selection)
    element_selection = [Value.path(tuple(p)) for p in selection_paths]

    # Artboard view (ARTBOARDS.md §Artboard data model).
    artboards_view = []
    for i, ab in enumerate(doc.artboards):
        artboards_view.append({
            "id": ab.id,
            "name": ab.name,
            "number": i + 1,
            "x": ab.x,
            "y": ab.y,
            "width": ab.width,
            "height": ab.height,
            "fill": ab.fill,
            "show_center_mark": ab.show_center_mark,
            "show_cross_hairs": ab.show_cross_hairs,
            "show_video_safe_areas": ab.show_video_safe_areas,
            "video_ruler_pixel_aspect_ratio": ab.video_ruler_pixel_aspect_ratio,
        })
    ab_sel_set = set(ab_sel)
    current = None
    for ab in doc.artboards:
        if ab.id in ab_sel_set:
            current = ab
            break
    if current is None and doc.artboards:
        current = doc.artboards[0]
    if current is not None:
        current_artboard_id = current.id
        current_artboard_view = {
            "id": current.id,
            "name": current.name,
            "x": current.x,
            "y": current.y,
            "width": current.width,
            "height": current.height,
        }
    else:
        current_artboard_id = None
        current_artboard_view = {}

    return {
        "top_level_layers": top_level_layers,
        "top_level_layer_paths": top_level_layer_paths,
        "next_layer_name": next_layer_name,
        "new_layer_insert_index": new_layer_insert_index,
        "layers_panel_selection_count": panel_count,
        "has_selection": len(selection_paths) > 0,
        "selection_count": len(selection_paths),
        "element_selection": element_selection,
        "artboards": artboards_view,
        "artboard_options": {
            "fade_region_outside_artboard": doc.artboard_options.fade_region_outside_artboard,
            "update_while_dragging": doc.artboard_options.update_while_dragging,
        },
        "artboards_count": len(doc.artboards),
        "next_artboard_name": next_artboard_name(doc.artboards),
        "current_artboard_id": current_artboard_id,
        "current_artboard": current_artboard_view,
        "artboards_panel_selection_ids": ab_sel,
    }


def sync_document_to_store(model, store) -> None:
    """Mirror the jas dataclass document onto the store's ``_document``
    dict so the interpreter's ``active_document`` view (used by dialog
    get/set cross-scope bindings) reflects current model state.

    The store's internal ``_document`` is the source of truth for
    ``store._active_document_view()`` which is built during
    ``store.get_dialog`` / ``store.set_dialog`` scope resolution —
    callers that only pass ``active_document`` through ``run_effects``
    ``extra`` ctx don't reach that code path. Sync before opening
    dialogs (and ideally before any run_effects) keeps those two
    views consistent.
    """
    if model is None or store is None:
        return
    doc = model.document
    artboards = [
        {
            "id": a.id,
            "name": a.name,
            "x": a.x,
            "y": a.y,
            "width": a.width,
            "height": a.height,
            "fill": a.fill,
            "show_center_mark": a.show_center_mark,
            "show_cross_hairs": a.show_cross_hairs,
            "show_video_safe_areas": a.show_video_safe_areas,
            "video_ruler_pixel_aspect_ratio": a.video_ruler_pixel_aspect_ratio,
        }
        for a in doc.artboards
    ]
    artboard_options = {
        "fade_region_outside_artboard": doc.artboard_options.fade_region_outside_artboard,
        "update_while_dragging": doc.artboard_options.update_while_dragging,
    }
    # Preserve any other keys the store may track (layers); overwrite
    # artboards + artboard_options from the jas model.
    if store._document is None:
        store._document = {}
    store._document["artboards"] = artboards
    store._document["artboard_options"] = artboard_options


def build_selection_predicates(model) -> dict:
    """Return the OPACITY.md §States / §Document model predicates
    at top-level for the yaml eval context:
    ``selection_has_mask``, ``selection_mask_clip``,
    ``selection_mask_invert``, ``selection_mask_linked``. Mixed
    selections count as no-mask; the mask fields come from the
    first selected element's mask and drive the "first-wins"
    bindings on CLIP_CHECKBOX / INVERT_MASK_CHECKBOX /
    LINK_INDICATOR.

    Mirrors ``build_selection_predicates`` in ``jas_dioxus``.
    """
    if model is None:
        return {
            "selection_has_mask": False,
            "selection_mask_clip": False,
            "selection_mask_invert": False,
            # Default `linked` to True so the LINK_INDICATOR shows
            # the linked glyph when no mask exists — matches the
            # "new masks are linked" spec default.
            "selection_mask_linked": True,
        }
    from document.controller import selection_has_mask, first_mask
    doc = model.document
    first = first_mask(doc)
    return {
        "selection_has_mask": selection_has_mask(doc),
        "selection_mask_clip": first.clip if first else False,
        "selection_mask_invert": first.invert if first else False,
        "selection_mask_linked": first.linked if first else True,
    }
