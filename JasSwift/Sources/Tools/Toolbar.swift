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

            case .deleteAnchorPoint:
                // Delete Anchor Point icon from SVG (viewBox 0 0 256 256), scaled to 28x28
                let s: CGFloat = 28.0 / 256.0
                let transform = CGAffineTransform(translationX: ox, y: oy).scaledBy(x: s, y: s)
                var nib = SwiftUI.Path()
                nib.move(to: CGPoint(x: 171.16, y: 209.05))
                nib.addLine(to: CGPoint(x: 83.32, y: 256.0))
                nib.addCurve(to: CGPoint(x: 72.34, y: 231.11),
                    control1: CGPoint(x: 79.37, y: 247.74), control2: CGPoint(x: 75.66, y: 239.67))
                nib.addCurve(to: CGPoint(x: 0.8, y: 161.2),
                    control1: CGPoint(x: 58.84, y: 196.29), control2: CGPoint(x: 34.83, y: 177.34))
                nib.addLine(to: CGPoint(x: 0.4, y: 106.59))
                nib.addLine(to: CGPoint(x: 0, y: 6.21))
                nib.addCurve(to: CGPoint(x: 4.05, y: 0.16),
                    control1: CGPoint(x: 0, y: 3.95), control2: CGPoint(x: 2.53, y: 0.66))
                nib.addCurve(to: CGPoint(x: 10.38, y: 1.67),
                    control1: CGPoint(x: 5.57, y: -0.34), control2: CGPoint(x: 8.47, y: 0.37))
                nib.addLine(to: CGPoint(x: 138.0, y: 87.83))
                nib.addCurve(to: CGPoint(x: 136.44, y: 104.0),
                    control1: CGPoint(x: 137.83, y: 93.34), control2: CGPoint(x: 137.19, y: 98.26))
                nib.addCurve(to: CGPoint(x: 149.25, y: 177.57),
                    control1: CGPoint(x: 133.14, y: 129.08), control2: CGPoint(x: 137.75, y: 154.95))
                nib.addLine(to: CGPoint(x: 171.15, y: 209.05))
                nib.closeSubpath()
                // Inner cutout
                nib.move(to: CGPoint(x: 126.23, y: 94.28))
                nib.addLine(to: CGPoint(x: 23.74, y: 25.13))
                nib.addLine(to: CGPoint(x: 64.38, y: 101.36))
                nib.addCurve(to: CGPoint(x: 64.69, y: 123.85),
                    control1: CGPoint(x: 59.16, y: 109.38), control2: CGPoint(x: 59.07, y: 117.72))
                nib.addCurve(to: CGPoint(x: 87.74, y: 124.59),
                    control1: CGPoint(x: 70.79, y: 130.51), control2: CGPoint(x: 79.99, y: 130.95))
                nib.addCurve(to: CGPoint(x: 92.78, y: 105.71),
                    control1: CGPoint(x: 94.31, y: 120.05), control2: CGPoint(x: 95.58, y: 112.34))
                nib.addCurve(to: CGPoint(x: 75.2, y: 95.38),
                    control1: CGPoint(x: 90.23, y: 99.59), control2: CGPoint(x: 83.64, y: 94.52))
                nib.addLine(to: CGPoint(x: 23.73, y: 25.13))
                nib.addLine(to: CGPoint(x: 126.23, y: 94.28))
                nib.closeSubpath()
                let nibTransformed = nib.applying(transform)
                context.fill(nibTransformed, with: .color(color), style: FillStyle(eoFill: true))
                // Minus sign (rotated rectangle)
                let minusTransform = CGAffineTransform(translationX: -31.37, y: 110.38)
                    .rotated(by: -28.0 * .pi / 180.0)
                var minus = SwiftUI.Path()
                minus.addRect(CGRect(x: 158.95, y: 110.41, width: 93.43, height: 15.36))
                let minusScaled = minus.applying(minusTransform).applying(transform)
                context.fill(minusScaled, with: .color(color))

            case .pencil:
                // Pencil icon from SVG paths (viewBox 0 0 256 256), scaled to 28x28.
                let s: CGFloat = 28.0 / 256.0
                let transform = CGAffineTransform(translationX: ox, y: oy).scaledBy(x: s, y: s)
                // Outer path (main outline)
                var outer = SwiftUI.Path()
                outer.move(to: CGPoint(x: 57.6, y: 233.77))
                outer.addLine(to: CGPoint(x: 5.83, y: 255.77))
                outer.addCurve(to: CGPoint(x: 0.12, y: 246.99), control1: CGPoint(x: 2.04, y: 257.38), control2: CGPoint(x: -0.59, y: 250.2))
                outer.addLine(to: CGPoint(x: 15.75, y: 175.88))
                outer.addCurve(to: CGPoint(x: 21.83, y: 161.79), control1: CGPoint(x: 16.99, y: 170.25), control2: CGPoint(x: 17.94, y: 166.36))
                outer.addLine(to: CGPoint(x: 108.97, y: 59.4))
                outer.addLine(to: CGPoint(x: 152.73, y: 9.16))
                outer.addCurve(to: CGPoint(x: 181.96, y: 3.06), control1: CGPoint(x: 159.64, y: 1.23), control2: CGPoint(x: 172.84, y: -3.41))
                outer.addCurve(to: CGPoint(x: 217.94, y: 33.93), control1: CGPoint(x: 195.07, y: 12.36), control2: CGPoint(x: 206.14, y: 22.95))
                outer.addCurve(to: CGPoint(x: 220.25, y: 62.13), control1: CGPoint(x: 225.32, y: 40.79), control2: CGPoint(x: 226.65, y: 54.5))
                outer.addLine(to: CGPoint(x: 191.96, y: 95.82))
                outer.addLine(to: CGPoint(x: 84.39, y: 222.9))
                outer.addCurve(to: CGPoint(x: 57.6, y: 233.78), control1: CGPoint(x: 75.27, y: 227.22), control2: CGPoint(x: 66.72, y: 229.9))
                outer.closeSubpath()
                let outerScaled = outer.applying(transform)
                context.fill(outerScaled, with: .color(color))
                // Gray facets
                let darkColor = SwiftUI.Color(nsColor: NSColor(white: 0.235, alpha: 1.0))
                var f1 = SwiftUI.Path()
                f1.move(to: CGPoint(x: 208.57, y: 55.33))
                f1.addCurve(to: CGPoint(x: 202.08, y: 36.15), control1: CGPoint(x: 212.62, y: 47.93), control2: CGPoint(x: 207.38, y: 40.51))
                f1.addLine(to: CGPoint(x: 177.08, y: 15.57))
                f1.addCurve(to: CGPoint(x: 149.01, y: 33.89), control1: CGPoint(x: 166.42, y: 6.79), control2: CGPoint(x: 154.72, y: 26.62))
                f1.addCurve(to: CGPoint(x: 193.41, y: 72.64), control1: CGPoint(x: 163.45, y: 47.79), control2: CGPoint(x: 177.29, y: 60.62))
                f1.addCurve(to: CGPoint(x: 208.57, y: 55.33), control1: CGPoint(x: 199.05, y: 66.99), control2: CGPoint(x: 204.86, y: 62.09))
                f1.closeSubpath()
                context.fill(f1.applying(transform), with: .color(darkColor))
                var f2 = SwiftUI.Path()
                f2.move(to: CGPoint(x: 70.01, y: 189.48))
                f2.addCurve(to: CGPoint(x: 56.07, y: 188.36), control1: CGPoint(x: 64.87, y: 189.83), control2: CGPoint(x: 59.66, y: 190.72))
                f2.addCurve(to: CGPoint(x: 53.23, y: 174.8), control1: CGPoint(x: 53.24, y: 186.5), control2: CGPoint(x: 52.14, y: 178.64))
                f2.addLine(to: CGPoint(x: 154.47, y: 55.84))
                f2.addCurve(to: CGPoint(x: 170.13, y: 70.41), control1: CGPoint(x: 160.42, y: 60.73), control2: CGPoint(x: 165.14, y: 64.9))
                f2.addLine(to: CGPoint(x: 70.01, y: 189.48))
                f2.closeSubpath()
                context.fill(f2.applying(transform), with: .color(darkColor))
                var f3 = SwiftUI.Path()
                f3.move(to: CGPoint(x: 47.55, y: 169.12))
                f3.addCurve(to: CGPoint(x: 34.86, y: 166.85), control1: CGPoint(x: 43.7, y: 170.57), control2: CGPoint(x: 37.83, y: 169.44))
                f3.addLine(to: CGPoint(x: 76.41, y: 117.48))
                f3.addLine(to: CGPoint(x: 108.97, y: 79.49))
                f3.addLine(to: CGPoint(x: 138.8, y: 44.51))
                f3.addCurve(to: CGPoint(x: 147.44, y: 51.6), control1: CGPoint(x: 142.42, y: 44.61), control2: CGPoint(x: 145.79, y: 48.23))
                f3.addLine(to: CGPoint(x: 102.14, y: 104.57))
                f3.addLine(to: CGPoint(x: 47.55, y: 169.11))
                f3.closeSubpath()
                context.fill(f3.applying(transform), with: .color(darkColor))
                var f4 = SwiftUI.Path()
                f4.move(to: CGPoint(x: 161.36, y: 111.12))
                f4.addLine(to: CGPoint(x: 93.27, y: 191.72))
                f4.addCurve(to: CGPoint(x: 79.55, y: 206.85), control1: CGPoint(x: 88.75, y: 197.06), control2: CGPoint(x: 84.94, y: 201.71))
                f4.addCurve(to: CGPoint(x: 78.52, y: 191.88), control1: CGPoint(x: 76.45, y: 203.48), control2: CGPoint(x: 74.45, y: 196.7))
                f4.addLine(to: CGPoint(x: 176.03, y: 76.63))
                f4.addCurve(to: CGPoint(x: 184.28, y: 83.19), control1: CGPoint(x: 179.47, y: 77.08), control2: CGPoint(x: 184.55, y: 80.31))
                f4.addLine(to: CGPoint(x: 161.36, y: 111.13))
                f4.closeSubpath()
                context.fill(f4.applying(transform), with: .color(darkColor))
                // White tip highlight
                var tipPath = SwiftUI.Path()
                tipPath.move(to: CGPoint(x: 71.47, y: 214.03))
                tipPath.addCurve(to: CGPoint(x: 39.16, y: 227.63), control1: CGPoint(x: 60.16, y: 218.55), control2: CGPoint(x: 50.33, y: 222.1))
                tipPath.addLine(to: CGPoint(x: 21.93, y: 214.37))
                tipPath.addCurve(to: CGPoint(x: 24.61, y: 197.77), control1: CGPoint(x: 22.92, y: 208.81), control2: CGPoint(x: 23.28, y: 203.26))
                tipPath.addLine(to: CGPoint(x: 29.0, y: 179.73))
                tipPath.addCurve(to: CGPoint(x: 42.67, y: 180.44), control1: CGPoint(x: 30.63, y: 176.51), control2: CGPoint(x: 40.55, y: 177.54))
                tipPath.addCurve(to: CGPoint(x: 49.8, y: 196.26), control1: CGPoint(x: 45.87, y: 184.84), control2: CGPoint(x: 45.86, y: 192.69))
                tipPath.addCurve(to: CGPoint(x: 64.72, y: 199.43), control1: CGPoint(x: 53.77, y: 199.86), control2: CGPoint(x: 60.42, y: 197.04))
                tipPath.addCurve(to: CGPoint(x: 71.47, y: 214.03), control1: CGPoint(x: 69.02, y: 201.82), control2: CGPoint(x: 69.61, y: 208.63))
                tipPath.closeSubpath()
                context.fill(tipPath.applying(transform), with: .color(.white))

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
