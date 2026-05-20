/// Selection → Color panel mirror.
///
/// Mirrors the Rust `build_live_panel_overrides` color block. When the
/// Color panel renders, its slider / hex values should reflect the
/// selection's fill (or stroke per `fillOnTop`) — without this the
/// panel keeps showing whatever values were stored at the last write,
/// so selecting a differently-colored shape leaves the sliders stale.
///
/// Resolution: selection's uniform fill / stroke → tab default → app
/// default. Returns `nil` when nothing resolves (panel falls back to
/// stored panel state).

import Foundation

public func colorPanelLiveOverrides(model: Model) -> [String: Any]? {
    let resolved: Color? = {
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
    guard let color = resolved else { return nil }

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
