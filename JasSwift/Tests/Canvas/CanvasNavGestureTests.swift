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

// MARK: - SH-2 zoom-about-point (pinch) math

/// The screen position of a document point under the current view transform:
/// screen = doc * zoom + offset. Used to assert the anchor invariant.
private func screenOf(docX: Double, docY: Double,
                      zoom: Double, offX: Double, offY: Double) -> (Double, Double) {
    (docX * zoom + offX, docY * zoom + offY)
}

@Test func navZoomKeepsAnchorPointFixed() {
    // The document point currently under the anchor must map back to the same
    // screen anchor after the zoom — the standard pinch expectation.
    let z0 = 1.5, ox0 = 40.0, oy0 = 90.0
    let ax = 300.0, ay = 220.0
    // Document coordinate under the anchor before zooming.
    let docX = (ax - ox0) / z0
    let docY = (ay - oy0) / z0
    let (z1, ox1, oy1) = CanvasNavMath.zoomAbout(
        zoom: z0, offsetX: ox0, offsetY: oy0,
        factor: 1.3, anchorX: ax, anchorY: ay, minZoom: 0.1, maxZoom: 64.0)
    let (sx, sy) = screenOf(docX: docX, docY: docY, zoom: z1, offX: ox1, offY: oy1)
    #expect(abs(sx - ax) < 1e-9)
    #expect(abs(sy - ay) < 1e-9)
    #expect(z1 == z0 * 1.3)
}

@Test func navZoomClampsToMaxAndKeepsAnchorGlued() {
    // Past the max-zoom clamp the anchor still stays glued (pan recompute uses
    // the POST-clamp zoom), and zoom does not exceed the bound.
    let z0 = 40.0, ox0 = 10.0, oy0 = 20.0
    let ax = 150.0, ay = 175.0
    let docX = (ax - ox0) / z0
    let docY = (ay - oy0) / z0
    let (z1, ox1, oy1) = CanvasNavMath.zoomAbout(
        zoom: z0, offsetX: ox0, offsetY: oy0,
        factor: 4.0, anchorX: ax, anchorY: ay, minZoom: 0.1, maxZoom: 64.0)
    #expect(z1 == 64.0)  // 40 * 4 clamped down to 64
    let (sx, sy) = screenOf(docX: docX, docY: docY, zoom: z1, offX: ox1, offY: oy1)
    #expect(abs(sx - ax) < 1e-9)
    #expect(abs(sy - ay) < 1e-9)
}

@Test func navZoomClampsToMinZoom() {
    let (z1, _, _) = CanvasNavMath.zoomAbout(
        zoom: 0.2, offsetX: 0, offsetY: 0,
        factor: 0.1, anchorX: 100, anchorY: 100, minZoom: 0.1, maxZoom: 64.0)
    #expect(z1 == 0.1)  // 0.2 * 0.1 = 0.02 clamped up to 0.1
}

@Test func navPinchFactorIsOnePlusMagnification() {
    // Documents the magnify(with:) adapter contract: AppKit magnification is a
    // fractional delta, so factor = 1 + magnification. A +0.25 pinch zooms in
    // 1.25x about the anchor.
    let (z1, _, _) = CanvasNavMath.zoomAbout(
        zoom: 2.0, offsetX: 0, offsetY: 0,
        factor: 1.0 + 0.25, anchorX: 50, anchorY: 50, minZoom: 0.1, maxZoom: 64.0)
    #expect(z1 == 2.5)
}

// MARK: - SWNAV-008 composed pan-during-pinch (zoom about a MOVING anchor)

// The composed op folds a concurrent screen-pixel pan into a zoom-about-anchor
// in ONE atomic frame — the Figma / native-Preview "pinch while sliding" feel.
// Semantics (derived, not asserted by fiat): the document point under the
// anchor BEFORE the frame ends up under the anchor DISPLACED by the pan delta
// (`anchor + (panDX, panDY)`). Equivalent to `zoomAbout` then a pure
// screen-pixel `pan` — the pan is NOT rescaled by the new zoom, matching
// doc.pan.apply. The applier's `.zoomPan` arm and the magnify handler that
// emits it are thin adapters over this math (same philosophy as SH-1/SH-2).

@Test func navComposedZoomPanKeepsMovingAnchorGlued() {
    // The doc point under the START anchor must map to the anchor DISPLACED by
    // the pan delta after a composed zoom+pan — the moving-anchor invariant.
    let z0 = 1.5, ox0 = 40.0, oy0 = 90.0
    let ax = 300.0, ay = 220.0
    let pdx = 18.0, pdy = -11.0
    let docX = (ax - ox0) / z0
    let docY = (ay - oy0) / z0
    let (z1, ox1, oy1) = CanvasNavMath.zoomAboutWithPan(
        zoom: z0, offsetX: ox0, offsetY: oy0,
        factor: 1.3, anchorX: ax, anchorY: ay,
        panDX: pdx, panDY: pdy, minZoom: 0.1, maxZoom: 64.0)
    let (sx, sy) = screenOf(docX: docX, docY: docY, zoom: z1, offX: ox1, offY: oy1)
    #expect(abs(sx - (ax + pdx)) < 1e-9)
    #expect(abs(sy - (ay + pdy)) < 1e-9)
    #expect(z1 == z0 * 1.3)
}

@Test func navComposedReducesToPureZoomWhenNoPan() {
    // With a zero pan delta the composed op is byte-identical to zoomAbout —
    // this is why routing magnify through `.zoomPan` preserves SWNAV-004
    // exactly on a stationary trackpad pinch (pointer does not move → pan 0).
    let (za, oxa, oya) = CanvasNavMath.zoomAbout(
        zoom: 2.0, offsetX: 33, offsetY: -12,
        factor: 0.8, anchorX: 120, anchorY: 240, minZoom: 0.1, maxZoom: 64.0)
    let (zb, oxb, oyb) = CanvasNavMath.zoomAboutWithPan(
        zoom: 2.0, offsetX: 33, offsetY: -12,
        factor: 0.8, anchorX: 120, anchorY: 240,
        panDX: 0, panDY: 0, minZoom: 0.1, maxZoom: 64.0)
    #expect(za == zb)
    #expect(oxa == oxb)
    #expect(oya == oyb)
}

@Test func navComposedReducesToPurePanWhenNoZoom() {
    // factor == 1 → zoom unchanged and the offset moves by EXACTLY the screen
    // pan delta (no zoom rescaling), matching CanvasNavMath.pan / doc.pan.apply.
    let (z1, ox1, oy1) = CanvasNavMath.zoomAboutWithPan(
        zoom: 3.0, offsetX: 100, offsetY: 50,
        factor: 1.0, anchorX: 400, anchorY: 300,
        panDX: 12, panDY: -7, minZoom: 0.1, maxZoom: 64.0)
    #expect(z1 == 3.0)
    #expect(ox1 == 112)
    #expect(oy1 == 43)
}

@Test func navComposedClampsAndKeepsMovingAnchorGlued() {
    // Past the max-zoom clamp the moving-anchor invariant still holds: the pan
    // recompute uses the POST-clamp zoom, so the START doc point lands under
    // the displaced anchor and zoom does not exceed the bound.
    let z0 = 40.0, ox0 = 10.0, oy0 = 20.0
    let ax = 150.0, ay = 175.0
    let pdx = -25.0, pdy = 9.0
    let docX = (ax - ox0) / z0
    let docY = (ay - oy0) / z0
    let (z1, ox1, oy1) = CanvasNavMath.zoomAboutWithPan(
        zoom: z0, offsetX: ox0, offsetY: oy0,
        factor: 4.0, anchorX: ax, anchorY: ay,
        panDX: pdx, panDY: pdy, minZoom: 0.1, maxZoom: 64.0)
    #expect(z1 == 64.0)  // 40 * 4 clamped down to 64
    let (sx, sy) = screenOf(docX: docX, docY: docY, zoom: z1, offX: ox1, offY: oy1)
    #expect(abs(sx - (ax + pdx)) < 1e-9)
    #expect(abs(sy - (ay + pdy)) < 1e-9)
}

@Test func navComposedEqualsZoomThenScreenPan() {
    // The composition order the applier promises: zoom about the anchor, THEN
    // add the screen-pixel pan (unscaled). Pin it against the hand-rolled
    // two-step so a future refactor cannot silently reorder to pan-then-zoom
    // (which would rescale the pan by the zoom).
    let z0 = 1.25, ox0 = -40.0, oy0 = 15.0
    let (zz, oxz, oyz) = CanvasNavMath.zoomAbout(
        zoom: z0, offsetX: ox0, offsetY: oy0,
        factor: 2.2, anchorX: 210, anchorY: 130, minZoom: 0.1, maxZoom: 64.0)
    let (oxp, oyp) = CanvasNavMath.pan(offsetX: oxz, offsetY: oyz, dx: 14, dy: 6)
    let (z1, ox1, oy1) = CanvasNavMath.zoomAboutWithPan(
        zoom: z0, offsetX: ox0, offsetY: oy0,
        factor: 2.2, anchorX: 210, anchorY: 130,
        panDX: 14, panDY: 6, minZoom: 0.1, maxZoom: 64.0)
    #expect(z1 == zz)
    #expect(ox1 == oxp)
    #expect(oy1 == oyp)
}

@Test func navZoomPanIntentEquatable() {
    // The composed intent is the iOS-ready shape a UIKit pinch recognizer will
    // emit directly (its .changed carries scale AND centroid translation).
    let a = CanvasNavIntent.zoomPan(factor: 1.2, anchorX: 5, anchorY: 6, panDX: 7, panDY: 8)
    let b = CanvasNavIntent.zoomPan(factor: 1.2, anchorX: 5, anchorY: 6, panDX: 7, panDY: 8)
    let c = CanvasNavIntent.zoomPan(factor: 1.2, anchorX: 5, anchorY: 6, panDX: 7, panDY: 9)
    #expect(a == b)
    #expect(a != c)
    // A zero-pan zoomPan is a distinct case from a bare zoomAbout even though
    // the applier collapses them to the same math.
    #expect(CanvasNavIntent.zoomPan(factor: 1.2, anchorX: 5, anchorY: 6, panDX: 0, panDY: 0)
            != CanvasNavIntent.zoomAbout(factor: 1.2, anchorX: 5, anchorY: 6))
}
