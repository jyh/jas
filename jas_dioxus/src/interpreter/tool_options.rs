//! Where a tool's options live, and which toolbar buttons open them.
//!
//! Double-clicking a TOOLBAR TOOL SLOT opens the ACTIVE tool's options. The
//! web's toolbar ran this from its own renderer; the engine's panel door
//! (`jas_panel_behavior`, `double_click`) runs it for a native shell. Both read
//! the resolver here, so the two cannot disagree on a tool's destination.
//! Not gated: the FFI build has no renderer.

use serde_json::Value;

/// One of the three mutually-exclusive destinations a tool declares.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolOptionsDest {
    /// `tool_options_panel`: show the named panel (Magic Wand).
    Panel(String),
    /// `tool_options_action`: invoke a one-shot action (Hand ->
    /// fit_active_artboard, Zoom -> zoom_to_actual_size, Artboard ->
    /// fit_all_artboards).
    Action(String),
    /// `tool_options_dialog`: open a modal options dialog (Paintbrush, Blob
    /// Brush, Scale, Rotate, Shear, Eyedropper).
    Dialog(String),
}

/// Resolve a tool's options destination from the compiled bundle's `tools`
/// map, keyed by the tool's YAML id. Panel beats action beats dialog when more
/// than one is present, though the spec keeps them mutually exclusive. `None`
/// when the tool is not in the bundle or declares no options: the double-click
/// is then a no-op. Built from the bundle, never a hardcoded tool table.
pub fn tool_options_dest_for_yaml_id(yaml_id: &str) -> Option<ToolOptionsDest> {
    let ws = super::workspace::Workspace::load()?;
    let tool = ws.data().get("tools")?.get(yaml_id)?;
    if let Some(p) = tool.get("tool_options_panel").and_then(|v| v.as_str()) {
        return Some(ToolOptionsDest::Panel(p.to_string()));
    }
    if let Some(a) = tool.get("tool_options_action").and_then(|v| v.as_str()) {
        return Some(ToolOptionsDest::Action(a.to_string()));
    }
    if let Some(d) = tool.get("tool_options_dialog").and_then(|v| v.as_str()) {
        return Some(ToolOptionsDest::Dialog(d.to_string()));
    }
    None
}

/// True when this icon_button is a TOOLBAR TOOL SLOT: a button whose
/// `behavior` declares an `action: select_tool` (every layout toolbar slot).
/// The double-click is scoped to these: panels' op_* buttons, dialog toggles,
/// and the long-press flyout items (which `set` active_tool and
/// `close_dialog` but carry no `select_tool` action) all return false.
pub fn is_toolbar_tool_slot(el: &Value) -> bool {
    el.get("behavior")
        .and_then(|b| b.as_array())
        .map(|behaviors| {
            behaviors.iter().any(|b| b.get("action").and_then(|a| a.as_str()) == Some("select_tool"))
        })
        .unwrap_or(false)
}
