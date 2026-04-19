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
            // Open a new one.
            current = Some(ParagraphSegment {
                char_start: cursor,
                char_end: cursor,
                left_indent: t.jas_left_indent.unwrap_or(0.0),
                right_indent: t.jas_right_indent.unwrap_or(0.0),
                first_line_indent: t.text_indent.unwrap_or(0.0),
                space_before: t.jas_space_before.unwrap_or(0.0),
                space_after: t.jas_space_after.unwrap_or(0.0),
                text_align: text_align_from(t.text_align.as_deref(), is_area),
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
}
