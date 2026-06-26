/// Selection → Stroke panel weight mirror (decision-5a).
///
/// The Stroke panel's Weight field must reflect the selection's stroke
/// width — its baked / effective width after the scale counter-scale
/// work — not the YAML default. Mirrors `colorPanelLiveOverrides` and
/// the Rust dock `build_live_panel_overrides` stroke block: resolves
/// the FIRST selected element's stroke width, falling back to the model
/// default (then 1.0).
///
/// Display-only — the override is merged into the panel's render scope
/// (DockPanelView.buildPanelCtx), never written to the selection, so it
/// cannot clobber other stroke props. Always returns a `weight`, so a
/// deselect shows the default rather than a stale selection value.

import Foundation

public func strokePanelLiveOverrides(model: Model) -> [String: Any] {
    let doc = model.document
    var width: Double? = nil
    if let first = doc.selection.first {
        width = doc.getElement(first.path).stroke?.width
    }
    let resolved = width ?? model.defaultStroke?.width ?? 1.0
    return ["weight": resolved]
}
