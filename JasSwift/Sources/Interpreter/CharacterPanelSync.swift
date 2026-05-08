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
    let aRaw: TextAttrsLive
    let tspans: [Tspan]
    switch elem {
    case .text(let t):
        aRaw = TextAttrsLive(
            fontFamily: t.fontFamily, fontSize: t.fontSize,
            fontWeight: t.fontWeight, fontStyle: t.fontStyle,
            textDecoration: t.textDecoration,
            textTransform: t.textTransform, fontVariant: t.fontVariant,
            baselineShift: t.baselineShift, lineHeight: t.lineHeight,
            letterSpacing: t.letterSpacing, xmlLang: t.xmlLang,
            aaMode: t.aaMode, rotate: t.rotate,
            horizontalScale: t.horizontalScale, verticalScale: t.verticalScale,
            kerning: t.kerning)
        tspans = t.tspans
    case .textPath(let tp):
        aRaw = TextAttrsLive(
            fontFamily: tp.fontFamily, fontSize: tp.fontSize,
            fontWeight: tp.fontWeight, fontStyle: tp.fontStyle,
            textDecoration: tp.textDecoration,
            textTransform: tp.textTransform, fontVariant: tp.fontVariant,
            baselineShift: tp.baselineShift, lineHeight: tp.lineHeight,
            letterSpacing: tp.letterSpacing, xmlLang: tp.xmlLang,
            aaMode: tp.aaMode, rotate: tp.rotate,
            horizontalScale: tp.horizontalScale, verticalScale: tp.verticalScale,
            kerning: tp.kerning)
        tspans = tp.tspans
    default:
        return nil
    }

    // When an edit session has a range selection on the same element,
    // resolve each attribute against the tspans covering [lo, hi).
    // Uniform values across the range surface as the panel's display
    // value; non-uniform falls back to the element-level default so the
    // dropdown still shows something concrete.
    let a: TextAttrsLive = {
        guard let session = model.currentEditSession,
              session.hasSelection,
              session.path == first.path
        else { return aRaw }
        let (lo, hi) = session.selectionRange
        return TextAttrsLive(
            fontFamily:      uniformStringInRange(tspans, lo, hi, { $0.fontFamily }, aRaw.fontFamily),
            fontSize:        aRaw.fontSize,
            fontWeight:      uniformStringInRange(tspans, lo, hi, { $0.fontWeight }, aRaw.fontWeight),
            fontStyle:       uniformStringInRange(tspans, lo, hi, { $0.fontStyle }, aRaw.fontStyle),
            textDecoration:  uniformDecorationInRange(tspans, lo, hi, aRaw.textDecoration),
            textTransform:   uniformStringInRange(tspans, lo, hi, { $0.textTransform }, aRaw.textTransform),
            fontVariant:     uniformStringInRange(tspans, lo, hi, { $0.fontVariant }, aRaw.fontVariant),
            baselineShift:   uniformBaselineShiftInRange(tspans, lo, hi, aRaw.baselineShift),
            lineHeight:      aRaw.lineHeight,
            letterSpacing:   aRaw.letterSpacing,
            xmlLang:         uniformStringInRange(tspans, lo, hi, { $0.xmlLang }, aRaw.xmlLang),
            aaMode:          uniformStringInRange(tspans, lo, hi, { $0.jasAaMode }, aRaw.aaMode),
            rotate:          aRaw.rotate,
            horizontalScale: aRaw.horizontalScale,
            verticalScale:   aRaw.verticalScale,
            kerning:         aRaw.kerning)
    }()

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
    // Kerning combo_box display: named modes pass through verbatim;
    // numeric "Nem" converts to a plain "{N*1000}" decimal string.
    // Empty element attribute → "Auto" (spec default).
    let kerningDisplay: String
    switch a.kerning {
    case "": kerningDisplay = "Auto"
    case "Auto", "Optical", "Metrics": kerningDisplay = a.kerning
    default:
        if let n = parseEmAsThousandths(a.kerning) {
            kerningDisplay = fmtNum(n)
        } else {
            kerningDisplay = a.kerning
        }
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
        "kerning": kerningDisplay,
        "language": a.xmlLang,
        "anti_aliasing": aaDisplay,
    ]
}

/// Whether the first selected Text / TextPath element has an empty
/// line_height attribute (i.e. leading is in Auto mode = 120% of font
/// size). Returns false when no text is selected. Used by the panel
/// commit path to keep leading tracking font_size while Auto remains
/// in effect.
public func characterElementHasAutoLeading(model: Model) -> Bool {
    guard let first = model.document.selection.first else { return false }
    switch model.document.getElement(first.path) {
    case .text(let t): return t.lineHeight.isEmpty
    case .textPath(let tp): return tp.lineHeight.isEmpty
    default: return false
    }
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

/// Trim trailing zeros from a decimal render — integers have no
/// decimal point. Mirrors Rust's `fmt_num`.
private func fmtNum(_ n: Double) -> String {
    if n == n.rounded(.towardZero) { return String(Int(n)) }
    var s = String(format: "%.4f", n)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

/// "Npt" / "N" → N. nil when unparseable (caller chooses a default).
private func parsePt(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces)
    let rest = t.hasSuffix("pt") ? String(t.dropLast(2)) : t
    return Double(rest)
}

/// Walk `tspans` over [lo, hi). For each tspan that overlaps the
/// range, take its override value (or the parent default when nil).
/// Return the common value when every covered tspan agrees;
/// otherwise return `parent` so the panel still shows a concrete
/// value rather than a blank or stale field.
private func uniformStringInRange(
    _ tspans: [Tspan], _ lo: Int, _ hi: Int,
    _ extract: (Tspan) -> String?, _ parent: String
) -> String {
    if lo >= hi { return parent }
    var seen: String? = nil
    var cursor = 0
    for t in tspans {
        let len = t.content.unicodeScalars.count
        let tStart = cursor
        let tEnd = cursor + len
        cursor = tEnd
        if max(lo, tStart) >= min(hi, tEnd) { continue }
        let val = extract(t) ?? parent
        if let s = seen {
            if s != val { return parent }
        } else {
            seen = val
        }
    }
    return seen ?? parent
}

/// text-decoration variant: tspan stores it as `[String]?` (sorted
/// tokens) rather than a single string, so adapt the comparison.
private func uniformDecorationInRange(
    _ tspans: [Tspan], _ lo: Int, _ hi: Int, _ parent: String
) -> String {
    if lo >= hi { return parent }
    let parentTokens = parent.split(separator: " ").map(String.init).sorted()
    var seen: [String]? = nil
    var cursor = 0
    for t in tspans {
        let len = t.content.unicodeScalars.count
        let tStart = cursor
        let tEnd = cursor + len
        cursor = tEnd
        if max(lo, tStart) >= min(hi, tEnd) { continue }
        let toks = t.textDecoration?.sorted() ?? parentTokens
        if let s = seen {
            if s != toks { return parent }
        } else {
            seen = toks
        }
    }
    return seen?.joined(separator: " ") ?? parent
}

/// baseline-shift variant: tspan stores it as `Double?` (pt) rather
/// than the element's "Npt" / "super" / "sub" string, so reformat to
/// match the parent's representation. When tspans disagree, fall
/// back to the element-level value.
private func uniformBaselineShiftInRange(
    _ tspans: [Tspan], _ lo: Int, _ hi: Int, _ parent: String
) -> String {
    if lo >= hi { return parent }
    var seen: Double? = nil
    var seenSet = false
    var cursor = 0
    for t in tspans {
        let len = t.content.unicodeScalars.count
        let tStart = cursor
        let tEnd = cursor + len
        cursor = tEnd
        if max(lo, tStart) >= min(hi, tEnd) { continue }
        let val = t.baselineShift
        if seenSet {
            if seen != val { return parent }
        } else {
            seen = val
            seenSet = true
        }
    }
    guard seenSet else { return parent }
    if let v = seen {
        if v == 0.0 { return "" }
        return fmtNum(v) + "pt"
    }
    return parent
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
