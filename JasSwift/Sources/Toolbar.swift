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

    /// A button that shows one tool but long-press reveals alternates.
    static func toolButtonWithAlternates(
        currentTool: Binding<Tool>,
        visibleTool: Binding<Tool>,
        alternates: [Tool]
    ) -> some View {
        ArrowSlotButton(
            currentTool: currentTool,
            visibleTool: visibleTool,
            alternates: alternates
        )
    }

    static func toolIcon(_ tool: Tool) -> some View {
        Canvas { context, size in
            let ox = (size.width - 28) / 2
            let oy = (size.height - 28) / 2
            let color = Color(nsColor: NSColor(white: 0.8, alpha: 1.0))

            switch tool {
            case .selection:
                context.fill(arrowPath(ox: ox, oy: oy), with: .color(color))

            case .directSelection:
                context.stroke(arrowPath(ox: ox, oy: oy), with: .color(color), lineWidth: 1.5)

            case .groupSelection:
                context.stroke(arrowPath(ox: ox, oy: oy), with: .color(color), lineWidth: 1.5)
                // Draw '+' badge in lower-right
                var plus = Path()
                plus.move(to: CGPoint(x: ox + 20, y: oy + 20))
                plus.addLine(to: CGPoint(x: ox + 27, y: oy + 20))
                plus.move(to: CGPoint(x: ox + 23.5, y: oy + 16.5))
                plus.addLine(to: CGPoint(x: ox + 23.5, y: oy + 23.5))
                context.stroke(plus, with: .color(color), lineWidth: 1.5)

            case .text:
                context.draw(
                    Text("T").font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color(nsColor: NSColor(white: 0.8, alpha: 1.0))),
                    at: CGPoint(x: size.width / 2, y: size.height / 2)
                )

            case .line:
                var path = Path()
                path.move(to: CGPoint(x: ox + 4, y: oy + 24))
                path.addLine(to: CGPoint(x: ox + 24, y: oy + 4))
                context.stroke(path, with: .color(color), lineWidth: 2.0)

            case .rect:
                let rect = CGRect(x: ox + 4, y: oy + 6, width: 20, height: 16)
                context.stroke(Path(rect), with: .color(color), lineWidth: 1.5)

            case .polygon:
                let cx = ox + 14.0, cy = oy + 14.0, r = 11.0
                let n = 6
                var path = Path()
                for i in 0..<n {
                    let angle = -.pi / 2 + 2 * .pi * Double(i) / Double(n)
                    let px = cx + r * cos(angle)
                    let py = cy + r * sin(angle)
                    if i == 0 { path.move(to: CGPoint(x: px, y: py)) }
                    else { path.addLine(to: CGPoint(x: px, y: py)) }
                }
                path.closeSubpath()
                context.stroke(path, with: .color(color), lineWidth: 1.5)
            }
        }
    }

    private static func arrowPath(ox: CGFloat, oy: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: ox + 5, y: oy + 2))
        path.addLine(to: CGPoint(x: ox + 5, y: oy + 24))
        path.addLine(to: CGPoint(x: ox + 10, y: oy + 18))
        path.addLine(to: CGPoint(x: ox + 15, y: oy + 26))
        path.addLine(to: CGPoint(x: ox + 18, y: oy + 24))
        path.addLine(to: CGPoint(x: ox + 13, y: oy + 16))
        path.addLine(to: CGPoint(x: ox + 20, y: oy + 16))
        path.closeSubpath()
        return path
    }
}

/// A button that shows the current visible tool, selects it on click,
/// and shows a popover with alternates on long press.
private struct ArrowSlotButton: View {
    @Binding var currentTool: Tool
    @Binding var visibleTool: Tool
    let alternates: [Tool]
    @State private var showingMenu = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ToolbarView.toolIcon(visibleTool)
                .frame(width: 32, height: 32)
            // Small triangle indicator for alternates
            alternateTriangle()
                .padding(2)
        }
            .background(currentTool == visibleTool
                ? Color(nsColor: NSColor(white: 0.38, alpha: 1.0))
                : Color.clear)
            .cornerRadius(3)
            .onTapGesture {
                currentTool = visibleTool
            }
            .onLongPressGesture(minimumDuration: 0.5) {
                showingMenu = true
            }
            .popover(isPresented: $showingMenu) {
                VStack(spacing: 0) {
                    ForEach(alternates, id: \.self) { tool in
                        Button {
                            visibleTool = tool
                            currentTool = tool
                            showingMenu = false
                        } label: {
                            HStack {
                                ToolbarView.toolIcon(tool)
                                    .frame(width: 24, height: 24)
                                Text(toolDisplayName(tool))
                                    .font(.system(size: 12))
                                Spacer()
                                if tool == visibleTool {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10))
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
            }
    }

    private func alternateTriangle() -> some View {
        Canvas { context, size in
            var path = Path()
            let s: CGFloat = 5
            path.move(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: size.width - s, y: size.height))
            path.addLine(to: CGPoint(x: size.width, y: size.height - s))
            path.closeSubpath()
            context.fill(path, with: .color(Color(nsColor: NSColor(white: 0.8, alpha: 1.0))))
        }
        .frame(width: 7, height: 7)
        .allowsHitTesting(false)
    }

    private func toolDisplayName(_ tool: Tool) -> String {
        switch tool {
        case .directSelection: return "Direct Selection"
        case .groupSelection: return "Group Selection"
        case .rect: return "Rectangle"
        case .polygon: return "Polygon"
        default: return tool.rawValue
        }
    }
}
