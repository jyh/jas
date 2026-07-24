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

/// Live `state.stroke_*` values the Stroke panel's paired toggles read in
/// their `set: { stroke_X: "not state.stroke_X" }` effects — the Dashed-Line
/// checkbox, the Link-scales button, and the Flip-profile button. The dock's
/// panel eval-context (DockPanelView.buildPanelCtx) otherwise seeds `state`
/// from the STATIC workspace defaults, which then shadow the live store globals
/// inside StateStore.evalContext. Without this overlay `not state.stroke_dashed`
/// reads a stale `false` on every click and the checkbox latches checked
/// (uncheckable) — the DASHFIX bug. Reads the live PANEL scope (the checkbox's
/// own `checked: panel.dashed` source of truth) so `state.stroke_dashed`
/// tracks `panel.dashed` and the two effects toggle in lockstep. Mirrors the
/// Rust dock `build_live_state_map` stroke block.
public func strokePanelStateOverrides(store: StateStore) -> [String: Any] {
    let ps = store.getPanelState("stroke_panel_content")
    var out: [String: Any] = [:]
    if let d = ps["dashed"] { out["stroke_dashed"] = d }
    if let l = ps["link_arrowhead_scale"] { out["stroke_link_arrowhead_scale"] = l }
    if let f = ps["profile_flipped"] { out["stroke_profile_flipped"] = f }
    return out
}

/// LINKSCALE gap closure. The Stroke panel's arrowhead-scale combos
/// (`stk_start_arrowhead_scale` / `stk_end_arrowhead_scale`) bind to
/// `panel.<field>` ONLY, so their native two-way write lands in the panel
/// scope alone. But `applyStrokePanelToSelection` reads the scale from the
/// GLOBAL `stroke_<field>` (via `store.getAll()`), so a committed scale
/// would never reach apply-to-selection. Rust has no such gap — its native
/// two-way write (`set_stroke_field`) mutates the unified `stroke_panel`
/// struct, where the panel field and the global are one and the same; the
/// reference interpreter's `_commit` writes both scopes explicitly. Swift
/// keeps panel and global as SEPARATE dicts, so the combo's panel-only
/// native write must mirror the committed scale into the global here.
/// No-op for non-scale keys. Runs BEFORE `notifyPanelStateChanged` so the
/// apply pass reads the fresh value.
public func mirrorStrokeScaleCommitToGlobal(
    store: StateStore, key: String, value: Any?
) {
    guard key == "start_arrowhead_scale" || key == "end_arrowhead_scale"
    else { return }
    store.set("stroke_\(key)", value)
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
