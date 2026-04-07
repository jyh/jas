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
public func layoutText(_ content: String,
                       maxWidth: Double,
                       fontSize: Double,
                       measure: (String) -> Double) -> TextLayout {
    let lineHeight = fontSize
    let ascent = fontSize * 0.8

    let chars = Array(content)
    let n = chars.count

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
        let token = String(chars[idx..<end])
        let tokenW = measure(token)

        if isWs {
            for k in 0..<(end - idx) {
                let cw = measure(String(chars[idx + k]))
                addGlyph(idx + k, lineNo, x, cw)
                x += cw
            }
            idx = end
        } else {
            if maxWidth > 0.0 && x + tokenW > maxWidth && x > 0.0 {
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
            if maxWidth > 0.0 && tokenW > maxWidth && x == 0.0 {
                // Char-by-char break for an over-long token.
                for k in 0..<(end - idx) {
                    let cw = measure(String(chars[idx + k]))
                    if x + cw > maxWidth && x > 0.0 {
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
                    let cw = measure(String(chars[idx + k]))
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
