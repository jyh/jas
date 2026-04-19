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
    }
    return out
}
