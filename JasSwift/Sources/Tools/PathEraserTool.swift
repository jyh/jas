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

// MARK: - EraserHit

private struct EraserHit {
    let firstFlatIdx: Int
    let lastFlatIdx: Int
    let entryTSeg: Double
    let entry: (Double, Double)
    let exitTSeg: Double
    let exitPt: (Double, Double)
}

// MARK: - Geometry helpers

private func findEraserHit(_ flat: [(Double, Double)],
                            _ minX: Double, _ minY: Double,
                            _ maxX: Double, _ maxY: Double) -> EraserHit? {
    var firstHit = -1
    var lastHit = -1

    for i in 0..<(flat.count - 1) {
        let (x1, y1) = flat[i]
        let (x2, y2) = flat[i + 1]
        if lineSegmentIntersectsRect(x1, y1, x2, y2, minX, minY, maxX, maxY) {
            if firstHit < 0 { firstHit = i }
            lastHit = i
        } else if firstHit >= 0 {
            break
        }
    }

    guard firstHit >= 0 else { return nil }

    // Entry point on first hit segment.
    let (ex1, ey1) = flat[firstHit]
    let (ex2, ey2) = flat[firstHit + 1]
    let entryTSeg: Double
    if ex1 >= minX && ex1 <= maxX && ey1 >= minY && ey1 <= maxY {
        entryTSeg = 0.0
    } else {
        entryTSeg = liangBarskyTMin(ex1, ey1, ex2, ey2, minX, minY, maxX, maxY)
    }
    let entry = (ex1 + entryTSeg * (ex2 - ex1), ey1 + entryTSeg * (ey2 - ey1))

    // Exit point on last hit segment.
    let (lx1, ly1) = flat[lastHit]
    let (lx2, ly2) = flat[lastHit + 1]
    let exitTSeg: Double
    if lx2 >= minX && lx2 <= maxX && ly2 >= minY && ly2 <= maxY {
        exitTSeg = 1.0
    } else {
        exitTSeg = liangBarskyTMax(lx1, ly1, lx2, ly2, minX, minY, maxX, maxY)
    }
    let exitPt = (lx1 + exitTSeg * (lx2 - lx1), ly1 + exitTSeg * (ly2 - ly1))

    return EraserHit(firstFlatIdx: firstHit, lastFlatIdx: lastHit,
                     entryTSeg: entryTSeg, entry: entry,
                     exitTSeg: exitTSeg, exitPt: exitPt)
}

private func liangBarskyTMin(_ x1: Double, _ y1: Double,
                              _ x2: Double, _ y2: Double,
                              _ minX: Double, _ minY: Double,
                              _ maxX: Double, _ maxY: Double) -> Double {
    let dx = x2 - x1, dy = y2 - y1
    var tMin = 0.0
    let edges: [(Double, Double)] = [
        (-dx, x1 - minX), (dx, maxX - x1),
        (-dy, y1 - minY), (dy, maxY - y1),
    ]
    for (p, q) in edges {
        if abs(p) >= 1e-12 && p < 0.0 {
            tMin = max(tMin, q / p)
        }
    }
    return max(0.0, min(1.0, tMin))
}

private func liangBarskyTMax(_ x1: Double, _ y1: Double,
                              _ x2: Double, _ y2: Double,
                              _ minX: Double, _ minY: Double,
                              _ maxX: Double, _ maxY: Double) -> Double {
    let dx = x2 - x1, dy = y2 - y1
    var tMax = 1.0
    let edges: [(Double, Double)] = [
        (-dx, x1 - minX), (dx, maxX - x1),
        (-dy, y1 - minY), (dy, maxY - y1),
    ]
    for (p, q) in edges {
        if abs(p) >= 1e-12 && p > 0.0 {
            tMax = min(tMax, q / p)
        }
    }
    return max(0.0, min(1.0, tMax))
}

private func lineSegmentIntersectsRect(_ x1: Double, _ y1: Double,
                                        _ x2: Double, _ y2: Double,
                                        _ minX: Double, _ minY: Double,
                                        _ maxX: Double, _ maxY: Double) -> Bool {
    if x1 >= minX && x1 <= maxX && y1 >= minY && y1 <= maxY { return true }
    if x2 >= minX && x2 <= maxX && y2 >= minY && y2 <= maxY { return true }

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

// MARK: - Flat index to command mapping

/// Map a flattened-segment index + t on that segment to (command index, t within command).
private func flatIndexToCmdAndT(_ cmds: [PathCommand], _ flatIdx: Int, _ tOnSeg: Double) -> (Int, Double) {
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
        case .quadTo:
            segs = flattenStepsPerCurve
        case .closePath:
            segs = 1
        default:
            segs = 1
        }
        if segs > 0 && flatIdx < flatCount + segs {
            let local = flatIdx - flatCount
            let t = (Double(local) + tOnSeg) / Double(segs)
            return (cmdIdx, max(0.0, min(1.0, t)))
        }
        flatCount += segs
    }
    return (max(0, cmds.count - 1), 1.0)
}

// MARK: - De Casteljau splitting

/// Split a cubic Bezier at parameter t using De Casteljau's algorithm.
private func splitCubicAt(_ p0: (Double, Double),
                           _ x1: Double, _ y1: Double,
                           _ x2: Double, _ y2: Double,
                           _ x: Double, _ y: Double,
                           _ t: Double) -> (PathCommand, PathCommand) {
    let lerp = { (a: Double, b: Double) in a + t * (b - a) }
    // Level 1
    let ax = lerp(p0.0, x1), ay = lerp(p0.1, y1)
    let bx = lerp(x1, x2), by = lerp(y1, y2)
    let cx = lerp(x2, x), cy = lerp(y2, y)
    // Level 2
    let dx = lerp(ax, bx), dy = lerp(ay, by)
    let ex = lerp(bx, cx), ey = lerp(by, cy)
    // Level 3 — point on curve
    let fx = lerp(dx, ex), fy = lerp(dy, ey)

    let first = PathCommand.curveTo(x1: ax, y1: ay, x2: dx, y2: dy, x: fx, y: fy)
    let second = PathCommand.curveTo(x1: ex, y1: ey, x2: cx, y2: cy, x: x, y: y)
    return (first, second)
}

/// Split a quadratic Bezier at parameter t using De Casteljau's algorithm.
private func splitQuadAt(_ p0: (Double, Double),
                          _ qx1: Double, _ qy1: Double,
                          _ x: Double, _ y: Double,
                          _ t: Double) -> (PathCommand, PathCommand) {
    let lerp = { (a: Double, b: Double) in a + t * (b - a) }
    let ax = lerp(p0.0, qx1), ay = lerp(p0.1, qy1)
    let bx = lerp(qx1, x), by = lerp(qy1, y)
    let cx = lerp(ax, bx), cy = lerp(ay, by)

    let first = PathCommand.quadTo(x1: ax, y1: ay, x: cx, y: cy)
    let second = PathCommand.quadTo(x1: bx, y1: by, x: x, y: y)
    return (first, second)
}

/// Get the endpoint of a path command.
private func cmdEndpoint(_ cmd: PathCommand) -> (Double, Double)? {
    return cmd.endpoint
}

/// Build the command start points array (the current point before each command).
private func cmdStartPoints(_ cmds: [PathCommand]) -> [(Double, Double)] {
    var starts = Array(repeating: (0.0, 0.0), count: cmds.count)
    var cur = (0.0, 0.0)
    for i in 0..<cmds.count {
        starts[i] = cur
        if let pt = cmdEndpoint(cmds[i]) {
            cur = pt
        }
    }
    return starts
}

/// Generate the first-half command ending at the entry point, preserving curves.
private func makeEntryCmd(_ cmd: PathCommand, _ start: (Double, Double), _ t: Double) -> PathCommand {
    switch cmd {
    case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
        return splitCubicAt(start, x1, y1, x2, y2, x, y, t).0
    case .quadTo(let x1, let y1, let x, let y):
        return splitQuadAt(start, x1, y1, x, y, t).0
    default:
        let end = cmdEndpoint(cmd) ?? start
        return .lineTo(start.0 + t * (end.0 - start.0),
                       start.1 + t * (end.1 - start.1))
    }
}

/// Generate the second-half command starting from the exit point, preserving curves.
private func makeExitCmd(_ cmd: PathCommand, _ start: (Double, Double), _ t: Double) -> PathCommand {
    switch cmd {
    case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
        return splitCubicAt(start, x1, y1, x2, y2, x, y, t).1
    case .quadTo(let x1, let y1, let x, let y):
        return splitQuadAt(start, x1, y1, x, y, t).1
    default:
        let end = cmdEndpoint(cmd) ?? start
        return .lineTo(end.0, end.1)
    }
}

// MARK: - Path splitting

/// Split a path at the eraser hit, with endpoints hugging the eraser boundary
/// and curves preserved via De Casteljau splitting.
private func splitPathAtEraser(_ cmds: [PathCommand], _ hit: EraserHit,
                                _ isClosed: Bool) -> [[PathCommand]] {
    let (entryCmdIdx, entryT) = flatIndexToCmdAndT(cmds, hit.firstFlatIdx, hit.entryTSeg)
    let (exitCmdIdx, exitT) = flatIndexToCmdAndT(cmds, hit.lastFlatIdx, hit.exitTSeg)
    let starts = cmdStartPoints(cmds)

    if isClosed {
        let drawingCmds: [(Int, PathCommand)] = cmds.enumerated().compactMap { (i, c) in
            if case .closePath = c { return nil }
            return (i, c)
        }
        guard !drawingCmds.isEmpty else { return [] }

        var openCmds: [PathCommand] = []

        // Start at the exit point.
        openCmds.append(.moveTo(hit.exitPt.0, hit.exitPt.1))

        // If the exit command has a remaining portion, add it as a curve.
        if exitT < 1.0 - 1e-9 {
            if let (origIdx, cmd) = drawingCmds.first(where: { $0.0 == exitCmdIdx }) {
                openCmds.append(makeExitCmd(cmd, starts[origIdx], exitT))
            }
        }

        // Commands after the last erased command.
        let resumeFrom = exitCmdIdx + 1
        for (origIdx, cmd) in drawingCmds {
            if origIdx >= resumeFrom && origIdx < cmds.count {
                openCmds.append(cmd)
            }
        }

        // Wrap around: line to original start, then commands before the erased region.
        if case .moveTo(let mx, let my) = drawingCmds[0].1 {
            openCmds.append(.lineTo(mx, my))
        }
        for (origIdx, cmd) in drawingCmds {
            if origIdx >= 1 && origIdx < entryCmdIdx {
                openCmds.append(cmd)
            }
        }

        // End with the entry portion of the entry command.
        if entryT > 1e-9 {
            openCmds.append(makeEntryCmd(cmds[entryCmdIdx], starts[entryCmdIdx], entryT))
        } else {
            openCmds.append(.lineTo(hit.entry.0, hit.entry.1))
        }

        if openCmds.count >= 2 { return [openCmds] }
        return []
    } else {
        var part1: [PathCommand] = []
        var part2: [PathCommand] = []

        // Part 1: commands before entry, plus the first portion of the entry command.
        for cmd in cmds[..<entryCmdIdx] {
            part1.append(cmd)
        }
        if entryT > 1e-9 {
            part1.append(makeEntryCmd(cmds[entryCmdIdx], starts[entryCmdIdx], entryT))
        } else {
            part1.append(.lineTo(hit.entry.0, hit.entry.1))
        }

        // Part 2: start at exit point, add remaining portion of exit command, then rest.
        part2.append(.moveTo(hit.exitPt.0, hit.exitPt.1))
        if exitT < 1.0 - 1e-9 {
            part2.append(makeExitCmd(cmds[exitCmdIdx], starts[exitCmdIdx], exitT))
        }
        if exitCmdIdx + 1 < cmds.count {
            for cmd in cmds[(exitCmdIdx + 1)...] {
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
