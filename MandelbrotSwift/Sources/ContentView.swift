import SwiftUI

struct ContentView: View {
    @State private var centerX: Float = -0.75
    @State private var centerY: Float = 0.0
    @State private var scale: Float = 3.5
    @State private var maxIter: Int32 = 500

    var body: some View {
        VStack(spacing: 0) {
            MetalView(
                centerX: $centerX,
                centerY: $centerY,
                scale: $scale,
                maxIter: $maxIter
            )
            .frame(minWidth: 640, minHeight: 480)

            HStack {
                Button("Reset") {
                    centerX = -0.75
                    centerY = 0.0
                    scale = 3.5
                    maxIter = 500
                }
                .controlSize(.regular)

                Text("Max iterations: \(maxIter)")
                    .frame(width: 150, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { Float(maxIter) },
                        set: { maxIter = Int32($0) }
                    ),
                    in: 100...4000,
                    step: 10
                )
            }
            .padding(8)
        }
    }
}
