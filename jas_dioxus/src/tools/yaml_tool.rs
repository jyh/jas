//! YAML-driven canvas tool.
//!
//! Parses a tool spec from `workspace/tools/*.yaml` (via the compiled
//! `workspace.json`) into a [`ToolSpec`], then implements the
//! [`CanvasTool`] trait by routing native events through the YAML
//! handlers declared in the spec. Mirrors the tool dispatcher in
//! `jas_flask/static/js/engine/tools.mjs`.
//!
//! Phase 3b of the Rust YAML tool runtime (see RUST_TOOL_RUNTIME.md):
//! this file currently provides the parsed spec shape only. Phase 3c
//! adds the `CanvasTool` impl; Phase 3d adds overlay rendering.

use std::collections::HashMap;

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
}
