//! Color conversion utilities matching the Python/JS implementations.

/// Parse a hex color string to (r, g, b). Returns (0,0,0) for invalid input.
pub fn parse_hex(c: &str) -> (u8, u8, u8) {
    let h = c.trim_start_matches('#');
    let h = if h.len() == 3 {
        format!(
            "{}{}{}{}{}{}",
            &h[0..1], &h[0..1], &h[1..2], &h[1..2], &h[2..3], &h[2..3]
        )
    } else {
        h.to_string()
    };
    if h.len() != 6 {
        return (0, 0, 0);
    }
    let r = u8::from_str_radix(&h[0..2], 16).unwrap_or(0);
    let g = u8::from_str_radix(&h[2..4], 16).unwrap_or(0);
    let b = u8::from_str_radix(&h[4..6], 16).unwrap_or(0);
    (r, g, b)
}

/// Convert RGB to 6-digit hex with # prefix.
pub fn rgb_to_hex(r: u8, g: u8, b: u8) -> String {
    format!("#{:02x}{:02x}{:02x}", r, g, b)
}

/// Convert RGB (0-255) to HSB (h:0-359, s:0-100, b:0-100).
pub fn rgb_to_hsb(r: u8, g: u8, b: u8) -> (i32, i32, i32) {
    let r1 = r as f64 / 255.0;
    let g1 = g as f64 / 255.0;
    let b1 = b as f64 / 255.0;
    let mx = r1.max(g1).max(b1);
    let mn = r1.min(g1).min(b1);
    let d = mx - mn;
    let s = if mx == 0.0 { 0.0 } else { d / mx };
    let v = mx;
    let mut h = 0.0;
    if d > 0.0 {
        if mx == r1 {
            h = ((g1 - b1) / d + if g1 < b1 { 6.0 } else { 0.0 }) / 6.0;
        } else if mx == g1 {
            h = ((b1 - r1) / d + 2.0) / 6.0;
        } else {
            h = ((r1 - g1) / d + 4.0) / 6.0;
        }
    }
    let hue = ((h * 360.0).round() as i32) % 360;
    (hue, (s * 100.0).round() as i32, (v * 100.0).round() as i32)
}

/// Clamp one colour channel into `lo..=hi`, mapping NaN to `lo`.
///
/// The colour primitives document their channels' ranges (`hsb` 0-360 / 0-100,
/// `cmyk` and `grayscale` 0-100) and this is how they enforce them: clamp the
/// INPUT, before any arithmetic. Clamping the input rather than saturating the
/// output is what makes the ports equal by construction. The formulas are
/// monotonic per channel, so for ONE out-of-range channel the two approaches
/// agree; they diverge when two channels overflow with signs that multiply back
/// positive — unclamped, `cmyk(150, 0, 0, 150)` computes
/// `(1-1.5)*(1-1.5)*255 = +63.75`, a bogus mid-grey that looks like a real
/// colour, where clamping gives black. NaN maps to `lo` for the same reason:
/// it is the one answer both ports can spell identically, where a cast would
/// saturate NaN to 0 in Rust and trap in Swift. Risk R9, transcripts/CORPUS_CENSUS.md §7.
pub fn clamp_channel(v: f64, lo: f64, hi: f64) -> f64 {
    if v.is_nan() {
        return lo;
    }
    v.clamp(lo, hi)
}

/// Convert HSB (h:0-360, s:0-100, b:0-100) to RGB (0-255).
///
/// Channels outside those ranges are clamped (see [`clamp_channel`]). Hue's
/// upper bound is 360, not 359: 360 is the wrap point that the colour corpus
/// pins as identical to 0 (`torgb_hue_360_is_red`).
pub fn hsb_to_rgb(h: f64, s: f64, b: f64) -> (u8, u8, u8) {
    let h = clamp_channel(h, 0.0, 360.0);
    let s = clamp_channel(s, 0.0, 100.0);
    let b = clamp_channel(b, 0.0, 100.0);
    let s1 = s / 100.0;
    let b1 = b / 100.0;
    let c = b1 * s1;
    let x = c * (1.0 - ((h / 60.0) % 2.0 - 1.0).abs());
    let m = b1 - c;
    let (r1, g1, b1_) = if h < 60.0 {
        (c, x, 0.0)
    } else if h < 120.0 {
        (x, c, 0.0)
    } else if h < 180.0 {
        (0.0, c, x)
    } else if h < 240.0 {
        (0.0, x, c)
    } else if h < 300.0 {
        (x, 0.0, c)
    } else {
        (c, 0.0, x)
    };
    (
        ((r1 + m) * 255.0).round() as u8,
        ((g1 + m) * 255.0).round() as u8,
        ((b1_ + m) * 255.0).round() as u8,
    )
}

/// Convert RGB (0-255) to CMYK (0-100 each).
pub fn rgb_to_cmyk(r: u8, g: u8, b: u8) -> (i32, i32, i32, i32) {
    if r == 0 && g == 0 && b == 0 {
        return (0, 0, 0, 100);
    }
    let c1 = 1.0 - r as f64 / 255.0;
    let m1 = 1.0 - g as f64 / 255.0;
    let y1 = 1.0 - b as f64 / 255.0;
    let k1 = c1.min(m1).min(y1);
    (
        ((c1 - k1) / (1.0 - k1) * 100.0).round() as i32,
        ((m1 - k1) / (1.0 - k1) * 100.0).round() as i32,
        ((y1 - k1) / (1.0 - k1) * 100.0).round() as i32,
        (k1 * 100.0).round() as i32,
    )
}

/// Quantise a float colour component in 0..=1 to 8 bits.
///
/// Half rounds AWAY from zero and the result saturates, which is exactly what
/// `(v * 255.0).round() as u8` does in Rust — spelled out as a function so the
/// other port can mirror the saturation deliberately instead of trapping on an
/// out-of-range component (Swift's `UInt8(_:)` is a precondition failure there).
pub fn quantise8(v: f64) -> u8 {
    let x = (v * 255.0).round();
    if x.is_nan() {
        return 0;
    }
    x.clamp(0.0, 255.0) as u8
}

/// The Color panel's eleven channel values for one colour.
///
/// `bl` is the blue channel's YAML name (`b` is brightness in `color.yaml`), and
/// the fields here carry the YAML's units: `r`/`g`/`bl` 0–255, `h` 0–359,
/// everything else 0–100.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PanelChannels {
    pub r: u8,
    pub g: u8,
    pub bl: u8,
    pub h: i32,
    pub s: i32,
    pub b: i32,
    pub c: i32,
    pub m: i32,
    pub y: i32,
    pub k: i32,
    pub hex: String,
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
/// unedited channels from this same map, it reached the COMMITTED colour —
/// Swift committed `664040` where this port committed `664141` for the same
/// drag (COLORTIERS, 2026-07-26).
///
/// Gated across the ports by `test_fixtures/algorithms/color_convert.json`'s
/// `panel_channels` vectors.
pub fn panel_channels(rf: f64, gf: f64, bf: f64) -> PanelChannels {
    let r = quantise8(rf);
    let g = quantise8(gf);
    let bl = quantise8(bf);
    let (h, s, b) = rgb_to_hsb(r, g, bl);
    let (c, m, y, k) = rgb_to_cmyk(r, g, bl);
    PanelChannels {
        r,
        g,
        bl,
        h,
        s,
        b,
        c,
        m,
        y,
        k,
        hex: format!("{:02x}{:02x}{:02x}", r, g, bl),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_hex_6digit() {
        assert_eq!(parse_hex("#ff0000"), (255, 0, 0));
        assert_eq!(parse_hex("#00ff00"), (0, 255, 0));
        assert_eq!(parse_hex("#000000"), (0, 0, 0));
    }

    #[test]
    fn test_parse_hex_3digit() {
        assert_eq!(parse_hex("#fff"), (255, 255, 255));
        assert_eq!(parse_hex("#f00"), (255, 0, 0));
    }

    #[test]
    fn test_rgb_to_hsb_red() {
        let (h, s, b) = rgb_to_hsb(255, 0, 0);
        assert_eq!(h, 0);
        assert_eq!(s, 100);
        assert_eq!(b, 100);
    }

    #[test]
    fn test_rgb_to_hsb_green() {
        let (h, _, _) = rgb_to_hsb(0, 255, 0);
        assert_eq!(h, 120);
    }

    #[test]
    fn test_hsb_to_rgb_red() {
        assert_eq!(hsb_to_rgb(0.0, 100.0, 100.0), (255, 0, 0));
    }

    #[test]
    fn test_roundtrip() {
        let (h, s, b) = rgb_to_hsb(128, 64, 192);
        let (r, g, b2) = hsb_to_rgb(h as f64, s as f64, b as f64);
        // Allow ±1 for rounding
        assert!((r as i32 - 128).abs() <= 1);
        assert!((g as i32 - 64).abs() <= 1);
        assert!((b2 as i32 - 192).abs() <= 1);
    }
}
