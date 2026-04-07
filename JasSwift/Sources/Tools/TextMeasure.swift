import AppKit
import Foundation

// MARK: - Text width measurement
//
// Returns a closure that measures the rendered width of a string in
// points for a given font. In-process tests run without a real font
// (or want deterministic behavior) and use the stub measurer; the live
// app uses NSFont + NSAttributedString sizing.

public func makeMeasurer(family: String, weight: String, style: String, size: Double) -> (String) -> Double {
    var traits: NSFontDescriptor.SymbolicTraits = []
    if weight == "bold" { traits.insert(.bold) }
    if style == "italic" { traits.insert(.italic) }
    let baseFont = NSFont(name: family, size: CGFloat(size)) ?? NSFont.systemFont(ofSize: CGFloat(size))
    let font: NSFont
    if !traits.isEmpty {
        let desc = baseFont.fontDescriptor.withSymbolicTraits(traits)
        font = NSFont(descriptor: desc, size: CGFloat(size)) ?? baseFont
    } else {
        font = baseFont
    }
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    return { s in
        if s.isEmpty { return 0.0 }
        let str = NSAttributedString(string: s, attributes: attrs)
        return Double(str.size().width)
    }
}

/// Deterministic stub measurer used by host-side tests.
public func stubMeasurer(_ size: Double) -> (String) -> Double {
    { s in Double(s.count) * size * 0.55 }
}
