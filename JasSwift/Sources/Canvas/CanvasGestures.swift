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
