import AppKit
import Foundation

// MARK: - Rich clipboard
//
// Cross-element / cross-app rich paste for in-place text editing.
// Mirrors Rust d76b09f: the type tool writes three formats on cut /
// copy and reads them back in preference order on paste. Native
// macOS NSPasteboard handles multi-format natively, so we publish
// all three simultaneously.
//
// Preference order on paste: application/x-jas-tspans > image/svg+xml
// > text/plain.

/// Pasteboard type for the jas JSON clipboard format.
public let jasTspansPasteboardType = NSPasteboard.PasteboardType(
    "application/x-jas-tspans")

/// Pasteboard type for an SVG fragment (the clipboard SVG format).
public let svgXmlPasteboardType = NSPasteboard.PasteboardType(
    "image/svg+xml")

/// Write a tspan selection to the system pasteboard in three formats:
/// text/plain (the flat content), application/x-jas-tspans (the jas
/// JSON payload), and image/svg+xml (an SVG fragment).
///
/// Platform paste targets pick the best format they understand. jas
/// apps prefer the JSON format; other SVG-aware apps prefer the
/// SVG fragment; anything else falls back to plain text.
public func richClipboardWrite(flat: String, tspans: [Tspan],
                                pasteboard: NSPasteboard = .general) {
    pasteboard.clearContents()
    pasteboard.declareTypes(
        [.string, jasTspansPasteboardType, svgXmlPasteboardType],
        owner: nil)
    pasteboard.setString(flat, forType: .string)
    pasteboard.setString(tspansToJsonClipboard(tspans),
                          forType: jasTspansPasteboardType)
    pasteboard.setString(tspansToSvgFragment(tspans),
                          forType: svgXmlPasteboardType)
}

/// Read the best rich-clipboard format from the system pasteboard
/// and return the reconstructed tspan list, or `nil` when none of
/// the rich formats are present / parse successfully. Callers fall
/// back to flat `pasteboard.string(forType: .string)` in that case.
public func richClipboardReadTspans(
    pasteboard: NSPasteboard = .general
) -> [Tspan]? {
    if let json = pasteboard.string(forType: jasTspansPasteboardType),
       let tspans = tspansFromJsonClipboard(json) {
        return tspans
    }
    if let svg = pasteboard.string(forType: svgXmlPasteboardType),
       let tspans = tspansFromSvgFragment(svg) {
        return tspans
    }
    return nil
}
