/// Regression oracle for the shared-bundle icon parser
/// (`Sources/Interpreter/WorkspaceIcon.swift`).
///
/// The toolbar/panels render tool icons from the shared `icons` map
/// in workspace.json (each entry: { viewbox, svg }) via
/// `SvgIconParser.parse`. When the parser cannot handle an SVG
/// construct it returns nil and the caller falls back to rendering
/// the icon's *summary text* ("Pen (P)") instead of the glyph.
///
/// This test loads the same `icons` map the app uses and asserts that
/// EVERY icon parses to non-nil rendered geometry (at least one
/// non-text primitive) — i.e. no icon silently degrades to text —
/// with the single documented exception of `para_numbered`, whose
/// glyph is a `<text>` element we deliberately do not rasterize.

import Foundation
import Testing
@testable import JasLib

/// Icons that legitimately produce no path geometry: their SVG is a
/// `<text>` element which the parser surfaces as a text primitive for
/// the caller to draw with a font. These are excluded from the
/// "non-text geometry" assertion.
private let textOnlyIcons: Set<String> = ["para_numbered"]

@Test func everyBundleIconParsesToGeometry() throws {
    let ws = try #require(WorkspaceData.load(), "workspace.json failed to load")
    let icons = ws.icons()
    #expect(!icons.isEmpty, "bundle has no icons map")

    var parsedCount = 0
    var failures: [String] = []
    var noGeometry: [String] = []
    var unexpectedText: [String] = []

    for (name, raw) in icons {
        guard let def = raw as? [String: Any],
              let viewbox = def["viewbox"] as? String,
              let svg = def["svg"] as? String else {
            failures.append("\(name): malformed icon entry")
            continue
        }
        guard let parsed = SvgIconParser.parse(viewbox: viewbox, svgFragment: svg) else {
            failures.append(name)
            continue
        }
        parsedCount += 1

        // Every icon must yield at least one non-text primitive...
        let hasGeometry = parsed.primitives.contains { $0.text == nil }
        // ...except para_numbered, whose path geometry happens to be
        // the divider lines; that still counts, but we never *require*
        // geometry of a text-only icon.
        if !hasGeometry && !textOnlyIcons.contains(name) {
            noGeometry.append(name)
        }
        // No icon other than the documented text-only set may produce
        // a <text> primitive: a text primitive is what the original
        // gap forced us to fall back on.
        let hasText = parsed.primitives.contains { $0.text != nil }
        if hasText && !textOnlyIcons.contains(name) {
            unexpectedText.append(name)
        }
    }

    // The core oracle: NO icon fails to parse. A parse failure is
    // exactly what makes renderIconButton fall back to summary text.
    #expect(failures.isEmpty,
            "icons that FAILED to parse (would fall back to text): \(failures.sorted())")
    #expect(parsedCount == icons.count,
            "expected all \(icons.count) icons to parse, got \(parsedCount)")
    #expect(noGeometry.isEmpty,
            "icons that parsed but produced no drawable geometry: \(noGeometry.sorted())")
    #expect(unexpectedText.isEmpty,
            "icons that unexpectedly produced text primitives: \(unexpectedText.sorted())")
}

/// Targeted checks for the specific path commands and the transform
/// attribute that motivated this work, so a regression in any one of
/// them is reported by name rather than only via the aggregate.
@Test func iconsUsingNewlySupportedFeaturesParse() throws {
    let ws = try #require(WorkspaceData.load(), "workspace.json failed to load")
    let icons = ws.icons()

    // S/s smooth cubic, T/t smooth quad, A/a arc, and transform=.
    let mustParse = [
        "pen", "pencil", "type", "add_anchor", "anchor_point", "delete_anchor",  // S/s
        "brush_options_for_selection",                                            // t
        "rotate", "link_linked", "link_unlinked", "reset",                        // A/a
        "paintbrush", "blob_brush", "path_eraser", "brush_libraries_menu",        // transform
        "brush_type_calligraphic", "char_snap_angular", "swap_arrows",            // transform
    ]
    for name in mustParse {
        guard let def = icons[name] as? [String: Any],
              let viewbox = def["viewbox"] as? String,
              let svg = def["svg"] as? String else {
            Issue.record("icon \(name) missing from bundle")
            continue
        }
        let parsed = SvgIconParser.parse(viewbox: viewbox, svgFragment: svg)
        #expect(parsed != nil, "icon \(name) failed to parse")
        if let parsed {
            #expect(parsed.primitives.contains { $0.text == nil },
                    "icon \(name) parsed but produced no drawable geometry")
        }
    }
}
