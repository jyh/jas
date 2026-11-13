import Foundation
import Testing
@testable import JasLib

/// THE LAYERS THUMBNAIL'S VIEWBOX IS IN THE SAME UNITS AS ITS CONTENT.
///
/// `elementSvg` writes every coordinate in px (pt × 96/72, `Svg.swift`), so a
/// viewBox built from the element's bounds in pt is a third too small: the
/// content overruns it right and down and the thumbnail shows its upper-left
/// corner. jas_dioxus's `tree_preview_svg` scales its viewBox for exactly this
/// reason. Both sides of each assertion are read from the emitted SVG.
@Suite struct LayersThumbnailBoxTests {

    private func numbers(_ s: String, _ pattern: String) -> [Double] {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return [] }
        return (1..<m.numberOfRanges).compactMap {
            Range(m.range(at: $0), in: s).flatMap { Double(s[$0]) }
        }
    }

    @Test func aRectSitsInsideItsThumbnailsViewBox() {
        let svg = buildPreviewSvg(.rect(Rect(x: 10, y: 10, width: 30, height: 30)))
        let vb = numbers(svg, #"viewBox="([-0-9.e]+) ([-0-9.e]+) ([-0-9.e]+) ([-0-9.e]+)""#)
        let x = numbers(svg, #"<rect[^>]* x="([-0-9.e]+)""#)
        let y = numbers(svg, #"<rect[^>]* y="([-0-9.e]+)""#)
        let w = numbers(svg, #"<rect[^>]* width="([-0-9.e]+)""#)
        let h = numbers(svg, #"<rect[^>]* height="([-0-9.e]+)""#)
        #expect(vb.count == 4 && x.count == 1 && y.count == 1 && w.count == 1 && h.count == 1,
                "the fixture must parse: \(svg)")
        guard vb.count == 4, let x0 = x.first, let y0 = y.first, let w0 = w.first, let h0 = h.first else { return }
        #expect(x0 >= vb[0] && y0 >= vb[1], "content starts inside the box: \(svg)")
        #expect(x0 + w0 <= vb[0] + vb[2] + 1e-9 && y0 + h0 <= vb[1] + vb[3] + 1e-9,
                "content ends inside the box: \(svg)")
    }
}
