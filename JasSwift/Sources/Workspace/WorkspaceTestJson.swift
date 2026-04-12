/// Canonical Test JSON serialization for workspace layout cross-language
/// equivalence testing.
///
/// Follows the same conventions as `Geometry/TestJson.swift`: sorted keys,
/// normalized floats (4 decimals), all optional fields explicit (`null`),
/// enums as lowercase strings. Byte-for-byte comparison is a valid
/// equivalence check.

import Foundation

// MARK: - Float formatting (same rules as Geometry/TestJson.swift)

private func fmt(_ v: Double) -> String {
    let rounded = (v * 10000.0).rounded() / 10000.0
    if rounded == rounded.rounded(.towardZero) && rounded.truncatingRemainder(dividingBy: 1) == 0 {
        return String(format: "%.1f", rounded)
    }
    var s = String(format: "%.4f", rounded)
    while s.hasSuffix("0") && !s.hasSuffix(".0") {
        s.removeLast()
    }
    return s
}

// MARK: - JSON builder with sorted keys

private class JsonObj {
    private var entries: [(String, String)] = []

    func str(_ key: String, _ v: String) {
        let escaped = v.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        entries.append((key, "\"\(escaped)\""))
    }

    func num(_ key: String, _ v: Double) {
        entries.append((key, fmt(v)))
    }

    func int(_ key: String, _ v: Int) {
        entries.append((key, "\(v)"))
    }

    func bool(_ key: String, _ v: Bool) {
        entries.append((key, v ? "true" : "false"))
    }

    func null(_ key: String) {
        entries.append((key, "null"))
    }

    func raw(_ key: String, _ json: String) {
        entries.append((key, json))
    }

    func build() -> String {
        entries.sort { $0.0 < $1.0 }
        let pairs = entries.map { "\"\($0.0)\":\($0.1)" }
        return "{\(pairs.joined(separator: ","))}"
    }
}

private func jsonArray(_ items: [String]) -> String {
    "[\(items.joined(separator: ","))]"
}

// MARK: - Enum to lowercase string

private func dockEdgeStr(_ e: DockEdge) -> String {
    switch e {
    case .left: return "left"
    case .right: return "right"
    case .bottom: return "bottom"
    }
}

private func panelKindStr(_ k: PanelKind) -> String {
    switch k {
    case .layers: return "layers"
    case .color: return "color"
    case .stroke: return "stroke"
    case .properties: return "properties"
    }
}

private func paneKindStr(_ k: PaneKind) -> String {
    switch k {
    case .toolbar: return "toolbar"
    case .canvas: return "canvas"
    case .dock: return "dock"
    }
}

private func edgeSideStr(_ e: EdgeSide) -> String {
    switch e {
    case .left: return "left"
    case .right: return "right"
    case .top: return "top"
    case .bottom: return "bottom"
    }
}

private func doubleClickActionStr(_ a: DoubleClickAction) -> String {
    switch a {
    case .maximize: return "maximize"
    case .redock: return "redock"
    case .none: return "none"
    }
}

// MARK: - Type serializers

private func snapTargetJson(_ t: SnapTarget) -> String {
    switch t {
    case .window(let edge):
        let o = JsonObj()
        o.str("window", edgeSideStr(edge))
        return o.build()
    case .pane(let id, let edge):
        let inner = JsonObj()
        inner.str("edge", edgeSideStr(edge))
        inner.int("id", id.value)
        let o = JsonObj()
        o.raw("pane", inner.build())
        return o.build()
    }
}

private func snapConstraintJson(_ s: SnapConstraint) -> String {
    let o = JsonObj()
    o.str("edge", edgeSideStr(s.edge))
    o.int("pane", s.pane.value)
    o.raw("target", snapTargetJson(s.target))
    return o.build()
}

private func paneConfigJson(_ c: PaneConfig) -> String {
    let o = JsonObj()
    if let cw = c.collapsedWidth {
        o.num("collapsed_width", cw)
    } else {
        o.null("collapsed_width")
    }
    o.str("double_click_action", doubleClickActionStr(c.doubleClickAction))
    o.bool("fixed_width", c.fixedWidth)
    o.str("label", c.label)
    o.num("min_height", c.minHeight)
    o.num("min_width", c.minWidth)
    return o.build()
}

private func paneJson(_ p: Pane) -> String {
    let o = JsonObj()
    o.raw("config", paneConfigJson(p.config))
    o.num("height", p.height)
    o.int("id", p.id.value)
    o.str("kind", paneKindStr(p.kind))
    o.num("width", p.width)
    o.num("x", p.x)
    o.num("y", p.y)
    return o.build()
}

private func paneLayoutJson(_ pl: PaneLayout) -> String {
    let o = JsonObj()
    o.bool("canvas_maximized", pl.canvasMaximized)
    let hidden = pl.hiddenPanes.map { "\"\(paneKindStr($0))\"" }
    o.raw("hidden_panes", jsonArray(hidden))
    o.int("next_pane_id", pl.getNextPaneId())
    let panes = pl.panes.map { paneJson($0) }
    o.raw("panes", jsonArray(panes))
    let snaps = pl.snaps.map { snapConstraintJson($0) }
    o.raw("snaps", jsonArray(snaps))
    o.num("viewport_height", pl.viewportHeight)
    o.num("viewport_width", pl.viewportWidth)
    let z = pl.zOrder.map { "\($0.value)" }
    o.raw("z_order", jsonArray(z))
    return o.build()
}

private func panelGroupJson(_ g: PanelGroup) -> String {
    let o = JsonObj()
    o.int("active", g.active)
    o.bool("collapsed", g.collapsed)
    if let h = g.height {
        o.num("height", h)
    } else {
        o.null("height")
    }
    let panels = g.panels.map { "\"\(panelKindStr($0))\"" }
    o.raw("panels", jsonArray(panels))
    return o.build()
}

private func dockJson(_ d: Dock) -> String {
    let o = JsonObj()
    o.bool("auto_hide", d.autoHide)
    o.bool("collapsed", d.collapsed)
    let groups = d.groups.map { panelGroupJson($0) }
    o.raw("groups", jsonArray(groups))
    o.int("id", d.id.value)
    o.num("min_width", d.minWidth)
    o.num("width", d.width)
    return o.build()
}

private func floatingDockJson(_ fd: FloatingDock) -> String {
    let o = JsonObj()
    o.raw("dock", dockJson(fd.dock))
    o.num("x", fd.x)
    o.num("y", fd.y)
    return o.build()
}

private func groupAddrJson(_ g: GroupAddr) -> String {
    let o = JsonObj()
    o.int("dock_id", g.dockId.value)
    o.int("group_idx", g.groupIdx)
    return o.build()
}

private func panelAddrJson(_ a: PanelAddr) -> String {
    let o = JsonObj()
    o.raw("group", groupAddrJson(a.group))
    o.int("panel_idx", a.panelIdx)
    return o.build()
}

// MARK: - Toolbar structure (static data for cross-language fixture)

/// Return canonical JSON for the toolbar slot layout.
///
/// Encodes the same slot grid defined in `tools/tool.rs` tests,
/// producing a fixture that all four languages must match.
public func toolbarStructureJson() -> String {
    let slots: [(Int, Int, [String])] = [
        (0, 0, ["selection"]),
        (0, 1, ["partial_selection", "interior_selection"]),
        (1, 0, ["pen", "add_anchor_point", "delete_anchor_point", "anchor_point"]),
        (1, 1, ["pencil", "path_eraser", "smooth"]),
        (2, 0, ["type", "type_on_path"]),
        (2, 1, ["line"]),
        (3, 0, ["rect", "rounded_rect", "polygon", "star"]),
        (3, 1, ["lasso"]),
    ]

    let total = slots.reduce(0) { $0 + $1.2.count }

    let slotJsons = slots.map { (row, col, tools) -> String in
        let o = JsonObj()
        o.int("col", col)
        o.int("row", row)
        let toolStrs = tools.map { "\"\($0)\"" }
        o.raw("tools", jsonArray(toolStrs))
        return o.build()
    }

    let o = JsonObj()
    o.raw("slots", jsonArray(slotJsons))
    o.int("total_tools", total)
    return o.build()
}

// MARK: - Menu bar data (mirrors Rust MENU_BAR)

/// A menu item: (label, command, shortcut). Label "---" denotes a separator.
public typealias MenuItem = (String, String, String)

/// Complete menu bar definition.
public let menuBar: [(String, [MenuItem])] = [
    ("File", [
        ("New", "new", "\u{2318}N"),
        ("Open...", "open", "\u{2318}O"),
        ("Save", "save", "\u{2318}S"),
        ("---", "", ""),
        ("Close Tab", "close", "\u{2318}W"),
    ]),
    ("Edit", [
        ("Undo", "undo", "\u{2318}Z"),
        ("Redo", "redo", "\u{21e7}\u{2318}Z"),
        ("---", "", ""),
        ("Cut", "cut", "\u{2318}X"),
        ("Copy", "copy", "\u{2318}C"),
        ("Paste", "paste", "\u{2318}V"),
        ("Paste in Place", "paste_in_place", "\u{21e7}\u{2318}V"),
        ("---", "", ""),
        ("Delete", "delete", "\u{232b}"),
        ("Select All", "select_all", "\u{2318}A"),
    ]),
    ("Object", [
        ("Group", "group", "\u{2318}G"),
        ("Ungroup", "ungroup", "\u{21e7}\u{2318}G"),
        ("Ungroup All", "ungroup_all", ""),
        ("---", "", ""),
        ("Lock", "lock", "\u{2318}2"),
        ("Unlock All", "unlock_all", "\u{2325}\u{2318}2"),
        ("---", "", ""),
        ("Hide", "hide", "\u{2318}3"),
        ("Show All", "show_all", "\u{2325}\u{2318}3"),
    ]),
    ("Window", [
        ("Workspace \u{25B6}", "workspace_submenu", ""),
        ("Appearance \u{25B6}", "appearance_submenu", ""),
        ("---", "", ""),
        ("Tile", "tile_panes", ""),
        ("---", "", ""),
        ("Toolbar", "toggle_pane_toolbar", ""),
        ("Panels", "toggle_pane_dock", ""),
        ("---", "", ""),
        ("Layers", "toggle_panel_layers", ""),
        ("Color", "toggle_panel_color", ""),
        ("Stroke", "toggle_panel_stroke", ""),
        ("Properties", "toggle_panel_properties", ""),
    ]),
]

// MARK: - Menu structure (static data for cross-language fixture)

/// Return canonical JSON for the menu bar structure.
///
/// Encodes the same data as `workspace::menu::MENU_BAR`,
/// producing a fixture that all four languages must match.
public func menuStructureJson() -> String {
    let total = menuBar.reduce(0) { $0 + $1.1.count }

    let menuJsons = menuBar.map { (title, items) -> String in
        let itemJsons = items.map { (label, cmd, shortcut) -> String in
            if label == "---" {
                let o = JsonObj()
                o.bool("separator", true)
                return o.build()
            } else {
                let o = JsonObj()
                o.str("command", cmd)
                o.str("label", label)
                o.str("shortcut", shortcut)
                return o.build()
            }
        }
        let o = JsonObj()
        o.raw("items", jsonArray(itemJsons))
        o.str("title", title)
        return o.build()
    }

    let o = JsonObj()
    o.raw("menus", jsonArray(menuJsons))
    o.int("total_items", total)
    return o.build()
}

// MARK: - State defaults (must match workspace/state.yaml)

public func stateDefaultsJson() -> String {
    let vars: [(String, String, String)] = [
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
    ]

    let varJsons = vars.map { (name, stype, defVal) -> String in
        let o = JsonObj()
        o.raw("default", defVal)
        o.str("name", name)
        o.str("type", stype)
        return o.build()
    }

    let o = JsonObj()
    o.int("count", vars.count)
    o.raw("variables", jsonArray(varJsons))
    return o.build()
}

// MARK: - Shortcut structure (must match workspace/shortcuts.yaml)

public func shortcutStructureJson() -> String {
    let shortcuts: [(String, String, (String, String)?)] = [
        ("Ctrl+N", "new_document", nil),
        ("Ctrl+O", "open_file", nil),
        ("Ctrl+S", "save", nil),
        ("Ctrl+Shift+S", "save_as", nil),
        ("Ctrl+Q", "quit", nil),
        ("Ctrl+Z", "undo", nil),
        ("Ctrl+Shift+Z", "redo", nil),
        ("Ctrl+X", "cut", nil),
        ("Ctrl+C", "copy", nil),
        ("Ctrl+V", "paste", nil),
        ("Ctrl+Shift+V", "paste_in_place", nil),
        ("Ctrl+A", "select_all", nil),
        ("Delete", "delete_selection", nil),
        ("Backspace", "delete_selection", nil),
        ("Ctrl+G", "group", nil),
        ("Ctrl+Shift+G", "ungroup", nil),
        ("Ctrl+2", "lock", nil),
        ("Ctrl+Alt+2", "unlock_all", nil),
        ("Ctrl+3", "hide_selection", nil),
        ("Ctrl+Alt+3", "show_all", nil),
        ("Ctrl+=", "zoom_in", nil),
        ("Ctrl+-", "zoom_out", nil),
        ("Ctrl+0", "fit_in_window", nil),
        ("V", "select_tool", ("tool", "selection")),
        ("A", "select_tool", ("tool", "partial_selection")),
        ("P", "select_tool", ("tool", "pen")),
        ("=", "select_tool", ("tool", "add_anchor")),
        ("-", "select_tool", ("tool", "delete_anchor")),
        ("T", "select_tool", ("tool", "type")),
        ("\\", "select_tool", ("tool", "line")),
        ("M", "select_tool", ("tool", "rect")),
        ("N", "select_tool", ("tool", "pencil")),
        ("Shift+E", "select_tool", ("tool", "path_eraser")),
        ("Q", "select_tool", ("tool", "lasso")),
        ("D", "reset_fill_stroke", nil),
        ("X", "toggle_fill_on_top", nil),
        ("Shift+X", "swap_fill_stroke", nil),
    ]

    let shortcutJsons = shortcuts.map { (key, action, params) -> String in
        let o = JsonObj()
        o.str("action", action)
        o.str("key", key)
        if let (pk, pv) = params {
            let po = JsonObj()
            po.str(pk, pv)
            o.raw("params", po.build())
        } else {
            o.null("params")
        }
        return o.build()
    }

    let o = JsonObj()
    o.int("count", shortcuts.count)
    o.raw("shortcuts", jsonArray(shortcutJsons))
    return o.build()
}

// MARK: - Public API: workspace -> test JSON

/// Serialize a WorkspaceLayout to canonical test JSON.
///
/// The output is a compact JSON string with sorted keys and normalized
/// floats, suitable for byte-for-byte cross-language comparison.
public func workspaceToTestJson(_ layout: WorkspaceLayout) -> String {
    let o = JsonObj()

    // anchored: array of {dock, edge}
    let anchored = layout.anchored.map { (edge, d) -> String in
        let ao = JsonObj()
        ao.raw("dock", dockJson(d))
        ao.str("edge", dockEdgeStr(edge))
        return ao.build()
    }
    o.raw("anchored", jsonArray(anchored))

    // appearance
    o.str("appearance", layout.appearance)

    // floating
    let floating = layout.floating.map { floatingDockJson($0) }
    o.raw("floating", jsonArray(floating))

    // focused_panel
    if let fp = layout.focusedPanel {
        o.raw("focused_panel", panelAddrJson(fp))
    } else {
        o.null("focused_panel")
    }

    // hidden_panels
    let hidden = layout.hiddenPanels.map { "\"\(panelKindStr($0))\"" }
    o.raw("hidden_panels", jsonArray(hidden))

    // name
    o.str("name", layout.name)

    // next_id
    o.int("next_id", layout.getNextId())

    // pane_layout
    if let pl = layout.paneLayout {
        o.raw("pane_layout", paneLayoutJson(pl))
    } else {
        o.null("pane_layout")
    }

    // version
    o.int("version", layout.version)

    // z_order
    let z = layout.zOrder.map { "\($0.value)" }
    o.raw("z_order", jsonArray(z))

    return o.build()
}

// MARK: - Public API: test JSON -> workspace

private func parseF(_ v: Any?) -> Double {
    if let n = v as? NSNumber { return n.doubleValue }
    return 0.0
}

private func parseInt(_ v: Any?) -> Int {
    if let n = v as? NSNumber { return n.intValue }
    return 0
}

private func parseDockEdge(_ v: Any?) -> DockEdge {
    switch v as? String ?? "right" {
    case "left": return .left
    case "bottom": return .bottom
    default: return .right
    }
}

private func parsePanelKind(_ v: Any?) -> PanelKind {
    switch v as? String ?? "layers" {
    case "color": return .color
    case "stroke": return .stroke
    case "properties": return .properties
    default: return .layers
    }
}

private func parsePaneKind(_ v: Any?) -> PaneKind {
    switch v as? String ?? "canvas" {
    case "toolbar": return .toolbar
    case "dock": return .dock
    default: return .canvas
    }
}

private func parseEdgeSide(_ v: Any?) -> EdgeSide {
    switch v as? String ?? "left" {
    case "right": return .right
    case "top": return .top
    case "bottom": return .bottom
    default: return .left
    }
}

private func parseDoubleClickAction(_ v: Any?) -> DoubleClickAction {
    switch v as? String ?? "none" {
    case "maximize": return .maximize
    case "redock": return .redock
    default: return .none
    }
}

private func parseSnapTarget(_ v: Any?) -> SnapTarget {
    guard let d = v as? [String: Any] else { return .window(.left) }
    if let edgeStr = d["window"] {
        return .window(parseEdgeSide(edgeStr))
    } else if let paneObj = d["pane"] as? [String: Any] {
        return .pane(
            PaneId(parseInt(paneObj["id"])),
            parseEdgeSide(paneObj["edge"])
        )
    }
    return .window(.left)
}

private func parseSnapConstraint(_ v: Any?) -> SnapConstraint {
    guard let d = v as? [String: Any] else {
        return SnapConstraint(pane: PaneId(0), edge: .left, target: .window(.left))
    }
    return SnapConstraint(
        pane: PaneId(parseInt(d["pane"])),
        edge: parseEdgeSide(d["edge"]),
        target: parseSnapTarget(d["target"])
    )
}

private func parsePaneConfig(_ v: Any?) -> PaneConfig {
    guard let d = v as? [String: Any] else { return .forKind(.canvas) }
    return PaneConfig(
        label: d["label"] as? String ?? "",
        minWidth: parseF(d["min_width"]),
        minHeight: parseF(d["min_height"]),
        fixedWidth: d["fixed_width"] as? Bool ?? false,
        collapsedWidth: (d["collapsed_width"] is NSNull || d["collapsed_width"] == nil)
            ? nil : parseF(d["collapsed_width"]),
        doubleClickAction: parseDoubleClickAction(d["double_click_action"])
    )
}

private func parsePane(_ v: Any?) -> Pane {
    guard let d = v as? [String: Any] else {
        return Pane(id: PaneId(0), kind: .canvas, config: .forKind(.canvas),
                    x: 0, y: 0, width: 0, height: 0)
    }
    return Pane(
        id: PaneId(parseInt(d["id"])),
        kind: parsePaneKind(d["kind"]),
        config: parsePaneConfig(d["config"]),
        x: parseF(d["x"]),
        y: parseF(d["y"]),
        width: parseF(d["width"]),
        height: parseF(d["height"])
    )
}

private func parsePaneLayout(_ v: Any?) -> PaneLayout {
    guard let d = v as? [String: Any] else {
        return PaneLayout.defaultThreePane(viewportW: 1200, viewportH: 800)
    }
    let panes = (d["panes"] as? [Any] ?? []).map { parsePane($0) }
    let snaps = (d["snaps"] as? [Any] ?? []).map { parseSnapConstraint($0) }
    let zOrder = (d["z_order"] as? [Any] ?? []).map { PaneId(parseInt($0)) }
    let hiddenPanes = (d["hidden_panes"] as? [Any] ?? []).map { parsePaneKind($0) }
    return PaneLayout.fromParts(
        panes: panes,
        snaps: snaps,
        zOrder: zOrder,
        hiddenPanes: hiddenPanes,
        canvasMaximized: d["canvas_maximized"] as? Bool ?? false,
        viewportWidth: parseF(d["viewport_width"]),
        viewportHeight: parseF(d["viewport_height"]),
        nextPaneId: parseInt(d["next_pane_id"])
    )
}

private func parsePanelGroup(_ v: Any?) -> PanelGroup {
    guard let d = v as? [String: Any] else { return PanelGroup(panels: []) }
    let panels = (d["panels"] as? [Any] ?? []).map { parsePanelKind($0) }
    return PanelGroup(
        panels: panels,
        active: parseInt(d["active"]),
        collapsed: d["collapsed"] as? Bool ?? false,
        height: (d["height"] is NSNull || d["height"] == nil) ? nil : parseF(d["height"])
    )
}

private func parseDock(_ v: Any?) -> Dock {
    guard let d = v as? [String: Any] else {
        return Dock.fromParts(id: DockId(0), groups: [], collapsed: false,
                              autoHide: false, width: defaultDockWidth, minWidth: minDockWidth)
    }
    let groups = (d["groups"] as? [Any] ?? []).map { parsePanelGroup($0) }
    return Dock.fromParts(
        id: DockId(parseInt(d["id"])),
        groups: groups,
        collapsed: d["collapsed"] as? Bool ?? false,
        autoHide: d["auto_hide"] as? Bool ?? false,
        width: parseF(d["width"]),
        minWidth: parseF(d["min_width"])
    )
}

private func parseFloatingDock(_ v: Any?) -> FloatingDock {
    guard let d = v as? [String: Any] else {
        return FloatingDock(dock: Dock.fromParts(id: DockId(0), groups: [], collapsed: false,
                                                  autoHide: false, width: defaultDockWidth,
                                                  minWidth: minDockWidth), x: 0, y: 0)
    }
    return FloatingDock(
        dock: parseDock(d["dock"]),
        x: parseF(d["x"]),
        y: parseF(d["y"])
    )
}

private func parseGroupAddr(_ v: Any?) -> GroupAddr {
    guard let d = v as? [String: Any] else {
        return GroupAddr(dockId: DockId(0), groupIdx: 0)
    }
    return GroupAddr(
        dockId: DockId(parseInt(d["dock_id"])),
        groupIdx: parseInt(d["group_idx"])
    )
}

private func parsePanelAddr(_ v: Any?) -> PanelAddr {
    guard let d = v as? [String: Any] else {
        return PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0)
    }
    return PanelAddr(
        group: parseGroupAddr(d["group"]),
        panelIdx: parseInt(d["panel_idx"])
    )
}

/// Parse canonical test JSON into a WorkspaceLayout.
///
/// This is the inverse of ``workspaceToTestJson(_:)``.
public func testJsonToWorkspace(_ json: String) -> WorkspaceLayout {
    let data = json.data(using: .utf8)!
    let v = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

    let anchored = (v["anchored"] as? [Any] ?? []).map { a -> (DockEdge, Dock) in
        let d = a as! [String: Any]
        return (parseDockEdge(d["edge"]), parseDock(d["dock"]))
    }

    let floating = (v["floating"] as? [Any] ?? []).map { parseFloatingDock($0) }

    let hiddenPanels = (v["hidden_panels"] as? [Any] ?? []).map { parsePanelKind($0) }

    let zOrder = (v["z_order"] as? [Any] ?? []).map { DockId(parseInt($0)) }

    let focusedPanel: PanelAddr?
    if v["focused_panel"] is NSNull || v["focused_panel"] == nil {
        focusedPanel = nil
    } else {
        focusedPanel = parsePanelAddr(v["focused_panel"])
    }

    let paneLayout: PaneLayout?
    if v["pane_layout"] is NSNull || v["pane_layout"] == nil {
        paneLayout = nil
    } else {
        paneLayout = parsePaneLayout(v["pane_layout"])
    }

    let name = v["name"] as? String ?? "Default"
    let version = parseInt(v["version"])
    let nextId = parseInt(v["next_id"])
    let appearance = v["appearance"] as? String ?? "dark_gray"

    return WorkspaceLayout.fromParts(
        version: version == 0 ? layoutVersion : version,
        name: name,
        anchored: anchored,
        floating: floating,
        hiddenPanels: hiddenPanels,
        zOrder: zOrder,
        focusedPanel: focusedPanel,
        appearance: appearance,
        paneLayout: paneLayout,
        nextId: nextId
    )
}
