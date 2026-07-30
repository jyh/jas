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
}
