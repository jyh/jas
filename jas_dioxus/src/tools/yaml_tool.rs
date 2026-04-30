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
use crate::tools::tool::{CanvasTool, KeyMods};

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
    /// Overlay declarations. Most tools have zero or one entry; the
    /// transform-tool family (Scale / Rotate / Shear) uses a list to
    /// layer the reference-point cross over the drag-time bbox ghost.
    /// Each entry is rendered in order; each entry's `guard` is
    /// evaluated independently.
    pub overlay: Vec<OverlaySpec>,
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

fn parse_overlay_entry(obj: &serde_json::Map<String, serde_json::Value>) -> Option<OverlaySpec> {
    let guard = obj
        .get("if")
        .and_then(|v| v.as_str())
        .map(String::from);
    let render = obj.get("render")?.clone();
    Some(OverlaySpec { guard, render })
}

fn parse_overlay(val: Option<&serde_json::Value>) -> Vec<OverlaySpec> {
    let Some(v) = val else { return Vec::new(); };
    // Accept either a single {if, render} object (most tools) or a
    // list of such objects (transform-tool family). Both forms
    // produce the same Vec<OverlaySpec> downstream.
    if let Some(obj) = v.as_object() {
        if let Some(spec) = parse_overlay_entry(obj) {
            return vec![spec];
        }
        return Vec::new();
    }
    if let Some(arr) = v.as_array() {
        return arr.iter()
            .filter_map(|item| item.as_object().and_then(parse_overlay_entry))
            .collect();
    }
    Vec::new()
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

    #[allow(dead_code)] // public API for future spec inspection; used in tests
    pub fn spec(&self) -> &ToolSpec {
        &self.spec
    }

    /// Read a tool-local state value. Primary use: tests that want to
    /// observe what a handler wrote to `$tool.<id>.<key>`.
    #[allow(dead_code)] // used in tests; public for future introspection tooling
    pub fn tool_state(&self, key: &str) -> &serde_json::Value {
        self.store.get_tool(&self.spec.id, key)
    }

    /// Build the `$event` scope dict for a pointer event.
    ///
    /// `x` / `y` are viewport-pixel coordinates (relative to the
    /// canvas DOM element); they're what every overlay reads, since
    /// overlays draw post-restore in screen-space.
    ///
    /// `doc_x` / `doc_y` are the same point converted to document
    /// coordinates via the active view transform — what tool YAMLs
    /// must use when committing element geometry. With a centered
    /// artboard the view_offset is non-zero, so passing screen-space
    /// straight into `add_element` plants the element ~hundreds of
    /// pixels off-screen.
    fn pointer_event_payload(
        event_type: &str,
        x: f64,
        y: f64,
        shift: bool,
        alt: bool,
        model: &Model,
    ) -> serde_json::Value {
        let z = model.zoom_level;
        let doc_x = if z == 0.0 { x } else { (x - model.view_offset_x) / z };
        let doc_y = if z == 0.0 { y } else { (y - model.view_offset_y) / z };
        serde_json::json!({
            "type": event_type,
            "x": x,
            "y": y,
            "doc_x": doc_x,
            "doc_y": doc_y,
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
    /// Build the `$active_document` scope dict for tool dispatch.
    ///
    /// Tools (notably Hand and Zoom) read view-state via
    /// `active_document.view_offset_x` / `view_offset_y` /
    /// `zoom_level` to capture pre-drag baselines. Without this
    /// the dispatch ctx has no `active_document` namespace and
    /// those references resolve to Null → 0.0, so the very first
    /// pan/zoom drag jumps from offset 0 instead of the current
    /// view position.
    fn active_document_payload(model: &Model) -> serde_json::Value {
        serde_json::json!({
            "view_offset_x": model.view_offset_x,
            "view_offset_y": model.view_offset_y,
            "zoom_level":    model.zoom_level,
        })
    }

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
        // Tools can `dispatch:` workspace actions from their handlers
        // (e.g. zoom.yaml's on_mouseup fires `dispatch: { action:
        // zoom_in, params: {...} }` for click-to-zoom). Without the
        // actions catalog AND preferences in the eval ctx, those
        // dispatches silently no-op (or, worse, evaluate
        // `preferences.viewport.zoom_step` to Null/0.0 inside
        // doc.zoom.apply and clamp the model to min_zoom). Loading
        // here is cheap (Workspace::load() hits a OnceLock cache).
        let workspace = crate::interpreter::workspace::Workspace::load();
        let actions = workspace.as_ref().map(|ws| ws.actions());
        let preferences = workspace
            .as_ref()
            .and_then(|ws| ws.data().get("preferences").cloned())
            .unwrap_or(serde_json::Value::Null);
        let ctx = serde_json::json!({
            "event": event_payload,
            "active_document": Self::active_document_payload(model),
            "preferences": preferences,
        });
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
            actions,
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
        let payload = Self::pointer_event_payload("mousedown", x, y, shift, alt, model);
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
        let mut payload = Self::pointer_event_payload("mousemove", x, y, shift, alt, model);
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
        let payload = Self::pointer_event_payload("mouseup", x, y, shift, alt, model);
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
        // Tool-specific dynamic cursor handling. Hand flips between
        // "grab" (idle) and "grabbing" (during drag). Zoom flips
        // between "zoom-in" (idle) and "zoom-out" (Alt held during
        // drag). Phase 1 reads tool state for the in-flight bits;
        // Alt-during-idle flipping (no drag) is deferred since it
        // requires keyboard handling outside the tool. Per
        // HAND_TOOL.md §Cursor states and ZOOM_TOOL.md §Cursor
        // states.
        match self.spec.id.as_str() {
            "hand" => {
                let mode = self.store.eval_context()
                    .get("tool")
                    .and_then(|t| t.get("hand"))
                    .and_then(|h| h.get("mode"))
                    .and_then(|m| m.as_str())
                    .map(String::from)
                    .unwrap_or_default();
                if mode == "panning" {
                    Some("grabbing".into())
                } else {
                    self.spec.cursor.clone()
                }
            }
            "zoom" => {
                let ctx = self.store.eval_context();
                let alt_held = ctx.get("tool")
                    .and_then(|t| t.get("zoom"))
                    .and_then(|z| z.get("alt_held"))
                    .and_then(|a| a.as_bool())
                    .unwrap_or(false);
                // alt_held is updated on every on_mousemove (drag or
                // idle), so the cursor flip tracks modifier state as
                // soon as the cursor moves with Alt held -- not only
                // during a scrubby drag. Mode is no longer part of
                // the gate; both idle Alt-click and drag-with-Alt
                // want the zoom-out glyph.
                if alt_held {
                    Some("zoom-out".into())
                } else {
                    self.spec.cursor.clone()
                }
            }
            "artboard" => {
                // Per ARTBOARD_TOOL.md §Cursor states. During a drag
                // the cursor reflects the gesture in flight (move /
                // copy / 8-way directional resize). At idle the
                // cursor reflects what's under the pointer (handle /
                // interior / empty), set by doc.artboard.probe_hover
                // on each mousemove.
                let ctx = self.store.eval_context();
                let read_str = |k: &str| -> String {
                    ctx.get("tool")
                        .and_then(|t| t.get("artboard"))
                        .and_then(|a| a.get(k))
                        .and_then(|v| v.as_str())
                        .map(String::from)
                        .unwrap_or_default()
                };
                let read_bool = |k: &str| -> bool {
                    ctx.get("tool")
                        .and_then(|t| t.get("artboard"))
                        .and_then(|a| a.get(k))
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false)
                };
                let mode = read_str("mode");
                let alt_held = read_bool("alt_held");
                let handle_pos = read_str("hit_handle_pos");

                let resize_cursor_for = |pos: &str| -> &'static str {
                    match pos {
                        "nw" | "se" => "nwse-resize",
                        "ne" | "sw" => "nesw-resize",
                        "n" | "s" => "ns-resize",
                        "e" | "w" => "ew-resize",
                        _ => "default",
                    }
                };

                // During drag — reflect the gesture.
                match mode.as_str() {
                    "moving" | "moving_pending" => return Some("move".into()),
                    "duplicating" | "duplicating_pending" => return Some("copy".into()),
                    "resizing" => {
                        return Some(resize_cursor_for(&handle_pos).into());
                    }
                    "creating" => return Some("crosshair".into()),
                    _ => {}
                }

                // Idle — reflect what's under the pointer.
                let hover = read_str("hover_kind");
                if let Some(rest) = hover.strip_prefix("handle:") {
                    return Some(resize_cursor_for(rest).into());
                }
                match hover.as_str() {
                    "interior" => Some(if alt_held { "copy" } else { "move" }.into()),
                    "empty" => Some("crosshair".into()),
                    _ => self.spec.cursor.clone(),
                }
            }
            _ => self.spec.cursor.clone(),
        }
    }

    fn on_double_click(&mut self, model: &mut Model, x: f64, y: f64) {
        // YAML handler key is `on_dblclick` to match the tool schema
        // (schema/tool.schema.json) — DOM / native frameworks also
        // use the shorter spelling.
        let payload = serde_json::json!({
            "type": "dblclick",
            "x": x,
            "y": y,
        });
        self.dispatch("on_dblclick", payload, model);
    }

    fn on_key(&mut self, model: &mut Model, key: &str) -> bool {
        // Important: `workspace::keyboard` routes Escape / Enter via
        // `on_key`, not `on_key_event`. A YamlTool that only overrode
        // the latter would miss those keys entirely — found the hard
        // way when Escape-to-commit-pen-path stopped working in
        // dx serve. Dispatch here too, with empty modifiers.
        self.on_key_event(model, key, KeyMods::default())
    }

    fn on_key_event(
        &mut self,
        model: &mut Model,
        key: &str,
        mods: KeyMods,
    ) -> bool {
        // Dispatch to on_keydown if the spec declares one. Return
        // true to signal consumption when we did dispatch — false
        // otherwise so the host keeps bubbling the event (e.g. to
        // menu accelerators) when the tool's YAML doesn't handle it.
        if self.spec.handler("on_keydown").is_empty() {
            return false;
        }
        let payload = serde_json::json!({
            "type": "keydown",
            "key": key,
            "modifiers": {
                "shift": mods.shift,
                "alt":   mods.alt,
                "ctrl":  mods.ctrl,
                "meta":  mods.meta,
            },
        });
        self.dispatch("on_keydown", payload, model);
        true
    }

    fn on_key_up(&mut self, model: &mut Model, key: &str) -> bool {
        // Mirrors on_key_event but for the matching keyup event. Used
        // by tools that need to react when a modifier (e.g. Alt for
        // the Zoom cursor) or other key is released. Modifiers aren't
        // wired through the trait signature; if a YAML handler needs
        // them, expose via on_key_up_event later.
        if self.spec.handler("on_keyup").is_empty() {
            return false;
        }
        let payload = serde_json::json!({
            "type": "keyup",
            "key": key,
        });
        self.dispatch("on_keyup", payload, model);
        true
    }

    fn on_wheel(
        &mut self,
        model: &mut Model,
        x: f64,
        y: f64,
        delta_x: f64,
        delta_y: f64,
        mods: KeyMods,
    ) -> bool {
        if self.spec.handler("on_wheel").is_empty() {
            return false;
        }
        let payload = serde_json::json!({
            "type": "wheel",
            "x": x,
            "y": y,
            "delta_x": delta_x,
            "delta_y": delta_y,
            "modifiers": {
                "shift": mods.shift,
                "alt":   mods.alt,
                "ctrl":  mods.ctrl,
                "meta":  mods.meta,
            },
        });
        self.dispatch("on_wheel", payload, model);
        true
    }

    fn draw_overlay(&self, model: &Model, ctx: &CanvasRenderingContext2d) {
        if self.spec.overlay.is_empty() {
            return;
        }
        // Document registration lets overlay expressions call
        // hit_test / selection_contains — same pattern as dispatch().
        let _guard = doc_primitives::register_document(model.document().clone());
        let eval_ctx = self.store.eval_context();

        for overlay in &self.spec.overlay {
            // Guard: if present, must evaluate truthy for this overlay
            // layer to draw.
            if let Some(guard_expr) = &overlay.guard {
                let result = crate::interpreter::expr::eval(guard_expr, &eval_ctx);
                if !result.to_bool() {
                    continue;
                }
            }

            // Dispatch on `render.type`. Each entry renders independently.
            let render = &overlay.render;
            let render_type = render
                .get("type")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            match render_type {
                "rect" => draw_rect_overlay(ctx, render, &eval_ctx),
                "ellipse" => draw_ellipse_overlay(ctx, render, &eval_ctx),
                "line" => draw_line_overlay(ctx, render, &eval_ctx),
                "polygon" => draw_regular_polygon_overlay(ctx, render, &eval_ctx),
                "star" => draw_star_overlay(ctx, render, &eval_ctx),
                "buffer_polygon" => draw_buffer_polygon_overlay(ctx, render, model),
                "buffer_polyline" => draw_buffer_polyline_overlay(ctx, render, &eval_ctx, model),
                "pen_overlay" => draw_pen_overlay(ctx, render, &eval_ctx, model),
                "partial_selection_overlay" => {
                    draw_partial_selection_overlay(ctx, render, &eval_ctx, model);
                }
                "oval_cursor" => draw_oval_cursor_overlay(ctx, render, &eval_ctx),
                "cursor_color_chip" => draw_cursor_color_chip_overlay(ctx, render, &eval_ctx),
                "reference_point_cross" => {
                    draw_reference_point_cross(ctx, render, &eval_ctx, model);
                }
                "bbox_ghost" => {
                    draw_bbox_ghost(ctx, render, &eval_ctx, model);
                }
                "marquee_rect" => {
                    draw_marquee_rect_overlay(ctx, render, &eval_ctx);
                }
                "artboard_resize_handles" => {
                    draw_artboard_resize_handles(ctx, render, &eval_ctx, model);
                }
                "artboard_outline_preview" => {
                    draw_artboard_outline_preview(ctx, render, &eval_ctx, model);
                }
                _ => {
                    // Unrecognized type — skip silently, matching the
                    // lenient-mode convention used elsewhere.
                }
            }
        }
    }

    fn drain_pending_panel_writes(
        &mut self,
    ) -> Vec<(String, String, serde_json::Value)> {
        // YAML-driven tools' effect handlers (e.g. doc.artboard.probe_hit)
        // queue panel-state writes on self.store; the canvas event
        // routing in workspace/app.rs drains and applies them after
        // each event dispatch. See ARTBOARD_TOOL.md §Selection coupling.
        self.store.drain_panel_state_writes()
    }
}

/// Evaluate an overlay geometry field — accepts a string expression
/// or a JSON number literal. Missing / unparseable → 0.0.
fn eval_number_field(
    ctx: &serde_json::Value,
    field: Option<&serde_json::Value>,
) -> f64 {
    match field {
        None | Some(serde_json::Value::Null) => 0.0,
        Some(serde_json::Value::Number(n)) => n.as_f64().unwrap_or(0.0),
        Some(serde_json::Value::String(s)) => {
            match crate::interpreter::expr::eval(s, ctx) {
                crate::interpreter::expr_types::Value::Number(n) => n,
                _ => 0.0,
            }
        }
        _ => 0.0,
    }
}

/// Parse a CSS-like style string into the subset of properties the
/// overlay renderer understands.
///
/// Input example: `"stroke: #4a90d9; stroke-width: 1; fill: rgba(74,144,217,0.08);"`
///
/// Unknown properties and malformed rules are ignored — a lenient
/// parser keeps the overlay surface from growing brittle as authors
/// experiment with style variations.
#[derive(Debug, Default, PartialEq)]
pub(crate) struct OverlayStyle {
    pub(crate) fill: Option<String>,
    pub(crate) stroke: Option<String>,
    pub(crate) stroke_width: Option<f64>,
    pub(crate) stroke_dasharray: Option<Vec<f64>>,
}

pub(crate) fn parse_style(s: &str) -> OverlayStyle {
    let mut style = OverlayStyle::default();
    for rule in s.split(';') {
        let rule = rule.trim();
        if rule.is_empty() {
            continue;
        }
        let Some((key, value)) = rule.split_once(':') else {
            continue;
        };
        let key = key.trim();
        let value = value.trim();
        match key {
            // SVG semantics: `fill: none` / `stroke: none` mean "skip
            // this paint", not "paint with the literal string 'none'".
            // Canvas2D's set_fill_style_str("none") silently fails and
            // leaves the previous fillStyle in place — the next
            // ctx.fill() then paints with whatever color was stale.
            "fill" if value == "none" => style.fill = None,
            "stroke" if value == "none" => style.stroke = None,
            "fill" => style.fill = Some(value.to_string()),
            "stroke" => style.stroke = Some(value.to_string()),
            "stroke-width" => style.stroke_width = value.parse().ok(),
            "stroke-dasharray" => {
                // Accept space- or comma-separated lengths, SVG style.
                let parts: Vec<f64> = value
                    .split(|c: char| c.is_whitespace() || c == ',')
                    .filter(|p| !p.is_empty())
                    .filter_map(|p| p.parse().ok())
                    .collect();
                if !parts.is_empty() {
                    style.stroke_dasharray = Some(parts);
                }
            }
            _ => {}
        }
    }
    style
}

/// Marquee zoom rectangle: thin dashed stroke between (x1, y1) and
/// (x2, y2). Used by the Zoom tool's drag overlay when scrubby_zoom
/// is off. Per ZOOM_TOOL.md §Drag — marquee zoom.
/// Draw the 8 resize handles on the single panel-selected artboard
/// per ARTBOARD_TOOL.md §Drag-to-resize. Handles render as 8 px
/// screen-space squares (white fill, blue border) at the four
/// corners and four edge midpoints. Coordinates are transformed
/// from the artboard's document-space bounds to viewport pixels via
/// model.zoom_level + model.view_offset_*.
fn draw_artboard_resize_handles(
    ctx: &CanvasRenderingContext2d,
    render: &serde_json::Value,
    eval_ctx: &serde_json::Value,
    model: &crate::document::model::Model,
) {
    let id_expr = render
        .get("artboard_id")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let id_val = crate::interpreter::expr::eval(id_expr, eval_ctx);
    let id = match id_val {
        crate::interpreter::expr_types::Value::Str(s) => s,
        _ => return,
    };
    let doc = model.document();
    let Some(ab) = doc.artboards.iter().find(|a| a.id == id) else { return; };

    let zoom = model.zoom_level;
    let offx = model.view_offset_x;
    let offy = model.view_offset_y;
    let to_vp = |dx: f64, dy: f64| -> (f64, f64) {
        (dx * zoom + offx, dy * zoom + offy)
    };
    let cx = ab.x + ab.width / 2.0;
    let cy = ab.y + ab.height / 2.0;
    let positions: [(f64, f64); 8] = [
        (ab.x, ab.y),                          // nw
        (cx, ab.y),                            // n
        (ab.x + ab.width, ab.y),               // ne
        (ab.x + ab.width, cy),                 // e
        (ab.x + ab.width, ab.y + ab.height),   // se
        (cx, ab.y + ab.height),                // s
        (ab.x, ab.y + ab.height),              // sw
        (ab.x, cy),                            // w
    ];
    const HANDLE_SIZE: f64 = 8.0;
    let half = HANDLE_SIZE / 2.0;
    ctx.set_fill_style_str("white");
    ctx.set_stroke_style_str("rgb(0, 120, 255)");
    ctx.set_line_width(1.5);
    for (dx, dy) in positions {
        let (vx, vy) = to_vp(dx, dy);
        ctx.fill_rect(vx - half, vy - half, HANDLE_SIZE, HANDLE_SIZE);
        ctx.stroke_rect(vx - half, vy - half, HANDLE_SIZE, HANDLE_SIZE);
    }
}

/// Draw the outline-preview rectangle for in-flight move / resize /
/// duplicate gestures when document.artboard_options.update_while_dragging
/// is false. The native renderer composes the in-flight bounds from
/// the gesture's mode + handle position + press/cursor + modifiers.
/// Phase 1.4 implementation: simple stroked rectangle in theme accent
/// color; refinements (handle previews on the outline, dimension
/// readout) are phase 2.
fn draw_artboard_outline_preview(
    ctx: &CanvasRenderingContext2d,
    render: &serde_json::Value,
    eval_ctx: &serde_json::Value,
    model: &crate::document::model::Model,
) {
    let mode_expr = render.get("mode").and_then(|v| v.as_str()).unwrap_or("");
    let mode = match crate::interpreter::expr::eval(mode_expr, eval_ctx) {
        crate::interpreter::expr_types::Value::Str(s) => s,
        _ => return,
    };
    let id_expr = render
        .get("artboard_id")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let id_val = crate::interpreter::expr::eval(id_expr, eval_ctx);
    let id = match id_val {
        crate::interpreter::expr_types::Value::Str(s) => s,
        _ => return,
    };
    let press_x = eval_number_field(eval_ctx, render.get("press_x"));
    let press_y = eval_number_field(eval_ctx, render.get("press_y"));
    let cursor_x = eval_number_field(eval_ctx, render.get("cursor_x"));
    let cursor_y = eval_number_field(eval_ctx, render.get("cursor_y"));

    let doc = model.document();
    // The preview is drawn against the model's CURRENT document state
    // (post-restore_preview_snapshot). For move / duplicate, the
    // artboard with `id` already lives at its in-flight position; we
    // draw a stroked outline around it. For resize, similar.
    let Some(ab) = doc.artboards.iter().find(|a| a.id == id) else { return; };
    let zoom = model.zoom_level;
    let offx = model.view_offset_x;
    let offy = model.view_offset_y;
    let vx = ab.x * zoom + offx;
    let vy = ab.y * zoom + offy;
    let vw = ab.width * zoom;
    let vh = ab.height * zoom;
    ctx.set_stroke_style_str("rgb(0, 120, 255)");
    ctx.set_line_width(1.0);
    ctx.stroke_rect(vx, vy, vw, vh);
    // Suppress unused warnings — these would be consumed by the
    // phase-2 refinements (handle previews, dimension readout).
    let _ = (press_x, press_y, cursor_x, cursor_y, mode);
}

fn draw_marquee_rect_overlay(
    ctx: &CanvasRenderingContext2d,
    render: &serde_json::Value,
    eval_ctx: &serde_json::Value,
) {
    let x1 = eval_number_field(eval_ctx, render.get("x1"));
    let y1 = eval_number_field(eval_ctx, render.get("y1"));
    let x2 = eval_number_field(eval_ctx, render.get("x2"));
    let y2 = eval_number_field(eval_ctx, render.get("y2"));
    let x = x1.min(x2);
    let y = y1.min(y2);
    let w = (x1 - x2).abs();
    let h = (y1 - y2).abs();
    if w <= 0.0 || h <= 0.0 { return; }
    ctx.set_stroke_style_str("#666");
    ctx.set_line_width(1.0);
    let dash = js_sys::Array::new();
    dash.push(&wasm_bindgen::JsValue::from_f64(4.0));
    dash.push(&wasm_bindgen::JsValue::from_f64(2.0));
    let _ = ctx.set_line_dash(&dash);
    ctx.stroke_rect(x, y, w, h);
    // Reset dash so subsequent overlays draw solid.
    let empty = js_sys::Array::new();
    let _ = ctx.set_line_dash(&empty);
}

fn draw_rect_overlay(
    ctx: &CanvasRenderingContext2d,
    render: &serde_json::Value,
    eval_ctx: &serde_json::Value,
) {
    let x = eval_number_field(eval_ctx, render.get("x"));
    let y = eval_number_field(eval_ctx, render.get("y"));
    let width = eval_number_field(eval_ctx, render.get("width"));
    let height = eval_number_field(eval_ctx, render.get("height"));
    // rx/ry give rounded corners — SVG-style. When either is > 0 the
    // fill/stroke path must walk corner arcs instead of using the
    // straight-corner fill_rect / stroke_rect fast path.
    let rx = eval_number_field(eval_ctx, render.get("rx"));
    let ry = eval_number_field(eval_ctx, render.get("ry"));
    let style_str = render
        .get("style")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let style = parse_style(style_str);

    let rounded = rx > 0.0 || ry > 0.0;
    let build_path = || {
        if rounded {
            build_rounded_rect_path(ctx, x, y, width, height, rx, ry);
        }
    };

    if let Some(fill) = &style.fill {
        ctx.set_fill_style_str(fill);
        if rounded {
            build_path();
            ctx.fill();
        } else {
            ctx.fill_rect(x, y, width, height);
        }
    }
    if let Some(stroke) = &style.stroke {
        ctx.set_stroke_style_str(stroke);
        if let Some(w) = style.stroke_width {
            ctx.set_line_width(w);
        }
        if let Some(dash) = &style.stroke_dasharray {
            let arr = js_sys::Array::new();
            for d in dash {
                arr.push(&wasm_bindgen::JsValue::from_f64(*d));
            }
            let _ = ctx.set_line_dash(&arr);
        }
        if rounded {
            build_path();
            ctx.stroke();
        } else {
            ctx.stroke_rect(x, y, width, height);
        }
        // Reset dash if we set one, so subsequent native strokes aren't
        // unexpectedly dashed. CanvasRenderingContext2d is stateful, so
        // reset with an empty array.
        if style.stroke_dasharray.is_some() {
            let _ = ctx.set_line_dash(&js_sys::Array::new());
        }
    }
}

/// Draw an ellipse overlay. Fields: cx/cy/rx/ry (numbers or string
/// expressions), style (CSS subset — fill, stroke, stroke-width,
/// stroke-dasharray). Used by the ellipse drawing tool's drag preview
/// and any other tool that wants an SVG-style ellipse on the overlay
/// layer.
fn draw_ellipse_overlay(
    ctx: &CanvasRenderingContext2d,
    render: &serde_json::Value,
    eval_ctx: &serde_json::Value,
) {
    let cx = eval_number_field(eval_ctx, render.get("cx"));
    let cy = eval_number_field(eval_ctx, render.get("cy"));
    let rx = eval_number_field(eval_ctx, render.get("rx"));
    let ry = eval_number_field(eval_ctx, render.get("ry"));
    if rx <= 0.0 || ry <= 0.0 {
        return;
    }
    let style_str = render
        .get("style")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let style = parse_style(style_str);

    let build_path = || {
        ctx.begin_path();
        let _ = ctx.ellipse(cx, cy, rx, ry, 0.0, 0.0, std::f64::consts::TAU);
    };

    if let Some(fill) = &style.fill {
        ctx.set_fill_style_str(fill);
        build_path();
        ctx.fill();
    }
    if let Some(stroke) = &style.stroke {
        ctx.set_stroke_style_str(stroke);
        if let Some(w) = style.stroke_width {
            ctx.set_line_width(w);
        }
        if let Some(dash) = &style.stroke_dasharray {
            let arr = js_sys::Array::new();
            for d in dash {
                arr.push(&wasm_bindgen::JsValue::from_f64(*d));
            }
            let _ = ctx.set_line_dash(&arr);
        }
        build_path();
        ctx.stroke();
        if style.stroke_dasharray.is_some() {
            let _ = ctx.set_line_dash(&js_sys::Array::new());
        }
    }
}

/// Draw a straight-line overlay. Fields: x1/y1/x2/y2 (numbers or
/// string expressions), style (CSS subset). Stroke only — line
/// overlays don't have a fillable interior.
fn draw_line_overlay(
    ctx: &CanvasRenderingContext2d,
    render: &serde_json::Value,
    eval_ctx: &serde_json::Value,
) {
    let x1 = eval_number_field(eval_ctx, render.get("x1"));
    let y1 = eval_number_field(eval_ctx, render.get("y1"));
    let x2 = eval_number_field(eval_ctx, render.get("x2"));
    let y2 = eval_number_field(eval_ctx, render.get("y2"));
    let style_str = render
        .get("style")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let style = parse_style(style_str);

    let Some(stroke) = &style.stroke else {
        return;
    };
    ctx.set_stroke_style_str(stroke);
    if let Some(w) = style.stroke_width {
        ctx.set_line_width(w);
    }
    if let Some(dash) = &style.stroke_dasharray {
        let arr = js_sys::Array::new();
        for d in dash {
            arr.push(&wasm_bindgen::JsValue::from_f64(*d));
        }
        let _ = ctx.set_line_dash(&arr);
    }
    ctx.begin_path();
    ctx.move_to(x1, y1);
    ctx.line_to(x2, y2);
    ctx.stroke();
    if style.stroke_dasharray.is_some() {
        let _ = ctx.set_line_dash(&js_sys::Array::new());
    }
}

/// Draw a closed polygon whose points come from a thread-local named
/// point buffer (see `interpreter::point_buffers`). Fields:
/// `buffer` (the buffer name), `style`. Used by Lasso's overlay.
fn draw_buffer_polygon_overlay(
    ctx: &CanvasRenderingContext2d,
    render: &serde_json::Value,
    model: &Model,
) {
    let name = render
        .get("buffer")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if name.is_empty() {
        return;
    }
    // Buffer points are in document-space; map to viewport pixels
    // here because the overlay draws post-restore (identity transform).
    let z = model.zoom_level;
    let ox = model.view_offset_x;
    let oy = model.view_offset_y;
    let points: Vec<(f64, f64)> =
        crate::interpreter::point_buffers::with_points(name, |pts| {
            pts.iter().map(|p| (p.0 * z + ox, p.1 * z + oy)).collect()
        });
    draw_closed_polygon_from_points(ctx, &points, render);
}

/// Draw an OPEN polyline — like buffer_polygon but without
/// close_path / fill. Used by Pencil's overlay: the user sees the raw
/// traced path while dragging, then the final fit_curve result lands
/// as a Bezier Path element on mouseup.
///
/// Optional `close_hint` field (expression or bool) — when truthy,
/// additionally draws a 1 px dashed line from the last buffer point
/// back to the first, indicating that a close-at-release would fire
/// right now (Paintbrush §Overlay → Close-at-release hint).
fn draw_buffer_polyline_overlay(
    ctx: &CanvasRenderingContext2d,
    render: &serde_json::Value,
    eval_ctx: &serde_json::Value,
    model: &Model,
) {
    let name = render
        .get("buffer")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if name.is_empty() {
        return;
    }
    // Buffer points are in document-space; map to viewport pixels
    // here because the overlay draws post-restore (identity transform).
    let z = model.zoom_level;
    let ox = model.view_offset_x;
    let oy = model.view_offset_y;
    let points: Vec<(f64, f64)> = crate::interpreter::point_buffers::with_points(
        name, |pts| pts.iter().map(|p| (p.0 * z + ox, p.1 * z + oy)).collect());
    if points.len() < 2 {
        return;
    }
    let style_str = render
        .get("style")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let style = parse_style(style_str);
    let Some(stroke) = &style.stroke else {
        return;
    };
    ctx.set_stroke_style_str(stroke);
    if let Some(w) = style.stroke_width {
        ctx.set_line_width(w);
    }
    if let Some(dash) = &style.stroke_dasharray {
        let arr = js_sys::Array::new();
        for d in dash {
            arr.push(&wasm_bindgen::JsValue::from_f64(*d));
        }
        let _ = ctx.set_line_dash(&arr);
    }
    ctx.begin_path();
    ctx.move_to(points[0].0, points[0].1);
    for p in &points[1..] {
        ctx.line_to(p.0, p.1);
    }
    ctx.stroke();
    if style.stroke_dasharray.is_some() {
        let _ = ctx.set_line_dash(&js_sys::Array::new());
    }

    // Close-at-release hint: dashed line from current cursor back to
    // press point when the `close_hint` field evaluates truthy.
    let hint_on = match render.get("close_hint") {
        None | Some(serde_json::Value::Null) => false,
        Some(serde_json::Value::Bool(b)) => *b,
        Some(serde_json::Value::String(s)) => {
            crate::interpreter::expr::eval(s, eval_ctx).to_bool()
        }
        _ => false,
    };
    if hint_on && points.len() >= 2 {
        let (sx, sy) = points[0];
        let (ex, ey) = *points.last().unwrap();
        ctx.set_stroke_style_str(stroke);
        ctx.set_line_width(1.0);
        let arr = js_sys::Array::new();
        arr.push(&wasm_bindgen::JsValue::from_f64(4.0));
        arr.push(&wasm_bindgen::JsValue::from_f64(4.0));
        let _ = ctx.set_line_dash(&arr);
        ctx.begin_path();
        ctx.move_to(ex, ey);
        ctx.line_to(sx, sy);
        ctx.stroke();
        let _ = ctx.set_line_dash(&js_sys::Array::new());
    }
}

/// Draw the Partial Selection tool's overlay:
///   - Blue 3px handle circles + connecting lines for every Bezier
///     handle on every selected Path in the document (this is what
///     the user clicks on to drag a handle).
///   - Blue rubber-band rectangle when `mode == "marquee"`.
/// Draw the Blob Brush tool's oval cursor + drag preview.
///
/// The `oval_cursor` render type has two responsibilities per
/// BLOB_BRUSH_TOOL.md §Overlay:
///   1. Hover cursor — draws an oval outline at (x, y) using the
///      effective tip shape (size/angle/roundness). When `dashed`
///      is truthy, the stroke is dashed to signal erase mode.
///   2. Drag preview — when `mode != "idle"`, renders accumulated
///      dabs from the buffer as semi-transparent filled ovals (for
///      painting) or dashed outlines (for erasing).
///
/// Fields (all optional unless noted):
///   x, y              current pointer position (required)
///   default_size      tip diameter in pt (fallback when no active brush)
///   default_angle     tip rotation in degrees (fallback)
///   default_roundness tip aspect percent (fallback)
///   stroke_color      outline color (defaults black)
///   dashed            boolean; erase-mode visual
///   buffer            point buffer name (for drag preview)
///   mode              string tool mode (idle / painting / erasing)
fn draw_oval_cursor_overlay(
    ctx: &CanvasRenderingContext2d,
    render: &serde_json::Value,
    eval_ctx: &serde_json::Value,
) {
    let cx = eval_number_field(eval_ctx, render.get("x"));
    let cy = eval_number_field(eval_ctx, render.get("y"));
    let size = eval_number_field(eval_ctx, render.get("default_size"))
        .max(1.0);
    let angle_deg = eval_number_field(eval_ctx, render.get("default_angle"));
    let roundness = eval_number_field(eval_ctx, render.get("default_roundness"))
        .max(1.0);
    let stroke_color = render.get("stroke_color")
        .and_then(|v| v.as_str())
        .unwrap_or("#000000")
        .to_string();
    let stroke_color = if stroke_color.is_empty() {
        "#000000".to_string()
    } else {
        stroke_color
    };
    // Expression fields may evaluate to a bool or a string literal.
    let eval_bool_render = |key: &str| -> bool {
        match render.get(key) {
            Some(serde_json::Value::Bool(b)) => *b,
            Some(serde_json::Value::String(s)) => {
                crate::interpreter::expr::eval(s, eval_ctx).to_bool()
            }
            _ => false,
        }
    };
    let dashed = eval_bool_render("dashed");
    let mode = render.get("mode")
        .and_then(|v| v.as_str())
        .map(|s| {
            // mode field may be an expression returning a string.
            if s.starts_with('\'') || s.starts_with('"') {
                s.trim_matches(|c: char| c == '\'' || c == '"').to_string()
            } else {
                match crate::interpreter::expr::eval(s, eval_ctx) {
                    crate::interpreter::expr_types::Value::Str(rs) => rs,
                    _ => s.to_string(),
                }
            }
        })
        .unwrap_or_else(|| "idle".to_string());

    let rx = size * 0.5;
    let ry = size * (roundness / 100.0) * 0.5;
    let rad = angle_deg * std::f64::consts::PI / 180.0;

    // Drag preview: if a buffer is named and mode != idle, draw
    // each buffered point as an oval. Painting = semi-transparent
    // fill; erasing = dashed outline.
    if mode != "idle" {
        if let Some(buffer_name) = render.get("buffer").and_then(|v| v.as_str()) {
            let pts: Vec<(f64, f64)> =
                crate::interpreter::point_buffers::with_points(
                    buffer_name, |p| p.to_vec());
            if pts.len() >= 2 {
                ctx.set_stroke_style_str(&stroke_color);
                ctx.set_fill_style_str(&stroke_color);
                ctx.set_line_width(1.0);
                let old_alpha = ctx.global_alpha();
                if mode == "painting" {
                    ctx.set_global_alpha(0.3);
                    for &(px, py) in &pts {
                        draw_oval_path(ctx, px, py, rx, ry, rad);
                        ctx.fill();
                    }
                    ctx.set_global_alpha(old_alpha);
                } else if mode == "erasing" {
                    let arr = js_sys::Array::new();
                    arr.push(&wasm_bindgen::JsValue::from_f64(3.0));
                    arr.push(&wasm_bindgen::JsValue::from_f64(3.0));
                    let _ = ctx.set_line_dash(&arr);
                    for &(px, py) in &pts {
                        draw_oval_path(ctx, px, py, rx, ry, rad);
                        ctx.stroke();
                    }
                    let _ = ctx.set_line_dash(&js_sys::Array::new());
                }
            }
        }
    }

    // Hover cursor at (cx, cy). Stroke is dashed when Alt is held
    // (erase-mode signal).
    ctx.set_stroke_style_str(&stroke_color);
    ctx.set_line_width(1.0);
    if dashed {
        let arr = js_sys::Array::new();
        arr.push(&wasm_bindgen::JsValue::from_f64(4.0));
        arr.push(&wasm_bindgen::JsValue::from_f64(4.0));
        let _ = ctx.set_line_dash(&arr);
    }
    draw_oval_path(ctx, cx, cy, rx, ry, rad);
    ctx.stroke();
    if dashed {
        let _ = ctx.set_line_dash(&js_sys::Array::new());
    }
    // 1 px screen-space crosshair for precision aiming.
    ctx.begin_path();
    ctx.move_to(cx - 3.0, cy);
    ctx.line_to(cx + 3.0, cy);
    ctx.move_to(cx, cy - 3.0);
    ctx.line_to(cx, cy + 3.0);
    ctx.stroke();
}

/// `cursor_color_chip` render type — a 12×12 px filled rectangle at
/// offset (+12, +12) from the cursor showing the cached
/// state.eyedropper_cache appearance. Visible only when the cache
/// is non-null and the eyedropper has seen the cursor at least once
/// (per the tool yaml's `if:` guard). See EYEDROPPER_TOOL.md
/// §Overlay.
///
/// Render fields:
///   x, y    cursor position (required, expression-evaluated).
///   cache   the cached Appearance JSON (expression yielding
///           state.eyedropper_cache; the renderer parses fill /
///           stroke from it).
fn draw_cursor_color_chip_overlay(
    ctx: &CanvasRenderingContext2d,
    render: &serde_json::Value,
    eval_ctx: &serde_json::Value,
) {
    let cx = eval_number_field(eval_ctx, render.get("x"));
    let cy = eval_number_field(eval_ctx, render.get("y"));

    // Resolve `cache:` — accept either an inline object or an
    // expression string of the form `state.<key>` (since the expr
    // evaluator returns objects as JSON strings, we read the
    // underlying serde value out of eval_ctx directly).
    let cache_value: serde_json::Value = match render.get("cache") {
        Some(serde_json::Value::String(expr)) => {
            // Strip leading `state.` and look up the key in eval_ctx.
            let key = expr.trim().strip_prefix("state.").unwrap_or(expr);
            eval_ctx
                .get("state")
                .and_then(|s| s.get(key))
                .cloned()
                .unwrap_or(serde_json::Value::Null)
        }
        Some(v) => v.clone(),
        None => return,
    };
    if cache_value.is_null() {
        return;
    }

    // Geometry: 12×12 chip at (+12, +12) offset from the cursor.
    let chip_x = cx + 12.0;
    let chip_y = cy + 12.0;
    let chip_w = 12.0;
    let chip_h = 12.0;

    // Fill: cache.fill.color when present (solid). Otherwise render
    // the standard none-glyph (white background with a red diagonal).
    let fill_color = cache_value
        .get("fill")
        .and_then(|f| f.as_object())
        .and_then(|f| f.get("color"));

    if let Some(color_val) = fill_color {
        let css = color_value_to_css(color_val);
        ctx.set_fill_style_str(&css);
        ctx.fill_rect(chip_x, chip_y, chip_w, chip_h);
    } else {
        // None-glyph: white square with a red diagonal slash.
        ctx.set_fill_style_str("#ffffff");
        ctx.fill_rect(chip_x, chip_y, chip_w, chip_h);
        ctx.set_stroke_style_str("#ff0000");
        ctx.set_line_width(1.5);
        ctx.begin_path();
        ctx.move_to(chip_x, chip_y + chip_h);
        ctx.line_to(chip_x + chip_w, chip_y);
        ctx.stroke();
    }

    // Border: 1 px outline from cache.stroke.color when solid;
    // otherwise a fixed neutral outline so the chip stays visible
    // against any canvas backdrop.
    let stroke_color = cache_value
        .get("stroke")
        .and_then(|s| s.as_object())
        .and_then(|s| s.get("color"));
    let border_css = match stroke_color {
        Some(color_val) => color_value_to_css(color_val),
        None => "#888888".to_string(),
    };
    ctx.set_stroke_style_str(&border_css);
    ctx.set_line_width(1.0);
    ctx.stroke_rect(chip_x + 0.5, chip_y + 0.5, chip_w - 1.0, chip_h - 1.0);
}

/// Convert a serialized `Color` JSON value (RGB(a) tuple or hex
/// string) to a CSS color string usable by canvas2d. Falls back to
/// solid black on parse failure.
fn color_value_to_css(v: &serde_json::Value) -> String {
    if let Some(s) = v.as_str() {
        return s.to_string();
    }
    if let Some(arr) = v.as_array()
        && arr.len() >= 3
    {
        let r = (arr[0].as_f64().unwrap_or(0.0) * 255.0).round() as u8;
        let g = (arr[1].as_f64().unwrap_or(0.0) * 255.0).round() as u8;
        let b = (arr[2].as_f64().unwrap_or(0.0) * 255.0).round() as u8;
        return format!("rgb({},{},{})", r, g, b);
    }
    if let Some(obj) = v.as_object() {
        let r = obj.get("r").and_then(|x| x.as_f64()).unwrap_or(0.0);
        let g = obj.get("g").and_then(|x| x.as_f64()).unwrap_or(0.0);
        let b = obj.get("b").and_then(|x| x.as_f64()).unwrap_or(0.0);
        let r = (r * 255.0).round() as u8;
        let g = (g * 255.0).round() as u8;
        let b = (b * 255.0).round() as u8;
        return format!("rgb({},{},{})", r, g, b);
    }
    "#000000".to_string()
}

/// Build a rotated ellipse path at (cx, cy) and add it to the
/// current path; caller decides whether to fill or stroke.
fn draw_oval_path(
    ctx: &CanvasRenderingContext2d,
    cx: f64, cy: f64, rx: f64, ry: f64, rad: f64,
) {
    const SEGMENTS: usize = 24;
    ctx.begin_path();
    for i in 0..=SEGMENTS {
        let t = 2.0 * std::f64::consts::PI * (i as f64) / (SEGMENTS as f64);
        let lx = rx * t.cos();
        let ly = ry * t.sin();
        let x = cx + lx * rad.cos() - ly * rad.sin();
        let y = cy + lx * rad.sin() + ly * rad.cos();
        if i == 0 {
            ctx.move_to(x, y);
        } else {
            ctx.line_to(x, y);
        }
    }
    ctx.close_path();
}

///
/// Fields:
///   mode: string — current tool mode
///   marquee_start_x/y, marquee_cur_x/y: marquee rect bounds
fn draw_partial_selection_overlay(
    ctx: &CanvasRenderingContext2d,
    render: &serde_json::Value,
    eval_ctx: &serde_json::Value,
    model: &crate::document::model::Model,
) {
    use crate::geometry::element::{
        control_points, path_handle_positions, Element,
    };
    let sel_color = "rgb(0,120,255)";
    let doc = model.document();
    for es in &doc.selection {
        if let Some(Element::Path(pe)) = doc.get_element(&es.path) {
            let anchors = control_points(&Element::Path(pe.clone()));
            for (ai, &(ax, ay)) in anchors.iter().enumerate() {
                let (h_in, h_out) = path_handle_positions(&pe.d, ai);
                for h in [h_in, h_out].iter().flatten() {
                    ctx.set_stroke_style_str(sel_color);
                    ctx.set_line_width(1.0);
                    ctx.begin_path();
                    ctx.move_to(ax, ay);
                    ctx.line_to(h.0, h.1);
                    ctx.stroke();

                    ctx.set_fill_style_str("white");
                    ctx.set_stroke_style_str(sel_color);
                    ctx.begin_path();
                    let _ = ctx.arc(h.0, h.1, 3.0, 0.0, std::f64::consts::TAU);
                    ctx.fill();
                    ctx.stroke();
                }
            }
        }
    }

    let mode = match render.get("mode") {
        Some(serde_json::Value::String(s)) => {
            match crate::interpreter::expr::eval(s, eval_ctx) {
                crate::interpreter::expr_types::Value::Str(v) => v,
                _ => String::new(),
            }
        }
        _ => String::new(),
    };
    if mode == "marquee" {
        let sx = eval_number_field(eval_ctx, render.get("marquee_start_x"));
        let sy = eval_number_field(eval_ctx, render.get("marquee_start_y"));
        let cx = eval_number_field(eval_ctx, render.get("marquee_cur_x"));
        let cy = eval_number_field(eval_ctx, render.get("marquee_cur_y"));
        let rx = sx.min(cx);
        let ry = sy.min(cy);
        let rw = (cx - sx).abs();
        let rh = (cy - sy).abs();
        ctx.set_stroke_style_str("rgba(0, 120, 215, 0.8)");
        ctx.set_fill_style_str("rgba(0, 120, 215, 0.1)");
        ctx.set_line_width(1.0);
        ctx.fill_rect(rx, ry, rw, rh);
        ctx.stroke_rect(rx, ry, rw, rh);
    }
}

/// Draw the Pen tool's in-progress overlay. Fields:
///   buffer: <anchor-buffer name>
///   mouse_x, mouse_y: current cursor (for the preview curve)
///   close_radius: px within which the cursor shows the close
///                 indicator (also decides the close-hit test)
///   placing: bool — true when not currently dragging a handle,
///            which is when the preview curve is drawn
///
/// Mirrors the inlined overlay logic from the deleted PenTool::draw_overlay.
fn draw_pen_overlay(
    ctx: &CanvasRenderingContext2d,
    render: &serde_json::Value,
    eval_ctx: &serde_json::Value,
    model: &Model,
) {
    let name = render
        .get("buffer")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if name.is_empty() {
        return;
    }
    // Anchors live in document-space (the buffer feeds add_path_from_anchor_buffer
    // directly); the overlay draws post-restore in viewport-pixel space, so each
    // coordinate has to go through the active view transform here.
    let z = model.zoom_level;
    let ox = model.view_offset_x;
    let oy = model.view_offset_y;
    let raw_anchors: Vec<crate::interpreter::anchor_buffers::Anchor> =
        crate::interpreter::anchor_buffers::with_anchors(name, |a| a.to_vec());
    if raw_anchors.is_empty() {
        return;
    }
    // Same shape as the buffered Anchor but in viewport pixels.
    let anchors: Vec<crate::interpreter::anchor_buffers::Anchor> = raw_anchors
        .iter()
        .map(|a| {
            let mut copy = a.clone();
            copy.x = a.x * z + ox;
            copy.y = a.y * z + oy;
            copy.hx_in = a.hx_in * z + ox;
            copy.hy_in = a.hy_in * z + oy;
            copy.hx_out = a.hx_out * z + ox;
            copy.hy_out = a.hy_out * z + oy;
            copy
        })
        .collect();
    // mouse_x / mouse_y in the YAML are now also doc-space (Pen
    // writes them from event.doc_x / event.doc_y), so convert here too.
    let mouse_x_doc = eval_number_field(eval_ctx, render.get("mouse_x"));
    let mouse_y_doc = eval_number_field(eval_ctx, render.get("mouse_y"));
    let mouse_x = mouse_x_doc * z + ox;
    let mouse_y = mouse_y_doc * z + oy;
    // close_radius stays in viewport pixels — the YAML supplies the
    // raw 8 here and we want it to feel constant on screen.
    let close_radius =
        eval_number_field(eval_ctx, render.get("close_radius")).max(1.0);
    let placing = match render.get("placing") {
        Some(serde_json::Value::String(s)) => {
            matches!(
                crate::interpreter::expr::eval(s, eval_ctx),
                crate::interpreter::expr_types::Value::Bool(true),
            )
        }
        Some(serde_json::Value::Bool(b)) => *b,
        _ => false,
    };

    // 1. Committed curves between consecutive anchors.
    if anchors.len() >= 2 {
        ctx.set_stroke_style_str("black");
        ctx.set_line_width(1.0);
        ctx.begin_path();
        ctx.move_to(anchors[0].x, anchors[0].y);
        for i in 1..anchors.len() {
            let prev = &anchors[i - 1];
            let curr = &anchors[i];
            ctx.bezier_curve_to(
                prev.hx_out, prev.hy_out,
                curr.hx_in,  curr.hy_in,
                curr.x, curr.y,
            );
        }
        ctx.stroke();
    }

    // 2. Preview curve from last anchor to mouse. Only when we're
    //    not dragging the last anchor's handle — during drag, the
    //    live-updating last anchor's handles already show the shape.
    if placing {
        let last = anchors.last().unwrap();
        let first = &anchors[0];
        let near_start = anchors.len() >= 2
            && (mouse_x - first.x).hypot(mouse_y - first.y) <= close_radius;

        ctx.set_stroke_style_str("rgb(100,100,100)");
        ctx.set_line_width(1.0);
        let dash = js_sys::Array::of2(&4.0.into(), &4.0.into());
        let _ = ctx.set_line_dash(&dash);

        ctx.begin_path();
        ctx.move_to(last.x, last.y);
        if near_start {
            ctx.bezier_curve_to(
                last.hx_out, last.hy_out,
                first.hx_in, first.hy_in,
                first.x, first.y,
            );
        } else {
            ctx.bezier_curve_to(
                last.hx_out, last.hy_out,
                mouse_x, mouse_y,
                mouse_x, mouse_y,
            );
        }
        ctx.stroke();
        let _ = ctx.set_line_dash(&js_sys::Array::new());
    }

    // 3. Handle lines + 4. Anchor squares.
    let sel_color = "rgb(0,120,255)";
    let handle_r = 3.0;
    let anchor_half = 5.0; // HANDLE_DRAW_SIZE / 2
    for a in &anchors {
        if a.smooth {
            ctx.set_stroke_style_str(sel_color);
            ctx.set_line_width(1.0);
            ctx.begin_path();
            ctx.move_to(a.hx_in, a.hy_in);
            ctx.line_to(a.hx_out, a.hy_out);
            ctx.stroke();

            ctx.set_fill_style_str("white");
            ctx.set_stroke_style_str(sel_color);
            ctx.begin_path();
            let _ = ctx.arc(
                a.hx_in, a.hy_in, handle_r,
                0.0, std::f64::consts::TAU,
            );
            ctx.fill();
            ctx.stroke();
            ctx.begin_path();
            let _ = ctx.arc(
                a.hx_out, a.hy_out, handle_r,
                0.0, std::f64::consts::TAU,
            );
            ctx.fill();
            ctx.stroke();
        }

        ctx.set_fill_style_str(sel_color);
        ctx.set_stroke_style_str(sel_color);
        ctx.fill_rect(
            a.x - anchor_half, a.y - anchor_half,
            anchor_half * 2.0, anchor_half * 2.0,
        );
        ctx.stroke_rect(
            a.x - anchor_half, a.y - anchor_half,
            anchor_half * 2.0, anchor_half * 2.0,
        );
    }

    // 5. Close indicator: green circle around the first anchor when
    //    the cursor is within close_radius of it.
    if anchors.len() >= 2 {
        let first = &anchors[0];
        if (mouse_x - first.x).hypot(mouse_y - first.y) <= close_radius {
            ctx.set_stroke_style_str("rgb(0,200,0)");
            ctx.set_line_width(2.0);
            ctx.begin_path();
            let _ = ctx.arc(
                first.x, first.y, anchor_half + 2.0,
                0.0, std::f64::consts::TAU,
            );
            ctx.stroke();
        }
    }
}

/// Draw a regular-N-gon overlay inscribed by a first-edge vector.
/// Fields: x1/y1/x2/y2 (the edge endpoints), sides (default 5),
/// style.
fn draw_regular_polygon_overlay(
    ctx: &CanvasRenderingContext2d,
    render: &serde_json::Value,
    eval_ctx: &serde_json::Value,
) {
    let x1 = eval_number_field(eval_ctx, render.get("x1"));
    let y1 = eval_number_field(eval_ctx, render.get("y1"));
    let x2 = eval_number_field(eval_ctx, render.get("x2"));
    let y2 = eval_number_field(eval_ctx, render.get("y2"));
    let sides = eval_number_field(eval_ctx, render.get("sides")) as usize;
    let sides = if sides == 0 { 5 } else { sides };
    let pts = crate::geometry::regular_shapes::regular_polygon_points(
        x1, y1, x2, y2, sides,
    );
    draw_closed_polygon_from_points(ctx, &pts, render);
}

/// Draw a star overlay inscribed in a bounding box. Fields:
/// x1/y1/x2/y2 (box corners), points (default 5 outer vertices),
/// style.
fn draw_star_overlay(
    ctx: &CanvasRenderingContext2d,
    render: &serde_json::Value,
    eval_ctx: &serde_json::Value,
) {
    let x1 = eval_number_field(eval_ctx, render.get("x1"));
    let y1 = eval_number_field(eval_ctx, render.get("y1"));
    let x2 = eval_number_field(eval_ctx, render.get("x2"));
    let y2 = eval_number_field(eval_ctx, render.get("y2"));
    let points_n = eval_number_field(eval_ctx, render.get("points")) as usize;
    let points_n = if points_n == 0 { 5 } else { points_n };
    let pts = crate::geometry::regular_shapes::star_points(
        x1, y1, x2, y2, points_n,
    );
    draw_closed_polygon_from_points(ctx, &pts, render);
}

/// Shared closed-polygon drawing: build a path from `points`, apply
/// fill/stroke style, and reset dash state if we set one. Shared by
/// the polygon and star overlay types — they differ only in how
/// points are computed.
fn draw_closed_polygon_from_points(
    ctx: &CanvasRenderingContext2d,
    points: &[(f64, f64)],
    render: &serde_json::Value,
) {
    if points.is_empty() {
        return;
    }
    let style_str = render
        .get("style")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let style = parse_style(style_str);

    let build_path = || {
        ctx.begin_path();
        ctx.move_to(points[0].0, points[0].1);
        for p in &points[1..] {
            ctx.line_to(p.0, p.1);
        }
        ctx.close_path();
    };

    if let Some(fill) = &style.fill {
        ctx.set_fill_style_str(fill);
        build_path();
        ctx.fill();
    }
    if let Some(stroke) = &style.stroke {
        ctx.set_stroke_style_str(stroke);
        if let Some(w) = style.stroke_width {
            ctx.set_line_width(w);
        }
        if let Some(dash) = &style.stroke_dasharray {
            let arr = js_sys::Array::new();
            for d in dash {
                arr.push(&wasm_bindgen::JsValue::from_f64(*d));
            }
            let _ = ctx.set_line_dash(&arr);
        }
        build_path();
        ctx.stroke();
        if style.stroke_dasharray.is_some() {
            let _ = ctx.set_line_dash(&js_sys::Array::new());
        }
    }
}

/// Begin + trace a rounded-rectangle path in the canvas context.
/// Matches native RoundedRectTool::draw_overlay: max-radius is clamped
/// to half the shorter side so the arcs don't overlap on small rects.
fn build_rounded_rect_path(
    ctx: &CanvasRenderingContext2d,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    rx: f64,
    ry: f64,
) {
    // SVG allows distinct rx / ry; native only uses one radius. Use
    // the stronger constraint of both for overlap-safe clamping.
    let r = rx.max(ry).min(w / 2.0).min(h / 2.0).max(0.0);
    ctx.begin_path();
    ctx.move_to(x + r, y);
    ctx.line_to(x + w - r, y);
    ctx.quadratic_curve_to(x + w, y, x + w, y + r);
    ctx.line_to(x + w, y + h - r);
    ctx.quadratic_curve_to(x + w, y + h, x + w - r, y + h);
    ctx.line_to(x + r, y + h);
    ctx.quadratic_curve_to(x, y + h, x, y + h - r);
    ctx.line_to(x, y + r);
    ctx.quadratic_curve_to(x, y, x + r, y);
    ctx.close_path();
}

/// Resolve the reference-point coordinate for a transform-tool
/// overlay. Reads the `ref_point` render field (a `Value::List` of
/// two numbers expressed as `state.transform_reference_point`) or,
/// when null, falls back to the selection's union bbox center.
/// Returns `None` when there is no selection — the caller skips
/// drawing in that case (matches SCALE_TOOL.md §Reference point §
/// Visibility).
fn resolve_overlay_reference_point(
    eval_ctx: &serde_json::Value,
    render: &serde_json::Value,
    model: &Model,
) -> Option<(f64, f64)> {
    use crate::algorithms::align;
    use crate::interpreter::expr_types::Value;
    // Custom reference point (state.transform_reference_point), if set.
    if let Some(field) = render.get("ref_point") {
        if let Some(expr) = field.as_str() {
            if let Value::List(items) = crate::interpreter::expr::eval(expr, eval_ctx) {
                if items.len() >= 2 {
                    if let (Some(rx), Some(ry)) = (items[0].as_f64(), items[1].as_f64()) {
                        return Some((rx, ry));
                    }
                }
            }
        }
    }
    // Fallback: selection union bbox center.
    let doc = model.document();
    let elements: Vec<&crate::geometry::element::Element> = doc.selection.iter()
        .filter_map(|es| doc.get_element(&es.path))
        .collect();
    if elements.is_empty() {
        return None;
    }
    let (x, y, w, h) = align::union_bounds(&elements, align::geometric_bounds);
    Some((x + w / 2.0, y + h / 2.0))
}

/// Draw the cyan-blue reference-point cross overlay used by Scale,
/// Rotate, and Shear. Per SCALE_TOOL.md §Reference-point cross
/// overlay: 12 px crosshair + 2 px center dot, color #4A9EFF.
/// Hidden when there is no selection.
fn draw_reference_point_cross(
    ctx: &CanvasRenderingContext2d,
    render: &serde_json::Value,
    eval_ctx: &serde_json::Value,
    model: &Model,
) {
    let Some((rx, ry)) = resolve_overlay_reference_point(eval_ctx, render, model) else {
        return;
    };
    const COLOR: &str = "#4A9EFF";
    const ARM: f64 = 6.0; // half-length → 12 px crosshair
    const DOT: f64 = 2.0;

    ctx.set_stroke_style_str(COLOR);
    ctx.set_line_width(1.0);
    // Horizontal arm.
    ctx.begin_path();
    ctx.move_to(rx - ARM, ry);
    ctx.line_to(rx + ARM, ry);
    ctx.stroke();
    // Vertical arm.
    ctx.begin_path();
    ctx.move_to(rx, ry - ARM);
    ctx.line_to(rx, ry + ARM);
    ctx.stroke();
    // Center dot.
    ctx.set_fill_style_str(COLOR);
    ctx.begin_path();
    let _ = ctx.arc(rx, ry, DOT, 0.0, std::f64::consts::TAU);
    ctx.fill();
}

/// Draw the dashed post-transform bounding-box ghost during a drag.
/// Reads `transform_kind` ("scale" / "rotate" / "shear"), the press
/// and cursor coordinates, and the shift_held flag from the render
/// dict, then composes the matrix via algorithms::transform_apply
/// and draws the union bbox of the selection under that matrix.
fn draw_bbox_ghost(
    ctx: &CanvasRenderingContext2d,
    render: &serde_json::Value,
    eval_ctx: &serde_json::Value,
    model: &Model,
) {
    use crate::algorithms::{align, transform_apply};
    use crate::geometry::element::Transform;

    let Some((rx, ry)) = resolve_overlay_reference_point(eval_ctx, render, model) else {
        return;
    };
    let kind = render.get("transform_kind")
        .and_then(|v| v.as_str())
        .map(|s| {
            // The yaml writes "'scale'" so the runtime treats it as a
            // string literal expression. Strip the wrapping quotes if
            // present.
            crate::interpreter::expr::eval(s, eval_ctx)
        })
        .map(|v| match v {
            crate::interpreter::expr_types::Value::Str(s) => s,
            _ => String::new(),
        })
        .unwrap_or_default();

    let px = eval_number_field(eval_ctx, render.get("press_x"));
    let py = eval_number_field(eval_ctx, render.get("press_y"));
    let cx = eval_number_field(eval_ctx, render.get("cursor_x"));
    let cy = eval_number_field(eval_ctx, render.get("cursor_y"));
    let shift = render.get("shift_held")
        .and_then(|v| v.as_str())
        .map(|s| crate::interpreter::expr::eval(s, eval_ctx).to_bool())
        .unwrap_or(false);

    // Build the matrix per the gesture's tool kind. Mirrors the
    // logic in interpreter::effects::doc.<tool>.apply but stays in
    // overlay-land — no document mutation.
    let matrix: Transform = match kind.as_str() {
        "scale" => {
            let denom_x = px - rx;
            let denom_y = py - ry;
            let sx = if denom_x.abs() < 1e-9 { 1.0 } else { (cx - rx) / denom_x };
            let sy = if denom_y.abs() < 1e-9 { 1.0 } else { (cy - ry) / denom_y };
            let (sx, sy) = if shift {
                let prod = sx * sy;
                let sign = if prod >= 0.0 { 1.0 } else { -1.0 };
                let mag = prod.abs().sqrt();
                let s = sign * mag;
                (s, s)
            } else { (sx, sy) };
            transform_apply::scale_matrix(sx, sy, rx, ry)
        }
        "rotate" => {
            let theta_press = (py - ry).atan2(px - rx);
            let theta_cursor = (cy - ry).atan2(cx - rx);
            let mut theta_deg = (theta_cursor - theta_press).to_degrees();
            if shift { theta_deg = (theta_deg / 45.0).round() * 45.0; }
            transform_apply::rotate_matrix(theta_deg, rx, ry)
        }
        "shear" => {
            let dx = cx - px;
            let dy = cy - py;
            if shift {
                if dx.abs() >= dy.abs() {
                    let denom = (py - ry).abs().max(1e-9);
                    let k = dx / denom;
                    transform_apply::shear_matrix(k.atan().to_degrees(), "horizontal", 0.0, rx, ry)
                } else {
                    let denom = (px - rx).abs().max(1e-9);
                    let k = dy / denom;
                    transform_apply::shear_matrix(k.atan().to_degrees(), "vertical", 0.0, rx, ry)
                }
            } else {
                let ax = px - rx;
                let ay = py - ry;
                let axis_len = (ax * ax + ay * ay).sqrt().max(1e-9);
                let perp_x = -ay / axis_len;
                let perp_y = ax / axis_len;
                let perp_dist = (cx - px) * perp_x + (cy - py) * perp_y;
                let k = perp_dist / axis_len;
                let axis_angle_deg = ay.atan2(ax).to_degrees();
                transform_apply::shear_matrix(k.atan().to_degrees(), "custom", axis_angle_deg, rx, ry)
            }
        }
        _ => Transform::IDENTITY,
    };

    // Compute the selection's pre-transform union bbox in document space.
    let doc = model.document();
    let elements: Vec<&crate::geometry::element::Element> = doc.selection.iter()
        .filter_map(|es| doc.get_element(&es.path))
        .collect();
    if elements.is_empty() {
        return;
    }
    let (bx, by, bw, bh) = align::union_bounds(&elements, align::geometric_bounds);

    // Transform the four corners and draw a closed quad.
    let corners = [
        matrix.apply_point(bx,        by),
        matrix.apply_point(bx + bw,   by),
        matrix.apply_point(bx + bw,   by + bh),
        matrix.apply_point(bx,        by + bh),
    ];

    ctx.set_stroke_style_str("#4A9EFF");
    ctx.set_line_width(1.0);
    let dash = js_sys::Array::new();
    dash.push(&wasm_bindgen::JsValue::from_f64(4.0));
    dash.push(&wasm_bindgen::JsValue::from_f64(2.0));
    let _ = ctx.set_line_dash(&dash);
    ctx.begin_path();
    ctx.move_to(corners[0].0, corners[0].1);
    for c in &corners[1..] {
        ctx.line_to(c.0, c.1);
    }
    ctx.close_path();
    ctx.stroke();
    // Reset dash so subsequent native strokes aren't unexpectedly dashed.
    let _ = ctx.set_line_dash(&js_sys::Array::new());
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
        assert_eq!(spec.overlay.len(), 1, "overlay should be present");
        let overlay = &spec.overlay[0];
        assert_eq!(
            overlay.guard.as_deref(),
            Some("tool.selection.mode == 'marquee'"),
        );
        assert_eq!(overlay.render["type"], serde_json::json!("rect"));
    }

    #[test]
    fn parses_overlay_list_form() {
        // Transform-tool family uses a list of {if, render} entries.
        let raw = serde_json::json!({
            "id": "scale",
            "handlers": {},
            "overlay": [
                { "if": "true", "render": { "type": "reference_point_cross" } },
                { "if": "tool.scale.mode == 'scaling'", "render": { "type": "bbox_ghost" } },
            ],
        });
        let spec = ToolSpec::from_workspace_tool(&raw).unwrap();
        assert_eq!(spec.overlay.len(), 2);
        assert_eq!(spec.overlay[0].render["type"], "reference_point_cross");
        assert_eq!(spec.overlay[1].render["type"], "bbox_ghost");
    }

    #[test]
    fn missing_overlay_becomes_empty() {
        let raw = serde_json::json!({ "id": "no_overlay" });
        let spec = ToolSpec::from_workspace_tool(&raw).unwrap();
        assert!(spec.overlay.is_empty());
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
        assert!(spec.overlay.is_empty());
    }

    #[test]
    fn overlay_without_render_is_rejected() {
        let raw = serde_json::json!({
            "id": "t",
            "overlay": { "if": "true" }
        });
        let spec = ToolSpec::from_workspace_tool(&raw).unwrap();
        assert!(spec.overlay.is_empty());
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
    fn yaml_tool_on_wheel_dispatches_when_handler_declared() {
        // Direct test of the YamlTool::on_wheel plumbing: any tool
        // YAML that declares an `on_wheel` handler receives the
        // dispatch payload with delta + modifiers. Wheel modifier
        // routing for the actual app (Alt zoom / Ctrl horizontal /
        // Cmd vertical) is in app.rs's on_wheel closure, not here.
        let raw = serde_json::json!({
            "id": "wheel_probe",
            "state": { "last_dy": { "default": 0.0 } },
            "handlers": {
                "on_wheel": [
                    { "set": { "tool.wheel_probe.last_dy": "event.delta_y" } }
                ]
            }
        });
        let spec = ToolSpec::from_workspace_tool(&raw).unwrap();
        let mut tool = YamlTool::new(spec);
        let mut model = Model::default();
        tool.on_wheel(&mut model, 0.0, 0.0, 0.0, -42.0, KeyMods::default());
        let observed = tool.tool_state("last_dy").as_f64();
        assert_eq!(
            observed,
            Some(-42.0),
            "on_wheel must dispatch with event.delta_y in payload",
        );
    }

    #[test]
    fn zoom_tool_scrubby_drag_uses_initial_view_state_from_tool_store() {
        // doc.zoom.scrubby anchors the new zoom + pan at the
        // pre-drag baseline, which it reads via
        // read_tool_zoom_state(store, ...). Bug: previously it
        // read from the dispatch ctx, which only carries
        // {event, active_document, preferences} -- no `tool`
        // namespace -- so initial_zoom defaulted to 1.0 and
        // initial_offx/y to 0.0, regardless of the model's
        // actual pre-drag view state. With view_offset != 0
        // (always the case post-center_view_on_current_artboard)
        // the very first scrubby move reanchored from the wrong
        // origin and the artboard "jumped".
        use crate::interpreter::workspace::Workspace;
        let ws = Workspace::load().expect("embedded workspace must parse");
        let zoom_spec = ws.data().get("tools").and_then(|t| t.get("zoom"))
            .expect("workspace must declare a zoom tool");
        let spec = ToolSpec::from_workspace_tool(zoom_spec).unwrap();
        let mut tool = YamlTool::new(spec);
        let mut model = Model::default();
        model.viewport_w = 800.0;
        model.viewport_h = 600.0;
        // Centered Letter would land here; what matters is that
        // these are the values the scrubby anchor must read back.
        model.zoom_level    = 1.0;
        model.view_offset_x = 100.0;
        model.view_offset_y = 50.0;

        tool.activate(&mut model);
        // Press at (200, 200), then move 1 px to start a drag
        // (still under the 4-px move threshold so no zoom yet),
        // then move past the threshold to trigger scrubby.
        tool.on_press(&mut model, 200.0, 200.0, false, false);
        tool.on_move(&mut model, 210.0, 200.0, false, false, true);

        // Sanity: the document point that was under the press
        // (in initial coordinates) should still be near the press
        // after the scrubby move. With initial_offx wrongly
        // defaulted to 0.0 the press anchor would land hundreds of
        // px off and the artboard "jumps".
        let z = model.zoom_level;
        let doc_x_under_press = (200.0 - model.view_offset_x) / z;
        let initial_doc_x_under_press = (200.0 - 100.0) / 1.0; // = 100
        assert!(
            (doc_x_under_press - initial_doc_x_under_press).abs() < 0.5,
            "scrubby should keep press anchored: doc_x under press now \
             {doc_x_under_press} vs initial {initial_doc_x_under_press} \
             (zoom={z}, off=({}, {}))",
            model.view_offset_x, model.view_offset_y,
        );
    }

    #[test]
    fn zoom_tool_click_dispatches_zoom_in_action() {
        // Reproduces the Zoom-tool click-to-zoom flow end-to-end:
        // on_mouseup with no significant motion fires
        // `dispatch: { action: zoom_in, params: {anchor_x, anchor_y} }`.
        // Without the workspace actions catalog plumbed into
        // YamlTool::dispatch, that dispatch silently no-ops and the
        // model's zoom_level stays at 1.0.
        use crate::interpreter::workspace::Workspace;
        let ws = Workspace::load().expect("embedded workspace must parse");
        let zoom_spec = ws.data().get("tools").and_then(|t| t.get("zoom"))
            .expect("workspace must declare a zoom tool");
        let spec = ToolSpec::from_workspace_tool(zoom_spec).unwrap();
        let mut tool = YamlTool::new(spec);
        let mut model = Model::default();
        model.viewport_w = 800.0;
        model.viewport_h = 600.0;
        let z_before = model.zoom_level;
        assert_eq!(z_before, 1.0, "default zoom is 1.0");

        // Activate the tool so on_enter seeds tool state defaults.
        tool.activate(&mut model);
        // Simulate a press-then-immediate-release at the same point
        // (no motion → click branch in on_mouseup).
        tool.on_press(&mut model, 100.0, 100.0, false, false);
        tool.on_release(&mut model, 100.0, 100.0, false, false);

        assert!(
            model.zoom_level > z_before,
            "click should zoom in; zoom_level={} (expected > 1.0)",
            model.zoom_level,
        );
    }

    #[test]
    fn hand_pan_uses_initial_view_offset_from_active_document() {
        // Reproduces the hand-tool drag flow: on_mousedown captures
        // active_document.view_offset_x as initial_offx; on_mousemove
        // doc.pan.apply uses initial + (cursor - press). After a 30 px
        // drag from a 100 px starting offset the new view_offset_x
        // must be 130, not 30 (which would mean the dispatch ctx
        // resolved active_document.view_offset_x to 0/Null).
        let raw = serde_json::json!({
            "id": "hand",
            "state": {
                "press_x":      { "default": 0.0 },
                "initial_offx": { "default": 0.0 },
            },
            "handlers": {
                "on_mousedown": [
                    { "set": { "tool.hand.press_x":      "event.x" } },
                    { "set": { "tool.hand.initial_offx": "active_document.view_offset_x" } }
                ],
                "on_mousemove": [
                    { "doc.pan.apply": {
                        "press_x":      "tool.hand.press_x",
                        "press_y":      "0.0",
                        "cursor_x":     "event.x",
                        "cursor_y":     "0.0",
                        "initial_offx": "tool.hand.initial_offx",
                        "initial_offy": "0.0",
                    }}
                ]
            }
        });
        let spec = ToolSpec::from_workspace_tool(&raw).unwrap();
        let mut tool = YamlTool::new(spec);
        let mut model = Model::default();
        model.view_offset_x = 100.0;

        tool.on_press(&mut model, 50.0, 0.0, false, false);
        tool.on_move(&mut model, 80.0, 0.0, false, false, true);

        assert_eq!(
            model.view_offset_x, 130.0,
            "view_offset_x should be initial (100) + drag delta (30)",
        );
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
        assert!(!parsed.overlay.is_empty(), "selection.yaml declares an overlay");
        // state_defaults should include 'mode' with a sensible default.
        assert_eq!(
            parsed.state_defaults.get("mode"),
            Some(&serde_json::json!("idle")),
        );
    }

    // ── Selection tool behavioral tests ────────────────────────────
    //
    // These started as Phase-4 parity ports of the six cases in
    // jas_dioxus/src/tools/selection_tool.rs::tests (since deleted in
    // Phase 5), plus Alt+drag cases added once that path lived in
    // selection.yaml. Run against a YamlTool constructed from the
    // actual selection.yaml — the only selection tool now. They
    // guard the canvas Selection UX against future YAML edits.
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
        // One-layer document with a single 20x20 rect at (50, 50).
        // Matches the fixture the deleted selection_tool.rs tests used.
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

    // ── parse_style (Phase 3d) ─────────────────────────────────────

    #[test]
    fn parse_style_empty_string() {
        let s = parse_style("");
        assert_eq!(s, OverlayStyle::default());
    }

    #[test]
    fn parse_style_extracts_stroke_and_fill() {
        let s = parse_style("stroke: #4a90d9; fill: rgba(74,144,217,0.08);");
        assert_eq!(s.stroke.as_deref(), Some("#4a90d9"));
        assert_eq!(s.fill.as_deref(), Some("rgba(74,144,217,0.08)"));
    }

    #[test]
    fn parse_style_extracts_stroke_width() {
        let s = parse_style("stroke: black; stroke-width: 1.5;");
        assert_eq!(s.stroke_width, Some(1.5));
    }

    #[test]
    fn parse_style_dasharray_space_separated() {
        let s = parse_style("stroke-dasharray: 4 4");
        assert_eq!(s.stroke_dasharray, Some(vec![4.0, 4.0]));
    }

    #[test]
    fn parse_style_dasharray_comma_separated() {
        let s = parse_style("stroke-dasharray: 2, 4, 6");
        assert_eq!(s.stroke_dasharray, Some(vec![2.0, 4.0, 6.0]));
    }

    #[test]
    fn parse_style_ignores_unknown_properties() {
        let s = parse_style("fill: red; some-unknown: value; stroke: blue;");
        assert_eq!(s.fill.as_deref(), Some("red"));
        assert_eq!(s.stroke.as_deref(), Some("blue"));
    }

    #[test]
    fn parse_style_ignores_malformed_rules() {
        // Missing colons, random whitespace — should not crash.
        let s = parse_style("fill: red; garbage-without-colon; stroke: blue; ;");
        assert_eq!(s.fill.as_deref(), Some("red"));
        assert_eq!(s.stroke.as_deref(), Some("blue"));
    }

    #[test]
    fn parse_style_selection_marquee_full() {
        // The real style string from selection.yaml.
        let s = parse_style(
            "stroke: #4a90d9; stroke-width: 1; \
             stroke-dasharray: 4 4; fill: rgba(74,144,217,0.08);",
        );
        assert_eq!(s.stroke.as_deref(), Some("#4a90d9"));
        assert_eq!(s.stroke_width, Some(1.0));
        assert_eq!(s.stroke_dasharray, Some(vec![4.0, 4.0]));
        assert_eq!(s.fill.as_deref(), Some("rgba(74,144,217,0.08)"));
    }

    #[test]
    fn parse_style_trims_whitespace_around_values() {
        let s = parse_style("stroke :   #000 ; fill :#fff;");
        assert_eq!(s.stroke.as_deref(), Some("#000"));
        assert_eq!(s.fill.as_deref(), Some("#fff"));
    }

    // ── eval_number_field for overlay geometry fields ──────────────

    #[test]
    fn eval_number_field_json_number() {
        let ctx = serde_json::json!({});
        assert_eq!(
            eval_number_field(&ctx, Some(&serde_json::json!(42))),
            42.0,
        );
    }

    #[test]
    fn eval_number_field_string_expr() {
        let ctx = serde_json::json!({ "tool": { "t": { "x": 17 } } });
        assert_eq!(
            eval_number_field(
                &ctx,
                Some(&serde_json::json!("tool.t.x")),
            ),
            17.0,
        );
    }

    #[test]
    fn eval_number_field_missing_is_zero() {
        let ctx = serde_json::json!({});
        assert_eq!(eval_number_field(&ctx, None), 0.0);
    }

    #[test]
    fn eval_number_field_non_number_result_is_zero() {
        let ctx = serde_json::json!({});
        assert_eq!(
            eval_number_field(&ctx, Some(&serde_json::json!("\"abc\""))),
            0.0,
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

    #[test]
    fn selection_parity_alt_drag_copies_element() {
        // Alt+drag: first move produces a copy at the drag offset and
        // re-selects the copy; subsequent moves translate the copy
        // further. The original stays where it was. The alt_held +
        // copied flag dance lives in selection.yaml's on_mousemove
        // handler (the deleted selection_tool.rs had it inline).
        let Some(mut tool) = selection_yaml_tool() else { return };
        let mut model = selection_parity_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        let children_before =
            model.document().layers[0].children().unwrap().len();
        // Press *with alt held*, two moves, release. End deltas are
        // the same as selection_parity_move_selection (dx=10, dy=10
        // cumulative), but the YAML handler branches into
        // doc.copy_selection on the first move because alt_held was
        // captured at press time.
        tool.on_press(&mut model, 60.0, 60.0, false, true);
        tool.on_move(&mut model, 65.0, 65.0, false, true, true);
        tool.on_move(&mut model, 70.0, 70.0, false, true, true);
        tool.on_release(&mut model, 70.0, 70.0, false, true);

        let children = model.document().layers[0].children().unwrap();
        assert_eq!(
            children.len(),
            children_before + 1,
            "alt+drag should have inserted exactly one copy",
        );

        // The original is at index 0, unchanged at (50, 50).
        if let Element::Rect(r) = &*children[0] {
            assert_eq!(r.x, 50.0, "original x should be unchanged");
            assert_eq!(r.y, 50.0, "original y should be unchanged");
        } else {
            panic!("expected Rect at index 0");
        }

        // The copy is at index 1, translated to (60, 60) — same end
        // position as selection_parity_move_selection. The copy
        // happens at (+5, +5) on the first move, then the second move
        // translates by (+5, +5) more.
        if let Element::Rect(r) = &*children[1] {
            assert_eq!(r.x, 60.0, "copy should be at dx=10 offset");
            assert_eq!(r.y, 60.0, "copy should be at dy=10 offset");
        } else {
            panic!("expected Rect at index 1 (the copy)");
        }

        // Selection is now the copy, not the original.
        let sel = &model.document().selection;
        assert_eq!(sel.len(), 1);
        assert_eq!(sel[0].path, vec![0, 1]);
    }

    // ── Rect tool behavioral tests ─────────────────────────────────
    //
    // Ports of the 4 cases in the deleted jas_dioxus/src/tools/rect_tool.rs
    // tests, run against a YamlTool constructed from workspace/tools/rect.yaml.
    // Native RectTool only committed the new rect on mouseup (with a
    // zero-size check) and used model.default_fill / default_stroke.
    // rect.yaml matches that flow — doc.add_element's fill/stroke
    // fallthrough pulls from the Model.

    fn rect_yaml_tool() -> Option<YamlTool> {
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
        let spec_json = ws.get("tools")?.get("rect")?;
        YamlTool::from_workspace_tool(spec_json)
    }

    fn empty_layer_model() -> Model {
        use crate::document::document::Document;
        use crate::geometry::element::LayerElem;
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![],
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

    #[test]
    fn rect_parity_draw_rect() {
        let Some(mut tool) = rect_yaml_tool() else { return };
        let mut model = empty_layer_model();
        // Press at (10, 20), drag to (110, 70), release: 100x50 rect
        // with top-left at (10, 20).
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_move(&mut model, 110.0, 70.0, false, false, true);
        tool.on_release(&mut model, 110.0, 70.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Rect(r) = &*children[0] {
            assert_eq!(r.x, 10.0);
            assert_eq!(r.y, 20.0);
            assert_eq!(r.width, 100.0);
            assert_eq!(r.height, 50.0);
        } else {
            panic!("expected Rect");
        }
    }

    #[test]
    fn rect_parity_zero_size_rect_not_created() {
        let Some(mut tool) = rect_yaml_tool() else { return };
        let mut model = empty_layer_model();
        // Press and release at the same point — no movement, no rect.
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_release(&mut model, 10.0, 20.0, false, false);
        assert_eq!(
            model.document().layers[0].children().unwrap().len(),
            0,
        );
    }

    #[test]
    fn rect_parity_negative_drag_normalizes() {
        let Some(mut tool) = rect_yaml_tool() else { return };
        let mut model = empty_layer_model();
        // Press at (100, 80), drag back to (10, 20). End rect should
        // be normalized to (10, 20, 90, 60).
        tool.on_press(&mut model, 100.0, 80.0, false, false);
        tool.on_move(&mut model, 10.0, 20.0, false, false, true);
        tool.on_release(&mut model, 10.0, 20.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Rect(r) = &*children[0] {
            assert_eq!(r.x, 10.0);
            assert_eq!(r.y, 20.0);
            assert_eq!(r.width, 90.0);
            assert_eq!(r.height, 60.0);
        } else {
            panic!("expected Rect");
        }
    }

    // ── Ellipse tool behavioral tests ──────────────────────────────
    //
    // Mirror the rect parity cases against workspace/tools/ellipse.yaml.
    // Ellipse fits the press→release bounding box: cx/cy at the center,
    // rx/ry at half each dimension. Zero-size click suppressed.

    fn ellipse_yaml_tool() -> Option<YamlTool> {
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
        let spec_json = ws.get("tools")?.get("ellipse")?;
        YamlTool::from_workspace_tool(spec_json)
    }

    #[test]
    fn ellipse_parity_draw_ellipse() {
        let Some(mut tool) = ellipse_yaml_tool() else { return };
        let mut model = empty_layer_model();
        // Press at (10, 20), drag to (110, 70), release: bbox is
        // 100×50; ellipse fits with cx=60, cy=45, rx=50, ry=25.
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_move(&mut model, 110.0, 70.0, false, false, true);
        tool.on_release(&mut model, 110.0, 70.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Ellipse(e) = &*children[0] {
            assert_eq!(e.cx, 60.0);
            assert_eq!(e.cy, 45.0);
            assert_eq!(e.rx, 50.0);
            assert_eq!(e.ry, 25.0);
        } else {
            panic!("expected Ellipse");
        }
    }

    #[test]
    fn ellipse_parity_zero_size_not_created() {
        let Some(mut tool) = ellipse_yaml_tool() else { return };
        let mut model = empty_layer_model();
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_release(&mut model, 10.0, 20.0, false, false);
        assert_eq!(
            model.document().layers[0].children().unwrap().len(),
            0,
        );
    }

    #[test]
    fn ellipse_parity_negative_drag_yields_positive_radii() {
        let Some(mut tool) = ellipse_yaml_tool() else { return };
        let mut model = empty_layer_model();
        // Press at (100, 80), drag back to (10, 20). Ellipse rx/ry must
        // be positive (abs of the deltas).
        tool.on_press(&mut model, 100.0, 80.0, false, false);
        tool.on_move(&mut model, 10.0, 20.0, false, false, true);
        tool.on_release(&mut model, 10.0, 20.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Ellipse(e) = &*children[0] {
            assert_eq!(e.cx, 55.0);
            assert_eq!(e.cy, 50.0);
            assert_eq!(e.rx, 45.0);
            assert_eq!(e.ry, 30.0);
        } else {
            panic!("expected Ellipse");
        }
    }

    // ── Partial Selection tool behavioral tests ──────────────────

    fn partial_selection_yaml_tool() -> Option<YamlTool> {
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
        let spec_json = ws.get("tools")?.get("partial_selection")?;
        YamlTool::from_workspace_tool(spec_json)
    }

    fn model_with_rect_element() -> Model {
        // Rect at (0, 0) 10x10 — control points:
        //   0 = (0, 0)   top-left
        //   1 = (10, 0)  top-right
        //   2 = (10, 10) bottom-right
        //   3 = (0, 10)  bottom-left
        model_with_rect_at(0.0, 0.0, 10.0, 10.0)
    }

    #[test]
    fn partial_selection_parity_click_on_cp_selects_it() {
        let Some(mut tool) = partial_selection_yaml_tool() else { return };
        let mut model = model_with_rect_element();
        // Click on CP 0 at (0, 0).
        tool.on_press(&mut model, 0.0, 0.0, false, false);
        tool.on_release(&mut model, 0.0, 0.0, false, false);
        let sel = &model.document().selection;
        assert_eq!(sel.len(), 1);
        assert_eq!(sel[0].path, vec![0, 0]);
        // The selection kind should include cp 0.
        assert!(sel[0].kind.contains(0));
        assert!(model.can_undo());
    }

    #[test]
    fn partial_selection_parity_click_empty_starts_marquee() {
        let Some(mut tool) = partial_selection_yaml_tool() else { return };
        let mut model = model_with_rect_element();
        // Click far from any CP.
        tool.on_press(&mut model, 500.0, 500.0, false, false);
        // Mode should be "marquee".
        assert_eq!(
            tool.tool_state("mode"),
            &serde_json::json!("marquee"),
        );
        // Release at a far position to commit the marquee.
        tool.on_release(&mut model, 600.0, 600.0, false, false);
        // No hits → no selection.
        assert!(model.document().selection.is_empty());
    }

    #[test]
    fn partial_selection_parity_marquee_picks_control_points() {
        let Some(mut tool) = partial_selection_yaml_tool() else { return };
        let mut model = model_with_rect_element();
        // Marquee covering the rect's CPs (all at 0 or 10 in x and y).
        tool.on_press(&mut model, -5.0, -5.0, false, false);
        tool.on_move(&mut model, 15.0, 15.0, false, false, true);
        tool.on_release(&mut model, 15.0, 15.0, false, false);
        // All 4 CPs of the rect should be selected (partial_select_rect
        // with extend=false replaces selection).
        let sel = &model.document().selection;
        assert_eq!(sel.len(), 1);
        assert_eq!(sel[0].path, vec![0, 0]);
    }

    // ── Path Eraser tool behavioral tests ─────────────────────────

    fn path_eraser_yaml_tool() -> Option<YamlTool> {
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
        let spec_json = ws.get("tools")?.get("path_eraser")?;
        YamlTool::from_workspace_tool(spec_json)
    }

    fn model_with_long_line_path() -> Model {
        use crate::document::document::Document;
        use crate::geometry::element::{
            LayerElem, PathCommand, PathElem, Color, Stroke,
        };
        let pe = PathElem {
            d: vec![
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::LineTo { x: 100.0, y: 0.0 },
            ],
            fill: None,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            width_points: vec![],
            common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
            stroke_brush: None, stroke_brush_overrides: None,
        };
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![std::rc::Rc::new(Element::Path(pe))],
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

    #[test]
    fn path_eraser_parity_splits_open_path() {
        let Some(mut tool) = path_eraser_yaml_tool() else { return };
        let mut model = model_with_long_line_path();
        // Press in the middle of the line at (50, 0) — should split
        // the line into two sub-paths.
        tool.on_press(&mut model, 50.0, 0.0, false, false);
        tool.on_release(&mut model, 50.0, 0.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(
            children.len(),
            2,
            "single line should split into 2 sub-paths",
        );
        assert!(model.can_undo());
    }

    #[test]
    fn path_eraser_parity_miss_does_nothing() {
        let Some(mut tool) = path_eraser_yaml_tool() else { return };
        let mut model = model_with_long_line_path();
        // Press far from the line.
        tool.on_press(&mut model, 500.0, 500.0, false, false);
        tool.on_release(&mut model, 500.0, 500.0, false, false);
        assert_eq!(
            model.document().layers[0].children().unwrap().len(),
            1,
            "miss should not change the path count",
        );
    }

    // ── Smooth tool behavioral tests ──────────────────────────────

    fn smooth_yaml_tool() -> Option<YamlTool> {
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
        let spec_json = ws.get("tools")?.get("smooth")?;
        YamlTool::from_workspace_tool(spec_json)
    }

    fn model_with_selected_zigzag_path() -> Model {
        use crate::document::document::{Document, ElementSelection};
        use crate::geometry::element::{
            Color, LayerElem, PathCommand, PathElem, Stroke,
        };
        let mut cmds = vec![PathCommand::MoveTo { x: 0.0, y: 0.0 }];
        for i in 1..=20 {
            let x = i as f64 * 5.0;
            let y = if i % 2 == 0 { 5.0 } else { -5.0 };
            cmds.push(PathCommand::LineTo { x, y });
        }
        let pe = PathElem {
            d: cmds,
            fill: None,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            width_points: vec![],
            common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
            stroke_brush: None, stroke_brush_overrides: None,
        };
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![std::rc::Rc::new(Element::Path(pe))],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        Model::new(
            Document {
                layers: vec![layer],
                selected_layer: 0,
                selection: vec![ElementSelection::all(vec![0, 0])],
                ..Document::default()
            },
            None,
        )
    }

    #[test]
    fn smooth_parity_reduces_commands_on_zigzag() {
        let Some(mut tool) = smooth_yaml_tool() else { return };
        let mut model = model_with_selected_zigzag_path();
        let original_len = {
            if let Element::Path(pe) =
                &*model.document().layers[0].children().unwrap()[0]
            {
                pe.d.len()
            } else {
                panic!("expected Path");
            }
        };
        // Smooth at the midpoint of the zigzag — radius 100 covers
        // the whole path.
        tool.on_press(&mut model, 50.0, 0.0, false, false);
        tool.on_release(&mut model, 50.0, 0.0, false, false);
        let new_len = {
            if let Element::Path(pe) =
                &*model.document().layers[0].children().unwrap()[0]
            {
                pe.d.len()
            } else {
                panic!("expected Path");
            }
        };
        assert!(
            new_len < original_len,
            "smooth should reduce command count on a zigzag (was {}, now {})",
            original_len, new_len,
        );
        assert!(model.can_undo());
    }

    #[test]
    fn smooth_parity_only_affects_selected_paths() {
        use crate::document::document::Document;
        // Unselected zigzag — smooth should do nothing.
        let mut model = model_with_selected_zigzag_path();
        let mut doc = model.document().clone();
        doc.selection.clear();
        model.set_document(doc);
        let original_len = {
            if let Element::Path(pe) =
                &*model.document().layers[0].children().unwrap()[0]
            {
                pe.d.len()
            } else {
                panic!("expected Path");
            }
        };
        let Some(mut tool) = smooth_yaml_tool() else { return };
        tool.on_press(&mut model, 50.0, 0.0, false, false);
        tool.on_release(&mut model, 50.0, 0.0, false, false);
        let new_len = {
            if let Element::Path(pe) =
                &*model.document().layers[0].children().unwrap()[0]
            {
                pe.d.len()
            } else {
                panic!("expected Path");
            }
        };
        assert_eq!(new_len, original_len);
        let _ = Document::default(); // keep the import used
    }

    // ── Add Anchor Point tool behavioral tests ────────────────────

    fn add_anchor_yaml_tool() -> Option<YamlTool> {
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
        let spec_json = ws.get("tools")?.get("add_anchor_point")?;
        YamlTool::from_workspace_tool(spec_json)
    }

    fn model_with_horizontal_line_path() -> Model {
        use crate::document::document::Document;
        use crate::geometry::element::{LayerElem, PathCommand, PathElem};
        let pe = PathElem {
            d: vec![
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::LineTo { x: 100.0, y: 0.0 },
            ],
            fill: None, stroke: None, width_points: vec![],
            common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
            stroke_brush: None, stroke_brush_overrides: None,
        };
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![std::rc::Rc::new(Element::Path(pe))],
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

    #[test]
    fn add_anchor_parity_click_on_line_inserts_midpoint() {
        use crate::geometry::element::{PathCommand, PathElem};
        let Some(mut tool) = add_anchor_yaml_tool() else { return };
        let mut model = model_with_horizontal_line_path();
        // Click at (50, 0) — exactly on the line at t=0.5.
        tool.on_press(&mut model, 50.0, 0.0, false, false);
        tool.on_release(&mut model, 50.0, 0.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        let pe: &PathElem = match &*children[0] {
            Element::Path(pe) => pe,
            _ => panic!("expected Path"),
        };
        // Should now have 3 commands: MoveTo, LineTo(mid), LineTo(end).
        assert_eq!(pe.d.len(), 3);
        if let PathCommand::LineTo { x, y } = pe.d[1] {
            assert!((x - 50.0).abs() < 0.01);
            assert!(y.abs() < 0.01);
        } else {
            panic!("expected inserted LineTo at midpoint");
        }
        assert!(model.can_undo());
    }

    #[test]
    fn add_anchor_parity_click_far_from_path_is_noop() {
        use crate::geometry::element::PathElem;
        let Some(mut tool) = add_anchor_yaml_tool() else { return };
        let mut model = model_with_horizontal_line_path();
        tool.on_press(&mut model, 500.0, 500.0, false, false);
        tool.on_release(&mut model, 500.0, 500.0, false, false);
        if let Element::Path(pe) = &*model.document().layers[0].children().unwrap()[0] {
            // Unchanged — still 2 commands.
            let pe: &PathElem = pe;
            assert_eq!(pe.d.len(), 2);
        }
        assert!(!model.can_undo());
    }

    #[test]
    fn add_anchor_parity_click_on_curve_splits_it() {
        use crate::geometry::element::{
            CommonProps, Element, LayerElem, PathCommand, PathElem,
        };
        use crate::document::document::Document;
        // Single cubic curve from (0,0) to (100,0) with symmetric handles.
        let pe = PathElem {
            d: vec![
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::CurveTo {
                    x1: 25.0, y1: 50.0,
                    x2: 75.0, y2: 50.0,
                    x: 100.0, y: 0.0,
                },
            ],
            fill: None, stroke: None, width_points: vec![],
            common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
            stroke_brush: None, stroke_brush_overrides: None,
        };
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![std::rc::Rc::new(Element::Path(pe))],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let mut model = Model::new(
            Document {
                layers: vec![layer],
                selected_layer: 0,
                selection: Vec::new(),
                ..Document::default()
            },
            None,
        );
        let Some(mut tool) = add_anchor_yaml_tool() else { return };
        // Click near the curve's midpoint at t=0.5.
        let (mid_x, mid_y) =
            crate::geometry::path_ops::eval_cubic(
                0.0, 0.0, 25.0, 50.0, 75.0, 50.0, 100.0, 0.0, 0.5);
        tool.on_press(&mut model, mid_x, mid_y, false, false);
        tool.on_release(&mut model, mid_x, mid_y, false, false);
        let children = model.document().layers[0].children().unwrap();
        let pe: &PathElem = match &*children[0] {
            Element::Path(pe) => pe,
            _ => panic!("expected Path"),
        };
        // Should have MoveTo + 2 CurveTos (split into halves).
        assert_eq!(pe.d.len(), 3);
        assert!(matches!(pe.d[1], PathCommand::CurveTo { .. }));
        assert!(matches!(pe.d[2], PathCommand::CurveTo { .. }));
        // First CurveTo endpoint should be the mid-point.
        if let PathCommand::CurveTo { x, y, .. } = pe.d[1] {
            assert!((x - mid_x).abs() < 0.1);
            assert!((y - mid_y).abs() < 0.1);
        }
    }

    // ── Anchor Point tool behavioral tests ────────────────────────

    fn anchor_point_yaml_tool() -> Option<YamlTool> {
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
        let spec_json = ws.get("tools")?.get("anchor_point")?;
        YamlTool::from_workspace_tool(spec_json)
    }

    fn model_with_smooth_three_anchor_path() -> Model {
        use crate::document::document::Document;
        use crate::geometry::element::{LayerElem, PathCommand, PathElem};
        let pe = PathElem {
            d: vec![
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::CurveTo {
                    x1: 10.0, y1: 20.0, x2: 40.0, y2: 20.0,
                    x: 50.0, y: 0.0,
                },
                PathCommand::CurveTo {
                    x1: 60.0, y1: -20.0, x2: 90.0, y2: -20.0,
                    x: 100.0, y: 0.0,
                },
            ],
            fill: None,
            stroke: None,
            width_points: vec![],
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
            stroke_brush: None,
            stroke_brush_overrides: None,
        };
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![std::rc::Rc::new(Element::Path(pe))],
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

    #[test]
    fn anchor_point_parity_click_smooth_makes_corner() {
        use crate::geometry::element::{is_smooth_point, PathElem};
        let Some(mut tool) = anchor_point_yaml_tool() else { return };
        let mut model = model_with_smooth_three_anchor_path();
        // Smooth anchor lives at (50, 0) — click without drag.
        tool.on_press(&mut model, 50.0, 0.0, false, false);
        tool.on_release(&mut model, 50.0, 0.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        let pe: &PathElem = match &*children[0] {
            Element::Path(pe) => pe,
            _ => panic!("expected Path"),
        };
        assert!(
            !is_smooth_point(&pe.d, 1),
            "click on smooth anchor should convert it to corner",
        );
        assert!(model.can_undo());
    }

    #[test]
    fn anchor_point_parity_drag_handle_moves_it() {
        use crate::geometry::element::{PathCommand, PathElem};
        let Some(mut tool) = anchor_point_yaml_tool() else { return };
        let mut model = model_with_smooth_three_anchor_path();
        // Outgoing handle of anchor 1 at (60, -20) — drag it by (+10, +5).
        tool.on_press(&mut model, 60.0, -20.0, false, false);
        tool.on_release(&mut model, 70.0, -15.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        let pe: &PathElem = match &*children[0] {
            Element::Path(pe) => pe,
            _ => panic!("expected Path"),
        };
        // x1 of cmd[2] (the outgoing handle of anchor 1) should now
        // be (70, -15); x2 of cmd[1] (the incoming handle of anchor 1)
        // should be UNCHANGED at (40, 20) — independent move.
        if let PathCommand::CurveTo { x1, y1, .. } = pe.d[2] {
            assert!((x1 - 70.0).abs() < 0.01);
            assert!((y1 - (-15.0)).abs() < 0.01);
        }
        if let PathCommand::CurveTo { x2, y2, .. } = pe.d[1] {
            assert!((x2 - 40.0).abs() < 0.01);
            assert!((y2 - 20.0).abs() < 0.01);
        }
    }

    #[test]
    fn anchor_point_parity_drag_corner_pulls_out_smooth_handles() {
        use crate::geometry::element::{
            is_smooth_point, LayerElem, PathCommand, PathElem,
        };
        use crate::document::document::Document;
        // Start with a CORNER anchor path (all LineTos).
        let pe = PathElem {
            d: vec![
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::LineTo { x: 50.0, y: 0.0 },
                PathCommand::LineTo { x: 100.0, y: 0.0 },
            ],
            fill: None, stroke: None, width_points: vec![],
            common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
            stroke_brush: None, stroke_brush_overrides: None,
        };
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![std::rc::Rc::new(Element::Path(pe))],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let mut model = Model::new(
            Document {
                layers: vec![layer],
                selected_layer: 0,
                selection: Vec::new(),
                ..Document::default()
            },
            None,
        );
        let Some(mut tool) = anchor_point_yaml_tool() else { return };
        // Corner anchor at (50, 0). Press there, drag to (50, 30).
        tool.on_press(&mut model, 50.0, 0.0, false, false);
        tool.on_release(&mut model, 50.0, 30.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        let pe: &PathElem = match &*children[0] {
            Element::Path(pe) => pe,
            _ => panic!("expected Path"),
        };
        // Anchor 1 should now be smooth.
        assert!(is_smooth_point(&pe.d, 1));
    }

    #[test]
    fn anchor_point_parity_click_without_hit_is_noop() {
        let Some(mut tool) = anchor_point_yaml_tool() else { return };
        let mut model = model_with_smooth_three_anchor_path();
        tool.on_press(&mut model, 500.0, 500.0, false, false);
        tool.on_release(&mut model, 500.0, 500.0, false, false);
        assert!(!model.can_undo());
    }

    // ── Delete Anchor Point tool behavioral tests ────────────────

    use crate::geometry::element::{PathCommand, PathElem};

    fn delete_anchor_yaml_tool() -> Option<YamlTool> {
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
        let spec_json = ws.get("tools")?.get("delete_anchor_point")?;
        YamlTool::from_workspace_tool(spec_json)
    }

    fn model_with_four_anchor_path() -> Model {
        use crate::document::document::Document;
        use crate::geometry::element::LayerElem;
        let pe = PathElem {
            d: vec![
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::CurveTo {
                    x1: 10.0, y1: 0.0, x2: 20.0, y2: 0.0,
                    x: 30.0, y: 0.0,
                },
                PathCommand::CurveTo {
                    x1: 40.0, y1: 0.0, x2: 50.0, y2: 0.0,
                    x: 60.0, y: 0.0,
                },
                PathCommand::CurveTo {
                    x1: 70.0, y1: 0.0, x2: 80.0, y2: 0.0,
                    x: 90.0, y: 0.0,
                },
            ],
            fill: None,
            stroke: None,
            width_points: vec![],
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
            stroke_brush: None,
            stroke_brush_overrides: None,
        };
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![std::rc::Rc::new(Element::Path(pe))],
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

    #[test]
    fn delete_anchor_parity_click_on_interior_removes_anchor() {
        let Some(mut tool) = delete_anchor_yaml_tool() else { return };
        let mut model = model_with_four_anchor_path();
        // Click on the anchor at (60, 0) — command index 2.
        tool.on_press(&mut model, 60.0, 0.0, false, false);
        tool.on_release(&mut model, 60.0, 0.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1, "path should still exist");
        if let Element::Path(pe) = &*children[0] {
            // Should go from 4 anchors to 3.
            assert_eq!(pe.d.len(), 3);
        } else {
            panic!("expected Path");
        }
        assert!(model.can_undo(), "delete should be undoable");
    }

    #[test]
    fn delete_anchor_parity_click_empty_is_noop() {
        let Some(mut tool) = delete_anchor_yaml_tool() else { return };
        let mut model = model_with_four_anchor_path();
        tool.on_press(&mut model, 500.0, 500.0, false, false);
        tool.on_release(&mut model, 500.0, 500.0, false, false);
        // Path unchanged, no undo snapshot.
        if let Element::Path(pe) = &*model.document().layers[0].children().unwrap()[0] {
            assert_eq!(pe.d.len(), 4);
        }
        assert!(!model.can_undo());
    }

    // ── Pen tool behavioral tests ──────────────────────────────────
    //
    // Native PenTool had no unit tests. These cover the externally-
    // observable outcomes: click-click-click creates a polyline,
    // click-drag creates a smooth curve, click-near-first closes,
    // double-click and Escape commit open.

    use crate::tools::tool::KeyMods;

    fn pen_yaml_tool() -> Option<YamlTool> {
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
        let spec_json = ws.get("tools")?.get("pen")?;
        YamlTool::from_workspace_tool(spec_json)
    }

    #[test]
    fn pen_parity_three_clicks_then_double_click_creates_polyline() {
        use crate::geometry::element::PathCommand;
        let Some(mut tool) = pen_yaml_tool() else { return };
        let mut model = empty_layer_model();
        // Click, click, click — each mouseup lands mode=placing and
        // leaves the anchor in the buffer. Handles stay at anchor
        // position (corner anchors).
        tool.on_press(&mut model, 10.0, 10.0, false, false);
        tool.on_release(&mut model, 10.0, 10.0, false, false);
        tool.on_press(&mut model, 50.0, 10.0, false, false);
        tool.on_release(&mut model, 50.0, 10.0, false, false);
        tool.on_press(&mut model, 50.0, 50.0, false, false);
        tool.on_release(&mut model, 50.0, 50.0, false, false);
        // Double-click (the second press pushed a fourth anchor; the
        // dblclick handler pops it, leaving 3 anchors).
        tool.on_press(&mut model, 50.0, 50.0, false, false);
        tool.on_release(&mut model, 50.0, 50.0, false, false);
        tool.on_double_click(&mut model, 50.0, 50.0);

        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Path(pe) = &*children[0] {
            // MoveTo + 2 CurveTos (3 anchors -> 2 segments). No
            // ClosePath because dblclick commits open.
            assert_eq!(pe.d.len(), 3);
            assert!(matches!(pe.d[0], PathCommand::MoveTo { x: 10.0, y: 10.0 }));
            assert!(matches!(pe.d[1], PathCommand::CurveTo { .. }));
            assert!(matches!(pe.d[2], PathCommand::CurveTo { .. }));
            assert!(!matches!(pe.d.last().unwrap(), PathCommand::ClosePath));
        } else {
            panic!("expected Path");
        }
    }

    #[test]
    fn pen_parity_click_drag_sets_out_handle() {
        use crate::geometry::element::PathCommand;
        let Some(mut tool) = pen_yaml_tool() else { return };
        let mut model = empty_layer_model();
        // First anchor: click + drag out to (60, 10). on_mousemove
        // sets the handle; first anchor's out = (60, 10), in mirrors
        // to (-40, 10).
        tool.on_press(&mut model, 10.0, 10.0, false, false);
        tool.on_move(&mut model, 60.0, 10.0, false, false, true);
        tool.on_release(&mut model, 60.0, 10.0, false, false);
        // Second anchor: plain click at (50, 50).
        tool.on_press(&mut model, 50.0, 50.0, false, false);
        tool.on_release(&mut model, 50.0, 50.0, false, false);
        // Escape commits open — testing the on_keydown path too.
        tool.on_key_event(&mut model, "Escape", KeyMods::default());

        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Path(pe) = &*children[0] {
            // d[0] = MoveTo(10,10); d[1] = CurveTo(prev_out=(60,10),
            // curr_in=(50,50), curr=(50,50)) because second anchor
            // is a corner.
            assert_eq!(pe.d.len(), 2);
            if let PathCommand::CurveTo { x1, y1, x, y, .. } = pe.d[1] {
                assert_eq!(x1, 60.0, "prev anchor out-handle x");
                assert_eq!(y1, 10.0, "prev anchor out-handle y");
                assert_eq!(x, 50.0);
                assert_eq!(y, 50.0);
            } else {
                panic!("expected CurveTo");
            }
        }
    }

    #[test]
    fn pen_parity_click_near_first_closes() {
        use crate::geometry::element::PathCommand;
        let Some(mut tool) = pen_yaml_tool() else { return };
        let mut model = empty_layer_model();
        // Three corner anchors.
        tool.on_press(&mut model, 10.0, 10.0, false, false);
        tool.on_release(&mut model, 10.0, 10.0, false, false);
        tool.on_press(&mut model, 50.0, 10.0, false, false);
        tool.on_release(&mut model, 50.0, 10.0, false, false);
        tool.on_press(&mut model, 50.0, 50.0, false, false);
        tool.on_release(&mut model, 50.0, 50.0, false, false);
        // Fourth click within 8 px of the first anchor (10, 10).
        tool.on_press(&mut model, 11.0, 11.0, false, false);
        tool.on_release(&mut model, 11.0, 11.0, false, false);

        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1, "should commit on close-click");
        if let Element::Path(pe) = &*children[0] {
            // Should end with ClosePath.
            assert!(matches!(
                pe.d.last().unwrap(),
                PathCommand::ClosePath,
            ));
        }
    }

    #[test]
    fn pen_parity_escape_via_on_key_commits() {
        // Regression guard for workspace::keyboard's Escape/Enter
        // path — it calls tool.on_key(), NOT tool.on_key_event().
        // A YamlTool that only overrode on_key_event would miss
        // Escape entirely (dx serve bug surfaced this).
        use crate::geometry::element::PathCommand;
        let Some(mut tool) = pen_yaml_tool() else { return };
        let mut model = empty_layer_model();
        tool.on_press(&mut model, 10.0, 10.0, false, false);
        tool.on_release(&mut model, 10.0, 10.0, false, false);
        tool.on_press(&mut model, 50.0, 50.0, false, false);
        tool.on_release(&mut model, 50.0, 50.0, false, false);
        // Using on_key (NOT on_key_event) — the shell's actual call path.
        tool.on_key(&mut model, "Escape");

        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Path(pe) = &*children[0] {
            assert!(matches!(pe.d[0], PathCommand::MoveTo { .. }));
            assert!(!matches!(pe.d.last().unwrap(), PathCommand::ClosePath));
        }
    }

    #[test]
    fn pen_parity_escape_without_enough_anchors_discards() {
        let Some(mut tool) = pen_yaml_tool() else { return };
        let mut model = empty_layer_model();
        // One anchor — not enough to make a path.
        tool.on_press(&mut model, 10.0, 10.0, false, false);
        tool.on_release(&mut model, 10.0, 10.0, false, false);
        tool.on_key_event(&mut model, "Escape", KeyMods::default());
        assert_eq!(
            model.document().layers[0].children().unwrap().len(),
            0,
            "single anchor should not produce a path",
        );
    }

    // ── Pencil tool behavioral tests ───────────────────────────────

    fn pencil_yaml_tool() -> Option<YamlTool> {
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
        let spec_json = ws.get("tools")?.get("pencil")?;
        YamlTool::from_workspace_tool(spec_json)
    }

    #[test]
    fn pencil_parity_freehand_draw_creates_path() {
        use crate::geometry::element::PathCommand;
        let Some(mut tool) = pencil_yaml_tool() else { return };
        let mut model = empty_layer_model();
        tool.on_press(&mut model, 0.0, 0.0, false, false);
        for i in 1..=20 {
            let x = i as f64 * 5.0;
            let y = (i as f64 * 0.1).sin() * 20.0;
            tool.on_move(&mut model, x, y, false, false, true);
        }
        tool.on_release(&mut model, 100.0, 0.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        match &*children[0] {
            Element::Path(pe) => {
                assert!(
                    pe.d.len() >= 2,
                    "path should have MoveTo + at least one CurveTo",
                );
                assert!(matches!(pe.d[0], PathCommand::MoveTo { .. }));
                for cmd in &pe.d[1..] {
                    assert!(matches!(cmd, PathCommand::CurveTo { .. }));
                }
            }
            _ => panic!("expected Path element"),
        }
    }

    #[test]
    fn pencil_parity_click_without_drag_creates_degenerate_path() {
        let Some(mut tool) = pencil_yaml_tool() else { return };
        let mut model = empty_layer_model();
        // Press + release at same point — on_release pushes the final
        // point, giving the buffer 2 identical points. fit_curve
        // returns 1 degenerate segment, which still lands a Path.
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_release(&mut model, 10.0, 20.0, false, false);
        assert_eq!(
            model.document().layers[0].children().unwrap().len(),
            1,
        );
    }

    #[test]
    fn pencil_parity_path_uses_model_defaults() {
        let Some(mut tool) = pencil_yaml_tool() else { return };
        let mut model = empty_layer_model();
        tool.on_press(&mut model, 0.0, 0.0, false, false);
        tool.on_move(&mut model, 50.0, 50.0, false, false, true);
        tool.on_release(&mut model, 100.0, 0.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        if let Element::Path(pe) = &*children[0] {
            assert!(pe.stroke.is_some(), "pencil path should have a stroke");
            assert!(pe.fill.is_none(), "pencil path should have no fill");
        } else {
            panic!("expected Path element");
        }
    }

    #[test]
    fn pencil_parity_release_without_press_is_noop() {
        let Some(mut tool) = pencil_yaml_tool() else { return };
        let mut model = empty_layer_model();
        tool.on_release(&mut model, 50.0, 60.0, false, false);
        assert_eq!(
            model.document().layers[0].children().unwrap().len(),
            0,
        );
    }

    #[test]
    fn pencil_parity_path_starts_at_press_point() {
        use crate::geometry::element::PathCommand;
        let Some(mut tool) = pencil_yaml_tool() else { return };
        let mut model = empty_layer_model();
        tool.on_press(&mut model, 15.0, 25.0, false, false);
        tool.on_move(&mut model, 50.0, 50.0, false, false, true);
        tool.on_release(&mut model, 100.0, 0.0, false, false);
        if let Element::Path(pe) =
            &*model.document().layers[0].children().unwrap()[0]
        {
            if let PathCommand::MoveTo { x, y } = pe.d[0] {
                assert_eq!(x, 15.0);
                assert_eq!(y, 25.0);
            } else {
                panic!("first command should be MoveTo");
            }
        }
    }

    // ── Lasso tool behavioral tests ────────────────────────────────

    fn lasso_yaml_tool() -> Option<YamlTool> {
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
        let spec_json = ws.get("tools")?.get("lasso")?;
        YamlTool::from_workspace_tool(spec_json)
    }

    fn selection_parity_model_for_lasso() -> Model {
        // Single rect at (50, 50, 20, 20). Matches the fixture the
        // deleted lasso_tool.rs tests used.
        model_with_rect_at(50.0, 50.0, 20.0, 20.0)
    }

    #[test]
    fn lasso_parity_lasso_select() {
        let Some(mut tool) = lasso_yaml_tool() else { return };
        let mut model = selection_parity_model_for_lasso();
        // Polygon enclosing the rect.
        tool.on_press(&mut model, 40.0, 40.0, false, false);
        tool.on_move(&mut model, 80.0, 40.0, false, false, true);
        tool.on_move(&mut model, 80.0, 80.0, false, false, true);
        tool.on_move(&mut model, 40.0, 80.0, false, false, true);
        tool.on_release(&mut model, 40.0, 80.0, false, false);
        assert!(!model.document().selection.is_empty());
    }

    #[test]
    fn lasso_parity_lasso_miss() {
        let Some(mut tool) = lasso_yaml_tool() else { return };
        let mut model = selection_parity_model_for_lasso();
        // Polygon nowhere near the rect.
        tool.on_press(&mut model, 0.0, 0.0, false, false);
        tool.on_move(&mut model, 10.0, 0.0, false, false, true);
        tool.on_move(&mut model, 10.0, 10.0, false, false, true);
        tool.on_move(&mut model, 0.0, 10.0, false, false, true);
        tool.on_release(&mut model, 0.0, 10.0, false, false);
        assert!(model.document().selection.is_empty());
    }

    #[test]
    fn lasso_parity_click_without_drag_clears() {
        let Some(mut tool) = lasso_yaml_tool() else { return };
        let mut model = selection_parity_model_for_lasso();
        Controller::select_element(&mut model, &vec![0, 0]);
        assert!(!model.document().selection.is_empty());
        // Press + release at same point, no shift — buffer has 1 point,
        // fewer than 3 → falls into "clear selection" branch.
        tool.on_press(&mut model, 5.0, 5.0, false, false);
        tool.on_release(&mut model, 5.0, 5.0, false, false);
        assert!(model.document().selection.is_empty());
    }

    #[test]
    fn lasso_parity_click_without_drag_shift_preserves() {
        let Some(mut tool) = lasso_yaml_tool() else { return };
        let mut model = selection_parity_model_for_lasso();
        Controller::select_element(&mut model, &vec![0, 0]);
        // Shift+click without drag — shift_held captured at press,
        // the "clear selection" else-branch is guarded by not
        // shift_held so nothing happens.
        tool.on_press(&mut model, 5.0, 5.0, true, false);
        tool.on_release(&mut model, 5.0, 5.0, true, false);
        assert!(!model.document().selection.is_empty());
    }

    #[test]
    fn lasso_parity_state_transitions() {
        let Some(mut tool) = lasso_yaml_tool() else { return };
        let mut model = selection_parity_model_for_lasso();
        assert_eq!(tool.tool_state("mode"), &serde_json::json!("idle"));
        tool.on_press(&mut model, 10.0, 10.0, false, false);
        assert_eq!(tool.tool_state("mode"), &serde_json::json!("drawing"));
        tool.on_release(&mut model, 10.0, 10.0, false, false);
        assert_eq!(tool.tool_state("mode"), &serde_json::json!("idle"));
    }

    // ── Interior Selection tool behavioral tests ──────────────────
    //
    // The native tool had no unit tests; these check the basic shape
    // of interior selection — recursing into groups on click, and
    // partial-style selection on marquee.

    fn interior_selection_yaml_tool() -> Option<YamlTool> {
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
        let spec_json = ws.get("tools")?.get("interior_selection")?;
        YamlTool::from_workspace_tool(spec_json)
    }

    fn model_with_rect_inside_group() -> Model {
        use crate::document::document::Document;
        use crate::geometry::element::{GroupElem, LayerElem};
        let rect = Element::Rect(RectElem {
            x: 50.0, y: 50.0, width: 20.0, height: 20.0,
            rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        });
        let group = Element::Group(GroupElem {
            children: vec![std::rc::Rc::new(rect)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![std::rc::Rc::new(group)],
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

    #[test]
    fn interior_selection_parity_click_enters_group() {
        let Some(mut tool) = interior_selection_yaml_tool() else { return };
        let mut model = model_with_rect_inside_group();
        // Click inside the rect (which lives at layer[0]/group[0]/rect[0]).
        tool.on_press(&mut model, 55.0, 55.0, false, false);
        tool.on_release(&mut model, 55.0, 55.0, false, false);
        let sel = &model.document().selection;
        assert_eq!(sel.len(), 1);
        assert_eq!(
            sel[0].path,
            vec![0, 0, 0],
            "interior selection should pick the leaf inside the group",
        );
    }

    #[test]
    fn interior_selection_parity_marquee_selects_partial() {
        let Some(mut tool) = interior_selection_yaml_tool() else { return };
        let mut model = model_with_rect_inside_group();
        tool.on_press(&mut model, 40.0, 40.0, false, false);
        tool.on_move(&mut model, 80.0, 80.0, false, false, true);
        tool.on_release(&mut model, 80.0, 80.0, false, false);
        // partial_select_in_rect produced a selection; entries are
        // SelectionKind::Partial so even whole-box coverage lists the
        // element with partial control points.
        assert!(!model.document().selection.is_empty());
    }

    // ── Polygon tool behavioral tests ──────────────────────────────

    fn polygon_yaml_tool() -> Option<YamlTool> {
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
        let spec_json = ws.get("tools")?.get("polygon")?;
        YamlTool::from_workspace_tool(spec_json)
    }

    #[test]
    fn polygon_parity_draw_polygon() {
        let Some(mut tool) = polygon_yaml_tool() else { return };
        let mut model = empty_layer_model();
        tool.on_press(&mut model, 50.0, 50.0, false, false);
        tool.on_move(&mut model, 100.0, 50.0, false, false, true);
        tool.on_release(&mut model, 100.0, 50.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Polygon(p) = &*children[0] {
            assert_eq!(p.points.len(), 5);
        } else {
            panic!("expected Polygon element");
        }
    }

    #[test]
    fn polygon_parity_short_drag_no_polygon() {
        let Some(mut tool) = polygon_yaml_tool() else { return };
        let mut model = empty_layer_model();
        tool.on_press(&mut model, 50.0, 50.0, false, false);
        tool.on_release(&mut model, 50.0, 50.0, false, false);
        assert_eq!(
            model.document().layers[0].children().unwrap().len(),
            0,
        );
    }

    // ── Star tool behavioral tests ─────────────────────────────────

    fn star_yaml_tool() -> Option<YamlTool> {
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
        let spec_json = ws.get("tools")?.get("star")?;
        YamlTool::from_workspace_tool(spec_json)
    }

    #[test]
    fn star_parity_draw_star() {
        let Some(mut tool) = star_yaml_tool() else { return };
        let mut model = empty_layer_model();
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_move(&mut model, 110.0, 120.0, false, false, true);
        tool.on_release(&mut model, 110.0, 120.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Polygon(p) = &*children[0] {
            // 5 outer points × 2 (alternating inner/outer) = 10 vertices.
            assert_eq!(p.points.len(), 10);
        } else {
            panic!("expected Polygon element");
        }
    }

    #[test]
    fn star_parity_zero_size_not_created() {
        let Some(mut tool) = star_yaml_tool() else { return };
        let mut model = empty_layer_model();
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_release(&mut model, 10.0, 20.0, false, false);
        assert_eq!(
            model.document().layers[0].children().unwrap().len(),
            0,
        );
    }

    #[test]
    fn star_parity_negative_drag_normalizes() {
        let Some(mut tool) = star_yaml_tool() else { return };
        let mut model = empty_layer_model();
        tool.on_press(&mut model, 100.0, 100.0, false, false);
        tool.on_move(&mut model, 0.0, 0.0, false, false, true);
        tool.on_release(&mut model, 0.0, 0.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Polygon(p) = &*children[0] {
            assert_eq!(p.points.len(), 10);
            // First outer point at top-center of the (normalized)
            // bounding box — center.x = 50, top.y = 0.
            assert!((p.points[0].0 - 50.0).abs() < 1e-9);
            assert!((p.points[0].1 - 0.0).abs() < 1e-9);
        } else {
            panic!("expected Polygon element");
        }
    }

    // ── Line tool behavioral tests ─────────────────────────────────

    fn line_yaml_tool() -> Option<YamlTool> {
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
        let spec_json = ws.get("tools")?.get("line")?;
        YamlTool::from_workspace_tool(spec_json)
    }

    #[test]
    fn line_parity_draw_line() {
        let Some(mut tool) = line_yaml_tool() else { return };
        let mut model = empty_layer_model();
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_move(&mut model, 30.0, 40.0, false, false, true);
        tool.on_release(&mut model, 50.0, 60.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Line(line) = &*children[0] {
            assert_eq!(line.x1, 10.0);
            assert_eq!(line.y1, 20.0);
            assert_eq!(line.x2, 50.0);
            assert_eq!(line.y2, 60.0);
        } else {
            panic!("expected Line element");
        }
    }

    #[test]
    fn line_parity_short_line_not_created() {
        let Some(mut tool) = line_yaml_tool() else { return };
        let mut model = empty_layer_model();
        // Press and release at same point — hypot distance = 0.
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_release(&mut model, 10.0, 20.0, false, false);
        assert_eq!(
            model.document().layers[0].children().unwrap().len(),
            0,
        );
    }

    #[test]
    fn line_parity_idle_after_release() {
        let Some(mut tool) = line_yaml_tool() else { return };
        let mut model = empty_layer_model();
        assert_eq!(tool.tool_state("mode"), &serde_json::json!("idle"));
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        assert_eq!(tool.tool_state("mode"), &serde_json::json!("drawing"));
        tool.on_release(&mut model, 50.0, 60.0, false, false);
        assert_eq!(tool.tool_state("mode"), &serde_json::json!("idle"));
    }

    #[test]
    fn line_parity_move_without_press_is_noop() {
        let Some(mut tool) = line_yaml_tool() else { return };
        let mut model = empty_layer_model();
        // on_mousemove's handler is guarded by `mode == "drawing"`;
        // without a prior on_mousedown, mode stays "idle" and nothing
        // happens.
        tool.on_move(&mut model, 50.0, 60.0, false, false, true);
        assert_eq!(tool.tool_state("mode"), &serde_json::json!("idle"));
    }

    // ── RoundedRect tool behavioral tests ──────────────────────────

    fn rounded_rect_yaml_tool() -> Option<YamlTool> {
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
        let spec_json = ws.get("tools")?.get("rounded_rect")?;
        YamlTool::from_workspace_tool(spec_json)
    }

    #[test]
    fn rounded_rect_parity_draw_with_radius() {
        let Some(mut tool) = rounded_rect_yaml_tool() else { return };
        let mut model = empty_layer_model();
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_move(&mut model, 110.0, 70.0, false, false, true);
        tool.on_release(&mut model, 110.0, 70.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Rect(r) = &*children[0] {
            assert_eq!(r.x, 10.0);
            assert_eq!(r.y, 20.0);
            assert_eq!(r.width, 100.0);
            assert_eq!(r.height, 50.0);
            assert_eq!(r.rx, 10.0);
            assert_eq!(r.ry, 10.0);
        } else {
            panic!("expected Rect");
        }
    }

    #[test]
    fn rounded_rect_parity_zero_size_not_created() {
        let Some(mut tool) = rounded_rect_yaml_tool() else { return };
        let mut model = empty_layer_model();
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_release(&mut model, 10.0, 20.0, false, false);
        assert_eq!(
            model.document().layers[0].children().unwrap().len(),
            0,
        );
    }

    #[test]
    fn rounded_rect_parity_negative_drag_normalizes() {
        let Some(mut tool) = rounded_rect_yaml_tool() else { return };
        let mut model = empty_layer_model();
        tool.on_press(&mut model, 100.0, 80.0, false, false);
        tool.on_move(&mut model, 10.0, 20.0, false, false, true);
        tool.on_release(&mut model, 10.0, 20.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Rect(r) = &*children[0] {
            assert_eq!(r.x, 10.0);
            assert_eq!(r.y, 20.0);
            assert_eq!(r.width, 90.0);
            assert_eq!(r.height, 60.0);
            assert_eq!(r.rx, 10.0);
        } else {
            panic!("expected Rect");
        }
    }

    #[test]
    fn rect_parity_uses_model_defaults() {
        use crate::geometry::element::{Color, Fill, Stroke};
        let Some(mut tool) = rect_yaml_tool() else { return };
        let mut model = empty_layer_model();
        model.default_fill = Some(Fill::new(Color::rgb(1.0, 0.0, 0.0)));
        model.default_stroke = Some(Stroke::new(Color::rgb(0.0, 0.0, 1.0), 3.0));
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        tool.on_move(&mut model, 110.0, 70.0, false, false, true);
        tool.on_release(&mut model, 110.0, 70.0, false, false);
        let children = model.document().layers[0].children().unwrap();
        if let Element::Rect(r) = &*children[0] {
            assert_eq!(r.fill, Some(Fill::new(Color::rgb(1.0, 0.0, 0.0))));
            assert_eq!(r.stroke, Some(Stroke::new(Color::rgb(0.0, 0.0, 1.0), 3.0)));
        } else {
            panic!("expected Rect");
        }
    }

    #[test]
    fn selection_parity_alt_captured_at_press_not_move() {
        // If Alt is released between press and first move, the copy
        // still happens — the native tool captures alt_held on press
        // and uses it through the drag, ignoring per-move alt state.
        let Some(mut tool) = selection_yaml_tool() else { return };
        let mut model = selection_parity_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        let children_before =
            model.document().layers[0].children().unwrap().len();
        // Press with alt held, but first move reports alt=false.
        tool.on_press(&mut model, 60.0, 60.0, false, true);
        tool.on_move(&mut model, 65.0, 65.0, false, false, true);
        tool.on_release(&mut model, 65.0, 65.0, false, false);
        // A copy should still have been made — alt_held was captured
        // at press time.
        let children_after =
            model.document().layers[0].children().unwrap().len();
        assert_eq!(
            children_after,
            children_before + 1,
            "drop of Alt mid-drag should not cancel the copy — alt_held \
             is captured at press time",
        );
    }
}
