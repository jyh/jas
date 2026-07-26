import Testing
@testable import JasLib

/// Every copy of a Path must carry its `fillRule` across unchanged.
///
/// Swift has no equivalent of Rust's `PathElem { d, ..p.clone() }`, so
/// every Swift edit of a Path is an open-coded rebuild that restates
/// each field by hand. Most of the Rust twins CANNOT lose a field:
/// `clear_ids` (element.rs) and `assign_id` (controller.rs) mutate
/// `common` in place, `apply_appearance` mutates `common_mut()`, and
/// `blob_brush_commit_erasing` uses `..pe.clone()`. The exception is
/// `simplify_selection`, which spells `fill_rule: p.fill_rule` out by hand
/// and so could regress — hence the Rust-side guard
/// `simplify_selection_preserves_even_odd_fill_rule`. Swift's rebuilds are
/// the larger divergence risk, and this file is their pin (PRIME
/// DIRECTIVE: jas_dioxus and JasSwift must agree exactly).
///
/// The FIRST line of defence is not this file: `Path.init` takes
/// `fillRule` with NO DEFAULT, so a rebuild that forgets it does not
/// compile. Two earlier rounds of this feature shipped with a default,
/// and both times a hand audit missed sites the compiler would have
/// named. These tests pin the BEHAVIOUR the sites were fixed to have —
/// they do not, on their own, enumerate the sites.
///
/// Three layers of coverage:
///
///  1. `fillRulePreservedByEveryElementCopyHelper` walks the
///     Element-level copy helpers listed in its own body, applied to a
///     Path, and asserts the rule survives. It catches a regression in
///     any helper it lists; a NEW helper is covered only once someone
///     adds it to the list.
///  2. The per-operation tests cover the named document-level paths that
///     reach a copy: assignId, createReference, makeSymbol, detach,
///     copySelection (duplicate) and dedupeElementIds.
///  3. Section 3 covers the open-coded rebuild sites inside feature code
///     (simplify, eyedropper) that sections 1-2 cannot see because they
///     are not helpers. The blob-brush erase rebuild is pinned next to
///     its own fixtures in Tests/Tools/YamlToolEffectsTests.swift.

// MARK: - Fixtures

/// A two-ring even-odd path: an outer 100x100 square with a concentric
/// inner square. Under `.evenodd` the inner ring is a HOLE; under
/// `.nonzero` (both rings wound the same way) it is filled solid. So
/// the rule is observable in the geometry's meaning, not just a tag.
private func evenOddDonut(id: String? = nil) -> Path {
    let d: [PathCommand] = [
        .moveTo(0, 0), .lineTo(100, 0), .lineTo(100, 100), .lineTo(0, 100), .closePath,
        .moveTo(25, 25), .lineTo(75, 25), .lineTo(75, 75), .lineTo(25, 75), .closePath,
    ]
    return Path(d: d, fill: Fill(color: Color(r: 0, g: 0, b: 0)),
                name: "donut", id: id, fillRule: .evenodd)
}

private func donutElement(id: String? = nil) -> Element {
    .path(evenOddDonut(id: id))
}

/// The `fillRule` of `elem`, or nil when it is not a Path.
private func ruleOf(_ elem: Element?) -> FillRule? {
    guard case .path(let p) = elem else { return nil }
    return p.fillRule
}

private func modelWith(_ children: [Element], selected: [ElementPath] = []) -> Model {
    let layer = Layer(children: children)
    let sel: Selection = Set(selected.map { ElementSelection.all($0) })
    return Model(document: Document(layers: [layer], selectedLayer: 0, selection: sel))
}

// MARK: - 1. The copy-helper battery

@Test func fillRulePreservedByEveryElementCopyHelper() {
    let donut = donutElement(id: "keeper")

    /// Each entry is (name of the helper, the copy it produces).
    /// Anything that returns a Path must return an EVENODD Path.
    let copies: [(String, Element)] = [
        ("withId(non-nil)", donut.withId("stamped")),
        ("withId(nil)", donut.withId(nil)),
        ("clearingIds()", donut.clearingIds()),
        ("withLocked", donut.withLocked(true)),
        ("withVisibility", donut.withVisibility(.outline)),
        ("withTransformTranslated", donut.withTransformTranslated(dx: 5, dy: 5)),
        ("translated", donut.translated(dx: 5, dy: 5)),
        ("withTransformPremultiplied",
         donut.withTransformPremultiplied(Transform(a: 2, b: 0, c: 0, d: 2, e: 0, f: 0))),
        ("moveControlPoints", donut.moveControlPoints(.all, dx: 3, dy: 3)),
        ("withFill", withFill(donut, fill: Fill(color: Color(r: 1, g: 0, b: 0)))),
        ("withFill(nil)", withFill(donut, fill: nil)),
        ("withStroke", withStroke(donut, stroke: Stroke(color: Color(r: 0, g: 0, b: 1)))),
        ("withStroke(nil)", withStroke(donut, stroke: nil)),
        ("withFillGradient(nil)", withFillGradient(donut, fillGradient: nil)),
        ("withStrokeGradient(nil)", withStrokeGradient(donut, strokeGradient: nil)),
        ("withStrokeBrush", withStrokeBrush(donut, strokeBrush: "basic/round")),
        ("withStrokeBrushOverrides",
         withStrokeBrushOverrides(donut, overrides: "{\"size\":2}")),
        ("withMask(nil)", withMask(donut, mask: nil)),
        ("withWidthPoints", withWidthPoints(donut, widthPoints: [])),
        ("promoteToPathForBrush", promoteToPathForBrush(donut)),
    ]

    for (name, copy) in copies {
        #expect(ruleOf(copy) == .evenodd,
                "\(name) dropped fillRule: got \(String(describing: ruleOf(copy)))")
    }
}

/// Guard the fixture itself: if `.nonzero` and `.evenodd` were somehow
/// indistinguishable the battery above would pass vacuously.
@Test func fillRuleFixtureIsDistinguishable() {
    #expect(evenOddDonut().fillRule == .evenodd)
    #expect(FillRule.nonzero != FillRule.evenodd)
    #expect(Path(d: [.moveTo(0, 0)], fillRule: .nonzero).fillRule == .nonzero)
}

// MARK: - 2. The named document-level paths

@Test func fillRuleSurvivesAssignId() {
    // Controller.assignId -> Element.withId (Controller.swift §assignId).
    let model = modelWith([donutElement()])
    Controller(model: model).assignId([0, 0], id: "e1")
    let out = model.document.layers[0].children[0]
    #expect(out.id == "e1")
    #expect(ruleOf(out) == .evenodd, "assignId refilled the hole")
}

@Test func fillRuleSurvivesCreateReferenceStamp() {
    // createReference stamps the target id when it has none -> withId.
    let model = modelWith([donutElement()])
    Controller(model: model).createReference([0, 0], targetId: "t1", refId: "r1")
    let target = model.document.layers[0].children[0]
    #expect(target.id == "t1")
    #expect(ruleOf(target) == .evenodd, "createReference refilled the hole")
}

@Test func fillRuleSurvivesMakeSymbolMaster() {
    // makeSymbol copies the element into doc.symbols via withId.
    let model = modelWith([donutElement()])
    Controller(model: model).makeSymbol([0, 0], masterId: "m1", refId: "r1")
    #expect(model.document.symbols.count == 1)
    let master = model.document.symbols[0]
    #expect(master.id == "m1")
    #expect(ruleOf(master) == .evenodd, "make-symbol refilled the master's hole")
}

@Test func fillRuleSurvivesDetach() {
    // detach resolves the master and copies it id-less via clearingIds.
    let model = modelWith([donutElement()])
    let ctrl = Controller(model: model)
    ctrl.makeSymbol([0, 0], masterId: "m1", refId: "r1")
    ctrl.detach([0, 0])
    let out = model.document.layers[0].children[0]
    #expect(ruleOf(out) == .evenodd, "detach refilled the hole")
}

@Test func fillRuleSurvivesDuplicate() {
    // copySelection (alt-drag / duplicate) copies via clearingIds.
    let model = modelWith([donutElement(id: "src")], selected: [[0, 0]])
    Controller(model: model).copySelection(dx: 10, dy: 0)
    let children = model.document.layers[0].children
    #expect(children.count == 2)
    for (i, child) in children.enumerated() {
        #expect(ruleOf(child) == .evenodd, "duplicate refilled the hole at index \(i)")
    }
}

// MARK: - 3. Ad-hoc rebuild sites (not copy helpers)

/// The sites below are not `with*` helpers — they are Path initializer
/// calls open-coded inside feature code, which is why the helper battery
/// above could not see them. The eyedropper and blob-brush edits are
/// `..p.clone()` / `common_mut()` mutations in Rust, so Rust cannot drop a
/// field there at all; each Swift rebuild must restate every field by
/// hand.

@Test func fillRuleSurvivesSimplifySelection() {
    // Controller.simplifySelection §Path arm. Rust's simplify_selection
    // writes `fill_rule: p.fill_rule` on the Path arm (controller.rs).
    let model = modelWith([donutElement()], selected: [[0, 0]])
    Controller(model: model).simplifySelection(precision: 1.0)
    let out = model.document.layers[0].children[0]
    #expect(ruleOf(out) == .evenodd, "Object > Simplify refilled the hole")
}

@Test func simplifySelectionPreservesPathIdentityFields() {
    // The same rebuild also has to carry name / id / toolOrigin, which
    // Rust gets for free from `common: p.common.clone()`.
    let src = Path(d: evenOddDonut().d,
                   fill: Fill(color: Color(r: 0, g: 0, b: 0)),
                   toolOrigin: "blob_brush", name: "donut", id: "keep-me",
                   fillRule: .evenodd)
    let model = modelWith([.path(src)], selected: [[0, 0]])
    Controller(model: model).simplifySelection(precision: 1.0)
    guard case .path(let out) = model.document.layers[0].children[0] else {
        Issue.record("expected .path"); return
    }
    #expect(out.id == "keep-me")
    #expect(out.name == "donut")
    #expect(out.toolOrigin == "blob_brush")
}

@Test func fillRuleSurvivesEyedropperOpacityApply() {
    // applyEyedropperAppearance -> withOpacity ->
    // rebuildWithOpacityAndBlend §.path arm (Eyedropper.swift). Rust's
    // apply_appearance writes `result.common_mut().opacity = op` on a
    // clone, so nothing else can change.
    var appearance = EyedropperAppearance()
    appearance.opacity = 0.5
    var config = EyedropperConfig()
    // Isolate the opacity arm: fill / stroke go through helpers already
    // covered by the battery above.
    config.fill = false
    config.stroke = false
    let out = applyEyedropperAppearance(donutElement(id: "tgt"),
                                        appearance: appearance, config: config)
    #expect(out.opacity == 0.5, "the opacity should have been applied")
    #expect(ruleOf(out) == .evenodd, "eyedropper opacity refilled the hole")
    #expect(out.id == "tgt", "eyedropper opacity wiped the element id")
    guard case .path(let p) = out else { Issue.record("expected .path"); return }
    #expect(p.name == "donut", "eyedropper opacity wiped the element name")
}

@Test func fillRuleSurvivesEyedropperBlendModeApply() {
    // The blend-mode arm of the same rebuild.
    var appearance = EyedropperAppearance()
    appearance.blendMode = .multiply
    var config = EyedropperConfig()
    config.fill = false
    config.stroke = false
    let src = Path(d: evenOddDonut().d,
                   fill: Fill(color: Color(r: 0, g: 0, b: 0)),
                   toolOrigin: "blob_brush", name: "donut", id: "tgt",
                   fillRule: .evenodd)
    let out = applyEyedropperAppearance(.path(src),
                                        appearance: appearance, config: config)
    guard case .path(let p) = out else { Issue.record("expected .path"); return }
    #expect(p.blendMode == .multiply, "the blend mode should have been applied")
    #expect(p.fillRule == .evenodd, "eyedropper blend refilled the hole")
    #expect(p.id == "tgt", "eyedropper blend wiped the element id")
    #expect(p.name == "donut", "eyedropper blend wiped the element name")
    #expect(p.toolOrigin == "blob_brush",
            "eyedropper blend wiped the tool origin")
}

/// The Path arm was not the only arm of `rebuildWithOpacityAndBlend`
/// that dropped identity: every arm rebuilds field by field, and none
/// restated `name` / `id`. Rust's apply_appearance mutates
/// `result.common_mut().opacity`, so identity cannot be lost for any
/// element kind. This pins all of them.
@Test func eyedropperOpacityApplyPreservesIdentityForEveryElementKind() {
    let fill = Fill(color: Color(r: 0, g: 0, b: 0))
    let stroke = Stroke(color: Color(r: 0, g: 0, b: 0))
    let kinds: [(String, Element)] = [
        ("line", .line(Line(x1: 0, y1: 0, x2: 1, y2: 1, stroke: stroke,
                            name: "n", id: "i"))),
        ("rect", .rect(Rect(x: 0, y: 0, width: 1, height: 1, fill: fill,
                            name: "n", id: "i"))),
        ("circle", .circle(Circle(cx: 0, cy: 0, r: 1, fill: fill,
                                  name: "n", id: "i"))),
        ("ellipse", .ellipse(Ellipse(cx: 0, cy: 0, rx: 1, ry: 2, fill: fill,
                                     name: "n", id: "i"))),
        ("polyline", .polyline(Polyline(points: [(0, 0), (1, 1)], stroke: stroke,
                                        name: "n", id: "i"))),
        ("polygon", .polygon(Polygon(points: [(0, 0), (1, 0), (0, 1)], fill: fill,
                                     name: "n", id: "i"))),
        ("path", donutElement(id: "i")),
    ]
    var appearance = EyedropperAppearance()
    appearance.opacity = 0.25
    appearance.blendMode = .multiply
    var config = EyedropperConfig()
    config.fill = false
    config.stroke = false

    for (label, src) in kinds {
        let out = applyEyedropperAppearance(src, appearance: appearance,
                                           config: config)
        #expect(out.opacity == 0.25, "\(label): opacity not applied")
        #expect(out.id == "i", "\(label): eyedropper wiped the element id")
    }
}

@Test func fillRuleSurvivesIdDedupe() {
    // dedupeElementIds clears the *later* duplicate id via withId(nil).
    let doc = Document(layers: [Layer(children: [donutElement(id: "dup"),
                                                donutElement(id: "dup")])],
                       selectedLayer: 0)
    let out = dedupeElementIds(doc)
    let children = out.layers[0].children
    #expect(children.count == 2)
    #expect(children[0].id == "dup")
    #expect(children[1].id == nil, "dedupe should have cleared the second id")
    for (i, child) in children.enumerated() {
        #expect(ruleOf(child) == .evenodd, "id-dedupe refilled the hole at index \(i)")
    }
}
