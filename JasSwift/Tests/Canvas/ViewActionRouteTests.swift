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

// MARK: - FITPHANTOM: what Fit in Window frames when the artwork is an instance

/// Twin of Rust's `document_bounds_must_not_invent_a_point_at_the_origin`
/// (document/evaluated_bounds.rs). A symbol instance measures its TARGET's
/// geometry; the resolver-less `Element.bounds` answers a zero box at the
/// ORIGIN for it, so the frame used to be dragged back there.
@Test func documentBoundsMustNotInventAPointAtTheOrigin() {
    let master = Element.rect(Rect(x: 5, y: 7, width: 10, height: 20, id: "m1"))
    let instance = Element.live(.reference(ReferenceElem(
        target: ElementRef("m1"), name: nil, id: "i1")))
    let doc = Document(layers: [Layer(children: [instance])], symbols: [master])

    let b = documentBounds(doc)
    #expect(b.x == 5 && b.y == 7 && b.w == 10 && b.h == 20,
            "Fit in Window frames the ARTWORK, not a phantom point at the origin")
}

/// And the union case: an instance beside a distant rect must not stretch the
/// frame back to (0,0).
@Test func documentBoundsUnionSkipsWhatResolvesToNothing() {
    let master = Element.rect(Rect(x: 5, y: 7, width: 10, height: 20, id: "m1"))
    let instance = Element.live(.reference(ReferenceElem(
        target: ElementRef("m1"), name: nil, id: "i1")))
    let dangling = Element.live(.reference(ReferenceElem(
        target: ElementRef("gone"), name: nil, id: "i2")))
    let far = Element.rect(Rect(x: 100, y: 100, width: 10, height: 10))
    let doc = Document(layers: [Layer(children: [instance, dangling, far])],
                       symbols: [master])

    let b = documentBounds(doc)
    #expect(b.x == 5 && b.y == 7 && b.w == 105 && b.h == 103,
            "the resolved instance and the far rect bound it; a dangling reference contributes nothing, not the origin")
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

/// F13 — CHARACTERISATION, NOT ENDORSEMENT. **BANKED FOR JYH.**
///
/// Both ports test `bounds.w <= 0 || bounds.h <= 0`, so a document holding only
/// a ZERO-WIDTH shape — a vertical line, a single point — takes the EMPTY arm
/// and jumps to 100% at the origin instead of fitting the artwork. Both ports
/// agree, so no equivalence gate can see it; this test and its Rust twin
/// (`test_doc_zoom_fit_elements_zero_width_shape_is_treated_as_empty_banked`)
/// make the behaviour VISIBLE so a change to it has to be deliberate.
///
/// NOT fixed here: "fit a zero-width shape" needs a ruling, not a guess.
///   1. w == 0 XOR h == 0 — fit the non-degenerate axis (a 10-unit line then
///      fills the viewport at zoom 86, clamped to max_zoom 64), or keep 100%
///      and merely CENTRE on the shape?
///   2. w == 0 AND h == 0 (a single point) — no zoom is determined at all.
///   3. `fitRectIntoViewport` carries the same `w <= 0` guard and is shared by
///      fit_rect / fit_marquee / fit_active_artboard / fit_all_artboards, so
///      any answer has to say whether it changes those four too.
@Test func fitInWindowOnAZeroWidthShapeIsTreatedAsEmpty() {
    // A vertical, un-stroked line at x = 500: real artwork, zero width.
    let line = Element.line(Line(x1: 500, y1: 100, x2: 500, y2: 400))
    let doc = Document(
        layers: [Layer(children: [line])],
        artboards: [Artboard.defaultWithId("ab1")])
    let m = Model(document: doc)
    m.viewportW = vw
    m.viewportH = vh
    m.zoomLevel = seedZoom
    m.viewOffsetX = seedOffX
    m.viewOffsetY = seedOffY
    let b = documentBounds(m.document)
    #expect(b.x == 500 && b.y == 100 && b.w == 0 && b.h == 300,
            "guard: the line has zero width and real height")

    ViewActions.dispatch("fit_in_window", model: m)

    // TODAY'S ANSWER: the empty arm. The artwork at x = 500 is not even on
    // screen afterwards — the view is centred on the ORIGIN at 100%.
    expectTriple(triple(m), (1.0, vw / 2.0, vh / 2.0),
                 "banked: zero-width artwork takes the EMPTY arm")
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

/// The View-verb call sites, plus the two files that hold the shared centring
/// and dispatch seams. Read as SOURCE TEXT, because there is no runtime handle
/// on a `private func` in a SwiftUI view or an AppKit responder — the very fact
/// that made this class invisible.
/// Blind spot, stated: it can only recognise the native entry points that
/// existed when it was written; see
/// ``viewPreferenceConstantsAreNeverCopiedIntoTheseFiles`` for the guard that
/// does NOT depend on knowing a name.
private let viewRouteGuardedFiles = [
    "Menu/JasCommands.swift",
    "Canvas/ContentView.swift",
    "Canvas/CanvasSubwindow.swift",
    "Canvas/Session.swift",
    "Canvas/ViewActions.swift",
    "Document/Model.swift",
]

private func viewRouteSourcesDir() -> NSString {
    let canvasTestsDir = (#filePath as NSString).deletingLastPathComponent
    let testsDir = (canvasTestsDir as NSString).deletingLastPathComponent
    let jasSwiftDir = (testsDir as NSString).deletingLastPathComponent
    return (jasSwiftDir as NSString).appendingPathComponent("Sources") as NSString
}

@Test func viewVerbsHaveNoNativeReimplementation() {
    let sourcesDir = viewRouteSourcesDir()
    let banned = [
        "zoomIn(", "zoomOut(", "zoomToActualSize(",
        "fitActiveArtboard(", "fitAllArtboards(", "fitInWindow(",
        "applyZoomCentered(", "applyZoomAnchored(",
    ]
    for file in viewRouteGuardedFiles {
        let path = sourcesDir.appendingPathComponent(file)
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

/// THE RESIDUE GUARD, widened past the name check above.
///
/// WHY THE NAME CHECK WAS NOT ENOUGH. The 2026-07-27 wave deleted nine native
/// View-verb reimplementations and left ``viewVerbsHaveNoNativeReimplementation``
/// behind to stop them regrowing — by NAME. Two survivors were invisible to it,
/// one per port, because they were not named after a verb:
/// `Model.centerViewOnCurrentArtboard` carried `let pad = 20.0` and
/// `min(max(zFit, 0.1), 64.0)` — literal copies of `fit_padding_px`, `min_zoom`
/// and `max_zoom`. Adding `centerViewOnCurrentArtboard(` to the banned list
/// would be wrong: that function is legitimate and lives in one of the scanned
/// files. The class is not "a function with a verb's name" but "a Swift-side
/// COPY of a viewport preference", so this guard bans the VALUES.
///
/// The banned literals are READ FROM `workspace/preferences.yaml` (via the
/// bundle), not typed here — so the guard tracks the preference file rather
/// than repeating it, which is the same discipline the expectations above use.
///
/// Exempt: lines calling `readPrefNumber` (its `default:` argument legitimately
/// names the value), comment lines, and lines carrying the explicit marker
/// `not-a-viewport-pref` for an unrelated number that happens to collide.
@Test func viewPreferenceConstantsAreNeverCopiedIntoTheseFiles() {
    let sourcesDir = viewRouteSourcesDir()
    // Spell each preference the way Swift source would: with a decimal point.
    // A bare integer spelling ("64", "20") is far too common to ban.
    let bannedLiterals: [(String, String)] = ["zoom_step", "min_zoom",
                                              "max_zoom", "fit_padding_px"]
        .map { ($0, String(format: "%g", pref($0, .nan))) }
        .map { (name, g) in (name, g.contains(".") ? g : g + ".0") }
    #expect(!bannedLiterals.contains { $0.1.contains("nan") },
            "guard: every viewport preference must be readable from the bundle")

    for file in viewRouteGuardedFiles {
        let path = sourcesDir.appendingPathComponent(file)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            Issue.record("could not read \(path)")
            continue
        }
        for (lineNo, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { continue }
            if line.contains("readPrefNumber") { continue }
            if line.contains("not-a-viewport-pref") { continue }
            for (name, literal) in bannedLiterals {
                guard let r = line.range(of: literal) else { continue }
                // Require a real token boundary so "164.0" or "0.15" do not
                // trip on "64.0" / "0.1".
                let digits = CharacterSet(charactersIn: "0123456789.")
                if let before = line[..<r.lowerBound].unicodeScalars.last,
                   digits.contains(before) { continue }
                if let after = line[r.upperBound...].unicodeScalars.first,
                   digits.contains(after) { continue }
                Issue.record(Comment(rawValue:
                    "\(file):\(lineNo + 1) writes the literal \(literal), which is the "
                    + "current value of preferences.viewport.\(name). Read it with "
                    + "readPrefNumber(\"\(name)\", default:) instead — a copy agrees "
                    + "with the workspace only until the preference moves, and that "
                    + "coincidence is exactly what hid the two survivors of the "
                    + "2026-07-27 zoom wave. If the number is unrelated, append the "
                    + "marker comment 'not-a-viewport-pref' with a reason.\n"
                    + "    \(line)"))
            }
        }
    }
}

// MARK: - F7: the centring the wave's deletion missed

/// `centerViewOnCurrentArtboard` is not named after a View verb, so it survived
/// the deletion still carrying `let pad = 20.0`, `min(max(zFit, 0.1), 64.0)`
/// and `document.artboards.first`. The tests below MOVE the preference (or the
/// selection) and require the behaviour to move with it, so a re-hardcoded
/// literal reds instead of agreeing by coincidence.

/// Seed: the default Letter artboard (612x792 at the origin) in a viewport too
/// small to hold it at 100%, so the FIT branch runs.
///   z = (400 - 2*pad) / 792   (height is the binding axis)
private func centerFitBranchModel() -> Model {
    let doc = Document(layers: [Layer(children: [])],
                       artboards: [Artboard.defaultWithId("ab1")
                                    .with(x: 0, y: 0, width: 612, height: 792)])
    let m = Model(document: doc)
    m.viewportW = 400
    m.viewportH = 400
    return m
}

@Test func centerViewFitBranchFollowsTheFitPaddingPxPreference() {
    // Guard: with the SHIPPED preference (20) the fit uses 20 — so the
    // assertion below is about the preference being READ, not about the
    // formula being different.
    let shipped = centerFitBranchModel()
    shipped.centerViewOnCurrentArtboard(artboardsPanelSelection: [])
    #expect(abs(shipped.zoomLevel - 360.0 / 792.0) < 1e-12,
            "shipped fit_padding_px 20: z is \(shipped.zoomLevel)")

    // Now MOVE the preference. A route that reads it lands on 200/792; a route
    // with `let pad = 20.0` lands on 360/792 and reds here.
    ViewportPrefOverride.$values.withValue(["fit_padding_px": 100.0]) {
        let m = centerFitBranchModel()
        m.centerViewOnCurrentArtboard(artboardsPanelSelection: [])
        #expect(abs(m.zoomLevel - 200.0 / 792.0) < 1e-12,
                "fit_padding_px moved to 100: z is \(m.zoomLevel), want \(200.0 / 792.0)")
    }
}

@Test func centerViewFitBranchFollowsTheMinZoomPreference() {
    // Unclamped fit zoom is 360/792 ~= 0.4545. Raise min_zoom above it: a route
    // that reads the preference clamps UP to 1.5; `min(max(zFit, 0.1), 64.0)`
    // stays at 0.4545 and reds here.
    ViewportPrefOverride.$values.withValue(["min_zoom": 1.5]) {
        let m = centerFitBranchModel()
        m.centerViewOnCurrentArtboard(artboardsPanelSelection: [])
        #expect(m.zoomLevel == 1.5, "min_zoom moved to 1.5: z is \(m.zoomLevel)")
    }
}

@Test func centerViewFitBranchFollowsTheMaxZoomPreference() {
    // Lower max_zoom below the unclamped fit zoom so the clamp binds from
    // above. `min(max(zFit, 0.1), 64.0)` never sees 0.25 and reds.
    ViewportPrefOverride.$values.withValue(["max_zoom": 0.25]) {
        let m = centerFitBranchModel()
        m.centerViewOnCurrentArtboard(artboardsPanelSelection: [])
        #expect(m.zoomLevel == 0.25, "max_zoom moved to 0.25: z is \(m.zoomLevel)")
    }
}

@Test func centerViewHonoursThePanelSelectedCurrentArtboard() {
    // Two boards that both fit at 100% in the default 888x900 viewport, at
    // rects that cannot coincide numerically. `document.artboards.first` lands
    // on a measurably different pan from the panel-selected board.
    func twoBoardModel() -> Model {
        let doc = Document(
            layers: [Layer(children: [])],
            artboards: [
                Artboard.defaultWithId("ab1")
                    .with(x: 0, y: 0, width: 612, height: 792),
                Artboard.defaultWithId("ab2")
                    .with(x: 200, y: 150, width: 100, height: 50),
            ])
        return Model(document: doc)
    }

    let selected = twoBoardModel()
    selected.centerViewOnCurrentArtboard(artboardsPanelSelection: ["ab2"])
    #expect(selected.zoomLevel == 1.0)
    // ab2 centre (250, 175) in 888x900 → (444 - 250, 450 - 175).
    #expect(selected.viewOffsetX == 194.0,
            "panel-selected ab2 must be centred, not artboards.first")
    #expect(selected.viewOffsetY == 275.0)

    // …and the first board is genuinely a different answer, so the assertion
    // above is discriminating rather than accidentally satisfied.
    let unselected = twoBoardModel()
    unselected.centerViewOnCurrentArtboard(artboardsPanelSelection: [])
    #expect(unselected.viewOffsetX == 138.0, "no selection → the first board")
    #expect(unselected.viewOffsetY == 54.0)
}

/// Rust and Swift must centre identically. Both ports' expectations are the
/// same arithmetic written out here once; the Rust half lives in
/// `jas_dioxus/src/document/model.rs` under the same four names.
@Test func centerViewMatchesTheRustPortsExpectations() {
    // fit branch, shipped padding: z = (400 - 40)/792
    let m = centerFitBranchModel()
    m.centerViewOnCurrentArtboard(artboardsPanelSelection: [])
    #expect(abs(m.zoomLevel - 0.45454545454545453) < 1e-15)
    // centre branch, default viewport, first board: (138, 54)
    let c = Model(document: Document(
        layers: [Layer(children: [])],
        artboards: [Artboard.defaultWithId("ab1")
                     .with(x: 0, y: 0, width: 612, height: 792)]))
    c.centerViewOnCurrentArtboard(artboardsPanelSelection: [])
    #expect(c.viewOffsetX == 138.0)
    #expect(c.viewOffsetY == 54.0)
}
