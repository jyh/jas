//! The runs a laid-out multi-tspan text draws, line by line: the shared
//! plan for non-flat text (STATUS-flask § 449 / § 452).
//!
//! A renderer lays the element's whole content out once, with each
//! character measured in its own tspan's font
//! ([`text_layout::layout_with_paragraphs_widths`]), and then draws each
//! line as RUNS: the line's characters cut at every tspan boundary, each run
//! at the x the layout gave its first character. That is how Swift's canvas
//! weaves per-tspan attributes into each line (`CanvasSubwindow.swift`, the
//! per-line attributed string), and it is what lets a styled run WRAP, which
//! drawing the tspans one after another on a single baseline cannot.
//!
//! The plan is font-agnostic on purpose: a run names the tspan it came from
//! (an index into the element's `tspans`), and the renderer resolves that
//! tspan's font, weight, style and decoration itself, with its own fallback
//! to the element's.

use crate::algorithms::text_layout::TextLayout;

/// One run: `text` drawn at `x` (relative to the element's origin, as the
/// layout's glyph x is) in tspan `tspan`'s attributes.
#[derive(Debug, Clone, PartialEq)]
pub struct TextRun {
    pub text: String,
    pub x: f64,
    pub tspan: usize,
}

/// One laid-out line: its baseline (relative to the element's origin) and
/// its runs, left to right. A line with no drawable characters (an empty
/// line, or one holding only its hard break) has no runs.
#[derive(Debug, Clone, PartialEq)]
pub struct RunLine {
    pub baseline_y: f64,
    pub runs: Vec<TextRun>,
}

/// Each tspan's `[start, end)` character range in the element's content, in
/// order: the cumulative character counts of `contents`.
pub fn tspan_ranges<'a>(contents: impl IntoIterator<Item = &'a str>) -> Vec<(usize, usize)> {
    let mut at = 0usize;
    contents
        .into_iter()
        .map(|c| {
            let n = c.chars().count();
            let r = (at, at + n);
            at += n;
            r
        })
        .collect()
}

/// The runs of every line of `layout`, over `content` (the text it laid out)
/// and the tspans' character `ranges`.
pub fn line_runs(layout: &TextLayout, content: &str, ranges: &[(usize, usize)]) -> Vec<RunLine> {
    let chars: Vec<char> = content.chars().collect();
    layout.lines.iter().map(|line| {
        let glyphs = &layout.glyphs[line.glyph_start.min(layout.glyphs.len())..line.glyph_end.min(layout.glyphs.len())];
        let mut runs = Vec::new();
        for (ti, &(a, b)) in ranges.iter().enumerate() {
            let (s, e) = (a.max(line.start), b.min(line.end).min(chars.len()));
            if s >= e {
                continue;
            }
            let text: String = chars[s..e].iter().filter(|c| **c != '\n').collect();
            if text.is_empty() {
                continue;
            }
            // The run starts at its first character's glyph; a character the
            // layout placed no glyph for (it should not happen) drops the run
            // rather than guess an x.
            if let Some(g) = glyphs.iter().find(|g| g.idx == s) {
                runs.push(TextRun { text, x: g.x, tspan: ti });
            }
        }
        RunLine { baseline_y: line.baseline_y, runs }
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::algorithms::text_layout::{layout_with_paragraphs_widths, ParagraphSegment};

    fn fixed(w: f64) -> Box<dyn Fn(&str) -> f64> {
        Box::new(move |s: &str| s.chars().count() as f64 * w)
    }

    /// Three tspans, "aa " + "BBBB" (wide) + " cc", wrapping at 120: line 1
    /// is "aa BBBB " in two runs, the bold run at x 30; line 2 is "cc", the
    /// third tspan's tail, at x 0 (its leading space stayed on line 1 as
    /// trailing whitespace). Every x is the layout's own glyph x.
    #[test]
    fn a_wrapped_styled_run_draws_as_runs_cut_at_tspan_boundaries() {
        let m = fixed(10.0);
        let parts = ["aa ", "BBBB", " cc"];
        let content: String = parts.concat();
        let ranges = tspan_ranges(parts);
        assert_eq!(ranges, vec![(0, 3), (3, 7), (7, 10)]);
        let mut widths = vec![10.0; 10];
        for w in &mut widths[3..7] { *w = 20.0; }
        let segs = vec![ParagraphSegment { char_start: 0, char_end: 10, ..ParagraphSegment::default() }];
        let lay = layout_with_paragraphs_widths(&content, 120.0, 16.0, &segs, m.as_ref(), Some(&widths));
        let runs = line_runs(&lay, &content, &ranges);
        let shape: Vec<Vec<(&str, f64, usize)>> = runs.iter()
            .map(|l| l.runs.iter().map(|r| (r.text.as_str(), r.x, r.tspan)).collect())
            .collect();
        assert_eq!(shape, vec![
            vec![("aa ", 0.0, 0), ("BBBB", 30.0, 1), (" ", 110.0, 2)],
            vec![("cc", 0.0, 2)],
        ]);
        assert_eq!(runs[0].baseline_y, lay.lines[0].baseline_y);
        assert_eq!(runs[1].baseline_y, lay.lines[1].baseline_y);
    }

    /// A hard break ends a line without a run of its own, an empty tspan
    /// contributes no run, and a line that is only a hard break has none.
    #[test]
    fn hard_breaks_and_empty_tspans_draw_nothing() {
        let m = fixed(10.0);
        let parts = ["", "ab\n", "", "\ncd"];
        let content: String = parts.concat();
        let ranges = tspan_ranges(parts);
        let n = content.chars().count();
        let segs = vec![ParagraphSegment { char_start: 0, char_end: n, ..ParagraphSegment::default() }];
        let lay = layout_with_paragraphs_widths(&content, 0.0, 16.0, &segs, m.as_ref(), None);
        let runs = line_runs(&lay, &content, &ranges);
        let shape: Vec<Vec<(&str, usize)>> = runs.iter()
            .map(|l| l.runs.iter().map(|r| (r.text.as_str(), r.tspan)).collect())
            .collect();
        assert_eq!(shape, vec![vec![("ab", 1)], vec![], vec![("cd", 3)]]);
    }
}
