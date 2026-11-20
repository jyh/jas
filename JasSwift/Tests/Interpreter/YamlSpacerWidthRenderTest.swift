/// A YAML `spacer` that declares a `style.width` is that wide; only a spacer
/// with NO width grows (row 189).
///
/// The Captain's Mac reading at the 11-20 sitting: in the Layers panel the
/// top-level layer's eye, lock and twirl sat pushed right against its name,
/// and its child row's icons sat further LEFT than the parent's, so the
/// hierarchy read inverted. layers.yaml's row is
/// `spacer(width: node.depth * 16) · eye · lock · twirl | spacer(width: 16) ·
/// preview · name`. This renderer drew every `spacer` as a flexible
/// `Spacer()`, so both the indent and the leaf's twirl gap stretched to fill
/// the row. The panel planner already states the law
/// (`PanelLayout.flexWeight`: a spacer with a width "must not grow").
///
/// The second law is the repeat column's: a `foreach` column lays its rows
/// out at the LEADING edge, as `containerBody`'s column does. With fixed
/// spacers and a centred column, rows of different widths would centre and
/// a deeper row's indent would be partly cancelled.
///
/// The arms render through `ImageRenderer` and read the x of the first inked
/// column of each row, so they see the indent the way the Captain did.

import Foundation
import Testing
import SwiftUI
import AppKit
@testable import JasLib

private let canvasW = 200
private let rowH = 20

/// A 10x10 box drawn by a container's border (white on black).
private let box: [String: Any] = [
    "type": "container",
    "style": ["width": 10, "height": 10, "border": "1px solid #ffffff"],
]

@MainActor
private func render(_ element: [String: Any], context: [String: Any], rows: Int) -> CGImage? {
    let view = ZStack(alignment: .topLeading) {
        Rectangle().fill(Color.black)
        YamlElementView(element: element, context: context)
    }
    .frame(width: CGFloat(canvasW), height: CGFloat(rowH * rows), alignment: .topLeading)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1.0
    return renderer.cgImage
}

/// The x of the first column holding ink in pixel rows [y0, y1), or nil.
private func firstInkX(_ img: CGImage, y0: Int, y1: Int) -> Int? {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    for x in 0..<w {
        for y in max(0, y0)..<min(h, y1) {
            let i = (y * w + x) * 4
            if Int(buf[i]) + Int(buf[i + 1]) + Int(buf[i + 2]) > 3 * 96 { return x }
        }
    }
    return nil
}

/// A row: a spacer of the given width expression, then the box.
private func row(spacerWidth: Any) -> [String: Any] {
    [
        "type": "container", "layout": "row", "style": ["gap": 0],
        "children": [
            ["type": "spacer", "style": ["width": spacerWidth]],
            box,
        ],
    ]
}

@Suite("YAML spacer width (row 189)") @MainActor
struct YamlSpacerWidthRenderTest {

    @Test("A spacer with a literal width is that wide, not flexible")
    func literalWidthSpacerIsFixed() throws {
        let img = try #require(render(row(spacerWidth: 32), context: [:], rows: 1))
        let x = try #require(firstInkX(img, y0: 0, y1: rowH), "no ink: the box did not draw")
        // Flexible: the box lands at the row's far end (canvasW - 10 = 190).
        #expect(abs(x - 32) <= 1, "box starts at x=\(x), expected 32 (a flexible spacer puts it at 190)")
    }

    @Test("A spacer whose width is a template is evaluated (the Layers indent)")
    func templateWidthSpacerIsEvaluated() throws {
        let img = try #require(render(row(spacerWidth: "{{node.depth * 16}}"),
                                      context: ["node": ["depth": 2]], rows: 1))
        let x = try #require(firstInkX(img, y0: 0, y1: rowH), "no ink: the box did not draw")
        #expect(abs(x - 32) <= 1, "box starts at x=\(x), expected 32 = depth 2 * 16")
    }

    @Test("A spacer with no width still grows (the control)")
    func widthlessSpacerGrows() throws {
        var r = row(spacerWidth: 0)
        r["children"] = [["type": "spacer"], box]
        let img = try #require(render(r, context: [:], rows: 1))
        let x = try #require(firstInkX(img, y0: 0, y1: rowH), "no ink: the box did not draw")
        #expect(abs(x - (canvasW - 10)) <= 1, "box starts at x=\(x), expected \(canvasW - 10)")
    }

    @Test("A foreach column lays rows at the leading edge: a deeper row starts further right")
    func foreachColumnRowsAreLeading() throws {
        let tree: [String: Any] = [
            "type": "container", "layout": "column",
            "foreach": ["source": "rows", "as": "node"],
            "do": [
                "type": "container", "layout": "row", "style": ["gap": 0, "height": rowH],
                "children": [
                    ["type": "spacer", "style": ["width": "{{node.depth * 16}}"]],
                    box,
                ],
            ] as [String: Any],
        ]
        let ctx: [String: Any] = ["rows": [["depth": 0], ["depth": 1]]]
        let img = try #require(render(tree, context: ctx, rows: 2))
        let x0 = try #require(firstInkX(img, y0: 0, y1: rowH), "row 0 drew no ink")
        let x1 = try #require(firstInkX(img, y0: rowH, y1: 2 * rowH), "row 1 drew no ink")
        // Centred rows: row 0 (10 wide) sits at 8 inside a 26-wide column.
        #expect(abs(x0 - 0) <= 1, "row 0 starts at x=\(x0), expected 0")
        #expect(abs(x1 - 16) <= 1, "row 1 starts at x=\(x1), expected 16")
        #expect(x1 > x0, "the child row must start RIGHT of its parent (x0=\(x0), x1=\(x1))")
    }
}
