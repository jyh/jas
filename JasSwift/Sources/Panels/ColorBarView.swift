/// 64-pt tall HSB color picker bar for the Color panel.
///
/// Hue varies along the x-axis (0–360°). The y-axis is split:
/// the top half ramps saturation from 0% to 100% while brightness
/// drops from 100% to 80%; the bottom half holds saturation at
/// 100% while brightness drops from 80% to 0%. Click or drag
/// updates the active color live; pointer-up commits it to the
/// recent-colors strip.
///
/// See `transcripts/COLOR.md` and `workspace/panels/color.yaml`
/// (cp_color_bar) for the spec; mirrors `render_color_bar` in
/// the Rust port.

import SwiftUI
import AppKit

struct ColorBarView: View {
    @ObservedObject var model: Model
    var height: CGFloat = 64
    /// Disabled when the active attribute (fill or stroke per
    /// fill_on_top) is none — the YAML resolves bind.disabled and
    /// passes the result here so the bar matches the slider /
    /// hex-input gating.
    var isDisabled: Bool = false

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                Self.draw(in: &ctx, size: size)
            }
            .frame(width: geo.size.width, height: height)
            .opacity(isDisabled ? 0.4 : 1.0)
            .allowsHitTesting(!isDisabled)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let c = Self.colorAt(
                            x: value.location.x, y: value.location.y,
                            width: geo.size.width, height: height
                        )
                        ColorPanel.setActiveColorLive(c, model: model)
                    }
                    .onEnded { value in
                        let c = Self.colorAt(
                            x: value.location.x, y: value.location.y,
                            width: geo.size.width, height: height
                        )
                        ColorPanel.setActiveColor(c, model: model)
                    }
            )
        }
        .frame(height: height)
    }

    /// Map a (x, y) pixel inside the bar to the HSB color that the
    /// gradient shows at that point. Mirrors the algorithm in
    /// `render_color_bar` (jas_dioxus).
    private static func colorAt(
        x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
    ) -> Color {
        let cx = max(0, min(width - 1, x))
        let cy = max(0, min(height - 1, y))
        let hue = 360.0 * Double(cx) / Double(width)
        let midY = height / 2
        // Color enum stores s/b in [0, 1]; the spec describes the
        // color bar in 0..100% units, so divide before constructing.
        let sat: Double
        let br: Double
        if cy <= midY {
            let t = Double(cy / midY)
            sat = t            // 0 → 1
            br = 1.0 - t * 0.2 // 1.0 → 0.8
        } else {
            let t = Double((cy - midY) / (height - midY))
            sat = 1.0
            br = 0.8 * (1.0 - t)
        }
        return Color.hsb(h: hue, s: sat, b: br, a: 1.0)
    }

    /// Draw the gradient into the Canvas. We sample the HSB
    /// function at a vertical strip resolution: each strip is
    /// `stripWidth` pixels wide and the full height. Within a
    /// strip we use a vertical LinearGradient between the top
    /// (white-ish) and middle (saturated) and bottom (black)
    /// sample points to keep it cheap.
    private static func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let stripWidth: CGFloat = 2
        let stripCount = max(1, Int(size.width / stripWidth))
        for i in 0..<stripCount {
            let x = CGFloat(i) * stripWidth
            let hue = 360.0 * Double(x) / Double(size.width)
            // Three sample colors per strip (top, middle, bottom),
            // s/b in [0, 1].
            let top = Color.hsb(h: hue, s: 0, b: 1.0, a: 1.0)
            let mid = Color.hsb(h: hue, s: 1.0, b: 0.8, a: 1.0)
            let bot = Color.hsb(h: hue, s: 1.0, b: 0, a: 1.0)
            let stops: [SwiftUI.Gradient.Stop] = [
                .init(color: swiftColor(top), location: 0),
                .init(color: swiftColor(mid), location: 0.5),
                .init(color: swiftColor(bot), location: 1),
            ]
            let rect = CGRect(x: x, y: 0, width: stripWidth, height: size.height)
            ctx.fill(
                SwiftUI.Path(rect),
                with: .linearGradient(
                    SwiftUI.Gradient(stops: stops),
                    startPoint: CGPoint(x: rect.midX, y: 0),
                    endPoint: CGPoint(x: rect.midX, y: size.height)
                )
            )
        }
    }

    private static func swiftColor(_ c: Color) -> SwiftUI.Color {
        let (r, g, b, a) = c.toRgba()
        return SwiftUI.Color(
            red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a)
        )
    }
}
