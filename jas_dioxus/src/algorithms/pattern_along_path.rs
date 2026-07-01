//! Pattern brush: the side artwork tile repeated along the stroke path.
//! Faithful reference for the Swift / OCaml / Python ports (BRUSHES.md
//! §Brush types > Pattern). Each side tile is a set of closed polygons in
//! tile coordinates (x in [0, width], y in [0, height]); the tile is warped
//! onto successive arc-length spans of the path (like art_along_path, but
//! tiled instead of stretched once).
//!
//! Tile ribbon height = (scale / 100) · stroke_weight; the tile's displayed
//! width along the path keeps its natural aspect (ribbon · width/height).
//! `spacing` (percent of tile width) is the gap between tiles.
//!
//! Phase 1: SIDE tile only (no start/end/corner tiles — corner tiles need
//! path-corner classification, deferred), polygon artwork, first subpath,
//! `fit: stretch` approximated by whole-tile tiling from the start.

use crate::geometry::element::PathCommand;
use super::art_along_path::{flatten, point_at_arclength};

/// A Pattern brush: inline polygon side tile plus tiling parameters.
#[derive(Debug, Clone)]
pub struct PatternBrush {
    pub tile_width: f64,
    pub tile_height: f64,
    /// Side-tile polygons in tile coordinates.
    pub side: Vec<Vec<(f64, f64)>>,
    pub scale: f64,   // percent
    pub spacing: f64, // percent of tile width
    pub flip_across: bool,
    pub flip_along: bool,
    pub stroke_weight: f64, // pt
}

/// Tile `brush.side` along the stroke `commands`. Returns one warped polygon
/// per (tile placement × side polygon); empty for degenerate input.
pub fn pattern_along_path(commands: &[PathCommand], brush: &PatternBrush) -> Vec<Vec<(f64, f64)>> {
    if brush.tile_width <= 0.0 || brush.tile_height <= 0.0 {
        return Vec::new();
    }
    let pts = flatten(commands);
    if pts.len() < 2 {
        return Vec::new();
    }
    let mut cum = vec![0.0_f64; pts.len()];
    for i in 1..pts.len() {
        let dx = pts[i].0 - pts[i - 1].0;
        let dy = pts[i].1 - pts[i - 1].1;
        cum[i] = cum[i - 1] + (dx * dx + dy * dy).sqrt();
    }
    let total = cum[pts.len() - 1];
    if total <= 0.0 {
        return Vec::new();
    }
    let ribbon = (brush.scale / 100.0) * brush.stroke_weight;
    let tile_w = ribbon * (brush.tile_width / brush.tile_height);
    if tile_w <= 0.0 {
        return Vec::new();
    }
    let gap = tile_w * (brush.spacing / 100.0);
    let step = tile_w + gap;
    if step <= 0.0 {
        return Vec::new();
    }
    // Whole tiles that fit; at least one (a short path gets one clamped tile).
    let n = ((total / step).floor() as i64).max(1);

    let mut out = Vec::new();
    for i in 0..n {
        let start = i as f64 * step;
        for poly in &brush.side {
            let mut warped = Vec::with_capacity(poly.len());
            for &(ax, ay) in poly {
                let mut u = (ax / brush.tile_width).clamp(0.0, 1.0);
                if brush.flip_along {
                    u = 1.0 - u;
                }
                let s = start + u * tile_w;
                let (px, py, tan) = point_at_arclength(&pts, &cum, total, s);
                let mut off = (ay - brush.tile_height / 2.0) / brush.tile_height * ribbon;
                if brush.flip_across {
                    off = -off;
                }
                let nx = -tan.sin();
                let ny = tan.cos();
                warped.push((px + nx * off, py + ny * off));
            }
            out.push(warped);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn brush() -> PatternBrush {
        PatternBrush {
            tile_width: 100.0,
            tile_height: 20.0,
            side: vec![vec![(0.0, 10.0), (50.0, 0.0), (100.0, 10.0), (50.0, 20.0)]],
            scale: 100.0,
            spacing: 0.0,
            flip_across: false,
            flip_along: false,
            // ribbon = 10 -> tile_w = 10 * (100/20) = 50 -> two tiles on a 100-long path.
            stroke_weight: 10.0,
        }
    }

    #[test]
    fn straight_path_tiles_twice() {
        let cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 100.0, y: 0.0 },
        ];
        let out = pattern_along_path(&cmds, &brush());
        assert_eq!(out.len(), 2, "two tiles");
        let close = |a: (f64, f64), b: (f64, f64)| (a.0 - b.0).abs() < 1e-6 && (a.1 - b.1).abs() < 1e-6;
        // Tile 0 spans x 0..50.
        assert!(close(out[0][0], (0.0, 0.0)), "t0 start: {:?}", out[0][0]);
        assert!(close(out[0][1], (25.0, -5.0)), "t0 mid-top: {:?}", out[0][1]);
        assert!(close(out[0][2], (50.0, 0.0)), "t0 end: {:?}", out[0][2]);
        // Tile 1 spans x 50..100.
        assert!(close(out[1][0], (50.0, 0.0)), "t1 start: {:?}", out[1][0]);
        assert!(close(out[1][2], (100.0, 0.0)), "t1 end: {:?}", out[1][2]);
    }

    #[test]
    fn empty_for_degenerate() {
        assert!(pattern_along_path(&[PathCommand::MoveTo { x: 0.0, y: 0.0 }], &brush()).is_empty());
    }
}
