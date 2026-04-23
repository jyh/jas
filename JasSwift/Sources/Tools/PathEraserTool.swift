import AppKit
import Foundation

/// Path Eraser tool for splitting and removing path segments.
///
/// # Algorithm
///
/// The eraser sweeps a rectangular region (derived from the cursor position and
/// `eraserSize`) across the canvas. For each path that intersects this region:
///
/// 1. **Flatten** — The path's commands (LineTo, CurveTo, QuadTo, etc.) are
///    flattened into a polyline of straight segments. Bezier curves are
///    approximated with `flattenStepsPerCurve` (20) line segments each.
///
/// 2. **Hit detection** — Walk the flattened segments to find the first and
///    last segments that intersect the eraser rectangle (using Liang-Barsky
///    line-rectangle clipping). This gives the contiguous "hit range."
///
/// 3. **Boundary intersection** — Compute the exact entry and exit points
///    where the path crosses the eraser boundary. Liang-Barsky gives t_min
///    (entry) and t_max (exit) parameters on the first/last hit flat segments.
///
/// 4. **Map back to original commands** — `flatIndexToCmdAndT` converts
///    each flat segment index + t-on-segment into a (command index, t) pair.
///    For a CurveTo with N flatten steps, flat segment j spans
///    t = [j/N, (j+1)/N], so command-level t = (j + t_seg) / N.
///
/// 5. **Curve-preserving split** — De Casteljau's algorithm splits Bezier
///    curves at the entry/exit t parameters, producing two sub-curves that
///    exactly reconstruct the original.
///    - `splitCubicAt(p0, cp1, cp2, end, t)` → two CurveTo commands
///    - `splitQuadAt(p0, cp, end, t)` → two QuadTo commands
///
/// 6. **Reassembly** — For open paths, the result is two sub-paths: one from
///    the original start to the entry point, and one from the exit point to the
///    original end. For closed paths, the path is "unwrapped" into a single
///    open path that runs from the exit point around the non-erased portion
///    back to the entry point.
///
/// Paths whose bounding box is smaller than the eraser are deleted entirely.

private let eraserSize: Double = 2.0
private let flattenStepsPerCurve = elementFlattenSteps

class PathEraserTool: CanvasTool {
    private var erasing = false
    private var lastPos: (Double, Double) = (0, 0)

    func onPress(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        ctx.snapshot()
        erasing = true
        lastPos = (x, y)
        eraseAt(ctx, x: x, y: y)
    }

    func onMove(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, dragging: Bool) {
        if erasing {
            eraseAt(ctx, x: x, y: y)
        }
        lastPos = (x, y)
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        erasing = false
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        let (x, y) = lastPos
        cgCtx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        cgCtx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        cgCtx.setLineWidth(1.0)
        cgCtx.strokeEllipse(in: CGRect(x: x - eraserSize, y: y - eraserSize,
                                        width: eraserSize * 2, height: eraserSize * 2))
    }

    // MARK: - Erasing logic

    private func eraseAt(_ ctx: ToolContext, x: Double, y: Double) {
        let doc = ctx.document
        let half = eraserSize
        let eraserMinX = min(lastPos.0, x) - half
        let eraserMinY = min(lastPos.1, y) - half
        let eraserMaxX = max(lastPos.0, x) + half
        let eraserMaxY = max(lastPos.1, y) + half

        var changed = false
        var newLayers = doc.layers

        for li in 0..<doc.layers.count {
            let layer = doc.layers[li]
            var newChildren: [Element] = []
            var layerChanged = false

            for child in layer.children {
                guard case .path(let pv) = child, !pv.locked else {
                    newChildren.append(child)
                    continue
                }

                let flat = flattenPathCommands(pv.d)
                guard flat.count >= 2 else {
                    newChildren.append(child)
                    continue
                }

                guard let hit = findEraserHit(flat, eraserMinX, eraserMinY,
                                               eraserMaxX, eraserMaxY) else {
                    newChildren.append(child)
                    continue
                }

                // Check if bbox is smaller than eraser -- delete entirely.
                let bounds = pv.bounds
                if bounds.width <= eraserSize * 2.0 && bounds.height <= eraserSize * 2.0 {
                    layerChanged = true
                    continue  // delete
                }

                let isClosed = pv.d.contains(where: { if case .closePath = $0 { return true }; return false })
                let results = splitPathAtEraser(pv.d, hit, isClosed)

                for cmds in results {
                    if cmds.count >= 2 {
                        let openCmds = cmds.filter { if case .closePath = $0 { return false }; return true }
                        let newPath = Path(d: openCmds, fill: pv.fill, stroke: pv.stroke,
                                           opacity: pv.opacity, transform: pv.transform,
                                           locked: pv.locked)
                        newChildren.append(.path(newPath))
                    }
                }
                layerChanged = true
            }

            if layerChanged {
                newLayers[li] = Layer(name: layer.name, children: newChildren,
                                     opacity: layer.opacity, transform: layer.transform)
                changed = true
            }
        }

        if changed {
            let newDoc = Document(layers: newLayers, selectedLayer: doc.selectedLayer,
                                 selection: Set(),
                                 artboards: doc.artboards,
                                 artboardOptions: doc.artboardOptions)
            ctx.model.document = newDoc
            ctx.requestUpdate()
        }
    }
}

// EraserHit + findEraserHit + splitPathAtEraser + helpers live in
// Geometry/PathOps.swift (shared with doc.path.erase_at_rect).
