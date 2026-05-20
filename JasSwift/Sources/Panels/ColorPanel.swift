/// Color panel menu definition.

public enum ColorPanel {
    public static func menuItems() -> [PanelMenuItem] {
        [
            .radio(label: "Grayscale", command: "mode_grayscale", group: "color_mode"),
            .radio(label: "RGB", command: "mode_rgb", group: "color_mode"),
            .radio(label: "HSB", command: "mode_hsb", group: "color_mode"),
            .radio(label: "CMYK", command: "mode_cmyk", group: "color_mode"),
            .radio(label: "Web Safe RGB", command: "mode_web_safe_rgb", group: "color_mode"),
            .separator,
            .action(label: "Invert", command: "invert_color"),
            .action(label: "Complement", command: "complement_color"),
            .separator,
            .action(label: "Close Color", command: "close_panel"),
        ]
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
                // Seed the destination mode's sliders from the
                // current active color — without this, switching
                // modes shows the YAML defaults (0/0/255 for RGB
                // etc.) regardless of the actual color.
                let active: Color = (model.fillOnTop
                    ? model.defaultFill?.color
                    : model.defaultStroke?.color)
                    ?? Color.rgb(r: 1, g: 1, b: 1, a: 1)
                seedSliders(from: active, mode: mode, store: store)
                model.panelStateVersion &+= 1
            }
            return
        }

        switch cmd {
        case "close_panel":
            layout.closePanel(addr)
        case "invert_color":
            guard let model = model else { return }
            if let color = model.fillOnTop ? model.defaultFill?.color : model.defaultStroke?.color {
                let (r, g, b, _) = color.toRgba()
                let inverted = Color.rgb(r: 1.0 - r, g: 1.0 - g, b: 1.0 - b, a: 1.0)
                setActiveColor(inverted, model: model)
            }
        case "complement_color":
            guard let model = model else { return }
            if let color = model.fillOnTop ? model.defaultFill?.color : model.defaultStroke?.color {
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

    public static func isChecked(_ cmd: String, layout: WorkspaceLayout) -> Bool {
        if let mode = ColorPanelMode.fromCommand(cmd) {
            return layout.colorPanelMode == mode
        }
        return false
    }

    /// Query whether a menu command is enabled. Invert / Complement
    /// need an active color (fill or stroke per `fillOnTop`) to
    /// operate on; gray them out when the active attribute is none.
    public static func isEnabled(_ cmd: String, model: Model?) -> Bool {
        switch cmd {
        case "invert_color", "complement_color":
            guard let m = model else { return true }
            let c: Color? = m.fillOnTop ? m.defaultFill?.color : m.defaultStroke?.color
            return c != nil
        default: return true
        }
    }

    /// Set the active color (fill or stroke per fillOnTop), push to recent colors.
    public static func setActiveColor(_ color: Color, model: Model) {
        let ctrl = Controller(model: model)
        if model.fillOnTop {
            model.defaultFill = Fill(color: color)
            if !model.document.selection.isEmpty {
                model.snapshot()
                ctrl.setSelectionFill(Fill(color: color))
            }
        } else {
            let width = model.defaultStroke?.width ?? 1.0
            model.defaultStroke = Stroke(color: color, width: width)
            if !model.document.selection.isEmpty {
                model.snapshot()
                ctrl.setSelectionStroke(Stroke(color: color, width: width))
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
    public static func setActiveColorLive(_ color: Color, model: Model) {
        let ctrl = Controller(model: model)
        if model.fillOnTop {
            model.defaultFill = Fill(color: color)
            if !model.document.selection.isEmpty {
                ctrl.setSelectionFill(Fill(color: color))
            }
        } else {
            let width = model.defaultStroke?.width ?? 1.0
            model.defaultStroke = Stroke(color: color, width: width)
            if !model.document.selection.isEmpty {
                ctrl.setSelectionStroke(Stroke(color: color, width: width))
            }
        }
    }

    /// Listeners fired after [pushRecentColor] commits. The Color and
    /// Swatches panels register here so a native push (slider/hex/
    /// recent click) flows into their YAML panel.recent_colors state
    /// stores. Each listener receives (model, hex).
    private static var _recentColorsListeners: [(Model, String) -> Void] = []

    public static func addRecentColorsListener(
        _ cb: @escaping (Model, String) -> Void
    ) {
        _recentColorsListeners.append(cb)
    }

    /// Read the Color panel's current mode + slider/hex state and
    /// derive the corresponding RGB color. Returns nil when the
    /// panel has no stored state yet (initial render).
    public static func colorFromPanelState(store: StateStore) -> Color? {
        let s = store.getPanelState("color_panel_content")
        let mode = (s["mode"] as? String) ?? "hsb"
        func num(_ k: String) -> Double {
            (s[k] as? Double)
                ?? (s[k] as? Int).map { Double($0) }
                ?? 0
        }
        switch mode {
        case "grayscale":
            let k = num("k") / 100.0
            return Color.rgb(r: 1.0 - k, g: 1.0 - k, b: 1.0 - k, a: 1.0)
        case "rgb", "web_safe_rgb":
            return Color.rgb(
                r: num("r") / 255.0,
                g: num("g") / 255.0,
                b: num("bl") / 255.0,
                a: 1.0
            )
        case "cmyk":
            let c = num("c") / 100.0, mk = num("m") / 100.0
            let y = num("y") / 100.0, k = num("k") / 100.0
            return Color.rgb(
                r: (1.0 - c) * (1.0 - k),
                g: (1.0 - mk) * (1.0 - k),
                b: (1.0 - y) * (1.0 - k),
                a: 1.0
            )
        default:  // hsb
            return Color.hsb(
                h: num("h"),
                s: num("s") / 100.0,
                b: num("b") / 100.0,
                a: 1.0
            )
        }
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
        for cb in _recentColorsListeners {
            cb(model, hex)
        }
    }
}
