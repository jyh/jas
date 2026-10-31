import Foundation
import Testing
@testable import JasLib

// Row 62 (STATUS-flask §703) and STATUS-flask 705 (1b)+(2), the reference's
// synthetic arms (test_panel_layout_leaf_min_height.py,
// test_panel_layout_row_min_width_stretch.py), one for one. Row 62: a leaf's
// height is its declared `height` (or `size`); else `w / aspect_ratio` from
// its FINAL width, rounded half away from zero; else its kind's; then its
// `min_height` floors it. 705 (1b): an over-subscribed row never shrinks a
// cell below its floor (a leaf's `min_width`; a container's is its
// content's). 705 (2): in a row with no `alignment` (or `stretch`), a
// heightless leaf takes the row's inner height, at the top. The shipped
// dialogs (the Color Picker, Layer Options) are pinned by panel_layout.json.

private typealias Rect = (x: Int, y: Int, w: Int, h: Int)

private func plan(_ content: [String: Any], _ availW: Int) -> [[Int]: Rect] {
    var out: [[Int]: Rect] = [:]
    for r in PanelLayout.layoutPanel(["content": content], availW: availW) {
        guard let p = r["path"] as? [Int], let rc = r["rect"] as? [String: Any],
              let x = rc["x"] as? Int, let y = rc["y"] as? Int,
              let w = rc["w"] as? Int, let h = rc["h"] as? Int else { continue }
        out[p] = (x, y, w, h)
    }
    return out
}

private func leaf(_ style: [String: Any]) -> [String: Any] {
    ["type": "color_gradient", "style": style]
}

private func col(_ children: [[String: Any]]) -> [String: Any] {
    ["type": "container", "layout": "column", "children": children]
}

private func row(_ children: [[String: Any]], _ availW: Int = 400,
                 _ style: [String: Any] = [:]) -> [[Int]: Rect] {
    plan(["type": "container", "layout": "row", "style": style, "children": children], availW)
}

@Test func aLeafsMinHeightAndAspectRatioSetItsHeightRowForRowWithTheReference() {
    func h(_ style: [String: Any], _ availW: Int = 400) -> (Int, Int)? {
        plan(col([leaf(style)]), availW)[[0]].map { ($0.w, $0.h) }
    }
    #expect(h([:])?.1 == 20, "CONTROL: the kind's height")
    #expect(h(["min_height": 100])?.1 == 100)
    #expect(h(["height": 50, "min_height": 60])?.1 == 60)
    #expect(h(["height": 80, "min_height": 60])?.1 == 80)
    #expect(h(["width": 120, "aspect_ratio": 2])?.1 == 60)
    #expect(h(["min_width": 180, "aspect_ratio": 1]).map { [$0.0, $0.1] } == [180, 180])
    #expect(h(["width": 181, "aspect_ratio": 2])?.1 == 91, "90.5 rounds half away from zero")
    #expect(h(["width": 120, "aspect_ratio": 2, "height": 40])?.1 == 40)
    #expect(h(["width": 100, "aspect_ratio": 2, "min_height": 60])?.1 == 60)
    #expect(h(["min_width": 180, "aspect_ratio": 1], 150).map { [$0.0, $0.1] } == [150, 150],
            "the width after the clamp")
    for bad in [0, -1, "1", true] as [Any] {
        #expect(h(["width": 120, "aspect_ratio": bad])?.1 == 20, "\(bad) is ignored")
    }
}

@Test func aRowNeverShrinksACellBelowItsFloorRowForRowWithTheReference() {
    var r = row([leaf(["width": 100]), leaf(["width": 300])], 200)
    #expect([r[[0]]?.w, r[[1]]?.w] == [50, 150], "CONTROL: no floors, in proportion")
    r = row([leaf(["width": 100, "min_width": 90]), leaf(["width": 300])], 200)
    #expect([r[[0]]?.w, r[[1]]?.w] == [90, 110])
    r = row([leaf(["min_width": 100]), leaf(["width": 100]), leaf(["width": 300])], 300)
    #expect([r[[0]]?.w, r[[1]]?.w, r[[2]]?.w] == [100, 50, 150])
    r = row([col([leaf(["width": 100, "min_width": 90])]), leaf(["width": 300])], 200)
    #expect([r[[0]]?.w, r[[0, 0]]?.w, r[[1]]?.w] == [90, 90, 110], "the floor carries up")
    let inner: [String: Any] = ["type": "container", "layout": "row", "style": ["gap": 4],
                                "children": [leaf(["min_width": 60]), leaf(["min_width": 30]),
                                             leaf(["width": 50])]]
    r = row([inner, leaf(["width": 400])], 200)
    #expect(r[[0]]?.w == 98, "60 + 30 + 0 and two gaps of 4")
    #expect([r[[0, 0]]?.w, r[[0, 1]]?.w, r[[0, 2]]?.w] == [60, 30, 0])
    r = row([leaf(["width": 150, "min_width": 150]), leaf(["width": 150, "min_width": 150])], 200)
    #expect([r[[0]]?.w, r[[1]]?.w] == [100, 100], "floors that cannot fit shrink as before")
    r = row([leaf(["width": 100, "min_width": 90]), leaf(["width": 50])], 400)
    #expect([r[[0]]?.w, r[[1]]?.w] == [100, 50], "a row that fits is unchanged")
}

@Test func aRowStretchesAHeightlessLeafRowForRowWithTheReference() {
    let tall = leaf(["width": 10, "height": 60])
    var r = row([tall, leaf(["width": 10])])
    #expect([r[[1]]?.h, r[[1]]?.y] == [60, 0])
    r = row([tall, leaf(["width": 10])], 400, ["alignment": "center"])
    #expect([r[[1]]?.h, r[[1]]?.y] == [20, 20], "CONTROL: another alignment centres")
    r = row([tall, leaf(["width": 10])], 400, ["alignment": "stretch"])
    #expect(r[[1]]?.h == 60)
    r = row([tall, leaf(["width": 10, "height": 30]),
             ["type": "color_swatch", "style": ["size": 16]], leaf(["width": 40, "aspect_ratio": 2])])
    #expect([r[[1]]?.h, r[[2]]?.h, r[[3]]?.h] == [30, 16, 20], "declared heights are not stretched")
    r = row([tall, col([leaf(["width": 10])])])
    #expect(r[[1]]?.h == 20, "a container is not stretched")
    r = row([leaf(["width": 10])], 400, ["height": 50, "padding": "5 0 5 0"])
    #expect(r[[0]]?.h == 40, "the declared height less the padding")
    r = row([leaf(["width": 10, "min_height": 70])], 400, ["height": 50])
    #expect(r[[0]]?.h == 70, "floored by the leaf's min_height")
}
