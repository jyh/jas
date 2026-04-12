/// Color panel body view.
///
/// Renders the inline color panel with swatches, fill/stroke widget,
/// mode-specific sliders, hex input, and a 2D color bar gradient.

import AppKit
import SwiftUI

// MARK: - Panel Color State

/// Panel-local working color values for all color spaces.
struct PanelColorState {
    var h: Double = 0     // 0..360
    var s: Double = 0     // 0..100
    var b: Double = 100   // 0..100
    var r: Double = 255   // 0..255
    var g: Double = 255   // 0..255
    var bl: Double = 255  // 0..255
    var c: Double = 0     // 0..100
    var m: Double = 0     // 0..100
    var y: Double = 0     // 0..100
    var k: Double = 0     // 0..100
    var hex: String = "ffffff"

    mutating func syncFromColor(_ color: Color) {
        let (rv, gv, bv, _) = color.toRgba()
        r = (rv * 255).rounded()
        g = (gv * 255).rounded()
        bl = (bv * 255).rounded()

        let (hv, sv, brv, _) = color.toHsba()
        h = hv.rounded()
        s = (sv * 100).rounded()
        b = (brv * 100).rounded()

        let (cv, mv, yv, kv, _) = color.toCmyka()
        c = (cv * 100).rounded()
        m = (mv * 100).rounded()
        y = (yv * 100).rounded()
        k = (kv * 100).rounded()

        hex = color.toHex()
    }

    func toColor(mode: ColorPanelMode) -> Color {
        switch mode {
        case .hsb:
            return .hsb(h: h, s: s / 100, b: b / 100, a: 1)
        case .rgb, .webSafeRgb:
            return .rgb(r: r / 255, g: g / 255, b: bl / 255, a: 1)
        case .cmyk:
            return .cmyk(c: c / 100, m: m / 100, y: y / 100, k: k / 100, a: 1)
        case .grayscale:
            let v = 1.0 - k / 100
            return .rgb(r: v, g: v, b: v, a: 1)
        }
    }

    mutating func get(_ field: String) -> Double {
        switch field {
        case "h": return h; case "s": return s; case "b": return b
        case "r": return r; case "g": return g; case "bl": return bl
        case "c": return c; case "m": return m; case "y": return y; case "k": return k
        default: return 0
        }
    }

    mutating func set(_ field: String, _ val: Double) {
        switch field {
        case "h": h = val; case "s": s = val; case "b": b = val
        case "r": r = val; case "g": g = val; case "bl": bl = val
        case "c": c = val; case "m": m = val; case "y": y = val; case "k": k = val
        default: break
        }
    }
}

// MARK: - Color Panel View

public struct ColorPanelView: View {
    @Binding var workspaceLayout: WorkspaceLayout
    @ObservedObject var model: Model
    let theme: Theme

    @State private var ps = PanelColorState()
    @State private var lastSyncedHex = ""

    private var mode: ColorPanelMode { workspaceLayout.colorPanelMode }
    private var fillOnTop: Bool { model.fillOnTop }
    private var activeColor: Color? {
        fillOnTop ? model.defaultFill?.color : model.defaultStroke?.color
    }
    private var disabled: Bool { activeColor == nil }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            swatchesRow
            controlsRow
            hexRow
            colorBar
        }
        .padding(4)
        .onChange(of: activeColor?.toHex() ?? "") { newHex in
            guard newHex != lastSyncedHex else { return }
            if let color = activeColor {
                ps.syncFromColor(color)
            }
            lastSyncedHex = newHex
        }
        .onAppear {
            if let color = activeColor {
                ps.syncFromColor(color)
                lastSyncedHex = color.toHex()
            }
        }
    }

    // MARK: - Row 1: Swatches

    private var swatchesRow: some View {
        HStack(spacing: 2) {
            // None shortcut
            noneButton
            // Black shortcut
            colorSwatch(color: .black, hex: "000000")
            // White shortcut
            colorSwatch(color: .white, hex: "ffffff")
            // Separator
            Rectangle()
                .fill(SwiftUI.Color(nsColor: theme.border))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 2)
            // Recent colors
            ForEach(0..<10, id: \.self) { i in
                recentSwatch(index: i)
            }
        }
    }

    private var noneButton: some View {
        Button {
            if model.fillOnTop {
                model.defaultFill = nil
                if !model.document.selection.isEmpty {
                    model.snapshot()
                    Controller(model: model).setSelectionFill(nil)
                }
            } else {
                model.defaultStroke = nil
                if !model.document.selection.isEmpty {
                    model.snapshot()
                    Controller(model: model).setSelectionStroke(nil)
                }
            }
        } label: {
            ZStack {
                Rectangle().fill(SwiftUI.Color.white).frame(width: 14, height: 14)
                    .border(SwiftUI.Color.gray, width: 0.5)
                SwiftUI.Path { path in
                    path.move(to: CGPoint(x: 0, y: 14))
                    path.addLine(to: CGPoint(x: 14, y: 0))
                }
                .stroke(SwiftUI.Color.red, lineWidth: 1.5)
                .frame(width: 14, height: 14)
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .help("None")
    }

    private func colorSwatch(color: Color, hex: String) -> some View {
        let (rv, gv, bv, _) = color.toRgba()
        let nsColor = NSColor(red: rv, green: gv, blue: bv, alpha: 1)
        return Button {
            ColorPanel.setActiveColor(color, model: model)
        } label: {
            Rectangle()
                .fill(SwiftUI.Color(nsColor: nsColor))
                .frame(width: 16, height: 16)
                .border(SwiftUI.Color.gray, width: 0.5)
        }
        .buttonStyle(.plain)
        .help("#\(hex)")
    }

    @ViewBuilder
    private func recentSwatch(index: Int) -> some View {
        if index < model.recentColors.count, let color = Color.fromHex(model.recentColors[index]) {
            let hex = model.recentColors[index]
            let (rv, gv, bv, _) = color.toRgba()
            let nsColor = NSColor(red: rv, green: gv, blue: bv, alpha: 1)
            Button {
                ColorPanel.setActiveColor(color, model: model)
            } label: {
                Rectangle()
                    .fill(SwiftUI.Color(nsColor: nsColor))
                    .frame(width: 16, height: 16)
                    .border(SwiftUI.Color.gray, width: 0.5)
            }
            .buttonStyle(.plain)
            .help("#\(hex)")
        } else {
            emptySwatch
        }
    }

    private var emptySwatch: some View {
        Rectangle()
            .fill(SwiftUI.Color.clear)
            .frame(width: 16, height: 16)
            .border(SwiftUI.Color(nsColor: theme.border), width: 1)
    }

    // MARK: - Row 2: Controls

    private var controlsRow: some View {
        HStack(alignment: .top, spacing: 6) {
            fillStrokeWidget
            slidersColumn
        }
    }

    // MARK: Fill/Stroke Widget

    private var fillStrokeWidget: some View {
        ZStack {
            // Swap button
            Button {
                let oldFill = model.defaultFill?.color
                let oldStroke = model.defaultStroke?.color
                model.defaultFill = oldStroke.map { Fill(color: $0) }
                if let c = oldFill {
                    let w = model.defaultStroke?.width ?? 1.0
                    model.defaultStroke = Stroke(color: c, width: w)
                } else {
                    model.defaultStroke = nil
                }
            } label: {
                SwiftUI.Text("\u{21C4}").font(.system(size: 11))
                    .foregroundColor(SwiftUI.Color(nsColor: theme.text))
            }
            .buttonStyle(.plain)
            .position(x: 46, y: 6)

            // Default button
            Button {
                model.defaultFill = nil
                model.defaultStroke = Stroke(color: .black)
            } label: {
                ZStack {
                    Rectangle().fill(SwiftUI.Color.black).frame(width: 9, height: 9)
                        .border(SwiftUI.Color.gray, width: 0.5)
                        .offset(x: -2, y: -2)
                    Rectangle().fill(SwiftUI.Color.white).frame(width: 9, height: 9)
                        .border(SwiftUI.Color.gray, width: 0.5)
                        .offset(x: 2, y: 2)
                }
                .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .position(x: 7, y: 49)

            // Back square
            if fillOnTop {
                strokeSquare.zIndex(1).position(x: 34, y: 36)
                    .onTapGesture { model.fillOnTop = false }
            } else {
                fillSquare.zIndex(1).position(x: 16, y: 16)
                    .onTapGesture { model.fillOnTop = true }
            }

            // Front square
            if fillOnTop {
                fillSquare.zIndex(2).position(x: 16, y: 16)
            } else {
                strokeSquare.zIndex(2).position(x: 34, y: 36)
            }
        }
        .frame(width: 52, height: 56)
    }

    private var fillSquare: some View {
        let fillColor: SwiftUI.Color = model.defaultFill.map { fill in
            let (r, g, b, _) = fill.color.toRgba()
            return SwiftUI.Color(nsColor: NSColor(red: r, green: g, blue: b, alpha: 1))
        } ?? .clear
        return ZStack {
            Rectangle().fill(fillColor).frame(width: 28, height: 28)
                .border(SwiftUI.Color.gray, width: 1)
            if model.defaultFill == nil {
                noneOverlay
            }
        }
    }

    private var strokeSquare: some View {
        let strokeColor: SwiftUI.Color = model.defaultStroke.map { s in
            let (r, g, b, _) = s.color.toRgba()
            return SwiftUI.Color(nsColor: NSColor(red: r, green: g, blue: b, alpha: 1))
        } ?? SwiftUI.Color(nsColor: theme.border)
        return ZStack {
            Rectangle().fill(SwiftUI.Color.clear).frame(width: 28, height: 28)
                .overlay(
                    Rectangle().stroke(strokeColor, lineWidth: 6)
                )
            if model.defaultStroke == nil {
                noneOverlay
            }
        }
    }

    private var noneOverlay: some View {
        SwiftUI.Path { path in
            path.move(to: CGPoint(x: 0, y: 28))
            path.addLine(to: CGPoint(x: 28, y: 0))
        }
        .stroke(SwiftUI.Color.red, lineWidth: 2)
        .frame(width: 28, height: 28)
    }

    // MARK: Sliders

    private var slidersColumn: some View {
        VStack(spacing: 2) {
            switch mode {
            case .grayscale:
                sliderRow(label: "K", field: "k", min: 0, max: 100, step: 1, suffix: "%")
            case .hsb:
                sliderRow(label: "H", field: "h", min: 0, max: 360, step: 1, suffix: "\u{00B0}")
                sliderRow(label: "S", field: "s", min: 0, max: 100, step: 1, suffix: "%")
                sliderRow(label: "B", field: "b", min: 0, max: 100, step: 1, suffix: "%")
            case .rgb:
                sliderRow(label: "R", field: "r", min: 0, max: 255, step: 1, suffix: nil)
                sliderRow(label: "G", field: "g", min: 0, max: 255, step: 1, suffix: nil)
                sliderRow(label: "B", field: "bl", min: 0, max: 255, step: 1, suffix: nil)
            case .cmyk:
                sliderRow(label: "C", field: "c", min: 0, max: 100, step: 1, suffix: "%")
                sliderRow(label: "M", field: "m", min: 0, max: 100, step: 1, suffix: "%")
                sliderRow(label: "Y", field: "y", min: 0, max: 100, step: 1, suffix: "%")
                sliderRow(label: "K", field: "k", min: 0, max: 100, step: 1, suffix: "%")
            case .webSafeRgb:
                sliderRow(label: "R", field: "r", min: 0, max: 255, step: 51, suffix: nil)
                sliderRow(label: "G", field: "g", min: 0, max: 255, step: 51, suffix: nil)
                sliderRow(label: "B", field: "bl", min: 0, max: 255, step: 51, suffix: nil)
            }
        }
    }

    private func sliderRow(label: String, field: String, min: Double, max: Double, step: Double, suffix: String?) -> some View {
        let currentVal = ps.get(field)
        let opacity = disabled ? 0.4 : 1.0
        return HStack(spacing: 4) {
            SwiftUI.Text(label)
                .font(.system(size: 10))
                .foregroundColor(SwiftUI.Color(nsColor: theme.text))
                .frame(width: 10, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { ps.get(field) },
                    set: { newVal in
                        ps.set(field, newVal)
                        let color = ps.toColor(mode: mode)
                        ps.syncFromColor(color)
                        let m = mode
                        ps.set(field, newVal)
                        lastSyncedHex = color.toHex()
                        ColorPanel.setActiveColorLive(color, model: model)
                    }
                ),
                in: min...max,
                step: step
            )
            .controlSize(.mini)

            SwiftUI.Text("\(Int(currentVal))")
                .font(.system(size: 10))
                .foregroundColor(SwiftUI.Color(nsColor: theme.text))
                .frame(width: 30, alignment: .trailing)

            if let sfx = suffix {
                SwiftUI.Text(sfx)
                    .font(.system(size: 10))
                    .foregroundColor(SwiftUI.Color(nsColor: theme.textDim))
            }
        }
        .opacity(opacity)
    }

    // MARK: - Row 3: Hex Input

    private var hexRow: some View {
        let opacity = disabled ? 0.4 : 1.0
        return HStack(spacing: 2) {
            SwiftUI.Text("#")
                .font(.system(size: 10))
                .foregroundColor(SwiftUI.Color(nsColor: theme.text))
            TextField("000000", text: $ps.hex, onCommit: {
                let raw = ps.hex.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "#", with: "")
                guard raw.count == 6,
                      raw.allSatisfy({ $0.isHexDigit }),
                      let color = Color.fromHex(raw) else { return }
                ps.syncFromColor(color)
                lastSyncedHex = color.toHex()
                ColorPanel.setActiveColor(color, model: model)
            })
            .font(.system(size: 10, design: .monospaced))
            .textFieldStyle(.squareBorder)
            .frame(width: 52)
            .disabled(disabled)
        }
        .opacity(opacity)
    }

    // MARK: - Color Bar

    private var colorBar: some View {
        let opacity = disabled ? 0.4 : 1.0
        return GeometryReader { geo in
            let w = geo.size.width
            let h: CGFloat = 64
            let nsImage = buildColorBarImage(width: Int(w), height: Int(h))
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: w, height: h)
                .border(SwiftUI.Color(nsColor: theme.border), width: 1)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard !disabled else { return }
                            applyColorBarPoint(x: value.location.x, y: value.location.y, width: w, height: h, commit: false)
                        }
                        .onEnded { value in
                            guard !disabled else { return }
                            applyColorBarPoint(x: value.location.x, y: value.location.y, width: w, height: h, commit: true)
                        }
                )
        }
        .frame(height: 64)
        .opacity(opacity)
    }

    /// Build a pixel-accurate NSImage for the color bar.
    /// Split y-axis: top half S 0→100%, B 100→80%; bottom half S 100%, B 80→0%.
    private func buildColorBarImage(width: Int, height: Int) -> NSImage {
        let w = Swift.max(width, 1)
        let h = Swift.max(height, 1)
        let midY = Double(h) / 2.0
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 3,
            hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: w * 3,
            bitsPerPixel: 24
        ), let data = rep.bitmapData else {
            return NSImage(size: NSSize(width: w, height: h))
        }
        for y in 0..<h {
            let yf = Double(y)
            let (sat, br): (Double, Double)
            if yf <= midY {
                let t = yf / midY
                sat = t
                br = 1.0 - t * 0.2
            } else {
                let t = (yf - midY) / (Double(h) - midY)
                sat = 1.0
                br = 0.8 * (1.0 - t)
            }
            for x in 0..<w {
                let hue = 360.0 * Double(x) / Double(w)
                let c = Color.hsb(h: hue, s: sat, b: br, a: 1)
                let (rv, gv, bv, _) = c.toRgba()
                let offset = (y * w + x) * 3
                data[offset] = UInt8((rv * 255).rounded())
                data[offset + 1] = UInt8((gv * 255).rounded())
                data[offset + 2] = UInt8((bv * 255).rounded())
            }
        }
        let image = NSImage(size: NSSize(width: w, height: h))
        image.addRepresentation(rep)
        return image
    }

    private func applyColorBarPoint(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, commit: Bool) {
        let w = Double(width > 0 ? width : 200)
        let h = Double(height > 0 ? height : 64)
        let xc = Double(x).clamped(to: 0...(w - 1))
        let yc = Double(y).clamped(to: 0...(h - 1))
        let midY = h / 2

        let hue = 360.0 * xc / w
        let (sat, br): (Double, Double)
        if yc <= midY {
            let t = yc / midY
            sat = t * 100
            br = 100 - t * 20
        } else {
            let t = (yc - midY) / (h - midY)
            sat = 100
            br = 80 * (1 - t)
        }

        let color = Color.hsb(h: hue, s: sat / 100, b: br / 100, a: 1)
        ps.syncFromColor(color)
        ps.h = hue.rounded()
        ps.s = sat.rounded()
        ps.b = br.rounded()
        lastSyncedHex = color.toHex()

        if commit {
            ColorPanel.setActiveColor(color, model: model)
        } else {
            ColorPanel.setActiveColorLive(color, model: model)
        }
    }
}

// MARK: - Double Clamped

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
