import Foundation
import Testing
@testable import JasLib

// PATH_B_DESIGN B.5, the reference's synthetic arms
// (test_panel_layout_container_width.py), one for one: the shipped panels the
// corpus replays never clamp, take a percentage, or size a container in a row.

private func rect(_ content: [String: Any], _ path: [Int]) -> (x: Int, w: Int, h: Int)? {
    let rects = PanelLayout.layoutPanel(["content": content], availW: 200)
    guard let r = rects.first(where: { ($0["path"] as? [Int]) == path }),
          let rc = r["rect"] as? [String: Any],
          let x = rc["x"] as? Int, let w = rc["w"] as? Int, let h = rc["h"] as? Int else { return nil }
    return (x, w, h)
}

private func col(_ child: [String: Any]) -> [String: Any] {
    ["type": "container", "children": [child]]
}

private func boxed(_ style: [String: Any]) -> [String: Any] {
    ["type": "container", "style": style, "children": [["type": "separator"]]]
}

@Test func aContainersDeclaredWidthIsHonouredRowForRowWithTheReference() {
    let plain: [String: Any] = ["type": "container", "children": [["type": "separator"]]]
    #expect(rect(col(plain), [0])?.w == 200, "the control: no width fills")
    #expect(rect(col(boxed(["width": 40])), [0])?.w == 40)
    #expect(rect(col(boxed(["width": 40, "padding": 4])), [0, 0])?.w == 32,
            "children are laid out in the declared width")
    #expect(rect(col(boxed(["width": 500])), [0])?.w == 200, "clamped")
    #expect(rect(col(boxed(["width": "25%"])), [0])?.w == 50)
    #expect(rect(col(boxed(["width": "auto"])), [0])?.w == 200, "unreadable is ignored")
    let row: [String: Any] = ["type": "container", "layout": "row",
                              "children": [boxed(["width": 30]), ["type": "text", "content": "ab"]]]
    #expect(rect(row, [0])?.w == 30)
    #expect(rect(row, [1])?.x == 30, "the next cell starts after the declared width")
    let r = rect(col(boxed(["width": 40, "height": 24])), [0])
    #expect(r?.w == 40 && r?.h == 24, "the height rule is unchanged")
}
