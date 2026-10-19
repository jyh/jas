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
    /// The content index of the run's first character.
    pub start: usize,
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
                runs.push(TextRun { text, x: g.x, tspan: ti, start: s });
            }
        }
        RunLine { baseline_y: line.baseline_y, runs }
    }).collect()
}

/// A face a run (or the element) is measured and drawn in. Each renderer
/// spells it as its own font string (the walk without the size, legacy's
/// canvas with `{size}px`).
#[derive(Debug, Clone, PartialEq)]
pub struct RunFace<'a> {
    pub family: &'a str,
    pub size: f64,
    pub weight: &'a str,
    pub style: &'a str,
}

/// The element's own face, its attributes as written: the face the layout's
/// glue, the synthetic hyphen and the list markers are measured in.
pub fn element_face(e: &crate::geometry::element::TextElem) -> RunFace<'_> {
    RunFace { family: &e.font_family, size: e.font_size, weight: &e.font_weight, style: &e.font_style }
}

/// A tspan's face: its own family, size, weight and style over the
/// element's, the element's weight read as bold or normal and its style as
/// italic (or oblique) or normal. The one rule every multi-tspan path uses.
pub fn tspan_face<'a>(
    e: &'a crate::geometry::element::TextElem,
    t: &'a crate::geometry::tspan::Tspan,
) -> RunFace<'a> {
    let weight = match t.font_weight.as_deref() {
        Some(w) => w,
        None => if e.font_weight == "bold" { "bold" } else { "normal" },
    };
    let style = match t.font_style.as_deref() {
        Some(s) => s,
        None => if e.font_style == "italic" || e.font_style == "oblique" { "italic" } else { "normal" },
    };
    RunFace {
        family: t.font_family.as_deref().unwrap_or(&e.font_family),
        size: t.font_size.unwrap_or(e.font_size),
        weight,
        style,
    }
}

/// A list marker placed relative to the element's origin, drawn in the
/// element's face.
#[derive(Debug, Clone, PartialEq)]
pub struct PlacedMarker {
    pub text: String,
    pub x: f64,
    pub baseline_y: f64,
}

/// The whole plan a renderer draws: the runs of every line, then the
/// markers. Every x and baseline is relative to the element's origin.
#[derive(Debug, Clone, PartialEq)]
pub struct RunsPlan {
    pub lines: Vec<RunLine>,
    pub markers: Vec<PlacedMarker>,
}

/// Whether a laid-out line's glue was stretched (or shrunk) away from the
/// natural width of its whitespace: a justified line. Then a run drawn as one
/// string would put its later words at the natural space.
fn stretched(glyphs: &[crate::algorithms::text_layout::Glyph], line: &crate::algorithms::text_layout::LineInfo, chars: &[char], widths: &[f64]) -> bool {
    glyphs.iter().any(|g| {
        g.idx < line.end
            && !g.is_trailing_space
            && chars.get(g.idx).is_some_and(|c| c.is_whitespace())
            && widths.get(g.idx).is_some_and(|w| ((g.right - g.x) - w).abs() > 1e-6)
    })
}

/// A stretched line's runs, re-cut so each WORD is its own run at the x the
/// layout gave its first character, as the flat path draws a justified line
/// word by word. The whitespace between words is not drawn (it is invisible,
/// and the plan's router keeps decorations away from it).
fn word_runs(runs: &[TextRun], glyphs: &[crate::algorithms::text_layout::Glyph]) -> Vec<TextRun> {
    let mut out = Vec::new();
    for r in runs {
        let mut word = String::new();
        let mut word_start = 0usize;
        for (k, c) in r.text.chars().enumerate() {
            let at = r.start + k;
            if c.is_whitespace() {
                if !word.is_empty() {
                    push_word(&mut out, std::mem::take(&mut word), word_start, r.tspan, glyphs);
                }
            } else {
                if word.is_empty() { word_start = at; }
                word.push(c);
            }
        }
        if !word.is_empty() {
            push_word(&mut out, word, word_start, r.tspan, glyphs);
        }
    }
    out
}

fn push_word(out: &mut Vec<TextRun>, text: String, start: usize, tspan: usize, glyphs: &[crate::algorithms::text_layout::Glyph]) {
    if let Some(g) = glyphs.iter().find(|g| g.idx == start) {
        out.push(TextRun { text, x: g.x, tspan, start });
    }
}

/// The shared plan for non-flat text, which the legacy canvas
/// (`canvas/render.rs`) and the walk (`painter/element_render.rs`) both draw,
/// so the two cannot lay it out differently: each character measured in its
/// own tspan's face, the content laid out once
/// ([`text_layout::layout_with_paragraphs_widths`], the element's face for
/// glue and the synthetic hyphen), then each line as its [`line_runs`] and
/// the paragraphs' list markers. A justified (stretched) line is drawn word
/// by word, and a hyphenated break draws its hyphen.
///
/// `measurer` answers a face's measurer, or `None` when it cannot measure
/// that face; then there is no plan (the walk refuses rather than position
/// text by metrics belonging to no font).
///
/// The leading is the element's `line_height` in pt, or Auto: the first
/// wrapper's `jas:auto-leading` percent of the size, else the size. What the
/// plan does NOT draw (spacing, decoration, a baseline shift, a case
/// transform, a per-tspan size, an anchor) is the
/// router's to keep away from it (`element_render::runs_plan_excludes`).
pub fn plan(
    e: &crate::geometry::element::TextElem,
    measurer: &dyn Fn(&RunFace) -> Option<Box<dyn Fn(&str) -> f64>>,
) -> Option<RunsPlan> {
    let measure = measurer(&element_face(e))?;
    let content = e.content();
    let mut widths: Vec<f64> = Vec::with_capacity(content.chars().count());
    for t in &e.tspans {
        if t.content.is_empty() { continue; }
        let m = measurer(&tspan_face(e, t))?;
        widths.extend(t.content.chars().map(|c| m(&c.to_string())));
    }
    let leading = if e.line_height.is_empty() {
        match e.tspans.iter()
            .find(|t| t.jas_role.as_deref() == Some("paragraph"))
            .and_then(|t| t.jas_auto_leading)
        {
            Some(pct) => e.font_size * pct / 100.0,
            None => e.font_size,
        }
    } else {
        crate::geometry::tspan::parse_pt(&e.line_height).unwrap_or(e.font_size)
    };
    let max_w = if e.is_area_text() { e.width } else { 0.0 };
    let segments = crate::algorithms::text_layout_paragraph::build_segments_from_text(
        &e.tspans, &content, e.is_area_text());
    let layout = crate::algorithms::text_layout::layout_with_paragraphs_widths(
        &content, max_w, leading, &segments, &*measure, Some(&widths));
    let ranges = tspan_ranges(e.tspans.iter().map(|t| t.content.as_str()));
    let mut lines = line_runs(&layout, &content, &ranges);
    let chars: Vec<char> = content.chars().collect();
    for (line, runs) in layout.lines.iter().zip(lines.iter_mut()) {
        let glyphs = &layout.glyphs[line.glyph_start.min(layout.glyphs.len())..line.glyph_end.min(layout.glyphs.len())];
        if stretched(glyphs, line, &chars, &widths) {
            runs.runs = word_runs(&runs.runs, glyphs);
        }
        if line.trailing_hyphen {
            // The layout's hyphen glyph is the one past the line's last
            // character; it is drawn in that character's tspan.
            let hyphen = glyphs.iter().rev().find(|g| g.idx >= line.end && !g.is_trailing_space);
            let owner = ranges.iter().position(|&(a, b)| a < line.end && line.end <= b);
            if let (Some(g), Some(t)) = (hyphen, owner) {
                runs.runs.push(TextRun { text: "-".into(), x: g.x, tspan: t, start: line.end });
            }
        }
    }
    let markers = crate::algorithms::text_layout_paragraph::list_marker_paragraphs(&layout, &segments)
        .into_iter()
        .map(|m| PlacedMarker { baseline_y: layout.lines[m.line].baseline_y, text: m.text, x: m.indent })
        .collect();
    Some(RunsPlan { lines, markers })
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

    // ── the whole plan, as both renderers draw it (legacy and the walk) ──

    use crate::geometry::element::{CommonProps, TextElem};
    use crate::geometry::tspan::Tspan;

    fn tspan(content: &str, weight: Option<&str>) -> Tspan {
        let mut t = Tspan::default_tspan();
        t.content = content.to_string();
        t.font_weight = weight.map(|w| w.to_string());
        t
    }

    /// Area text with styled runs: wrapper, plain, bold, plain, in a `width` box.
    fn styled_area(width: f64) -> TextElem {
        let mut e = TextElem::from_string(
            1.0, 2.0, "", "Arial", 20.0, "normal", "normal", "none", width, 200.0, None, None,
            CommonProps::default(),
        );
        let mut w = Tspan::default();
        w.jas_role = Some("paragraph".into());
        e.tspans = vec![w, tspan("One fine day ", None), tspan("extraordinarily patiently", Some("bold")), tspan(" sat", None)];
        e
    }

    /// A measurer per face: 10 per character, 20 in bold. Counts each face it
    /// was asked for, so an arm can see which faces the plan measured.
    fn faces(seen: &std::cell::RefCell<Vec<String>>) -> impl Fn(&RunFace) -> Option<Box<dyn Fn(&str) -> f64>> + '_ {
        move |f: &RunFace| {
            seen.borrow_mut().push(format!("{} {} {} {}", f.style, f.weight, f.size, f.family));
            let w = if f.weight == "bold" { 20.0 } else { 10.0 };
            Some(Box::new(move |s: &str| s.chars().count() as f64 * w) as Box<dyn Fn(&str) -> f64>)
        }
    }

    fn shape(p: &RunsPlan) -> Vec<Vec<(String, f64, usize)>> {
        p.lines.iter().map(|l| l.runs.iter().map(|r| (r.text.clone(), r.x, r.tspan)).collect()).collect()
    }

    /// The defect `paragraph.align_center_styled_wrap` froze: the styled area
    /// text wraps, each run in its tspan, every x the per-font sum of what
    /// precedes it on its line.
    #[test]
    fn the_plan_wraps_styled_area_text_measuring_each_char_in_its_tspans_face() {
        let seen = std::cell::RefCell::new(Vec::new());
        let wide = plan(&styled_area(2000.0), &faces(&seen)).expect("every face measures");
        assert_eq!(wide.lines.len(), 1, "control: a wide box is one line");
        // " sat" after 13 plain (130) and 25 bold (500) characters.
        assert_eq!(shape(&wide)[0], vec![
            ("One fine day ".to_string(), 0.0, 1),
            ("extraordinarily patiently".to_string(), 130.0, 2),
            (" sat".to_string(), 630.0, 3),
        ]);
        assert!(seen.borrow().iter().any(|f| f == "normal bold 20 Arial"), "the bold tspan's face was measured: {:?}", seen.borrow());

        let narrow = plan(&styled_area(450.0), &faces(&seen)).expect("every face measures");
        assert_eq!(shape(&narrow), vec![
            vec![("One fine day ".to_string(), 0.0, 1), ("extraordinarily ".to_string(), 130.0, 2)],
            vec![("patiently".to_string(), 0.0, 2), (" sat".to_string(), 180.0, 3)],
        ], "the bold run wraps in bold, at bold widths");
        assert!(narrow.lines[1].baseline_y > narrow.lines[0].baseline_y);
        assert_eq!(narrow.lines[0].baseline_y, 16.0, "first baseline at 0.8 x leading (Auto = the size)");
    }

    /// Align center moves the line, a set leading spaces the lines, and a
    /// tspan whose face cannot be measured refuses the whole plan.
    #[test]
    fn the_plan_aligns_takes_the_leading_and_refuses_an_unmeasurable_face() {
        let seen = std::cell::RefCell::new(Vec::new());
        let left = plan(&styled_area(2000.0), &faces(&seen)).unwrap();
        let mut c = styled_area(2000.0);
        c.tspans[0].text_align = Some("center".into());
        let centred = plan(&c, &faces(&seen)).unwrap();
        // The line is 670 wide in a 2000 box: centred, it starts at 665.
        assert_eq!(centred.lines[0].runs[0].x, 665.0, "Align center moves the line: {:?}", centred.lines[0]);
        assert_eq!(left.lines[0].runs[0].x, 0.0);

        let mut lead = styled_area(400.0);
        lead.line_height = "30pt".into();
        let l = plan(&lead, &faces(&seen)).unwrap();
        assert_eq!(l.lines[1].baseline_y - l.lines[0].baseline_y, 30.0, "a set leading is the line pitch");

        let no_bold = |f: &RunFace| if f.weight == "bold" { None } else { faces(&seen)(f) };
        assert!(plan(&styled_area(400.0), &no_bold).is_none(), "an unmeasurable tspan face refuses the plan");
    }

    /// The markers a list paragraph draws come with the plan, at the
    /// paragraph's indent on its first line.
    #[test]
    fn the_plan_carries_the_list_markers() {
        let seen = std::cell::RefCell::new(Vec::new());
        let mut e = styled_area(2000.0);
        e.tspans[0].jas_list_style = Some("bullet-disc".into());
        e.tspans[0].jas_left_indent = Some(12.0);
        let p = plan(&e, &faces(&seen)).unwrap();
        assert_eq!(p.markers.len(), 1, "{:?}", p.markers);
        assert_eq!((p.markers[0].x, p.markers[0].baseline_y), (12.0, p.lines[0].baseline_y));
        let none = plan(&styled_area(2000.0), &faces(&seen)).unwrap();
        assert!(none.markers.is_empty(), "control: no list style, no marker");
    }

    /// A justified line stretches its glue, so a run drawn as one string
    /// would put its later words at the natural space: on a stretched line
    /// each WORD is its own run, at the layout's x. The last line is ragged
    /// (its glue is not stretched) and keeps whole runs.
    #[test]
    fn a_justified_line_draws_each_word_at_its_stretched_x() {
        let seen = std::cell::RefCell::new(Vec::new());
        let mut e = styled_area(450.0);
        e.tspans[0].text_align = Some("justify".into());
        let p = plan(&e, &faces(&seen)).unwrap();
        let got = shape(&p);
        // Line 1: One(30) fine(40) day(30) extraordinarily(300, bold) = 400 of
        // words in 450, so each of the three glues is 50/3.
        let g = 50.0 / 3.0;
        let want0 = [("One", 0.0, 1), ("fine", 30.0 + g, 1), ("day", 70.0 + 2.0 * g, 1), ("extraordinarily", 100.0 + 3.0 * g, 2)];
        assert_eq!(got[0].len(), want0.len(), "one run per word on the stretched line: {got:?}");
        for (r, w) in got[0].iter().zip(want0) {
            assert_eq!((r.0.as_str(), r.2), (w.0, w.2), "{got:?}");
            assert!((r.1 - w.1).abs() < 1e-9, "{} at {} not {}: {got:?}", w.0, r.1, w.1);
        }
        assert_eq!(got[1], vec![("patiently".to_string(), 0.0, 2), (" sat".to_string(), 180.0, 3)],
            "the ragged last line keeps whole runs");
        // CONTROL: the same text unjustified keeps whole runs on line 1.
        let ragged = shape(&plan(&styled_area(450.0), &faces(&seen)).unwrap());
        assert_eq!(ragged[0].len(), 2, "{ragged:?}");
    }

    /// A line broken at a hyphenation point draws a visible hyphen after its
    /// last character, at the layout's hyphen glyph, in that character's
    /// tspan.
    #[test]
    fn a_hyphenated_line_draws_its_hyphen_in_the_broken_words_tspan() {
        let seen = std::cell::RefCell::new(Vec::new());
        let mut e = styled_area(160.0);
        e.tspans = vec![e.tspans[0].clone(), tspan("go ", None), tspan("information", Some("bold"))];
        e.tspans[0].jas_hyphenate = Some(true);
        let p = plan(&e, &faces(&seen)).unwrap();
        let got = shape(&p);
        let last = got[0].last().expect("line 1 has runs");
        assert_eq!((last.0.as_str(), last.2), ("-", 2), "the hyphen ends line 1, in the bold tspan: {got:?}");
        let before = &got[0][got[0].len() - 2];
        let bold_w = before.0.chars().count() as f64 * 20.0;
        assert!((last.1 - (before.1 + bold_w)).abs() < 1e-9, "the hyphen sits right after the broken word: {got:?}");
        assert!(got[1][0].0.chars().all(|c| c.is_alphabetic()), "line 2 carries the rest of the word: {got:?}");
        // CONTROL: no hyphenation, no hyphen run.
        let mut plain = e.clone();
        plain.tspans[0].jas_hyphenate = None;
        assert!(shape(&plan(&plain, &faces(&seen)).unwrap()).iter().flatten().all(|r| r.0 != "-"));
    }
}
