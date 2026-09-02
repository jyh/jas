import CoreGraphics
import Foundation
import Testing
@testable import JasLib

/// ROW EH — THE `.live` SIBLING OF `PathFillRuleRenderTests`.
///
/// That file exists because three of the four `.path` fill sites called a bare
/// `ctx.fillPath()`, which means WINDING, so an even-odd path had its holes
/// flooded. This file is the same defect on the arm that wave did not reach:
/// `drawElementBody`'s `.live` case, which also calls a bare `ctx.fillPath()`.
///
/// ⛔ AND HERE IT IS NOT A DROPPED FIELD — THERE IS NO FIELD TO DROP.
/// BOOLEAN.md's carried-rule law (RULED 2026-07-26, clause 4) says a generated
/// boolean result DECLARES EVEN-ODD, named by `boolResultFillRule` /
/// `RESULT_FILL_RULE`, and the 07/26 wave made both ports' destructive-boolean
/// emitters stamp that constant onto the `Path` ELEMENT they produce. A LIVE
/// compound shape produces no element: it evaluates to rings at paint time and
/// carries no `fillRule` slot anywhere in the model. So the remedy that wave
/// installed — declare the rule ON the path, and have the canvas honour it —
/// was structurally unavailable on this arm, and the arm kept the bug while
/// its sibling was fixed and pinned. The rule has to come from the constant
/// directly, because the geometry has nowhere to carry it.
///
/// ⚖️ THE SAME SHAPE AS THE RUST FIXTURE, deliberately: an outer 0…100 square
/// with a concentric 25…75 cutter, probed at (50,50) and (10,50). Two ports
/// pinning one law with the same numbers is comparable by inspection; two
/// ports pinning it with different fixtures is an argument.

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

private let black = Color(r: 0, g: 0, b: 0)

/// A paint-free operand. A live compound paints with its OWN fill and never
/// its operands', and leaving these unpainted keeps that visible: a regression
/// that started painting operands would change the picture instead of hiding
/// behind identical colours.
private func bareRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Element {
    .rect(Rect(x: x, y: y, width: w, height: h))
}

private func liveCompound(_ op: CompoundOperation, _ operands: [Element]) -> Element {
    .live(.compoundShape(CompoundShape(
        operation: op,
        operands: operands,
        name: nil,
        fill: Fill(color: black))))
}

/// Render `elem` through `drawElement` and report the alpha at the hole
/// (50, 50) and at the ring (10, 50).
private func render(_ elem: Element) -> (hole: UInt8, ring: UInt8) {
    let (ctx, buf) = makeBitmap()
    defer { buf.deallocate() }
    drawElement(ctx, elem)
    return (alphaAt(buf, 50, 50), alphaAt(buf, 10, 50))
}

// MARK: - The law

/// ⛔⛔ A LIVE SUBTRACTION'S HOLE SURVIVES THE PAINT.
///
/// Red before the repair (hole = 255): `boolSubtract` hands back two
/// co-oriented rings, so the cutter's interior has winding ±2 and a
/// winding-rule fill covers it. The subtraction ran; the hole was refilled at
/// the last step.
@Test func liveSubtractFrontLeavesItsHole() {
    let donut = liveCompound(.subtractFront, [
        bareRect(0, 0, 100, 100),
        bareRect(25, 25, 50, 50),
    ])
    let got = render(donut)
    // The instrument first: a walk that painted nothing reports a flawless
    // hole, so the ring reading is what makes the hole reading evidence.
    #expect(got.ring == 255,
            "POSITIVE CONTROL: the ring must be painted; got \(got.ring)")
    // A boolean result declares EVEN-ODD (BOOLEAN.md clause 4); a bare
    // ctx.fillPath() reads winding, which refills the cutter's interior.
    #expect(got.hole == 0, "a live SubtractFront must leave the hole it cut; got alpha \(got.hole)")
}

/// ⛔ THE UNCHANGED HALF, ASSERTED — GREEN BEFORE AND AFTER.
///
/// A union of two overlapping rects evaluates to ONE ring, and one ring reads
/// identically under both rules. This arm bounds the repair's blast radius to
/// the multi-ring case, and it is NOT red-first for anything: it is the
/// control that makes the red arm above attributable.
@Test func liveUnionSingleRingIsUnchangedByTheRule() {
    let union = liveCompound(.union, [
        bareRect(0, 0, 60, 60),
        bareRect(40, 40, 60, 60),
    ])
    // (50,50) is inside BOTH operands — the overlap, which is where a rule
    // change would show if the result were still two rings.
    let got = render(union)
    #expect(got.hole == 255, "a union's overlap is INSIDE the result")
    #expect(got.ring == 255, "and so is the part only one operand covers")
}
