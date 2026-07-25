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

/// The stroke attributes ONE Stroke-panel field owns.
///
/// A panel edit must write only the group it touched and preserve every
/// other attribute from the element (see `applyStrokePanelToSelection`).
/// Fields that move together stay in one group: the dash inputs and the
/// dashed toggle are one pattern, and the two arrowhead scales move
/// together because the link-scales button mirrors one onto the other.
/// Mirrors the Rust `StrokeEditGroup` (app_state.rs).
public enum StrokeEditGroup {
    case width
    case cap
    case join
    case miterLimit
    case align
    case dash
    case startArrow
    case endArrow
    case arrowScales
    case arrowAlign
    /// Width profile only — the Stroke itself is untouched.
    case profile

    /// Map a Stroke-panel field key to the group it owns. Accepts both the
    /// PANEL key (`"cap"` — what the widget write-backs commit) and the
    /// flat GLOBAL key (`"stroke_cap"` — what YAML `set:` effects write).
    /// `nil` means the key owns no element attribute, so editing it writes
    /// nothing to the selection.
    public static func fromField(_ key: String) -> StrokeEditGroup? {
        switch strokeFieldName(key) {
        case "weight": return .width
        case "cap": return .cap
        case "join": return .join
        case "miter_limit": return .miterLimit
        case "align_stroke", "align": return .align
        case "dashed", "dash_1", "gap_1", "dash_2", "gap_2", "dash_3",
             "gap_3", "dash_align_anchors": return .dash
        case "start_arrowhead": return .startArrow
        case "end_arrowhead": return .endArrow
        case "start_arrowhead_scale", "end_arrowhead_scale": return .arrowScales
        // `link_arrowhead_scale` is a UI-only flag: the chain button
        // mirrors one scale onto the other by committing the SIBLING scale
        // field, which applies through .arrowScales. Toggling the chain
        // itself must not touch the document (it would push an undo step
        // that changes nothing).
        case "arrow_align": return .arrowAlign
        case "profile", "profile_flipped": return .profile
        default: return nil
        }
    }
}

/// Normalize a Stroke-panel field key to its panel-scope name by dropping
/// the `stroke_` prefix the flat global keys carry.
public func strokeFieldName(_ key: String) -> String {
    key.hasPrefix("stroke_") ? String(key.dropFirst("stroke_".count)) : key
}

/// Read one Stroke-panel field, PANEL scope first and the flat global
/// `stroke_<field>` as fallback.
///
/// Panel-first because that is where every in-panel widget write-back
/// lands: the arrowhead selects and the weight / dash / scale inputs bind
/// `panel.<field>` only, and the YAML `set:` effects mirror their writes
/// into both scopes (`set_panel_state` + `set`). The globals stay as the
/// fallback for out-of-panel writers. Rust has one unified `stroke_panel`
/// struct where the panel field and the global are the same slot.
public func strokePanelField(_ store: StateStore, _ field: String) -> Any? {
    if let v = store.getPanel("stroke_panel_content", field), !(v is NSNull) {
        return v
    }
    let globals = store.getAll()
    if let v = globals["stroke_\(field)"], !(v is NSNull) { return v }
    // `align_stroke` is written to the global as `stroke_align` by the
    // panel's `init:` block but as `stroke_align_stroke` by its widgets;
    // accept both.
    if field == "align_stroke", let v = globals["stroke_align"], !(v is NSNull) {
        return v
    }
    return nil
}

/// `strokePanelField` as a Double (numeric values arrive as Int / Double /
/// NSNumber depending on the commit path).
public func strokePanelNumber(_ store: StateStore, _ field: String) -> Double? {
    switch strokePanelField(store, field) {
    case let n as NSNumber: return n.doubleValue
    case let d as Double: return d
    case let i as Int: return Double(i)
    default: return nil
    }
}

/// Overwrite `base`'s `group` attributes from the Stroke panel state,
/// leaving every other attribute of `base` untouched. `committedWidth` is
/// the weight input's committed value and is read only for `.width`.
/// Mirrors the Rust `stroke_with_group`.
public func strokeWithGroup(
    _ base: Stroke, store: StateStore, group: StrokeEditGroup,
    committedWidth: Double
) -> Stroke {
    var width = base.width
    var linecap = base.linecap
    var linejoin = base.linejoin
    var miterLimit = base.miterLimit
    var align = base.align
    var dashPattern = base.dashPattern
    var dashAlignAnchors = base.dashAlignAnchors
    var startArrow = base.startArrow
    var endArrow = base.endArrow
    var startArrowScale = base.startArrowScale
    var endArrowScale = base.endArrowScale
    var arrowAlign = base.arrowAlign
    switch group {
    case .width:
        width = committedWidth
    case .cap:
        switch strokePanelField(store, "cap") as? String {
        case "round": linecap = .round
        case "square": linecap = .square
        default: linecap = .butt
        }
    case .join:
        switch strokePanelField(store, "join") as? String {
        case "round": linejoin = .round
        case "bevel": linejoin = .bevel
        default: linejoin = .miter
        }
    case .miterLimit:
        miterLimit = strokePanelNumber(store, "miter_limit") ?? 10.0
    case .align:
        switch strokePanelField(store, "align_stroke") as? String {
        case "inside": align = .inside
        case "outside": align = .outside
        default: align = .center
        }
    case .dash:
        let dashed = strokePanelField(store, "dashed") as? Bool ?? false
        var pattern: [Double] = []
        if dashed {
            pattern = [strokePanelNumber(store, "dash_1") ?? 12.0,
                       strokePanelNumber(store, "gap_1") ?? 12.0]
            if let d2 = strokePanelNumber(store, "dash_2"),
               let g2 = strokePanelNumber(store, "gap_2") {
                pattern.append(contentsOf: [d2, g2])
            }
            if let d3 = strokePanelNumber(store, "dash_3"),
               let g3 = strokePanelNumber(store, "gap_3") {
                pattern.append(contentsOf: [d3, g3])
            }
        }
        dashPattern = pattern
        dashAlignAnchors = strokePanelField(store, "dash_align_anchors") as? Bool ?? false
    case .startArrow:
        startArrow = Arrowhead(
            fromString: strokePanelField(store, "start_arrowhead") as? String ?? "none")
    case .endArrow:
        endArrow = Arrowhead(
            fromString: strokePanelField(store, "end_arrowhead") as? String ?? "none")
    case .arrowScales:
        startArrowScale = strokePanelNumber(store, "start_arrowhead_scale") ?? 100.0
        endArrowScale = strokePanelNumber(store, "end_arrowhead_scale") ?? 100.0
    case .arrowAlign:
        arrowAlign = (strokePanelField(store, "arrow_align") as? String)
            == "center_at_end" ? .centerAtEnd : .tipAtEnd
    case .profile:
        // The profile lives in the element's width points, not the Stroke.
        break
    }
    return Stroke(color: base.color, width: width, linecap: linecap,
                  linejoin: linejoin, miterLimit: miterLimit, align: align,
                  dashPattern: dashPattern, dashAlignAnchors: dashAlignAnchors,
                  startArrow: startArrow, endArrow: endArrow,
                  startArrowScale: startArrowScale, endArrowScale: endArrowScale,
                  arrowAlign: arrowAlign, opacity: base.opacity)
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
