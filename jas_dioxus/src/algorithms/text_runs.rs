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
    /// The size the run draws at (its tspan's, or the element's after a
    /// baseline shift's scale).
    pub size: f64,
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
                runs.push(TextRun { text, x: g.x, tspan: ti, start: s, size: 0.0 });
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

/// An element baseline shift as `(size_scale, y_shift)`, the flat path's
/// and Swift's law (`canvas/render.rs`; `parseBaselineShift`): `super` at
/// 0.7 x size and 0.35 x size up, `sub` at 0.7 x size and 0.2 x size down,
/// `Npt` N up at full size, none `(1, 0)`. `None` for a value that does not
/// read, which the router keeps away from the plan rather than guess.
pub fn baseline_shift(e: &crate::geometry::element::TextElem) -> Option<(f64, f64)> {
    match e.baseline_shift.as_str() {
        "" => Some((1.0, 0.0)),
        "super" => Some((0.7, -e.font_size * 0.35)),
        "sub" => Some((0.7, e.font_size * 0.2)),
        other => crate::geometry::tspan::parse_pt(other).map(|pt| (1.0, -pt)),
    }
}

/// Tracking plus numeric kerning as one uniform advance in px at `size`, the
/// flat path's and Swift's law (`canvas/render.rs`'s `letterSpacing`;
/// `letterSpacingPx`): each is `Nem`, empty is 0. `None` when either is set
/// and does not read (a kerning MODE word such as `auto`): the router keeps
/// that away from the plan rather than guess.
pub fn letter_spacing(e: &crate::geometry::element::TextElem, size: f64) -> Option<f64> {
    let read = |v: &str| -> Option<f64> {
        if v.is_empty() { Some(0.0) } else { crate::geometry::tspan::parse_em_as_thousandths(v) }
    };
    Some((read(&e.letter_spacing)? + read(&e.kerning)?) * size / 1000.0)
}

/// The face a tspan's run is measured and drawn in under a baseline shift's
/// `scale`: [`tspan_face`], whose size falls back to the element's SCALED
/// size; a tspan's own size is not scaled (Swift: `t.fontSize ?? effectiveFs`).
fn run_face<'a>(
    e: &'a crate::geometry::element::TextElem,
    t: &'a crate::geometry::tspan::Tspan,
    scale: f64,
) -> RunFace<'a> {
    RunFace { size: t.font_size.unwrap_or(e.font_size * scale), ..tspan_face(e, t) }
}

/// A list marker placed relative to the element's origin, drawn in the
/// element's face.
#[derive(Debug, Clone, PartialEq)]
pub struct PlacedMarker {
    pub text: String,
    pub x: f64,
    pub baseline_y: f64,
    /// The size it draws at: the element's, after a baseline shift's scale.
    pub size: f64,
}

/// Which line a decoration draws.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecorationKind {
    Underline,
    LineThrough,
}

/// One decoration line, relative to the element's origin: a horizontal
/// stroke from `x0` to `x1` at `y`, `thickness` wide, in the element's fill.
#[derive(Debug, Clone, PartialEq)]
pub struct Decoration {
    pub kind: DecorationKind,
    pub x0: f64,
    pub x1: f64,
    pub y: f64,
    pub thickness: f64,
}

/// Whether tspan `t` draws `kind`: its own tokens when it overrides (an
/// empty override is "none"), else the element's.
fn decorated(e: &crate::geometry::element::TextElem, t: &crate::geometry::tspan::Tspan, kind: DecorationKind) -> bool {
    let token = match kind { DecorationKind::Underline => "underline", DecorationKind::LineThrough => "line-through" };
    match &t.text_decoration {
        Some(own) => own.iter().any(|w| w == token),
        None => e.text_decoration.split_whitespace().any(|w| w == token),
    }
}

/// The decoration lines of a laid-out text: per line and per kind, each run
/// of contiguous decorated characters from its first glyph's x to its last
/// glyph's right. A soft wrap's trailing space and the synthetic hyphen are
/// not decorated; a justified line's stretched glue is, because the glyphs
/// carry the stretch. A change of tspan size cuts a piece, and each piece is
/// placed at its own size. Legacy's offsets and thickness
/// (`canvas/render.rs`, `draw_text_decorations`): an underline at baseline +
/// 0.12 x size, a line-through at baseline - 0.3 x size, max(0.07 x size, 1)
/// wide.
fn decorations(
    e: &crate::geometry::element::TextElem,
    layout: &TextLayout,
    chars: &[char],
    ranges: &[(usize, usize)],
    scale: f64,
    dy: f64,
    shifts: &[f64],
) -> Vec<Decoration> {
    let owner = |i: usize| ranges.iter().position(|&(a, b)| a <= i && i < b);
    // A decoration line at `size`: its offset from the baseline and thickness.
    let place = |kind: DecorationKind, size: f64| match kind {
        DecorationKind::Underline => size * 0.12,
        DecorationKind::LineThrough => -size * 0.3,
    };
    let mut out = Vec::new();
    for (line, &shift) in layout.lines.iter().zip(shifts) {
        let glyphs = &layout.glyphs[line.glyph_start.min(layout.glyphs.len())..line.glyph_end.min(layout.glyphs.len())];
        for kind in [DecorationKind::Underline, DecorationKind::LineThrough] {
            // (x0, x1, size): one piece of contiguous decorated characters of
            // one size; a change of size starts a new piece.
            let mut span: Option<(f64, f64, f64)> = None;
            let close = |span: &mut Option<(f64, f64, f64)>, out: &mut Vec<Decoration>| {
                if let Some((x0, x1, size)) = span.take() {
                    out.push(Decoration { kind, x0: x0 + shift, x1: x1 + shift, y: line.baseline_y + dy + place(kind, size), thickness: (size * 0.07).max(1.0) });
                }
            };
            for g in glyphs {
                let drawn = g.idx < line.end && g.idx < chars.len() && !g.is_trailing_space && chars[g.idx] != '\n';
                if !drawn { continue; }
                let t = owner(g.idx);
                let on = t.is_some_and(|t| decorated(e, &e.tspans[t], kind));
                if !on {
                    close(&mut span, &mut out);
                    continue;
                }
                let size = t.map_or(e.font_size * scale, |t| run_face(e, &e.tspans[t], scale).size);
                match span {
                    Some((x0, x1, s)) if s == size => span = Some((x0, x1.max(g.right), s)),
                    _ => {
                        close(&mut span, &mut out);
                        span = Some((g.x, g.right, size));
                    }
                }
            }
            close(&mut span, &mut out);
        }
    }
    out
}

/// A tspan's text with its case transform applied: the tspan's own
/// `text_transform` / `font_variant` over the element's; uppercase and small
/// caps upper-case, lowercase lower-cases. The text as written when the
/// transform would change its character count.
fn cased(e: &crate::geometry::element::TextElem, t: &crate::geometry::tspan::Tspan) -> String {
    let tt = t.text_transform.as_deref().unwrap_or(&e.text_transform);
    let fv = t.font_variant.as_deref().unwrap_or(&e.font_variant);
    let out = if tt == "uppercase" || fv == "small-caps" {
        t.content.to_uppercase()
    } else if tt == "lowercase" {
        t.content.to_lowercase()
    } else {
        return t.content.clone();
    };
    if out.chars().count() == t.content.chars().count() { out } else { t.content.clone() }
}

/// The whole plan a renderer draws: the runs of every line, then the
/// markers. Every x and baseline is relative to the element's origin.
#[derive(Debug, Clone, PartialEq)]
pub struct RunsPlan {
    pub lines: Vec<RunLine>,
    pub markers: Vec<PlacedMarker>,
    pub decorations: Vec<Decoration>,
    /// The uniform advance after every character (tracking plus numeric
    /// kerning, in px), which every run draws with. 0 when neither is set.
    pub letter_spacing: f64,
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
        out.push(TextRun { text, x: g.x, tspan, start, size: 0.0 });
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
/// plan does NOT draw (spacing that does not read, a scale or rotation, a baseline shift that
/// does not read, an anchor, a tspan's dx, rotate, transform or baseline
/// shift) is the router's to keep away from it
/// (`element_render::runs_plan_excludes`). A tspan's own size is drawn (its
/// characters measured and its run drawn at that size, on the element's
/// uniform leading), and so are a case transform (each tspan's text as
/// `cased` transforms it) and an element baseline shift ([`baseline_shift`]:
/// the element's size scaled, every baseline moved; each run and marker
/// carries the size it draws at), and tracking and kerning ([`letter_spacing`],
/// in every character's width so the layout matches the draw; the plan carries
/// the advance). `None` also when the shift or the spacing does not read.
pub fn plan(
    e: &crate::geometry::element::TextElem,
    measurer: &dyn Fn(&RunFace) -> Option<Box<dyn Fn(&str) -> f64>>,
) -> Option<RunsPlan> {
    let (scale, dy) = baseline_shift(e)?;
    let base = RunFace { size: e.font_size * scale, ..element_face(e) };
    let spacing = letter_spacing(e, base.size)?;
    let measure = measurer(&base)?;
    // Each tspan's characters as drawn: its case transform (its own over the
    // element's; small caps draws as uppercase), as Swift's per-run
    // `applyTextTransform`. A transform that would change the character count
    // (a German sharp s uppercases to two letters) keeps the text as written,
    // because the layout and the tspan ranges count characters.
    let shown: Vec<String> = e.tspans.iter().map(|t| cased(e, t)).collect();
    let content: String = shown.concat();
    let mut widths: Vec<f64> = Vec::with_capacity(content.chars().count());
    for (t, text) in e.tspans.iter().zip(&shown) {
        if text.is_empty() { continue; }
        let m = measurer(&run_face(e, t, scale))?;
        widths.extend(text.chars().map(|c| m(&c.to_string()) + spacing));
    }
    let leading = if e.line_height.is_empty() {
        match e.tspans.iter()
            .find(|t| t.jas_role.as_deref() == Some("paragraph"))
            .and_then(|t| t.jas_auto_leading)
        {
            Some(pct) => base.size * pct / 100.0,
            None => base.size,
        }
    } else {
        crate::geometry::tspan::parse_pt(&e.line_height).unwrap_or(base.size)
    };
    let max_w = if e.is_area_text() { e.width } else { 0.0 };
    let segments = crate::algorithms::text_layout_paragraph::build_segments_from_text(
        &e.tspans, &content, e.is_area_text());
    let layout = crate::algorithms::text_layout::layout_with_paragraphs_widths(
        &content, max_w, leading, &segments, &*measure, Some(&widths));
    let ranges = tspan_ranges(shown.iter().map(|t| t.as_str()));
    let mut lines = line_runs(&layout, &content, &ranges);
    let chars: Vec<char> = content.chars().collect();
    // A point text's anchor moves each line by the width it draws: its
    // characters' widths, its hard break excluded (`anchor_shift` is 0 for
    // area text and the default anchor). The markers stay at their indent.
    let shifts: Vec<f64> = layout.lines.iter().map(|line| {
        let w: f64 = (line.start..line.end.min(chars.len()))
            .filter(|&i| chars[i] != '\n')
            .map(|i| widths[i])
            .sum();
        e.anchor_shift(w)
    }).collect();
    for ((line, runs), shift) in layout.lines.iter().zip(lines.iter_mut()).zip(&shifts) {
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
                runs.runs.push(TextRun { text: "-".into(), x: g.x, tspan: t, start: line.end, size: 0.0 });
            }
        }
        // Each run at its resolved size, on the shifted baseline.
        for r in &mut runs.runs {
            r.size = run_face(e, &e.tspans[r.tspan], scale).size;
            r.x += shift;
        }
        runs.baseline_y += dy;
    }
    let markers = crate::algorithms::text_layout_paragraph::list_marker_paragraphs(&layout, &segments)
        .into_iter()
        .map(|m| PlacedMarker { baseline_y: layout.lines[m.line].baseline_y + dy, text: m.text, x: m.indent, size: base.size })
        .collect();
    let decorations = decorations(e, &layout, &chars, &ranges, scale, dy, &shifts);
    Some(RunsPlan { lines, markers, decorations, letter_spacing: spacing })
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

    /// A measurer per face: size / 2 per character, the size in bold. Counts each face it
    /// was asked for, so an arm can see which faces the plan measured.
    fn faces(seen: &std::cell::RefCell<Vec<String>>) -> impl Fn(&RunFace) -> Option<Box<dyn Fn(&str) -> f64>> + '_ {
        move |f: &RunFace| {
            seen.borrow_mut().push(format!("{} {} {} {}", f.style, f.weight, f.size, f.family));
            // Half the size per character, the whole size in bold: 10 and 20
            // at the element's size 20.
            let w = if f.weight == "bold" { f.size } else { f.size / 2.0 };
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

    /// A justified line that fits exactly is not stretched (ratio 0): its
    /// dropped trailing glue leaves a ZERO-width space glyph, which is not a
    /// stretch, so the line keeps its whole run.
    #[test]
    fn an_exactly_fitting_justified_line_keeps_its_whole_run() {
        let seen = std::cell::RefCell::new(Vec::new());
        let mut e = styled_area(90.0);
        e.tspans = vec![e.tspans[0].clone(), tspan("aaaa bbbb cc", None)];
        e.tspans[0].text_align = Some("justify".into());
        let got = shape(&plan(&e, &faces(&seen)).unwrap());
        assert_eq!(got[0], vec![("aaaa bbbb ".to_string(), 0.0, 1)], "{got:?}");
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
        // Justified too: the composer's hyphen penalty places the glyph.
        let mut both = e.clone();
        both.tspans[0].text_align = Some("justify".into());
        let j = shape(&plan(&both, &faces(&seen)).unwrap());
        let jl = j.iter().find(|l| l.last().is_some_and(|r| r.0 == "-")).expect(&format!("a justified line ends in the hyphen: {j:?}"));
        let jb = &jl[jl.len() - 2];
        assert_eq!(jl.last().unwrap().2, 2, "{j:?}");
        assert!((jl.last().unwrap().1 - (jb.1 + jb.0.chars().count() as f64 * 20.0)).abs() < 1e-9, "{j:?}");
        // CONTROL: no hyphenation, no hyphen run.
        let mut plain = e.clone();
        plain.tspans[0].jas_hyphenate = None;
        assert!(shape(&plan(&plain, &faces(&seen)).unwrap()).iter().flatten().all(|r| r.0 != "-"));
    }
    fn decos(p: &RunsPlan) -> Vec<(DecorationKind, f64, f64, f64)> {
        p.decorations.iter().map(|d| (d.kind, d.x0, d.x1, d.y)).collect()
    }

    /// A tspan's underline is drawn under its own characters only, one line
    /// per laid-out line it reaches, from its first glyph's x to its last
    /// visible glyph's right (a soft wrap's trailing space is not underlined).
    #[test]
    fn a_tspans_underline_follows_its_characters_across_a_wrap() {
        let seen = std::cell::RefCell::new(Vec::new());
        let mut e = styled_area(450.0);
        e.tspans[2].text_decoration = Some(vec!["underline".into()]);
        let p = plan(&e, &faces(&seen)).unwrap();
        let (b0, b1) = (p.lines[0].baseline_y, p.lines[1].baseline_y);
        assert_eq!(decos(&p), vec![
            (DecorationKind::Underline, 130.0, 430.0, b0 + 20.0 * 0.12),
            (DecorationKind::Underline, 0.0, 180.0, b1 + 20.0 * 0.12),
        ], "under \"extraordinarily\" on line 1 and \"patiently\" on line 2");
        assert_eq!(p.decorations[0].thickness, (20.0f64 * 0.07).max(1.0));
        // CONTROL: no decoration anywhere, no lines.
        assert!(plan(&styled_area(450.0), &faces(&seen)).unwrap().decorations.is_empty());
    }

    /// The element's decoration reaches every tspan that does not override
    /// it; an explicit empty override (`Some([])`) cuts the line; a strike is
    /// at baseline - 0.3 x size.
    #[test]
    fn an_element_decoration_is_inherited_and_an_empty_override_cuts_it() {
        let seen = std::cell::RefCell::new(Vec::new());
        let mut e = styled_area(2000.0);
        e.text_decoration = "line-through".into();
        e.tspans[2].text_decoration = Some(vec![]);
        let p = plan(&e, &faces(&seen)).unwrap();
        let b = p.lines[0].baseline_y;
        assert_eq!(decos(&p), vec![
            (DecorationKind::LineThrough, 0.0, 130.0, b - 20.0 * 0.3),
            (DecorationKind::LineThrough, 630.0, 670.0, b - 20.0 * 0.3),
        ], "struck through the plain runs, not the bold one");
        // CONTROL: without the override the strike is continuous.
        let mut whole = styled_area(2000.0);
        whole.text_decoration = "line-through".into();
        assert_eq!(decos(&plan(&whole, &faces(&seen)).unwrap()), vec![(DecorationKind::LineThrough, 0.0, 670.0, b - 20.0 * 0.3)]);
    }

    /// A tspan's own SIZE (Swift's law: each run at its tspan's size on the
    /// element's uniform leading): its characters are measured at that size,
    /// the run draws at it, the baselines do not move, and a decoration is cut
    /// where the size changes, each piece at its own offset and thickness.
    #[test]
    fn a_tspans_size_measures_and_decorates_its_run_on_the_uniform_leading() {
        let seen = std::cell::RefCell::new(Vec::new());
        let mut e = styled_area(2000.0);
        e.tspans[2].font_size = Some(30.0);
        e.text_decoration = "underline".into();
        let p = plan(&e, &faces(&seen)).unwrap();
        // 25 bold characters at 30 each: " sat" at 130 + 750.
        assert_eq!(shape(&p)[0], vec![
            ("One fine day ".to_string(), 0.0, 1),
            ("extraordinarily patiently".to_string(), 130.0, 2),
            (" sat".to_string(), 880.0, 3),
        ]);
        assert_eq!(p.lines[0].baseline_y, 16.0, "the leading is the element's, not the run's");
        let b = p.lines[0].baseline_y;
        let d: Vec<(f64, f64, f64, f64)> = p.decorations.iter().map(|d| (d.x0, d.x1, d.y, d.thickness)).collect();
        assert_eq!(d, vec![
            (0.0, 130.0, b + 20.0 * 0.12, (20.0f64 * 0.07).max(1.0)),
            (130.0, 880.0, b + 30.0 * 0.12, (30.0f64 * 0.07).max(1.0)),
            (880.0, 920.0, b + 20.0 * 0.12, (20.0f64 * 0.07).max(1.0)),
        ], "the underline is cut where the size changes");
    }

    /// A case transform (the element's, or a tspan's own over it; small caps
    /// draws as uppercase, the flat path's placeholder) changes the characters
    /// the plan MEASURES and DRAWS, as Swift's per-run transform does. Here a
    /// capital measures 20 and anything else 10, so the widths prove the
    /// measurement was taken on the transformed text.
    #[test]
    fn a_case_transform_is_measured_and_drawn_per_tspan() {
        let caps = |_: &RunFace| Some(Box::new(|s: &str| s.chars().map(|c| if c.is_uppercase() { 20.0 } else { 10.0 }).sum::<f64>()) as Box<dyn Fn(&str) -> f64>);
        let mut e = styled_area(2000.0);
        e.text_transform = "uppercase".into();
        e.tspans[2].text_transform = Some("none".into());
        e.tspans[3].font_variant = Some("small-caps".into());
        e.tspans[3].text_transform = Some("none".into());
        let p = plan(&e, &caps).unwrap();
        // "ONE FINE DAY ": 10 capitals and 3 spaces = 230; then 25 lower-case.
        assert_eq!(shape(&p)[0], vec![
            ("ONE FINE DAY ".to_string(), 0.0, 1),
            ("extraordinarily patiently".to_string(), 230.0, 2),
            (" SAT".to_string(), 480.0, 3),
        ]);
        // A transform that changes the character count keeps the text as
        // written: "ß" uppercases to "SS".
        let mut sharp = styled_area(2000.0);
        sharp.text_transform = "uppercase".into();
        sharp.tspans[3].content = " straße".into();
        let q = shape(&plan(&sharp, &caps).unwrap());
        assert_eq!(q[0].last().unwrap().0, " straße", "{q:?}");
        assert_eq!(q[0][0].0, "ONE FINE DAY ", "and the other tspans still transform: {q:?}");
        // CONTROL: no transform, the text as written.
        let plain = plan(&styled_area(2000.0), &caps).unwrap();
        assert_eq!(shape(&plain)[0][0], ("One fine day ".to_string(), 0.0, 1));
        assert_eq!(shape(&plain)[0][1].1, 140.0, "the capital O measures 20, the rest 10");
    }

    /// An element baseline shift (Swift's and the flat path's law): super and
    /// sub draw at 0.7 x the size (a tspan's OWN size is not scaled), the
    /// leading follows the scaled size, and every baseline moves: super up
    /// 0.35 x size, sub down 0.2 x size, `Npt` up N at full size. Each run
    /// carries the size it draws at.
    #[test]
    fn an_element_baseline_shift_scales_and_moves_the_plan() {
        let seen = std::cell::RefCell::new(Vec::new());
        let mut e = styled_area(2000.0);
        e.baseline_shift = "super".into();
        let p = plan(&e, &faces(&seen)).unwrap();
        // Size 14: 7 per plain character, 14 per bold one.
        assert_eq!(shape(&p)[0], vec![
            ("One fine day ".to_string(), 0.0, 1),
            ("extraordinarily patiently".to_string(), 91.0, 2),
            (" sat".to_string(), 441.0, 3),
        ]);
        assert!(p.lines[0].runs.iter().all(|r| r.size == 14.0), "{:?}", p.lines[0].runs);
        assert!((p.lines[0].baseline_y - (14.0 * 0.8 - 20.0 * 0.35)).abs() < 1e-9, "{}", p.lines[0].baseline_y);
        // A marker and a decoration move and scale with it.
        let mut deco = e.clone();
        deco.tspans[0].jas_list_style = Some("bullet-disc".into());
        deco.text_decoration = "underline".into();
        let d = plan(&deco, &faces(&seen)).unwrap();
        let b = d.lines[0].baseline_y;
        assert_eq!((d.markers[0].baseline_y, d.markers[0].size), (b, 14.0), "{:?}", d.markers);
        assert!((d.decorations[0].y - (b + 14.0 * 0.12)).abs() < 1e-9 && d.decorations[0].thickness == (14.0f64 * 0.07).max(1.0), "{:?}", d.decorations);
        // A tspan's own size is not scaled.
        let mut own = e.clone();
        own.tspans[2].font_size = Some(30.0);
        assert_eq!(plan(&own, &faces(&seen)).unwrap().lines[0].runs[1].size, 30.0);
        // Sub, and a numeric shift at full size.
        let mut sub = styled_area(2000.0);
        sub.baseline_shift = "sub".into();
        assert!((plan(&sub, &faces(&seen)).unwrap().lines[0].baseline_y - (14.0 * 0.8 + 20.0 * 0.2)).abs() < 1e-9);
        let mut pt = styled_area(2000.0);
        pt.baseline_shift = "3pt".into();
        let q = plan(&pt, &faces(&seen)).unwrap();
        assert!((q.lines[0].baseline_y - (16.0 - 3.0)).abs() < 1e-9 && q.lines[0].runs[0].size == 20.0);
        // CONTROL: no shift, the size and baseline as written.
        let none = plan(&styled_area(2000.0), &faces(&seen)).unwrap();
        assert_eq!((none.lines[0].baseline_y, none.lines[0].runs[0].size), (16.0, 20.0));
    }

    /// Tracking and numeric kerning (the flat path's and Swift's law: one
    /// uniform advance, (tracking + kerning) in em x the size, after every
    /// character) are IN the layout: each character's width carries it, so a
    /// tracked line wraps and aligns at the width it is drawn at. The plan
    /// carries the advance for the renderer to draw with.
    #[test]
    fn tracking_and_kerning_are_in_the_layout_and_the_draw() {
        let seen = std::cell::RefCell::new(Vec::new());
        let mut e = styled_area(2000.0);
        e.letter_spacing = "0.06em".into();
        e.kerning = "0.04em".into();
        let p = plan(&e, &faces(&seen)).unwrap();
        // 0.1 em at size 20 = 2 per character: plain 12, bold 22.
        assert!((p.letter_spacing - 2.0).abs() < 1e-9, "{}", p.letter_spacing);
        let got = shape(&p)[0].clone();
        assert_eq!(got.iter().map(|r| r.0.as_str()).collect::<Vec<_>>(), ["One fine day ", "extraordinarily patiently", " sat"]);
        assert!((got[1].1 - 156.0).abs() < 1e-9 && (got[2].1 - 706.0).abs() < 1e-9, "{got:?}");
        // A super shift scales the advance with the size.
        let mut sup = e.clone();
        sup.baseline_shift = "super".into();
        assert!((plan(&sup, &faces(&seen)).unwrap().letter_spacing - 1.4).abs() < 1e-9);
        // CONTROL: none set, no advance and the widths as measured.
        let none = plan(&styled_area(2000.0), &faces(&seen)).unwrap();
        assert_eq!((none.letter_spacing, shape(&none)[0][1].1), (0.0, 130.0));
        // A value that does not read refuses the plan rather than guess.
        let mut bad = styled_area(2000.0);
        bad.kerning = "auto".into();
        assert!(plan(&bad, &faces(&seen)).is_none());
    }

    /// On a justified line the underline spans the STRETCHED glue, not the
    /// natural width: one line from the first word to the last.
    #[test]
    fn an_underline_spans_a_justified_lines_stretched_glue() {
        let seen = std::cell::RefCell::new(Vec::new());
        let mut e = styled_area(450.0);
        e.tspans[0].text_align = Some("justify".into());
        e.text_decoration = "underline".into();
        let p = plan(&e, &faces(&seen)).unwrap();
        let d = decos(&p);
        assert_eq!((d[0].1, d[0].2), (0.0, 450.0), "line 1 is underlined edge to edge: {d:?}");
    }

    /// Point text under an anchor: each line moves left by `anchor_shift` of
    /// the width it draws (its characters' widths, its hard break excluded),
    /// so a middle line centres on `x` and an end line ends there. Its
    /// decorations move with it; a list marker stays at its indent, as the
    /// layout path and Swift place it. Area text ignores the anchor.
    #[test]
    fn a_point_texts_anchor_moves_each_line_by_its_own_width() {
        let seen = std::cell::RefCell::new(Vec::new());
        let point = |anchor: &str| {
            let mut e = TextElem::from_string(
                1.0, 2.0, "", "Arial", 20.0, "normal", "normal", "none", 0.0, 0.0, None, None,
                CommonProps::default(),
            );
            let mut w = Tspan::default();
            w.jas_role = Some("paragraph".into());
            w.jas_list_style = Some("bullet-disc".into());
            w.jas_left_indent = Some(12.0);
            e.tspans = vec![w, tspan("ab\n", None), tspan("cdef", Some("bold"))];
            e.text_decoration = "underline".into();
            e.text_anchor = anchor.into();
            e
        };
        let xs = |p: &RunsPlan| shape(p).iter().map(|l| l.iter().map(|r| r.1).collect::<Vec<_>>()).collect::<Vec<_>>();
        // "ab" is 2 x 10 wide, "cdef" 4 x 20 (bold): each line by its own width.
        let start = plan(&point(""), &faces(&seen)).unwrap();
        // The list indent puts both lines at 24; the anchor moves them from there.
        assert_eq!(xs(&start), vec![vec![24.0], vec![24.0]]);
        let middle = plan(&point("middle"), &faces(&seen)).unwrap();
        assert_eq!(xs(&middle), vec![vec![14.0], vec![-16.0]]);
        let end = plan(&point("end"), &faces(&seen)).unwrap();
        assert_eq!(xs(&end), vec![vec![4.0], vec![-56.0]]);
        // The underline moves with its line.
        let spans = |p: &RunsPlan| decos(p).iter().map(|d| (d.1, d.2)).collect::<Vec<_>>();
        assert_eq!(spans(&start), vec![(24.0, 44.0), (24.0, 104.0)]);
        assert_eq!(spans(&middle), vec![(14.0, 34.0), (-16.0, 64.0)]);
        // A marker stays at its indent, whatever the anchor.
        assert!(!start.markers.is_empty(), "the fixture must place a marker");
        assert_eq!(middle.markers, start.markers);
        assert_eq!(end.markers, start.markers);
        // An unknown anchor is the default.
        assert_eq!(plan(&point("bogus"), &faces(&seen)).unwrap(), start);
        // Area text ignores the anchor.
        let mut area = styled_area(450.0);
        let plain = plan(&area, &faces(&seen)).unwrap();
        area.text_anchor = "end".into();
        assert_eq!(plan(&area, &faces(&seen)).unwrap(), plain);
    }
}
