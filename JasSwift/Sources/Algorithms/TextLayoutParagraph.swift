/// Build [`ParagraphSegment`] lists from a Text/TextPath's `tspans`.
///
/// A `tspan` whose `jasRole == "paragraph"` is a paragraph wrapper:
/// it carries the per-paragraph attribute set (indent, space, list
/// style, alignment) but no text content. The body tspans that
/// follow it (until the next wrapper or end) make up that paragraph.
///
/// Phase 5: produces segments for the rendering pipeline so
/// `layoutTextWithParagraphs` can apply each paragraph's
/// constraints. When the element has no wrapper tspans the entire
/// content collapses to no segment — the caller falls back to plain
/// `layoutText`.

import Foundation

/// Build a list of paragraph segments from `tspans`. Returns an
/// empty array when no wrapper tspan is present (caller falls back
/// to the default-paragraph layout).
public func buildParagraphSegments(
    tspans: [Tspan],
    content: String,
    isArea: Bool
) -> [ParagraphSegment] {
    let totalChars = content.count
    var segs: [ParagraphSegment] = []
    var cursor = 0
    var current: ParagraphSegment? = nil
    for t in tspans {
        let bodyChars = t.content.count
        if t.jasRole == "paragraph" {
            if var seg = current {
                seg.charEnd = cursor
                if seg.charEnd > seg.charStart { segs.append(seg) }
            }
            // Phase 6: jas:list-style propagates to the segment so
            // the renderer can draw the marker and the layout can
            // shift the text by markerGap.
            let listStyle = t.jasListStyle
            let markerGap: Double = listStyle != nil ? markerGapPt : 0
            current = ParagraphSegment(
                charStart: cursor, charEnd: cursor,
                leftIndent: t.jasLeftIndent ?? 0,
                rightIndent: t.jasRightIndent ?? 0,
                firstLineIndent: t.textIndent ?? 0,
                spaceBefore: t.jasSpaceBefore ?? 0,
                spaceAfter: t.jasSpaceAfter ?? 0,
                textAlign: textAlignFrom(t.textAlign, isArea: isArea),
                listStyle: listStyle, markerGap: markerGap)
        } else {
            cursor += bodyChars
        }
    }
    if var seg = current {
        seg.charEnd = min(cursor, totalChars)
        if seg.charEnd > seg.charStart { segs.append(seg) }
    }
    return segs
}

/// Map the wrapper tspan's `text-align` string to a `TextAlign`.
/// Phase 5 supports `left` / `center` / `right`; the four `justify*`
/// values fall back to `.left` until the composer lands. Point text
/// passes alignment through unchanged — the renderer's text-anchor
/// channel typically takes over for single-line caret positioning.
private func textAlignFrom(_ value: String?, isArea: Bool) -> TextAlign {
    switch value {
    case "center": return .center
    case "right": return .right
    case "justify": return isArea ? .left : .left  // Phase 5 placeholder
    default: return .left
    }
}

// MARK: - Phase 6: list markers + counter run rule

/// Gap between marker and text per PARAGRAPH.md §Marker rendering.
public let markerGapPt: Double = 12.0

/// The literal glyph string that renders as the marker for the
/// given `jas:list-style` value at counter index `counter` (1-based).
/// `bullet-*` styles ignore the counter; `num-*` styles format it
/// per the §Bullets and numbered lists enumeration. Unknown styles
/// return an empty string so the renderer skips drawing.
public func markerText(_ listStyle: String, counter: Int) -> String {
    switch listStyle {
    case "bullet-disc": return "\u{2022}"          // •
    case "bullet-open-circle": return "\u{25CB}"   // ○
    case "bullet-square": return "\u{25A0}"        // ■
    case "bullet-open-square": return "\u{25A1}"   // □
    case "bullet-dash": return "\u{2013}"          // –
    case "bullet-check": return "\u{2713}"         // ✓
    case "num-decimal": return "\(counter)."
    case "num-lower-alpha": return "\(toAlpha(counter, upper: false))."
    case "num-upper-alpha": return "\(toAlpha(counter, upper: true))."
    case "num-lower-roman": return "\(toRoman(counter, upper: false))."
    case "num-upper-roman": return "\(toRoman(counter, upper: true))."
    default: return ""
    }
}

/// 1 → "a", 2 → "b", ... 26 → "z", 27 → "aa", 28 → "ab", ...
public func toAlpha(_ n: Int, upper: Bool) -> String {
    if n <= 0 { return "" }
    let base: UInt8 = upper ? 0x41 : 0x61
    var v = n
    var bytes: [UInt8] = []
    while v > 0 {
        v -= 1
        bytes.append(base + UInt8(v % 26))
        v /= 26
    }
    return String(bytes: bytes.reversed(), encoding: .ascii) ?? ""
}

/// 1 → "i", 4 → "iv", 9 → "ix", 1990 → "mcmxc". Above 3999 falls
/// back to "(N)" since standard Roman tops out at MMMCMXCIX.
public func toRoman(_ n: Int, upper: Bool) -> String {
    if n <= 0 { return "" }
    if n > 3999 { return "(\(n))" }
    let pairs: [(Int, String, String)] = [
        (1000, "M", "m"), (900, "CM", "cm"),
        (500, "D", "d"),  (400, "CD", "cd"),
        (100, "C", "c"),  (90, "XC", "xc"),
        (50, "L", "l"),   (40, "XL", "xl"),
        (10, "X", "x"),   (9, "IX", "ix"),
        (5, "V", "v"),    (4, "IV", "iv"),
        (1, "I", "i"),
    ]
    var v = n
    var out = ""
    for (val, u, l) in pairs {
        while v >= val {
            out += upper ? u : l
            v -= val
        }
    }
    return out
}

/// Compute the 1-based counter for each numbered-list paragraph in
/// `segs`, in order. Bullet and non-list paragraphs get 0. Per
/// PARAGRAPH.md §Counter run rule: consecutive paragraphs with the
/// same `num-*` list style continue counting; a different style or
/// a bullet / no-style paragraph breaks the run, and the next
/// `num-*` paragraph starts again at 1 (even with the same style).
public func computeCounters(_ segs: [ParagraphSegment]) -> [Int] {
    var counters: [Int] = []
    counters.reserveCapacity(segs.count)
    var prevNum: String? = nil
    var current = 0
    for seg in segs {
        if let style = seg.listStyle, style.hasPrefix("num-") {
            if prevNum == style {
                current += 1
            } else {
                current = 1
            }
            counters.append(current)
            prevNum = style
        } else {
            counters.append(0)
            prevNum = nil
            current = 0
        }
    }
    return counters
}
