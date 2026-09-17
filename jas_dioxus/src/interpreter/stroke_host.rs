//! The Stroke panel's write to the selection, hosted without a web dependency
//! (FB wave 2b, W2b-4).
//!
//! A Stroke panel edit names the field the person committed, and only the
//! attribute GROUP that field owns is written to each selected element (the
//! law is `transcripts/STROKE.md`, the table is
//! `workspace_interpreter/stroke_law.py`). This module is the ONE Rust
//! implementation of that write. The web app calls it from
//! `AppState::apply_stroke_panel_to_selection` with the panel struct it
//! keeps. The engine calls it from its effect host with a
//! [`StrokePanelState`] read out of its store by
//! [`StrokePanelState::from_store`], as the reference's `stroke_panel_state`
//! reads it.

use crate::document::controller::Controller;
use crate::document::model::Model;
use crate::geometry::element::{ArrowAlign, Arrowhead, LineCap, LineJoin, Stroke, StrokeAlign};

/// Stroke panel state fields that sync with global state and the selection.
#[derive(Debug, Clone)]
pub struct StrokePanelState {
    /// The Weight input's committed value, in points. THE source of the
    /// width a weight edit applies (`StrokeEditGroup::Width`).
    ///
    /// This used to have no slot at all: the weight commit wrote straight
    /// into `app_default_stroke.width` / the tab default and the apply read
    /// it back from there, so with no default stroke (after picking the None
    /// stroke swatch) the commit was DROPPED and typing a weight was a
    /// silent no-op — while Swift, which reads its panel-scope `weight`
    /// first, applied it. Both ports now read the panel-committed value.
    pub weight: f64,
    pub cap: String,
    pub join: String,
    pub miter_limit: f64,
    pub align: String,
    pub dashed: bool,
    pub dash_1: f64,
    pub gap_1: f64,
    pub dash_2: Option<f64>,
    pub gap_2: Option<f64>,
    pub dash_3: Option<f64>,
    pub gap_3: Option<f64>,
    pub dash_align_anchors: bool,
    pub start_arrowhead: String,
    pub end_arrowhead: String,
    pub start_arrowhead_scale: f64,
    pub end_arrowhead_scale: f64,
    pub link_arrowhead_scale: bool,
    pub arrow_align: String,
    pub profile: String,
    pub profile_flipped: bool,
}

impl StrokePanelState {
    /// Write ONE panel field from a YAML-interpreted value. Keys are the
    /// panel-scope names (`cap`, `weight`, ...). A value of the wrong type,
    /// and an unknown key, write nothing. The three optional dash pairs take
    /// `null` as "unused".
    pub fn set_field(&mut self, key: &str, val: &serde_json::Value) {
        let sp = self;
        match key {
            "cap" => { if let Some(s) = val.as_str() { sp.cap = s.into(); } }
            "join" => { if let Some(s) = val.as_str() { sp.join = s.into(); } }
            "miter_limit" => { if let Some(n) = val.as_f64() { sp.miter_limit = n; } }
            "align_stroke" => { if let Some(s) = val.as_str() { sp.align = s.into(); } }
            "dashed" => { if let Some(b) = val.as_bool() { sp.dashed = b; } }
            "dash_1" => { if let Some(n) = val.as_f64() { sp.dash_1 = n; } }
            "gap_1" => { if let Some(n) = val.as_f64() { sp.gap_1 = n; } }
            "dash_2" => { sp.dash_2 = val.as_f64(); }
            "gap_2" => { sp.gap_2 = val.as_f64(); }
            "dash_3" => { sp.dash_3 = val.as_f64(); }
            "gap_3" => { sp.gap_3 = val.as_f64(); }
            "dash_align_anchors" => { if let Some(b) = val.as_bool() { sp.dash_align_anchors = b; } }
            "start_arrowhead" => { if let Some(s) = val.as_str() { sp.start_arrowhead = s.into(); } }
            "end_arrowhead" => { if let Some(s) = val.as_str() { sp.end_arrowhead = s.into(); } }
            "start_arrowhead_scale" => { if let Some(n) = val.as_f64() { sp.start_arrowhead_scale = n; } }
            "end_arrowhead_scale" => { if let Some(n) = val.as_f64() { sp.end_arrowhead_scale = n; } }
            "link_arrowhead_scale" => { if let Some(b) = val.as_bool() { sp.link_arrowhead_scale = b; } }
            "arrow_align" => { if let Some(s) = val.as_str() { sp.arrow_align = s.into(); } }
            "profile" => { if let Some(s) = val.as_str() { sp.profile = s.into(); } }
            "profile_flipped" => { if let Some(b) = val.as_bool() { sp.profile_flipped = b; } }
            // The committed weight lives on the panel state like every other
            // field; `apply_stroke_panel_to_selection` reads it from there.
            "weight" => { if let Some(n) = val.as_f64() { sp.weight = n; } }
            _ => {}
        }
    }
}

impl Default for StrokePanelState {
    fn default() -> Self {
        Self {
            weight: 1.0,
            cap: "butt".into(),
            join: "miter".into(),
            miter_limit: 10.0,
            align: "center".into(),
            dashed: false,
            dash_1: 12.0,
            gap_1: 12.0,
            dash_2: None,
            gap_2: None,
            dash_3: None,
            gap_3: None,
            dash_align_anchors: false,
            start_arrowhead: "none".into(),
            end_arrowhead: "none".into(),
            start_arrowhead_scale: 100.0,
            end_arrowhead_scale: 100.0,
            link_arrowhead_scale: false,
            arrow_align: "tip_at_end".into(),
            profile: "uniform".into(),
            profile_flipped: false,
        }
    }
}

/// The stroke attributes ONE Stroke-panel field owns.
///
/// A panel edit must write only the group it touched and preserve every
/// other attribute from the element (see
/// `AppState::apply_stroke_panel_to_selection`). Fields that move
/// together stay in one group, and only where that is forced: the dash
/// inputs and the dashed toggle are one pattern because a dash array
/// cannot be written a slot at a time.
///
/// The two arrowhead scales are NOT one group. They used to be, on the
/// reasoning that the link-scales button moves them together — but the
/// chain mirrors by COMMITTING the sibling field (`stroke.yaml` arrow-scale
/// on_change), which applies through that field's own group. The wide group
/// bought nothing and cost an UNLINKED scale edit stamping the panel's
/// sibling scale over the element's own.
///
/// Mirrors the reference `STROKE_EDIT_GROUPS`
/// (`workspace_interpreter/stroke_law.py`), which states the table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StrokeEditGroup {
    Width,
    Cap,
    Join,
    MiterLimit,
    Align,
    Dash,
    StartArrow,
    EndArrow,
    StartArrowScale,
    EndArrowScale,
    ArrowAlign,
    /// Width profile only — the Stroke struct itself is untouched.
    Profile,
}

/// A Stroke-panel field key normalized to its panel-scope name.
///
/// The flat GLOBAL keys a YAML `set:` effect writes carry a `stroke_`
/// prefix (`stroke_cap`); the panel scope does not (`cap`). The weight
/// input is the one asymmetric pair: its global is `stroke_width` while its
/// panel field is `weight`.
///
/// This normalization belongs in production, not in a test harness. The
/// corpus's `*_global_key` vectors assert that the flat form reaches the
/// same group, and the Rust arm used to do the stripping itself — so those
/// vectors passed VACUOUSLY here while genuinely pinning the reference and
/// Swift, both of which normalize in production (`stroke_field_name` /
/// `strokeFieldName`). Mirrors them.
pub fn stroke_field_name(key: &str) -> &str {
    let name = key.strip_prefix("stroke_").unwrap_or(key);
    if name == "width" { "weight" } else { name }
}

impl StrokeEditGroup {
    /// Map a Stroke-panel field key to the group it owns. Accepts both the
    /// PANEL key (`"cap"` — what `renderer::set_stroke_field` writes) and
    /// the flat GLOBAL key (`"stroke_cap"` — what a YAML `set:` effect
    /// writes). `None` means the key owns no element attribute, so editing
    /// it writes nothing to the selection.
    pub fn from_field(key: &str) -> Option<Self> {
        Some(match stroke_field_name(key) {
            "weight" => Self::Width,
            "cap" => Self::Cap,
            "join" => Self::Join,
            "miter_limit" => Self::MiterLimit,
            "align_stroke" | "align" => Self::Align,
            "dashed" | "dash_1" | "gap_1" | "dash_2" | "gap_2" | "dash_3"
            | "gap_3" | "dash_align_anchors" => Self::Dash,
            "start_arrowhead" => Self::StartArrow,
            "end_arrowhead" => Self::EndArrow,
            "start_arrowhead_scale" => Self::StartArrowScale,
            "end_arrowhead_scale" => Self::EndArrowScale,
            // `link_arrowhead_scale` is a UI-only flag: the chain button
            // mirrors one scale onto the other by committing the SIBLING
            // scale field, which applies through that field's own group.
            // Toggling the chain itself must not touch the document (it
            // would push an undo step that changes nothing).
            "arrow_align" => Self::ArrowAlign,
            "profile" | "profile_flipped" => Self::Profile,
            _ => return None,
        })
    }
}

/// Overwrite `base`'s `group` attributes from the Stroke panel state,
/// leaving every other attribute of `base` untouched. `committed_width`
/// is the weight input's committed value and is read only for
/// [`StrokeEditGroup::Width`].
pub fn stroke_with_group(
    base: Stroke, sp: &StrokePanelState, group: StrokeEditGroup, committed_width: f64,
) -> Stroke {
    let mut s = base;
    match group {
        StrokeEditGroup::Width => s.width = committed_width,
        StrokeEditGroup::Cap => {
            s.linecap = match sp.cap.as_str() {
                "round" => LineCap::Round,
                "square" => LineCap::Square,
                _ => LineCap::Butt,
            };
        }
        StrokeEditGroup::Join => {
            s.linejoin = match sp.join.as_str() {
                "round" => LineJoin::Round,
                "bevel" => LineJoin::Bevel,
                _ => LineJoin::Miter,
            };
        }
        StrokeEditGroup::MiterLimit => s.miter_limit = sp.miter_limit,
        StrokeEditGroup::Align => {
            s.align = match sp.align.as_str() {
                "inside" => StrokeAlign::Inside,
                "outside" => StrokeAlign::Outside,
                _ => StrokeAlign::Center,
            };
        }
        StrokeEditGroup::Dash => {
            let mut dash_pattern = [0.0f64; 6];
            let mut dash_len: u8 = 0;
            if sp.dashed {
                dash_pattern[0] = sp.dash_1;
                dash_pattern[1] = sp.gap_1;
                dash_len = 2;
                if let (Some(d), Some(g)) = (sp.dash_2, sp.gap_2) {
                    dash_pattern[2] = d;
                    dash_pattern[3] = g;
                    dash_len = 4;
                }
                if let (Some(d), Some(g)) = (sp.dash_3, sp.gap_3) {
                    dash_pattern[4] = d;
                    dash_pattern[5] = g;
                    dash_len = 6;
                }
            }
            s.dash_pattern = dash_pattern;
            s.dash_len = dash_len;
            s.dash_align_anchors = sp.dash_align_anchors;
        }
        StrokeEditGroup::StartArrow => s.start_arrow = Arrowhead::from_str(&sp.start_arrowhead),
        StrokeEditGroup::EndArrow => s.end_arrow = Arrowhead::from_str(&sp.end_arrowhead),
        // Each scale is its own group: an unlinked edit of one must not
        // stamp the panel's sibling scale onto the element.
        StrokeEditGroup::StartArrowScale => s.start_arrow_scale = sp.start_arrowhead_scale,
        StrokeEditGroup::EndArrowScale => s.end_arrow_scale = sp.end_arrowhead_scale,
        StrokeEditGroup::ArrowAlign => {
            s.arrow_align = if sp.arrow_align == "center_at_end" {
                ArrowAlign::CenterAtEnd
            } else {
                ArrowAlign::TipAtEnd
            };
        }
        // The profile lives in the element's width points, not the Stroke.
        StrokeEditGroup::Profile => {}
    }
    s
}

/// Apply ONE Stroke-panel edit to the selected element(s) of `model`, and to
/// the new-element default.
///
/// `edited` is the field the person just committed, in either spelling
/// ([`stroke_field_name`]). Only that field's [`StrokeEditGroup`] is taken
/// from `sp`; every other stroke attribute is preserved from the element being
/// edited, per element. An element with no stroke builds on the fallback: the
/// first selected element's stroke, else the default. A key that owns no group
/// writes nothing.
///
/// `app_default` is the web app's app-wide default stroke, consulted after the
/// model's own. The engine has none and passes `None`. The return value is the
/// new default when one was written, which the web app stores back as its
/// app-wide default; `model.default_stroke` is written here.
///
/// Why field-scoped: this used to rebuild the whole Stroke from panel state on
/// every edit and read `width` from the app / tab DEFAULT stroke. That made
/// the weight input work at the cost of resetting a selected 5pt line to 1pt
/// whenever ANY other control was touched (JYH, 2026-07-24). Gating the width
/// write to the weight edit itself removes the ordering problem entirely:
/// nothing else reads the committed weight, so nothing else can clobber it.
/// Cap / join were the same shape (the panel DISPLAYS them from the element
/// via `dock_panel::build_live_panel_overrides`, so re-imposing panel state on
/// an unrelated edit contradicted what the person saw), and the dash /
/// arrowhead / profile groups were re-stamped from stale panel state on every
/// edit.
pub fn apply_stroke_panel_to_selection(
    model: &mut Model,
    sp: &StrokePanelState,
    edited: &str,
    app_default: Option<Stroke>,
) -> Option<Stroke> {
    let group = StrokeEditGroup::from_field(edited)?;
    let sel_stroke = {
        let doc = model.document();
        doc.selection.first()
            .and_then(|es| doc.get_element(&es.path))
            .and_then(|e| e.stroke().cloned())
    };
    let default_stroke = model.default_stroke.or(app_default);
    // Nothing to build on: no selected stroke and no default.
    let fallback = sel_stroke.or(default_stroke)?;
    // The weight input's committed value, read ONLY for a weight edit. It
    // comes from the PANEL field, not from the default stroke: the default can
    // be absent (the None stroke swatch), which used to drop the commit and
    // make a weight edit a silent no-op.
    let committed_width = sp.weight;
    // Width profiles are re-derived only when the edit can change them: the
    // profile shape / flip, or the weight they scale with.
    let profile_edit = matches!(group, StrokeEditGroup::Width | StrokeEditGroup::Profile);
    if !model.document().selection.is_empty() {
        let profile_width = if group == StrokeEditGroup::Width {
            committed_width
        } else {
            sel_stroke.map(|s| s.width).unwrap_or(committed_width)
        };
        model.with_txn(|m| {
            Controller::map_selection_stroke(m, |el_stroke| {
                let base = el_stroke.unwrap_or(fallback);
                Some(stroke_with_group(base, sp, group, committed_width))
            });
            if profile_edit {
                let width_pts = crate::geometry::element::profile_to_width_points(
                    &sp.profile, profile_width, sp.profile_flipped,
                );
                Controller::set_selection_width_profile(m, width_pts);
            }
        });
    }
    // The new-element default takes the SAME field-scoped edit, built on the
    // default stroke — never on the selected element, whose width / colour
    // must not leak into what the next element gets.
    let new_default = stroke_with_group(
        default_stroke.unwrap_or(fallback), sp, group, committed_width);
    model.default_stroke = Some(new_default);
    Some(new_default)
}
