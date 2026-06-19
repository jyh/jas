//! The single op dispatcher — `op_apply` (OP_LOG.md §4 / §9, Increment 3b-B).
//!
//! STAGED-ASTERISK: this is the promoted, production-shared form of what was
//! the `#[cfg(test)]` `apply_op` dispatcher. It is the §4 single-path end-state
//! built in the increment that needs it. In 3b-B it is adopted from production
//! for **exactly three replay-safe verbs** — `select_rect`, `copy_selection`,
//! and `move_selection` — which are the ones `RecordedElem.capture_recipe`
//! consumes. Those three populate `targets:[common.id]` (Fork 4); EVERY OTHER
//! verb here keeps `targets: Vec::new()` and is reachable only from the
//! `#[cfg(test)]` cross-language harness (which shims through this module so
//! harness + production share ONE dispatcher and ONE `record_op` site). The
//! other ~30 `doc.*` production verbs, the `renderer.rs::run_yaml_effect`
//! AppState-level handlers (Layers-panel Duplicate / Duplicate Artboard), the
//! per-frame drag coalescing, and the full 33-verb unification are explicitly
//! deferred per OP_LOG.md §9.
//!
//! Production input must never panic, so every param read is hardened: numbers
//! resolve with `as_f64().unwrap_or(0.0)`; a missing REQUIRED field (a path, an
//! id, a transform) early-returns/skips rather than unwrapping. The harness
//! fixtures (which always carry well-formed params) replay byte-identically.

use crate::document::controller::{self, Controller};
use crate::document::document::ElementPath;
use crate::document::model::Model;

/// The eight print-config field setters (PRINT.md §1–§6). OP_LOG.md §9 Phase P1
/// (the actions.yaml↔op_apply unification proving ground): these journal real
/// ops through `op_apply`, so the renderer.rs production handler and the replay
/// harness share ONE mutation body. Each value is a RESOLVED literal
/// (`serde_json::Value`) — replay has no eval context, so the YAML expr is
/// resolved to a number/string/bool BEFORE it reaches here. Type mismatches
/// (a string where a bool is wanted, etc.) SKIP rather than mutating, exactly
/// like the pre-P1 inline renderer blocks. Returns `true` iff a field matched
/// AND the value coerced — the caller records the op only on `true`, so a
/// type-mismatch skip journals nothing (the document is unchanged, so an empty
/// journal entry would add no information).
pub const PRINT_CONFIG_VERBS: &[&str] = &[
    "set_color_management_field",
    "set_document_setup_field",
    "set_graphics_field",
    "set_marks_and_bleed_field",
    "set_output_field",
    "set_output_ink_field",
    "set_print_preferences_field",
    "set_advanced_field",
];

/// Apply one print-config field setter to `model`, self-bracketing through
/// `edit_document` (joins an open transaction; opens its own otherwise — the
/// same write path the Controller mutators use). `verb` selects which of the
/// four print-config structs to dispatch into; `field` names the field; `value`
/// is the RESOLVED literal; `index` is the ink index (only `set_output_ink_field`
/// reads it). Returns `true` iff the field matched and the value coerced.
///
/// SHARED between `renderer.rs::run_yaml_effect` (production) and `op_apply`
/// (replay) so the field-match + type-coerce + write are byte-identical on both
/// paths (the checkpoint_equivalence gate, OP_LOG.md §6). Behavior-preserving vs
/// the pre-P1 inline blocks: every match arm and every type-mismatch skip below
/// mirrors the renderer.rs code it replaced.
pub fn apply_print_config_field(
    model: &mut Model,
    verb: &str,
    field: &str,
    value: &serde_json::Value,
    index: usize,
) -> bool {
    use crate::document::print_preferences as pp;
    // Hardened reads: a malformed production payload never panics — a
    // type-mismatch yields `None`, which the per-field arms treat as "skip".
    let as_num = value.as_f64();
    let as_bool = value.as_bool();
    let as_str = value.as_str();
    let mut new_doc = model.document().clone();
    let applied: bool = match verb {
        "set_print_preferences_field" => {
            let p = &mut new_doc.print_preferences;
            match field {
                "preset_name" => match as_str {
                    Some(s) => { p.preset_name = s.to_string(); true }
                    None => false,
                },
                "printer_name" => match as_str {
                    // Numbers/bools were explicitly rejected in the inline
                    // block; a string (incl. empty → None) is the only accept.
                    Some(s) => {
                        p.printer_name = if s.is_empty() { None } else { Some(s.to_string()) };
                        true
                    }
                    None => false,
                },
                "copies" => match as_num {
                    Some(n) => { p.copies = (n as i64).max(0) as u32; true }
                    None => false,
                },
                "collate" => match as_bool { Some(b) => { p.collate = b; true } None => false },
                "reverse_order" => match as_bool { Some(b) => { p.reverse_order = b; true } None => false },
                "artboard_range_mode" => match as_str {
                    Some(s) => { p.artboard_range_mode = pp::artboard_range_mode_from(s); true }
                    None => false,
                },
                "artboard_range" => match as_str {
                    Some(s) => { p.artboard_range = s.to_string(); true }
                    None => false,
                },
                "ignore_artboards" => match as_bool { Some(b) => { p.ignore_artboards = b; true } None => false },
                "skip_blank_artboards" => match as_bool { Some(b) => { p.skip_blank_artboards = b; true } None => false },
                "media_size" => match as_str {
                    Some(s) => { p.media_size = pp::media_size_from(s); true }
                    None => false,
                },
                "media_width" => match as_num { Some(n) => { p.media_width = n; true } None => false },
                "media_height" => match as_num { Some(n) => { p.media_height = n; true } None => false },
                "orientation" => match as_str {
                    Some(s) => { p.orientation = pp::orientation_from(s); true }
                    None => false,
                },
                "auto_rotate" => match as_bool { Some(b) => { p.auto_rotate = b; true } None => false },
                "transverse" => match as_bool { Some(b) => { p.transverse = b; true } None => false },
                "print_layers" => match as_str {
                    Some(s) => { p.print_layers = pp::print_layers_from(s); true }
                    None => false,
                },
                "placement_x" => match as_num { Some(n) => { p.placement_x = n; true } None => false },
                "placement_y" => match as_num { Some(n) => { p.placement_y = n; true } None => false },
                "scaling_mode" => match as_str {
                    Some(s) => { p.scaling_mode = pp::scaling_mode_from(s); true }
                    None => false,
                },
                "custom_scale" => match as_num { Some(n) => { p.custom_scale = n; true } None => false },
                "tile_overlap_h" => match as_num { Some(n) => { p.tile_overlap_h = n; true } None => false },
                "tile_overlap_v" => match as_num { Some(n) => { p.tile_overlap_v = n; true } None => false },
                "tile_range" => match as_str {
                    Some(s) => { p.tile_range = s.to_string(); true }
                    None => false,
                },
                _ => false,
            }
        }
        "set_marks_and_bleed_field" => {
            let m = &mut new_doc.print_preferences.marks_and_bleed;
            match field {
                "all_printer_marks" => match as_bool { Some(b) => { m.all_printer_marks = b; true } None => false },
                "trim_marks" => match as_bool { Some(b) => { m.trim_marks = b; true } None => false },
                "registration_marks" => match as_bool { Some(b) => { m.registration_marks = b; true } None => false },
                "color_bars" => match as_bool { Some(b) => { m.color_bars = b; true } None => false },
                "page_information" => match as_bool { Some(b) => { m.page_information = b; true } None => false },
                "printer_mark_type" => match as_str {
                    Some(s) => { m.printer_mark_type = pp::printer_mark_type_from(s); true }
                    None => false,
                },
                "trim_mark_weight" => match as_num { Some(n) => { m.trim_mark_weight = n; true } None => false },
                "mark_offset" => match as_num { Some(n) => { m.mark_offset = n; true } None => false },
                "use_document_bleed" => match as_bool { Some(b) => { m.use_document_bleed = b; true } None => false },
                "bleed_top" => match as_num { Some(n) => { m.bleed_top = n; true } None => false },
                "bleed_right" => match as_num { Some(n) => { m.bleed_right = n; true } None => false },
                "bleed_bottom" => match as_num { Some(n) => { m.bleed_bottom = n; true } None => false },
                "bleed_left" => match as_num { Some(n) => { m.bleed_left = n; true } None => false },
                _ => false,
            }
        }
        "set_output_field" => {
            let o = &mut new_doc.print_preferences.output;
            match field {
                "mode" => match as_str { Some(s) => { o.mode = pp::output_mode_from(s); true } None => false },
                "emulsion" => match as_str { Some(s) => { o.emulsion = pp::emulsion_from(s); true } None => false },
                "image_polarity" => match as_str { Some(s) => { o.image_polarity = pp::image_polarity_from(s); true } None => false },
                "printer_resolution" => match as_str { Some(s) => { o.printer_resolution = s.to_string(); true } None => false },
                "convert_spot_to_process" => match as_bool { Some(b) => { o.convert_spot_to_process = b; true } None => false },
                "overprint_black" => match as_bool { Some(b) => { o.overprint_black = b; true } None => false },
                _ => false,
            }
        }
        "set_output_ink_field" => {
            let inks = &mut new_doc.print_preferences.output.inks;
            match inks.get_mut(index) {
                Some(ink) => match field {
                    "print" => match as_bool { Some(b) => { ink.print = b; true } None => false },
                    "frequency" => match as_num { Some(n) => { ink.frequency = n; true } None => false },
                    "angle" => match as_num { Some(n) => { ink.angle = n; true } None => false },
                    "dot_shape" => match as_str { Some(s) => { ink.dot_shape = pp::dot_shape_from(s); true } None => false },
                    "name" => match as_str { Some(s) => { ink.name = s.to_string(); true } None => false },
                    _ => false,
                },
                // An out-of-range index is a skip (the inline block early-returned).
                None => false,
            }
        }
        "set_graphics_field" => {
            let g = &mut new_doc.print_preferences.graphics;
            match field {
                "flatness" => match as_num { Some(n) => { g.flatness = n; true } None => false },
                "font_download" => match as_str { Some(s) => { g.font_download = pp::font_download_from(s); true } None => false },
                "postscript_level" => match as_str { Some(s) => { g.postscript_level = pp::postscript_level_from(s); true } None => false },
                "data_format" => match as_str { Some(s) => { g.data_format = pp::data_format_from(s); true } None => false },
                "compatible_gradient_printing" => match as_bool { Some(b) => { g.compatible_gradient_printing = b; true } None => false },
                "raster_effects_resolution" => match as_num { Some(n) => { g.raster_effects_resolution = n; true } None => false },
                _ => false,
            }
        }
        "set_color_management_field" => {
            let c = &mut new_doc.print_preferences.color_management;
            match field {
                "document_profile" => match as_str { Some(s) => { c.document_profile = s.to_string(); true } None => false },
                "color_handling" => match as_str { Some(s) => { c.color_handling = pp::color_handling_from(s); true } None => false },
                "printer_profile" => match as_str { Some(s) => { c.printer_profile = s.to_string(); true } None => false },
                "rendering_intent" => match as_str { Some(s) => { c.rendering_intent = pp::rendering_intent_from(s); true } None => false },
                "preserve_rgb_numbers" => match as_bool { Some(b) => { c.preserve_rgb_numbers = b; true } None => false },
                _ => false,
            }
        }
        "set_advanced_field" => {
            let a = &mut new_doc.print_preferences.advanced;
            match field {
                "print_as_bitmap" => match as_bool { Some(b) => { a.print_as_bitmap = b; true } None => false },
                "overprint_flattener_preset" => match as_str {
                    Some(s) => { a.overprint_flattener_preset = pp::flattener_preset_from(s); true }
                    None => false,
                },
                _ => false,
            }
        }
        "set_document_setup_field" => {
            let d = &mut new_doc.document_setup;
            match field {
                "bleed_top" => match as_num { Some(n) => { d.bleed_top = n; true } None => false },
                "bleed_right" => match as_num { Some(n) => { d.bleed_right = n; true } None => false },
                "bleed_bottom" => match as_num { Some(n) => { d.bleed_bottom = n; true } None => false },
                "bleed_left" => match as_num { Some(n) => { d.bleed_left = n; true } None => false },
                "bleed_uniform" => match as_bool { Some(b) => { d.bleed_uniform = b; true } None => false },
                "show_images_outline" => match as_bool { Some(b) => { d.show_images_outline = b; true } None => false },
                "highlight_substituted_glyphs" => match as_bool { Some(b) => { d.highlight_substituted_glyphs = b; true } None => false },
                "simulate_colored_paper" => match as_bool { Some(b) => { d.simulate_colored_paper = b; true } None => false },
                "discard_white_overprint" => match as_bool { Some(b) => { d.discard_white_overprint = b; true } None => false },
                "grid_size" => match as_num { Some(n) => { d.grid_size = n; true } None => false },
                // grid_color/paper_color accept any string (the inline block
                // accepted both Value::Str and the hex-coerced Value::Color,
                // which both serialize to a JSON string).
                "grid_color" => match as_str { Some(s) => { d.grid_color = s.to_string(); true } None => false },
                "paper_color" => match as_str { Some(s) => { d.paper_color = s.to_string(); true } None => false },
                "transparency_flattener_preset" => match as_str {
                    Some(s) => { d.transparency_flattener_preset = pp::flattener_preset_from(s); true }
                    None => false,
                },
                _ => false,
            }
        }
        _ => false,
    };
    if applied {
        model.edit_document(new_doc);
    }
    applied
}

// ── Artboard doc.* setters (OP_LOG.md §9 Phase P2) ────────────────────────────
//
// The five no-id-minting artboard verbs journal real ops through `op_apply`, so
// the renderer.rs production handler and the replay harness share ONE mutation
// body (the P1 print-config pattern, applied to artboards). Each op carries
// RESOLVED literals (the renderer evals the YAML exprs before building the op;
// replay has no eval context). Hardened reads: a malformed payload SKIPS rather
// than panicking, and a no-op edit (type mismatch / missing id / boundary swap /
// missing delete) journals nothing — the caller records only on an effective
// change. The id-minting verbs `create_artboard` / `duplicate_artboard` are
// handled separately below (Phase P3, VALUE-IN-OP id strategy): the id is minted
// at production time and recorded as a LITERAL, so this layer NEVER mints on
// replay. Artboards live in `document.artboards` (String ids), NOT the element
// tree, so `targets` carries the written artboard id(s) (delete → the deleted id;
// set_artboard_field → the written id; move → the moved ids; create/duplicate →
// the new id), and `set_artboard_options_field` carries [] (document-global). The
// byte-gate ignores `targets`; this is best-effort merge metadata.

/// Apply one field of one artboard (by id) to `model`, self-bracketing through
/// `edit_document`. `value` is a RESOLVED literal. Returns `true` iff the
/// artboard exists AND the field matched AND the value coerced — the caller
/// records the op only on `true`. Field types mirror renderer.rs's
/// `apply_artboard_override` (the create/duplicate path), kept at the document
/// layer here so `op_apply` does not reach up into the interpreter layer.
pub fn apply_set_artboard_field(
    model: &mut Model,
    id: &str,
    field: &str,
    value: &serde_json::Value,
) -> bool {
    use crate::document::artboard::ArtboardFill;
    let as_num = value.as_f64();
    let as_bool = value.as_bool();
    let as_str = value.as_str();
    let mut new_doc = model.document().clone();
    let Some(ab) = new_doc.artboards.iter_mut().find(|a| a.id == id) else {
        return false;
    };
    let applied = match field {
        "name" => match as_str { Some(s) => { ab.name = s.to_string(); true } None => false },
        "x" => match as_num { Some(n) => { ab.x = n; true } None => false },
        "y" => match as_num { Some(n) => { ab.y = n; true } None => false },
        "width" => match as_num { Some(n) => { ab.width = n; true } None => false },
        "height" => match as_num { Some(n) => { ab.height = n; true } None => false },
        // A hex color and a plain string both arrive here as a JSON string;
        // ArtboardFill::from_canonical handles both (matching the renderer's
        // Str/Color acceptance for create/duplicate).
        "fill" => match as_str { Some(s) => { ab.fill = ArtboardFill::from_canonical(s); true } None => false },
        "show_center_mark" => match as_bool { Some(b) => { ab.show_center_mark = b; true } None => false },
        "show_cross_hairs" => match as_bool { Some(b) => { ab.show_cross_hairs = b; true } None => false },
        "show_video_safe_areas" => match as_bool { Some(b) => { ab.show_video_safe_areas = b; true } None => false },
        "video_ruler_pixel_aspect_ratio" => match as_num { Some(n) => { ab.video_ruler_pixel_aspect_ratio = n; true } None => false },
        _ => false,
    };
    if applied {
        model.edit_document(new_doc);
    }
    applied
}

/// Apply one document-global artboard-options field (PRINT-adjacent; bool only).
/// Returns `true` iff the field matched and the value coerced to a bool.
pub fn apply_set_artboard_options_field(
    model: &mut Model,
    field: &str,
    value: &serde_json::Value,
) -> bool {
    let Some(flag) = value.as_bool() else { return false; };
    let mut new_doc = model.document().clone();
    let applied = match field {
        "fade_region_outside_artboard" => { new_doc.artboard_options.fade_region_outside_artboard = flag; true }
        "update_while_dragging" => { new_doc.artboard_options.update_while_dragging = flag; true }
        _ => false,
    };
    if applied {
        model.edit_document(new_doc);
    }
    applied
}

/// Delete the artboard whose id == `id`. Returns `true` iff an artboard was
/// removed (a missing id is a no-op that journals nothing).
pub fn apply_delete_artboard_by_id(model: &mut Model, id: &str) -> bool {
    let mut new_doc = model.document().clone();
    let before = new_doc.artboards.len();
    new_doc.artboards.retain(|a| a.id != id);
    if new_doc.artboards.len() < before {
        model.edit_document(new_doc);
        true
    } else {
        false
    }
}

/// Swap-with-neighbor-skipping-selected for Move Up (ARTBOARDS.md §Reordering),
/// in-place on `artboards`. Returns `true` iff any swap occurred. Pure helper
/// (no Model) so renderer.rs's create-time path and the unit test can call it.
pub fn move_artboards_up_in_place(
    artboards: &mut [crate::document::artboard::Artboard],
    selected_ids: &[String],
) -> bool {
    let selected: std::collections::HashSet<&str> =
        selected_ids.iter().map(|s| s.as_str()).collect();
    let mut changed = false;
    for i in 0..artboards.len() {
        if !selected.contains(artboards[i].id.as_str()) {
            continue;
        }
        if i == 0 {
            continue;
        }
        if selected.contains(artboards[i - 1].id.as_str()) {
            continue;
        }
        artboards.swap(i - 1, i);
        changed = true;
    }
    changed
}

/// Symmetric Move Down. Returns `true` iff any swap occurred.
pub fn move_artboards_down_in_place(
    artboards: &mut [crate::document::artboard::Artboard],
    selected_ids: &[String],
) -> bool {
    let selected: std::collections::HashSet<&str> =
        selected_ids.iter().map(|s| s.as_str()).collect();
    let mut changed = false;
    let n = artboards.len();
    for i in (0..n).rev() {
        if !selected.contains(artboards[i].id.as_str()) {
            continue;
        }
        if i + 1 >= n {
            continue;
        }
        if selected.contains(artboards[i + 1].id.as_str()) {
            continue;
        }
        artboards.swap(i, i + 1);
        changed = true;
    }
    changed
}

/// Apply Move Up to `model`'s artboards. Returns `true` iff any swap occurred.
pub fn apply_move_artboards_up(model: &mut Model, ids: &[String]) -> bool {
    let mut new_doc = model.document().clone();
    if move_artboards_up_in_place(&mut new_doc.artboards, ids) {
        model.edit_document(new_doc);
        true
    } else {
        false
    }
}

/// Apply Move Down to `model`'s artboards. Returns `true` iff any swap occurred.
pub fn apply_move_artboards_down(model: &mut Model, ids: &[String]) -> bool {
    let mut new_doc = model.document().clone();
    if move_artboards_down_in_place(&mut new_doc.artboards, ids) {
        model.edit_document(new_doc);
        true
    } else {
        false
    }
}

// ── OP_LOG.md §9 Phase P3 — the TWO id-minting artboard verbs ──────────────
//
// `create_artboard` / `duplicate_artboard` are the first id-MINTING verbs to
// journal through `op_apply`, under the VALUE-IN-OP id strategy (REFERENCE_GRAPH.md
// §4 / OP_LOG.md §7): the id is minted ONCE at production capture time (the
// renderer.rs handler keeps the entropic collision-retry mint), then written into
// the op params as a LITERAL — `create_artboard.id` / `duplicate_artboard.new_id`.
// These two Model-level helpers REPLAY from that recorded id and the other RESOLVED
// params VERBATIM: they NEVER call generate_artboard_id, NEVER tap platform
// entropy, and NEVER run the collision-retry, so replay is a pure deterministic
// function of the journal even though the original mint was entropic. Both write
// via `edit_document` (self-bracketing: joins an open transaction, opens its own
// otherwise) so the renderer.rs handler (after it mints) and the op_apply arm share
// ONE mutation body — the checkpoint_equivalence gate (OP_LOG.md §6) then proves the
// captured-id replay reproduces the minted-id production byte-identically.

/// Append a new artboard with the GIVEN (already-minted) `id`, applying the
/// RESOLVED `fields` overrides on top of the canonical default. `id` is taken
/// VERBATIM — no minting, no collision-retry, no entropy. Each field is a RESOLVED
/// literal; a type mismatch on any field SKIPS that field (matching the renderer's
/// create-path tolerance) without failing the create. The default name is the
/// canonical `Artboard 1` from `Artboard::default_with_id`; a `name` override (if
/// present and a string) replaces it. Always an effective change (an artboard is
/// always appended), so this returns `()` — the caller always records the op.
pub fn apply_create_artboard(
    model: &mut Model,
    id: &str,
    fields: &serde_json::Value,
) {
    use crate::document::artboard::Artboard;
    let mut new_doc = model.document().clone();
    let mut ab = Artboard::default_with_id(id.to_string());
    // Apply the RESOLVED field overrides (the same field set + types as
    // `apply_set_artboard_field`, so the create-path and the set-path coerce a
    // value identically). A non-object `fields` (or a missing one) leaves the
    // default artboard untouched.
    if let Some(map) = fields.as_object() {
        for (field, value) in map {
            apply_artboard_field_in_place(&mut ab, field, value);
        }
    }
    new_doc.artboards.push(ab);
    model.edit_document(new_doc);
}

/// Clone the artboard whose id == `source_id`, assign the GIVEN (already-minted)
/// `new_id` and `name` VERBATIM, and offset its position by `(ox, oy)`. Returns
/// `true` iff the source existed (a missing source is a no-op that journals
/// nothing). No minting / no name-derivation / no entropy here — both the id and
/// the name are recorded literals (the renderer derives the name via
/// `next_artboard_name` at production time and journals the result).
pub fn apply_duplicate_artboard(
    model: &mut Model,
    source_id: &str,
    new_id: &str,
    name: &str,
    ox: f64,
    oy: f64,
) -> bool {
    use crate::document::artboard::Artboard;
    let mut new_doc = model.document().clone();
    let Some(source) = new_doc.artboards.iter().find(|a| a.id == source_id).cloned() else {
        return false;
    };
    let mut dup = Artboard { id: new_id.to_string(), ..source };
    dup.name = name.to_string();
    dup.x += ox;
    dup.y += oy;
    new_doc.artboards.push(dup);
    model.edit_document(new_doc);
    true
}

/// Apply one RESOLVED field literal to an in-flight `Artboard` (the create-path
/// field application). Mirrors `apply_set_artboard_field`'s field set + type
/// coercion exactly, but operates on a bare `Artboard` (no Model / no id lookup)
/// because the create path is building a NOT-YET-INSERTED artboard. A type
/// mismatch or unknown field is silently skipped (the field keeps its default),
/// matching renderer.rs's `apply_artboard_override` tolerance.
fn apply_artboard_field_in_place(
    ab: &mut crate::document::artboard::Artboard,
    field: &str,
    value: &serde_json::Value,
) {
    use crate::document::artboard::ArtboardFill;
    let as_num = value.as_f64();
    let as_bool = value.as_bool();
    let as_str = value.as_str();
    match field {
        "name" => if let Some(s) = as_str { ab.name = s.to_string(); },
        "x" => if let Some(n) = as_num { ab.x = n; },
        "y" => if let Some(n) = as_num { ab.y = n; },
        "width" => if let Some(n) = as_num { ab.width = n; },
        "height" => if let Some(n) = as_num { ab.height = n; },
        "fill" => if let Some(s) = as_str { ab.fill = ArtboardFill::from_canonical(s); },
        "show_center_mark" => if let Some(b) = as_bool { ab.show_center_mark = b; },
        "show_cross_hairs" => if let Some(b) = as_bool { ab.show_cross_hairs = b; },
        "show_video_safe_areas" => if let Some(b) = as_bool { ab.show_video_safe_areas = b; },
        "video_ruler_pixel_aspect_ratio" => if let Some(n) = as_num { ab.video_ruler_pixel_aspect_ratio = n; },
        _ => {}
    }
}

// ── OP_LOG.md §9 Phase P4 — the structural tree-mutation verbs ──────────────
//
// `delete_at` / `delete_selection` / `insert_after` / `insert_at` are the first
// verbs that mutate the ELEMENT TREE (not the artboard list / print config) to
// journal through `op_apply`, so the renderer.rs production handler and the replay
// harness share ONE mutation body. The two INSERTING verbs use the VALUE-IN-OP
// strategy at full strength (OP_LOG.md §7): the op carries the ENTIRE element to
// insert as LITERAL serde JSON in the params (exactly as P3 carried the minted id,
// but now the value is a whole `Element`). In production the element comes from a
// preceding NON-JOURNALED binder — `clone_at` (binds a clone of an existing
// element as JSON in ctx) or `create_layer` (a deterministic factory producing a
// Layer as JSON). Those binders stay non-journaled (they only produce ctx values);
// only the resulting `insert_after`/`insert_at` journals, carrying the produced
// element JSON. On replay these helpers deserialize the element from the op JSON
// via `serde_json::from_value::<Element>` (Element derives Deserialize, so this
// layer is self-contained — no interpreter import) and insert it BYTE-IDENTICALLY:
// the clone keeps whatever id it had (value-in-op ⇒ replay inserts the same id),
// which the checkpoint_equivalence gate (OP_LOG.md §6) proves via
// document_to_test_json. Hardened reads: a malformed/absent element or path SKIPS
// rather than panicking; an effective-change check (delete a present path / a
// non-empty selection) means a no-op edit journals nothing. Elements live in the
// `document.layers` tree (paths, not ids), so `targets` carries the affected
// element's `common.id` when it has one, else `[]` (delete_selection carries the
// pre-deletion selection ids).

/// Deserialize the `element` op param into an [`Element`]. Returns `None` if the
/// field is absent or is not a valid serialized Element (a malformed production
/// payload skips the op rather than panicking — the value-in-op element must
/// round-trip, so a non-Element value is a hard skip).
fn parse_element(op: &serde_json::Value) -> Option<crate::geometry::element::Element> {
    let v = op.get("element")?;
    serde_json::from_value::<crate::geometry::element::Element>(v.clone()).ok()
}

/// The `common.id` of an Element, or `None` when id-less. Used to populate
/// `targets` for the inserting verbs (Fork 4 merge metadata; the byte-gate
/// ignores it).
fn element_id(el: &crate::geometry::element::Element) -> Option<String> {
    el.common().id.clone()
}

/// Delete the element at `path`. Returns `true` iff an element was present and
/// removed (an absent path is a no-op that journals nothing). Self-bracketing
/// through `edit_document` (joins an open transaction; opens its own otherwise),
/// so the renderer.rs handler and this arm share ONE mutation body. The deleted
/// element's id (if any) is returned to the caller for `targets`.
pub fn apply_delete_element_at(
    model: &mut Model,
    path: &ElementPath,
) -> (bool, Vec<String>) {
    let doc = model.document().clone();
    let Some(existing) = doc.get_element(path) else {
        return (false, Vec::new());
    };
    let targets: Vec<String> = element_id(existing).into_iter().collect();
    let new_doc = doc.delete_element(path);
    model.edit_document(new_doc);
    (true, targets)
}

/// Delete every currently-selected element (reference-aware delete path). Returns
/// the pre-deletion selection ids (for `targets`) and `true` iff the selection
/// was non-empty (an empty selection is a no-op that journals nothing). The
/// document's serialized selection IS the operand — no params.
pub fn apply_delete_selection(model: &mut Model) -> (bool, Vec<String>) {
    let doc = model.document();
    if doc.selection.is_empty() {
        return (false, Vec::new());
    }
    let targets = controller::selection_to_ids(doc);
    let new_doc = doc.delete_selection();
    model.edit_document(new_doc);
    (true, targets)
}

/// Insert `element` immediately after the element at `path`. The element is taken
/// VERBATIM (value-in-op): whatever id it carries is inserted as-is, so replay is
/// byte-identical to production. Returns the inserted element's id (if any) for
/// `targets`. An empty path is a no-op at the document layer
/// (`insert_element_after` returns the document unchanged); we still journal it
/// only on the renderer's resolved-path contract — the harness fixtures always
/// supply a well-formed path, and the gate would catch a non-effective insert.
pub fn apply_insert_element_after(
    model: &mut Model,
    path: &ElementPath,
    element: crate::geometry::element::Element,
) -> Vec<String> {
    let targets: Vec<String> = element_id(&element).into_iter().collect();
    let new_doc = model.document().clone().insert_element_after(path, element);
    model.edit_document(new_doc);
    targets
}

/// Insert `element` at `index` under `parent_path` (an empty `parent_path` inserts
/// into the top-level `layers` array). The element is taken VERBATIM (value-in-op).
/// Returns the inserted element's id (if any) for `targets`. Mirrors renderer.rs's
/// `insert_element_at` body exactly so the production and replay paths agree.
pub fn apply_insert_element_at(
    model: &mut Model,
    parent_path: &ElementPath,
    index: usize,
    element: crate::geometry::element::Element,
) -> Vec<String> {
    let targets: Vec<String> = element_id(&element).into_iter().collect();
    let mut new_doc = model.document().clone();
    if parent_path.is_empty() {
        let idx = index.min(new_doc.layers.len());
        new_doc.layers.insert(idx, element);
    } else {
        let mut insert_path = parent_path.clone();
        insert_path.push(index);
        new_doc = new_doc.insert_element_at(&insert_path, element);
    }
    model.edit_document(new_doc);
    targets
}

// ── OP_LOG.md §9 Phase P5 — the group/layer wrapping verbs ──────────────────
//
// `wrap_in_group` / `wrap_in_layer` / `unpack_group_at` are the highest-structural-
// complexity verbs to journal through `op_apply`: each is a MULTI-STEP mutation
// (collect elements at paths, reverse-delete them, build a container, insert it)
// that must replay as ONE deterministic op. The multi-step algorithm — sort paths
// in document order, collect clones, delete in REVERSE order, build the container,
// insert at the topmost source index (group) / append (layer) — lives ENTIRELY in
// these three Model-level helpers, so the renderer.rs production handlers and the
// op_apply replay arms share ONE mutation body (the byte-gate, OP_LOG.md §6, then
// proves they agree). Each op carries enough to replay byte-identically:
//   - `paths`: the RESOLVED plain index arrays (`[[..],..]`). The renderer
//     represents path lists internally as `{__path__:[..]}` markers; it normalizes
//     them to plain arrays BEFORE building the op, so this layer parses uniformly.
//   - `name` (wrap_in_layer only): the RESOLVED name LITERAL. The renderer evals
//     `active_document.next_layer_name` against the LIVE doc FIRST and journals the
//     result; replay reuses that literal rather than re-deriving a possibly-
//     colliding name from the (now-mutated) tree.
//   - `id` (optional, value-in-op): when the action assigns a container id, it is a
//     LITERAL in the op; absent ⇒ the container is born id-less.
// Hardened reads: a malformed `paths` (not an array of index arrays) or a missing/
// non-Group target SKIPS rather than panicking, and an empty/non-effective edit
// journals nothing (the caller records only on `true`). Elements live in the
// `document.layers` tree (paths, not ids), so `targets` carries the wrapped
// element ids PLUS the container id when assigned (wrap_*), or the unpacked
// children ids (unpack); the byte-gate ignores `targets` (merge metadata).

/// Parse the `paths` op param — a JSON array of index arrays (`[[..],..]`) — into
/// a `Vec<ElementPath>`. Returns `None` if the field is absent or is not an array
/// of arrays of non-negative integers (a malformed payload skips the op rather
/// than panicking). An empty top-level array yields `Some(vec![])`, which the
/// caller treats as a no-op (journals nothing).
fn parse_path_list(v: Option<&serde_json::Value>) -> Option<Vec<ElementPath>> {
    let arr = v?.as_array()?;
    let mut out: Vec<ElementPath> = Vec::with_capacity(arr.len());
    for item in arr {
        // Each item must itself be an array of indices; a non-array entry makes
        // the whole list malformed (hard skip — no partial wraps).
        let inner = item.as_array()?;
        let mut path: ElementPath = Vec::with_capacity(inner.len());
        for n in inner {
            path.push(n.as_u64()? as usize);
        }
        out.push(path);
    }
    Some(out)
}

/// The `common.id` of an Element-like container's common props, helper for targets.
fn opt_id(common: &crate::geometry::element::CommonProps) -> Option<String> {
    common.id.clone()
}

/// Collect (in sorted document order) clones of the elements at `paths`, plus
/// their ids for `targets`. Returns `(children, child_ids, sorted_paths)`. A path
/// that resolves to nothing is silently dropped (matching the renderer's
/// `get_element` filter); `sorted_paths` is the input sorted ascending (the order
/// both the collect and the reverse-delete depend on).
fn collect_children_for_wrap(
    doc: &crate::document::document::Document,
    paths: &[ElementPath],
) -> (
    Vec<std::rc::Rc<crate::geometry::element::Element>>,
    Vec<String>,
    Vec<ElementPath>,
) {
    use std::rc::Rc;
    let mut sorted = paths.to_vec();
    sorted.sort();
    let mut children: Vec<Rc<crate::geometry::element::Element>> = Vec::new();
    let mut ids: Vec<String> = Vec::new();
    for p in &sorted {
        if let Some(elem) = doc.get_element(p) {
            if let Some(id) = element_id(elem) {
                ids.push(id);
            }
            children.push(Rc::new(elem.clone()));
        }
    }
    (children, ids, sorted)
}

/// Wrap the elements at `paths` in a new Group (OP_LOG.md §9 Phase P5). Collects
/// clones in document order, reverse-deletes the sources, builds a Group carrying
/// them as children (with the optional value-in-op `id`), and inserts it at the
/// TOPMOST source index under the shared parent. Self-bracketing through
/// `edit_document` (joins an open transaction; opens its own otherwise), so the
/// renderer.rs handler and the op_apply arm share ONE mutation body. Returns
/// `(changed, targets)`: `changed` is `false` (no-op, journals nothing) when no
/// source element resolved or the topmost path is empty; `targets` is the wrapped
/// child ids plus the group id when assigned.
pub fn apply_wrap_in_group(
    model: &mut Model,
    paths: &[ElementPath],
    id: Option<&str>,
) -> (bool, Vec<String>) {
    use crate::geometry::element::{Element, GroupElem, CommonProps};
    let doc = model.document().clone();
    let (children, child_ids, sorted) = collect_children_for_wrap(&doc, paths);
    // No source resolved ⇒ nothing to wrap (no-op, journals nothing).
    if children.is_empty() {
        return (false, Vec::new());
    }
    // The insertion site is the topmost (smallest) source path: split into the
    // shared parent + the final index. An empty topmost path is malformed.
    let first = &sorted[0];
    if first.is_empty() {
        return (false, Vec::new());
    }
    let insert_parent: ElementPath = first[..first.len() - 1].to_vec();
    let insert_index = first[first.len() - 1];
    // Reverse-delete the sources (descending paths keep indices valid).
    let mut new_doc = doc;
    for p in sorted.iter().rev() {
        new_doc = new_doc.delete_element(p);
    }
    // Build the group (value-in-op id when assigned, else id-less).
    let common = CommonProps {
        id: id.map(|s| s.to_string()),
        ..Default::default()
    };
    let mut targets = child_ids;
    if let Some(group_id) = opt_id(&common) {
        targets.push(group_id);
    }
    let group = Element::Group(GroupElem {
        children,
        common,
        isolated_blending: false,
        knockout_group: false,
    });
    // Insert at the topmost index (empty parent ⇒ top-level layers array).
    if insert_parent.is_empty() {
        let idx = insert_index.min(new_doc.layers.len());
        new_doc.layers.insert(idx, group);
    } else {
        let mut insert_path = insert_parent;
        insert_path.push(insert_index);
        new_doc = new_doc.insert_element_at(&insert_path, group);
    }
    model.edit_document(new_doc);
    (true, targets)
}

/// Wrap the elements at `paths` in a new top-level Layer with the RESOLVED `name`
/// LITERAL (OP_LOG.md §9 Phase P5). Parallel to `apply_wrap_in_group` but always
/// APPENDS the new Layer to the top-level `layers` array. The `name` is taken
/// VERBATIM — the renderer resolved `next_layer_name` against the live doc before
/// journaling, so replay never re-derives a colliding name. Optional value-in-op
/// `id`. Returns `(changed, targets)`: `changed` is `false` (no-op) when no source
/// resolved; `targets` is the wrapped child ids plus the layer id when assigned.
pub fn apply_wrap_in_layer(
    model: &mut Model,
    paths: &[ElementPath],
    name: &str,
    id: Option<&str>,
) -> (bool, Vec<String>) {
    use crate::geometry::element::{Element, LayerElem, CommonProps};
    let doc = model.document().clone();
    let (children, child_ids, sorted) = collect_children_for_wrap(&doc, paths);
    if children.is_empty() {
        return (false, Vec::new());
    }
    let mut new_doc = doc;
    for p in sorted.iter().rev() {
        new_doc = new_doc.delete_element(p);
    }
    let common = CommonProps {
        name: Some(name.to_string()),
        id: id.map(|s| s.to_string()),
        ..Default::default()
    };
    let mut targets = child_ids;
    if let Some(layer_id) = opt_id(&common) {
        targets.push(layer_id);
    }
    let new_layer = Element::Layer(LayerElem {
        children,
        common,
        isolated_blending: false,
        knockout_group: false,
    });
    new_doc.layers.push(new_layer);
    model.edit_document(new_doc);
    (true, targets)
}

/// Unpack the Group at `path` (OP_LOG.md §9 Phase P5): extract its children,
/// delete the group, and re-insert the children at the vacated position with
/// ascending indices (children keep their ids — NO minting). Self-bracketing
/// through `edit_document`. A non-Group target (or an absent path) is a no-op that
/// journals nothing. Returns `(changed, targets)` where `targets` is the unpacked
/// children's ids.
pub fn apply_unpack_group_at(
    model: &mut Model,
    path: &ElementPath,
) -> (bool, Vec<String>) {
    use crate::geometry::element::Element;
    let doc = model.document().clone();
    // The target must be a Group; anything else (incl. an absent path) is a no-op.
    let children: Vec<Element> = match doc.get_element(path) {
        Some(Element::Group(g)) => g.children.iter().map(|rc| (**rc).clone()).collect(),
        _ => return (false, Vec::new()),
    };
    let targets: Vec<String> = children.iter().filter_map(element_id).collect();
    let mut new_doc = doc.delete_element(path);
    // Insert children at the vacated position, ascending the final index so they
    // land in their original document order at the group's former slot.
    let mut insert_path = path.clone();
    for child in children {
        new_doc = new_doc.insert_element_at(&insert_path, child);
        let last = insert_path.len() - 1;
        insert_path[last] += 1;
    }
    model.edit_document(new_doc);
    (true, targets)
}

/// Read a JSON array-of-strings field (the `ids` payload for the move verbs).
/// Non-string entries are dropped; a missing/non-array field yields `[]`.
fn str_list_field(op: &serde_json::Value, key: &str) -> Vec<String> {
    op.get(key)
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
        .unwrap_or_default()
}

/// Parse a JSON array of indices into an [`ElementPath`]. Returns `None` if the
/// field is absent or not an array of non-negative integers (a malformed
/// production payload skips the op rather than panicking).
fn parse_path(v: Option<&serde_json::Value>) -> Option<ElementPath> {
    let arr = v?.as_array()?;
    Some(arr.iter().map(|i| i.as_u64().unwrap_or(0) as usize).collect())
}

/// Read a string field, or `None` if absent / not a string.
fn str_field<'a>(op: &'a serde_json::Value, key: &str) -> Option<&'a str> {
    op.get(key).and_then(|v| v.as_str())
}

/// Read an f64 field, defaulting to 0.0 (the non-panicking number form).
fn num_field(op: &serde_json::Value, key: &str) -> f64 {
    op.get(key).and_then(|v| v.as_f64()).unwrap_or(0.0)
}

/// The single op dispatcher (OP_LOG.md §4). Applies one primitive op to the
/// model and records it into the open transaction (the `checkpoint_equivalence`
/// gate, §5-6). History-navigation ops (`snapshot`/`undo`/`redo`) manage the
/// transaction boundary / journal cursor and are NOT primitive ops, so they
/// early-return WITHOUT being journaled. `record_op` is a no-op when no
/// transaction is open, so this is safe to call unconditionally.
pub fn op_apply(model: &mut Model, op: &serde_json::Value) {
    let Some(name) = op["op"].as_str() else {
        // A primitive op with no verb is malformed; skip it (never panic).
        return;
    };
    // History-navigation ops (OP_LOG.md §5): they manage transaction
    // boundaries / the journal cursor and are NOT primitive ops, so they
    // are never journaled. `snapshot` commits the prior action's
    // transaction (relocated redo-clear) and opens a new one, so the
    // mutator ops that follow JOIN one checkpoint; undo/redo end the open
    // context and move the cursor.
    match name {
        "snapshot" => {
            model.commit_txn();
            model.begin_txn();
            return;
        }
        "undo" => {
            model.undo();
            return;
        }
        "redo" => {
            model.redo();
            return;
        }
        _ => {}
    }
    // OP_LOG.md §9 (Increment 3b-B) — close the subsequent-drag-frame
    // journaling hole. Every verb below except `select_rect` is an UNDOABLE
    // mutation that writes through `edit_document`, which SELF-BRACKETS
    // (begin/write/commit) when no transaction is open. On a bare drag frame
    // (selection.yaml emits `doc.snapshot` only on the FIRST mousemove), that
    // self-commit closes the transaction BEFORE `record_op` runs (so the op is
    // dropped) and before the batch owner's `name_txn`/`commit_txn` fires (so
    // the txn is unnamed). Opening the transaction HERE — and leaving it OPEN —
    // makes `edit_document` JOIN it (in_txn==true ⇒ no self-commit), so
    // `record_op` lands the op and the batch owner (run_effects /
    // run_yaml_effects) names + commits the single transaction. `begin_txn` is
    // a no-op while one is already open, so the harness (which always brackets
    // around `op_apply`) and the snapshot-led first frame are byte-unchanged.
    // `select_rect` is EXCLUDED: it only changes selection (non-undoable,
    // serialized state), so a bare marquee must stay journal-neutral — opening a
    // txn for it would spuriously journal a selection-only batch as an
    // undoable step.
    if name != "select_rect" && !model.in_txn() {
        model.begin_txn();
    }
    // Fork-4 `targets` (OP_LOG.md §9). Populated for the THREE replay-safe
    // verbs `capture_recipe` consumes; every other verb keeps it empty.
    // `move_selection`/`copy_selection` resolve the source ids BEFORE the
    // mutation (a copy is born id-less; a move can change which ids are
    // selected — pre-mutation avoids the post-mutation-id hazard).
    // `select_rect` resolves AFTER its Controller call (the selection it just
    // established IS the keystone targets).
    let mut targets: Vec<String> = Vec::new();
    if name == "move_selection" || name == "copy_selection" {
        targets = controller::selection_to_ids(model.document());
    }
    match name {
        "select_rect" => {
            Controller::select_rect(
                model,
                num_field(op, "x"),
                num_field(op, "y"),
                num_field(op, "width"),
                num_field(op, "height"),
                op["extend"].as_bool().unwrap_or(false),
            );
            // Keystone: the resolved selection is this op's targets, so
            // `capture_recipe` can seed its working set (empty targets ⇒
            // empty recipe). Resolved AFTER the Controller call.
            targets = controller::selection_to_ids(model.document());
        }
        "move_selection" => {
            Controller::move_selection(model, num_field(op, "dx"), num_field(op, "dy"));
        }
        "copy_selection" => {
            Controller::copy_selection(model, num_field(op, "dx"), num_field(op, "dy"));
        }
        "assign_id" => {
            let (Some(path), Some(id)) = (parse_path(op.get("path")), str_field(op, "id"))
            else {
                return;
            };
            Controller::assign_id(model, &path, id);
        }
        "create_reference" => {
            let (Some(target_path), Some(target_id), Some(ref_id)) = (
                parse_path(op.get("target_path")),
                str_field(op, "target_id"),
                str_field(op, "ref_id"),
            ) else {
                return;
            };
            Controller::create_reference(model, &target_path, target_id, ref_id);
        }
        // Symbols P2 operations (SYMBOLS.md §7). Value-in-op: the ids and
        // paths are read literally from the fixture payload, exactly like
        // the create_reference arm.
        "make_symbol" => {
            let (Some(path), Some(master_id), Some(ref_id)) = (
                parse_path(op.get("path")),
                str_field(op, "master_id"),
                str_field(op, "ref_id"),
            ) else {
                return;
            };
            Controller::make_symbol(model, &path, master_id, ref_id);
        }
        "place_instance" => {
            let (Some(master_id), Some(ref_id)) =
                (str_field(op, "master_id"), str_field(op, "ref_id"))
            else {
                return;
            };
            Controller::place_instance(model, master_id, ref_id);
        }
        "detach" => {
            let Some(path) = parse_path(op.get("path")) else {
                return;
            };
            Controller::detach(model, &path);
        }
        "redefine" => {
            let (Some(master_id), Some(path), Some(ref_id)) = (
                str_field(op, "master_id"),
                parse_path(op.get("path")),
                str_field(op, "ref_id"),
            ) else {
                return;
            };
            Controller::redefine(model, master_id, &path, ref_id);
        }
        "delete_symbol" => {
            let Some(master_id) = str_field(op, "master_id") else {
                return;
            };
            Controller::delete_symbol(model, master_id);
        }
        // Symbols P4 (SYMBOLS.md §4 / Fork F2). Value-in-op: the instance
        // transform is carried in the payload as {a,b,c,d,e,f} (the same
        // matrix shape parsed elsewhere) and applied verbatim.
        "set_instance_transform" => {
            let Some(path) = parse_path(op.get("path")) else {
                return;
            };
            let t = &op["transform"];
            if !t.is_object() {
                return;
            }
            let transform = crate::geometry::element::Transform {
                a: num_field(t, "a"),
                b: num_field(t, "b"),
                c: num_field(t, "c"),
                d: num_field(t, "d"),
                e: num_field(t, "e"),
                f: num_field(t, "f"),
            };
            Controller::set_instance_transform(model, &path, transform);
        }
        // Structural tree-mutation verbs (OP_LOG.md §9 Phase P4). `delete_at` /
        // `delete_selection` / `insert_after` / `insert_at` mutate the element
        // TREE through the SHARED helpers (apply_delete_element_at /
        // apply_delete_selection / apply_insert_element_after /
        // apply_insert_element_at), so the renderer.rs handlers and these arms
        // share ONE mutation body. The inserting verbs carry the WHOLE element as
        // LITERAL serde JSON (value-in-op, OP_LOG.md §7) — `parse_element`
        // deserializes it defensively (a non-Element value SKIPS). Hardened reads:
        // a missing/malformed path or element early-returns BEFORE record_op, and
        // a no-op edit (absent delete path / empty selection) journals nothing.
        // targets carry the affected element's id (delete_selection → the
        // pre-deletion selection ids).
        "delete_at" => {
            let Some(path) = parse_path(op.get("path")) else {
                return;
            };
            let (changed, t) = apply_delete_element_at(model, &path);
            if !changed {
                return;
            }
            targets = t;
        }
        "delete_selection" => {
            let (changed, t) = apply_delete_selection(model);
            if !changed {
                return;
            }
            targets = t;
        }
        "insert_after" => {
            let (Some(path), Some(element)) = (parse_path(op.get("path")), parse_element(op))
            else {
                return;
            };
            targets = apply_insert_element_after(model, &path, element);
        }
        "insert_at" => {
            let (Some(parent_path), Some(element)) =
                (parse_path(op.get("parent_path")), parse_element(op))
            else {
                return;
            };
            // A missing/malformed index defaults to 0 (the renderer's contract:
            // index is a resolved usize; out-of-range clamps in the helper).
            let index = op.get("index").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
            targets = apply_insert_element_at(model, &parent_path, index, element);
        }
        // Group/layer wrapping verbs (OP_LOG.md §9 Phase P5). The highest-
        // structural-complexity verbs: each is a MULTI-STEP mutation (collect,
        // reverse-delete, build container, insert) that replays as ONE
        // deterministic op through the SHARED helpers (apply_wrap_in_group /
        // apply_wrap_in_layer / apply_unpack_group_at), so the renderer.rs handlers
        // and these arms share ONE mutation body. `paths` is parsed defensively
        // (a malformed list SKIPS before any mutation; an empty list is a no-op
        // that journals nothing). `wrap_in_layer` carries the RESOLVED name LITERAL
        // (replay never re-derives next_layer_name). An optional value-in-op `id`
        // assigns the container's id. A no-op edit (no source resolved / non-Group
        // target) records nothing. targets carry the wrapped/unpacked element ids
        // plus the container id when assigned.
        "wrap_in_group" => {
            let Some(paths) = parse_path_list(op.get("paths")) else {
                return;
            };
            if paths.is_empty() {
                return;
            }
            let id = str_field(op, "id");
            let (changed, t) = apply_wrap_in_group(model, &paths, id);
            if !changed {
                return;
            }
            targets = t;
        }
        "wrap_in_layer" => {
            let Some(paths) = parse_path_list(op.get("paths")) else {
                return;
            };
            if paths.is_empty() {
                return;
            }
            // The name is a RESOLVED literal; a missing name defaults to "" (the
            // renderer always supplies the resolved next_layer_name).
            let name = str_field(op, "name").unwrap_or("").to_string();
            let id = str_field(op, "id");
            let (changed, t) = apply_wrap_in_layer(model, &paths, &name, id);
            if !changed {
                return;
            }
            targets = t;
        }
        "unpack_group_at" => {
            let Some(path) = parse_path(op.get("path")) else {
                return;
            };
            let (changed, t) = apply_unpack_group_at(model, &path);
            if !changed {
                return;
            }
            targets = t;
        }
        "lock_selection" => {
            Controller::lock_selection(model);
        }
        "unlock_all" => {
            Controller::unlock_all(model);
        }
        "hide_selection" => {
            Controller::hide_selection(model);
        }
        "show_all" => {
            Controller::show_all(model);
        }
        "set_character_attribute" => {
            let (Some(path), Some(attribute), Some(value)) = (
                parse_path(op.get("path")),
                str_field(op, "attribute"),
                str_field(op, "value"),
            ) else {
                return;
            };
            let char_start = op.get("char_start").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
            let char_end = op.get("char_end").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
            Controller::set_character_attribute(
                model, &path, char_start, char_end, attribute, value,
            );
        }
        // Boolean ops (OP_LOG.md §9 trap: these were NOT in apply_op — added
        // for the boolean_union_simplify_grouping pin). The destructive
        // boolean combines the ≥2 selected sibling paths; `simplify` refits
        // the (now-selected) output. Both write via edit_document, joining
        // the harness transaction so the pair is one journaled Transaction.
        "boolean_union" => {
            Controller::apply_destructive_boolean(
                model,
                "union",
                &crate::document::controller::BooleanOptions::default(),
            );
        }
        "simplify" => {
            let precision = op.get("precision").and_then(|v| v.as_f64()).unwrap_or(0.5);
            Controller::simplify_selection(model, precision);
        }
        // Print-config field setters (OP_LOG.md §9 Phase P1). The eight
        // doc.* print-config verbs journal real ops: each op carries a RESOLVED
        // `field`/`value` (and `index` for ink) — the value is a literal, NOT a
        // YAML expr (replay has no eval context). Routes through the SAME
        // `apply_print_config_field` helper as renderer.rs, so the mutation is
        // byte-identical on the production and replay paths. A type-mismatch
        // skip mutates nothing AND records nothing (early-return before
        // `record_op`), so the journal carries only effective edits.
        // `targets` stays EMPTY: this is document-global config, and the
        // checkpoint_equivalence gate compares documents, not metadata.
        v if PRINT_CONFIG_VERBS.contains(&v) => {
            let Some(field) = str_field(op, "field") else {
                return;
            };
            let Some(value) = op.get("value") else {
                return;
            };
            // `index` is read defensively (only set_output_ink_field uses it);
            // a missing/malformed index defaults to 0, which the helper's
            // `inks.get_mut(index)` bounds-checks (out-of-range ⇒ skip).
            let index = op.get("index").and_then(|x| x.as_u64()).unwrap_or(0) as usize;
            // Clone `field`/`value` out of the borrow so `apply_…` can take
            // `&mut model` (the helper borrows the model mutably).
            let field = field.to_string();
            let value = value.clone();
            if !apply_print_config_field(model, v, &field, &value, index) {
                // Type-mismatch / unknown-field skip: nothing mutated, so
                // journal nothing (an empty op would replay to no change and
                // only add noise).
                return;
            }
        }
        // Artboard doc.* setters (OP_LOG.md §9 Phase P2). Each carries RESOLVED
        // literals; the helper skips (returns false) on a malformed payload, a
        // type mismatch, a missing id, or a no-op edit, in which case we journal
        // nothing. `targets` carries the written artboard id(s); the
        // document-global options setter keeps it empty.
        "set_artboard_field" => {
            let (Some(id), Some(field)) = (str_field(op, "id"), str_field(op, "field")) else {
                return;
            };
            let Some(value) = op.get("value") else {
                return;
            };
            let id = id.to_string();
            let field = field.to_string();
            let value = value.clone();
            if !apply_set_artboard_field(model, &id, &field, &value) {
                return;
            }
            targets = vec![id];
        }
        "set_artboard_options_field" => {
            let Some(field) = str_field(op, "field") else {
                return;
            };
            let Some(value) = op.get("value") else {
                return;
            };
            let field = field.to_string();
            let value = value.clone();
            if !apply_set_artboard_options_field(model, &field, &value) {
                return;
            }
            // Document-global config ⇒ empty targets (the gate compares
            // documents, not metadata).
        }
        "delete_artboard_by_id" => {
            let Some(id) = str_field(op, "id") else {
                return;
            };
            let id = id.to_string();
            if !apply_delete_artboard_by_id(model, &id) {
                return;
            }
            targets = vec![id];
        }
        "move_artboards_up" => {
            let ids = str_list_field(op, "ids");
            if !apply_move_artboards_up(model, &ids) {
                return;
            }
            targets = ids;
        }
        "move_artboards_down" => {
            let ids = str_list_field(op, "ids");
            if !apply_move_artboards_down(model, &ids) {
                return;
            }
            targets = ids;
        }
        // Artboard id-minting verbs (OP_LOG.md §9 Phase P3). VALUE-IN-OP: the id
        // was minted ONCE at production capture time and recorded as a LITERAL in
        // the op params (`id` for create, `new_id` for duplicate); this arm reads
        // it VERBATIM and NEVER mints / NEVER taps entropy / NEVER runs the
        // collision-retry, so replay is a pure deterministic function of the
        // journal. All other params (fields / name / offsets) are RESOLVED
        // literals too (replay has no eval context). targets carry the new id.
        "create_artboard" => {
            // A missing/empty id is a malformed payload — skip rather than mint
            // (this arm must NEVER mint). The harness + production always supply
            // the literal minted id.
            let Some(id) = str_field(op, "id").filter(|s| !s.is_empty()) else {
                return;
            };
            let id = id.to_string();
            // `fields` is an optional RESOLVED override object; absent ⇒ defaults.
            let fields = op.get("fields").cloned().unwrap_or(serde_json::Value::Null);
            apply_create_artboard(model, &id, &fields);
            targets = vec![id];
        }
        "duplicate_artboard" => {
            // Both the source id and the (already-minted) new_id are required
            // literals; either missing ⇒ skip (never mint). A missing source
            // artboard is a no-op that journals nothing.
            let (Some(source_id), Some(new_id)) = (
                str_field(op, "id").filter(|s| !s.is_empty()),
                str_field(op, "new_id").filter(|s| !s.is_empty()),
            ) else {
                return;
            };
            let source_id = source_id.to_string();
            let new_id = new_id.to_string();
            // `name` is the RESOLVED next-artboard name (derived at production
            // time, NOT re-derived on replay); offsets default to 0.0 if absent.
            let name = str_field(op, "name").unwrap_or("").to_string();
            let ox = num_field(op, "offset_x");
            let oy = num_field(op, "offset_y");
            if !apply_duplicate_artboard(model, &source_id, &new_id, &name, ox, oy) {
                return;
            }
            targets = vec![new_id];
        }
        // Unknown verb: a malformed/unsupported production payload is skipped
        // rather than panicking. (The harness corpus only carries known verbs,
        // so this never fires under test — the byte-gate would catch a typo.)
        _ => return,
    }
    // Capture the op into the open transaction so the journal replays to
    // the same document — the checkpoint_equivalence gate (OP_LOG.md §5-6).
    // `targets` (Fork 4) is populated above for the three replay-safe verbs;
    // empty for every other verb (the gate compares documents, not metadata,
    // so empty is fine there). record_op is a no-op when no transaction is open.
    model.record_op(crate::document::op_log::PrimitiveOp {
        op: name.to_string(),
        params: op.clone(),
        targets,
    });
}
