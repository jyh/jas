// Path-level operations: anchor insertion / deletion, eraser split,
// cubic/quad evaluation + projection. The Swift analogue of
// jas_dioxus/src/geometry/path_ops.rs.
//
// L2 primitives per NATIVE_BOUNDARY.md §5 — path geometry is shared
// across vector-illustration apps. interpreter/YamlToolEffects.swift's
// doc.path.* effects call into this module.

import Foundation

// MARK: - Basic helpers

/// Linear interpolation.
public func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + t * (b - a)
}

/// Evaluate a cubic Bezier at parameter t.
public func evalCubic(
    _ x0: Double, _ y0: Double,
    _ x1: Double, _ y1: Double,
    _ x2: Double, _ y2: Double,
    _ x3: Double, _ y3: Double,
    _ t: Double
) -> (Double, Double) {
    let mt = 1 - t
    let x = pow(mt, 3) * x0
        + 3 * pow(mt, 2) * t * x1
        + 3 * mt * pow(t, 2) * x2
        + pow(t, 3) * x3
    let y = pow(mt, 3) * y0
        + 3 * pow(mt, 2) * t * y1
        + 3 * mt * pow(t, 2) * y2
        + pow(t, 3) * y3
    return (x, y)
}

/// Endpoint of a path command (ClosePath has no endpoint → nil).
public func cmdEndpoint(_ cmd: PathCommand) -> (Double, Double)? {
    switch cmd {
    case .moveTo(let x, let y): return (x, y)
    case .lineTo(let x, let y): return (x, y)
    case .curveTo(_, _, _, _, let x, let y): return (x, y)
    case .quadTo(_, _, let x, let y): return (x, y)
    case .smoothCurveTo(_, _, let x, let y): return (x, y)
    case .smoothQuadTo(let x, let y): return (x, y)
    case .arcTo(_, _, _, _, _, let x, let y): return (x, y)
    case .closePath: return nil
    }
}

/// Build a parallel array of "pen position before each command."
public func cmdStartPoints(_ cmds: [PathCommand]) -> [(Double, Double)] {
    var starts = Array(repeating: (0.0, 0.0), count: cmds.count)
    var cur: (Double, Double) = (0, 0)
    for i in cmds.indices {
        starts[i] = cur
        if let pt = cmdEndpoint(cmds[i]) { cur = pt }
    }
    return starts
}

/// Start point of the command at `cmdIdx`. `(0, 0)` when `cmdIdx == 0`
/// or the prior command has no endpoint (ClosePath).
public func cmdStartPoint(_ cmds: [PathCommand], _ cmdIdx: Int) -> (Double, Double) {
    if cmdIdx == 0 { return (0, 0) }
    return cmdEndpoint(cmds[cmdIdx - 1]) ?? (0, 0)
}

// MARK: - Flattening

/// Flatten path commands into a polyline with a parallel cmd-index
/// map. Mirrors Smooth/PathEraser's flatten_with_cmd_map.
public func flattenWithCmdMap(
    _ cmds: [PathCommand]
) -> ([(Double, Double)], [Int]) {
    var pts: [(Double, Double)] = []
    var map: [Int] = []
    var cx: Double = 0
    var cy: Double = 0
    let steps = flattenSteps
    for (cmdIdx, cmd) in cmds.enumerated() {
        switch cmd {
        case .moveTo(let x, let y), .lineTo(let x, let y):
            pts.append((x, y))
            map.append(cmdIdx)
            cx = x; cy = y
        case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let mt = 1 - t
                let px = pow(mt, 3) * cx
                    + 3 * pow(mt, 2) * t * x1
                    + 3 * mt * pow(t, 2) * x2
                    + pow(t, 3) * x
                let py = pow(mt, 3) * cy
                    + 3 * pow(mt, 2) * t * y1
                    + 3 * mt * pow(t, 2) * y2
                    + pow(t, 3) * y
                pts.append((px, py))
                map.append(cmdIdx)
            }
            cx = x; cy = y
        case .quadTo(let x1, let y1, let x, let y):
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let mt = 1 - t
                let px = pow(mt, 2) * cx + 2 * mt * t * x1 + pow(t, 2) * x
                let py = pow(mt, 2) * cy + 2 * mt * t * y1 + pow(t, 2) * y
                pts.append((px, py))
                map.append(cmdIdx)
            }
            cx = x; cy = y
        case .closePath:
            // skip
            break
        default:
            if let (ex, ey) = cmdEndpoint(cmd) {
                pts.append((ex, ey))
                map.append(cmdIdx)
                cx = ex; cy = ey
            }
        }
    }
    return (pts, map)
}

// MARK: - Projection

/// Closest-point projection onto a line segment. Returns (distance, t).
public func closestOnLine(
    _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
    _ px: Double, _ py: Double
) -> (Double, Double) {
    let dx = x1 - x0
    let dy = y1 - y0
    let lenSq = dx * dx + dy * dy
    if lenSq == 0 {
        let d = ((px - x0) * (px - x0) + (py - y0) * (py - y0)).squareRoot()
        return (d, 0)
    }
    var t = ((px - x0) * dx + (py - y0) * dy) / lenSq
    t = max(0, min(1, t))
    let qx = x0 + t * dx
    let qy = y0 + t * dy
    let d = ((px - qx) * (px - qx) + (py - qy) * (py - qy)).squareRoot()
    return (d, t)
}

/// Closest-point projection onto a cubic. 50-sample coarse pass +
/// 20-iter trisection refinement — native-equivalent.
public func closestOnCubic(
    _ x0: Double, _ y0: Double,
    _ x1: Double, _ y1: Double,
    _ x2: Double, _ y2: Double,
    _ x3: Double, _ y3: Double,
    _ px: Double, _ py: Double
) -> (Double, Double) {
    let steps = 50
    var bestDist = Double.infinity
    var bestT = 0.0
    for i in 0...steps {
        let t = Double(i) / Double(steps)
        let (bx, by) = evalCubic(x0, y0, x1, y1, x2, y2, x3, y3, t)
        let d = ((px - bx) * (px - bx) + (py - by) * (py - by)).squareRoot()
        if d < bestDist { bestDist = d; bestT = t }
    }
    var lo = max(bestT - 1.0 / Double(steps), 0)
    var hi = min(bestT + 1.0 / Double(steps), 1)
    for _ in 0..<20 {
        let t1 = lo + (hi - lo) / 3
        let t2 = hi - (hi - lo) / 3
        let (bx1, by1) = evalCubic(x0, y0, x1, y1, x2, y2, x3, y3, t1)
        let (bx2, by2) = evalCubic(x0, y0, x1, y1, x2, y2, x3, y3, t2)
        let d1 = ((px - bx1) * (px - bx1) + (py - by1) * (py - by1)).squareRoot()
        let d2 = ((px - bx2) * (px - bx2) + (py - by2) * (py - by2)).squareRoot()
        if d1 < d2 { hi = t2 } else { lo = t1 }
    }
    bestT = (lo + hi) / 2
    let (bx, by) = evalCubic(x0, y0, x1, y1, x2, y2, x3, y3, bestT)
    bestDist = ((px - bx) * (px - bx) + (py - by) * (py - by)).squareRoot()
    return (bestDist, bestT)
}

/// Find which segment of a path `(px, py)` is closest to, plus the
/// t-on-that-segment. Returns `(cmd_idx, t)` — the index refers to
/// the LineTo / CurveTo command that owns the segment.
public func closestSegmentAndT(
    _ d: [PathCommand], _ px: Double, _ py: Double
) -> (Int, Double)? {
    var bestDist = Double.infinity
    var bestSeg = 0
    var bestT = 0.0
    var cx: Double = 0
    var cy: Double = 0
    for (i, cmd) in d.enumerated() {
        switch cmd {
        case .moveTo(let x, let y):
            cx = x; cy = y
        case .lineTo(let x, let y):
            let (dist, t) = closestOnLine(cx, cy, x, y, px, py)
            if dist < bestDist { bestDist = dist; bestSeg = i; bestT = t }
            cx = x; cy = y
        case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
            let (dist, t) = closestOnCubic(cx, cy, x1, y1, x2, y2, x, y, px, py)
            if dist < bestDist { bestDist = dist; bestSeg = i; bestT = t }
            cx = x; cy = y
        default:
            break
        }
    }
    return bestDist.isFinite ? (bestSeg, bestT) : nil
}

// MARK: - Splitting

/// Split a cubic at t. Returns `(first, second)` where each is a
/// tuple of (x1, y1, x2, y2, x, y) — control handles + end point.
public func splitCubic(
    _ x0: Double, _ y0: Double,
    _ x1: Double, _ y1: Double,
    _ x2: Double, _ y2: Double,
    _ x3: Double, _ y3: Double,
    _ t: Double
) -> (
    (Double, Double, Double, Double, Double, Double),
    (Double, Double, Double, Double, Double, Double)
) {
    let a1x = lerp(x0, x1, t), a1y = lerp(y0, y1, t)
    let a2x = lerp(x1, x2, t), a2y = lerp(y1, y2, t)
    let a3x = lerp(x2, x3, t), a3y = lerp(y2, y3, t)
    let b1x = lerp(a1x, a2x, t), b1y = lerp(a1y, a2y, t)
    let b2x = lerp(a2x, a3x, t), b2y = lerp(a2y, a3y, t)
    let mx = lerp(b1x, b2x, t), my = lerp(b1y, b2y, t)
    return (
        (a1x, a1y, b1x, b1y, mx, my),
        (b2x, b2y, a3x, a3y, x3, y3)
    )
}

/// Split a cubic at t, returning two `PathCommand.curveTo` values.
public func splitCubicCmdAt(
    _ p0: (Double, Double),
    _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
    _ x: Double, _ y: Double,
    _ t: Double
) -> (PathCommand, PathCommand) {
    let (first, second) = splitCubic(p0.0, p0.1, x1, y1, x2, y2, x, y, t)
    return (
        .curveTo(x1: first.0, y1: first.1,
                 x2: first.2, y2: first.3,
                 x: first.4, y: first.5),
        .curveTo(x1: second.0, y1: second.1,
                 x2: second.2, y2: second.3,
                 x: second.4, y: second.5)
    )
}

/// Split a quadratic at t, returning two `PathCommand.quadTo` values.
public func splitQuadCmdAt(
    _ p0: (Double, Double),
    _ qx: Double, _ qy: Double, _ x: Double, _ y: Double,
    _ t: Double
) -> (PathCommand, PathCommand) {
    let ax = lerp(p0.0, qx, t), ay = lerp(p0.1, qy, t)
    let bx = lerp(qx, x, t), by = lerp(qy, y, t)
    let cx = lerp(ax, bx, t), cy = lerp(ay, by, t)
    return (
        .quadTo(x1: ax, y1: ay, x: cx, y: cy),
        .quadTo(x1: bx, y1: by, x: x, y: y)
    )
}

// MARK: - Anchor deletion

/// Delete the anchor at `anchorIdx` from `d`. Returns nil if the
/// result would have < 2 anchors. Interior deletion merges adjacent
/// segments preserving outer handles (curve+curve → single curve,
/// etc.).
public func deleteAnchorFromPath(
    _ d: [PathCommand], _ anchorIdx: Int
) -> [PathCommand]? {
    let anchorCount = d.filter { cmd in
        switch cmd {
        case .moveTo, .lineTo, .curveTo: return true
        default: return false
        }
    }.count
    if anchorCount <= 2 { return nil }

    // First anchor: promote command[1] into the new MoveTo.
    if anchorIdx == 0 {
        guard d.count > 1 else { return nil }
        let second = d[1]
        let (nx, ny): (Double, Double)
        switch second {
        case .lineTo(let x, let y): (nx, ny) = (x, y)
        case .curveTo(_, _, _, _, let x, let y): (nx, ny) = (x, y)
        default: return nil
        }
        var result: [PathCommand] = [.moveTo(nx, ny)]
        result.append(contentsOf: d.dropFirst(2))
        return result
    }

    // Last anchor: trim trailing segment, keep any ClosePath.
    let lastCmdIdx = d.count - 1
    let effectiveLast: Int
    if case .closePath = d[lastCmdIdx] {
        effectiveLast = max(lastCmdIdx - 1, 0)
    } else {
        effectiveLast = lastCmdIdx
    }
    if anchorIdx == effectiveLast {
        var result = Array(d[..<anchorIdx])
        if effectiveLast < lastCmdIdx {
            result.append(.closePath)
        }
        return result
    }

    // Interior: merge this command with the next.
    var result: [PathCommand] = []
    let cmdAt = d[anchorIdx]
    let cmdAfter = d[anchorIdx + 1]
    for (i, cmd) in d.enumerated() {
        if i == anchorIdx {
            switch (cmdAt, cmdAfter) {
            case (.curveTo(let x1, let y1, _, _, _, _),
                  .curveTo(_, _, let x2, let y2, let x, let y)):
                result.append(.curveTo(x1: x1, y1: y1, x2: x2, y2: y2, x: x, y: y))
            case (.curveTo(let x1, let y1, _, _, _, _),
                  .lineTo(let x, let y)):
                result.append(.curveTo(x1: x1, y1: y1, x2: x, y2: y, x: x, y: y))
            case (.lineTo(_, _),
                  .curveTo(_, _, let x2, let y2, let x, let y)):
                let (px, py): (Double, Double) = (anchorIdx > 0)
                    ? (cmdEndpoint(d[anchorIdx - 1]) ?? (0, 0))
                    : (0, 0)
                result.append(.curveTo(x1: px, y1: py, x2: x2, y2: y2, x: x, y: y))
            case (.lineTo(_, _), .lineTo(let x, let y)):
                result.append(.lineTo(x, y))
            default: break
            }
            continue
        }
        if i == anchorIdx + 1 { continue }
        result.append(cmd)
    }
    return result
}

// MARK: - Anchor insertion

/// Result of inserting an anchor along a segment.
public struct InsertAnchorResult: Equatable {
    public let commands: [PathCommand]
    public let firstNewIdx: Int
    public let anchorX: Double
    public let anchorY: Double
}

/// Insert an anchor at parameter `t` along the segment at `segIdx`.
/// Returns the new command list plus the new anchor's position.
public func insertPointInPath(
    _ d: [PathCommand], _ segIdx: Int, _ t: Double
) -> InsertAnchorResult {
    var result: [PathCommand] = []
    var cx: Double = 0
    var cy: Double = 0
    var firstNewIdx = 0
    var anchorX = 0.0
    var anchorY = 0.0
    for (i, cmd) in d.enumerated() {
        if i == segIdx {
            switch cmd {
            case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
                let (first, second) = splitCubic(cx, cy, x1, y1, x2, y2, x, y, t)
                firstNewIdx = result.count
                anchorX = first.4; anchorY = first.5
                result.append(.curveTo(
                    x1: first.0, y1: first.1,
                    x2: first.2, y2: first.3,
                    x: first.4, y: first.5))
                result.append(.curveTo(
                    x1: second.0, y1: second.1,
                    x2: second.2, y2: second.3,
                    x: second.4, y: second.5))
                cx = x; cy = y
                continue
            case .lineTo(let x, let y):
                let mx = lerp(cx, x, t), my = lerp(cy, y, t)
                firstNewIdx = result.count
                anchorX = mx; anchorY = my
                result.append(.lineTo(mx, my))
                result.append(.lineTo(x, y))
                cx = x; cy = y
                continue
            default: break
            }
        }
        switch cmd {
        case .moveTo(let x, let y): cx = x; cy = y
        case .lineTo(let x, let y): cx = x; cy = y
        case .curveTo(_, _, _, _, let x, let y): cx = x; cy = y
        default: break
        }
        result.append(cmd)
    }
    return InsertAnchorResult(
        commands: result, firstNewIdx: firstNewIdx,
        anchorX: anchorX, anchorY: anchorY)
}

// MARK: - Eraser (Liang-Barsky + find hit + split)

public func liangBarskyTMin(
    _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
    _ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double
) -> Double {
    let dx = x2 - x1, dy = y2 - y1
    var tMin = 0.0
    for (p, q) in [
        (-dx, x1 - minX), (dx, maxX - x1),
        (-dy, y1 - minY), (dy, maxY - y1),
    ] {
        if abs(p) >= 1e-12 && p < 0 {
            tMin = max(tMin, q / p)
        }
    }
    return max(0, min(1, tMin))
}

public func liangBarskyTMax(
    _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
    _ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double
) -> Double {
    let dx = x2 - x1, dy = y2 - y1
    var tMax = 1.0
    for (p, q) in [
        (-dx, x1 - minX), (dx, maxX - x1),
        (-dy, y1 - minY), (dy, maxY - y1),
    ] {
        if abs(p) >= 1e-12 && p > 0 {
            tMax = min(tMax, q / p)
        }
    }
    return max(0, min(1, tMax))
}

public func lineSegmentIntersectsRect(
    _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
    _ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double
) -> Bool {
    if x1 >= minX && x1 <= maxX && y1 >= minY && y1 <= maxY { return true }
    if x2 >= minX && x2 <= maxX && y2 >= minY && y2 <= maxY { return true }
    var tMin = 0.0
    var tMax = 1.0
    let dx = x2 - x1, dy = y2 - y1
    for (p, q) in [
        (-dx, x1 - minX), (dx, maxX - x1),
        (-dy, y1 - minY), (dy, maxY - y1),
    ] {
        if abs(p) < 1e-12 {
            if q < 0 { return false }
        } else {
            let t = q / p
            if p < 0 { tMin = max(tMin, t) }
            else { tMax = min(tMax, t) }
            if tMin > tMax { return false }
        }
    }
    return true
}

// MARK: - Eraser (findEraserHit + splitPathAtEraser)

/// Where an eraser-stroke rectangle first clips a path's flattened
/// polyline. Carries both flat-segment indices and the exact entry/exit
/// points for curve-preserving splitting.
public struct EraserHit: Equatable {
    public let firstFlatIdx: Int
    public let lastFlatIdx: Int
    public let entryTSeg: Double
    public let entry: (Double, Double)
    public let exitTSeg: Double
    public let exitPt: (Double, Double)

    public static func == (lhs: EraserHit, rhs: EraserHit) -> Bool {
        lhs.firstFlatIdx == rhs.firstFlatIdx
            && lhs.lastFlatIdx == rhs.lastFlatIdx
            && lhs.entryTSeg == rhs.entryTSeg
            && lhs.entry.0 == rhs.entry.0 && lhs.entry.1 == rhs.entry.1
            && lhs.exitTSeg == rhs.exitTSeg
            && lhs.exitPt.0 == rhs.exitPt.0 && lhs.exitPt.1 == rhs.exitPt.1
    }
}

/// Walk the flattened polyline `flat` and return the first contiguous
/// run of segments that intersect the rect `[minX..maxX] × [minY..maxY]`,
/// plus the exact entry/exit points. Returns nil if no segment intersects.
public func findEraserHit(
    _ flat: [(Double, Double)],
    _ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double
) -> EraserHit? {
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

    let (ex1, ey1) = flat[firstHit]
    let (ex2, ey2) = flat[firstHit + 1]
    let entryTSeg: Double
    if ex1 >= minX && ex1 <= maxX && ey1 >= minY && ey1 <= maxY {
        entryTSeg = 0.0
    } else {
        entryTSeg = liangBarskyTMin(ex1, ey1, ex2, ey2, minX, minY, maxX, maxY)
    }
    let entry = (ex1 + entryTSeg * (ex2 - ex1), ey1 + entryTSeg * (ey2 - ey1))

    let (lx1, ly1) = flat[lastHit]
    let (lx2, ly2) = flat[lastHit + 1]
    let exitTSeg: Double
    if lx2 >= minX && lx2 <= maxX && ly2 >= minY && ly2 <= maxY {
        exitTSeg = 1.0
    } else {
        exitTSeg = liangBarskyTMax(lx1, ly1, lx2, ly2, minX, minY, maxX, maxY)
    }
    let exitPt = (lx1 + exitTSeg * (lx2 - lx1), ly1 + exitTSeg * (ly2 - ly1))

    return EraserHit(
        firstFlatIdx: firstHit, lastFlatIdx: lastHit,
        entryTSeg: entryTSeg, entry: entry,
        exitTSeg: exitTSeg, exitPt: exitPt)
}

/// Map a `(flatIdx, tOnSeg)` pair back to `(commandIdx, t)` on the
/// original command list. LineTo → 1 segment; CurveTo/QuadTo →
/// `elementFlattenSteps` segments (matches flattenWithCmdMap).
public func flatIndexToCmdAndT(
    _ cmds: [PathCommand], _ flatIdx: Int, _ tOnSeg: Double
) -> (Int, Double) {
    var flatCount = 0
    for cmdIdx in cmds.indices {
        let segs: Int
        switch cmds[cmdIdx] {
        case .moveTo: segs = 0
        case .lineTo: segs = 1
        case .curveTo, .quadTo: segs = elementFlattenSteps
        case .closePath: segs = 1
        default: segs = 1
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

/// First half of a command split at `t` (LineTo/CurveTo/QuadTo aware).
/// For segments without a native split representation, falls back to a
/// LineTo to the interpolated endpoint.
public func entryCmd(
    _ cmd: PathCommand, _ start: (Double, Double), _ t: Double
) -> PathCommand {
    switch cmd {
    case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
        return splitCubicCmdAt(start, x1, y1, x2, y2, x, y, t).0
    case .quadTo(let qx, let qy, let x, let y):
        return splitQuadCmdAt(start, qx, qy, x, y, t).0
    default:
        let end = cmdEndpoint(cmd) ?? start
        return .lineTo(start.0 + t * (end.0 - start.0),
                       start.1 + t * (end.1 - start.1))
    }
}

/// Second half of a command split at `t`.
public func exitCmd(
    _ cmd: PathCommand, _ start: (Double, Double), _ t: Double
) -> PathCommand {
    switch cmd {
    case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
        return splitCubicCmdAt(start, x1, y1, x2, y2, x, y, t).1
    case .quadTo(let qx, let qy, let x, let y):
        return splitQuadCmdAt(start, qx, qy, x, y, t).1
    default:
        let end = cmdEndpoint(cmd) ?? start
        return .lineTo(end.0, end.1)
    }
}

/// Cut `cmds` at the eraser hit. Open paths produce 0–2 sub-paths;
/// closed paths are unwrapped into a single open path running from the
/// exit point around the non-erased side back to the entry point.
public func splitPathAtEraser(
    _ cmds: [PathCommand], _ hit: EraserHit, _ isClosed: Bool
) -> [[PathCommand]] {
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
        openCmds.append(.moveTo(hit.exitPt.0, hit.exitPt.1))
        if exitT < 1.0 - 1e-9 {
            if let (origIdx, cmd) = drawingCmds.first(where: { $0.0 == exitCmdIdx }) {
                openCmds.append(exitCmd(cmd, starts[origIdx], exitT))
            }
        }
        let resumeFrom = exitCmdIdx + 1
        for (origIdx, cmd) in drawingCmds {
            if origIdx >= resumeFrom && origIdx < cmds.count {
                openCmds.append(cmd)
            }
        }
        if case .moveTo(let mx, let my) = drawingCmds[0].1 {
            openCmds.append(.lineTo(mx, my))
        }
        for (origIdx, cmd) in drawingCmds {
            if origIdx >= 1 && origIdx < entryCmdIdx {
                openCmds.append(cmd)
            }
        }
        if entryT > 1e-9 {
            openCmds.append(entryCmd(cmds[entryCmdIdx], starts[entryCmdIdx], entryT))
        } else {
            openCmds.append(.lineTo(hit.entry.0, hit.entry.1))
        }
        if openCmds.count >= 2 { return [openCmds] }
        return []
    } else {
        var part1: [PathCommand] = []
        var part2: [PathCommand] = []
        for cmd in cmds[..<entryCmdIdx] { part1.append(cmd) }
        if entryT > 1e-9 {
            part1.append(entryCmd(cmds[entryCmdIdx], starts[entryCmdIdx], entryT))
        } else {
            part1.append(.lineTo(hit.entry.0, hit.entry.1))
        }
        part2.append(.moveTo(hit.exitPt.0, hit.exitPt.1))
        if exitT < 1.0 - 1e-9 {
            part2.append(exitCmd(cmds[exitCmdIdx], starts[exitCmdIdx], exitT))
        }
        if exitCmdIdx + 1 < cmds.count {
            for cmd in cmds[(exitCmdIdx + 1)...] {
                if case .closePath = cmd { continue }
                part2.append(cmd)
            }
        }
        var result: [[PathCommand]] = []
        let part1HasNonMove = part1.contains {
            if case .moveTo = $0 { return false }
            return true
        }
        if part1.count >= 2 && part1HasNonMove { result.append(part1) }
        if part2.count >= 2 { result.append(part2) }
        return result
    }
}

// MARK: - Path ↔ PolygonSet adapters
//
// Blob Brush's commit path needs to hand PathElem geometry to the
// Algorithms/Boolean module (which speaks in `BoolPolygonSet` /
// `BoolRing` terms) and then convert the unioned / subtracted result
// back to `[PathCommand]` for the new element's `d` field. The
// algorithm module is deliberately geometry-only; this pair is the
// element-level bridge.
//
// `BoolPolygonSet` is `[BoolRing]`, `BoolRing` is `[(Double, Double)]`
// — same shape as `flattenPathToRings`, which we reuse verbatim for
// the forward direction. The reverse direction emits
// `MoveTo` + LineTos + `ClosePath` per ring.

/// Flatten a `PathCommand` list to the `BoolPolygonSet` shape expected
/// by Algorithms/Boolean. Alias for `flattenPathToRings`, named to
/// match BLOB_BRUSH_TOOL.md §Commit pipeline.
public func pathToPolygonSet(_ d: [PathCommand]) -> BoolPolygonSet {
    flattenPathToRings(d)
}

/// Emit a `[PathCommand]` from a `BoolPolygonSet`. One
/// `MoveTo` + LineTos + `ClosePath` subpath per ring. Rings with
/// fewer than 3 vertices are dropped (a 1- or 2-vertex "ring" has
/// no interior).
public func polygonSetToPath(_ ps: BoolPolygonSet) -> [PathCommand] {
    var out: [PathCommand] = []
    for ring in ps {
        if ring.count < 3 { continue }
        out.append(.moveTo(ring[0].0, ring[0].1))
        for i in 1..<ring.count {
            out.append(.lineTo(ring[i].0, ring[i].1))
        }
        out.append(.closePath)
    }
    return out
}
