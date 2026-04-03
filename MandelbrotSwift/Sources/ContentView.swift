import SwiftUI

public struct ContentView: View {
    @State private var centerX: Double = -0.75
    @State private var centerY: Double = 0.0
    @State private var scale: Double = 3.5
    @State private var maxIter: Int32 = 200
    @State private var coordText: String = "(-0.75, 0) 1X"
    @FocusState private var coordFocused: Bool

    private static let initialScale = 3.5

    public init() {}

    // Format coordinate state into the display string.
    private func formatCoord() -> String {
        let displayScale = Self.initialScale / scale
        let x = String(format: "%.15g", centerX)
        let y = String(format: "%.15g", centerY)
        let s = String(format: "%.10g", displayScale)
        return "(\(x), \(y)) \(s)X"
    }

    // Parse "({centerX}, {centerY}) {displayScale}X" and update state.
    private func applyCoordText() {
        let text = coordText.trimmingCharacters(in: .whitespaces)
        // Strip surrounding parens from the coord part: "(x, y) sX"
        guard text.hasPrefix("("),
              let closeIdx = text.firstIndex(of: ")") else { coordText = formatCoord(); return }

        let coordPart = String(text[text.index(after: text.startIndex)..<closeIdx])
        let remainder = text[text.index(after: closeIdx)...].trimmingCharacters(in: .whitespaces)

        let coords = coordPart.components(separatedBy: ",")
        guard coords.count == 2 else { coordText = formatCoord(); return }

        let scaleStr = remainder.hasSuffix("X") ? String(remainder.dropLast()) : remainder

        guard let newX = Double(coords[0].trimmingCharacters(in: .whitespaces)),
              let newY = Double(coords[1].trimmingCharacters(in: .whitespaces)),
              let displayScale = Double(scaleStr.trimmingCharacters(in: .whitespaces)),
              displayScale > 0 else {
            coordText = formatCoord()
            return
        }

        centerX = newX
        centerY = newY
        scale = Self.initialScale / displayScale
    }

    public var body: some View {
        VStack(spacing: 0) {
            TextField("", text: $coordText)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.center)
                .focused($coordFocused)
                .onSubmit { applyCoordText(); coordFocused = false }
                .padding(6)

            MetalView(
                centerX: $centerX,
                centerY: $centerY,
                scale: $scale,
                maxIter: $maxIter
            )
            .frame(minWidth: 640, minHeight: 480)
            .onChange(of: centerX) { _ in if !coordFocused { coordText = formatCoord() } }
            .onChange(of: centerY) { _ in if !coordFocused { coordText = formatCoord() } }
            .onChange(of: scale)   { _ in if !coordFocused { coordText = formatCoord() } }

            HStack {
                Button("Reset") {
                    centerX = -0.75
                    centerY = 0.0
                    scale = 3.5
                    maxIter = 200
                }
                .controlSize(.regular)

                Text("Max iterations: \(maxIter)")
                    .frame(width: 150, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { Double(maxIter) },
                        set: { maxIter = Int32($0) }
                    ),
                    in: 100...10000,
                    step: 10
                )
            }
            .padding(8)
        }
    }
}
