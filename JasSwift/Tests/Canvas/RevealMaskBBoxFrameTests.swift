import CoreGraphics
import Foundation
import Testing
@testable import JasLib

/// ⚖️ THE REVEAL-BBOX FRAME CONTRACT, ruled 2026-08-31 (A6 §3.3): the reveal
/// law's bounding box is the axis-aligned bounds OF the transformed mask
/// subtree — `bounds(mask_xf · subtree)`, never the transformed rect as a
/// region — computed in the frame where the clip is applied.
///
/// This is the Swift twin of jas_dioxus's
/// `ph4_conversion_tests::a_rotated_reveal_mask_clips_the_box_of_what_it_draws`,
/// on the same input and pinned to the same row pattern, because the prime
/// directive is exact functional equivalence across the active ports: body
/// black 16×8; artwork white rect (4,0,8,8), UNLINKED mask carrying a 45°
/// rotation about (8,4) → the diamond `|x−8| + |y−4| ≤ 4√2`, bbox
/// x ∈ [2.34, 13.66]. Rows 1 and 6 (the input is symmetric about y = 4, so
/// the assertion is orientation-proof): kept outside the bbox (px 0–1,
/// 14–15), erased inside it where the diamond is absent (px 2–4, 11–13),
/// kept on the diamond (px 5–10).
///
/// The pre-ruling renderer set the clip AFTER the mask transform went on the
/// context, so it clipped the ROTATED rect — for rect artwork filling its own
/// bounds, clip region == artwork support and the mask was a NO-OP: this row
/// rendered all-'#'.
///
/// A pixel test because the clip region is CGContext state, observable only
/// through what survives the composite.

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

/// The discriminating document: a full-canvas body under an unlinked reveal
/// mask whose captured transform is a 45° rotation about (8,4).
private func rotatedRevealDoc() -> Element {
    let s = 0.5.squareRoot()
    let rot = Transform(a: s, b: s, c: -s, d: s, e: 8.0 - 4.0 * s, f: 4.0 - 12.0 * s)
    return .rect(Rect(
        x: 0, y: 0, width: 16, height: 8,
        fill: Fill(color: Color(r: 0, g: 0, b: 0)),
        mask: Mask(
            subtreeElement: .rect(Rect(x: 4, y: 0, width: 8, height: 8,
                                       fill: Fill(color: Color(r: 1, g: 1, b: 1)))),
            clip: false, invert: false, disabled: false,
            linked: false, unlinkTransform: rot
        )
    ))
}

/// The isolation half on an axis-aligned input — the twin of jas_dioxus's
/// `reveal_outside_bbox_punches_the_gap_in_its_artwork`: bbox 0..8, artwork
/// bars 0..2 and 6..8, so the 2..6 gap must be masked away. Before the
/// repair the `.destinationIn` was clobbered by `drawElementBody`'s own
/// blend-mode set and the bars painted OVER the body instead of masking it:
/// this row rendered `########` where the law says `##....##`.
@Test func revealOutsideBboxPunchesTheGapInItsArtwork() {
    let (ctx, buf) = makeBitmap()
    defer { buf.deallocate() }
    let bars: Element = .group(Group(children: [
        .rect(Rect(x: 0, y: 0, width: 2, height: 8,
                   fill: Fill(color: Color(r: 1, g: 1, b: 1)))),
        .rect(Rect(x: 6, y: 0, width: 2, height: 8,
                   fill: Fill(color: Color(r: 1, g: 1, b: 1)))),
    ]))
    let doc: Element = .rect(Rect(
        x: 0, y: 0, width: 8, height: 8,
        fill: Fill(color: Color(r: 0, g: 0, b: 0)),
        mask: Mask(subtreeElement: bars, clip: false, invert: false)
    ))
    drawElement(ctx, doc)
    #expect(rowPattern(buf, 4) == "##....##........",
            "inside the bbox only the artwork survives; outside it nothing was drawn")
}

@Test func aRotatedRevealMaskClipsTheBoxOfWhatItDraws() {
    let (ctx, buf) = makeBitmap()
    defer { buf.deallocate() }
    drawElement(ctx, rotatedRevealDoc())
    let want = "##...######...##"
    #expect(rowPattern(buf, 1) == want,
            "the ruled A6 §3.3 contract: clip the BOX of the transformed mask subtree, not the rotated rect (which makes the reveal law a no-op)")
    #expect(rowPattern(buf, 6) == want,
            "…and the mirror row agrees (the input is symmetric about y = 4)")
}
