import Foundation

/// The swatch libraries the artist can EDIT, app-global.
///
/// WHY THIS EXISTS. `WorkspaceData` is the immutable, process-cached bundle
/// loaded from `workspace.json`; `DockPanelView.buildPanelCtx` re-read
/// `ws.swatchLibraries()` fresh on every render, so the Swatches panel could
/// only ever display the shipped libraries. Four of its five menu verbs — Sort
/// by Name, Add Used Colors, Delete Swatch, Duplicate Swatch — MUTATE a library,
/// and there was nowhere for a mutation to live. That is why they were Swift
/// no-ops against five working jas_dioxus verbs (council O1.3, 2026-07-30).
///
/// APP-GLOBAL, NOT PER-DOCUMENT, and that is the whole design decision.
/// jas_dioxus holds these on `AppState.swatch_libraries`, which is shared across
/// every open tab: edit a swatch while working on one drawing and the change is
/// there in the next. `Model.stateStore` is the tempting home and it is WRONG —
/// it is one per canvas (`Model.swift`), so libraries stashed there would fork
/// per tab and silently diverge from Rust in a way every unit test would pass.
///
/// So this follows the ratified `AppDefaults` precedent exactly (the COLORTIERS
/// ruling, 2026-07-26): a reference class owned by `WorkspaceState`, installed
/// into every adopted `Model`, with a standalone instance as the default so a
/// bare `Model` in a test or a headless path still works.
public final class AppSwatchLibraries {
    /// `{ library_id: { "name": String, "swatches": [ {...} ] } }` — the same
    /// untyped JSON shape `workspace.json` ships and the YAML renderer reads,
    /// deliberately: the panel binds `data.swatch_libraries[lib.id].swatches`
    /// through the generic expression evaluator, so typing this into a Swift
    /// struct would mean maintaining a second schema that the YAML could
    /// silently outgrow. jas_dioxus keeps it as `serde_json::Value` for the
    /// same reason.
    public var libs: [String: Any]

    /// Seeded from the shipped bundle, so an untouched app shows exactly what
    /// `workspace.json` declares — matching Rust, which seeds
    /// `AppState::swatch_libraries` from the same source.
    public init(seed: [String: Any]? = nil) {
        self.libs = seed ?? (WorkspaceData.load()?.swatchLibraries() ?? [:])
    }

    /// The mutable swatch array of one library, or nil when the id is unknown
    /// or the library has no `swatches` key.
    ///
    /// Read-modify-write through this accessor rather than mutating in place:
    /// `libs` is `[String: Any]`, so a nested `[[String: Any]]` fetched out of
    /// it is a VALUE COPY. Mutating that copy and forgetting to store it back
    /// is a silent no-op, and it is the single easiest way to write a verb that
    /// passes every test and changes nothing on screen.
    public func swatches(of libraryId: String) -> [[String: Any]]? {
        (libs[libraryId] as? [String: Any])?["swatches"] as? [[String: Any]]
    }

    /// Store a swatch array back into a library. Paired with ``swatches(of:)``.
    public func setSwatches(_ swatches: [[String: Any]], of libraryId: String) {
        guard var lib = libs[libraryId] as? [String: Any] else { return }
        lib["swatches"] = swatches
        libs[libraryId] = lib
    }
}
