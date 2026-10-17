import CoreGraphics
import Foundation
import Testing
@testable import JasLib

/// THE LIVE TRANSFORM OPERATION (council 2026-10-16, ruling 4), the Swift twin
/// of jas_dioxus `a_transformed_rect_draws_its_stroke_by_scale_strokes`.
///
/// His arm: a 200 % × 300 % scale of a 1 pt rectangle. Scale Strokes OFF:
/// "the stroke should stay 1pt" on all four edges. ON: "identical to
/// converting the stroke to outlines, then scaling", so the vertical edges
/// draw 2 pt and the horizontal ones 3 pt.
///
/// This port draws straight into CoreGraphics, so the arm reads PIXELS: the
/// canvas is drawn at 4 px per pt, and every edge is chosen to land on whole
/// pixels (a 1 pt edge at x = 4 pt covers 14…18 px), so each pixel is fully
/// in or fully out and a count is exact, not a threshold.
///
/// ⛔ A WIDTH ALONE CANNOT TELL OFF FROM "THE MATRIX WAS DROPPED": an unscaled
/// 1 pt rect also reads 1 pt. So each case also asserts WHERE the edges are.

private let pxPerPt = 4.0
private let size = 200

private func render(_ elem: Element) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: size * size * 4)
    buf.withUnsafeMutableBytes { raw in
        let ctx = CGContext(
            data: raw.baseAddress, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(pxPerPt), y: CGFloat(pxPerPt))
        drawElement(ctx, elem)
    }
    return buf
}

/// The runs of covered pixels (alpha > 127) along one row or one column, as
/// `(first, last)` pixel indices. Row/column orientation in the buffer does not
/// matter for a symmetric count; a flip only mirrors the indices, so each case
/// below also asserts the runs' mirror-free STARTS against both orientations.
private func runs(_ buf: [UInt8], row: Int? = nil, col: Int? = nil) -> [(Int, Int)] {
    var out: [(Int, Int)] = []
    var start: Int? = nil
    for i in 0..<size {
        let (x, y) = row != nil ? (i, row!) : (col!, i)
        let on = buf[(y * size + x) * 4 + 3] > 127
        if on, start == nil { start = i }
        if !on, let s = start { out.append((s, i - 1)); start = nil }
    }
    if let s = start { out.append((s, size - 1)) }
    return out
}

private let black = Color(r: 0, g: 0, b: 0)

/// A 10 × 10 rect at (2, 2), stroked 1 pt, no fill. Under 2 × 3 it lands on
/// 4…24 × 6…36 pt = 16…96 × 24…144 px.
private let rect: Element = .rect(Rect(x: 2, y: 2, width: 10, height: 10,
                                      stroke: Stroke(color: black, width: 1)))

private func wrap(_ child: Element, _ m: Transform, _ scaleStrokes: Bool) -> Element {
    .live(.transformed(TransformedElem(child: child, matrix: m, scaleStrokes: scaleStrokes)))
}

/// Per-edge thickness in pt, and the edges' outer starts in px, measured
/// through the middle of the drawn rect.
private func measure(_ buf: [UInt8]) -> (vertical: [Double], horizontal: [Double], xStart: Int, yStarts: Set<Int>) {
    let across = runs(buf, row: 84)      // crosses the two vertical edges
    let down = runs(buf, col: 56)        // crosses the two horizontal edges
    let w = { (r: (Int, Int)) in Double(r.1 - r.0 + 1) / pxPerPt }
    let ys = Set(down.map { $0.0 })
    return (across.map(w), down.map(w), across.first?.0 ?? -1, ys)
}

@Test func aTransformedRectDrawsItsStrokeByScaleStrokes() {
    // OFF: 1 pt everywhere; the left edge (x = 16 px) starts at 14 px.
    let off = measure(render(wrap(rect, .scale(2, 3), false)))
    #expect(off.vertical == [1, 1], "OFF vertical edges \(off.vertical)")
    #expect(off.horizontal == [1, 1], "OFF horizontal edges \(off.horizontal)")
    #expect(off.xStart == 14, "OFF drawn from x = \(off.xStart) px, want 14 (the matrix applied)")
    // ON: vertical edges 2 pt, horizontal 3 pt; the left edge starts at 12 px.
    let on = measure(render(wrap(rect, .scale(2, 3), true)))
    #expect(on.vertical == [2, 2], "ON vertical edges \(on.vertical)")
    #expect(on.horizontal == [3, 3], "ON horizontal edges \(on.horizontal)")
    #expect(on.xStart == 12, "ON drawn from x = \(on.xStart) px, want 12")
}

/// The stack order decides the case: OFF 2 × 3 inside ON 2 × 2 keeps 1 pt,
/// then the ON scale doubles it on every edge. The 5 × 5 rect at (1, 1) lands
/// on 4…24 × 6…36 pt (16…96 × 24…144 px, all on the 200 px canvas), so the
/// left edge (2 pt wide at 16 px) starts at 12 px.
@Test func anOffWrapperInsideAnOnWrapperScalesTheKeptStroke() {
    let small: Element = .rect(Rect(x: 1, y: 1, width: 5, height: 5,
                                    stroke: Stroke(color: black, width: 1)))
    let buf = render(wrap(wrap(small, .scale(2, 3), false), .scale(2, 2), true))
    let across = runs(buf, row: 84)
    let down = runs(buf, col: 56)
    let w = { (r: (Int, Int)) in Double(r.1 - r.0 + 1) / pxPerPt }
    #expect(across.map(w) == [2, 2], "vertical edges \(across.map(w))")
    #expect(down.map(w) == [2, 2], "horizontal edges \(down.map(w))")
    #expect(across.first?.0 == 12, "drawn from x = \(String(describing: across.first?.0)) px, want 12")
}

/// An ellipse's image under an affine map is an ellipse; `ellipseAxesThrough`
/// must name it. Each point of the original, mapped, must lie on the image at
/// the mapped angle. Driven over a non-uniform scale, a rotated one, a shear
/// and a mirror.
@Test func ellipseAxesThroughNamesTheImageEllipse() {
    let (rx, ry, rot) = (5.0, 2.0, 0.3)
    let point = { (rx: Double, ry: Double, rot: Double, t: Double) -> (Double, Double) in
        let x = rx * cos(t), y = ry * sin(t)
        return (cos(rot) * x - sin(rot) * y, sin(rot) * x + cos(rot) * y)
    }
    let mats: [(String, Transform)] = [
        ("scale 2x3", .scale(2, 3)),
        ("rotate*scale", Transform.rotate(30).multiply(.scale(2, 0.5))),
        ("shear", .shear(0.4, 0.1)),
        ("mirror", .scale(-1, 2)),
    ]
    for (name, m) in mats {
        let ax = ellipseAxesThrough(m, rx: rx, ry: ry, rotation: rot)
        for k in 0...8 {
            let t = Double(k) * 0.7
            let p = point(rx, ry, rot, t)
            let want = (m.a * p.0 + m.c * p.1, m.b * p.0 + m.d * p.1)
            let tm = (ax.mirrored ? -t : t) + ax.theta
            let got = point(ax.rx, ax.ry, ax.rotation, tm)
            #expect(abs(want.0 - got.0) < 1e-9 && abs(want.1 - got.1) < 1e-9,
                    "\(name) at t=\(t): want \(want) got \(got)")
        }
    }
}

/// The wrapper round-trips WHOLE through test JSON and binary: the child with
/// its own paint and transform, the matrix, and both Scale Strokes values,
/// nested one wrapper in another.
@Test func aTransformedWrapperRoundTripsThroughBothCodecs() throws {
    let child: Element = .rect(Rect(x: 1, y: 2, width: 10, height: 5,
                                    fill: Fill(color: black), stroke: Stroke(color: black, width: 1.5),
                                    transform: .rotate(30)))
    for scaleStrokes in [false, true] {
        let elem = wrap(wrap(child, .scale(2, 3), scaleStrokes), .shear(0.25, 0), !scaleStrokes)
        let json = elementJson(elem)
        #expect(json.contains("\"kind\":\"transformed\""), "\(json)")
        let parsed = parseElement(try JSONSerialization.jsonObject(with: Data(json.utf8)))
        #expect(elementJson(parsed) == json, "test JSON, scaleStrokes=\(scaleStrokes)")
        let doc = Document(layers: [Layer(name: "L", children: [elem])], selectedLayer: 0, selection: [])
        let back = try binaryToDocument(documentToBinary(doc, compress: false))
        #expect(back.layers[0].children.first == elem, "binary, scaleStrokes=\(scaleStrokes)")
    }
}
