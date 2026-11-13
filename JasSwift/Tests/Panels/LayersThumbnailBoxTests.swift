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

    /// The namespace prefixes a document USES (`p:attr=`) and DECLARES
    /// (`xmlns:p=`), read from its bytes. Measured 11-12: XMLParser accepts an
    /// undeclared prefix (it cannot be this check's instrument), and
    /// `NSImage(data:)` still draws one but libxml2 logs a "namespace error"
    /// to the console per thumbnail built, which is what the inkscape: fix was for.
    private func prefixes(_ s: String) -> (used: Set<String>, declared: Set<String>) {
        func all(_ pattern: String) -> Set<String> {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
            return Set(re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
                Range($0.range(at: 1), in: s).map { String(s[$0]) }
            })
        }
        return (all(#"\s([A-Za-z][A-Za-z0-9]*):[A-Za-z-]+="#).subtracting(["xmlns", "xml"]),
                all(#"xmlns:([A-Za-z][A-Za-z0-9]*)="#))
    }

    @Test func everyPrefixAThumbnailUsesIsDeclared() {
        // Positive control: the named rect the inkscape: lesson already covers.
        let named = buildPreviewSvg(.rect(Rect(x: 0, y: 0, width: 10, height: 10, name: "hull")))
        let n = prefixes(named)
        #expect(n.used.contains("inkscape"), "the control must exercise its prefix: \(named)")
        #expect(n.used.isSubset(of: n.declared), "control: \(named)")
        // The class: a gradient fill writes jas:fill-gradient.
        let g = Gradient(type: .linear, angle: 0, stops: [
            GradientStop(color: "#ff0000", location: 0),
            GradientStop(color: "#0000ff", location: 100),
        ])
        let graded = buildPreviewSvg(.rect(Rect(x: 0, y: 0, width: 10, height: 10, fillGradient: g)))
        let p = prefixes(graded)
        #expect(p.used.contains("jas"), "the case must exercise the jas: prefix: \(graded)")
        #expect(p.used.isSubset(of: p.declared),
                "undeclared: \(p.used.subtracting(p.declared).sorted()) in \(graded)")
    }

    /// A gradient-filled element's thumbnail defines its gradient (flask
    /// STATUS-flask §911, measured on Windows): outside a document export the
    /// serializer writes `fill="none"` plus a `jas:fill-gradient` attribute and
    /// no `<linearGradient>`, so the thumbnail drew blank. Every `url(#id)` the
    /// thumbnail paints with must be defined in the same document.
    @Test func aGradientThumbnailDefinesTheGradientItPaints() {
        let g = Gradient(type: .linear, angle: 0, stops: [
            GradientStop(color: "#ff0000", location: 0),
            GradientStop(color: "#0000ff", location: 100),
        ])
        let svg = buildPreviewSvg(.rect(Rect(x: 0, y: 0, width: 10, height: 10, fillGradient: g)))
        #expect(svg.contains("<linearGradient"), "the gradient is defined: \(svg)")
        guard let re = try? NSRegularExpression(pattern: #"url\(#([^)]+)\)"#) else { return }
        let refs = re.matches(in: svg, range: NSRange(svg.startIndex..., in: svg)).compactMap {
            Range($0.range(at: 1), in: svg).map { String(svg[$0]) }
        }
        #expect(!refs.isEmpty, "the fill points at a gradient: \(svg)")
        for id in refs {
            #expect(svg.contains("id=\"\(id)\""), "url(#\(id)) is defined here: \(svg)")
        }
    }

    /// Two thumbnails with DIFFERENT gradients must not share an id: the web
    /// inlines every row's thumbnail into one page, where ids are global.
    @Test func differentGradientsGetDifferentThumbnailIds() {
        func thumb(_ c: String) -> String {
            let g = Gradient(type: .linear, angle: 0, stops: [
                GradientStop(color: c, location: 0), GradientStop(color: "#ffffff", location: 100)])
            return buildPreviewSvg(.rect(Rect(x: 0, y: 0, width: 10, height: 10, fillGradient: g)))
        }
        func ids(_ s: String) -> Set<String> {
            guard let re = try? NSRegularExpression(pattern: #"<(?:linear|radial)Gradient id="([^"]+)""#) else { return [] }
            return Set(re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
                Range($0.range(at: 1), in: s).map { String(s[$0]) } })
        }
        let a = ids(thumb("#ff0000")), b = ids(thumb("#00ff00"))
        #expect(!a.isEmpty && !b.isEmpty, "both define a gradient")
        #expect(a.isDisjoint(with: b), "\(a) vs \(b)")
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
