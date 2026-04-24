//! Dock panel rendering: anchored dock groups and floating docks.
//!
//! Extracted from `app.rs` to keep that file focused on top-level
//! application wiring.

use std::cell::RefCell;
use std::rc::Rc;

use dioxus::prelude::*;

use super::app_state::{Act, AppState};
use super::theme::*;
use super::workspace::{
    DockEdge, DockId, DragPayload, DropTarget, GroupAddr, PanelAddr, PanelGroup, PanelKind,
};
use crate::interpreter::workspace::{Workspace, panel_kind_to_content_id};
use crate::panels::panel_menu_state::{PanelMenuOpen, PanelMenuState, MenuBarState};

/// Convert a ToolKind to its YAML snake_case name.
fn tool_kind_name(kind: crate::tools::tool::ToolKind) -> &'static str {
    use crate::tools::tool::ToolKind;
    match kind {
        ToolKind::Selection => "selection",
        ToolKind::PartialSelection => "partial_selection",
        ToolKind::InteriorSelection => "interior_selection",
        ToolKind::Pen => "pen",
        ToolKind::AddAnchorPoint => "add_anchor",
        ToolKind::DeleteAnchorPoint => "delete_anchor",
        ToolKind::AnchorPoint => "anchor_point",
        ToolKind::Pencil => "pencil",
        ToolKind::Paintbrush => "paintbrush",
        ToolKind::PathEraser => "path_eraser",
        ToolKind::Smooth => "smooth",
        ToolKind::Type => "type",
        ToolKind::TypeOnPath => "type_on_path",
        ToolKind::Line => "line",
        ToolKind::Rect => "rect",
        ToolKind::RoundedRect => "rounded_rect",
        ToolKind::Polygon => "polygon",
        ToolKind::Star => "star",
        ToolKind::Lasso => "lasso",
    }
}

// ---------------------------------------------------------------------------
// Live panel state — computed from AppState for YAML eval context
// ---------------------------------------------------------------------------

/// Build panel state overrides from the live AppState so that the YAML
/// eval context reflects the current color mode and active color values.
/// Build the selection-level predicates referenced by yaml expressions
/// (``selection_has_mask``, ``selection_mask_clip``,
/// ``selection_mask_invert``) per OPACITY.md § States. Mixed selections
/// count as "no mask"; the mask's clip / invert are read from the
/// first selected element's mask, driving the "first-wins" bindings
/// on CLIP_CHECKBOX / INVERT_MASK_CHECKBOX.
fn build_selection_predicates(st: &AppState) -> serde_json::Map<String, serde_json::Value> {
    let mut m = serde_json::Map::new();
    let (has_mask, clip, invert, linked) = st.tab().map(|t| {
        let doc = t.model.document();
        let has = !doc.selection.is_empty() && doc.selection.iter().all(|es| {
            doc.get_element(&es.path)
                .map(|e| e.common().mask.is_some())
                .unwrap_or(false)
        });
        let first_mask = doc.selection.first()
            .and_then(|es| doc.get_element(&es.path))
            .and_then(|e| e.common().mask.as_ref());
        let (c, i, l) = match first_mask {
            // Default ``linked`` to true so the LINK_INDICATOR shows
            // the linked glyph when no mask exists — matches the
            // "New masks are linked" spec default.
            Some(mask) => (mask.clip, mask.invert, mask.linked),
            None => (false, false, true),
        };
        (has, c, i, l)
    }).unwrap_or((false, false, false, true));
    m.insert("selection_has_mask".into(), serde_json::Value::Bool(has_mask));
    m.insert("selection_mask_clip".into(), serde_json::Value::Bool(clip));
    m.insert("selection_mask_invert".into(), serde_json::Value::Bool(invert));
    m.insert("selection_mask_linked".into(), serde_json::Value::Bool(linked));
    // OPACITY.md §Preview interactions: ``editing_target_is_mask``
    // reflects whether mask-editing mode is active, so OPACITY_PREVIEW
    // and MASK_PREVIEW can show a persistent highlight on the current
    // editing target.
    let editing_mask = matches!(st.tab().map(|t| &t.model.editing_target),
        Some(crate::workspace::app_state::EditingTarget::Mask(_)));
    m.insert("editing_target_is_mask".into(), serde_json::Value::Bool(editing_mask));
    m
}

fn build_live_panel_overrides(st: &AppState) -> serde_json::Map<String, serde_json::Value> {
    use crate::interpreter::color_util::{rgb_to_hsb, rgb_to_cmyk};
    use serde_json::Value as J;

    let mode_str = match st.color_panel_mode {
        super::color_panel_view::ColorMode::Grayscale => "grayscale",
        super::color_panel_view::ColorMode::Hsb => "hsb",
        super::color_panel_view::ColorMode::Rgb => "rgb",
        super::color_panel_view::ColorMode::Cmyk => "cmyk",
        super::color_panel_view::ColorMode::WebSafeRgb => "web_safe_rgb",
    };
    let mut m = serde_json::Map::new();
    m.insert("mode".into(), J::String(mode_str.into()));

    // Compute slider values from the active color
    if let Some(color) = st.active_color() {
        let (rf, gf, bf, _) = color.to_rgba();
        let r = (rf * 255.0).round() as u8;
        let g = (gf * 255.0).round() as u8;
        let b = (bf * 255.0).round() as u8;

        // RGB
        m.insert("r".into(), J::Number(serde_json::Number::from(r as i64)));
        m.insert("g".into(), J::Number(serde_json::Number::from(g as i64)));
        m.insert("bl".into(), J::Number(serde_json::Number::from(b as i64)));

        // HSB
        let (h, s, br) = rgb_to_hsb(r, g, b);
        m.insert("h".into(), J::Number(serde_json::Number::from(h as i64)));
        m.insert("s".into(), J::Number(serde_json::Number::from(s as i64)));
        m.insert("b".into(), J::Number(serde_json::Number::from(br as i64)));

        // CMYK
        let (c, mk, y, k) = rgb_to_cmyk(r, g, b);
        m.insert("c".into(), J::Number(serde_json::Number::from(c as i64)));
        m.insert("m".into(), J::Number(serde_json::Number::from(mk as i64)));
        m.insert("y".into(), J::Number(serde_json::Number::from(y as i64)));
        m.insert("k".into(), J::Number(serde_json::Number::from(k as i64)));

        // Hex
        m.insert("hex".into(), J::String(format!("{:02x}{:02x}{:02x}", r, g, b)));
    }

    // ── Stroke panel overrides ──────────────────────────────
    // Read cap/join/width from the selected element; fall back to panel state.
    let sel_stroke = st.tab().and_then(|tab| {
        let doc = tab.model.document();
        doc.selection.first()
            .and_then(|es| doc.get_element(&es.path))
            .and_then(|e| e.stroke().cloned())
    });
    let sp = &st.stroke_panel;
    if let Some(ref s) = sel_stroke {
        m.insert("weight".into(), serde_json::json!(s.width));
        m.insert("cap".into(), J::String(match s.linecap {
            crate::geometry::element::LineCap::Butt => "butt",
            crate::geometry::element::LineCap::Round => "round",
            crate::geometry::element::LineCap::Square => "square",
        }.into()));
        m.insert("join".into(), J::String(match s.linejoin {
            crate::geometry::element::LineJoin::Miter => "miter",
            crate::geometry::element::LineJoin::Round => "round",
            crate::geometry::element::LineJoin::Bevel => "bevel",
        }.into()));
    } else {
        m.insert("weight".into(), serde_json::json!(
            st.app_default_stroke.map(|s| s.width).unwrap_or(1.0)));
        m.insert("cap".into(), J::String(sp.cap.clone()));
        m.insert("join".into(), J::String(sp.join.clone()));
    }
    m.insert("miter_limit".into(), serde_json::json!(sp.miter_limit));
    m.insert("align_stroke".into(), J::String(sp.align.clone()));
    m.insert("dashed".into(), J::Bool(sp.dashed));
    m.insert("dash_1".into(), serde_json::json!(sp.dash_1));
    m.insert("gap_1".into(), serde_json::json!(sp.gap_1));
    m.insert("dash_2".into(), sp.dash_2.map_or(J::Null, |v| serde_json::json!(v)));
    m.insert("gap_2".into(), sp.gap_2.map_or(J::Null, |v| serde_json::json!(v)));
    m.insert("dash_3".into(), sp.dash_3.map_or(J::Null, |v| serde_json::json!(v)));
    m.insert("gap_3".into(), sp.gap_3.map_or(J::Null, |v| serde_json::json!(v)));
    m.insert("start_arrowhead".into(), J::String(sp.start_arrowhead.clone()));
    m.insert("end_arrowhead".into(), J::String(sp.end_arrowhead.clone()));
    m.insert("start_arrowhead_scale".into(), serde_json::json!(sp.start_arrowhead_scale));
    m.insert("end_arrowhead_scale".into(), serde_json::json!(sp.end_arrowhead_scale));
    m.insert("link_arrowhead_scale".into(), J::Bool(sp.link_arrowhead_scale));
    m.insert("arrow_align".into(), J::String(sp.arrow_align.clone()));
    m.insert("profile".into(), J::String(sp.profile.clone()));
    m.insert("profile_flipped".into(), J::Bool(sp.profile_flipped));

    // ── Character panel overrides ───────────────────────────
    // Read font_family / font_size from the first selected
    // Text / TextPath element; fall back to panel state when no
    // text element is selected. Matches the stroke-panel pattern
    // above; the Character panel dropdowns then show the current
    // selection's attributes rather than stale panel-local values.
    // Read the first selected Text / TextPath's character attributes
    // into the panel eval context, so Character-panel controls reflect
    // the selection. Falls back to panel-local state when nothing is
    // selected.
    struct TextAttrs {
        font_family: String,
        font_size: f64,
        font_weight: String,
        font_style: String,
        text_decoration: String,
        text_transform: String,
        font_variant: String,
        baseline_shift: String,
        line_height: String,
        letter_spacing: String,
        xml_lang: String,
        aa_mode: String,
        rotate: String,
        horizontal_scale: String,
        vertical_scale: String,
        kerning: String,
    }
    let sel_text: Option<TextAttrs> = st.tab().and_then(|tab| {
        let doc = tab.model.document();
        doc.selection.first().and_then(|es| {
            let elem = doc.get_element(&es.path)?;
            match elem {
                crate::geometry::element::Element::Text(t) => Some(TextAttrs {
                    font_family: t.font_family.clone(),
                    font_size: t.font_size,
                    font_weight: t.font_weight.clone(),
                    font_style: t.font_style.clone(),
                    text_decoration: t.text_decoration.clone(),
                    text_transform: t.text_transform.clone(),
                    font_variant: t.font_variant.clone(),
                    baseline_shift: t.baseline_shift.clone(),
                    line_height: t.line_height.clone(),
                    letter_spacing: t.letter_spacing.clone(),
                    xml_lang: t.xml_lang.clone(),
                    aa_mode: t.aa_mode.clone(),
                    rotate: t.rotate.clone(),
                    horizontal_scale: t.horizontal_scale.clone(),
                    vertical_scale: t.vertical_scale.clone(),
                    kerning: t.kerning.clone(),
                }),
                crate::geometry::element::Element::TextPath(tp) => Some(TextAttrs {
                    font_family: tp.font_family.clone(),
                    font_size: tp.font_size,
                    font_weight: tp.font_weight.clone(),
                    font_style: tp.font_style.clone(),
                    text_decoration: tp.text_decoration.clone(),
                    text_transform: tp.text_transform.clone(),
                    font_variant: tp.font_variant.clone(),
                    baseline_shift: tp.baseline_shift.clone(),
                    line_height: tp.line_height.clone(),
                    letter_spacing: tp.letter_spacing.clone(),
                    xml_lang: tp.xml_lang.clone(),
                    aa_mode: tp.aa_mode.clone(),
                    rotate: tp.rotate.clone(),
                    horizontal_scale: tp.horizontal_scale.clone(),
                    vertical_scale: tp.vertical_scale.clone(),
                    kerning: tp.kerning.clone(),
                }),
                _ => None,
            }
        })
    });
    let cp = &st.character_panel;
    if let Some(a) = sel_text {
        let (u, s) = super::app_state::text_decoration_flags(&a.text_decoration);
        // Numeric baseline-shift: only read when super/sub isn't set.
        let bshift_pt = if a.baseline_shift == "super" || a.baseline_shift == "sub" {
            0.0
        } else {
            super::app_state::parse_pt(&a.baseline_shift).unwrap_or(0.0)
        };
        // Leading: empty = Auto (120% of font_size), else parsed pt.
        let leading_pt = if a.line_height.is_empty() {
            a.font_size * 1.2
        } else {
            super::app_state::parse_pt(&a.line_height).unwrap_or(a.font_size * 1.2)
        };
        // Tracking: parse "Nem" → N*1000 (panel stores 1/1000 em).
        let tracking_val = if a.letter_spacing.is_empty() {
            0.0
        } else {
            super::app_state::parse_em_as_thousandths(&a.letter_spacing).unwrap_or(0.0)
        };
        let style_name = super::app_state::format_style_name(&a.font_weight, &a.font_style);
        // Anti-aliasing: empty element field → panel default "Sharp".
        let aa_mode_display = if a.aa_mode.is_empty() {
            "Sharp".to_string()
        } else {
            a.aa_mode.clone()
        };
        m.insert("font_family".into(), J::String(a.font_family));
        m.insert("font_size".into(), serde_json::json!(a.font_size));
        m.insert("style_name".into(), J::String(style_name));
        m.insert("underline".into(), J::Bool(u));
        m.insert("strikethrough".into(), J::Bool(s));
        m.insert("all_caps".into(), J::Bool(a.text_transform == "uppercase"));
        m.insert("small_caps".into(), J::Bool(a.font_variant == "small-caps"));
        m.insert("superscript".into(), J::Bool(a.baseline_shift == "super"));
        m.insert("subscript".into(), J::Bool(a.baseline_shift == "sub"));
        m.insert("baseline_shift".into(), serde_json::json!(bshift_pt));
        m.insert("leading".into(), serde_json::json!(leading_pt));
        m.insert("tracking".into(), serde_json::json!(tracking_val));
        // Character rotation: parse degrees; empty → 0.
        let rotation = a.rotate.parse::<f64>().unwrap_or(0.0);
        // V/H scale: parse percent; empty → 100 (identity).
        let h_scale = a.horizontal_scale.parse::<f64>().unwrap_or(100.0);
        let v_scale = a.vertical_scale.parse::<f64>().unwrap_or(100.0);
        // Kerning: named modes pass through to the panel combo_box
        // verbatim; numeric "{N}em" converts to a plain "{N*1000}"
        // string (1/1000 em is the panel's numeric unit). Empty
        // element attribute shows as "Auto" — the spec default.
        let kerning_display = match a.kerning.as_str() {
            "" | "Auto" => "Auto".to_string(),
            "Optical" | "Metrics" => a.kerning.clone(),
            other => match super::app_state::parse_em_as_thousandths(other) {
                Some(n) => super::app_state::fmt_num(n),
                None => a.kerning.clone(),
            }
        };
        m.insert("language".into(), J::String(a.xml_lang));
        m.insert("anti_aliasing".into(), J::String(aa_mode_display));
        m.insert("character_rotation".into(), serde_json::json!(rotation));
        m.insert("horizontal_scale".into(), serde_json::json!(h_scale));
        m.insert("vertical_scale".into(), serde_json::json!(v_scale));
        m.insert("kerning".into(), J::String(kerning_display));
    } else {
        m.insert("font_family".into(), J::String(cp.font_family.clone()));
        m.insert("font_size".into(), serde_json::json!(cp.font_size));
        m.insert("style_name".into(), J::String(cp.style_name.clone()));
        m.insert("underline".into(), J::Bool(cp.underline));
        m.insert("strikethrough".into(), J::Bool(cp.strikethrough));
        m.insert("all_caps".into(), J::Bool(cp.all_caps));
        m.insert("small_caps".into(), J::Bool(cp.small_caps));
        m.insert("superscript".into(), J::Bool(cp.superscript));
        m.insert("subscript".into(), J::Bool(cp.subscript));
        m.insert("baseline_shift".into(), serde_json::json!(cp.baseline_shift));
        m.insert("leading".into(), serde_json::json!(cp.leading));
        m.insert("tracking".into(), serde_json::json!(cp.tracking));
        m.insert("language".into(), J::String(cp.language.clone()));
        m.insert("anti_aliasing".into(), J::String(cp.anti_aliasing.clone()));
        m.insert("character_rotation".into(), serde_json::json!(cp.character_rotation));
        m.insert("horizontal_scale".into(), serde_json::json!(cp.horizontal_scale));
        m.insert("vertical_scale".into(), serde_json::json!(cp.vertical_scale));
        // No selection: show the stored panel value (default "Auto").
        let kerning_display = if cp.kerning.is_empty() {
            "Auto".to_string()
        } else {
            cp.kerning.clone()
        };
        m.insert("kerning".into(), J::String(kerning_display));
    }

    // ── Paragraph panel — text-kind gating (Phase 3a) + attr reads (Phase 3b/c) ──
    // PARAGRAPH.md §Text-kind gating disables JUSTIFY_*, indents,
    // hyphenate, and hanging punctuation when any selected text
    // element is non-area (point text or text-on-path). The bare
    // alignments, space-before/after, and list dropdowns gate on
    // text_selected only.
    //
    // Phase 3b/c iterates every paragraph wrapper tspan in every
    // selected text element and aggregates the panel-surface attrs.
    // When all wrappers agree on a value, the panel reflects it;
    // when they disagree (mixed state per PARAGRAPH.md §Selection
    // model rule 2/3/4), the override is omitted so the panel
    // retains its prior / YAML-default value. A future Phase polishes
    // this into a tri-state visual indicator on checkboxes and a
    // blank state on combos.
    let mut any_text = false;
    let mut all_area = true;
    let mut wrappers: Vec<&crate::geometry::tspan::Tspan> = Vec::new();
    if let Some(tab) = st.tab() {
        let doc = tab.model.document();
        for es in doc.selection.iter() {
            if let Some(el) = doc.get_element(&es.path) {
                match el {
                    crate::geometry::element::Element::Text(t) => {
                        any_text = true;
                        if !(t.width > 0.0 && t.height > 0.0) {
                            all_area = false;
                        }
                        for tspan in t.tspans.iter() {
                            if tspan.jas_role.as_deref() == Some("paragraph") {
                                wrappers.push(tspan);
                            }
                        }
                    }
                    crate::geometry::element::Element::TextPath(_) => {
                        any_text = true;
                        all_area = false;
                    }
                    _ => {}
                }
            }
        }
    }
    m.insert("text_selected".into(), J::Bool(any_text));
    m.insert("area_text_selected".into(), J::Bool(any_text && all_area));

    // Always seed every paragraph control from the typed panel state
    // first; selection-derived overrides below shadow these on agree.
    // This way Phase 4 panel writes show up immediately even with no
    // selection (the panel becomes self-consistent after a click).
    let pp = &st.paragraph_panel;
    m.insert("align_left".into(), J::Bool(pp.align_left));
    m.insert("align_center".into(), J::Bool(pp.align_center));
    m.insert("align_right".into(), J::Bool(pp.align_right));
    m.insert("justify_left".into(), J::Bool(pp.justify_left));
    m.insert("justify_center".into(), J::Bool(pp.justify_center));
    m.insert("justify_right".into(), J::Bool(pp.justify_right));
    m.insert("justify_all".into(), J::Bool(pp.justify_all));
    m.insert("bullets".into(), J::String(pp.bullets.clone()));
    m.insert("numbered_list".into(), J::String(pp.numbered_list.clone()));
    m.insert("left_indent".into(), serde_json::json!(pp.left_indent));
    m.insert("right_indent".into(), serde_json::json!(pp.right_indent));
    m.insert("first_line_indent".into(), serde_json::json!(pp.first_line_indent));
    m.insert("space_before".into(), serde_json::json!(pp.space_before));
    m.insert("space_after".into(), serde_json::json!(pp.space_after));
    m.insert("hyphenate".into(), J::Bool(pp.hyphenate));
    m.insert("hanging_punctuation".into(), J::Bool(pp.hanging_punctuation));

    // Aggregate across all wrappers. Each wrapper's effective value
    // is the field if Some, else the panel/YAML default. We collect
    // distinct values; one distinct value → write it; >1 distinct or
    // 0 wrappers → omit override (panel keeps the typed-struct seed).
    fn agree<T: PartialEq + Clone>(values: &[T]) -> Option<T> {
        let first = values.first()?.clone();
        if values.iter().all(|v| *v == first) { Some(first) } else { None }
    }
    if !wrappers.is_empty() {
        let lefts: Vec<f64> = wrappers.iter()
            .map(|w| w.jas_left_indent.unwrap_or(0.0)).collect();
        if let Some(v) = agree(&lefts) {
            m.insert("left_indent".into(), serde_json::json!(v));
        }
        let rights: Vec<f64> = wrappers.iter()
            .map(|w| w.jas_right_indent.unwrap_or(0.0)).collect();
        if let Some(v) = agree(&rights) {
            m.insert("right_indent".into(), serde_json::json!(v));
        }
        let firsts: Vec<f64> = wrappers.iter()
            .map(|w| w.text_indent.unwrap_or(0.0)).collect();
        if let Some(v) = agree(&firsts) {
            m.insert("first_line_indent".into(), serde_json::json!(v));
        }
        let sb: Vec<f64> = wrappers.iter()
            .map(|w| w.jas_space_before.unwrap_or(0.0)).collect();
        if let Some(v) = agree(&sb) {
            m.insert("space_before".into(), serde_json::json!(v));
        }
        let sa: Vec<f64> = wrappers.iter()
            .map(|w| w.jas_space_after.unwrap_or(0.0)).collect();
        if let Some(v) = agree(&sa) {
            m.insert("space_after".into(), serde_json::json!(v));
        }
        let hyphs: Vec<bool> = wrappers.iter()
            .map(|w| w.jas_hyphenate.unwrap_or(false)).collect();
        if let Some(v) = agree(&hyphs) {
            m.insert("hyphenate".into(), J::Bool(v));
        }
        let hps: Vec<bool> = wrappers.iter()
            .map(|w| w.jas_hanging_punctuation.unwrap_or(false)).collect();
        if let Some(v) = agree(&hps) {
            m.insert("hanging_punctuation".into(), J::Bool(v));
        }
        // Single backing attr split into two panel dropdowns. We
        // aggregate the raw list-style value first, then route to
        // bullets / numbered_list based on the prefix.
        let styles: Vec<String> = wrappers.iter()
            .map(|w| w.jas_list_style.clone().unwrap_or_default()).collect();
        if let Some(ls) = agree(&styles) {
            if ls.starts_with("bullet-") {
                m.insert("bullets".into(), J::String(ls));
                m.insert("numbered_list".into(), J::String("".into()));
            } else if ls.starts_with("num-") {
                m.insert("numbered_list".into(), J::String(ls));
                m.insert("bullets".into(), J::String("".into()));
            } else {
                // Empty string (no marker) — clear both dropdowns.
                m.insert("bullets".into(), J::String("".into()));
                m.insert("numbered_list".into(), J::String("".into()));
            }
        }
        // Aggregate alignment from text_align + text_align_last.
        let tas: Vec<String> = wrappers.iter()
            .map(|w| w.text_align.clone().unwrap_or_else(|| "left".into())).collect();
        let tals: Vec<String> = wrappers.iter()
            .map(|w| w.text_align_last.clone().unwrap_or_default()).collect();
        if let (Some(ta), Some(tal)) = (agree(&tas), agree(&tals)) {
            // Reset all 7, then set the matching one.
            for k in &["align_left", "align_center", "align_right",
                       "justify_left", "justify_center", "justify_right", "justify_all"] {
                m.insert((*k).into(), J::Bool(false));
            }
            let key = match (ta.as_str(), tal.as_str()) {
                ("center", _) => "align_center",
                ("right", _) => "align_right",
                ("justify", "left") => "justify_left",
                ("justify", "center") => "justify_center",
                ("justify", "right") => "justify_right",
                ("justify", "justify") => "justify_all",
                _ => "align_left",
            };
            m.insert(key.into(), J::Bool(true));
        }
    }

    // ── Opacity panel overrides ─────────────────────────────
    // Phase 1 panel-local: emit the OpacityPanelState fields as-is.
    // `blend_mode` is serialized via serde (snake_case). The key is
    // named `blend_mode` rather than `mode` to avoid colliding with
    // the Color panel's state.mode.
    let op = &st.opacity_panel;
    let blend_mode_json = serde_json::to_value(op.blend_mode)
        .unwrap_or_else(|_| J::String("normal".into()));
    m.insert("blend_mode".into(), blend_mode_json);
    m.insert("opacity".into(), serde_json::json!(op.opacity));
    m.insert("thumbnails_hidden".into(), J::Bool(op.thumbnails_hidden));
    m.insert("options_shown".into(), J::Bool(op.options_shown));
    m.insert("new_masks_clipping".into(), J::Bool(op.new_masks_clipping));
    m.insert("new_masks_inverted".into(), J::Bool(op.new_masks_inverted));

    m
}

/// Build a live state map from AppState for the YAML eval context.
/// Includes fill_color, stroke_color, fill_on_top, and other state fields.
pub(crate) fn build_live_state_map(st: &AppState) -> serde_json::Map<String, serde_json::Value> {
    use serde_json::Value as J;

    // Start with workspace defaults
    let ws = Workspace::load();
    let mut m: serde_json::Map<String, serde_json::Value> = ws
        .map(|w| w.state_defaults().into_iter().collect())
        .unwrap_or_default();

    // Override with live values from AppState
    m.insert("fill_on_top".into(), J::Bool(st.fill_on_top));
    m.insert("active_tool".into(), J::String(tool_kind_name(st.active_tool).into()));

    // Override fill/stroke colors from tab state or app-level defaults.
    let fill_color = st.tab()
        .and_then(|t| t.model.default_fill)
        .or(st.app_default_fill);
    let stroke_color = st.tab()
        .and_then(|t| t.model.default_stroke)
        .or(st.app_default_stroke);
    if let Some(fill) = fill_color {
        let (r, g, b, _) = fill.color.to_rgba();
        m.insert("fill_color".into(), J::String(format!("#{:02x}{:02x}{:02x}",
            (r * 255.0).round() as u8, (g * 255.0).round() as u8, (b * 255.0).round() as u8)));
    }
    if let Some(stroke) = stroke_color {
        let (r, g, b, _) = stroke.color.to_rgba();
        m.insert("stroke_color".into(), J::String(format!("#{:02x}{:02x}{:02x}",
            (r * 255.0).round() as u8, (g * 255.0).round() as u8, (b * 255.0).round() as u8)));
    }

    // Mutable swatch libraries for rendering
    m.insert("_swatch_libraries".into(), st.swatch_libraries.clone());

    // Document generation counter — changes on every document mutation,
    // ensuring the layers panel re-renders when selection, visibility,
    // lock state, or element structure changes.
    let doc_gen = st.tab().map(|t| t.model.generation()).unwrap_or(0);
    m.insert("_doc_generation".into(), serde_json::Value::Number(doc_gen.into()));

    // Layers panel UI state — included so the panel re-renders when
    // inline rename or twirl state changes.
    if let Some(ref path) = st.layers_renaming {
        m.insert("_layers_renaming".into(), serde_json::json!(path));
    }
    let collapsed_count = st.layers_collapsed.len();
    m.insert("_layers_collapsed_count".into(), serde_json::Value::Number(collapsed_count.into()));
    let panel_sel_count = st.layers_panel_selection.len();
    m.insert("_layers_panel_sel_count".into(), serde_json::Value::Number(panel_sel_count.into()));
    if let Some(ref dt) = st.layers_drag_target {
        m.insert("_layers_drag_target".into(), serde_json::json!(dt));
    }
    if st.layers_context_menu.is_some() {
        m.insert("_layers_context_menu".into(), serde_json::Value::Bool(true));
    }
    m.insert("_layers_search_query".into(), serde_json::Value::String(st.layers_search_query.clone()));
    m.insert("_layers_isolation_depth".into(), serde_json::Value::Number(st.layers_isolation_stack.len().into()));
    m.insert("_layers_hidden_types_count".into(), serde_json::Value::Number(st.layers_hidden_types.len().into()));
    m.insert("_layers_filter_open".into(), serde_json::Value::Bool(st.layers_filter_dropdown_open));

    m
}

/// Build a minimal state subset for a panel's eval context.
/// Only includes the state keys the panel actually references,
/// so unrelated state changes don't invalidate the panel memo cache.
fn build_panel_state_subset(
    panel_name: &str,
    full_state: &serde_json::Map<String, serde_json::Value>,
) -> serde_json::Map<String, serde_json::Value> {
    let keys: &[&str] = match panel_name {
        "stroke" => &["stroke_width", "stroke_color"],
        "color" | "swatches" => &["fill_color", "stroke_color", "fill_on_top"],
        "layers" => &["_doc_generation", "_layers_renaming", "_layers_collapsed_count", "_layers_panel_sel_count", "_layers_drag_target", "_layers_context_menu", "_layers_search_query", "_layers_isolation_depth", "_layers_hidden_types_count", "_layers_filter_open"],
        _ => &["fill_color", "stroke_color", "fill_on_top"],
    };
    let mut m = serde_json::Map::new();
    for &k in keys {
        if let Some(v) = full_state.get(k) {
            m.insert(k.into(), v.clone());
        }
    }
    m
}

// ---------------------------------------------------------------------------
// DragState — shared drag signals, provided via context
// ---------------------------------------------------------------------------

/// Shared drag-and-drop signals used by dock panels and the main app shell.
#[derive(Clone, Copy)]
pub(crate) struct DragState {
    pub drag_source: Signal<Option<DragPayload>>,
    pub drop_target: Signal<Option<DropTarget>>,
    pub was_dropped: Signal<bool>,
    pub last_drag_pos: Signal<(f64, f64)>,
    pub title_drag: Signal<Option<(DockId, f64, f64)>>,
}

// ---------------------------------------------------------------------------
// build_dock_groups — reusable renderer for a list of PanelGroups
// ---------------------------------------------------------------------------

/// Build panel group nodes for a given dock.  Reused for anchored and
/// floating docks.
pub(crate) fn build_dock_groups(
    dock_id: DockId,
    groups: &[PanelGroup],
    act: &Rc<RefCell<dyn FnMut(Box<dyn FnOnce(&mut AppState)>)>>,
    mut drag_source: Signal<Option<DragPayload>>,
    mut drop_target_sig: Signal<Option<DropTarget>>,
    mut was_dropped: Signal<bool>,
    mut last_drag_pos: Signal<(f64, f64)>,
    focused: Option<PanelAddr>,
    mut panel_menu_open: Signal<Option<PanelMenuOpen>>,
    mut menu_bar_open: Signal<Option<String>>,
    live_panel_overrides: &serde_json::Map<String, serde_json::Value>,
    live_state_map: &serde_json::Map<String, serde_json::Value>,
    selection_preds: &serde_json::Map<String, serde_json::Value>,
) -> Vec<Result<VNode, RenderError>> {
    let did = dock_id;
    let group_count = groups.len();
    let cur_drag = drag_source();
    let cur_drop = drop_target_sig();

    groups.iter().enumerate().map(|(gi, group)| {
        let act_tabs = act.clone();
        let act_chevron = act.clone();
        let act_collapse = act.clone();
        let act_drop = act.clone();
        let group_collapsed = group.collapsed;

        // Tab insertion indicator: which index has the drop caret?
        let tab_drop_idx: Option<usize> = if cur_drag.is_some() {
            match cur_drop {
                Some(DropTarget::TabBar { group: g, index }) if g == (GroupAddr { dock_id: did, group_idx: gi }) => Some(index),
                _ => None,
            }
        } else {
            None
        };
        let panel_count = group.panels.len();

        // Tab bar buttons — each tab is individually draggable
        let tab_nodes: Vec<Result<VNode, RenderError>> = group.panels.iter().enumerate().flat_map(|(pi, &kind)| {
            let act_dragend = act_tabs.clone();
            let act_click = act_tabs.clone();
            let label = crate::panels::panel_label(kind);
            let is_active = pi == group.active;
            let bg = if is_active { THEME_BG_TAB } else { THEME_BG_TAB_INACTIVE };
            let border_bottom = if is_active { format!("2px solid {THEME_BG_TAB}") } else { format!("2px solid {THEME_BORDER}") };
            let font_weight = if is_active { "bold" } else { "normal" };
            let is_focused = focused == Some(PanelAddr {
                group: GroupAddr { dock_id: did, group_idx: gi },
                panel_idx: pi,
            });
            let outline = "";

            // Insertion indicator before this tab
            let show_caret = tab_drop_idx == Some(pi);
            let mut nodes: Vec<Result<VNode, RenderError>> = Vec::new();
            if show_caret {
                nodes.push(rsx! {
                    div {
                        key: "tab-caret-{gi}-{pi}",
                        style: "width:3px; align-self:stretch; background:{THEME_ACCENT}; border-radius:1px; flex-shrink:0; transition:width 0.1s ease;",
                    }
                });
            }
            nodes.push(rsx! {
                div {
                    key: "dock-tab-{gi}-{pi}",
                    style: "padding:3px 8px; cursor:pointer; font-size:11px; color:{THEME_TEXT}; font-weight:{font_weight}; background:{bg}; border-bottom:{border_bottom}; user-select:none; {outline}",
                    draggable: "true",
                    ondragstart: move |evt: Event<DragData>| {
                        evt.stop_propagation();
                        drag_source.set(Some(DragPayload::Panel(PanelAddr {
                            group: GroupAddr { dock_id: did, group_idx: gi },
                            panel_idx: pi,
                        })));
                        was_dropped.set(false);
                    },
                    ondragend: move |_| {
                        if !was_dropped() {
                            let (x, y) = last_drag_pos();
                            let cur_tgt = drop_target_sig();
                            (act_dragend.borrow_mut())(Box::new(move |st: &mut AppState| {
                                let addr = PanelAddr {
                                    group: GroupAddr { dock_id: did, group_idx: gi },
                                    panel_idx: pi,
                                };
                                if let Some(DropTarget::Edge(edge)) = cur_tgt {
                                    if let Some(fid) = st.workspace_layout.detach_panel(addr, x, y) {
                                        st.workspace_layout.snap_to_edge(fid, edge);
                                    }
                                } else {
                                    st.workspace_layout.detach_panel(addr, x, y);
                                }
                            }));
                        }
                        drag_source.set(None);
                        drop_target_sig.set(None);
                        was_dropped.set(false);
                    },
                    ondragover: move |evt: Event<DragData>| {
                        evt.prevent_default();
                        evt.stop_propagation();
                        let coords = evt.data().page_coordinates();
                        last_drag_pos.set((coords.x, coords.y));
                        // Left half → insert before this tab; right half → insert after
                        let x = evt.data().element_coordinates().x;
                        let mid = 30.0; // approximate tab half-width
                        let idx = if x < mid { pi } else { pi + 1 };
                        drop_target_sig.set(Some(DropTarget::TabBar {
                            group: GroupAddr { dock_id: did, group_idx: gi },
                            index: idx,
                        }));
                    },
                    onclick: move |_| {
                        (act_click.borrow_mut())(Box::new(move |st: &mut AppState| {
                            st.workspace_layout.set_active_panel(PanelAddr {
                                group: GroupAddr { dock_id: did, group_idx: gi },
                                panel_idx: pi,
                            });
                        }));
                    },
                    "{label}"
                    // Close button
                    {
                        let act_close = act_click.clone();
                        rsx! {
                            span {
                                style: "margin-left:4px; color:{THEME_TEXT_BODY}; cursor:pointer; font-size:10px; line-height:1;",
                                onclick: move |evt: Event<MouseData>| {
                                    evt.stop_propagation();
                                    (act_close.borrow_mut())(Box::new(move |st: &mut AppState| {
                                        st.workspace_layout.close_panel(PanelAddr {
                                            group: GroupAddr { dock_id: did, group_idx: gi },
                                            panel_idx: pi,
                                        });
                                    }));
                                },
                                "\u{00d7}"
                            }
                        }
                    }
                }
            });
            // After-last caret (only on the final tab)
            if pi == panel_count - 1 && tab_drop_idx == Some(panel_count) {
                nodes.push(rsx! {
                    div {
                        key: "tab-caret-{gi}-end",
                        style: "width:3px; align-self:stretch; background:{THEME_ACCENT}; border-radius:1px; flex-shrink:0; transition:width 0.1s ease;",
                    }
                });
            }
            nodes
        }).collect();

        let chevron = if group_collapsed { "\u{00BB}" } else { "\u{00AB}" };
        let body_label = group.active_panel()
            .map(crate::panels::panel_label)
            .unwrap_or_default();
        // Pre-compute active panel info for hamburger menu button
        let active_panel_info = group.active_panel().map(|kind| (kind, group.active));

        // Drop indicator logic
        let show_drop_before = cur_drag.is_some()
            && cur_drop == Some(DropTarget::GroupSlot { dock_id: did, group_idx: gi });
        let drop_indicator_style = if show_drop_before {
            "height:3px; background:{THEME_ACCENT}; border-radius:1px; margin:1px 4px; transition:height 0.1s ease;"
        } else {
            "height:0px; margin:0 4px; transition:height 0.1s ease;"
        };
        let show_drop_after = gi == group_count - 1
            && cur_drag.is_some()
            && cur_drop == Some(DropTarget::GroupSlot { dock_id: did, group_idx: group_count });
        let drop_after_style = if show_drop_after {
            "height:3px; background:{THEME_ACCENT}; border-radius:1px; margin:1px 4px; transition:height 0.1s ease;"
        } else {
            "height:0px; margin:0 4px; transition:height 0.1s ease;"
        };
        // Highlight tab bar when it's a TabBar drop target
        let tab_bar_drop = cur_drag.is_some()
            && matches!(cur_drop, Some(DropTarget::TabBar { group, .. }) if group == GroupAddr { dock_id: did, group_idx: gi });
        let tab_bar_border = if tab_bar_drop { format!("2px solid {THEME_ACCENT}") } else { format!("1px solid {THEME_BORDER}") };

        let is_dragged_group = matches!(cur_drag,
            Some(DragPayload::Group(addr)) if addr.dock_id == did && addr.group_idx == gi);
        let opacity = if is_dragged_group { "0.4" } else { "1.0" };

        rsx! {
            div {
                key: "dock-group-{did:?}-{gi}",
                style: "border-bottom:1px solid {THEME_BORDER}; opacity:{opacity};",
                ondragover: move |evt: Event<DragData>| {
                    evt.prevent_default();
                    let coords = evt.data().page_coordinates();
                    last_drag_pos.set((coords.x, coords.y));
                    let y = evt.data().element_coordinates().y;
                    let mid = 30.0;
                    if y < mid {
                        drop_target_sig.set(Some(DropTarget::GroupSlot { dock_id: did, group_idx: gi }));
                    } else {
                        drop_target_sig.set(Some(DropTarget::GroupSlot { dock_id: did, group_idx: gi + 1 }));
                    }
                },
                ondrop: move |evt: Event<DragData>| {
                    evt.prevent_default();
                    was_dropped.set(true);
                    let src = drag_source();
                    let tgt = drop_target_sig();
                    if let (Some(src), Some(tgt)) = (src, tgt) {
                        (act_drop.borrow_mut())(Box::new(move |st: &mut AppState| {
                            match (src, tgt) {
                                (DragPayload::Group(from), DropTarget::GroupSlot { dock_id: to_dock, group_idx: to_idx }) => {
                                    if from.dock_id == to_dock {
                                        st.workspace_layout.move_group_within_dock(to_dock, from.group_idx, to_idx);
                                    } else {
                                        st.workspace_layout.move_group_to_dock(from, to_dock, to_idx);
                                    }
                                }
                                (DragPayload::Panel(from), DropTarget::GroupSlot { dock_id: to_dock, group_idx: to_idx }) => {
                                    st.workspace_layout.insert_panel_as_new_group(from, to_dock, to_idx);
                                }
                                (DragPayload::Group(from), DropTarget::TabBar { group: to_group, .. }) => {
                                    st.workspace_layout.move_group_to_dock(from, to_group.dock_id, to_group.group_idx);
                                }
                                (DragPayload::Panel(from), DropTarget::TabBar { group: to_group, index: to_idx }) => {
                                    if from.group == to_group {
                                        // Same group: reorder
                                        st.workspace_layout.reorder_panel(to_group, from.panel_idx, to_idx);
                                    } else {
                                        st.workspace_layout.move_panel_to_group(from, to_group);
                                    }
                                }
                                _ => {}
                            }
                        }));
                    }
                    drag_source.set(None);
                    drop_target_sig.set(None);
                },

                div { style: "{drop_indicator_style}" }

                // Tab bar with grip handle
                {let panel_count = group.panels.len();
                rsx! { div {
                    style: "display:flex; background:{THEME_BG_DARK}; border-bottom:{tab_bar_border}; align-items:center; overflow-x:auto; overflow-y:hidden; min-height:24px;",
                    ondragover: move |evt: Event<DragData>| {
                        evt.prevent_default();
                        evt.stop_propagation();
                        let coords = evt.data().page_coordinates();
                        last_drag_pos.set((coords.x, coords.y));
                        drop_target_sig.set(Some(DropTarget::TabBar { group: GroupAddr { dock_id: did, group_idx: gi }, index: panel_count }));
                    },

                    // Grip handle for dragging the whole group
                    div {
                        style: "padding:2px 4px; cursor:grab; color:{THEME_TEXT_HINT}; font-size:10px; user-select:none;",
                        draggable: "true",
                        ondragstart: move |evt: Event<DragData>| {
                            evt.stop_propagation();
                            drag_source.set(Some(DragPayload::Group(GroupAddr {
                                dock_id: did,
                                group_idx: gi,
                            })));
                            was_dropped.set(false);
                        },
                        ondragend: move |_| {
                            if !was_dropped() {
                                let (x, y) = last_drag_pos();
                                let cur_tgt = drop_target_sig();
                                let act_detach = act_collapse.clone();
                                (act_detach.borrow_mut())(Box::new(move |st: &mut AppState| {
                                    let addr = GroupAddr { dock_id: did, group_idx: gi };
                                    if let Some(DropTarget::Edge(edge)) = cur_tgt {
                                        // Detach then snap to edge
                                        if let Some(fid) = st.workspace_layout.detach_group(addr, x, y) {
                                            st.workspace_layout.snap_to_edge(fid, edge);
                                        }
                                    } else {
                                        st.workspace_layout.detach_group(addr, x, y);
                                    }
                                }));
                            }
                            drag_source.set(None);
                            drop_target_sig.set(None);
                            was_dropped.set(false);
                        },
                        "\u{2801}\u{2801}"
                    }

                    for tab in tab_nodes {
                        {tab}
                    }

                    div {
                        style: "margin-left:auto; padding:3px 6px; cursor:pointer; font-size:18px; color:{THEME_TEXT_BUTTON}; user-select:none; line-height:1;",
                        onclick: {
                            let act = act_chevron.clone();
                            move |_| {
                                (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                    st.workspace_layout.toggle_group_collapsed(GroupAddr {
                                        dock_id: did,
                                        group_idx: gi,
                                    });
                                }));
                            }
                        },
                        "{chevron}"
                    }

                    // Hamburger menu button — hidden when collapsed
                    if !group_collapsed && active_panel_info.is_some() {
                        {
                            let (active_kind, active_idx) = active_panel_info.unwrap();
                            rsx! {
                                div {
                                    style: "padding:3px 6px; cursor:pointer; font-size:18px; color:{THEME_TEXT_BUTTON}; user-select:none; line-height:1;",
                                    onmousedown: move |evt: Event<MouseData>| {
                                        evt.stop_propagation();
                                        let coords = evt.data().page_coordinates();
                                        let addr = PanelAddr {
                                            group: GroupAddr { dock_id: did, group_idx: gi },
                                            panel_idx: active_idx,
                                        };
                                        panel_menu_open.set(Some(PanelMenuOpen {
                                            kind: active_kind,
                                            addr,
                                            x: coords.x,
                                            y: coords.y,
                                        }));
                                        menu_bar_open.set(None);
                                    },
                                    "\u{2261}" // ≡
                                }
                            }
                        }
                    }
                } } } // close tab bar div, rsx!, let

                if !group_collapsed {
                    {
                        let panel_body: Option<(serde_json::Value, serde_json::Value)> = group.active_panel().and_then(|kind| {
                            let content_id = panel_kind_to_content_id(kind);
                            let ws = Workspace::load()?;
                            // Pass the whole panel object (type: panel, id, content)
                            // so render_el dispatches to render_panel — which sets
                            // RenderCtx.panel_kind from the panel id. Without this,
                            // widget writes inside the panel fall through to the
                            // Stroke/None branch (stroke state writes silently
                            // discard non-stroke fields like font_family).
                            let content = ws.panel(content_id)?.clone();
                            let mut panel_map: serde_json::Map<String, serde_json::Value> = ws.panel_state_defaults(content_id).into_iter().collect();
                            // Apply live overrides only for relevant panels
                            let panel_name = content_id.strip_suffix("_panel_content").unwrap_or("");
                            for (k, v) in live_panel_overrides {
                                // Color overrides: mode, h, s, b, r, g, bl, c, m, y, k, hex
                                // Stroke overrides: weight, cap, join, miter_limit, etc.
                                // Only apply if key exists in this panel's state defaults
                                if panel_map.contains_key(k) {
                                    panel_map.insert(k.clone(), v.clone());
                                }
                            }
                            // Build a minimal state map containing only the keys this
                            // panel references. This prevents unrelated state changes
                            // (e.g. active_tool) from invalidating the panel memo cache.
                            let panel_state = build_panel_state_subset(panel_name, live_state_map);
                            let mut eval_map = serde_json::Map::new();
                            eval_map.insert("state".into(), serde_json::Value::Object(panel_state));
                            eval_map.insert("panel".into(), serde_json::Value::Object(panel_map));
                            eval_map.insert("icons".into(), serde_json::json!({}));
                            eval_map.insert("data".into(), serde_json::json!({
                                "swatch_libraries": live_state_map.get("_swatch_libraries")
                                    .cloned().unwrap_or(serde_json::Value::Null),
                                "_doc_generation": live_state_map.get("_doc_generation")
                                    .cloned().unwrap_or(serde_json::Value::Null)
                            }));
                            // OPACITY.md § States predicates at top level so
                            // yaml expressions like `enabled_when:
                            // "selection_has_mask"` and `bind.disabled:
                            // "!selection_has_mask"` resolve uniformly.
                            for (k, v) in selection_preds {
                                eval_map.insert(k.clone(), v.clone());
                            }
                            let eval_ctx = serde_json::Value::Object(eval_map);
                            Some((content, eval_ctx))
                        });
                        if let Some((content, eval_ctx)) = panel_body {
                            rsx! {
                                crate::interpreter::renderer::MemoYamlElement {
                                    el: content,
                                    ctx: eval_ctx,
                                }
                            }
                        } else {
                            rsx! {
                                div {
                                    style: "padding:12px; min-height:60px; color:{THEME_TEXT_BODY}; font-size:12px;",
                                    "{body_label}"
                                }
                            }
                        }
                    }
                }

                div { style: "{drop_after_style}" }
            }
        }
    }).collect()
}

// ---------------------------------------------------------------------------
// DockGroupsView — anchored dock content
// ---------------------------------------------------------------------------

/// Renders the panel groups for the anchored right dock.
///
/// When the dock is collapsed, shows icon buttons for each panel.
/// When expanded, renders full tabbed groups via [`build_dock_groups`].
#[component]
pub(crate) fn DockGroupsView() -> Element {
    let act = use_context::<Act>();
    let app = use_context::<Rc<RefCell<AppState>>>();
    let ds = use_context::<DragState>();
    let pms = use_context::<PanelMenuState>();
    let mbs = use_context::<MenuBarState>();
    // Subscribe to revision so we re-render when state changes.
    let revision = use_context::<Signal<u64>>();
    let _ = revision();

    // Extract everything we need from AppState, then drop the borrow
    // so child components (e.g. FillStrokeWidgetView) can borrow it.
    let (focused_panel, right_dock_snapshot, live_panel_overrides, live_state_map,
         selection_preds) = {
        let st = app.borrow();
        let focused = st.workspace_layout.focused_panel();
        let dock = st.workspace_layout.anchored_dock(DockEdge::Right).cloned();
        let panel_ov = build_live_panel_overrides(&st);
        let state_map = build_live_state_map(&st);
        let preds = build_selection_predicates(&st);
        (focused, dock, panel_ov, state_map, preds)
    };

    let nodes: Vec<Result<VNode, RenderError>> = match right_dock_snapshot.as_ref() {
        None => vec![],
        Some(dock) if dock.collapsed => {
            let act_dock = act.0.clone();
            let did = dock.id;
            dock.groups.iter().enumerate().flat_map(|(gi, group)| {
                let act_inner = act_dock.clone();
                group.panels.iter().enumerate().map(move |(pi, &kind)| {
                    let act = act_inner.clone();
                    let label = crate::panels::panel_label(kind);
                    let first_char: String = label.chars().take(1).collect();
                    rsx! {
                        div {
                            key: "dock-icon-{gi}-{pi}",
                            style: "width:28px; height:28px; margin:2px auto; background:{THEME_BG_TAB}; border-radius:3px; display:flex; align-items:center; justify-content:center; cursor:pointer; font-size:12px; font-weight:bold; color:{THEME_TEXT};",
                            title: "{label}",
                            onclick: move |_| {
                                (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                    st.workspace_layout.toggle_dock_collapsed(did);
                                    st.workspace_layout.set_active_panel(PanelAddr {
                                        group: GroupAddr { dock_id: did, group_idx: gi },
                                        panel_idx: pi,
                                    });
                                }));
                            },
                            "{first_char}"
                        }
                    }
                })
            }).collect()
        }
        Some(dock) => {
            build_dock_groups(
                dock.id,
                &dock.groups,
                &act.0,
                ds.drag_source,
                ds.drop_target,
                ds.was_dropped,
                ds.last_drag_pos,
                focused_panel,
                pms.open,
                mbs.open_menu,
                &live_panel_overrides,
                &live_state_map,
                &selection_preds,
            )
        }
    };

    // (borrow already dropped above)

    rsx! {
        for node in nodes {
            {node}
        }
    }
}

// ---------------------------------------------------------------------------
// FloatingDocksView — all floating dock overlays
// ---------------------------------------------------------------------------

/// Renders every floating dock as a position:fixed overlay.
#[component]
pub(crate) fn FloatingDocksView() -> Element {
    let act = use_context::<Act>();
    let app = use_context::<Rc<RefCell<AppState>>>();
    let ds = use_context::<DragState>();
    let pms = use_context::<PanelMenuState>();
    let mbs = use_context::<MenuBarState>();
    // Subscribe to revision so we re-render when state changes.
    let revision = use_context::<Signal<u64>>();
    let _ = revision();
    let mut title_drag = ds.title_drag;

    let (focused_panel, floating_snapshot, live_panel_overrides, live_state_map,
         selection_preds, z_order) = {
        let st = app.borrow();
        let focused = st.workspace_layout.focused_panel();
        let floating = st.workspace_layout.floating.clone();
        let panel_ov = build_live_panel_overrides(&st);
        let state_map = build_live_state_map(&st);
        let preds = build_selection_predicates(&st);
        let z = st.workspace_layout.z_order.clone();
        (focused, floating, panel_ov, state_map, preds, z)
    };

    let floating_nodes: Vec<Result<VNode, RenderError>> = floating_snapshot.iter().map(|fd| {
        let fid = fd.dock.id;
        let fx = fd.x;
        let fy = fd.y;
        let fw = fd.dock.width;
        let act_front = act.0.clone();
        let act_redock = act.0.clone();
        let fgroups = build_dock_groups(
            fid,
            &fd.dock.groups,
            &act.0,
            ds.drag_source,
            ds.drop_target,
            ds.was_dropped,
            ds.last_drag_pos,
            focused_panel,
            pms.open,
            mbs.open_menu,
            &live_panel_overrides,
            &live_state_map,
            &selection_preds,
        );
        let z = 900 + z_order.iter().position(|&id| id == fid).unwrap_or(0);

        rsx! {
            div {
                key: "floating-{fid:?}",
                style: "position:fixed; left:{fx}px; top:{fy}px; width:{fw}px; background:{THEME_BG}; border:1px solid {THEME_BORDER}; box-shadow:4px 4px 12px rgba(0,0,0,0.4); border-radius:4px; z-index:{z}; display:flex; flex-direction:column; overflow:hidden;",
                onmousedown: move |evt: Event<MouseData>| {
                    evt.stop_propagation();
                    (act_front.borrow_mut())(Box::new(move |st: &mut AppState| {
                        st.workspace_layout.bring_to_front(fid);
                    }));
                },

                // Title bar: drag to reposition, double-click to redock
                div {
                    style: "height:20px; background:{THEME_BG_DARK}; cursor:grab; display:flex; align-items:center; padding:0 6px; font-size:10px; color:{THEME_TEXT_DIM}; user-select:none;",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        let coords = evt.data().page_coordinates();
                        title_drag.set(Some((fid, coords.x - fx, coords.y - fy)));
                    },
                    ondoubleclick: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        title_drag.set(None);
                        (act_redock.borrow_mut())(Box::new(move |st: &mut AppState| {
                            st.workspace_layout.redock(fid);
                        }));
                    },
                }

                for g in fgroups {
                    {g}
                }
            }
        }
    }).collect();

    // (borrow already dropped above)

    rsx! {
        for fdock in floating_nodes {
            {fdock}
        }
    }
}
