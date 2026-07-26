/// What a `color_swatch` widget PAINTS, decided from its `bind.color` alone.
///
/// Three pure functions, mirroring Rust's `swatch_color_bind` /
/// `swatch_face_color` / `swatch_border` (jas_dioxus interpreter/renderer.rs)
/// function for function, so the two ports cannot answer this differently.
///
/// They live outside the view for one reason: to be REACHABLE by a test.
/// `color_panel_content` is Path-B-excluded, so no widget_tree golden sees this
/// widget, and the harness has no none-indicator check — so when the
/// red-diagonal plumbing shipped, reverting it left every Swift test, every
/// golden and every gui_drive check green. The white face, the diagonal and the
/// empty-string arm are pinned by ColorSwatchFaceTests.swift now.

import AppKit
import SwiftUI

/// The no-paint diagonal's line width as a fraction of the swatch: 8%.
///
/// Rust draws the same indicator as `stroke-width: 8` inside a `0 0 100 100`
/// viewBox (`NONE_DIAG_SVG`), which is the same 8%. Pinned on both sides so the
/// indicator cannot drift apart.
let swatchNoneDiagonalFraction: CGFloat = 0.08

/// The no-paint diagonal itself: bottom-left to top-right, the corner-to-corner
/// line Rust's `NONE_DIAG_SVG` draws (`x1=0 y1=100 → x2=100 y2=0`).
func swatchNoneDiagonalPath(size: CGFloat) -> SwiftUI.Path {
    var path = SwiftUI.Path()
    path.move(to: CGPoint(x: 0, y: size))
    path.addLine(to: CGPoint(x: size, y: 0))
    return path
}

/// …at least a hairline, so the indicator never vanishes on a tiny swatch.
func swatchNoneDiagonalLineWidth(size: CGFloat) -> CGFloat {
    max(1, size * swatchNoneDiagonalFraction)
}

/// The colour a swatch's `bind.color` resolves to, and whether "no colour"
/// means an EXPLICIT none.
///
/// `explicitNone == true` is the "intentionally no paint" case — the
/// red-diagonal indicator — as distinct from "missing bind / unset slot", which
/// also has no colour but is a PLACEHOLDER. Two producers encode the
/// intentional case: an empty string (a dialog's hex field cleared), and a NULL
/// from a bind that declares a nullable state colour (``nullColorMeansNone``).
/// Sending both to `.clear` — which ``YamlPanelBodyView/renderColorSwatch`` once
/// did — made an explicit None and an empty recent-colour slot the same square,
/// and drew a cleared hex field as BLACK.
///
/// The colour comes back as a hex STRING (`""` for no colour), exactly as in
/// Rust, so the decision is comparable across the ports without an NSColor in
/// the way. Bare hex (how `recent_colors` stores them) gets its '#'.
func swatchColorBind(_ colorExpr: String?, context: [String: Any])
    -> (color: String, explicitNone: Bool)
{
    guard let colorExpr = colorExpr else { return ("", false) }
    // "#dialog.hex" means "#" + eval("dialog.hex"), mirroring Rust.
    let hashPrefixed = colorExpr.hasPrefix("#") && colorExpr.contains(".")
    let inner = hashPrefixed ? String(colorExpr.dropFirst()) : colorExpr
    switch evaluate(inner, context: context) {
    case .color(let c):
        return (c, false)
    case .string(let s):
        if s.isEmpty { return ("", true) }
        return (s.hasPrefix("#") && !hashPrefixed ? s : "#" + s, false)
    case .null:
        return ("", nullColorMeansNone(inner))
    default:
        return ("", false)
    }
}

/// The colour a swatch PAINTS, given ``swatchColorBind``'s answer: `nil` means
/// paint nothing (a transparent placeholder face).
///
/// An explicit none paints WHITE so the red diagonal reads against a clean
/// background — the same substitution Rust's `swatch_face_color` makes, and what
/// the native ``FillStrokeWidget`` squares already did. The hollow ("stroke")
/// swatch runs its RING through this same function, so a no-stroke ring is a
/// white ring with a diagonal rather than an invisible one.
func swatchFaceColor(_ color: String, explicitNone: Bool) -> NSColor? {
    if explicitNone { return .white }
    if color.isEmpty { return nil }
    let (r, g, b) = parseHex(color)
    return NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                   blue: CGFloat(b) / 255, alpha: 1)
}

/// Which of the three borders a swatch draws. Mirrors Rust's `SwatchBorder`.
enum SwatchBorder: Equatable {
    /// In `bind.selected_in`'s list: a 2px accent outline.
    case selected
    /// No colour and no explicit none — an EMPTY SLOT (an unfilled
    /// recent-colours tile). Dashed, the standard placeholder affordance, as
    /// Rust has always drawn it.
    case placeholder
    /// A real swatch: a colour, or an explicit none (a real answer about the
    /// paint, drawn as a white face with a red diagonal — not an empty slot).
    case solid
}

func swatchBorder(_ color: String, explicitNone: Bool, selected: Bool) -> SwatchBorder {
    if selected { return .selected }
    if color.isEmpty && !explicitNone { return .placeholder }
    return .solid
}
