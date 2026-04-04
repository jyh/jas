import SwiftUI
import AppKit

/// Tool button and icon drawing utilities for the toolbar.
public struct ToolbarView {
    static func toolButton(currentTool: Binding<Tool>, tool: Tool) -> some View {
        Button(action: { currentTool.wrappedValue = tool }) {
            toolIcon(tool)
                .frame(width: 32, height: 32)
                .background(currentTool.wrappedValue == tool
                    ? Color(nsColor: NSColor(white: 0.38, alpha: 1.0))
                    : Color.clear)
                .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }

    static func toolIcon(_ tool: Tool) -> some View {
        Canvas { context, size in
            let ox = (size.width - 28) / 2
            let oy = (size.height - 28) / 2
            let color = Color(nsColor: NSColor(white: 0.8, alpha: 1.0))

            switch tool {
            case .selection:
                var path = Path()
                path.move(to: CGPoint(x: ox + 5, y: oy + 2))
                path.addLine(to: CGPoint(x: ox + 5, y: oy + 24))
                path.addLine(to: CGPoint(x: ox + 10, y: oy + 18))
                path.addLine(to: CGPoint(x: ox + 15, y: oy + 26))
                path.addLine(to: CGPoint(x: ox + 18, y: oy + 24))
                path.addLine(to: CGPoint(x: ox + 13, y: oy + 16))
                path.addLine(to: CGPoint(x: ox + 20, y: oy + 16))
                path.closeSubpath()
                context.fill(path, with: .color(color))

            case .directSelection:
                var path = Path()
                path.move(to: CGPoint(x: ox + 5, y: oy + 2))
                path.addLine(to: CGPoint(x: ox + 5, y: oy + 24))
                path.addLine(to: CGPoint(x: ox + 10, y: oy + 18))
                path.addLine(to: CGPoint(x: ox + 15, y: oy + 26))
                path.addLine(to: CGPoint(x: ox + 18, y: oy + 24))
                path.addLine(to: CGPoint(x: ox + 13, y: oy + 16))
                path.addLine(to: CGPoint(x: ox + 20, y: oy + 16))
                path.closeSubpath()
                context.stroke(path, with: .color(color), lineWidth: 1.5)

            case .line:
                var path = Path()
                path.move(to: CGPoint(x: ox + 4, y: oy + 24))
                path.addLine(to: CGPoint(x: ox + 24, y: oy + 4))
                context.stroke(path, with: .color(color), lineWidth: 2.0)
            }
        }
    }
}
