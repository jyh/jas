//! Per-character-range formatting substructure of Text and TextPath.
//!
//! See `TSPAN.md` at the repository root for the full language-agnostic
//! design. This module covers the Rust side of steps B.3.1 (data model)
//! and B.3.2 (pure-function primitives). Integration with `TextElem` /
//! `TextPathElem` (making `tspans` a field on each) happens in a
//! separate step; this module is standalone so the primitives can be
//! tested against the shared algorithm vectors before that integration.

use crate::geometry::element::Transform;

/// Stable in-memory tspan identifier.
///
/// Unique within a single `Text` / `TextPath` element. Monotonic `u32`;
/// a fresh id is always strictly greater than every existing id in the
/// element. Not serialized — on SVG load, fresh ids are assigned per
/// tspan starting from 0.
pub type TspanId = u32;

/// A tspan: one contiguous character range inside a `Text` or
/// `TextPath`, carrying per-range attribute overrides.
///
/// All override fields are `None` to mean "inherit the parent
/// element's effective value". See `TSPAN.md` Attribute Inheritance.
#[derive(Debug, Clone, Default, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct Tspan {
    pub id: TspanId,
    pub content: String,
    pub baseline_shift: Option<f64>,
    pub dx: Option<f64>,
    pub font_family: Option<String>,
    pub font_size: Option<f64>,
    pub font_style: Option<String>,
    pub font_variant: Option<String>,
    pub font_weight: Option<String>,
    pub jas_aa_mode: Option<String>,
    pub jas_fractional_widths: Option<bool>,
    pub jas_kerning_mode: Option<String>,
    pub jas_no_break: Option<bool>,
    pub letter_spacing: Option<f64>,
    pub line_height: Option<f64>,
    pub rotate: Option<f64>,
    pub style_name: Option<String>,
    /// Sorted-set of decoration members (`"underline"`, `"line-through"`).
    /// `None` inherits the parent; `Some([])` is an explicit no-decoration
    /// override; writers sort members alphabetically.
    pub text_decoration: Option<Vec<String>>,
    pub text_rendering: Option<String>,
    pub text_transform: Option<String>,
    pub transform: Option<Transform>,
    pub xml_lang: Option<String>,
}

impl Tspan {
    /// Construct a tspan with empty content, id `0`, and every override
    /// `None`. Mirrors the `tspan_default` algorithm vector.
    pub fn default_tspan() -> Self {
        Self::default()
    }

    /// Returns `true` if every override field is `None`. A tspan with no
    /// overrides is purely content — it inherits everything from its
    /// parent element.
    pub fn has_no_overrides(&self) -> bool {
        self.baseline_shift.is_none()
            && self.dx.is_none()
            && self.font_family.is_none()
            && self.font_size.is_none()
            && self.font_style.is_none()
            && self.font_variant.is_none()
            && self.font_weight.is_none()
            && self.jas_aa_mode.is_none()
            && self.jas_fractional_widths.is_none()
            && self.jas_kerning_mode.is_none()
            && self.jas_no_break.is_none()
            && self.letter_spacing.is_none()
            && self.line_height.is_none()
            && self.rotate.is_none()
            && self.style_name.is_none()
            && self.text_decoration.is_none()
            && self.text_rendering.is_none()
            && self.text_transform.is_none()
            && self.transform.is_none()
            && self.xml_lang.is_none()
    }
}

/// Returns the concatenation of every tspan's content in reading order.
///
/// This is the derived `Text.content` value; see `TSPAN.md` Primitives.
pub fn concat_content(tspans: &[Tspan]) -> String {
    let total_len: usize = tspans.iter().map(|t| t.content.len()).sum();
    let mut s = String::with_capacity(total_len);
    for t in tspans {
        s.push_str(&t.content);
    }
    s
}

/// Return the current index of the tspan with the given id, or `None` if
/// no such tspan exists (e.g., it was dropped by `merge`).
///
/// O(n) in tspan count. Matches `resolve_id` in `TSPAN.md`.
pub fn resolve_id(tspans: &[Tspan], id: TspanId) -> Option<usize> {
    tspans.iter().position(|t| t.id == id)
}

/// Split the tspan at `tspan_idx` at character `offset`.
///
/// Returns `(new_tspans, left_idx, right_idx)`. `left_idx` and
/// `right_idx` are `None` when the side of the split is out of the list.
///
/// - `offset == 0`: no split; `left_idx = Some(tspan_idx - 1)` or `None`
///   when `tspan_idx == 0`; `right_idx = Some(tspan_idx)`.
/// - `offset == content_len`: no split; `left_idx = Some(tspan_idx)`;
///   `right_idx = Some(tspan_idx + 1)` or `None` at end of list.
/// - Otherwise: the tspan at `tspan_idx` is replaced by two tspans
///   sharing the original's attribute overrides. The left fragment keeps
///   the original's id; the right fragment receives
///   `max(existing ids) + 1` (a fresh id). Left/right indices are
///   `tspan_idx` and `tspan_idx + 1`.
///
/// Panics if `tspan_idx >= tspans.len()` or `offset > content_len`.
pub fn split(
    tspans: &[Tspan],
    tspan_idx: usize,
    offset: usize,
) -> (Vec<Tspan>, Option<usize>, Option<usize>) {
    assert!(
        tspan_idx < tspans.len(),
        "split: tspan_idx {} out of range ({} tspans)",
        tspan_idx,
        tspans.len()
    );
    let t = &tspans[tspan_idx];
    let content_len_chars = t.content.chars().count();
    assert!(
        offset <= content_len_chars,
        "split: offset {} exceeds tspan content length {}",
        offset,
        content_len_chars
    );

    if offset == 0 {
        let left = if tspan_idx > 0 { Some(tspan_idx - 1) } else { None };
        return (tspans.to_vec(), left, Some(tspan_idx));
    }
    if offset == content_len_chars {
        let right = if tspan_idx + 1 < tspans.len() {
            Some(tspan_idx + 1)
        } else {
            None
        };
        return (tspans.to_vec(), Some(tspan_idx), right);
    }

    let max_id = tspans.iter().map(|t| t.id).max().unwrap_or(0);
    let right_id = max_id + 1;

    let byte_offset: usize = t.content.chars().take(offset).map(|c| c.len_utf8()).sum();
    let mut left = t.clone();
    left.content = t.content[..byte_offset].to_string();
    let mut right = t.clone();
    right.content = t.content[byte_offset..].to_string();
    right.id = right_id;

    let mut result = Vec::with_capacity(tspans.len() + 1);
    result.extend_from_slice(&tspans[..tspan_idx]);
    result.push(left);
    result.push(right);
    result.extend_from_slice(&tspans[tspan_idx + 1..]);
    (result, Some(tspan_idx), Some(tspan_idx + 1))
}

/// Split tspans so that the character range `[char_start, char_end)` of
/// the concatenated content is covered exactly by a contiguous run of
/// tspans. Returns `(new_tspans, first_idx, last_idx)` with the
/// first/last indices inclusive, both `None` when the range is empty.
///
/// Panics if `char_start > char_end` or `char_end` exceeds the total
/// content length.
pub fn split_range(
    tspans: &[Tspan],
    char_start: usize,
    char_end: usize,
) -> (Vec<Tspan>, Option<usize>, Option<usize>) {
    assert!(
        char_start <= char_end,
        "split_range: char_start {} > char_end {}",
        char_start,
        char_end
    );
    let total: usize = tspans.iter().map(|t| t.content.chars().count()).sum();
    assert!(
        char_end <= total,
        "split_range: char_end {} exceeds content length {}",
        char_end,
        total
    );

    if char_start == char_end {
        return (tspans.to_vec(), None, None);
    }

    let mut next_id: TspanId = tspans
        .iter()
        .map(|t| t.id)
        .max()
        .map(|m| m + 1)
        .unwrap_or(0);
    let mut result: Vec<Tspan> = Vec::with_capacity(tspans.len() + 2);
    let mut first_idx: Option<usize> = None;
    let mut last_idx: Option<usize> = None;
    let mut cursor = 0usize;

    for t in tspans {
        let len = t.content.chars().count();
        let tspan_start = cursor;
        let tspan_end = cursor + len;
        let overlap_start = char_start.max(tspan_start);
        let overlap_end = char_end.min(tspan_end);

        if overlap_start >= overlap_end {
            result.push(t.clone());
        } else {
            let local_start = overlap_start - tspan_start;
            let local_end = overlap_end - tspan_start;
            let byte_start: usize = t
                .content
                .chars()
                .take(local_start)
                .map(|c| c.len_utf8())
                .sum();
            let byte_end: usize = t
                .content
                .chars()
                .take(local_end)
                .map(|c| c.len_utf8())
                .sum();

            if local_start > 0 {
                let mut prefix = t.clone();
                prefix.content = t.content[..byte_start].to_string();
                // prefix keeps the original id
                result.push(prefix);
            }

            let mut middle = t.clone();
            middle.content = t.content[byte_start..byte_end].to_string();
            if local_start > 0 {
                // middle is the right side of the char_start split → fresh id
                middle.id = next_id;
                next_id += 1;
            }
            let middle_idx = result.len();
            if first_idx.is_none() {
                first_idx = Some(middle_idx);
            }
            last_idx = Some(middle_idx);
            result.push(middle);

            if local_end < len {
                let mut suffix = t.clone();
                suffix.content = t.content[byte_end..].to_string();
                // suffix is the right side of the char_end split → fresh id
                suffix.id = next_id;
                next_id += 1;
                result.push(suffix);
            }
        }

        cursor = tspan_end;
    }

    (result, first_idx, last_idx)
}

/// Merge adjacent tspans with identical resolved override sets, drop
/// empty-content tspans unconditionally. Preserves the "at least one
/// tspan" invariant: if every tspan would collapse to empty, returns a
/// single default tspan.
///
/// The surviving (left) tspan keeps its id; the right tspan's id is
/// dropped.
pub fn merge(tspans: &[Tspan]) -> Vec<Tspan> {
    let filtered: Vec<&Tspan> = tspans.iter().filter(|t| !t.content.is_empty()).collect();
    if filtered.is_empty() {
        return vec![Tspan::default_tspan()];
    }

    let mut result: Vec<Tspan> = Vec::with_capacity(filtered.len());
    for t in filtered {
        match result.last_mut() {
            Some(prev) if attrs_equal(prev, t) => {
                prev.content.push_str(&t.content);
            }
            _ => {
                result.push(t.clone());
            }
        }
    }
    result
}

/// Returns `true` when the two tspans share identical override sets
/// (every optional field equal). Content and id are ignored.
fn attrs_equal(a: &Tspan, b: &Tspan) -> bool {
    a.baseline_shift == b.baseline_shift
        && a.dx == b.dx
        && a.font_family == b.font_family
        && a.font_size == b.font_size
        && a.font_style == b.font_style
        && a.font_variant == b.font_variant
        && a.font_weight == b.font_weight
        && a.jas_aa_mode == b.jas_aa_mode
        && a.jas_fractional_widths == b.jas_fractional_widths
        && a.jas_kerning_mode == b.jas_kerning_mode
        && a.jas_no_break == b.jas_no_break
        && a.letter_spacing == b.letter_spacing
        && a.line_height == b.line_height
        && a.rotate == b.rotate
        && a.style_name == b.style_name
        && a.text_decoration == b.text_decoration
        && a.text_rendering == b.text_rendering
        && a.text_transform == b.text_transform
        && a.transform == b.transform
        && a.xml_lang == b.xml_lang
}

#[cfg(test)]
mod tests {
    use super::*;

    // Absolute path to the shared test-fixture root.
    const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../test_fixtures");

    fn load(path: &str) -> serde_json::Value {
        let full = format!("{}/{}", FIXTURES, path);
        let raw = std::fs::read_to_string(&full)
            .unwrap_or_else(|e| panic!("read {}: {}", full, e));
        serde_json::from_str(&raw).unwrap_or_else(|e| panic!("parse {}: {}", full, e))
    }

    fn parse_tspans(v: &serde_json::Value) -> Vec<Tspan> {
        serde_json::from_value(v.clone()).expect("parse tspan list")
    }

    fn opt_usize(v: &serde_json::Value) -> Option<usize> {
        v.as_u64().map(|n| n as usize)
    }

    // ── default_tspan ───────────────────────────────────────────────

    #[test]
    fn default_tspan_returns_empty_with_id_zero() {
        let file = load("algorithms/tspan_default.json");
        let vectors = file["vectors"].as_array().unwrap();
        for v in vectors {
            let expected: Tspan = serde_json::from_value(v["expected"].clone()).unwrap();
            let got = Tspan::default_tspan();
            assert_eq!(got, expected, "vector {}", v["name"]);
            assert_eq!(got.id, 0);
            assert!(got.content.is_empty());
            assert!(got.has_no_overrides());
        }
    }

    // ── concat_content ──────────────────────────────────────────────

    #[test]
    fn concat_content_matches_fixtures() {
        let file = load("algorithms/tspan_concat_content.json");
        let vectors = file["vectors"].as_array().unwrap();
        for v in vectors {
            let tspans = parse_tspans(&v["tspans"]);
            let expected = v["expected"].as_str().unwrap();
            assert_eq!(concat_content(&tspans), expected, "vector {}", v["name"]);
        }
    }

    // ── split ───────────────────────────────────────────────────────

    #[test]
    fn split_matches_fixtures() {
        let file = load("algorithms/tspan_split.json");
        let vectors = file["vectors"].as_array().unwrap();
        for v in vectors {
            let input = &v["input"];
            let tspans = parse_tspans(&input["tspans"]);
            let idx = input["tspan_idx"].as_u64().unwrap() as usize;
            let offset = input["offset"].as_u64().unwrap() as usize;

            let (got, got_left, got_right) = split(&tspans, idx, offset);

            let expected = &v["expected"];
            let expected_tspans = parse_tspans(&expected["tspans"]);
            let expected_left = opt_usize(&expected["left_idx"]);
            let expected_right = opt_usize(&expected["right_idx"]);

            assert_eq!(got, expected_tspans, "vector {} tspans", v["name"]);
            assert_eq!(got_left, expected_left, "vector {} left_idx", v["name"]);
            assert_eq!(got_right, expected_right, "vector {} right_idx", v["name"]);
        }
    }

    // ── split_range ─────────────────────────────────────────────────

    #[test]
    fn split_range_matches_fixtures() {
        let file = load("algorithms/tspan_split_range.json");
        let vectors = file["vectors"].as_array().unwrap();
        for v in vectors {
            let input = &v["input"];
            let tspans = parse_tspans(&input["tspans"]);
            let start = input["char_start"].as_u64().unwrap() as usize;
            let end = input["char_end"].as_u64().unwrap() as usize;

            let (got, got_first, got_last) = split_range(&tspans, start, end);

            let expected = &v["expected"];
            let expected_tspans = parse_tspans(&expected["tspans"]);
            let expected_first = opt_usize(&expected["first_idx"]);
            let expected_last = opt_usize(&expected["last_idx"]);

            assert_eq!(got, expected_tspans, "vector {} tspans", v["name"]);
            assert_eq!(got_first, expected_first, "vector {} first_idx", v["name"]);
            assert_eq!(got_last, expected_last, "vector {} last_idx", v["name"]);
        }
    }

    // ── merge ───────────────────────────────────────────────────────

    #[test]
    fn merge_matches_fixtures() {
        let file = load("algorithms/tspan_merge.json");
        let vectors = file["vectors"].as_array().unwrap();
        for v in vectors {
            let input_tspans = parse_tspans(&v["input"]["tspans"]);
            let expected_tspans = parse_tspans(&v["expected"]["tspans"]);
            let got = merge(&input_tspans);
            assert_eq!(got, expected_tspans, "vector {}", v["name"]);
        }
    }

    // ── resolve_id ──────────────────────────────────────────────────

    #[test]
    fn resolve_id_matches_fixtures() {
        let file = load("algorithms/tspan_resolve_id.json");
        let vectors = file["vectors"].as_array().unwrap();
        for v in vectors {
            let input = &v["input"];
            let tspans = parse_tspans(&input["tspans"]);
            let id = input["id"].as_u64().unwrap() as TspanId;

            let got = resolve_id(&tspans, id);
            let expected = opt_usize(&v["expected"]);

            assert_eq!(got, expected, "vector {}", v["name"]);
        }
    }

    // ── Hand-written sanity tests that don't depend on fixtures ─────

    #[test]
    fn split_preserves_attribute_overrides_on_both_sides() {
        let original = Tspan {
            id: 0,
            content: "Hello".to_string(),
            font_weight: Some("bold".to_string()),
            ..Tspan::default_tspan()
        };
        let (got, _left, _right) = split(&[original.clone()], 0, 2);
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].font_weight.as_deref(), Some("bold"));
        assert_eq!(got[1].font_weight.as_deref(), Some("bold"));
        assert_eq!(got[0].content, "He");
        assert_eq!(got[1].content, "llo");
        assert_eq!(got[0].id, 0);
        assert_eq!(got[1].id, 1);
    }

    #[test]
    fn merge_preserves_attribute_overrides() {
        let a = Tspan {
            id: 0,
            content: "A".to_string(),
            font_weight: Some("bold".to_string()),
            ..Tspan::default_tspan()
        };
        let b = Tspan {
            id: 1,
            content: "B".to_string(),
            font_weight: Some("bold".to_string()),
            ..Tspan::default_tspan()
        };
        let got = merge(&[a, b]);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].content, "AB");
        assert_eq!(got[0].font_weight.as_deref(), Some("bold"));
        assert_eq!(got[0].id, 0);
    }

    #[test]
    fn merge_does_not_combine_different_overrides() {
        let a = Tspan {
            id: 0,
            content: "A".to_string(),
            font_weight: Some("bold".to_string()),
            ..Tspan::default_tspan()
        };
        let b = Tspan {
            id: 1,
            content: "B".to_string(),
            font_weight: Some("normal".to_string()),
            ..Tspan::default_tspan()
        };
        let got = merge(&[a, b]);
        assert_eq!(got.len(), 2);
    }

    #[test]
    fn resolve_id_after_merge_loses_right_id() {
        let a = Tspan {
            id: 0,
            content: "A".to_string(),
            ..Tspan::default_tspan()
        };
        let b = Tspan {
            id: 3,
            content: "B".to_string(),
            ..Tspan::default_tspan()
        };
        let merged = merge(&[a, b]);
        assert_eq!(resolve_id(&merged, 0), Some(0));
        assert_eq!(resolve_id(&merged, 3), None);
    }
}
