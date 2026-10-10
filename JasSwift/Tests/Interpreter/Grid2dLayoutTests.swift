import Foundation
import Testing
@testable import JasLib

// PATH_B_DESIGN B.7, the reference's synthetic arms (test_panel_layout_grid.py)
// and Rust's (grid_2d_tests), one for one: the 2-D `type: grid` (`cols`, `gap`,
// a `grid: {row, col}` per child). The toolbar's tool grid is the shipped case,
// pinned by the `toolbar` vector in the panel_layout.json golden.

private func rects(_ content: [String: Any], availW: Int = 72) -> [[Int]: (x: Int, y: Int, w: Int, h: Int)] {
    var out: [[Int]: (x: Int, y: Int, w: Int, h: Int)] = [:]
    for r in PanelLayout.layoutPanel(["content": content], availW: availW) {
        guard let p = r["path"] as? [Int], let rc = r["rect"] as? [String: Any],
              let x = rc["x"] as? Int, let y = rc["y"] as? Int,
              let w = rc["w"] as? Int, let h = rc["h"] as? Int else { continue }
        out[p] = (x, y, w, h)
    }
    return out
}

private func btn(_ cell: (Int, Int)? = nil) -> [String: Any] {
    var b: [String: Any] = ["type": "icon_button", "icon": "x"]
    if let (row, col) = cell { b["grid"] = ["row": row, "col": col] }
    return b
}

private func grid(_ children: [[String: Any]], style: [String: Any]? = nil) -> [String: Any] {
    var g: [String: Any] = ["type": "grid", "cols": 2, "gap": 2, "children": children]
    if let s = style { g["style"] = s }
    return g
}

@Test func aGridsChildrenAreLaidOut() {
    let r = rects(grid([btn((0, 0)), btn((0, 1))]))
    #expect(r[[0]] != nil && r[[1]] != nil, "\(r)")
}

@Test func gridCellsAreColumnsOfTheInnerWidthGapApart() {
    // inner 72: cw = (72 - 2) / 2 = 35; col 1 starts at 35 + 2 = 37.
    let r = rects(grid([btn((0, 0)), btn((0, 1))]))
    #expect(r[[0]]?.x == 0 && r[[1]]?.x == 37)
    #expect(r[[0]]?.y == 0 && r[[1]]?.y == 0)
}

@Test func aFixedSizeLeafKeepsItsSizeInItsGridCell() {
    let r = rects(grid([btn((0, 0))]))
    #expect(r[[0]]?.w == 24 && r[[0]]?.h == 24)
}

@Test func gridRowsAreTheTallestChildTallAndGapApart() {
    let tall: [String: Any] = ["type": "icon_button", "icon": "x", "style": ["height": 30],
                               "grid": ["row": 0, "col": 1]]
    let r = rects(grid([btn((0, 0)), tall, btn((1, 0))]))
    #expect(r[[2]]?.y == 30 + 2)
}

@Test func aGridChildWithoutACellTakesTheNextInReadingOrder() {
    let r = rects(grid([btn(), btn(), btn()]))
    #expect(r[[0]]?.x == 0 && r[[0]]?.y == 0)
    #expect(r[[1]]?.x == 37 && r[[1]]?.y == 0)
    #expect(r[[2]]?.x == 0 && r[[2]]?.y == 24 + 2)
}

@Test func theGridIsAsTallAsItsRowsPlusPadding() {
    let r = rects(grid([btn((0, 0)), btn((1, 1))], style: ["padding": 4]))
    // inner 64: two rows of 24, one gap of 2, padding 4 + 4.
    #expect(r[[]]?.h == 24 + 2 + 24 + 8)
    #expect(r[[1]]?.x == 4 + (64 - 2) / 2 + 2)
}

@Test func aHiddenGridChildTakesNoCell() {
    let hidden: [String: Any] = ["type": "icon_button", "icon": "x", "visible": false]
    let r = rects(grid([hidden, btn()]))
    #expect(r[[1]] != nil && r[[0]] == nil)
    #expect(r[[1]]?.x == 0 && r[[1]]?.y == 0)
}

@Test func aGridRowNumberNoChildUsesTakesNoSpace() {
    let r = rects(grid([btn((0, 0)), btn((2, 0))]))
    #expect(r[[1]]?.y == 24 + 2)
}

@Test func aGridFloatCellFallsBackToReadingOrder() {
    let floaty: [String: Any] = ["type": "icon_button", "icon": "x",
                                 "grid": ["row": 1.0, "col": 1.0]]
    let r = rects(grid([btn((0, 0)), floaty]))
    #expect(r[[1]]?.x == 37 && r[[1]]?.y == 0)
}
