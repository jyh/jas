import Foundation
import Testing
@testable import JasLib

// PATH_B_DESIGN B.6, the reference's synthetic arms
// (test_panel_layout_container_min_height.py), one for one: a container's
// `style.min_height` floors its height, declared or content. The shipped case
// (Color's fill/stroke container) is pinned by the panel_layout.json golden.

private func yh(_ content: [String: Any], _ path: [Int]) -> (y: Int, h: Int)? {
    let rects = PanelLayout.layoutPanel(["content": content], availW: 200)
    guard let r = rects.first(where: { ($0["path"] as? [Int]) == path }),
          let rc = r["rect"] as? [String: Any],
          let y = rc["y"] as? Int, let h = rc["h"] as? Int else { return nil }
    return (y, h)
}

private func boxed(_ style: [String: Any]) -> [String: Any] {
    ["type": "container", "style": style, "children": [["type": "text", "content": "x"]]]
}

private func col(_ children: [[String: Any]]) -> [String: Any] {
    ["type": "container", "style": ["gap": 0], "children": children]
}

@Test func aContainersMinHeightFloorsItsHeightRowForRowWithTheReference() {
    let contentH = yh(col([boxed([:])]), [0])?.h ?? -1
    #expect(contentH > 0 && contentH < 60, "the control")
    #expect(yh(col([boxed(["min_height": 60])]), [0])?.h == 60)
    #expect(yh(col([boxed(["min_height": 1])]), [0])?.h == contentH, "a floor, never a size")
    #expect(yh(col([boxed(["height": 59.52, "min_height": 60])]), [0])?.h == 60,
            "the shipped shape: a truncated 59 is floored to 60")
    #expect(yh(col([boxed(["height": 80, "min_height": 60])]), [0])?.h == 80)
    let two = col([boxed(["min_height": 60]), boxed([:])])
    if let a = yh(two, [0]), let b = yh(two, [1]) {
        #expect(b.y == a.y + 60, "the next sibling starts below the floor")
    } else {
        Issue.record("no rects for the sibling arm")
    }
    for v in ["50%", "auto"] {
        #expect(yh(col([boxed(["min_height": v])]), [0])?.h == contentH, "\(v)")
    }
}
