import CoreGraphics
import Foundation
import Testing
@testable import JasLib

/// ⛔⛔ THE SWIFT RENDERER NEVER CARRIED AN ANCESTOR ALPHA, AND SPENT A MASKED
/// ELEMENT'S OWN OPACITY TWICE.
///
/// `jas_dioxus` reads the context's current alpha and MULTIPLIES into it —
/// `let parent_alpha = ctx.global_alpha(); let base_alpha = parent_alpha *
/// elem.opacity()` (`jas_dioxus/src/canvas/render.rs`), with the intent in its
/// own comment: *"we want this element's effective alpha to MULTIPLY into any
/// outer alpha (parent group opacity, isolation dim) rather than replace it."*
/// Its masked path then blits at `mask_blit_alpha(parent_alpha, own) =
/// parent_alpha`, because the body pass already spent `own` once — the repair
/// it calls D-α, landed 2026-08-24.
///
/// JasSwift did neither. Every arm called `ctx.setAlpha(v.opacity)`, which
/// REPLACES, and the masked path set the layer's composite-back alpha to the
/// element's own opacity and then re-applied that same opacity inside the
/// layer. The prime directive is exact functional equivalence across the
/// active ports, so both are divergences and not preferences.
///
/// ⚠️ AND `transcripts/OPACITY.md` ASSERTED THE OPPOSITE: *"The Swift port's
/// masked composite already spends the element's own opacity once, at a
/// transparency layer — read in `CanvasSubwindow.swift`, not executed."* The
/// disclaimer was in the sentence. Nobody ran it; these fixtures do.
///
/// 🔑 THE ROW THAT HID BOTH — `aMaskedElementInsideAHalfOpaqueGroup` — WAS
/// GREEN THE WHOLE TIME, because the squared own-opacity and the discarded
/// ancestor cancel exactly when the two are equal. It is the tidy example
/// anyone would reach for, and it is the one example that cannot fail under
/// either defect. It is kept as a regression arm precisely for that.
///
/// MEASURED before the repair (alpha at the centre of an 8×8 black body):
/// ```text
///   masked own=0.5, no ancestor        got  64   law 128   own spent twice
///   masked own=0.5 inside group 0.5    got  64   law  64   ✅ two errors cancel
///   masked own=1.0 inside group 0.5    got 255   law 128   ancestor discarded
///   masked own=0.5 inside group 1.0    got  64   law 128   own spent twice
///   plain  own=0.5 inside group 0.5    got 128   law  64   ancestor replaced
/// ```
///
/// Pixel tests on the ALPHA VALUE, not on a threshold: the whole defect lives
/// in the difference between 128 and 64, and both of those are ink.

private let bmpW = 8, bmpH = 8

private func makeBitmap() -> (CGContext, UnsafeMutablePointer<UInt8>) {
    let bytes = bmpW * bmpH * 4
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
    buf.initialize(repeating: 0, count: bytes)
    let ctx = CGContext(
        data: buf, width: bmpW, height: bmpH,
        bitsPerComponent: 8, bytesPerRow: bmpW * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return (ctx, buf)
}

/// Alpha at the centre of the body, where every fixture's shapes overlap.
private func centreAlpha(_ elem: Element) -> Int {
    let (ctx, buf) = makeBitmap()
    defer { buf.deallocate() }
    drawElement(ctx, elem)
    return Int(buf[(4 * bmpW + 4) * 4 + 3])
}

/// Rounding slack for one 8-bit composite, matching jas_dioxus's own `close`.
private func close(_ got: Int, _ want: Int) -> Bool { abs(got - want) <= 2 }

private func blackRect(_ opacity: Double) -> Element {
    .rect(Rect(x: 0, y: 0, width: 8, height: 8,
               fill: Fill(color: Color(r: 0, g: 0, b: 0)), opacity: opacity))
}

/// The same body under a FULL WHITE clipping mask — `M = 1` everywhere, so the
/// mask changes nothing and the only thing the fixture can see is how many
/// times the element's own opacity was spent.
private func maskedBlackRect(_ opacity: Double) -> Element {
    .rect(Rect(x: 0, y: 0, width: 8, height: 8,
               fill: Fill(color: Color(r: 0, g: 0, b: 0)), opacity: opacity,
               mask: Mask(
                   subtreeElement: .rect(Rect(x: 0, y: 0, width: 8, height: 8,
                                              fill: Fill(color: Color(r: 1, g: 1, b: 1)))),
                   clip: true, invert: false)))
}

// MARK: - The ancestor product must reach the element

@Test func aGroupsOpacityMultipliesIntoItsChildren() {
    let got = centreAlpha(.group(Group(children: [blackRect(0.5)], opacity: 0.5)))
    #expect(close(got, 64),
            "0.5 group × 0.5 child = 0.25 (got \(got), want ~64; 128 means the child REPLACED the group's alpha)")
}

@Test func aLayersOpacityMultipliesIntoItsChildren() {
    let got = centreAlpha(.layer(Layer(children: [blackRect(0.5)], opacity: 0.5)))
    #expect(close(got, 64),
            "0.5 layer × 0.5 child = 0.25 (got \(got), want ~64) — a layer is the container every real document sits in")
}

/// Three levels, so the law is a PRODUCT and not a single pairing — the arm
/// that separates "multiply into the accumulated ancestor alpha" from
/// "multiply by the immediate parent only".
@Test func nestedContainerOpacitiesCompoundAsAProduct() {
    let got = centreAlpha(.layer(Layer(
        children: [.group(Group(children: [blackRect(0.5)], opacity: 0.5))],
        opacity: 0.5)))
    #expect(close(got, 32),
            "0.5 layer × 0.5 group × 0.5 child = 0.125 (got \(got), want ~32)")
}

// MARK: - A masked element spends its own opacity ONCE (D-α, in Swift)

/// The control that makes the next fixture a measurement: the SAME element
/// without a mask. If this ever moves, the masked reading below is measuring
/// the instrument and not the mask path.
@Test func theUnmaskedControlSpendsItsOpacityOnce() {
    let got = centreAlpha(blackRect(0.5))
    #expect(close(got, 128), "an unmasked 0.5 element is 0.5 (got \(got), want ~128)")
}

@Test func aMaskedElementSpendsItsOwnOpacityOnce() {
    let got = centreAlpha(maskedBlackRect(0.5))
    #expect(close(got, 128),
            "a 0.5 element under M = 1 is 0.5, exactly as unmasked (got \(got), want ~128; 64 is own²)")
}

/// The ancestor product must reach a MASKED element too — and this is the arm
/// that isolates it, because the element's own opacity is 1.0 here, so nothing
/// can cancel a discarded ancestor.
@Test func theAncestorProductReachesAMaskedElement() {
    let got = centreAlpha(.group(Group(children: [maskedBlackRect(1.0)], opacity: 0.5)))
    #expect(close(got, 128),
            "0.5 group × opaque masked child = 0.5 (got \(got), want ~128; 255 means the group's alpha never arrived)")
}

/// 🔑 THE ROW THAT HID BOTH DEFECTS, kept deliberately. `own²` and a discarded
/// ancestor cancel exactly when the two opacities are equal, so this — the
/// tidiest example anyone would reach for — was GREEN under both defects and
/// is green after the repair, for a different reason. A fixture that cannot
/// fail proves nothing on its own; it is here so that a future change which
/// re-breaks only ONE of the two is caught.
@Test func aMaskedElementInsideAHalfOpaqueGroup() {
    let got = centreAlpha(.group(Group(children: [maskedBlackRect(0.5)], opacity: 0.5)))
    #expect(close(got, 64),
            "0.5 group × 0.5 own = 0.25 (got \(got), want ~64) — green before the repair too, by two errors cancelling")
}
