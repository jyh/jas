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
import AppKit
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

// MARK: - SVG paint-default conformance

/// SVG `fill` default is BLACK. An attribute-less `<path>` must NOT
/// degrade to `.none` (invisible) — that made `pen` (and every no-fill
/// bundle icon) vanish in Swift while the real engines fill it black.
@Test func attributeLessPathDefaultsToBlackFill() throws {
    let parsed = try #require(
        SvgIconParser.parse(viewbox: "0 0 10 10",
                            svgFragment: #"<path d="M0,0 L10,0 L10,10 Z"/>"#),
        "no-fill path should parse")
    let prim = try #require(parsed.primitives.first { $0.text == nil })
    // Default fill must produce a (non-nil) color, and specifically
    // black, with no fill-rule / opacity surprises.
    let color = prim.fill.toColor(tint: .red)
    #expect(color != nil, "absent fill must default to a visible paint, not .none")
    if case .literal(let c) = prim.fill {
        // Approximate-equality on the sRGB components (black).
        let r = c.usingColorSpace(.sRGB)?.redComponent ?? -1
        let g = c.usingColorSpace(.sRGB)?.greenComponent ?? -1
        let b = c.usingColorSpace(.sRGB)?.blueComponent ?? -1
        #expect(r == 0 && g == 0 && b == 0, "default fill must be black, got \(r),\(g),\(b)")
    } else {
        Issue.record("default fill should be a literal black, got \(prim.fill)")
    }
    // SVG `stroke` default IS none — keep that.
    #expect(prim.stroke.toColor(tint: .red) == nil, "absent stroke must default to none")
    #expect(prim.fillEvenOdd == false, "default fill-rule is nonzero")
    #expect(prim.fillAlpha == 1.0)
    #expect(prim.strokeAlpha == 1.0)
}

/// `fill-rule="evenodd"` must be surfaced so nested/overlapping
/// subpaths leave holes (star center, boolean_* overlaps) instead of
/// filling solid. Default (`nonzero`) must NOT be flagged even-odd.
@Test func fillRuleEvenOddIsFlagged() throws {
    let eo = try #require(SvgIconParser.parse(
        viewbox: "0 0 10 10",
        svgFragment: #"<polygon fill="gray" fill-rule="evenodd" points="0,0 10,0 10,10"/>"#))
    let eoPrim = try #require(eo.primitives.first { $0.text == nil })
    #expect(eoPrim.fillEvenOdd == true, "fill-rule=evenodd must be flagged")

    let nz = try #require(SvgIconParser.parse(
        viewbox: "0 0 10 10",
        svgFragment: #"<polygon fill="gray" points="0,0 10,0 10,10"/>"#))
    let nzPrim = try #require(nz.primitives.first { $0.text == nil })
    #expect(nzPrim.fillEvenOdd == false, "absent fill-rule must be nonzero")
}

/// Real-bundle spot checks: the actual `star` polygon is even-odd and
/// the actual `pen` first path has no fill (→ black).
@Test func realBundlePaintDefaults() throws {
    let ws = try #require(WorkspaceData.load())
    let icons = ws.icons()

    // star: even-odd fill (center hole).
    let starDef = try #require(icons["star"] as? [String: Any])
    let star = try #require(SvgIconParser.parse(
        viewbox: starDef["viewbox"] as! String,
        svgFragment: starDef["svg"] as! String))
    #expect(star.primitives.contains { $0.text == nil && $0.fillEvenOdd },
            "star polygon must be flagged even-odd")

    // pen: first path has no fill attribute → must default to a
    // visible (black) fill, not .none.
    let penDef = try #require(icons["pen"] as? [String: Any])
    let pen = try #require(SvgIconParser.parse(
        viewbox: penDef["viewbox"] as! String,
        svgFragment: penDef["svg"] as! String))
    let firstGeom = try #require(pen.primitives.first { $0.text == nil })
    #expect(firstGeom.fill.toColor(tint: .red) != nil,
            "pen body (no fill attr) must render visible, not invisible")
}

/// Shorthand hex (`#fff`, `#888`) must expand per CSS — the shared
/// NSColor(hex:) reads `#fff` as 0x000fff (blue), so the icon path must
/// expand nibbles itself. Affects every `#fff` facet (pen / paintbrush
/// / arrows) and `#888` swatches.
@Test func shorthandHexExpands() throws {
    func fillColor(_ svg: String) throws -> NSColor {
        let p = try #require(SvgIconParser.parse(viewbox: "0 0 10 10", svgFragment: svg))
        let prim = try #require(p.primitives.first { $0.text == nil })
        guard case .literal(let c) = prim.fill else {
            Issue.record("expected literal fill"); return .clear
        }
        return c.usingColorSpace(.sRGB) ?? c
    }
    let white = try fillColor(##"<rect x="0" y="0" width="10" height="10" fill="#fff"/>"##)
    #expect(abs(white.redComponent - 1) < 0.01 && abs(white.greenComponent - 1) < 0.01
            && abs(white.blueComponent - 1) < 0.01, "#fff must be white, got \(white)")
    let gray = try fillColor(##"<rect x="0" y="0" width="10" height="10" fill="#888"/>"##)
    let g = 0x88 / 255.0
    #expect(abs(gray.redComponent - g) < 0.01 && abs(gray.greenComponent - g) < 0.01
            && abs(gray.blueComponent - g) < 0.01, "#888 must be mid-gray, got \(gray)")
    // 3-digit shorthand red still expands correctly.
    let red = try fillColor(##"<rect x="0" y="0" width="10" height="10" fill="#d22"/>"##)
    #expect(abs(red.redComponent - 0xdd / 255.0) < 0.01, "#d22 red channel")
}

/// `opacity` / `fill-opacity` / `stroke-opacity` must fold into the
/// effective paint alpha (panel_layers / eye_invisible fade). Element
/// `opacity` multiplies both channels; per-paint opacity its channel.
@Test func opacityFoldsIntoPaintAlpha() throws {
    let p = try #require(SvgIconParser.parse(
        viewbox: "0 0 10 10",
        svgFragment: #"<rect x="0" y="0" width="10" height="10" fill="gray" opacity="0.3"/>"#))
    let prim = try #require(p.primitives.first { $0.text == nil })
    #expect(abs(prim.fillAlpha - 0.3) < 1e-9, "opacity must fold into fillAlpha")

    let q = try #require(SvgIconParser.parse(
        viewbox: "0 0 10 10",
        svgFragment: #"<line x1="0" y1="0" x2="10" y2="10" stroke="gray" stroke-width="1" stroke-opacity="0.5" opacity="0.5"/>"#))
    let qp = try #require(q.primitives.first { $0.text == nil })
    #expect(abs(qp.strokeAlpha - 0.25) < 1e-9, "opacity * stroke-opacity must fold into strokeAlpha")
}
