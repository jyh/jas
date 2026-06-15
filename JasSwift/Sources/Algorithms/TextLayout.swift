import Foundation

// MARK: - Pure word-wrap text layout
//
// Mirrors `text_layout.rs` / `text_layout.ml` / `text_layout.py`. Given a
// string, an optional max width, a font size, and a measurer closure, lay
// out glyphs into lines and expose cursor/hit-test queries. The layout is
// driven entirely from char indices (Swift `Character` count) and the
// caller-supplied measurer — there is no AppKit dependency, so the same
// code is exercised by host-side tests with a deterministic stub measurer.

public struct TextGlyph {
    public let idx: Int
    public let line: Int
    public let x: Double
    public let right: Double
    public let baselineY: Double
    public let top: Double
    public let height: Double
    public var isTrailingSpace: Bool
}

public struct LineInfo {
    public let start: Int
    public let end: Int
    public let hardBreak: Bool
    public let top: Double
    public let baselineY: Double
    public let height: Double
    public let width: Double
    /// Index range into `TextLayout.glyphs` for this line. Filled in
    /// at the end of `layoutText` so cursor/hit_test can slice in
    /// O(line) instead of filtering the whole glyph vector.
    public var glyphStart: Int = 0
    public var glyphEnd: Int = 0
    /// True when the line was wrapped at a hyphenation breakpoint
    /// inside a word — the renderer must append a visible hyphen
    /// glyph at the line's end. The synthetic hyphen advance is
    /// already baked into the line's last visible glyph's `right`.
    public var trailingHyphen: Bool = false
}

public struct TextLayout {
    public let glyphs: [TextGlyph]
    public let lines: [LineInfo]
    public let fontSize: Double
    public let charCount: Int
}

private func isSpaceChar(_ c: Character) -> Bool {
    // Match Rust's `char::is_whitespace` (Unicode-aware). Any Character
    // whose scalars are all whitespace counts; \n is handled separately
    // as a hard break before this is consulted.
    c != "\n" && c.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
}

/// Run word-wrap layout on `content`. `maxWidth <= 0` disables wrapping.
///
/// `perCharWidths`, when provided, is a width-per-character array
/// (`content.count` entries) used in lieu of `measure` for individual
/// glyph and token widths. This is what lets the layout track tspan-
/// override fonts (e.g. a bold range produces wider glyphs) so that
/// downstream selection-highlight rectangles still align with the
/// rendered text. `measure` stays in the signature for the no-override
/// fast path and as the fallback when `perCharWidths` is `nil`.
public func layoutText(_ content: String,
                       maxWidth: Double,
                       fontSize: Double,
                       measure: (String) -> Double,
                       perCharWidths: [Double]? = nil,
                       firstLineExtra: Double = 0.0) -> TextLayout {
    let lineHeight = fontSize
    let ascent = fontSize * 0.8

    let chars = Array(content)
    let n = chars.count

    // First line is shifted right by `firstLineExtra` (positive for
    // indent; the negative-hanging case is handled by the segment
    // caller). To keep the first line from running past the right edge
    // we narrow the wrap width for line 0 only. Mirrors python's
    // `_line_max` in text_layout.py.
    func lineMax(_ ln: Int) -> Double {
        if maxWidth <= 0.0 { return maxWidth }
        if ln == 0 && firstLineExtra > 0.0 {
            return max(0.0, maxWidth - firstLineExtra)
        }
        return maxWidth
    }

    // Resolve per-character widths up front so the layout below can
    // index into a flat array regardless of which path the caller
    // populated. When the caller's array is wrong-length (transform
    // changed the char count) fall back to the measure closure.
    let widths: [Double] = {
        if let w = perCharWidths, w.count == n { return w }
        return chars.map { measure(String($0)) }
    }()
    func tokenWidth(_ start: Int, _ end: Int) -> Double {
        var sum = 0.0
        for k in start..<end { sum += widths[k] }
        return sum
    }

    var glyphs: [TextGlyph] = []
    var lines: [LineInfo] = []

    var idx = 0
    var lineNo = 0
    var lineStart = 0
    var x: Double = 0.0

    func pushLine(_ start: Int, _ end: Int, _ hardBreak: Bool, _ width: Double) {
        let top = Double(lineNo) * lineHeight
        lines.append(LineInfo(start: start, end: end, hardBreak: hardBreak,
                              top: top, baselineY: top + ascent,
                              height: lineHeight, width: width))
    }

    func addGlyph(_ i: Int, _ ln: Int, _ gx: Double, _ gw: Double) {
        let top = Double(ln) * lineHeight
        glyphs.append(TextGlyph(idx: i, line: ln, x: gx, right: gx + gw,
                                baselineY: top + ascent, top: top, height: lineHeight,
                                isTrailingSpace: false))
    }

    while idx < n {
        let c = chars[idx]
        if c == "\n" {
            pushLine(lineStart, idx, true, x)
            lineNo += 1
            lineStart = idx + 1
            x = 0.0
            idx += 1
            continue
        }

        let isWs = isSpaceChar(c)
        var end = idx + 1
        while end < n && chars[end] != "\n" && (isSpaceChar(chars[end]) == isWs) {
            end += 1
        }
        let tokenW = tokenWidth(idx, end)

        if isWs {
            for k in 0..<(end - idx) {
                let cw = widths[idx + k]
                addGlyph(idx + k, lineNo, x, cw)
                x += cw
            }
            idx = end
        } else {
            if maxWidth > 0.0 && x + tokenW > lineMax(lineNo) && x > 0.0 {
                // Mark trailing whitespace glyphs on the current line.
                for gi in 0..<glyphs.count {
                    if glyphs[gi].line == lineNo && isSpaceChar(chars[glyphs[gi].idx]) {
                        glyphs[gi].isTrailingSpace = true
                    }
                }
                pushLine(lineStart, idx, false, x)
                lineNo += 1
                lineStart = idx
                x = 0.0
            }
            if maxWidth > 0.0 && tokenW > lineMax(lineNo) && x == 0.0 {
                // Char-by-char break for an over-long token.
                for k in 0..<(end - idx) {
                    let cw = widths[idx + k]
                    if x + cw > lineMax(lineNo) && x > 0.0 {
                        pushLine(lineStart, idx + k, false, x)
                        lineNo += 1
                        lineStart = idx + k
                        x = 0.0
                    }
                    addGlyph(idx + k, lineNo, x, cw)
                    x += cw
                }
            } else {
                var curX = x
                for k in 0..<(end - idx) {
                    let cw = widths[idx + k]
                    addGlyph(idx + k, lineNo, curX, cw)
                    curX += cw
                }
                x = curX
            }
            idx = end
        }
    }

    pushLine(lineStart, n, false, x)
    if lines.isEmpty {
        lines.append(LineInfo(start: 0, end: 0, hardBreak: false,
                              top: 0, baselineY: ascent, height: lineHeight, width: 0))
    }
    // Sweep glyphs once to fill line glyph ranges. Glyphs are emitted
    // in line order so a single pass suffices.
    var gi = 0
    for li in 0..<lines.count {
        lines[li].glyphStart = gi
        while gi < glyphs.count && glyphs[gi].line == li { gi += 1 }
        lines[li].glyphEnd = gi
    }
    return TextLayout(glyphs: glyphs, lines: lines, fontSize: fontSize, charCount: n)
}

/// Hyphenation options for greedy (non-justify) layout. When passed
/// to `layoutTextWithHyphen`, the layout will try to break long
/// words at hyphenation candidates instead of wrapping the whole
/// word to the next line.
public struct HyphenOpts {
    public var minWord: Int
    public var minBefore: Int
    public var minAfter: Int
    /// When false, words starting with an uppercase letter are
    /// excluded from hyphenation (proper-noun protection).
    public var allowCapitalized: Bool

    public init(minWord: Int, minBefore: Int, minAfter: Int,
                allowCapitalized: Bool) {
        self.minWord = minWord
        self.minBefore = minBefore
        self.minAfter = minAfter
        self.allowCapitalized = allowCapitalized
    }
}

/// Variant of [`layoutText`] that consults hyphenation patterns when
/// a non-whitespace token doesn't fit on the current line. Used by
/// `layoutTextWithParagraphs` for non-justify segments where
/// `seg.hyphenate` is set.
///
/// Picks the *largest* prefix that still leaves room for a hyphen,
/// greedy-style. If no break fits, falls through to the standard
/// wrap-before-token. Words shorter than `minWord` chars and (when
/// `!allowCapitalized`) words starting with uppercase are skipped.
/// Sets `LineInfo.trailingHyphen = true` on the line where the
/// break occurred so the renderer can draw the visible hyphen.
public func layoutTextWithHyphen(_ content: String,
                                 maxWidth: Double,
                                 fontSize: Double,
                                 opts: HyphenOpts,
                                 measure: (String) -> Double,
                                 firstLineExtra: Double = 0.0) -> TextLayout {
    let lineHeight = fontSize
    let ascent = fontSize * 0.8
    let chars = Array(content)
    let n = chars.count
    var glyphs: [TextGlyph] = []
    var lines: [LineInfo] = []
    var idx = 0
    var lineNo = 0
    var lineStart = 0
    var x: Double = 0

    // Narrow line 0's wrap width when the first line is indented, so the
    // first line breaks earlier instead of overflowing the right edge.
    // Mirrors python's `_line_max` in text_layout.py.
    func lineMax(_ ln: Int) -> Double {
        if maxWidth <= 0.0 { return maxWidth }
        if ln == 0 && firstLineExtra > 0.0 {
            return max(0.0, maxWidth - firstLineExtra)
        }
        return maxWidth
    }

    func pushLine(_ start: Int, _ end: Int, _ hardBreak: Bool, _ width: Double,
                  _ trailingHyphen: Bool) {
        let top = Double(lineNo) * lineHeight
        var info = LineInfo(start: start, end: end, hardBreak: hardBreak,
                            top: top, baselineY: top + ascent,
                            height: lineHeight, width: width)
        info.trailingHyphen = trailingHyphen
        lines.append(info)
    }
    func addGlyph(_ i: Int, _ ln: Int, _ gx: Double, _ gw: Double) {
        let top = Double(ln) * lineHeight
        glyphs.append(TextGlyph(idx: i, line: ln, x: gx, right: gx + gw,
                                baselineY: top + ascent, top: top,
                                height: lineHeight, isTrailingSpace: false))
    }

    while idx < n {
        let c = chars[idx]
        if c == "\n" {
            pushLine(lineStart, idx, true, x, false)
            lineNo += 1
            lineStart = idx + 1
            x = 0
            idx += 1
            continue
        }
        let isWs = isSpaceChar(c)
        var end = idx + 1
        while end < n && chars[end] != "\n" && (isSpaceChar(chars[end]) == isWs) {
            end += 1
        }
        if isWs {
            for k in 0..<(end - idx) {
                let cw = measure(String(chars[idx + k]))
                addGlyph(idx + k, lineNo, x, cw)
                x += cw
            }
            idx = end
            continue
        }
        let token = String(chars[idx..<end])
        let tokenW = measure(token)
        if maxWidth > 0 && x + tokenW > lineMax(lineNo) && x > 0 {
            // Hyphenation: try to split the token at a hyphenation
            // breakpoint that fits on the current line. Picks the
            // *largest* prefix that still leaves room for the hyphen,
            // greedy-style. If no break fits, falls through to the
            // standard wrap below.
            var hyphenSplit: (Int, Double)? = nil
            let tokenChars = Array(token)
            let startsCapital = tokenChars.first?.isUppercase ?? false
            let allowed = tokenChars.count >= opts.minWord
                && (opts.allowCapitalized || !startsCapital)
            if allowed {
                let breaks = hyphenate(token, patterns: enUsPatternsSample,
                                       minBefore: opts.minBefore,
                                       minAfter: opts.minAfter)
                let hyphenW = measure("-")
                let avail = lineMax(lineNo) - x
                // Try the largest valid break point first.
                for bi in stride(from: tokenChars.count - 1, through: 1, by: -1) {
                    if bi >= breaks.count || !breaks[bi] { continue }
                    let prefix = String(tokenChars[..<bi])
                    let prefixW = measure(prefix)
                    if prefixW + hyphenW <= avail {
                        hyphenSplit = (bi, prefixW)
                        break
                    }
                }
            }
            if let (splitAt, _) = hyphenSplit {
                // Emit prefix glyphs on the current line, then the
                // synthetic hyphen, then wrap.
                for k in 0..<splitAt {
                    let cw = measure(String(tokenChars[k]))
                    addGlyph(idx + k, lineNo, x, cw)
                    x += cw
                }
                let hyphenW = measure("-")
                // Synthetic hyphen carries idx = split point so hit-
                // test still maps to a real char. The renderer
                // recognises trailingHyphen on the line and draws the
                // visible '-' here.
                addGlyph(idx + splitAt, lineNo, x, hyphenW)
                let lineW = x + hyphenW
                pushLine(lineStart, idx + splitAt, false, lineW, true)
                lineNo += 1
                lineStart = idx + splitAt
                x = 0
                idx = idx + splitAt
                // Place the tail at x=0 (or char-by-char if it overflows).
                let tailChars = Array(tokenChars[splitAt...])
                let tailW = tailChars.reduce(0.0) { $0 + measure(String($1)) }
                if maxWidth > 0 && tailW > lineMax(lineNo) {
                    for (k, ch) in tailChars.enumerated() {
                        let cw = measure(String(ch))
                        if x + cw > lineMax(lineNo) && x > 0 {
                            pushLine(lineStart, idx + k, false, x, false)
                            lineNo += 1
                            lineStart = idx + k
                            x = 0
                        }
                        addGlyph(idx + k, lineNo, x, cw)
                        x += cw
                    }
                } else {
                    var curX = x
                    for (k, ch) in tailChars.enumerated() {
                        let cw = measure(String(ch))
                        addGlyph(idx + k, lineNo, curX, cw)
                        curX += cw
                    }
                    x = curX
                }
                idx = end
                continue
            }
            // No hyphenation break fits — standard wrap-before-token.
            for gi in 0..<glyphs.count {
                if glyphs[gi].line == lineNo
                    && isSpaceChar(chars[glyphs[gi].idx]) {
                    glyphs[gi].isTrailingSpace = true
                }
            }
            pushLine(lineStart, idx, false, x, false)
            lineNo += 1
            lineStart = idx
            x = 0
        }
        if maxWidth > 0 && tokenW > lineMax(lineNo) && x == 0 {
            // Char-by-char break for an over-long token.
            for k in 0..<(end - idx) {
                let cw = measure(String(chars[idx + k]))
                if x + cw > lineMax(lineNo) && x > 0 {
                    pushLine(lineStart, idx + k, false, x, false)
                    lineNo += 1
                    lineStart = idx + k
                    x = 0
                }
                addGlyph(idx + k, lineNo, x, cw)
                x += cw
            }
        } else {
            var curX = x
            for k in 0..<(end - idx) {
                let cw = measure(String(chars[idx + k]))
                addGlyph(idx + k, lineNo, curX, cw)
                curX += cw
            }
            x = curX
        }
        idx = end
    }
    pushLine(lineStart, n, false, x, false)
    if lines.isEmpty {
        var info = LineInfo(start: 0, end: 0, hardBreak: false,
                            top: 0, baselineY: ascent, height: lineHeight,
                            width: 0)
        info.trailingHyphen = false
        lines.append(info)
    }
    var gi = 0
    for li in 0..<lines.count {
        lines[li].glyphStart = gi
        while gi < glyphs.count && glyphs[gi].line == li { gi += 1 }
        lines[li].glyphEnd = gi
    }
    return TextLayout(glyphs: glyphs, lines: lines, fontSize: fontSize, charCount: n)
}

public extension TextLayout {
    /// Visual line containing `cursor`.
    func lineForCursor(_ cursor: Int) -> Int {
        let nLines = lines.count
        for i in 0..<nLines {
            let l = lines[i]
            if cursor < l.end { return i }
            if cursor == l.end {
                if l.hardBreak { return i }
                if i == nLines - 1 { return i }
                return i + 1
            }
        }
        return nLines - 1
    }

    /// (x, baselineY, height) for the caret at `cursor`.
    func cursorXY(_ cursor: Int) -> (Double, Double, Double) {
        let cur = min(cursor, charCount)
        let lineNo = lineForCursor(cur)
        let line = lines[lineNo]
        let h = line.height
        let by = line.baselineY
        if cur == line.start { return (0, by, h) }
        let lineGlyphs = glyphs[line.glyphStart..<line.glyphEnd]
        if cur >= line.end {
            return (lineGlyphs.last?.right ?? 0, by, h)
        }
        for g in lineGlyphs where g.idx == cur {
            return (g.x, by, h)
        }
        return (0, by, h)
    }

    func glyphsOnLine(_ lineNo: Int) -> [TextGlyph] {
        let l = lines[lineNo]
        return glyphs[l.glyphStart..<l.glyphEnd].filter { !$0.isTrailingSpace }
    }

    /// Map a (x, y) point in layout-local coordinates to a char cursor.
    func hitTest(_ x: Double, _ y: Double) -> Int {
        if lines.isEmpty { return 0 }
        var lineNo = lines.count - 1
        for i in 0..<lines.count {
            if y < lines[i].top + lines[i].height { lineNo = i; break }
        }
        let line = lines[lineNo]
        let gs = glyphsOnLine(lineNo)
        guard let first = gs.first else { return line.start }
        if x <= first.x { return line.start }
        for g in gs {
            let mid = (g.x + g.right) / 2
            if x < mid { return g.idx }
        }
        let last = gs.last!
        let lastVisible = last.idx + 1
        if line.hardBreak { return line.end }
        return max(line.start, min(lastVisible, line.end))
    }

    func cursorAtLineX(_ lineNo: Int, _ targetX: Double) -> Int {
        let line = lines[lineNo]
        let gs = glyphsOnLine(lineNo)
        guard let first = gs.first else { return line.start }
        if targetX <= first.x { return line.start }
        for g in gs {
            let mid = (g.x + g.right) / 2
            if targetX < mid { return g.idx }
        }
        return line.end
    }

    func cursorUp(_ cursor: Int) -> Int {
        let lineNo = lineForCursor(cursor)
        if lineNo == 0 { return 0 }
        let (x, _, _) = cursorXY(cursor)
        return cursorAtLineX(lineNo - 1, x)
    }

    func cursorDown(_ cursor: Int) -> Int {
        let lineNo = lineForCursor(cursor)
        if lineNo + 1 >= lines.count { return charCount }
        let (x, _, _) = cursorXY(cursor)
        return cursorAtLineX(lineNo + 1, x)
    }
}

/// Return `(min(a, b), max(a, b))`.
public func orderedRange(_ a: Int, _ b: Int) -> (Int, Int) {
    a <= b ? (a, b) : (b, a)
}

// MARK: - Phase 5 paragraph-aware layout

/// Horizontal alignment within a paragraph's effective box (the
/// box width minus left/right indents). Phase 10 lights up `.justify`
/// (area-text only — point text and text-on-path coerce back to
/// `.left` in `textAlignFrom`).
public enum TextAlign: Equatable {
    case left, center, right, justify
}

/// Per-paragraph layout constraints derived from the wrapper tspan
/// attributes (or panel defaults when there is no wrapper). All
/// indent / space values are in pixels.
public struct ParagraphSegment: Equatable {
    public var charStart: Int
    public var charEnd: Int
    public var leftIndent: Double
    public var rightIndent: Double
    /// `text-indent` — additional x offset on the *first* line only.
    /// Signed; negative produces a hanging indent. Phase 5 supports
    /// non-negative values; negative falls back to 0. Ignored when
    /// `listStyle` is non-nil per PARAGRAPH.md §Marker rendering.
    public var firstLineIndent: Double
    /// `jas:space-before` — extra vertical gap above this paragraph.
    /// Always 0 for the first paragraph in the element.
    public var spaceBefore: Double
    public var spaceAfter: Double
    public var textAlign: TextAlign
    /// `jas:list-style` — Phase 6. When non-nil, the paragraph is a
    /// list item: layout pushes every line by an extra `markerGap`
    /// (so the marker has room before the text) and ignores
    /// `firstLineIndent`. The marker glyph itself is drawn at
    /// `x = leftIndent` by the renderer.
    public var listStyle: String?
    /// Gap between marker and text. Phase 6 uses a fixed 12pt per
    /// PARAGRAPH.md §Marker rendering.
    public var markerGap: Double
    /// `jas:hanging-punctuation` — Phase 7. When true, hangable
    /// punctuation chars at line start / end offset outside the
    /// effective edge by their own advance width per PARAGRAPH.md
    /// §Hanging Punctuation. Alignment interaction: left-aligned
    /// hangs only left side, right-aligned only right side,
    /// centered both.
    public var hangingPunctuation: Bool
    // ── Phase 10: Justification dialog soft constraints ──
    /// `jas:word-spacing-{min,desired,max}` as percentages of a
    /// natural space. Defaults 80 / 100 / 133 per PARAGRAPH.md
    /// §Reset Panel. Used by `.justify` to derive glue stretch /
    /// shrink for the every-line composer.
    public var wordSpacingMin: Double
    public var wordSpacingDesired: Double
    public var wordSpacingMax: Double
    /// `text-align-last` mapped from the wrapper attr. Only consulted
    /// when `textAlign == .justify`. The last line aligns per this
    /// value; `.justify` flushes the last line to both edges
    /// (JUSTIFY_ALL).
    public var lastLineAlign: TextAlign
    // ── Phase 10: Hyphenation dialog wiring ──
    public var hyphenate: Bool
    public var hyphenateMinWord: Int
    public var hyphenateMinBefore: Int
    public var hyphenateMinAfter: Int
    /// 0 (Better Spacing) ... 6 (Fewer Hyphens). Maps to per-hyphen
    /// penalty value in the composer.
    public var hyphenateBias: Int
    /// `jas:hyphenate-capitalized` — when false (the default in
    /// Illustrator / InDesign / Word), proper nouns and other
    /// words starting with an uppercase letter are NOT broken at
    /// hyphenation candidates. Avoids breaks like "T-rump".
    public var hyphenateCapitalized: Bool

    public init(charStart: Int = 0, charEnd: Int = 0,
                leftIndent: Double = 0, rightIndent: Double = 0,
                firstLineIndent: Double = 0,
                spaceBefore: Double = 0, spaceAfter: Double = 0,
                textAlign: TextAlign = .left,
                listStyle: String? = nil, markerGap: Double = 0,
                hangingPunctuation: Bool = false,
                wordSpacingMin: Double = 80,
                wordSpacingDesired: Double = 100,
                wordSpacingMax: Double = 133,
                lastLineAlign: TextAlign = .left,
                hyphenate: Bool = false,
                hyphenateMinWord: Int = 6,
                hyphenateMinBefore: Int = 2,
                hyphenateMinAfter: Int = 2,
                hyphenateBias: Int = 0,
                hyphenateCapitalized: Bool = false) {
        self.charStart = charStart
        self.charEnd = charEnd
        self.leftIndent = leftIndent
        self.rightIndent = rightIndent
        self.firstLineIndent = firstLineIndent
        self.spaceBefore = spaceBefore
        self.spaceAfter = spaceAfter
        self.textAlign = textAlign
        self.listStyle = listStyle
        self.markerGap = markerGap
        self.hangingPunctuation = hangingPunctuation
        self.wordSpacingMin = wordSpacingMin
        self.wordSpacingDesired = wordSpacingDesired
        self.wordSpacingMax = wordSpacingMax
        self.lastLineAlign = lastLineAlign
        self.hyphenate = hyphenate
        self.hyphenateMinWord = hyphenateMinWord
        self.hyphenateMinBefore = hyphenateMinBefore
        self.hyphenateMinAfter = hyphenateMinAfter
        self.hyphenateBias = hyphenateBias
        self.hyphenateCapitalized = hyphenateCapitalized
    }
}

/// True if `c` may hang into the *left* margin per PARAGRAPH.md
/// §Hanging Punctuation. Straight quotes hang either side; the
/// curly directional variants hang only on their matching side.
public func isLeftHanger(_ c: Character) -> Bool {
    switch c {
    case "\"", "'",                                     // straight quotes (both)
         "\u{201C}", "\u{2018}",                        // " ' (left curly)
         "\u{00AB}", "\u{2039}",                        // « ‹
         "(", "[", "{":
        return true
    default: return false
    }
}

/// True if `c` may hang into the *right* margin per PARAGRAPH.md
/// §Hanging Punctuation. Periods, commas, close quotes / brackets
/// always qualify when at end-of-line; dashes qualify only at
/// end-of-line (the layout consults this only on last visible
/// glyph so the EOL constraint is implicit).
public func isRightHanger(_ c: Character) -> Bool {
    switch c {
    case "\"", "'",                                     // straight quotes (both)
         "\u{201D}", "\u{2019}",                        // " ' (right curly)
         "\u{00BB}", "\u{203A}",                        // » ›
         ")", "]", "}",
         ".", ",",
         "-", "\u{2013}", "\u{2014}":                   // - – —
        return true
    default: return false
    }
}

/// Visible width of a line: max `right` of any non-trailing-space glyph.
private func trimmedLineWidth(_ line: LineInfo, _ glyphs: [TextGlyph]) -> Double {
    var w: Double = 0
    for g in glyphs[line.glyphStart..<line.glyphEnd] {
        if !g.isTrailingSpace && g.right > w { w = g.right }
    }
    return w
}

/// Paragraph-aware layout. For each segment lays out the covered
/// slice with the segment's effective wrap width
/// (`maxWidth - leftIndent - rightIndent`), inserts spaceBefore /
/// spaceAfter vertical gaps between paragraphs (the very first
/// paragraph's spaceBefore is always skipped per PARAGRAPH.md
/// §SVG attribute mapping), shifts the first line by
/// firstLineIndent, and applies the segment's horizontal alignment.
///
/// `paragraphs` must be ordered by `charStart`; gaps between
/// segments and content past the last segment fall back to a
/// default paragraph (left-aligned, no indents, no extra spacing).
/// When `paragraphs` is empty the entire content is treated as one
/// default paragraph — equivalent to calling `layoutText`.
///
/// Phase 5: alignment supports `.left` / `.center` / `.right`. The
/// four `JUSTIFY_*` modes fall back to `.left`.
public func layoutTextWithParagraphs(_ content: String,
                                     maxWidth: Double,
                                     fontSize: Double,
                                     paragraphs: [ParagraphSegment],
                                     measure: (String) -> Double,
                                     perCharWidths: [Double]? = nil) -> TextLayout {
    let chars = Array(content)
    let n = chars.count
    let lineHeight = fontSize
    let ascent = fontSize * 0.8

    // Build the effective segment list: gap-fill so every char is
    // covered exactly once.
    var segs: [ParagraphSegment] = []
    var cursor = 0
    for p in paragraphs {
        let start = max(p.charStart, cursor); let s = min(start, n)
        let end = min(max(p.charEnd, s), n)
        if s > cursor {
            segs.append(ParagraphSegment(charStart: cursor, charEnd: s))
        }
        if end > s {
            var seg = p
            seg.charStart = s; seg.charEnd = end
            segs.append(seg)
        }
        cursor = end
    }
    if cursor < n {
        segs.append(ParagraphSegment(charStart: cursor, charEnd: n))
    }
    if segs.isEmpty {
        segs.append(ParagraphSegment(charStart: 0, charEnd: n))
    }

    var allGlyphs: [TextGlyph] = []
    var allLines: [LineInfo] = []
    var yOffset: Double = 0

    for (pi, seg) in segs.enumerated() {
        if pi > 0 { yOffset += seg.spaceBefore }
        let slice = String(chars[seg.charStart..<seg.charEnd])
        // Phase 6: an active list adds markerGap to the effective
        // left indent (so the marker has room before the text) AND
        // suppresses firstLineIndent — the marker already occupies
        // the first-line position so a separate first-line offset
        // would push the text away from the marker.
        let hasList = seg.listStyle != nil
        let listIndent: Double = hasList ? seg.markerGap : 0
        let effectiveMax: Double = maxWidth > 0
            ? max(0, maxWidth - seg.leftIndent - listIndent - seg.rightIndent) : 0
        // Negative firstLineIndent (hanging indent) shifts the first
        // line LEFT of the left-indent edge — keep the sign so the
        // per-line offset can hang. `lineMax` inside the inner layout
        // only narrows when this is positive, so hanging indents do
        // not change the wrap decision. Mirrors python's
        // `first_line_extra` in layout_with_paragraphs.
        let firstLineExtra: Double = hasList ? 0 : seg.firstLineIndent
        // Phase 10: justify segments go through the every-line
        // composer instead of greedy first-fit. Falls back to greedy
        // when the composer can't find a feasible composition.
        let para: TextLayout
        // Slice the per-char widths to match this paragraph's content.
        let segWidths: [Double]? = perCharWidths.map {
            Array($0[seg.charStart..<seg.charEnd])
        }
        if seg.textAlign == .justify && effectiveMax > 0 {
            // Justify dispatch is nested (not folded into one `if`)
            // so that a nil composer result falls back to PLAIN
            // layout — never to the hyphenating greedy path. Folding
            // the optional binding into the justify `if` would let a
            // nil result drop through to `else if seg.hyphenate` and
            // wrongly hyphenate a justify segment. Mirrors python's
            // nested justify-then-plain fallback in
            // layout_with_paragraphs.
            if let kp = justifyLayoutSegment(slice, maxWidth: effectiveMax,
                                              fontSize: fontSize, seg: seg,
                                              measure: measure,
                                              firstLineExtra: firstLineExtra) {
                para = kp
            } else {
                para = layoutText(slice, maxWidth: effectiveMax,
                                  fontSize: fontSize, measure: measure,
                                  perCharWidths: segWidths,
                                  firstLineExtra: firstLineExtra)
            }
        } else if seg.hyphenate && effectiveMax > 0 {
            // Plain (non-justify) layout supports hyphenation via a
            // greedy break-at-largest-fitting-prefix path. Without
            // this, seg.hyphenate had no effect on left-aligned text
            // because plain `layoutText` didn't consult patterns.
            let opts = HyphenOpts(minWord: seg.hyphenateMinWord,
                                  minBefore: seg.hyphenateMinBefore,
                                  minAfter: seg.hyphenateMinAfter,
                                  allowCapitalized: seg.hyphenateCapitalized)
            para = layoutTextWithHyphen(slice, maxWidth: effectiveMax,
                                        fontSize: fontSize, opts: opts,
                                        measure: measure,
                                        firstLineExtra: firstLineExtra)
        } else {
            para = layoutText(slice, maxWidth: effectiveMax,
                              fontSize: fontSize, measure: measure,
                              perCharWidths: segWidths,
                              firstLineExtra: firstLineExtra)
        }
        let firstLineNoInCombined = allLines.count
        let linesN = para.lines.count
        // A segment may span multiple sub-paragraphs (the user typed
        // "a\nb\nc" then applied panel attrs — one wrapper covers all
        // three). spaceBefore / spaceAfter are paragraph attributes,
        // so they must apply between each sub-paragraph too, not just
        // between top-level segments. Accumulates as we cross hard
        // breaks within the segment.
        var subParaDelta: Double = 0
        for (li, line) in para.lines.enumerated() {
            if li > 0 && para.lines[li - 1].hardBreak {
                subParaDelta += seg.spaceAfter + seg.spaceBefore
            }
            let xShift = seg.leftIndent + listIndent + (li == 0 ? firstLineExtra : 0)
            let lineAvail: Double = effectiveMax > 0
                ? max(0, effectiveMax - (li == 0 ? firstLineExtra : 0)) : 0
            let visibleW = trimmedLineWidth(line, para.glyphs)
            // Phase 7: hanging punctuation. Offset hangable chars
            // at line start / end outside the effective edge per
            // PARAGRAPH.md §Hanging Punctuation. Alignment per
            // spec: left-aligned hangs only left, right-aligned
            // only right, centered both.
            var leftHangW: Double = 0
            var rightHangW: Double = 0
            if seg.hangingPunctuation {
                // Justify is treated like Left/Center for left-edge
                // hangs: the body composer stretches the line to fill
                // the max width, but the leading punctuation should
                // still hang into the margin so the visible left edge
                // of the paragraph is straight. Right hangs on Justify
                // body lines need composer support and stay disabled.
                let allowLeft = seg.textAlign == .left
                    || seg.textAlign == .center
                    || seg.textAlign == .justify
                let allowRight = seg.textAlign == .right || seg.textAlign == .center
                if allowLeft, let g = para.glyphs[line.glyphStart..<line.glyphEnd]
                       .first(where: { !$0.isTrailingSpace }) {
                    let c = chars[seg.charStart + g.idx]
                    if isLeftHanger(c) { leftHangW = g.right - g.x }
                }
                if allowRight, let g = para.glyphs[line.glyphStart..<line.glyphEnd]
                       .reversed().first(where: { !$0.isTrailingSpace }) {
                    let c = chars[seg.charStart + g.idx]
                    if isRightHanger(c) { rightHangW = g.right - g.x }
                }
            }
            let effectiveVisibleW = max(0, visibleW - leftHangW - rightHangW)
            // For a justified segment the body lines are stretched to
            // fill the line width by the composer, so a Justify-arm
            // shift of 0 leaves them flush with both edges. The LAST
            // line is *not* stretched (composer convention), so it
            // needs to be positioned per `seg.lastLineAlign` —
            // otherwise justify_right / justify_center / justify_left
            // all visually look like left-aligned.
            let isLastLineOfSegment = li + 1 == linesN
            let effectiveAlign: TextAlign =
                (seg.textAlign == .justify && isLastLineOfSegment)
                    ? seg.lastLineAlign
                    : seg.textAlign
            let alignShift: Double
            switch effectiveAlign {
            case .left, .justify: alignShift = -leftHangW
            case .center:
                alignShift = lineAvail > effectiveVisibleW
                    ? (lineAvail - effectiveVisibleW) / 2 - leftHangW
                    : -leftHangW
            case .right:
                alignShift = lineAvail > effectiveVisibleW
                    ? lineAvail - effectiveVisibleW : 0
            }
            let totalShift = xShift + alignShift
            let origStart = seg.charStart + line.start
            let origEnd = seg.charStart + line.end
            let baseline = yOffset + line.baselineY + subParaDelta
            let top = yOffset + line.top + subParaDelta
            let glyphStart = allGlyphs.count
            for g in para.glyphs[line.glyphStart..<line.glyphEnd] {
                allGlyphs.append(TextGlyph(
                    idx: seg.charStart + g.idx,
                    line: firstLineNoInCombined + li,
                    x: g.x + totalShift,
                    right: g.right + totalShift,
                    baselineY: g.baselineY + yOffset + subParaDelta,
                    top: g.top + yOffset + subParaDelta,
                    height: g.height,
                    isTrailingSpace: g.isTrailingSpace))
            }
            let glyphEnd = allGlyphs.count
            var info = LineInfo(start: origStart, end: origEnd,
                                hardBreak: line.hardBreak,
                                top: top, baselineY: baseline,
                                height: line.height,
                                width: visibleW + totalShift)
            info.glyphStart = glyphStart
            info.glyphEnd = glyphEnd
            info.trailingHyphen = line.trailingHyphen
            allLines.append(info)
        }
        if !para.lines.isEmpty {
            yOffset += Double(para.lines.count) * lineHeight + subParaDelta
        }
        yOffset += seg.spaceAfter
    }

    if allLines.isEmpty {
        // Empty content — keep the single-empty-line invariant.
        var info = LineInfo(start: 0, end: 0, hardBreak: false,
                            top: 0, baselineY: ascent, height: lineHeight, width: 0)
        info.glyphStart = 0; info.glyphEnd = 0
        allLines.append(info)
    }

    return TextLayout(glyphs: allGlyphs, lines: allLines,
                      fontSize: fontSize, charCount: n)
}

// MARK: - Phase 10: Justify path via Knuth-Plass composer

/// Map the dialog bias slider (0..6) to a KP penalty value.
/// 0 = Better Spacing (cheap hyphens), 6 = Fewer Hyphens (expensive).
/// Linear interpolation over [50, 1000].
private func hyphenPenaltyFromBias(_ bias: Int) -> Double {
    50 + Double(min(max(bias, 0), 6)) * (950.0 / 6.0)
}

/// Justify-mode line layout via the every-line composer. Returns nil
/// when no feasible composition exists (caller falls back to greedy
/// first-fit). Mirrors `justify_layout` in jas_dioxus.
func justifyLayoutSegment(_ content: String, maxWidth: Double,
                          fontSize: Double, seg: ParagraphSegment,
                          measure: (String) -> Double,
                          firstLineExtra: Double = 0.0) -> TextLayout? {
    let lineHeight = fontSize
    let ascent = fontSize * 0.8
    let chars = Array(content)
    let n = chars.count
    if n == 0 {
        var info = LineInfo(start: 0, end: 0, hardBreak: false,
                            top: 0, baselineY: ascent,
                            height: lineHeight, width: 0)
        info.glyphStart = 0; info.glyphEnd = 0
        return TextLayout(glyphs: [], lines: [info],
                          fontSize: fontSize, charCount: 0)
    }

    let spaceW = measure(" ")
    let desiredW = spaceW * seg.wordSpacingDesired / 100
    let stretchW = spaceW * (seg.wordSpacingMax - seg.wordSpacingDesired) / 100
    let shrinkW = spaceW * (seg.wordSpacingDesired - seg.wordSpacingMin) / 100
    let hyphenW = measure("-")
    let hyphenPen = hyphenPenaltyFromBias(seg.hyphenateBias)

    // Sub-paragraphs split on '\n'.
    var paraStarts: [Int] = [0]
    for (i, c) in chars.enumerated() where c == "\n" { paraStarts.append(i + 1) }
    paraStarts.append(n + 1)

    var allGlyphs: [TextGlyph] = []
    var allLines: [LineInfo] = []
    var nextLineNo = 0

    for k in 0..<(paraStarts.count - 1) {
        let paraStart = paraStarts[k]
        let paraEndExcl = min(max(0, paraStarts[k + 1] - 1), n)
        if paraStart > n { break }
        let sliceChars = Array(chars[paraStart..<paraEndExcl])

        var items: [KPItem] = []
        var i = 0
        while i < sliceChars.count {
            if sliceChars[i].isWhitespace {
                var j = i
                while j < sliceChars.count && sliceChars[j].isWhitespace { j += 1 }
                items.append(.glue(width: desiredW, stretch: stretchW,
                                   shrink: shrinkW,
                                   charIdx: paraStart + i))
                i = j
                continue
            }
            let wordStart = i
            while i < sliceChars.count && !sliceChars[i].isWhitespace { i += 1 }
            let word = String(sliceChars[wordStart..<i])
            let wordW = measure(word)
            // Hyphenation candidates inside the word. Capitalized
            // words (proper nouns) are excluded unless explicitly
            // allowed — without this, "Trump" hyphenates to
            // "T-rump" via the sample pattern set.
            let startsCapital = word.first?.isUppercase ?? false
            if seg.hyphenate && word.count >= seg.hyphenateMinWord
                && (seg.hyphenateCapitalized || !startsCapital) {
                let breaks = hyphenate(word, patterns: enUsPatternsSample,
                                        minBefore: seg.hyphenateMinBefore,
                                        minAfter: seg.hyphenateMinAfter)
                var cur = 0
                for bi in 0..<breaks.count {
                    if !breaks[bi] || bi == 0 || bi >= breaks.count - 1 { continue }
                    let pre = String(word.dropFirst(cur).prefix(bi - cur))
                    let preW = measure(pre)
                    items.append(.box(width: preW,
                                       charIdx: paraStart + wordStart + cur))
                    items.append(.penalty(width: hyphenW, value: hyphenPen,
                                           flagged: true,
                                           charIdx: paraStart + wordStart + bi))
                    cur = bi
                }
                let tail = String(word.dropFirst(cur))
                items.append(.box(width: measure(tail),
                                   charIdx: paraStart + wordStart + cur))
            } else {
                items.append(.box(width: wordW, charIdx: paraStart + wordStart))
            }
        }
        // End-of-paragraph terminator.
        items.append(.glue(width: 0, stretch: 1e9, shrink: 0,
                           charIdx: paraStart + sliceChars.count))
        items.append(.penalty(width: 0, value: -kpPenaltyInfinity,
                               flagged: false,
                               charIdx: paraStart + sliceChars.count))

        // Only the very first line of the very first sub-paragraph
        // carries the indent — subsequent sub-paragraphs (split on
        // '\n') start a fresh line at the normal left edge. Narrowing
        // line 0 makes the indented first line break earlier instead
        // of overflowing. Mirrors python's `line_widths` in
        // `_justify_layout_segment`. `kpCompose` reuses the last entry
        // for all later lines, so [narrowed, full] applies the narrow
        // width to line 0 and the full width to every line after.
        let lineWidths: [Double] = (k == 0 && firstLineExtra > 0.0)
            ? [max(0.0, maxWidth - firstLineExtra), maxWidth]
            : [maxWidth]
        // Try the strict cap first (Knuth's default 10 = "loose" but
        // typographically acceptable). If no feasible composition
        // exists at that cap, retry with a much looser cap so the
        // paragraph still justifies — falling all the way back to
        // ragged-left would be visually worse than a too-loose body
        // line. Mirrors Illustrator / InDesign behavior of allowing
        // looser spacing rather than abandoning justify entirely.
        let breaksOrNil: [KPBreak]? =
            kpCompose(items: items, lineWidths: lineWidths)
                ?? kpCompose(items: items, lineWidths: lineWidths,
                              opts: KPOpts(maxRatio: 100))
        guard let breaks = breaksOrNil, !breaks.isEmpty else {
            return nil
        }

        var prevBreak: Int? = nil
        let lineCount = breaks.count
        for (lidx, br) in breaks.enumerated() {
            let isLast = lidx == lineCount - 1
            let from = prevBreak.map { $0 + 1 } ?? 0
            let to = br.itemIdx
            var x: Double = 0
            let lineStartChar = items[from].charIdx
            var lineEndChar = items[from].charIdx
            let glyphStart = allGlyphs.count
            let top = Double(nextLineNo) * lineHeight
            let baselineY = top + ascent
            for ii in from...to {
                let item = items[ii]
                let isTrailing = ii == to
                switch item {
                case .box(_, let charIdx):
                    let chunkEnd = ii + 1 < items.count
                        ? items[ii + 1].charIdx : (n + paraStart)
                    var ci = charIdx
                    while ci < min(chunkEnd, paraStart + sliceChars.count) {
                        let ch = chars[ci]
                        let cw = measure(String(ch))
                        allGlyphs.append(TextGlyph(
                            idx: ci, line: nextLineNo,
                            x: x, right: x + cw,
                            baselineY: baselineY, top: top,
                            height: lineHeight,
                            isTrailingSpace: false))
                        x += cw
                        lineEndChar = ci + 1
                        ci += 1
                    }
                case .glue(let gw, let gs, let gz, let charIdx):
                    let runEnd = ii + 1 < items.count
                        ? items[ii + 1].charIdx : (paraStart + sliceChars.count)
                    if isTrailing {
                        var wi = charIdx
                        while wi < runEnd {
                            allGlyphs.append(TextGlyph(
                                idx: wi, line: nextLineNo,
                                x: x, right: x,
                                baselineY: baselineY, top: top,
                                height: lineHeight,
                                isTrailingSpace: true))
                            wi += 1
                        }
                        lineEndChar = runEnd
                    } else {
                        let r: Double
                        if isLast && seg.lastLineAlign != .justify {
                            r = 0
                        } else if isLast && seg.lastLineAlign == .justify {
                            r = lastLineJustifyRatio(items: items, from: from,
                                                      to: to, lineWidth: maxWidth)
                        } else {
                            r = br.ratio
                        }
                        let adj = r >= 0 ? gw + r * gs : gw + r * gz
                        var wi = charIdx
                        var placedFirst = false
                        while wi < runEnd {
                            let cw = !placedFirst ? adj : 0
                            allGlyphs.append(TextGlyph(
                                idx: wi, line: nextLineNo,
                                x: x, right: x + cw,
                                baselineY: baselineY, top: top,
                                height: lineHeight,
                                isTrailingSpace: false))
                            if !placedFirst { x += cw; placedFirst = true }
                            wi += 1
                        }
                        lineEndChar = runEnd
                    }
                case .penalty(let pw, _, _, let charIdx):
                    if isTrailing && pw > 0 {
                        allGlyphs.append(TextGlyph(
                            idx: charIdx, line: nextLineNo,
                            x: x, right: x + pw,
                            baselineY: baselineY, top: top,
                            height: lineHeight,
                            isTrailingSpace: false))
                        x += pw
                    }
                }
            }
            let glyphEnd = allGlyphs.count
            let hardBreak = isLast && paraEndExcl < n && chars[paraEndExcl] == "\n"
            // The renderer needs to draw a visible hyphen at end of
            // line when the composer broke inside a word at a
            // hyphenation penalty. The penalty's `width` is the
            // hyphen advance (already baked into x), and `width > 0`
            // distinguishes a hyphen penalty from the terminator
            // penalty (zero width). Source content has no hyphen at
            // this position, so without the explicit signal the
            // renderer would draw "exam" instead of "exam-".
            let trailingHyphen: Bool = {
                if case .penalty(let pw, _, _, _) = items[to], pw > 0 { return true }
                return false
            }()
            var info = LineInfo(start: lineStartChar, end: lineEndChar,
                                hardBreak: hardBreak,
                                top: top, baselineY: baselineY,
                                height: lineHeight, width: x)
            info.glyphStart = glyphStart
            info.glyphEnd = glyphEnd
            info.trailingHyphen = trailingHyphen
            allLines.append(info)
            nextLineNo += 1
            prevBreak = to
            _ = lineStartChar  // suppress unused warning
        }
    }

    if allLines.isEmpty {
        var info = LineInfo(start: 0, end: 0, hardBreak: false,
                            top: 0, baselineY: ascent,
                            height: lineHeight, width: 0)
        info.glyphStart = 0; info.glyphEnd = 0
        allLines.append(info)
    }

    return TextLayout(glyphs: allGlyphs, lines: allLines,
                      fontSize: fontSize, charCount: n)
}

/// Custom ratio for the last line of a JUSTIFY_ALL paragraph.
/// Excludes the fil-glue terminator so regular inter-word glues
/// stretch / shrink to fill the line.
private func lastLineJustifyRatio(items: [KPItem], from: Int, to: Int,
                                   lineWidth: Double) -> Double {
    var nat: Double = 0
    var stretchTotal: Double = 0
    var shrinkTotal: Double = 0
    for ii in from..<to {  // exclude trailing item `to`
        switch items[ii] {
        case .box(let w, _): nat += w
        case .glue(let w, let s, let z, _):
            if s >= 1e8 { continue }  // fil-glue terminator, ignore
            nat += w
            stretchTotal += s
            shrinkTotal += z
        case .penalty: break
        }
    }
    let slack = lineWidth - nat
    if slack > 0 && stretchTotal > 0 { return slack / stretchTotal }
    if slack < 0 && shrinkTotal > 0 { return slack / shrinkTotal }
    return 0
}
