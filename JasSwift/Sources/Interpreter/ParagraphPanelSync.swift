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

/// Compute the text-kind override map plus, in Phase 3b, paragraph
/// attribute overrides read from the first paragraph wrapper tspan
/// in the first selected text element. Always returns a dict (even
/// for empty selections) so the caller doesn't need to special-case
/// "no overrides"; the booleans default to false (matching "fully
/// disabled" when nothing is selected).
///
/// Mixed-state aggregation across multiple wrappers / multiple text
/// elements is deferred to Phase 3c. For now the reader takes the
/// first wrapper's values verbatim; absent wrapper leaves the
/// caller's panel-state defaults intact (we only insert keys for
/// fields actually present on the wrapper).
public func paragraphPanelLiveOverrides(model: Model) -> [String: Any] {
    var anyText = false
    var allArea = true
    var firstPara: Tspan? = nil
    for es in model.document.selection {
        let elem = model.document.getElement(es.path)
        switch elem {
        case .text(let t):
            anyText = true
            if !(t.width > 0 && t.height > 0) {
                allArea = false
            }
            if firstPara == nil {
                firstPara = t.tspans.first(where: { $0.jasRole == "paragraph" })
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
    if let p = firstPara {
        if let v = p.jasLeftIndent { out["left_indent"] = v }
        if let v = p.jasRightIndent { out["right_indent"] = v }
        if let v = p.jasHyphenate { out["hyphenate"] = v }
        if let v = p.jasHangingPunctuation { out["hanging_punctuation"] = v }
        // Single backing attr split into two panel dropdowns. bullet-*
        // populates panel.bullets; num-* populates panel.numbered_list.
        // The other dropdown shows None (matching the spec's mutual
        // exclusion in PARAGRAPH.md §Bullets and numbered lists).
        if let ls = p.jasListStyle {
            if ls.hasPrefix("bullet-") {
                out["bullets"] = ls
                out["numbered_list"] = ""
            } else if ls.hasPrefix("num-") {
                out["numbered_list"] = ls
                out["bullets"] = ""
            }
        }
    }
    return out
}
