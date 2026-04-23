//! YAML-driven canvas tool.
//!
//! Parses a tool spec from `workspace/tools/*.yaml` (via the compiled
//! `workspace.json`) into a [`ToolSpec`], then implements the
//! [`CanvasTool`] trait by routing native events through the YAML
//! handlers declared in the spec. Mirrors the tool dispatcher in
//! `jas_flask/static/js/engine/tools.mjs`.
//!
//! Phase 3c of the Rust YAML tool runtime (see RUST_TOOL_RUNTIME.md):
//! event dispatch through [`CanvasTool`] is wired; overlay rendering
//! remains a Phase 3d stub.

use std::collections::HashMap;

use web_sys::CanvasRenderingContext2d;

use crate::document::model::Model;
use crate::interpreter::doc_primitives;
use crate::interpreter::effects::run_effects;
use crate::interpreter::state_store::StateStore;
use crate::tools::tool::CanvasTool;

/// Parsed shape of a tool YAML spec.
///
/// Holds enough to drive event dispatch and overlay rendering: the
/// tool id, the per-tool state defaults, the handler dispatch table
/// (keyed by `on_<event>` name), and an optional overlay spec. Pure
/// data — no evaluator or model references.
#[derive(Debug, Clone)]
pub struct ToolSpec {
    pub id: String,
    pub cursor: Option<String>,
    pub menu_label: Option<String>,
    pub shortcut: Option<String>,
    /// Initial values for `$tool.<id>.<var>` state, keyed by variable
    /// name. Applied via [`StateStore::init_tool`] when a YamlTool is
    /// registered; handlers read and write them via scope-routed `set:`
    /// effects (see `interpreter::effects`).
    pub state_defaults: HashMap<String, serde_json::Value>,
    /// Event handlers keyed by event name (`on_enter`, `on_leave`,
    /// `on_mousedown`, `on_mousemove`, `on_mouseup`, `on_keydown`, …).
    /// Each value is the raw effect list — dispatched through
    /// `interpreter::effects::run_effects` on the corresponding event.
    pub handlers: HashMap<String, Vec<serde_json::Value>>,
    /// Optional overlay declaration. When `render_overlay` wants to
    /// draw, it evaluates `guard` (if any) and, when truthy, renders
    /// `render`. Kept as a raw JSON dict for Phase 3d to interpret.
    pub overlay: Option<OverlaySpec>,
}

/// Tool-overlay declaration — a guard expression plus a render dict.
#[derive(Debug, Clone)]
pub struct OverlaySpec {
    /// Expression that must evaluate truthy for the overlay to draw.
    /// `None` means always draw.
    pub guard: Option<String>,
    /// The `render:` subtree. Shape depends on the overlay type
    /// (`{ type: rect, x, y, width, height, style }` etc.). Kept as
    /// raw JSON so the renderer can evolve without reshaping this struct.
    pub render: serde_json::Value,
}

impl ToolSpec {
    /// Parse a single tool spec, typically loaded from
    /// `workspace.json` under `tools.<id>`. Returns `None` if the spec
    /// is missing its `id`, which is the only required field.
    pub fn from_workspace_tool(spec: &serde_json::Value) -> Option<Self> {
        let id = spec.get("id")?.as_str()?.to_string();
        let cursor = spec
            .get("cursor")
            .and_then(|v| v.as_str())
            .map(String::from);
        let menu_label = spec
            .get("menu_label")
            .and_then(|v| v.as_str())
            .map(String::from);
        let shortcut = spec
            .get("shortcut")
            .and_then(|v| v.as_str())
            .map(String::from);
        let state_defaults = parse_state_defaults(spec.get("state"));
        let handlers = parse_handlers(spec.get("handlers"));
        let overlay = parse_overlay(spec.get("overlay"));
        Some(Self {
            id,
            cursor,
            menu_label,
            shortcut,
            state_defaults,
            handlers,
            overlay,
        })
    }

    /// Fetch a handler by event name (e.g. `"on_mousedown"`). Returns
    /// an empty slice when the event has no declared handler — the
    /// caller treats that as a no-op.
    pub fn handler(&self, event_name: &str) -> &[serde_json::Value] {
        self.handlers
            .get(event_name)
            .map(|v| v.as_slice())
            .unwrap_or(&[])
    }
}

fn parse_state_defaults(
    val: Option<&serde_json::Value>,
) -> HashMap<String, serde_json::Value> {
    let mut out = HashMap::new();
    if let Some(serde_json::Value::Object(map)) = val {
        for (key, defn) in map {
            // Each state entry is either `<key>: <scalar>` (shorthand)
            // or `<key>: { default: <value>, enum?: [...] }` (long form).
            let default = if let serde_json::Value::Object(d) = defn {
                d.get("default").cloned().unwrap_or(serde_json::Value::Null)
            } else {
                defn.clone()
            };
            out.insert(key.clone(), default);
        }
    }
    out
}

fn parse_handlers(
    val: Option<&serde_json::Value>,
) -> HashMap<String, Vec<serde_json::Value>> {
    let mut out = HashMap::new();
    if let Some(serde_json::Value::Object(map)) = val {
        for (name, effects) in map {
            if let serde_json::Value::Array(effs) = effects {
                out.insert(name.clone(), effs.clone());
            }
        }
    }
    out
}

fn parse_overlay(val: Option<&serde_json::Value>) -> Option<OverlaySpec> {
    let obj = val?.as_object()?;
    let guard = obj
        .get("if")
        .and_then(|v| v.as_str())
        .map(String::from);
    let render = obj.get("render")?.clone();
    Some(OverlaySpec { guard, render })
}

/// YAML-driven tool. Holds a parsed [`ToolSpec`] and a private
/// [`StateStore`] seeded with the tool's state defaults. Each
/// [`CanvasTool`] method builds the corresponding `$event` scope,
/// registers the current document for doc-aware primitives, and
/// dispatches the matching handler list through `run_effects`.
///
/// The store is self-contained — state mutations persist between
/// calls on this tool's own store only, not on a global app store.
/// Phase 5 (or a pre-Phase-5 integration) will decide whether to
/// share a store with AppState; for now the self-contained layout
/// matches the Phase 4 test plan (run Selection tests directly
/// against `YamlTool::from_spec`).
pub struct YamlTool {
    spec: ToolSpec,
    store: StateStore,
}

impl YamlTool {
    /// Build a YamlTool from a parsed spec. Seeds the internal store
    /// with the spec's state defaults under `tool.<id>.*`.
    pub fn new(spec: ToolSpec) -> Self {
        let mut store = StateStore::new();
        store.init_tool(&spec.id, spec.state_defaults.clone());
        Self { spec, store }
    }

    /// Build directly from raw workspace spec JSON. Returns `None` when
    /// the spec fails to parse (missing id).
    pub fn from_workspace_tool(spec_json: &serde_json::Value) -> Option<Self> {
        ToolSpec::from_workspace_tool(spec_json).map(Self::new)
    }

    pub fn spec(&self) -> &ToolSpec {
        &self.spec
    }

    /// Read a tool-local state value. Primary use: tests that want to
    /// observe what a handler wrote to `$tool.<id>.<key>`.
    pub fn tool_state(&self, key: &str) -> &serde_json::Value {
        self.store.get_tool(&self.spec.id, key)
    }

    /// Build the `$event` scope dict for a pointer event.
    fn pointer_event_payload(
        event_type: &str,
        x: f64,
        y: f64,
        shift: bool,
        alt: bool,
    ) -> serde_json::Value {
        serde_json::json!({
            "type": event_type,
            "x": x,
            "y": y,
            "modifiers": {
                "shift": shift,
                "alt": alt,
                "ctrl": false,
                "meta": false,
            }
        })
    }

    /// Dispatch the handler for `event_name` (e.g. `"on_mousedown"`).
    /// Registers the Model's document for doc-aware primitives, runs
    /// the handler's effects, then drops the registration. No-op when
    /// the event is not declared on the spec.
    fn dispatch(
        &mut self,
        event_name: &str,
        event_payload: serde_json::Value,
        model: &mut Model,
    ) {
        let handler = self.spec.handler(event_name);
        if handler.is_empty() {
            return;
        }
        let ctx = serde_json::json!({ "event": event_payload });
        // Registration tears down on guard drop — handler panics still
        // leave the doc-primitive thread-local in a clean state.
        let _guard = doc_primitives::register_document(model.document().clone());
        // Clone handler to drop the borrow on self.spec; run_effects
        // wants &mut self.store.
        let effects = handler.to_vec();
        run_effects(
            &effects,
            &ctx,
            &mut self.store,
            Some(model),
            None,
            None,
        );
    }
}

impl CanvasTool for YamlTool {
    fn on_press(
        &mut self,
        model: &mut Model,
        x: f64,
        y: f64,
        shift: bool,
        alt: bool,
    ) {
        let payload = Self::pointer_event_payload("mousedown", x, y, shift, alt);
        self.dispatch("on_mousedown", payload, model);
    }

    fn on_move(
        &mut self,
        model: &mut Model,
        x: f64,
        y: f64,
        shift: bool,
        alt: bool,
        dragging: bool,
    ) {
        let mut payload = Self::pointer_event_payload("mousemove", x, y, shift, alt);
        // `dragging` is Rust-specific (Flask doesn't emit it), kept as
        // an extra scope field so YAML authors can opt into it.
        if let serde_json::Value::Object(ref mut map) = payload {
            map.insert(
                "dragging".to_string(),
                serde_json::Value::Bool(dragging),
            );
        }
        self.dispatch("on_mousemove", payload, model);
    }

    fn on_release(
        &mut self,
        model: &mut Model,
        x: f64,
        y: f64,
        shift: bool,
        alt: bool,
    ) {
        let payload = Self::pointer_event_payload("mouseup", x, y, shift, alt);
        self.dispatch("on_mouseup", payload, model);
    }

    fn activate(&mut self, model: &mut Model) {
        // Reset tool-local state to declared defaults, then fire on_enter.
        self.store
            .init_tool(&self.spec.id, self.spec.state_defaults.clone());
        let payload = serde_json::json!({ "type": "enter" });
        self.dispatch("on_enter", payload, model);
    }

    fn deactivate(&mut self, model: &mut Model) {
        let payload = serde_json::json!({ "type": "leave" });
        self.dispatch("on_leave", payload, model);
    }

    fn cursor_css_override(&self) -> Option<String> {
        self.spec.cursor.clone()
    }

    fn draw_overlay(&self, _model: &Model, _ctx: &CanvasRenderingContext2d) {
        // Phase 3d will evaluate self.spec.overlay.guard + render here.
        // For Phase 3c the overlay is a no-op — Selection tool tests
        // focus on state/doc mutations; overlay rendering is covered
        // separately in Phase 3d.
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn minimal_spec() -> serde_json::Value {
        serde_json::json!({
            "id": "selection",
            "cursor": "arrow",
            "menu_label": "Selection Tool",
            "shortcut": "V",
            "state": {
                "mode": { "default": "idle", "enum": ["idle", "marquee"] },
                "marquee_start_x": { "default": 0 }
            },
            "handlers": {
                "on_enter": [
                    { "set": { "tool.selection.mode": "'idle'" } }
                ],
                "on_mousedown": [
                    { "set": { "tool.selection.marquee_start_x": "event.x" } }
                ]
            },
            "overlay": {
                "if": "tool.selection.mode == 'marquee'",
                "render": {
                    "type": "rect",
                    "x": "tool.selection.marquee_start_x",
                    "style": "stroke: #4a90d9;"
                }
            }
        })
    }

    #[test]
    fn parses_all_top_level_fields() {
        let spec = ToolSpec::from_workspace_tool(&minimal_spec()).unwrap();
        assert_eq!(spec.id, "selection");
        assert_eq!(spec.cursor.as_deref(), Some("arrow"));
        assert_eq!(spec.menu_label.as_deref(), Some("Selection Tool"));
        assert_eq!(spec.shortcut.as_deref(), Some("V"));
    }

    #[test]
    fn parses_state_defaults_from_long_form() {
        let spec = ToolSpec::from_workspace_tool(&minimal_spec()).unwrap();
        assert_eq!(
            spec.state_defaults.get("mode"),
            Some(&serde_json::json!("idle")),
        );
        assert_eq!(
            spec.state_defaults.get("marquee_start_x"),
            Some(&serde_json::json!(0)),
        );
    }

    #[test]
    fn parses_state_defaults_from_shorthand() {
        // shorthand: `<key>: <scalar>`
        let raw = serde_json::json!({
            "id": "t",
            "state": { "x": 42, "s": "hello" }
        });
        let spec = ToolSpec::from_workspace_tool(&raw).unwrap();
        assert_eq!(spec.state_defaults.get("x"), Some(&serde_json::json!(42)));
        assert_eq!(
            spec.state_defaults.get("s"),
            Some(&serde_json::json!("hello")),
        );
    }

    #[test]
    fn missing_default_in_long_form_becomes_null() {
        let raw = serde_json::json!({
            "id": "t",
            "state": { "x": { "enum": ["a", "b"] } }
        });
        let spec = ToolSpec::from_workspace_tool(&raw).unwrap();
        assert_eq!(
            spec.state_defaults.get("x"),
            Some(&serde_json::Value::Null),
        );
    }

    #[test]
    fn parses_handlers_into_effect_lists() {
        let spec = ToolSpec::from_workspace_tool(&minimal_spec()).unwrap();
        let enter = spec.handler("on_enter");
        assert_eq!(enter.len(), 1);
        assert!(enter[0].get("set").is_some());
        let down = spec.handler("on_mousedown");
        assert_eq!(down.len(), 1);
    }

    #[test]
    fn handler_returns_empty_slice_for_unknown_event() {
        let spec = ToolSpec::from_workspace_tool(&minimal_spec()).unwrap();
        assert_eq!(spec.handler("on_keydown"), &[] as &[serde_json::Value]);
    }

    #[test]
    fn parses_overlay_spec() {
        let spec = ToolSpec::from_workspace_tool(&minimal_spec()).unwrap();
        let overlay = spec.overlay.expect("overlay should be present");
        assert_eq!(
            overlay.guard.as_deref(),
            Some("tool.selection.mode == 'marquee'"),
        );
        assert_eq!(overlay.render["type"], serde_json::json!("rect"));
    }

    #[test]
    fn missing_overlay_becomes_none() {
        let raw = serde_json::json!({ "id": "no_overlay" });
        let spec = ToolSpec::from_workspace_tool(&raw).unwrap();
        assert!(spec.overlay.is_none());
    }

    #[test]
    fn missing_id_returns_none() {
        let raw = serde_json::json!({ "cursor": "arrow" });
        assert!(ToolSpec::from_workspace_tool(&raw).is_none());
    }

    #[test]
    fn empty_state_and_handlers_are_ok() {
        let raw = serde_json::json!({ "id": "t" });
        let spec = ToolSpec::from_workspace_tool(&raw).unwrap();
        assert!(spec.state_defaults.is_empty());
        assert!(spec.handlers.is_empty());
        assert!(spec.overlay.is_none());
    }

    #[test]
    fn overlay_without_render_is_rejected() {
        let raw = serde_json::json!({
            "id": "t",
            "overlay": { "if": "true" }
        });
        let spec = ToolSpec::from_workspace_tool(&raw).unwrap();
        assert!(spec.overlay.is_none());
    }

    // ── YamlTool dispatch tests (Phase 3c) ─────────────────────────

    use crate::document::controller::Controller;
    use crate::document::document::Document;
    use crate::document::model::Model;
    use crate::geometry::element::{
        Color, CommonProps, Element, Fill, LayerElem, RectElem,
    };

    fn model_with_rect_at(x: f64, y: f64, w: f64, h: f64) -> Model {
        let rect = Element::Rect(RectElem {
            x, y, width: w, height: h,
            rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        });
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![std::rc::Rc::new(rect)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        Model::new(
            Document {
                layers: vec![layer],
                selected_layer: 0,
                selection: Vec::new(),
                ..Document::default()
            },
            None,
        )
    }

    fn spec_with_mousedown_set() -> serde_json::Value {
        // Simplest tool: on_mousedown writes event.x to tool state.
        serde_json::json!({
            "id": "probe",
            "state": { "last_x": { "default": 0 } },
            "handlers": {
                "on_mousedown": [
                    { "set": { "tool.probe.last_x": "event.x" } }
                ]
            }
        })
    }

    #[test]
    fn new_seeds_tool_state_from_defaults() {
        let spec = ToolSpec::from_workspace_tool(&spec_with_mousedown_set()).unwrap();
        let tool = YamlTool::new(spec);
        assert_eq!(tool.tool_state("last_x"), &serde_json::json!(0));
    }

    #[test]
    fn on_press_writes_tool_state_from_event_scope() {
        let spec = ToolSpec::from_workspace_tool(&spec_with_mousedown_set()).unwrap();
        let mut tool = YamlTool::new(spec);
        let mut model = Model::default();
        tool.on_press(&mut model, 17.0, 42.0, false, false);
        assert_eq!(tool.tool_state("last_x"), &serde_json::json!(17));
    }

    #[test]
    fn on_press_with_no_handler_is_noop() {
        // Spec declares no on_mousedown handler.
        let raw = serde_json::json!({
            "id": "empty",
            "state": { "x": { "default": 0 } }
        });
        let spec = ToolSpec::from_workspace_tool(&raw).unwrap();
        let mut tool = YamlTool::new(spec);
        let mut model = Model::default();
        tool.on_press(&mut model, 10.0, 10.0, false, false);
        // State stays at default — no handler ran.
        assert_eq!(tool.tool_state("x"), &serde_json::json!(0));
    }

    #[test]
    fn activate_resets_state_and_fires_on_enter() {
        let raw = serde_json::json!({
            "id": "t",
            "state": {
                "mode": { "default": "idle" },
                "counter": { "default": 0 }
            },
            "handlers": {
                "on_enter": [
                    { "set": { "tool.t.mode": "'ready'" } }
                ]
            }
        });
        let spec = ToolSpec::from_workspace_tool(&raw).unwrap();
        let mut tool = YamlTool::new(spec);
        // Mutate state so activate's reset is observable.
        tool.store
            .set_tool("t", "counter", serde_json::json!(99));
        let mut model = Model::default();
        tool.activate(&mut model);
        // counter was reset to default, mode was written by on_enter.
        assert_eq!(tool.tool_state("counter"), &serde_json::json!(0));
        assert_eq!(tool.tool_state("mode"), &serde_json::json!("ready"));
    }

    #[test]
    fn deactivate_fires_on_leave() {
        let raw = serde_json::json!({
            "id": "t",
            "state": { "mode": { "default": "active" } },
            "handlers": {
                "on_leave": [
                    { "set": { "tool.t.mode": "'gone'" } }
                ]
            }
        });
        let spec = ToolSpec::from_workspace_tool(&raw).unwrap();
        let mut tool = YamlTool::new(spec);
        let mut model = Model::default();
        tool.deactivate(&mut model);
        assert_eq!(tool.tool_state("mode"), &serde_json::json!("gone"));
    }

    #[test]
    fn cursor_override_reads_spec() {
        let raw = serde_json::json!({
            "id": "t",
            "cursor": "crosshair"
        });
        let tool = YamlTool::new(ToolSpec::from_workspace_tool(&raw).unwrap());
        assert_eq!(tool.cursor_css_override(), Some("crosshair".to_string()));
    }

    #[test]
    fn on_press_dispatches_doc_effects_against_real_model() {
        // Handler: doc.snapshot, then doc.clear_selection. Verify both
        // landed on the model.
        let raw = serde_json::json!({
            "id": "clearer",
            "handlers": {
                "on_mousedown": [
                    { "doc.snapshot": {} },
                    { "doc.clear_selection": {} }
                ]
            }
        });
        let spec = ToolSpec::from_workspace_tool(&raw).unwrap();
        let mut tool = YamlTool::new(spec);
        let mut model = model_with_rect_at(10.0, 10.0, 20.0, 20.0);
        Controller::select_element(&mut model, &vec![0, 0]);
        assert!(!model.document().selection.is_empty());
        assert!(!model.can_undo());

        tool.on_press(&mut model, 5.0, 5.0, false, false);

        assert!(model.can_undo(), "doc.snapshot should push undo");
        assert!(
            model.document().selection.is_empty(),
            "doc.clear_selection should empty selection",
        );
    }

    #[test]
    fn on_press_hit_test_finds_element_under_point() {
        // hit_test is a doc-aware primitive that needs the Model's
        // document registered. YamlTool::dispatch does this.
        let raw = serde_json::json!({
            "id": "probe",
            "state": { "hit_path": { "default": [] } },
            "handlers": {
                "on_mousedown": [
                    {
                        "let": { "hit": "hit_test(event.x, event.y)" },
                        "in": [
                            // If we hit something, record non-null marker;
                            // otherwise stays as the default empty list.
                            { "if": {
                                "condition": "hit != null",
                                "then": [
                                    { "set": { "tool.probe.hit_path": "hit" } }
                                ],
                                "else": []
                            }}
                        ]
                    }
                ]
            }
        });
        let spec = ToolSpec::from_workspace_tool(&raw).unwrap();
        let mut tool = YamlTool::new(spec);
        let mut model = model_with_rect_at(10.0, 10.0, 20.0, 20.0);
        // Hit inside the rect (bounds 10..30 × 10..30).
        tool.on_press(&mut model, 15.0, 15.0, false, false);
        let hit = tool.tool_state("hit_path");
        // hit_path was written from a Path value, which serializes as
        // {"__path__": [0, 0]}.
        assert_eq!(
            hit,
            &serde_json::json!({"__path__": [0, 0]}),
            "hit_test on a rect under the cursor should yield its path",
        );
    }

    #[test]
    fn on_move_receives_dragging_flag_in_scope() {
        // Handler reads `event.dragging` and sets a tool flag.
        let raw = serde_json::json!({
            "id": "t",
            "state": { "was_dragging": { "default": false } },
            "handlers": {
                "on_mousemove": [
                    { "set": { "tool.t.was_dragging": "event.dragging" } }
                ]
            }
        });
        let spec = ToolSpec::from_workspace_tool(&raw).unwrap();
        let mut tool = YamlTool::new(spec);
        let mut model = Model::default();
        tool.on_move(&mut model, 1.0, 2.0, false, false, true);
        assert_eq!(
            tool.tool_state("was_dragging"),
            &serde_json::json!(true),
        );
    }

    #[test]
    fn on_release_dispatches_mouseup_handler() {
        let raw = serde_json::json!({
            "id": "t",
            "state": { "released_at": { "default": 0 } },
            "handlers": {
                "on_mouseup": [
                    { "set": { "tool.t.released_at": "event.x" } }
                ]
            }
        });
        let spec = ToolSpec::from_workspace_tool(&raw).unwrap();
        let mut tool = YamlTool::new(spec);
        let mut model = Model::default();
        tool.on_release(&mut model, 33.0, 44.0, false, false);
        assert_eq!(tool.tool_state("released_at"), &serde_json::json!(33));
    }

    #[test]
    fn parses_real_selection_yaml() {
        // Smoke-test against the actual compiled workspace tool spec
        // to catch shape drift between the YAML authoring and this
        // parser. Loads workspace.json and picks out the selection tool.
        use std::fs;
        use std::path::PathBuf;
        let workspace_path: PathBuf = [
            env!("CARGO_MANIFEST_DIR"),
            "..",
            "workspace",
            "workspace.json",
        ]
        .iter()
        .collect();
        if !workspace_path.exists() {
            // Skip silently if the compiled workspace isn't present;
            // the main CI lane always generates it before the Rust step.
            return;
        }
        let raw = fs::read_to_string(&workspace_path).unwrap();
        let ws: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let sel_spec = ws
            .get("tools")
            .and_then(|t| t.get("selection"))
            .expect("selection tool should live at tools.selection");
        let parsed = ToolSpec::from_workspace_tool(sel_spec)
            .expect("selection tool should parse into ToolSpec");
        assert_eq!(parsed.id, "selection");
        // Should have at least on_mousedown / on_mousemove / on_mouseup.
        for ev in ["on_mousedown", "on_mousemove", "on_mouseup"] {
            assert!(
                !parsed.handler(ev).is_empty(),
                "selection.yaml should declare a non-empty {ev} handler",
            );
        }
        // Should have the marquee overlay.
        assert!(parsed.overlay.is_some(), "selection.yaml declares an overlay");
        // state_defaults should include 'mode' with a sensible default.
        assert_eq!(
            parsed.state_defaults.get("mode"),
            Some(&serde_json::json!("idle")),
        );
    }

    // ── Phase 4: parity with native SelectionTool ──────────────────
    //
    // Behavior-for-behavior ports of the six cases in
    // jas_dioxus/src/tools/selection_tool.rs::tests, run against a
    // YamlTool constructed from the actual selection.yaml. Each
    // assertion is the same — same pre-state, same sequence of events,
    // same final document state.
    //
    // Two test-shape differences from the native cases:
    //
    // 1. Marquee tests insert an on_move(end_x, end_y) between
    //    on_press and on_release. The native tool uses the release
    //    x/y directly to compute the marquee rect, while the YAML
    //    spec reads tool.selection.marquee_end_{x,y} which is only
    //    updated in on_mousemove. In real UI the browser always
    //    delivers mousemove between mousedown and mouseup; tests
    //    must simulate it.
    //
    // 2. move_selection matches native exactly — press, two moves,
    //    release. The YAML spec transitions mode to drag_move on
    //    any press that hits an element (no DRAG_THRESHOLD), so
    //    even the first move applies a translation. The test
    //    expectations land on the same end position because the
    //    delta accumulation works out identically for the moves
    //    the test performs.

    fn selection_yaml_tool() -> Option<YamlTool> {
        use std::fs;
        use std::path::PathBuf;
        let ws_path: PathBuf = [
            env!("CARGO_MANIFEST_DIR"),
            "..",
            "workspace",
            "workspace.json",
        ]
        .iter()
        .collect();
        if !ws_path.exists() {
            return None;
        }
        let raw = fs::read_to_string(&ws_path).ok()?;
        let ws: serde_json::Value = serde_json::from_str(&raw).ok()?;
        let spec_json = ws.get("tools")?.get("selection")?;
        YamlTool::from_workspace_tool(spec_json)
    }

    fn selection_parity_model() -> Model {
        // Same shape as SelectionTool's `make_model_with_rect`: a
        // single 20×20 rect at (50, 50) inside a one-layer document.
        model_with_rect_at(50.0, 50.0, 20.0, 20.0)
    }

    #[test]
    fn selection_parity_marquee_select() {
        let Some(mut tool) = selection_yaml_tool() else { return };
        let mut model = selection_parity_model();
        // Marquee covering the rect: (45,45) → (75,75).
        tool.on_press(&mut model, 45.0, 45.0, false, false);
        tool.on_move(&mut model, 75.0, 75.0, false, false, true);
        tool.on_release(&mut model, 75.0, 75.0, false, false);
        assert!(!model.document().selection.is_empty());
    }

    #[test]
    fn selection_parity_marquee_miss() {
        let Some(mut tool) = selection_yaml_tool() else { return };
        let mut model = selection_parity_model();
        // Marquee away from rect: (0,0) → (10,10).
        tool.on_press(&mut model, 0.0, 0.0, false, false);
        tool.on_move(&mut model, 10.0, 10.0, false, false, true);
        tool.on_release(&mut model, 10.0, 10.0, false, false);
        assert!(model.document().selection.is_empty());
    }

    #[test]
    fn selection_parity_click_selects_element() {
        let Some(mut tool) = selection_yaml_tool() else { return };
        let mut model = selection_parity_model();
        // Click inside the rect's bounds: (55,55).
        tool.on_press(&mut model, 55.0, 55.0, false, false);
        tool.on_release(&mut model, 55.0, 55.0, false, false);
        assert!(!model.document().selection.is_empty());
    }

    #[test]
    fn selection_parity_click_on_empty_canvas_clears_selection() {
        let Some(mut tool) = selection_yaml_tool() else { return };
        let mut model = selection_parity_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        assert!(!model.document().selection.is_empty());
        // Click on empty canvas, no shift → selection cleared.
        tool.on_press(&mut model, 5.0, 5.0, false, false);
        tool.on_release(&mut model, 5.0, 5.0, false, false);
        assert!(
            model.document().selection.is_empty(),
            "selection should be cleared after click on empty canvas",
        );
    }

    #[test]
    fn selection_parity_shift_click_on_empty_canvas_keeps_selection() {
        let Some(mut tool) = selection_yaml_tool() else { return };
        let mut model = selection_parity_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        // Shift+click on empty canvas — selection preserved.
        tool.on_press(&mut model, 5.0, 5.0, true, false);
        tool.on_release(&mut model, 5.0, 5.0, true, false);
        assert!(
            !model.document().selection.is_empty(),
            "shift-click on empty canvas should not clear the selection",
        );
    }

    #[test]
    fn selection_parity_move_selection() {
        let Some(mut tool) = selection_yaml_tool() else { return };
        let mut model = selection_parity_model();
        // Pre-select the rect.
        Controller::select_element(&mut model, &vec![0, 0]);
        // Press on it, then two moves, then release. Final position
        // should match the native tool's (60, 60) end state.
        tool.on_press(&mut model, 60.0, 60.0, false, false);
        tool.on_move(&mut model, 65.0, 65.0, false, false, true);
        tool.on_move(&mut model, 70.0, 70.0, false, false, true);
        tool.on_release(&mut model, 70.0, 70.0, false, false);
        let elem = &model.document().layers[0].children().unwrap()[0];
        if let Element::Rect(r) = &**elem {
            assert_eq!(r.x, 60.0);
            assert_eq!(r.y, 60.0);
        } else {
            panic!("expected Rect element");
        }
    }
}
