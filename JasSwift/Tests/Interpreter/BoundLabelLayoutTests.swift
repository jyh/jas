import Foundation
import Testing
@testable import JasLib

// A button whose label is BOUND is as wide as the label it draws (flask
// STATUS §569, finding L): the reference's test_panel_layout_bound_label.py,
// one for one.

private func width(_ leaf: [String: Any], _ ctx: [String: Any] = [:]) -> Int? {
    let rects = PanelLayout.layoutPanel(["content": ["type": "row", "children": [leaf]]], availW: 400, ctx: ctx)
    guard let r = rects.first(where: { ($0["path"] as? [Int]) == [0] }),
          let rc = r["rect"] as? [String: Any] else { return nil }
    return rc["w"] as? Int
}

@Test func aBoundLabelIsMeasuredAsItDraws() {
    let cw = PanelLayout.charWidth
    let mask: [String: Any] = ["type": "button", "bind": ["label": "if selection_has_mask then \"Release\" else \"Make Mask\""]]
    #expect(width(mask, ["selection_has_mask": false]) == 9 * cw + 16)
    #expect(width(mask, ["selection_has_mask": true]) == 7 * cw + 16, "the other arm")
    #expect(width(["type": "button", "bind": ["label": "op.label"]], ["op": ["label": "Add Side"]]) == 8 * cw + 16,
            "a foreach row's label")
}

@Test func aBoundLabelBeatsTheStaticOneAndFallsBackToIt() {
    let cw = PanelLayout.charWidth
    let both: [String: Any] = ["type": "button", "label": "Static", "bind": ["label": "op.label"]]
    #expect(width(both, ["op": ["label": "Bound label"]]) == 11 * cw + 16)
    #expect(width(both) == 6 * cw + 16, "a non-string result: the static label")
    #expect(width(["type": "button", "label": "Static"]) == 6 * cw + 16, "no bind: unchanged")
}
