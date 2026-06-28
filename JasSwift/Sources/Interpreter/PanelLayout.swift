// Shared canonical panel widget-layout pass (Path B).
//
// Swift port of `jas/panels/panel_layout.py` / `panel_layout.rs`.  A pure,
// integer-arithmetic layout of a compiled panel node into widget rects,
// byte-identical across all five apps.  The full contract is
// PATH_B_DESIGN.md Appendix A.
//
// All arithmetic is integer (no float anywhere), so the native
// implementations are byte-identical and the corpus
// (`test_fixtures/algorithms/panel_layout.json`) needs no tolerance.  Text
// widths use the deterministic stub measure `codepoints(text) * CHAR_WIDTH`
// (CHAR_WIDTH = 10) and columns use the Bootstrap-12 rule
// `cell_w = (2*inner_w*N + 12) / 24` (round-half-up, exact, truncating div).

import Foundation

public enum PanelLayout {
    public static let charWidth = 10

    private static let containerTypes: Set<String> = ["container", "row", "col", "panel"]

    private static let fillKinds: Set<String> = [
        "select", "number_input", "text_input", "length_input",
        "slider", "placeholder", "separator",
    ]

    /// An intermediate item with coords RELATIVE to its node's origin.
    private struct MItem {
        var path: [Int]
        var x: Int
        var y: Int
        var w: Int
        var h: Int
    }

    /// Lay out a compiled panel node (`{"type":"panel","content":<root>}`) into
    /// an array of `{"path":[..],"rect":{x,y,w,h}}`, pre-order, panel-relative.
    public static func layoutPanel(_ panelNode: [String: Any], availW: Int) -> [[String: Any]] {
        guard let root = panelNode["content"] as? [String: Any] else {
            return []
        }
        let (_, _, items) = measure(root, path: [], availW: availW)
        return items.map { it in
            [
                "path": it.path,
                "rect": ["x": it.x, "y": it.y, "w": it.w, "h": it.h],
            ]
        }
    }

    // MARK: - value readers

    private static func asInt(_ v: Any?) -> Int? {
        guard let v = v, !(v is NSNull) else { return nil }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func nodeType(_ n: [String: Any]) -> String {
        (n["type"] as? String) ?? ""
    }

    private static func style(_ n: [String: Any]) -> [String: Any] {
        (n["style"] as? [String: Any]) ?? [:]
    }

    private static func styleI(_ n: [String: Any], _ key: String) -> Int? {
        asInt(style(n)[key])
    }

    private static func isContainer(_ n: [String: Any]) -> Bool {
        containerTypes.contains(nodeType(n))
    }

    private static func resolvedLayout(_ n: [String: Any]) -> String {
        if let lay = n["layout"] as? String, lay == "row" || lay == "column" {
            return lay
        }
        return nodeType(n) == "row" ? "row" : "column"
    }

    private static func hasCol(_ n: [String: Any]) -> Bool {
        guard let v = n["col"] else { return false }
        return !(v is NSNull)
    }

    private static func textW(_ s: String) -> Int {
        // UNICODE CODE POINTS, not bytes / UTF-16 units.
        s.unicodeScalars.count * charWidth
    }

    private static func isFill(_ kind: String) -> Bool {
        fillKinds.contains(kind)
    }

    private static func kindHeight(_ kind: String) -> Int {
        switch kind {
        case "text": return 20
        case "button": return 24
        case "checkbox": return 20
        case "icon_button": return 24
        case "icon": return 20
        case "select": return 20
        case "number_input": return 20
        case "text_input": return 20
        case "length_input": return 20
        case "slider": return 12
        case "placeholder": return 40
        case "separator": return 1
        default: return 20
        }
    }

    private static func kindFallbackW(_ kind: String) -> Int {
        switch kind {
        case "select": return 80
        case "number_input": return 45
        case "text_input": return 80
        case "length_input": return 80
        case "slider": return 100
        case "placeholder": return 60
        default: return 0
        }
    }

    /// CSS 1/2/4-value shorthand -> (top, right, bottom, left), ints.
    private static func parsePadding(_ v: Any?) -> (Int, Int, Int, Int) {
        guard let v = v, !(v is NSNull) else { return (0, 0, 0, 0) }
        if let n = v as? NSNumber { let i = n.intValue; return (i, i, i, i) }
        var parts: [Int] = []
        if let s = v as? String {
            for p in s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
                if let i = Int(p) { parts.append(i) }
            }
        } else if let a = v as? [Any] {
            for x in a {
                if let i = asInt(x) { parts.append(i) }
            }
        } else {
            return (0, 0, 0, 0)
        }
        switch parts.count {
        case 1:
            let n = parts[0]
            return (n, n, n, n)
        case 2:
            return (parts[0], parts[1], parts[0], parts[1])
        case let c where c >= 4:
            return (parts[0], parts[1], parts[2], parts[3])
        default:
            return (0, 0, 0, 0)
        }
    }

    private static func visibleChildren(_ n: [String: Any]) -> [(Int, [String: Any])] {
        var out: [(Int, [String: Any])] = []
        guard let ch = n["children"] as? [Any] else { return out }
        for (i, c) in ch.enumerated() {
            guard let c = c as? [String: Any] else { continue }
            if let vis = c["visible"] as? Bool, vis == false { continue }
            out.append((i, c))
        }
        return out
    }

    private static func colSpan(_ n: [String: Any]) -> Int {
        // Mirror Python `int(c.get("col") or 1)`: 0 / null both become 1.
        let raw = asInt(n["col"]) ?? 0
        return raw != 0 ? raw : 1
    }

    private static func leafSize(_ n: [String: Any], availW: Int) -> (Int, Int, Bool) {
        let t = nodeType(n)
        let h = styleI(n, "height") ?? kindHeight(t)
        let fill = isFill(t)
        var w: Int
        if fill {
            w = availW > 0 ? availW : kindFallbackW(t)
        } else {
            switch t {
            case "text":
                w = textW((n["content"] as? String) ?? "")
            case "button":
                w = textW((n["label"] as? String) ?? "") + 16
            case "checkbox":
                w = 16 + 4 + textW((n["label"] as? String) ?? "")
            case "icon_button":
                w = 24
            case "icon":
                w = 20
            default:
                w = 0
            }
        }
        if let x = styleI(n, "width") { w = x }
        if let m = styleI(n, "min_width") { w = max(w, m) }
        return (w, h, fill)
    }

    /// Returns (w, h, items) with item coords RELATIVE to this node's origin.
    private static func measure(_ n: [String: Any], path: [Int], availW: Int) -> (Int, Int, [MItem]) {
        let (pt, pr, pb, pl) = parsePadding(style(n)["padding"])
        let gap = styleI(n, "gap") ?? 0
        let innerW = availW - pl - pr

        if isContainer(n) {
            let children = visibleChildren(n)
            let lay = resolvedLayout(n)
            let chItems: [MItem]
            let contentH: Int
            if lay == "row" && children.contains(where: { hasCol($0.1) }) {
                (chItems, contentH) = grid(children, path: path, innerW: innerW, gap: gap)
            } else if lay == "row" {
                (chItems, contentH) = flow(children, path: path, innerW: innerW, gap: gap)
            } else {
                (chItems, contentH) = column(children, path: path, innerW: innerW, gap: gap)
            }
            let w = availW
            let h = contentH + pt + pb
            var items = [MItem(path: path, x: 0, y: 0, w: w, h: h)]
            for var it in chItems {
                it.x += pl
                it.y += pt
                items.append(it)
            }
            return (w, h, items)
        } else {
            let (w, h, fill) = leafSize(n, availW: availW)
            let rectW = (fill && availW > 0) ? availW : w
            return (rectW, h, [MItem(path: path, x: 0, y: 0, w: rectW, h: h)])
        }
    }

    private static func column(_ children: [(Int, [String: Any])], path: [Int], innerW: Int, gap: Int) -> ([MItem], Int) {
        var items: [MItem] = []
        var cy = 0
        var n = 0
        for (i, c) in children {
            let (_, ch, cit) = measure(c, path: path + [i], availW: innerW)
            for var it in cit {
                it.y += cy
                items.append(it)
            }
            cy += ch + gap
            n += 1
        }
        return (items, n > 0 ? cy - gap : 0)
    }

    private static func flow(_ children: [(Int, [String: Any])], path: [Int], innerW: Int, gap: Int) -> ([MItem], Int) {
        // Measure each child at intrinsic width (avail = -1).
        var measured: [(c: [String: Any], w: Int, h: Int, items: [MItem])] = []
        for (i, c) in children {
            let (cw, ch, cit) = measure(c, path: path + [i], availW: -1)
            measured.append((c, cw, ch, cit))
        }
        let n = measured.count
        let fixed = measured.reduce(0) { $0 + $1.w } + (n > 0 ? gap * (n - 1) : 0)
        let leftover = max(0, innerW - fixed)
        let weights = measured.map { styleI($0.c, "flex") ?? 0 }
        let sumw = weights.reduce(0, +)
        var extra = [Int](repeating: 0, count: n)
        if sumw > 0 && leftover > 0 {
            var base = (0..<n).map { leftover * weights[$0] / sumw }
            var rem = leftover - base.reduce(0, +)
            for k in 0..<n {
                if rem <= 0 { break }
                if weights[k] > 0 {
                    base[k] += 1
                    rem -= 1
                }
            }
            extra = base
        }
        let rowH = measured.map { $0.h }.max() ?? 0
        var items: [MItem] = []
        var cx = 0
        for k in 0..<n {
            let cw = measured[k].w
            let ch = measured[k].h
            var cit = measured[k].items
            let fw = cw + extra[k]
            let dy = (rowH - ch) / 2
            for j in cit.indices {
                cit[j].x += cx
                cit[j].y += dy
            }
            if extra[k] != 0 && !cit.isEmpty {
                cit[0].w = fw
            }
            items.append(contentsOf: cit)
            cx += fw + gap
        }
        return (items, rowH)
    }

    private static func grid(_ children: [(Int, [String: Any])], path: [Int], innerW: Int, gap: Int) -> ([MItem], Int) {
        // Wrap into lines so each line's column span sums to <= 12.
        var lines: [[(Int, [String: Any], Int)]] = []
        var cur: [(Int, [String: Any], Int)] = []
        var curSpan = 0
        for (i, c) in children {
            let span = colSpan(c)
            if !cur.isEmpty && curSpan + span > 12 {
                lines.append(cur)
                cur = []
                curSpan = 0
            }
            cur.append((i, c, span))
            curSpan += span
        }
        if !cur.isEmpty { lines.append(cur) }

        var items: [MItem] = []
        var lineY = 0
        for line in lines {
            var cx = 0
            var lineH = 0
            var cells: [(items: [MItem], h: Int, cellX: Int)] = []
            for (i, c, span) in line {
                let cellW = (2 * innerW * span + 12) / 24 // round-half-up, exact
                let (_, ch, cit) = measure(c, path: path + [i], availW: cellW)
                cells.append((cit, ch, cx))
                if ch > lineH { lineH = ch }
                cx += cellW + gap
            }
            for cell in cells {
                let dy = (lineH - cell.h) / 2
                var cit = cell.items
                for j in cit.indices {
                    cit[j].x += cell.cellX
                    cit[j].y += lineY + dy
                }
                items.append(contentsOf: cit)
            }
            lineY += lineH + gap
        }
        return (items, !lines.isEmpty ? lineY - gap : 0)
    }
}
