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

    /// Map a (x, y) pixel inside the bar to the color that the gradient shows at
    /// that point. Mirrors the algorithm in `render_color_bar` (jas_dioxus);
    /// internal rather than private so `colorBarProducesTheQuantisedRgbBothPortsStore`
    /// can hold it to that mirror.
    static func colorAt(
        x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
    ) -> Color {
        // Clamp the DERIVED values, not the pixel coordinates — Rust's
        // `xy_to_color` clamps the hue to 0...360 and the vertical parameter to
        // 0...1, and the difference shows at the edges: clamping `y` to
        // `height - 1` left a drag past the bottom edge at 2% brightness where
        // Rust answers black. `width.max(1)` is Rust's guard too, and here it
        // also keeps a zero-width bar from handing a NaN hue to
        // `hsbToRgbComponents`, whose `Int(floor(nan))` would trap.
        let hue = min(max(360.0 * Double(x) / Double(max(width, 1)), 0.0), 360.0)
        let midY = height / 2
        // hsbToRgb takes saturation / brightness in the spec's 0..100% units.
        let sat: Double
        let br: Double
        if y <= midY {
            let t = min(max(Double(y / midY), 0.0), 1.0)
            sat = t * 100.0             // 0% → 100%
            br = 100.0 - t * 20.0       // 100% → 80%
        } else {
            let t = min(max(Double((y - midY) / (height - midY)), 0.0), 1.0)
            sat = 100.0
            br = 80.0 * (1.0 - t)
        }
        // Store the QUANTISED RGB, exactly as Rust's `xy_to_color` does
        // (`hsb_to_rgb` then `Color::rgb`). Storing `Color.hsb` of the float
        // triple instead left the two ports holding different colour VALUES for
        // the same click, and left the panel's overlay a `toHsba()`
        // short-circuit to read that Rust has no equivalent of.
        let (r, g, b) = hsbToRgb(hue, sat, br)
        return Color.rgb(r: Double(r) / 255.0, g: Double(g) / 255.0,
                         b: Double(b) / 255.0, a: 1.0)
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
            // `max(width, 1)` for the same reason `colorAt` above has it: at
            // zero width `stripCount` is still 1, so this divide is 0.0/0.0 and
            // hands a NaN hue on to the colour conversion. `hsbToRgbComponents`
            // no longer traps on that (risk R9), but a NaN hue is not a colour
            // either, and Rust rasterises this bar at a fixed 120px width where
            // the divisor cannot be zero at all.
            let hue = 360.0 * Double(x) / Double(max(size.width, 1))
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
