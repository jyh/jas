/// The APP-level default paint — the tier BELOW the per-document
/// ``Model/defaultFill`` / ``Model/defaultStroke``.
///
/// Fill and stroke defaults are WORKSPACE state, not document state: they
/// belong with the brush size and the active tool. Set a red, hit File > New,
/// and you are mid-flow and expect red — nobody thinks of "current fill" as a
/// property of the file. So the tier cannot live on a ``Model``, of which this
/// port has one PER CANVAS: it lives on ``WorkspaceState``, above the canvases,
/// exactly where Rust keeps `AppState.app_default_fill` above its tabs
/// (JYH ruling, 2026-07-26 — COLORTIERS).
///
/// Every ``Model`` holds a reference to one of these (``Model/appDefaults``)
/// and reads / writes it through ``Model/appDefaultFill`` /
/// ``Model/appDefaultStroke``, so the tier is reachable from the places that
/// only ever get a model: the panel-render reader ``liveFillStrokeValues`` and
/// the colour writers (``applyActiveColorWrite``, the `set_active_color_none`
/// intercept). ``WorkspaceState`` installs ITS instance into every canvas it
/// adopts, which is what makes the tier shared rather than per-canvas.
///
/// A bare ``Model`` gets its OWN instance, seeded white / black exactly as a
/// cold launch is. That keeps a model constructed outside the workspace (a
/// unit test, the throwaway model the toolbar renders against when no document
/// is open) self-contained instead of reaching into global mutable state.
import Foundation

public final class AppDefaults {
    /// Seeded WHITE, mirroring Rust's `AppState::new` (`app_default_fill:
    /// Some(Fill::new(Color::WHITE))`). A `nil` here is a real answer — the
    /// user chose None with nothing selected — not "unset".
    public var fill: Fill? = Fill(color: .white)
    /// Seeded BLACK, mirroring Rust's `app_default_stroke`.
    public var stroke: Stroke? = Stroke(color: .black)

    public init() {}
}
