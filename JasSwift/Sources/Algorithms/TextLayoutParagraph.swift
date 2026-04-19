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
            current = ParagraphSegment(
                charStart: cursor, charEnd: cursor,
                leftIndent: t.jasLeftIndent ?? 0,
                rightIndent: t.jasRightIndent ?? 0,
                firstLineIndent: t.textIndent ?? 0,
                spaceBefore: t.jasSpaceBefore ?? 0,
                spaceAfter: t.jasSpaceAfter ?? 0,
                textAlign: textAlignFrom(t.textAlign, isArea: isArea))
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
