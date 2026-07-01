//! Bristle brush: N semi-transparent bristle lines spread across the brush
//! width, each following the stroke path at a fixed perpendicular offset.
//! Faithful reference for the Swift / OCaml / Python ports (BRUSHES.md
//! §Brush types > Bristle). Bristles paint in the stroke colour with the
//! brush's own per-bristle `opacity` (they overlap and build up), so the
//! caller strokes each returned polyline with `alpha()` and `line_width()`.
//!
//! Phase 1: bristle COUNT from `density`, per-bristle line width from
//! `thickness`, alpha from `opacity`; `length` / `stiffness` / `shape` not
//! yet modelled (straight offset bristles, first subpath only).

use crate::geometry::element::PathCommand;
use super::art_along_path::flatten;

/// A Bristle brush.
#[derive(Debug, Clone, Copy)]
pub struct BristleBrush {
    pub size: f64,      // diameter at 1 pt stroke
    pub density: f64,   // percent -> bristle count
    pub thickness: f64, // percent -> per-bristle line width
    pub opacity: f64,   // percent -> per-bristle alpha
    pub stroke_weight: f64, // pt
}

impl BristleBrush {
    /// Bristle count (2..=12), derived from density.
    pub fn count(&self) -> i64 {
        ((self.density / 12.5).round() as i64).clamp(2, 12)
    }
    /// Per-bristle line width (min 0.5), from thickness and the spacing.
    pub fn line_width(&self) -> f64 {
        let bw = self.size * self.stroke_weight;
        let n = self.count() as f64;
        ((self.thickness / 100.0) * (bw / n)).max(0.5)
    }
    /// Per-bristle stroke alpha (0..=1), from opacity.
    pub fn alpha(&self) -> f64 {
        (self.opacity / 100.0).clamp(0.0, 1.0)
    }
}

/// Compute the bristle polylines: one per bristle, each the stroke path
/// offset perpendicular by that bristle's centre offset. Empty for
/// degenerate input. The caller strokes each with `alpha()` / `line_width()`.
pub fn bristle_stroke(commands: &[PathCommand], brush: &BristleBrush) -> Vec<Vec<(f64, f64)>> {
    let pts = flatten(commands);
    if pts.len() < 2 {
        return Vec::new();
    }
    let brush_width = brush.size * brush.stroke_weight;
    if brush_width <= 0.0 {
        return Vec::new();
    }
    let n = brush.count();
    let m = pts.len();
    // Per-point unit normal (perpendicular to the local tangent).
    let mut normals = Vec::with_capacity(m);
    for i in 0..m {
        let (tx, ty) = if i + 1 < m {
            (pts[i + 1].0 - pts[i].0, pts[i + 1].1 - pts[i].1)
        } else {
            (pts[i].0 - pts[i - 1].0, pts[i].1 - pts[i - 1].1)
        };
        let len = (tx * tx + ty * ty).sqrt();
        if len > 0.0 {
            normals.push((-ty / len, tx / len));
        } else {
            normals.push((0.0, 1.0));
        }
    }
    let mut out = Vec::with_capacity(n as usize);
    for b in 0..n {
        let oc = (b as f64 / (n as f64 - 1.0) - 0.5) * brush_width;
        let mut line = Vec::with_capacity(m);
        for i in 0..m {
            let (nx, ny) = normals[i];
            line.push((pts[i].0 + nx * oc, pts[i].1 + ny * oc));
        }
        out.push(line);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn brush() -> BristleBrush {
        // width = 4, density 25 -> 2 bristles at ±2.
        BristleBrush { size: 4.0, density: 25.0, thickness: 30.0, opacity: 30.0, stroke_weight: 1.0 }
    }

    #[test]
    fn straight_path_two_offset_bristles() {
        let cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 100.0, y: 0.0 },
        ];
        let out = bristle_stroke(&cmds, &brush());
        assert_eq!(out.len(), 2, "two bristles");
        let close = |a: (f64, f64), b: (f64, f64)| (a.0 - b.0).abs() < 1e-6 && (a.1 - b.1).abs() < 1e-6;
        assert!(close(out[0][0], (0.0, -2.0)), "b0 start: {:?}", out[0][0]);
        assert!(close(out[0][1], (100.0, -2.0)), "b0 end: {:?}", out[0][1]);
        assert!(close(out[1][0], (0.0, 2.0)), "b1 start: {:?}", out[1][0]);
        assert!(close(out[1][1], (100.0, 2.0)), "b1 end: {:?}", out[1][1]);
    }

    #[test]
    fn count_and_alpha() {
        let b = brush();
        assert_eq!(b.count(), 2);
        assert!((b.alpha() - 0.3).abs() < 1e-9);
    }

    #[test]
    fn empty_for_degenerate() {
        assert!(bristle_stroke(&[PathCommand::MoveTo { x: 0.0, y: 0.0 }], &brush()).is_empty());
    }
}
