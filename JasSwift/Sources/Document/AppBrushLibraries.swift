import Foundation

/// The brush libraries the artist can EDIT, app-global (STATUS-jas row 59).
///
/// jas_dioxus holds them on `AppState.brush_libraries`, ONE value shared
/// across every tab. From #649 the Mac kept them in each canvas's
/// `stateStore`, which is one per canvas (`Model.swift`), so a brush edited
/// in one tab was not seen in the next: the per-tab fork that
/// ``AppSwatchLibraries`` names as the wrong home for libraries.
///
/// The workspace owns one instance and installs it into every adopted
/// canvas's store (``StateStore/sharedBrushLibraries``); the store then reads
/// and writes its `data.brush_libraries` HERE, and the rest of `data` stays
/// its own. A bare `Model` (a test, a headless path) has no tier installed and
/// keeps its own seed, as before.
public final class AppBrushLibraries {
    /// `{ library_id: { "name": String, "brushes": [ {...} ] } }`, untyped for
    /// the reason ``AppSwatchLibraries/libs`` gives. LAZY, so the seed reads
    /// the app's user-library store (``BrushLibraryStore/live``) as installed
    /// when the libraries are first used, not when the workspace was built.
    public lazy var libs: [String: Any] = Self.shippedSeed()

    public init() {}

    /// The bundle's brush libraries, with the user's saved libraries
    /// shadowing them by slug when the app installed a live store (never
    /// under test). The engine's `panel_scope::seed_library_data` seeds the
    /// same way.
    public static func shippedSeed() -> [String: Any] {
        guard let libs = WorkspaceData.load()?.brushLibraries() else { return [:] }
        return BrushLibraryStore.live.map { BrushLibraryStore.merged(bundle: libs, user: $0.load()) } ?? libs
    }
}
