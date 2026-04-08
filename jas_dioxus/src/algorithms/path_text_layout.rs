//! Layout for text that flows along a path.
//!
//! For each character in the content this computes its position and tangent
//! along an arc-length parameterised path. Returned data supports both
//! rendering and hit-testing (mouse → cursor index).

use crate::geometry::element::PathCommand;
use crate::geometry::measure::arc_lengths;
use crate::geometry::element::flatten_path_commands;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PathGlyph {
    pub idx: usize,
    /// Arc-length offset of the glyph's left edge along the path.
    pub offset: f64,
    /// Width of the glyph in pixels.
    pub width: f64,
    /// Center point (x, y) of the glyph baseline.
    pub cx: f64,
    pub cy: f64,
    /// Tangent angle (radians) of the path at the glyph center.
    pub angle: f64,
    /// True if the glyph fell off the end of the path.
    pub overflow: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PathTextLayout {
    pub glyphs: Vec<PathGlyph>,
    /// Total arc length of the path.
    pub total_length: f64,
    pub font_size: f64,
    pub char_count: usize,
}

/// Compute glyph positions for `content` flowing along `d`.
///
/// `start_offset` is in [0, 1] (fraction of total path length).
/// `measure` returns pixel widths for each character substring.
pub fn layout_path_text(
    d: &[PathCommand],
    content: &str,
    start_offset: f64,
    font_size: f64,
    measure: &dyn Fn(&str) -> f64,
) -> PathTextLayout {
    let pts = flatten_path_commands(d);
    let lengths = arc_lengths(&pts);
    let total = lengths.last().copied().unwrap_or(0.0);

    let mut glyphs = Vec::new();
    let chars: Vec<char> = content.chars().collect();
    let n = chars.len();

    if total <= 0.0 || pts.is_empty() {
        return PathTextLayout { glyphs, total_length: total, font_size, char_count: n };
    }

    let start_arc = start_offset.clamp(0.0, 1.0) * total;
    let mut cur_arc = start_arc;

    for (i, ch) in chars.iter().enumerate() {
        let s = ch.to_string();
        let cw = measure(&s);
        let center_arc = cur_arc + cw / 2.0;
        let overflow = center_arc > total;
        let (cx, cy, angle) = sample_at_arc(&pts, &lengths, center_arc.min(total));
        glyphs.push(PathGlyph {
            idx: i,
            offset: cur_arc,
            width: cw,
            cx,
            cy,
            angle,
            overflow,
        });
        cur_arc += cw;
    }

    PathTextLayout { glyphs, total_length: total, font_size, char_count: n }
}

/// Sample (x, y, tangent_angle) at a given arc length.
fn sample_at_arc(
    pts: &[(f64, f64)],
    lengths: &[f64],
    arc: f64,
) -> (f64, f64, f64) {
    if pts.len() < 2 {
        let p = pts.first().copied().unwrap_or((0.0, 0.0));
        return (p.0, p.1, 0.0);
    }
    let arc = arc.max(0.0);
    for i in 1..lengths.len() {
        if lengths[i] >= arc {
            let seg = lengths[i] - lengths[i - 1];
            let t = if seg > 0.0 {
                (arc - lengths[i - 1]) / seg
            } else {
                0.0
            };
            let (ax, ay) = pts[i - 1];
            let (bx, by) = pts[i];
            let x = ax + t * (bx - ax);
            let y = ay + t * (by - ay);
            let angle = (by - ay).atan2(bx - ax);
            return (x, y, angle);
        }
    }
    let last = pts.len() - 1;
    let (ax, ay) = pts[last - 1];
    let (bx, by) = pts[last];
    (bx, by, (by - ay).atan2(bx - ax))
}

impl PathTextLayout {
    /// Cursor visual position at index `cursor` (0..=char_count).
    /// Returns (x, y, angle) of the cursor base.
    pub fn cursor_pos(&self, cursor: usize) -> Option<(f64, f64, f64)> {
        if self.glyphs.is_empty() {
            return None;
        }
        if cursor == 0 {
            let g = &self.glyphs[0];
            // Move from center back to left edge.
            let (dx, dy) = (-g.angle.cos() * g.width / 2.0, -g.angle.sin() * g.width / 2.0);
            return Some((g.cx + dx, g.cy + dy, g.angle));
        }
        if cursor >= self.glyphs.len() {
            let g = self.glyphs.last().unwrap();
            let (dx, dy) = (g.angle.cos() * g.width / 2.0, g.angle.sin() * g.width / 2.0);
            return Some((g.cx + dx, g.cy + dy, g.angle));
        }
        let g = &self.glyphs[cursor];
        let (dx, dy) = (-g.angle.cos() * g.width / 2.0, -g.angle.sin() * g.width / 2.0);
        Some((g.cx + dx, g.cy + dy, g.angle))
    }

    /// Hit-test a point against this path-text layout. Returns the cursor
    /// index that minimizes the distance to the click.
    pub fn hit_test(&self, x: f64, y: f64) -> usize {
        if self.glyphs.is_empty() {
            return 0;
        }
        let mut best_idx = 0usize;
        let mut best_dist = f64::INFINITY;
        for (i, g) in self.glyphs.iter().enumerate() {
            // Two candidate positions: the cursor BEFORE this glyph (idx i)
            // and the cursor AFTER this glyph (idx i+1).
            let half = g.width / 2.0;
            let bx = g.cx - g.angle.cos() * half;
            let by = g.cy - g.angle.sin() * half;
            let ax = g.cx + g.angle.cos() * half;
            let ay = g.cy + g.angle.sin() * half;
            let db = ((x - bx).powi(2) + (y - by).powi(2)).sqrt();
            let da = ((x - ax).powi(2) + (y - ay).powi(2)).sqrt();
            if db < best_dist {
                best_dist = db;
                best_idx = i;
            }
            if da < best_dist {
                best_dist = da;
                best_idx = i + 1;
            }
        }
        best_idx
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn straight() -> Vec<PathCommand> {
        vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 100.0, y: 0.0 },
        ]
    }

    fn fixed(w: f64) -> Box<dyn Fn(&str) -> f64> {
        Box::new(move |s: &str| s.chars().count() as f64 * w)
    }

    #[test]
    fn empty_content_is_empty_layout() {
        let m = fixed(10.0);
        let l = layout_path_text(&straight(), "", 0.0, 16.0, m.as_ref());
        assert_eq!(l.char_count, 0);
        assert!(l.glyphs.is_empty());
    }

    #[test]
    fn glyphs_advance_along_straight_path() {
        let m = fixed(10.0);
        let l = layout_path_text(&straight(), "abc", 0.0, 16.0, m.as_ref());
        assert_eq!(l.glyphs.len(), 3);
        // Centers at 5, 15, 25.
        assert!((l.glyphs[0].cx - 5.0).abs() < 1e-6);
        assert!((l.glyphs[1].cx - 15.0).abs() < 1e-6);
        assert!((l.glyphs[2].cx - 25.0).abs() < 1e-6);
        // All on y=0 with angle 0.
        for g in &l.glyphs {
            assert!(g.cy.abs() < 1e-6);
            assert!(g.angle.abs() < 1e-6);
        }
    }

    #[test]
    fn cursor_pos_at_start_is_path_origin() {
        let m = fixed(10.0);
        let l = layout_path_text(&straight(), "abc", 0.0, 16.0, m.as_ref());
        let (x, y, _) = l.cursor_pos(0).unwrap();
        assert!(x.abs() < 1e-6);
        assert!(y.abs() < 1e-6);
    }

    #[test]
    fn cursor_pos_at_end_is_after_last_glyph() {
        let m = fixed(10.0);
        let l = layout_path_text(&straight(), "abc", 0.0, 16.0, m.as_ref());
        let (x, _, _) = l.cursor_pos(3).unwrap();
        assert!((x - 30.0).abs() < 1e-6);
    }

    #[test]
    fn hit_test_picks_nearest_cursor_index() {
        let m = fixed(10.0);
        let l = layout_path_text(&straight(), "abc", 0.0, 16.0, m.as_ref());
        // Click at x=12 → between 'a' and 'b' → cursor 1.
        assert_eq!(l.hit_test(12.0, 0.0), 1);
        // Click well past end.
        assert_eq!(l.hit_test(1000.0, 0.0), 3);
        // Click at far left.
        assert_eq!(l.hit_test(-100.0, 0.0), 0);
    }

    #[test]
    fn start_offset_shifts_glyphs_along_path() {
        let m = fixed(10.0);
        let l = layout_path_text(&straight(), "abc", 0.5, 16.0, m.as_ref());
        // 50% of 100px = 50, then centers at 55, 65, 75.
        assert!((l.glyphs[0].cx - 55.0).abs() < 1e-6);
        assert!((l.glyphs[1].cx - 65.0).abs() < 1e-6);
        assert!((l.glyphs[2].cx - 75.0).abs() < 1e-6);
    }

    #[test]
    fn total_length_matches_straight_path() {
        let m = fixed(10.0);
        let l = layout_path_text(&straight(), "ab", 0.0, 16.0, m.as_ref());
        assert!((l.total_length - 100.0).abs() < 1e-6);
    }

    #[test]
    fn cursor_pos_for_index_in_middle() {
        let m = fixed(10.0);
        let l = layout_path_text(&straight(), "abc", 0.0, 16.0, m.as_ref());
        let (x, _, _) = l.cursor_pos(1).unwrap();
        // Between 'a' and 'b' → arc-length 10.
        assert!((x - 10.0).abs() < 1e-6);
    }

    #[test]
    fn empty_path_has_zero_total_length() {
        let m = fixed(10.0);
        let l = layout_path_text(&[], "abc", 0.0, 16.0, m.as_ref());
        assert_eq!(l.total_length, 0.0);
    }

    #[test]
    fn glyphs_overflow_when_path_too_short() {
        let m = fixed(10.0);
        // 100px path, 12 chars at 10px each = 120 → some overflow.
        let l = layout_path_text(&straight(), "abcdefghijkl", 0.0, 16.0, m.as_ref());
        assert!(l.glyphs.iter().any(|g| g.overflow));
    }
}
