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

    fn draw_overlay(&self, model: &Model, ctx: &CanvasRenderingContext2d) {
        let Some(overlay) = self.spec.overlay.as_ref() else {
            return;
        };
        // Document registration lets overlay expressions call
        // hit_test / selection_contains — same pattern as dispatch().
        let _guard = doc_primitives::register_document(model.document().clone());
        let eval_ctx = self.store.eval_context();

        // Guard: if present, must evaluate truthy for the overlay to draw.
        if let Some(guard_expr) = &overlay.guard {
            let result = crate::interpreter::expr::eval(guard_expr, &eval_ctx);
            if !result.to_bool() {
                return;
            }
        }

        // Dispatch on `render.type` — Phase 3d handles `rect` (Selection
        // tool's marquee). Other shapes extend here as their tools port.
        let render = &overlay.render;
        let render_type = render
            .get("type")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        match render_type {
            "rect" => draw_rect_overlay(ctx, render, &eval_ctx),
            "line" => draw_line_overlay(ctx, render, &eval_ctx),
            "polygon" => draw_regular_polygon_overlay(ctx, render, &eval_ctx),
            "star" => draw_star_overlay(ctx, render, &eval_ctx),
            "buffer_polygon" => draw_buffer_polygon_overlay(ctx, render),
            "buffer_polyline" => draw_buffer_polyline_overlay(ctx, render),
            "pen_overlay" => draw_pen_overlay(ctx, render, &eval_ctx),
            _ => {
                // Unrecognized type — skip silently, matching the
                // lenient-mode convention used elsewhere.
            }
        }
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
) {
    let name = render
        .get("buffer")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if name.is_empty() {
        return;
    }
    let points: Vec<(f64, f64)> =
        crate::interpreter::point_buffers::with_points(name, |pts| pts.to_vec());
    draw_closed_polygon_from_points(ctx, &points, render);
}

/// Draw an OPEN polyline — like buffer_polygon but without
/// close_path / fill. Used by Pencil's overlay: the user sees the raw
/// traced path while dragging, then the final fit_curve result lands
/// as a Bezier Path element on mouseup.
fn draw_buffer_polyline_overlay(
    ctx: &CanvasRenderingContext2d,
    render: &serde_json::Value,
) {
    let name = render
        .get("buffer")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if name.is_empty() {
        return;
    }
    let points: Vec<(f64, f64)> = crate::interpreter::point_buffers::with_points(
        name, |pts| pts.to_vec());
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
) {
    let name = render
        .get("buffer")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if name.is_empty() {
        return;
    }
    let anchors: Vec<crate::interpreter::anchor_buffers::Anchor> =
        crate::interpreter::anchor_buffers::with_anchors(name, |a| a.to_vec());
    if anchors.is_empty() {
        return;
    }
    let mouse_x = eval_number_field(eval_ctx, render.get("mouse_x"));
    let mouse_y = eval_number_field(eval_ctx, render.get("mouse_y"));
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
