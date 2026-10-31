//! The Color Picker's two pictures (finding 13, step 2), each a
//! `data:image/bmp;base64,…` URI a native shell draws from the dialog plan:
//! the hue strip (`cp_colorbar`, a `color_hue_bar`) and the saturation and
//! brightness field (`cp_gradient`, a `color_gradient`).
//!
//! The law is [`crate::color_bar_picture`]'s: each pixel is the PICK at that
//! pixel, so a click lands on the colour drawn under it. The strip's pick is
//! [`strip_value`] (top is max: 359 for hue, so top-down the strip runs red,
//! magenta, blue, cyan, green, yellow, red); the field's is [`gradient_sb`].
//! Both picks are held to `test_fixtures/algorithms/picker_picks.json`, and
//! so is each picture here, at every corpus point it can draw.

use crate::color_bar_picture::bmp_data_uri;
use crate::interpreter::color_util::{gradient_sb, hsb_to_rgb, strip_value};

/// The hue strip's max, the pick's own (`strip_value(v, HUE_MAX)`).
pub const HUE_MAX: f64 = 359.0;
/// The strip picture's size in pixels; a shell scales it to the leaf's rect.
const STRIP_WIDTH: usize = 16;
const STRIP_HEIGHT: usize = 180;
/// The field picture's size in pixels (design §2: 64 × 64 is enough).
const FIELD_WIDTH: usize = 64;
const FIELD_HEIGHT: usize = 64;

/// The strip's colour at `v` (0 at the top, 1 at the bottom): the hue the
/// strip picks there, at full saturation and brightness.
pub fn strip_rgb(v: f64) -> (u8, u8, u8) {
    hsb_to_rgb(strip_value(v, HUE_MAX), 100.0, 100.0)
}

/// The field's colour at (`u`, `v`) under hue `h`: the saturation and the
/// brightness the field picks there.
pub fn field_rgb(h: f64, u: f64, v: f64) -> (u8, u8, u8) {
    let (s, b) = gradient_sb(u, v);
    hsb_to_rgb(h, s, b)
}

/// The hue strip as a BMP data URI. Cached: the strip never changes.
pub fn strip_data_uri() -> String {
    use std::sync::OnceLock;
    static CACHE: OnceLock<String> = OnceLock::new();
    CACHE.get_or_init(|| bmp_data_uri(STRIP_WIDTH, STRIP_HEIGHT, |_, v| strip_rgb(v))).clone()
}

/// The field under hue `h` as a BMP data URI.
pub fn field_data_uri(h: f64) -> String {
    bmp_data_uri(FIELD_WIDTH, FIELD_HEIGHT, |u, v| field_rgb(h, u, v))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::interpreter::color_util::rgb_to_hsb;

    fn vectors(function: &str) -> Vec<serde_json::Value> {
        let text = std::fs::read_to_string("../test_fixtures/algorithms/picker_picks.json")
            .expect("picker_picks.json");
        let doc: serde_json::Value = serde_json::from_str(&text).expect("picker_picks.json parses");
        doc["vectors"].as_array().expect("vectors").iter()
            .filter(|v| v["function"] == function).cloned().collect()
    }

    /// The pixels of a BMP data URI, top row first, as (r, g, b), with its size.
    fn decode(uri: &str) -> (usize, usize, Vec<Vec<(u8, u8, u8)>>) {
        let b64 = uri.strip_prefix("data:image/bmp;base64,").expect("a BMP data URI");
        let alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut bytes = Vec::new();
        let (mut acc, mut bits) = (0u32, 0u32);
        for c in b64.bytes().filter(|&c| c != b'=') {
            acc = (acc << 6) | alphabet.iter().position(|&a| a == c).expect("base64") as u32;
            bits += 6;
            if bits >= 8 {
                bits -= 8;
                bytes.push((acc >> bits) as u8);
                acc &= (1 << bits) - 1;
            }
        }
        assert_eq!(&bytes[0..2], b"BM");
        let w = i32::from_le_bytes(bytes[18..22].try_into().unwrap()) as usize;
        let h = i32::from_le_bytes(bytes[22..26].try_into().unwrap()) as usize;
        assert_eq!(u16::from_le_bytes(bytes[28..30].try_into().unwrap()), 24, "24-bit");
        let mut rows = vec![Vec::new(); h];
        for bmp_row in 0..h {
            let start = 54 + bmp_row * w * 3;
            rows[h - 1 - bmp_row] = (0..w).map(|x| {
                let p = &bytes[start + x * 3..start + x * 3 + 3];
                (p[2], p[1], p[0])
            }).collect();
        }
        (w, h, rows)
    }

    /// The shortest distance between two hues on the circle.
    fn hue_gap(a: f64, b: f64) -> f64 {
        let d = (a - b).rem_euclid(360.0);
        d.min(360.0 - d)
    }

    /// THE STRIP IS DRAWN BY ITS OWN PICK, at every hue point of step 1's
    /// corpus the strip can draw. The pixel row holding `v` shows the hue the
    /// pick stores there, to within one row (359 / 180 of a degree) and the
    /// RGB rounding. The corpus's v = 1/6 row is the one that refutes a strip
    /// drawn the other way up: magenta (299), never yellow (60).
    #[test]
    fn the_strip_is_drawn_by_its_own_pick_at_every_corpus_hue() {
        let (w, h, rows) = decode(&strip_data_uri());
        assert_eq!((w, h), (STRIP_WIDTH, STRIP_HEIGHT));
        let mut seen = 0;
        for vec in vectors("strip_value") {
            if vec["max"] != serde_json::json!(HUE_MAX) { continue; }
            let v = vec["v"].as_f64().unwrap();
            if !(0.0..=1.0).contains(&v) { continue; } // a clamp: off the picture
            let row = ((v * h as f64) as usize).min(h - 1);
            let (r, g, b) = rows[row][w / 2];
            let (drawn, _, _) = rgb_to_hsb(r, g, b);
            let picked = vec["expected"].as_f64().unwrap();
            let tolerance = HUE_MAX / h as f64 + 1.0;
            assert!(hue_gap(drawn as f64, picked) <= tolerance,
                    "{}: row {row} draws hue {drawn}, the pick stores {picked}", vec["name"]);
            assert!(rows[row].iter().all(|&p| p == (r, g, b)), "{}: a row is one colour", vec["name"]);
            seen += 1;
        }
        assert!(seen >= 4, "the corpus's hue rows reached the arm ({seen})");
    }

    /// THE FIELD IS DRAWN BY ITS OWN PICK under any hue, at every corpus point
    /// the field can draw: the pixel holding (u, v) is `hsb_to_rgb(h, s, b)`
    /// for the (s, b) the pick stores there, to within one pixel.
    #[test]
    fn the_field_is_drawn_by_its_own_pick_at_every_corpus_point() {
        for hue in [0.0, 120.0, 210.0, 299.0] {
            let (w, h, rows) = decode(&field_data_uri(hue));
            assert_eq!((w, h), (FIELD_WIDTH, FIELD_HEIGHT));
            let mut seen = 0;
            for vec in vectors("gradient_sb") {
                let (u, v) = (vec["u"].as_f64().unwrap(), vec["v"].as_f64().unwrap());
                if !(0.0..=1.0).contains(&u) || !(0.0..=1.0).contains(&v) { continue; }
                let (col, row) = (((u * w as f64) as usize).min(w - 1), ((v * h as f64) as usize).min(h - 1));
                let (s_at, b_at) = gradient_sb(col as f64 / w as f64, row as f64 / h as f64);
                let (s, b) = (vec["expected"][0].as_f64().unwrap(), vec["expected"][1].as_f64().unwrap());
                assert!((s_at - s).abs() <= 100.0 / w as f64 && (b_at - b).abs() <= 100.0 / h as f64,
                        "{}: pixel ({col},{row}) is not the corpus point", vec["name"]);
                assert_eq!(rows[row][col], hsb_to_rgb(hue, s_at, b_at), "{} at hue {hue}", vec["name"]);
                seen += 1;
            }
            assert!(seen >= 6, "the corpus's field rows reached the arm ({seen})");
        }
    }

    /// The field's corners are the colours the corpus names them by: the top
    /// left white, the top right the pure hue, the bottom black.
    #[test]
    fn the_fields_corners_are_white_the_hue_and_black() {
        let (w, h, rows) = decode(&field_data_uri(210.0));
        assert_eq!(rows[0][0], (255, 255, 255), "top left is white");
        assert_eq!(rows[0][w - 1], field_rgb(210.0, (w - 1) as f64 / w as f64, 0.0), "top right");
        let (hue, sat, bri) = rgb_to_hsb(rows[0][w - 1].0, rows[0][w - 1].1, rows[0][w - 1].2);
        assert!(hue_gap(hue as f64, 210.0) <= 2.0 && sat >= 97 && bri == 100, "top right is near the pure hue");
        assert!(rows[h - 1].iter().all(|&(r, g, b)| r <= 5 && g <= 5 && b <= 5), "the bottom row is black");
    }

    /// The strip is static and cached; the field is a function of the hue.
    #[test]
    fn the_strip_is_cached_and_the_field_follows_the_hue() {
        assert_eq!(strip_data_uri(), strip_data_uri());
        assert_ne!(field_data_uri(0.0), field_data_uri(120.0), "a new hue is a new picture");
        assert_eq!(field_data_uri(120.0), field_data_uri(120.0));
    }
}
