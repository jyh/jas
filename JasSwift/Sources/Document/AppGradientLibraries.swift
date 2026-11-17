import Foundation

/// The gradient libraries the artist can EDIT, app-global (design 2026-11-17
/// §1): the twin of jas_dioxus's `AppState.gradient_libraries`, and of
/// ``AppSwatchLibraries``, whose header says why the tier is app-global and
/// not per-`Model` (a per-canvas copy would fork per tab).
///
/// `{ library_id: { "name", "description", "gradients": [...] } }`, the
/// untyped JSON shape `workspace.json` ships, which the Gradient panel's YAML
/// reads as `data.gradient_libraries`.
public final class AppGradientLibraries {
    public var libs: [String: Any]

    /// Seeded from the shipped bundle, with the user's saved libraries (Save
    /// Gradient Library) shadowing it by id when the app installed a live
    /// store, never under test.
    public init(seed: [String: Any]? = nil) {
        self.libs = seed ?? Self.shippedSeed()
    }

    public static func shippedSeed() -> [String: Any] {
        let libs = (WorkspaceData.load()?.data["gradient_libraries"] as? [String: Any]) ?? [:]
        return BrushLibraryStore.live.map { BrushLibraryStore.merged(bundle: libs, user: $0.loadGradients()) } ?? libs
    }
}
