/// Color panel menu definition.

import Foundation

public enum ColorPanel {
    /// Source of truth is workspace/panels/color.yaml's `menu:` block
    /// (review #15); the generic reader builds the items from the bundle.
    /// The five mode rows share `action: set_color_panel_mode`, so the
    /// builder folds each `params.mode` into the command
    /// (`set_color_panel_mode:grayscale`, …) — `ColorPanelMode.fromCommand`
    /// splits that suffix back off.
    public static func menuItems() -> [PanelMenuItem] {
        menuItemsFromYaml("color_panel_content")
    }

    public static func dispatch(_ cmd: String, addr: PanelAddr, layout: inout WorkspaceLayout, model: Model? = nil) {
        // Mode changes
        if let mode = ColorPanelMode.fromCommand(cmd) {
            layout.colorPanelMode = mode
            // Also push the mode into the panel state so YAML
            // bind.visible expressions (panel.mode == "rgb") see
            // the change. Without this the slider groups stay on
            // whatever mode was active at first render (hsb default).
            if let model = model {
                // ColorPanelMode.rawValue is camelCase
                // (`webSafeRgb`) but the YAML expects snake_case
                // (`web_safe_rgb`); convert before storing.
                let yamlMode: String
                switch mode {
                case .webSafeRgb: yamlMode = "web_safe_rgb"
                default: yamlMode = mode.rawValue
                }
                let store = model.stateStore
                store.setPanel("color_panel_content", "mode", yamlMode)
                // Seed the destination mode's sliders from the current active
                // color — without this, switching modes shows the YAML defaults
                // (0/0/255 for RGB etc.) regardless of the actual color.
                //
                // Through ``resolveActivePaintColor``, the same reader the
                // panel's render overlay and its write path use: the hand-rolled
                // `defaultFill?.color ?? white` here had no app tier, so after
                // File > New a mode switch seeded WHITE and the next drag mixed
                // the dragged channel with white's channels (COLORTIERS
                // repair 2).
                let active = resolveActivePaintColor(model: model)
                    ?? Color.rgb(r: 1, g: 1, b: 1, a: 1)
                seedSliders(from: active, mode: mode, store: store)
                model.panelStateVersion &+= 1
            }
            return
        }

        switch cmd {
        case "close_panel":
            layoutApply(&layout, opClosePanel(addr))
        case "invert_active_color":
            guard let model = model else { return }
            if let color = activeDefaultPaintColor(model: model) {
                let (r, g, b, _) = color.toRgba()
                let inverted = Color.rgb(r: 1.0 - r, g: 1.0 - g, b: 1.0 - b, a: 1.0)
                setActiveColor(inverted, model: model)
            }
        case "complement_active_color":
            guard let model = model else { return }
            if let color = activeDefaultPaintColor(model: model) {
                let (h, s, br, _) = color.toHsba()
                guard s > 0.001 else { return }
                let newH = (h + 180.0).truncatingRemainder(dividingBy: 360.0)
                let complemented = Color.hsb(h: newH, s: s, b: br, a: 1.0)
                setActiveColor(complemented, model: model)
            }
        default:
            break
        }
    }

    /// Set the active color (fill or stroke per fillOnTop), push to recent colors.
    ///
    /// A colour pick changes the COLOUR and nothing else: each selected
    /// element keeps its own width / cap / join / dash / arrowheads and its
    /// fill or stroke opacity, and so do the new-element defaults. This
    /// used to stamp `Stroke(color:width:)` over the whole selection, which
    /// reset a 5pt dashed arrowheaded line to a plain 1pt stroke — the
    /// Color-panel twin of the Stroke-panel width clobber (STROKEWIDTH,
    /// 2026-07-24). Mirrors Rust `set_active_color`.
    public static func setActiveColor(_ color: Color, model: Model) {
        let ctrl = Controller(model: model)
        if model.fillOnTop {
            // The APP tier first, exactly as Rust's `set_active_color` does
            // ("Always update app-level defaults", before the per-tab write).
            // A colour committed on a slider / the hex field / the colour bar is
            // the same workspace-level fact as one clicked on a swatch, so it
            // has to survive File > New the same way; writing only the document
            // tier lost it at the next New (COLORTIERS repair 2). The LIVE arm
            // below deliberately does NOT write it — neither does Rust's
            // `set_active_color_live` — so a mid-drag tick cannot leak forward.
            model.appDefaultFill = recolorFill(model.appDefaultFill, color)
            model.defaultFill = recolorFill(model.defaultFill, color)
            if !model.document.selection.isEmpty {
                // editDocument self-brackets the apply into ONE undo step
                // (OP_LOG.md Increment 1); no separate snapshot() — that would
                // double-checkpoint. Mirrors Rust set_active_color's
                // `with_txn { map_selection_fill }`.
                ctrl.mapSelectionFill { recolorFill($0, color) }
            }
        } else {
            model.appDefaultStroke = recolorStroke(model.appDefaultStroke, color)
            model.defaultStroke = recolorStroke(model.defaultStroke, color)
            if !model.document.selection.isEmpty {
                ctrl.mapSelectionStroke { recolorStroke($0, color) }
            }
        }
        pushRecentColor(color.toHex(), model: model)
    }

    /// Set the active color without pushing to recent colors (live slider drag).
    ///
    /// Also writes to the active selection — without that, the canvas
    /// doesn't animate during drag (selection's fill stays at its
    /// pre-drag color until release) and the Color panel's
    /// selection-fed live overrides keep the sliders / hex stuck on
    /// the stale selection value. We deliberately skip
    /// `model.snapshot()` so the per-tick drag doesn't pollute the
    /// undo stack — the eventual `setActiveColor` on release does the
    /// snapshot for the whole drag.
    /// Colour-only, exactly like ``setActiveColor(_:model:)``.
    public static func setActiveColorLive(_ color: Color, model: Model) {
        let ctrl = Controller(model: model)
        if model.fillOnTop {
            model.defaultFill = recolorFill(model.defaultFill, color)
            if !model.document.selection.isEmpty {
                // Live, NON-undoable per-tick write (OP_LOG.md §7/§8); undo is
                // captured once on release by setActiveColor. Mirrors Rust
                // set_active_color_live's map_selection_fill_live.
                ctrl.mapSelectionFillLive { recolorFill($0, color) }
            }
        } else {
            model.defaultStroke = recolorStroke(model.defaultStroke, color)
            if !model.document.selection.isEmpty {
                ctrl.mapSelectionStrokeLive { recolorStroke($0, color) }
            }
        }
    }

    /// A stroke with `color` replaced and every other attribute preserved.
    /// `nil` (nothing to recolour) becomes a plain 1pt stroke in that
    /// colour. Mirrors Rust `recolor_stroke`.
    static func recolorStroke(_ base: Stroke?, _ color: Color) -> Stroke {
        guard let b = base else { return Stroke(color: color, width: 1.0) }
        return Stroke(color: color, width: b.width, linecap: b.linecap,
                      linejoin: b.linejoin, miterLimit: b.miterLimit,
                      align: b.align, dashPattern: b.dashPattern,
                      dashAlignAnchors: b.dashAlignAnchors,
                      startArrow: b.startArrow, endArrow: b.endArrow,
                      startArrowScale: b.startArrowScale,
                      endArrowScale: b.endArrowScale,
                      arrowAlign: b.arrowAlign, opacity: b.opacity)
    }

    /// A fill with `color` replaced and its opacity preserved.
    static func recolorFill(_ base: Fill?, _ color: Color) -> Fill {
        Fill(color: color, opacity: base?.opacity ?? 1.0)
    }

    /// Listeners fired after [pushRecentColor] commits. The Color and
    /// Swatches panels register here so a native push (slider/hex/
    /// recent click) flows into their YAML panel.recent_colors state
    /// stores. Each listener receives (model, hex).
    ///
    /// Guarded by `_recentColorsLock`: registration (append) and
    /// firing (iterate) can run concurrently — e.g. parallel tests
    /// that install the bridge while pushing recent colors — and an
    /// unsynchronised Array append racing an iteration is undefined
    /// behaviour (buffer reallocation under a live reader → SIGSEGV).
    private static var _recentColorsListeners: [(Model, String) -> Void] = []
    private static let _recentColorsLock = NSLock()

    public static func addRecentColorsListener(
        _ cb: @escaping (Model, String) -> Void
    ) {
        _recentColorsLock.lock()
        defer { _recentColorsLock.unlock() }
        _recentColorsListeners.append(cb)
    }

    /// Parse a 6-char hex string (with or without `#`) into a Color.
    /// Returns nil if the string is not a valid hex color.
    public static func colorFromHex(_ s: String) -> Color? {
        var hex = s.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else {
            return nil
        }
        let r = Double((v >> 16) & 0xff) / 255.0
        let g = Double((v >> 8) & 0xff) / 255.0
        let b = Double(v & 0xff) / 255.0
        return Color.rgb(r: r, g: g, b: b, a: 1.0)
    }

    /// Write the slider values for a given mode into the panel
    /// state derived from a starting color. Called on mode switch
    /// so the sliders reflect the current active color rather than
    /// stale init-time values.
    public static func seedSliders(
        from color: Color, mode: ColorPanelMode, store: StateStore
    ) {
        let pid = "color_panel_content"
        let (r, g, b, _) = color.toRgba()
        switch mode {
        case .grayscale:
            // K = 1 - max(R, G, B) interpreted as a single ink amount;
            // simplest mapping: K ≈ 1 - luminance. Pick brightness so
            // round-tripping a gray color is exact.
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let k = (1.0 - luma) * 100.0
            store.setPanel(pid, "k", k)
        case .rgb, .webSafeRgb:
            store.setPanel(pid, "r", r * 255.0)
            store.setPanel(pid, "g", g * 255.0)
            store.setPanel(pid, "bl", b * 255.0)
        case .cmyk:
            let k = 1.0 - max(r, max(g, b))
            let c = (k < 1.0) ? (1.0 - r - k) / (1.0 - k) : 0
            let m = (k < 1.0) ? (1.0 - g - k) / (1.0 - k) : 0
            let y = (k < 1.0) ? (1.0 - b - k) / (1.0 - k) : 0
            store.setPanel(pid, "c", c * 100.0)
            store.setPanel(pid, "m", m * 100.0)
            store.setPanel(pid, "y", y * 100.0)
            store.setPanel(pid, "k", k * 100.0)
        case .hsb:
            let (h, s, br, _) = color.toHsba()
            store.setPanel(pid, "h", h)
            store.setPanel(pid, "s", s * 100.0)
            store.setPanel(pid, "b", br * 100.0)
        }
        // Hex always reflects the active color too.
        store.setPanel(pid, "hex", color.toHex())
    }

    /// Push a hex color to the recent colors list (move-to-front dedup, max 10).
    public static func pushRecentColor(_ hex: String, model: Model) {
        model.recentColors.removeAll { $0 == hex }
        model.recentColors.insert(hex, at: 0)
        if model.recentColors.count > 10 {
            model.recentColors = Array(model.recentColors.prefix(10))
        }
        // Snapshot under the lock, then fire outside it so a listener
        // can re-enter (e.g. register another listener) without a
        // deadlock and so the array buffer can't be mutated mid-iterate.
        _recentColorsLock.lock()
        let listeners = _recentColorsListeners
        _recentColorsLock.unlock()
        for cb in listeners {
            cb(model, hex)
        }
    }
}
