import Testing
import Foundation
import Combine
@testable import JasLib

// Row 220: `panelDispatch` publishes the panel-state write it makes.
//
// The dock's panel bodies hold the model as an @ObservedObject, so they redraw
// on any `objectWillChange`; the `StateStore` publishes nothing. Most kinds'
// dispatchers already bump `panelStateVersion` (Character and Opacity: the two
// narrow arms below passed on main, so they witness the value flips, not the
// fix). The population arm found the gap: three Artboards rows (Duplicate,
// Delete, Delete Empty) set `rearrange_dirty`, the Rearrange badge, and when
// they change no document nothing is published. `panelDispatch` now bumps
// after every kind's dispatch.

private func dispatchOnce(_ kind: PanelKind, _ cmd: String, _ model: Model) {
    var layout = WorkspaceLayout.defaultLayout()
    let addr = PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0)
    panelDispatch(kind, cmd: cmd, addr: addr, layout: &layout, model: model)
}

@Test func theCharacterMenuToggleWritesAndPublishesBothWays() {
    let model = Model(document: Document.newEmptyDocument())
    let pid = "character_panel_content"
    let v0 = model.panelStateVersion
    dispatchOnce(.character, "toggle_snap_to_glyph_visible", model)
    // panelDispatch seeds the scope from its YAML defaults (shown), then toggles.
    #expect(model.stateStore.getPanel(pid, "snap_to_glyph_visible") as? Bool == false)
    let v1 = model.panelStateVersion
    #expect(v1 != v0)
    dispatchOnce(.character, "toggle_snap_to_glyph_visible", model)
    #expect(model.stateStore.getPanel(pid, "snap_to_glyph_visible") as? Bool == true)
    #expect(model.panelStateVersion != v1)
}

@Test func aSecondPanelKindsMenuTogglePublishesToo() {
    // The publish belongs to panelDispatch, not to one kind's dispatcher.
    let model = Model(document: Document.newEmptyDocument())
    let pid = "opacity_panel_content"
    let v0 = model.panelStateVersion
    dispatchOnce(.opacity, "toggle_opacity_thumbnails", model)
    // opacity.yaml declares thumbnails_hidden false; the menu row hides them.
    #expect(model.stateStore.getPanel(pid, "thumbnails_hidden") as? Bool == true)
    #expect(model.panelStateVersion != v0)
}

/// Every `set_panel_state` effect anywhere under an action's effects.
private func writesPanelState(_ o: Any) -> Bool {
    if let d = o as? [String: Any] {
        if d["set_panel_state"] != nil { return true }
        return d.values.contains(where: writesPanelState)
    }
    if let a = o as? [Any] { return a.contains(where: writesPanelState) }
    return false
}

@Test func everyPanelMenuRowThatWritesPanelStatePublishes() throws {
    // The population is derived from the workspace, never typed: each panel
    // kind's menu rows whose action writes panel state (row 218's census).
    let ws = try #require(WorkspaceData.load())
    let actions = try #require(ws.data["actions"] as? [String: Any])
    var population: [(PanelKind, String)] = []
    for kind in PanelKind.all + [.brushes, .gradient, .concepts] {
        for entry in ws.panelMenuRaw(panelKindToContentId(kind)) {
            guard let obj = entry as? [String: Any], let name = obj["action"] as? String,
                  let def = actions[name] as? [String: Any],
                  writesPanelState(def["effects"] ?? []) else { continue }
            population.append((kind, commandWithParams(obj)))
        }
    }
    // Anti-vacuity: the census ran, and over a population holding the control.
    #expect(!population.isEmpty)
    #expect(population.contains { $0.0 == .character && $0.1 == "toggle_snap_to_glyph_visible" },
            "the control is in the population")
    // The panel body holds the model as an @ObservedObject, so ANY
    // objectWillChange redraws it (a document change included), not only a
    // panelStateVersion bump: count what the view actually observes.
    var silent: [String] = []
    var unwitnessed: [String] = []
    for (kind, cmd) in population {
        let model = Model(document: Document.newEmptyDocument())
        let pid = panelKindToContentId(kind)
        if !model.stateStore.hasPanel(pid) {
            model.stateStore.initPanel(pid, defaults: ws.panelStateDefaults(pid))
        }
        let before = model.stateStore.getPanelState(pid) as NSDictionary
        var emitted = 0
        let sub = model.objectWillChange.sink { _ in emitted += 1 }
        dispatchOnce(kind, cmd, model)
        sub.cancel()
        let after = model.stateStore.getPanelState(pid) as NSDictionary
        // A row that changed nothing in its fixture has nothing to announce;
        // the defect is a panel write the view is never told about.
        if emitted == 0 && !before.isEqual(after) {
            let keys = Set((before.allKeys + after.allKeys).compactMap { $0 as? String })
                .filter { !((before[$0] as AnyObject?)?.isEqual(after[$0]) ?? (after[$0] == nil)) }
                .sorted()
            let shown = keys.map { "\($0): \(before[$0] ?? "absent") -> \(after[$0] ?? "absent")" }
            silent.append("\(pid) \(cmd) {\(shown.joined(separator: "; "))}")
        }
        if emitted == 0 && before.isEqual(after) { unwitnessed.append("\(pid) \(cmd)") }
    }
    #expect(silent.isEmpty, "rows whose write publishes nothing (\(population.count) driven): \(silent)")
    print("row 218 census: \(population.count) driven; no change in this fixture, so unwitnessed: \(unwitnessed)")
}
