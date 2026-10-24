import Foundation

/// The Mac dialog overlay's acts on the store, lifted out of
/// ``YamlDialogView`` (2026-10-24) so the dialog action corpus
/// (`test_fixtures/dialog_actions/`) drives the code the overlay runs, not a
/// copy of it. The view keeps its SwiftUI binding sync; everything that
/// touches the store or the document is here.
enum DialogWidgetActions {
    /// A widget's `params`, each string evaluated against the widget's render
    /// context (`params: { angle: "dialog.angle" }` sends the typed angle). A
    /// value that evaluates to null is dropped, as the view always did.
    static func resolveParams(_ raw: [String: Any], context: [String: Any]) -> [String: Any] {
        var resolved: [String: Any] = [:]
        for (k, v) in raw {
            if let exprStr = v as? String {
                if let any = evaluate(exprStr, context: context).toAny() {
                    resolved[k] = any
                }
            } else {
                resolved[k] = v
            }
        }
        return resolved
    }

    /// Run a dialog widget's node-level `action` with its resolved params.
    /// `dismiss_dialog` (Cancel) is the `close_dialog` effect, so a preview the
    /// dialog drew is put back (`doc.preview.restore`) as the engine's
    /// `close_dialog_in` does; until 2026-10-24 it was the store's bare
    /// `closeDialog()`, which left a live preview on the canvas. Any other
    /// action runs through ``LayersPanel/dispatchYamlAction``. Returns true
    /// when no dialog is open afterwards.
    @discardableResult
    static func run(_ actionName: String, params: [String: Any], model m: Model) -> Bool {
        if actionName == "dismiss_dialog" {
            runEffects([["close_dialog": NSNull()]], ctx: [:], store: m.stateStore,
                       platformEffects: buildYamlToolEffects(model: m), model: m)
            return m.stateStore.getDialogId() == nil
        }
        let abSel = (m.stateStore.getPanelState("artboards")["artboards_panel_selection"] as? [Any])?
            .compactMap { $0 as? String } ?? []
        LayersPanel.dispatchYamlAction(
            actionName, model: m,
            artboardsPanelSelection: abSel,
            params: params
        )
        return m.stateStore.getDialogId() == nil
    }

    /// Write a dialog-body widget's bound `dialog.<key>`: through the store's
    /// setter (which runs a field's YAML `set` lambda), then the Color
    /// Picker's "Only Web Colors" snap.
    static func write(_ key: String, _ value: Any?, store: StateStore) {
        store.setDialog(key, value)
        // Color picker "Only Web Colors": when toggled on, snap each
        // RGB channel to multiples of 51 (0/51/102/153/204/255). The
        // r/g/bl setters route through the YAML lambdas which rebuild
        // dialog.color, so subsequent reads of h/s/b/r/g/bl/c/m/y/k/hex
        // see the snapped value.
        if key == "web_only", let on = value as? Bool, on {
            // Rust clamps BEFORE its cast here (`v.clamp(0.0, 255.0) as i64`,
            // renderer.rs) and this port clamped after; the inputs are the
            // 0...255 r/g/bl getters so the two agree today, but the shape is
            // risk R9's and saturatingInt removes it either way.
            func snap(_ v: Int) -> Int {
                let n = (Double(v) / 51.0).rounded() * 51.0
                return min(max(saturatingInt(n), 0), 255)
            }
            func ival(_ k: String) -> Int {
                if let any = store.getDialog(k) {
                    if let i = any as? Int { return i }
                    if let d = any as? Double { return saturatingInt(d.rounded()) }
                }
                return 0
            }
            store.setDialog("r", snap(ival("r")))
            store.setDialog("g", snap(ival("g")))
            store.setDialog("bl", snap(ival("bl")))
        }
    }
}
