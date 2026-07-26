import Testing
@testable import JasLib

/// Every copy of a Path must carry its `fillRule` across unchanged.
///
/// `Path.fillRule` is declared last in the initializer with a
/// `.nonzero` default so that pre-existing `Path(...)` call sites keep
/// compiling (Element.swift §Path). That convenience is exactly the
/// hazard: a copy site that forgets to append `fillRule:` does not fail
/// to build — it silently reinterprets the artwork, refilling the holes
/// of an even-odd boolean result.
///
/// Rust has no such hazard on the id paths: `clear_ids`
/// (element.rs) and `assign_id` (controller.rs) mutate `common` in
/// place, so no field can be dropped. Swift's value-type copies must be
/// pinned by test instead. These tests are that pin — the equivalence
/// gate for the id-stamping family (PRIME DIRECTIVE: jas_dioxus and
/// JasSwift must agree exactly).
///
/// Two layers of coverage:
///
///  1. `fillRulePreservedByEveryElementCopyHelper` walks *every*
///     Element-level copy helper that can be applied to a Path and
///     asserts the rule survives. That is the test that catches a
///     FUTURE omission: a new helper is only covered once it is added
///     to the battery, but any change to an existing helper that drops
///     the field turns this test red.
///  2. The per-operation tests below cover the named document-level
///     paths that reach a copy: assignId, createReference, makeSymbol,
///     detach, copySelection (duplicate) and dedupeElementIds. Swift
///     offers no reflective way to enumerate copy sites, so these name
///     each reachable operation explicitly rather than asserting one
///     call site.

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
@Test func fillRuleFixtureIsNotAlreadyTheDefault() {
    #expect(evenOddDonut().fillRule == .evenodd)
    #expect(FillRule.nonzero != FillRule.evenodd)
    // A Path built with no explicit rule takes the app default.
    #expect(Path(d: [.moveTo(0, 0)]).fillRule == .nonzero)
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
