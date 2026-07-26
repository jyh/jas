import Testing
import Foundation
@testable import JasLib

// MARK: - The compiled bundle is parsed ONCE
//
// ``WorkspaceData/load()`` re-read and re-parsed workspace.json — 1.4 MB of
// JSON — on EVERY call, and it has ~40 callers, some of them inside SwiftUI
// bodies. ``liveSwatchPaint`` is the worst of them: the toolbar's fill / stroke
// squares call it while a MIXED selection is live, and that arm reaches the
// bundle for one key, twice per redraw.
//
// Rust has never had this problem: `Workspace::load()` hands out a reference to
// a `OnceLock`-cached parse (jas_dioxus/src/interpreter/workspace.rs). This is
// that shape — a `static let`, which Swift initialises lazily and exactly once.
// ``WorkspaceData`` is immutable (`let data`), so one instance is safely shared.

@Test func workspaceBundleIsParsedOnceNotPerCall() {
    let first = WorkspaceData.load()
    let second = WorkspaceData.load()
    #expect(first != nil, "the bundle must load at all")
    #expect(first === second,
            """
            two loads must be the SAME instance — a fresh instance per call \
            means the 1.4 MB bundle was re-read and re-parsed, which is what \
            liveSwatchPaint did inside a SwiftUI body
            """)
}

/// The cached instance still answers, so the callers that reach it for one key
/// are unaffected by the caching.
@Test func cachedBundleStillAnswersStateDefaults() {
    let defaults = WorkspaceData.load()?.stateDefaults()
    #expect(defaults?["fill_color"] as? String == "#ffffff")
    #expect(defaults?["stroke_color"] as? String == "#000000")
}

/// The MIXED arm is the one that reaches the bundle: nothing is published, so
/// the DECLARED default stands. Coverage for the arm the caching lives in — it
/// passed before the caching change too (behaviour is unchanged by design).
@Test func toolbarSquaresShowTheDeclaredDefaultForMixed() {
    let mixed = Model(document: Document(
        layers: [Layer(children: [
            .rect(Rect(x: 0, y: 0, width: 10, height: 10,
                       fill: Fill(color: Color(r: 1, g: 0, b: 0)),
                       stroke: Stroke(color: .black))),
            .rect(Rect(x: 0, y: 0, width: 10, height: 10,
                       fill: Fill(color: Color(r: 0, g: 0, b: 1)),
                       stroke: Stroke(color: .black))),
        ])],
        selectedLayer: 0,
        selection: [ElementSelection(path: [0, 0]), ElementSelection(path: [0, 1])]))
    #expect(liveSwatchPaint(model: mixed, isFill: true) == Color(r: 1, g: 1, b: 1),
            "Mixed publishes nothing, so state.yaml's declared #ffffff stands")
}
