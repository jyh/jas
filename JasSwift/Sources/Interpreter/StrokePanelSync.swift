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

private func capName(_ c: LineCap) -> String {
    switch c { case .butt: return "butt"; case .round: return "round"; case .square: return "square" }
}

private func joinName(_ j: LineJoin) -> String {
    switch j { case .miter: return "miter"; case .round: return "round"; case .bevel: return "bevel" }
}

public func strokePanelLiveOverrides(model: Model) -> [String: Any] {
    let doc = model.document
    var stroke: Stroke? = nil
    if let first = doc.selection.first {
        stroke = doc.getElement(first.path).stroke
    }
    let s = stroke ?? model.defaultStroke
    var out: [String: Any] = ["weight": s?.width ?? 1.0]
    // Also mirror the selection's cap / join (matches the Rust dock), so
    // those widgets reflect the selection. Display-only.
    if let s = s {
        out["cap"] = capName(s.linecap)
        out["join"] = joinName(s.linejoin)
    }
    return out
}
