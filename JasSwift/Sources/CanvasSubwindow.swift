import SwiftUI
import AppKit

/// An embedded, draggable canvas subwindow within the workspace.
public struct CanvasSubwindow: View {
    let title: String
    @Binding var position: CGPoint

    private let titleBarHeight: CGFloat = 24
    private let canvasSize = CGSize(width: 800, height: 600)

    public var body: some View {
        let totalWidth = canvasSize.width
        let totalHeight = titleBarHeight + canvasSize.height

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                // Title bar
                ZStack {
                    Color(nsColor: NSColor(white: 0.6, alpha: 1.0))
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundColor(.black)
                }
                .frame(width: totalWidth, height: titleBarHeight)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            position.x += value.translation.width
                            position.y += value.translation.height
                        }
                )

                // Canvas
                Color.white
                    .frame(width: totalWidth, height: canvasSize.height)
            }
            .border(Color(nsColor: NSColor(white: 0.4, alpha: 1.0)), width: 1)
        }
        .frame(width: totalWidth, height: totalHeight)
        .position(x: position.x + totalWidth / 2, y: position.y + totalHeight / 2)
    }
}
