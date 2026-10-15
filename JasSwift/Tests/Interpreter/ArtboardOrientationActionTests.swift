import Foundation
import Testing
@testable import JasLib

// `toggle_artboard_orientation` is effects in actions.yaml (2026-10-15, flask
// STATUS §290), run here by Swift's own interpreter, as the reference's
// test_artboard_orientation.py and Rust's
// dialog_event_landscape_swaps_the_artboard_around_its_anchor: around the
// centre anchor, 100x200 at (10, 20) becomes 200x100 at (-40, 70).
@Test func toggleArtboardOrientationSwapsAroundTheAnchor() throws {
    let ws = try #require(WorkspaceData.load())
    let actions = try #require(ws.actions())
    let action = try #require(actions["toggle_artboard_orientation"] as? [String: Any])
    let effects = try #require(action["effects"] as? [Any])
    let store = StateStore()
    store.initPanel("artboards", defaults: ["reference_point": "center"])
    store.setActivePanel("artboards")
    store.initDialog("artboard_options", defaults: ["width": 100.0, "height": 200.0,
                                                     "x_stored": 10.0, "y_stored": 20.0])
    runEffects(effects, ctx: [:], store: store, actions: actions)
    let n = { (k: String) in (store.getDialog(k) as? NSNumber)?.doubleValue ?? .nan }
    #expect(n("width") == 200 && n("height") == 100, "the size swaps")
    #expect(n("x_stored") == -40 && n("y_stored") == 70, "the centre stays put")
}
