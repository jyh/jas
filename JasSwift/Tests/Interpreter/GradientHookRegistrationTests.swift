import Testing
@testable import JasLib

/// THE GRADIENT PANEL'S WRITE PATH IS REGISTERED.
///
/// `applySetEffects` looks up `platformEffects["apply_gradient_panel"]` after any
/// `gradient_*` render-key write. No site in `JasSwift/Sources` registered that
/// key, so the `if let` failed silently and EVERY Gradient-panel edit was a
/// no-op against the document — while jas_dioxus wired the same path and applied
/// it correctly, recursing into group members.
///
/// Found 2026-07-29 by an adversarially-verified trace of a ledger row that
/// turned out to be about something else entirely. It is the FOURTH shape of one
/// dead-code hazard found that day, and the subtlest: not "no callers" but **one
/// caller behind a hook nobody installs**. `applyGradientPanelToSelection`
/// already existed and already mirrored Rust; grepping its name found the
/// definition and its test, and told you nothing.
///
/// These tests assert the REGISTRATION, not the gradient maths — the maths was
/// always correct and always unreachable.
@Suite("Gradient hook registration")
struct GradientHookRegistrationTests {

    private func rect(_ x: Double) -> Element {
        .rect(Rect(x: x, y: 0, width: 10, height: 10))
    }

    /// The bug in one line: the hook must EXIST in the map every production
    /// panel-effect site builds.
    @Test func theHookIsRegisteredOnTheSharedEffectMap() {
        let model = Model(document: Document(layers: [Layer(name: "L", children: [rect(0)])]))
        let effects = alignPlatformEffects(model: model)
        #expect(effects["apply_gradient_panel"] != nil,
                "every Gradient-panel edit is a silent no-op without this key")
    }

    /// And it reaches the document — including into a group's members, which is
    /// what the Rust twin does (§ paint recursion, ruled 2026-07-29).
    @Test func aGradientEditReachesASelectedGroupsMembers() {
        let g = Element.group(Group(children: [rect(0), rect(20)]))
        let doc = Document(layers: [Layer(name: "L", children: [g])])
        let model = Model(document: doc.replacing(
            selection: [ElementSelection.all([0, 0])]))
        let store = StateStore()
        store.set("gradient_type", "linear")
        store.set("gradient_angle", 45.0)
        store.set("gradient_stops", [
            ["offset": 0.0, "color": "#000000", "opacity": 1.0],
            ["offset": 1.0, "color": "#ffffff", "opacity": 1.0],
        ])

        guard let hook = alignPlatformEffects(model: model)["apply_gradient_panel"] else {
            Issue.record("hook not registered"); return
        }
        _ = hook("", [:], store)

        guard case .group(let out) = model.document.getElement([0, 0]) else {
            Issue.record("[0,0] should still be a Group"); return
        }
        var gradients = 0
        for child in out.children {
            if case .rect(let r) = child, r.fillGradient != nil { gradients += 1 }
        }
        #expect(gradients == 2,
                "both members carry the gradient; got \(gradients) of 2")
    }

    /// A `set:` effect stores a whole number as an Int, and the apply used to
    /// read the angle and ratio `as? Double`, which an Int never matches: a
    /// 45-degree edit applied as 0. The arm above seeds `45.0`, a Double,
    /// which is why it never saw this.
    @Test func aWholeNumberAngleAndRatioWrittenAsIntApply() {
        let model = Model(document: Document(
            layers: [Layer(name: "L", children: [rect(0)])],
            selection: [ElementSelection.all([0, 0])]))
        let store = StateStore()
        store.set("gradient_angle", 45)
        store.set("gradient_aspect_ratio", 150)
        #expect(store.get("gradient_angle") is Int, "the arm needs an Int in the store")
        applyGradientPanelToSelection(store: store, controller: Controller(model: model))
        let g = model.document.getElement([0, 0]).fillGradient
        #expect(g?.angle == 45, "applied: \(String(describing: g))")
        #expect(g?.aspectRatio == 150)
    }

    private func graded(_ from: String, _ to: String, fill: Fill? = nil) -> Element {
        .rect(Rect(x: 0, y: 0, width: 10, height: 10, fill: fill, fillGradient: Gradient(stops: [
            GradientStop(color: from, location: 0), GradientStop(color: to, location: 100)])))
    }

    private func readSelected(_ e: Element, fillOnTop: Bool = true) -> SelectionGradient {
        selectionGradient(Document(layers: [Layer(name: "L", children: [e])],
                                   selection: [ElementSelection.all([0, 0])]), fillOnTop: fillOnTop)
    }

    private func colours(_ s: SelectionGradient) -> [String]? {
        if case .uniform(let g) = s { return g.stops.map(\.color) }
        return nil
    }

    /// The read twin of the write above: a selected group speaks for its
    /// paintable members at any depth. Mirrors gradient_host.rs
    /// `a_selected_group_reads_its_members_gradient`.
    @Test func aSelectedGroupReadsItsMembersGradient() {
        let rb = { self.graded("#ff0000", "#0000ff") }
        let red = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, fill: Fill(color: .rgb(r: 1, g: 0, b: 0, a: 1))))
        let blue = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, fill: Fill(color: .rgb(r: 0, g: 0, b: 1, a: 1))))
        #expect(colours(readSelected(.group(Group(children: [rb()])))) == ["#ff0000", "#0000ff"])
        #expect(colours(readSelected(.group(Group(children: [rb(), .group(Group(children: [rb()]))])))) == ["#ff0000", "#0000ff"], "nested")
        #expect(readSelected(.group(Group(children: [rb(), graded("#0000ff", "#ff0000")]))) == .mixed)
        #expect(readSelected(.group(Group(children: [rb(), red]))) == .mixed, "a gradient member beside a solid one")
        #expect(readSelected(.group(Group(children: [red, blue]))) == .solid(.rgb(r: 1, g: 0, b: 0, a: 1)),
                "all solid: the first member's colour seeds")
        #expect(readSelected(.group(Group(children: []))) == .empty, "an empty group contributes nothing")
    }

    @Test func aSelectedGroupsStrokeReadsItsMembersStrokeGradient() {
        let leaf = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                     stroke: Stroke(color: .rgb(r: 0, g: 0, b: 1, a: 1), width: 1),
                                     strokeGradient: Gradient(stops: [
                                        GradientStop(color: "#ff0000", location: 0), GradientStop(color: "#0000ff", location: 100)])))
        #expect(colours(readSelected(.group(Group(children: [leaf])), fillOnTop: false)) == ["#ff0000", "#0000ff"])
    }

    /// End to end through the hook: an angle edit on a selected group keeps
    /// its members' stops. Mirrors `an_edit_on_a_selected_group_keeps_its_members_stops`.
    @Test func anEditOnASelectedGroupKeepsItsMembersStops() {
        let g = Element.group(Group(children: [graded("#ff0000", "#0000ff"), graded("#ff0000", "#0000ff")]))
        let model = Model(document: Document(layers: [Layer(name: "L", children: [g])],
                                             selection: [ElementSelection.all([0, 0])]))
        let store = StateStore()
        store.set("gradient_angle", 45)
        guard let hook = alignPlatformEffects(model: model)["apply_gradient_panel"] else {
            Issue.record("hook not registered"); return
        }
        _ = hook("gradient_angle", [:], store)
        guard case .group(let out) = model.document.getElement([0, 0]) else {
            Issue.record("[0,0] should still be a Group"); return
        }
        for child in out.children {
            #expect(child.fillGradient?.angle == 45)
            #expect(child.fillGradient?.stops.map(\.color) == ["#ff0000", "#0000ff"])
        }
    }

    private func mixedModel() -> Model {
        let a = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, fillGradient: Gradient(angle: 30, stops: [
            GradientStop(color: "#ff0000", location: 0), GradientStop(color: "#0000ff", location: 100)])))
        let b = graded("#0000ff", "#ff0000")
        let c = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, fill: Fill(color: .rgb(r: 1, g: 0, b: 0, a: 1))))
        return Model(document: Document(layers: [Layer(name: "L", children: [a, b, c])],
                                        selection: [ElementSelection.all([0, 0]), ElementSelection.all([0, 1]),
                                                    ElementSelection.all([0, 2])]))
    }

    /// GRADIENT.md §Multi-selection: "each control is evaluated independently".
    /// A field commit on a MIXED selection sets that field on each member's own
    /// gradient; a solid member is promoted from its own seed. Mirrors
    /// gradient_host.rs `a_mixed_field_edit_sets_that_field_on_each_members_own_gradient`.
    @Test func aMixedFieldEditSetsThatFieldOnEachMembersOwnGradient() {
        let model = mixedModel()
        #expect(selectionGradient(model.document, fillOnTop: true) == .mixed)
        let store = StateStore()
        store.set("gradient_stops", [["color": "#000000", "opacity": 100, "location": 0],
                                     ["color": "#ffffff", "opacity": 100, "location": 100]])
        store.set("gradient_dither", true)
        _ = alignPlatformEffects(model: model)["apply_gradient_panel"]?("gradient_dither", [:], store)
        let g = { (i: Int) in model.document.getElement([0, i]).fillGradient }
        #expect(g(0)?.dither == true && g(0)?.stops.map(\.color) == ["#ff0000", "#0000ff"] && g(0)?.angle == 30)
        #expect(g(1)?.dither == true && g(1)?.stops.map(\.color) == ["#0000ff", "#ff0000"])
        #expect(g(2)?.dither == true && g(2)?.stops.map(\.color) == ["#ff0000", "#ffffff"], "promoted from its own seed")
    }

    /// The stop combos on a MIXED selection start from the FIRST member's
    /// stops, and a commit overwrites only the others' stops. Mirrors
    /// `a_mixed_stop_edit_starts_from_the_first_members_stops`.
    @Test func aMixedStopEditStartsFromTheFirstMembersStops() {
        let model = mixedModel()
        let store = StateStore()
        store.initPanel("gradient_panel_content", defaults: ["selected_stop_index": 0])
        store.set("gradient_stop_opacity", 25)
        _ = alignPlatformEffects(model: model)["apply_gradient_panel"]?("gradient_stop_opacity", [:], store)
        for i in 0..<3 {
            let g = model.document.getElement([0, i]).fillGradient
            #expect(g?.stops.map { "\($0.color)@\($0.opacity)" } == ["#ff0000@25.0", "#0000ff@100.0"], "member \(i)")
        }
        #expect(model.document.getElement([0, 0]).fillGradient?.angle == 30)
        #expect(model.document.getElement([0, 1]).fillGradient?.angle == 0, "only the stops are overwritten")
    }

    /// A field edit keeps every field it does not name, from the SELECTION'S
    /// gradient, never from the store's last values: the store here holds a
    /// previous edit's stops and dither, as it would after editing another
    /// gradient. Mirrors renderer.rs `a_web_gradient_field_edit_keeps_the_selections_stops`,
    /// the port that once rebuilt the gradient from its panel struct.
    @Test func aFieldEditKeepsTheSelectionsOtherFields() {
        let model = Model(document: Document(
            layers: [Layer(name: "L", children: [rect(0)])],
            selection: [ElementSelection.all([0, 0])]))
        let controller = Controller(model: model)
        controller.setSelectionFillGradient(Gradient(dither: true, stops: [
            GradientStop(color: "#ff0000", location: 0, midpointToNext: 40),
            GradientStop(color: "#0000ff", location: 100, midpointToNext: 40)]))
        let store = StateStore()
        store.set("gradient_stops", [
            ["color": "#000000", "opacity": 100, "location": 0, "midpoint_to_next": 50],
            ["color": "#ffffff", "opacity": 100, "location": 100, "midpoint_to_next": 50]])
        store.set("gradient_dither", false)
        store.set("gradient_angle", 45)
        guard let hook = alignPlatformEffects(model: model)["apply_gradient_panel"] else {
            Issue.record("hook not registered"); return
        }
        _ = hook("gradient_angle", [:], store)
        let g = model.document.getElement([0, 0]).fillGradient
        #expect(g?.angle == 45)
        #expect(g?.dither == true, "an angle edit leaves the other fields")
        #expect(g?.stops.map { "\($0.color)@\($0.location)" } == ["#ff0000@0.0", "#0000ff@100.0"])
    }

    /// A stop combo through the hook: a location crossing the right
    /// neighbour re-sorts the selected rect's stops (the law is the corpus's;
    /// GradientStopCorpusTests) and the panel's selected index follows the
    /// moved stop, 0 -> 1. A refused edit (no stop selected) writes nothing.
    @Test func aStopComboEditsTheSelectedStopAndTheIndexFollowsIt() {
        let model = Model(document: Document(
            layers: [Layer(name: "L", children: [rect(0)])],
            selection: [ElementSelection.all([0, 0])]))
        let controller = Controller(model: model)
        controller.setSelectionFillGradient(Gradient(stops: [
            GradientStop(color: "#ff0000", location: 0),
            GradientStop(color: "#000000", location: 50),
            GradientStop(color: "#ffffff", location: 100)]))
        let store = StateStore()
        store.initPanel("gradient_panel_content", defaults: ["selected_stop_index": 0])
        store.set("gradient_stop_location", 70)
        guard let hook = alignPlatformEffects(model: model)["apply_gradient_panel"] else {
            Issue.record("hook not registered"); return
        }
        _ = hook("gradient_stop_location", [:], store)
        let g = model.document.getElement([0, 0]).fillGradient
        #expect(g?.stops.map { "\($0.color)@\($0.location)" } == ["#000000@50.0", "#ff0000@70.0", "#ffffff@100.0"])
        #expect((store.getPanel("gradient_panel_content", "selected_stop_index") as? Int) == 1)
        store.setPanel("gradient_panel_content", "selected_stop_index", -1)
        store.set("gradient_stop_opacity", 10)
        _ = hook("gradient_stop_opacity", [:], store)
        #expect(model.document.getElement([0, 0]).fillGradient == g, "a refused stop edit changes nothing")
    }
}
