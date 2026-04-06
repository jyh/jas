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

// MARK: - Helper functions

/// Return the endpoint (final pen position) of a path command.
///
/// Every path command except ClosePath moves the pen to a new position.
/// For ClosePath (which returns to the last MoveTo), we return (0, 0)
/// as a fallback — ClosePath is not expected in a smoothable region.
private func cmdEndpoint(_ cmd: PathCommand) -> (Double, Double) {
    switch cmd {
    case .moveTo(let x, let y), .lineTo(let x, let y):
        return (x, y)
    case .curveTo(_, _, _, _, let x, let y):
        return (x, y)
    case .quadTo(_, _, let x, let y):
        return (x, y)
    case .closePath:
        return (0, 0)
    default:
        return (0, 0)
    }
}

/// Return the start point of command at `cmdIdx`.
///
/// A path command's start point is the endpoint of the preceding command,
/// since each command implicitly begins where the previous one ended. For
/// the first command (index 0), the start point is the origin (0, 0).
///
/// Used during re-fitting to prepend the correct start point to the
/// collected flat points, ensuring the re-fitted curve connects seamlessly
/// with the unaffected prefix of the path.
private func cmdStartPoint(_ cmds: [PathCommand], _ cmdIdx: Int) -> (Double, Double) {
    if cmdIdx == 0 { return (0, 0) }
    return cmdEndpoint(cmds[cmdIdx - 1])
}

/// Flatten path commands into a polyline with a parallel command-index map.
///
/// Returns `(flatPoints, cmdMap)` where:
///   - `flatPoints[i]` is the (x, y) position of the i-th polyline sample.
///   - `cmdMap[i]` is the index of the original path command that produced
///     `flatPoints[i]`.
///
/// **MoveTo** and **LineTo** commands produce exactly one flat point each.
/// **CurveTo** commands are subdivided into `flattenSteps` samples using
/// the cubic Bezier formula:
///     B(t) = (1-t)³·P0 + 3(1-t)²t·P1 + 3(1-t)t²·P2 + t³·P3
/// evaluated at t = 1/steps, 2/steps, …, 1. This captures the curve's
/// shape as a dense polyline while recording which command each sample
/// came from. **QuadTo** commands are similarly subdivided using the
/// quadratic formula. **ClosePath** produces no points.
private func flattenWithCmdMap(_ cmds: [PathCommand]) -> ([(Double, Double)], [Int]) {
    var pts: [(Double, Double)] = []
    var map: [Int] = []
    var cx = 0.0, cy = 0.0
    let steps = flattenSteps

    for (cmdIdx, cmd) in cmds.enumerated() {
        switch cmd {
        case .moveTo(let x, let y):
            pts.append((x, y))
            map.append(cmdIdx)
            cx = x; cy = y
        case .lineTo(let x, let y):
            pts.append((x, y))
            map.append(cmdIdx)
            cx = x; cy = y
        case .curveTo(let x1, let y1, let x2, let y2, let ex, let ey):
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let mt = 1.0 - t
                let px = mt * mt * mt * cx + 3 * mt * mt * t * x1
                       + 3 * mt * t * t * x2 + t * t * t * ex
                let py = mt * mt * mt * cy + 3 * mt * mt * t * y1
                       + 3 * mt * t * t * y2 + t * t * t * ey
                pts.append((px, py))
                map.append(cmdIdx)
            }
            cx = ex; cy = ey
        case .quadTo(let x1, let y1, let ex, let ey):
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let mt = 1.0 - t
                let px = mt * mt * cx + 2 * mt * t * x1 + t * t * ex
                let py = mt * mt * cy + 2 * mt * t * y1 + t * t * ey
                pts.append((px, py))
                map.append(cmdIdx)
            }
            cx = ex; cy = ey
        case .closePath:
            break
        default:
            break
        }
    }
    return (pts, map)
}
