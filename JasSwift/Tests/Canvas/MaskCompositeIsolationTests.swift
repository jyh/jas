import CoreGraphics
import Foundation
import Testing
@testable import JasLib

/// ⛔⛔ THE `clipIn` AND `clipOut` MASK ARMS WERE INERT IN THE SHIPPED SWIFT
/// RENDERER — the same shipped defect family jas_dioxus repaired on
/// 2026-08-30, alive in JasSwift until 2026-08-31.
///
/// Both arms set the composite blend mode on the context (`.destinationIn` /
/// `.destinationOut`) and then called ``drawElement``, whose
/// ``drawElementBody`` sets the blend mode from the element's OWN blend mode
/// as one of its first acts. **The operation was clobbered before a single
/// pixel landed**, so the mask artwork painted itself normally over the
/// element body instead of compositing against it — and on an opaque body
/// that is indistinguishable from no mask at all.
///
/// MEASURED before the repair, both arms: `########........` where the laws
/// say `####............` (clipIn) and `....####........` (clipOut).
///
/// 🔑 WHY IT SURVIVED, and why these fixtures look the way they do: the mask
/// arms were only ever exercised with artwork that COVERS what it masks, and
/// for full-coverage opaque artwork `.destinationIn` and `.normal` leave the
/// same alpha. The defect needs artwork covering only PART of the body to be
/// visible at all — the same discriminating shape jas_dioxus's fixtures use.
///
/// These are the Swift twins of jas_dioxus's
/// `a_luminance_mask_erases_where_the_artwork_is_absent` and
/// `an_inverted_mask_erases_where_the_artwork_is`
/// (`jas_dioxus/src/canvas/render.rs`), on the same input and pinned to the
/// same row pattern, because the prime directive is exact functional
/// equivalence across the active ports.
///
/// Pixel tests because the composite operation is CGContext state, observable
/// only through what survives it.

private let bmpW = 16, bmpH = 8

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

private func rowPattern(_ buf: UnsafeMutablePointer<UInt8>, _ y: Int) -> String {
    (0..<bmpW).map { x in
        buf[(y * bmpW + x) * 4 + 3] > 127 ? "#" : "."
    }.joined()
}

/// A black 8×8 body under a mask whose artwork is a white 4×8 bar covering
/// only the body's LEFT half — the shape that separates a working composite
/// from an inert one.
private func halfCoveredBody(clip: Bool, invert: Bool) -> Element {
    .rect(Rect(
        x: 0, y: 0, width: 8, height: 8,
        fill: Fill(color: Color(r: 0, g: 0, b: 0)),
        mask: Mask(
            subtreeElement: .rect(Rect(x: 0, y: 0, width: 4, height: 8,
                                       fill: Fill(color: Color(r: 1, g: 1, b: 1)))),
            clip: clip, invert: invert, disabled: false,
            linked: true, unlinkTransform: nil
        )
    ))
}

/// `clip: true, invert: false` → ``MaskPlan/clipIn``: `α_S ← α_S · M`.
/// Artwork covering only the left half must therefore erase the right half.
/// If the arm is inert the whole body survives.
@Test func aClipInMaskErasesWhereTheArtworkIsAbsent() {
    let (ctx, buf) = makeBitmap()
    defer { buf.deallocate() }
    drawElement(ctx, halfCoveredBody(clip: true, invert: false))
    #expect(rowPattern(buf, 4) == "####............",
            "clipIn must keep only where the artwork is (Rust twin: a_luminance_mask_erases_where_the_artwork_is_absent)")
}

/// `clip: true, invert: true` → ``MaskPlan/clipOut``: `α_S ← α_S · (1 − M)`.
/// The artwork must ERASE the half it covers. If the arm is inert the whole
/// body survives — on an opaque body, indistinguishable from no mask.
@Test func anInvertedMaskErasesWhereTheArtworkIs() {
    let (ctx, buf) = makeBitmap()
    defer { buf.deallocate() }
    drawElement(ctx, halfCoveredBody(clip: true, invert: true))
    #expect(rowPattern(buf, 4) == "....####........",
            "clipOut must erase where the artwork is (Rust twin: an_inverted_mask_erases_where_the_artwork_is)")
}

/// `clip: false, invert: true` collapses to ``MaskPlan/clipOut`` for
/// alpha-based masks (``maskPlan``'s own comment), so the ALPHA-mask spelling
/// of an inverted mask must render byte-identically to the clip spelling.
/// The plan-selection test pins the routing; this pins that the routing
/// reaches a composite that actually runs.
@Test func anAlphaInvertedMaskAgreesWithTheClipSpelling() {
    let (ctxA, bufA) = makeBitmap()
    defer { bufA.deallocate() }
    drawElement(ctxA, halfCoveredBody(clip: false, invert: true))
    #expect(rowPattern(bufA, 4) == "....####........",
            "clip:false/invert:true is the same law through the same arm")
}
