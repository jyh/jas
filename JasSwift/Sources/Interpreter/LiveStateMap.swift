/// The panel-render `state.*` scope.
///
/// A panel body is rendered against an eval context whose `state` namespace
/// starts from the STATIC workspace defaults (`workspace/state.yaml`). That is
/// the right starting point — it names every key and gives each a value — but
/// the app-level facts inside it are LIVE, and a panel that renders the static
/// default for one of them renders against a fact the user already changed.
///
/// This is the reader half of the fill/stroke contract. The writer half is
/// spread across the action dispatchers (`set: { fill_color: … }` through
/// `applyActiveColorWrite`, and the `set_active_color_none` native arm in
/// ``YamlPanelBodyView``), and all of them land the fact on the MODEL:
/// `model.defaultFill` / `model.defaultStroke`, plus the selection itself.
/// So the reader resolves from the model, never from the store mirror.
///
/// Mirrors the Rust dock's `build_live_state_map` (jas_dioxus
/// workspace/dock_panel.rs), which overlays the same three keys onto the same
/// workspace defaults.

import Foundation

/// The live `state.fill_color` / `state.stroke_color` VALUES, resolved from the
/// active selection's fill / stroke summary and falling back to the model's
/// default fill / stroke.
///
/// Three outcomes, and the middle one is the whole point:
///
/// * `"#rrggbb"` — one colour is in force.
/// * `NSNull()` — the attribute is explicitly NONE. This must be PUBLISHED,
///   not omitted: the caller starts from the workspace defaults
///   (`fill_color: "#ffffff"`), so omitting the key leaves WHITE standing.
///   That is how the Color panel's None controls came to clear the fill and
///   move nothing a user could see — `color.yaml`'s fifteen slider `disabled`
///   guards, the hex field (`cp_hex_input`) and the colour bar
///   (`cp_color_bar`, honoured in ``YamlPanelBodyView/renderColorBar``) all
///   test `state.fill_color == null`, and so do the panel-menu
///   `enabled_when`s on Invert / Complement. Against a static `"#ffffff"`
///   that comparison can never be true (CPTRIAGE).
/// * `nil` — no single value (a MIXED selection). Leave the caller's existing
///   value in place; a panel cannot show one colour for many.
///
/// With NOTHING selected the answer is the default paint, resolved down two
/// tiers — the per-document ``Model/defaultFill`` (seeded `nil`) and then the
/// app-level ``Model/appDefaultFill`` (seeded WHITE) — mirroring Rust's
/// `tab.model.default_fill.or(st.app_default_fill)`. Only when BOTH are absent
/// is the answer None, which is what keeps a fresh launch's live controls live
/// and still lets a user's explicit None reach the panel: the YAML colour
/// routes clear both tiers together (see ``Model/appDefaultFill``).
///
/// This is the SINGLE SOURCE for the fact. Both readers call it — the panel
/// scope through ``liveAppStateOverrides``, and the per-tool bridge through
/// ``YamlTool/syncAppState`` — because they must not be able to answer one fact
/// two ways: the bridge used to map a `nil` default to `"#ffffff"` on its own,
/// so a cleared fill was None to the panel and white to the next tool commit.
/// Mirrors Rust, where `build_live_state_map` and `build_tool_state_map` share
/// `live_fill_stroke_values` for the same reason.
///
/// Mirrors Rust's `live_fill_stroke_values` outcome-for-outcome. Swift's
/// evaluator is ctx-only (``evaluate(_:context:)`` never consults the store),
/// so nothing downstream can rescue an unpublished null — the overlay is the
/// only chance.
///
/// RENDERING the explicit none agrees too, as of COLORTIERS:
/// ``YamlPanelBodyView/renderColorSwatch`` draws the red-diagonal no-paint
/// indicator and decides none-from-empty-slot by the bind's own declaration
/// (``nullColorMeansNone``), key-for-key with Rust's `render_color_swatch` /
/// `null_color_means_none`. It used to send every non-colour value to `.clear`,
/// so an explicit None and an empty recent-colour slot were the same square.
public func liveFillStrokeValues(model: Model?) -> (fill: Any?, stroke: Any?) {
    guard let model = model else { return (nil, nil) }
    let fill: Any? = {
        switch selectionFillSummary(model.document) {
        case .uniform(let f?): return "#" + f.color.toHex()
        case .uniform(nil): return NSNull()
        case .mixed: return nil
        case .noSelection:
            let paint = model.defaultFill ?? model.appDefaultFill
            return paint.map { "#" + $0.color.toHex() } ?? NSNull()
        }
    }()
    let stroke: Any? = {
        switch selectionStrokeSummary(model.document) {
        case .uniform(let s?): return "#" + s.color.toHex()
        case .uniform(nil): return NSNull()
        case .mixed: return nil
        case .noSelection:
            let paint = model.defaultStroke ?? model.appDefaultStroke
            return paint.map { "#" + $0.color.toHex() } ?? NSNull()
        }
    }()
    return (fill, stroke)
}

/// The fill / stroke fact typed for a NATIVE swatch to draw: a colour, or
/// `nil` for "no paint" (the red-diagonal indicator).
///
/// Same three outcomes as ``liveFillStrokeValues`` — which it calls, so this is
/// not a second opinion — with the third resolved the way every other reader
/// resolves it: a MIXED selection publishes nothing, so the DECLARED
/// `workspace/state.yaml` default stands, exactly as it stands in the map
/// ``buildLiveStateMap`` composes for the panel scope.
///
/// ``FillStrokeWidget`` used to resolve `selection ?? model.defaultFill` on its
/// own — no app tier — so a cold launch drew the NO-PAINT indicator on the
/// toolbar while the Color panel showed white, and after the app tier moved
/// above the canvases (COLORTIERS) a File > New would not have carried the
/// user's colour into the widget at all.
func liveSwatchPaint(model: Model?, isFill: Bool) -> Color? {
    let key = isFill ? "fill_color" : "stroke_color"
    let live = liveFillStrokeValues(model: model)
    let value = isFill ? live.fill : live.stroke
    if let hex = value as? String { return Color.fromHex(hex) }
    if value is NSNull { return nil }
    // MIXED (or no model at all): nothing is published, so the DECLARED
    // default stands — the same composition `buildLiveStateMap` performs,
    // resolved for one key so the toolbar's redraw path does not rebuild the
    // whole defaults map twice per frame.
    guard let hex = WorkspaceData.load()?.stateDefaults()[key] as? String
    else { return nil }
    return Color.fromHex(hex)
}

/// The LIVE app-level `state.*` keys, as an overlay to merge over the workspace
/// defaults. Keys absent from the result mean "keep what the caller has".
///
/// `fill_on_top` rides along because it is what SELECTS which colour every
/// guard reads (`if state.fill_on_top then state.fill_color == null else
/// state.stroke_color == null`). Publishing the colours while leaving the
/// selector static would half-fix the guard: swap to stroke-on-top and the
/// Color panel would still disable on the FILL. Rust's `build_live_state_map`
/// overlays it for the same reason.
public func liveAppStateOverrides(model: Model?) -> [String: Any] {
    guard let model = model else { return [:] }
    var out: [String: Any] = ["fill_on_top": model.fillOnTop]
    let (fill, stroke) = liveFillStrokeValues(model: model)
    if let fill = fill { out["fill_color"] = fill }
    if let stroke = stroke { out["stroke_color"] = stroke }
    return out
}

/// The panel-render `state.*` scope: the workspace defaults with
/// ``liveAppStateOverrides`` merged over them.
///
/// One function so the render path and the conformance corpus read the same
/// composition — the corpus's `expected_panel_state` block calls THIS, so a
/// port that stops overlaying reds the shared gate rather than quietly
/// rendering stale controls. Mirrors Rust `build_live_state_map`.
///
/// Internal, not public: ``WorkspaceData`` is internal, and every caller (the
/// dock render path, the corpus's `@testable` arm) is in-module.
func buildLiveStateMap(ws: WorkspaceData, model: Model?) -> [String: Any] {
    var m = ws.stateDefaults()
    for (k, v) in liveAppStateOverrides(model: model) { m[k] = v }
    return m
}

/// The `state` scope a DIALOG opens against — ``buildLiveStateMap`` with the
/// bundle loaded for the caller.
///
/// A dialog's `init:` expressions read `state.fill_color` (the colour picker
/// seeds its channels from it; the Swatch Options dialog seeds a new swatch
/// from it), so it wants the same live fact the panels render against. The two
/// opening sites in ``ContentView`` used to hand-roll it from
/// `model.defaultFill` alone — no selection tier, no app tier, and an absent
/// default silently left the workspace's white standing — so double-clicking
/// the toolbar fill swatch with a red rect selected seeded the picker RED in
/// Rust (which seeds from `build_live_state_map`) and WHITE here (COLORTIERS).
func dialogStateScope(model: Model?) -> [String: Any] {
    guard let ws = WorkspaceData.load() else { return [:] }
    return buildLiveStateMap(ws: ws, model: model)
}

/// The ctx a colour picker opened by DOUBLE-CLICKING a `fill_stroke_widget`
/// initialises against: the widget's own render ctx with the two colour keys
/// re-stated from ``dialogStateScope``.
///
/// `color_picker.yaml`'s init reads `if param.target == "fill" then
/// state.fill_color else state.stroke_color`, so the seed is only as good as
/// the `state` map handed to dispatch. This site is the third of the three
/// dialog-opening sites and the last to be routed through the one reader; it
/// hand-rolled `selection ?? model.defaultFill` and overlaid THAT onto the
/// (already-live) panel ctx. For a MIXED selection the hand-rolled answer was
/// the tab default, which OVERWROTE the declared default the panel ctx
/// correctly carried — so Rust seeded the picker `#ffffff` (Mixed publishes
/// nothing, the declared default stands) and this port seeded the tab colour.
/// Mixed is the one outcome the COLORTIERS corpus case pins, so the two ports
/// disagreed on the rule the gate exists for.
///
/// Re-stating both keys rather than passing `context` through untouched keeps
/// the seed correct for callers whose ctx was built without the live overlay,
/// and costs one map build per double-click.
func colorPickerSeedContext(_ context: [String: Any], model: Model) -> [String: Any] {
    var ctx = context
    var stateMap = (ctx["state"] as? [String: Any]) ?? [:]
    let live = dialogStateScope(model: model)
    for key in ["fill_color", "stroke_color"] {
        if let v = live[key] { stateMap[key] = v }
    }
    ctx["state"] = stateMap
    return ctx
}
