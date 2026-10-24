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
        // The paragraph dialogs' OK (PARAGRAPH.md §Justification Dialog,
        // §Hyphenation Dialog) writes the fields to the selection's paragraph
        // wrappers HERE, before the action's YAML clears the preview snapshot
        // and closes the dialog: an intercept, as the engine's
        // `panel_behavior` does. Until 2026-10-24 nothing called these two
        // apply functions, so OK on the Mac closed and wrote nothing.
        if actionName == "paragraph_justification_confirm" {
            applyJustificationDialogToSelection(justificationValues(m.stateStore),
                                                controller: Controller(model: m))
        } else if actionName == "paragraph_hyphenation_confirm" {
            applyHyphenationDialogToSelection(hyphenationValues(m.stateStore),
                                              controller: Controller(model: m), store: m.stateStore)
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

    /// The open dialog's fields by their dialog keys; a null or absent field
    /// is blank (the paragraphs differ) and writes nothing. Rust
    /// `paragraph_host::JustificationDialogValues::from_dialog`.
    static func justificationValues(_ store: StateStore) -> JustificationDialogValues {
        let f = { (k: String) in dialogNumber(store.getDialog(k)) }
        return JustificationDialogValues(
            wordSpacingMin: f("word_spacing_min"), wordSpacingDesired: f("word_spacing_desired"),
            wordSpacingMax: f("word_spacing_max"),
            letterSpacingMin: f("letter_spacing_min"), letterSpacingDesired: f("letter_spacing_desired"),
            letterSpacingMax: f("letter_spacing_max"),
            glyphScalingMin: f("glyph_scaling_min"), glyphScalingDesired: f("glyph_scaling_desired"),
            glyphScalingMax: f("glyph_scaling_max"),
            autoLeading: f("auto_leading"),
            singleWordJustify: store.getDialog("single_word_justify") as? String)
    }

    /// Rust `paragraph_host::HyphenationDialogValues::from_dialog`.
    static func hyphenationValues(_ store: StateStore) -> HyphenationDialogValues {
        let f = { (k: String) in dialogNumber(store.getDialog(k)) }
        let b = { (k: String) in dialogBool(store.getDialog(k)) }
        return HyphenationDialogValues(
            hyphenate: b("hyphenate"),
            minWord: f("hyphenate_min_word"), minBefore: f("hyphenate_min_before"),
            minAfter: f("hyphenate_min_after"), limit: f("hyphenate_limit"),
            zone: f("hyphenate_zone"), bias: f("hyphenate_bias"),
            capitalized: b("hyphenate_capitalized"))
    }

    /// A number, never a bool (an NSNumber can be either; JSON's are distinct).
    private static func dialogNumber(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, !isBoolNumber(n) else { return nil }
        return n.doubleValue
    }

    private static func dialogBool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, isBoolNumber(n) else { return nil }
        return n.boolValue
    }

    private static func isBoolNumber(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
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
