//! The Brushes panel's `brush_preview` thumbnail, as SVG markup (BRUSHES.md).
//!
//! Every tile draws its brush in a `0 0 40 40` box: a calligraphic brush as
//! its nib ellipse, an art / pattern / bristle brush as a stroke sample along
//! a short horizontal path. Until this module the drawing lived only in the
//! web VIEW (`renderer.rs`, web-gated), so the panel plan a native shell
//! materializes had nothing to send: every preview reached the shell as
//! `values: {}`, an empty box.
//!
//! One copy, two readers: the web renderer wraps [`preview_svg`] in its
//! `<svg>` element, and `panel_plan` sends the same markup in the entry's
//! `display` map. Paint is `currentColor`, never a CSS variable, because the
//! shell has no stylesheet: each reader sets the colour it draws in.

use serde_json::Value;

use crate::algorithms::brush_json::{art_from_json, bristle_from_json, pattern_from_json};
use crate::geometry::element::PathCommand;

/// The coordinate box every preview is drawn in.
pub const VIEWBOX: &str = "0 0 40 40";

/// The SVG elements (no enclosing `<svg>`) that draw `brush` in [`VIEWBOX`],
/// or `None` for a brush type with no preview (the tile stays an empty box).
pub fn preview_svg(brush: &Value) -> Option<String> {
    let num = |k: &str, d: f64| brush.get(k).and_then(Value::as_f64).unwrap_or(d);
    // A stroke sample runs along a short horizontal path across the tile.
    let sample = |x0: f64, x1: f64| vec![
        PathCommand::MoveTo { x: x0, y: 20.0 },
        PathCommand::LineTo { x: x1, y: 20.0 },
    ];
    let points = |pts: &[(f64, f64)]| pts.iter()
        .map(|(x, y)| format!("{:.2},{:.2}", x, y))
        .collect::<Vec<_>>()
        .join(" ");
    let polygons = |polys: Vec<Vec<(f64, f64)>>| polys.iter()
        .filter(|p| p.len() >= 3)
        .map(|p| format!(r#"<polygon points="{}" fill="currentColor"/>"#, points(p)))
        .collect::<String>();
    match brush.get("type").and_then(Value::as_str)? {
        "calligraphic" => {
            // Map pt size to a display diameter that fills the tile; roundness
            // flattens the minor axis (100 = circle), angle rotates it.
            let angle = num("angle", 0.0);
            let major = (num("size", 5.0) * 2.8).clamp(4.0, 30.0);
            let minor = (major * (num("roundness", 100.0) / 100.0)).clamp(1.5, major);
            let (rx, ry) = (major / 2.0, minor / 2.0);
            Some(format!(
                r#"<ellipse cx="20" cy="20" rx="{rx}" ry="{ry}" fill="currentColor" transform="rotate({angle} 20 20)"/>"#
            ))
        }
        "art" => {
            // A fixed ribbon height regardless of the brush's own scale.
            let mut art = art_from_json(brush, 14.0)?;
            art.scale = 100.0;
            Some(polygons(crate::algorithms::art_along_path::art_along_path(&sample(5.0, 35.0), &art)))
        }
        "pattern" => {
            let mut pat = pattern_from_json(brush, 10.0)?;
            pat.scale = 100.0;
            Some(polygons(crate::algorithms::pattern_along_path::pattern_along_path(&sample(4.0, 36.0), &pat)))
        }
        "bristle" => {
            // Offset bristle lines, each at its own opacity: they overlap and
            // build up.
            let br = bristle_from_json(brush, 6.0)?;
            Some(crate::algorithms::bristle_stroke::bristle_stroke(&sample(4.0, 36.0), &br).iter()
                .filter(|l| l.len() >= 2)
                .map(|l| format!(
                    r#"<polyline points="{}" fill="none" stroke="currentColor" stroke-width="{}" stroke-opacity="{}" stroke-linecap="round"/>"#,
                    points(l), br.line_width(), br.alpha()))
                .collect())
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// The nib law, row by row. The numbers are the web view's own formula
    /// (`major = clamp(size * 2.8, 4, 30)`, `minor = clamp(major * roundness /
    /// 100, 1.5, major)`), worked by hand:
    ///   size 5, roundness 50  -> major 14, minor 7   -> rx 7,  ry 3.5
    ///   size 1, roundness 100 -> major 2.8 -> 4 (floor), minor 4 -> rx 2, ry 2
    ///   size 20, roundness 0  -> major 56 -> 30 (cap), minor 0 -> 1.5 -> rx 15, ry 0.75
    #[test]
    fn a_calligraphic_brush_is_its_nib_ellipse() {
        let rows = [
            (json!({"type": "calligraphic", "size": 5.0, "roundness": 50.0, "angle": 30.0}),
             r#"<ellipse cx="20" cy="20" rx="7" ry="3.5" fill="currentColor" transform="rotate(30 20 20)"/>"#),
            (json!({"type": "calligraphic", "size": 1.0, "roundness": 100.0, "angle": 0.0}),
             r#"<ellipse cx="20" cy="20" rx="2" ry="2" fill="currentColor" transform="rotate(0 20 20)"/>"#),
            (json!({"type": "calligraphic", "size": 20.0, "roundness": 0.0, "angle": -45.0}),
             r#"<ellipse cx="20" cy="20" rx="15" ry="0.75" fill="currentColor" transform="rotate(-45 20 20)"/>"#),
        ];
        for (brush, want) in rows {
            assert_eq!(preview_svg(&brush).as_deref(), Some(want), "{brush}");
        }
    }

    /// The web view's defaults: size 5, roundness 100, angle 0.
    #[test]
    fn a_calligraphic_brush_with_no_parameters_takes_the_defaults() {
        assert_eq!(
            preview_svg(&json!({"type": "calligraphic"})).as_deref(),
            Some(r#"<ellipse cx="20" cy="20" rx="7" ry="7" fill="currentColor" transform="rotate(0 20 20)"/>"#)
        );
    }

    fn square() -> Value {
        json!({"width": 10.0, "height": 10.0, "polygons": [[[0, 0], [10, 0], [10, 10], [0, 10]]]})
    }

    /// Every number in the markup, so a test can ask where the drawing lands.
    fn numbers(svg: &str) -> Vec<f64> {
        svg.split(|c: char| !(c.is_ascii_digit() || c == '.' || c == '-'))
            .filter_map(|t| t.parse::<f64>().ok())
            .collect()
    }

    /// A stroke sample must be drawn, in `currentColor`, and INSIDE the box:
    /// a preview that runs off the tile draws nothing visible and reads as
    /// "no preview".
    #[test]
    fn a_stroke_sample_brush_draws_inside_the_box_in_the_current_colour() {
        let rows = [
            ("art", json!({"type": "art", "artwork": square()}), "<polygon "),
            ("pattern", json!({"type": "pattern", "tiles": {"side": square()}}), "<polygon "),
            ("bristle", json!({"type": "bristle", "size": 3.0}), "<polyline "),
        ];
        for (name, brush, element) in rows {
            let svg = preview_svg(&brush).unwrap_or_else(|| panic!("{name}: no preview"));
            assert!(svg.contains(element), "{name}: {svg}");
            assert!(svg.contains("currentColor"), "{name}: {svg}");
            assert!(!svg.contains("var("), "{name}: a CSS variable reaches no native shell: {svg}");
            let ns = numbers(svg.split("points=").nth(1).unwrap_or(""));
            assert!(!ns.is_empty(), "{name}: no coordinates read -- the check is vacuous: {svg}");
            // bristle carries opacity/width attrs after `points`; they are in
            // range too, so the whole tail is bounded by the box.
            assert!(ns.iter().all(|&v| (-0.001..=40.001).contains(&v)), "{name}: {ns:?}");
        }
    }

    #[test]
    fn a_brush_with_no_preview_is_none() {
        for brush in [json!({"type": "scatter"}), json!({}), Value::Null,
                      json!({"type": "art"}), json!({"type": "pattern", "tiles": {}})] {
            assert_eq!(preview_svg(&brush), None, "{brush}");
        }
    }
}
