import Foundation

// MARK: - The conformance corpus's fixed-width text measurer
//
// `test_fixtures/algorithms/{text_layout,text_layout_paragraph,
// path_text_layout}.json` each carry a `char_width` field, and every
// roundtrip binary is expected to inject "this many units per character"
// as its `measure` closure. Before this file existed the closure was
// written inline three times per port, and the two active ports had
// drifted apart on what "per character" MEANS: Rust counted Unicode
// scalars (`chars().count()`) while Swift counted grapheme clusters
// (`s.count`). For ASCII those coincide, so the drift went unseen.
//
// The unit is fixed by the reference implementation, not by either port:
// `jas/tools/algorithm_roundtrip.py` injects `len(s) * char_width`, and
// `len` on a Python `str` counts **Unicode scalar values** (code points).
// Measured on the reference at this commit, with `char_width = 10`:
// "ae\u{301}b" (4 scalars, 3 grapheme clusters) measures 40, and the ZWJ
// family emoji U+1F468 U+200D U+1F469 U+200D U+1F467 (5 scalars, 1
// grapheme cluster) measures 50.
//
// So: **scalars**. Every roundtrip binary routes its `measure` through
// the helper below so a future edit cannot re-open the drift at one of
// three call sites without the guard in
// `scripts/cross_language_algorithms.py` naming the line.

/// The corpus `measure` closure: `charWidth` units per Unicode scalar.
public func fixedCharWidthMeasure(_ charWidth: Double) -> (String) -> Double {
    { s in Double(s.unicodeScalars.count) * charWidth }
}
