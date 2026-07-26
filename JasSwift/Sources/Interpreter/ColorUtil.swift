/// Color conversion utilities matching the Rust/Python implementations.

import Foundation

/// Parse a hex color string to (r, g, b). Returns (0, 0, 0) for invalid input.
public func parseHex(_ c: String) -> (UInt8, UInt8, UInt8) {
    var h = c
    if h.hasPrefix("#") {
        h = String(h.dropFirst())
    }
    if h.count == 3 {
        let chars = Array(h)
        h = "\(chars[0])\(chars[0])\(chars[1])\(chars[1])\(chars[2])\(chars[2])"
    }
    guard h.count == 6 else { return (0, 0, 0) }
    let chars = Array(h)
    let rStr = String(chars[0...1])
    let gStr = String(chars[2...3])
    let bStr = String(chars[4...5])
    let r = UInt8(rStr, radix: 16) ?? 0
    let g = UInt8(gStr, radix: 16) ?? 0
    let b = UInt8(bStr, radix: 16) ?? 0
    return (r, g, b)
}

/// Convert RGB to 6-digit hex with # prefix.
public func rgbToHex(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> String {
    String(format: "#%02x%02x%02x", r, g, b)
}

/// Convert RGB (0-255) to HSB (h: 0-359, s: 0-100, b: 0-100).
public func rgbToHsb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (Int, Int, Int) {
    let r1 = Double(r) / 255.0
    let g1 = Double(g) / 255.0
    let b1 = Double(b) / 255.0
    let mx = max(r1, g1, b1)
    let mn = min(r1, g1, b1)
    let d = mx - mn
    let s = mx == 0.0 ? 0.0 : d / mx
    let v = mx
    var h = 0.0
    if d > 0.0 {
        if mx == r1 {
            h = ((g1 - b1) / d + (g1 < b1 ? 6.0 : 0.0)) / 6.0
        } else if mx == g1 {
            h = ((b1 - r1) / d + 2.0) / 6.0
        } else {
            h = ((r1 - g1) / d + 4.0) / 6.0
        }
    }
    let hue = Int((h * 360.0).rounded()) % 360
    return (hue, Int((s * 100.0).rounded()), Int((v * 100.0).rounded()))
}

/// Convert HSB (h: 0-359, s: 0-100, b: 0-100) to RGB (0-255).
public func hsbToRgb(_ h: Double, _ s: Double, _ b: Double) -> (UInt8, UInt8, UInt8) {
    let s1 = s / 100.0
    let b1 = b / 100.0
    let c = b1 * s1
    let x = c * (1.0 - abs((h / 60.0).truncatingRemainder(dividingBy: 2.0) - 1.0))
    let m = b1 - c
    let (r1, g1, b1_): (Double, Double, Double)
    if h < 60.0 {
        (r1, g1, b1_) = (c, x, 0.0)
    } else if h < 120.0 {
        (r1, g1, b1_) = (x, c, 0.0)
    } else if h < 180.0 {
        (r1, g1, b1_) = (0.0, c, x)
    } else if h < 240.0 {
        (r1, g1, b1_) = (0.0, x, c)
    } else if h < 300.0 {
        (r1, g1, b1_) = (x, 0.0, c)
    } else {
        (r1, g1, b1_) = (c, 0.0, x)
    }
    return (
        UInt8(((r1 + m) * 255.0).rounded()),
        UInt8(((g1 + m) * 255.0).rounded()),
        UInt8(((b1_ + m) * 255.0).rounded())
    )
}

/// The Color panel's eleven channel values for one colour.
///
/// `bl` is the blue channel's YAML name (`b` is brightness in `color.yaml`), and
/// the fields carry the YAML's units: `r`/`g`/`bl` 0–255, `h` 0–359, everything
/// else 0–100. Swift twin of Rust's `color_util::PanelChannels`.
public struct PanelChannels: Equatable {
    public var r: Int, g: Int, bl: Int
    public var h: Int, s: Int, b: Int
    public var c: Int, m: Int, y: Int, k: Int
    public var hex: String
}

/// Quantise a float colour component in 0...1 to 8 bits.
///
/// Half rounds AWAY from zero and the result SATURATES. Both halves are
/// deliberate: `Double.rounded()` matches Rust's `f64::round`, and the clamp
/// matches what `as u8` does to an out-of-range float in Rust — where
/// `UInt8(_:)` in Swift would instead be a precondition failure, i.e. a crash
/// on a colour the other port renders.
public func quantise8(_ v: Double) -> Int {
    let x = (v * 255.0).rounded()
    if x.isNaN { return 0 }
    return Int(max(0.0, min(255.0, x)))
}

/// Derive every Color-panel channel from a float colour — QUANTISING TO 8 BITS
/// FIRST, then converting those three integers.
///
/// The ORDER is the contract, and it is the whole reason this is one function
/// rather than a line of arithmetic in each caller. A reader that instead asks
/// the float colour for its own hue / saturation / brightness answers up to a
/// whole unit differently, because the 8-bit grid the panel displays on is
/// coarser than the float colour it came from. That used to be a cosmetic
/// display difference; once the panel's WRITE path started recomputing the
/// unedited channels from this same map, it reached the COMMITTED colour — this
/// port committed `664040` where Rust committed `664141` for the same drag
/// (COLORTIERS, 2026-07-26). The hand-rolled float CMYK it replaces was worse
/// than off-by-one: it published 129% and -40% for colours the shared corpus
/// pins at 100 and 0.
///
/// Gated across the ports by `test_fixtures/algorithms/color_convert.json`'s
/// `panel_channels` vectors; Rust twin is `color_util::panel_channels`.
public func panelChannels(rf: Double, gf: Double, bf: Double) -> PanelChannels {
    let r = quantise8(rf), g = quantise8(gf), bl = quantise8(bf)
    let (h, s, br) = rgbToHsb(UInt8(r), UInt8(g), UInt8(bl))
    let (c, m, y, k) = rgbToCmyk(UInt8(r), UInt8(g), UInt8(bl))
    return PanelChannels(
        r: r, g: g, bl: bl, h: h, s: s, b: br, c: c, m: m, y: y, k: k,
        hex: String(format: "%02x%02x%02x", r, g, bl))
}

/// The overlay's entry point: the panel channels for a `Color`.
///
/// It goes through `toRgba()` and NOT `toHsba()`, deliberately. `toHsba()` on a
/// `.hsb` colour short-circuits and hands back the exact triple the colour was
/// constructed with — bypassing the 8-bit grid entirely — and the two reachable
/// `.hsb` producers (a colour-bar click, and Complement, which is `.hsb` in both
/// ports) are precisely where the ports disagreed. Rust has no such
/// short-circuit to take: `build_live_panel_overrides` starts from `to_rgba()`.
public func panelChannels(for color: Color) -> PanelChannels {
    let (rf, gf, bf, _) = color.toRgba()
    return panelChannels(rf: rf, gf: gf, bf: bf)
}

/// Convert RGB (0-255) to CMYK (0-100 each).
public func rgbToCmyk(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (Int, Int, Int, Int) {
    if r == 0 && g == 0 && b == 0 {
        return (0, 0, 0, 100)
    }
    let c1 = 1.0 - Double(r) / 255.0
    let m1 = 1.0 - Double(g) / 255.0
    let y1 = 1.0 - Double(b) / 255.0
    let k1 = min(c1, m1, y1)
    return (
        Int(((c1 - k1) / (1.0 - k1) * 100.0).rounded()),
        Int(((m1 - k1) / (1.0 - k1) * 100.0).rounded()),
        Int(((y1 - k1) / (1.0 - k1) * 100.0).rounded()),
        Int((k1 * 100.0).rounded())
    )
}
