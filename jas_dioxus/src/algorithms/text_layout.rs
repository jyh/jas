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
    /// Index range into `TextLayout::glyphs` for this line. Finalized
    /// after layout so `cursor_xy`/`hit_test`/etc. can slice in O(line)
    /// instead of walking the whole glyph vector.
    pub glyph_start: usize,
    pub glyph_end: usize,
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

/// Horizontal alignment within a paragraph's effective box (the
/// box width minus left/right indents). Phase 5 supports the three
/// non-justify alignments; the four `JUSTIFY_*` variants land with
/// the composer in Phase 8 — they fall back to `Left` for now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextAlign {
    Left,
    Center,
    Right,
}

/// Per-paragraph layout constraints derived from the wrapper tspan
/// attributes (or panel defaults when there is no wrapper). All
/// indent / space values are in pixels (the caller converts pt → px).
#[derive(Debug, Clone, PartialEq)]
pub struct ParagraphSegment {
    /// Half-open char range `[start, end)` covered by this paragraph
    /// in the surrounding `content` string.
    pub char_start: usize,
    pub char_end: usize,
    /// `jas:left-indent` — narrows the available wrap width on the
    /// left side and pushes every line's start x by this much.
    pub left_indent: f64,
    /// `jas:right-indent` — narrows the available wrap width on the
    /// right side (no x shift; lines just wrap earlier).
    pub right_indent: f64,
    /// `text-indent` — additional x offset on the *first* line only.
    /// Signed; negative produces a hanging indent. Phase 5 supports
    /// non-negative values; negative falls back to 0. Ignored when
    /// `list_style` is `Some(_)` per PARAGRAPH.md §Marker rendering.
    pub first_line_indent: f64,
    /// `jas:space-before` — extra vertical gap above this paragraph.
    /// Always 0 for the first paragraph in the element.
    pub space_before: f64,
    /// `jas:space-after` — extra vertical gap below this paragraph.
    pub space_after: f64,
    /// Alignment within the paragraph's effective box.
    pub text_align: TextAlign,
    /// `jas:list-style` — Phase 6. When `Some(_)`, this paragraph
    /// is a list item: the layout pushes every line's start x by an
    /// extra `marker_gap` (so the marker has room before the text)
    /// and ignores `first_line_indent`. The marker glyph itself is
    /// drawn at `x = left_indent` by the renderer (not by this
    /// pure-layout function).
    pub list_style: Option<String>,
    /// Gap between marker and text. Phase 6 uses a fixed 12pt per
    /// PARAGRAPH.md §Marker rendering. Stored on the segment so
    /// future variants (e.g. wider markers like "iii.") can override.
    pub marker_gap: f64,
}

impl Default for ParagraphSegment {
    fn default() -> Self {
        Self {
            char_start: 0, char_end: 0,
            left_indent: 0.0, right_indent: 0.0, first_line_indent: 0.0,
            space_before: 0.0, space_after: 0.0,
            text_align: TextAlign::Left,
            list_style: None, marker_gap: 0.0,
        }
    }
}

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

    // `glyph_start`/`glyph_end` are filled in below as a single pass
    // after layout — easier than threading the running glyph count
    // through every push_line call.
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
            glyph_start: 0,
            glyph_end: 0,
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

    // Fill glyph_start/glyph_end for each line by scanning the glyph
    // vector once. Glyphs are emitted in line order so a single sweep
    // suffices.
    let mut gi = 0usize;
    for (li, line) in lines.iter_mut().enumerate() {
        line.glyph_start = gi;
        while gi < glyphs.len() && glyphs[gi].line == li {
            gi += 1;
        }
        line.glyph_end = gi;
    }

    TextLayout {
        glyphs,
        lines,
        font_size,
        char_count: n,
    }
}

/// Paragraph-aware layout. For each paragraph segment, lays out the
/// covered slice with the segment's effective wrap width
/// (`max_width - left_indent - right_indent`), inserts
/// `space_before` / `space_after` vertical gaps between paragraphs
/// (the very first paragraph's `space_before` is always skipped per
/// PARAGRAPH.md §SVG attribute mapping), shifts the first line by
/// `first_line_indent`, and applies the segment's horizontal
/// alignment.
///
/// `paragraphs` must be ordered by `char_start`; gaps between
/// segments and content past the last segment fall back to a default
/// paragraph (left-aligned, no indents, no extra spacing). When
/// `paragraphs` is empty the entire content is treated as one
/// default paragraph — equivalent to calling [`layout`].
///
/// Phase 5: alignment supports `Left` / `Center` / `Right`. The
/// four `JUSTIFY_*` modes fall back to `Left` until the composer
/// lands.
pub fn layout_with_paragraphs(
    content: &str,
    max_width: f64,
    font_size: f64,
    paragraphs: &[ParagraphSegment],
    measure: &Measurer<'_>,
) -> TextLayout {
    let chars: Vec<char> = content.chars().collect();
    let n = chars.len();
    let line_height = font_size;
    let ascent = font_size * 0.8;

    // Build the effective segment list: gap-fill with default
    // segments so every char is covered exactly once.
    let mut segs: Vec<ParagraphSegment> = Vec::new();
    let mut cursor = 0usize;
    for p in paragraphs {
        let start = p.char_start.max(cursor).min(n);
        let end = p.char_end.max(start).min(n);
        if start > cursor {
            segs.push(ParagraphSegment {
                char_start: cursor, char_end: start,
                ..ParagraphSegment::default()
            });
        }
        if end > start {
            let mut seg = p.clone();
            seg.char_start = start;
            seg.char_end = end;
            segs.push(seg);
        }
        cursor = end;
    }
    if cursor < n {
        segs.push(ParagraphSegment {
            char_start: cursor, char_end: n,
            ..ParagraphSegment::default()
        });
    }
    if segs.is_empty() {
        segs.push(ParagraphSegment {
            char_start: 0, char_end: n,
            ..ParagraphSegment::default()
        });
    }

    let mut all_glyphs: Vec<Glyph> = Vec::new();
    let mut all_lines: Vec<LineInfo> = Vec::new();
    let mut y_offset: f64 = 0.0;

    for (pi, seg) in segs.iter().enumerate() {
        if pi > 0 {
            // space_before is omitted before the first paragraph in
            // the element per PARAGRAPH.md.
            y_offset += seg.space_before;
        }
        // Phase 6: an active list adds marker_gap to the effective
        // left indent (so the marker has room before the text) AND
        // suppresses first_line_indent — the marker already occupies
        // the first-line position so a separate first-line offset
        // would push the text away from the marker.
        let has_list = seg.list_style.is_some();
        let list_indent = if has_list { seg.marker_gap } else { 0.0 };
        let slice: String = chars[seg.char_start..seg.char_end].iter().collect();
        let effective_max_w = if max_width > 0.0 {
            (max_width - seg.left_indent - list_indent - seg.right_indent).max(0.0)
        } else {
            0.0
        };
        let para_layout = layout(&slice, effective_max_w, font_size, measure);
        // Indent shift: each line's start x is pushed right by
        // `left_indent` (+ list marker gap when active); the first
        // line gets the additional `first_line_indent` only when no
        // list is present.
        let first_line_extra = if has_list { 0.0 } else { seg.first_line_indent.max(0.0) };
        let lines_n = para_layout.lines.len();
        let first_line_no_in_combined = all_lines.len();
        for (li, line) in para_layout.lines.iter().enumerate() {
            let x_shift = seg.left_indent + list_indent
                + (if li == 0 { first_line_extra } else { 0.0 });
            // text-align horizontal shift within the effective box.
            // Center / right need the line's measured width vs the
            // available width on this line (smaller for first-line
            // when the indent eats into it).
            let line_avail = if effective_max_w > 0.0 {
                (effective_max_w
                    - if li == 0 { first_line_extra } else { 0.0 })
                    .max(0.0)
            } else {
                0.0
            };
            // Trim trailing-space contribution from the displayed
            // width: those glyphs visually disappear at end-of-line.
            let visible_w = trimmed_line_width(line, &para_layout.glyphs);
            let align_shift = match seg.text_align {
                TextAlign::Left => 0.0,
                TextAlign::Center => {
                    if line_avail > visible_w { (line_avail - visible_w) / 2.0 } else { 0.0 }
                }
                TextAlign::Right => {
                    if line_avail > visible_w { line_avail - visible_w } else { 0.0 }
                }
            };
            let total_x_shift = x_shift + align_shift;
            // Char index of this line, in original-content coordinates.
            let orig_start = seg.char_start + line.start;
            let orig_end = seg.char_start + line.end;
            let baseline = y_offset + line.baseline_y + ascent_padding(line, font_size, ascent);
            let top = y_offset + line.top;
            // Re-emit glyphs with the new (x, top, baseline) values.
            let glyph_start = all_glyphs.len();
            for g in &para_layout.glyphs[line.glyph_start..line.glyph_end] {
                all_glyphs.push(Glyph {
                    idx: seg.char_start + g.idx,
                    line: first_line_no_in_combined + li,
                    x: g.x + total_x_shift,
                    right: g.right + total_x_shift,
                    baseline_y: g.baseline_y + y_offset,
                    top: g.top + y_offset,
                    height: g.height,
                    is_trailing_space: g.is_trailing_space,
                });
            }
            let glyph_end = all_glyphs.len();
            all_lines.push(LineInfo {
                start: orig_start,
                end: orig_end,
                hard_break: line.hard_break,
                top,
                baseline_y: baseline,
                height: line.height,
                width: visible_w + total_x_shift,
                glyph_start,
                glyph_end,
            });
        }
        if lines_n > 0 {
            y_offset += lines_n as f64 * line_height;
        }
        y_offset += seg.space_after;
    }

    if all_lines.is_empty() {
        // Empty content — keep the single-empty-line invariant from
        // [`layout`] so cursor placement still has a line to land on.
        all_lines.push(LineInfo {
            start: 0, end: 0, hard_break: false,
            top: 0.0, baseline_y: ascent, height: line_height,
            width: 0.0, glyph_start: 0, glyph_end: 0,
        });
    }

    TextLayout {
        glyphs: all_glyphs,
        lines: all_lines,
        font_size,
        char_count: n,
    }
}

/// Visible width of a line: the maximum `right` of any non-trailing-
/// whitespace glyph, or 0 when the line has none.
fn trimmed_line_width(line: &LineInfo, glyphs: &[Glyph]) -> f64 {
    let mut w: f64 = 0.0;
    for g in &glyphs[line.glyph_start..line.glyph_end] {
        if !g.is_trailing_space && g.right > w {
            w = g.right;
        }
    }
    w
}

/// Helper: 0.0 for the typical case. Reserved for future leading
/// adjustments where a line's baseline differs from the default
/// `top + ascent` (e.g. mixed font sizes within a paragraph). For
/// now the value is unused since `layout()` already encodes the
/// default baseline in `LineInfo.baseline_y`.
fn ascent_padding(_line: &LineInfo, _font_size: f64, _ascent: f64) -> f64 {
    0.0
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
        let line_glyphs = &self.glyphs[line_info.glyph_start..line_info.glyph_end];
        if cursor >= line_info.end {
            // Place cursor after the last visible glyph on this line.
            let x = line_glyphs.last().map(|g| g.right).unwrap_or(0.0);
            return (x, baseline_y, height);
        }
        // Cursor sits before the glyph at index `cursor`.
        if let Some(g) = line_glyphs.iter().find(|g| g.idx == cursor) {
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
        let glyphs_on_line: Vec<&Glyph> = self.glyphs[line.glyph_start..line.glyph_end]
            .iter()
            .filter(|g| !g.is_trailing_space)
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
        let glyphs_on_line: Vec<&Glyph> = self.glyphs[line.glyph_start..line.glyph_end]
            .iter()
            .filter(|g| !g.is_trailing_space)
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

    // ── Phase 5: paragraph-aware layout ─────────────────────

    #[test]
    fn empty_paragraph_list_matches_plain_layout() {
        let m = fixed(10.0);
        let plain = layout("hello world", 100.0, 16.0, m.as_ref());
        let para = layout_with_paragraphs("hello world", 100.0, 16.0, &[], m.as_ref());
        assert_eq!(plain.lines.len(), para.lines.len());
        assert_eq!(plain.glyphs.len(), para.glyphs.len());
        for (a, b) in plain.glyphs.iter().zip(para.glyphs.iter()) {
            assert_eq!(a.x, b.x);
            assert_eq!(a.right, b.right);
            assert_eq!(a.line, b.line);
        }
    }

    #[test]
    fn left_indent_shifts_every_line() {
        let m = fixed(10.0);
        // "hello world" wraps at 60 → 2 lines. left_indent=20 →
        // every glyph's x is 20 higher AND the wrap happens earlier
        // (effective width = 60 - 20 = 40).
        let segs = vec![ParagraphSegment {
            char_start: 0, char_end: 11,
            left_indent: 20.0,
            ..Default::default()
        }];
        let l = layout_with_paragraphs("hello world", 60.0, 16.0, &segs, m.as_ref());
        // Effective width 40 only fits "hell" before wrapping.
        // Line 0 starts at x=20. First glyph 'h' should be at x=20.
        assert_eq!(l.glyphs[0].x, 20.0);
    }

    #[test]
    fn right_indent_narrows_wrap_width() {
        let m = fixed(10.0);
        // Plain "hello world" at width 110 fits on one line; with
        // right_indent=60, effective width = 50 → wrap.
        let segs = vec![ParagraphSegment {
            char_start: 0, char_end: 11,
            right_indent: 60.0,
            ..Default::default()
        }];
        let l = layout_with_paragraphs("hello world", 110.0, 16.0, &segs, m.as_ref());
        assert!(l.lines.len() >= 2);
    }

    #[test]
    fn first_line_indent_only_shifts_first_line() {
        let m = fixed(10.0);
        let segs = vec![ParagraphSegment {
            char_start: 0, char_end: 11,
            first_line_indent: 25.0,
            ..Default::default()
        }];
        let l = layout_with_paragraphs("hello world", 60.0, 16.0, &segs, m.as_ref());
        // Line 0 starts shifted by 25; line 1 starts at 0.
        let first_line_first_glyph = l.glyphs.iter()
            .find(|g| g.line == 0).unwrap();
        let second_line_first_glyph = l.glyphs.iter()
            .find(|g| g.line == 1).unwrap();
        assert_eq!(first_line_first_glyph.x, 25.0);
        assert_eq!(second_line_first_glyph.x, 0.0);
    }

    #[test]
    fn alignment_center_shifts_glyphs_to_center() {
        let m = fixed(10.0);
        // "hi" (20 wide) centered in 100-width box → x = (100-20)/2 = 40.
        let segs = vec![ParagraphSegment {
            char_start: 0, char_end: 2,
            text_align: TextAlign::Center,
            ..Default::default()
        }];
        let l = layout_with_paragraphs("hi", 100.0, 16.0, &segs, m.as_ref());
        assert_eq!(l.glyphs[0].x, 40.0);
    }

    #[test]
    fn alignment_right_shifts_to_right_edge() {
        let m = fixed(10.0);
        // "hi" right-aligned in 100-width box → x = 100 - 20 = 80.
        let segs = vec![ParagraphSegment {
            char_start: 0, char_end: 2,
            text_align: TextAlign::Right,
            ..Default::default()
        }];
        let l = layout_with_paragraphs("hi", 100.0, 16.0, &segs, m.as_ref());
        assert_eq!(l.glyphs[0].x, 80.0);
    }

    #[test]
    fn space_before_skipped_for_first_paragraph() {
        let m = fixed(10.0);
        let segs = vec![
            ParagraphSegment {
                char_start: 0, char_end: 2,
                space_before: 50.0,  // should NOT apply (first para)
                space_after: 0.0,
                ..Default::default()
            },
            ParagraphSegment {
                char_start: 2, char_end: 4,
                space_before: 30.0,  // should apply
                ..Default::default()
            },
        ];
        let l = layout_with_paragraphs("abcd", 100.0, 16.0, &segs, m.as_ref());
        assert_eq!(l.lines.len(), 2);
        // Line 0 top: 0 (no space_before for first para).
        assert_eq!(l.lines[0].top, 0.0);
        // Line 1 top: 16 (one line) + 30 (space_before) = 46.
        assert_eq!(l.lines[1].top, 46.0);
    }

    #[test]
    fn space_after_inserts_gap_before_next_paragraph() {
        let m = fixed(10.0);
        let segs = vec![
            ParagraphSegment {
                char_start: 0, char_end: 2,
                space_after: 20.0,
                ..Default::default()
            },
            ParagraphSegment {
                char_start: 2, char_end: 4,
                ..Default::default()
            },
        ];
        let l = layout_with_paragraphs("abcd", 100.0, 16.0, &segs, m.as_ref());
        // Line 0 (first para) takes y=[0, 16]; +20 space_after; line 1 top = 36.
        assert_eq!(l.lines[1].top, 36.0);
    }

    #[test]
    fn alignment_with_indent_uses_remaining_width_for_centering() {
        let m = fixed(10.0);
        // "hi" centered in box of effective width 80 (100 - 20 left).
        // Center offset within the effective box = (80 - 20) / 2 = 30.
        // Plus left_indent 20 → final x = 50.
        let segs = vec![ParagraphSegment {
            char_start: 0, char_end: 2,
            left_indent: 20.0,
            text_align: TextAlign::Center,
            ..Default::default()
        }];
        let l = layout_with_paragraphs("hi", 100.0, 16.0, &segs, m.as_ref());
        assert_eq!(l.glyphs[0].x, 50.0);
    }

    // ── Phase 6: list marker indent semantics ─────────────────

    #[test]
    fn list_style_pushes_text_by_marker_gap() {
        let m = fixed(10.0);
        let segs = vec![ParagraphSegment {
            char_start: 0, char_end: 2,
            list_style: Some("bullet-disc".into()),
            marker_gap: 12.0,
            ..Default::default()
        }];
        let l = layout_with_paragraphs("hi", 100.0, 16.0, &segs, m.as_ref());
        // No left_indent set, but marker_gap=12 → text starts at x=12.
        assert_eq!(l.glyphs[0].x, 12.0);
    }

    #[test]
    fn list_style_combines_left_indent_and_marker_gap() {
        let m = fixed(10.0);
        let segs = vec![ParagraphSegment {
            char_start: 0, char_end: 2,
            left_indent: 20.0,
            list_style: Some("num-decimal".into()),
            marker_gap: 12.0,
            ..Default::default()
        }];
        let l = layout_with_paragraphs("hi", 100.0, 16.0, &segs, m.as_ref());
        // Text x = left_indent + marker_gap = 32.
        assert_eq!(l.glyphs[0].x, 32.0);
    }

    #[test]
    fn list_style_ignores_first_line_indent() {
        let m = fixed(10.0);
        // first_line_indent would normally shift line 0 by 25, but
        // PARAGRAPH.md §Marker rendering says the panel control is
        // ignored when a list is active.
        let segs = vec![ParagraphSegment {
            char_start: 0, char_end: 2,
            first_line_indent: 25.0,
            list_style: Some("bullet-disc".into()),
            marker_gap: 12.0,
            ..Default::default()
        }];
        let l = layout_with_paragraphs("hi", 100.0, 16.0, &segs, m.as_ref());
        assert_eq!(l.glyphs[0].x, 12.0);  // not 12 + 25
    }

    #[test]
    fn list_style_continuation_lines_align_with_first_line_text() {
        let m = fixed(10.0);
        // "abcdef ghijk" with effective width 50 (100 - 12 marker_gap
        // - other) wraps; both lines should start at x = 12 (marker_gap)
        // — the standard hanging-indent effect for lists.
        let segs = vec![ParagraphSegment {
            char_start: 0, char_end: 12,
            list_style: Some("bullet-disc".into()),
            marker_gap: 12.0,
            ..Default::default()
        }];
        let l = layout_with_paragraphs("abcdef ghijk", 60.0, 16.0,
                                        &segs, m.as_ref());
        assert!(l.lines.len() >= 2);
        let line0_first = l.glyphs.iter().find(|g| g.line == 0).unwrap();
        let line1_first = l.glyphs.iter().find(|g| g.line == 1).unwrap();
        assert_eq!(line0_first.x, 12.0);
        assert_eq!(line1_first.x, 12.0);
    }
}
