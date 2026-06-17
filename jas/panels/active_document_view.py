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
        from document.document_setup import DocumentSetup
        from document.print_preferences import PrintPreferences
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
            "document_setup": _document_setup_view(DocumentSetup()),
            "print_preferences": _print_preferences_view(PrintPreferences()),
            "artboards_count": 0,
            "next_artboard_name": "Artboard 1",
            "current_artboard_id": None,
            "current_artboard": {},
            "artboards_panel_selection_ids": ab_sel,
            "symbols": [],
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

    # Symbols view (SYMBOLS.md §8). One row per master in the off-canvas
    # store. ``name`` is the master's user-visible name, falling back to a
    # positional "Symbol N" (1-based) label so every row shows something
    # readable. ``usage_count`` is the number of live instances of the
    # master — the length of its reverse-dependency list (rdeps) in the
    # dependency index, the same signal that gates the reference-aware
    # delete. Mirrors the Rust ``build_active_document_view`` symbols arm.
    from document.dependency_index import dependency_index
    dep_index = dependency_index(doc)
    symbols_view = []
    for i, master in enumerate(doc.symbols):
        master_id = getattr(master, "id", None) or ""
        master_name = getattr(master, "name", None)
        name = master_name if master_name else f"Symbol {i + 1}"
        usage_count = len(dep_index.rdeps.get(master_id, []))
        symbols_view.append({
            "id": master_id,
            "name": name,
            "usage_count": usage_count,
        })

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
        "document_setup": _document_setup_view(doc.document_setup),
        "print_preferences": _print_preferences_view(doc.print_preferences),
        "artboards_count": len(doc.artboards),
        "next_artboard_name": next_artboard_name(doc.artboards),
        "current_artboard_id": current_artboard_id,
        "current_artboard": current_artboard_view,
        "artboards_panel_selection_ids": ab_sel,
        "symbols": symbols_view,
    }


def _document_setup_view(s) -> dict:
    return {
        "bleed_top": s.bleed_top,
        "bleed_right": s.bleed_right,
        "bleed_bottom": s.bleed_bottom,
        "bleed_left": s.bleed_left,
        "bleed_uniform": s.bleed_uniform,
        "show_images_outline": s.show_images_outline,
        "highlight_substituted_glyphs": s.highlight_substituted_glyphs,
        "grid_size": s.grid_size,
        "grid_color": s.grid_color,
        "paper_color": s.paper_color,
        "simulate_colored_paper": s.simulate_colored_paper,
        "transparency_flattener_preset": s.transparency_flattener_preset.value,
        "discard_white_overprint": s.discard_white_overprint,
    }


def _advanced_view(a) -> dict:
    return {
        "print_as_bitmap": a.print_as_bitmap,
        "overprint_flattener_preset": a.overprint_flattener_preset.value,
    }


def _color_management_view(c) -> dict:
    return {
        "document_profile": c.document_profile,
        "color_handling": c.color_handling.value,
        "printer_profile": c.printer_profile,
        "rendering_intent": c.rendering_intent.value,
        "preserve_rgb_numbers": c.preserve_rgb_numbers,
    }


def _graphics_view(g) -> dict:
    return {
        "flatness": g.flatness,
        "font_download": g.font_download.value,
        "postscript_level": g.postscript_level.value,
        "data_format": g.data_format.value,
        "compatible_gradient_printing": g.compatible_gradient_printing,
        "raster_effects_resolution": g.raster_effects_resolution,
    }


def _ink_override_view(ink) -> dict:
    return {
        "name": ink.name,
        "print": ink.print,
        "frequency": ink.frequency,
        "angle": ink.angle,
        "dot_shape": ink.dot_shape.value,
    }


def _output_view(o) -> dict:
    return {
        "mode": o.mode.value,
        "emulsion": o.emulsion.value,
        "image_polarity": o.image_polarity.value,
        "printer_resolution": o.printer_resolution,
        "convert_spot_to_process": o.convert_spot_to_process,
        "overprint_black": o.overprint_black,
        "inks": [_ink_override_view(i) for i in o.inks],
    }


def _marks_and_bleed_view(m) -> dict:
    return {
        "all_printer_marks": m.all_printer_marks,
        "trim_marks": m.trim_marks,
        "registration_marks": m.registration_marks,
        "color_bars": m.color_bars,
        "page_information": m.page_information,
        "printer_mark_type": m.printer_mark_type.value,
        "trim_mark_weight": m.trim_mark_weight,
        "mark_offset": m.mark_offset,
        "use_document_bleed": m.use_document_bleed,
        "bleed_top": m.bleed_top,
        "bleed_right": m.bleed_right,
        "bleed_bottom": m.bleed_bottom,
        "bleed_left": m.bleed_left,
    }


def _print_preferences_view(p) -> dict:
    return {
        "preset_name": p.preset_name,
        "printer_name": p.printer_name,
        "copies": p.copies,
        "collate": p.collate,
        "reverse_order": p.reverse_order,
        "artboard_range_mode": p.artboard_range_mode.value,
        "artboard_range": p.artboard_range,
        "ignore_artboards": p.ignore_artboards,
        "skip_blank_artboards": p.skip_blank_artboards,
        "media_size": p.media_size.value,
        "media_width": p.media_width,
        "media_height": p.media_height,
        "orientation": p.orientation.value,
        "auto_rotate": p.auto_rotate,
        "transverse": p.transverse,
        "print_layers": p.print_layers.value,
        "placement_x": p.placement_x,
        "placement_y": p.placement_y,
        "scaling_mode": p.scaling_mode.value,
        "custom_scale": p.custom_scale,
        "tile_overlap_h": p.tile_overlap_h,
        "tile_overlap_v": p.tile_overlap_v,
        "tile_range": p.tile_range,
        "marks_and_bleed": _marks_and_bleed_view(p.marks_and_bleed),
        "output": _output_view(p.output),
        "graphics": _graphics_view(p.graphics),
        "color_management": _color_management_view(p.color_management),
        "advanced": _advanced_view(p.advanced),
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
    """Return the OPACITY.md §States / §Document model / §Preview
    interactions predicates at top-level for the yaml eval context:
    ``selection_has_mask``, ``selection_mask_clip``,
    ``selection_mask_invert``, ``selection_mask_linked``,
    ``editing_target_is_mask``. Mixed selections count as no-mask;
    the mask fields come from the first selected element's mask
    and drive the "first-wins" bindings on CLIP_CHECKBOX /
    INVERT_MASK_CHECKBOX / LINK_INDICATOR.

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
            "editing_target_is_mask": False,
        }
    from document.controller import selection_has_mask, first_mask
    doc = model.document
    first = first_mask(doc)
    editing_target = getattr(model, "editing_target", None)
    editing_mask = bool(editing_target and editing_target.is_mask)
    return {
        "selection_has_mask": selection_has_mask(doc),
        "selection_mask_clip": first.clip if first else False,
        "selection_mask_invert": first.invert if first else False,
        "selection_mask_linked": first.linked if first else True,
        "editing_target_is_mask": editing_mask,
    }
