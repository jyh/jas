import Testing
import Foundation
import AppKit
@testable import JasLib

// MARK: - COLORTIERS: the RENDER half gets vectors of its own
//
// Only the PREDICATE (``nullColorMeansNone``) had a test. The white face, the
// red diagonal and the empty-string arm had none, in either port —
// `color_panel_content` is Path-B-excluded so no widget_tree golden sees this
// widget, and the harness has no none-indicator check. Reverting the whole
// `explicitNone` plumbing left all 2386 Swift tests, the goldens and 8/8
// gui_drive checks GREEN. These are the vectors that red instead.
//
// Mirrors the Rust `colortiers_*` swatch tests in
// jas_dioxus/src/interpreter/renderer.rs, function for function.

/// The Color panel's own render scope, reduced to what a swatch reads: the fill
/// is NONE, the stroke is black, and recent slot 1 has never been filled.
private let swatchCtx: [String: Any] = [
    "state": ["fill_color": NSNull(), "stroke_color": "#000000"] as [String: Any],
    "panel": ["recent_colors": ["ff0000", NSNull()] as [Any]] as [String: Any],
    "dialog": ["hex": ""] as [String: Any],
]

@Test func explicitNoneSwatchPaintsWhiteWithADiagonal() {
    let (color, explicitNone) = swatchColorBind("state.fill_color", context: swatchCtx)
    #expect(color.isEmpty, "a None fill resolves to no colour")
    #expect(explicitNone,
            "…and the null MEANS none, so the swatch draws the indicator")
    #expect(swatchFaceColor(color, explicitNone: explicitNone) == NSColor.white,
            """
            the face is WHITE so the red diagonal reads against it — a \
            transparent face just shows the panel background through
            """)
    #expect(swatchBorder(color, explicitNone: explicitNone, selected: false) == .solid,
            "an explicit none is a real swatch, not an empty slot")
}

@Test func emptyRecentSlotStaysAPlaceholder() {
    let (color, explicitNone) = swatchColorBind("panel.recent_colors.1", context: swatchCtx)
    #expect(color.isEmpty)
    #expect(!explicitNone, "an unfilled recent slot is a PLACEHOLDER — no diagonal")
    #expect(swatchFaceColor(color, explicitNone: explicitNone) == nil,
            "and no white face either: the slot is empty, not no-paint")
    #expect(swatchBorder(color, explicitNone: explicitNone, selected: false) == .placeholder)
}

@Test func clearedHexFieldIsAnExplicitNone() {
    // The second producer of the intentional case: a dialog's hex field cleared
    // to "". `#dialog.hex` means "#" + eval("dialog.hex").
    let (color, explicitNone) = swatchColorBind("#dialog.hex", context: swatchCtx)
    #expect(color.isEmpty)
    #expect(explicitNone, "an empty hex field is no paint, not black")
    #expect(swatchFaceColor(color, explicitNone: explicitNone) == NSColor.white)
}

@Test func aRealColourSwatchIsUnaffected() {
    let (color, explicitNone) = swatchColorBind("state.stroke_color", context: swatchCtx)
    #expect(color == "#000000")
    #expect(!explicitNone)
    #expect(swatchFaceColor(color, explicitNone: explicitNone) == NSColor(
        red: 0, green: 0, blue: 0, alpha: 1))
    #expect(swatchBorder(color, explicitNone: explicitNone, selected: false) == .solid)
    // A bare hex (how recent_colors stores them) gets its '#'.
    let (bare, _) = swatchColorBind("panel.recent_colors.0", context: swatchCtx)
    #expect(bare == "#ff0000")
}

@Test func selectionOutlineWinsOverBothBorders() {
    let (color, explicitNone) = swatchColorBind("state.fill_color", context: swatchCtx)
    #expect(swatchBorder(color, explicitNone: explicitNone, selected: true) == .selected)
    #expect(swatchBorder("", explicitNone: false, selected: true) == .selected)
}

/// An unbound swatch (no `bind.color` at all) is the third no-colour case and it
/// is a placeholder: nothing declared it as paint.
@Test func unboundSwatchIsAPlaceholder() {
    let (color, explicitNone) = swatchColorBind(nil, context: swatchCtx)
    #expect(color.isEmpty)
    #expect(!explicitNone)
    #expect(swatchBorder(color, explicitNone: explicitNone, selected: false) == .placeholder)
}

/// The INDICATOR's own geometry: bottom-left to top-right at 8% of the swatch.
/// Rust draws `x1='0' y1='100' x2='100' y2='0'` with `stroke-width='8'` in a
/// 100-unit viewBox, which is the same line and the same 8% — pinned on both
/// sides by `colortiers_none_diagonal_is_a_red_corner_to_corner_line`.
@Test func noneDiagonalRunsCornerToCornerAtEightPercent() {
    let path = swatchNoneDiagonalPath(size: 16)
    let box = path.boundingRect
    #expect(box.minX == 0 && box.minY == 0)
    #expect(box.maxX == 16 && box.maxY == 16, "corner to corner, not inset")
    #expect(swatchNoneDiagonalFraction == 0.08, "Rust's stroke-width 8 of 100")
    #expect(swatchNoneDiagonalLineWidth(size: 16) == 16 * 0.08)
    #expect(swatchNoneDiagonalLineWidth(size: 6) == 1,
            "never thinner than a hairline, or a small swatch loses the indicator")
}

/// The two ports must agree value for value, and the values are strings on both
/// sides for exactly that reason. This states the whole table once, in the shape
/// the Rust tests assert it.
@Test func swatchFaceTableMatchesRust() {
    let cases: [(expr: String?, color: String, none: Bool, face: NSColor?, border: SwatchBorder)] = [
        ("state.fill_color", "", true, .white, .solid),
        ("state.stroke_color", "#000000", false,
         NSColor(red: 0, green: 0, blue: 0, alpha: 1), .solid),
        ("panel.recent_colors.0", "#ff0000", false,
         NSColor(red: 1, green: 0, blue: 0, alpha: 1), .solid),
        ("panel.recent_colors.1", "", false, nil, .placeholder),
        ("#dialog.hex", "", true, .white, .solid),
        (nil, "", false, nil, .placeholder),
    ]
    for c in cases {
        let (color, explicitNone) = swatchColorBind(c.expr, context: swatchCtx)
        #expect(color == c.color, "colour for \(c.expr ?? "<unbound>")")
        #expect(explicitNone == c.none, "explicitNone for \(c.expr ?? "<unbound>")")
        #expect(swatchFaceColor(color, explicitNone: explicitNone) == c.face,
                "face for \(c.expr ?? "<unbound>")")
        #expect(swatchBorder(color, explicitNone: explicitNone, selected: false) == c.border,
                "border for \(c.expr ?? "<unbound>")")
    }
}
