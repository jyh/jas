import CoreGraphics
import Foundation
import Testing
@testable import JasLib

/// The `.path` arm of `drawElementBody` paints the element's interior in
/// FOUR places, not one. Only the last routes through
/// `fillStrokeOrOutline`; the other three are their own fill calls,
/// each preceding a special stroke renderer:
///
///   - the strokeBrush branch (a resolved brush owns the stroke),
///   - the widthPoints branch (variable-width profile),
///   - the dashAlignAnchors branch (anchor-aligned dashes).
///
/// All four read `fillRule` now. Until this file existed the three above
/// called a bare `ctx.fillPath()`, which means winding, so an even-odd
/// path had its holes flooded whenever any of those strokes was in play.
///
/// jas_dioxus has no such split: its legacy Path arm emits the fill ONCE
/// at the top with `match e.fill_rule` and only then chooses a stroke
/// renderer (canvas/render.rs §Element::Path). `path_painter_inputs`
/// returns None for exactly these three cases, so in Rust all three land
/// on that single fill_rule-honouring fill. Applying a calligraphic
/// brush, a variable-width profile, or anchor-aligned dashes to an
/// even-odd boolean result therefore kept the hole in Rust and flooded it
/// in Swift — a live parity divergence, not a latent one.
///
/// These are pixel tests because CGContext winding state is not
/// observable from outside. They drive `drawElement`, the entry point that
/// reaches the branches: `drawElementBody` is private, and no
/// display-list or document-level assertion can see a winding rule.

// MARK: - Harness

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

private func alphaAt(_ buf: UnsafeMutablePointer<UInt8>, _ x: Int, _ y: Int) -> UInt8 {
    buf[(y * canvasSize + x) * 4 + 3]
}

/// The donut command list: outer 0…100 square plus a concentric inner
/// 25…75 square wound the same way. Even-odd makes the inner square a
/// hole; nonzero fills it solid.
private let donutCommands: [PathCommand] = [
    .moveTo(0, 0), .lineTo(100, 0), .lineTo(100, 100), .lineTo(0, 100), .closePath,
    .moveTo(25, 25), .lineTo(75, 25), .lineTo(75, 75), .lineTo(25, 75), .closePath,
]

/// Render `path` through `drawElement` and report the alpha in the hole
/// (50, 50) and in the ring (10, 50).
private func renderDonut(_ path: Path) -> (hole: UInt8, ring: UInt8) {
    let (ctx, buf) = makeBitmap()
    defer { buf.deallocate() }
    drawElement(ctx, .path(path))
    return (alphaAt(buf, 50, 50), alphaAt(buf, 10, 50))
}

private let black = Color(r: 0, g: 0, b: 0)

/// A calligraphic brush library so `lookupBrush("t/thin")` resolves and
/// `drawBrushedPath` returns true (which is what selects the branch).
/// Size 2 keeps the brush outline itself well clear of (50, 50), so the
/// hole probe reads the element FILL, not the brush stroke.
private func installThinCalligraphicBrush() {
    setCanvasBrushLibraries([
        "t": [
            "brushes": [
                ["slug": "thin", "type": "calligraphic",
                 "angle": 0.0, "roundness": 100.0, "size": 2.0],
            ],
        ],
    ])
}

// MARK: - 1. The strokeBrush branch

@Test func brushedPathFillHonoursEvenOddRule() {
    installThinCalligraphicBrush()
    defer { setCanvasBrushLibraries([:]) }
    let evenodd = renderDonut(Path(
        d: donutCommands, fill: Fill(color: black),
        stroke: Stroke(color: black, width: 1.0),
        strokeBrush: "t/thin", fillRule: .evenodd))
    #expect(evenodd.ring > 0, "the ring must be painted")
    #expect(evenodd.hole == 0,
            "a brushed even-odd path must leave the hole empty")
}

@Test func brushedPathFillUnderNonZeroFillsTheHole() {
    // The other half of the contract: nonzero is not rewritten to
    // even-odd. Same geometry, opposite rule, opposite result — this is
    // also what proves the probe point is inside the fill at all.
    installThinCalligraphicBrush()
    defer { setCanvasBrushLibraries([:]) }
    let winding = renderDonut(Path(
        d: donutCommands, fill: Fill(color: black),
        stroke: Stroke(color: black, width: 1.0),
        strokeBrush: "t/thin", fillRule: .nonzero))
    #expect(winding.hole > 0, "under nonzero the fill covers the inner square")
}

// MARK: - 2. The variable-width (widthPoints) branch

@Test func variableWidthPathFillHonoursEvenOddRule() {
    let evenodd = renderDonut(Path(
        d: donutCommands, fill: Fill(color: black),
        stroke: Stroke(color: black, width: 1.0),
        widthPoints: [StrokeWidthPoint(t: 0, widthLeft: 0.5, widthRight: 0.5),
                      StrokeWidthPoint(t: 1, widthLeft: 0.5, widthRight: 0.5)],
        fillRule: .evenodd))
    #expect(evenodd.ring > 0, "the ring must be painted")
    #expect(evenodd.hole == 0,
            "a variable-width even-odd path must leave the hole empty")
}

@Test func variableWidthPathFillUnderNonZeroFillsTheHole() {
    let winding = renderDonut(Path(
        d: donutCommands, fill: Fill(color: black),
        stroke: Stroke(color: black, width: 1.0),
        widthPoints: [StrokeWidthPoint(t: 0, widthLeft: 0.5, widthRight: 0.5),
                      StrokeWidthPoint(t: 1, widthLeft: 0.5, widthRight: 0.5)],
        fillRule: .nonzero))
    #expect(winding.hole > 0, "under nonzero the fill covers the inner square")
}

// MARK: - 3. The anchor-aligned dash branch

/// dashAlignAnchors + a non-empty dash pattern + no gradients selects the
/// DashRenderer sub-path expansion. A thin stroke keeps the dashes clear
/// of (50, 50).
private func anchorDashedStroke() -> Stroke {
    Stroke(color: black, width: 1.0, dashPattern: [4, 4], dashAlignAnchors: true)
}

@Test func anchorDashedPathFillHonoursEvenOddRule() {
    let evenodd = renderDonut(Path(
        d: donutCommands, fill: Fill(color: black),
        stroke: anchorDashedStroke(), fillRule: .evenodd))
    #expect(evenodd.ring > 0, "the ring must be painted")
    #expect(evenodd.hole == 0,
            "an anchor-dashed even-odd path must leave the hole empty")
}

@Test func anchorDashedPathFillUnderNonZeroFillsTheHole() {
    let winding = renderDonut(Path(
        d: donutCommands, fill: Fill(color: black),
        stroke: anchorDashedStroke(), fillRule: .nonzero))
    #expect(winding.hole > 0, "under nonzero the fill covers the inner square")
}

// MARK: - 4. The control: the branch that was already correct

@Test func plainPathFillHonoursEvenOddRule() {
    // No brush, no width points, no anchor dashes → the
    // fillStrokeOrOutline branch, fixed in an earlier commit. Present so
    // a regression there shows up in this file too.
    let evenodd = renderDonut(Path(
        d: donutCommands, fill: Fill(color: black),
        stroke: Stroke(color: black, width: 1.0), fillRule: .evenodd))
    #expect(evenodd.ring > 0, "the ring must be painted")
    #expect(evenodd.hole == 0, "a plain even-odd path must leave the hole empty")
    let winding = renderDonut(Path(
        d: donutCommands, fill: Fill(color: black),
        stroke: Stroke(color: black, width: 1.0), fillRule: .nonzero))
    #expect(winding.hole > 0, "under nonzero the fill covers the inner square")
}
