import Testing
import Foundation
@testable import JasLib

// STATUS-jas row 141: the Layers row's context menu is drawn from layers.yaml's
// `context_menu:` (on `lp_tree`), in the row's scope, not hand-built. These arms
// hold the two pure pieces the native row draws from:
// * `WidgetEvent.rowBinding`, which finds the foreach row for a path, the one
//   copy the forms runner also uses;
// * `WidgetEvent.contextMenuEntries`, which gives each item's label, its enabled
//   state and the separators, read exactly as the door
//   (`WidgetEvent.contextMenuItem`) reads them.

/// multi_layer.svg: rows, top first, [1] [1,0] [0] [0,0]; two layers, each with
/// one leaf child.
private func twoLayers() -> Model {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../test_fixtures/svg/multi_layer.svg").standardizedFileURL
    let svg = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let model = Model(document: svgToDocument(svg))
    if let ws = WorkspaceData.load(), let panels = ws.panels() {
        for pid in panels.keys.sorted() {
            model.stateStore.initPanel(pid, defaults: ws.panelStateDefaults(pid))
        }
    }
    model.stateStore.setActivePanel("layers_panel_content")
    return model
}

private let pid = "layers_panel_content"

/// The holder (`lp_tree`) and the panel's render scope, as the dock builds it.
private func holderAndScope(_ model: Model) -> ([String: Any], [String: Any])? {
    guard let ws = WorkspaceData.load(), let panel = ws.panel(pid) else { return nil }
    func find(_ n: Any?) -> [String: Any]? {
        guard let d = n as? [String: Any] else { return nil }
        if d["id"] as? String == "lp_tree" { return d }
        for k in ["children", "do"] {
            if let a = d[k] as? [Any] { for c in a { if let f = find(c) { return f } } }
            if let c = d[k] as? [String: Any], let f = find(c) { return f }
        }
        return nil
    }
    guard let holder = find(panel["content"]) else { return nil }
    return (holder, buildPanelBodyContext(ws: ws, model: model, contentId: pid,
                                          opacityPanel: OpacityPanelState()))
}

private func labels(_ es: [WidgetEvent.ContextMenuEntry]) -> [String] {
    es.map { if case .item(let l, _, _) = $0 { return l } else { return "—" } }
}

private func enabled(_ es: [WidgetEvent.ContextMenuEntry], _ label: String) -> Bool? {
    for e in es { if case .item(let l, let on, _) = e, l == label { return on } }
    return nil
}

@Test func rowBindingFindsTheRowByPathAndBindsItAsNode() {
    let model = twoLayers()
    guard let (holder, scope) = holderAndScope(model) else { Issue.record("no lp_tree"); return }
    guard case .success(let (name, data)) = WidgetEvent.rowBinding(holder, scope: scope, row: [1]) else {
        Issue.record("row [1] not bound"); return
    }
    #expect(name == "node")
    #expect(data["type"] as? String == "layer")
    guard case .success(let (_, leaf)) = WidgetEvent.rowBinding(holder, scope: scope, row: [1, 0]) else {
        Issue.record("row [1,0] not bound"); return
    }
    #expect(leaf["type"] as? String != "layer", "CONTROL: a leaf row binds a different node")
    if case .success = WidgetEvent.rowBinding(holder, scope: scope, row: [7]) {
        Issue.record("a row that is not drawn must not bind")
    }
}

@Test func theEntriesAreTheYamlsItemsInTheRowsScope() {
    let model = twoLayers()
    guard let (holder, scope) = holderAndScope(model),
          case .success(let (name, data)) = WidgetEvent.rowBinding(holder, scope: scope, row: [1]) else {
        Issue.record("no row scope"); return
    }
    var rowScope = scope
    rowScope[name] = data
    let es = WidgetEvent.contextMenuEntries(holder, scope: rowScope)
    #expect(labels(es) == ["Options for Layer...", "Duplicate", "Delete Selection", "—",
                           "Enter Isolation Mode", "—", "Flatten Artwork", "Collect in New Layer"])
    #expect(enabled(es, "Options for Layer...") == true, "a layer row may open its options")
    #expect(enabled(es, "Enter Isolation Mode") == true, "a layer is a container")
    #expect(enabled(es, "Duplicate") == true, "an item with no enabled_when is enabled")
    // Each item's index is its position in the yaml list, separators included,
    // because that is the index the door takes.
    var idx: [Int] = []
    for e in es { if case .item(_, _, let i) = e { idx.append(i) } }
    #expect(idx == [0, 1, 2, 4, 6, 7])
}

@Test func aLeafRowDisablesTheLayerOnlyItems() {
    let model = twoLayers()
    guard let (holder, scope) = holderAndScope(model),
          case .success(let (name, data)) = WidgetEvent.rowBinding(holder, scope: scope, row: [1, 0]) else {
        Issue.record("no row scope"); return
    }
    var rowScope = scope
    rowScope[name] = data
    let es = WidgetEvent.contextMenuEntries(holder, scope: rowScope)
    #expect(enabled(es, "Options for Layer...") == false)
    #expect(enabled(es, "Enter Isolation Mode") == false, "a leaf is not a container")
}

@Test func theIsolationItemsLabelFollowsTheIsolationStack() {
    let model = twoLayers()
    #expect(setModelHeldPanelState(pid, "isolation_stack", paths: [[1]], model: model),
            "positive control: the stack is held on the Model and was set")
    guard let (holder, scope) = holderAndScope(model),
          case .success(let (name, data)) = WidgetEvent.rowBinding(holder, scope: scope, row: [1, 0]) else {
        Issue.record("no row scope"); return
    }
    var rowScope = scope
    rowScope[name] = data
    let es = WidgetEvent.contextMenuEntries(holder, scope: rowScope)
    #expect(labels(es).contains("Exit Isolation Mode"), "\(labels(es))")
    #expect(enabled(es, "Exit Isolation Mode") == true, "exit is enabled on any row while isolated")
}
