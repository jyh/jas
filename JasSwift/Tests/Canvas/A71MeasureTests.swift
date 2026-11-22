import Testing
import CoreGraphics
@testable import JasLib

// A7.1 (the knockout edge law), ratified 11-22 MEASURE-FIRST: before Route D
// is built, measure on every backend the two platform behaviours it rests on
// (addendum A7.1 §5, first bullet):
//   (1) the Difference blend of two OPAQUE pixels is |T − Q| with alpha 1;
//   (2) the additive composite whose alpha sum exceeds 1 SATURATES alpha at 1
//       and keeps the premultiplied colour sum.
// This is the Mac's half: CoreGraphics `.difference` and `.plusLighter`, drawn
// into a premultiplied RGBA8 bitmap and read back RAW. (1) is measured twice:
// as a plain fill, and the way Route D draws it on the Mac, a transparency
// layer composited under `.difference`. Expectations are computed from the
// inputs, never typed; each CONTROL draws the same pair source-over and must
// MISS the law, so a pass cannot be an instrument blind to the mode.

private typealias Px = (Double, Double, Double, Double)

private func pixel(dst: Px, src: Px, mode: CGBlendMode, viaLayer: Bool = false) -> [Int] {
    let cs = CGColorSpaceCreateDeviceRGB()
    var buf = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // CGColor components are UNpremultiplied; the bitmap stores premultiplied.
    func color(_ p: Px) -> CGColor {
        let a = p.3
        return CGColor(colorSpace: cs, components: a == 0 ? [0, 0, 0, 0]
                       : [p.0 / a, p.1 / a, p.2 / a, a])!
    }
    let r = CGRect(x: 0, y: 0, width: 1, height: 1)
    ctx.setBlendMode(.copy)
    ctx.setFillColor(color(dst))
    ctx.fill(r)
    ctx.setBlendMode(mode)
    if viaLayer {
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setBlendMode(.normal)
        ctx.setFillColor(color(src))
        ctx.fill(r)
        ctx.endTransparencyLayer()
    } else {
        ctx.setFillColor(color(src))
        ctx.fill(r)
    }
    return buf.map(Int.init)
}

private func bytes(_ v: [Double]) -> [Int] { v.map { Int((min(max($0, 0), 1) * 255).rounded()) } }

/// (name, T = destination, Q' = source), premultiplied = straight, both opaque.
/// E1 and E2 are the fixture's edge pixel (`a7_fixture`: B0 = (0.8, 0.8, 0.2),
/// f = 0.5, so Q' = (0.4, 0.4, 0.1)); a generic pair; and Q > T on two
/// channels, to see the absolute value.
private let diffCases: [(String, Px, Px)] = [
    ("E1 bracket", (0.4, 0.4, 0.6, 1), (0.4, 0.4, 0.1, 1)),
    ("E2 bracket", (0.6, 0.6, 0.4, 1), (0.4, 0.4, 0.1, 1)),
    ("generic", (0.8, 0.6, 0.2, 1), (0.3, 0.1, 0.2, 1)),
    ("Q > T", (0.2, 0.6, 0.1, 1), (0.5, 0.1, 0.3, 1)),
]

/// (name, S = (1−f)·S, premultiplied; T = the opaque bracket): alpha sum > 1 in
/// every row, every colour sum <= 1 (the law's domain). E1 and E2 (S = (1−f)·RED)
/// are the addendum's A7.1 column: 128, 0, 128 and 179, 51, 77.
private let satCases: [(String, Px, Px)] = [
    ("E1 f=0.5", (0.5, 0, 0, 0.5), (0, 0, 0.5, 1)),
    ("E2 f=0.5", (0.5, 0, 0, 0.5), (0.2, 0.2, 0.3, 1)),
    ("generic f=0.5", (0.3, 0.2, 0.1, 0.5), (0.25, 0.4, 0.3, 1)),
    ("f=0.25", (0.3, 0.45, 0.15, 0.75), (0.2, 0.1, 0.5, 1)),
]

private func off(_ a: [Int], _ b: [Int]) -> Int { zip(a, b).map { abs($0 - $1) }.max()! }

// Two plain tests, not one parameterized test: the Swift execution gate reads
// every declared case back by name and does not model parameterized cases.
@Test func a71TheMacDifferenceOfTwoOpaquePixelsIsTheAbsoluteDifference() {
    differenceArm(viaLayer: false)
}

@Test func a71TheMacDifferenceThroughATransparencyLayerIsTheAbsoluteDifference() {
    differenceArm(viaLayer: true)
}

private func differenceArm(viaLayer: Bool) {
    var worst = 0, bestControl = Int.max
    for (name, t, q) in diffCases {
        let want = bytes([abs(t.0 - q.0), abs(t.1 - q.1), abs(t.2 - q.2), 1])
        let got = pixel(dst: t, src: q, mode: .difference, viaLayer: viaLayer)
        let over = pixel(dst: t, src: q, mode: .normal, viaLayer: viaLayer)
        worst = max(worst, off(got, want))
        bestControl = min(bestControl, off(over, want))
        print("A7.1 CG difference layer=\(viaLayer) \(name): got \(got) source-over \(over) want \(want)")
    }
    print("A7.1 CG difference layer=\(viaLayer) worst \(worst) control-best \(bestControl)")
    #expect(bestControl > 3, "CONTROL: source-over met |T−Q|")
    #expect(worst <= 3, "A7.1 (1) NOT EXACT on CoreGraphics (worst \(worst)): STOP, bring this to him")
}

@Test func a71TheMacPlusLighterSaturatesAlphaAtOneWithTheColourSumIntact() {
    var worst = 0, bestControl = Int.max
    for (name, s, t) in satCases {
        let want = bytes([s.0 + t.0, s.1 + t.1, s.2 + t.2, s.3 + t.3])
        let got = pixel(dst: s, src: t, mode: .plusLighter)
        let over = pixel(dst: s, src: t, mode: .normal)
        worst = max(worst, off(got, want))
        bestControl = min(bestControl, off(over, want))
        print("A7.1 CG plusLighter-saturation \(name): got \(got) source-over \(over) want \(want)")
    }
    print("A7.1 CG plusLighter-saturation worst \(worst) control-best \(bestControl)")
    #expect(bestControl > 3, "CONTROL: source-over met S + T")
    #expect(worst <= 3, "A7.1 (2) NOT EXACT on CoreGraphics (worst \(worst)): STOP, bring this to him")
}

// Row 216, A7.1's declared limit as a GUARD: `knockoutBackdropRefusal` renders
// the knockout backdrop into a probe bitmap and names the limit when any pixel
// is partially transparent; `drawKnockoutLayers` hands a refusal to
// `assertionFailure` in DEBUG. Planted (alpha 0.5) must refuse; opaque and
// absent (the isolated page) must not.
private func probeContext() -> CGContext {
    CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

@Test func a71AKnockoutOverAPartiallyTransparentBackdropIsRefusedOnTheMac() {
    let partial: (CGContext) -> Void = { c in
        c.setFillColor(CGColor(red: 0.8, green: 0.8, blue: 0.2, alpha: 0.5))
        c.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }
    let opaque: (CGContext) -> Void = { c in
        c.setFillColor(CGColor(red: 0.8, green: 0.8, blue: 0.2, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }
    let refused = knockoutBackdropRefusal(probeContext(), partial)
    #expect(refused?.contains("A7.1") == true, "planted partial backdrop: \(String(describing: refused))")
    #expect(knockoutBackdropRefusal(probeContext(), opaque) == nil, "CONTROL: an opaque backdrop")
    #expect(knockoutBackdropRefusal(probeContext(), nil) == nil, "CONTROL: the isolated page's empty backdrop")
}
