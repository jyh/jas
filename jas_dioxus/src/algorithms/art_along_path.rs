//! Art brush: one vector artwork stretched along the full stroke path.
//! Faithful reference for the Swift / OCaml / Python ports (BRUSHES.md
//! §Brush types > Art). The artwork is a set of closed polygons in artwork
//! coordinates (x ∈ [0, width], y ∈ [0, height]); it is warped onto the
//! stroke path so the artwork's x-axis maps to arc-length along the path
//! (0 → start, width → end) and its y-axis maps to the perpendicular
//! (normal) offset, centred on the path and scaled to the ribbon height.
//!
//! Ribbon height = (scale / 100) · stroke_weight — the full artwork height
//! spans that many points across the path. `flip_along` reverses the
//! arc-length mapping; `flip_across` mirrors the perpendicular offset.
//!
//! Phase 1: polygon artwork only (no arbitrary SVG `d` curves), first
//! subpath of the stroke path only, `scale_mode: proportional` (the
//! artwork stretches to the full path length). Colorization is applied by
//! the caller when filling the returned polygons.

use crate::geometry::element::PathCommand;

/// An Art brush: inline polygon artwork plus warp parameters.
#[derive(Debug, Clone)]
pub struct ArtBrush {
    pub artwork_width: f64,
    pub artwork_height: f64,
    /// Closed polygons in artwork coordinates.
    pub artwork: Vec<Vec<(f64, f64)>>,
    pub scale: f64, // percent
    pub flip_across: bool,
    pub flip_along: bool,
    pub stroke_weight: f64, // pt
}

/// Warp `brush.artwork` along the stroke `commands`. Returns one warped
/// polygon per artwork polygon (empty for degenerate input).
pub fn art_along_path(commands: &[PathCommand], brush: &ArtBrush) -> Vec<Vec<(f64, f64)>> {
    if brush.artwork_width <= 0.0 || brush.artwork_height <= 0.0 {
        return Vec::new();
    }
    let pts = flatten(commands);
    if pts.len() < 2 {
        return Vec::new();
    }
    // Cumulative arc-length over the flattened polyline.
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
    // Full artwork height spans this many points across the path.
    let h_out = (brush.scale / 100.0) * brush.stroke_weight;

    let mut out = Vec::with_capacity(brush.artwork.len());
    for poly in &brush.artwork {
        let mut warped = Vec::with_capacity(poly.len());
        for &(ax, ay) in poly {
            let mut t = (ax / brush.artwork_width).clamp(0.0, 1.0);
            if brush.flip_along {
                t = 1.0 - t;
            }
            let (px, py, tan) = point_at_arclength(&pts, &cum, total, t * total);
            let mut off = (ay - brush.artwork_height / 2.0) / brush.artwork_height * h_out;
            if brush.flip_across {
                off = -off;
            }
            // Left normal of the tangent (rotate +90°).
            let nx = -tan.sin();
            let ny = tan.cos();
            warped.push((px + nx * off, py + ny * off));
        }
        out.push(warped);
    }
    out
}

/// Point, and tangent (radians), at arc-length `s` along the polyline.
/// Shared with pattern_along_path / bristle_stroke.
pub(crate) fn point_at_arclength(
    pts: &[(f64, f64)],
    cum: &[f64],
    total: f64,
    s: f64,
) -> (f64, f64, f64) {
    let s = s.clamp(0.0, total);
    // Binary search for the segment [i-1, i] containing s.
    let mut lo = 1usize;
    let mut hi = pts.len() - 1;
    while lo < hi {
        let mid = (lo + hi) / 2;
        if cum[mid] < s {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    let i = lo;
    let seg = cum[i] - cum[i - 1];
    let f = if seg > 0.0 { (s - cum[i - 1]) / seg } else { 0.0 };
    let (x0, y0) = pts[i - 1];
    let (x1, y1) = pts[i];
    let x = x0 + (x1 - x0) * f;
    let y = y0 + (y1 - y0) * f;
    let tan = (y1 - y0).atan2(x1 - x0);
    (x, y, tan)
}

/// Flatten the first subpath of `commands` into a polyline. Cubics/quads
/// are subdivided uniformly; matches the conservative Phase-1 sampler used
/// by `calligraphic_outline`. Shared with pattern_along_path / bristle_stroke.
/// `pub` rather than `pub(crate)` so the `algorithm_roundtrip` binary can
/// drive it: the `art_flatten` conformance family is the only thing that can
/// see a defect this function shares with its Swift twin.
pub fn flatten(commands: &[PathCommand]) -> Vec<(f64, f64)> {
    let mut out: Vec<(f64, f64)> = Vec::new();
    let (mut cx, mut cy) = (0.0_f64, 0.0_f64);
    let (mut sx, mut sy) = (0.0_f64, 0.0_f64);
    let mut started = false;
    let push = |out: &mut Vec<(f64, f64)>, x: f64, y: f64| {
        if out.last().map_or(true, |&(lx, ly)| lx != x || ly != y) {
            out.push((x, y));
        }
    };
    for cmd in commands {
        match cmd {
            PathCommand::MoveTo { x, y } => {
                if started {
                    return out;
                }
                cx = *x;
                cy = *y;
                sx = cx;
                sy = cy;
                push(&mut out, cx, cy);
            }
            PathCommand::LineTo { x, y } => {
                push(&mut out, *x, *y);
                cx = *x;
                cy = *y;
                started = true;
            }
            PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
                let n = 16;
                for k in 1..=n {
                    let t = k as f64 / n as f64;
                    let u = 1.0 - t;
                    let bx = u * u * u * cx + 3.0 * u * u * t * x1 + 3.0 * u * t * t * x2 + t * t * t * x;
                    let by = u * u * u * cy + 3.0 * u * u * t * y1 + 3.0 * u * t * t * y2 + t * t * t * y;
                    push(&mut out, bx, by);
                }
                cx = *x;
                cy = *y;
                started = true;
            }
            PathCommand::QuadTo { x1, y1, x, y } => {
                let n = 12;
                for k in 1..=n {
                    let t = k as f64 / n as f64;
                    let u = 1.0 - t;
                    let bx = u * u * cx + 2.0 * u * t * x1 + t * t * x;
                    let by = u * u * cy + 2.0 * u * t * y1 + t * t * y;
                    push(&mut out, bx, by);
                }
                cx = *x;
                cy = *y;
                started = true;
            }
            PathCommand::ClosePath => {
                // S-4: a LEADING ClosePath is a no-op. Ruled by JYH at the
                // fleet council, 2026-07-27 -- a close appearing before any
                // point has been established contributes nothing, because the
                // artist never means a close-before-anything.
                //
                // Without this guard the arm below returned the (still empty)
                // accumulator, so `[Z, M(3,2), L(13,2)]` -- a path an artist
                // can draw -- flattened to NOTHING and art / pattern-along-
                // path / the bristle brush drew nothing at all. The ruling was
                // already honoured by `flatten_path_commands` (`!pts.is_empty()`)
                // and by `flatten_path_to_rings` (a flush of an empty ring
                // drops it); this was the third flattener, and it was wrong
                // identically in both ports, so no equivalence gate saw it.
                //
                // The guard is deliberately "nothing emitted yet" and NOT
                // "cx == sx && cy == sy": at a MoveTo-then-Z degenerate
                // subpath those coordinates are equal too, and there the close
                // is REAL -- it ends the subpath. Gated by
                // test_fixtures/algorithms/art_flatten.json.
                if out.is_empty() {
                    continue;
                }
                if cx != sx || cy != sy {
                    push(&mut out, sx, sy);
                }
                return out;
            }
            _ => return out,
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rhombus() -> ArtBrush {
        // A tapered lens (rhombus): pointed at x=0 and x=W, widest at x=W/2.
        ArtBrush {
            artwork_width: 100.0,
            artwork_height: 20.0,
            artwork: vec![vec![(0.0, 10.0), (50.0, 0.0), (100.0, 10.0), (50.0, 20.0)]],
            scale: 100.0,
            flip_across: false,
            flip_along: false,
            stroke_weight: 2.0,
        }
    }

    #[test]
    fn straight_path_warps_to_centered_ribbon() {
        // A straight horizontal path: artwork maps 1:1 along x, ribbon
        // height = (100/100)*2 = 2 (±1 about the path).
        let cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 100.0, y: 0.0 },
        ];
        let out = art_along_path(&cmds, &rhombus());
        assert_eq!(out.len(), 1);
        let p = &out[0];
        assert_eq!(p.len(), 4);
        let close = |a: (f64, f64), b: (f64, f64)| {
            (a.0 - b.0).abs() < 1e-6 && (a.1 - b.1).abs() < 1e-6
        };
        assert!(close(p[0], (0.0, 0.0)), "start point on path: {:?}", p[0]);
        assert!(close(p[1], (50.0, -1.0)), "mid-top offset -1: {:?}", p[1]);
        assert!(close(p[2], (100.0, 0.0)), "end point on path: {:?}", p[2]);
        assert!(close(p[3], (50.0, 1.0)), "mid-bottom offset +1: {:?}", p[3]);
    }

    #[test]
    fn empty_for_degenerate() {
        let cmds = vec![PathCommand::MoveTo { x: 0.0, y: 0.0 }];
        assert!(art_along_path(&cmds, &rhombus()).is_empty());
    }

    #[test]
    fn flip_across_mirrors_offset() {
        let cmds = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 100.0, y: 0.0 },
        ];
        let mut b = rhombus();
        b.flip_across = true;
        let out = art_along_path(&cmds, &b);
        // Mid-top now offsets +1 (mirrored).
        assert!((out[0][1].1 - 1.0).abs() < 1e-6, "flip_across mid: {:?}", out[0][1]);
    }

    // ── S-4: a leading ClosePath is a no-op ──────────────────────────────
    //
    // Ruled by JYH at the fleet council, 2026-07-27. Honoured by
    // `flatten_path_commands` and `flatten_path_to_rings` since that ruling
    // landed; this flattener was the THIRD one and did not honour it, in BOTH
    // ports identically, so the equivalence gate was structurally blind. The
    // cross-language pin is test_fixtures/algorithms/art_flatten.json; these
    // are the in-port pins, and the FIRST is the artist-visible consequence
    // the fixture cannot reach (the fixture drives `flatten`, not the brush).

    /// THE CONSEQUENCE. A leading Z made the whole path flatten to nothing, so
    /// an art brush applied to it produced NO ribbon at all — a silently blank
    /// stroke. With the ruling honoured the output is byte-identical to the
    /// same path without the leading Z (`straight_path_warps_to_centered_ribbon`).
    #[test]
    fn art_along_a_path_with_a_leading_close_draws_the_same_ribbon() {
        let with_z = art_along_path(
            &[
                PathCommand::ClosePath,
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::LineTo { x: 100.0, y: 0.0 },
            ],
            &rhombus(),
        );
        let without_z = art_along_path(
            &[
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::LineTo { x: 100.0, y: 0.0 },
            ],
            &rhombus(),
        );
        assert_eq!(with_z, without_z, "a leading Z changed the ribbon");
        // MANDATORY GEOMETRY PAIRING: equality to a possibly-empty value is not
        // enough — say where the ribbon actually is.
        assert_eq!(with_z.len(), 1, "one ribbon");
        assert_eq!(with_z[0].len(), 4);
        assert!(
            (with_z[0][1].0 - 50.0).abs() < 1e-6 && (with_z[0][1].1 + 1.0).abs() < 1e-6,
            "mid-top should be (50, -1), got {:?}",
            with_z[0][1]
        );
    }

    /// The flattener, directly: a leading close is SKIPPED, not a bail-out.
    /// Without the guard this returns `[]`.
    #[test]
    fn flatten_leading_close_is_skipped_not_a_bail_out() {
        let out = flatten(&[
            PathCommand::ClosePath,
            PathCommand::MoveTo { x: 3.0, y: 2.0 },
            PathCommand::LineTo { x: 13.0, y: 2.0 },
        ]);
        assert_eq!(out, vec![(3.0, 2.0), (13.0, 2.0)]);
    }

    /// SCOPE BOUNDARY against the over-fix. A close that is NOT leading still
    /// closes and still ENDS the first subpath — art rides the first subpath
    /// only. This does NOT fail under the pre-fix code; it fails if the arm is
    /// turned into an unconditional `continue`, which would append the second
    /// subpath and silently redefine "the first subpath".
    #[test]
    fn flatten_a_real_close_still_ends_the_first_subpath() {
        let out = flatten(&[
            PathCommand::MoveTo { x: 3.0, y: 2.0 },
            PathCommand::LineTo { x: 13.0, y: 2.0 },
            PathCommand::ClosePath,
            PathCommand::MoveTo { x: 23.0, y: 2.0 },
            PathCommand::LineTo { x: 33.0, y: 2.0 },
        ]);
        assert_eq!(out, vec![(3.0, 2.0), (13.0, 2.0), (3.0, 2.0)]);
    }

    /// SCOPE BOUNDARY, and why the guard reads the ACCUMULATOR and not the
    /// coordinates: at `M(5,5) Z` we also have cx == sx and cy == sy, but a
    /// point has been established, so the close is real and ends the subpath.
    /// A guard written as `cx == sx && cy == sy` would pass the fixture's
    /// leading-close vectors and break this one.
    #[test]
    fn flatten_moveto_then_immediate_close_is_a_real_close() {
        let out = flatten(&[
            PathCommand::MoveTo { x: 5.0, y: 5.0 },
            PathCommand::ClosePath,
            PathCommand::MoveTo { x: 50.0, y: 50.0 },
            PathCommand::LineTo { x: 60.0, y: 50.0 },
        ]);
        assert_eq!(out, vec![(5.0, 5.0)]);
    }
}
