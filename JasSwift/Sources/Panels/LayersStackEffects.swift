import Foundation

/// The platform routes for the document-owned lists an action writes under a
/// store-looking name: `panel.isolation_stack` is the DOCUMENT's
/// (`Model.layersIsolationStack`) and `active_document.recent_colors` is the
/// model's (`ColorPanel.pushRecentColor`). ONE copy, used by the Layers
/// panel's effect table AND the YAML tool's (`buildYamlToolEffects`), so
/// `enter_isolation_mode` / `exit_isolation_mode` dispatched from a TOOL
/// (G11, STATUS-jas row 73: the selection tool's canvas double-click) reach the
/// same stack as the panel's. Measured 2026-11-07 before this existed: a
/// tool-dispatched enter left the stack `[]` and an exit left `[[0, 0]]`,
/// while `zoom_in` from the same handler landed
/// (`YamlToolIsolationProbeTests`).
///
/// `list_push` has no generic store form in this runtime, so any other target
/// is a no-op as it was. `pop` does (`genericPop`), and a platform handler
/// REPLACES it, so every other target falls through to it rather than being
/// dropped.
func layersStackEffects(model: Model) -> [String: PlatformEffect] {
    let listPush: PlatformEffect = { value, callCtx, _ in
        guard let spec = value as? [String: Any] else { return nil }
        let target = (spec["target"] as? String) ?? ""
        guard let valueExpr = spec["value"] as? String else { return nil }
        if target == "panel.isolation_stack" {
            guard case .path(let indices) = evaluate(valueExpr, context: callCtx) else { return nil }
            model.layersIsolationStack.append(indices)
        } else if target == "active_document.recent_colors" {
            let hex: String?
            switch evaluate(valueExpr, context: callCtx) {
            case .color(let c): hex = c
            case .string(let s) where s.hasPrefix("#"): hex = s
            default: hex = nil
            }
            if let h = hex, !h.isEmpty {
                ColorPanel.pushRecentColor(h, model: model)
            }
        }
        return nil
    }
    let pop: PlatformEffect = { value, _, store in
        guard let target = value as? String else { return nil }
        if target == "panel.isolation_stack" {
            if !model.layersIsolationStack.isEmpty {
                _ = model.layersIsolationStack.removeLast()
            }
        } else {
            genericPop(target, store: store)
        }
        return nil
    }
    return ["list_push": listPush, "pop": pop]
}
