//! Views of the document that a panel binds under `active_document.*`, built
//! web-free so the web view (`renderer::build_active_document_view`) and the
//! engine's scope (`panel_scope::engine_scope`) call ONE definition (W2b-15).
//! They read only the document and the workspace.

use serde_json::{json, Value};

use crate::document::document::Document;
use crate::geometry::element::Element;
use crate::geometry::live::LiveVariant;

/// The Brushes panel's two gates (BRUSHES.md § Bottom toolbar;
/// runtime_contexts.yaml): `(selection_has_brushed_stroke,
/// selection_is_single_brushed_stroke)`. A selected element is a brushed stroke
/// when it is a path carrying a non-empty `stroke_brush`; only the selected
/// elements are read, never their descendants. A stale selection path counts as
/// nothing, never a panic.
pub fn brushed_stroke_facts(doc: &Document) -> (bool, bool) {
    let brushed = doc.selection.iter().filter(|es| matches!(
        doc.get_element(&es.path),
        Some(Element::Path(p)) if p.stroke_brush.as_deref().is_some_and(|b| !b.is_empty())
    )).count();
    (brushed > 0, doc.selection.len() == 1 && brushed == 1)
}

/// Symbols view (SYMBOLS.md §8). One row per master in the off-canvas
/// store. `name` is the master's common.name, falling back to a
/// positional "Symbol N" label so every row shows something readable.
/// `usage_count` is the number of live instances of the master — the
/// length of its reverse-dependency list (rdeps) in the dependency
/// index, the same signal that gates the reference-aware delete.
pub fn symbols_view(doc: &Document) -> Value {
    let dep_index = crate::document::dependency_index::dependency_index(doc);
    let rows: Vec<Value> = doc
        .symbols
        .iter()
        .enumerate()
        .map(|(i, m)| {
            let id = m.common().id.clone().unwrap_or_default();
            let name = match m.common().name.as_deref() {
                Some(n) if !n.is_empty() => n.to_string(),
                _ => format!("Symbol {}", i + 1),
            };
            let usage_count = dep_index
                .rdeps
                .get(&id)
                .map(|v| v.len())
                .unwrap_or(0);
            json!({
                "id": id,
                "name": name,
                "usage_count": usage_count,
            })
        })
        .collect();
    Value::Array(rows)
}

/// `active_document.selected_concept`: when exactly one `Generated` concept
/// instance is selected, its concept's view ([`concept_view`]); `null` otherwise,
/// so the Concepts panel switches to PARAMS mode only then.
pub fn selected_concept_view(doc: &Document) -> Value {
    if doc.selection.len() != 1 {
        return Value::Null;
    }
    match doc.get_element(&doc.selection[0].path) {
        Some(Element::Live(LiveVariant::Generated(ge))) => concept_view(&ge.concept_id, &ge.params),
        _ => Value::Null,
    }
}

/// Build `active_document.selected_concept` for a selected `Generated` instance:
/// the concept's display name + its declared param schema (name/min/max) merged
/// with the instance's current values (CONCEPTS.md §6.4, Slice 2). Null if the
/// concept is not registered.
pub fn concept_view(
    concept_id: &str,
    instance_params: &serde_json::Value,
) -> serde_json::Value {
    let Some(ws) = crate::interpreter::workspace::Workspace::load() else {
        return serde_json::Value::Null;
    };
    let Some(concept) = ws.concept(concept_id) else {
        return serde_json::Value::Null;
    };
    let name = concept
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or(concept_id);
    let mut params_out: Vec<serde_json::Value> = Vec::new();
    if let Some(schema) = concept.get("params").and_then(|v| v.as_array()) {
        for p in schema {
            let Some(pname) = p.get("name").and_then(|v| v.as_str()) else {
                continue;
            };
            let value = instance_params
                .get(pname)
                .cloned()
                .or_else(|| p.get("default").cloned())
                .unwrap_or(serde_json::Value::Null);
            let mut entry = serde_json::json!({ "name": pname, "value": value });
            if let Some(min) = p.get("min") {
                entry["min"] = min.clone();
            }
            if let Some(max) = p.get("max") {
                entry["max"] = max.clone();
            }
            params_out.push(entry);
        }
    }
    // The concept's named operations (CONCEPTS.md §9): id + label + description,
    // so the panel can render a button per operation. Empty when the concept
    // declares no `operations:`.
    let mut operations_out: Vec<serde_json::Value> = Vec::new();
    if let Some(ops) = concept.get("operations").and_then(|v| v.as_array()) {
        for o in ops {
            let Some(oid) = o.get("id").and_then(|v| v.as_str()) else {
                continue;
            };
            operations_out.push(serde_json::json!({
                "id": oid,
                "label": o.get("label").and_then(|v| v.as_str()).unwrap_or(oid),
                "description": o.get("description").and_then(|v| v.as_str()).unwrap_or(""),
            }));
        }
    }
    // The concept's VIOLATED constraints (CONCEPTS.md §11): evaluate each
    // constraint's `check` over the instance's params; collect the ones that are
    // NOT truthy (`to_bool`, the same truthiness `if` uses), in declared order.
    // Advisory + read-only — the panel surfaces these as a warning. Empty when
    // the concept declares no `constraints:` or all hold.
    let mut violations_out: Vec<serde_json::Value> = Vec::new();
    if let Some(cons) = concept.get("constraints").and_then(|v| v.as_array()) {
        let mut ctx = serde_json::Map::new();
        ctx.insert("param".to_string(), instance_params.clone());
        let ctx = serde_json::Value::Object(ctx);
        for c in cons {
            let Some(cid) = c.get("id").and_then(|v| v.as_str()) else {
                continue;
            };
            let Some(check) = c.get("check").and_then(|v| v.as_str()) else {
                continue;
            };
            if !crate::interpreter::expr::eval(check, &ctx).to_bool() {
                violations_out.push(serde_json::json!({
                    "id": cid,
                    "message": c.get("message").and_then(|v| v.as_str()).unwrap_or(""),
                }));
            }
        }
    }
    serde_json::json!({
        "concept_id": concept_id,
        "name": name,
        "params": params_out,
        "operations": operations_out,
        "violations": violations_out,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::test_fixture::{brushed_path as path, model_with, rect};

    const B: Option<&str> = Some("default_brushes/flat_10");

    /// W2b-18: the reference's table (`test_brush_panel_spec.py::CASES`), row
    /// for row: (name, children, selected, has, single).
    #[test]
    fn brushed_stroke_facts_match_the_reference_table() {
        let cases: Vec<(&str, Vec<Element>, Vec<usize>, bool, bool)> = vec![
            ("one brushed path", vec![path(0.0, B)], vec![0], true, true),
            ("one plain path", vec![path(0.0, None)], vec![0], false, false),
            ("brushed + plain selected", vec![path(0.0, B), path(60.0, None)], vec![0, 1], true, false),
            ("two brushed selected", vec![path(0.0, B), path(60.0, B)], vec![0, 1], true, false),
            ("brushed but NOT selected", vec![path(0.0, B), path(60.0, None)], vec![1], false, false),
            ("a rect", vec![rect(0.0, 0.0, 10.0, 10.0)], vec![0], false, false),
            ("empty brush id", vec![path(0.0, Some(""))], vec![0], false, false),
            ("nothing selected", vec![path(0.0, B)], vec![], false, false),
            ("a stale selection path", vec![path(0.0, B)], vec![7], false, false),
        ];
        for (name, children, sel, has, single) in cases {
            let m = model_with(children, &sel);
            assert_eq!(brushed_stroke_facts(m.document()), (has, single), "{name}");
        }
    }
}

/// The `active_document` namespace (Phase 3 §7.2) for one open document: the
/// layer tree (`top_level_layers`, which `element_at` reads), the selection
/// rollups, the artboards, `artboard_options`, `document_setup`,
/// `print_preferences`, the symbols, the save state. The web view
/// (`renderer::build_active_document_view`) and the engine's scope
/// (`panel_scope::engine_scope`) both call it; until 2026-10-14 only the web
/// had it, and a dialog opened on the engine's route read nulls where the
/// document had values. `layers_sel`, `artboards_sel` and `artboards_anchor`
/// are the Layers and Artboards panels' selections, which each caller holds in
/// its own place.
pub fn active_document_view(
    model: &crate::document::model::Model,
    layers_sel: &[Vec<usize>],
    artboards_sel: &[String],
    artboards_anchor: Option<&str>,
) -> Value {
    use crate::geometry::element::Visibility;
    use std::collections::HashSet;
    let mut top_level_layers = Vec::new();
    let mut top_level_layer_paths = Vec::new();
    let mut layer_names: HashSet<String> = HashSet::new();
    for (i, elem) in model.document().layers.iter().enumerate() {
        if let Element::Layer(le) = elem {
            let vis = match le.common.visibility {
                Visibility::Invisible => "invisible",
                Visibility::Outline => "outline",
                Visibility::Preview => "preview",
            };
            let path_json = serde_json::json!({"__path__": [i as u64]});
            top_level_layers.push(serde_json::json!({
                "kind": "Layer",
                "name": le.name(),
                "common": {
                    "visibility": vis,
                    "locked": le.common.locked,
                    "opacity": le.common.opacity,
                },
                "path": path_json.clone(),
            }));
            top_level_layer_paths.push(path_json);
            layer_names.insert(le.name().to_string());
        }
    }
    // next_layer_name: smallest "Layer N" not already taken
    let mut n = 1usize;
    loop {
        let candidate = format!("Layer {n}");
        if !layer_names.contains(&candidate) { break; }
        n += 1;
    }
    let next_layer_name = format!("Layer {n}");
    // new_layer_insert_index: min(selected top-level indices) + 1, else end
    let top_level_selected: Vec<usize> = layers_sel.iter()
        .filter_map(|p| if p.len() == 1 { Some(p[0]) } else { None })
        .collect();
    let new_layer_insert_index = match top_level_selected.iter().min() {
        Some(&i) => i + 1,
        None => model.document().layers.len(),
    };
    // runtime_contexts.yaml's two layers-panel rollups — "the sole selected
    // layer item is a container (group or layer)" and "at least one selected
    // layer item is a group". Declared there, read by layers.yaml's Enter
    // Isolation Mode / Flatten Artwork rows (and those actions' own
    // `enabled_when`), and built by NO port until the panel-menu
    // `enabled_when` went live and the read census found both unpublished:
    // they had evaluated null wherever anything evaluated them at all.
    let layers_panel_selection_is_container = layers_sel.len() == 1
        && matches!(
            model.document().get_element(&layers_sel[0]),
            Some(Element::Group(_)) | Some(Element::Layer(_))
        );
    let layers_panel_selection_has_group = layers_sel.iter().any(|p| {
        matches!(model.document().get_element(p), Some(Element::Group(_)))
    });
    // Canvas selection rollup (Phase 0a, Align panel): scalar/boolean
    // plus path markers for downstream predicates and list operations.
    let canvas_selection = &model.document().selection;
    let element_selection: Vec<serde_json::Value> = canvas_selection
        .iter()
        .map(|es| {
            let path_ints: Vec<u64> = es.path.iter().map(|&i| i as u64).collect();
            serde_json::json!({"__path__": path_ints})
        })
        .collect();
    // Consumed by the Boolean panel's Expand button. The one definition
    // lives in `boolean_host`, which the engine's scope also calls.
    let selection_has_compound_shape =
        crate::interpreter::boolean_host::selection_has_compound_shape(model.document());
    // The Brushes panel's two gates (W2b-18), from the one definition the
    // engine's scope also calls.
    let (has_brushed_stroke, single_brushed_stroke) =
        crate::interpreter::document_views::brushed_stroke_facts(model.document());
    // Concepts panel (Slice 2): when exactly one generated concept instance is
    // selected, expose its concept id + param schema merged with current values
    // so the panel switches to PARAMS mode; null otherwise.
    let selected_concept =
        crate::interpreter::document_views::selected_concept_view(model.document());
    // Artboard view (ARTBOARDS.md §Artboard data model).
    let doc = model.document();
    let artboards_json: Vec<serde_json::Value> = doc
        .artboards
        .iter()
        .enumerate()
        .map(|(i, a)| artboard_row(i, a))
        .collect();
    // current_artboard: topmost panel-selected, else first. THE shared rule
    // (document::artboard::current_artboard), not a second copy of it — this
    // used to be the only place the rule was written, so every other site that
    // wanted "the current artboard" reached for `artboards.first()`.
    let current: Option<&crate::document::artboard::Artboard> =
        crate::document::artboard::current_artboard(
            &doc.artboards, artboards_sel,
        );
    let current_artboard_json = match current {
        Some(a) => serde_json::json!({
            "id": a.id,
            "name": a.name,
            "x": a.x,
            "y": a.y,
            "width": a.width,
            "height": a.height,
        }),
        None => serde_json::json!({}),
    };
    let current_id = current.map(|a| serde_json::Value::String(a.id.clone())).unwrap_or(serde_json::Value::Null);
    // next_artboard_name: smallest N not used by any "Artboard N" pattern name.
    let next_artboard_name = crate::document::artboard::next_artboard_name(&doc.artboards);
    let symbols_json = crate::interpreter::document_views::symbols_view(&doc);
    let mut view = serde_json::json!({
        "top_level_layers": top_level_layers,
        "top_level_layer_paths": top_level_layer_paths,
        "next_layer_name": next_layer_name,
        "new_layer_insert_index": new_layer_insert_index,
        "layers_panel_selection_count": layers_sel.len(),
        "has_selection": !canvas_selection.is_empty(),
        "selection_count": canvas_selection.len(),
        "selection_has_compound_shape": selection_has_compound_shape,
        "element_selection": element_selection,
        "artboards": artboards_json,
        "artboard_options": {
            "fade_region_outside_artboard": doc.artboard_options.fade_region_outside_artboard,
            "update_while_dragging": doc.artboard_options.update_while_dragging,
        },
        "document_setup": {
            "bleed_top": doc.document_setup.bleed_top,
            "bleed_right": doc.document_setup.bleed_right,
            "bleed_bottom": doc.document_setup.bleed_bottom,
            "bleed_left": doc.document_setup.bleed_left,
            "bleed_uniform": doc.document_setup.bleed_uniform,
            "show_images_outline": doc.document_setup.show_images_outline,
            "highlight_substituted_glyphs": doc.document_setup.highlight_substituted_glyphs,
            "grid_size": doc.document_setup.grid_size,
            "grid_color": doc.document_setup.grid_color.clone(),
            "paper_color": doc.document_setup.paper_color.clone(),
            "simulate_colored_paper": doc.document_setup.simulate_colored_paper,
            "transparency_flattener_preset": crate::document::print_preferences::flattener_preset_str(
                &doc.document_setup.transparency_flattener_preset),
            "discard_white_overprint": doc.document_setup.discard_white_overprint,
        },
        "print_preferences": {
            "preset_name": doc.print_preferences.preset_name.clone(),
            "printer_name": doc.print_preferences.printer_name.clone()
                .map(serde_json::Value::String).unwrap_or(serde_json::Value::Null),
            "copies": doc.print_preferences.copies,
            "collate": doc.print_preferences.collate,
            "reverse_order": doc.print_preferences.reverse_order,
            "artboard_range_mode": crate::document::print_preferences::artboard_range_mode_str(&doc.print_preferences.artboard_range_mode),
            "artboard_range": doc.print_preferences.artboard_range.clone(),
            "ignore_artboards": doc.print_preferences.ignore_artboards,
            "skip_blank_artboards": doc.print_preferences.skip_blank_artboards,
            "media_size": crate::document::print_preferences::media_size_str(&doc.print_preferences.media_size),
            "media_width": doc.print_preferences.media_width,
            "media_height": doc.print_preferences.media_height,
            "orientation": crate::document::print_preferences::orientation_str(&doc.print_preferences.orientation),
            "auto_rotate": doc.print_preferences.auto_rotate,
            "transverse": doc.print_preferences.transverse,
            "print_layers": crate::document::print_preferences::print_layers_str(&doc.print_preferences.print_layers),
            "placement_x": doc.print_preferences.placement_x,
            "placement_y": doc.print_preferences.placement_y,
            "scaling_mode": crate::document::print_preferences::scaling_mode_str(&doc.print_preferences.scaling_mode),
            "custom_scale": doc.print_preferences.custom_scale,
            "tile_overlap_h": doc.print_preferences.tile_overlap_h,
            "tile_overlap_v": doc.print_preferences.tile_overlap_v,
            "tile_range": doc.print_preferences.tile_range.clone(),
            "marks_and_bleed": marks_and_bleed_view(&doc.print_preferences.marks_and_bleed),
            "output": output_view(&doc.print_preferences.output),
            "graphics": graphics_view(&doc.print_preferences.graphics),
            "color_management": color_management_view(&doc.print_preferences.color_management),
            "advanced": advanced_view(&doc.print_preferences.advanced),
        },
        "artboards_count": doc.artboards.len(),
        "next_artboard_name": next_artboard_name,
        "current_artboard_id": current_id,
        "current_artboard": current_artboard_json,
        "artboards_panel_selection_ids": artboards_sel.to_vec(),
        "artboards_panel_anchor": artboards_anchor.map(|s| serde_json::Value::String(s.to_string()))
            .unwrap_or(serde_json::Value::Null),
        "zoom_level": model.zoom_level,
        "view_offset_x": model.view_offset_x,
        "view_offset_y": model.view_offset_y,
    });
    // Inserted outside the json! literal to keep the macro under the
    // recursion limit (the tab-branch object is at the ceiling too).
    if let serde_json::Value::Object(m) = &mut view {
        m.insert("layers_panel_selection_is_container".to_string(),
                 serde_json::Value::Bool(layers_panel_selection_is_container));
        m.insert("layers_panel_selection_has_group".to_string(),
                 serde_json::Value::Bool(layers_panel_selection_has_group));
    }
    // Inserted after the json! literal: the populated active-document
    // object is already at the macro recursion ceiling, so the symbols
    // list is attached here (SYMBOLS.md §8).
    if let serde_json::Value::Object(m) = &mut view {
        m.insert("selection_has_brushed_stroke".to_string(), has_brushed_stroke.into());
        m.insert("selection_is_single_brushed_stroke".to_string(), single_brushed_stroke.into());
        m.insert("symbols".to_string(), symbols_json);
        // Concepts panel Slice 2: attached here too (macro recursion ceiling).
        m.insert("selected_concept".to_string(), selected_concept);
        // The ids `delete_empty_artboards` may remove — already filtered by the
        // preserve-position-1 rule, so the action's `foreach` stays a plain
        // mirror of `delete_artboards`. See
        // `document::evaluated_bounds::deletable_empty_artboard_ids`.
        m.insert(
            "deletable_empty_artboard_ids".to_string(),
            serde_json::Value::Array(
                crate::document::evaluated_bounds::deletable_empty_artboard_ids(doc)
                    .into_iter()
                    .map(serde_json::Value::String)
                    .collect(),
            ),
        );
    }
    // The per-document recent colours, the one writable document list
    // (`runtime_contexts.yaml`), which Color and Swatches both read.
    if let Some(m) = view.as_object_mut() {
        m.insert("recent_colors".to_string(), serde_json::json!(model.recent_colors));
        // The document's save state (`runtime_contexts.yaml`), as the menu
        // context has it (`menu_bar.rs`). Until 2026-10-14 only menus saw it,
        // so `close_tab`'s `if active_document.is_modified` was always false
        // and an edited tab closed without the Save Changes prompt.
        // `filename` is the name the tab shows (`Untitled-N` until a save);
        // `has_filename` says whether it has been saved.
        m.insert("is_modified".to_string(), serde_json::json!(model.is_modified()));
        // `any_modified`: whether ANY open document has unsaved changes, which
        // `quit` asks (`actions.yaml`). This view sees one document, so it
        // answers for that one; a host holding several overrides it
        // (`renderer::build_active_document_view`). Until 2026-10-15 no port
        // built it, so `quit` never offered to save.
        m.insert("any_modified".to_string(), serde_json::json!(model.is_modified()));
        // The selected paragraphs' justification values, which the
        // Justification dialog's `init:` reads (`paragraph_host::justification_values`).
        m.insert("paragraph_wrappers".to_string(), serde_json::Value::Object(
            crate::interpreter::paragraph_host::justification_values(model.document())));
        m.insert("has_filename".to_string(), serde_json::json!(!model.filename.starts_with("Untitled-")));
        m.insert("filename".to_string(), serde_json::json!(model.filename));
    }
    view
}

/// Build the ``marks_and_bleed`` nested object exposed under
/// ``active_document.print_preferences``. Split out so the parent
/// json! macro stays under serde's recursion limit.
pub(crate) fn marks_and_bleed_view(
    m: &crate::document::print_preferences::MarksAndBleed,
) -> serde_json::Value {
    serde_json::json!({
        "all_printer_marks": m.all_printer_marks,
        "trim_marks": m.trim_marks,
        "registration_marks": m.registration_marks,
        "color_bars": m.color_bars,
        "page_information": m.page_information,
        "printer_mark_type": crate::document::print_preferences::printer_mark_type_str(&m.printer_mark_type),
        "trim_mark_weight": m.trim_mark_weight,
        "mark_offset": m.mark_offset,
        "use_document_bleed": m.use_document_bleed,
        "bleed_top": m.bleed_top,
        "bleed_right": m.bleed_right,
        "bleed_bottom": m.bleed_bottom,
        "bleed_left": m.bleed_left,
    })
}

fn ink_override_view(ink: &crate::document::print_preferences::InkOverride) -> serde_json::Value {
    serde_json::json!({
        "name": ink.name,
        "print": ink.print,
        "frequency": ink.frequency,
        "angle": ink.angle,
        "dot_shape": crate::document::print_preferences::dot_shape_str(&ink.dot_shape),
    })
}

pub(crate) fn output_view(o: &crate::document::print_preferences::Output) -> serde_json::Value {
    let inks: Vec<serde_json::Value> = o.inks.iter().map(ink_override_view).collect();
    serde_json::json!({
        "mode": crate::document::print_preferences::output_mode_str(&o.mode),
        "emulsion": crate::document::print_preferences::emulsion_str(&o.emulsion),
        "image_polarity": crate::document::print_preferences::image_polarity_str(&o.image_polarity),
        "printer_resolution": o.printer_resolution,
        "convert_spot_to_process": o.convert_spot_to_process,
        "overprint_black": o.overprint_black,
        "inks": inks,
    })
}

pub(crate) fn advanced_view(a: &crate::document::print_preferences::Advanced) -> serde_json::Value {
    serde_json::json!({
        "print_as_bitmap": a.print_as_bitmap,
        "overprint_flattener_preset": crate::document::print_preferences::flattener_preset_str(&a.overprint_flattener_preset),
    })
}

pub(crate) fn color_management_view(c: &crate::document::print_preferences::ColorManagement) -> serde_json::Value {
    serde_json::json!({
        "document_profile": c.document_profile,
        "color_handling": crate::document::print_preferences::color_handling_str(&c.color_handling),
        "printer_profile": c.printer_profile,
        "rendering_intent": crate::document::print_preferences::rendering_intent_str(&c.rendering_intent),
        "preserve_rgb_numbers": c.preserve_rgb_numbers,
    })
}

pub(crate) fn graphics_view(g: &crate::document::print_preferences::Graphics) -> serde_json::Value {
    serde_json::json!({
        "flatness": g.flatness,
        "font_download": crate::document::print_preferences::font_download_str(&g.font_download),
        "postscript_level": crate::document::print_preferences::postscript_level_str(&g.postscript_level),
        "data_format": crate::document::print_preferences::data_format_str(&g.data_format),
        "compatible_gradient_printing": g.compatible_gradient_printing,
        "raster_effects_resolution": g.raster_effects_resolution,
    })
}

/// One row of `active_document.artboards`: the artboard's fields under the
/// canonical form's names, and its 1-based `number`. The web view and the
/// engine's panel scope both build the list from this, so a dialog's init
/// (`filter(active_document.artboards, …)[0].width`) reads the same row on
/// both routes; until 2026-10-14 the engine's rows carried `id`, `name` and
/// `number` only.
pub fn artboard_row(i: usize, a: &crate::document::artboard::Artboard) -> Value {
    json!({
        "id": a.id,
        "name": a.name,
        "number": i + 1,
        "x": a.x,
        "y": a.y,
        "width": a.width,
        "height": a.height,
        "fill": a.fill.as_canonical(),
        "show_center_mark": a.show_center_mark,
        "show_cross_hairs": a.show_cross_hairs,
        "show_video_safe_areas": a.show_video_safe_areas,
        "video_ruler_pixel_aspect_ratio": a.video_ruler_pixel_aspect_ratio,
    })
}
