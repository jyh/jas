import Foundation
import Testing
@testable import JasLib

// swap_panel_state: exchange two keys of one panel's state, as the array form
// (the active panel; Stroke's `stk_swap_arrowheads` widget) or the
// `{panel, keys}` form (the named panel; the `swap_arrowheads` action). The
// reference's `test_swap_panel_state.py` pins the same laws. Until this node
// JasSwift had no arm, so the widget swapped the two globals and left the
// panel's own values where they were.

private func strokeStore() -> StateStore {
    let store = StateStore(defaults: [
        "stroke_start_arrowhead": "simple_arrow", "stroke_end_arrowhead": "none",
        "stroke_start_arrowhead_scale": 100.0, "stroke_end_arrowhead_scale": 150.0])
    store.initPanel("stroke", defaults: [
        "start_arrowhead": "simple_arrow", "end_arrowhead": "none",
        "start_arrowhead_scale": 100.0, "end_arrowhead_scale": 150.0])
    store.setActivePanel("stroke")
    return store
}

private func panel(_ s: StateStore) -> [String] {
    ["start_arrowhead", "end_arrowhead", "start_arrowhead_scale", "end_arrowhead_scale"]
        .map { "\(s.getPanel("stroke", $0) ?? "nil")" }
}

private func run(_ effects: [Any], _ store: StateStore) {
    runEffects(effects, ctx: [:], store: store)
}

private func findWidget(_ node: Any, _ id: String) -> [String: Any]? {
    if let d = node as? [String: Any] {
        if d["id"] as? String == id { return d }
        for v in d.values { if let hit = findWidget(v, id) { return hit } }
    } else if let a = node as? [Any] {
        for v in a { if let hit = findWidget(v, id) { return hit } }
    }
    return nil
}

@Test func swapPanelStateArrayFormSwapsInTheActivePanel() {
    let s = strokeStore()
    run([["swap_panel_state": ["start_arrowhead", "end_arrowhead"]]], s)
    #expect(panel(s) == ["none", "simple_arrow", "100.0", "150.0"])
}

@Test func swapPanelStateObjectFormSwapsInTheNamedPanel() {
    let s = strokeStore()
    s.setActivePanel(nil)
    run([["swap_panel_state": ["panel": "stroke",
                               "keys": ["start_arrowhead_scale", "end_arrowhead_scale"]]]], s)
    #expect(panel(s) == ["simple_arrow", "none", "150.0", "100.0"])
}

@Test func swapPanelStateNotTwoNamesIsANoOp() {
    for keys: Any in [["start_arrowhead"], ["start_arrowhead", "end_arrowhead", "x"], [String](), "start_arrowhead"] {
        // One store PER FORM: on one store a wrongly accepted list swaps twice
        // and restores itself (a mutant accepting 3 names survived).
        for eff: [String: Any] in [["swap_panel_state": keys],
                                   ["swap_panel_state": ["panel": "stroke", "keys": keys]]] {
            let s = strokeStore()
            run([eff], s)
            #expect(panel(s) == ["simple_arrow", "none", "100.0", "150.0"], "\(eff)")
        }
    }
}

@Test func theRealSwapArrowheadsWidgetSwapsPanelAndGlobals() throws {
    let ws = try #require(WorkspaceData.load())
    let widget = try #require(findWidget(ws.data["panels"] as Any, "stk_swap_arrowheads"))
    let behavior = try #require((widget["behavior"] as? [[String: Any]])?.first)
    let effects = try #require(behavior["effects"] as? [Any])
    let s = strokeStore()
    run(effects, s)
    #expect(panel(s) == ["none", "simple_arrow", "150.0", "100.0"])
    #expect(s.get("stroke_start_arrowhead") as? String == "none")
}
