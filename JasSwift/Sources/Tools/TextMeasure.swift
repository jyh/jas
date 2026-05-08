import AppKit
import Foundation

// MARK: - Text width measurement
//
// Returns a closure that measures the rendered width of a string in
// points for a given font. In-process tests run without a real font
// (or want deterministic behavior) and use the stub measurer; the live
// app uses NSFont + NSAttributedString sizing.

public func makeMeasurer(family: String, weight: String, style: String, size: Double) -> (String) -> Double {
    let font = resolveFont(family: family, bold: weight == "bold",
                           italic: style == "italic" || style == "oblique",
                           size: size)
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    return { s in
        if s.isEmpty { return 0.0 }
        let str = NSAttributedString(string: s, attributes: attrs)
        return Double(str.size().width)
    }
}

/// Resolve a font family name to an NSFont, applying bold / italic
/// symbolic traits. CSS generic family names (sans-serif, serif,
/// monospace) don't correspond to installed faces on macOS, so
/// `NSFontDescriptor(name:)` returns nil for them and the naive bold
/// path silently produces a regular-weight system font. We fall back
/// to the system font's descriptor and apply traits there, which
/// resolves to actual bold / italic SF variants.
public func resolveFont(family: String, bold: Bool, italic: Bool,
                        size: Double) -> NSFont {
    var traits: NSFontDescriptor.SymbolicTraits = []
    if bold { traits.insert(.bold) }
    if italic { traits.insert(.italic) }
    if let baseFont = NSFont(name: family, size: CGFloat(size)) {
        if traits.isEmpty { return baseFont }
        let desc = baseFont.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: desc, size: CGFloat(size)) ?? baseFont
    }
    let sys = NSFont.systemFont(ofSize: CGFloat(size))
    if traits.isEmpty { return sys }
    let desc = sys.fontDescriptor.withSymbolicTraits(traits)
    return NSFont(descriptor: desc, size: CGFloat(size)) ?? sys
}

/// Deterministic stub measurer used by host-side tests.
public func stubMeasurer(_ size: Double) -> (String) -> Double {
    { s in Double(s.count) * size * 0.55 }
}

/// Compute one width per visible character, walking the element's
/// tspans and falling back to element-level defaults for any
/// override slot that's `nil`. Output length matches
/// `applyTextTransform(elementTextTransform, elementFontVariant,
/// elementContent).count` when each tspan has the same effective
/// transform as the element; mismatched per-tspan transforms can
/// still produce the right count for ASCII (uppercased() preserves
/// length there), and the layout falls back to its own measure when
/// the array is the wrong size.
public func textPerCharWidths(_ tspans: [Tspan], element: Text) -> [Double] {
    var out: [Double] = []
    for t in tspans {
        let effFamily = t.fontFamily ?? element.fontFamily
        let effSize = t.fontSize ?? element.fontSize
        let effBold = t.fontWeight.map { $0 == "bold" }
            ?? (element.fontWeight == "bold")
        let effItalic = t.fontStyle.map { $0 == "italic" || $0 == "oblique" }
            ?? (element.fontStyle == "italic" || element.fontStyle == "oblique")
        let effTT = t.textTransform ?? element.textTransform
        let effFV = t.fontVariant ?? element.fontVariant
        let weight = effBold ? "bold" : "normal"
        let style = effItalic ? "italic" : "normal"
        let measure = makeMeasurer(family: effFamily, weight: weight,
                                    style: style, size: effSize)
        let display = applyTextTransform(effTT, effFV, t.content)
        for ch in display {
            out.append(measure(String(ch)))
        }
    }
    return out
}

/// Same as `textPerCharWidths` but for `TextPath` elements.
public func textPerCharWidths(_ tspans: [Tspan], element: TextPath) -> [Double] {
    var out: [Double] = []
    for t in tspans {
        let effFamily = t.fontFamily ?? element.fontFamily
        let effSize = t.fontSize ?? element.fontSize
        let effBold = t.fontWeight.map { $0 == "bold" }
            ?? (element.fontWeight == "bold")
        let effItalic = t.fontStyle.map { $0 == "italic" || $0 == "oblique" }
            ?? (element.fontStyle == "italic" || element.fontStyle == "oblique")
        let effTT = t.textTransform ?? element.textTransform
        let effFV = t.fontVariant ?? element.fontVariant
        let weight = effBold ? "bold" : "normal"
        let style = effItalic ? "italic" : "normal"
        let measure = makeMeasurer(family: effFamily, weight: weight,
                                    style: style, size: effSize)
        let display = applyTextTransform(effTT, effFV, t.content)
        for ch in display {
            out.append(measure(String(ch)))
        }
    }
    return out
}

/// Apply text-transform / font-variant: uppercase or lowercase
/// `content`. Small-caps renders as uppercase (placeholder shared
/// with Rust / OCaml). Public so the per-char width path can mirror
/// what the canvas renders.
public func applyTextTransform(_ tt: String, _ fv: String, _ content: String) -> String {
    if tt == "uppercase" || fv == "small-caps" { return content.uppercased() }
    if tt == "lowercase" { return content.lowercased() }
    return content
}
