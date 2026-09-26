//! The panel data scope the engine assembles, and the colour tick's write path.
//!
//! Lifted out of `ffi.rs` at S-C.2 so the scope and the write that moves it can
//! be tested without an ABI in the way — and so the ABI file stays a boundary
//! file. Behind `feature = "ffi"` with the rest of the boundary: this is the
//! shell's state slice, not an interpreter concept, and the interpreter is the
//! cross-language-pinned layer that must not grow spike-shaped structures.
//!
//! # BL1 is the reason any of this is here
//!
//! The shell sends **events**, never state. So the engine must own two things
//! the shell would otherwise have to: the SCOPE a panel's bindings resolve
//! against, and the RULE that turns "the H slider now reads 210" into a colour.
//! Both live here. A shell that assembled either would be the third
//! interpreter's state half arriving through a parameter list.
//!
//! # What is NOT here, deliberately
//!
//! ⛔ **The eleven channels are DERIVED, not stored.** `r/g/bl/h/s/b/c/m/y/k/hex`
//! come from [`panel_channels`] at assembly time. Storing them would create a
//! second source of truth for values that already have one, and the copy is the
//! one that drifts — the sequencer ruled this before C1 was measured.

use serde_json::{json, Map, Value};

use crate::document::document::Document;
use crate::document::model::Model;
use crate::interpreter::color_util::{color_from_panel_edit, panel_channels, parse_hex};
use crate::interpreter::state_store::StateStore;

/// The colour panel's id. Its `panel.*` state is [`PanelState`]'s, never the
/// store's.
pub const COLOUR_PANEL: &str = "color_panel_content";

/// The minimum a materialized panel needs. **Deliberately not a general state
/// store**: this is the spike's slice, not an app-state design.
#[derive(Debug, Clone)]
pub struct PanelState {
    /// Float RGB, 0..1. Seeded to a NON-DEGENERATE colour on purpose: at white
    /// every derivation agrees, so a white seed would let a wrong one pass. This
    /// is the corpus's own `panel_exact_eighth_bit_values` vector.
    pub fill: (f64, f64, f64),
    pub stroke: (f64, f64, f64),
    pub fill_on_top: bool,
    pub mode: String,
    pub recent: Vec<String>,
}

impl Default for PanelState {
    fn default() -> Self {
        PanelState {
            fill: (0.4, 0.25, 0.25),
            stroke: (0.0, 0.0, 0.0),
            fill_on_top: true,
            mode: "hsb".to_string(),
            recent: vec![],
        }
    }
}

/// What one edit did, so the caller can tell a refusal from a no-op from a
/// change. **The three are different and a single bool hides the one that
/// matters**: gate ④ is a vacuity guard, and "the write was accepted" must not
/// stand in for "a value moved".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditOutcome {
    /// The target was written and the resulting state differs from before.
    Changed,
    /// The target was written and the state is byte-identical to before — a
    /// drag that landed where it already was.
    Unchanged,
    /// No writable target of that name. **Not an error to swallow**: it means
    /// the shell named a binding this slice does not implement.
    NoSuchTarget,
}

impl PanelState {
    /// The active colour — fill or stroke, per `fill_on_top`. The panel's
    /// channels are always derived from THIS, never from the inactive one.
    fn active(&self) -> (f64, f64, f64) {
        if self.fill_on_top { self.fill } else { self.stroke }
    }

    fn set_active(&mut self, rgb: (f64, f64, f64)) {
        if self.fill_on_top { self.fill = rgb } else { self.stroke = rgb }
    }

    /// The panel channel map, in the shape `color_from_panel_edit` reads.
    fn channel_map(&self) -> Value {
        let (r, g, b) = self.active();
        let ch = panel_channels(r, g, b);
        json!({
            "mode": self.mode,
            "r": ch.r, "g": ch.g, "bl": ch.bl,
            "h": ch.h, "s": ch.s, "b": ch.b,
            "c": ch.c, "m": ch.m, "y": ch.y, "k": ch.k,
            "hex": ch.hex,
        })
    }

    /// Assemble the data scope a panel's bindings resolve against.
    ///
    /// **BL1, and it is why the externs take only a panel id.** Exposing the
    /// pure `bind_values(panel_node, ctx)` would have forced the shell to build
    /// this map, which puts app state in C#.
    ///
    /// Shape follows the cross-language byte-gate's own ctx
    /// (`cross_language_test.rs`): `state.fill_color` carries the `#`,
    /// `panel.hex` does not.
    ///
    /// ⚠️ `active_document` is a **SLICE**, added at S-C.2 and named honestly:
    /// it carries what the data-driven second panel binds and nothing else. A
    /// second panel measured against a scope that could not vary would have
    /// reported "no growth with widget count" with the widget count held
    /// constant — a pass with two arms that were never different.
    /// ⛔ **`panel.*` follows `fill_on_top`; `state.*` carries both.** `color.yaml`'s
    /// own `init` block says so — every channel is
    /// `hsb_h(if state.fill_on_top then state.fill_color else state.stroke_color)`
    /// — and the web port resolves the same way in
    /// `dock_panel::build_live_panel_overrides`. C1's `panel_ctx` derived
    /// `panel.*` from `fill` unconditionally and was never caught, because
    /// `fill_on_top` was true for the whole of C1: with the stroke active, the
    /// sliders would have shown the FILL's channels. Corrected at S-C.2.
    pub fn scope(&self, doc: &Document) -> Value {
        let (ar, ag, ab) = self.active();
        let ch = panel_channels(ar, ag, ab);
        json!({
            "state": self.state_keys(),
            "panel": {
                "mode": self.mode,
                "hex": ch.hex,
                "r": ch.r, "g": ch.g, "bl": ch.bl,
                "h": ch.h, "s": ch.s, "b": ch.b,
                "c": ch.c, "m": ch.m, "y": ch.y, "k": ch.k,
                "recent_colors": self.recent,
                // The artboards panel reads these two; an absent key and a
                // false key are not the same thing to `eval`.
                "renaming_artboard": Value::Null,
                "rearrange_dirty": false,
            },
            "active_document": {
                "artboards": artboards_json(doc),
                "artboards_count": doc.artboards.len(),
                // No panel-selection model in this slice. Stated as an empty
                // list rather than omitted, because `mem(x, null)` and
                // `mem(x, [])` are different questions to the evaluator.
                "artboards_panel_selection_ids": Value::Array(vec![]),
            },
        })
    }

    /// The three `state.*` keys this slice owns, as a scope carries them. The
    /// engine's store holds a copy of exactly these, written from here
    /// (see [`sync_colour_state`]).
    pub fn state_keys(&self) -> Map<String, Value> {
        let st = panel_channels(self.stroke.0, self.stroke.1, self.stroke.2);
        let fl = panel_channels(self.fill.0, self.fill.1, self.fill.2);
        let mut m = Map::new();
        m.insert("fill_color".into(), Value::String(format!("#{}", fl.hex)));
        m.insert("stroke_color".into(), Value::String(format!("#{}", st.hex)));
        m.insert("fill_on_top".into(), Value::Bool(self.fill_on_top));
        m
    }

    /// Carry into the slice any of its three `state.*` keys that a behavior
    /// wrote into the STORE's copy ([`sync_colour_state`] writes that copy;
    /// this is the other direction). A behavior the engine door runs writes
    /// the store (Swatches' `set_active_color`), while every scope reads the
    /// slice, so without this the write is a success that shows nothing.
    ///
    /// A key is adopted only where the store's copy DIFFERS from the slice's
    /// own rendering of it, so an untouched copy adopts nothing. A colour key
    /// that is not a string is NOT adopted: the slice has no "none", and
    /// `parse_hex` would read it as black. Returns whether anything moved.
    pub fn adopt_store_state(&mut self, store: &StateStore) -> bool {
        let mine = self.state_keys();
        let written = |k: &str| Some(store.get(k)).filter(|v| Some(*v) != mine.get(k));
        let rgb = |v: &Value| v.as_str().map(|s| {
            let (r, g, b) = parse_hex(s);
            (r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0)
        });
        let mut moved = false;
        if let Some(c) = written("fill_color").and_then(rgb) {
            self.fill = c;
            moved = true;
        }
        if let Some(c) = written("stroke_color").and_then(rgb) {
            self.stroke = c;
            moved = true;
        }
        if let Some(b) = written("fill_on_top").and_then(Value::as_bool) {
            self.fill_on_top = b;
            moved = true;
        }
        moved
    }

    /// Apply one control's new value, addressed by the BINDING EXPRESSION the
    /// panel spec declares for it (`"panel.h"`, `"panel.hex"`, …).
    ///
    /// The shell never names a channel: it names a WIDGET, the engine reads
    /// that widget's `bind.value` out of the panel spec, and this applies it.
    /// So the shell knows nothing about colour, which is the property that makes
    /// it a materializer rather than an interpreter.
    pub fn apply_edit(&mut self, target: &str, value: &Value) -> EditOutcome {
        let before = self.clone();

        match target {
            // The ten numeric channels all go through the shared write half,
            // which reads the UNEDITED channels from `panel_channels` — the
            // COLORTIERS order, and the reason this is not open-coded here.
            "panel.h" | "panel.s" | "panel.b" | "panel.r" | "panel.g" | "panel.bl"
            | "panel.c" | "panel.m" | "panel.y" | "panel.k" => {
                let Some(n) = as_number(value) else { return EditOutcome::NoSuchTarget };
                let field = &target["panel.".len()..];
                match color_from_panel_edit(field, n, &self.channel_map()) {
                    Some(rgb) => self.set_active(rgb),
                    // An undeclared mode: the write half refuses and so does
                    // this. Silently keeping the old colour would report a
                    // successful tick that moved nothing.
                    None => return EditOutcome::NoSuchTarget,
                }
            }
            "panel.hex" => {
                let Some(s) = value.as_str() else { return EditOutcome::NoSuchTarget };
                // `parse_hex` takes the `#` form or the bare one; the panel's
                // own field is bare (`panel.hex` carries no `#`).
                let (r, g, b) = parse_hex(s);
                self.set_active((r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0));
            }
            "panel.mode" => {
                let Some(s) = value.as_str() else { return EditOutcome::NoSuchTarget };
                self.mode = s.to_string();
            }
            "state.fill_on_top" => {
                let Some(v) = value.as_bool() else { return EditOutcome::NoSuchTarget };
                self.fill_on_top = v;
            }
            _ => return EditOutcome::NoSuchTarget,
        }

        // Compared on the DERIVED channels, not the floats: two float colours a
        // hair apart quantise to the same eight bits and therefore display
        // identically, and a tick that moved nothing a user can see is not a
        // change. `active()` is read after the write, `before` before it.
        if panel_channels(self.active().0, self.active().1, self.active().2)
            == panel_channels(before.active().0, before.active().1, before.active().2)
            && self.mode == before.mode
            && self.fill_on_top == before.fill_on_top
        {
            EditOutcome::Unchanged
        } else {
            EditOutcome::Changed
        }
    }
}

/// A number from either a JSON number or a numeric string. The shell's controls
/// hand back strings (a `NumberBox` reads `Value` as a double, a `TextBox` as
/// text) and refusing one of the two would make the protocol depend on which
/// native control a kind happened to map to.
fn as_number(v: &Value) -> Option<f64> {
    v.as_f64().or_else(|| v.as_str().and_then(|s| s.trim().parse::<f64>().ok()))
}

/// The `active_document.*` facts the ENGINE owns, as a JSON object: the five
/// that `menu_state.rs:19-25` also names, plus `selection_has_compound_shape`
/// (W2b-13b), which the Boolean panel's Expand button binds, and the Brushes
/// panel's two brushed-stroke gates (W2b-18).
///
/// ⛔ THE LIST IS EXHAUSTIVE ON PURPOSE AND IT IS SHORTER THAN THE NAMESPACE.
/// `menu_state.rs:19-25` names six `active_document` fields; the engine can
/// answer five of those. `has_filename` is NOT here because `jas_load_svg` takes BYTES —
/// the engine has never seen a path and inventing `false` for it would be the
/// shell's answer wearing the engine's authority.
///
/// It lives beside the panel scope because two passes read it: the menubar's
/// state and every panel's bindings (Align's `disabled` reads
/// `selection_count`). One definition, so the two cannot disagree.
pub fn document_facts(model: &Model) -> Map<String, Value> {
    let selection_count = model.document().selection.len();
    let mut m = Map::new();
    m.insert("has_selection".into(), (selection_count > 0).into());
    m.insert("selection_count".into(), selection_count.into());
    m.insert("can_undo".into(), model.can_undo().into());
    m.insert("can_redo".into(), model.can_redo().into());
    m.insert("is_modified".into(), model.is_modified().into());
    m.insert("selection_has_compound_shape".into(),
             crate::interpreter::boolean_host::selection_has_compound_shape(model.document()).into());
    let (has_brushed, single_brushed) =
        crate::interpreter::document_views::brushed_stroke_facts(model.document());
    m.insert("selection_has_brushed_stroke".into(), has_brushed.into());
    m.insert("selection_is_single_brushed_stroke".into(), single_brushed.into());
    m
}

/// Write the slice's three `state.*` keys into the store, so an effect that
/// reads `state.fill_color` from the store reads the value the panels show.
/// Called when the engine is made and after every colour edit.
pub fn sync_colour_state(store: &mut StateStore, slice: &PanelState) {
    for (k, v) in slice.state_keys() {
        store.set(&k, v);
    }
}

/// The scope panel `panel_id`'s bindings resolve against, in the engine
/// (FB wave 2, A6). One function, so the plan the shell draws and the
/// behavior the engine runs read the same values.
///
/// * `state` — the store's global state, with the slice's three keys over it.
///   The store holds a copy of those three ([`sync_colour_state`]), so the
///   overlay changes nothing when the copy is current.
/// * `panel` — the slice's, with the panel's own store scope over it. The
///   colour panel never HAS a store scope (the engine never seeds one), so
///   its `panel.*` is the slice's alone. That is one guard, at the seeding,
///   and an arm holds it.
/// * `active_document` — the slice's, plus [`document_facts`].
/// * The Properties panel's eight fields are DERIVED from the selection
///   (`properties_host::live_values`) over its store scope, as the web app
///   derives them. A written field is applied to the document, never shown.
///
/// Keys are inserted in sorted order, so the scope does not depend on a hash
/// map's iteration order.
pub fn engine_scope(slice: &PanelState, store: &StateStore, model: &Model, panel_id: &str) -> Value {
    let mut scope = slice.scope(model.document());
    let mut state: Map<String, Value> = sorted(store.get_all());
    state.extend(slice.state_keys());
    scope["state"] = Value::Object(state);
    if let (Some(own), Some(panel)) = (store.panel_scope(panel_id), scope["panel"].as_object_mut()) {
        panel.extend(sorted(own));
        if panel_id == crate::interpreter::properties_host::PROPERTIES_PANEL {
            panel.extend(crate::interpreter::properties_host::live_values(model.document()));
        }
        // W2b-7. The Paragraph panel's fields describe the SELECTION, so the
        // scope must be derived from the document exactly as Properties' is.
        // A store-backed scope makes a boolean press read a stale sibling and
        // negate the wrong value — `paragraph_host::live_values` says how.
        if panel_id == crate::interpreter::paragraph_host::PARAGRAPH_PANEL {
            panel.extend(crate::interpreter::paragraph_host::live_values(model.document()));
        }
    }
    if let Some(doc) = scope["active_document"].as_object_mut() {
        doc.extend(document_facts(model));
        doc.extend(artboard_facts(store, model.document()));
        // W2b-15: the symbols list and the Concepts panel's PARAMS mode.
        doc.insert("symbols".into(),
                   crate::interpreter::document_views::symbols_view(model.document()));
        doc.insert("selected_concept".into(),
                   crate::interpreter::document_views::selected_concept_view(model.document()));
    }
    // W2b-8: the five selection-level predicates the YAML binds by BARE NAME
    // (`selection_has_mask`, the mask clip/invert/linked triple, and
    // `editing_target_is_mask`). They sit at the scope ROOT because that is
    // where the panel compiler reads them — not under `panel.` or `state.`.
    // ⛔ Two of them are the bound expressions of CHECKBOXES, and a boolean
    // press writes the NEGATION of what it reads, so a scope without them
    // negates a value that is not there (the W2b-7 defect, second panel).
    if let Some(root) = scope.as_object_mut() {
        root.extend(crate::interpreter::mask_facts::selection_predicates(model));
    }
    // W2b-15: the list sources a `foreach source: "data.*"` reads. The store's
    // data (the libraries, seeded by [`seed_library_data`] and written by the
    // library effects) plus the concept registry, which is read-only.
    let mut data = store.data().as_object().cloned().unwrap_or_default();
    data.insert("concepts".into(), crate::interpreter::workspace::concepts_list());
    scope["data"] = Value::Object(data);
    scope
}

/// W2b-15. Seed the store's `data` with the workspace bundle's brush and swatch
/// libraries, the values the web's `AppState` starts from. They live in the
/// STORE, not in a view, because the library effects write them there
/// (`set_data_path`), so an edit and the next plan read the same copy.
pub fn seed_library_data(store: &mut StateStore) {
    let Some(ws) = crate::interpreter::workspace::Workspace::load() else { return };
    let mut data = Map::new();
    for key in ["brush_libraries", "swatch_libraries"] {
        data.insert(key.into(), ws.data().get(key).cloned().unwrap_or_else(|| serde_json::json!({})));
    }
    store.set_data(Value::Object(data));
}

/// W2b-14. The artboard facts the artboards panel and its actions read, from
/// the STORE's `artboards_panel_selection`, as `state_store.py` derives them:
///
/// * `artboards_panel_selection_ids`: the selection's STRING entries, in order;
/// * `current_artboard` / `current_artboard_id`: the first SELECTED artboard in
///   DOCUMENT order, else the first artboard; `{}` and `null` when there is none,
///   so `current_artboard.width` does not null-deref;
/// * `next_artboard_name`: the smallest unused "Artboard N".
///
/// Before it the scope stated the selection as a hard-coded `[]` and carried no
/// `current_artboard`, so `ap_new` created a default-sized artboard where the
/// action says "the current artboard's size".
fn artboard_facts(store: &StateStore, doc: &Document) -> Map<String, Value> {
    let selected: Vec<String> = store
        .panel_scope("artboards")
        .and_then(|p| p.get("artboards_panel_selection"))
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_default();
    let current = doc
        .artboards
        .iter()
        .find(|a| selected.contains(&a.id))
        .or_else(|| doc.artboards.first());
    let mut m = Map::new();
    m.insert("artboards_panel_selection_ids".into(), json!(selected));
    m.insert("current_artboard_id".into(), current.map_or(Value::Null, |a| json!(a.id)));
    m.insert(
        "current_artboard".into(),
        // The artboard's fields under the canonical form's names
        // (`test_json::artboard_json`), as the reference's raw dict carries them.
        current.map_or_else(|| json!({}), |a| json!({
            "id": a.id, "name": a.name, "x": a.x, "y": a.y,
            "width": a.width, "height": a.height, "fill": a.fill.as_canonical(),
            "show_center_mark": a.show_center_mark,
            "show_cross_hairs": a.show_cross_hairs,
            "show_video_safe_areas": a.show_video_safe_areas,
            "video_ruler_pixel_aspect_ratio": a.video_ruler_pixel_aspect_ratio,
        })),
    );
    m.insert(
        "next_artboard_name".into(),
        json!(crate::document::artboard::next_artboard_name(&doc.artboards)),
    );
    m
}

fn sorted(m: &std::collections::HashMap<String, Value>) -> Map<String, Value> {
    let mut keys: Vec<&String> = m.keys().collect();
    keys.sort();
    keys.into_iter().map(|k| (k.clone(), m[k].clone())).collect()
}

/// The BINDING EXPRESSION a widget declares for one of its keys — the engine's
/// half of "the shell names a control, not a channel".
///
/// `key` is a `bind_values` row key: `"bind.value"`, `"bind.color"`, `"visible"`,
/// `"content"`, `"label"`. Returns the expression string, which is what
/// [`PanelState::apply_edit`] takes as its target.
///
/// ⚠️ **The FIRST node with that id wins, and ids are not unique in a compiled
/// panel.** The colour panel carries `cp_h` (the slider) and `cp_h_val` (the
/// number box) as distinct ids, but `cp_r` appears once for RGB and again as
/// `cp_r_ws` for web-safe — different ids. Where a template really does repeat
/// an id, the two nodes bind the same expression by construction (they are the
/// same template expansion), so first-wins is not a coin flip. Stated because a
/// reader should not have to discover the ambiguity from a wrong value.
pub fn binding_of(panel_node: &Value, widget_id: &str, key: &str) -> Option<String> {
    if widget_id.is_empty() {
        return None;
    }
    let root = panel_node.get("content")?;
    let mut found: Option<String> = None;
    find_binding(root, widget_id, key, &mut found);
    found
}

fn find_binding(node: &Value, widget_id: &str, key: &str, out: &mut Option<String>) {
    if out.is_some() {
        return;
    }
    if node.get("id").and_then(|v| v.as_str()) == Some(widget_id) {
        let expr = match key.strip_prefix("bind.") {
            Some(name) => node.get("bind").and_then(|b| b.get(name)),
            // `visible` / `content` / `label` sit on the node itself.
            None => node.get(key),
        };
        if let Some(s) = expr.and_then(|v| v.as_str()) {
            *out = Some(s.to_string());
            return;
        }
        // The id matched and the key did not. Keep walking rather than stopping:
        // a later node may carry it, and returning None here would report "no
        // such widget" for a widget that exists.
    }
    for k in ["children", "do"] {
        match node.get(k) {
            Some(Value::Array(a)) => {
                for c in a {
                    find_binding(c, widget_id, key, out);
                }
            }
            Some(v @ Value::Object(_)) => find_binding(v, widget_id, key, out),
            _ => {}
        }
    }
}

/// The artboard rows the panel binds. `number` is 1-based LIST POSITION and is
/// derived here rather than stored — `artboard.rs` says so, and a stored copy
/// would be the one that drifts on reorder.
fn artboards_json(doc: &Document) -> Value {
    Value::Array(
        doc.artboards
            .iter()
            .enumerate()
            .map(|(i, a)| json!({ "id": a.id, "name": a.name, "number": i + 1 }))
            .collect(),
    )
}

// ---------------------------------------------------------------------------
// The sync protocol: what the shell is told after a tick
// ---------------------------------------------------------------------------

/// Every panel the shell has materialized, and the rows it was last served.
///
/// # Why the engine holds it rather than the shell
///
/// The delta is computed where the values are. The alternative — the shell
/// sends what it holds and asks what changed — puts the panel's whole value map
/// back across the boundary on every tick, which is the O(n)-in-bytes design the
/// gate exists to notice.
#[derive(Debug, Default)]
pub struct PanelRegistry {
    /// `(panel_id, last_served_rows)`. A Vec, not a map: the shell has a
    /// handful of panels open, insertion order is the order they were opened,
    /// and a deterministic order makes the delta's row order reproducible.
    served: Vec<(String, Value)>,
}

impl PanelRegistry {
    /// Record what a panel was just served, so the next tick can diff against
    /// it. Called by `jas_bind_values`, so opening a panel enrolls it.
    pub fn record(&mut self, panel_id: &str, rows: &Value) {
        match self.served.iter_mut().find(|(id, _)| id == panel_id) {
            Some(slot) => slot.1 = rows.clone(),
            None => self.served.push((panel_id.to_string(), rows.clone())),
        }
    }

    pub fn open_panels(&self) -> Vec<String> {
        self.served.iter().map(|(id, _)| id.clone()).collect()
    }

    /// Re-resolve **every open panel** against the new scope and return only the
    /// rows whose value changed, tagged with the panel they belong to.
    ///
    /// ⭐ **Every open panel, not just the edited one, and that is the design
    /// decision the gate is pointed at.** Refreshing only the edited panel is
    /// cheaper and is WRONG in the general case — a colour change with a
    /// selection moves what other panels display. Refreshing all of them is
    /// correct, stays flat in crossings and in bytes (an unchanged panel
    /// contributes no rows), and moves the cost that does grow to the ENGINE,
    /// where the gate cannot see it. Hence [`Sync::rows_evaluated`], which is
    /// reported beside the crossings under gate ⑤.
    ///
    /// `scope_of` gives each panel its own scope: panels hold their own
    /// `panel.*` state, so one shared scope would resolve every panel against
    /// one panel's values.
    pub fn sync(
        &mut self,
        ws: &crate::interpreter::workspace::Workspace,
        scope_of: &dyn Fn(&str) -> Value,
    ) -> Sync {
        let mut changed: Vec<Value> = vec![];
        let mut evaluated = 0usize;

        for (panel_id, last) in self.served.iter_mut() {
            let Some(spec) = ws.panel(panel_id) else { continue };
            let now = crate::interpreter::bind_values::bind_values(spec, &scope_of(panel_id));
            let now_rows = now.as_array().cloned().unwrap_or_default();
            let last_rows = last.as_array().cloned().unwrap_or_default();
            evaluated += now_rows.len();

            for (i, row) in now_rows.iter().enumerate() {
                // Positional: `bind_values` walks a panel spec whose SHAPE is
                // fixed by the scope's foreach sources. A row count that moved
                // means the structure changed, and a positional diff would be
                // comparing different widgets — so that case sends the panel
                // whole rather than guessing an alignment.
                let same = last_rows.len() == now_rows.len() && last_rows.get(i) == Some(row);
                if !same {
                    let mut tagged = row.clone();
                    if let Some(o) = tagged.as_object_mut() {
                        o.insert("panel".to_string(), Value::String(panel_id.clone()));
                    }
                    changed.push(tagged);
                }
            }
            *last = now;
        }

        Sync { changed: Value::Array(changed), rows_evaluated: evaluated, panels_evaluated: self.served.len() }
    }
}

/// One tick's reply, plus the engine-side cost the boundary cannot see.
pub struct Sync {
    pub changed: Value,
    /// Bind rows RE-EVALUATED this tick across all open panels — the number
    /// that grows with the document while the crossing count does not.
    pub rows_evaluated: usize,
    pub panels_evaluated: usize,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::artboard::Artboard;

    fn doc_with(n: usize) -> Document {
        let mut d = Document::default();
        d.artboards = (0..n)
            .map(|i| {
                let mut a = Artboard::default_with_id(format!("ab{i:04}"));
                a.name = format!("Artboard {}", i + 1);
                a
            })
            .collect();
        d
    }

    /// W2b-15. The Concepts panel's `foreach source: "data.concepts"` reads the
    /// workspace's concept registry, as the web's `data` does. Before it the
    /// engine's scope carried no `data`, so the plan drew 0 rows where the
    /// web draws 4.
    #[test]
    fn the_engine_scope_carries_the_concept_registry_as_data() {
        let m = crate::document::test_fixture::model_with(vec![], &[]);
        let s = engine_scope(&PanelState::default(), &StateStore::new(), &m, "concepts_panel_content");
        let ids: Vec<&str> = s["data"]["concepts"].as_array().expect("data.concepts is a list")
            .iter().filter_map(|c| c["id"].as_str()).collect();
        assert_eq!(ids, vec!["gear", "regular_polygon", "spiral", "star"]);
    }

    /// W2b-15. The Symbols panel lists `active_document.symbols`, one row per
    /// master, and the Concepts panel switches to PARAMS mode on
    /// `active_document.selected_concept`. Both come from the ONE web-free
    /// builder the web view also calls. Before it the engine's scope had
    /// neither, so the symbols list drew 0 rows and PARAMS mode never opened.
    #[test]
    fn the_engine_scope_carries_the_symbols_and_the_selected_concept() {
        use crate::document::test_fixture::{model_with, rect};
        use crate::geometry::element::{CommonProps, Element};
        use crate::geometry::live::{GeneratedElem, LiveVariant};
        let read = |m: &Model| {
            engine_scope(&PanelState::default(), &StateStore::new(), m, "symbols_panel_content")
                ["active_document"].clone()
        };
        let mut m = model_with(vec![rect(0.0, 0.0, 1.0, 1.0)], &[0]);
        let mut doc = m.document().clone();
        doc.symbols = vec![rect(0.0, 0.0, 5.0, 5.0)];
        m.set_document_for_test(doc);
        let ad = read(&m);
        assert_eq!(ad["symbols"].as_array().map(|a| a.len()), Some(1), "{ad}");
        assert_eq!(ad["symbols"][0]["name"], "Symbol 1", "the positional fallback");
        assert_eq!(ad["selected_concept"], Value::Null, "a rect is not a concept instance");

        let gear = Element::Live(LiveVariant::Generated(
            GeneratedElem::new("gear".into(), serde_json::json!({}), CommonProps::default())));
        let g = model_with(vec![gear], &[0]);
        let sc = read(&g)["selected_concept"].clone();
        let ws = crate::interpreter::workspace::Workspace::load().unwrap();
        assert_eq!(sc["concept_id"], "gear", "{sc}");
        assert_eq!(sc["name"], ws.concept("gear").unwrap()["name"], "{sc}");
    }

    /// W2b-13b, fork F-I. The engine's scope answers Expand's predicate, from
    /// the ONE definition the web view also calls. Before it the engine
    /// supplied no predicate, so `not active_document.selection_has_compound_shape`
    /// resolved against a missing key and Expand was disabled on the engine path.
    #[test]
    fn the_engine_scope_answers_the_compound_shape_predicate() {
        use crate::document::controller::BooleanOptions;
        use crate::document::test_fixture::{model_with, rect};
        let read = |m: &Model| {
            engine_scope(&PanelState::default(), &StateStore::new(), m, "boolean_panel_content")
                ["active_document"]["selection_has_compound_shape"].clone()
        };
        let mut m = model_with(vec![rect(0.0, 0.0, 10.0, 10.0), rect(5.0, 5.0, 10.0, 10.0)], &[0, 1]);
        assert_eq!(read(&m), Value::Bool(false), "two plain rects");
        assert!(crate::interpreter::boolean_host::run(
            &mut m, "boolean_union_compound", &BooleanOptions::default()));
        assert_eq!(read(&m), Value::Bool(true), "a compound shape is selected");
    }

    /// W2b-18. The engine's scope answers the Brushes panel's two gates from
    /// the ONE definition the web view also calls (`document_views`).
    #[test]
    fn the_engine_scope_answers_the_brushed_stroke_predicates() {
        use crate::document::test_fixture::{brushed_path, model_with};
        let read = |m: &Model| {
            let s = engine_scope(&PanelState::default(), &StateStore::new(), m, "brushes_panel_content");
            (s["active_document"]["selection_has_brushed_stroke"].clone(),
             s["active_document"]["selection_is_single_brushed_stroke"].clone())
        };
        let b = Some("default_brushes/flat_10");
        assert_eq!(read(&model_with(vec![brushed_path(0.0, b)], &[0])),
                   (Value::Bool(true), Value::Bool(true)));
        assert_eq!(read(&model_with(vec![brushed_path(0.0, b), brushed_path(60.0, None)], &[0, 1])),
                   (Value::Bool(true), Value::Bool(false)));
        assert_eq!(read(&model_with(vec![brushed_path(0.0, None)], &[0])),
                   (Value::Bool(false), Value::Bool(false)));
    }

    // -- the scope --------------------------------------------------------

    #[test]
    fn the_scope_carries_the_derived_channels_not_stored_ones() {
        let st = PanelState::default();
        let s = st.scope(&doc_with(0));
        assert_eq!(s["panel"]["hex"], "664040", "the C1 seed, derived");
        assert_eq!(s["state"]["fill_color"], "#664040", "state carries the #");
        assert_eq!(s["panel"]["r"], 102);
    }

    /// The half the S-C.2 flag turned on: the scope must VARY with the
    /// document, or a second panel measured against it cannot grow.
    #[test]
    fn the_scope_varies_with_the_document() {
        let st = PanelState::default();
        let small = st.scope(&doc_with(8));
        let large = st.scope(&doc_with(200));
        assert_eq!(small["active_document"]["artboards_count"], 8);
        assert_eq!(large["active_document"]["artboards_count"], 200);
        assert_eq!(large["active_document"]["artboards"][199]["number"], 200);
        assert_ne!(
            small["active_document"], large["active_document"],
            "if these are ever equal the second panel cannot be measured"
        );
    }

    // -- the write --------------------------------------------------------

    /// A panel in RGB mode: the mode whose sliders the tests below drag.
    fn rgb_mode() -> PanelState {
        PanelState { mode: "rgb".to_string(), ..PanelState::default() }
    }

    #[test]
    fn a_channel_edit_moves_the_colour_and_says_so() {
        let mut st = rgb_mode();
        assert_eq!(st.apply_edit("panel.r", &json!(200)), EditOutcome::Changed);
        assert_eq!(st.scope(&doc_with(0))["panel"]["hex"], "c84040");
    }

    /// ⚠️ **A channel the CURRENT MODE does not show is a no-op, not a write** —
    /// and this is a property of the shared write half, not of this file: in HSB
    /// the colour comes from h/s/b, so an `r` that arrived anyway changes
    /// nothing. The panel never sends it (the RGB sliders are
    /// `visible: panel.mode == "rgb"`), and the engine does not have to trust
    /// that. Pinned because a reader who sees `panel.r` in the target list will
    /// otherwise assume it always writes.
    #[test]
    fn a_channel_outside_the_current_mode_moves_nothing() {
        let mut st = PanelState::default(); // hsb
        assert_eq!(st.apply_edit("panel.r", &json!(200)), EditOutcome::Unchanged);
        assert_eq!(st.scope(&doc_with(0))["panel"]["hex"], "664040");
        // The control: in RGB mode the same edit lands. Without it, "no-op" and
        // "this target never writes" are the same output.
        let mut rgb = rgb_mode();
        assert_eq!(rgb.apply_edit("panel.r", &json!(200)), EditOutcome::Changed);
    }

    /// The `panel.*` channels follow `fill_on_top`, per `color.yaml`'s `init`.
    /// C1's scope derived them from the fill unconditionally.
    #[test]
    fn the_channels_follow_the_active_attribute() {
        let mut st = PanelState::default();
        assert_eq!(st.scope(&doc_with(0))["panel"]["hex"], "664040", "fill active");
        assert_eq!(st.apply_edit("state.fill_on_top", &json!(false)), EditOutcome::Changed);
        assert_eq!(st.scope(&doc_with(0))["panel"]["hex"], "000000", "stroke active");
        // `state.*` still carries BOTH, unchanged by the flag.
        let s = st.scope(&doc_with(0));
        assert_eq!(s["state"]["fill_color"], "#664040");
        assert_eq!(s["state"]["stroke_color"], "#000000");
    }

    /// Gate ④ in miniature: the outcome must distinguish a tick that moved a
    /// value from one that did not. A single "accepted" bool would report the
    /// no-op drag as a successful tick.
    #[test]
    fn a_drag_that_lands_where_it_already_was_reports_unchanged() {
        let mut st = PanelState::default();
        let current = st.channel_map()["h"].as_f64().unwrap();
        assert_eq!(st.apply_edit("panel.h", &json!(current)), EditOutcome::Unchanged);
    }

    #[test]
    fn a_string_value_is_accepted_because_native_controls_hand_back_strings() {
        let mut st = rgb_mode();
        assert_eq!(st.apply_edit("panel.r", &json!("200")), EditOutcome::Changed);
        assert_eq!(st.scope(&doc_with(0))["panel"]["r"], 200);
    }

    #[test]
    fn hex_mode_and_fill_on_top_are_writable_targets() {
        let mut st = PanelState::default();
        assert_eq!(st.apply_edit("panel.hex", &json!("00ff80")), EditOutcome::Changed);
        assert_eq!(st.scope(&doc_with(0))["panel"]["hex"], "00ff80");
        assert_eq!(st.apply_edit("panel.mode", &json!("rgb")), EditOutcome::Changed);
        assert_eq!(st.apply_edit("state.fill_on_top", &json!(false)), EditOutcome::Changed);
        // Stroke is black, so the active colour follows the flag, not the fill.
        assert_eq!(st.scope(&doc_with(0))["panel"]["hex"], "000000");
    }

    /// A behavior run by the engine door writes `state.fill_color` (Swatches'
    /// `set_active_color`) into the STORE's copy, while every scope reads the
    /// SLICE. `adopt_store_state` carries such a write into the slice, so the
    /// tap is not a success that shows nothing. Each key is adopted only when
    /// the store's copy DIFFERS from the slice's own rendering of it.
    #[test]
    fn the_slice_adopts_a_colour_the_store_copy_was_given() {
        let slice = PanelState::default();
        let mut store = StateStore::new();
        sync_colour_state(&mut store, &slice);

        // The control: an untouched copy adopts nothing.
        let mut st = slice.clone();
        assert!(!st.adopt_store_state(&store));
        assert_eq!(st.state_keys(), slice.state_keys());

        // fill_color written: the fill moves, the stroke and the flag do not.
        let mut s = store.clone();
        s.set("fill_color", json!("#000099"));
        let mut st = slice.clone();
        assert!(st.adopt_store_state(&s));
        assert_eq!(st.state_keys()["fill_color"], "#000099");
        assert_eq!(st.state_keys()["stroke_color"], slice.state_keys()["stroke_color"]);
        assert_eq!(st.fill_on_top, slice.fill_on_top);

        // stroke_color and the flag, together.
        let mut s = store.clone();
        s.set("stroke_color", json!("#12ab34"));
        s.set("fill_on_top", json!(false));
        let mut st = slice.clone();
        assert!(st.adopt_store_state(&s));
        assert_eq!(st.state_keys()["stroke_color"], "#12ab34");
        assert_eq!(st.state_keys()["fill_color"], slice.state_keys()["fill_color"]);
        assert!(!st.fill_on_top);

        // A value the slice cannot hold (no colour) is NOT adopted: the slice
        // has no "none", and a parse of null is black, which would be a wrong
        // colour shown as a success. Only `color.yaml` writes one, and the
        // door does not host that panel.
        let mut s = store.clone();
        s.set("fill_color", serde_json::Value::Null);
        let mut st = slice.clone();
        assert!(!st.adopt_store_state(&s));
        assert_eq!(st.state_keys(), slice.state_keys());
    }

    /// ⛔ THE NEGATIVE CONTROL. Without an arm that MUST refuse, "every edit is
    /// accepted" and "this function cannot refuse" are the same output.
    #[test]
    fn an_unwritable_target_is_refused_rather_than_ignored() {
        let mut st = PanelState::default();
        assert_eq!(st.apply_edit("panel.no_such_field", &json!(1)), EditOutcome::NoSuchTarget);
        assert_eq!(st.apply_edit("active_document.artboards", &json!([])), EditOutcome::NoSuchTarget);
        // Right target, wrong type.
        assert_eq!(st.apply_edit("panel.mode", &json!(7)), EditOutcome::NoSuchTarget);
        assert_eq!(st.apply_edit("panel.r", &json!("not a number")), EditOutcome::NoSuchTarget);
    }

    /// ⚖️ **The sequencer's C3 watch, answered by measurement.**
    ///
    /// A commit PUSHES to `recent_colors`, and a commit that mutated a list the
    /// panel binds to could move the panel's RECORD COUNT — in which case C3's
    /// denominator would differ from C2's and the two figures could not sit
    /// adjacent.
    ///
    /// **It does not.** The colour panel declares TEN fixed swatch nodes
    /// (`cp_recent_0` … `cp_recent_9`), each binding `panel.recent_colors.<n>`;
    /// an empty slot renders as a hollow square rather than not rendering. So
    /// the count is **constant at every list length** and only the VALUES move.
    /// C2 and C3 share a denominator.
    #[test]
    fn a_recent_colours_push_moves_values_and_not_the_record_count() {
        let w = ws();
        let spec = w.panel("color_panel_content").unwrap();
        let doc = doc_with(0);

        let rows = |recent: Vec<String>| -> (usize, usize) {
            let st = PanelState { recent, ..PanelState::default() };
            let v = crate::interpreter::bind_values::bind_values(spec, &st.scope(&doc));
            let arr = v.as_array().unwrap().clone();
            let slots = arr.iter().filter(|r| {
                r["id"].as_str().is_some_and(|s| s.starts_with("cp_recent_"))
            }).count();
            (arr.len(), slots)
        };

        let (empty_rows, empty_slots) = rows(vec![]);
        let (one_rows, _) = rows(vec!["#ff0000".into()]);
        let (full_rows, full_slots) = rows(
            (0..10).map(|i| format!("#ff00{i:02}")).collect(),
        );

        assert!(empty_rows > 0 && empty_slots > 0, "nothing was examined");
        assert_eq!(empty_slots, 10, "ten declared recent slots");
        assert_eq!(full_slots, 10, "and still ten when the list is full");
        assert_eq!(empty_rows, one_rows, "one push does not move the count");
        assert_eq!(empty_rows, full_rows, "ten pushes do not move the count");

        // The CONTROL: the values DO move, or this test would pass on a scope
        // that ignored `recent` entirely and prove nothing about pushes.
        let value_of = |recent: Vec<String>| -> String {
            let st = PanelState { recent, ..PanelState::default() };
            let v = crate::interpreter::bind_values::bind_values(spec, &st.scope(&doc));
            v.as_array().unwrap().iter()
                .find(|r| r["id"] == "cp_recent_0")
                .expect("the first recent slot")["value"].as_str().unwrap().to_string()
        };
        assert_ne!(
            value_of(vec![]), value_of(vec!["#ff0000".into()]),
            "the first slot must change when a colour is pushed"
        );
    }

    // -- widget -> binding ------------------------------------------------

    fn ws() -> crate::interpreter::workspace::Workspace {
        crate::interpreter::workspace::Workspace::load().expect("workspace")
    }

    /// The shell names a CONTROL; this is the lookup that keeps it from having
    /// to name a channel.
    #[test]
    fn a_widget_id_resolves_to_the_expression_it_binds() {
        let w = ws();
        let colour = w.panel("color_panel_content").unwrap();
        assert_eq!(binding_of(colour, "cp_h", "bind.value").as_deref(), Some("panel.h"));
        assert_eq!(binding_of(colour, "cp_hex", "bind.value").as_deref(), Some("panel.hex"));
        // The number box beside the H slider binds the SAME expression, which is
        // what makes "drag the slider" and "type in the box" one tick shape.
        assert_eq!(binding_of(colour, "cp_h_val", "bind.value").as_deref(), Some("panel.h"));
        // A non-`bind.` key reads off the node itself.
        assert_eq!(
            binding_of(colour, "cp_h", "bind.disabled").as_deref(),
            Some("if state.fill_on_top then state.fill_color == null else state.stroke_color == null")
        );
    }

    /// ⛔ THE NEGATIVE CONTROL. A lookup that cannot miss would resolve a
    /// misspelling to something plausible, and the tick would move the wrong
    /// control's value with no error anywhere.
    #[test]
    fn an_unknown_widget_or_key_resolves_to_nothing() {
        let w = ws();
        let colour = w.panel("color_panel_content").unwrap();
        assert_eq!(binding_of(colour, "cp_no_such_widget", "bind.value"), None);
        assert_eq!(binding_of(colour, "cp_h", "bind.no_such_key"), None);
        assert_eq!(binding_of(colour, "", "bind.value"), None);
        // A container with no `bind` at all.
        assert_eq!(binding_of(colour, "cp_hex_row", "bind.value"), None);
    }

    /// The lookup reaches inside a `foreach`'s `do` template, not only
    /// `children` — the artboards panel's rows live there, and a walker that
    /// missed them would make every data-driven panel unwritable.
    #[test]
    fn the_lookup_descends_into_a_foreach_template() {
        let w = ws();
        let artboards = w.panel("artboards_panel_content").unwrap();
        assert_eq!(
            binding_of(artboards, "ap_name", "content").as_deref(),
            Some("{{ab.name}}"),
            "the row template's name node is reachable"
        );
    }

    // -- the sync protocol ------------------------------------------------

    #[test]
    fn the_delta_carries_only_what_moved() {
        let mut st = rgb_mode();
        let doc = doc_with(8);
        let w = ws();

        let mut reg = PanelRegistry::default();
        let rows = crate::interpreter::bind_values::bind_values(
            w.panel("color_panel_content").unwrap(), &st.scope(&doc));
        let total = rows.as_array().unwrap().len();
        reg.record("color_panel_content", &rows);

        // A tick that changes nothing produces an EMPTY delta. This arm is what
        // makes the next one readable: without it, "the delta is small" and
        // "the diff never fires" are indistinguishable.
        let quiet = reg.sync(&w, &|_| st.scope(&doc));
        assert_eq!(quiet.changed.as_array().unwrap().len(), 0, "no edit, no rows");
        assert_eq!(quiet.rows_evaluated, total, "and it still evaluated everything");

        assert_eq!(st.apply_edit("panel.r", &json!(200)), EditOutcome::Changed);
        let moved = reg.sync(&w, &|_| st.scope(&doc));
        let n = moved.changed.as_array().unwrap().len();
        assert!(n > 0, "a real edit must produce rows");
        assert!(n < total, "and fewer than all {total} of them");
        for row in moved.changed.as_array().unwrap() {
            assert_eq!(row["panel"], "color_panel_content", "rows are panel-tagged");
        }
    }

    /// ⭐ **COMPLETENESS, which a crossing count can never see.** A delta that
    /// misses a row leaves a control showing a stale value — a real bug that
    /// looks like a cheap tick. So: apply the delta to the shell's map and
    /// require the result to equal a full re-read.
    #[test]
    fn applying_the_delta_reproduces_a_full_re_read() {
        let mut st = rgb_mode();
        let doc = doc_with(8);
        let w = ws();
        let spec = w.panel("color_panel_content").unwrap();

        let mut reg = PanelRegistry::default();
        let first = crate::interpreter::bind_values::bind_values(spec, &st.scope(&doc));
        reg.record("color_panel_content", &first);
        // The shell's map: row index -> value, exactly what a materializer holds.
        let mut shell: Vec<Value> = first.as_array().unwrap().clone();

        let mut ticks = 0;
        for v in [200, 12, 255, 7] {
            assert_eq!(st.apply_edit("panel.r", &json!(v)), EditOutcome::Changed);
            let sync = reg.sync(&w, &|_| st.scope(&doc));
            for row in sync.changed.as_array().unwrap() {
                let path = &row["path"];
                let key = &row["key"];
                let slot = shell
                    .iter_mut()
                    .find(|r| r["path"] == *path && r["key"] == *key)
                    .expect("a delta row the shell has no slot for");
                *slot = {
                    let mut r = row.clone();
                    r.as_object_mut().unwrap().remove("panel");
                    r
                };
            }
            ticks += 1;

            let truth = crate::interpreter::bind_values::bind_values(spec, &st.scope(&doc));
            assert_eq!(
                Value::Array(shell.clone()), truth,
                "the shell's map diverged from a full re-read after tick {ticks}"
            );
        }
        assert_eq!(ticks, 4, "four ticks, each verified");
    }

    /// Gate ② and ⑤ together: the delta's SIZE does not grow with the document,
    /// but the engine's evaluation does — which is the finding the gate is blind
    /// to unless it is reported.
    #[test]
    fn the_delta_is_flat_in_the_document_and_the_engine_work_is_not() {
        let w = ws();
        let measure = |n: usize| -> (usize, usize) {
            let mut st = rgb_mode();
            let doc = doc_with(n);
            let mut reg = PanelRegistry::default();
            for p in ["color_panel_content", "artboards_panel_content"] {
                let rows = crate::interpreter::bind_values::bind_values(
                    w.panel(p).unwrap(), &st.scope(&doc));
                reg.record(p, &rows);
            }
            assert_eq!(st.apply_edit("panel.r", &json!(200)), EditOutcome::Changed);
            let s = reg.sync(&w, &|_| st.scope(&doc));
            (s.changed.as_array().unwrap().len(), s.rows_evaluated)
        };

        let (d_small, e_small) = measure(8);
        let (d_large, e_large) = measure(200);
        assert!(d_small > 0 && d_large > 0, "both arms must have measured a tick");
        assert_eq!(d_small, d_large, "the delta must not grow with the document");
        assert!(
            e_large > e_small,
            "the engine's work MUST grow, or the two arms were never different: \
             {e_small} vs {e_large}"
        );
    }

    /// W2b-14. The four artboard facts come from the STORE's
    /// `artboards_panel_selection`, as `state_store.py` derives them, and not
    /// from a hard-coded `[]`. `current_artboard` is the first SELECTED
    /// artboard in DOCUMENT order (not selection order), else the first one.
    #[test]
    fn the_engine_scope_derives_the_artboard_facts_from_the_store() {
        use crate::document::artboard::{next_artboard_name, Artboard};
        use crate::interpreter::state_store::StateStore;
        let mut doc = Document::default();
        doc.artboards = ["a", "b", "c"]
            .iter()
            .enumerate()
            .map(|(i, id)| {
                let mut ab = Artboard::default_with_id(id.to_string());
                ab.name = format!("Artboard {}", i + 1);
                ab.width = 100.0 * (i + 1) as f64;
                ab
            })
            .collect();
        let model = Model::new(doc, None);
        let slice = PanelState::default();
        let panel = "artboards_panel_content";

        let mut store = StateStore::new();
        store.init_panel("artboards", std::collections::HashMap::from([(
            "artboards_panel_selection".to_string(),
            json!(["c", 7, "b"]),
        )]));
        let ad = engine_scope(&slice, &store, &model, panel)["active_document"].clone();
        // Only strings are ids (the reference filters the same way).
        assert_eq!(ad["artboards_panel_selection_ids"], json!(["c", "b"]), "{ad}");
        // DOCUMENT order: "b" precedes "c" in the list, though "c" was selected first.
        assert_eq!(ad["current_artboard_id"], json!("b"), "{ad}");
        assert_eq!(ad["current_artboard"]["width"], json!(200.0), "{ad}");
        assert_eq!(
            ad["next_artboard_name"],
            json!(next_artboard_name(&model.document().artboards)),
            "{ad}"
        );
        assert_ne!(ad["next_artboard_name"], json!(""), "a derived name, not an empty one");

        // No selection: the FIRST artboard is current.
        let empty = engine_scope(&slice, &StateStore::new(), &model, panel)["active_document"].clone();
        assert_eq!(empty["artboards_panel_selection_ids"], json!([]), "{empty}");
        assert_eq!(empty["current_artboard_id"], json!("a"), "{empty}");
        assert_eq!(empty["current_artboard"]["width"], json!(100.0), "{empty}");
    }
}
