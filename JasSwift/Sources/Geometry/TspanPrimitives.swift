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

// MARK: - rich-clipboard serializers

/// Serialize `tspans` as the `application/x-jas-tspans` JSON payload
/// described in TSPAN.md: `{"tspans": [...]}` with each tspan's
/// override fields in snake_case. Ids are stripped; nil overrides
/// are omitted.
public func tspansToJsonClipboard(_ tspans: [Tspan]) -> String {
    var arr: [[String: Any]] = []
    for t in tspans {
        var obj: [String: Any] = ["content": t.content]
        if let v = t.baselineShift { obj["baseline_shift"] = v }
        if let v = t.dx { obj["dx"] = v }
        if let v = t.fontFamily { obj["font_family"] = v }
        if let v = t.fontSize { obj["font_size"] = v }
        if let v = t.fontStyle { obj["font_style"] = v }
        if let v = t.fontVariant { obj["font_variant"] = v }
        if let v = t.fontWeight { obj["font_weight"] = v }
        if let v = t.jasAaMode { obj["jas_aa_mode"] = v }
        if let v = t.jasFractionalWidths { obj["jas_fractional_widths"] = v }
        if let v = t.jasKerningMode { obj["jas_kerning_mode"] = v }
        if let v = t.jasNoBreak { obj["jas_no_break"] = v }
        if let v = t.jasRole { obj["jas_role"] = v }
        if let v = t.letterSpacing { obj["letter_spacing"] = v }
        if let v = t.lineHeight { obj["line_height"] = v }
        if let v = t.rotate { obj["rotate"] = v }
        if let v = t.styleName { obj["style_name"] = v }
        if let v = t.textDecoration { obj["text_decoration"] = v }
        if let v = t.textRendering { obj["text_rendering"] = v }
        if let v = t.textTransform { obj["text_transform"] = v }
        if let v = t.xmlLang { obj["xml_lang"] = v }
        arr.append(obj)
    }
    let root: [String: Any] = ["tspans": arr]
    let data = (try? JSONSerialization.data(withJSONObject: root,
                                             options: [.sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Parse a rich-clipboard JSON payload back into a tspan list with
/// fresh ids (0, 1, 2, …). Returns `nil` if the payload is malformed.
public func tspansFromJsonClipboard(_ jsonStr: String) -> [Tspan]? {
    guard let data = jsonStr.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let arr = root["tspans"] as? [[String: Any]]
    else { return nil }
    var out: [Tspan] = []
    for (i, obj) in arr.enumerated() {
        let t = Tspan(
            id: UInt32(i),
            content: obj["content"] as? String ?? "",
            baselineShift: (obj["baseline_shift"] as? NSNumber)?.doubleValue,
            dx: (obj["dx"] as? NSNumber)?.doubleValue,
            fontFamily: obj["font_family"] as? String,
            fontSize: (obj["font_size"] as? NSNumber)?.doubleValue,
            fontStyle: obj["font_style"] as? String,
            fontVariant: obj["font_variant"] as? String,
            fontWeight: obj["font_weight"] as? String,
            jasAaMode: obj["jas_aa_mode"] as? String,
            jasFractionalWidths: (obj["jas_fractional_widths"] as? NSNumber)?.boolValue,
            jasKerningMode: obj["jas_kerning_mode"] as? String,
            jasNoBreak: (obj["jas_no_break"] as? NSNumber)?.boolValue,
            jasRole: obj["jas_role"] as? String,
            letterSpacing: (obj["letter_spacing"] as? NSNumber)?.doubleValue,
            lineHeight: (obj["line_height"] as? NSNumber)?.doubleValue,
            rotate: (obj["rotate"] as? NSNumber)?.doubleValue,
            styleName: obj["style_name"] as? String,
            textDecoration: obj["text_decoration"] as? [String],
            textRendering: obj["text_rendering"] as? String,
            textTransform: obj["text_transform"] as? String,
            transform: nil,  // transform isn't part of the clipboard payload
            xmlLang: obj["xml_lang"] as? String)
        out.append(t)
    }
    return out
}

/// Serialize `tspans` as an SVG fragment suitable for the
/// `image/svg+xml` clipboard format — a single `<text>` element
/// wrapping the tspan children with standard CSS-style attribute
/// names, alphabetically sorted.
public func tspansToSvgFragment(_ tspans: [Tspan]) -> String {
    var out = #"<text xmlns="http://www.w3.org/2000/svg">"#
    for t in tspans {
        out += "<tspan"
        var attrs: [(String, String)] = []
        if let v = t.baselineShift { attrs.append(("baseline-shift", _fmtDouble(v))) }
        if let v = t.dx { attrs.append(("dx", _fmtDouble(v))) }
        if let v = t.fontFamily { attrs.append(("font-family", v)) }
        if let v = t.fontSize { attrs.append(("font-size", _fmtDouble(v))) }
        if let v = t.fontStyle { attrs.append(("font-style", v)) }
        if let v = t.fontVariant { attrs.append(("font-variant", v)) }
        if let v = t.fontWeight { attrs.append(("font-weight", v)) }
        if let v = t.jasAaMode { attrs.append(("jas:aa-mode", v)) }
        if let v = t.jasFractionalWidths { attrs.append(("jas:fractional-widths", v ? "true" : "false")) }
        if let v = t.jasKerningMode { attrs.append(("jas:kerning-mode", v)) }
        if let v = t.jasNoBreak { attrs.append(("jas:no-break", v ? "true" : "false")) }
        if let v = t.jasRole { attrs.append(("jas:role", v)) }
        if let v = t.letterSpacing { attrs.append(("letter-spacing", _fmtDouble(v))) }
        if let v = t.lineHeight { attrs.append(("line-height", _fmtDouble(v))) }
        if let v = t.rotate { attrs.append(("rotate", _fmtDouble(v))) }
        if let v = t.styleName { attrs.append(("jas:style-name", v)) }
        if let v = t.textDecoration, !v.isEmpty { attrs.append(("text-decoration", v.joined(separator: " "))) }
        if let v = t.textRendering { attrs.append(("text-rendering", v)) }
        if let v = t.textTransform { attrs.append(("text-transform", v)) }
        if let v = t.xmlLang { attrs.append(("xml:lang", v)) }
        attrs.sort { $0.0 < $1.0 }
        for (k, v) in attrs {
            out += " \(k)=\"\(_xmlEscape(v))\""
        }
        out += ">\(_xmlEscape(t.content))</tspan>"
    }
    out += "</text>"
    return out
}

private func _fmtDouble(_ v: Double) -> String {
    v == v.rounded() ? "\(Int(v))" : "\(v)"
}

private func _xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private func _xmlUnescape(_ s: String) -> String {
    s.replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&amp;", with: "&")
}

/// Parse an SVG fragment of the shape emitted by `tspansToSvgFragment`
/// (or a compatible shape from another SVG app) into a tspan list
/// with fresh ids. Returns `nil` when the root is not `<text>`.
public func tspansFromSvgFragment(_ svgStr: String) -> [Tspan]? {
    let trimmed = svgStr.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let textRange = trimmed.range(of: "<text") else { return nil }
    let rest = String(trimmed[textRange.lowerBound...])
    var out: [Tspan] = []
    var nextId: UInt32 = 0
    var searchStart = rest.startIndex
    while let openRange = rest.range(of: "<tspan", range: searchStart..<rest.endIndex) {
        // Find end of open tag
        guard let gtRange = rest.range(of: ">", range: openRange.upperBound..<rest.endIndex)
        else { break }
        let attrsStr = String(rest[openRange.upperBound..<gtRange.lowerBound])
        guard let closeRange = rest.range(of: "</tspan>", range: gtRange.upperBound..<rest.endIndex)
        else { break }
        let contentRaw = String(rest[gtRange.upperBound..<closeRange.lowerBound])
        // Flatten nested tags.
        let content = _xmlUnescape(_stripTags(contentRaw))
        var t = Tspan(id: nextId, content: content)
        nextId += 1
        for (k, v) in _parseXmlAttrs(attrsStr) {
            switch k {
            case "baseline-shift": t = mergeFields(t, baselineShift: Double(v))
            case "dx": t = mergeFields(t, dx: Double(v))
            case "font-family": t = mergeFields(t, fontFamily: v)
            case "font-size": t = mergeFields(t, fontSize: Double(v))
            case "font-style": t = mergeFields(t, fontStyle: v)
            case "font-variant": t = mergeFields(t, fontVariant: v)
            case "font-weight": t = mergeFields(t, fontWeight: v)
            case "jas:aa-mode": t = mergeFields(t, jasAaMode: v)
            case "jas:fractional-widths": t = mergeFields(t, jasFractionalWidths: v == "true")
            case "jas:kerning-mode": t = mergeFields(t, jasKerningMode: v)
            case "jas:no-break": t = mergeFields(t, jasNoBreak: v == "true")
            case "jas:role": t = mergeFields(t, jasRole: v)
            case "letter-spacing": t = mergeFields(t, letterSpacing: Double(v))
            case "line-height": t = mergeFields(t, lineHeight: Double(v))
            case "rotate": t = mergeFields(t, rotate: Double(v))
            case "jas:style-name": t = mergeFields(t, styleName: v)
            case "text-decoration":
                let parts = v.split(separator: " ").map(String.init).filter { $0 != "none" }
                t = mergeFields(t, textDecoration: parts)
            case "text-rendering": t = mergeFields(t, textRendering: v)
            case "text-transform": t = mergeFields(t, textTransform: v)
            case "xml:lang": t = mergeFields(t, xmlLang: v)
            default: break
            }
        }
        out.append(t)
        searchStart = closeRange.upperBound
    }
    return out.isEmpty ? nil : out
}

/// Return a new Tspan derived from `t` with the supplied fields
/// replacing the existing values. Fields default to the current
/// value, so only the one(s) you name change.
private func mergeFields(_ t: Tspan,
                         baselineShift: Double?? = .some(nil),
                         dx: Double?? = .some(nil),
                         fontFamily: String?? = .some(nil),
                         fontSize: Double?? = .some(nil),
                         fontStyle: String?? = .some(nil),
                         fontVariant: String?? = .some(nil),
                         fontWeight: String?? = .some(nil),
                         jasAaMode: String?? = .some(nil),
                         jasFractionalWidths: Bool?? = .some(nil),
                         jasKerningMode: String?? = .some(nil),
                         jasNoBreak: Bool?? = .some(nil),
                         jasRole: String?? = .some(nil),
                         letterSpacing: Double?? = .some(nil),
                         lineHeight: Double?? = .some(nil),
                         rotate: Double?? = .some(nil),
                         styleName: String?? = .some(nil),
                         textDecoration: [String]?? = .some(nil),
                         textRendering: String?? = .some(nil),
                         textTransform: String?? = .some(nil),
                         xmlLang: String?? = .some(nil)) -> Tspan {
    // Each double-optional parameter has three possible states:
    //   .some(.some(v)) — explicit new value
    //   .some(.none)    — caller omitted the argument (default)
    //   .none           — caller passed nil to clear (unused here)
    func pick<T>(_ new: T??, _ old: T?) -> T? {
        switch new {
        case .some(.some(let v)): return v
        case .some(.none): return old
        case .none: return nil
        }
    }
    return Tspan(
        id: t.id, content: t.content,
        baselineShift: pick(baselineShift, t.baselineShift),
        dx: pick(dx, t.dx),
        fontFamily: pick(fontFamily, t.fontFamily),
        fontSize: pick(fontSize, t.fontSize),
        fontStyle: pick(fontStyle, t.fontStyle),
        fontVariant: pick(fontVariant, t.fontVariant),
        fontWeight: pick(fontWeight, t.fontWeight),
        jasAaMode: pick(jasAaMode, t.jasAaMode),
        jasFractionalWidths: pick(jasFractionalWidths, t.jasFractionalWidths),
        jasKerningMode: pick(jasKerningMode, t.jasKerningMode),
        jasNoBreak: pick(jasNoBreak, t.jasNoBreak),
        jasRole: pick(jasRole, t.jasRole),
        letterSpacing: pick(letterSpacing, t.letterSpacing),
        lineHeight: pick(lineHeight, t.lineHeight),
        rotate: pick(rotate, t.rotate),
        styleName: pick(styleName, t.styleName),
        textDecoration: pick(textDecoration, t.textDecoration),
        textRendering: pick(textRendering, t.textRendering),
        textTransform: pick(textTransform, t.textTransform),
        transform: t.transform,
        xmlLang: pick(xmlLang, t.xmlLang))
}

private func _stripTags(_ s: String) -> String {
    var out = ""
    var inTag = false
    for c in s {
        if c == "<" { inTag = true; continue }
        if c == ">" && inTag { inTag = false; continue }
        if !inTag { out.append(c) }
    }
    return out
}

private func _parseXmlAttrs(_ s: String) -> [(String, String)] {
    var out: [(String, String)] = []
    let chars = Array(s)
    var i = 0
    while i < chars.count {
        while i < chars.count && chars[i].isWhitespace { i += 1 }
        if i >= chars.count { break }
        var nameStart = i
        while i < chars.count && chars[i] != "=" && !chars[i].isWhitespace { i += 1 }
        let name = String(chars[nameStart..<i])
        if name.isEmpty { break }
        while i < chars.count && chars[i] != "=" { i += 1 }
        if i >= chars.count { break }
        i += 1
        while i < chars.count && chars[i] != "\"" && chars[i] != "'" { i += 1 }
        if i >= chars.count { break }
        let quote = chars[i]
        i += 1
        let valStart = i
        while i < chars.count && chars[i] != quote { i += 1 }
        let val = String(chars[valStart..<i])
        if i < chars.count { i += 1 }
        out.append((name, _xmlUnescape(val)))
        _ = nameStart  // suppress unused warning on some compilers
    }
    return out
}

// MARK: - merge overrides

/// Copy every non-`nil` override field from `source` into `target`.
/// Does not touch `id` or `content`. Used by the next-typed-character
/// state (the "pending override" template) when applying captured
/// overrides to newly-typed tspans.
public func mergeTspanOverrides(_ target: Tspan, _ source: Tspan) -> Tspan {
    Tspan(
        id: target.id,
        content: target.content,
        baselineShift: source.baselineShift ?? target.baselineShift,
        dx: source.dx ?? target.dx,
        fontFamily: source.fontFamily ?? target.fontFamily,
        fontSize: source.fontSize ?? target.fontSize,
        fontStyle: source.fontStyle ?? target.fontStyle,
        fontVariant: source.fontVariant ?? target.fontVariant,
        fontWeight: source.fontWeight ?? target.fontWeight,
        jasAaMode: source.jasAaMode ?? target.jasAaMode,
        jasFractionalWidths: source.jasFractionalWidths ?? target.jasFractionalWidths,
        jasKerningMode: source.jasKerningMode ?? target.jasKerningMode,
        jasNoBreak: source.jasNoBreak ?? target.jasNoBreak,
        jasRole: source.jasRole ?? target.jasRole,
        letterSpacing: source.letterSpacing ?? target.letterSpacing,
        lineHeight: source.lineHeight ?? target.lineHeight,
        rotate: source.rotate ?? target.rotate,
        styleName: source.styleName ?? target.styleName,
        textDecoration: source.textDecoration ?? target.textDecoration,
        textRendering: source.textRendering ?? target.textRendering,
        textTransform: source.textTransform ?? target.textTransform,
        transform: source.transform ?? target.transform,
        xmlLang: source.xmlLang ?? target.xmlLang
    )
}

// MARK: - caret affinity

/// Caret side at a tspan boundary. See TSPAN.md Text-edit session
/// integration — when a character index lands exactly on the join
/// between two tspans, the affinity decides which side "wins".
///
/// `.left` corresponds to the spec's default: "new text inherits the
/// attributes of the previous character". `.right` is used by callers
/// that explicitly want the caret on the leading edge of the next
/// tspan.
public enum Affinity: Sendable {
    case left
    case right
}

/// Resolve a flat character index to a concrete `(tspanIdx, offset)`
/// position given the tspan list and a caret affinity.
///
/// - Mid-tspan: returns `(i, charIdx - prefixChars)`.
/// - Boundary between tspans `i` and `i+1`: `.left` returns the end
///   of tspan `i`; `.right` returns the start of tspan `i+1`. The
///   very last boundary (end of the final tspan) always returns the
///   end of that tspan regardless of affinity.
/// - Beyond the last tspan: clamps to the end.
/// - Empty tspan list: returns `(0, 0)`.
public func charToTspanPos(
    _ tspans: [Tspan], _ charIdx: Int, _ affinity: Affinity
) -> (tspanIdx: Int, offset: Int) {
    if tspans.isEmpty { return (0, 0) }
    var acc = 0
    for (i, t) in tspans.enumerated() {
        let n = t.content.count
        if charIdx < acc + n {
            return (i, charIdx - acc)
        }
        if charIdx == acc + n {
            if i + 1 == tspans.count {
                return (i, n)
            }
            switch affinity {
            case .left:  return (i, n)
            case .right: return (i + 1, 0)
            }
        }
        acc += n
    }
    let last = tspans.count - 1
    return (last, tspans[last].content.count)
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
