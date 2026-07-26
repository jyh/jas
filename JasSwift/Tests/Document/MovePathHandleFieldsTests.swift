import Testing
@testable import JasLib

/// `Controller.movePathHandle` must rewrite a Path's `d` and NOTHING ELSE.
///
/// Rust's twin is one line — `PathElem { d: new_cmds, ..elem.clone() }`
/// (`geometry/element.rs`, `move_path_handle`) — so it structurally cannot
/// lose a field. Swift has no `..clone()`, so the Swift side is an
/// open-coded rebuild that restates each field by hand, and a hand-written
/// rebuild can silently drop fields the artist set. It did: the rebuild
/// forwarded only d/fill/stroke/widthPoints/opacity/transform/locked/
/// fillRule, dropping the other ten. This file is that rebuild's pin
/// (PRIME DIRECTIVE: jas_dioxus and JasSwift must agree exactly).
///
/// The path is live: `doc.move_path_handle` (YamlToolEffects
/// `pathMoveLatchedHandle`) calls it on an ordinary direct-selection
/// bezier-handle drag.
///
/// EXHAUSTIVENESS METHOD, stated so it can be checked rather than trusted:
/// `everyPathFieldSurvivesMovePathHandle` does not carry a hand-written
/// list of fields. It walks `Mirror(reflecting:)` over the Path struct and
/// compares every stored property except `d`, so a field added to `Path`
/// tomorrow is compared without editing this test. The one thing Mirror
/// cannot do for us is notice that a NEW field's fixture value is still
/// the type's default (default == default compares equal even when the
/// rebuild drops it), so the test also asserts the stored-property COUNT.
/// When that assertion fires, give the new field a non-default value in
/// `fullyPopulatedPath()` and raise the count.

// MARK: - Fixture

/// A two-segment cubic whose EVERY Path field is set to a value distinct
/// from that field's default, so that "the rebuild dropped it" and "the
/// rebuild kept it" are distinguishable outcomes for all of them.
private func fullyPopulatedPath() -> Path {
    return Path(
        d: [
            .moveTo(0, 0),
            .curveTo(x1: 10, y1: 0, x2: 20, y2: 10, x: 30, y: 10),
            .curveTo(x1: 40, y1: 10, x2: 50, y2: 20, x: 60, y: 20),
        ],
        fill: Fill(color: Color(r: 0.2, g: 0.4, b: 0.6)),
        stroke: Stroke(color: Color(r: 0.9, g: 0.1, b: 0.1), width: 3.5),
        widthPoints: [StrokeWidthPoint(t: 0, widthLeft: 0.5, widthRight: 2.5),
                      StrokeWidthPoint(t: 1, widthLeft: 2.5, widthRight: 0.5)],
        opacity: 0.42,
        transform: Transform.translate(7, 11),
        locked: false,       // locked paths are unreachable here: see below.
        visibility: .outline,
        blendMode: .multiply,
        mask: Mask(subtreeElement: .rect(Rect(x: 1, y: 2, width: 3, height: 4))),
        fillGradient: distinctGradient(angle: 30),
        strokeGradient: distinctGradient(angle: 60),
        strokeBrush: "calligraphic/flat-6pt",
        strokeBrushOverrides: "{\"angle\":45}",
        toolOrigin: "blob_brush",
        name: "my-curve",
        id: "curve-1",
        fillRule: .evenodd)
}

private func distinctGradient(angle: Double) -> Gradient {
    Gradient(
        type: .radial,
        angle: angle,
        aspectRatio: 200,
        method: .smooth,
        dither: true,
        strokeSubMode: .within,
        stops: [
            GradientStop(color: "#00ff00", opacity: 100, location: 0, midpointToNext: 50),
            GradientStop(color: "#0000ff", opacity: 100, location: 100, midpointToNext: 50),
        ])
}

private func modelWith(_ path: Path) -> Model {
    Model(document: Document(layers: [Layer(children: [.path(path)])],
                             selectedLayer: 0,
                             selection: []))
}

private func pathAt(_ doc: Document, _ p: ElementPath) -> Path? {
    guard case .path(let pe) = doc.getElement(p) else { return nil }
    return pe
}

// MARK: - The exhaustive pin

@Test func everyPathFieldSurvivesMovePathHandle() {
    let before = fullyPopulatedPath()
    let model = modelWith(before)
    Controller(model: model).movePathHandle([0, 0], anchorIdx: 0,
                                            handleType: "out", dx: 5, dy: -3)
    guard let after = pathAt(model.document, [0, 0]) else {
        Issue.record("element is no longer a Path")
        return
    }

    // The edit must actually have happened, so that a rebuild which
    // returned the input unchanged could not pass this test.
    #expect(after.d != before.d, "movePathHandle did not change d at all")

    let mb = Mirror(reflecting: before)
    let ma = Mirror(reflecting: after)

    // See EXHAUSTIVENESS METHOD above: this count is what makes the
    // Mirror walk trustworthy for fields added later.
    #expect(mb.children.count == 18,
            """
            Path's stored-property count changed. Give the new field a \
            NON-DEFAULT value in fullyPopulatedPath() — otherwise the \
            Mirror comparison below cannot tell "preserved" from \
            "dropped" for it — then update this count.
            """)

    let beforeByLabel = Dictionary(uniqueKeysWithValues:
        mb.children.compactMap { c -> (String, String)? in
            guard let l = c.label else { return nil }
            return (l, String(describing: c.value))
        })
    var comparedLabels: [String] = []
    for child in ma.children {
        guard let label = child.label, label != "d" else { continue }
        comparedLabels.append(label)
        #expect(String(describing: child.value) == beforeByLabel[label],
                "movePathHandle changed Path.\(label)")
    }
    // 18 stored properties minus `d` itself.
    #expect(comparedLabels.count == 17,
            "compared \(comparedLabels.count) fields: \(comparedLabels)")
}

// MARK: - The two losses with visible consequences

/// Dropping `visibility` silently PROMOTES an outline-mode or invisible
/// element to `.preview`, i.e. dragging a handle makes hidden artwork
/// paint. Called out separately from the Mirror walk because the failure
/// is a rendering change, not just a lost tag.
@Test func movePathHandleKeepsOutlineVisibility() {
    for vis in [Visibility.invisible, Visibility.outline] {
        let before = Path(d: fullyPopulatedPath().d, visibility: vis, fillRule: .nonzero)
        let model = modelWith(before)
        Controller(model: model).movePathHandle([0, 0], anchorIdx: 0,
                                                handleType: "out", dx: 5, dy: -3)
        #expect(pathAt(model.document, [0, 0])?.visibility == vis,
                "visibility \(vis) was not preserved")
    }
}

/// Dropping `name` / `id` destroys the stable element identity that
/// selection, references and symbols are keyed on.
@Test func movePathHandleKeepsElementIdentity() {
    let model = modelWith(fullyPopulatedPath())
    Controller(model: model).movePathHandle([0, 0], anchorIdx: 0,
                                            handleType: "out", dx: 5, dy: -3)
    #expect(pathAt(model.document, [0, 0])?.name == "my-curve")
    #expect(pathAt(model.document, [0, 0])?.id == "curve-1")
}

/// `locked` is forwarded, and the fixture leaves it false on purpose:
/// a locked path cannot be direct-selected, so `locked: true` is not a
/// reachable input to this effect. Pinned anyway — the rebuild is the
/// thing under test, not the reachability argument.
@Test func movePathHandleKeepsLockedFlag() {
    let src = fullyPopulatedPath()
    let before = Path(d: src.d, locked: true, fillRule: .evenodd)
    let model = modelWith(before)
    Controller(model: model).movePathHandle([0, 0], anchorIdx: 0,
                                            handleType: "out", dx: 5, dy: -3)
    #expect(pathAt(model.document, [0, 0])?.locked == true)
    #expect(pathAt(model.document, [0, 0])?.fillRule == .evenodd)
}
