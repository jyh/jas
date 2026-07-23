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
        ToolKind::MagicWand => "magic_wand",
        ToolKind::Pen => "pen",
        ToolKind::AddAnchorPoint => "add_anchor",
        ToolKind::DeleteAnchorPoint => "delete_anchor",
        ToolKind::AnchorPoint => "anchor_point",
        ToolKind::Pencil => "pencil",
        ToolKind::Paintbrush => "paintbrush",
        ToolKind::BlobBrush => "blob_brush",
        ToolKind::PathEraser => "path_eraser",
        ToolKind::Smooth => "smooth",
        ToolKind::Type => "type",
        ToolKind::TypeOnPath => "type_on_path",
        ToolKind::Line => "line",
        ToolKind::Rect => "rect",
        ToolKind::RoundedRect => "rounded_rect",
        ToolKind::Ellipse => "ellipse",
        ToolKind::Polygon => "polygon",
        ToolKind::Star => "star",
        ToolKind::Lasso => "lasso",
        ToolKind::Scale => "scale",
        ToolKind::Rotate => "rotate",
        ToolKind::Shear => "shear",
        ToolKind::Hand => "hand",
        ToolKind::Zoom => "zoom",
        ToolKind::Artboard => "artboard",
        ToolKind::Eyedropper => "eyedropper",
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

    // Resolve the "active color" the color panel should reflect.
    // Priority: the selection's uniform fill/stroke (so changing
    // selection updates the sliders) → tab default → app default.
    // Without this, active_color() returned only the tab/app default,
    // which is unchanged when the user clicks a differently-colored
    // shape on the canvas — the sliders would stay stuck on the old
    // panel-init values.
    let panel_color: Option<crate::geometry::element::Color> = {
        use crate::document::controller::{FillSummary, StrokeSummary,
            selection_fill_summary, selection_stroke_summary};
        st.tab().and_then(|t| {
            if st.fill_on_top {
                match selection_fill_summary(t.model.document()) {
                    FillSummary::Uniform(Some(f)) => Some(f.color),
                    FillSummary::Uniform(None) => None,
                    _ => t.model.default_fill.map(|f| f.color),
                }
            } else {
                match selection_stroke_summary(t.model.document()) {
                    StrokeSummary::Uniform(Some(s)) => Some(s.color),
                    StrokeSummary::Uniform(None) => None,
                    _ => t.model.default_stroke.map(|s| s.color),
                }
            }
        }).or_else(|| {
            if st.fill_on_top {
                st.app_default_fill.map(|f| f.color)
            } else {
                st.app_default_stroke.map(|s| s.color)
            }
        })
    };

    // Compute slider values from the resolved active color
    if let Some(color) = panel_color {
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
    m.insert("dash_align_anchors".into(), J::Bool(sp.dash_align_anchors));

    // ── Swatches panel overrides ────────────────────────────
    // Mirror SwatchesPanelState so the swatches panel's bind
    // expressions (panel.selected_swatches, panel.selected_library,
    // panel.open_libraries, panel.thumbnail_size) resolve against
    // the live state instead of the YAML defaults.
    let swp = &st.swatches_panel;
    m.insert("selected_swatches".into(), serde_json::Value::Array(
        swp.selected_swatches.iter().map(|&i| serde_json::json!(i)).collect()));
    m.insert("selected_library".into(), J::String(swp.selected_library.clone()));
    m.insert("open_libraries".into(), swp.open_libraries.clone());
    m.insert("thumbnail_size".into(), J::String(swp.thumbnail_size.clone()));
    // panel.recent_colors mirrors the active tab's model.recent_colors,
    // so the YAML's recent-color slot binds (panel.recent_colors.0..9)
    // see live edits without needing to re-init the panel each click.
    let recent: Vec<serde_json::Value> = st.recent_colors().iter()
        .map(|c| J::String(c.clone()))
        .collect();
    m.insert("recent_colors".into(), serde_json::Value::Array(recent));

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

    // ── Align panel overrides ─────────────────────────────────
    // Surface AlignPanelState so panel.align_to / panel.key_object_path
    // / panel.distribute_spacing_value / panel.use_preview_bounds
    // re-evaluate after set_align_to / set_panel_state effects.
    // Without this the Align To radio buttons don't toggle their
    // checked highlight when the user picks a different target.
    let ap = &st.align_panel;
    m.insert("align_to".into(), J::String(ap.align_to.as_str().into()));
    m.insert(
        "key_object_path".into(),
        match &ap.key_object_path {
            Some(p) => serde_json::json!({"__path__": p}),
            None => J::Null,
        },
    );
    m.insert("distribute_spacing_value".into(), serde_json::json!(ap.distribute_spacing));
    m.insert("use_preview_bounds".into(), J::Bool(ap.use_preview_bounds));

    // ── Artboards panel overrides ─────────────────────────────
    // panel.renaming_artboard reflects which row's inline editor is
    // open. Without this, the row template's bind.visible expressions
    // can't toggle between the static name and the text_input.
    m.insert(
        "renaming_artboard".into(),
        match &st.artboards_renaming {
            Some(id) => J::String(id.clone()),
            None => J::Null,
        },
    );
    m.insert(
        "artboards_panel_selection".into(),
        J::Array(
            st.artboards_panel_selection
                .iter()
                .map(|s| J::String(s.clone()))
                .collect(),
        ),
    );
    m.insert(
        "panel_selection_anchor".into(),
        match &st.artboards_panel_anchor {
            Some(id) => J::String(id.clone()),
            None => J::Null,
        },
    );
    m.insert("rearrange_dirty".into(), J::Bool(st.artboards_rearrange_dirty));
    m.insert(
        "reference_point".into(),
        J::String(st.artboards_reference_point.clone()),
    );

    // Symbols panel: the panel-selected master id (or null). Drives the
    // row highlight and the footer buttons' bind.disabled expressions.
    m.insert(
        "selected_symbol".into(),
        match &st.symbols_selected {
            Some(id) => J::String(id.clone()),
            None => J::Null,
        },
    );

    // Properties panel: the selection's EVALUATED bounding box (document
    // space, post-transform) in points — decision-5 Part B.1. The keys are
    // prop_-prefixed so they never collide with the Color panel's short y / h
    // keys (this map is applied to every panel by leaf-name match).
    if let Some(tab) = st.tab() {
        let doc = tab.model.document();
        let (px, py, pw, ph) = crate::canvas::render::selection_evaluated_bounds(doc);
        let r2 = |v: f64| (v * 100.0).round() / 100.0;
        m.insert("prop_x".into(), serde_json::json!(r2(px)));
        m.insert("prop_y".into(), serde_json::json!(r2(py)));
        m.insert("prop_w".into(), serde_json::json!(r2(pw)));
        m.insert("prop_h".into(), serde_json::json!(r2(ph)));
        // Part B.3: rotation / opacity / blend from the FIRST selected
        // element (like the Stroke panel weight). Defaults 0deg / 100% /
        // normal. Blend serializes to its snake_case id via serde.
        let mut rot = 0.0_f64;
        let mut shear = 0.0_f64;
        let mut op = 100.0_f64;
        let mut blend = J::String("normal".into());
        if let Some(e) = doc.selection.first().and_then(|es| doc.get_element(&es.path)) {
            if let Some(t) = e.transform() {
                rot = t.b.atan2(t.a).to_degrees();
                // Decomposed shear (M = R . ShearX . Scale): k = (a*c+b*d)/det,
                // shear = atan(k). 0 for any shear-free or degenerate matrix.
                let sx = (t.a * t.a + t.b * t.b).sqrt();
                let det = t.a * t.d - t.b * t.c;
                if sx != 0.0 && det != 0.0 {
                    shear = ((t.a * t.c + t.b * t.d) / det).atan().to_degrees();
                }
            }
            op = e.opacity() * 100.0;
            blend = serde_json::to_value(e.mode())
                .unwrap_or_else(|_| J::String("normal".into()));
        }
        m.insert("prop_rotation".into(), serde_json::json!(r2(rot)));
        m.insert("prop_shear".into(), serde_json::json!(r2(shear)));
        m.insert("prop_opacity".into(), serde_json::json!(r2(op)));
        m.insert("prop_blend".into(), blend);
    }
    // Properties constrain-proportions lock — a sticky AppState toggle, so the
    // icon binding (chain_linked / chain_broken) reflects it.
    m.insert("prop_constrain".into(), J::Bool(st.properties_constrain));

    m
}

/// The concept-pack registry as a sorted list of `{id, name, description}` for
/// the Concepts panel's `foreach source: "data.concepts"` (CONCEPTS.md §6).
/// Derived from the compiled workspace `concepts` registry; `Workspace::load`
/// is cached, so this is cheap.
fn workspace_concepts_list() -> serde_json::Value {
    let Some(ws) = crate::interpreter::workspace::Workspace::load() else {
        return serde_json::Value::Array(Vec::new());
    };
    let Some(map) = ws.data().get("concepts").and_then(|c| c.as_object()) else {
        return serde_json::Value::Array(Vec::new());
    };
    let mut ids: Vec<&String> = map.keys().collect();
    ids.sort();
    let list: Vec<serde_json::Value> = ids
        .into_iter()
        .map(|id| {
            let c = &map[id];
            serde_json::json!({
                "id": id,
                "name": c.get("name").cloned()
                    .unwrap_or_else(|| serde_json::Value::String(id.clone())),
                "description": c.get("description").cloned()
                    .unwrap_or(serde_json::Value::Null),
            })
        })
        .collect();
    serde_json::Value::Array(list)
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

    // Override fill/stroke colors from the active selection's fill /
    // stroke summary (so the Color panel's swatch reflects whatever
    // the user just clicked on the canvas), falling back to the tab
    // / app-level defaults when nothing is selected. Empty string for
    // "uniform but no fill" (the swatch renderer treats empty as the
    // diagonal-line "no fill" indicator).
    let (fill_string, stroke_string) = live_fill_stroke_strings(st);
    if let Some(s) = fill_string {
        m.insert("fill_color".into(), J::String(s));
    }
    if let Some(s) = stroke_string {
        m.insert("stroke_color".into(), J::String(s));
    }

    // Mutable swatch libraries for rendering
    m.insert("_swatch_libraries".into(), st.swatch_libraries.clone());
    // Mutable brush libraries for rendering — the Brushes panel binds its
    // per-library disclosure label/tiles to data.brush_libraries[lib.id].
    m.insert("_brush_libraries".into(), st.brush_libraries.clone());

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
    // Include the FULL panel selection paths (not just the count) so
    // clicking from one row to another with the same selection size
    // invalidates the panel memo cache and the row highlights update.
    let panel_sel_count = st.layers_panel_selection.len();
    m.insert("_layers_panel_sel_count".into(), serde_json::Value::Number(panel_sel_count.into()));
    m.insert(
        "_layers_panel_selection".into(),
        serde_json::json!(st.layers_panel_selection),
    );
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

/// Resolve the live `fill_color` / `stroke_color` strings from the active
/// selection's fill/stroke summary, falling back to the tab- / app-level
/// default. `Some("")` means "uniform but explicitly no fill" (the swatch
/// renderer draws the diagonal-line no-fill indicator, and a blob commit
/// reads it as an empty hex → genuinely unfilled). `None` means leave the
/// caller's existing value in place (Mixed selection, or NoSelection with
/// no default — the workspace `#ffffff` default then stands). Shared by
/// `build_live_state_map` (panel render) and `build_tool_state_map` (the
/// per-tool bridge) so both agree on the white-by-default contract.
pub(crate) fn live_fill_stroke_strings(
    st: &AppState,
) -> (Option<String>, Option<String>) {
    use crate::document::controller::{FillSummary, StrokeSummary};
    let (sel_fill_summary, sel_stroke_summary) = st.tab()
        .map(|t| (
            crate::document::controller::selection_fill_summary(t.model.document()),
            crate::document::controller::selection_stroke_summary(t.model.document()),
        ))
        .unwrap_or((FillSummary::NoSelection, StrokeSummary::NoSelection));
    let hex = |r: f64, g: f64, b: f64| format!("#{:02x}{:02x}{:02x}",
        (r * 255.0).round() as u8, (g * 255.0).round() as u8, (b * 255.0).round() as u8);
    let fill_string: Option<String> = match sel_fill_summary {
        FillSummary::Uniform(Some(f)) => { let (r, g, b, _) = f.color.to_rgba(); Some(hex(r, g, b)) }
        FillSummary::Uniform(None) => Some(String::new()),
        FillSummary::Mixed => None,
        FillSummary::NoSelection => st.tab()
            .and_then(|t| t.model.default_fill)
            .or(st.app_default_fill)
            .map(|f| { let (r, g, b, _) = f.color.to_rgba(); hex(r, g, b) }),
    };
    let stroke_string: Option<String> = match sel_stroke_summary {
        StrokeSummary::Uniform(Some(s)) => { let (r, g, b, _) = s.color.to_rgba(); Some(hex(r, g, b)) }
        StrokeSummary::Uniform(None) => Some(String::new()),
        StrokeSummary::Mixed => None,
        StrokeSummary::NoSelection => st.tab()
            .and_then(|t| t.model.default_stroke)
            .or(st.app_default_stroke)
            .map(|s| { let (r, g, b, _) = s.color.to_rgba(); hex(r, g, b) }),
    };
    (fill_string, stroke_string)
}

/// Lean app-state map for the per-tool bridge (`CanvasTool::sync_global_state`).
/// Carries only the global `state.*` keys a tool's commit-effects read —
/// the live fill/stroke (white `#ffffff` workspace default when nothing is
/// selected) plus the blob-brush tip params from the workspace defaults —
/// and deliberately omits the `_swatch_libraries` / `_doc_generation` /
/// `_layers_*` panel-render extras that `build_live_state_map` clones, since
/// this runs on the mousemove hot path. The tool side allowlists from this
/// map (see `BRIDGED_STATE_KEYS`).
pub(crate) fn build_tool_state_map(
    st: &AppState,
) -> serde_json::Map<String, serde_json::Value> {
    use serde_json::Value as J;
    let ws = Workspace::load();
    let defaults: serde_json::Map<String, serde_json::Value> = ws
        .map(|w| w.state_defaults().into_iter().collect())
        .unwrap_or_default();
    let mut m = serde_json::Map::new();
    // Base each bridged key on its workspace default (so fill_color
    // starts at #ffffff and blob_brush_* at 10/0/100/3/false), then
    // overlay the live fill/stroke below.
    for k in crate::tools::yaml_tool::BRIDGED_STATE_KEYS {
        if let Some(v) = defaults.get(*k) {
            m.insert((*k).to_string(), v.clone());
        }
    }
    let (fill_string, stroke_string) = live_fill_stroke_strings(st);
    if let Some(s) = fill_string {
        m.insert("fill_color".into(), J::String(s));
    }
    if let Some(s) = stroke_string {
        m.insert("stroke_color".into(), J::String(s));
    }
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
        "layers" => &["_doc_generation", "_layers_renaming", "_layers_collapsed_count", "_layers_panel_sel_count", "_layers_panel_selection", "_layers_drag_target", "_layers_context_menu", "_layers_search_query", "_layers_isolation_depth", "_layers_hidden_types_count", "_layers_filter_open"],
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
    active_doc_view: &serde_json::Value,
) -> Vec<Result<VNode, RenderError>> {
    let did = dock_id;
    let group_count = groups.len();
    // peek() reads drag_source / drop_target_sig without subscribing
    // the dock_panel render to them. Subscribing causes a full
    // dock_panel re-render mid-drag (when ondragstart writes the
    // signal), which destroys the source DOM element and kills the
    // browser's drag operation — dragend / drop / mouseup never
    // fire and the panel can't be detached. Drop-target visualization
    // (carets, highlights) is sacrificed but the drag actually works.
    let cur_drag = drag_source.peek().clone();
    let cur_drop = drop_target_sig.peek().clone();

    groups.iter().enumerate().map(|(gi, group)| {
        let act_tabs = act.clone();
        let act_chevron = act.clone();
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
                    // ondragend is handled at the app-level container
                    // (see app.rs). The dock_panel re-renders mid-drag
                    // when drag_source changes, destroying this div
                    // before release; a handler bound here would never
                    // fire. The bubbled event reaches the always-
                    // mounted app root reliably.
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
                            crate::workspace::layout_apply::layout_apply(
                                &mut st.workspace_layout,
                                &crate::workspace::layout_apply::op_set_active_panel(PanelAddr {
                                    group: GroupAddr { dock_id: did, group_idx: gi },
                                    panel_idx: pi,
                                }),
                            );
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
                                        crate::workspace::layout_apply::layout_apply(
                                            &mut st.workspace_layout,
                                            &crate::workspace::layout_apply::op_close_panel(PanelAddr {
                                                group: GroupAddr { dock_id: did, group_idx: gi },
                                                panel_idx: pi,
                                            }),
                                        );
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

        // Chevron points the way the panel will move on click: when
        // collapsed it points back toward the canvas (« — click to
        // expand inward); when expanded it points toward the dock
        // edge (» — click to collapse outward). Assumes right-side
        // dock placement, which is where panel groups live by default.
        let chevron = if group_collapsed { "\u{00AB}" } else { "\u{00BB}" };
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
                                        crate::workspace::layout_apply::layout_apply(
                                            &mut st.workspace_layout,
                                            &crate::workspace::layout_apply::op_reorder_panel(to_group, from.panel_idx, to_idx),
                                        );
                                    } else {
                                        crate::workspace::layout_apply::layout_apply(
                                            &mut st.workspace_layout,
                                            &crate::workspace::layout_apply::op_move_panel_to_group(from, to_group),
                                        );
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
                        // ondragend handled at app-level (see app.rs)
                        // — same re-render-destroys-source rationale
                        // as the panel-tab grip above.
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
                                    crate::workspace::layout_apply::layout_apply(
                                        &mut st.workspace_layout,
                                        &crate::workspace::layout_apply::op_toggle_group_collapsed(GroupAddr {
                                            dock_id: did,
                                            group_idx: gi,
                                        }),
                                    );
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
                            // SwatchesPanelState mirror keys (build_live_panel_overrides)
                            // use bare names that collide with the Brushes panel's own
                            // state (selected_library / open_libraries / thumbnail_size).
                            // They reflect the live SWATCHES state, so applying them to
                            // any other panel clobbers its defaults — e.g. Brushes'
                            // open_libraries becomes the swatches' web_colors library,
                            // which is absent from data.brush_libraries and blanks the
                            // panel. Scope them to the swatches panel.
                            const SWATCHES_OWNED: &[&str] = &[
                                "selected_swatches", "selected_library",
                                "open_libraries", "thumbnail_size",
                            ];
                            for (k, v) in live_panel_overrides {
                                // Color overrides: mode, h, s, b, r, g, bl, c, m, y, k, hex
                                // Stroke overrides: weight, cap, join, miter_limit, etc.
                                if panel_name != "swatches" && SWATCHES_OWNED.contains(&k.as_str()) {
                                    continue;
                                }
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
                            eval_map.insert("active_document".into(), active_doc_view.clone());
                            // Expose the active theme's colors as theme.colors
                            // so YAML expressions like {{theme.colors.selection}}
                            // resolve in panel bindings.
                            let theme_colors = ws.theme()
                                .get("base").and_then(|b| b.get("colors"))
                                .cloned().unwrap_or(serde_json::Value::Null);
                            eval_map.insert("theme".into(), serde_json::json!({"colors": theme_colors}));
                            eval_map.insert("icons".into(), serde_json::json!({}));
                            eval_map.insert("data".into(), serde_json::json!({
                                "swatch_libraries": live_state_map.get("_swatch_libraries")
                                    .cloned().unwrap_or(serde_json::Value::Null),
                                "brush_libraries": live_state_map.get("_brush_libraries")
                                    .cloned().unwrap_or(serde_json::Value::Null),
                                "concepts": workspace_concepts_list(),
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
                            // Explicit dark background on the panel
                            // body wrapper. Without this, areas without
                            // an explicit background (e.g. the
                            // <details>/<summary> disclosure containing
                            // the Swatches grid) render transparent and
                            // show the canvas through when the dock is
                            // floating.
                            rsx! {
                                div {
                                    style: "background:{THEME_BG};",
                                    crate::interpreter::renderer::MemoYamlElement {
                                        el: content,
                                        ctx: eval_ctx,
                                    }
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
         selection_preds, active_doc_view) = {
        let st = app.borrow();
        let focused = st.workspace_layout.focused_panel();
        let dock = st.workspace_layout.anchored_dock(DockEdge::Right).cloned();
        let panel_ov = build_live_panel_overrides(&st);
        let state_map = build_live_state_map(&st);
        let preds = build_selection_predicates(&st);
        let active_doc = crate::interpreter::renderer::build_active_document_view(&st);
        (focused, dock, panel_ov, state_map, preds, active_doc)
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
                                    crate::workspace::layout_apply::layout_apply(
                                        &mut st.workspace_layout,
                                        &crate::workspace::layout_apply::op_set_active_panel(PanelAddr {
                                            group: GroupAddr { dock_id: did, group_idx: gi },
                                            panel_idx: pi,
                                        }),
                                    );
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
                &active_doc_view,
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
         selection_preds, z_order, active_doc_view) = {
        let st = app.borrow();
        let focused = st.workspace_layout.focused_panel();
        let floating = st.workspace_layout.floating.clone();
        let panel_ov = build_live_panel_overrides(&st);
        let state_map = build_live_state_map(&st);
        let preds = build_selection_predicates(&st);
        let z = st.workspace_layout.z_order.clone();
        let active_doc = crate::interpreter::renderer::build_active_document_view(&st);
        (focused, floating, panel_ov, state_map, preds, z, active_doc)
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
            &active_doc_view,
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
                            crate::workspace::layout_apply::layout_apply(
                                &mut st.workspace_layout,
                                &crate::workspace::layout_apply::op_redock(fid),
                            );
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

#[cfg(test)]
mod stroke_panel_override_tests {
    use super::*;
    use crate::workspace::app_state::{AppState, TabState};
    use crate::document::document::ElementSelection;
    // `Element` in this module resolves to Dioxus's VNode result, so
    // reach the geometry enum by an explicit alias.
    use crate::geometry::element::{
        CommonProps, Color, Stroke, RectElem, Element as GeoEl,
    };

    // decision-5a: the Stroke panel Weight must reflect the SELECTED
    // element's stroke width (its baked / effective width after the
    // scale counter-scale work), not the app default — and fall back to
    // the app default stroke when nothing is selected. Rust already
    // does this in build_live_panel_overrides; these lock the parity
    // with the Python / Swift / OCaml ports.

    fn select_rect_with_stroke(st: &mut AppState, stroke: Option<Stroke>) {
        if st.tabs.is_empty() {
            st.tabs.push(TabState::new());
            st.active_tab = 0;
        }
        let r = GeoEl::Rect(RectElem {
            x: 0.0, y: 0.0, width: 100.0, height: 50.0, rx: 0.0, ry: 0.0,
            fill: None,
            stroke,
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        });
        let mut new_doc = st.tabs[st.active_tab].model.document().clone();
        if let Some(GeoEl::Layer(layer)) = new_doc.layers.get_mut(0) {
            layer.children = vec![std::rc::Rc::new(r)];
        }
        new_doc.selection = vec![ElementSelection::all(vec![0, 0])];
        st.tabs[st.active_tab].model.set_document_for_test(new_doc);
    }

    fn select_element(st: &mut AppState, e: GeoEl) {
        if st.tabs.is_empty() {
            st.tabs.push(TabState::new());
            st.active_tab = 0;
        }
        let mut new_doc = st.tabs[st.active_tab].model.document().clone();
        if let Some(GeoEl::Layer(layer)) = new_doc.layers.get_mut(0) {
            layer.children = vec![std::rc::Rc::new(e)];
        }
        new_doc.selection = vec![ElementSelection::all(vec![0, 0])];
        st.tabs[st.active_tab].model.set_document_for_test(new_doc);
    }

    // Brushes panel data fix: the live-state map must carry a non-empty
    // _brush_libraries so the panel data namespace resolves
    // data.brush_libraries[lib.id].name / .brushes.
    #[test]
    fn live_state_map_carries_brush_libraries() {
        let st = AppState::new();
        let m = build_live_state_map(&st);
        let bl = m.get("_brush_libraries").expect("_brush_libraries present");
        let obj = bl.as_object().expect("_brush_libraries is an object");
        assert!(obj.contains_key("default_brushes"),
            "default_brushes seeded, got keys {:?}", obj.keys().collect::<Vec<_>>());
        let name = bl.pointer("/default_brushes/name").and_then(|v| v.as_str());
        assert_eq!(name, Some("Default Brushes"));
    }

    // End-to-end render-context check for the Brushes panel body: replicate
    // the eval_map the dock builds (lines ~1244-1274) and evaluate the real
    // disclosure-label / tile-foreach expressions from brushes.yaml.
    #[test]
    fn brushes_panel_body_expressions_resolve() {
        use crate::interpreter::workspace::Workspace;
        use crate::interpreter::expr;
        let st = AppState::new();
        let ws = Workspace::load().expect("workspace");
        let content_id = "brushes_panel_content";
        let panel_name = "brushes";
        let live_state_map = build_live_state_map(&st);

        let mut panel_map: serde_json::Map<String, serde_json::Value> =
            ws.panel_state_defaults(content_id).into_iter().collect();
        // Replicate the dock's override application (incl. the swatches-owned
        // scoping): the live SWATCHES open_libraries (web_colors) must NOT
        // clobber the Brushes panel's own open_libraries default.
        let overrides = build_live_panel_overrides(&st);
        // Confirm the collision exists: the override map carries the swatches
        // open_libraries (web_colors), which without scoping would clobber
        // the brushes default below.
        assert_eq!(
            overrides.get("open_libraries")
                .and_then(|v| v.as_array())
                .and_then(|a| a.first())
                .and_then(|o| o.get("id"))
                .and_then(|v| v.as_str()),
            Some("web_colors"),
            "swatches override open_libraries present (the collision source)");
        const SWATCHES_OWNED: &[&str] = &[
            "selected_swatches", "selected_library", "open_libraries", "thumbnail_size",
        ];
        for (k, v) in &overrides {
            if panel_name != "swatches" && SWATCHES_OWNED.contains(&k.as_str()) {
                continue;
            }
            if panel_map.contains_key(k) {
                panel_map.insert(k.clone(), v.clone());
            }
        }
        let panel_state = build_panel_state_subset(panel_name, &live_state_map);
        let mut eval_map = serde_json::Map::new();
        eval_map.insert("state".into(), serde_json::Value::Object(panel_state));
        eval_map.insert("panel".into(), serde_json::Value::Object(panel_map));
        eval_map.insert("data".into(), serde_json::json!({
            "brush_libraries": live_state_map.get("_brush_libraries")
                .cloned().unwrap_or(serde_json::Value::Null),
        }));
        let ctx = serde_json::Value::Object(eval_map);

        // Outer foreach source.
        use crate::interpreter::expr_types::Value;
        let open = expr::eval("panel.open_libraries", &ctx);
        let open_json = match open { Value::List(ref v) => serde_json::Value::Array(v.clone()), Value::Str(ref s) => serde_json::from_str(s).unwrap_or(serde_json::Value::Null), _ => serde_json::Value::Null };
        let arr = open_json.as_array().expect("open_libraries is a list");
        assert_eq!(arr.len(), 1, "one open library, got {:?}", open_json);
        let lib_id = arr[0].get("id").and_then(|v| v.as_str()).unwrap_or("");
        assert_eq!(lib_id, "default_brushes", "lib.id");

        // Build the foreach child scope and evaluate the disclosure label.
        let mut child = ctx.as_object().unwrap().clone();
        child.insert("lib".into(), arr[0].clone());
        let child_ctx = serde_json::Value::Object(child);
        let name = expr::eval("data.brush_libraries[lib.id].name", &child_ctx);
        assert_eq!(name.to_string_coerce(), "Default Brushes",
            "disclosure label resolved (got {:?})", name);

        // The disclosure renders its label via eval_text (the {{...}} form),
        // and the tile foreach source is also an indexed data path. Pin both
        // through the exact render entrypoints.
        let label_text = expr::eval_text("{{data.brush_libraries[lib.id].name}}", &child_ctx);
        assert_eq!(label_text, "Default Brushes", "eval_text label (got {:?})", label_text);
        let brushes = expr::eval("data.brush_libraries[lib.id].brushes", &child_ctx);
        let brushes_json = match brushes { Value::List(ref v) => serde_json::Value::Array(v.clone()), Value::Str(ref s) => serde_json::from_str(s).unwrap_or(serde_json::Value::Null), _ => serde_json::Value::Null };
        assert!(brushes_json.as_array().map(|a| !a.is_empty()).unwrap_or(false),
            "tile foreach source non-empty (got {:?})", brushes_json);
    }

    // Part B.3: rotation / opacity / blend from the first selected element.
    #[test]
    fn properties_attrs_from_first_selected() {
        use crate::geometry::element::{Transform, BlendMode};
        let mut st = AppState::new();
        let e = GeoEl::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps {
                transform: Some(Transform::rotate(90.0)),
                opacity: 0.5,
                mode: BlendMode::Multiply,
                ..Default::default()
            },
            fill_gradient: None, stroke_gradient: None,
        });
        select_element(&mut st, e);
        let m = build_live_panel_overrides(&st);
        assert!((m.get("prop_rotation").and_then(|v| v.as_f64()).unwrap() - 90.0).abs() < 0.01);
        assert_eq!(m.get("prop_opacity").and_then(|v| v.as_f64()), Some(50.0));
        assert_eq!(m.get("prop_blend").and_then(|v| v.as_str()), Some("multiply"));
    }

    // SHEAR-FIELD T1: the panel shows the first selected element's decomposed
    // shear. A transform (a=1,b=0,c=1,d=1,e=0,f=0) decomposes to shear ~= 45.
    #[test]
    fn properties_shear_from_first_selected() {
        use crate::geometry::element::Transform;
        let mut st = AppState::new();
        let e = GeoEl::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps {
                transform: Some(Transform { a: 1.0, b: 0.0, c: 1.0, d: 1.0, e: 0.0, f: 0.0 }),
                ..Default::default()
            },
            fill_gradient: None, stroke_gradient: None,
        });
        select_element(&mut st, e);
        let m = build_live_panel_overrides(&st);
        assert!((m.get("prop_shear").and_then(|v| v.as_f64()).unwrap() - 45.0).abs() < 0.01,
            "prop_shear={:?}", m.get("prop_shear"));
    }

    #[test]
    fn properties_attrs_default_no_selection() {
        // A tab with an empty selection (the realistic "nothing selected"
        // case; the panel only renders with a document open).
        let mut st = AppState::new();
        if st.tabs.is_empty() {
            st.tabs.push(TabState::new());
            st.active_tab = 0;
        }
        let m = build_live_panel_overrides(&st);
        assert_eq!(m.get("prop_rotation").and_then(|v| v.as_f64()), Some(0.0));
        assert_eq!(m.get("prop_shear").and_then(|v| v.as_f64()), Some(0.0));
        assert_eq!(m.get("prop_opacity").and_then(|v| v.as_f64()), Some(100.0));
        assert_eq!(m.get("prop_blend").and_then(|v| v.as_str()), Some("normal"));
    }

    #[test]
    fn weight_from_selected_element() {
        let mut st = AppState::new();
        // A scaled element baked its stroke to 2.5pt — the panel shows it.
        select_rect_with_stroke(&mut st, Some(Stroke::new(Color::BLACK, 2.5)));
        let m = build_live_panel_overrides(&st);
        assert_eq!(m.get("weight").and_then(|v| v.as_f64()), Some(2.5));
    }

    #[test]
    fn cap_join_from_selected_element() {
        use crate::geometry::element::{LineCap, LineJoin};
        let mut st = AppState::new();
        let mut s = Stroke::new(Color::BLACK, 1.0);
        s.linecap = LineCap::Round;
        s.linejoin = LineJoin::Bevel;
        select_rect_with_stroke(&mut st, Some(s));
        let m = build_live_panel_overrides(&st);
        assert_eq!(m.get("cap").and_then(|v| v.as_str()), Some("round"));
        assert_eq!(m.get("join").and_then(|v| v.as_str()), Some("bevel"));
    }

    #[test]
    fn no_selection_uses_app_default() {
        let mut st = AppState::new();  // app_default_stroke width 1.0
        // Selection empty -> fall back to the app default stroke width.
        let m = build_live_panel_overrides(&st);
        assert_eq!(m.get("weight").and_then(|v| v.as_f64()), Some(1.0));
    }

    #[test]
    fn selected_without_stroke_uses_app_default() {
        let mut st = AppState::new();
        select_rect_with_stroke(&mut st, None);  // rect has no stroke
        let m = build_live_panel_overrides(&st);
        assert_eq!(m.get("weight").and_then(|v| v.as_f64()), Some(1.0));
    }
}

#[cfg(test)]
mod concept_tests {
    use super::*;

    #[test]
    fn workspace_concepts_list_exposes_sorted_registry() {
        // data.concepts for the Concepts panel: the registered packs as a
        // sorted [{id,name,description}] list (CONCEPTS.md §6 / 3a).
        let v = workspace_concepts_list();
        let arr = v.as_array().expect("a list");
        let ids: Vec<&str> = arr.iter()
            .filter_map(|c| c.get("id").and_then(|i| i.as_str()))
            .collect();
        assert_eq!(ids, vec!["gear", "regular_polygon", "spiral", "star"]);
        // Names are present (so {{concept.name}} renders).
        assert!(arr.iter().all(|c| c.get("name").and_then(|n| n.as_str()).is_some()));
    }
}

// ── Paragraph panel text-kind gating + attr read-back seam tests ──
//
// Cross-language-equivalent port of the text-kind gating and indent
// read-back cases from the Python reference suite
// jas/panels/paragraph_panel_state_test.py
// (TestSyncParagraphPanelFromSelection + TestPhase3bParagraphAttrReads).
// In Rust these live-panel values are computed in
// `build_live_panel_overrides`: `text_selected` / `area_text_selected`
// mark whether a text element (and specifically an area-text element)
// is selected, and the paragraph-wrapper attrs are aggregated onto the
// panel keys. (The panel->element WRITE path — apply / mutual
// exclusion / reset / alignment sync — is already covered by the
// existing paragraph tests in interpreter/renderer.rs.)
#[cfg(test)]
mod paragraph_gating_tests {
    use super::*;
    use crate::workspace::app_state::{AppState, TabState};
    use crate::document::document::ElementSelection;
    use crate::geometry::element::{
        CommonProps, Color, Fill, RectElem, TextElem, TextPathElem, Element as GeoEl,
    };
    use crate::geometry::tspan::Tspan;

    fn ensure_tab(st: &mut AppState) {
        if st.tabs.is_empty() {
            st.tabs.push(TabState::new());
            st.active_tab = 0;
        }
    }

    /// Put `children` under layer 0 and select every listed path.
    fn state_with(children: Vec<GeoEl>, selection: Vec<Vec<usize>>) -> AppState {
        let mut st = AppState::new();
        ensure_tab(&mut st);
        let mut new_doc = st.tabs[st.active_tab].model.document().clone();
        if let Some(GeoEl::Layer(layer)) = new_doc.layers.get_mut(0) {
            layer.children = children.into_iter().map(std::rc::Rc::new).collect();
        }
        new_doc.selection = selection.into_iter().map(ElementSelection::all).collect();
        st.tabs[st.active_tab].model.set_document_for_test(new_doc);
        st
    }

    fn text(width: f64, height: f64) -> GeoEl {
        GeoEl::Text(TextElem::from_string(
            0.0, 0.0, "hi", "sans-serif", 12.0,
            "normal", "normal", "none", width, height,
            Some(Fill::new(Color::BLACK)), None, CommonProps::default(),
        ))
    }

    fn area_text_with_wrapper(w: Tspan) -> GeoEl {
        let mut t = TextElem::from_string(
            0.0, 0.0, "hello", "sans-serif", 12.0,
            "normal", "normal", "none", 200.0, 100.0,
            Some(Fill::new(Color::BLACK)), None, CommonProps::default(),
        );
        let body = Tspan { id: 1, content: "hello".into(), ..Tspan::default_tspan() };
        t.tspans = vec![w, body];
        GeoEl::Text(t)
    }

    fn get_bool(st: &AppState, key: &str) -> bool {
        build_live_panel_overrides(st).get(key).and_then(|v| v.as_bool())
            .unwrap_or_else(|| panic!("{key} missing / not a bool"))
    }

    fn get_f64(st: &AppState, key: &str) -> f64 {
        build_live_panel_overrides(st).get(key).and_then(|v| v.as_f64())
            .unwrap_or_else(|| panic!("{key} missing / not a number"))
    }

    fn get_str(st: &AppState, key: &str) -> String {
        build_live_panel_overrides(st).get(key).and_then(|v| v.as_str())
            .unwrap_or_else(|| panic!("{key} missing / not a string")).to_string()
    }

    #[test]
    fn point_text_enables_universal_only() {
        // width=0,height=0 -> point text.
        let st = state_with(vec![text(0.0, 0.0)], vec![vec![0, 0]]);
        assert!(get_bool(&st, "text_selected"));
        assert!(!get_bool(&st, "area_text_selected"));
    }

    #[test]
    fn area_text_enables_all() {
        let st = state_with(vec![text(200.0, 100.0)], vec![vec![0, 0]]);
        assert!(get_bool(&st, "text_selected"));
        assert!(get_bool(&st, "area_text_selected"));
    }

    #[test]
    fn text_path_enables_universal_only() {
        let tp = GeoEl::TextPath(TextPathElem::from_string(
            vec![], "path", 0.0, "sans-serif", 14.0,
            "normal", "normal", "none",
            Some(Fill::new(Color::BLACK)), None, CommonProps::default(),
        ));
        let st = state_with(vec![tp], vec![vec![0, 0]]);
        assert!(get_bool(&st, "text_selected"));
        assert!(!get_bool(&st, "area_text_selected"));
    }

    #[test]
    fn empty_selection_disables_panel() {
        let st = state_with(vec![text(200.0, 100.0)], vec![]);
        assert!(!get_bool(&st, "text_selected"));
        assert!(!get_bool(&st, "area_text_selected"));
    }

    #[test]
    fn non_text_selection_disables_panel() {
        let r = GeoEl::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        });
        let st = state_with(vec![r], vec![vec![0, 0]]);
        assert!(!get_bool(&st, "text_selected"));
        assert!(!get_bool(&st, "area_text_selected"));
    }

    #[test]
    fn mixed_area_and_point_disables_area_only_controls() {
        // "a control is enabled iff every selected text element supports
        // it" -> area_text_selected stays false when a point text is
        // also selected.
        let st = state_with(vec![text(200.0, 100.0), text(0.0, 0.0)],
                            vec![vec![0, 0], vec![0, 1]]);
        assert!(get_bool(&st, "text_selected"));
        assert!(!get_bool(&st, "area_text_selected"));
    }

    #[test]
    fn reads_para_wrapper_indents_and_bullets() {
        let w = Tspan {
            id: 0, content: String::new(),
            jas_role: Some("paragraph".into()),
            jas_left_indent: Some(18.0),
            jas_right_indent: Some(9.0),
            jas_hyphenate: Some(true),
            jas_list_style: Some("bullet-disc".into()),
            ..Tspan::default_tspan()
        };
        let st = state_with(vec![area_text_with_wrapper(w)], vec![vec![0, 0]]);
        assert_eq!(get_f64(&st, "left_indent"), 18.0);
        assert_eq!(get_f64(&st, "right_indent"), 9.0);
        assert!(get_bool(&st, "hyphenate"));
        assert_eq!(get_str(&st, "bullets"), "bullet-disc");
        assert_eq!(get_str(&st, "numbered_list"), "");
    }

    #[test]
    fn num_list_style_routes_to_numbered_dropdown() {
        let w = Tspan {
            id: 0, content: String::new(),
            jas_role: Some("paragraph".into()),
            jas_list_style: Some("num-decimal".into()),
            ..Tspan::default_tspan()
        };
        let st = state_with(vec![area_text_with_wrapper(w)], vec![vec![0, 0]]);
        assert_eq!(get_str(&st, "numbered_list"), "num-decimal");
        assert_eq!(get_str(&st, "bullets"), "");
    }

    #[test]
    fn mixed_numeric_indent_omits_override() {
        // Two wrappers disagreeing on left_indent -> no agreed value ->
        // panel keeps the typed-struct default (0).
        let w1 = Tspan {
            id: 0, content: String::new(), jas_role: Some("paragraph".into()),
            jas_left_indent: Some(12.0), ..Tspan::default_tspan()
        };
        let c1 = Tspan { id: 1, content: "first ".into(), ..Tspan::default_tspan() };
        let w2 = Tspan {
            id: 2, content: String::new(), jas_role: Some("paragraph".into()),
            jas_left_indent: Some(24.0), ..Tspan::default_tspan()
        };
        let c2 = Tspan { id: 3, content: "second".into(), ..Tspan::default_tspan() };
        let mut t = TextElem::from_string(
            0.0, 0.0, "first second", "sans-serif", 12.0,
            "normal", "normal", "none", 200.0, 100.0,
            Some(Fill::new(Color::BLACK)), None, CommonProps::default(),
        );
        t.tspans = vec![w1, c1, w2, c2];
        let st = state_with(vec![GeoEl::Text(t)], vec![vec![0, 0]]);
        assert_eq!(get_f64(&st, "left_indent"), 0.0);
    }
}
