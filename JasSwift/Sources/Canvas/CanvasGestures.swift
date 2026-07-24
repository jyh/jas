import Foundation

// Canvas navigation gestures — the iOS-readiness seam.
//
// Platform event handlers (AppKit `scrollWheel(with:)` / `magnify(with:)`
// today; UIKit pan/pinch recognizers later) translate raw device events into
// device-independent `CanvasNavIntent`s; the applier on the canvas view writes
// each intent through the SAME Model view-state channel the Hand and Zoom
// tools use (`view_offset_x/y`, `zoom_level`). No new mutation channel is
// invented, and NO AppKit / UIKit types appear in this file — the abstract
// intent and its math stay portable and unit-testable in isolation.
//
// The write paths mirrored here:
//   • pan       — doc.pan.apply (HAND_TOOL.md): view_offset += screen-pixel
//                 delta, NOT scaled by zoom.
//   • zoomAbout — doc.zoom.apply (ZOOM_TOOL.md §Anchor and clamp math): the
//                 document point under the anchor stays under the anchor;
//                 zoom clamps to [min_zoom, max_zoom] and the pan recompute
//                 uses the POST-clamp zoom so the anchor stays glued at a
//                 clamp boundary.

/// An abstract, device-independent canvas navigation intent. The platform
/// event layer produces these; `CanvasNSView.applyNavIntent` consumes them.
enum CanvasNavIntent: Equatable {
    /// Pan the view by a screen-pixel delta. Content follows the delta
    /// (the Hand-tool feel): a positive `dx` moves canvas content to the
    /// right, a positive `dy` moves it down (the view is y-flipped, so a
    /// larger `view_offset_y` lowers content on screen).
    case pan(dx: Double, dy: Double)
    /// Zoom by a multiplicative `factor` about `(anchorX, anchorY)` given in
    /// viewport-local pixels. The document point under the anchor stays under
    /// the anchor; the zoom clamps to the app's `[min_zoom, max_zoom]`.
    case zoomAbout(factor: Double, anchorX: Double, anchorY: Double)
    /// Zoom about `(anchorX, anchorY)` AND pan by a concurrent screen-pixel
    /// delta in one atomic frame — the "pinch while sliding" compose (SWNAV-008,
    /// Figma / native-Preview feel). The document point under the anchor ends up
    /// under the anchor DISPLACED by `(panDX, panDY)`; the zoom clamps as in
    /// `zoomAbout` and the pan is unscaled by zoom (as in `pan`). This is the
    /// iOS-ready shape: a UIKit pinch recognizer's `.changed` already carries
    /// both a scale and a centroid translation, which map straight onto this
    /// case. A zero pan delta reduces it to `zoomAbout` exactly.
    case zoomPan(factor: Double, anchorX: Double, anchorY: Double,
                 panDX: Double, panDY: Double)
}

/// Pure view-state math shared by the navigation gestures and the existing
/// keyboard / tool zoom paths. Free of AppKit and Model so it is portable to
/// iOS and unit-testable in isolation.
enum CanvasNavMath {
    /// Pan: new offset = old offset + screen-pixel delta. Byte-identical to
    /// the Hand tool's `doc.pan.apply`, which adds the cursor delta to the
    /// view offset with NO zoom scaling (the offset is itself in screen
    /// pixels). Returns the new `(offsetX, offsetY)`.
    static func pan(offsetX: Double, offsetY: Double,
                    dx: Double, dy: Double) -> (Double, Double) {
        (offsetX + dx, offsetY + dy)
    }

    /// Zoom about a viewport-pixel anchor. Returns `(zoom', offsetX', offsetY')`.
    /// The document point under the anchor is invariant across the zoom; `zoom'`
    /// is clamped to `[minZoom, maxZoom]` and the pan recompute uses the
    /// POST-clamp zoom so the anchor stays glued to its screen position even at
    /// a clamp boundary. Byte-identical to the Zoom tool's `doc.zoom.apply`
    /// (and the keyboard `applyZoomAnchored`) anchor math.
    static func zoomAbout(zoom: Double, offsetX: Double, offsetY: Double,
                          factor: Double, anchorX: Double, anchorY: Double,
                          minZoom: Double, maxZoom: Double)
        -> (zoom: Double, offsetX: Double, offsetY: Double) {
        // Document coordinate currently under the anchor.
        let docAx = (anchorX - offsetX) / zoom
        let docAy = (anchorY - offsetY) / zoom
        let zNew = min(max(zoom * factor, minZoom), maxZoom)
        // Solve for the offset that keeps (docAx, docAy) under the anchor.
        return (zNew, anchorX - docAx * zNew, anchorY - docAy * zNew)
    }

    /// Composed zoom-about-anchor + concurrent screen-pixel pan, applied as one
    /// atomic frame (SWNAV-008). Defined as `zoomAbout` FOLLOWED BY a pure
    /// screen-pixel `pan` — the pan is added AFTER the zoom and is NOT rescaled
    /// by the new zoom (mirroring doc.pan.apply, whose offset is itself in
    /// screen pixels). The net invariant: the document point under
    /// `(anchorX, anchorY)` before the frame lands under the DISPLACED anchor
    /// `(anchorX + panDX, anchorY + panDY)` after — the "zoom about a moving
    /// anchor" law that gives the Figma / native-Preview pinch-while-sliding
    /// feel. A zero pan delta collapses this to `zoomAbout` exactly, so a
    /// stationary trackpad pinch is byte-identical to the SH-2 zoom path.
    static func zoomAboutWithPan(zoom: Double, offsetX: Double, offsetY: Double,
                                 factor: Double, anchorX: Double, anchorY: Double,
                                 panDX: Double, panDY: Double,
                                 minZoom: Double, maxZoom: Double)
        -> (zoom: Double, offsetX: Double, offsetY: Double) {
        let (z, ox, oy) = zoomAbout(
            zoom: zoom, offsetX: offsetX, offsetY: offsetY,
            factor: factor, anchorX: anchorX, anchorY: anchorY,
            minZoom: minZoom, maxZoom: maxZoom)
        let (ox2, oy2) = pan(offsetX: ox, offsetY: oy, dx: panDX, dy: panDY)
        return (z, ox2, oy2)
    }
}

/// Translates raw platform scroll/pinch parameters into abstract
/// `CanvasNavIntent`s. Kept as pure functions (no NSEvent) so the mapping
/// — sign convention, precise-vs-line amplitude, zoom-independence — is
/// unit-testable without a live event. The AppKit handlers read the event
/// fields and call these; UIKit handlers will do the same with their own
/// recognizer values.
enum CanvasNavAdapter {
    /// Line-based (mouse-wheel) scroll deltas arrive in "lines", not points;
    /// scale them to a comparable pixel amplitude. Mirrors the Rust wheel
    /// handler's `Lines(p) => p * 16.0` coalescing so the two active ports
    /// pan by the same amount per wheel notch.
    static let lineScrollScale: Double = 16.0

    /// Translate an AppKit scroll event's scrolling deltas into a pan intent.
    /// Content follows the fingers: the view offset moves BY the scroll delta
    /// (unscaled by zoom, mirroring `doc.pan.apply`). Trackpad ("precise")
    /// deltas are already in points and pass through 1:1; mouse-wheel ("line")
    /// deltas are scaled to a comparable pixel amplitude. AppKit already folds
    /// the user's natural-scroll-direction preference into the raw deltas, so
    /// adding them yields the natural "grab the canvas" direction.
    static func panIntent(scrollingDeltaX: Double, scrollingDeltaY: Double,
                          hasPreciseScrollingDeltas: Bool) -> CanvasNavIntent {
        let scale = hasPreciseScrollingDeltas ? 1.0 : lineScrollScale
        return .pan(dx: scrollingDeltaX * scale, dy: scrollingDeltaY * scale)
    }
}
