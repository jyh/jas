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

/// The active paint's colour, resolved through the three tiers: the
/// selection's uniform fill / stroke → the per-document default → the app
/// default. `nil` when none of the three resolves.
///
/// Mirrors the `st.tab().and_then { … }.or_else { st.app_default_fill … }`
/// chain in Rust's `build_live_panel_overrides`, including the fall-through on
/// an explicit `Uniform(None)`.
public func resolveActivePaintColor(model: Model) -> Color? {
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
    return fromDocument ?? fromAppTier
}

public func colorPanelLiveOverrides(model: Model) -> [String: Any]? {
    guard let color = resolveActivePaintColor(model: model) else { return nil }

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

// MARK: - The Color panel's WRITE path reads the same overlay

/// The channel map a Color-panel write computes from: the stored panel state
/// with ``colorPanelLiveOverrides`` laid over it, EXCEPT for `edited` — the one
/// channel whose stored value is what the user just dragged or typed.
///
/// This is the Swift twin of what Rust's write path is handed. There, a
/// slider's `oninput` / `onchange` and a value box's `onchange` all pass
/// `ctx.get("panel")` — the panel-defaults map ALREADY overlaid by
/// `build_live_panel_overrides` — into `compute_color_from_panel`, whose `pf`
/// closure substitutes the new value for the edited field
/// (`if name == field { return new_val }`); the `edited` exclusion here is that
/// substitution, expressed against a store the caller has already written.
///
/// Why it matters: without the overlay the write path was a SECOND reader of
/// the active paint with no app tier, so after File > New (fresh per-document
/// tier, colour held above the canvases) the panel DISPLAYED the app tier's red
/// while a Brightness drag on that same panel mixed with `color.yaml`'s stored
/// white and committed mid grey — COLORTIERS repair 2.
public func colorPanelWriteScope(
    store: StateStore, model: Model, edited: String?
) -> [String: Any] {
    var scope = store.getPanelState("color_panel_content")
    if let overrides = colorPanelLiveOverrides(model: model) {
        for (k, v) in overrides where k != edited { scope[k] = v }
    }
    return scope
}

/// The colour a Color-panel channel write commits, read off `panel`'s `mode`
/// and that mode's channels. `nil` for a mode this function does not know.
///
/// Mirror of Rust `compute_color_from_panel` (renderer.rs), arm for arm and
/// including the `unwrap_or(0.0)` on a missing channel. The HSB arm goes
/// through ``hsbToRgb`` — the same c / x / m form as Rust's `hsb_to_rgb`,
/// quantised to 8 bits the same way — so both ports store the same RGB for a
/// given channel triple. (This arm used to build `Color.hsb` instead, which
/// keeps the h / s / b it was handed; Rust has only the RGB.)
public func colorFromColorPanelScope(_ panel: [String: Any]) -> Color? {
    func num(_ key: String) -> Double {
        (panel[key] as? Double)
            ?? (panel[key] as? Int).map { Double($0) }
            ?? 0
    }
    // Channels are stored in the YAML's units (hue 0–360, r/g/bl 0–255,
    // everything else 0–100); `Color` wants 0–1 (and hue in degrees).
    switch (panel["mode"] as? String) ?? "hsb" {
    case "grayscale":
        let k = num("k") / 100.0
        return Color.rgb(r: 1.0 - k, g: 1.0 - k, b: 1.0 - k, a: 1.0)
    case "rgb", "web_safe_rgb":
        return Color.rgb(r: num("r") / 255.0, g: num("g") / 255.0,
                         b: num("bl") / 255.0, a: 1.0)
    case "cmyk":
        let c = num("c") / 100.0, mk = num("m") / 100.0
        let y = num("y") / 100.0, k = num("k") / 100.0
        return Color.rgb(r: (1.0 - c) * (1.0 - k), g: (1.0 - mk) * (1.0 - k),
                         b: (1.0 - y) * (1.0 - k), a: 1.0)
    case "hsb":
        let (r, g, b) = hsbToRgb(num("h"), num("s"), num("b"))
        return Color.rgb(r: Double(r) / 255.0, g: Double(g) / 255.0,
                         b: Double(b) / 255.0, a: 1.0)
    default:
        return nil
    }
}

/// The colour a Color-panel CHANNEL write commits: ``colorFromColorPanelScope``
/// over ``colorPanelWriteScope``.
///
/// Every channel write goes through here — a slider drag tick, a slider release,
/// a value box's Enter / blur — because all three land in
/// ``notifyPanelStateChanged``'s Color branch. Two Color-panel writes do NOT,
/// in either port, because neither is a channel: the hex field parses its own
/// string (a hex edit does not ripple back into the channels, so the channels
/// would answer with the previous colour) and the colour bar computes hue /
/// saturation / brightness from the pointer position.
public func colorPanelWriteColor(
    store: StateStore, model: Model, edited: String?
) -> Color? {
    colorFromColorPanelScope(
        colorPanelWriteScope(store: store, model: model, edited: edited))
}

/// The colour the Color panel MENU's Invert / Complement operate on, and the
/// one their enabled state tests: the per-document default, else the app
/// default.
///
/// Mirror of Rust `AppState::active_color()`. It differs from
/// ``resolveActivePaintColor`` in one deliberate way: the SELECTION is not
/// consulted. Neither port consults it here — both invert the DEFAULT paint
/// even with a shape selected — so this stays as narrow as Rust's, and the
/// question of whether it SHOULD read the selection is banked in COLOR_TESTS.md
/// rather than answered here.
///
/// Both ports greyed the two menu items out after File > New — the fresh
/// per-document tier is empty and the colour lives above the canvases — for
/// slightly different reasons: Rust's `active_color()` reached the app tier only
/// in the no-document branch, and this port did not reach it at all. Fixed
/// together, COLORTIERS repair 2.
///
/// A none reaches `nil` through the YAML None route, which clears BOTH tiers
/// (pinned by `colorPanelInvertStaysDisabledForAnExplicitNone`). The NATIVE
/// None buttons clear only the document tier, in both ports, so after one of
/// those this answers the app tier — the same answer the panel's own swatch and
/// sliders already give for that state, since they resolve the same two tiers.
/// That half-none is banked in COLOR_TESTS.md; it is not introduced here.
public func activeDefaultPaintColor(model: Model) -> Color? {
    let fromDocument: Color? = model.fillOnTop
        ? model.defaultFill?.color
        : model.defaultStroke?.color
    let fromAppTier: Color? = model.fillOnTop
        ? model.appDefaultFill?.color
        : model.appDefaultStroke?.color
    return fromDocument ?? fromAppTier
}
