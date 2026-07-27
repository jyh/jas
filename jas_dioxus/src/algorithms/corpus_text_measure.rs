//! The conformance corpus's fixed-width text measurer.
//!
//! `test_fixtures/algorithms/{text_layout,text_layout_paragraph,
//! path_text_layout}.json` each carry a `char_width` field, and every
//! roundtrip binary is expected to inject "this many units per character"
//! as its `measure` closure. Before this module existed the closure was
//! written inline three times per port, and the two active ports had
//! drifted apart on what "per character" MEANS: Rust counted Unicode
//! scalars while Swift counted grapheme clusters. For ASCII those
//! coincide, so the drift went unseen.
//!
//! The unit is fixed by the reference implementation, not by either port:
//! `jas/tools/algorithm_roundtrip.py` injects `len(s) * char_width`, and
//! `len` on a Python `str` counts **Unicode scalar values** (code points).
//! Measured on the reference at this commit, with `char_width = 10`:
//! `"ae\u{301}b"` (4 scalars, 3 grapheme clusters) measures 40, and the
//! ZWJ family emoji `U+1F468 U+200D U+1F469 U+200D U+1F467` (5 scalars,
//! 1 grapheme cluster) measures 50.
//!
//! So: **scalars**. Every roundtrip binary routes its `measure` through
//! the helper below so a future edit cannot re-open the drift at one of
//! three call sites without the guard in
//! `scripts/cross_language_algorithms.py` naming the line.

/// The corpus `measure` closure: `char_width` units per Unicode scalar.
pub fn fixed_char_width_measure(char_width: f64) -> impl Fn(&str) -> f64 {
    move |s: &str| s.chars().count() as f64 * char_width
}

#[cfg(test)]
mod tests {
    use super::*;

    // The three vectors below are the ones where scalars and grapheme
    // clusters disagree; every expected value is the reference's
    // `len(s) * char_width`, quoted in the module doc above.

    #[test]
    fn ascii_measures_one_unit_per_letter() {
        let m = fixed_char_width_measure(10.0);
        assert_eq!(m("hello"), 50.0);
    }

    #[test]
    fn combining_mark_counts_as_its_own_unit() {
        let m = fixed_char_width_measure(10.0);
        // 'a', 'e', U+0301 COMBINING ACUTE, 'b' = 4 scalars / 3 clusters.
        assert_eq!(m("ae\u{301}b"), 40.0);
    }

    #[test]
    fn zwj_sequence_counts_every_scalar() {
        let m = fixed_char_width_measure(10.0);
        // MAN ZWJ WOMAN ZWJ GIRL = 5 scalars / 1 cluster.
        assert_eq!(m("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"), 50.0);
    }

    #[test]
    fn char_width_scales_linearly() {
        // Guards the multiply as well as the count: a helper that ignored
        // char_width would still pass the three cases above at width 10.
        let m = fixed_char_width_measure(2.5);
        assert_eq!(m("ae\u{301}b"), 10.0);
    }
}
