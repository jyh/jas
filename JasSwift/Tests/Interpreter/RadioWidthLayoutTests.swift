import Foundation
import Testing
@testable import JasLib

// The two radio kinds have a width: the reference's synthetic arms
// (test_panel_layout_radio_width.py), one for one. No shipped PANEL holds a
// radio, so the panel goldens do not witness it.

private func width(_ leaf: [String: Any]) -> Int? {
    let rects = PanelLayout.layoutPanel(["content": ["type": "row", "children": [leaf]]], availW: 400)
    guard let r = rects.first(where: { ($0["path"] as? [Int]) == [0] }),
          let rc = r["rect"] as? [String: Any] else { return nil }
    return rc["w"] as? Int
}

@Test func aRadioIsSizedAsACheckbox() {
    let cw = PanelLayout.charWidth
    #expect(width(["type": "radio", "label": "Vertical"]) == 16 + 4 + 8 * cw)
    #expect(width(["type": "checkbox", "label": "Vertical"]) == 16 + 4 + 8 * cw, "the control")
}

@Test func aRadioGroupIsItsOptionsInARowSixApart() {
    let cw = PanelLayout.charWidth
    #expect(width(["type": "radio_group", "options": [["id": "h", "label": ""]]]) == 16)
    let opts: [Any] = [["id": "a", "label": "Ab"], ["id": "b"], ["id": "c", "label": "C"]]
    #expect(width(["type": "radio_group", "options": opts]) == (16 + 4 + 2 * cw) + 6 + 16 + 6 + (16 + 4 + cw))
    #expect(width(["type": "radio_group"]) == 0)
    let pair: [Any] = [["icon": "orientation_portrait", "value": "portrait"],
                       ["icon": "orientation_landscape", "value": "landscape"]]
    #expect(width(["type": "icon_button_group", "options": pair]) == 24 + 4 + 24)
    #expect(width(["type": "icon_button_group"]) == 0)
    #expect(width(["type": "radio_group", "options": "dialog.list"]) == 0)
}
