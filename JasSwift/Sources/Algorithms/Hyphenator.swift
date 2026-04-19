import Foundation

/// Knuth-Liang hyphenation algorithm.
///
/// Pure-Swift implementation of the Knuth-Liang word hyphenation
/// algorithm as used in TeX. Given a word and a TeX-style pattern
/// list (e.g. `2'2`, `1ad`, `2bc1d`), returns the set of valid
/// break points (1-based char indices, where breaks[i] means
/// "break is allowed between chars i-1 and i").
///
/// The pattern format follows TeX's hyphenation patterns: each
/// pattern is a string of letters interleaved with digits. A `.`
/// at the start means "word start"; a `.` at the end means "word
/// end". Digits between letters are priorities; the highest
/// priority at each inter-character position wins. Odd priorities
/// mark break points; even priorities suppress them.
///
/// Phase 9: ships with a small en-US pattern subset for testing
/// (full TeX dictionary is a follow-up packaging task). The
/// algorithm itself works with any pattern list a caller loads.

/// Compute valid break positions in `word` per the given patterns.
/// Returns a `[Bool]` of length `word.count + 1`, where
/// `breaks[i] == true` means a break is permitted between chars
/// `i-1` and `i`. Indices 0 and `word.count` are always false (no
/// break before first or after last char). Patterns are case-folded;
/// the input word is lowercased for matching.
///
/// `minBefore` and `minAfter` enforce the dialog's "After First N
/// letters" / "Before Last N letters" constraints — break points
/// within the first `minBefore` or last `minAfter` characters are
/// suppressed.
public func hyphenate(_ word: String, patterns: [String],
                      minBefore: Int, minAfter: Int) -> [Bool] {
    let chars = Array(word)
    let n = chars.count
    if n == 0 { return [] }
    var levels = [UInt8](repeating: 0, count: n + 1)
    let lower = word.lowercased()
    let padded = "." + lower + "."
    let paddedChars = Array(padded)
    for pat in patterns {
        let (letters, digits) = splitPattern(pat)
        if letters.isEmpty { continue }
        let patChars = Array(letters)
        let pn = patChars.count
        if pn > paddedChars.count { continue }
        for start in 0...(paddedChars.count - pn) {
            if Array(paddedChars[start..<start + pn]) == patChars {
                for (i, lvl) in digits.enumerated() {
                    if lvl == 0 { continue }
                    let paddedPos = start + i
                    if paddedPos == 0 || paddedPos > n { continue }
                    let unpaddedPos = paddedPos - 1
                    if unpaddedPos > n { continue }
                    if levels[unpaddedPos] < lvl {
                        levels[unpaddedPos] = lvl
                    }
                }
            }
        }
    }
    var breaks = [Bool](repeating: false, count: n + 1)
    let upper = max(0, n - minAfter)
    for i in 0...n {
        if i < minBefore || i > upper { continue }
        if levels[i] % 2 == 1 {
            breaks[i] = true
        }
    }
    return breaks
}

/// Split a TeX hyphenation pattern into its letter sequence and
/// the per-position digit list. `2'2` -> letters="'", digits=[2,2,2]
/// (digit at position 0, between, after). The digit array has
/// length `letters.count + 1`; positions with no digit in the
/// pattern get 0.
public func splitPattern(_ pat: String) -> (String, [UInt8]) {
    var letters = ""
    var digits: [UInt8] = []
    var pendingDigit: UInt8? = nil
    for c in pat {
        if let v = c.asciiValue, v >= 0x30, v <= 0x39 {
            pendingDigit = v - 0x30
        } else {
            digits.append(pendingDigit ?? 0)
            pendingDigit = nil
            letters.append(c)
        }
    }
    digits.append(pendingDigit ?? 0)
    return (letters, digits)
}

/// A small en-US pattern set sufficient for unit tests and a rough
/// demonstration. Sourced from a tiny subset of the TeX `hyphen.tex`
/// patterns. A full dictionary (~4500 patterns) landing as a packaged
/// resource is tracked separately — production callers should load the
/// full set instead of this.
public let enUsPatternsSample: [String] = [
    "1ti", "2tion", "1men", "2ment", "1ness", "2ness",
    "3able", "1able",
    ".un1", ".re1", ".dis1", ".pre1", ".pro1",
    "2bl", "2br", "2cl", "2cr", "2dr", "2fl", "2fr", "2gl",
    "2gr", "2pl", "2pr", "2sc", "2sl", "2sm", "2sn", "2sp",
    "2st", "2sw", "2tr", "2tw", "2wr",
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
]
