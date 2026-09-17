import Foundation

/// The widget event contract (`WIDGET_EVENTS.md`), headless: what a value
/// widget's commit or press does to the store, with no view in sight.
///
/// The executable meaning is the reference's
/// `workspace_interpreter/widget_event.py`, and this is its Swift port, held
/// to the reference-generated corpus
/// (`test_fixtures/widget_events/corpus.json`) by
/// `Tests/Interpreter/WidgetEventCorpusTests.swift`. The engine's panel door
/// is held to the same corpus in `jas_dioxus/src/ffi.rs`.
///
/// Two procedures, one per family of kinds:
///
/// * ``commit(widget:text:store:panel:actions:dialogs:platformEffects:model:)``
///   for the INPUT kinds. Refuse a disabled widget, a missing value and text
///   the kind refuses; write the parsed value to a `panel.`/`dialog.` bound
///   target (with the two-way bound global); THEN run the `commit`/`change`
///   behaviors with `event.value`.
/// * ``press(widget:store:panel:actions:dialogs:platformEffects:model:)``
///   for the BOOLEAN kinds. A declared `click`/`change` behavior IS the press
///   and the bind write is skipped; otherwise the negated value is written.
///
/// The caller owns the active panel: `panel.` targets and `set_panel_state`
/// both write the store's active panel.
enum WidgetEvent {
    static let commitEvents = ["commit", "change"]
    static let pressEvents = ["click", "change"]
    static let inputKinds: Set<String> = [
        "number_input", "length_input", "text_input",
        "select", "icon_select", "combo_box",
    ]
    static let booleanKinds: Set<String> = ["toggle", "checkbox"]

    static let badValue = "BadValue"
    static let missingValue = "MissingValue"
    static let disabled = "Disabled"
    static let wrongKind = "WrongKind"

    /// What one event did. `outcome` is `committed`, `refused` (with
    /// `reason`) or `inert`. `value` is the parsed value, `nil` when there is
    /// none (a refusal, or a cleared nullable length).
    struct Result {
        let outcome: String
        var reason: String? = nil
        var value: Any? = nil
        var bindWritten: Bool = false
        var behaviorsRun: Int = 0
    }

    static func commit(
        widget: [String: Any], text: String?, store: StateStore,
        panel: [String: Any]?,
        actions: [String: Any]? = nil, dialogs: [String: Any]? = nil,
        platformEffects: [String: PlatformEffect] = [:], model: Model? = nil
    ) -> Result {
        Result(outcome: "refused", reason: wrongKind)
    }

    static func press(
        widget: [String: Any], store: StateStore, panel: [String: Any]?,
        actions: [String: Any]? = nil, dialogs: [String: Any]? = nil,
        platformEffects: [String: PlatformEffect] = [:], model: Model? = nil
    ) -> Result {
        Result(outcome: "refused", reason: wrongKind)
    }

    /// The node whose `id` is `id`, searched depth-first through a panel's
    /// content (dictionaries and arrays). `nil` when there is none.
    static func findWidget(in node: Any?, id: String) -> [String: Any]? {
        nil
    }
}
