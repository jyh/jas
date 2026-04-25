import SwiftUI
import AppKit

/// Current theme colors for toolbar rendering — updated by switchAppearance().
public var toolbarCheckedBg = NSColor(white: 0.38, alpha: 1.0)
public var toolbarIconColor = NSColor(white: 0.8, alpha: 1.0)

/// Tool button and icon drawing utilities for the toolbar.
public struct ToolbarView {
    /// Optional double-click handler. When set, double-clicking the
    /// tool icon invokes this closure with the current tool; the
    /// parent view looks up the tool's tool_options_dialog field and
    /// dispatches open_dialog. See PAINTBRUSH_TOOL.md §Tool options.
    static func toolButton(
        currentTool: Binding<Tool>,
        tool: Tool,
        onRequestOptions: ((Tool) -> Void)? = nil
    ) -> some View {
        Button(action: { currentTool.wrappedValue = tool }) {
            toolIcon(tool)
                .frame(width: 32, height: 32)
                .background(currentTool.wrappedValue == tool
                    ? SwiftUI.Color(nsColor: toolbarCheckedBg)
                    : SwiftUI.Color.clear)
                .cornerRadius(3)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            onRequestOptions?(tool)
        })
    }

    /// A button that shows one tool but long-press reveals alternates.
    static func toolButtonWithAlternates(
        currentTool: Binding<Tool>,
        visibleTool: Binding<Tool>,
        alternates: [Tool],
        onRequestOptions: ((Tool) -> Void)? = nil
    ) -> some View {
        ArrowSlotButton(
            currentTool: currentTool,
            visibleTool: visibleTool,
            alternates: alternates,
            onRequestOptions: onRequestOptions
        )
    }

    static func toolIcon(_ tool: Tool) -> some View {
        Canvas { context, size in
            let ox = (size.width - 28) / 2
            let oy = (size.height - 28) / 2
            let color = SwiftUI.Color(nsColor: toolbarIconColor)

            switch tool {
            case .selection:
                // Black arrow with white border
                let p = arrowPath(ox: ox, oy: oy)
                context.fill(p, with: .color(.black))
                context.stroke(p, with: .color(.white), lineWidth: 1.0)

            case .partialSelection:
                // White arrow with black border
                let p = arrowPath(ox: ox, oy: oy)
                context.fill(p, with: .color(.white))
                context.stroke(p, with: .color(.black), lineWidth: 1.0)

            case .interiorSelection:
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

            case .magicWand:
                // Diagonal handle (lower-left → upper-right) +
                // 4-point sparkle at the tip + small accent star.
                // Matches workspace/icons.yaml magic_wand entry and
                // examples/magic-wand.png.
                var handle = SwiftUI.Path()
                handle.move(to: CGPoint(x: ox + 4, y: oy + 22))
                handle.addLine(to: CGPoint(x: ox + 18, y: oy + 8))
                context.stroke(handle, with: .color(color),
                               style: .init(lineWidth: 2, lineCap: .round))
                var sparkle = SwiftUI.Path()
                sparkle.move(to: CGPoint(x: ox + 20, y: oy + 3))
                sparkle.addLine(to: CGPoint(x: ox + 21, y: oy + 7))
                sparkle.addLine(to: CGPoint(x: ox + 25, y: oy + 8))
                sparkle.addLine(to: CGPoint(x: ox + 21, y: oy + 9))
                sparkle.addLine(to: CGPoint(x: ox + 20, y: oy + 13))
                sparkle.addLine(to: CGPoint(x: ox + 19, y: oy + 9))
                sparkle.addLine(to: CGPoint(x: ox + 15, y: oy + 8))
                sparkle.addLine(to: CGPoint(x: ox + 19, y: oy + 7))
                sparkle.closeSubpath()
                context.fill(sparkle, with: .color(color))
                var accent = SwiftUI.Path()
                accent.move(to: CGPoint(x: ox + 24, y: oy + 12))
                accent.addLine(to: CGPoint(x: ox + 24.7, y: oy + 13.5))
                accent.addLine(to: CGPoint(x: ox + 26.5, y: oy + 14))
                accent.addLine(to: CGPoint(x: ox + 24.7, y: oy + 14.5))
                accent.addLine(to: CGPoint(x: ox + 24, y: oy + 16))
                accent.addLine(to: CGPoint(x: ox + 23.3, y: oy + 14.5))
                accent.addLine(to: CGPoint(x: ox + 21.5, y: oy + 14))
                accent.addLine(to: CGPoint(x: ox + 23.3, y: oy + 13.5))
                accent.closeSubpath()
                context.fill(accent, with: .color(color))

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

            case .paintbrush:
                // Paintbrush — angled handle + ferrule + rounded
                // bristled tip. Matches PAINTBRUSH_TOOL.md §Tool icon
                // (Rust icons.rs equivalent).
                let s: CGFloat = 28.0 / 256.0
                let transform = CGAffineTransform(translationX: ox, y: oy).scaledBy(x: s, y: s)

                // Handle (diagonal)
                var handle = SwiftUI.Path()
                handle.move(to: CGPoint(x: 30, y: 230))
                handle.addLine(to: CGPoint(x: 60, y: 255))
                handle.addLine(to: CGPoint(x: 200, y: 115))
                handle.addLine(to: CGPoint(x: 165, y: 80))
                handle.closeSubpath()
                context.fill(handle.applying(transform), with: .color(color))

                // Ferrule (rotated darker band)
                let ferruleTx = CGAffineTransform(translationX: -187, y: -75)
                    .rotated(by: -45 * .pi / 180)
                    .translatedBy(x: 187, y: 75)
                var ferrule = SwiftUI.Path()
                ferrule.addRect(CGRect(x: 165, y: 60, width: 45, height: 30))
                let darkColor = SwiftUI.Color(nsColor: NSColor(white: 0.39, alpha: 1.0))
                context.fill(ferrule.applying(ferruleTx).applying(transform),
                             with: .color(darkColor))

                // Bristled tip
                var tip = SwiftUI.Path()
                tip.move(to: CGPoint(x: 195, y: 45))
                tip.addQuadCurve(to: CGPoint(x: 250, y: 40),
                                 control: CGPoint(x: 225, y: 20))
                tip.addQuadCurve(to: CGPoint(x: 225, y: 90),
                                 control: CGPoint(x: 255, y: 70))
                tip.addLine(to: CGPoint(x: 185, y: 65))
                tip.closeSubpath()
                context.fill(tip.applying(transform), with: .color(color))

                // Bristle highlights
                var hi1 = SwiftUI.Path()
                hi1.move(to: CGPoint(x: 205, y: 55))
                hi1.addLine(to: CGPoint(x: 225, y: 82))
                var hi2 = SwiftUI.Path()
                hi2.move(to: CGPoint(x: 220, y: 45))
                hi2.addLine(to: CGPoint(x: 238, y: 70))
                var hi3 = SwiftUI.Path()
                hi3.move(to: CGPoint(x: 235, y: 45))
                hi3.addLine(to: CGPoint(x: 242, y: 75))
                context.stroke(hi1.applying(transform), with: .color(.white), lineWidth: 4)
                context.stroke(hi2.applying(transform), with: .color(.white), lineWidth: 4)
                context.stroke(hi3.applying(transform), with: .color(.white), lineWidth: 4)

            case .blobBrush:
                // Blob Brush — angled handle + ferrule, filled oval
                // tip, and a filled blob trail below. Distinct from
                // Paintbrush's bristled tip: emphasizes filled-region
                // output. Matches BLOB_BRUSH_TOOL.md §Tool icon.
                let s: CGFloat = 28.0 / 256.0
                let transform = CGAffineTransform(translationX: ox, y: oy).scaledBy(x: s, y: s)

                // Handle (diagonal, shared with Paintbrush shape)
                var handle = SwiftUI.Path()
                handle.move(to: CGPoint(x: 30, y: 230))
                handle.addLine(to: CGPoint(x: 60, y: 255))
                handle.addLine(to: CGPoint(x: 200, y: 115))
                handle.addLine(to: CGPoint(x: 165, y: 80))
                handle.closeSubpath()
                context.fill(handle.applying(transform), with: .color(color))

                // Ferrule (rotated darker band)
                let ferruleTx = CGAffineTransform(translationX: -187, y: -75)
                    .rotated(by: -45 * .pi / 180)
                    .translatedBy(x: 187, y: 75)
                var ferrule = SwiftUI.Path()
                ferrule.addRect(CGRect(x: 165, y: 60, width: 45, height: 30))
                let darkColor = SwiftUI.Color(nsColor: NSColor(white: 0.39, alpha: 1.0))
                context.fill(ferrule.applying(ferruleTx).applying(transform),
                             with: .color(darkColor))

                // Filled oval tip
                var tip = SwiftUI.Path()
                tip.addEllipse(in: CGRect(x: 180, y: 32, width: 80, height: 56))
                context.fill(tip.applying(transform), with: .color(color))

                // Filled wavy blob trail
                var trail = SwiftUI.Path()
                trail.move(to: CGPoint(x: 50, y: 250))
                trail.addQuadCurve(to: CGPoint(x: 115, y: 240),
                                   control: CGPoint(x: 80, y: 230))
                trail.addQuadCurve(to: CGPoint(x: 175, y: 245),
                                   control: CGPoint(x: 145, y: 255))
                trail.addQuadCurve(to: CGPoint(x: 225, y: 245),
                                   control: CGPoint(x: 205, y: 230))
                trail.addQuadCurve(to: CGPoint(x: 230, y: 250),
                                   control: CGPoint(x: 245, y: 265))
                trail.addQuadCurve(to: CGPoint(x: 185, y: 245),
                                   control: CGPoint(x: 210, y: 235))
                trail.addQuadCurve(to: CGPoint(x: 125, y: 250),
                                   control: CGPoint(x: 155, y: 260))
                trail.addQuadCurve(to: CGPoint(x: 55, y: 260),
                                   control: CGPoint(x: 90, y: 240))
                trail.closeSubpath()
                context.fill(trail.applying(transform), with: .color(color))

            case .pathEraser:
                // Path Eraser icon from SVG paths (viewBox 0 0 256 256), scaled to 28x28
                let s: CGFloat = 28.0 / 256.0
                let transform = CGAffineTransform(translationX: ox, y: oy).scaledBy(x: s, y: s)
                let darkColor = SwiftUI.Color(nsColor: NSColor(white: 0.235, alpha: 1.0))

                // Outer outline
                var outer = SwiftUI.Path()
                outer.move(to: CGPoint(x: 169.86, y: 33.13))
                outer.addLine(to: CGPoint(x: 243.34, y: 1.82))
                outer.addCurve(to: CGPoint(x: 253.26, y: 1.3),
                    control1: CGPoint(x: 246.77, y: 0.36), control2: CGPoint(x: 249.73, y: -1.15))
                outer.addCurve(to: CGPoint(x: 255.67, y: 10.06),
                    control1: CGPoint(x: 255.47, y: 2.84), control2: CGPoint(x: 256.6, y: 6.18))
                outer.addLine(to: CGPoint(x: 236.36, y: 90.59))
                outer.addLine(to: CGPoint(x: 128.34, y: 216.3))
                outer.addLine(to: CGPoint(x: 100.36, y: 247.5))
                outer.addCurve(to: CGPoint(x: 64.8, y: 249.13),
                    control1: CGPoint(x: 90.73, y: 258.24), control2: CGPoint(x: 75.45, y: 258.84))
                outer.addLine(to: CGPoint(x: 36.8, y: 223.61))
                outer.addCurve(to: CGPoint(x: 35.38, y: 190.66),
                    control1: CGPoint(x: 27.71, y: 215.33), control2: CGPoint(x: 27.26, y: 200.13))
                outer.addLine(to: CGPoint(x: 76.02, y: 143.21))
                outer.addLine(to: CGPoint(x: 169.85, y: 33.13))
                outer.closeSubpath()
                context.fill(outer.applying(transform), with: .color(color))

                // Gray facets
                var f1 = SwiftUI.Path()
                f1.move(to: CGPoint(x: 184.63, y: 65.93))
                f1.addCurve(to: CGPoint(x: 198.13, y: 68.25),
                    control1: CGPoint(x: 189.51, y: 66.39), control2: CGPoint(x: 194.59, y: 66.2))
                f1.addCurve(to: CGPoint(x: 201.14, y: 81.28),
                    control1: CGPoint(x: 201.04, y: 69.93), control2: CGPoint(x: 203.57, y: 78.45))
                f1.addLine(to: CGPoint(x: 116.25, y: 180.28))
                f1.addCurve(to: CGPoint(x: 100.36, y: 164.52),
                    control1: CGPoint(x: 109.28, y: 176.56), control2: CGPoint(x: 104.39, y: 171.21))
                f1.addLine(to: CGPoint(x: 184.63, y: 65.93))
                f1.closeSubpath()
                context.fill(f1.applying(transform), with: .color(darkColor))

                var f2 = SwiftUI.Path()
                f2.move(to: CGPoint(x: 44.69, y: 212.9))
                f2.addCurve(to: CGPoint(x: 61.74, y: 180.12),
                    control1: CGPoint(x: 36.95, y: 201.82), control2: CGPoint(x: 53.37, y: 190.58))
                f2.addLine(to: CGPoint(x: 106.79, y: 221.05))
                f2.addLine(to: CGPoint(x: 90.97, y: 239.52))
                f2.addCurve(to: CGPoint(x: 64.2, y: 232.21),
                    control1: CGPoint(x: 82.2, y: 249.76), control2: CGPoint(x: 69.76, y: 237.13))
                f2.addCurve(to: CGPoint(x: 44.68, y: 212.9),
                    control1: CGPoint(x: 57.24, y: 226.04), control2: CGPoint(x: 50.08, y: 220.63))
                f2.closeSubpath()
                context.fill(f2.applying(transform), with: .color(darkColor))

                var f3 = SwiftUI.Path()
                f3.move(to: CGPoint(x: 207.17, y: 85.96))
                f3.addCurve(to: CGPoint(x: 220.02, y: 89.55),
                    control1: CGPoint(x: 211.98, y: 85.74), control2: CGPoint(x: 215.71, y: 86.73))
                f3.addLine(to: CGPoint(x: 154.89, y: 165.84))
                f3.addLine(to: CGPoint(x: 131.54, y: 192.84))
                f3.addCurve(to: CGPoint(x: 122.92, y: 184.95),
                    control1: CGPoint(x: 127.63, y: 191.48), control2: CGPoint(x: 125.1, y: 188.78))
                f3.addLine(to: CGPoint(x: 207.17, y: 85.97))
                f3.closeSubpath()
                context.fill(f3.applying(transform), with: .color(darkColor))

                var f4 = SwiftUI.Path()
                f4.move(to: CGPoint(x: 124.64, y: 106.13))
                f4.addLine(to: CGPoint(x: 175.0, y: 47.68))
                f4.addCurve(to: CGPoint(x: 178.33, y: 59.8),
                    control1: CGPoint(x: 177.8, y: 51.64), control2: CGPoint(x: 180.01, y: 56.74))
                f4.addCurve(to: CGPoint(x: 158.5, y: 84.62),
                    control1: CGPoint(x: 173.13, y: 69.28), control2: CGPoint(x: 165.51, y: 76.42))
                f4.addLine(to: CGPoint(x: 95.94, y: 157.83))
                f4.addCurve(to: CGPoint(x: 89.56, y: 157.97),
                    control1: CGPoint(x: 93.95, y: 160.16), control2: CGPoint(x: 90.93, y: 158.89))
                f4.addCurve(to: CGPoint(x: 86.41, y: 151.47),
                    control1: CGPoint(x: 87.97, y: 156.9), control2: CGPoint(x: 84.31, y: 153.0))
                f4.addCurve(to: CGPoint(x: 116.95, y: 115.69),
                    control1: CGPoint(x: 96.6, y: 139.21), control2: CGPoint(x: 107.11, y: 127.91))
                f4.addLine(to: CGPoint(x: 124.64, y: 106.13))
                f4.closeSubpath()
                context.fill(f4.applying(transform), with: .color(darkColor))

                // White tip
                var tip = SwiftUI.Path()
                tip.move(to: CGPoint(x: 183.88, y: 41.54))
                tip.addCurve(to: CGPoint(x: 208.22, y: 31.18),
                    control1: CGPoint(x: 191.96, y: 36.87), control2: CGPoint(x: 200.2, y: 34.23))
                tip.addCurve(to: CGPoint(x: 232.64, y: 41.38),
                    control1: CGPoint(x: 221.06, y: 26.3), control2: CGPoint(x: 214.11, y: 26.93))
                tip.addCurve(to: CGPoint(x: 225.67, y: 77.25),
                    control1: CGPoint(x: 235.55, y: 41.71), control2: CGPoint(x: 227.33, y: 76.83))
                tip.addCurve(to: CGPoint(x: 210.75, y: 75.03),
                    control1: CGPoint(x: 222.3, y: 80.28), control2: CGPoint(x: 212.1, y: 79.09))
                tip.addLine(to: CGPoint(x: 205.76, y: 60.03))
                tip.addLine(to: CGPoint(x: 189.06, y: 56.22))
                tip.addCurve(to: CGPoint(x: 183.89, y: 41.54),
                    control1: CGPoint(x: 184.53, y: 55.19), control2: CGPoint(x: 184.95, y: 47.11))
                tip.closeSubpath()
                context.fill(tip.applying(transform), with: .color(.white))

                // White band (rotated rectangle)
                let bandAngle = 131.58 * .pi / 180.0
                let pivotX = 299.56, pivotY = 239.09
                let bandTransform = CGAffineTransform(translationX: pivotX, y: pivotY)
                    .rotated(by: bandAngle)
                    .translatedBy(x: -pivotX, y: -pivotY)
                    .translatedBy(x: 88.74, y: 155.97)
                var band = SwiftUI.Path()
                band.addRect(CGRect(x: 0, y: 0, width: 14.58, height: 61.84))
                let bandScaled = band.applying(bandTransform).applying(transform)
                context.fill(bandScaled, with: .color(.white))

            case .smooth:
                // Smooth icon: pencil body + "S" lettering (viewBox 0 0 256 256), scaled to 28x28
                let s: CGFloat = 28.0 / 256.0
                let transform = CGAffineTransform(translationX: ox, y: oy).scaledBy(x: s, y: s)
                let darkColor = SwiftUI.Color(nsColor: NSColor(white: 0.235, alpha: 1.0))
                // Pencil body
                var outer = SwiftUI.Path()
                outer.move(to: CGPoint(x: 70.89, y: 227.68))
                outer.addLine(to: CGPoint(x: 4.52, y: 255.09))
                outer.addCurve(to: CGPoint(x: -0.16, y: 245.21), control1: CGPoint(x: 0.88, y: 256.59), control2: CGPoint(x: -0.91, y: 248.43))
                outer.addLine(to: CGPoint(x: 17.39, y: 169.99))
                outer.addCurve(to: CGPoint(x: 39.68, y: 143.64), control1: CGPoint(x: 24.75, y: 160.38), control2: CGPoint(x: 31.97, y: 152.72))
                outer.addLine(to: CGPoint(x: 131.03, y: 36.05))
                outer.addLine(to: CGPoint(x: 144.21, y: 21.29))
                outer.addCurve(to: CGPoint(x: 179.56, y: 21.24), control1: CGPoint(x: 154.4, y: 9.87), control2: CGPoint(x: 168.74, y: 11.64))
                outer.addLine(to: CGPoint(x: 205.01, y: 43.83))
                outer.addCurve(to: CGPoint(x: 204.99, y: 75.55), control1: CGPoint(x: 214.73, y: 52.45), control2: CGPoint(x: 213.09, y: 65.99))
                outer.addLine(to: CGPoint(x: 174.64, y: 111.37))
                outer.addLine(to: CGPoint(x: 86.01, y: 216.71))
                outer.addCurve(to: CGPoint(x: 70.89, y: 227.68), control1: CGPoint(x: 81.53, y: 222.03), control2: CGPoint(x: 77.91, y: 224.78))
                outer.closeSubpath()
                context.fill(outer.applying(transform), with: .color(color))
                // Gray facets
                var f1 = SwiftUI.Path()
                f1.move(to: CGPoint(x: 66.39, y: 191.49))
                f1.addCurve(to: CGPoint(x: 52.22, y: 192.25), control1: CGPoint(x: 63.13, y: 195.37), control2: CGPoint(x: 55.31, y: 192.23))
                f1.addCurve(to: CGPoint(x: 49.59, y: 179.38), control1: CGPoint(x: 50.62, y: 187.3), control2: CGPoint(x: 49.74, y: 184.33))
                f1.addLine(to: CGPoint(x: 145.52, y: 66.15))
                f1.addCurve(to: CGPoint(x: 160.81, y: 79.96), control1: CGPoint(x: 151.28, y: 70.25), control2: CGPoint(x: 156.08, y: 74.56))
                f1.addLine(to: CGPoint(x: 112.0, y: 137.22))
                f1.addLine(to: CGPoint(x: 66.39, y: 191.49))
                f1.closeSubpath()
                context.fill(f1.applying(transform), with: .color(darkColor))
                var f2 = SwiftUI.Path()
                f2.move(to: CGPoint(x: 194.82, y: 68.3))
                f2.addCurve(to: CGPoint(x: 182.22, y: 82.5), control1: CGPoint(x: 190.49, y: 73.55), control2: CGPoint(x: 186.85, y: 77.91))
                f2.addLine(to: CGPoint(x: 141.05, y: 44.73))
                f2.addCurve(to: CGPoint(x: 169.33, y: 28.72), control1: CGPoint(x: 147.58, y: 35.76), control2: CGPoint(x: 157.41, y: 18.57))
                f2.addLine(to: CGPoint(x: 192.63, y: 48.55))
                f2.addCurve(to: CGPoint(x: 194.83, y: 68.3), control1: CGPoint(x: 198.53, y: 53.57), control2: CGPoint(x: 199.92, y: 62.13))
                f2.closeSubpath()
                context.fill(f2.applying(transform), with: .color(darkColor))
                var f3 = SwiftUI.Path()
                f3.move(to: CGPoint(x: 32.69, y: 171.62))
                f3.addCurve(to: CGPoint(x: 38.13, y: 163.87), control1: CGPoint(x: 35.03, y: 169.5), control2: CGPoint(x: 35.9, y: 166.47))
                f3.addLine(to: CGPoint(x: 86.71, y: 107.09))
                f3.addLine(to: CGPoint(x: 131.67, y: 54.87))
                f3.addCurve(to: CGPoint(x: 139.63, y: 61.75), control1: CGPoint(x: 134.96, y: 55.93), control2: CGPoint(x: 137.97, y: 58.23))
                f3.addLine(to: CGPoint(x: 44.81, y: 173.16))
                f3.addCurve(to: CGPoint(x: 32.69, y: 171.62), control1: CGPoint(x: 41.4, y: 174.85), control2: CGPoint(x: 37.29, y: 173.22))
                f3.closeSubpath()
                context.fill(f3.applying(transform), with: .color(darkColor))
                var f4 = SwiftUI.Path()
                f4.move(to: CGPoint(x: 74.85, y: 208.97))
                f4.addCurve(to: CGPoint(x: 71.65, y: 197.51), control1: CGPoint(x: 72.95, y: 205.46), control2: CGPoint(x: 70.31, y: 201.15))
                f4.addLine(to: CGPoint(x: 134.32, y: 122.98))
                f4.addCurve(to: CGPoint(x: 145.53, y: 109.99), control1: CGPoint(x: 138.19, y: 118.38), control2: CGPoint(x: 141.65, y: 114.55))
                f4.addLine(to: CGPoint(x: 166.6, y: 85.22))
                f4.addCurve(to: CGPoint(x: 174.12, y: 90.63), control1: CGPoint(x: 169.52, y: 87.53), control2: CGPoint(x: 172.2, y: 88.21))
                f4.addCurve(to: CGPoint(x: 151.85, y: 119.0), control1: CGPoint(x: 167.84, y: 101.81), control2: CGPoint(x: 159.75, y: 109.64))
                f4.addLine(to: CGPoint(x: 83.45, y: 199.98))
                f4.addCurve(to: CGPoint(x: 74.84, y: 208.97), control1: CGPoint(x: 80.68, y: 203.26), control2: CGPoint(x: 78.45, y: 205.5))
                f4.closeSubpath()
                context.fill(f4.applying(transform), with: .color(darkColor))
                // White tip highlight
                var tip = SwiftUI.Path()
                tip.move(to: CGPoint(x: 61.28, y: 200.71))
                tip.addCurve(to: CGPoint(x: 66.93, y: 215.37), control1: CGPoint(x: 64.24, y: 205.11), control2: CGPoint(x: 65.93, y: 209.9))
                tip.addLine(to: CGPoint(x: 35.72, y: 228.83))
                tip.addLine(to: CGPoint(x: 20.11, y: 215.85))
                tip.addLine(to: CGPoint(x: 26.48, y: 181.11))
                tip.addCurve(to: CGPoint(x: 39.5, y: 183.8), control1: CGPoint(x: 30.34, y: 181.56), control2: CGPoint(x: 36.75, y: 180.57))
                tip.addCurve(to: CGPoint(x: 45.63, y: 199.46), control1: CGPoint(x: 43.15, y: 188.1), control2: CGPoint(x: 42.2, y: 194.89))
                tip.addCurve(to: CGPoint(x: 61.27, y: 200.72), control1: CGPoint(x: 50.38, y: 200.86), control2: CGPoint(x: 55.12, y: 200.42))
                tip.closeSubpath()
                context.fill(tip.applying(transform), with: .color(.white))
                // "S" lettering
                var sPath = SwiftUI.Path()
                sPath.move(to: CGPoint(x: 210.2, y: 175.94))
                sPath.addCurve(to: CGPoint(x: 255.69, y: 222.01), control1: CGPoint(x: 221.68, y: 185.28), control2: CGPoint(x: 259.83, y: 188.72))
                sPath.addCurve(to: CGPoint(x: 237.42, y: 246.05), control1: CGPoint(x: 254.5, y: 231.57), control2: CGPoint(x: 248.08, y: 241.8))
                sPath.addCurve(to: CGPoint(x: 192.05, y: 244.82), control1: CGPoint(x: 222.73, y: 251.9), control2: CGPoint(x: 206.61, y: 250.52))
                sPath.addCurve(to: CGPoint(x: 195.16, y: 233.15), control1: CGPoint(x: 192.52, y: 240.14), control2: CGPoint(x: 193.6, y: 236.89))
                sPath.addCurve(to: CGPoint(x: 224.8, y: 236.57), control1: CGPoint(x: 204.66, y: 236.94), control2: CGPoint(x: 214.74, y: 238.68))
                sPath.addCurve(to: CGPoint(x: 239.23, y: 220.41), control1: CGPoint(x: 233.48, y: 234.75), control2: CGPoint(x: 238.62, y: 228.4))
                sPath.addCurve(to: CGPoint(x: 227.47, y: 201.4), control1: CGPoint(x: 239.88, y: 211.86), control2: CGPoint(x: 235.9, y: 205.22))
                sPath.addLine(to: CGPoint(x: 206.01, y: 191.68))
                sPath.addCurve(to: CGPoint(x: 187.67, y: 163.79), control1: CGPoint(x: 194.41, y: 186.43), control2: CGPoint(x: 187.58, y: 176.16))
                sPath.addCurve(to: CGPoint(x: 206.21, y: 136.42), control1: CGPoint(x: 187.75, y: 152.1), control2: CGPoint(x: 194.35, y: 141.45))
                sPath.addCurve(to: CGPoint(x: 251.7, y: 139.29), control1: CGPoint(x: 220.61, y: 130.31), control2: CGPoint(x: 237.7, y: 132.02))
                sPath.addCurve(to: CGPoint(x: 247.15, y: 151.76), control1: CGPoint(x: 251.19, y: 144.18), control2: CGPoint(x: 248.58, y: 147.49))
                sPath.addCurve(to: CGPoint(x: 204.03, y: 159.51), control1: CGPoint(x: 233.82, y: 143.01), control2: CGPoint(x: 205.83, y: 143.47))
                sPath.addCurve(to: CGPoint(x: 210.2, y: 175.93), control1: CGPoint(x: 203.3, y: 166.01), control2: CGPoint(x: 204.94, y: 171.65))
                sPath.closeSubpath()
                context.fill(sPath.applying(transform), with: .color(color))

            case .typeTool:
                // Type icon from assets/icons/type.svg (viewBox 0 0 256 256), scaled to 28x28
                let s: CGFloat = 28.0 / 256.0
                let transform = CGAffineTransform(translationX: ox, y: oy).scaledBy(x: s, y: s)
                var path = SwiftUI.Path()
                path.move(to: CGPoint(x: 156.78, y: 197.66))
                path.addLine(to: CGPoint(x: 100.75, y: 197.48))
                path.addCurve(to: CGPoint(x: 100.77, y: 178.84),
                              control1: CGPoint(x: 96.82, y: 194.40),
                              control2: CGPoint(x: 96.71, y: 181.39))
                path.addCurve(to: CGPoint(x: 117.52, y: 175.37),
                              control1: CGPoint(x: 104.79, y: 176.31),
                              control2: CGPoint(x: 116.01, y: 180.43))
                path.addLine(to: CGPoint(x: 117.81, y: 79.15))
                path.addCurve(to: CGPoint(x: 79.61, y: 78.96),
                              control1: CGPoint(x: 104.22, y: 77.42),
                              control2: CGPoint(x: 92.22, y: 77.65))
                path.addLine(to: CGPoint(x: 77.77, y: 97.29))
                path.addCurve(to: CGPoint(x: 59.23, y: 97.22),
                              control1: CGPoint(x: 71.41, y: 98.59),
                              control2: CGPoint(x: 65.94, y: 98.55))
                path.addCurve(to: CGPoint(x: 59.38, y: 58.35),
                              control1: CGPoint(x: 58.49, y: 84.22),
                              control2: CGPoint(x: 58.18, y: 72.18))
                path.addLine(to: CGPoint(x: 196.62, y: 58.35))
                path.addCurve(to: CGPoint(x: 196.75, y: 97.25),
                              control1: CGPoint(x: 197.80, y: 72.10),
                              control2: CGPoint(x: 197.59, y: 84.19))
                path.addCurve(to: CGPoint(x: 178.21, y: 97.25),
                              control1: CGPoint(x: 190.10, y: 98.62),
                              control2: CGPoint(x: 184.66, y: 98.52))
                path.addLine(to: CGPoint(x: 176.38, y: 78.97))
                path.addCurve(to: CGPoint(x: 138.23, y: 79.15),
                              control1: CGPoint(x: 163.73, y: 77.71),
                              control2: CGPoint(x: 151.71, y: 77.51))
                path.addLine(to: CGPoint(x: 138.23, y: 176.88))
                path.addLine(to: CGPoint(x: 156.82, y: 178.76))
                path.addCurve(to: CGPoint(x: 156.78, y: 197.67),
                              control1: CGPoint(x: 158.02, y: 184.54),
                              control2: CGPoint(x: 158.40, y: 189.25))
                path.closeSubpath()
                let transformed = path.applying(transform)
                context.fill(transformed, with: .color(color))

            case .typeOnPath:
                // Type-on-a-Path icon from assets/icons/type on a path.svg
                // (viewBox 0 0 256 256), scaled to 28x28.
                let s: CGFloat = 28.0 / 256.0
                let transform = CGAffineTransform(translationX: ox, y: oy).scaledBy(x: s, y: s)
                // Caret/insertion-point glyph.
                var caret = SwiftUI.Path()
                caret.move(to: CGPoint(x: 146.65, y: 143.92))
                caret.addCurve(to: CGPoint(x: 133.15, y: 143.77),
                               control1: CGPoint(x: 146.90, y: 149.81),
                               control2: CGPoint(x: 136.63, y: 147.47))
                caret.addLine(to: CGPoint(x: 115.23, y: 124.75))
                caret.addCurve(to: CGPoint(x: 116.23, y: 114.81),
                               control1: CGPoint(x: 112.23, y: 121.57),
                               control2: CGPoint(x: 114.91, y: 117.25))
                caret.addCurve(to: CGPoint(x: 126.72, y: 115.88),
                               control1: CGPoint(x: 117.93, y: 111.69),
                               control2: CGPoint(x: 124.83, y: 117.32))
                caret.addCurve(to: CGPoint(x: 170.36, y: 72.51),
                               control1: CGPoint(x: 141.92, y: 103.01),
                               control2: CGPoint(x: 156.13, y: 87.44))
                caret.addCurve(to: CGPoint(x: 165.59, y: 63.83),
                               control1: CGPoint(x: 173.34, y: 69.38),
                               control2: CGPoint(x: 167.59, y: 65.27))
                caret.addCurve(to: CGPoint(x: 146.36, y: 57.74),
                               control1: CGPoint(x: 159.29, y: 59.29),
                               control2: CGPoint(x: 144.76, y: 74.47))
                caret.addCurve(to: CGPoint(x: 166.61, y: 44.99),
                               control1: CGPoint(x: 146.98, y: 51.26),
                               control2: CGPoint(x: 159.88, y: 39.14))
                caret.addCurve(to: CGPoint(x: 217.12, y: 95.93),
                               control1: CGPoint(x: 184.78, y: 60.79),
                               control2: CGPoint(x: 201.40, y: 78.14))
                caret.addCurve(to: CGPoint(x: 199.03, y: 115.42),
                               control1: CGPoint(x: 219.01, y: 102.34),
                               control2: CGPoint(x: 205.42, y: 115.82))
                caret.addCurve(to: CGPoint(x: 197.33, y: 95.66),
                               control1: CGPoint(x: 189.98, y: 114.86),
                               control2: CGPoint(x: 201.34, y: 101.38))
                caret.addCurve(to: CGPoint(x: 186.13, y: 91.11),
                               control1: CGPoint(x: 195.60, y: 93.19),
                               control2: CGPoint(x: 189.73, y: 87.53))
                caret.addLine(to: CGPoint(x: 146.09, y: 130.89))
                caret.addLine(to: CGPoint(x: 146.65, y: 143.92))
                caret.closeSubpath()
                context.fill(caret.applying(transform), with: .color(color))
                // Underlying curve glyph.
                var curve = SwiftUI.Path()
                curve.move(to: CGPoint(x: 194.00, y: 177.67))
                curve.addCurve(to: CGPoint(x: 182.32, y: 203.63),
                               control1: CGPoint(x: 196.66, y: 188.47),
                               control2: CGPoint(x: 189.71, y: 199.52))
                curve.addCurve(to: CGPoint(x: 120.34, y: 168.89),
                               control1: CGPoint(x: 158.52, y: 216.88),
                               control2: CGPoint(x: 137.39, y: 188.98))
                curve.addCurve(to: CGPoint(x: 72.65, y: 119.71),
                               control1: CGPoint(x: 105.40, y: 151.28),
                               control2: CGPoint(x: 88.87, y: 136.25))
                curve.addCurve(to: CGPoint(x: 59.42, y: 116.74),
                               control1: CGPoint(x: 68.96, y: 115.94),
                               control2: CGPoint(x: 63.09, y: 114.70))
                curve.addCurve(to: CGPoint(x: 45.63, y: 135.65),
                               control1: CGPoint(x: 47.24, y: 123.50),
                               control2: CGPoint(x: 54.88, y: 134.76))
                curve.addCurve(to: CGPoint(x: 51.73, y: 106.74),
                               control1: CGPoint(x: 27.42, y: 135.43),
                               control2: CGPoint(x: 43.44, y: 109.53))
                curve.addCurve(to: CGPoint(x: 79.04, y: 108.46),
                               control1: CGPoint(x: 59.80, y: 102.36),
                               control2: CGPoint(x: 72.46, y: 102.18))
                curve.addCurve(to: CGPoint(x: 120.81, y: 150.92),
                               control1: CGPoint(x: 93.71, y: 122.48),
                               control2: CGPoint(x: 107.83, y: 135.56))
                curve.addCurve(to: CGPoint(x: 161.34, y: 192.68),
                               control1: CGPoint(x: 133.49, y: 165.91),
                               control2: CGPoint(x: 147.03, y: 179.29))
                curve.addCurve(to: CGPoint(x: 175.80, y: 192.54),
                               control1: CGPoint(x: 165.16, y: 196.26),
                               control2: CGPoint(x: 172.01, y: 194.09))
                curve.addCurve(to: CGPoint(x: 181.52, y: 178.11),
                               control1: CGPoint(x: 180.32, y: 190.70),
                               control2: CGPoint(x: 180.63, y: 184.50))
                curve.addCurve(to: CGPoint(x: 194.00, y: 177.67),
                               control1: CGPoint(x: 181.97, y: 174.91),
                               control2: CGPoint(x: 193.13, y: 174.16))
                curve.closeSubpath()
                context.fill(curve.applying(transform), with: .color(color))

            case .line:
                // Line icon from SVG (viewBox 0 0 256 256), scaled to 28x28
                let s: CGFloat = 28.0 / 256.0
                let transform = CGAffineTransform(translationX: ox, y: oy).scaledBy(x: s, y: s)
                var path = SwiftUI.Path()
                path.move(to: CGPoint(x: 30.79, y: 232.04))
                path.addLine(to: CGPoint(x: 231.78, y: 31.05))
                let transformed = path.applying(transform)
                context.stroke(transformed, with: .color(color), lineWidth: 8.0 * s)

            case .rect:
                let rect = CGRect(x: ox + 4, y: oy + 6, width: 20, height: 16)
                context.stroke(SwiftUI.Path(rect), with: .color(color), lineWidth: 1.5)

            case .roundedRect:
                // Rounded Rectangle icon from SVG (viewBox 0 0 256 256), scaled to 28x28
                let s: CGFloat = 28.0 / 256.0
                let transform = CGAffineTransform(translationX: ox, y: oy).scaledBy(x: s, y: s)
                let rect = CGRect(x: 23.33, y: 58.26, width: 212.06, height: 139.47)
                let path = SwiftUI.Path(roundedRect: rect, cornerSize: CGSize(width: 30, height: 30))
                let transformed = path.applying(transform)
                context.stroke(transformed, with: .color(color), lineWidth: 8.0 * s)

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

            case .anchorPoint:
                // Convert Anchor Point: a center anchor square with two
                // diagonal handle lines, suggesting a smooth/corner convert.
                let cx = ox + 14, cy = oy + 14
                // Handle lines (diagonal)
                var handles = SwiftUI.Path()
                handles.move(to: CGPoint(x: cx - 10, y: cy - 10))
                handles.addLine(to: CGPoint(x: cx, y: cy))
                handles.addLine(to: CGPoint(x: cx + 10, y: cy + 10))
                context.stroke(handles, with: .color(color), lineWidth: 1.5)
                // Handle endpoint circles
                let r: CGFloat = 2.5
                for (hx, hy) in [(cx - 10, cy - 10), (cx + 10, cy + 10)] {
                    var hc = SwiftUI.Path()
                    hc.addEllipse(in: CGRect(x: hx - r, y: hy - r, width: r * 2, height: r * 2))
                    context.fill(hc, with: .color(color))
                }
                // Anchor square (filled)
                let half: CGFloat = 4
                var anchor = SwiftUI.Path()
                anchor.addRect(CGRect(x: cx - half, y: cy - half, width: half * 2, height: half * 2))
                context.fill(anchor, with: .color(color))
                context.stroke(anchor, with: .color(.black), lineWidth: 1.0)

            case .star:
                // Star icon from SVG (viewBox 0 0 256 256), scaled to 28x28
                let s: CGFloat = 28.0 / 256.0
                let transform = CGAffineTransform(translationX: ox, y: oy).scaledBy(x: s, y: s)
                let pts: [(CGFloat, CGFloat)] = [
                    (128, 50.18), (145.47, 103.95), (202.01, 103.95),
                    (156.27, 137.18), (173.74, 190.95), (128, 157.72),
                    (82.26, 190.95), (99.73, 137.18), (53.99, 103.95),
                    (110.53, 103.95),
                ]
                var path = SwiftUI.Path()
                path.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
                for i in 1..<pts.count {
                    path.addLine(to: CGPoint(x: pts[i].0, y: pts[i].1))
                }
                path.closeSubpath()
                let transformed = path.applying(transform)
                context.stroke(transformed, with: .color(color), lineWidth: 8.0 * s)

            case .lasso:
                // Lasso (freehand loop — placeholder icon)
                var path = SwiftUI.Path()
                path.move(to: CGPoint(x: ox + 14, y: oy + 5))
                path.addCurve(to: CGPoint(x: ox + 3, y: oy + 14),
                              control1: CGPoint(x: ox + 6, y: oy + 5),
                              control2: CGPoint(x: ox + 3, y: oy + 10))
                path.addCurve(to: CGPoint(x: ox + 14, y: oy + 22),
                              control1: CGPoint(x: ox + 3, y: oy + 20),
                              control2: CGPoint(x: ox + 8, y: oy + 24))
                path.addCurve(to: CGPoint(x: ox + 20, y: oy + 12),
                              control1: CGPoint(x: ox + 20, y: oy + 20),
                              control2: CGPoint(x: ox + 22, y: oy + 16))
                path.addCurve(to: CGPoint(x: ox + 12, y: oy + 13),
                              control1: CGPoint(x: ox + 18, y: oy + 8),
                              control2: CGPoint(x: ox + 12, y: oy + 9))
                path.addCurve(to: CGPoint(x: ox + 17, y: oy + 15),
                              control1: CGPoint(x: ox + 12, y: oy + 16),
                              control2: CGPoint(x: ox + 16, y: oy + 17))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            case .scale:
                // Scale — small square being extruded into a larger one
                // (per SCALE_TOOL.md §Tool icon).
                var small = SwiftUI.Path()
                small.addRect(CGRect(x: ox + 3, y: oy + 13, width: 10, height: 11))
                context.stroke(small, with: .color(color), lineWidth: 1.5)
                var large = SwiftUI.Path()
                large.addRect(CGRect(x: ox + 13, y: oy + 3, width: 12, height: 13))
                context.stroke(large, with: .color(color), lineWidth: 1.5)

            case .rotate:
                // Rotate — 270 deg arc with arrowhead (per
                // ROTATE_TOOL.md §Tool icon). Arc center (14, 14),
                // radius 9, from top (14, 5) sweeping CCW to left
                // (5, 14).
                var arc = SwiftUI.Path()
                arc.addArc(center: CGPoint(x: ox + 14, y: oy + 14),
                           radius: 9,
                           startAngle: .degrees(-90),
                           endAngle: .degrees(180),
                           clockwise: false)
                context.stroke(arc, with: .color(color),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                var head = SwiftUI.Path()
                head.move(to: CGPoint(x: ox + 11, y: oy + 2))
                head.addLine(to: CGPoint(x: ox + 14, y: oy + 5))
                head.addLine(to: CGPoint(x: ox + 11, y: oy + 8))
                context.stroke(head, with: .color(color),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

            case .shear:
                // Shear — right-leaning parallelogram (per
                // SHEAR_TOOL.md §Tool icon).
                var path = SwiftUI.Path()
                path.move(to: CGPoint(x: ox + 9,  y: oy + 4))
                path.addLine(to: CGPoint(x: ox + 26, y: oy + 4))
                path.addLine(to: CGPoint(x: ox + 19, y: oy + 24))
                path.addLine(to: CGPoint(x: ox + 2,  y: oy + 24))
                path.closeSubpath()
                context.stroke(path, with: .color(color), lineWidth: 1.5)

            case .hand:
                // Hand — open palm with four fingers extended and a
                // stubby base. Per HAND_TOOL.md §Tool icon.
                let strokeStyle = StrokeStyle(lineWidth: 2.0, lineCap: .round)
                for (x1, y1) in [(10.0, 14.0), (13.0, 14.0), (16.0, 14.0), (19.0, 14.0)] {
                    let yTip = [10.0: 5.0, 13.0: 3.0, 16.0: 4.0, 19.0: 6.0][x1] ?? 5.0
                    var p = SwiftUI.Path()
                    p.move(to: CGPoint(x: ox + x1, y: oy + y1))
                    p.addLine(to: CGPoint(x: ox + x1, y: oy + yTip))
                    context.stroke(p, with: .color(color), style: strokeStyle)
                }
                var palm = SwiftUI.Path()
                palm.move(to: CGPoint(x: ox + 9,  y: oy + 14))
                palm.addLine(to: CGPoint(x: ox + 4,  y: oy + 18))
                palm.addLine(to: CGPoint(x: ox + 4,  y: oy + 22))
                palm.addQuadCurve(
                    to: CGPoint(x: ox + 9, y: oy + 25),
                    control: CGPoint(x: ox + 5, y: oy + 25))
                palm.addLine(to: CGPoint(x: ox + 19, y: oy + 25))
                palm.addQuadCurve(
                    to: CGPoint(x: ox + 22, y: oy + 22),
                    control: CGPoint(x: ox + 22, y: oy + 25))
                palm.addLine(to: CGPoint(x: ox + 22, y: oy + 14))
                context.stroke(
                    palm, with: .color(color),
                    style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))

            case .zoom:
                // Zoom — circular lens with short ~45° handle at
                // lower-right. No interior glyph; plus / minus
                // appear in the cursor at use time. Per
                // ZOOM_TOOL.md §Tool icon.
                let lens = SwiftUI.Path(ellipseIn: CGRect(
                    x: ox + 11 - 6.5, y: oy + 11 - 6.5,
                    width: 13, height: 13))
                context.stroke(lens, with: .color(color), lineWidth: 2.0)
                var handle = SwiftUI.Path()
                handle.move(to: CGPoint(x: ox + 15.5, y: oy + 15.5))
                handle.addLine(to: CGPoint(x: ox + 22.5, y: oy + 22.5))
                context.stroke(
                    handle, with: .color(color),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
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
    var onRequestOptions: ((Tool) -> Void)? = nil
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
            .onTapGesture(count: 2) {
                onRequestOptions?(visibleTool)
            }
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
        case .partialSelection: return "Partial Selection"
        case .interiorSelection: return "Interior Selection"
        case .magicWand: return "Magic Wand"
        case .pen: return "Pen"
        case .addAnchorPoint: return "Add Anchor Point"
        case .deleteAnchorPoint: return "Delete Anchor Point"
        case .anchorPoint: return "Anchor Point"
        case .pencil: return "Pencil"
        case .paintbrush: return "Paintbrush"
        case .blobBrush: return "Blob Brush"
        case .pathEraser: return "Path Eraser"
        case .smooth: return "Smooth"
        case .typeTool: return "Type"
        case .typeOnPath: return "Type on a Path"
        case .rect: return "Rectangle"
        case .roundedRect: return "Rounded Rectangle"
        case .polygon: return "Polygon"
        case .star: return "Star"
        case .lasso: return "Lasso"
        case .scale: return "Scale"
        case .rotate: return "Rotate"
        case .shear: return "Shear"
        case .hand: return "Hand"
        case .zoom: return "Zoom"
        default: return tool.rawValue
        }
    }
}
