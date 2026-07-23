import Testing
import Foundation
@testable import JasLib

// Unit tests for the abstract canvas navigation seam (CanvasGestures.swift).
// The pan/zoom math and the raw-event → intent adapter are pure, so they are
// tested here without driving a live NSView. The gesture handlers on
// CanvasNSView are thin wrappers that read platform-event fields and forward
// to these functions; their model-write behavior is covered by the effect
// tests for doc.pan.apply / doc.zoom.apply (the SAME channel).

// MARK: - SH-1 pan math

@Test func navPanAddsDeltaToOffset() {
    let (ox, oy) = CanvasNavMath.pan(offsetX: 100, offsetY: 50, dx: 12, dy: -7)
    #expect(ox == 112)
    #expect(oy == 43)
}

@Test func navPanIsZoomIndependent() {
    // doc.pan.apply adds the screen-pixel delta directly with NO zoom
    // scaling; the pan math must match regardless of the current zoom.
    let (ox, oy) = CanvasNavMath.pan(offsetX: 0, offsetY: 0, dx: 30, dy: 40)
    #expect(ox == 30)
    #expect(oy == 40)
}

// MARK: - SH-1 scroll adapter (raw event deltas → pan intent)

@Test func navPreciseScrollPassesDeltasThrough() {
    // Trackpad (precise) deltas are already in points: 1:1, content follows.
    let intent = CanvasNavAdapter.panIntent(
        scrollingDeltaX: 8, scrollingDeltaY: -5, hasPreciseScrollingDeltas: true)
    #expect(intent == .pan(dx: 8, dy: -5))
}

@Test func navLineScrollScalesToPixels() {
    // Mouse-wheel (line) deltas are scaled by the line height so a wheel
    // notch pans a comparable amount to the Rust wheel handler (×16).
    let intent = CanvasNavAdapter.panIntent(
        scrollingDeltaX: 0, scrollingDeltaY: 3, hasPreciseScrollingDeltas: false)
    #expect(intent == .pan(dx: 0, dy: 3 * CanvasNavAdapter.lineScrollScale))
}

@Test func navScrollDeltaDrivesBothAxes() {
    // Two-finger trackpad scroll carries both axes; the intent must pan in 2D
    // (not the vertical-only mouse-wheel scheme).
    let intent = CanvasNavAdapter.panIntent(
        scrollingDeltaX: -4, scrollingDeltaY: 6, hasPreciseScrollingDeltas: true)
    #expect(intent == .pan(dx: -4, dy: 6))
}

// MARK: - SH-1 end-to-end: adapter intent applied through the pan channel

@Test func navScrollIntentAppliedMatchesHandPanWrite() {
    // Compose the adapter and the pan math the way applyNavIntent does, and
    // confirm the offset moves by exactly the (scaled) scroll delta — the
    // same result doc.pan.apply would produce for an equal cursor delta.
    let intent = CanvasNavAdapter.panIntent(
        scrollingDeltaX: 10, scrollingDeltaY: -3, hasPreciseScrollingDeltas: true)
    guard case let .pan(dx, dy) = intent else {
        Issue.record("expected a pan intent")
        return
    }
    let (ox, oy) = CanvasNavMath.pan(offsetX: 200, offsetY: 100, dx: dx, dy: dy)
    #expect(ox == 210)
    #expect(oy == 97)
}
