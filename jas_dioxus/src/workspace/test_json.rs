//! Canonical Test JSON serialization for workspace layout cross-language
//! equivalence testing.
//!
//! Follows the same conventions as `geometry::test_json`: sorted keys,
//! normalized floats (4 decimals), all optional fields explicit (`null`),
//! enums as lowercase strings. Byte-for-byte comparison is a valid
//! equivalence check.

use super::workspace::*;
use super::pane::*;

// ---------------------------------------------------------------------------
// Float formatting (same rules as geometry::test_json)
// ---------------------------------------------------------------------------

fn fmt(v: f64) -> String {
    let rounded = (v * 10000.0).round() / 10000.0;
    if rounded == rounded.trunc() {
        format!("{:.1}", rounded)
    } else {
        let s = format!("{:.4}", rounded);
        let s = s.trim_end_matches('0');
        s.to_string()
    }
}

// ---------------------------------------------------------------------------
// JSON building helpers (same as geometry::test_json)
// ---------------------------------------------------------------------------

struct JsonObj {
    entries: Vec<(String, String)>,
}

impl JsonObj {
    fn new() -> Self {
        Self { entries: Vec::new() }
    }

    fn str_val(&mut self, key: &str, v: &str) {
        self.entries.push((
            key.to_string(),
            format!("\"{}\"", v.replace('\\', "\\\\").replace('"', "\\\"")),
        ));
    }

    fn num(&mut self, key: &str, v: f64) {
        self.entries.push((key.to_string(), fmt(v)));
    }

    fn bool_val(&mut self, key: &str, v: bool) {
        self.entries
            .push((key.to_string(), if v { "true" } else { "false" }.to_string()));
    }

    fn null(&mut self, key: &str) {
        self.entries.push((key.to_string(), "null".to_string()));
    }

    fn int(&mut self, key: &str, v: usize) {
        self.entries.push((key.to_string(), v.to_string()));
    }

    fn raw(&mut self, key: &str, json: String) {
        self.entries.push((key.to_string(), json));
    }

    fn build(mut self) -> String {
        self.entries.sort_by(|a, b| a.0.cmp(&b.0));
        let pairs: Vec<String> = self
            .entries
            .iter()
            .map(|(k, v)| format!("\"{}\":{}", k, v))
            .collect();
        format!("{{{}}}", pairs.join(","))
    }
}

fn json_array(items: &[String]) -> String {
    format!("[{}]", items.join(","))
}

// ---------------------------------------------------------------------------
// Enum → lowercase string
// ---------------------------------------------------------------------------

fn dock_edge_str(e: DockEdge) -> &'static str {
    match e {
        DockEdge::Left => "left",
        DockEdge::Right => "right",
        DockEdge::Bottom => "bottom",
    }
}

fn panel_kind_str(k: PanelKind) -> &'static str {
    match k {
        PanelKind::Layers => "layers",
        PanelKind::Color => "color",
        PanelKind::Stroke => "stroke",
        PanelKind::Properties => "properties",
    }
}

fn pane_kind_str(k: PaneKind) -> &'static str {
    match k {
        PaneKind::Toolbar => "toolbar",
        PaneKind::Canvas => "canvas",
        PaneKind::Dock => "dock",
    }
}

fn edge_side_str(e: EdgeSide) -> &'static str {
    match e {
        EdgeSide::Left => "left",
        EdgeSide::Right => "right",
        EdgeSide::Top => "top",
        EdgeSide::Bottom => "bottom",
    }
}

fn double_click_action_str(a: DoubleClickAction) -> &'static str {
    match a {
        DoubleClickAction::Maximize => "maximize",
        DoubleClickAction::Redock => "redock",
        DoubleClickAction::None => "none",
    }
}

// ---------------------------------------------------------------------------
// Type serializers
// ---------------------------------------------------------------------------

fn snap_target_json(t: &SnapTarget) -> String {
    match t {
        SnapTarget::Window(edge) => {
            let mut o = JsonObj::new();
            o.str_val("window", edge_side_str(*edge));
            o.build()
        }
        SnapTarget::Pane(id, edge) => {
            let mut inner = JsonObj::new();
            inner.str_val("edge", edge_side_str(*edge));
            inner.int("id", id.0);
            let mut o = JsonObj::new();
            o.raw("pane", inner.build());
            o.build()
        }
    }
}

fn snap_constraint_json(s: &SnapConstraint) -> String {
    let mut o = JsonObj::new();
    o.str_val("edge", edge_side_str(s.edge));
    o.int("pane", s.pane.0);
    o.raw("target", snap_target_json(&s.target));
    o.build()
}

fn pane_config_json(c: &PaneConfig) -> String {
    let mut o = JsonObj::new();
    match &c.collapsed_width {
        Some(w) => o.num("collapsed_width", *w),
        None => o.null("collapsed_width"),
    }
    o.str_val("double_click_action", double_click_action_str(c.double_click_action));
    o.bool_val("fixed_width", c.fixed_width);
    o.str_val("label", &c.label);
    o.num("min_height", c.min_height);
    o.num("min_width", c.min_width);
    o.build()
}

fn pane_json(p: &Pane) -> String {
    let mut o = JsonObj::new();
    o.raw("config", pane_config_json(&p.config));
    o.num("height", p.height);
    o.int("id", p.id.0);
    o.str_val("kind", pane_kind_str(p.kind));
    o.num("width", p.width);
    o.num("x", p.x);
    o.num("y", p.y);
    o.build()
}

fn pane_layout_json(pl: &PaneLayout) -> String {
    let mut o = JsonObj::new();
    o.bool_val("canvas_maximized", pl.canvas_maximized);
    let hidden: Vec<String> = pl.hidden_panes.iter()
        .map(|k| format!("\"{}\"", pane_kind_str(*k)))
        .collect();
    o.raw("hidden_panes", json_array(&hidden));
    o.int("next_pane_id", pl.next_pane_id());
    let panes: Vec<String> = pl.panes.iter().map(pane_json).collect();
    o.raw("panes", json_array(&panes));
    let snaps: Vec<String> = pl.snaps.iter().map(snap_constraint_json).collect();
    o.raw("snaps", json_array(&snaps));
    o.num("viewport_height", pl.viewport_height);
    o.num("viewport_width", pl.viewport_width);
    let z: Vec<String> = pl.z_order.iter().map(|id| id.0.to_string()).collect();
    o.raw("z_order", json_array(&z));
    o.build()
}

fn panel_group_json(g: &PanelGroup) -> String {
    let mut o = JsonObj::new();
    o.int("active", g.active);
    o.bool_val("collapsed", g.collapsed);
    match g.height {
        Some(h) => o.num("height", h),
        None => o.null("height"),
    }
    let panels: Vec<String> = g.panels.iter()
        .map(|k| format!("\"{}\"", panel_kind_str(*k)))
        .collect();
    o.raw("panels", json_array(&panels));
    o.build()
}

fn dock_json(d: &Dock) -> String {
    let mut o = JsonObj::new();
    o.bool_val("auto_hide", d.auto_hide);
    o.bool_val("collapsed", d.collapsed);
    let groups: Vec<String> = d.groups.iter().map(panel_group_json).collect();
    o.raw("groups", json_array(&groups));
    o.int("id", d.id.0);
    o.num("min_width", d.min_width);
    o.num("width", d.width);
    o.build()
}

fn floating_dock_json(fd: &FloatingDock) -> String {
    let mut o = JsonObj::new();
    o.raw("dock", dock_json(&fd.dock));
    o.num("x", fd.x);
    o.num("y", fd.y);
    o.build()
}

fn group_addr_json(g: &GroupAddr) -> String {
    let mut o = JsonObj::new();
    o.int("dock_id", g.dock_id.0);
    o.int("group_idx", g.group_idx);
    o.build()
}

fn panel_addr_json(a: &PanelAddr) -> String {
    let mut o = JsonObj::new();
    o.raw("group", group_addr_json(&a.group));
    o.int("panel_idx", a.panel_idx);
    o.build()
}

// ---------------------------------------------------------------------------
// Toolbar structure (static data for cross-language fixture)
// ---------------------------------------------------------------------------

/// Return canonical JSON for the toolbar slot layout.
///
/// This encodes the same slot grid defined in `tools/tool.rs` tests,
/// producing a fixture that all four languages must match.
pub fn toolbar_structure_json() -> String {
    let slots: &[(usize, usize, &[&str])] = &[
        (0, 0, &["selection"]),
        (0, 1, &["partial_selection", "interior_selection"]),
        (1, 0, &["pen", "add_anchor_point", "delete_anchor_point", "anchor_point"]),
        (1, 1, &["pencil", "path_eraser", "smooth"]),
        (2, 0, &["type", "type_on_path"]),
        (2, 1, &["line"]),
        (3, 0, &["rect", "rounded_rect", "polygon", "star"]),
        (3, 1, &["lasso"]),
    ];

    let total: usize = slots.iter().map(|(_, _, tools)| tools.len()).sum();

    let slot_jsons: Vec<String> = slots.iter().map(|(row, col, tools)| {
        let mut o = JsonObj::new();
        o.int("col", *col);
        o.int("row", *row);
        let tool_strs: Vec<String> = tools.iter()
            .map(|t| format!("\"{}\"", t))
            .collect();
        o.raw("tools", json_array(&tool_strs));
        o.build()
    }).collect();

    let mut o = JsonObj::new();
    o.raw("slots", json_array(&slot_jsons));
    o.int("total_tools", total);
    o.build()
}

// ---------------------------------------------------------------------------
// Menu structure (static data for cross-language fixture)
// ---------------------------------------------------------------------------

/// Return canonical JSON for the menu bar structure.
///
/// This encodes the same data as `workspace::menu::MENU_BAR`,
/// producing a fixture that all four languages must match.
pub fn menu_structure_json() -> String {
    use super::menu::MENU_BAR;

    let total: usize = MENU_BAR.iter().map(|(_, items)| items.len()).sum();

    let menu_jsons: Vec<String> = MENU_BAR.iter().map(|(title, items)| {
        let item_jsons: Vec<String> = items.iter().map(|&(label, cmd, shortcut)| {
            if label == "---" {
                let mut o = JsonObj::new();
                o.bool_val("separator", true);
                o.build()
            } else {
                let mut o = JsonObj::new();
                o.str_val("command", cmd);
                o.str_val("label", label);
                o.str_val("shortcut", shortcut);
                o.build()
            }
        }).collect();
        let mut o = JsonObj::new();
        o.raw("items", json_array(&item_jsons));
        o.str_val("title", title);
        o.build()
    }).collect();

    let mut o = JsonObj::new();
    o.raw("menus", json_array(&menu_jsons));
    o.int("total_items", total);
    o.build()
}

// ---------------------------------------------------------------------------
// State defaults (must match workspace/state.yaml)
// ---------------------------------------------------------------------------

/// Return canonical JSON for all user-facing state variable defaults.
pub fn state_defaults_json() -> String {
    let vars: &[(&str, &str, &str)] = &[
        ("active_tab", "number", "-1"),
        ("active_tool", "enum", "\"selection\""),
        ("canvas_maximized", "bool", "false"),
        ("canvas_visible", "bool", "true"),
        ("dock_collapsed", "bool", "false"),
        ("dock_visible", "bool", "true"),
        ("fill_color", "color", "\"#ffffff\""),
        ("fill_on_top", "bool", "true"),
        ("stroke_color", "color", "\"#000000\""),
        ("stroke_width", "number", "1"),
        ("tab_count", "number", "0"),
        ("toolbar_visible", "bool", "true"),
    ];

    let var_jsons: Vec<String> = vars.iter().map(|(name, stype, default)| {
        let mut o = JsonObj::new();
        o.raw("default", default.to_string());
        o.str_val("name", name);
        o.str_val("type", stype);
        o.build()
    }).collect();

    let mut o = JsonObj::new();
    o.int("count", vars.len());
    o.raw("variables", json_array(&var_jsons));
    o.build()
}

// ---------------------------------------------------------------------------
// Shortcut structure (must match workspace/shortcuts.yaml)
// ---------------------------------------------------------------------------

/// Return canonical JSON for all keyboard shortcuts.
pub fn shortcut_structure_json() -> String {
    let shortcuts: &[(&str, &str, Option<(&str, &str)>)] = &[
        ("Ctrl+N", "new_document", None),
        ("Ctrl+O", "open_file", None),
        ("Ctrl+S", "save", None),
        ("Ctrl+Shift+S", "save_as", None),
        ("Ctrl+Q", "quit", None),
        ("Ctrl+Z", "undo", None),
        ("Ctrl+Shift+Z", "redo", None),
        ("Ctrl+X", "cut", None),
        ("Ctrl+C", "copy", None),
        ("Ctrl+V", "paste", None),
        ("Ctrl+Shift+V", "paste_in_place", None),
        ("Ctrl+A", "select_all", None),
        ("Delete", "delete_selection", None),
        ("Backspace", "delete_selection", None),
        ("Ctrl+G", "group", None),
        ("Ctrl+Shift+G", "ungroup", None),
        ("Ctrl+2", "lock", None),
        ("Ctrl+Alt+2", "unlock_all", None),
        ("Ctrl+3", "hide_selection", None),
        ("Ctrl+Alt+3", "show_all", None),
        ("Ctrl+=", "zoom_in", None),
        ("Ctrl+-", "zoom_out", None),
        ("Ctrl+0", "fit_in_window", None),
        ("V", "select_tool", Some(("tool", "selection"))),
        ("A", "select_tool", Some(("tool", "partial_selection"))),
        ("P", "select_tool", Some(("tool", "pen"))),
        ("=", "select_tool", Some(("tool", "add_anchor"))),
        ("-", "select_tool", Some(("tool", "delete_anchor"))),
        ("T", "select_tool", Some(("tool", "type"))),
        ("\\", "select_tool", Some(("tool", "line"))),
        ("M", "select_tool", Some(("tool", "rect"))),
        ("N", "select_tool", Some(("tool", "pencil"))),
        ("Shift+E", "select_tool", Some(("tool", "path_eraser"))),
        ("Q", "select_tool", Some(("tool", "lasso"))),
        ("D", "reset_fill_stroke", None),
        ("X", "toggle_fill_on_top", None),
        ("Shift+X", "swap_fill_stroke", None),
    ];

    let shortcut_jsons: Vec<String> = shortcuts.iter().map(|(key, action, params)| {
        let mut o = JsonObj::new();
        o.str_val("action", action);
        o.str_val("key", key);
        match params {
            Some((pk, pv)) => {
                let mut po = JsonObj::new();
                po.str_val(pk, pv);
                o.raw("params", po.build());
            }
            None => o.null("params"),
        }
        o.build()
    }).collect();

    let mut o = JsonObj::new();
    o.int("count", shortcuts.len());
    o.raw("shortcuts", json_array(&shortcut_jsons));
    o.build()
}

// ---------------------------------------------------------------------------
// Public API: workspace → test JSON
// ---------------------------------------------------------------------------

/// Serialize a WorkspaceLayout to canonical test JSON.
///
/// The output is a compact JSON string with sorted keys and normalized
/// floats, suitable for byte-for-byte cross-language comparison.
pub fn workspace_to_test_json(layout: &WorkspaceLayout) -> String {
    let mut o = JsonObj::new();

    // anchored: array of {dock, edge}
    let anchored: Vec<String> = layout.anchored.iter().map(|(edge, d)| {
        let mut ao = JsonObj::new();
        ao.raw("dock", dock_json(d));
        ao.str_val("edge", dock_edge_str(*edge));
        ao.build()
    }).collect();
    o.raw("anchored", json_array(&anchored));

    // appearance
    o.str_val("appearance", &layout.appearance);

    // floating
    let floating: Vec<String> = layout.floating.iter().map(floating_dock_json).collect();
    o.raw("floating", json_array(&floating));

    // hidden_panels
    let hidden: Vec<String> = layout.hidden_panels.iter()
        .map(|k| format!("\"{}\"", panel_kind_str(*k)))
        .collect();
    o.raw("hidden_panels", json_array(&hidden));

    // name
    o.str_val("name", &layout.name);

    // next_id
    o.int("next_id", layout.next_id());

    // pane_layout
    match &layout.pane_layout {
        Some(pl) => o.raw("pane_layout", pane_layout_json(pl)),
        None => o.null("pane_layout"),
    }

    // version
    o.int("version", layout.version as usize);

    // z_order
    let z: Vec<String> = layout.z_order.iter().map(|id| id.0.to_string()).collect();
    o.raw("z_order", json_array(&z));

    // focused_panel
    match &layout.focused_panel {
        Some(a) => o.raw("focused_panel", panel_addr_json(a)),
        None => o.null("focused_panel"),
    }

    o.build()
}

// ---------------------------------------------------------------------------
// Public API: test JSON → workspace
// ---------------------------------------------------------------------------

fn parse_f(v: &serde_json::Value) -> f64 {
    v.as_f64().unwrap_or(0.0)
}

fn parse_usize(v: &serde_json::Value) -> usize {
    v.as_u64().unwrap_or(0) as usize
}

fn parse_dock_edge(v: &serde_json::Value) -> DockEdge {
    match v.as_str().unwrap_or("right") {
        "left" => DockEdge::Left,
        "bottom" => DockEdge::Bottom,
        _ => DockEdge::Right,
    }
}

fn parse_panel_kind(v: &serde_json::Value) -> PanelKind {
    match v.as_str().unwrap_or("layers") {
        "color" => PanelKind::Color,
        "stroke" => PanelKind::Stroke,
        "properties" => PanelKind::Properties,
        _ => PanelKind::Layers,
    }
}

fn parse_pane_kind(v: &serde_json::Value) -> PaneKind {
    match v.as_str().unwrap_or("canvas") {
        "toolbar" => PaneKind::Toolbar,
        "dock" => PaneKind::Dock,
        _ => PaneKind::Canvas,
    }
}

fn parse_edge_side(v: &serde_json::Value) -> EdgeSide {
    match v.as_str().unwrap_or("left") {
        "right" => EdgeSide::Right,
        "top" => EdgeSide::Top,
        "bottom" => EdgeSide::Bottom,
        _ => EdgeSide::Left,
    }
}

fn parse_double_click_action(v: &serde_json::Value) -> DoubleClickAction {
    match v.as_str().unwrap_or("none") {
        "maximize" => DoubleClickAction::Maximize,
        "redock" => DoubleClickAction::Redock,
        _ => DoubleClickAction::None,
    }
}

fn parse_snap_target(v: &serde_json::Value) -> SnapTarget {
    if let Some(edge_str) = v.get("window") {
        SnapTarget::Window(parse_edge_side(edge_str))
    } else if let Some(pane_obj) = v.get("pane") {
        SnapTarget::Pane(
            PaneId(parse_usize(&pane_obj["id"])),
            parse_edge_side(&pane_obj["edge"]),
        )
    } else {
        SnapTarget::Window(EdgeSide::Left)
    }
}

fn parse_snap_constraint(v: &serde_json::Value) -> SnapConstraint {
    SnapConstraint {
        pane: PaneId(parse_usize(&v["pane"])),
        edge: parse_edge_side(&v["edge"]),
        target: parse_snap_target(&v["target"]),
    }
}

fn parse_pane_config(v: &serde_json::Value) -> PaneConfig {
    PaneConfig {
        label: v["label"].as_str().unwrap_or("").to_string(),
        min_width: parse_f(&v["min_width"]),
        min_height: parse_f(&v["min_height"]),
        fixed_width: v["fixed_width"].as_bool().unwrap_or(false),
        collapsed_width: if v["collapsed_width"].is_null() {
            None
        } else {
            Some(parse_f(&v["collapsed_width"]))
        },
        double_click_action: parse_double_click_action(&v["double_click_action"]),
    }
}

fn parse_pane(v: &serde_json::Value) -> Pane {
    Pane {
        id: PaneId(parse_usize(&v["id"])),
        kind: parse_pane_kind(&v["kind"]),
        config: parse_pane_config(&v["config"]),
        x: parse_f(&v["x"]),
        y: parse_f(&v["y"]),
        width: parse_f(&v["width"]),
        height: parse_f(&v["height"]),
    }
}

fn parse_pane_layout(v: &serde_json::Value) -> PaneLayout {
    let panes: Vec<Pane> = v["panes"].as_array().unwrap_or(&vec![])
        .iter().map(parse_pane).collect();
    let snaps: Vec<SnapConstraint> = v["snaps"].as_array().unwrap_or(&vec![])
        .iter().map(parse_snap_constraint).collect();
    let z_order: Vec<PaneId> = v["z_order"].as_array().unwrap_or(&vec![])
        .iter().map(|id| PaneId(parse_usize(id))).collect();
    let hidden_panes: Vec<PaneKind> = v["hidden_panes"].as_array().unwrap_or(&vec![])
        .iter().map(parse_pane_kind).collect();
    PaneLayout::from_parts(
        panes,
        snaps,
        z_order,
        hidden_panes,
        v["canvas_maximized"].as_bool().unwrap_or(false),
        parse_f(&v["viewport_width"]),
        parse_f(&v["viewport_height"]),
        parse_usize(&v["next_pane_id"]),
    )
}

fn parse_panel_group(v: &serde_json::Value) -> PanelGroup {
    let panels: Vec<PanelKind> = v["panels"].as_array().unwrap_or(&vec![])
        .iter().map(parse_panel_kind).collect();
    PanelGroup {
        panels,
        active: parse_usize(&v["active"]),
        collapsed: v["collapsed"].as_bool().unwrap_or(false),
        height: if v["height"].is_null() { None } else { Some(parse_f(&v["height"])) },
    }
}

fn parse_dock(v: &serde_json::Value) -> Dock {
    let groups: Vec<PanelGroup> = v["groups"].as_array().unwrap_or(&vec![])
        .iter().map(parse_panel_group).collect();
    Dock::from_parts(
        DockId(parse_usize(&v["id"])),
        groups,
        v["collapsed"].as_bool().unwrap_or(false),
        v["auto_hide"].as_bool().unwrap_or(false),
        parse_f(&v["width"]),
        parse_f(&v["min_width"]),
    )
}

fn parse_floating_dock(v: &serde_json::Value) -> FloatingDock {
    FloatingDock {
        dock: parse_dock(&v["dock"]),
        x: parse_f(&v["x"]),
        y: parse_f(&v["y"]),
    }
}

fn parse_group_addr(v: &serde_json::Value) -> GroupAddr {
    GroupAddr {
        dock_id: DockId(parse_usize(&v["dock_id"])),
        group_idx: parse_usize(&v["group_idx"]),
    }
}

fn parse_panel_addr(v: &serde_json::Value) -> PanelAddr {
    PanelAddr {
        group: parse_group_addr(&v["group"]),
        panel_idx: parse_usize(&v["panel_idx"]),
    }
}

/// Parse canonical test JSON into a WorkspaceLayout.
///
/// This is the inverse of [`workspace_to_test_json`].
pub fn test_json_to_workspace(json: &str) -> WorkspaceLayout {
    let v: serde_json::Value = serde_json::from_str(json)
        .expect("Failed to parse workspace test JSON");

    let anchored: Vec<(DockEdge, Dock)> = v["anchored"].as_array().unwrap_or(&vec![])
        .iter().map(|a| {
            (parse_dock_edge(&a["edge"]), parse_dock(&a["dock"]))
        }).collect();

    let floating: Vec<FloatingDock> = v["floating"].as_array().unwrap_or(&vec![])
        .iter().map(parse_floating_dock).collect();

    let hidden_panels: Vec<PanelKind> = v["hidden_panels"].as_array().unwrap_or(&vec![])
        .iter().map(parse_panel_kind).collect();

    let z_order: Vec<DockId> = v["z_order"].as_array().unwrap_or(&vec![])
        .iter().map(|id| DockId(parse_usize(id))).collect();

    let focused_panel = if v["focused_panel"].is_null() {
        None
    } else {
        Some(parse_panel_addr(&v["focused_panel"]))
    };

    let pane_layout = if v["pane_layout"].is_null() {
        None
    } else {
        Some(parse_pane_layout(&v["pane_layout"]))
    };

    let name = v["name"].as_str().unwrap_or("Default").to_string();
    let version = v["version"].as_u64().unwrap_or(LAYOUT_VERSION as u64) as u32;
    let next_id = parse_usize(&v["next_id"]);
    let appearance = v["appearance"].as_str().unwrap_or("dark_gray").to_string();

    WorkspaceLayout::from_parts(
        version,
        name,
        anchored,
        floating,
        hidden_panels,
        z_order,
        focused_panel,
        appearance,
        pane_layout,
        next_id,
    )
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_layout_roundtrip() {
        let layout = WorkspaceLayout::default_layout();
        let json = workspace_to_test_json(&layout);
        let parsed = test_json_to_workspace(&json);
        let json2 = workspace_to_test_json(&parsed);
        assert_eq!(json, json2, "Roundtrip produced different JSON");
    }

    #[test]
    fn default_layout_with_panes_roundtrip() {
        let mut layout = WorkspaceLayout::default_layout();
        layout.ensure_pane_layout(1200.0, 800.0);
        let json = workspace_to_test_json(&layout);
        let parsed = test_json_to_workspace(&json);
        let json2 = workspace_to_test_json(&parsed);
        assert_eq!(json, json2, "Roundtrip with panes produced different JSON");
    }

    #[test]
    fn keys_sorted() {
        let layout = WorkspaceLayout::default_layout();
        let json = workspace_to_test_json(&layout);
        // Top-level keys must be sorted: anchored < floating < focused_panel < ...
        let anchored_pos = json.find("\"anchored\"").unwrap();
        let floating_pos = json.find("\"floating\"").unwrap();
        let name_pos = json.find("\"name\"").unwrap();
        assert!(anchored_pos < floating_pos);
        assert!(floating_pos < name_pos);
    }

    #[test]
    fn enums_lowercase() {
        let layout = WorkspaceLayout::default_layout();
        let json = workspace_to_test_json(&layout);
        assert!(json.contains("\"right\""), "DockEdge should be lowercase");
        assert!(json.contains("\"layers\""), "PanelKind should be lowercase");
    }

    #[test]
    fn null_optional_fields() {
        let layout = WorkspaceLayout::default_layout();
        let json = workspace_to_test_json(&layout);
        assert!(json.contains("\"pane_layout\":null"), "pane_layout should be explicit null");
        assert!(json.contains("\"focused_panel\":null"), "focused_panel should be explicit null");
    }

    #[test]
    fn float_formatting() {
        assert_eq!(fmt(1.0), "1.0");
        assert_eq!(fmt(0.0), "0.0");
        assert_eq!(fmt(240.0), "240.0");
        assert_eq!(fmt(72.0), "72.0");
        assert_eq!(fmt(3.14159), "3.1416");
    }

    #[test]
    #[ignore] // Run manually to regenerate fixtures: cargo test generate_workspace_fixtures -- --ignored --nocapture
    fn generate_workspace_fixtures() {
        let fixtures = format!("{}/{}", env!("CARGO_MANIFEST_DIR"), "../test_fixtures/expected");

        let layout = WorkspaceLayout::default_layout();
        let json = workspace_to_test_json(&layout);
        std::fs::write(format!("{}/workspace_default.json", fixtures), &json)
            .expect("Failed to write workspace_default.json");
        eprintln!("Wrote workspace_default.json ({} bytes)", json.len());

        let mut layout_with_panes = WorkspaceLayout::default_layout();
        layout_with_panes.ensure_pane_layout(1200.0, 800.0);
        let json = workspace_to_test_json(&layout_with_panes);
        std::fs::write(format!("{}/workspace_default_with_panes.json", fixtures), &json)
            .expect("Failed to write workspace_default_with_panes.json");
        eprintln!("Wrote workspace_default_with_panes.json ({} bytes)", json.len());

        let json = toolbar_structure_json();
        std::fs::write(format!("{}/toolbar_structure.json", fixtures), &json)
            .expect("Failed to write toolbar_structure.json");
        eprintln!("Wrote toolbar_structure.json ({} bytes)", json.len());

        let json = menu_structure_json();
        std::fs::write(format!("{}/menu_structure.json", fixtures), &json)
            .expect("Failed to write menu_structure.json");
        eprintln!("Wrote menu_structure.json ({} bytes)", json.len());
    }

    #[test]
    fn snap_target_format() {
        let window_snap = SnapTarget::Window(EdgeSide::Left);
        let json = snap_target_json(&window_snap);
        assert_eq!(json, "{\"window\":\"left\"}");

        let pane_snap = SnapTarget::Pane(PaneId(1), EdgeSide::Right);
        let json = snap_target_json(&pane_snap);
        assert_eq!(json, "{\"pane\":{\"edge\":\"right\",\"id\":1}}");
    }
}
