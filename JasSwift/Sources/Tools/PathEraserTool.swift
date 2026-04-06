import AppKit
import Foundation

/// Path Eraser tool for splitting and removing path segments.
///
/// When dragged over a path, the eraser splits the path at the drag area,
/// creating two endpoints on either side. Closed paths become open; open paths
/// become two separate paths. Paths with bounding boxes smaller than the eraser
/// size are deleted entirely.

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
            lastPos = (x, y)
        }
    }

    func onRelease(_ ctx: ToolContext, x: Double, y: Double, shift: Bool, alt: Bool) {
        erasing = false
    }

    func drawOverlay(_ ctx: ToolContext, _ cgCtx: CGContext) {
        guard erasing else { return }
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

                guard let hitIdx = findHitSegment(flat, eraserMinX, eraserMinY,
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
                let results = splitPathAtSegment(pv.d, hitIdx, isClosed)

                for cmds in results {
                    if cmds.count >= 2 {
                        // Remove any ClosePath commands (path is now open).
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
                                 selection: Set())
            ctx.model.document = newDoc
            ctx.requestUpdate()
        }
    }
}

// MARK: - Geometry helpers

private func findHitSegment(_ flat: [(Double, Double)],
                             _ minX: Double, _ minY: Double,
                             _ maxX: Double, _ maxY: Double) -> Int? {
    for i in 0..<(flat.count - 1) {
        let (x1, y1) = flat[i]
        let (x2, y2) = flat[i + 1]
        if lineSegmentIntersectsRect(x1, y1, x2, y2, minX, minY, maxX, maxY) {
            return i
        }
    }
    return nil
}

private func lineSegmentIntersectsRect(_ x1: Double, _ y1: Double,
                                        _ x2: Double, _ y2: Double,
                                        _ minX: Double, _ minY: Double,
                                        _ maxX: Double, _ maxY: Double) -> Bool {
    // Check if either endpoint is inside the rect.
    if x1 >= minX && x1 <= maxX && y1 >= minY && y1 <= maxY { return true }
    if x2 >= minX && x2 <= maxX && y2 >= minY && y2 <= maxY { return true }

    // Liang-Barsky clipping.
    var tMin = 0.0, tMax = 1.0
    let dx = x2 - x1, dy = y2 - y1
    let edges: [(Double, Double)] = [
        (-dx, x1 - minX), (dx, maxX - x1),
        (-dy, y1 - minY), (dy, maxY - y1),
    ]
    for (p, q) in edges {
        if abs(p) < 1e-12 {
            if q < 0 { return false }
        } else {
            let t = q / p
            if p < 0 {
                tMin = max(tMin, t)
            } else {
                tMax = min(tMax, t)
            }
            if tMin > tMax { return false }
        }
    }
    return true
}

/// Map a flattened polyline index to the corresponding PathCommand index.
private func flatIndexToCmdIndex(_ cmds: [PathCommand], _ flatIdx: Int) -> Int {
    var flatCount = 0
    for cmdIdx in 0..<cmds.count {
        let segs: Int
        switch cmds[cmdIdx] {
        case .moveTo:
            segs = 0
        case .lineTo:
            segs = 1
        case .curveTo:
            segs = flattenStepsPerCurve
        case .closePath:
            segs = 1
        default:
            segs = 1
        }
        if segs > 0 && flatIdx < flatCount + segs {
            return cmdIdx
        }
        flatCount += segs
    }
    return max(0, cmds.count - 1)
}

/// Get the endpoint of a path command.
private func cmdEndpoint(_ cmd: PathCommand) -> (Double, Double)? {
    return cmd.endpoint
}

/// Split a path at the given flattened segment index.
private func splitPathAtSegment(_ cmds: [PathCommand], _ flatHitIdx: Int,
                                 _ isClosed: Bool) -> [[PathCommand]] {
    let cmdIdx = flatIndexToCmdIndex(cmds, flatHitIdx)

    if isClosed {
        let drawingCmds = cmds.filter { if case .closePath = $0 { return false }; return true }
        guard !drawingCmds.isEmpty else { return [] }

        let splitAfter = min(cmdIdx + 1, drawingCmds.count)
        let after = Array(drawingCmds[splitAfter...])
        let before: [PathCommand]
        if drawingCmds.count > 1 {
            before = Array(drawingCmds[1..<min(cmdIdx, drawingCmds.count)])
        } else {
            before = []
        }

        var openCmds: [PathCommand] = []
        let refIdx = splitAfter > 0 ? min(splitAfter - 1, drawingCmds.count - 1) : 0
        let refCmd = drawingCmds[refIdx]
        if let endPt = cmdEndpoint(refCmd) {
            openCmds.append(.moveTo(endPt.0, endPt.1))
        }

        openCmds.append(contentsOf: after)
        if case .moveTo(let mx, let my) = drawingCmds[0] {
            openCmds.append(.lineTo(mx, my))
        }
        openCmds.append(contentsOf: before)

        if openCmds.count >= 2 { return [openCmds] }
        return []
    } else {
        var part1: [PathCommand] = []
        var cur = (0.0, 0.0)
        for cmd in cmds[..<cmdIdx] {
            part1.append(cmd)
            if let pt = cmdEndpoint(cmd) { cur = pt }
        }

        var part2: [PathCommand] = []
        if cmdIdx < cmds.count {
            if let pt = cmdEndpoint(cmds[cmdIdx]) {
                part2.append(.moveTo(pt.0, pt.1))
            } else {
                part2.append(.moveTo(cur.0, cur.1))
            }
        }

        if cmdIdx + 1 < cmds.count {
            for cmd in cmds[(cmdIdx + 1)...] {
                if case .closePath = cmd { continue }
                part2.append(cmd)
            }
        }

        var result: [[PathCommand]] = []
        if part1.count >= 2 && part1.contains(where: { if case .moveTo = $0 { return false }; return true }) {
            result.append(part1)
        }
        if part2.count >= 2 {
            result.append(part2)
        }
        return result
    }
}
