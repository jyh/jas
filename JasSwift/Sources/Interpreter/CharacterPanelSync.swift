/// Selection → Character panel mirror.
///
/// When a Text / TextPath element is selected, the Character panel's
/// controls should reflect *that element's* attributes rather than
/// stale panel-local state. This file exposes the inverse of
/// `applyCharacterPanelToSelection`: pull the selection's character
/// attributes into the `character_panel` scope dict so the YAML
/// widgets bound to `panel.font_family` / `panel.all_caps` / etc
/// display the current element.
///
/// Mirrors the `build_live_panel_overrides` block in the Rust dock
/// panel. Called from `DockPanelView.buildPanelCtx`.

import Foundation

/// Read the first selected Text / TextPath element and derive the
/// Character-panel key/value overrides. Returns `nil` when no text
/// element is selected — caller falls back to the stored panel scope.
public func characterPanelLiveOverrides(model: Model) -> [String: Any]? {
    guard let first = model.document.selection.first else { return nil }
    let elem = model.document.getElement(first.path)
    let a: TextAttrsLive
    switch elem {
    case .text(let t):
        a = TextAttrsLive(
            fontFamily: t.fontFamily, fontSize: t.fontSize,
            fontWeight: t.fontWeight, fontStyle: t.fontStyle,
            textDecoration: t.textDecoration,
            textTransform: t.textTransform, fontVariant: t.fontVariant,
            baselineShift: t.baselineShift, lineHeight: t.lineHeight,
            letterSpacing: t.letterSpacing, xmlLang: t.xmlLang,
            aaMode: t.aaMode, rotate: t.rotate,
            horizontalScale: t.horizontalScale, verticalScale: t.verticalScale,
            kerning: t.kerning)
    case .textPath(let tp):
        a = TextAttrsLive(
            fontFamily: tp.fontFamily, fontSize: tp.fontSize,
            fontWeight: tp.fontWeight, fontStyle: tp.fontStyle,
            textDecoration: tp.textDecoration,
            textTransform: tp.textTransform, fontVariant: tp.fontVariant,
            baselineShift: tp.baselineShift, lineHeight: tp.lineHeight,
            letterSpacing: tp.letterSpacing, xmlLang: tp.xmlLang,
            aaMode: tp.aaMode, rotate: tp.rotate,
            horizontalScale: tp.horizontalScale, verticalScale: tp.verticalScale,
            kerning: tp.kerning)
    default:
        return nil
    }

    let (underline, strikethrough) = textDecorationFlags(a.textDecoration)
    // Numeric baseline-shift: only expose when super/sub isn't set.
    let bshiftPt: Double = (a.baselineShift == "super" || a.baselineShift == "sub")
        ? 0.0
        : (parsePt(a.baselineShift) ?? 0.0)
    // Leading: empty = Auto (120% of font_size).
    let leadingPt = a.lineHeight.isEmpty
        ? a.fontSize * 1.2
        : (parsePt(a.lineHeight) ?? a.fontSize * 1.2)
    // Tracking: parse "Nem" → N*1000 (panel stores 1/1000 em).
    let tracking = a.letterSpacing.isEmpty
        ? 0.0
        : (parseEmAsThousandths(a.letterSpacing) ?? 0.0)
    // Kerning: parse "Nem" → N*1000. Empty or named mode → 0.
    let kerning: Double
    if a.kerning.isEmpty || a.kerning == "Auto" || a.kerning == "Optical" || a.kerning == "Metrics" {
        kerning = 0.0
    } else {
        kerning = parseEmAsThousandths(a.kerning) ?? 0.0
    }
    let styleName = formatStyleName(weight: a.fontWeight, style: a.fontStyle)
    // Anti-aliasing: empty element field → panel default "Sharp".
    let aaDisplay = a.aaMode.isEmpty ? "Sharp" : a.aaMode
    let rotation = Double(a.rotate) ?? 0.0
    let hScale = Double(a.horizontalScale) ?? 100.0
    let vScale = Double(a.verticalScale) ?? 100.0

    return [
        "font_family": a.fontFamily,
        "font_size": a.fontSize,
        "style_name": styleName,
        "underline": underline,
        "strikethrough": strikethrough,
        "all_caps": a.textTransform == "uppercase",
        "small_caps": a.fontVariant == "small-caps",
        "superscript": a.baselineShift == "super",
        "subscript": a.baselineShift == "sub",
        "baseline_shift": bshiftPt,
        "leading": leadingPt,
        "tracking": tracking,
        "character_rotation": rotation,
        "horizontal_scale": hScale,
        "vertical_scale": vScale,
        "kerning": kerning,
        "language": a.xmlLang,
        "anti_aliasing": aaDisplay,
    ]
}

private struct TextAttrsLive {
    let fontFamily: String
    let fontSize: Double
    let fontWeight: String
    let fontStyle: String
    let textDecoration: String
    let textTransform: String
    let fontVariant: String
    let baselineShift: String
    let lineHeight: String
    let letterSpacing: String
    let xmlLang: String
    let aaMode: String
    let rotate: String
    let horizontalScale: String
    let verticalScale: String
    let kerning: String
}

/// Underline + strikethrough flags from a whitespace-split
/// `text-decoration`. "underline line-through", "line-through
/// underline", mixed-case all round-trip cleanly through the panel.
private func textDecorationFlags(_ td: String) -> (Bool, Bool) {
    var u = false, s = false
    for tok in td.split(separator: " ") {
        if tok == "underline" { u = true }
        if tok == "line-through" { s = true }
    }
    return (u, s)
}

/// "Nem" → N * 1000 (panel stores tracking / kerning in 1/1000 em).
private func parseEmAsThousandths(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces)
    let rest = t.hasSuffix("em") ? String(t.dropLast(2)) : t
    return Double(rest).map { $0 * 1000.0 }
}

/// "Npt" / "N" → N. nil when unparseable (caller chooses a default).
private func parsePt(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces)
    let rest = t.hasSuffix("pt") ? String(t.dropLast(2)) : t
    return Double(rest)
}

/// Display the Style picker's current name from font_weight /
/// font_style. Matches the Rust `format_style_name` fallback
/// (unrecognised combos → "Regular") so the dropdown always shows
/// a concrete value.
private func formatStyleName(weight: String, style: String) -> String {
    let bold = weight == "bold" || (Int(weight).map { $0 >= 600 } ?? false)
    let italic = style == "italic" || style == "oblique"
    switch (bold, italic) {
    case (true, true): return "Bold Italic"
    case (true, false): return "Bold"
    case (false, true): return "Italic"
    case (false, false): return "Regular"
    }
}
