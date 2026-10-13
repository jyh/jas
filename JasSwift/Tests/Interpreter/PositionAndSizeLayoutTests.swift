import Foundation
import Testing
@testable import JasLib

// PATH_B_DESIGN B.8 (a child's `style.position`) and B.9 (a leaf's
// `style.size`), the reference's synthetic arms
// (test_panel_layout_position.py), one for one. The shipped cases (the Color
// and Swatches fill/stroke widgets, the sized icon buttons) are pinned by the
// panel_layout.json and pane_layout.json goldens.

private func rects(_ content: [String: Any], _ availW: Int = 200) -> [[Int]: (x: Int, y: Int, w: Int, h: Int)] {
    var out: [[Int]: (x: Int, y: Int, w: Int, h: Int)] = [:]
    for r in PanelLayout.layoutPanel(["content": content], availW: availW) {
        guard let p = r["path"] as? [Int], let rc = r["rect"] as? [String: Any],
              let x = rc["x"] as? Int, let y = rc["y"] as? Int,
              let w = rc["w"] as? Int, let h = rc["h"] as? Int else { continue }
        out[p] = (x, y, w, h)
    }
    return out
}

private func btn(_ style: [String: Any] = [:]) -> [String: Any] {
    ["type": "icon_button", "style": style]
}

private func at(_ x: Any, _ y: Any, _ node: [String: Any]) -> [String: Any] {
    var n = node
    var st = (n["style"] as? [String: Any]) ?? [:]
    st["position"] = ["x": x, "y": y]
    n["style"] = st
    return n
}

private func col(_ children: [[String: Any]]) -> [String: Any] {
    ["type": "container", "children": children]
}

@Test func aLeafWithoutASizeKeepsItsKindSize() {
    let r = rects(col([btn()]))
    #expect(r[[0]]?.w == 24 && r[[0]]?.h == 24)
}

@Test func aLeafsSizeIsItsWidthAndHeight() {
    let r = rects(col([btn(["size": 14.4])]))
    #expect(r[[0]]?.w == 14 && r[[0]]?.h == 14)
}

@Test func aDeclaredWidthAndHeightStillApplyAfterSize() {
    let r = rects(col([btn(["size": 14, "width": 30, "height": 9])]))
    #expect(r[[0]]?.w == 30 && r[[0]]?.h == 9)
}

@Test func aSizeMovesAFlowRowsNextCell() {
    let r = rects(["type": "row", "style": ["gap": 2],
                   "children": [btn(["size": 11.52]), btn(["size": 11.52])]])
    #expect(r[[1]]?.x == 11 + 2)
}

@Test func aPositionedChildIsPlacedAtItsPointInsideThePadding() {
    let r = rects(["type": "container", "style": ["padding": 5],
                   "children": [at(4.32, 15.84, btn(["size": 10]))]])
    #expect(r[[0]]?.x == 5 + 4 && r[[0]]?.y == 5 + 15)
}

@Test func aPositionedChildTakesNoSpaceInAColumn() {
    let r = rects(["type": "container", "style": ["gap": 3],
                   "children": [at(0, 30, btn(["size": 10])), btn(["size": 10])]])
    #expect(r[[1]]?.y == 0)
}

@Test func aPositionedChildTakesNoSpaceInARow() {
    let r = rects(["type": "row", "style": ["gap": 3],
                   "children": [at(50, 0, btn(["size": 10])), btn(["size": 10])]])
    #expect(r[[1]]?.x == 0)
}

@Test func positionedChildrenMayOverlapEachOther() {
    let r = rects(col([at(4, 4, btn(["size": 26])), at(15, 15, btn(["size": 26]))]))
    #expect(r[[0]]?.x == 4 && r[[1]]?.x == 15 && r[[0]]?.y == 4 && r[[1]]?.y == 15)
}

@Test func theParentsHeightReachesItsLowestPositionedChild() {
    let r = rects(col([col([btn(["size": 10]), at(0, 40, btn(["size": 12]))]), btn(["size": 10])]))
    #expect(r[[0]]?.h == 40 + 12)
    #expect(r[[1]]?.y == 40 + 12, "the next row starts after the positioned child")
}

@Test func aDeclaredHeightStillDecides() {
    let r = rects(col([["type": "container", "style": ["height": 20],
                        "children": [at(0, 40, btn(["size": 12]))]]]))
    #expect(r[[0]]?.h == 20)
}

@Test func aPositionedFillLeafReachesTheParentsRightEdge() {
    let r = rects(col([at(30, 0, ["type": "separator"])]), 100)
    #expect(r[[0]]?.x == 30 && r[[0]]?.w == 70)
}

@Test func aRowsNaturalWidthReachesItsRightmostPositionedChild() {
    let inner = col([at(30, 0, btn(["size": 10]))])
    let r = rects(["type": "row", "children": [inner, btn(["size": 10])]], 400)
    #expect((r[[1]]?.x ?? -1) >= 30 + 10)
}

@Test func outputIsPreOrderInChildIndexOrder() {
    let out = PanelLayout.layoutPanel(["content": col([
        btn(["size": 10]),
        at(0, 40, ["type": "row", "children": [btn(["size": 5])]]),
        btn(["size": 10]),
    ])], availW: 200)
    #expect(out.compactMap { $0["path"] as? [Int] } == [[], [0], [1], [1, 0], [2]])
}

@Test func aPositionThatIsNotTwoNumbersIsNotHonoured() {
    let r = rects(col([btn(["size": 10]), at("50%", 7, btn(["size": 10]))]))
    #expect(r[[1]]?.y == 10, "laid out in the flow, after its sibling")
}
