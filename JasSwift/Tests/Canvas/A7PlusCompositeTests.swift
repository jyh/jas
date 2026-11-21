import Testing
import CoreGraphics

// A7 (knockout bracket), ratified 11-21 ON A CONDITION: before anything is
// built, measure need (f), the ADDITIVE composite S + T, premultiplied, on
// every backend (design block §6: a platform's additive composite may clamp or
// un-premultiply differently from S + T). This is the Mac's: CoreGraphics
// `.plusLighter`, drawn into a premultiplied RGBA8 bitmap and read back RAW,
// so no colour conversion or un-premultiplying sits between the op and the
// reading. The expectation is computed from the same inputs by the law,
// never typed.

/// One pixel: put premultiplied `dst` in place (`.copy`), draw `src` with
/// `.plusLighter`, return the raw premultiplied bytes.
private func plus(dst: (Double, Double, Double, Double),
                  src: (Double, Double, Double, Double)) -> [Int] {
    let cs = CGColorSpaceCreateDeviceRGB()
    var buf = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // CGColor components are UNpremultiplied; the bitmap stores premultiplied.
    func color(_ p: (Double, Double, Double, Double)) -> CGColor {
        let a = p.3
        return CGColor(colorSpace: cs, components: a == 0 ? [0, 0, 0, 0]
                       : [p.0 / a, p.1 / a, p.2 / a, a])!
    }
    ctx.setBlendMode(.copy)
    ctx.setFillColor(color(dst))
    ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    ctx.setBlendMode(.plusLighter)
    ctx.setFillColor(color(src))
    ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    return buf.map(Int.init)
}

/// The law's S + T, premultiplied, clamped to 1, as bytes.
private func law(_ s: (Double, Double, Double, Double), _ t: (Double, Double, Double, Double)) -> [Int] {
    [s.0 + t.0, s.1 + t.1, s.2 + t.2, s.3 + t.3].map { Int((min($0, 1) * 255).rounded()) }
}

/// The block's §5 edge pixel, f = 0.5: S = the red overlap (1,0,0,1) erased to
/// (1 − f)·S; T = the child over B0 = (0.4, 0.6, 0.2, 1) kept to f·T. And a
/// partial-alpha pair whose sum has alpha < 1, where an implementation that
/// un-premultiplies would differ from S + T.
private let cases: [(String, (Double, Double, Double, Double), (Double, Double, Double, Double))] = [
    ("edge f=0.5", (0.5, 0, 0, 0.5), (0.2, 0.3, 0.1, 0.5)),
    ("partial alpha", (0.5, 0, 0, 0.5), (0.1, 0.15, 0.05, 0.25)),
    ("f=0.25", (0.75, 0, 0, 0.75), (0.1, 0.15, 0.05, 0.25)),
]

@Test func a7TheMacAdditiveCompositeIsSPlusT() {
    for (name, s, t) in cases {
        let got = plus(dst: s, src: t)
        let want = law(s, t)
        let worst = zip(got, want).map { abs($0 - $1) }.max()!
        print("A7(f) CG plusLighter \(name): got \(got) want \(want) worst \(worst)")
        #expect(worst <= 3, "\(name): got \(got), the law gives \(want)")
    }
}
