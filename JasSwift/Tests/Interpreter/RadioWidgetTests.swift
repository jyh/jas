/// Behavior oracle for the SCALE-DIALOG ``radio`` widget
/// (`Sources/Interpreter/YamlPanelBodyView.swift` → `renderRadio`).
///
/// SwiftUI views can't be instantiated headlessly, so this exercises the
/// two load-bearing decisions the renderer makes — both of which are pure
/// expression evaluations against the live dialog scope:
///
///   * the CIRCLE FILL: `bind.checked` evaluated to a bool (truthy →
///     `circle.inset.filled`, else `circle`);
///   * the on_check ROUND-TRIP: clicking runs `on_check` through
///     `runEffects`, whose `set: { dialog.X }` routes via the dialog arm
///     into the open dialog's scope, flipping the value the companion
///     radio's `bind.checked` reads back.
///
/// Together these prove that clicking Non-Uniform fills its circle and
/// hollows Uniform (and vice versa) — the mode selector the dialog was
/// previously missing because `radio` fell through to the placeholder.

import Foundation
import Testing
@testable import JasLib

/// Mirror renderRadio's checked-fill decision: evaluate the element's
/// `bind.checked` expression against the store's dialog-aware context.
private func radioChecked(_ checkedExpr: String, store: StateStore) -> Bool {
    evaluate(checkedExpr, context: store.evalContext()).toBool()
}

@Test func scaleRadioCircleFillReflectsDialogUniform() {
    let store = StateStore()
    store.initDialog("scale_options", defaults: ["uniform": true])
    // so_uniform_radio: bind.checked = "dialog.uniform"
    #expect(radioChecked("dialog.uniform", store: store) == true)
    // so_nonuniform_radio: bind.checked = "not dialog.uniform"
    #expect(radioChecked("not dialog.uniform", store: store) == false)
}

@Test func scaleRadioOnCheckFlipsBothCircles() {
    let store = StateStore()
    store.initDialog("scale_options", defaults: ["uniform": true])
    // Click Non-Uniform: its on_check is `set: { dialog.uniform: "false" }`.
    // renderRadio runs this through runEffects (the same pipeline buttons
    // use); the dialog arm routes the write into the dialog scope.
    runEffects([["set": ["dialog.uniform": "false"]]], ctx: [:], store: store)
    #expect(store.getDialog("uniform") as? Bool == false)
    // Now Uniform's circle is hollow and Non-Uniform's is filled.
    #expect(radioChecked("dialog.uniform", store: store) == false)
    #expect(radioChecked("not dialog.uniform", store: store) == true)

    // Click Uniform back: on_check `set: { dialog.uniform: "true" }`.
    runEffects([["set": ["dialog.uniform": "true"]]], ctx: [:], store: store)
    #expect(radioChecked("dialog.uniform", store: store) == true)
    #expect(radioChecked("not dialog.uniform", store: store) == false)
}

@Test func shearAxisRadioCircleFillAndFlip() {
    let store = StateStore()
    store.initDialog("shear_options", defaults: ["axis": "horizontal"])
    // sho_axis_horizontal / sho_axis_vertical bind.checked exprs.
    #expect(radioChecked("dialog.axis == 'horizontal'", store: store) == true)
    #expect(radioChecked("dialog.axis == 'vertical'", store: store) == false)
    // Click Vertical: on_check `set: { dialog.axis: "'vertical'" }`.
    runEffects([["set": ["dialog.axis": "'vertical'"]]], ctx: [:], store: store)
    #expect(store.getDialog("axis") as? String == "vertical")
    #expect(radioChecked("dialog.axis == 'horizontal'", store: store) == false)
    #expect(radioChecked("dialog.axis == 'vertical'", store: store) == true)
}

@Test func radioDisabledExprEvaluates() {
    // A radio may carry bind.disabled; renderRadio mutes + ignores taps
    // when it evaluates truthy. Confirm both polarities resolve.
    let store = StateStore()
    store.initDialog("scale_options", defaults: ["uniform": true, "locked": true])
    #expect(evaluate("dialog.locked", context: store.evalContext()).toBool() == true)
    store.setDialog("locked", false)
    #expect(evaluate("dialog.locked", context: store.evalContext()).toBool() == false)
}
