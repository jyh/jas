import AppKit
import Foundation

/// Smooth tool for simplifying path curves by re-fitting anchor points.
///
/// # Overview
///
/// The Smooth tool is a brush-like tool that simplifies vector paths by
/// reducing the number of anchor points while preserving the overall shape.
/// The user drags the tool over a selected path, and the portion of the path
/// that falls within the tool's circular influence region (radius =
/// `smoothSize`, currently 100 pt) is simplified in real time.
///
/// Only selected, unlocked Path elements are affected. Non-path elements
/// (rectangles, ellipses, text, etc.) and locked paths are skipped.
///
/// # Algorithm
///
/// Each time the tool processes a cursor position (on press and on drag),
/// it runs the following pipeline on every selected path:
///
/// ## 1. Flatten with command map
///
/// The path's command list (MoveTo, LineTo, CurveTo, QuadTo, etc.) is
/// converted into a dense polyline of (x, y) points. Curves are subdivided
/// into `flattenSteps` (20) evenly-spaced samples using de Casteljau
/// evaluation. Straight segments produce a single point.
///
/// Alongside the flat point array, a parallel **command map** array is built:
/// `cmdMap[i]` records the index of the original path command that produced
/// flat point `i`. This mapping is the key data structure that connects the
/// polyline back to the original command list.
///
/// ## 2. Hit detection
///
/// The flat points are scanned to find the **contiguous range** that lies
/// within the tool's circular influence region (distance ≤ `smoothSize`
/// from the cursor). The scan records `firstHit` and `lastHit` — the
/// indices of the first and last flat points inside the circle.
///
/// If no flat points are within range, the path is skipped.
///
/// ## 3. Command mapping
///
/// The flat-point hit indices are mapped back to original command indices
/// via the command map: `firstCmd = cmdMap[firstHit]` and
/// `lastCmd = cmdMap[lastHit]`. These define the range of original
/// commands `[firstCmd, lastCmd]` that will be replaced.
///
/// If `firstCmd == lastCmd`, the influence region only touches points
/// from a single command — there is nothing to merge, so the path is
/// skipped. At least two commands must be affected for smoothing to have
/// any effect.
///
/// ## 4. Re-fit (Schneider curve fitting)
///
/// All flat points whose command index falls in `[firstCmd, lastCmd]`
/// are collected into `rangeFlat`. The start point of `firstCmd` (i.e.
/// the endpoint of the preceding command) is prepended to form
/// `pointsToFit`, ensuring the re-fitted curve begins exactly where the
/// unaffected prefix ends.
///
/// These points are passed to `fitCurve()`, which implements the Schneider
/// curve-fitting algorithm. `smoothError` (8.0) is the maximum allowed
/// deviation. Because this tolerance is relatively generous, the fitter
/// typically produces fewer Bezier segments than the original commands —
/// that is the simplification.
///
/// ## 5. Reassembly
///
/// The original command list is reconstructed in three parts:
///   - **Prefix**: commands `[0, firstCmd)` — unchanged.
///   - **Middle**: the re-fitted CurveTo commands from step 4.
///   - **Suffix**: commands `(lastCmd, end]` — unchanged.
///
/// If the resulting command count is not strictly less than the original,
/// the replacement is discarded (no improvement). Otherwise the path
/// element is replaced in the document.
///
/// ## Cumulative effect
///
/// The effect is cumulative: each drag pass removes more detail, producing
/// progressively smoother curves. Repeatedly dragging over the same region
/// continues to simplify until the path can be represented by a single
/// Bezier segment (or the fit can no longer reduce the command count).
///
/// ## Overlay
///
/// While the tool is active, a cornflower-blue circle (rgba 100, 149, 237,
/// 0.4) is drawn at the cursor position showing the influence region.

private let smoothSize: Double = 100.0
private let smoothError: Double = 8.0

class SmoothTool: CanvasTool {
    private var smoothing = false
    private var lastPos: (Double, Double) = (0, 0)

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        ctx.snapshot()
        smoothing = true
        lastPos = (x, y)
        smoothAt(ctx, x: x, y: y)
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        if smoothing {
            smoothAt(ctx, x: x, y: y)
        }
        lastPos = (x, y)
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        smoothing = false
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        let (x, y) = lastPos
        cgCtx.setStrokeColor(CGColor(red: 0.39, green: 0.58, blue: 0.93, alpha: 0.4))
        cgCtx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        cgCtx.setLineWidth(1.0)
        cgCtx.strokeEllipse(in: CGRect(x: x - smoothSize, y: y - smoothSize,
                                        width: smoothSize * 2, height: smoothSize * 2))
    }

    // MARK: - Smoothing logic

    /// Run the smoothing pipeline at cursor position (x, y).
    ///
    /// For each selected, unlocked path with at least 2 commands:
    ///   1. Flatten the path into a polyline with a command-index map.
    ///   2. Find which flat points fall inside the influence circle.
    ///   3. Map those flat indices back to original command indices.
    ///   4. Re-fit the affected region with Schneider curve fitting.
    ///   5. Splice the re-fitted curves into the original command list.
    /// If the result has fewer commands, update the document.
    private func smoothAt(_ ctx: ToolContext, x: Double, y: Double) {
        let doc = ctx.document
        let radiusSq = smoothSize * smoothSize
        var newDoc = doc

        for es in doc.selection {
            let path = es.path
            let elem = doc.getElement(path)
            guard case .path(let pv) = elem, !pv.locked else { continue }
            guard pv.d.count >= 2 else { continue }

            // Flatten with command mapping.
            let (flat, cmdMap) = flattenWithCmdMap(pv.d)
            guard flat.count >= 2 else { continue }

            // Find contiguous range of flat points within the circle.
            var firstHit: Int? = nil
            var lastHit: Int? = nil
            for i in 0..<flat.count {
                let dx = flat[i].0 - x
                let dy = flat[i].1 - y
                if dx * dx + dy * dy <= radiusSq {
                    if firstHit == nil { firstHit = i }
                    lastHit = i
                }
            }

            guard let fh = firstHit, let lh = lastHit else { continue }

            // Map to command indices.
            let firstCmd = cmdMap[fh]
            let lastCmd = cmdMap[lh]

            // Need at least 2 commands affected to smooth.
            guard firstCmd < lastCmd else { continue }

            // Collect flattened points for the affected command range.
            var rangeFlat: [(Double, Double)] = []
            for i in 0..<flat.count {
                let ci = cmdMap[i]
                if ci >= firstCmd && ci <= lastCmd {
                    rangeFlat.append(flat[i])
                }
            }

            // Include the start point of the first affected command.
            let startPoint = cmdStartPoint(pv.d, firstCmd)
            let pointsToFit = [startPoint] + rangeFlat

            guard pointsToFit.count >= 2 else { continue }

            // Re-fit the points.
            let segments = fitCurve(points: pointsToFit, error: smoothError)
            guard !segments.isEmpty else { continue }

            // Build replacement commands.
            var newCmds: [PathCommand] = []
            // Commands before the affected range.
            newCmds.append(contentsOf: pv.d[..<firstCmd])
            // Re-fitted curves.
            for seg in segments {
                newCmds.append(.curveTo(x1: seg.c1x, y1: seg.c1y,
                                        x2: seg.c2x, y2: seg.c2y,
                                        x: seg.p2x, y: seg.p2y))
            }
            // Commands after the affected range.
            newCmds.append(contentsOf: pv.d[(lastCmd + 1)...])

            // Skip if no actual reduction.
            guard newCmds.count < pv.d.count else { continue }

            let newPath = Path(d: newCmds, fill: pv.fill, stroke: pv.stroke,
                               opacity: pv.opacity, transform: pv.transform,
                               locked: pv.locked)
            newDoc = newDoc.replaceElement(path, with: .path(newPath))
        }

        if newDoc != doc {
            ctx.model.document = newDoc
            ctx.requestUpdate()
        }
    }
}

// Kernel helpers (cmdEndpoint, cmdStartPoint, flattenWithCmdMap) live
// in Geometry/PathOps.swift and are shared across tools.
