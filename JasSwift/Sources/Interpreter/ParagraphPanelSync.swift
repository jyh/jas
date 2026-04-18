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

/// Compute the text-kind override map. Always returns a dict (even
/// for empty selections) so the caller doesn't need to special-case
/// "no overrides"; the booleans default to false (matching "fully
/// disabled" when nothing is selected).
public func paragraphPanelLiveOverrides(model: Model) -> [String: Any] {
    var anyText = false
    var allArea = true
    for es in model.document.selection {
        let elem = model.document.getElement(es.path)
        switch elem {
        case .text(let t):
            anyText = true
            if !(t.width > 0 && t.height > 0) {
                allArea = false
            }
        case .textPath:
            anyText = true
            allArea = false
        default:
            break
        }
    }
    return [
        "text_selected": anyText,
        "area_text_selected": anyText && allArea,
    ]
}
