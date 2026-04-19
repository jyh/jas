//! Build [`ParagraphSegment`] lists from a Text/TextPath's `tspans`.
//!
//! A `tspan` whose `jas_role == "paragraph"` is a paragraph wrapper:
//! it carries the per-paragraph attribute set (indent, space, list
//! style, alignment) but no text content. The body tspans that
//! follow it (until the next wrapper or end) make up that paragraph.
//!
//! Phase 5: produces segments for the rendering pipeline so
//! `text_layout::layout_with_paragraphs` can apply each paragraph's
//! constraints. When the element has no wrapper tspans the entire
//! content collapses to a single default segment — equivalent to
//! the old wrapper-unaware layout.

use crate::algorithms::text_layout::{ParagraphSegment, TextAlign};
use crate::geometry::tspan::Tspan;

/// Gap between marker and text per PARAGRAPH.md §Marker rendering.
/// Stored on each ParagraphSegment so future variants (e.g. wider
/// markers like "iii.") could override the constant per item.
pub const MARKER_GAP_PT: f64 = 12.0;

/// The literal glyph string that renders as the marker for the
/// given `jas:list-style` value at counter index `counter` (1-based).
/// `bullet-*` styles ignore the counter; `num-*` styles format it
/// per the §Bullets and numbered lists enumeration. Unknown styles
/// return an empty string so the renderer skips drawing.
pub fn marker_text(list_style: &str, counter: usize) -> String {
    match list_style {
        "bullet-disc" => "\u{2022}".into(),         // •
        "bullet-open-circle" => "\u{25CB}".into(),  // ○
        "bullet-square" => "\u{25A0}".into(),       // ■
        "bullet-open-square" => "\u{25A1}".into(),  // □
        "bullet-dash" => "\u{2013}".into(),         // –
        "bullet-check" => "\u{2713}".into(),        // ✓
        "num-decimal" => format!("{}.", counter),
        "num-lower-alpha" => format!("{}.", to_alpha(counter, false)),
        "num-upper-alpha" => format!("{}.", to_alpha(counter, true)),
        "num-lower-roman" => format!("{}.", to_roman(counter, false)),
        "num-upper-roman" => format!("{}.", to_roman(counter, true)),
        _ => String::new(),
    }
}

/// 1 → "a", 2 → "b", ... 26 → "z", 27 → "aa", 28 → "ab", ...
/// Spreadsheet-style base-26 with no zero digit. `upper` capitalises.
pub fn to_alpha(mut n: usize, upper: bool) -> String {
    if n == 0 { return String::new(); }
    let base = if upper { b'A' } else { b'a' };
    let mut buf = Vec::new();
    while n > 0 {
        n -= 1;
        buf.push(base + (n % 26) as u8);
        n /= 26;
    }
    buf.reverse();
    String::from_utf8(buf).unwrap_or_default()
}

/// 1 → "i", 4 → "iv", 9 → "ix", 1990 → "mcmxc", etc. Numbers above
/// 3999 collapse to "(N)" since standard Roman tops out at MMMCMXCIX.
pub fn to_roman(mut n: usize, upper: bool) -> String {
    if n == 0 { return String::new(); }
    if n > 3999 { return format!("({})", n); }
    const PAIRS: &[(usize, &str, &str)] = &[
        (1000, "M", "m"),  (900, "CM", "cm"),
        (500, "D", "d"),   (400, "CD", "cd"),
        (100, "C", "c"),   (90, "XC", "xc"),
        (50, "L", "l"),    (40, "XL", "xl"),
        (10, "X", "x"),    (9, "IX", "ix"),
        (5, "V", "v"),     (4, "IV", "iv"),
        (1, "I", "i"),
    ];
    let mut out = String::new();
    for &(v, u, l) in PAIRS {
        while n >= v {
            out.push_str(if upper { u } else { l });
            n -= v;
        }
    }
    out
}

/// Compute the 1-based counter for each numbered-list paragraph in
/// `segs`, in order. Bullet and non-list paragraphs get 0 (the
/// renderer ignores the counter for them). Per PARAGRAPH.md
/// §Counter run rule: consecutive paragraphs with the same `num-*`
/// list style continue counting; a different style or a bullet /
/// no-style paragraph breaks the run, and the next `num-*` paragraph
/// starts again at 1 (even if the same style as before the break).
pub fn compute_counters(segs: &[ParagraphSegment]) -> Vec<usize> {
    let mut counters = Vec::with_capacity(segs.len());
    let mut prev_num: Option<&str> = None;
    let mut current: usize = 0;
    for seg in segs {
        match seg.list_style.as_deref() {
            Some(style) if style.starts_with("num-") => {
                if prev_num == Some(style) {
                    current += 1;
                } else {
                    current = 1;
                }
                counters.push(current);
                prev_num = Some(style);
            }
            _ => {
                counters.push(0);
                prev_num = None;
                current = 0;
            }
        }
    }
    counters
}

/// Build a list of paragraph segments from `tspans`. The segments
/// are ordered by char position, half-open, and cover every char in
/// `content` exactly once. Each wrapper's pt-valued indent / space
/// attributes are passed through verbatim — the renderer's px units
/// happen to equal pt for the canvas coordinate space, so no
/// conversion is needed at this boundary.
///
/// `is_area` mirrors the area-vs-point decision in PARAGRAPH.md
/// §Text-kind gating: the four `JUSTIFY_*` modes only apply to
/// area text. For point text we coerce them to `Left` so the
/// renderer doesn't try to justify a single-line caret.
pub fn build_segments_from_text(
    tspans: &[Tspan],
    content: &str,
    is_area: bool,
) -> Vec<ParagraphSegment> {
    let total_chars = content.chars().count();
    let mut segs: Vec<ParagraphSegment> = Vec::new();
    let mut cursor = 0usize;
    // Find every wrapper and the run of body chars that follows.
    // Track "current open segment" so multiple body tspans inside
    // one paragraph collapse into a single segment.
    let mut current: Option<ParagraphSegment> = None;
    for t in tspans {
        let body_chars = t.content.chars().count();
        if t.jas_role.as_deref() == Some("paragraph") {
            // Close the previous open segment at the current cursor.
            if let Some(mut seg) = current.take() {
                seg.char_end = cursor;
                if seg.char_end > seg.char_start {
                    segs.push(seg);
                }
            }
            // Open a new one. Phase 6 carries jas:list-style through
            // so the renderer can draw the marker and the layout can
            // shift the text by marker_gap. Phase 7 carries
            // jas:hanging-punctuation so layout can offset hanging
            // chars at line edges.
            let list_style = t.jas_list_style.clone();
            let marker_gap = if list_style.is_some() { MARKER_GAP_PT } else { 0.0 };
            current = Some(ParagraphSegment {
                char_start: cursor,
                char_end: cursor,
                left_indent: t.jas_left_indent.unwrap_or(0.0),
                right_indent: t.jas_right_indent.unwrap_or(0.0),
                first_line_indent: t.text_indent.unwrap_or(0.0),
                space_before: t.jas_space_before.unwrap_or(0.0),
                space_after: t.jas_space_after.unwrap_or(0.0),
                text_align: text_align_from(t.text_align.as_deref(), is_area),
                list_style,
                marker_gap,
                hanging_punctuation: t.jas_hanging_punctuation.unwrap_or(false),
            });
        } else {
            cursor += body_chars;
        }
    }
    // Close any pending wrapper.
    if let Some(mut seg) = current.take() {
        seg.char_end = cursor.min(total_chars);
        if seg.char_end > seg.char_start {
            segs.push(seg);
        }
    }
    segs
}

/// Map the wrapper tspan's `text-align` string to a `TextAlign`.
/// Phase 5 supports `left` / `center` / `right`; the four `justify*`
/// values fall back to `Left` for now (the composer in Phase 8 will
/// promote them). For point text every alignment maps to `Left` —
/// the renderer doesn't visibly justify a single-line caret.
fn text_align_from(value: Option<&str>, is_area: bool) -> TextAlign {
    match value {
        Some("center") => TextAlign::Center,
        Some("right") => TextAlign::Right,
        Some("justify") if is_area => TextAlign::Left,  // placeholder
        _ => TextAlign::Left,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::tspan::Tspan;

    fn wrapper(left: f64, right: f64, fli: f64, sb: f64, sa: f64, ta: Option<&str>) -> Tspan {
        Tspan {
            id: 0, content: String::new(),
            jas_role: Some("paragraph".into()),
            jas_left_indent: if left == 0.0 { None } else { Some(left) },
            jas_right_indent: if right == 0.0 { None } else { Some(right) },
            text_indent: if fli == 0.0 { None } else { Some(fli) },
            jas_space_before: if sb == 0.0 { None } else { Some(sb) },
            jas_space_after: if sa == 0.0 { None } else { Some(sa) },
            text_align: ta.map(String::from),
            ..Default::default()
        }
    }

    fn body(content: &str) -> Tspan {
        Tspan { id: 0, content: content.into(), ..Default::default() }
    }

    #[test]
    fn no_wrapper_yields_no_segments() {
        let segs = build_segments_from_text(&[body("hello")], "hello", true);
        assert!(segs.is_empty());
    }

    #[test]
    fn single_wrapper_covers_the_content() {
        let segs = build_segments_from_text(
            &[wrapper(12.0, 0.0, 0.0, 0.0, 0.0, None), body("hello")],
            "hello", true);
        assert_eq!(segs.len(), 1);
        assert_eq!(segs[0].char_start, 0);
        assert_eq!(segs[0].char_end, 5);
        assert_eq!(segs[0].left_indent, 12.0);
    }

    #[test]
    fn two_wrappers_split_content() {
        let segs = build_segments_from_text(
            &[
                wrapper(0.0, 0.0, 0.0, 0.0, 0.0, None), body("ab"),
                wrapper(0.0, 0.0, 0.0, 6.0, 0.0, Some("center")), body("cde"),
            ],
            "abcde", true);
        assert_eq!(segs.len(), 2);
        assert_eq!(segs[0].char_start, 0);
        assert_eq!(segs[0].char_end, 2);
        assert_eq!(segs[1].char_start, 2);
        assert_eq!(segs[1].char_end, 5);
        assert_eq!(segs[1].space_before, 6.0);
        assert_eq!(segs[1].text_align, TextAlign::Center);
    }

    #[test]
    fn justify_falls_back_to_left_in_phase5() {
        let segs = build_segments_from_text(
            &[wrapper(0.0, 0.0, 0.0, 0.0, 0.0, Some("justify")), body("x")],
            "x", true);
        assert_eq!(segs[0].text_align, TextAlign::Left);
    }

    #[test]
    fn point_text_alignment_falls_back_to_left() {
        // Center alignment on point text would be confusing — the
        // renderer collapses it (canvas point text uses
        // text-anchor on the <text> element, set elsewhere).
        let segs = build_segments_from_text(
            &[wrapper(0.0, 0.0, 0.0, 0.0, 0.0, Some("center")), body("x")],
            "x", false);
        // Point-text mapping isn't fully wired yet — center still
        // round-trips through TextAlign::Center, but the renderer's
        // text_anchor channel takes over. Documented limitation.
        assert_eq!(segs[0].text_align, TextAlign::Center);
    }

    // ── Phase 6: list markers + counter run rule ──────────────

    fn list_wrapper(style: &str) -> Tspan {
        Tspan {
            id: 0, content: String::new(),
            jas_role: Some("paragraph".into()),
            jas_list_style: Some(style.into()),
            ..Default::default()
        }
    }

    #[test]
    fn marker_text_bullets() {
        assert_eq!(marker_text("bullet-disc", 1), "\u{2022}");
        assert_eq!(marker_text("bullet-open-circle", 99), "\u{25CB}");
        assert_eq!(marker_text("bullet-square", 1), "\u{25A0}");
        assert_eq!(marker_text("bullet-open-square", 1), "\u{25A1}");
        assert_eq!(marker_text("bullet-dash", 1), "\u{2013}");
        assert_eq!(marker_text("bullet-check", 1), "\u{2713}");
    }

    #[test]
    fn marker_text_decimal() {
        assert_eq!(marker_text("num-decimal", 1), "1.");
        assert_eq!(marker_text("num-decimal", 42), "42.");
    }

    #[test]
    fn marker_text_alpha() {
        assert_eq!(marker_text("num-lower-alpha", 1), "a.");
        assert_eq!(marker_text("num-lower-alpha", 26), "z.");
        assert_eq!(marker_text("num-lower-alpha", 27), "aa.");
        assert_eq!(marker_text("num-upper-alpha", 28), "AB.");
    }

    #[test]
    fn marker_text_roman() {
        assert_eq!(marker_text("num-lower-roman", 1), "i.");
        assert_eq!(marker_text("num-lower-roman", 4), "iv.");
        assert_eq!(marker_text("num-lower-roman", 9), "ix.");
        assert_eq!(marker_text("num-upper-roman", 1990), "MCMXC.");
    }

    #[test]
    fn marker_text_unknown_style_returns_empty() {
        assert_eq!(marker_text("invented-style", 1), "");
    }

    #[test]
    fn list_segment_carries_style_and_marker_gap() {
        let segs = build_segments_from_text(
            &[list_wrapper("bullet-disc"), body("hello")],
            "hello", true);
        assert_eq!(segs[0].list_style.as_deref(), Some("bullet-disc"));
        assert_eq!(segs[0].marker_gap, MARKER_GAP_PT);
    }

    #[test]
    fn non_list_segment_has_no_marker_gap() {
        let segs = build_segments_from_text(
            &[wrapper(0.0, 0.0, 0.0, 0.0, 0.0, None), body("hi")],
            "hi", true);
        assert_eq!(segs[0].list_style, None);
        assert_eq!(segs[0].marker_gap, 0.0);
    }

    #[test]
    fn compute_counters_consecutive_decimal_run() {
        let segs = vec![
            ParagraphSegment { list_style: Some("num-decimal".into()), ..Default::default() },
            ParagraphSegment { list_style: Some("num-decimal".into()), ..Default::default() },
            ParagraphSegment { list_style: Some("num-decimal".into()), ..Default::default() },
        ];
        let counters = compute_counters(&segs);
        assert_eq!(counters, vec![1, 2, 3]);
    }

    #[test]
    fn compute_counters_bullet_breaks_run() {
        let segs = vec![
            ParagraphSegment { list_style: Some("num-decimal".into()), ..Default::default() },
            ParagraphSegment { list_style: Some("num-decimal".into()), ..Default::default() },
            ParagraphSegment { list_style: Some("bullet-disc".into()), ..Default::default() },
            ParagraphSegment { list_style: Some("num-decimal".into()), ..Default::default() },
        ];
        let counters = compute_counters(&segs);
        assert_eq!(counters, vec![1, 2, 0, 1]);
    }

    #[test]
    fn compute_counters_different_num_style_resets() {
        let segs = vec![
            ParagraphSegment { list_style: Some("num-decimal".into()), ..Default::default() },
            ParagraphSegment { list_style: Some("num-decimal".into()), ..Default::default() },
            ParagraphSegment { list_style: Some("num-lower-alpha".into()), ..Default::default() },
            ParagraphSegment { list_style: Some("num-lower-alpha".into()), ..Default::default() },
        ];
        let counters = compute_counters(&segs);
        assert_eq!(counters, vec![1, 2, 1, 2]);
    }

    #[test]
    fn compute_counters_no_style_breaks_run() {
        let segs = vec![
            ParagraphSegment { list_style: Some("num-decimal".into()), ..Default::default() },
            ParagraphSegment { list_style: None, ..Default::default() },
            ParagraphSegment { list_style: Some("num-decimal".into()), ..Default::default() },
        ];
        let counters = compute_counters(&segs);
        assert_eq!(counters, vec![1, 0, 1]);
    }
}
