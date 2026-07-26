/// Selection → Color panel mirror.
///
/// Mirrors the Rust `build_live_panel_overrides` color block. When the
/// Color panel renders, its slider / hex values should reflect the
/// selection's fill (or stroke per `fillOnTop`) — without this the
/// panel keeps showing whatever values were stored at the last write,
/// so selecting a differently-colored shape leaves the sliders stale.
///
/// Resolution, tier for tier with Rust: the selection's uniform fill /
/// stroke → the per-document default → the APP default. Returns `nil`
/// only when none of the three resolves, and then the panel falls back
/// to its stored state.
///
/// The app tier is the whole reason this comment exists. This reader
/// used to stop at the per-document default, which was unreachable
/// while that tier was reseeded per canvas — and became reachable the
/// moment the app tier moved above the canvases (COLORTIERS): set a red
/// with nothing selected, File > New, and the new canvas's own tier is
/// empty while the app tier holds red. Rust answered red, this port
/// answered "nothing resolved" and the sliders / hex showed
/// `color.yaml`'s stored 255/255/255 — beside a fill swatch, one reader
/// away, painting red. One fact must have one answer.
///
/// An explicit None (`Uniform(nil)`) yields nothing from the document
/// tiers and so falls THROUGH to the app tier, matching Rust's
/// `and_then` → `.or_else` chain exactly. Nothing a user reads changes:
/// `color.yaml`'s slider / hex / colour-bar `disabled` guards test
/// `state.fill_color == null` and disable the controls regardless. But
/// the numbers the disabled controls hold are the same numbers in both
/// ports, which is what the prime directive asks.

import Foundation

public func colorPanelLiveOverrides(model: Model) -> [String: Any]? {
    // The two document-owned tiers: the selection, else the per-document
    // default. Mirrors Rust's `st.tab().and_then { … }`.
    let fromDocument: Color? = {
        if model.fillOnTop {
            switch selectionFillSummary(model.document) {
            case .uniform(let f?): return f.color
            case .uniform(nil): return nil
            default: return model.defaultFill?.color
            }
        } else {
            switch selectionStrokeSummary(model.document) {
            case .uniform(let s?): return s.color
            case .uniform(nil): return nil
            default: return model.defaultStroke?.color
            }
        }
    }()
    // …and Rust's `.or_else(|| st.app_default_fill … )`.
    let fromAppTier: Color? = model.fillOnTop
        ? model.appDefaultFill?.color
        : model.appDefaultStroke?.color
    guard let color = fromDocument ?? fromAppTier else { return nil }

    let (rf, gf, bf, _) = color.toRgba()
    let r = Int((rf * 255.0).rounded())
    let g = Int((gf * 255.0).rounded())
    let b = Int((bf * 255.0).rounded())
    let (h, s, br, _) = color.toHsba()

    // CMYK from RGB (same convention as ColorPanel.seedSliders).
    let rN = rf, gN = gf, bN = bf
    let kN = 1.0 - max(rN, max(gN, bN))
    let cN = (kN < 1.0) ? (1.0 - rN - kN) / (1.0 - kN) : 0
    let mN = (kN < 1.0) ? (1.0 - gN - kN) / (1.0 - kN) : 0
    let yN = (kN < 1.0) ? (1.0 - bN - kN) / (1.0 - kN) : 0

    return [
        "r": r,
        "g": g,
        "bl": b,
        "h": Int(h.rounded()),
        "s": Int((s * 100.0).rounded()),
        "b": Int((br * 100.0).rounded()),
        "c": Int((cN * 100.0).rounded()),
        "m": Int((mN * 100.0).rounded()),
        "y": Int((yN * 100.0).rounded()),
        "k": Int((kN * 100.0).rounded()),
        "hex": String(format: "%02x%02x%02x", r, g, b),
    ]
}
