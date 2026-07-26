import CoreGraphics
import Foundation
import Testing
@testable import JasLib

/// A gradient-painted Path must honour its declared `fillRule`.
///
/// `fillAndStroke` (the solid-paint branch) already reads the rule, but
/// two branches of `fillStrokeOrOutline` did not: the gradient FILL
/// branch clipped with `ctx.clip()` (winding) and the solid-fill +
/// gradient-STROKE branch called a bare `ctx.fillPath()` (winding). An
/// even-odd path with a gradient therefore filled its holes solid.
///
/// jas_dioxus has no such split: `conv_fill` takes the winding rule
/// alongside the brush, whether that brush is a colour or a gradient
/// (painter/element_render.rs), and the legacy canvas arm calls
/// `fill_with_canvas_winding_rule` after installing the gradient
/// (canvas/render.rs). So this was a live parity break.
///
/// Unreachable from applyDestructiveBoolean (which emits solid fills)
/// but reachable from any imported SVG that pairs `fill-rule="evenodd"`
/// with a gradient — hence a pixel test, not a display-list assertion:
/// CGContext state is the only observable here.

// MARK: - Harness

/// An opaque red-to-blue linear gradient (two stops, so
/// `makeCGGradient` accepts it).
private func opaqueGradient() -> Gradient {
    Gradient(type: .linear, angle: 0, stops: [
        GradientStop(color: "#ff0000", location: 0),
        GradientStop(color: "#0000ff", location: 100),
    ])
}

/// A donut: outer 0…100 square, concentric inner 25…75 square, wound
/// the same way. Even-odd makes the inner square a hole; winding fills
/// it solid.
private func donutCGPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0, y: 0))
    p.addLine(to: CGPoint(x: 100, y: 0))
    p.addLine(to: CGPoint(x: 100, y: 100))
    p.addLine(to: CGPoint(x: 0, y: 100))
    p.closeSubpath()
    p.move(to: CGPoint(x: 25, y: 25))
    p.addLine(to: CGPoint(x: 75, y: 25))
    p.addLine(to: CGPoint(x: 75, y: 75))
    p.addLine(to: CGPoint(x: 25, y: 75))
    p.closeSubpath()
    return p
}

private let canvasSize = 100

private func makeBitmap() -> (CGContext, UnsafeMutablePointer<UInt8>) {
    let bytes = canvasSize * canvasSize * 4
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
    buf.initialize(repeating: 0, count: bytes)
    let ctx = CGContext(
        data: buf, width: canvasSize, height: canvasSize,
        bitsPerComponent: 8, bytesPerRow: canvasSize * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return (ctx, buf)
}

/// Alpha of the pixel at (x, y). 0 means nothing was painted there.
private func alphaAt(_ buf: UnsafeMutablePointer<UInt8>, _ x: Int, _ y: Int) -> UInt8 {
    buf[(y * canvasSize + x) * 4 + 3]
}

/// Paint the donut once and report (alpha in the hole, alpha in the ring).
/// `configure` supplies the paint arguments under test.
private func paintDonut(
    fill: Fill?, stroke: Stroke?, fillGradient: Gradient?, strokeGradient: Gradient?,
    rule: FillRule
) -> (hole: UInt8, ring: UInt8) {
    let (ctx, buf) = makeBitmap()
    defer { buf.deallocate() }
    ctx.addPath(donutCGPath())
    fillStrokeOrOutline(ctx, fill, stroke,
                        fillGradient: fillGradient, strokeGradient: strokeGradient,
                        bbox: CGRect(x: 0, y: 0, width: 100, height: 100),
                        outline: false, fillRule: rule)
    // (50, 50) is the middle of the inner square (the hole under
    // even-odd); (10, 50) is the ring, painted under either rule.
    return (alphaAt(buf, 50, 50), alphaAt(buf, 10, 50))
}

// MARK: - The solid-paint branch (already correct — the control)

@Test func solidFillHonoursEvenOddRule() {
    let black = Fill(color: Color(r: 0, g: 0, b: 0))
    let solid = paintDonut(fill: black, stroke: nil, fillGradient: nil,
                           strokeGradient: nil, rule: .evenodd)
    #expect(solid.ring > 0, "the ring must be painted")
    #expect(solid.hole == 0, "solid even-odd fill must leave the hole empty")
    let winding = paintDonut(fill: black, stroke: nil, fillGradient: nil,
                             strokeGradient: nil, rule: .nonzero)
    #expect(winding.hole > 0, "under nonzero the same geometry fills solid")
}

// MARK: - The gradient-fill branch

@Test func gradientFillHonoursEvenOddRule() {
    let g = opaqueGradient()
    let evenodd = paintDonut(fill: nil, stroke: nil, fillGradient: g,
                             strokeGradient: nil, rule: .evenodd)
    #expect(evenodd.ring > 0, "the ring must be painted with the gradient")
    #expect(evenodd.hole == 0, "gradient even-odd fill must leave the hole empty")
}

@Test func gradientFillUnderNonZeroStillFillsTheHole() {
    // The other half of the contract: nonzero is not silently rewritten
    // to even-odd. Same geometry, opposite rule, opposite result.
    let g = opaqueGradient()
    let winding = paintDonut(fill: nil, stroke: nil, fillGradient: g,
                             strokeGradient: nil, rule: .nonzero)
    #expect(winding.hole > 0, "under nonzero the gradient fills the inner square")
}

// MARK: - The solid-fill + gradient-stroke branch

@Test func solidFillWithGradientStrokeHonoursEvenOddRule() {
    // A thin stroke so the stroked outline cannot itself cover (50, 50).
    let stroke = Stroke(color: Color(r: 0, g: 0, b: 0), width: 1.0)
    let evenodd = paintDonut(fill: Fill(color: Color(r: 0, g: 0, b: 0)),
                             stroke: stroke, fillGradient: nil,
                             strokeGradient: opaqueGradient(), rule: .evenodd)
    #expect(evenodd.ring > 0, "the ring must be painted")
    #expect(evenodd.hole == 0,
            "solid fill under a gradient stroke must still honour even-odd")
}

@Test func solidFillWithGradientStrokeUnderNonZeroFillsTheHole() {
    let stroke = Stroke(color: Color(r: 0, g: 0, b: 0), width: 1.0)
    let winding = paintDonut(fill: Fill(color: Color(r: 0, g: 0, b: 0)),
                             stroke: stroke, fillGradient: nil,
                             strokeGradient: opaqueGradient(), rule: .nonzero)
    #expect(winding.hole > 0, "under nonzero the solid fill covers the inner square")
}

// MARK: - The gradient-fill + gradient-stroke branch

@Test func gradientFillWithGradientStrokeHonoursEvenOddRule() {
    let stroke = Stroke(color: Color(r: 0, g: 0, b: 0), width: 1.0)
    let evenodd = paintDonut(fill: nil, stroke: stroke, fillGradient: opaqueGradient(),
                             strokeGradient: opaqueGradient(), rule: .evenodd)
    #expect(evenodd.ring > 0, "the ring must be painted")
    #expect(evenodd.hole == 0,
            "gradient fill under a gradient stroke must still honour even-odd")
}
