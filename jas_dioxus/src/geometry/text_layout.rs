//! Word-wrapped text layout with per-character hit testing.
//!
//! This module is intentionally pure: it takes a `Measurer` closure that
//! returns the pixel width of an arbitrary string and produces a [`TextLayout`]
//! containing one [`Glyph`] entry per character. The closure can be backed
//! by a real `CanvasRenderingContext2d::measure_text` call in the browser
//! and by a deterministic stub in unit tests.
//!
//! Layout rules
//! ------------
//! - For point text (`max_width <= 0.0`) wrapping is disabled; only hard
//!   `\n` newlines split lines.
//! - For area text wrapping breaks on whitespace runs. A word longer than
//!   `max_width` is broken at character boundaries (each character takes
//!   its own slot, falling onto a new line as needed).
//! - Lines that overflow `max_height` are still emitted; the caller renders
//!   them past the bottom edge.
//! - Character indices are *char* indices (not byte indices) so they map
//!   one-to-one to the cursor positions exposed to keyboard editing.

/// Pixel position and size of a single character within a [`TextLayout`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Glyph {
    /// Char index within the original content (0-based).
    pub idx: usize,
    /// Index of the line this glyph belongs to.
    pub line: usize,
    /// Pixel x of the glyph's left edge, relative to layout origin (0,0).
    pub x: f64,
    /// Pixel x of the glyph's right edge.
    pub right: f64,
    /// Baseline y for this glyph.
    pub baseline_y: f64,
    /// Top y of the glyph's bounding box.
    pub top: f64,
    /// Height of the glyph's bounding box (== line height).
    pub height: f64,
    /// True if this glyph is the trailing whitespace of a soft-wrapped run
    /// (it should not consume horizontal space at end-of-line, and clicking
    /// past it places the cursor at the next line start).
    pub is_trailing_space: bool,
}

/// Per-line summary used during cursor placement.
#[derive(Debug, Clone, PartialEq)]
pub struct LineInfo {
    /// Char index of the first character on this line (== char count of all
    /// preceding lines, including the implicit caret-after-last-char slot).
    pub start: usize,
    /// Char index one past the last character on this line. This is the
    /// position the cursor lands at when "End" is pressed.
    pub end: usize,
    /// True if this line ends with a hard newline character (`\n`). The
    /// trailing newline itself is not included in `end..`.
    pub hard_break: bool,
    /// Top y of the line bounding box.
    pub top: f64,
    /// Baseline y of the line.
    pub baseline_y: f64,
    /// Total height of the line (line height).
    pub height: f64,
    /// Maximum right edge of the visible glyphs on this line.
    pub width: f64,
}

/// Result of laying out a string into wrapped lines.
#[derive(Debug, Clone, PartialEq)]
pub struct TextLayout {
    pub glyphs: Vec<Glyph>,
    pub lines: Vec<LineInfo>,
    pub font_size: f64,
    /// Total number of characters in the source content. The cursor can
    /// occupy positions `0..=char_count`.
    pub char_count: usize,
}

/// A function that returns the pixel width of `s` for a fixed font.
pub type Measurer<'a> = dyn Fn(&str) -> f64 + 'a;

/// Compute a wrapped layout for `content`.
///
/// `max_width <= 0.0` disables wrapping (point text). `font_size` is used
/// as the line height; the caller may pre-multiply by a leading factor.
pub fn layout(
    content: &str,
    max_width: f64,
    font_size: f64,
    measure: &Measurer<'_>,
) -> TextLayout {
    let line_height = font_size;
    let ascent = font_size * 0.8;
    let mut glyphs: Vec<Glyph> = Vec::new();
    let mut lines: Vec<LineInfo> = Vec::new();

    let chars: Vec<char> = content.chars().collect();
    let n = chars.len();

    let mut idx = 0usize;
    let mut line_no = 0usize;
    let mut line_start_char = 0usize;
    let mut x = 0.0f64;

    let push_line = |lines: &mut Vec<LineInfo>,
                     line_no: usize,
                     start: usize,
                     end: usize,
                     hard_break: bool,
                     line_width: f64| {
        let top = line_no as f64 * line_height;
        lines.push(LineInfo {
            start,
            end,
            hard_break,
            top,
            baseline_y: top + ascent,
            height: line_height,
            width: line_width,
        });
    };

    while idx < n {
        // Hard newline: emit current line and start a new one.
        if chars[idx] == '\n' {
            push_line(&mut lines, line_no, line_start_char, idx, true, x);
            line_no += 1;
            line_start_char = idx + 1;
            x = 0.0;
            idx += 1;
            continue;
        }

        // Find the next "token" — a run of whitespace or a run of non-whitespace.
        let is_ws = chars[idx].is_whitespace();
        let mut end = idx + 1;
        while end < n && chars[end] != '\n' && chars[end].is_whitespace() == is_ws {
            end += 1;
        }
        let token: String = chars[idx..end].iter().collect();
        let token_w = measure(&token);

        if is_ws {
            // Whitespace token: place each char one at a time so we can mark
            // the trailing ones if we wrap inside it.
            for (k, ch) in token.chars().enumerate() {
                let cw = measure(&ch.to_string());
                let glyph_idx = idx + k;
                let g = Glyph {
                    idx: glyph_idx,
                    line: line_no,
                    x,
                    right: x + cw,
                    baseline_y: line_no as f64 * line_height + ascent,
                    top: line_no as f64 * line_height,
                    height: line_height,
                    is_trailing_space: false,
                };
                glyphs.push(g);
                x += cw;
            }
            idx = end;
            continue;
        }

        // Non-whitespace token: try to fit on current line.
        if max_width > 0.0 && x + token_w > max_width && x > 0.0 {
            // Wrap before this token. Mark any trailing whitespace at the end
            // of the previous line as "soft-wrap whitespace" so the cursor
            // skips past them naturally.
            for g in glyphs.iter_mut().rev() {
                if g.line != line_no { break; }
                if !chars[g.idx].is_whitespace() { break; }
                g.is_trailing_space = true;
            }
            push_line(&mut lines, line_no, line_start_char, idx, false, x);
            line_no += 1;
            line_start_char = idx;
            x = 0.0;
        }

        if max_width > 0.0 && token_w > max_width && x == 0.0 {
            // Word longer than the box: break at character boundaries.
            for (k, ch) in token.chars().enumerate() {
                let cw = measure(&ch.to_string());
                if x + cw > max_width && x > 0.0 {
                    push_line(&mut lines, line_no, line_start_char, idx + k, false, x);
                    line_no += 1;
                    line_start_char = idx + k;
                    x = 0.0;
                }
                let g = Glyph {
                    idx: idx + k,
                    line: line_no,
                    x,
                    right: x + cw,
                    baseline_y: line_no as f64 * line_height + ascent,
                    top: line_no as f64 * line_height,
                    height: line_height,
                    is_trailing_space: false,
                };
                glyphs.push(g);
                x += cw;
            }
        } else {
            // Fits on current line.
            let mut cur_x = x;
            for (k, ch) in token.chars().enumerate() {
                let cw = measure(&ch.to_string());
                let g = Glyph {
                    idx: idx + k,
                    line: line_no,
                    x: cur_x,
                    right: cur_x + cw,
                    baseline_y: line_no as f64 * line_height + ascent,
                    top: line_no as f64 * line_height,
                    height: line_height,
                    is_trailing_space: false,
                };
                glyphs.push(g);
                cur_x += cw;
            }
            x = cur_x;
        }

        idx = end;
    }

    // Final line.
    push_line(&mut lines, line_no, line_start_char, n, false, x);
    if lines.is_empty() {
        push_line(&mut lines, 0, 0, 0, false, 0.0);
    }

    TextLayout {
        glyphs,
        lines,
        font_size,
        char_count: n,
    }
}

impl TextLayout {
    /// Cursor position (x, baseline_y, height) for a given char index.
    /// `cursor` may equal `char_count`.
    pub fn cursor_xy(&self, cursor: usize) -> (f64, f64, f64) {
        let cursor = cursor.min(self.char_count);
        // Find the line containing this cursor position.
        let line = self.line_for_cursor(cursor);
        let line_info = &self.lines[line];
        let height = line_info.height;
        let baseline_y = line_info.baseline_y;

        if cursor == line_info.start {
            return (0.0, baseline_y, height);
        }
        if cursor >= line_info.end {
            // Place cursor after the last visible glyph on this line.
            let last = self
                .glyphs
                .iter()
                .filter(|g| g.line == line)
                .last();
            let x = last.map(|g| g.right).unwrap_or(0.0);
            return (x, baseline_y, height);
        }
        // Cursor sits before the glyph at index `cursor`.
        if let Some(g) = self.glyphs.iter().find(|g| g.idx == cursor) {
            return (g.x, baseline_y, height);
        }
        (0.0, baseline_y, height)
    }

    /// Find which line a given cursor position falls on. The cursor at
    /// `line_info.end` belongs to the same line *unless* the line ends with
    /// a hard break, in which case the cursor at `end` is the same physical
    /// position as `start` of the next line — we keep it on the current line.
    pub fn line_for_cursor(&self, cursor: usize) -> usize {
        for (i, l) in self.lines.iter().enumerate() {
            if cursor < l.end {
                return i;
            }
            if cursor == l.end {
                // The cursor lives on this line unless this is a soft wrap
                // (then the cursor at this position appears at the next line
                // start). For hard breaks the cursor stays on this line.
                if l.hard_break {
                    return i;
                }
                // For the last line, stay here too.
                if i == self.lines.len() - 1 {
                    return i;
                }
                return i + 1;
            }
        }
        self.lines.len() - 1
    }

    /// Map a (x, y) point in layout-local coordinates to a cursor index.
    pub fn hit_test(&self, x: f64, y: f64) -> usize {
        if self.lines.is_empty() {
            return 0;
        }
        // Find line by y. Anything above is line 0; below is last line.
        let mut line_no = self.lines.len() - 1;
        for (i, l) in self.lines.iter().enumerate() {
            if y < l.top + l.height {
                line_no = i;
                break;
            }
        }
        let line = &self.lines[line_no];
        let glyphs_on_line: Vec<&Glyph> = self
            .glyphs
            .iter()
            .filter(|g| g.line == line_no && !g.is_trailing_space)
            .collect();
        if glyphs_on_line.is_empty() {
            return line.start;
        }
        if x <= glyphs_on_line[0].x {
            return line.start;
        }
        for g in &glyphs_on_line {
            let mid = (g.x + g.right) / 2.0;
            if x < mid {
                return g.idx;
            }
        }
        // Past the end of the line. If the line ends with a hard break,
        // the cursor sits before the newline; otherwise it sits at the
        // start of the next line (which has the same numeric index).
        // For soft-wrapped lines we land *before* any trailing whitespace
        // so the caret visually sits after the last visible glyph.
        let last_visible = glyphs_on_line.last().map(|g| g.idx + 1).unwrap_or(line.start);
        if line.hard_break {
            line.end
        } else {
            last_visible.max(line.start).min(line.end)
        }
    }

    /// Move the cursor up one line, keeping the visual x as close as possible.
    pub fn cursor_up(&self, cursor: usize) -> usize {
        let line_no = self.line_for_cursor(cursor);
        if line_no == 0 {
            return 0;
        }
        let (x, _, _) = self.cursor_xy(cursor);
        let target_line = line_no - 1;
        self.cursor_at_line_x(target_line, x)
    }

    /// Move the cursor down one line.
    pub fn cursor_down(&self, cursor: usize) -> usize {
        let line_no = self.line_for_cursor(cursor);
        if line_no + 1 >= self.lines.len() {
            return self.char_count;
        }
        let (x, _, _) = self.cursor_xy(cursor);
        let target_line = line_no + 1;
        self.cursor_at_line_x(target_line, x)
    }

    fn cursor_at_line_x(&self, line_no: usize, target_x: f64) -> usize {
        let line = &self.lines[line_no];
        let glyphs_on_line: Vec<&Glyph> = self
            .glyphs
            .iter()
            .filter(|g| g.line == line_no && !g.is_trailing_space)
            .collect();
        if glyphs_on_line.is_empty() {
            return line.start;
        }
        if target_x <= glyphs_on_line[0].x {
            return line.start;
        }
        for g in &glyphs_on_line {
            let mid = (g.x + g.right) / 2.0;
            if target_x < mid {
                return g.idx;
            }
        }
        line.end
    }
}

/// Convenience: split a `(start, end)` selection so `start <= end`.
pub fn ordered_range(a: usize, b: usize) -> (usize, usize) {
    if a <= b { (a, b) } else { (b, a) }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Deterministic measurer: every char is `width_per_char` wide.
    fn fixed(w: f64) -> Box<dyn Fn(&str) -> f64> {
        Box::new(move |s: &str| s.chars().count() as f64 * w)
    }

    #[test]
    fn empty_string_has_one_line() {
        let m = fixed(10.0);
        let l = layout("", 100.0, 16.0, m.as_ref());
        assert_eq!(l.lines.len(), 1);
        assert_eq!(l.char_count, 0);
        assert_eq!(l.cursor_xy(0).0, 0.0);
    }

    #[test]
    fn point_text_no_wrapping() {
        let m = fixed(10.0);
        let l = layout("hello world", 0.0, 16.0, m.as_ref());
        assert_eq!(l.lines.len(), 1);
        assert_eq!(l.char_count, 11);
    }

    #[test]
    fn hard_newline_splits_lines() {
        let m = fixed(10.0);
        let l = layout("ab\ncd", 0.0, 16.0, m.as_ref());
        assert_eq!(l.lines.len(), 2);
        assert_eq!(l.lines[0].end, 2);
        assert!(l.lines[0].hard_break);
        assert_eq!(l.lines[1].start, 3);
    }

    #[test]
    fn word_wrap_breaks_on_whitespace() {
        let m = fixed(10.0);
        // "hello world" with width 60 → "hello " on line 0, "world" on line 1.
        let l = layout("hello world", 60.0, 16.0, m.as_ref());
        assert_eq!(l.lines.len(), 2);
        assert_eq!(l.lines[0].start, 0);
        assert_eq!(l.lines[1].start, 6);
    }

    #[test]
    fn long_word_breaks_at_char() {
        let m = fixed(10.0);
        // "abcdefgh" with width 30 → 3 chars per line.
        let l = layout("abcdefgh", 30.0, 16.0, m.as_ref());
        assert!(l.lines.len() >= 3);
    }

    #[test]
    fn hit_test_first_char() {
        let m = fixed(10.0);
        let l = layout("hello", 0.0, 16.0, m.as_ref());
        assert_eq!(l.hit_test(0.0, 8.0), 0);
        // Click 7px in (just past midpoint of 'h') → cursor at 1.
        assert_eq!(l.hit_test(7.0, 8.0), 1);
    }

    #[test]
    fn hit_test_past_end() {
        let m = fixed(10.0);
        let l = layout("hello", 0.0, 16.0, m.as_ref());
        assert_eq!(l.hit_test(999.0, 8.0), 5);
    }

    #[test]
    fn hit_test_below_last_line_clamps() {
        let m = fixed(10.0);
        let l = layout("a\nb", 0.0, 16.0, m.as_ref());
        // Click well below: should land on the last line.
        assert_eq!(l.lines.len(), 2);
        let cursor = l.hit_test(0.0, 999.0);
        // Beginning of second line → char index 2 (after 'a' and '\n').
        assert_eq!(cursor, 2);
    }

    #[test]
    fn cursor_xy_advances_with_index() {
        let m = fixed(10.0);
        let l = layout("abc", 0.0, 16.0, m.as_ref());
        assert_eq!(l.cursor_xy(0).0, 0.0);
        assert_eq!(l.cursor_xy(1).0, 10.0);
        assert_eq!(l.cursor_xy(2).0, 20.0);
        assert_eq!(l.cursor_xy(3).0, 30.0);
    }

    #[test]
    fn cursor_up_down_preserves_x() {
        let m = fixed(10.0);
        // Two lines via hard break.
        let l = layout("hello\nworld", 0.0, 16.0, m.as_ref());
        // Cursor at start of "world" (index 6), move up.
        let up = l.cursor_up(6);
        // Should land at start of "hello" (line 0, x=0) → index 0.
        assert_eq!(up, 0);
        // Cursor at index 8 ("wo|rld") → x ≈ 20 → up should land at 'l' (idx 2).
        let up_mid = l.cursor_up(8);
        assert_eq!(up_mid, 2);
    }

    #[test]
    fn cursor_down_at_last_line_goes_to_end() {
        let m = fixed(10.0);
        let l = layout("hi", 0.0, 16.0, m.as_ref());
        assert_eq!(l.cursor_down(1), l.char_count);
    }

    #[test]
    fn ordered_range_swaps_when_needed() {
        assert_eq!(ordered_range(3, 1), (1, 3));
        assert_eq!(ordered_range(1, 3), (1, 3));
        assert_eq!(ordered_range(2, 2), (2, 2));
    }

    #[test]
    fn line_for_cursor_after_hard_break_stays_on_prev_line() {
        let m = fixed(10.0);
        let l = layout("ab\ncd", 0.0, 16.0, m.as_ref());
        // cursor at 2 == line 0 end (hard break), should be on line 0.
        assert_eq!(l.line_for_cursor(2), 0);
        // cursor at 3 == line 1 start.
        assert_eq!(l.line_for_cursor(3), 1);
    }

    #[test]
    fn long_word_breaks_at_max_width_chars() {
        let m = fixed(10.0);
        // "abcdef" with width 30 → 3-char lines: "abc", "def".
        let l = layout("abcdef", 30.0, 16.0, m.as_ref());
        assert_eq!(l.lines.len(), 2);
        assert_eq!(l.lines[0].start, 0);
        assert_eq!(l.lines[0].end, 3);
        assert_eq!(l.lines[1].start, 3);
        assert_eq!(l.lines[1].end, 6);
    }

    #[test]
    fn glyphs_match_char_count() {
        let m = fixed(10.0);
        let l = layout("hello world", 60.0, 16.0, m.as_ref());
        // Every char should have a glyph.
        assert_eq!(l.glyphs.len(), l.char_count);
    }

    #[test]
    fn cursor_down_between_wrapped_lines() {
        let m = fixed(10.0);
        // "abcd ef" wraps at 40 → "abcd " on line 0, "ef" on line 1.
        let l = layout("abcd ef", 40.0, 16.0, m.as_ref());
        assert_eq!(l.lines.len(), 2);
        // From idx 1 ('a|bcd'), x ≈ 10 → down should land at 'e|f' (idx 6).
        let down = l.cursor_down(1);
        assert_eq!(down, 6);
    }

    #[test]
    fn lines_past_max_height_still_emitted() {
        let m = fixed(10.0);
        // 5 hard-broken lines.
        let l = layout("a\nb\nc\nd\ne", 0.0, 16.0, m.as_ref());
        assert_eq!(l.lines.len(), 5);
        // No clipping based on height — all lines retained.
        let last = l.lines.last().unwrap();
        assert!(last.baseline_y > 0.0);
    }

    #[test]
    fn point_text_cursor_xy_at_end_is_full_width() {
        let m = fixed(10.0);
        let l = layout("hi", 0.0, 16.0, m.as_ref());
        let (x, _, _) = l.cursor_xy(2);
        assert_eq!(x, 20.0);
    }

    #[test]
    fn empty_layout_cursor_xy_is_origin() {
        let m = fixed(10.0);
        let l = layout("", 100.0, 16.0, m.as_ref());
        let (x, _, h) = l.cursor_xy(0);
        assert_eq!(x, 0.0);
        assert!(h > 0.0);
    }

    #[test]
    fn hit_test_on_first_line_with_multiple_lines() {
        let m = fixed(10.0);
        let l = layout("ab\ncd", 0.0, 16.0, m.as_ref());
        // Click on line 0 ("ab"), past the end → should stay on line 0.
        let cursor = l.hit_test(999.0, 5.0);
        // Hard break: cursor at end of line 0 stays on line 0 → idx 2.
        assert_eq!(cursor, 2);
    }

    #[test]
    fn soft_wrap_trailing_space_is_skipped_in_hit_test() {
        let m = fixed(10.0);
        // "ab cd" wrapping at 30 → "ab " on line 0, "cd" on line 1.
        let l = layout("ab cd", 30.0, 16.0, m.as_ref());
        assert_eq!(l.lines.len(), 2);
        // Click far right of line 0 → should land at end of "ab" (idx 2),
        // not after the trailing space.
        let cursor = l.hit_test(99.0, 8.0);
        assert_eq!(cursor, 2);
    }
}
