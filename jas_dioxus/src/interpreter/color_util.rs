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

/// The Color panel's WRITE path: one channel edited, the colour recomputed.
///
/// The inverse of [`panel_channels`], and it lives beside it for the reason
/// that docstring gives: the two halves must be held to the same order by every
/// port rather than each rewriting the arithmetic. `panel_channels` derives the
/// eleven channels from a colour; this takes that same map with **one field
/// replaced by what the user just dragged** and returns the colour it names.
///
/// ⚠️ **The unedited channels MUST come from [`panel_channels`]**, which is what
/// `panel` carries in both callers. A caller that instead asked the float colour
/// for its own hue / saturation / brightness would reach a different committed
/// colour — that is COLORTIERS (2026-07-26) exactly, and the reason this
/// function takes the derived map rather than a colour.
///
/// Returns float RGB in 0..1, or `None` for a mode this panel does not declare.
/// Floats rather than a `Color` so this module keeps no dependency on
/// `geometry::element` — the arithmetic is shared, the colour type is not.
///
/// # Provenance
/// Extracted verbatim from `interpreter::renderer::compute_color_from_panel`,
/// which was `feature = "web"`-gated and therefore unreachable from the native
/// FFI shell. `super::widget_commit` is the same move for the same reason (the
/// commit rules live outside the web module "so the corpus can run them
/// natively"); this follows that precedent rather than inventing one.
pub fn color_from_panel_edit(
    field: &str,
    new_val: f64,
    panel: &serde_json::Value,
) -> Option<(f64, f64, f64)> {
    // The edited field reads the DRAGGED value; every other channel reads the
    // panel's derived map. An absent channel reads 0.0, matching the web path.
    let pf = |name: &str| -> f64 {
        if name == field {
            return new_val;
        }
        panel.get(name).and_then(|v| v.as_f64()).unwrap_or(0.0)
    };

    let mode = panel.get("mode").and_then(|v| v.as_str()).unwrap_or("hsb");

    let rgb = match mode {
        "hsb" => {
            let (r, g, b) = hsb_to_rgb(pf("h"), pf("s"), pf("b"));
            (r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0)
        }
        "rgb" | "web_safe_rgb" => (pf("r") / 255.0, pf("g") / 255.0, pf("bl") / 255.0),
        "grayscale" => {
            let v = 1.0 - pf("k") / 100.0;
            (v, v, v)
        }
        "cmyk" => {
            let c = pf("c") / 100.0;
            let m = pf("m") / 100.0;
            let y = pf("y") / 100.0;
            let k = pf("k") / 100.0;
            ((1.0 - c) * (1.0 - k), (1.0 - m) * (1.0 - k), (1.0 - y) * (1.0 - k))
        }
        _ => return None,
    };
    Some(rgb)
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

    // -- color_from_panel_edit: the panel's WRITE half ---------------------

    /// The derived map for a colour, in the shape both callers pass.
    fn panel_map(mode: &str, rf: f64, gf: f64, bf: f64) -> serde_json::Value {
        let ch = panel_channels(rf, gf, bf);
        serde_json::json!({
            "mode": mode,
            "r": ch.r, "g": ch.g, "bl": ch.bl,
            "h": ch.h, "s": ch.s, "b": ch.b,
            "c": ch.c, "m": ch.m, "y": ch.y, "k": ch.k,
            "hex": ch.hex,
        })
    }

    fn as_8bit(rgb: (f64, f64, f64)) -> (u8, u8, u8) {
        (quantise8(rgb.0), quantise8(rgb.1), quantise8(rgb.2))
    }

    /// ⭐ The COLORTIERS property, stated as a test: **a drag that lands on the
    /// channel's own current value must not move the colour.**
    ///
    /// This is the one that fails if the unedited channels are ever taken from
    /// the float colour instead of [`panel_channels`] — the map would disagree
    /// with the colour by up to a whole unit, and a no-op drag would commit a
    /// different colour than the one already shown.
    #[test]
    fn a_no_op_drag_does_not_move_the_colour() {
        // The C1 seed: deliberately non-degenerate, because at white every
        // derivation agrees and a wrong one would pass.
        let (rf, gf, bf) = (0.4, 0.25, 0.25);
        let start = (quantise8(rf), quantise8(gf), quantise8(bf));
        assert_eq!(start, (102, 64, 64), "the seed, pinned");

        let mut checked = 0;
        for (mode, fields) in [
            ("hsb", &["h", "s", "b"][..]),
            ("rgb", &["r", "g", "bl"][..]),
            ("cmyk", &["c", "m", "y", "k"][..]),
        ] {
            let map = panel_map(mode, rf, gf, bf);
            for f in fields {
                let current = map.get(*f).and_then(|v| v.as_f64()).unwrap();
                let got = as_8bit(color_from_panel_edit(f, current, &map).unwrap());
                // ±1: `hsb_to_rgb`/`rgb_to_hsb` are an inverse pair only to the
                // 8-bit grid's rounding, which `test_roundtrip` above already
                // pins. The claim here is that a no-op drag stays PUT, not that
                // the pair is exact.
                assert!(
                    (got.0 as i32 - start.0 as i32).abs() <= 1
                        && (got.1 as i32 - start.1 as i32).abs() <= 1
                        && (got.2 as i32 - start.2 as i32).abs() <= 1,
                    "{mode}/{f}: no-op drag moved {start:?} to {got:?}"
                );
                checked += 1;
            }
        }
        // A loop that iterated nothing passes every assertion inside it.
        assert_eq!(checked, 10, "three modes, ten channels");
    }

    /// The edited field wins over the map; the others are read from it.
    #[test]
    fn the_dragged_channel_is_the_one_that_moves() {
        let map = panel_map("rgb", 0.4, 0.25, 0.25);
        let got = as_8bit(color_from_panel_edit("r", 200.0, &map).unwrap());
        assert_eq!(got, (200, 64, 64), "only r moved");
    }

    #[test]
    fn grayscale_reads_k_alone_and_web_safe_shares_the_rgb_arm() {
        let gray = panel_map("grayscale", 0.4, 0.25, 0.25);
        assert_eq!(as_8bit(color_from_panel_edit("k", 0.0, &gray).unwrap()), (255, 255, 255));
        assert_eq!(as_8bit(color_from_panel_edit("k", 100.0, &gray).unwrap()), (0, 0, 0));

        let ws = panel_map("web_safe_rgb", 0.4, 0.25, 0.25);
        let rgb = panel_map("rgb", 0.4, 0.25, 0.25);
        assert_eq!(
            color_from_panel_edit("g", 128.0, &ws),
            color_from_panel_edit("g", 128.0, &rgb),
            "web_safe_rgb shares the rgb arm"
        );
    }

    /// ⛔ THE NEGATIVE CONTROL, in the executable rather than in a comment.
    /// Without an arm that MUST return `None`, "every mode resolves" is
    /// indistinguishable from a function that cannot return anything else.
    #[test]
    fn an_undeclared_mode_returns_none() {
        let map = panel_map("lab", 0.4, 0.25, 0.25);
        assert_eq!(color_from_panel_edit("h", 10.0, &map), None);
        // And the absent-mode default is hsb, not None — a different arm.
        let no_mode = serde_json::json!({ "h": 0, "s": 100, "b": 100 });
        assert_eq!(
            as_8bit(color_from_panel_edit("h", 0.0, &no_mode).unwrap()),
            (255, 0, 0),
            "an absent mode defaults to hsb"
        );
    }
}
