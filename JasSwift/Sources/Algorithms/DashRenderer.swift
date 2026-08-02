/// Dash-alignment renderer for stroked paths.
///
/// Pure function — port of `workspace_interpreter/dash_renderer.py`
/// and `jas_dioxus/src/algorithms/dash_renderer.rs`. See DASH_ALIGN.md
/// §Algorithm. Keep all four ports in lockstep.
///
/// Lines AND curves. A subpath is walked as a list of primitive
/// segments (line / quad / cubic) between consecutive anchors —
/// `ArrowTrim`'s segment kernel, reused verbatim so the arc→parameter
/// mapping and the de-Casteljau split are the same ones the arrowhead
/// trim is pinned on. A dash that straddles a cubic is emitted as a
/// cubic (DASH_ALIGN.md §subpath_between), not as a chord and not as a
/// polyline.
///
/// Output: an array of sub-paths. Each sub-path is one solid dash;
/// the caller draws each via the existing solid-stroke pipeline.

import Foundation

private let EPS = 1e-9

public enum DashRenderer {

    private typealias Seg = ArrowTrim.Seg

    /// Expand a dashed stroke into a list of solid sub-paths.
    public static func expandDashedStroke(
        path: [PathCommand],
        dashArray: [Double],
        alignAnchors: Bool
    ) -> [[PathCommand]] {
        guard !path.isEmpty else { return [] }
        // S-4: a LEADING closePath establishes no anchor and draws nothing,
        // so it must not reach either branch below. The dashed branch
        // already ignores it — `splitAtMoveTo` gives it its own subpath and
        // `buildSegments` finds no segment there — but the undashed fast
        // path did not, and the two branches have to answer alike. Measured,
        // in BOTH ports identically (so no port-vs-port comparison could see
        // it): a bare `Z M 5 5` came back as ONE sub-path where `M 5 5` came
        // back as none, because the drawability test asked only "is some
        // command not a moveTo" and a closePath is not a moveTo. Same shape
        // as the leading-close bail-outs already repaired in `artFlatten`
        // and `calligraphicOutline`.
        let lead = path.prefix { if case .closePath = $0 { return true }; return false }.count
        let path = Array(path.dropFirst(lead))
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
            // No drawable segment (a bare moveTo, or the S-4 bare
            // closePath that establishes no anchor) -> no dash.
            let segs = ArrowTrim.buildSegments(sp)
            guard !segs.isEmpty else { continue }
            if alignAnchors {
                result.append(contentsOf:
                    expandAlign(segs, closed: isClosed(sp), pattern: pattern))
            } else {
                result.append(contentsOf: expandPreserve(segs, pattern: pattern))
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

    private static func isClosed(_ subpath: [PathCommand]) -> Bool {
        for cmd in subpath {
            if case .closePath = cmd { return true }
        }
        return false
    }

    /// Per-segment arc lengths plus their running total (`cum[0] = 0`,
    /// `cum[i + 1] = cum[i] + len(seg i)`). A line measures exactly; a
    /// curve measures as its `elementFlattenSteps` polyline, the house
    /// parameterization.
    private static func segLengthsAndCum(_ segs: [Seg]) -> ([Double], [Double]) {
        let lengths = segs.map { ArrowTrim.arcLen($0) }
        var cum: [Double] = [0.0]
        var s = 0.0
        for l in lengths { s += l; cum.append(s) }
        return (lengths, cum)
    }

    // MARK: - Preserve mode

    private static func expandPreserve(
        _ segs: [Seg],
        pattern: [Double]
    ) -> [[PathCommand]] {
        let (_, cum) = segLengthsAndCum(segs)
        let total = cum.last ?? 0.0
        guard total > 0 else { return [] }
        return emitDashes(segs, cum: cum, pattern: pattern,
                          periodOffset: 0.0, tStart: 0.0, tEnd: total)
    }

    // MARK: - Align mode

    private enum BoundaryKind { case ii, ee, ei, ie }

    private static func expandAlign(
        _ segs: [Seg],
        closed: Bool,
        pattern: [Double]
    ) -> [[PathCommand]] {
        let nSegs = segs.count
        guard nSegs >= 1 else { return [] }
        let basePeriod = pattern.reduce(0, +)
        guard basePeriod > 0 else { return [] }
        let (segLengths, cum) = segLengthsAndCum(segs)
        if segLengths.allSatisfy({ $0 <= 0 }) { return [] }

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
            if let sub = subpathBetweenWrapping(segs: segs, cum: cum,
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
        segs: [Seg],
        cum: [Double],
        t0: Double, t1: Double,
        closed: Bool
    ) -> [PathCommand]? {
        let total = cum.last ?? 0.0
        if !closed || t1 <= total + EPS {
            return subpathBetween(segs: segs, cum: cum, t0: t0, t1: min(t1, total))
        }
        let head = subpathBetween(segs: segs, cum: cum, t0: t0, t1: total)
        let tail = subpathBetween(segs: segs, cum: cum, t0: 0.0, t1: t1 - total)
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

    /// The stretch of the subpath between arc-lengths `t0` and `t1`, in
    /// the subpath's own primitives: the straddled ends are de-Casteljau
    /// splits of their segment, the segments fully inside are re-emitted
    /// verbatim. A cubic in, a cubic out — the dash follows the drawn
    /// geometry, never its chord.
    private static func subpathBetween(
        segs: [Seg],
        cum: [Double],
        t0: Double, t1: Double
    ) -> [PathCommand]? {
        if t1 <= t0 + EPS { return nil }
        let (i, local0) = ArrowTrim.locate(cum, t0)
        let (j, local1) = ArrowTrim.locate(cum, t1)
        let a0 = ArrowTrim.paramAtArc(segs[i], local0)
        let a1 = ArrowTrim.paramAtArc(segs[j], local1)
        let start = ArrowTrim.pointAt(segs[i], a0)
        var cmds: [PathCommand] = [.moveTo(start.0, start.1)]
        if i == j {
            cmds.append(ArrowTrim.subCommand(segs[i], a0, a1))
        } else {
            cmds.append(ArrowTrim.subCommand(segs[i], a0, 1.0))
            if i + 1 < j {
                for k in (i + 1)..<j { cmds.append(ArrowTrim.fullCommand(segs[k])) }
            }
            cmds.append(ArrowTrim.subCommand(segs[j], 0.0, a1))
        }
        // `t1` landing exactly on an anchor makes the final command a
        // zero-length repeat of the point we just drew to; drop it, as
        // the lines-only engine dropped its redundant trailing lineTo.
        if cmds.count >= 2 {
            let last = cmdEndpoint(cmds[cmds.count - 1])
            let prev = cmdEndpoint(cmds[cmds.count - 2])
            if abs(last.0 - prev.0) <= 1e-9 && abs(last.1 - prev.1) <= 1e-9 {
                cmds.removeLast()
            }
        }
        return cmds
    }

    private static func cmdEndpoint(_ cmd: PathCommand) -> (Double, Double) {
        switch cmd {
        case .moveTo(let x, let y), .lineTo(let x, let y),
             .smoothQuadTo(let x, let y):
            return (x, y)
        case .curveTo(_, _, _, _, let x, let y),
             .smoothCurveTo(_, _, let x, let y):
            return (x, y)
        case .quadTo(_, _, let x, let y):
            return (x, y)
        case .arcTo(_, _, _, _, _, let x, let y):
            return (x, y)
        case .closePath:
            return (Double.nan, Double.nan)
        }
    }

    private static func emitDashes(
        _ segs: [Seg],
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
                if let sub = subpathBetween(segs: segs, cum: cum, t0: t, t1: nextT) {
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
