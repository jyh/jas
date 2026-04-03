import SwiftUI
import AppKit

/// A vertical toolbar with tool icons in a 2-column grid.
public struct ToolbarView: View {
    @Binding var currentTool: Tool

    public var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                toolButton(.selection)
                toolButton(.directSelection)
            }
            Spacer()
        }
        .padding(4)
        .frame(width: 76)
        .background(Color(nsColor: NSColor(white: 0.30, alpha: 1.0)))
    }

    private func toolButton(_ tool: Tool) -> some View {
        Button(action: { currentTool = tool }) {
            toolIcon(tool)
                .frame(width: 32, height: 32)
                .background(currentTool == tool
                    ? Color(nsColor: NSColor(white: 0.38, alpha: 1.0))
                    : Color.clear)
                .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }

    private func toolIcon(_ tool: Tool) -> some View {
        Canvas { context, size in
            let ox = (size.width - 28) / 2
            let oy = (size.height - 28) / 2
            var path = Path()
            path.move(to: CGPoint(x: ox + 5, y: oy + 2))
            path.addLine(to: CGPoint(x: ox + 5, y: oy + 24))
            path.addLine(to: CGPoint(x: ox + 10, y: oy + 18))
            path.addLine(to: CGPoint(x: ox + 15, y: oy + 26))
            path.addLine(to: CGPoint(x: ox + 18, y: oy + 24))
            path.addLine(to: CGPoint(x: ox + 13, y: oy + 16))
            path.addLine(to: CGPoint(x: ox + 20, y: oy + 16))
            path.closeSubpath()

            let color = Color(nsColor: NSColor(white: 0.8, alpha: 1.0))
            switch tool {
            case .selection:
                context.fill(path, with: .color(color))
            case .directSelection:
                context.stroke(path, with: .color(color), lineWidth: 1.5)
            }
        }
    }
}
