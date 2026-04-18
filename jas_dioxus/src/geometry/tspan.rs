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

/// Extract the covered slice `[char_start, char_end)` of the input
/// as a fresh tspan list. Each returned tspan carries its source
/// tspan's overrides and id, with `content` truncated to the
/// overlap. Empty range → empty Vec. Out-of-range bounds saturate.
///
/// Building block for tspan-aware clipboard: `copy_range` produces
/// the tspan payload to stash, and `insert_tspans_at` consumes it
/// at paste time.
pub fn copy_range(original: &[Tspan], char_start: usize, char_end: usize) -> Vec<Tspan> {
    if char_start >= char_end {
        return Vec::new();
    }
    let total: usize = original.iter().map(|t| t.content.chars().count()).sum();
    let start = char_start.min(total);
    let end = char_end.min(total);
    if start >= end {
        return Vec::new();
    }

    let mut result = Vec::new();
    let mut cursor = 0usize;
    for t in original {
        let t_len = t.content.chars().count();
        let t_start = cursor;
        let t_end = cursor + t_len;
        let overlap_start = start.max(t_start);
        let overlap_end = end.min(t_end);
        if overlap_start < overlap_end {
            let local_start = overlap_start - t_start;
            let local_end = overlap_end - t_start;
            let byte_start: usize = t.content.chars().take(local_start).map(|c| c.len_utf8()).sum();
            let byte_end: usize = t.content.chars().take(local_end).map(|c| c.len_utf8()).sum();
            let mut cloned = t.clone();
            cloned.content = t.content[byte_start..byte_end].to_string();
            result.push(cloned);
        }
        cursor = t_end;
    }
    result
}

/// Splice `to_insert` into `original` at character position
/// `char_pos`. When `char_pos` lands inside a tspan, that tspan
/// splits around the insertion; when at a boundary, the new tspans
/// slot between neighbours cleanly. Ids on `to_insert` are
/// reassigned to avoid collision with `original`'s ids, so the
/// caller can reuse tspans copied from the same or a different
/// element without worrying about id clashes.
///
/// Runs the final `merge` pass so adjacent tspans whose overrides
/// match collapse automatically.
pub fn insert_tspans_at(
    original: &[Tspan],
    char_pos: usize,
    to_insert: &[Tspan],
) -> Vec<Tspan> {
    // Empty insertion: no-op. Empty-content-only tspans drop out
    // via merge, so treat them as empty too.
    let nonempty = to_insert.iter().any(|t| !t.content.is_empty());
    if !nonempty {
        return original.to_vec();
    }

    // Re-id to_insert to sit above original's max id.
    let base_max = original.iter().map(|t| t.id).max().unwrap_or(0);
    let mut next_id = base_max + 1;
    let reindexed: Vec<Tspan> = to_insert.iter().map(|t| {
        let mut cloned = t.clone();
        cloned.id = next_id;
        next_id += 1;
        cloned
    }).collect();

    // Split original at char_pos into left / right halves.
    let total: usize = original.iter().map(|t| t.content.chars().count()).sum();
    let pos = char_pos.min(total);
    let mut before: Vec<Tspan> = Vec::new();
    let mut after: Vec<Tspan> = Vec::new();
    let mut cursor = 0usize;
    for t in original {
        let t_len = t.content.chars().count();
        let t_end = cursor + t_len;
        if t_end <= pos {
            before.push(t.clone());
        } else if cursor >= pos {
            after.push(t.clone());
        } else {
            let local = pos - cursor;
            let byte: usize = t.content.chars().take(local).map(|c| c.len_utf8()).sum();
            let mut left = t.clone();
            left.content = t.content[..byte].to_string();
            before.push(left);
            // Right half gets a fresh id (max + inserted + 1) to
            // avoid colliding with the left half that keeps the
            // original id.
            let mut right = t.clone();
            right.id = next_id;
            next_id += 1;
            right.content = t.content[byte..].to_string();
            after.push(right);
        }
        cursor = t_end;
    }

    let mut result: Vec<Tspan> =
        Vec::with_capacity(before.len() + reindexed.len() + after.len());
    result.extend(before);
    result.extend(reindexed);
    result.extend(after);
    merge(&result)
}

/// Reconcile a new flat content string back onto the original tspan
/// structure, preserving per-range attribute overrides where possible.
///
/// The unchanged common prefix and suffix (measured in bytes, snapped
/// to UTF-8 char boundaries) keep their original tspan assignments.
/// The changed middle region is absorbed into the first tspan that
/// overlaps it — extending that tspan's content — with subsequent
/// overlapping tspans truncated to their post-middle suffix. The
/// result is passed through `merge` to drop empty tspans and combine
/// adjacent ones whose override sets now match.
///
/// Used by the text-edit session commit path: if the user's edits
/// didn't touch a stretch of text that lived in a bold tspan, that
/// tspan's bold override survives. Any edit that fully replaces a
/// tspan's content collapses its overrides into the neighbour that
/// absorbed the change.
pub fn reconcile_content(original: &[Tspan], new_content: &str) -> Vec<Tspan> {
    let old_content = concat_content(original);
    if old_content == new_content {
        return original.to_vec();
    }
    if original.is_empty() {
        let mut t = Tspan::default_tspan();
        t.content = new_content.to_string();
        return vec![t];
    }

    let old_bytes = old_content.as_bytes();
    let new_bytes = new_content.as_bytes();

    // Longest common prefix (byte-level), snapped to a UTF-8 boundary.
    let max_prefix = old_bytes.len().min(new_bytes.len());
    let mut prefix_len = 0;
    while prefix_len < max_prefix && old_bytes[prefix_len] == new_bytes[prefix_len] {
        prefix_len += 1;
    }
    while prefix_len > 0 && !old_content.is_char_boundary(prefix_len) {
        prefix_len -= 1;
    }

    // Longest common suffix, bounded so it doesn't overlap the prefix.
    let max_suffix = (old_bytes.len() - prefix_len).min(new_bytes.len() - prefix_len);
    let mut suffix_len = 0;
    while suffix_len < max_suffix
        && old_bytes[old_bytes.len() - 1 - suffix_len]
            == new_bytes[new_bytes.len() - 1 - suffix_len]
    {
        suffix_len += 1;
    }
    while suffix_len > 0
        && !old_content.is_char_boundary(old_bytes.len() - suffix_len)
    {
        suffix_len -= 1;
    }

    // Changed region in bytes: old[prefix..old_len-suffix), new[prefix..new_len-suffix).
    let old_mid_start = prefix_len;
    let old_mid_end = old_bytes.len() - suffix_len;
    let new_middle = &new_content[prefix_len..new_bytes.len() - suffix_len];

    // Pure insertion at a boundary (old middle is empty): find the
    // tspan containing old_mid_start and splice new_middle into its
    // content. Keeps all override assignments intact.
    if old_mid_start == old_mid_end {
        let mut result = original.to_vec();
        let mut pos = old_mid_start;
        let mut absorbed = false;
        for tspan in result.iter_mut() {
            let t_len = tspan.content.len();
            if pos <= t_len {
                let mut s = String::with_capacity(t_len + new_middle.len());
                s.push_str(&tspan.content[..pos]);
                s.push_str(new_middle);
                s.push_str(&tspan.content[pos..]);
                tspan.content = s;
                absorbed = true;
                break;
            }
            pos -= t_len;
        }
        if !absorbed {
            if let Some(last) = result.last_mut() {
                last.content.push_str(new_middle);
            } else {
                let mut t = Tspan::default_tspan();
                t.content = new_middle.to_string();
                result.push(t);
            }
        }
        return merge(&result);
    }

    // Replacement (including pure deletion): walk tspans and absorb
    // new_middle into the first tspan that overlaps the changed
    // region. Tspans fully before / after pass through; a tspan
    // fully inside the middle ends up with empty content and is
    // dropped by the subsequent merge pass.
    let mut result: Vec<Tspan> = Vec::with_capacity(original.len() + 1);
    let mut cursor_bytes = 0usize;
    let mut middle_consumed = false;

    for tspan in original {
        let t_start = cursor_bytes;
        let t_end = cursor_bytes + tspan.content.len();

        if t_end <= old_mid_start {
            result.push(tspan.clone());
        } else if t_start >= old_mid_end {
            result.push(tspan.clone());
        } else {
            let before_len = old_mid_start.saturating_sub(t_start);
            let after_off_in_tspan = if t_end > old_mid_end {
                old_mid_end - t_start
            } else {
                tspan.content.len()
            };
            let before = &tspan.content[..before_len];
            let after = if t_end > old_mid_end {
                &tspan.content[after_off_in_tspan..]
            } else {
                ""
            };

            let mut new_tspan_content =
                String::with_capacity(before.len() + after.len() + new_middle.len());
            new_tspan_content.push_str(before);
            if !middle_consumed {
                new_tspan_content.push_str(new_middle);
                middle_consumed = true;
            }
            new_tspan_content.push_str(after);

            if !new_tspan_content.is_empty() {
                let mut new_tspan = tspan.clone();
                new_tspan.content = new_tspan_content;
                result.push(new_tspan);
            }
        }
        cursor_bytes = t_end;
    }

    if result.is_empty() {
        result.push(Tspan::default_tspan());
    }

    merge(&result)
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

    // ── reconcile_content ──────────────────────────────────────

    fn bold(s: &str) -> Tspan {
        Tspan {
            content: s.to_string(),
            font_weight: Some("bold".into()),
            ..Tspan::default_tspan()
        }
    }
    fn plain(s: &str) -> Tspan {
        Tspan { content: s.to_string(), ..Tspan::default_tspan() }
    }

    #[test]
    fn reconcile_identity_passes_through() {
        let tspans = vec![plain("Hello "), bold("world")];
        let r = reconcile_content(&tspans, "Hello world");
        assert_eq!(r, tspans);
    }

    #[test]
    fn reconcile_append_extends_last_tspan() {
        // "Hello world" → "Hello world!": '!' is pure suffix append.
        // The trailing bold "world" absorbs the new '!'.
        let tspans = vec![plain("Hello "), bold("world")];
        let r = reconcile_content(&tspans, "Hello world!");
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "Hello ");
        assert_eq!(r[1].content, "world!");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn reconcile_prepend_extends_first_tspan() {
        let tspans = vec![plain("Hello "), bold("world")];
        let r = reconcile_content(&tspans, "Say Hello world");
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "Say Hello ");
        assert_eq!(r[1].content, "world");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn reconcile_edit_inside_a_tspan_preserves_neighbours() {
        // "Hello world" → "Hellooo world": insert "oo" inside the
        // plain tspan. Bold "world" preserved untouched.
        let tspans = vec![plain("Hello "), bold("world")];
        let r = reconcile_content(&tspans, "Hellooo world");
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "Hellooo ");
        assert!(r[0].font_weight.is_none());
        assert_eq!(r[1].content, "world");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn reconcile_delete_inside_a_tspan() {
        // "Hello world" → "Helo world": drop one 'l' from the plain tspan.
        let tspans = vec![plain("Hello "), bold("world")];
        let r = reconcile_content(&tspans, "Helo world");
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "Helo ");
        assert_eq!(r[1].content, "world");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn reconcile_change_absorbs_into_first_overlapping_tspan() {
        // "Hello world" → "HelloXXworld": the middle " " vanishes,
        // "XX" inserted, touching both tspans. First overlapping
        // (plain "Hello ") absorbs the change.
        let tspans = vec![plain("Hello "), bold("world")];
        let r = reconcile_content(&tspans, "HelloXXworld");
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "HelloXX");
        assert!(r[0].font_weight.is_none());
        assert_eq!(r[1].content, "world");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn reconcile_delete_all_yields_single_default_tspan() {
        let tspans = vec![plain("Hello "), bold("world")];
        let r = reconcile_content(&tspans, "");
        assert_eq!(r.len(), 1);
        assert!(r[0].content.is_empty());
        assert!(r[0].has_no_overrides());
    }

    #[test]
    fn reconcile_full_replacement_collapses_to_single_tspan() {
        // Every char changes → no common prefix / suffix. Middle is
        // the whole new content, absorbed into the first tspan.
        let tspans = vec![plain("abc"), bold("def")];
        let r = reconcile_content(&tspans, "xyz");
        // After merge: one tspan with "xyz" (plus plain's override set).
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].content, "xyz");
    }

    #[test]
    fn reconcile_preserves_utf8_boundaries() {
        // Multibyte chars on each side of the edit: the back-off
        // logic must not split a codepoint.
        let tspans = vec![plain("café "), bold("naïve")];
        let r = reconcile_content(&tspans, "café plus naïve");
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "café plus ");
        assert_eq!(r[1].content, "naïve");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn reconcile_runs_merge_cleanup() {
        // After editing, adjacent tspans with matching overrides
        // collapse via the merge primitive.
        let tspans = vec![plain("a"), plain("b"), bold("C")];
        // Remove the 'C' → merge should collapse "a"+"b" into one tspan.
        let r = reconcile_content(&tspans, "ab");
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].content, "ab");
    }

    // ── copy_range ──────────────────────────────────────────────

    #[test]
    fn copy_range_empty_returns_empty() {
        let tspans = vec![plain("hello")];
        assert!(copy_range(&tspans, 2, 2).is_empty());
        assert!(copy_range(&tspans, 3, 1).is_empty());
    }

    #[test]
    fn copy_range_inside_single_tspan_preserves_overrides() {
        let tspans = vec![bold("bold text")];
        let r = copy_range(&tspans, 5, 9);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].content, "text");
        assert_eq!(r[0].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn copy_range_across_boundary_returns_both_partial_tspans() {
        // "foo" + bold "bar": copy chars 1..5 → "oo" + "ba"
        let tspans = vec![plain("foo"), bold("bar")];
        let r = copy_range(&tspans, 1, 5);
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "oo");
        assert!(r[0].font_weight.is_none());
        assert_eq!(r[1].content, "ba");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn copy_range_end_saturates_to_total() {
        let tspans = vec![plain("hi")];
        let r = copy_range(&tspans, 0, 999);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].content, "hi");
    }

    // ── insert_tspans_at ────────────────────────────────────────

    #[test]
    fn insert_tspans_at_boundary_between_tspans() {
        // "foo" + bold "bar"; insert bold "X" at char_pos=3 (boundary).
        let base = vec![plain("foo"), bold("bar")];
        let ins = vec![bold("X")];
        let r = insert_tspans_at(&base, 3, &ins);
        // Expect: foo | bold X | bold bar → merge collapses boldX+boldbar
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "foo");
        assert_eq!(r[1].content, "Xbar");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn insert_tspans_at_inside_a_tspan_splits() {
        // Plain "hello"; insert bold "X" at char_pos=2.
        let base = vec![plain("hello")];
        let ins = vec![bold("X")];
        let r = insert_tspans_at(&base, 2, &ins);
        // Expect: plain "he" | bold "X" | plain "llo"
        assert_eq!(r.len(), 3);
        assert_eq!(r[0].content, "he");
        assert!(r[0].font_weight.is_none());
        assert_eq!(r[1].content, "X");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
        assert_eq!(r[2].content, "llo");
        assert!(r[2].font_weight.is_none());
    }

    #[test]
    fn insert_tspans_at_prepend_at_position_zero() {
        let base = vec![plain("hello")];
        let ins = vec![bold("Say ")];
        let r = insert_tspans_at(&base, 0, &ins);
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "Say ");
        assert_eq!(r[0].font_weight.as_deref(), Some("bold"));
        assert_eq!(r[1].content, "hello");
    }

    #[test]
    fn insert_tspans_at_append_at_end() {
        let base = vec![plain("hello")];
        let ins = vec![bold("!")];
        let r = insert_tspans_at(&base, 5, &ins);
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "hello");
        assert_eq!(r[1].content, "!");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn insert_tspans_at_reassigns_ids() {
        let base = vec![Tspan { id: 0, content: "abc".into(), ..Tspan::default_tspan() }];
        let ins = vec![
            Tspan { id: 0, content: "X".into(), font_weight: Some("bold".into()),
                    ..Tspan::default_tspan() },
        ];
        let r = insert_tspans_at(&base, 1, &ins);
        // All ids must be distinct.
        let mut ids: Vec<u32> = r.iter().map(|t| t.id).collect();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), r.len());
    }

    #[test]
    fn insert_empty_is_noop() {
        let base = vec![plain("hello")];
        assert_eq!(insert_tspans_at(&base, 2, &[]), base);
        assert_eq!(insert_tspans_at(&base, 2, &[plain("")]), base);
    }

    #[test]
    fn copy_then_insert_roundtrip_preserves_overrides() {
        // "foo" + bold "bar": copy "bar", paste at 0 → bold "bar" + "foo" + bold "bar"
        let base = vec![plain("foo"), bold("bar")];
        let clipboard = copy_range(&base, 3, 6);
        let r = insert_tspans_at(&base, 0, &clipboard);
        assert_eq!(concat_content(&r), "barfoobar");
        // Original bold "bar" preserved; new prefix "bar" also bold via clipboard.
        assert!(r.iter().any(|t| t.content.contains("bar") && t.font_weight.as_deref() == Some("bold")));
    }
}
