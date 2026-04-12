/// Color panel menu definition.

public enum ColorPanel {
    public static let label = "Color"

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
    public static func setActiveColorLive(_ color: Color, model: Model) {
        if model.fillOnTop {
            model.defaultFill = Fill(color: color)
        } else {
            let width = model.defaultStroke?.width ?? 1.0
            model.defaultStroke = Stroke(color: color, width: width)
        }
    }

    /// Push a hex color to the recent colors list (move-to-front dedup, max 10).
    public static func pushRecentColor(_ hex: String, model: Model) {
        model.recentColors.removeAll { $0 == hex }
        model.recentColors.insert(hex, at: 0)
        if model.recentColors.count > 10 {
            model.recentColors = Array(model.recentColors.prefix(10))
        }
    }
}
