import SwiftUI
import AppKit

/// Modal color picker dialog presented as a sheet.
///
/// Displays a 2D color gradient, vertical colorbar, radio buttons for
/// H/S/B/R/G/Blue, text inputs for HSB/RGB/CMYK/hex, a color swatch
/// preview, and OK/Cancel buttons.
struct ColorPickerView: View {
    @ObservedObject var state: ColorPickerState
    var onOK: (Color) -> Void
    var onCancel: () -> Void

    /// The initial color when the picker was opened, for the "old" swatch.
    let originalColor: Color

    private let gradientSize: CGFloat = 256
    private let colorbarWidth: CGFloat = 20
    private let colorbarHeight: CGFloat = 256

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                // 2D gradient
                gradientView
                    .frame(width: gradientSize, height: gradientSize)

                // Vertical colorbar
                colorbarView
                    .frame(width: colorbarWidth, height: colorbarHeight)

                // Radio buttons and text inputs
                VStack(alignment: .leading, spacing: 8) {
                    radioAndInputSection
                }
                .frame(width: 200)
            }

            HStack(spacing: 16) {
                // Color swatches
                VStack(spacing: 0) {
                    // New color
                    SwiftUI.Rectangle()
                        .fill(toSwiftUIColor(state.color()))
                        .frame(width: 60, height: 30)
                    // Old color
                    SwiftUI.Rectangle()
                        .fill(toSwiftUIColor(originalColor))
                        .frame(width: 60, height: 30)
                }
                .border(SwiftUI.Color.gray, width: 1)

                Toggle("Only Web Colors", isOn: $state.webOnly)
                    .toggleStyle(.checkbox)

                Spacer()

                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { onOK(state.color()) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 380)
        .background(SwiftUI.Color(nsColor: NSColor(white: 0.22, alpha: 1.0)))
    }

    // MARK: - Gradient View

    private var gradientView: some View {
        ZStack {
            gradientBackground
            // Crosshair indicator
            let pos = state.gradientPos()
            SwiftUI.Circle()
                .stroke(SwiftUI.Color.white, lineWidth: 1.5)
                .frame(width: 10, height: 10)
                .position(x: pos.0 * gradientSize, y: pos.1 * gradientSize)
        }
        .clipShape(SwiftUI.Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let x = value.location.x / gradientSize
                    let y = value.location.y / gradientSize
                    state.setFromGradient(x, y)
                }
        )
    }

    @ViewBuilder
    private var gradientBackground: some View {
        switch state.radio {
        case .h:
            // S on x-axis, B on y-axis, fixed H
            let hueColor = toSwiftUIColor(Color.hsb(h: state.hue, s: 1.0, b: 1.0, a: 1.0))
            ZStack {
                LinearGradient(colors: [.white, hueColor], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            }
        default:
            // Fallback: render using Canvas for pixel accuracy
            SwiftUI.Canvas { context, size in
                let w = Int(size.width)
                let h = Int(size.height)
                let step = 4
                for yi in stride(from: 0, to: h, by: step) {
                    for xi in stride(from: 0, to: w, by: step) {
                        let nx = Double(xi) / Double(w)
                        let ny = Double(yi) / Double(h)
                        let c = gradientColorAt(nx, ny)
                        let rect = CGRect(x: CGFloat(xi), y: CGFloat(yi),
                                         width: CGFloat(step), height: CGFloat(step))
                        context.fill(SwiftUI.Path(rect), with: .color(toSwiftUIColor(c)))
                    }
                }
            }
        }
    }

    /// Compute the color at a gradient position for the current radio channel.
    private func gradientColorAt(_ x: Double, _ y: Double) -> Color {
        switch state.radio {
        case .h:
            return Color.hsb(h: state.hue, s: x, b: 1.0 - y, a: 1.0)
        case .s:
            return Color.hsb(h: x * 360.0, s: state.sat, b: 1.0 - y, a: 1.0)
        case .b:
            let (_, _, br, _) = state.color().toHsba()
            return Color.hsb(h: x * 360.0, s: 1.0 - y, b: br, a: 1.0)
        case .r:
            return Color(r: state.r, g: 1.0 - y, b: x)
        case .g:
            return Color(r: 1.0 - y, g: state.g, b: x)
        case .blue:
            return Color(r: x, g: 1.0 - y, b: state.b)
        }
    }

    // MARK: - Colorbar View

    private var colorbarView: some View {
        ZStack {
            // Gradient for the colorbar
            SwiftUI.Canvas { context, size in
                let h = Int(size.height)
                for yi in 0..<h {
                    let t = Double(yi) / Double(h)
                    let c = colorbarColorAt(t)
                    let rect = CGRect(x: 0, y: CGFloat(yi), width: size.width, height: 1)
                    context.fill(SwiftUI.Path(rect), with: .color(toSwiftUIColor(c)))
                }
            }
            // Slider indicator
            let pos = state.colorbarPos()
            SwiftUI.Rectangle()
                .stroke(SwiftUI.Color.white, lineWidth: 1.5)
                .frame(width: colorbarWidth + 4, height: 4)
                .position(x: colorbarWidth / 2, y: pos * colorbarHeight)
        }
        .clipShape(SwiftUI.Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let t = value.location.y / colorbarHeight
                    state.setFromColorbar(t)
                }
        )
    }

    /// Compute the color at a colorbar position for the current radio channel.
    private func colorbarColorAt(_ t: Double) -> Color {
        switch state.radio {
        case .h:
            return Color.hsb(h: t * 360.0, s: 1.0, b: 1.0, a: 1.0)
        case .s:
            return Color.hsb(h: state.hue, s: 1.0 - t, b: 1.0, a: 1.0)
        case .b:
            return Color.hsb(h: state.hue, s: state.sat, b: 1.0 - t, a: 1.0)
        case .r:
            return Color(r: 1.0 - t, g: 0, b: 0)
        case .g:
            return Color(r: 0, g: 1.0 - t, b: 0)
        case .blue:
            return Color(r: 0, g: 0, b: 1.0 - t)
        }
    }

    // MARK: - Radio Buttons and Text Inputs

    private var radioAndInputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // HSB section
            radioRow(channel: .h, label: "H:", value: hsbBinding(0), suffix: "\u{00B0}")
            radioRow(channel: .s, label: "S:", value: hsbBinding(1), suffix: "%")
            radioRow(channel: .b, label: "B:", value: hsbBinding(2), suffix: "%")

            Divider()

            // RGB section
            radioRow(channel: .r, label: "R:", value: rgbBinding(0), suffix: "")
            radioRow(channel: .g, label: "G:", value: rgbBinding(1), suffix: "")
            radioRow(channel: .blue, label: "B:", value: rgbBinding(2), suffix: "")

            Divider()

            // CMYK section (no radio buttons)
            cmykRow(label: "C:", index: 0)
            cmykRow(label: "M:", index: 1)
            cmykRow(label: "Y:", index: 2)
            cmykRow(label: "K:", index: 3)

            Divider()

            // Hex
            HStack {
                SwiftUI.Text("#")
                    .foregroundColor(.white)
                    .frame(width: 16, alignment: .trailing)
                TextField("", text: hexBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
        }
    }

    private func radioRow(channel: RadioChannel, label: String, value: Binding<String>, suffix: String) -> some View {
        HStack(spacing: 4) {
            Button(action: { state.radio = channel }) {
                Image(systemName: state.radio == channel ? "circle.inset.filled" : "circle")
                    .foregroundColor(.white)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)

            SwiftUI.Text(label)
                .foregroundColor(.white)
                .frame(width: 16, alignment: .trailing)

            TextField("", text: value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 50)

            if !suffix.isEmpty {
                SwiftUI.Text(suffix)
                    .foregroundColor(.gray)
                    .frame(width: 16)
            }
        }
    }

    private func cmykRow(label: String, index: Int) -> some View {
        HStack(spacing: 4) {
            Spacer().frame(width: 20)
            SwiftUI.Text(label)
                .foregroundColor(.white)
                .frame(width: 16, alignment: .trailing)
            TextField("", text: cmykBinding(index))
                .textFieldStyle(.roundedBorder)
                .frame(width: 50)
            SwiftUI.Text("%")
                .foregroundColor(.gray)
                .frame(width: 16)
        }
    }

    // MARK: - Value Bindings

    private func hsbBinding(_ component: Int) -> Binding<String> {
        Binding(
            get: {
                let (h, s, b) = state.hsbVals()
                let val = [h, s, b][component]
                return String(Int(val.rounded()))
            },
            set: { newVal in
                guard let v = Double(newVal) else { return }
                let (h, s, b) = state.hsbVals()
                var vals = [h, s, b]
                vals[component] = v
                state.setHsb(vals[0], vals[1], vals[2])
            }
        )
    }

    private func rgbBinding(_ component: Int) -> Binding<String> {
        Binding(
            get: {
                let (r, g, b) = state.rgbU8()
                let val = [r, g, b][component]
                return String(val)
            },
            set: { newVal in
                guard let v = UInt8(newVal) else { return }
                let (r, g, b) = state.rgbU8()
                var vals = [r, g, b]
                vals[component] = v
                state.setRgb(vals[0], vals[1], vals[2])
            }
        )
    }

    private func cmykBinding(_ component: Int) -> Binding<String> {
        Binding(
            get: {
                let (c, m, y, k) = state.cmykVals()
                let val = [c, m, y, k][component]
                return String(Int(val.rounded()))
            },
            set: { newVal in
                guard let v = Double(newVal) else { return }
                let (c, m, y, k) = state.cmykVals()
                var vals = [c, m, y, k]
                vals[component] = v
                state.setCmyk(vals[0], vals[1], vals[2], vals[3])
            }
        )
    }

    private var hexBinding: Binding<String> {
        Binding(
            get: { state.hexStr() },
            set: { newVal in
                if newVal.count == 6 {
                    state.setHex(newVal)
                }
            }
        )
    }

    // MARK: - Helpers

    /// Convert a jas Color to a SwiftUI Color.
    private func toSwiftUIColor(_ c: Color) -> SwiftUI.Color {
        let (r, g, b, a) = c.toRgba()
        return SwiftUI.Color(nsColor: NSColor(red: r, green: g, blue: b, alpha: a))
    }
}
