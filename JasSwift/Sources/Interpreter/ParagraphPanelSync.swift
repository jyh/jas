/// Selection → Paragraph panel mirror — Phase 3a.
///
/// Computes panel.text_selected and panel.area_text_selected from
/// the current document selection so PARAGRAPH.md §Text-kind gating
/// can disable controls that don't apply to the selected text kind.
///
/// Mirrors the paragraph-panel block in `build_live_panel_overrides`
/// in jas_dioxus/src/workspace/dock_panel.rs.
///
/// Phase 3a only emits the two text-kind booleans. Phase 3b (combined
/// with Phase 1b) will read the selection's actual paragraph attribute
/// values (`jas:left-indent`, `jas:hyphenate`, etc.) and push them
/// to the matching `panel.*` fields.

import Foundation

/// Compute the text-kind override map plus paragraph attribute
/// overrides aggregated across every paragraph wrapper tspan in
/// every selected text element. Always returns a dict (even for
/// empty selections) so the caller doesn't need to special-case
/// "no overrides"; the booleans default to false (matching "fully
/// disabled" when nothing is selected).
///
/// Phase 3c: for each panel-surface paragraph attr, collect every
/// wrapper's effective value (Some(v) or the type's default). If
/// all wrappers agree the agreed value flows to the matching panel
/// key; if they disagree the key is omitted so the caller's panel
/// state retains its prior / YAML-default value. A future phase
/// polishes mixed into proper visual indication.
public func paragraphPanelLiveOverrides(model: Model) -> [String: Any] {
    var anyText = false
    var allArea = true
    var wrappers: [Tspan] = []
    for es in model.document.selection {
        let elem = model.document.getElement(es.path)
        switch elem {
        case .text(let t):
            anyText = true
            if !(t.width > 0 && t.height > 0) {
                allArea = false
            }
            for tspan in t.tspans where tspan.jasRole == "paragraph" {
                wrappers.append(tspan)
            }
        case .textPath:
            anyText = true
            allArea = false
        default:
            break
        }
    }
    var out: [String: Any] = [
        "text_selected": anyText,
        "area_text_selected": anyText && allArea,
    ]
    if !wrappers.isEmpty {
        // Returns the agreed value when all wrappers' effective values
        // are equal, nil when they differ.
        func agree<T: Equatable>(_ values: [T]) -> T? {
            guard let first = values.first else { return nil }
            return values.allSatisfy({ $0 == first }) ? first : nil
        }
        if let v = agree(wrappers.map { $0.jasLeftIndent ?? 0 }) {
            out["left_indent"] = v
        }
        if let v = agree(wrappers.map { $0.jasRightIndent ?? 0 }) {
            out["right_indent"] = v
        }
        if let v = agree(wrappers.map { $0.textIndent ?? 0 }) {
            out["first_line_indent"] = v
        }
        if let v = agree(wrappers.map { $0.jasSpaceBefore ?? 0 }) {
            out["space_before"] = v
        }
        if let v = agree(wrappers.map { $0.jasSpaceAfter ?? 0 }) {
            out["space_after"] = v
        }
        if let v = agree(wrappers.map { $0.jasHyphenate ?? false }) {
            out["hyphenate"] = v
        }
        if let v = agree(wrappers.map { $0.jasHangingPunctuation ?? false }) {
            out["hanging_punctuation"] = v
        }
        // Single backing attr split into two panel dropdowns; aggregate
        // first, then route by prefix.
        if let ls = agree(wrappers.map { $0.jasListStyle ?? "" }) {
            if ls.hasPrefix("bullet-") {
                out["bullets"] = ls
                out["numbered_list"] = ""
            } else if ls.hasPrefix("num-") {
                out["numbered_list"] = ls
                out["bullets"] = ""
            } else {
                out["bullets"] = ""
                out["numbered_list"] = ""
            }
        }
        // Aggregate alignment from text_align + text_align_last per
        // PARAGRAPH.md §Alignment sub-mapping. When all wrappers agree
        // on both values, set exactly one of the seven radio bools.
        let tas = wrappers.map { $0.textAlign ?? "left" }
        let tals = wrappers.map { $0.textAlignLast ?? "" }
        if let ta = agree(tas), let tal = agree(tals) {
            // Reset all seven first.
            for k in ["align_left", "align_center", "align_right",
                      "justify_left", "justify_center",
                      "justify_right", "justify_all"] {
                out[k] = false
            }
            let key: String
            switch (ta, tal) {
            case ("center", _): key = "align_center"
            case ("right", _): key = "align_right"
            case ("justify", "left"): key = "justify_left"
            case ("justify", "center"): key = "justify_center"
            case ("justify", "right"): key = "justify_right"
            case ("justify", "justify"): key = "justify_all"
            default: key = "align_left"
            }
            out[key] = true
        }
    }
    return out
}

/// Return a copy of `t` with `jasRole` replaced. Tspan fields are
/// `let`, so we rebuild via the full initializer rather than mutate.
public func withJasRole(_ t: Tspan, _ role: String?) -> Tspan {
    Tspan(
        id: t.id, content: t.content,
        baselineShift: t.baselineShift, dx: t.dx,
        fontFamily: t.fontFamily, fontSize: t.fontSize,
        fontStyle: t.fontStyle, fontVariant: t.fontVariant,
        fontWeight: t.fontWeight,
        jasAaMode: t.jasAaMode, jasFractionalWidths: t.jasFractionalWidths,
        jasKerningMode: t.jasKerningMode, jasNoBreak: t.jasNoBreak,
        jasRole: role,
        jasLeftIndent: t.jasLeftIndent, jasRightIndent: t.jasRightIndent,
        jasHyphenate: t.jasHyphenate,
        jasHangingPunctuation: t.jasHangingPunctuation,
        jasListStyle: t.jasListStyle,
        textAlign: t.textAlign, textAlignLast: t.textAlignLast,
        textIndent: t.textIndent,
        jasSpaceBefore: t.jasSpaceBefore, jasSpaceAfter: t.jasSpaceAfter,
        letterSpacing: t.letterSpacing, lineHeight: t.lineHeight,
        rotate: t.rotate, styleName: t.styleName,
        textDecoration: t.textDecoration, textRendering: t.textRendering,
        textTransform: t.textTransform, transform: t.transform,
        xmlLang: t.xmlLang)
}

/// Return a copy of `t` with the ten panel-surface paragraph attribute
/// fields replaced. Other tspan fields pass through unchanged.
public func withParagraphAttrs(
    _ t: Tspan,
    textAlign: String?, textAlignLast: String?,
    textIndent: Double?,
    jasLeftIndent: Double?, jasRightIndent: Double?,
    jasSpaceBefore: Double?, jasSpaceAfter: Double?,
    jasHyphenate: Bool?, jasHangingPunctuation: Bool?,
    jasListStyle: String?
) -> Tspan {
    Tspan(
        id: t.id, content: t.content,
        baselineShift: t.baselineShift, dx: t.dx,
        fontFamily: t.fontFamily, fontSize: t.fontSize,
        fontStyle: t.fontStyle, fontVariant: t.fontVariant,
        fontWeight: t.fontWeight,
        jasAaMode: t.jasAaMode, jasFractionalWidths: t.jasFractionalWidths,
        jasKerningMode: t.jasKerningMode, jasNoBreak: t.jasNoBreak,
        jasRole: t.jasRole,
        jasLeftIndent: jasLeftIndent, jasRightIndent: jasRightIndent,
        jasHyphenate: jasHyphenate,
        jasHangingPunctuation: jasHangingPunctuation,
        jasListStyle: jasListStyle,
        textAlign: textAlign, textAlignLast: textAlignLast,
        textIndent: textIndent,
        jasSpaceBefore: jasSpaceBefore, jasSpaceAfter: jasSpaceAfter,
        letterSpacing: t.letterSpacing, lineHeight: t.lineHeight,
        rotate: t.rotate, styleName: t.styleName,
        textDecoration: t.textDecoration, textRendering: t.textRendering,
        textTransform: t.textTransform, transform: t.transform,
        xmlLang: t.xmlLang)
}

/// Apply mutual exclusion side effects for a paragraph panel write.
/// Called by `commitPanelWrite` *before* the user's new value lands
/// in the panel state, so the seven alignment radio bools collapse to
/// one and bullets / numbered_list never both hold a non-empty value.
public func applyParagraphPanelMutualExclusion(
    store: StateStore, key: String, value: Any?
) {
    let pid = "paragraph_panel_content"
    let alignKeys = ["align_left", "align_center", "align_right",
                     "justify_left", "justify_center",
                     "justify_right", "justify_all"]
    if alignKeys.contains(key) {
        // Writing any alignment radio button clears the other six —
        // turning a button on is a radio-group press, turning one off
        // is a no-op (the visible button can't be unchecked, only
        // replaced; we still respect a false write but don't promote
        // any other button).
        if let b = value as? Bool, b {
            for k in alignKeys where k != key {
                store.setPanel(pid, k, false)
            }
        }
        return
    }
    if key == "bullets" {
        if let s = value as? String, !s.isEmpty {
            store.setPanel(pid, "numbered_list", "")
        }
    } else if key == "numbered_list" {
        if let s = value as? String, !s.isEmpty {
            store.setPanel(pid, "bullets", "")
        }
    }
}
