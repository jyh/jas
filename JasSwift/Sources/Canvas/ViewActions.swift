import Foundation

/// The ONE seam every user-facing invocation of a View-menu zoom / fit verb
/// goes through: the View menu (``JasCommands``), the canvas keyboard chords
/// (`CanvasSubwindow.keyDown`) and the toolbar tool-options double-click
/// (`ContentView.dispatchToolOptionsAction`).
///
/// WHY THIS TYPE EXISTS. Those three surfaces each carried their OWN `switch`
/// over the same six verb names, calling native `Model` methods with constants
/// hardcoded in Swift — zoom_step 1.2, min / max zoom 0.1 / 64.0, fit padding
/// 20.0 — while `workspace/actions.yaml` declares those verbs as `doc.zoom.*`
/// effects reading `preferences.viewport.*`. The action corpus gates the
/// EFFECTS, so a fix to `doc.zoom.set` turned the gate green and changed nothing
/// a user could see: the gate was testing a road nobody drove. The three
/// switches had also drifted from the workspace and from each other
/// (`fit_active_artboard` used `document.artboards.first` where actions.yaml
/// uses `active_document.current_artboard`, i.e. the topmost PANEL-SELECTED
/// artboard; the keyboard route had no `fit_in_window` arm at all).
///
/// Collecting them here is the precondition for testing them: none of the three
/// was callable from a test — each is a `private func` on a SwiftUI view or an
/// AppKit responder — which is why the divergence lived this long.
///
/// RULED 2026-07-27 (transcripts/ZOOM_TOOL.md, "Swift's MENU AND KEYBOARD must
/// route through the YAML pipeline"): the body below must dispatch the YAML
/// action. It does NOT yet — this revision is the verbatim extraction of the
/// three native switches into one seam, so ``ViewActionRouteTests`` can show the
/// divergence as a measured red before the routing changes underneath it.
/// The `StateStore` scope the Artboards panel's own state lives in. `set_panel_state
/// { panel: artboards }` normalises the short workspace name to this content id, and
/// the panel body renders from it, so it is where `artboards_panel_select` puts the
/// selection.
///
/// KNOWN, NOT FIXED HERE: four Swift sites read or write the UN-suffixed
/// `"artboards"` bucket instead — `ContentView.buildDialogOuterScope`,
/// `ArtboardsPanel.dispatch`, `YamlDialogView`, and the Artboard TOOL's writes in
/// `YamlToolEffects`. Those are a different bucket entirely (`StateStore` does no
/// normalisation on read), so a panel row-click and a canvas artboard click record
/// their selection in two places that cannot see each other. Rust has one bucket
/// (`AppState.artboards_panel_selection`). Naming the canonical scope here rather
/// than joining the split; the four sites are banked as their own item.
let artboardsPanelScope = "artboards_panel_content"

public enum ViewActions {
    /// The six verbs this seam owns — the View > Zoom / Fit group of
    /// `workspace/actions.yaml`. Named as data so a test can enumerate the
    /// route instead of trusting a list in prose.
    public static let names: [String] = [
        "zoom_in",
        "zoom_out",
        "zoom_to_actual_size",
        "fit_active_artboard",
        "fit_all_artboards",
        "fit_in_window",
    ]

    /// True when `name` is one of the six verbs above.
    public static func owns(_ name: String) -> Bool { names.contains(name) }

    /// Dispatch a View verb against `model`.
    public static func dispatch(_ name: String, model: Model) {
        switch name {
        case "zoom_in": model.zoomIn()
        case "zoom_out": model.zoomOut()
        case "zoom_to_actual_size": model.zoomToActualSize()
        case "fit_active_artboard": model.fitActiveArtboard()
        case "fit_all_artboards": model.fitAllArtboards()
        case "fit_in_window": model.fitInWindow()
        default: break
        }
    }
}
