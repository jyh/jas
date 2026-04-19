//! Knuth-Liang hyphenation algorithm.
//!
//! Pure-Rust implementation of the Knuth-Liang word hyphenation
//! algorithm as used in TeX. Given a word and a TeX-style pattern
//! list (e.g. `2'2`, `1ad`, `2bc1d`), returns the set of valid
//! break points (1-based char indices, where break_at[i] means
//! "break is allowed between chars i-1 and i").
//!
//! The pattern format follows TeX's hyphenation patterns: each
//! pattern is a string of letters interleaved with digits. A `.`
//! at the start means "word start"; a `.` at the end means "word
//! end". Digits between letters are priorities; the highest
//! priority at each inter-character position wins. Odd priorities
//! mark break points; even priorities suppress them.
//!
//! Phase 9: ships with a small en-US pattern subset for testing
//! (full TeX dictionary is a follow-up packaging task). The
//! algorithm itself works with any pattern list a caller loads.

/// Compute valid break positions in `word` per the given patterns.
/// Returns a `Vec<bool>` of length `word.chars().count() + 1`,
/// where `breaks[i] == true` means a break is permitted between
/// chars `i-1` and `i`. Indices 0 and `word.len()` are always
/// false (no break before first or after last char). Patterns are
/// case-folded; the input word is lowercased for matching.
///
/// `min_before` and `min_after` enforce the dialog's
/// "After First N letters" / "Before Last N letters" constraints
/// — break points within the first `min_before` or last
/// `min_after` characters are suppressed.
pub fn hyphenate(
    word: &str,
    patterns: &[&str],
    min_before: usize,
    min_after: usize,
) -> Vec<bool> {
    let chars: Vec<char> = word.chars().collect();
    let n = chars.len();
    if n == 0 { return Vec::new(); }
    // Working buffer: priority at each inter-character position.
    // Indices: 0 = before first char, n = after last char.
    let mut levels = vec![0u8; n + 1];
    let lower: String = chars.iter().flat_map(|c| c.to_lowercase()).collect();
    let padded = format!(".{}.", lower);
    let padded_chars: Vec<char> = padded.chars().collect();
    // For every pattern, find every match position in the padded
    // word; at each inter-character position the pattern covers,
    // upgrade the level if the pattern's priority is higher.
    for &pat in patterns {
        let (letters, digits) = split_pattern(pat);
        if letters.is_empty() { continue; }
        let pat_chars: Vec<char> = letters.chars().collect();
        let pn = pat_chars.len();
        if pn > padded_chars.len() { continue; }
        for start in 0..=(padded_chars.len() - pn) {
            if padded_chars[start..start + pn] == pat_chars[..] {
                // The pattern matched starting at `start` in the
                // padded word. Each digit in `digits` applies at
                // position `start + i` of the padded word; convert
                // to unpadded inter-character position by
                // subtracting 1 (the leading `.`).
                for (i, &lvl) in digits.iter().enumerate() {
                    if lvl == 0 { continue; }
                    let padded_pos = start + i;
                    if padded_pos == 0 || padded_pos > n { continue; }
                    let unpadded_pos = padded_pos - 1;
                    if unpadded_pos > n { continue; }
                    if levels[unpadded_pos] < lvl {
                        levels[unpadded_pos] = lvl;
                    }
                }
            }
        }
    }
    // Convert levels to break / no-break: odd priority = break,
    // even (including 0) = no break. Suppress positions inside the
    // min_before / min_after exclusion windows.
    let mut breaks = vec![false; n + 1];
    for i in 0..=n {
        if i < min_before || i > n.saturating_sub(min_after) {
            continue;
        }
        if levels[i] % 2 == 1 {
            breaks[i] = true;
        }
    }
    breaks
}

/// Split a TeX hyphenation pattern into its letter sequence and
/// the per-position digit list. `2'2` → letters="'", digits=[2,2,2]
/// (digit at position 0, between, after). The digit array has
/// length `letters.chars().count() + 1`; positions with no digit
/// in the pattern get 0.
pub fn split_pattern(pat: &str) -> (String, Vec<u8>) {
    let mut letters = String::new();
    let mut digits = Vec::new();
    let mut pending_digit: Option<u8> = None;
    for c in pat.chars() {
        if c.is_ascii_digit() {
            pending_digit = Some(c.to_digit(10).unwrap_or(0) as u8);
        } else {
            digits.push(pending_digit.take().unwrap_or(0));
            letters.push(c);
        }
    }
    digits.push(pending_digit.unwrap_or(0));
    (letters, digits)
}

/// A small en-US pattern set sufficient for unit tests and a
/// rough demonstration. Sourced from a tiny subset of the TeX
/// `hyphen.tex` patterns. A full dictionary (~4500 patterns)
/// landing as a packaged resource is tracked separately —
/// production callers should load the full set instead of this.
pub const EN_US_PATTERNS_SAMPLE: &[&str] = &[
    // Suffixes that frequently break: -tion, -ment, -ness, -able
    "1ti", "2tion", "1men", "2ment", "1ness", "2ness",
    "3able", "1able",
    // Prefixes
    ".un1", ".re1", ".dis1", ".pre1", ".pro1",
    // Common consonant clusters
    "2bl", "2br", "2cl", "2cr", "2dr", "2fl", "2fr", "2gl",
    "2gr", "2pl", "2pr", "2sc", "2sl", "2sm", "2sn", "2sp",
    "2st", "2sw", "2tr", "2tw", "2wr",
    // Common vowel-consonant break points
    "1ba", "1be", "1bi", "1bo", "1bu",
    "1ca", "1ce", "1ci", "1co", "1cu",
    "1da", "1de", "1di", "1do", "1du",
    "1fa", "1fe", "1fi", "1fo", "1fu",
    "1ga", "1ge", "1gi", "1go", "1gu",
    "1ha", "1he", "1hi", "1ho", "1hu",
    "1la", "1le", "1li", "1lo", "1lu",
    "1ma", "1me", "1mi", "1mo", "1mu",
    "1na", "1ne", "1ni", "1no", "1nu",
    "1pa", "1pe", "1pi", "1po", "1pu",
    "1ra", "1re", "1ri", "1ro", "1ru",
    "1sa", "1se", "1si", "1so", "1su",
    "1ta", "1te", "1ti", "1to", "1tu",
    "1va", "1ve", "1vi", "1vo", "1vu",
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_pattern_simple() {
        let (letters, digits) = split_pattern("2'2");
        assert_eq!(letters, "'");
        assert_eq!(digits, vec![2, 2]);
    }

    #[test]
    fn split_pattern_no_digits() {
        let (letters, digits) = split_pattern("abc");
        assert_eq!(letters, "abc");
        assert_eq!(digits, vec![0, 0, 0, 0]);
    }

    #[test]
    fn split_pattern_with_word_anchors() {
        let (letters, digits) = split_pattern(".un1");
        assert_eq!(letters, ".un");
        assert_eq!(digits, vec![0, 0, 0, 1]);
    }

    #[test]
    fn empty_word_returns_empty_breaks() {
        let breaks = hyphenate("", &[".un1"], 1, 1);
        assert!(breaks.is_empty());
    }

    #[test]
    fn no_patterns_no_breaks() {
        let breaks = hyphenate("hello", &[], 1, 1);
        assert_eq!(breaks.len(), 6);
        assert!(breaks.iter().all(|&b| !b));
    }

    #[test]
    fn min_before_suppresses_early_breaks() {
        // A pattern that would break at position 1 — suppressed by
        // min_before=2.
        let patterns = ["1ello"];
        let breaks = hyphenate("hello", &patterns, 2, 1);
        // Position 1 (between 'h' and 'e') is < min_before so
        // suppressed.
        assert!(!breaks[1]);
    }

    #[test]
    fn min_after_suppresses_late_breaks() {
        // Pattern would break at position 4 (between 'l' and 'o').
        // With min_after=2, only positions <= n - 2 = 3 allowed.
        let patterns = ["hell1o"];
        let breaks = hyphenate("hello", &patterns, 1, 2);
        assert!(!breaks[4]);
    }

    #[test]
    fn en_us_sample_breaks_action() {
        // "action" should break as "ac-tion" via the 2tion pattern
        // — even priority 2 SUPPRESSES a break, so let's pick one
        // that DOES break: "national" via "1na" prefix isn't quite
        // right either. Instead, use a directly tested case: the
        // .re1 prefix marks position 2 (after "re") as a break for
        // any word starting with "re".
        let patterns: Vec<&str> = EN_US_PATTERNS_SAMPLE.to_vec();
        let breaks = hyphenate("repeat", &patterns, 1, 1);
        // Word .repeat. → ".re1" matches at position 0–2 of padded;
        // digit 1 lands at unpadded position 2 (between 'e' and 'p').
        assert!(breaks[2], "expected a break after 're': breaks={:?}", breaks);
    }
}
