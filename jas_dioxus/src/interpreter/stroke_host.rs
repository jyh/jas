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
use crate::interpreter::state_store::StateStore;

/// The Stroke panel's id: the store scope its fields live in.
pub const STROKE_PANEL: &str = "stroke_panel_content";

/// The global `state.*` keys whose write reaches the selection (A11): the
/// reference's `STROKE_RENDER_KEYS` (`workspace_interpreter/effects.py`), in
/// its order. Swift keeps the same list. A test reads the reference's literal
/// and requires this one to equal it, so the copy cannot drift.
///
/// The trigger is the GLOBAL write. A stroke behavior writes both
/// `set_panel_state cap` and `set stroke_cap`, the panel's `init:` two-way
/// binds every field to its global, and `set_stroke_cap` says in its own
/// description that the global write "propagates to the selection".
pub const STROKE_RENDER_KEYS: &[&str] = &[
    "stroke_cap", "stroke_join", "stroke_width", "stroke_miter_limit",
    "stroke_dashed", "stroke_dash_1", "stroke_gap_1",
    "stroke_dash_2", "stroke_gap_2", "stroke_dash_3", "stroke_gap_3",
    "stroke_dash_align_anchors",
    "stroke_align", "stroke_start_arrowhead", "stroke_end_arrowhead",
    "stroke_start_arrowhead_scale", "stroke_end_arrowhead_scale",
    "stroke_arrow_align", "stroke_profile", "stroke_profile_flipped",
];

/// True when a write to the global `key` applies to the selection.
pub fn is_render_key(key: &str) -> bool {
    STROKE_RENDER_KEYS.contains(&key)
}

/// Stroke panel state fields that sync with global state and the selection.
#[derive(Debug, Clone, PartialEq)]
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
    /// The panel's fields, as `stroke.yaml` declares them under `state:`. A
    /// test requires this to be the declared list.
    pub const FIELDS: [&'static str; 21] = [
        "weight", "cap", "join", "miter_limit", "align_stroke", "dashed",
        "dash_1", "gap_1", "dash_2", "gap_2", "dash_3", "gap_3",
        "dash_align_anchors", "start_arrowhead", "end_arrowhead",
        "start_arrowhead_scale", "end_arrowhead_scale", "link_arrowhead_scale",
        "arrow_align", "profile", "profile_flipped",
    ];

    /// The panel as the store holds it, in the reference's order
    /// (`effects.py`, `stroke_panel_state`): the panel scope first, because
    /// every in-panel write lands there; then the flat global, for writers
    /// outside the panel; then the declared default. A null is absent at each
    /// step. Two globals are not `stroke_<field>`: weight's is `stroke_width`,
    /// and `align_stroke` reads `stroke_align_stroke` and then `stroke_align`.
    ///
    /// ⚠️ One difference from the reference, stated: its weight has no
    /// default (a missing weight builds on the default stroke's width), and
    /// here it is 1, as in the web app's struct. The engine seeds the panel
    /// scope from its declared state, which holds a weight, so the case does
    /// not arise there.
    pub fn from_store(store: &StateStore) -> Self {
        let mut sp = Self::default();
        for field in Self::FIELDS {
            let globals: &[&str] = match field {
                "weight" => &["stroke_width"],
                "align_stroke" => &["stroke_align_stroke", "stroke_align"],
                _ => &[],
            };
            let flat = format!("stroke_{field}");
            let globals = if globals.is_empty() { vec![flat.as_str()] } else { globals.to_vec() };
            let panel = store.get_panel(STROKE_PANEL, field);
            let value = std::iter::once(panel)
                .chain(globals.into_iter().map(|g| store.get(g)))
                .find(|v| !v.is_null());
            if let Some(v) = value {
                sp.set_field(field, v);
            }
        }
        sp
    }

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
        // Join a transaction the caller already opened (the engine's batch),
        // or bracket this edit as its own undo step. Not `with_txn`: it
        // commits unconditionally, so inside an open transaction it would
        // close the CALLER's, and the rest of the batch would land outside it.
        let opened = !model.in_txn();
        model.begin_txn();
        Controller::map_selection_stroke(model, |el_stroke| {
            let base = el_stroke.unwrap_or(fallback);
            Some(stroke_with_group(base, sp, group, committed_width))
        });
        if profile_edit {
            let width_pts = crate::geometry::element::profile_to_width_points(
                &sp.profile, profile_width, sp.profile_flipped,
            );
            Controller::set_selection_width_profile(model, width_pts);
        }
        if opened {
            model.commit_txn();
        }
    }
    // The new-element default takes the SAME field-scoped edit, built on the
    // default stroke — never on the selected element, whose width / colour
    // must not leak into what the next element gets.
    let new_default = stroke_with_group(
        default_stroke.unwrap_or(fallback), sp, group, committed_width);
    model.default_stroke = Some(new_default);
    Some(new_default)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::interpreter::workspace::Workspace;
    use serde_json::{json, Value};
    use std::collections::HashMap;

    fn root() -> &'static str {
        concat!(env!("CARGO_MANIFEST_DIR"), "/..")
    }

    /// The bracketed list literal that follows `head` in the reference's
    /// `effects.py`, as its quoted strings. Refuses anything that is not a
    /// quoted string, so a reshaped literal reds here instead of reading short.
    fn reference_list(head: &str) -> Vec<String> {
        let src = std::fs::read_to_string(format!("{}/workspace_interpreter/effects.py", root()))
            .expect("effects.py is readable");
        assert_eq!(src.matches(head).count(), 1, "effects.py must define `{head}` once");
        let start = src.find(head).unwrap() + head.len();
        let body = &src[start..start + src[start..].find(']').unwrap()];
        let items: Vec<String> = body
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(|s| {
                assert!(s.len() > 2 && s.starts_with('"') && s.ends_with('"'),
                        "not a quoted string in `{head}`: {s:?}");
                s[1..s.len() - 1].to_string()
            })
            .collect();
        assert!(items.len() > 10, "`{head}` read {} items: {items:?}", items.len());
        items
    }

    /// **A11's key list is the reference's**, element for element and in its
    /// order. It is read here, never re-typed from a port.
    #[test]
    fn the_render_keys_are_the_references() {
        let want = reference_list("STROKE_RENDER_KEYS: list[str] = [");
        let got: Vec<String> = STROKE_RENDER_KEYS.iter().map(|k| k.to_string()).collect();
        assert_eq!(got, want);
        for k in &want {
            assert!(is_render_key(k), "{k} is a render key");
            assert!(StrokeEditGroup::from_field(k).is_some(), "{k} must own a group");
        }
        // The trigger is the GLOBAL write: a panel key, and a UI-only global,
        // are not render keys.
        for k in ["cap", "weight", "stroke_link_arrowhead_scale", "stroke_brush", ""] {
            assert!(!is_render_key(k), "{k:?} is not a render key");
        }
    }

    fn declared() -> HashMap<String, Value> {
        Workspace::load().expect("workspace loads").panel_state_defaults(STROKE_PANEL)
    }

    /// **The field list is the workspace's.** `from_store` reads every field
    /// the panel declares, and nothing else.
    #[test]
    fn the_fields_are_the_declared_panel_state() {
        let mut want: Vec<String> = declared().into_keys().collect();
        want.sort();
        let mut got: Vec<String> = StrokePanelState::FIELDS.iter().map(|k| k.to_string()).collect();
        got.sort();
        assert!(want.len() > 10, "the declared state was read: {want:?}");
        assert_eq!(got, want);
    }

    /// A value of `declared`'s type that differs from it.
    fn probe(declared: &Value) -> Value {
        match declared {
            Value::Bool(b) => json!(!b),
            Value::String(_) => json!("zz_probe"),
            Value::Number(_) | Value::Null => json!(777.0),
            other => panic!("no probe for {other}"),
        }
    }

    /// **The defaults are the declared ones, and every field is writable.**
    /// Writing a field's declared default into the default panel changes
    /// nothing; writing any other value changes it.
    #[test]
    fn the_default_panel_is_the_declared_one_and_set_field_knows_every_field() {
        let base = StrokePanelState::default();
        for (field, value) in declared() {
            let mut sp = base.clone();
            sp.set_field(&field, &value);
            assert_eq!(sp, base, "{field}: the declared default {value} is not the default");
            let mut sp = base.clone();
            sp.set_field(&field, &probe(&value));
            assert_ne!(sp, base, "{field}: set_field does not write it");
        }
    }

    fn store_with_panel(fields: &[(&str, Value)]) -> StateStore {
        let mut store = StateStore::new();
        store.init_panel(STROKE_PANEL,
                         fields.iter().map(|(k, v)| (k.to_string(), v.clone())).collect());
        store
    }

    /// **The reference's order: the panel scope, then the flat global, then
    /// the declared default** (`effects.py`, `stroke_panel_state`). A null
    /// counts as absent at each step.
    #[test]
    fn from_store_reads_the_panel_then_the_global_then_the_default() {
        let empty = StateStore::new();
        assert_eq!(StrokePanelState::from_store(&empty), StrokePanelState::default());

        let mut store = StateStore::new();
        store.set("stroke_cap", json!("round"));
        assert_eq!(StrokePanelState::from_store(&store).cap, "round", "the global is read");
        let mut store = store_with_panel(&[("cap", json!("square"))]);
        store.set("stroke_cap", json!("round"));
        assert_eq!(StrokePanelState::from_store(&store).cap, "square", "the panel wins");
        store.set_panel(STROKE_PANEL, "cap", Value::Null);
        assert_eq!(StrokePanelState::from_store(&store).cap, "round", "a null panel value is absent");

        // The asymmetric spellings: weight's global is `stroke_width`, and
        // `align_stroke` reads `stroke_align_stroke`, then `stroke_align`.
        let mut store = StateStore::new();
        store.set("stroke_width", json!(3.5));
        store.set("stroke_weight", json!(9.0));
        store.set("stroke_align", json!("inside"));
        let sp = StrokePanelState::from_store(&store);
        assert_eq!((sp.weight, sp.align.as_str()), (3.5, "inside"));
        store.set("stroke_align_stroke", json!("outside"));
        assert_eq!(StrokePanelState::from_store(&store).align, "outside");

        // An optional dash pair: a null global leaves it unused, a number sets it.
        let mut store = store_with_panel(&[("dash_2", Value::Null)]);
        store.set("stroke_dash_2", Value::Null);
        assert_eq!(StrokePanelState::from_store(&store).dash_2, None);
        store.set("stroke_dash_2", json!(4.0));
        assert_eq!(StrokePanelState::from_store(&store).dash_2, Some(4.0));
    }
}
