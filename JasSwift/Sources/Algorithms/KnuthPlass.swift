/// Knuth-Plass every-line line-breaking composer.
///
/// Pure-Swift implementation of the dynamic-programming line breaker
/// from Knuth-Plass "Breaking Paragraphs into Lines" (1981). Mirrors
/// `jas_dioxus/src/algorithms/knuth_plass.rs`.
///
/// Phase 10: V1 supports word-spacing stretch/shrink derived from
/// the Justification dialog's min/desired/max plus hyphen penalties
/// from the bias slider. Letter-spacing and glyph-scaling fallbacks
/// are reserved for follow-up tuning when the parity harness lands.

import Foundation

/// One item in the paragraph stream. Knuth-Plass models text as
/// alternating boxes (immutable glyph clusters), glue (stretchable /
/// shrinkable inter-word space), and penalties (potential break
/// points with an associated cost).
public enum KPItem: Equatable {
    /// A printable cluster of glyphs (typically a word). Cannot be
    /// broken.
    case box(width: Double, charIdx: Int)
    /// Stretchable / shrinkable space between two boxes. A legal
    /// break point when followed by a Box. The line that breaks at
    /// this glue ends just before it; the glue is dropped from the
    /// next line.
    case glue(width: Double, stretch: Double, shrink: Double, charIdx: Int)
    /// Discretionary break point. The line breaks here only if the
    /// composer chooses to; when it does, the line gains `width`.
    case penalty(width: Double, value: Double, flagged: Bool, charIdx: Int)

    public var width: Double {
        switch self {
        case .box(let w, _): return w
        case .glue(let w, _, _, _): return w
        case .penalty: return 0  // contributes only on break
        }
    }
    public var charIdx: Int {
        switch self {
        case .box(_, let c), .glue(_, _, _, let c), .penalty(_, _, _, let c):
            return c
        }
    }
    var isGlue: Bool { if case .glue = self { return true } else { return false } }
    var isBox: Bool { if case .box = self { return true } else { return false } }
}

/// Composer tuning. Defaults match Knuth's original paper.
public struct KPOpts {
    public var linePenalty: Double = 10
    public var flaggedDemerit: Double = 3000
    public var maxRatio: Double = 10

    public init(linePenalty: Double = 10, flaggedDemerit: Double = 3000,
                maxRatio: Double = 10) {
        self.linePenalty = linePenalty
        self.flaggedDemerit = flaggedDemerit
        self.maxRatio = maxRatio
    }
}

/// Penalty value above which a candidate is treated as forbidden.
public let kpPenaltyInfinity: Double = 10000

/// One line's break decision. Returned by `kpCompose` in source
/// order.
public struct KPBreak: Equatable {
    /// Index of the item that *ends* the line. The line spans
    /// `prev.itemIdx + 1 ... itemIdx` (or `0 ... itemIdx` for the
    /// first line).
    public var itemIdx: Int
    /// Adjustment ratio. Glue widths render as
    /// `width + ratio * stretch` (or `+ ratio * shrink` when ratio
    /// is negative).
    public var ratio: Double
    /// True when the line ends at a flagged penalty (typically a
    /// hyphen).
    public var flagged: Bool
}

/// Run the Knuth-Plass DP composer. `lineWidths` reuses its last
/// element when the paragraph wants more lines. Returns nil when no
/// feasible composition exists (caller falls back to greedy fit).
///
/// The returned breaks always end at the final item, which the
/// caller must terminate with a forced penalty
/// (`.penalty(value: -kpPenaltyInfinity)`).
public func kpCompose(items: [KPItem], lineWidths: [Double],
                      opts: KPOpts = KPOpts()) -> [KPBreak]? {
    if items.isEmpty || lineWidths.isEmpty { return [] }
    let n = items.count
    // Prefix sums of width / stretch / shrink for O(1) line eval.
    var sumW = [Double](repeating: 0, count: n + 1)
    var sumY = [Double](repeating: 0, count: n + 1)
    var sumZ = [Double](repeating: 0, count: n + 1)
    for (i, it) in items.enumerated() {
        sumW[i + 1] = sumW[i] + it.width
        if case .glue(_, let s, let z, _) = it {
            sumY[i + 1] = sumY[i] + s
            sumZ[i + 1] = sumZ[i] + z
        } else {
            sumY[i + 1] = sumY[i]
            sumZ[i + 1] = sumZ[i]
        }
    }

    struct Node {
        var itemIdx: Int
        var line: Int
        var totalDemerits: Double
        var ratio: Double
        var flagged: Bool
        var prev: Int?
    }

    var nodes: [Node] = [Node(itemIdx: 0, line: 0, totalDemerits: 0,
                              ratio: 0, flagged: false, prev: nil)]

    func natWidth(_ from: Int, _ to: Int) -> (Double, Double, Double) {
        var w = sumW[to + 1] - sumW[from]
        var y = sumY[to + 1] - sumY[from]
        var z = sumZ[to + 1] - sumZ[from]
        switch items[to] {
        case .glue(let gw, let gs, let gz, _):
            w -= gw; y -= gs; z -= gz
        case .penalty(let pw, _, _, _):
            w += pw
        case .box: break
        }
        return (w, y, z)
    }

    func lineWidthFor(_ line: Int) -> Double {
        line < lineWidths.count ? lineWidths[line] : lineWidths.last!
    }

    for j in 0..<n {
        let legal: Bool
        switch items[j] {
        case .glue: legal = j > 0 && items[j - 1].isBox
        case .penalty(_, let v, _, _): legal = v < kpPenaltyInfinity
        case .box: legal = false
        }
        if !legal { continue }

        var best: (Int, Double, Double)? = nil
        for ni in 0..<nodes.count {
            let nNode = nodes[ni]
            let from = (nNode.prev == nil && ni == 0) ? 0 : nNode.itemIdx + 1
            if from > j { continue }
            let (nat, stretch, shrink) = natWidth(from, j)
            let lineW = lineWidthFor(nNode.line)
            let ratio: Double
            if abs(nat - lineW) < 1e-9 {
                ratio = 0
            } else if nat < lineW {
                ratio = stretch > 0 ? (lineW - nat) / stretch : .infinity
            } else {
                ratio = shrink > 0 ? (lineW - nat) / shrink : -.infinity
            }
            if ratio < -1 || ratio > opts.maxRatio { continue }
            let badness = 100 * pow(abs(ratio), 3)
            let (penValue, penFlagged): (Double, Bool)
            if case .penalty(_, let v, let f, _) = items[j] {
                penValue = v; penFlagged = f
            } else {
                penValue = 0; penFlagged = false
            }
            let lineDemerit: Double
            if penValue >= 0 {
                lineDemerit = pow(opts.linePenalty + badness + penValue, 2)
            } else if penValue > -kpPenaltyInfinity {
                lineDemerit = pow(opts.linePenalty + badness, 2) - pow(penValue, 2)
            } else {
                lineDemerit = pow(opts.linePenalty + badness, 2)
            }
            var demerits = nNode.totalDemerits + lineDemerit
            if nNode.flagged && penFlagged {
                demerits += opts.flaggedDemerit
            }
            if best == nil || demerits < best!.1 {
                best = (ni, demerits, ratio)
            }
        }
        if let (prev, d, r) = best {
            let isFlag: Bool
            if case .penalty(_, _, let f, _) = items[j] { isFlag = f }
            else { isFlag = false }
            nodes.append(Node(itemIdx: j, line: nodes[prev].line + 1,
                              totalDemerits: d, ratio: r, flagged: isFlag,
                              prev: prev))
        }
    }

    // Find lowest-demerit node ending at item n-1.
    var best: Int? = nil
    var bestD = Double.infinity
    for (ni, node) in nodes.enumerated() {
        if node.itemIdx == n - 1 && node.totalDemerits < bestD {
            bestD = node.totalDemerits
            best = ni
        }
    }
    guard var cur = best else { return nil }
    var out: [KPBreak] = []
    while true {
        let n = nodes[cur]
        if n.prev == nil && cur == 0 { break }
        out.append(KPBreak(itemIdx: n.itemIdx, ratio: n.ratio, flagged: n.flagged))
        if let p = n.prev { cur = p } else { break }
    }
    out.reverse()
    return out
}
