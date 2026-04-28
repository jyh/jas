/// Dash-alignment renderer for stroked paths.
///
/// Pure function — port of `workspace_interpreter/dash_renderer.py`
/// and `jas_dioxus/src/algorithms/dash_renderer.rs`. See DASH_ALIGN.md
/// §Algorithm. Keep all four ports in lockstep.
///
/// Phase 4 ships lines-only support (`.moveTo` / `.lineTo` /
/// `.closePath`). Curve segments will join in a follow-up phase.
///
/// Output: an array of sub-paths. Each sub-path is one solid dash;
/// the caller draws each via the existing solid-stroke pipeline.

import Foundation

private let EPS = 1e-9

public enum DashRenderer {

    /// Expand a dashed stroke into a list of solid sub-paths.
    public static func expandDashedStroke(
        path: [PathCommand],
        dashArray: [Double],
        alignAnchors: Bool
    ) -> [[PathCommand]] {
        guard !path.isEmpty else { return [] }
        // No dashing → single solid sub-path equal to the original.
        if dashArray.isEmpty || dashArray.allSatisfy({ $0 == 0.0 }) {
            // Skip MoveTo-only paths.
            let hasNonMove = path.contains { cmd in
                if case .moveTo = cmd { return false }
                return true
            }
            return hasNonMove ? [path] : []
        }
        // Pad odd-length pattern (SVG semantics).
        let pattern: [Double] = (dashArray.count % 2 == 1)
            ? dashArray + dashArray
            : dashArray
        let subpaths = splitAtMoveTo(path)
        var result: [[PathCommand]] = []
        for sp in subpaths {
            guard hasSegments(sp) else { continue }
            if alignAnchors {
                result.append(contentsOf: expandAlign(sp, pattern: pattern))
            } else {
                result.append(contentsOf: expandPreserve(sp, pattern: pattern))
            }
        }
        return result
    }

    // MARK: - Path utilities

    private static func splitAtMoveTo(_ path: [PathCommand]) -> [[PathCommand]] {
        var subs: [[PathCommand]] = []
        var cur: [PathCommand] = []
        for cmd in path {
            if case .moveTo = cmd {
                if !cur.isEmpty { subs.append(cur) }
                cur = [cmd]
            } else {
                cur.append(cmd)
            }
        }
        if !cur.isEmpty { subs.append(cur) }
        return subs
    }

    private static func hasSegments(_ subpath: [PathCommand]) -> Bool {
        for cmd in subpath {
            if case .lineTo = cmd { return true }
            if case .closePath = cmd { return true }
        }
        return false
    }

    private static func isClosed(_ subpath: [PathCommand]) -> Bool {
        for cmd in subpath {
            if case .closePath = cmd { return true }
        }
        return false
    }

    private static func anchorPoints(_ subpath: [PathCommand]) -> [(Double, Double)] {
        var pts: [(Double, Double)] = []
        for cmd in subpath {
            switch cmd {
            case .moveTo(let x, let y), .lineTo(let x, let y):
                pts.append((x, y))
            default:
                break
            }
        }
        return pts
    }

    private static func segLen(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let dx = b.0 - a.0
        let dy = b.1 - a.1
        return (dx*dx + dy*dy).squareRoot()
    }

    // MARK: - Preserve mode

    private static func expandPreserve(
        _ subpath: [PathCommand],
        pattern: [Double]
    ) -> [[PathCommand]] {
        let anchors = anchorPoints(subpath)
        var anchorsWalk = anchors
        if isClosed(subpath), let first = anchors.first {
            anchorsWalk.append(first)
        }
        guard anchorsWalk.count >= 2 else { return [] }
        let segLengths = (0..<anchorsWalk.count - 1).map {
            segLen(anchorsWalk[$0], anchorsWalk[$0 + 1])
        }
        var cum: [Double] = [0.0]
        var s = 0.0
        for l in segLengths { s += l; cum.append(s) }
        let total = cum.last ?? 0.0
        guard total > 0 else { return [] }
        return emitDashes(anchorsWalk, cum: cum, pattern: pattern,
                          periodOffset: 0.0, tStart: 0.0, tEnd: total)
    }

    // MARK: - Align mode

    private enum BoundaryKind { case ii, ee, ei, ie }

    private static func expandAlign(
        _ subpath: [PathCommand],
        pattern: [Double]
    ) -> [[PathCommand]] {
        let anchors = anchorPoints(subpath)
        let closed = isClosed(subpath)
        var anchorsWalk = anchors
        if closed, let first = anchors.first {
            anchorsWalk.append(first)
        }
        let nSegs = anchorsWalk.count > 0 ? anchorsWalk.count - 1 : 0
        guard nSegs >= 1 else { return [] }
        let basePeriod = pattern.reduce(0, +)
        guard basePeriod > 0 else { return [] }
        let segLengths = (0..<nSegs).map {
            segLen(anchorsWalk[$0], anchorsWalk[$0 + 1])
        }
        if segLengths.allSatisfy({ $0 <= 0 }) { return [] }
        var cum: [Double] = [0.0]
        var s = 0.0
        for l in segLengths { s += l; cum.append(s) }

        var allRanges: [(Double, Double)] = []
        for i in 0..<nSegs {
            let lI = segLengths[i]
            guard lI > 0 else { continue }
            let kind = boundaryKind(i: i, nSegs: nSegs, closed: closed)
            let scale = solveSegmentScale(segL: lI, pattern: pattern, kind: kind)
            let local = segmentDashRanges(segL: lI, pattern: pattern,
                                          scale: scale, kind: kind)
            let off = cum[i]
            for r in local { allRanges.append((r.0 + off, r.1 + off)) }
        }

        var merged = mergeAdjacentRanges(allRanges)

        if closed && merged.count >= 2 {
            let total = cum.last ?? 0.0
            let last = merged[merged.count - 1]
            let first = merged[0]
            if abs(last.1 - total) < EPS && abs(first.0) < EPS {
                let wrapped = (last.0, first.1 + total)
                var newMerged = [wrapped]
                for i in 1..<merged.count - 1 {
                    newMerged.append(merged[i])
                }
                merged = newMerged
            }
        }

        var result: [[PathCommand]] = []
        for (gs, ge) in merged {
            if let sub = subpathBetweenWrapping(anchors: anchorsWalk, cum: cum,
                                                t0: gs, t1: ge, closed: closed) {
                result.append(sub)
            }
        }
        return result
    }

    private static func boundaryKind(i: Int, nSegs: Int, closed: Bool) -> BoundaryKind {
        if closed { return .ii }
        if nSegs == 1 { return .ee }
        if i == 0 { return .ei }
        if i == nSegs - 1 { return .ie }
        return .ii
    }

    private static func solveSegmentScale(
        segL: Double, pattern: [Double], kind: BoundaryKind
    ) -> Double {
        let basePeriod = pattern.reduce(0, +)
        let d0 = pattern[0]
        switch kind {
        case .ii:
            let m = max(1.0, (segL / basePeriod).rounded())
            return segL / (m * basePeriod)
        case .ee:
            let m = max(0.0, ((segL - d0) / basePeriod).rounded())
            let denom = m * basePeriod + d0
            return denom > 0 ? segL / denom : 1.0
        case .ei, .ie:
            let m = max(1.0, ((segL - 0.5 * d0) / basePeriod).rounded())
            let denom = m * basePeriod + 0.5 * d0
            return denom > 0 ? segL / denom : 1.0
        }
    }

    private static func segmentDashRanges(
        segL: Double, pattern: [Double], scale: Double, kind: BoundaryKind
    ) -> [(Double, Double)] {
        let scaled = pattern.map { $0 * scale }
        let period = scaled.reduce(0, +)
        guard period > 0 && segL > 0 else { return [] }
        let halfD = scaled[0] * 0.5
        let offset0: Double
        switch kind {
        case .ee, .ei: offset0 = 0.0
        case .ii, .ie: offset0 = halfD
        }
        var ranges: [(Double, Double)] = []
        var t = 0.0
        var (curIdx, inIdx) = locateInPattern(offset0, pattern: scaled)
        while t < segL - EPS {
            let remaining = scaled[curIdx] - inIdx
            let nextT = min(t + remaining, segL)
            let isDash = (curIdx % 2 == 0)
            if isDash && nextT > t + EPS {
                ranges.append((t, nextT))
            }
            let consumed = nextT - t
            inIdx += consumed
            if inIdx >= scaled[curIdx] - EPS {
                inIdx = 0.0
                curIdx = (curIdx + 1) % scaled.count
            }
            t = nextT
        }
        return ranges
    }

    private static func locateInPattern(
        _ offset: Double, pattern: [Double]
    ) -> (Int, Double) {
        let period = pattern.reduce(0, +)
        guard period > 0 else { return (0, 0.0) }
        var o = offset.truncatingRemainder(dividingBy: period)
        if o < 0 { o += period }
        for (i, w) in pattern.enumerated() {
            if o < w - EPS { return (i, o) }
            o -= w
        }
        return (0, 0.0)
    }

    private static func mergeAdjacentRanges(
        _ ranges: [(Double, Double)]
    ) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for r in ranges {
            if let last = out.last, abs(last.1 - r.0) < EPS {
                out[out.count - 1] = (last.0, r.1)
            } else {
                out.append(r)
            }
        }
        return out
    }

    private static func subpathBetweenWrapping(
        anchors: [(Double, Double)],
        cum: [Double],
        t0: Double, t1: Double,
        closed: Bool
    ) -> [PathCommand]? {
        let total = cum.last ?? 0.0
        if !closed || t1 <= total + EPS {
            return subpathBetween(anchors: anchors, cum: cum, t0: t0, t1: min(t1, total))
        }
        let head = subpathBetween(anchors: anchors, cum: cum, t0: t0, t1: total)
        let tail = subpathBetween(anchors: anchors, cum: cum, t0: 0.0, t1: t1 - total)
        switch (head, tail) {
        case (.some(let h), .some(let t)):
            var combined = h
            for cmd in t.dropFirst() {
                if case .moveTo = cmd { continue }
                combined.append(cmd)
            }
            return combined
        case (.some(let h), nil): return h
        case (nil, .some(let t)): return t
        case (nil, nil): return nil
        }
    }

    private static func subpathBetween(
        anchors: [(Double, Double)],
        cum: [Double],
        t0: Double, t1: Double
    ) -> [PathCommand]? {
        if t1 <= t0 + EPS { return nil }
        let p0 = interpolate(anchors: anchors, cum: cum, t: t0)
        let p1 = interpolate(anchors: anchors, cum: cum, t: t1)
        let i = locateSegment(cum: cum, t: t0)
        let j = locateSegment(cum: cum, t: t1)
        var cmds: [PathCommand] = [.moveTo(p0.0, p0.1)]
        if j > i {
            for k in (i + 1)...j {
                cmds.append(.lineTo(anchors[k].0, anchors[k].1))
            }
        }
        let last = cmds.last!
        var lastX = 0.0, lastY = 0.0
        switch last {
        case .moveTo(let x, let y), .lineTo(let x, let y):
            lastX = x; lastY = y
        default: break
        }
        if abs(lastX - p1.0) > 1e-9 || abs(lastY - p1.1) > 1e-9 {
            cmds.append(.lineTo(p1.0, p1.1))
        }
        return cmds
    }

    private static func interpolate(
        anchors: [(Double, Double)], cum: [Double], t: Double
    ) -> (Double, Double) {
        if t <= 0 { return anchors[0] }
        let total = cum.last ?? 0.0
        if t >= total { return anchors.last! }
        let i = locateSegment(cum: cum, t: t)
        let segL = cum[i + 1] - cum[i]
        if segL <= 0 { return anchors[i] }
        let alpha = (t - cum[i]) / segL
        let a = anchors[i]
        let b = anchors[i + 1]
        return (a.0 + alpha * (b.0 - a.0), a.1 + alpha * (b.1 - a.1))
    }

    private static func locateSegment(cum: [Double], t: Double) -> Int {
        let n = cum.count - 1
        if t <= cum[0] { return 0 }
        if t >= cum[cum.count - 1] { return n - 1 }
        for i in 0..<n {
            if cum[i] <= t && t < cum[i + 1] { return i }
        }
        return n - 1
    }

    private static func emitDashes(
        _ anchorsWalk: [(Double, Double)],
        cum: [Double],
        pattern: [Double],
        periodOffset: Double,
        tStart: Double, tEnd: Double
    ) -> [[PathCommand]] {
        var out: [[PathCommand]] = []
        let period = pattern.reduce(0, +)
        guard period > 0 else { return out }
        var (curIdx, inIdx) = locateInPattern(periodOffset, pattern: pattern)
        var t = tStart
        while t < tEnd - EPS {
            let remaining = pattern[curIdx] - inIdx
            let nextT = min(t + remaining, tEnd)
            let isDash = (curIdx % 2 == 0)
            if isDash && nextT > t + EPS {
                if let sub = subpathBetween(anchors: anchorsWalk, cum: cum, t0: t, t1: nextT) {
                    out.append(sub)
                }
            }
            let consumed = nextT - t
            inIdx += consumed
            if inIdx >= pattern[curIdx] - EPS {
                inIdx = 0.0
                curIdx = (curIdx + 1) % pattern.count
            }
            t = nextT
        }
        return out
    }
}
