/// True arc-length trim for arrowheaded strokes.
///
/// Port of `jas_dioxus/src/algorithms/arrow_trim.rs`. Keep in lockstep:
/// `trimPath` walks in from each armed end by the setback distance along arc
/// length, de-Casteljau-splits the segment that straddles the cut, drops the
/// tail, and butts the cut. The head stays oriented off the ORIGINAL path (see
/// Arrowheads orientation contract), so the stroke ends at the head base with
/// nothing protruding.
///
/// Arc length reuses the house parameterization: each curve is sampled at
/// `elementFlattenSteps` uniform-in-t points and measured as the resulting
/// polyline, identical to `flattenPathCommands`. Lines are measured exactly.
/// This keeps the arc→parameter mapping byte-reproducible against the Rust port,
/// which the cross-language corpus (`test_fixtures/algorithms/arrow_trim.json`)
/// pins to 4 decimals.
///
/// An empty result means the setbacks meet-or-exceed the total length: draw
/// arrowheads only (oriented off the original path), no stroke.

import Foundation

public enum ArrowTrim {
    private typealias Pt = (Double, Double)
    private static let eps = 1e-9

    private enum Seg {
        case line(Pt, Pt)
        case quad(Pt, Pt, Pt)
        case cubic(Pt, Pt, Pt, Pt)
    }

    private static func lerp(_ a: Pt, _ b: Pt, _ t: Double) -> Pt {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
    }

    private static func dist(_ a: Pt, _ b: Pt) -> Double {
        let dx = b.0 - a.0, dy = b.1 - a.1
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func segP0(_ s: Seg) -> Pt {
        switch s {
        case .line(let p0, _): return p0
        case .quad(let p0, _, _): return p0
        case .cubic(let p0, _, _, _): return p0
        }
    }

    private static func segP1(_ s: Seg) -> Pt {
        switch s {
        case .line(_, let p1): return p1
        case .quad(_, _, let p2): return p2
        case .cubic(_, _, _, let p3): return p3
        }
    }

    private static func pointAt(_ s: Seg, _ t: Double) -> Pt {
        switch s {
        case .line(let p0, let p1):
            return lerp(p0, p1, t)
        case .quad(let p0, let p1, let p2):
            let a = lerp(p0, p1, t), b = lerp(p1, p2, t)
            return lerp(a, b, t)
        case .cubic(let p0, let p1, let p2, let p3):
            let a = lerp(p0, p1, t), b = lerp(p1, p2, t), c = lerp(p2, p3, t)
            let d = lerp(a, b, t), e = lerp(b, c, t)
            return lerp(d, e, t)
        }
    }

    private static func flatten(_ s: Seg) -> [Pt] {
        switch s {
        case .line(let p0, let p1):
            return [p0, p1]
        default:
            let n = elementFlattenSteps
            var pts: [Pt] = []
            pts.reserveCapacity(n + 1)
            for i in 0...n { pts.append(pointAt(s, Double(i) / Double(n))) }
            return pts
        }
    }

    private static func arcLen(_ s: Seg) -> Double {
        let pts = flatten(s)
        var total = 0.0
        for i in 1..<pts.count { total += dist(pts[i - 1], pts[i]) }
        return total
    }

    private static func paramAtArc(_ s: Seg, _ target: Double) -> Double {
        if target <= 0.0 { return 0.0 }
        switch s {
        case .line(let p0, let p1):
            let l = dist(p0, p1)
            return l <= eps ? 0.0 : min(max(target / l, 0.0), 1.0)
        default:
            let n = elementFlattenSteps
            let pts = flatten(s)
            var cum = 0.0
            for i in 1...n {
                let segL = dist(pts[i - 1], pts[i])
                if cum + segL >= target - eps {
                    let frac = segL <= eps ? 0.0 : (target - cum) / segL
                    return (Double(i - 1) + min(max(frac, 0.0), 1.0)) / Double(n)
                }
                cum += segL
            }
            return 1.0
        }
    }

    // de Casteljau split of a cubic at t: (left ctrl pts, right ctrl pts).
    private static func cubicSplit(_ p0: Pt, _ p1: Pt, _ p2: Pt, _ p3: Pt, _ t: Double)
        -> ((Pt, Pt, Pt, Pt), (Pt, Pt, Pt, Pt)) {
        let a = lerp(p0, p1, t), b = lerp(p1, p2, t), c = lerp(p2, p3, t)
        let d = lerp(a, b, t), e = lerp(b, c, t)
        let m = lerp(d, e, t)
        return ((p0, a, d, m), (m, e, c, p3))
    }

    private static func cubicBetween(_ p0: Pt, _ p1: Pt, _ p2: Pt, _ p3: Pt,
                                     _ t0: Double, _ t1: Double) -> (Pt, Pt, Pt, Pt) {
        let (_, right) = cubicSplit(p0, p1, p2, p3, t0)
        let denom = 1.0 - t0
        let tt = abs(denom) <= eps ? 0.0 : min(max((t1 - t0) / denom, 0.0), 1.0)
        let (left, _) = cubicSplit(right.0, right.1, right.2, right.3, tt)
        return left
    }

    private static func quadSplit(_ p0: Pt, _ p1: Pt, _ p2: Pt, _ t: Double)
        -> ((Pt, Pt, Pt), (Pt, Pt, Pt)) {
        let a = lerp(p0, p1, t), b = lerp(p1, p2, t)
        let m = lerp(a, b, t)
        return ((p0, a, m), (m, b, p2))
    }

    private static func quadBetween(_ p0: Pt, _ p1: Pt, _ p2: Pt,
                                    _ t0: Double, _ t1: Double) -> (Pt, Pt, Pt) {
        let (_, right) = quadSplit(p0, p1, p2, t0)
        let denom = 1.0 - t0
        let tt = abs(denom) <= eps ? 0.0 : min(max((t1 - t0) / denom, 0.0), 1.0)
        let (left, _) = quadSplit(right.0, right.1, right.2, tt)
        return left
    }

    // Sub-segment [t0, t1] as a PathCommand drawing FROM pointAt(t0) TO pointAt(t1).
    private static func subCommand(_ s: Seg, _ t0: Double, _ t1: Double) -> PathCommand {
        switch s {
        case .line:
            let e = pointAt(s, t1)
            return .lineTo(e.0, e.1)
        case .cubic(let p0, let p1, let p2, let p3):
            let (_, q1, q2, q3) = cubicBetween(p0, p1, p2, p3, t0, t1)
            return .curveTo(x1: q1.0, y1: q1.1, x2: q2.0, y2: q2.1, x: q3.0, y: q3.1)
        case .quad(let p0, let p1, let p2):
            let (_, q1, q2) = quadBetween(p0, p1, p2, t0, t1)
            return .quadTo(x1: q1.0, y1: q1.1, x: q2.0, y: q2.1)
        }
    }

    private static func fullCommand(_ s: Seg) -> PathCommand {
        switch s {
        case .line(_, let p1): return .lineTo(p1.0, p1.1)
        case .cubic(_, let p1, let p2, let p3):
            return .curveTo(x1: p1.0, y1: p1.1, x2: p2.0, y2: p2.1, x: p3.0, y: p3.1)
        case .quad(_, let p1, let p2):
            return .quadTo(x1: p1.0, y1: p1.1, x: p2.0, y: p2.1)
        }
    }

    private static func buildSegments(_ cmds: [PathCommand]) -> [Seg] {
        var segs: [Seg] = []
        var cur: Pt = (0.0, 0.0)
        var subStart: Pt = (0.0, 0.0)
        for cmd in cmds {
            switch cmd {
            case .moveTo(let x, let y):
                cur = (x, y); subStart = (x, y)
            case .lineTo(let x, let y):
                segs.append(.line(cur, (x, y))); cur = (x, y)
            case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
                segs.append(.cubic(cur, (x1, y1), (x2, y2), (x, y))); cur = (x, y)
            case .quadTo(let x1, let y1, let x, let y):
                segs.append(.quad(cur, (x1, y1), (x, y))); cur = (x, y)
            case .smoothCurveTo(_, _, let x, let y),
                 .arcTo(_, _, _, _, _, let x, let y):
                segs.append(.line(cur, (x, y))); cur = (x, y)
            case .smoothQuadTo(let x, let y):
                segs.append(.line(cur, (x, y))); cur = (x, y)
            case .closePath:
                if dist(cur, subStart) > eps { segs.append(.line(cur, subStart)) }
                cur = subStart
            }
        }
        return segs
    }

    // Locate the segment straddling global arc distance `a`; returns (index, local).
    private static func locate(_ cum: [Double], _ a: Double) -> (Int, Double) {
        let n = cum.count - 1
        if a <= cum[0] { return (0, 0.0) }
        if a >= cum[n] { return (n - 1, cum[n] - cum[n - 1]) }
        for i in 0..<n where a < cum[i + 1] { return (i, a - cum[i]) }
        return (n - 1, cum[n] - cum[n - 1])
    }

    /// Arc-length-trim `cmds` inward by `startSetback` from the path start and
    /// `endSetback` from the path end. An empty result means nothing remains
    /// (heads-only, no stroke).
    public static func trimPath(_ cmds: [PathCommand],
                                startSetback: Double,
                                endSetback: Double) -> [PathCommand] {
        if cmds.isEmpty { return [] }
        let startSetback = max(startSetback, 0.0)
        let endSetback = max(endSetback, 0.0)
        if startSetback <= eps && endSetback <= eps { return cmds }

        let segs = buildSegments(cmds)
        if segs.isEmpty { return cmds }

        var cum: [Double] = [0.0]
        var s = 0.0
        for seg in segs { s += arcLen(seg); cum.append(s) }
        let total = s
        if total <= eps { return cmds }

        let aStart = min(startSetback, total)
        let aEnd = total - endSetback
        if aEnd <= aStart + eps { return [] }  // overlapping / consumed -> heads-only

        let (i0, local0) = locate(cum, aStart)
        let (i1, local1) = locate(cum, aEnd)
        let t0 = paramAtArc(segs[i0], local0)
        let t1 = paramAtArc(segs[i1], local1)

        var out: [PathCommand] = []
        let startPt = pointAt(segs[i0], t0)
        out.append(.moveTo(startPt.0, startPt.1))
        var lastPt = startPt

        if i0 == i1 {
            out.append(subCommand(segs[i0], t0, t1))
        } else {
            out.append(subCommand(segs[i0], t0, 1.0))
            lastPt = segP1(segs[i0])
            if i0 + 1 < i1 {
                for k in (i0 + 1)..<i1 {
                    if dist(segP0(segs[k]), lastPt) > eps {
                        let p0 = segP0(segs[k])
                        out.append(.moveTo(p0.0, p0.1))
                    }
                    out.append(fullCommand(segs[k]))
                    lastPt = segP1(segs[k])
                }
            }
            if dist(segP0(segs[i1]), lastPt) > eps {
                let p0 = segP0(segs[i1])
                out.append(.moveTo(p0.0, p0.1))
            }
            out.append(subCommand(segs[i1], 0.0, t1))
        }
        return out
    }
}
