/// Color conversion utilities matching the Rust/Python implementations.

import Foundation

/// Parse a hex color string to (r, g, b). Returns (0, 0, 0) for invalid input.
func parseHex(_ c: String) -> (UInt8, UInt8, UInt8) {
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
func rgbToHex(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> String {
    String(format: "#%02x%02x%02x", r, g, b)
}

/// Convert RGB (0-255) to HSB (h: 0-359, s: 0-100, b: 0-100).
func rgbToHsb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (Int, Int, Int) {
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
func hsbToRgb(_ h: Double, _ s: Double, _ b: Double) -> (UInt8, UInt8, UInt8) {
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

/// Convert RGB (0-255) to CMYK (0-100 each).
func rgbToCmyk(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (Int, Int, Int, Int) {
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
