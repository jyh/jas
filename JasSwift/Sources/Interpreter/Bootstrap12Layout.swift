/// Bootstrap-style 12-column row layout. See `transcripts/LAYOUT.md`.
///
/// Each subview carries a weight (the YAML's `col: N`, 1..12). The
/// row's content width minus inter-child `gap` is divided into 12
/// equal tracks; a child with weight `N` claims `N` tracks. A child
/// with weight 0 takes its intrinsic width (used by spacers and raw
/// widgets that opt out of the grid). Children stack horizontally
/// with `gap` between them; the row's height is the tallest child
/// (intrinsic), so it doesn't collapse rows that contain a
/// 60-pt fill/stroke widget or a 64-pt color gradient.

import SwiftUI

@available(macOS 13.0, *)
struct Bootstrap12Layout: Layout {
    var weights: [Int]
    var gap: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let totalWidth = proposal.width ?? defaultWidth(subviews)
        let widths = computeWidths(totalWidth: totalWidth, subviews: subviews)
        var maxHeight: CGFloat = 0
        for (i, subview) in subviews.enumerated() {
            let h = subview.sizeThatFits(
                ProposedViewSize(width: widths[i], height: nil)
            ).height
            maxHeight = max(maxHeight, h)
        }
        return CGSize(width: totalWidth, height: maxHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) {
        let widths = computeWidths(totalWidth: bounds.width, subviews: subviews)
        var x = bounds.minX
        for (i, subview) in subviews.enumerated() {
            let w = widths[i]
            let h = subview.sizeThatFits(
                ProposedViewSize(width: w, height: nil)
            ).height
            // Cross-axis centering matches the YAML row default
            // (`alignment: center`) — see LAYOUT.md §Edge cases.
            let y = bounds.minY + max(0, (bounds.height - h) / 2)
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: w, height: h)
            )
            x += w + gap
        }
    }

    /// Default total width when the parent gives an unspecified
    /// proposal: sum of intrinsic widths plus inter-child gaps.
    private func defaultWidth(_ subviews: Subviews) -> CGFloat {
        let intrinsic = subviews.map {
            $0.sizeThatFits(.unspecified).width
        }.reduce(0, +)
        return intrinsic + gap * CGFloat(max(0, subviews.count - 1))
    }

    /// Compute per-child widths from the available row width.
    /// Weight 0 children take their intrinsic width; weighted
    /// children share the remaining width proportional to N/12.
    private func computeWidths(
        totalWidth: CGFloat, subviews: Subviews
    ) -> [CGFloat] {
        let totalGap = gap * CGFloat(max(0, subviews.count - 1))
        var sumWeight = 0
        var intrinsicSum: CGFloat = 0
        var intrinsics: [CGFloat] = []
        for (i, subview) in subviews.enumerated() {
            if i < weights.count && weights[i] > 0 {
                sumWeight += weights[i]
                intrinsics.append(0)
            } else {
                let w = subview.sizeThatFits(.unspecified).width
                intrinsicSum += w
                intrinsics.append(w)
            }
        }
        let usable = max(0, totalWidth - totalGap - intrinsicSum)
        // Bootstrap convention: divide by 12, not by sumWeight. A
        // row with two col:3 children leaves the remaining 6 tracks
        // empty rather than stretching the children to fill.
        return weights.indices.prefix(subviews.count).map { i in
            if i < weights.count && weights[i] > 0 {
                return usable * CGFloat(weights[i]) / 12.0
            } else {
                return intrinsics[i]
            }
        }
    }
}
