// Shared canonical panel widget-layout pass (Path B).
//
// Swift port of `workspace_interpreter/panel_layout.py` / `panel_layout.rs`.
// A pure, integer-arithmetic layout of a compiled panel node into widget
// rects, byte-identical across all five apps.  The full contract is
// PATH_B_DESIGN.md (Appendix A + Appendix B for foreach / vertical flex).
//
// All arithmetic is integer (no float anywhere), so the native
// implementations are byte-identical and the corpus
// (`test_fixtures/algorithms/panel_layout.json`) needs no tolerance.  Text
// `content` / `label` is first resolved through `evaluateText` against the
// data scope `ctx` so a bound `"{{sym.name}}"` is measured at its resolved
// value (a literal passes through unchanged); width is then
// `codepoints(resolved) * CHAR_WIDTH` (CHAR_WIDTH = 10).  Columns use the
// Bootstrap-12 rule `cell_w = (2*inner_w*N + 12) / 24` (round-half-up, exact,
// truncating div).  `foreach` containers expand their `do` template once per
// item of `evaluate(source, ctx)`; a column distributes `avail_h` leftover to
// `flex`-weighted children (vertical flex).

import Foundation

public enum PanelLayout {
    public static let charWidth = 10

    private static let containerTypes: Set<String> = ["container", "row", "col", "panel"]

    private static let fillKinds: Set<String> = [
        "select", "number_input", "text_input", "length_input",
        "slider", "placeholder", "separator",
        "combo_box", "icon_select", "spacer",
        // composite / data-driven widgets: placed as a fixed box (fill width)
        "color_bar", "fill_stroke_widget", "gradient_slider", "gradient_tile",
        "dropdown", "tree_view",
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
    ///
    /// `ctx` is the data scope (`state` / `panel` / `data` / `active_document`
    /// namespaces) used to evaluate `foreach` sources and text bindings;
    /// defaults to empty (literals only). `availH` drives vertical flex; 0 means
    /// content-height (no vertical flex).
    public static func layoutPanel(_ panelNode: [String: Any], availW: Int,
                                   availH: Int = 0, ctx: [String: Any] = [:]) -> [[String: Any]] {
        guard let root = panelNode["content"] as? [String: Any] else {
            return []
        }
        let (_, _, items) = measure(root, path: [], availW: availW, availH: availH, ctx: ctx)
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

    /// Resolve a style dimension to integer px, or nil to ignore. Numbers
    /// truncate toward zero; `"N%"` is `(avail*N)/100` (ignored when avail <= 0,
    /// e.g. heights); a bare numeric string is that int; anything else
    /// (`"auto"`, junk) is ignored.
    private static func resolveDim(_ v: Any?, _ avail: Int) -> Int? {
        guard let v = v, !(v is NSNull) else { return nil }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String {
            let s = s.trimmingCharacters(in: .whitespaces)
            if s.hasSuffix("%") {
                let num = String(s.dropLast()).trimmingCharacters(in: .whitespaces)
                let p: Int
                if let i = Int(num) {
                    p = i
                } else if let f = Double(num) {
                    p = Int(f)
                } else {
                    return nil
                }
                return avail > 0 ? (avail * p) / 100 : nil
            }
            if let i = Int(s) { return i }
            if let f = Double(s) { return Int(f) }
            return nil
        }
        return nil
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

    /// Resolved text width: `evaluateText(node[key], ctx)` codepoints * CHAR_WIDTH.
    /// A literal (no `{{}}`) passes through `evaluateText` unchanged so non-bound
    /// panels stay byte-identical. UNICODE CODE POINTS, not bytes / UTF-16 units.
    private static func textW(_ n: [String: Any], _ key: String, _ ctx: [String: Any]) -> Int {
        guard let raw = n[key] as? String else { return 0 }
        let resolved = evaluateText(raw, context: ctx)
        return resolved.unicodeScalars.count * charWidth
    }

    private static func isFill(_ kind: String) -> Bool {
        fillKinds.contains(kind)
    }

    /// Flex weight: explicit `style.flex`, or implicit 1 for a `spacer`.
    private static func flexWeight(_ n: [String: Any]) -> Int {
        let w = styleI(n, "flex") ?? 0
        return (w == 0 && nodeType(n) == "spacer") ? 1 : w
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
        case "combo_box": return 20
        case "icon_select": return 20
        case "spacer": return 0
        case "color_swatch": return 16
        case "toggle": return 20
        // composite box heights (provisional)
        case "color_bar": return 24
        case "fill_stroke_widget": return 44
        case "gradient_slider": return 24
        case "gradient_tile": return 24
        case "dropdown": return 20
        case "tree_view": return 200
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
        case "combo_box": return 80
        case "icon_select": return 80
        case "spacer": return 0
        case "fill_stroke_widget": return 50
        case "gradient_tile": return 32
        case "dropdown": return 80
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

    private static func leafSize(_ n: [String: Any], availW: Int, ctx: [String: Any]) -> (Int, Int, Bool) {
        let t = nodeType(n)
        let st = style(n)
        let h = resolveDim(st["height"], 0) ?? kindHeight(t)
        let fill = isFill(t)
        var w: Int
        if fill {
            w = availW > 0 ? availW : kindFallbackW(t)
        } else {
            switch t {
            case "text":
                w = textW(n, "content", ctx)
            case "button":
                w = textW(n, "label", ctx) + 16
            case "checkbox", "toggle":
                w = 16 + 4 + textW(n, "label", ctx)
            case "color_swatch":
                w = 16
            case "icon_button":
                w = 24
            case "icon":
                w = 20
            default:
                w = 0
            }
        }
        if let x = resolveDim(st["width"], availW) { w = x }
        if let m = resolveDim(st["min_width"], availW) { w = max(w, m) }
        return (w, h, fill)
    }

    /// Returns (w, h, items) with item coords RELATIVE to this node's origin.
    private static func measure(_ n: [String: Any], path: [Int], availW: Int,
                               availH: Int, ctx: [String: Any]) -> (Int, Int, [MItem]) {
        let st = style(n)
        let (pt, pr, pb, pl) = parsePadding(st["padding"])
        let gap = styleI(n, "gap") ?? 0
        let innerW = availW - pl - pr
        let innerH = availH > 0 ? (availH - pt - pb) : 0

        if isContainer(n) {
            let chItems: [MItem]
            let contentH: Int
            if let fe = n["foreach"] as? [String: Any], n["do"] != nil {
                (chItems, contentH) = foreach(n, foreachSpec: fe, path: path,
                                              innerW: innerW, gap: gap, ctx: ctx)
            } else {
                let children = visibleChildren(n)
                let lay = resolvedLayout(n)
                if lay == "row" && children.contains(where: { hasCol($0.1) }) {
                    (chItems, contentH) = grid(children, path: path, innerW: innerW, gap: gap, ctx: ctx)
                } else if lay == "row" {
                    (chItems, contentH) = flow(children, path: path, innerW: innerW, gap: gap, ctx: ctx)
                } else {
                    (chItems, contentH) = column(children, path: path, innerW: innerW,
                                                 gap: gap, availH: innerH, ctx: ctx)
                }
            }
            let expH = resolveDim(st["height"], 0)
            let w = availW
            let h = expH ?? (contentH + pt + pb)
            var items = [MItem(path: path, x: 0, y: 0, w: w, h: h)]
            for var it in chItems {
                it.x += pl
                it.y += pt
                items.append(it)
            }
            return (w, h, items)
        } else {
            let (w, h, _) = leafSize(n, availW: availW, ctx: ctx)
            return (w, h, [MItem(path: path, x: 0, y: 0, w: w, h: h)])
        }
    }

    private static func column(_ children: [(Int, [String: Any])], path: [Int],
                              innerW: Int, gap: Int, availH: Int, ctx: [String: Any]) -> ([MItem], Int) {
        var measured: [(node: [String: Any], h: Int, items: [MItem])] = []
        for (i, c) in children {
            let (_, ch, cit) = measure(c, path: path + [i], availW: innerW, availH: 0, ctx: ctx)
            measured.append((c, ch, cit))
        }
        let n = measured.count
        let natural = measured.reduce(0) { $0 + $1.h } + (n > 0 ? gap * (n - 1) : 0)
        var extra = [Int](repeating: 0, count: n)
        if availH > 0 {
            let leftover = availH - natural
            if leftover > 0 {
                let weights = measured.map { flexWeight($0.node) }
                let sumw = weights.reduce(0, +)
                if sumw > 0 {
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
            }
        }
        var items: [MItem] = []
        var cy = 0
        for k in 0..<n {
            let ch = measured[k].h
            let hk = ch + extra[k]
            var cit = measured[k].items
            for j in cit.indices {
                cit[j].y += cy
            }
            if extra[k] != 0 && !cit.isEmpty {
                cit[0].h = hk
            }
            items.append(contentsOf: cit)
            cy += hk + gap
        }
        return (items, n > 0 ? cy - gap : 0)
    }

    private static func flow(_ children: [(Int, [String: Any])], path: [Int],
                            innerW: Int, gap: Int, ctx: [String: Any]) -> ([MItem], Int) {
        // Measure each child at intrinsic width (avail = -1).
        var measured: [(c: [String: Any], w: Int, h: Int, items: [MItem])] = []
        for (i, c) in children {
            let (cw, ch, cit) = measure(c, path: path + [i], availW: -1, availH: 0, ctx: ctx)
            measured.append((c, cw, ch, cit))
        }
        let n = measured.count
        let fixed = measured.reduce(0) { $0 + $1.w } + (n > 0 ? gap * (n - 1) : 0)
        let leftover = max(0, innerW - fixed)
        let weights = measured.map { flexWeight($0.c) }
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

    private static func grid(_ children: [(Int, [String: Any])], path: [Int],
                            innerW: Int, gap: Int, ctx: [String: Any]) -> ([MItem], Int) {
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
                let (_, ch, cit) = measure(c, path: path + [i], availW: cellW, availH: 0, ctx: ctx)
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

    /// Expand a foreach container's `do` template once per item, laid out per
    /// the container's `layout`: `column` (vertical stack), `row` (horizontal,
    /// single line), or `wrap` (horizontal, wrapping at `innerW`).
    ///
    /// Each item is bound as `foreach.as` (plus `_index`) in a child scope.
    /// Row/wrap items are measured at intrinsic width; `itemW` is the subtree's
    /// actual extent (so a container item gets its content width, not the
    /// unbounded sentinel), and the item's own rect width is corrected to that.
    private static func foreach(_ node: [String: Any], foreachSpec spec: [String: Any],
                               path: [Int], innerW: Int, gap: Int, ctx: [String: Any]) -> ([MItem], Int) {
        let src = (spec["source"] as? String) ?? ""
        let varName = (spec["as"] as? String) ?? "item"
        let template = (node["do"] as? [String: Any]) ?? [:]
        let lay = (node["layout"] as? String) ?? "column"

        var rawItems: [Any] = []
        if !src.isEmpty {
            let res = evaluate(src, context: ctx)
            if case .list(let arr) = res {
                rawItems = arr.map { $0.value }
            }
        }

        // Measure every expansion (column fills innerW; row/wrap are intrinsic).
        let avail = lay == "column" ? innerW : -1
        var measured: [(w: Int, h: Int, items: [MItem])] = []
        for (i, item) in rawItems.enumerated() {
            var itemData: [String: Any]
            if let d = item as? [String: Any] {
                itemData = d
            } else {
                itemData = ["_value": item]
            }
            itemData["_index"] = i
            var childCtx = ctx
            childCtx[varName] = itemData
            var (w, h, cit) = measure(template, path: path + [i], availW: avail,
                                      availH: 0, ctx: childCtx)
            if lay != "column" {
                let iw = cit.map { $0.x + $0.w }.max() ?? 0
                if !cit.isEmpty {
                    cit[0].w = iw
                }
                w = iw
            }
            measured.append((w, h, cit))
        }

        var out: [MItem] = []
        if lay == "row" {
            let rowH = measured.map { $0.h }.max() ?? 0
            var cx = 0
            for m in measured {
                let dy = (rowH - m.h) / 2
                var cit = m.items
                for j in cit.indices {
                    cit[j].x += cx
                    cit[j].y += dy
                }
                out.append(contentsOf: cit)
                cx += m.w + gap
            }
            return (out, rowH)
        }
        if lay == "wrap" {
            var cx = 0
            var lineY = 0
            var lineH = 0
            for m in measured {
                if cx > 0 && cx + m.w > innerW {
                    lineY += lineH + gap
                    cx = 0
                    lineH = 0
                }
                var cit = m.items
                for j in cit.indices {
                    cit[j].x += cx
                    cit[j].y += lineY
                }
                out.append(contentsOf: cit)
                cx += m.w + gap
                lineH = max(lineH, m.h)
            }
            return (out, measured.isEmpty ? 0 : lineY + lineH)
        }
        // column
        var cy = 0
        for m in measured {
            var cit = m.items
            for j in cit.indices {
                cit[j].y += cy
            }
            out.append(contentsOf: cit)
            cy += m.h + gap
        }
        return (out, measured.isEmpty ? 0 : cy - gap)
    }
}
