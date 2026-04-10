/// CLI tool for cross-language workspace layout testing.
///
/// Usage:
///   WorkspaceRoundtrip default                       -- canonical JSON for defaultLayout()
///   WorkspaceRoundtrip default_with_panes <w> <h>    -- with pane layout at viewport size
///   WorkspaceRoundtrip parse <workspace.json>        -- parse, output canonical test JSON
///   WorkspaceRoundtrip apply <workspace.json>        -- parse, apply ops from stdin, output canonical test JSON

import Foundation
import JasLib

func readFile(_ path: String) -> String {
    guard let data = FileManager.default.contents(atPath: path),
          let str = String(data: data, encoding: .utf8) else {
        fputs("Failed to read: \(path)\n", stderr)
        exit(1)
    }
    return str.trimmingCharacters(in: .whitespacesAndNewlines)
}

func parsePanelKind(_ s: String) -> PanelKind {
    switch s {
    case "color": return .color
    case "stroke": return .stroke
    case "properties": return .properties
    default: return .layers
    }
}

func parsePaneKind(_ s: String) -> PaneKind {
    switch s {
    case "toolbar": return .toolbar
    case "dock": return .dock
    default: return .canvas
    }
}

func applyOp(_ layout: inout WorkspaceLayout, _ op: [String: Any]) {
    guard let name = op["op"] as? String else { return }
    switch name {
    case "toggle_group_collapsed":
        let addr = GroupAddr(dockId: DockId(op["dock_id"] as! Int), groupIdx: op["group_idx"] as! Int)
        layout.toggleGroupCollapsed(addr)
    case "set_active_panel":
        let addr = PanelAddr(
            group: GroupAddr(dockId: DockId(op["dock_id"] as! Int), groupIdx: op["group_idx"] as! Int),
            panelIdx: op["panel_idx"] as! Int)
        layout.setActivePanel(addr)
    case "close_panel":
        let addr = PanelAddr(
            group: GroupAddr(dockId: DockId(op["dock_id"] as! Int), groupIdx: op["group_idx"] as! Int),
            panelIdx: op["panel_idx"] as! Int)
        layout.closePanel(addr)
    case "show_panel":
        layout.showPanel(parsePanelKind(op["kind"] as! String))
    case "reorder_panel":
        let addr = GroupAddr(dockId: DockId(op["dock_id"] as! Int), groupIdx: op["group_idx"] as! Int)
        layout.reorderPanel(addr, from: op["from"] as! Int, to: op["to"] as! Int)
    case "move_panel_to_group":
        let from = PanelAddr(
            group: GroupAddr(dockId: DockId(op["from_dock_id"] as! Int), groupIdx: op["from_group_idx"] as! Int),
            panelIdx: op["from_panel_idx"] as! Int)
        let to = GroupAddr(dockId: DockId(op["to_dock_id"] as! Int), groupIdx: op["to_group_idx"] as! Int)
        layout.movePanelToGroup(from, to: to)
    case "detach_group":
        let addr = GroupAddr(dockId: DockId(op["dock_id"] as! Int), groupIdx: op["group_idx"] as! Int)
        _ = layout.detachGroup(addr, x: op["x"] as! Double, y: op["y"] as! Double)
    case "redock":
        layout.redock(DockId(op["dock_id"] as! Int))
    case "set_pane_position":
        layout.paneLayout!.setPanePosition(PaneId(op["pane_id"] as! Int), x: op["x"] as! Double, y: op["y"] as! Double)
    case "tile_panes":
        layout.paneLayout!.tilePanes(collapsedOverride: nil)
    case "toggle_canvas_maximized":
        layout.paneLayout!.toggleCanvasMaximized()
    case "resize_pane":
        layout.paneLayout!.resizePane(PaneId(op["pane_id"] as! Int), width: op["width"] as! Double, height: op["height"] as! Double)
    case "hide_pane":
        layout.paneLayout!.hidePane(parsePaneKind(op["kind"] as! String))
    case "show_pane":
        layout.paneLayout!.showPane(parsePaneKind(op["kind"] as! String))
    case "bring_pane_to_front":
        layout.paneLayout!.bringPaneToFront(PaneId(op["pane_id"] as! Int))
    default:
        fputs("Unknown workspace op: \(name)\n", stderr)
        exit(1)
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: \(args[0]) default|default_with_panes|parse|apply ...\n", stderr)
    exit(1)
}

let mode = args[1]

switch mode {
case "default":
    let layout = WorkspaceLayout.defaultLayout()
    print(workspaceToTestJson(layout), terminator: "")

case "default_with_panes":
    guard args.count >= 4,
          let w = Double(args[2]), let h = Double(args[3]) else {
        fputs("Usage: \(args[0]) default_with_panes <width> <height>\n", stderr)
        exit(1)
    }
    var layout = WorkspaceLayout.defaultLayout()
    layout.ensurePaneLayout(viewportW: w, viewportH: h)
    print(workspaceToTestJson(layout), terminator: "")

case "parse":
    guard args.count >= 3 else {
        fputs("Usage: \(args[0]) parse <workspace.json>\n", stderr)
        exit(1)
    }
    let json = readFile(args[2])
    let layout = testJsonToWorkspace(json)
    print(workspaceToTestJson(layout), terminator: "")

case "apply":
    guard args.count >= 3 else {
        fputs("Usage: \(args[0]) apply <workspace.json>  (ops from stdin)\n", stderr)
        exit(1)
    }
    let json = readFile(args[2])
    var layout = testJsonToWorkspace(json)
    var stdinData = Data()
    while let chunk = try? FileHandle.standardInput.availableData, !chunk.isEmpty {
        stdinData.append(chunk)
    }
    let opsStr = String(data: stdinData, encoding: .utf8) ?? "[]"
    guard let opsJson = try? JSONSerialization.jsonObject(with: Data(opsStr.utf8)) as? [[String: Any]] else {
        fputs("Failed to parse ops JSON from stdin\n", stderr)
        exit(1)
    }
    for op in opsJson {
        applyOp(&layout, op)
    }
    print(workspaceToTestJson(layout), terminator: "")

default:
    fputs("Unknown mode: \(mode)\n", stderr)
    exit(1)
}
