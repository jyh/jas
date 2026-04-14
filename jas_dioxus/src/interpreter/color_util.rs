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

/// Convert HSB (h:0-359, s:0-100, b:0-100) to RGB (0-255).
pub fn hsb_to_rgb(h: f64, s: f64, b: f64) -> (u8, u8, u8) {
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
