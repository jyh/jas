/// Pure-function primitives over tspan lists.
///
/// Mirrors `jas_dioxus/src/geometry/tspan.rs`. See TSPAN.md Primitives
/// for the language-agnostic design. Shared fixtures in
/// `test_fixtures/algorithms/tspan_*.json` verify parity with Rust.
///
/// Every primitive is a pure function: it takes a tspan list and
/// returns a new list; inputs are never mutated. Matches the value-
/// type representation of Tspan.

import Foundation

// MARK: - resolve_id

/// Return the current index of the tspan with `id`, or `nil` when no
/// such tspan exists (e.g. dropped by `mergeTspans`). O(n).
public func resolveTspanId(_ tspans: [Tspan], id: UInt32) -> Int? {
    tspans.firstIndex { $0.id == id }
}

// MARK: - split

/// Split `tspans[tspanIdx]` at character `offset`.
///
/// Returns `(tspans, leftIdx, rightIdx)`. `leftIdx` / `rightIdx` are
/// `nil` when the side of the split falls outside the list:
///
/// - `offset == 0`: no split; `leftIdx = tspanIdx - 1` (or nil at 0),
///   `rightIdx = tspanIdx`.
/// - `offset == content.count`: no split; `leftIdx = tspanIdx`,
///   `rightIdx = tspanIdx + 1` (or nil at end).
/// - Otherwise: the tspan is replaced by two fragments sharing the
///   original's attribute overrides. The left fragment keeps the
///   original's id; the right gets `maxExistingId + 1`.
///
/// Fails a precondition if `tspanIdx >= tspans.count` or
/// `offset > content.unicodeScalars.count` (mirrors Rust `split`).
public func splitTspans(_ tspans: [Tspan],
                        tspanIdx: Int,
                        offset: Int) -> (tspans: [Tspan], leftIdx: Int?, rightIdx: Int?) {
    precondition(tspanIdx < tspans.count,
                 "splitTspans: tspanIdx \(tspanIdx) out of range (\(tspans.count) tspans)")
    let t = tspans[tspanIdx]
    let scalars = Array(t.content.unicodeScalars)
    precondition(offset <= scalars.count,
                 "splitTspans: offset \(offset) exceeds tspan content length \(scalars.count)")

    if offset == 0 {
        let left = tspanIdx > 0 ? tspanIdx - 1 : nil
        return (tspans, left, tspanIdx)
    }
    if offset == scalars.count {
        let right = tspanIdx + 1 < tspans.count ? tspanIdx + 1 : nil
        return (tspans, tspanIdx, right)
    }

    let maxId = tspans.map(\.id).max() ?? 0
    let rightId = maxId + 1

    let leftContent = String(String.UnicodeScalarView(scalars[..<offset]))
    let rightContent = String(String.UnicodeScalarView(scalars[offset...]))
    let left = withContent(t, content: leftContent)
    let right = withContent(t, content: rightContent, idOverride: rightId)

    var result = Array(tspans[..<tspanIdx])
    result.append(left)
    result.append(right)
    result.append(contentsOf: tspans[(tspanIdx + 1)...])
    return (result, tspanIdx, tspanIdx + 1)
}

// MARK: - split_range

/// Split tspans so the character range `[charStart, charEnd)` of the
/// concatenated content is covered exactly by a contiguous run of
/// tspans. Returns `(tspans, firstIdx, lastIdx)` with inclusive
/// bounds; both `nil` when the range is empty.
///
/// Fails a precondition if `charStart > charEnd` or `charEnd` exceeds
/// the total content length (mirrors Rust `split_range`).
public func splitTspanRange(_ tspans: [Tspan],
                            charStart: Int,
                            charEnd: Int) -> (tspans: [Tspan], firstIdx: Int?, lastIdx: Int?) {
    precondition(charStart <= charEnd,
                 "splitTspanRange: charStart \(charStart) > charEnd \(charEnd)")
    let total = tspans.reduce(0) { $0 + $1.content.unicodeScalars.count }
    precondition(charEnd <= total,
                 "splitTspanRange: charEnd \(charEnd) exceeds content length \(total)")

    if charStart == charEnd {
        return (tspans, nil, nil)
    }

    var nextId: UInt32 = (tspans.map(\.id).max().map { $0 + 1 }) ?? 0
    var result: [Tspan] = []
    result.reserveCapacity(tspans.count + 2)
    var firstIdx: Int? = nil
    var lastIdx: Int? = nil
    var cursor = 0

    for t in tspans {
        let scalars = Array(t.content.unicodeScalars)
        let len = scalars.count
        let spanStart = cursor
        let spanEnd = cursor + len
        let overlapStart = max(charStart, spanStart)
        let overlapEnd = min(charEnd, spanEnd)

        if overlapStart >= overlapEnd {
            result.append(t)
        } else {
            let localStart = overlapStart - spanStart
            let localEnd = overlapEnd - spanStart

            if localStart > 0 {
                let prefix = withContent(t, content:
                    String(String.UnicodeScalarView(scalars[..<localStart])))
                result.append(prefix)
            }

            let middleContent = String(String.UnicodeScalarView(scalars[localStart..<localEnd]))
            var middle = withContent(t, content: middleContent)
            if localStart > 0 {
                middle = withId(middle, id: nextId)
                nextId += 1
            }
            let middleIdx = result.count
            if firstIdx == nil { firstIdx = middleIdx }
            lastIdx = middleIdx
            result.append(middle)

            if localEnd < len {
                let suffixContent = String(String.UnicodeScalarView(scalars[localEnd...]))
                let suffix = withContent(t, content: suffixContent, idOverride: nextId)
                nextId += 1
                result.append(suffix)
            }
        }
        cursor = spanEnd
    }

    return (result, firstIdx, lastIdx)
}

// MARK: - merge

/// Merge adjacent tspans with identical resolved override sets. Empty-
/// content tspans are dropped unconditionally. The surviving (left)
/// tspan keeps its id; the right tspan's id is dropped.
///
/// Preserves the "at least one tspan" invariant: if every tspan would
/// collapse to empty, returns `[Tspan.defaultTspan()]`.
public func mergeTspans(_ tspans: [Tspan]) -> [Tspan] {
    let filtered = tspans.filter { !$0.content.isEmpty }
    if filtered.isEmpty { return [Tspan.defaultTspan()] }

    var result: [Tspan] = []
    result.reserveCapacity(filtered.count)
    for t in filtered {
        if let prev = result.last, tspanAttrsEqual(prev, t) {
            result[result.count - 1] = withContent(prev, content: prev.content + t.content)
        } else {
            result.append(t)
        }
    }
    return result
}

// MARK: - attrsEqual

/// True when every override slot agrees. Content and id are ignored.
private func tspanAttrsEqual(_ a: Tspan, _ b: Tspan) -> Bool {
    a.baselineShift == b.baselineShift
        && a.dx == b.dx
        && a.fontFamily == b.fontFamily
        && a.fontSize == b.fontSize
        && a.fontStyle == b.fontStyle
        && a.fontVariant == b.fontVariant
        && a.fontWeight == b.fontWeight
        && a.jasAaMode == b.jasAaMode
        && a.jasFractionalWidths == b.jasFractionalWidths
        && a.jasKerningMode == b.jasKerningMode
        && a.jasNoBreak == b.jasNoBreak
        && a.letterSpacing == b.letterSpacing
        && a.lineHeight == b.lineHeight
        && a.rotate == b.rotate
        && a.styleName == b.styleName
        && a.textDecoration == b.textDecoration
        && a.textRendering == b.textRendering
        && a.textTransform == b.textTransform
        && a.transform == b.transform
        && a.xmlLang == b.xmlLang
}

// MARK: - copy_range / insert_tspans_at

/// Extract the covered slice `[charStart, charEnd)` of the input as
/// a fresh tspan array. Each returned tspan carries its source
/// tspan's overrides and id, with `content` truncated to the
/// overlap. Empty / inverted range → empty array; out-of-range
/// bounds saturate.
public func copyTspanRange(_ original: [Tspan], charStart: Int, charEnd: Int) -> [Tspan] {
    if charStart >= charEnd { return [] }
    let total = original.reduce(0) { $0 + $1.content.unicodeScalars.count }
    let start = min(charStart, total)
    let end = min(charEnd, total)
    if start >= end { return [] }

    var result: [Tspan] = []
    var cursor = 0
    for t in original {
        let scalars = Array(t.content.unicodeScalars)
        let tStart = cursor
        let tEnd = cursor + scalars.count
        let overlapStart = max(start, tStart)
        let overlapEnd = min(end, tEnd)
        if overlapStart < overlapEnd {
            let localStart = overlapStart - tStart
            let localEnd = overlapEnd - tStart
            let sliced = String(String.UnicodeScalarView(scalars[localStart..<localEnd]))
            result.append(withContent(t, content: sliced))
        }
        cursor = tEnd
    }
    return result
}

/// Splice `toInsert` into `original` at character position
/// `charPos`. Boundary insert slots between neighbours; mid-tspan
/// insert splits that tspan around the insertion. IDs on `toInsert`
/// are reassigned above `original`'s max id to avoid collisions.
/// Final merge pass collapses adjacent-equal tspans.
public func insertTspansAt(
    _ original: [Tspan], charPos: Int, _ toInsert: [Tspan]
) -> [Tspan] {
    let anyNonEmpty = toInsert.contains { !$0.content.isEmpty }
    if !anyNonEmpty { return original }

    let baseMax = original.map(\.id).max() ?? 0
    var nextId = baseMax + 1
    let reindexed = toInsert.map { t -> Tspan in
        let out = withId(t, id: nextId)
        nextId += 1
        return out
    }

    let total = original.reduce(0) { $0 + $1.content.unicodeScalars.count }
    let pos = min(charPos, total)
    var before: [Tspan] = []
    var after: [Tspan] = []
    var cursor = 0
    for t in original {
        let scalars = Array(t.content.unicodeScalars)
        let tEnd = cursor + scalars.count
        if tEnd <= pos {
            before.append(t)
        } else if cursor >= pos {
            after.append(t)
        } else {
            let local = pos - cursor
            let leftContent = String(String.UnicodeScalarView(scalars[..<local]))
            let rightContent = String(String.UnicodeScalarView(scalars[local...]))
            before.append(withContent(t, content: leftContent))
            // Right half gets a fresh id to avoid colliding with the
            // left half keeping the original id.
            let right = withContent(t, content: rightContent, idOverride: nextId)
            nextId += 1
            after.append(right)
        }
        cursor = tEnd
    }
    var result: [Tspan] = []
    result.reserveCapacity(before.count + reindexed.count + after.count)
    result.append(contentsOf: before)
    result.append(contentsOf: reindexed)
    result.append(contentsOf: after)
    return mergeTspans(result)
}

// MARK: - reconcile

/// Reconcile a new flat content string back onto the original tspan
/// structure, preserving per-range overrides where possible.
///
/// Unchanged common prefix and suffix (byte-level, snapped to UTF-8
/// boundaries) keep their original tspan assignments. The changed
/// middle region is absorbed into the first overlapping tspan, with
/// adjacent-equal tspans collapsed by `mergeTspans`.
///
/// Mirrors Rust's `reconcile_content`. Used by
/// `TextEditSession.applyToDocument` so an edit inside one tspan
/// doesn't wipe out every other tspan's overrides.
public func reconcileTspanContent(_ original: [Tspan], _ newContent: String) -> [Tspan] {
    let oldContent = concatTspanContent(original)
    if oldContent == newContent { return original }
    if original.isEmpty {
        return [Tspan(id: 0, content: newContent)]
    }

    // Work with utf8 byte views for LCP/LCS; String.Index values are
    // byte offsets in utf8.
    let oldU8 = Array(oldContent.utf8)
    let newU8 = Array(newContent.utf8)

    let maxPrefix = min(oldU8.count, newU8.count)
    var prefixLen = 0
    while prefixLen < maxPrefix && oldU8[prefixLen] == newU8[prefixLen] {
        prefixLen += 1
    }
    // Back off to the nearest Unicode scalar boundary so we don't
    // split a multibyte codepoint.
    while prefixLen > 0 && !isUtf8Boundary(oldContent, byteOffset: prefixLen) {
        prefixLen -= 1
    }

    let maxSuffix = min(oldU8.count - prefixLen, newU8.count - prefixLen)
    var suffixLen = 0
    while suffixLen < maxSuffix
        && oldU8[oldU8.count - 1 - suffixLen] == newU8[newU8.count - 1 - suffixLen] {
        suffixLen += 1
    }
    while suffixLen > 0 && !isUtf8Boundary(oldContent, byteOffset: oldU8.count - suffixLen) {
        suffixLen -= 1
    }

    let oldMidStart = prefixLen
    let oldMidEnd = oldU8.count - suffixLen
    let newMiddleStart = prefixLen
    let newMiddleEnd = newU8.count - suffixLen
    let newMiddle = String(decoding: Array(newU8[newMiddleStart..<newMiddleEnd]), as: UTF8.self)

    // Pure insertion at a boundary: splice newMiddle into the tspan
    // containing oldMidStart; everything else pass-through.
    if oldMidStart == oldMidEnd {
        var result = original
        var pos = oldMidStart
        var absorbed = false
        for i in 0..<result.count {
            let tLen = result[i].content.utf8.count
            if pos <= tLen {
                let content = result[i].content
                let beforeEnd = content.utf8.index(content.startIndex, offsetBy: pos)
                let before = String(content[..<beforeEnd])
                let after = String(content[beforeEnd...])
                result[i] = withContent(result[i], content: before + newMiddle + after)
                absorbed = true
                break
            }
            pos -= tLen
        }
        if !absorbed {
            if let last = result.last {
                result[result.count - 1] = withContent(last, content: last.content + newMiddle)
            } else {
                result.append(Tspan(id: 0, content: newMiddle))
            }
        }
        return mergeTspans(result)
    }

    // Replacement (including pure deletion): walk tspans and absorb
    // newMiddle into the first overlapping tspan.
    var result: [Tspan] = []
    result.reserveCapacity(original.count + 1)
    var cursor = 0
    var middleConsumed = false

    for tspan in original {
        let tLen = tspan.content.utf8.count
        let tStart = cursor
        let tEnd = cursor + tLen

        if tEnd <= oldMidStart {
            result.append(tspan)
        } else if tStart >= oldMidEnd {
            result.append(tspan)
        } else {
            let beforeLen = max(0, oldMidStart - tStart)
            let afterOff = min(tLen, max(0, oldMidEnd - tStart))
            let content = tspan.content
            let beforeEnd = content.utf8.index(content.startIndex, offsetBy: beforeLen)
            let afterStart = content.utf8.index(content.startIndex, offsetBy: afterOff)
            let before = String(content[..<beforeEnd])
            let after = (tEnd > oldMidEnd) ? String(content[afterStart...]) : ""

            var newContentStr = before
            if !middleConsumed {
                newContentStr += newMiddle
                middleConsumed = true
            }
            newContentStr += after
            if !newContentStr.isEmpty {
                result.append(withContent(tspan, content: newContentStr))
            }
        }
        cursor = tEnd
    }

    if result.isEmpty {
        result.append(Tspan.defaultTspan())
    }
    return mergeTspans(result)
}

/// Whether `byteOffset` is a valid UTF-8 scalar boundary in `s`.
private func isUtf8Boundary(_ s: String, byteOffset: Int) -> Bool {
    if byteOffset <= 0 || byteOffset >= s.utf8.count { return true }
    // UTF-8 continuation bytes have the high bits 10xxxxxx.
    let byte = Array(s.utf8)[byteOffset]
    return (byte & 0xC0) != 0x80
}

// MARK: - rebuild helpers

/// Return a copy of `t` with a new content string (and optionally a
/// new id). Needed because `Tspan` stores every field as `let`, so
/// copy-on-modify goes through the full init.
private func withContent(_ t: Tspan, content: String, idOverride: UInt32? = nil) -> Tspan {
    Tspan(
        id: idOverride ?? t.id, content: content,
        baselineShift: t.baselineShift, dx: t.dx,
        fontFamily: t.fontFamily, fontSize: t.fontSize,
        fontStyle: t.fontStyle, fontVariant: t.fontVariant,
        fontWeight: t.fontWeight,
        jasAaMode: t.jasAaMode, jasFractionalWidths: t.jasFractionalWidths,
        jasKerningMode: t.jasKerningMode, jasNoBreak: t.jasNoBreak,
        letterSpacing: t.letterSpacing, lineHeight: t.lineHeight,
        rotate: t.rotate, styleName: t.styleName,
        textDecoration: t.textDecoration, textRendering: t.textRendering,
        textTransform: t.textTransform, transform: t.transform,
        xmlLang: t.xmlLang)
}

private func withId(_ t: Tspan, id: UInt32) -> Tspan {
    withContent(t, content: t.content, idOverride: id)
}
