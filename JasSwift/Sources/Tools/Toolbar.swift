import SwiftUI
import AppKit

/// Tool button and icon drawing utilities for the toolbar.
public struct ToolbarView {
    static func toolButton(currentTool: Binding<Tool>, tool: Tool) -> some View {
        Button(action: { currentTool.wrappedValue = tool }) {
            toolIcon(tool)
                .frame(width: 32, height: 32)
                .background(currentTool.wrappedValue == tool
                    ? SwiftUI.Color(nsColor: NSColor(white: 0.38, alpha: 1.0))
                    : SwiftUI.Color.clear)
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
            let color = SwiftUI.Color(nsColor: NSColor(white: 0.8, alpha: 1.0))

            switch tool {
            case .selection:
                // Black arrow with white border
                let p = arrowPath(ox: ox, oy: oy)
                context.fill(p, with: .color(.black))
                context.stroke(p, with: .color(.white), lineWidth: 1.0)

            case .directSelection:
                // White arrow with black border
                let p = arrowPath(ox: ox, oy: oy)
                context.fill(p, with: .color(.white))
                context.stroke(p, with: .color(.black), lineWidth: 1.0)

            case .groupSelection:
                // White arrow with black border
                let p = arrowPath(ox: ox, oy: oy)
                context.fill(p, with: .color(.white))
                context.stroke(p, with: .color(.black), lineWidth: 1.0)
                // Draw '+' badge in lower-right
                var plus = SwiftUI.Path()
                plus.move(to: CGPoint(x: ox + 20, y: oy + 20))
                plus.addLine(to: CGPoint(x: ox + 27, y: oy + 20))
                plus.move(to: CGPoint(x: ox + 23.5, y: oy + 16.5))
                plus.addLine(to: CGPoint(x: ox + 23.5, y: oy + 23.5))
                context.stroke(plus, with: .color(.black), lineWidth: 1.5)

            case .pen:
                // Pen icon from SVG paths (viewBox 0 0 256 256), scaled to 28x28
                let s: CGFloat = 28.0 / 256.0
                let transform = CGAffineTransform(translationX: ox, y: oy).scaledBy(x: s, y: s)
                // Outer path
                var outer = SwiftUI.Path()
                outer.move(to: CGPoint(x: 163.07, y: 190.51))
                outer.addLine(to: CGPoint(x: 175.61, y: 210.03))
                outer.addLine(to: CGPoint(x: 84.93, y: 255.99))
                outer.addLine(to: CGPoint(x: 72.47, y: 227.94))
                outer.addCurve(to: CGPoint(x: 0.13, y: 161.51),
                    control1: CGPoint(x: 58.86, y: 195.29), control2: CGPoint(x: 32.68, y: 176.45))
                outer.addLine(to: CGPoint(x: 0, y: 4.58))
                outer.addCurve(to: CGPoint(x: 4.11, y: -0.37),
                    control1: CGPoint(x: 0, y: 2.38), control2: CGPoint(x: 2.8, y: -0.28))
                outer.addCurve(to: CGPoint(x: 9.42, y: 0.97),
                    control1: CGPoint(x: 5.42, y: -0.46), control2: CGPoint(x: 8.07, y: 0.08))
                outer.addLine(to: CGPoint(x: 94.84, y: 57.3))
                outer.addLine(to: CGPoint(x: 143.22, y: 89.45))
                outer.addCurve(to: CGPoint(x: 163.08, y: 190.51),
                    control1: CGPoint(x: 135.93, y: 124.03), control2: CGPoint(x: 139.17, y: 161.04))
                outer.closeSubpath()
                // Inner cutout
                outer.move(to: CGPoint(x: 61.7, y: 49.58))
                outer.addLine(to: CGPoint(x: 23.48, y: 24.2))
                outer.addLine(to: CGPoint(x: 65.56, y: 102.31))
                outer.addCurve(to: CGPoint(x: 83.05, y: 111.1),
                    control1: CGPoint(x: 73.04, y: 102.48), control2: CGPoint(x: 79.74, y: 105.2))
                outer.addCurve(to: CGPoint(x: 82.1, y: 129.97),
                    control1: CGPoint(x: 86.36, y: 117.0), control2: CGPoint(x: 86.92, y: 124.26))
                outer.addCurve(to: CGPoint(x: 57.38, y: 133.01),
                    control1: CGPoint(x: 75.74, y: 137.51), control2: CGPoint(x: 64.43, y: 138.54))
                outer.addCurve(to: CGPoint(x: 54.52, y: 108.06),
                    control1: CGPoint(x: 49.55, y: 126.87), control2: CGPoint(x: 47.97, y: 116.88))
                outer.addLine(to: CGPoint(x: 12.09, y: 30.4))
                outer.addLine(to: CGPoint(x: 12.53, y: 100.36))
                outer.addLine(to: CGPoint(x: 12.24, y: 154.67))
                outer.addCurve(to: CGPoint(x: 73.77, y: 206.51),
                    control1: CGPoint(x: 37.86, y: 166.32), control2: CGPoint(x: 59.12, y: 182.87))
                outer.addLine(to: CGPoint(x: 138.57, y: 173.27))
                outer.addCurve(to: CGPoint(x: 130.1, y: 95.08),
                    control1: CGPoint(x: 127.46, y: 148.19), control2: CGPoint(x: 124.88, y: 122.64))
                outer.addLine(to: CGPoint(x: 61.7, y: 49.58))
                outer.closeSubpath()
                let transformed = outer.applying(transform)
                context.fill(transformed, with: .color(color), style: FillStyle(eoFill: true))

            case .addAnchorPoint:
                // Add anchor point icon from SVG (viewBox 0 0 256 256), scaled to 28x28
                let s: CGFloat = 28.0 / 256.0
                let transform = CGAffineTransform(translationX: ox, y: oy).scaledBy(x: s, y: s)
                // Pen nib outer path with inner cutout (eoFill)
                var nib = SwiftUI.Path()
                nib.move(to: CGPoint(x: 170.82, y: 209.27))
                nib.addLine(to: CGPoint(x: 82.74, y: 256.0))
                nib.addLine(to: CGPoint(x: 71.75, y: 230.69))
                nib.addCurve(to: CGPoint(x: 0.51, y: 162.2),
                    control1: CGPoint(x: 60.04, y: 197.72), control2: CGPoint(x: 31.98, y: 175.62))
                nib.addLine(to: CGPoint(x: 0.07, y: 55.68))
                nib.addLine(to: CGPoint(x: 0, y: 7.02))
                nib.addCurve(to: CGPoint(x: 1.66, y: 1.26),
                    control1: CGPoint(x: 0, y: 5.03), control2: CGPoint(x: 0.62, y: 2.32))
                nib.addCurve(to: CGPoint(x: 8.2, y: 0.39),
                    control1: CGPoint(x: 2.7, y: 0.2), control2: CGPoint(x: 6.93, y: -0.46))
                nib.addLine(to: CGPoint(x: 138.64, y: 88.51))
                nib.addCurve(to: CGPoint(x: 153.1, y: 182.9),
                    control1: CGPoint(x: 133.74, y: 121.05), control2: CGPoint(x: 134.34, y: 149.06))
                nib.addLine(to: CGPoint(x: 170.82, y: 209.27))
                nib.closeSubpath()
                // Inner cutout
                nib.move(to: CGPoint(x: 126.44, y: 94.04))
                nib.addLine(to: CGPoint(x: 22.84, y: 24.64))
                nib.addLine(to: CGPoint(x: 64.53, y: 103.04))
                nib.addCurve(to: CGPoint(x: 83.05, y: 111.1),
                    control1: CGPoint(x: 73.04, y: 102.48), control2: CGPoint(x: 79.74, y: 105.2))
                nib.addCurve(to: CGPoint(x: 82.1, y: 129.97),
                    control1: CGPoint(x: 86.36, y: 117.0), control2: CGPoint(x: 86.92, y: 124.26))
                nib.addCurve(to: CGPoint(x: 57.38, y: 133.01),
                    control1: CGPoint(x: 75.74, y: 137.51), control2: CGPoint(x: 64.43, y: 138.54))
                nib.addCurve(to: CGPoint(x: 54.52, y: 108.06),
                    control1: CGPoint(x: 49.55, y: 126.87), control2: CGPoint(x: 47.97, y: 116.88))
                nib.addLine(to: CGPoint(x: 12.09, y: 30.4))
                nib.addLine(to: CGPoint(x: 12.53, y: 100.36))
                nib.addLine(to: CGPoint(x: 12.24, y: 154.67))
                nib.addCurve(to: CGPoint(x: 73.77, y: 206.51),
                    control1: CGPoint(x: 37.86, y: 166.32), control2: CGPoint(x: 59.12, y: 182.87))
                nib.addLine(to: CGPoint(x: 138.57, y: 173.27))
                nib.addCurve(to: CGPoint(x: 130.1, y: 95.08),
                    control1: CGPoint(x: 127.46, y: 148.19), control2: CGPoint(x: 124.88, y: 122.64))
                nib.addLine(to: CGPoint(x: 126.44, y: 94.04))
                nib.closeSubpath()
                let nibTransformed = nib.applying(transform)
                context.fill(nibTransformed, with: .color(color), style: FillStyle(eoFill: true))
                // Plus sign (separate fill, not eoFill)
                var plus = SwiftUI.Path()
                plus.move(to: CGPoint(x: 232.87, y: 153.61))
                plus.addCurve(to: CGPoint(x: 219.01, y: 161.41),
                    control1: CGPoint(x: 229.4, y: 156.72), control2: CGPoint(x: 224.13, y: 159.31))
                plus.addLine(to: CGPoint(x: 200.67, y: 127.38))
                plus.addLine(to: CGPoint(x: 166.99, y: 145.47))
                plus.addLine(to: CGPoint(x: 159.35, y: 132.09))
                plus.addLine(to: CGPoint(x: 193.51, y: 113.89))
                plus.addLine(to: CGPoint(x: 175.05, y: 78.74))
                plus.addLine(to: CGPoint(x: 188.64, y: 71.1))
                plus.addLine(to: CGPoint(x: 207.47, y: 106.52))
                plus.addLine(to: CGPoint(x: 240.85, y: 88.53))
                plus.addLine(to: CGPoint(x: 248.17, y: 101.98))
                plus.addLine(to: CGPoint(x: 214.87, y: 120.12))
                plus.addLine(to: CGPoint(x: 232.86, y: 153.58))
                plus.closeSubpath()
                let plusTransformed = plus.applying(transform)
                context.fill(plusTransformed, with: .color(color))

            case .pencil:
                var path = SwiftUI.Path()
                // Pencil body (angled)
                path.move(to: CGPoint(x: ox + 6, y: oy + 22))
                path.addLine(to: CGPoint(x: ox + 20, y: oy + 8))
                path.addLine(to: CGPoint(x: ox + 24, y: oy + 4))
                path.addLine(to: CGPoint(x: ox + 26, y: oy + 6))
                path.addLine(to: CGPoint(x: ox + 22, y: oy + 10))
                path.addLine(to: CGPoint(x: ox + 8, y: oy + 24))
                path.closeSubpath()
                context.stroke(path, with: .color(color), lineWidth: 1.5)
                // Tip
                var tip = SwiftUI.Path()
                tip.move(to: CGPoint(x: ox + 6, y: oy + 22))
                tip.addLine(to: CGPoint(x: ox + 4, y: oy + 26))
                tip.addLine(to: CGPoint(x: ox + 8, y: oy + 24))
                context.stroke(tip, with: .color(color), lineWidth: 1.5)

            case .text:
                context.draw(
                    SwiftUI.Text("T").font(.system(size: 18, weight: .bold))
                        .foregroundColor(SwiftUI.Color(nsColor: NSColor(white: 0.8, alpha: 1.0))),
                    at: CGPoint(x: size.width / 2, y: size.height / 2)
                )

            case .textPath:
                // "T" with a wavy path
                context.draw(
                    SwiftUI.Text("T").font(.system(size: 14, weight: .bold))
                        .foregroundColor(SwiftUI.Color(nsColor: NSColor(white: 0.8, alpha: 1.0))),
                    at: CGPoint(x: ox + 7, y: size.height / 2)
                )
                var wavePath = SwiftUI.Path()
                wavePath.move(to: CGPoint(x: ox + 12, y: oy + 20))
                wavePath.addCurve(to: CGPoint(x: ox + 26, y: oy + 12),
                                  control1: CGPoint(x: ox + 16, y: oy + 8),
                                  control2: CGPoint(x: ox + 22, y: oy + 24))
                context.stroke(wavePath, with: .color(color), lineWidth: 1.0)

            case .line:
                var path = SwiftUI.Path()
                path.move(to: CGPoint(x: ox + 4, y: oy + 24))
                path.addLine(to: CGPoint(x: ox + 24, y: oy + 4))
                context.stroke(path, with: .color(color), lineWidth: 2.0)

            case .rect:
                let rect = CGRect(x: ox + 4, y: oy + 6, width: 20, height: 16)
                context.stroke(SwiftUI.Path(rect), with: .color(color), lineWidth: 1.5)

            case .polygon:
                let cx = ox + 14.0, cy = oy + 14.0, r = 11.0
                let n = 6
                var path = SwiftUI.Path()
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

    private static func arrowPath(ox: CGFloat, oy: CGFloat) -> SwiftUI.Path {
        var path = SwiftUI.Path()
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
                ? SwiftUI.Color(nsColor: NSColor(white: 0.38, alpha: 1.0))
                : SwiftUI.Color.clear)
            .cornerRadius(3)
            .onTapGesture {
                currentTool = visibleTool
            }
            .onLongPressGesture(minimumDuration: longPressDuration) {
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
                                SwiftUI.Text(toolDisplayName(tool))
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
            var path = SwiftUI.Path()
            let s: CGFloat = 5
            path.move(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: size.width - s, y: size.height))
            path.addLine(to: CGPoint(x: size.width, y: size.height - s))
            path.closeSubpath()
            context.fill(path, with: .color(SwiftUI.Color(nsColor: NSColor(white: 0.8, alpha: 1.0))))
        }
        .frame(width: 7, height: 7)
        .allowsHitTesting(false)
    }

    private func toolDisplayName(_ tool: Tool) -> String {
        switch tool {
        case .directSelection: return "Direct Selection"
        case .groupSelection: return "Group Selection"
        case .pen: return "Pen"
        case .addAnchorPoint: return "Add Anchor Point"
        case .pencil: return "Pencil"
        case .text: return "Text"
        case .textPath: return "Text on Path"
        case .rect: return "Rectangle"
        case .polygon: return "Polygon"
        default: return tool.rawValue
        }
    }
}
