import Foundation
import Testing
@testable import JasLib

/// The gate ``ViewActions`` had to build for itself.
///
/// WHY IT HAS TO BE BUILT HERE. The action corpus
/// (`test_fixtures/actions/view_state.json`) gates the `doc.zoom.*` EFFECTS
/// through `LayersPanel.dispatchYamlAction`. No corpus vector can reach the
/// user's route — the View menu, the canvas keyboard chords, the toolbar
/// double-click — because each of those was a `private func` on a SwiftUI view
/// or an AppKit responder, switching on the verb name and calling a native
/// `Model` method with constants hardcoded in Swift. So a fix to a `doc.zoom.*`
/// effect passed the corpus and changed nothing a user could see. That is worse
/// than an honest hole: it manufactures confidence. (Recorded as the
/// `view-actions-bypass-yaml-in-swift` coverage gap; RULED 2026-07-27,
/// transcripts/ZOOM_TOOL.md.)
///
/// WHAT THIS FILE ASSERTS. For each of the six verbs, the seam every user path
/// now goes through (``ViewActions/dispatch``) must land the view triple on the
/// value the SPEC produces — recomputed here from the seed and from the LIVE
/// workspace preferences, by the formulas in transcripts/ZOOM_TOOL.md §Anchor
/// and clamp math and §Keyboard shortcuts and actions. The expectations are a
/// third implementation of those formulas, in the same spirit as the corpus
/// goldens (which are CPython evaluations of the same block): no expectation
/// below is a value captured from either implementation.
///
/// ITS BLIND SPOT, stated. This file gates the SEAM, not the three call sites'
/// use of it. A future surface that re-implements a verb natively instead of
/// calling ``ViewActions/dispatch`` is invisible here;
/// ``viewVerbsHaveNoNativeReimplementation`` covers exactly that, by reading the
/// three source files, and it in turn is blind to a native reimplementation
/// under a name it does not know. Neither can see a NEW View verb that is never
/// added to ``ViewActions/names``.

// MARK: - The seed and the spec formulas

/// Viewport + view seed shared by every case: deliberately non-identity, so the
/// multiply/divide-by-zoom half of every formula has to be right (the identity
/// view is algebraically the identity and cannot fail — CORPUS_CENSUS.md §5.7).
private let vw = 800.0
private let vh = 600.0
private let seedZoom = 4.0
private let seedOffX = -300.0
private let seedOffY = -200.0

/// Read a viewport preference out of the LIVE compiled workspace, so an
/// expectation below follows `workspace/preferences.yaml` rather than repeating
/// a literal. This is what makes the hardcoded-constant class visible at all: a
/// route that hardcodes 1.2 agrees with the workspace only by coincidence, and
/// the day the preference moves, this test moves with the workspace and the
/// route does not.
private func pref(_ key: String, _ fallback: Double) -> Double {
    guard let prefs = WorkspaceData.load()?.data["preferences"] as? [String: Any],
          let viewport = prefs["viewport"] as? [String: Any],
          let n = viewport[key] as? NSNumber
    else { return fallback }
    return n.doubleValue
}

/// transcripts/ZOOM_TOOL.md §Anchor and clamp math, with the default anchor at
/// the viewport centre (the -1 sentinel, RULED 2026-07-27).
private func specZoomCentred(factor: Double) -> (Double, Double, Double) {
    let minZ = pref("min_zoom", 0.1), maxZ = pref("max_zoom", 64.0)
    let ax = vw / 2.0, ay = vh / 2.0
    let docAx = (ax - seedOffX) / seedZoom
    let docAy = (ay - seedOffY) / seedZoom
    let zNew = min(max(seedZoom * factor, minZ), maxZ)
    return (zNew, ax - docAx * zNew, ay - docAy * zNew)
}

/// The same file's `zoom_fit_rect` primitive: fit a document rect inside the
/// viewport with screen-space padding, centred.
private func specFitRect(_ x: Double, _ y: Double,
                         _ w: Double, _ h: Double) -> (Double, Double, Double) {
    let minZ = pref("min_zoom", 0.1), maxZ = pref("max_zoom", 64.0)
    let pad = pref("fit_padding_px", 20.0)
    let z = min(max(min((vw - 2 * pad) / w, (vh - 2 * pad) / h), minZ), maxZ)
    return (z, vw / 2.0 - (x + w / 2.0) * z, vh / 2.0 - (y + h / 2.0) * z)
}

// MARK: - Fixtures

/// Two artboards whose rects differ in BOTH dimensions, so "first" and
/// "panel-selected" cannot coincide numerically, plus one un-stroked rect at a
/// known box. `ab2` is the panel-selected board in every case below.
private let ab1Rect = (x: 0.0, y: 0.0, w: 100.0, h: 80.0)
private let ab2Rect = (x: 200.0, y: 150.0, w: 120.0, h: 60.0)
private let contentRect = (x: 10.0, y: 20.0, w: 30.0, h: 40.0)

private func seededModel(withContent: Bool = true,
                         panelSelectAb2: Bool = true) -> Model {
    // No stroke: an un-stroked rect's bounds are exactly its box, so the
    // fit_in_window expectation needs no stroke-inflation term.
    let rect = Element.rect(Rect(
        x: contentRect.x, y: contentRect.y,
        width: contentRect.w, height: contentRect.h))
    let doc = Document(
        layers: [Layer(children: withContent ? [rect] : [])],
        artboards: [
            Artboard.defaultWithId("ab1")
                .with(x: ab1Rect.x, y: ab1Rect.y,
                      width: ab1Rect.w, height: ab1Rect.h),
            Artboard.defaultWithId("ab2")
                .with(x: ab2Rect.x, y: ab2Rect.y,
                      width: ab2Rect.w, height: ab2Rect.h),
        ])
    let model = Model(document: doc)
    model.viewportW = vw
    model.viewportH = vh
    model.zoomLevel = seedZoom
    model.viewOffsetX = seedOffX
    model.viewOffsetY = seedOffY
    if panelSelectAb2 {
        // Seed the selection through the SAME scope `artboards_panel_select`'s
        // `set_panel_state` writes (the store keys panel state by content id;
        // the effect normalises the short `artboards` name to it), and
        // INITIALIZE that scope first: `setPanel` is an optional-chained write
        // and is a silent no-op on a scope that does not exist yet, which a
        // fresh Model's store has not created. Seeding it the way
        // `DockPanelView` does makes this a faithful stand-in for a live app
        // whose Artboards panel has been shown and a row clicked.
        let scope = artboardsPanelScope
        let defaults = WorkspaceData.load()?.panelStateDefaults(scope) ?? [:]
        model.stateStore.initPanel(scope, defaults: defaults)
        model.stateStore.setPanel(scope, "artboards_panel_selection", ["ab2"])
        #expect((model.stateStore.getPanel(scope, "artboards_panel_selection")
                    as? [Any])?.compactMap { $0 as? String } == ["ab2"],
                "seed guard: the panel selection must actually be stored")
    }
    return model
}

private func triple(_ m: Model) -> (Double, Double, Double) {
    (m.zoomLevel, m.viewOffsetX, m.viewOffsetY)
}

private func expectTriple(_ got: (Double, Double, Double),
                          _ want: (Double, Double, Double),
                          _ verb: String) {
    #expect(got.0 == want.0,
        "\(verb): zoom_level is \(got.0), spec says \(want.0)")
    #expect(got.1 == want.1,
        "\(verb): view_offset_x is \(got.1), spec says \(want.1)")
    #expect(got.2 == want.2,
        "\(verb): view_offset_y is \(got.2), spec says \(want.2)")
}

// MARK: - The geometry pin the batteries below lean on

/// The fit_in_window expectations use `contentRect` as the document's element
/// bounds. Pin that first, as a GEOMETRY VALUE, so a change in `documentBounds`
/// shows up as itself instead of silently re-basing three other assertions. An
/// un-stroked rect's bounds are its box.
@Test func seededModelContentBoundsAreTheRectBox() {
    let b = documentBounds(seededModel().document)
    #expect(b.x == contentRect.x)
    #expect(b.y == contentRect.y)
    #expect(b.w == contentRect.w)
    #expect(b.h == contentRect.h)
}

// MARK: - The route lands on the spec value, verb by verb

@Test func viewRouteZoomInAnchorsAtViewportCentre() {
    let m = seededModel()
    ViewActions.dispatch("zoom_in", model: m)
    expectTriple(triple(m), specZoomCentred(factor: pref("zoom_step", 1.2)),
                 "zoom_in")
}

@Test func viewRouteZoomOutAnchorsAtViewportCentre() {
    let m = seededModel()
    ViewActions.dispatch("zoom_out", model: m)
    expectTriple(triple(m), specZoomCentred(factor: 1.0 / pref("zoom_step", 1.2)),
                 "zoom_out")
}

/// RULED 2026-07-27: Ctrl+1 RECENTRES. The doc point under the viewport centre
/// stays under it; `view_offset` is the doc ORIGIN's screen position, so holding
/// it fixed while zoom goes 4x -> 1x walks the artwork off the canvas.
@Test func viewRouteZoomToActualSizeRecentres() {
    let m = seededModel()
    ViewActions.dispatch("zoom_to_actual_size", model: m)
    let want = specZoomCentred(factor: 1.0 / seedZoom) // z_new == 1.0
    #expect(want.0 == 1.0, "guard: the seed must reach exactly 100%")
    expectTriple(triple(m), want, "zoom_to_actual_size")
    // The requirement in its own terms, not as a consequence of a field: the
    // artist keeps looking at the same document point.
    let docBefore = ((vw / 2 - seedOffX) / seedZoom, (vh / 2 - seedOffY) / seedZoom)
    let docAfter = ((vw / 2 - m.viewOffsetX) / m.zoomLevel,
                    (vh / 2 - m.viewOffsetY) / m.zoomLevel)
    #expect(abs(docBefore.0 - docAfter.0) < 1e-9)
    #expect(abs(docBefore.1 - docAfter.1) < 1e-9)
}

/// `fit_active_artboard` fits `active_document.current_artboard` — the topmost
/// PANEL-SELECTED artboard, else the first (ARTBOARDS.md §Selection semantics).
/// `ab2` is selected here, so a route that reaches for `artboards.first` lands
/// on a measurably different triple.
@Test func viewRouteFitActiveArtboardHonoursThePanelSelection() {
    let m = seededModel()
    ViewActions.dispatch("fit_active_artboard", model: m)
    expectTriple(triple(m),
                 specFitRect(ab2Rect.x, ab2Rect.y, ab2Rect.w, ab2Rect.h),
                 "fit_active_artboard (ab2 panel-selected)")
    // …and the first board is genuinely a different answer, so the assertion
    // above is discriminating rather than accidentally satisfied.
    let alt = specFitRect(ab1Rect.x, ab1Rect.y, ab1Rect.w, ab1Rect.h)
    #expect(alt.0 != specFitRect(ab2Rect.x, ab2Rect.y, ab2Rect.w, ab2Rect.h).0,
        "guard: the two artboards must fit at different zooms")
}

/// With NO panel selection the current artboard is the first one — the other
/// half of the same rule.
@Test func viewRouteFitActiveArtboardFallsBackToTheFirstBoard() {
    let m = seededModel(panelSelectAb2: false)
    ViewActions.dispatch("fit_active_artboard", model: m)
    expectTriple(triple(m),
                 specFitRect(ab1Rect.x, ab1Rect.y, ab1Rect.w, ab1Rect.h),
                 "fit_active_artboard (no panel selection)")
}

@Test func viewRouteFitAllArtboardsFitsTheUnion() {
    let m = seededModel()
    ViewActions.dispatch("fit_all_artboards", model: m)
    let minX = min(ab1Rect.x, ab2Rect.x), minY = min(ab1Rect.y, ab2Rect.y)
    let maxX = max(ab1Rect.x + ab1Rect.w, ab2Rect.x + ab2Rect.w)
    let maxY = max(ab1Rect.y + ab1Rect.h, ab2Rect.y + ab2Rect.h)
    expectTriple(triple(m), specFitRect(minX, minY, maxX - minX, maxY - minY),
                 "fit_all_artboards")
}

@Test func viewRouteFitInWindowFitsTheElementBounds() {
    let m = seededModel()
    ViewActions.dispatch("fit_in_window", model: m)
    expectTriple(triple(m),
                 specFitRect(contentRect.x, contentRect.y,
                             contentRect.w, contentRect.h),
                 "fit_in_window")
}

/// The degenerate case the spec legislates and the native path did not: an EMPTY
/// document fits at 100% centred on the origin (`doc.zoom.fit_elements`, empty
/// bounds arm). The native `fitRect` guarded `w > 0` and returned, leaving
/// whatever view was standing — so Fit in Window on an empty canvas did nothing
/// at all, at any zoom.
@Test func viewRouteFitInWindowOnEmptyDocumentCentresAt100Percent() {
    let m = seededModel(withContent: false)
    ViewActions.dispatch("fit_in_window", model: m)
    expectTriple(triple(m), (1.0, vw / 2.0, vh / 2.0),
                 "fit_in_window (empty document)")
}

// MARK: - The route is the YAML route, not a lookalike

/// Whatever the seam does, it must be what the CORPUS gates. Every verb is
/// dispatched twice from identical seeds — once through the user seam, once
/// through `LayersPanel.dispatchYamlAction`, the dispatcher
/// `test_fixtures/actions/view_state.json` drives — and the triples must be
/// identical. This is the assertion that ties the gated road to the driven one;
/// on its own it would be satisfiable by making both wrong, which is why the
/// absolute spec-derived batteries above exist alongside it.
@Test func viewRouteAgreesWithTheDispatcherTheCorpusDrives() {
    for verb in ViewActions.names {
        let viaSeam = seededModel()
        ViewActions.dispatch(verb, model: viaSeam)

        let viaYaml = seededModel()
        LayersPanel.dispatchYamlAction(verb, model: viaYaml,
                                       artboardsPanelSelection: ["ab2"])
        expectTriple(triple(viaSeam), triple(viaYaml),
                     "\(verb): user seam vs the dispatcher the corpus drives")
    }
}

/// Every name in ``ViewActions/names`` is a real action in the compiled
/// workspace whose effects are `doc.zoom.*` — so the list cannot rot into a verb
/// the workspace does not define (which would dispatch to nothing and look like
/// a dead menu item), and cannot quietly gain a verb that mutates the document.
@Test func viewActionNamesAreDeclaredViewEffectsInTheWorkspace() {
    let actions = WorkspaceData.load()?.data["actions"] as? [String: Any] ?? [:]
    #expect(!actions.isEmpty)
    for verb in ViewActions.names {
        guard let def = actions[verb] as? [String: Any],
              let effects = def["effects"] as? [Any] else {
            Issue.record("ViewActions.names has '\(verb)', which the workspace does not declare with effects")
            continue
        }
        for eff in effects {
            let keys = (eff as? [String: Any])?.keys.sorted() ?? []
            for k in keys {
                let why = "'\(verb)' declares effect '\(k)'; a View verb routed through this seam must only touch view state"
                #expect(k.hasPrefix("doc.zoom."), Comment(rawValue: why))
            }
        }
    }
}

/// The three call sites must not re-implement a verb natively. Read as SOURCE
/// TEXT, because there is no runtime handle on a `private func` in a SwiftUI
/// view or an AppKit responder — the very fact that made this class invisible.
/// Blind spot, stated: it can only recognise the native entry points that
/// existed when it was written.
@Test func viewVerbsHaveNoNativeReimplementation() {
    let canvasTestsDir = (#filePath as NSString).deletingLastPathComponent
    let testsDir = (canvasTestsDir as NSString).deletingLastPathComponent
    let jasSwiftDir = (testsDir as NSString).deletingLastPathComponent
    let sourcesDir = (jasSwiftDir as NSString).appendingPathComponent("Sources")
    let banned = [
        "zoomIn(", "zoomOut(", "zoomToActualSize(",
        "fitActiveArtboard(", "fitAllArtboards(", "fitInWindow(",
        "applyZoomCentered(", "applyZoomAnchored(",
    ]
    for file in ["Menu/JasCommands.swift",
                 "Canvas/ContentView.swift",
                 "Canvas/CanvasSubwindow.swift",
                 "Document/Model.swift"] {
        let path = (sourcesDir as NSString).appendingPathComponent(file)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            Issue.record("could not read \(path)")
            continue
        }
        for token in banned {
            let why = "\(file) mentions '\(token)'. The six View verbs route through ViewActions.dispatch, which dispatches the YAML action; a native re-implementation reintroduces the hardcoded zoom_step / clamp / padding constants and the artboards.first rule the 2026-07-27 ruling removed."
            #expect(!text.contains(token), Comment(rawValue: why))
        }
    }
}
