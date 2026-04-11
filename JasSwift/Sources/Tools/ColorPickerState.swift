import Foundation

/// Which radio button is selected in the color picker.
public enum RadioChannel: String, CaseIterable {
    case h = "H"
    case s = "S"
    case b = "B"
    case r = "R"
    case g = "G"
    case blue = "Blue"
}

/// State for the color picker dialog.
///
/// Stores the working color as internal RGB (0..1) with preserved
/// hue and saturation values that survive when brightness or saturation
/// drop to zero.
public class ColorPickerState: ObservableObject {
    /// Whether the dialog is for fill or stroke.
    public var forFill: Bool

    /// Current working color (always stored as RGB internally, 0..1).
    @Published public private(set) var r: Double
    @Published public private(set) var g: Double
    @Published public private(set) var b: Double

    /// Preserved hue (0..360) -- survives when brightness or saturation is 0.
    public private(set) var hue: Double
    /// Preserved saturation (0..1) -- survives when brightness is 0.
    public private(set) var sat: Double

    /// Selected radio button.
    @Published public var radio: RadioChannel = .h
    /// Only web colors checkbox.
    @Published public var webOnly: Bool = false

    /// Create a new color picker state with the given initial color.
    public init(color: Color, forFill: Bool) {
        self.forFill = forFill
        let (r, g, b, _) = color.toRgba()
        self.r = r
        self.g = g
        self.b = b
        let (h, s, _, _) = color.toHsba()
        self.hue = h
        self.sat = s
    }

    /// Get the current color as an RGB Color.
    public func color() -> Color {
        Color(r: r, g: g, b: b)
    }

    /// Update preserved hue/sat from the current RGB, but only when the
    /// conversion is meaningful.
    private func syncHueSat() {
        let (h, s, br, _) = Color(r: r, g: g, b: b).toHsba()
        if br > 0.001 && s > 0.001 {
            hue = h
        }
        if br > 0.001 {
            sat = s
        }
    }

    /// Set the color from RGB components (0-255 integer scale).
    public func setRgb(_ rv: UInt8, _ gv: UInt8, _ bv: UInt8) {
        r = Double(rv) / 255.0
        g = Double(gv) / 255.0
        b = Double(bv) / 255.0
        if webOnly { snapToWeb() }
        syncHueSat()
    }

    /// Set the color from HSB components (h: 0-360, s: 0-100, b: 0-100).
    public func setHsb(_ hv: Double, _ sv: Double, _ bv: Double) {
        hue = hv
        sat = sv / 100.0
        let c = Color.hsb(h: hv, s: sv / 100.0, b: bv / 100.0, a: 1.0)
        let (rv, gv, blv, _) = c.toRgba()
        r = rv
        g = gv
        b = blv
        if webOnly { snapToWeb() }
    }

    /// Set the color from CMYK components (all 0-100).
    public func setCmyk(_ cv: Double, _ mv: Double, _ yv: Double, _ kv: Double) {
        let color = Color.cmyk(c: cv / 100.0, m: mv / 100.0, y: yv / 100.0, k: kv / 100.0, a: 1.0)
        let (rv, gv, bv, _) = color.toRgba()
        r = rv
        g = gv
        b = bv
        if webOnly { snapToWeb() }
        syncHueSat()
    }

    /// Set the color from a hex string.
    public func setHex(_ hex: String) {
        if let c = Color.fromHex(hex) {
            let (rv, gv, bv, _) = c.toRgba()
            r = rv
            g = gv
            b = bv
            if webOnly { snapToWeb() }
            syncHueSat()
        }
    }

    /// Get RGB values as 0-255 integers.
    public func rgbU8() -> (UInt8, UInt8, UInt8) {
        (
            UInt8((r * 255.0).rounded()),
            UInt8((g * 255.0).rounded()),
            UInt8((b * 255.0).rounded())
        )
    }

    /// Get HSB values (h: 0-360, s: 0-100, b: 0-100).
    /// Uses preserved hue/sat when the derived values would be lost.
    public func hsbVals() -> (Double, Double, Double) {
        let (dh, ds, db, _) = Color(r: r, g: g, b: b).toHsba()
        let h = (db < 0.001 || ds < 0.001) ? hue : dh
        let s = db < 0.001 ? sat : ds
        return (h, s * 100.0, db * 100.0)
    }

    /// Get CMYK values (all 0-100).
    public func cmykVals() -> (Double, Double, Double, Double) {
        let (c, m, y, k, _) = Color(r: r, g: g, b: b).toCmyka()
        return (c * 100.0, m * 100.0, y * 100.0, k * 100.0)
    }

    /// Get hex string (no #).
    public func hexStr() -> String {
        Color(r: r, g: g, b: b).toHex()
    }

    /// Snap RGB to web-safe colors.
    private func snapToWeb() {
        r = snapWeb(r)
        g = snapWeb(g)
        b = snapWeb(b)
    }

    /// Set the color from gradient position (x, y normalized 0..1),
    /// given the current radio button.
    public func setFromGradient(_ x: Double, _ y: Double) {
        let x = x.clamped(to: 0.0...1.0)
        let y = y.clamped(to: 0.0...1.0)
        switch radio {
        case .h:
            sat = x
            let c = Color.hsb(h: hue, s: x, b: 1.0 - y, a: 1.0)
            let (rv, gv, bv, _) = c.toRgba()
            r = rv; g = gv; b = bv
        case .s:
            hue = x * 360.0
            let c = Color.hsb(h: x * 360.0, s: sat, b: 1.0 - y, a: 1.0)
            let (rv, gv, bv, _) = c.toRgba()
            r = rv; g = gv; b = bv
        case .b:
            hue = x * 360.0
            sat = 1.0 - y
            let (_, _, br, _) = Color(r: r, g: g, b: b).toHsba()
            let c = Color.hsb(h: x * 360.0, s: 1.0 - y, b: br, a: 1.0)
            let (rv, gv, bv, _) = c.toRgba()
            r = rv; g = gv; b = bv
        case .r:
            b = x; g = 1.0 - y; syncHueSat()
        case .g:
            b = x; r = 1.0 - y; syncHueSat()
        case .blue:
            r = x; g = 1.0 - y; syncHueSat()
        }
        if webOnly { snapToWeb() }
    }

    /// Set the color from colorbar position (t: 0..1, top=0, bottom=1).
    public func setFromColorbar(_ t: Double) {
        let t = t.clamped(to: 0.0...1.0)
        switch radio {
        case .h:
            hue = t * 360.0
            let (_, _, bri, _) = Color(r: r, g: g, b: b).toHsba()
            let c = Color.hsb(h: t * 360.0, s: sat, b: bri, a: 1.0)
            let (rv, gv, blv, _) = c.toRgba()
            r = rv; g = gv; b = blv
        case .s:
            sat = 1.0 - t
            let (_, _, bri, _) = Color(r: r, g: g, b: b).toHsba()
            let c = Color.hsb(h: hue, s: 1.0 - t, b: bri, a: 1.0)
            let (rv, gv, blv, _) = c.toRgba()
            r = rv; g = gv; b = blv
        case .b:
            let c = Color.hsb(h: hue, s: sat, b: 1.0 - t, a: 1.0)
            let (rv, gv, blv, _) = c.toRgba()
            r = rv; g = gv; b = blv
        case .r:
            r = 1.0 - t; syncHueSat()
        case .g:
            g = 1.0 - t; syncHueSat()
        case .blue:
            b = 1.0 - t; syncHueSat()
        }
        if webOnly { snapToWeb() }
    }

    /// Get colorbar position (0..1, 0=top) for current color.
    public func colorbarPos() -> Double {
        switch radio {
        case .h: return hue / 360.0
        case .s: return 1.0 - sat
        case .b:
            let (_, _, bri, _) = Color(r: r, g: g, b: b).toHsba()
            return 1.0 - bri
        case .r: return 1.0 - r
        case .g: return 1.0 - g
        case .blue: return 1.0 - b
        }
    }

    /// Get gradient position (x, y: 0..1) for current color.
    public func gradientPos() -> (Double, Double) {
        let (_, _, db, _) = Color(r: r, g: g, b: b).toHsba()
        switch radio {
        case .h: return (sat, 1.0 - db)
        case .s: return (hue / 360.0, 1.0 - db)
        case .b: return (hue / 360.0, 1.0 - sat)
        case .r: return (b, 1.0 - g)
        case .g: return (b, 1.0 - r)
        case .blue: return (r, 1.0 - g)
        }
    }
}

/// Snap a 0..1 component to the nearest web-safe value.
func snapWeb(_ v: Double) -> Double {
    let steps = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
    var best = steps[0]
    for s in steps {
        if abs(v - s) < abs(v - best) {
            best = s
        }
    }
    return best
}

// Extension for clamping Double (available in newer Swift but added for safety).
private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
