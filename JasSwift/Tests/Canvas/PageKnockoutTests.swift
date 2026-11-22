import Testing
import AppKit
@testable import JasLib

// Row 209 (AMENDMENT A7, ratified 2026-11-21): the page knockout group on the
// Mac canvas, in pixels. The Swift twin of jas_dioxus's pixel arms
// (`canvas::render::a7_knockout_pixel_tests`, `painter::canvas2d`'s
// `a7_knockout_bracket_tests`, Direct2D's `a7_the_page_knockout_group_...`)
// on the design block's §5 scene: backdrop B0 = (0.8, 0.8, 0.2) (the artboard
// fill), layer 1 an opaque red rect over x ∈ [0, 20), layer 2 one leaf
// (0, 0.5, 1) at element opacity 0.5, blend Multiply, over x ∈ [10, 30).
//
// ⛔ THE BLOCK'S §5 TABLE IS NEVER TYPED HERE. `law` computes each expectation
// from the scene's inputs. The view is drawn into a RAW sRGB RGBA8 bitmap of
// our own (not `cacheDisplay`, which colour-manages the read-back), and the
// inputs are taken into that space the way the renderer's own colours land
// there: B0 is an sRGB artboard colour (exact), the element colours are
// `CGColor(red:green:blue:alpha:)`, converted. The law is then evaluated in
// that space, which is where CoreGraphics composites.

private let W = 40, H = 10, Y = 5
private let overlapX = 15, leafX = 25, outsideX = 35, edgeX = 10

/// sRGB components of a colour built the way the renderer builds element
/// colours (`cgColor` in CanvasSubwindow.swift).
private func landed(_ r: Double, _ g: Double, _ b: Double) -> [Double] {
    let c = CGColor(red: r, green: g, blue: b, alpha: 1)
    let s = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)!
    return s.components!.prefix(3).map(Double.init)
}

private let b0: [Double] = [204, 204, 51].map { $0 / 255 }   // "#cccc33", sRGB, exact

private enum Blend { case normal, multiply }
/// (straight colour, element opacity, blend, coverage of the pixel)
private typealias Child = ([Double], Double, Blend, Double)

/// The W3C compositing formula, premultiplied:
/// `co = cs·(1 − αb) + cb·(1 − αs) + αs·αb·B(Cb, Cs)`, `αo = αs + αb·(1 − αs)`.
private func composite(_ dst: [Double], _ c: [Double], _ a: Double, _ blend: Blend) -> [Double] {
    let ab = dst[3]
    var out = [0.0, 0, 0, 0]
    for i in 0..<3 {
        let cb = ab > 0 ? dst[i] / ab : 0
        let mixed = blend == .multiply ? cb * c[i] : c[i]
        out[i] = a * c[i] * (1 - ab) + dst[i] * (1 - a) + a * ab * mixed
    }
    out[3] = a + ab * (1 - a)
    return out
}

/// The knockout child term: A7.1's (the law of record, ratified 11-22), or
/// A7's first ratified `f·T`, kept ONLY so the edge arms can show they
/// separate it (mutant M8). Nothing renders the second.
private enum ChildTerm { case a71, ratified }

/// ⭐ THE EXPECTATION, BY THE LAW. NEITHER: `S ← c(S, E_i)`. ISOLATED: onto a
/// transparent L, then L over B0. KNOCKOUT (A7.1): `S ← B0`;
/// `T_i = c(B0, E_i)`; `S ← (1 − f_i)·S + [T_i − (1 − f_i)·B0]`, f = coverage
/// (coverage counts once). BOTH: knockout with B0 transparent, then over the
/// real B0. Returns 0–255 straight RGB.
private func law(iso: Bool, ko: Bool, _ children: [Child], term: ChildTerm = .a71) -> [Int] {
    let opaqueB0 = b0 + [1]
    let start = iso ? [0.0, 0, 0, 0] : opaqueB0
    var s = start
    for (c, op, blend, cov) in children {
        if ko {
            let t = composite(start, c, op * cov, blend)
            s = (0..<4).map { term == .a71
                ? (1 - cov) * s[$0] + t[$0] - (1 - cov) * start[$0]
                : (1 - cov) * s[$0] + cov * t[$0] }
        } else {
            s = composite(s, c, op * cov, blend)
        }
    }
    if iso {
        let k = 1 - s[3]
        s = (0..<4).map { s[$0] + k * opaqueB0[$0] }
    }
    return (0..<3).map { Int((min(max(s[$0] / s[3], 0), 1) * 255).rounded()) }
}

private let red = landed(1, 0, 0), leaf = landed(0, 0.5, 1), blue = landed(0, 0, 1)

private func children(at x: Int) -> [Child] {
    let cx = Double(x) + 0.5
    return [(red, 1, .normal, cx < 20 ? 1 : 0),
            (leaf, 0.5, .multiply, (10..<30).contains(cx) ? 1 : 0)]
}

/// The edge arms (addendum A7.1 §4, the twin of `a7_fixture::EDGES`): layer
/// 2's leaf, its left edge on a half pixel. (name, document colour, landed
/// colour, element opacity, blend.) E1 separates A7.1 from the ratified term
/// but equals ordinary compositing; E2 and E3 separate all three.
private let edges: [(String, Color, [Double], Double, Blend)] = [
    ("E1 opaque Normal blue", Color(r: 0, g: 0, b: 1), blue, 1, .normal),
    ("E2 Normal blue at 0.5", Color(r: 0, g: 0, b: 1), blue, 0.5, .normal),
    ("E3 the Multiply leaf at 0.5", Color(r: 0, g: 0.5, b: 1), leaf, 0.5, .multiply),
]

private func scene(iso: Bool, ko: Bool, edge: Int? = nil) -> Document {
    let l2: Element
    if let e = edge {
        let (_, c, _, op, blend) = edges[e]
        l2 = .rect(Rect(x: 10.5, y: 0, width: 19.5, height: 10, fill: Fill(color: c),
                        opacity: op, blendMode: blend == .multiply ? .multiply : .normal))
    } else {
        l2 = .rect(Rect(x: 10, y: 0, width: 20, height: 10, fill: Fill(color: Color(r: 0, g: 0.5, b: 1)),
                        opacity: 0.5, blendMode: .multiply))
    }
    return Document(
        layers: [Layer(name: "L1", children: [.rect(Rect(x: 0, y: 0, width: 20, height: 10,
                                                          fill: Fill(color: Color(r: 1, g: 0, b: 0))))]),
                 Layer(name: "L2", children: [l2])],
        artboards: [Artboard(id: "a", x: 0, y: 0, width: Double(W), height: Double(H), fill: .color("#cccc33"))],
        documentSetup: _withDocSetup(.default, pageIsolatedBlending: iso, pageKnockoutGroup: ko))
}

/// Draw the real `CanvasNSView` into a raw sRGB RGBA8 bitmap and read straight
/// RGB at row `Y` for each x.
@MainActor private func render(iso: Bool, ko: Bool, edge: Int? = nil, _ xs: [Int]) -> [[Int]] {
    let doc = scene(iso: iso, ko: ko, edge: edge)
    let view = CanvasNSView()
    view.frame = NSRect(x: 0, y: 0, width: W, height: H)
    let model = Model(document: doc)
    model.viewportW = Double(W); model.viewportH = Double(H)
    model.zoomLevel = 1.0; model.viewOffsetX = 0; model.viewOffsetY = 0
    view.document = doc
    view.controller = Controller(model: model)
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // The view is flipped (y down): row 0 of the bitmap is its top.
    ctx.translateBy(x: 0, y: CGFloat(H))
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()
    let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return xs.map { x in
        let i = (Y * W + x) * 4
        let a = Double(px[i + 3])
        return (0..<3).map { a > 0 ? Int((Double(px[i + $0]) * 255 / a).rounded()) : 0 }
    }
}

private func off(_ a: [Int], _ b: [Int]) -> Int { zip(a, b).map { abs($0 - $1) }.max()! }

private let regimes: [(String, Bool, Bool)] = [
    ("neither", false, false), ("isolated", true, false), ("knockout", false, true), ("both", true, true),
]

/// Four regimes × three pixels (overlap, leaf over bare backdrop, outside
/// every shape), each within ±3 of the law.
@Test @MainActor func thePageKnockoutGroupCompositesByTheLawOnTheMac() {
    let xs = [overlapX, leafX, outsideX]
    var worst = 0
    var report: [String] = []
    for (name, iso, ko) in regimes {
        let got = render(iso: iso, ko: ko, xs)
        for (i, x) in xs.enumerate() {
            let want = law(iso: iso, ko: ko, children(at: x))
            worst = max(worst, off(got[i], want))
            report.append("\(name) x=\(x): got \(got[i]) law \(want)")
        }
    }
    print("A7 Mac: " + report.joined(separator: "; "))
    #expect(worst <= 3, "A7 on the Mac off the law by \(worst): \(report.joined(separator: "; "))")
}

/// THE EDGE ARMS (A7.1 §4): layer 2's edge on a half pixel, f = 0.5 there,
/// for each of `edges`. A7.1 counts coverage once; the ratified child term
/// (mutant M8) reads `law(.., term: .ratified)`. The arm's power is asserted,
/// not inferred: every arm separates A7.1 from the ratified term, and E2 and
/// E3 separate ordinary, A7.1 and ratified pairwise, by more than 2·3. The
/// interior pixels of E1's scene equal ordinary compositing.
@Test @MainActor func theKnockoutEdgePixelsCountCoverageOnceOnTheMac() {
    var worst = 0
    var report: [String] = []
    for (e, (name, _, landedColour, op, blend)) in edges.enumerated() {
        let ch: [Child] = [(red, 1, .normal, 1), (landedColour, op, blend, 0.5)]
        let want = law(iso: false, ko: true, ch)
        let ratified = law(iso: false, ko: true, ch, term: .ratified)
        let ordinary = law(iso: false, ko: false, ch)
        #expect(off(want, ratified) > 6, "\(name): A7.1 \(want) and ratified \(ratified) not separable")
        if e > 0 {
            #expect(off(want, ordinary) > 6 && off(ordinary, ratified) > 6,
                    "\(name): ordinary \(ordinary), A7.1 \(want), ratified \(ratified) not pairwise separable")
        }
        let got = render(iso: false, ko: true, edge: e, [edgeX])[0]
        worst = max(worst, off(got, want))
        report.append("\(name): got \(got) A7.1 \(want) ratified \(ratified) ordinary \(ordinary)")
    }
    print("A7.1 Mac edge arms worst \(worst): " + report.joined(separator: "; "))
    #expect(worst <= 3, "A7.1 edge arms on the Mac off the law by \(worst): \(report.joined(separator: "; "))")
    let got = render(iso: false, ko: true, edge: 0, [5, 25])
    let ordinary = render(iso: false, ko: false, edge: 0, [5, 25])
    #expect(off(got[0], ordinary[0]) <= 3 && off(got[1], ordinary[1]) <= 3,
            "interior: knockout \(got) vs ordinary \(ordinary)")
}

private extension Array {
    func enumerate() -> EnumeratedSequence<[Element]> { enumerated() }
}
