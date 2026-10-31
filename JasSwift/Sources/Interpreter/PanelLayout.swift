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

    private static let containerTypes: Set<String> = ["container", "row", "col", "panel", "grid"]

    private static let fillKinds: Set<String> = [
        "select", "number_input", "text_input", "length_input",
        "slider", "placeholder", "separator",
        "combo_box", "icon_select", "spacer",
        // composite / data-driven widgets: placed as a fixed box (fill width)
        "color_bar", "fill_stroke_widget", "gradient_slider", "gradient_tile",
        "dropdown", "tree_view",
    ]

    /// An intermediate item with coords RELATIVE to its node's origin.
    ///
    /// `node` is the YAML node that produced this item (the container root
    /// item carries its container node; a leaf item carries the leaf node;
    /// `foreach` expansions carry their per-row template node). `ctx` is the
    /// data scope the node should be rendered with — for a `foreach`-expanded
    /// row this is the per-row child scope (the loop var bound), which is why
    /// the render swap can render rows that `node_at_path` over `children`
    /// could never resolve. `layoutPanel` ignores both fields (it projects
    /// rects only, so its output stays byte-identical); `renderPlan` consumes
    /// them. One traversal, two projections.
    private struct MItem {
        var path: [Int]
        var x: Int
        var y: Int
        var w: Int
        var h: Int
        var node: [String: Any]
        var ctx: [String: Any]
    }

    /// One renderable leaf produced by ``renderPlan``: the node to render, the
    /// (child) scope to render it with, and its absolute rect.
    public struct RenderLeaf {
        public let x: Int
        public let y: Int
        public let w: Int
        public let h: Int
        public let node: [String: Any]
        public let ctx: [String: Any]
    }

    /// The render-side projection of the layout pass: the canonical panel
    /// content height, the layout-only containers that carry chrome (a
    /// border / background to draw BEHIND the leaves, e.g. a selected-row
    /// highlight), and one leaf per renderable widget.
    public struct RenderPlanResult {
        public let height: Int
        public let chrome: [RenderLeaf]
        public let leaves: [RenderLeaf]
    }

    /// Layout-only node types: they position their children but draw no widget
    /// of their own in the absolute render (their children are the rendered
    /// leaves). Omitted from ``renderPlan``'s leaves.
    private static let layoutContainerTypes: Set<String> = [
        "container", "row", "col", "grid", "panel", "disclosure",
    ]

    /// A layout-only node, which the render plan never sends as a leaf: the
    /// container types, and a `tree_view` laid out as its foreach expansion
    /// (STATUS-jas item 38; flask §603 measured the shell drawing a
    /// `tree_view` placeholder behind the rows when this test read the type
    /// alone).
    private static func isLayoutOnly(_ n: [String: Any]) -> Bool {
        if nodeType(n) == "tree_view" { return isContainer(n) }
        return layoutContainerTypes.contains(nodeType(n))
    }

    /// A layout-only container still worth drawing — it carries a border /
    /// background (static `style.border` / `style.background` / `style.bg`, or a
    /// `bind.background`, e.g. a selected-row highlight). Mirrors
    /// `panel_layout.py`'s `_has_chrome`.
    private static func hasChrome(_ n: [String: Any]) -> Bool {
        let st = style(n)
        if st["border"] != nil || st["background"] != nil || st["bg"] != nil {
            return true
        }
        if let b = n["bind"] as? [String: Any], b["background"] != nil {
            return true
        }
        return false
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

    /// Render-side projection of the same layout pass. Returns the canonical
    /// panel content height (the root item's height, incl. padding), the
    /// `chrome` entries (layout-only containers carrying a border/background to
    /// draw BEHIND the leaves), and one leaf per renderable widget — each
    /// carrying the rect, the node to render, and the (child) scope `ctx` to
    /// render it with (so a `foreach`-expanded leaf carries its per-row scope).
    /// Layout-only nodes (container / row / col / grid / panel / disclosure)
    /// without chrome are omitted entirely.
    ///
    /// The cross-app byte-gate consumes ``layoutPanel`` (rects only); the
    /// render swaps consume this. One traversal, two projections. Mirrors
    /// `panel_layout.py`'s `render_plan` (PATH_B_DESIGN.md Appendix B).
    public static func renderPlan(_ panelNode: [String: Any], availW: Int,
                                  availH: Int = 0, ctx: [String: Any] = [:]) -> RenderPlanResult {
        guard let root = panelNode["content"] as? [String: Any] else {
            return RenderPlanResult(height: 0, chrome: [], leaves: [])
        }
        let (_, _, items) = measure(root, path: [], availW: availW, availH: availH, ctx: ctx)
        let height = items.first?.h ?? 0
        var chrome: [RenderLeaf] = []
        var out: [RenderLeaf] = []
        for it in items {
            let entry = RenderLeaf(x: it.x, y: it.y, w: it.w, h: it.h,
                                   node: it.node, ctx: it.ctx)
            if isLayoutOnly(it.node) {
                // Layout-only container: omitted unless it carries chrome
                // (a border / background) worth drawing behind the leaves.
                if hasChrome(it.node) { chrome.append(entry) }
            } else {
                out.append(entry)
            }
        }
        return RenderPlanResult(height: height, chrome: chrome, leaves: out)
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

    /// A JSON integer, as the reference's `isinstance(v, int)` reads one: a
    /// float (`1.0`) is NOT an integer here, so a `grid` cell given as a float
    /// falls back to reading order, as in the reference and Rust.
    private static func strictInt(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, !CFNumberIsFloatType(n),
              CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.intValue
    }

    /// A number (int or float, truncated), as the reference's
    /// `isinstance(v, (int, float))` reads one: never a string.
    private static func numI(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.intValue
    }

    /// A container's gap: `style.gap`, else (B.7) a 2-D grid's own `gap` key,
    /// the toolbar's form. The reference's `_gap`, read in both `measure` and
    /// `natural_w`.
    private static func gap(_ n: [String: Any]) -> Int {
        if let g = styleI(n, "gap") { return g }
        if nodeType(n) == "grid", let g = numI(n["gap"]) { return g }
        return 0
    }

    /// B.7: a 2-D grid's column count, at least 1.
    private static func gridCols(_ n: [String: Any]) -> Int {
        max(numI(n["cols"]) ?? 1, 1)
    }

    /// Resolve a style dimension to integer px, or nil to ignore. Numbers
    /// truncate toward zero; `"N%"` is `(avail*N)/100` (ignored when avail <= 0,
    /// e.g. heights); a bare numeric string is that int; anything else
    /// (`"auto"`, junk) is ignored.
    /// Internal rather than private so `R9GuardedCastTests` can hold its two
    /// float branches to Rust's `f as i64` (interpreter/panel_layout.rs).
    /// A style dimension as written, with a template (`"{{node.depth * 16}}"`,
    /// the Layers row's indent, STATUS-jas item 38) evaluated in the node's
    /// scope first, as a bound text is; `resolveDim` then reads the number. A
    /// template that does not yield a number resolves to nil, as any
    /// unparsable dimension does.
    static func dim(_ v: Any?, _ ctx: [String: Any]) -> Any? {
        if let s = v as? String, s.contains("{{") { return evaluateText(s, context: ctx) }
        return v
    }

    static func resolveDim(_ v: Any?, _ avail: Int) -> Int? {
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
                    // saturatingInt mirrors Rust's `f as i64`. `Double("nan")`
                    // and `Double("1e400")` both succeed, so a hand-authored
                    // `width: "nan%"` trapped here (risk R9).
                    p = saturatingInt(f)
                } else {
                    return nil
                }
                return avail > 0 ? (avail * p) / 100 : nil
            }
            if let i = Int(s) { return i }
            if let f = Double(s) { return saturatingInt(f) }
            return nil
        }
        return nil
    }

    private static func isContainer(_ n: [String: Any]) -> Bool {
        // A `tree_view` that declares a `foreach` + `do` (the Layers tree,
        // STATUS-jas item 38) is laid out as its expansion, like any foreach
        // container; one without them stays a fixed leaf.
        if nodeType(n) == "tree_view" {
            return n["foreach"] is [String: Any] && n["do"] != nil && !(n["do"] is NSNull)
        }
        return containerTypes.contains(nodeType(n))
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
    /// A `radio_group`'s options in a row: each a 16 indicator plus, when it
    /// has a label, a 4 gap and the label; options 6 apart. Computed options
    /// (an expression) have no declared rows, so the width is 0.
    private static func radioGroupW(_ n: [String: Any], _ ctx: [String: Any]) -> Int {
        guard let options = n["options"] as? [Any] else { return 0 }
        let widths = options.compactMap { $0 as? [String: Any] }.map { o -> Int in
            let labelled = !((o["label"] as? String) ?? "").isEmpty
            return 16 + (labelled ? 4 + textW(o, "label", ctx) : 0)
        }
        return widths.reduce(0, +) + 6 * max(widths.count - 1, 0)
    }

    /// A button's label as it draws: `bind.label` evaluated as an expression
    /// when that yields a string, else the static `label` (Rust
    /// `render_button`). Measuring the static key alone planned a bound label
    /// at 0 (flask STATUS §569, finding L). Rust's `button_label_w`.
    private static func buttonLabelW(_ n: [String: Any], _ ctx: [String: Any]) -> Int {
        if let expr = (n["bind"] as? [String: Any])?["label"] as? String,
           case .string(let s) = evaluate(expr, context: ctx) {
            return s.unicodeScalars.count * charWidth
        }
        return textW(n, "label", ctx)
    }

    private static func textW(_ n: [String: Any], _ key: String, _ ctx: [String: Any]) -> Int {
        guard let raw = n[key] as? String else { return 0 }
        let resolved = evaluateText(raw, context: ctx)
        return resolved.unicodeScalars.count * charWidth
    }

    private static func isFill(_ kind: String) -> Bool {
        fillKinds.contains(kind)
    }

    /// Flex weight: explicit `style.flex`, or implicit 1 for a `spacer` that
    /// declares no width (the Layers indent is `width: depth * 16` and must
    /// not grow on a short row).
    private static func flexWeight(_ n: [String: Any]) -> Int {
        let w = styleI(n, "flex") ?? 0
        return (w == 0 && nodeType(n) == "spacer" && style(n)["width"] == nil) ? 1 : w
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
        case "reference_point_widget": return 28
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

    /// True when a node draws nothing, so it takes no space (CSS `display:
    /// none`): a static `visible: false`, or a dynamic `visible: <expr>` /
    /// `bind.visible` that evaluates false in the node's scope (reference
    /// `_hidden`). A bound-hidden child that kept its width over-subscribed
    /// its row (the Layers rename field squeezed the indent, flask STATUS §617).
    private static func hidden(_ n: [String: Any], _ ctx: [String: Any]) -> Bool {
        if let vis = n["visible"] as? Bool, vis == false { return true }
        let exprs = [n["visible"] as? String,
                     (n["bind"] as? [String: Any])?["visible"] as? String]
        return exprs.compactMap { $0 }.contains { !evaluate($0, context: ctx).toBool() }
    }

    private static func visibleChildren(_ n: [String: Any],
                                        _ ctx: [String: Any]) -> [(Int, [String: Any])] {
        var out: [(Int, [String: Any])] = []
        guard let ch = n["children"] as? [Any] else { return out }
        for (i, c) in ch.enumerated() {
            guard let c = c as? [String: Any], !hidden(c, ctx) else { continue }
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
        // B.9: a declared size is the leaf's width and height.
        let size = sizeI(n)
        let h = resolveDim(st["height"], 0) ?? size ?? kindHeight(t)
        let fill = isFill(t)
        var w: Int
        if let sz = size {
            w = sz
        } else if fill {
            w = availW > 0 ? availW : kindFallbackW(t)
        } else {
            switch t {
            case "text":
                w = textW(n, "content", ctx)
            case "button":
                w = buttonLabelW(n, ctx) + 16
            case "checkbox", "toggle", "radio":
                w = 16 + 4 + textW(n, "label", ctx)
            case "radio_group":
                w = radioGroupW(n, ctx)
            case "reference_point_widget":
                w = 28  // the web's repeat(3, 8px), gap 2px
            case "icon_button_group":
                let k = (n["options"] as? [Any])?.count ?? 0
                w = 24 * k + 4 * max(k - 1, 0)
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
        if let x = resolveDim(dim(st["width"], ctx), availW) { w = x }
        if let m = resolveDim(dim(st["min_width"], ctx), availW) { w = max(w, m) }
        return (w, h, fill)
    }

    /// B.9: a leaf's `style.size` (a number), truncated; else nil.
    private static func sizeI(_ n: [String: Any]) -> Int? {
        numI(style(n)["size"])
    }

    /// ROW 62 (STATUS-flask §703), the reference's `_leaf_h`: a leaf's height at
    /// its FINAL width `w`. A declared `height` (or B.9's `size`) is the height;
    /// else an `aspect_ratio` (width / height) gives `w / r`, rounded half away
    /// from zero; else the kind's height. Then `min_height` floors it.
    private static func leafH(_ n: [String: Any], _ w: Int) -> Int {
        let st = style(n)
        var h: Int
        if let d = resolveDim(st["height"], 0) {
            h = d
        } else if let sz = sizeI(n) {
            h = sz
        } else if let r = aspectRatio(n) {
            h = Int((Double(w) / r).rounded(.toNearestOrAwayFromZero))
        } else {
            h = kindHeight(nodeType(n))
        }
        if let floor = resolveDim(st["min_height"], 0) { h = max(h, floor) }
        return h
    }

    /// Row 62: a leaf's `style.aspect_ratio` (width / height), a positive
    /// number; else nil. A bool or a string is not a number here.
    private static func aspectRatio(_ n: [String: Any]) -> Double? {
        guard let v = style(n)["aspect_ratio"] as? NSNumber,
              CFGetTypeID(v) != CFBooleanGetTypeID() else { return nil }
        return v.doubleValue > 0 ? v.doubleValue : nil
    }

    /// STATUS-flask 705 (1b), the reference's `_floor_w`: the least width a row
    /// may shrink `n` to, as CSS `min-width` beats `flex-shrink`. A leaf's floor
    /// is its declared `min_width` (a percentage has nothing to resolve against
    /// and is ignored). A container's is its content's, as a flex item's
    /// automatic minimum is: a row sums its cells' floors and gaps, any other
    /// container takes its widest child's, both plus padding. A node with no
    /// floor anywhere inside it has 0 and shrinks as before.
    private static func floorW(_ n: [String: Any], _ ctx: [String: Any]) -> Int {
        if !(isContainer(n) || nodeType(n) == "disclosure") {
            if let f = resolveDim(dim(style(n)["min_width"], ctx), -1), f > 0 { return f }
            return 0
        }
        if n["foreach"] is [String: Any] { return 0 }
        let (kids, _) = splitPositioned(visibleChildren(n, ctx))
        let floors = kids.map { floorW($0.1, ctx) }
        if floors.allSatisfy({ $0 == 0 }) { return 0 }
        let (_, pr, _, pl) = parsePadding(style(n)["padding"])
        let inner: Int
        if nodeType(n) != "disclosure" && resolvedLayout(n) == "row" && !kids.contains(where: { hasCol($0.1) }) {
            inner = floors.reduce(0, +) + gap(n) * (kids.count - 1)
        } else {
            inner = floors.max() ?? 0
        }
        return inner + pl + pr
    }

    /// STATUS-flask 705 (2), the reference's `_stretch_h`: a row's cross-axis
    /// rule, CSS `align-items: stretch`. nil when the row declares an alignment
    /// other than `stretch`: its leaves are centred, as before. Otherwise the
    /// height its heightless leaves take: its declared height less its
    /// padding, or 0 for "its tallest child".
    private static func stretchH(_ n: [String: Any], _ pt: Int, _ pb: Int) -> Int? {
        let a = style(n)["alignment"]
        if let a = a, !(a is NSNull), (a as? String) != "stretch" { return nil }
        if let h = resolveDim(style(n)["height"], 0) { return max(h - pt - pb, 0) }
        return 0
    }

    /// STATUS-flask 705 (2), the reference's `_stretches`: a leaf that declares
    /// no `height`, `size` or `aspect_ratio`.
    private static func stretches(_ n: [String: Any]) -> Bool {
        if isContainer(n) || nodeType(n) == "disclosure" { return false }
        return resolveDim(style(n)["height"], 0) == nil && sizeI(n) == nil && aspectRatio(n) == nil
    }

    /// STATUS-flask 705 (1b), the reference's `_shrink`: shrink `nat` to sum to
    /// `avail`, each cell in proportion to its natural width but never below
    /// its floor. A cell whose share would fall below its floor is frozen there
    /// and the rest are re-shared, until none is; the rounding remainder then
    /// goes one pixel at a time to the unfrozen cells in order. When the floors
    /// alone exceed `avail`, every cell shrinks in proportion as before.
    private static func shrink(_ nat: [Int], _ floorsIn: [Int], _ avail: Int) -> [Int] {
        let n = nat.count
        var floors = (0..<n).map { min(floorsIn[$0], nat[$0]) }
        if floors.reduce(0, +) > avail { floors = Array(repeating: 0, count: n) }
        var widths = Array(repeating: 0, count: n)
        var frozen = Array(repeating: false, count: n)
        while true {
            let free = (0..<n).filter { !frozen[$0] }
            let space = avail - (0..<n).filter { frozen[$0] }.map { widths[$0] }.reduce(0, +)
            let total = free.map { nat[$0] }.reduce(0, +)
            func share(_ k: Int) -> Int { total > 0 ? nat[k] * space / total : 0 }
            let over = free.filter { share($0) < floors[$0] }
            if over.isEmpty {
                for k in free { widths[k] = share(k) }
                break
            }
            for k in over {
                frozen[k] = true
                widths[k] = floors[k]
            }
        }
        var rem = avail - widths.reduce(0, +)
        let unfrozen = (0..<n).filter { !frozen[$0] }
        let order = unfrozen.isEmpty ? Array(0..<n) : unfrozen
        var j = 0
        while rem > 0 && !order.isEmpty {
            widths[order[j]] += 1
            rem -= 1
            j = (j + 1) % order.count
        }
        return widths
    }

    /// B.8: a child's `style.position` as integer `(x, y)` when it is two
    /// numbers; else nil, and the child stays in its parent's flow.
    private static func positionI(_ n: [String: Any]) -> (Int, Int)? {
        guard let pos = style(n)["position"] as? [String: Any],
              let x = numI(pos["x"]), let y = numI(pos["y"]) else { return nil }
        return (x, y)
    }

    /// `(flow, positioned)`: B.8 takes a positioned child out of the flow.
    private static func splitPositioned(_ children: [(Int, [String: Any])])
        -> ([(Int, [String: Any])], [(Int, [String: Any])]) {
        (children.filter { positionI($0.1) == nil }, children.filter { positionI($0.1) != nil })
    }

    /// B.8: each positioned child at its own point, measured at the width to
    /// the parent's right edge. Returns its items and the lowest bottom.
    private static func positioned(_ placed: [(Int, [String: Any])], path: [Int], innerW: Int,
                                   ctx: [String: Any]) -> ([MItem], Int) {
        var items: [MItem] = []
        var bottom = 0
        for (i, c) in placed {
            guard let (x, y) = positionI(c) else { continue }
            let (_, ch, cit) = measure(c, path: path + [i], availW: max(innerW - x, 0),
                                       availH: 0, ctx: ctx)
            for var it in cit {
                it.x += x
                it.y += y
                items.append(it)
            }
            bottom = max(bottom, y + ch)
        }
        return (items, bottom)
    }

    /// Group `(i, node)` children into Bootstrap-12 rows by their `col` span.
    /// Mirrors `panel_layout.py`'s `_grid_lines`. Used by `naturalW` to find a
    /// grid container's widest 12-col line.
    private static func gridLines(_ children: [(Int, [String: Any])]) -> [[(Int, [String: Any], Int)]] {
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
        return lines
    }

    /// Min-content width a node wants, ignoring the width available to it.
    ///
    /// A leaf reports its own intrinsic width; a container reports the width its
    /// content needs (row = sum of children + gaps, column = widest child, grid
    /// = widest 12-col line). Used so a row can grow cells / columns to fit
    /// nested content and shrink-to-fit deterministically when over-subscribed,
    /// instead of letting a wide label or input overrun its neighbour. Mirrors
    /// `panel_layout.py`'s `_natural_w`.
    private static func naturalW(_ node: [String: Any], _ ctx: [String: Any]) -> Int {
        if !(isContainer(node) || nodeType(node) == "disclosure") {
            return leafSize(node, availW: -1, ctx: ctx).0
        }
        let st = style(node)
        // B.5: a declared width is the container's natural width. A percentage
        // has nothing to resolve against here and is ignored, as a leaf's is.
        if let declared = resolveDim(dim(st["width"], ctx), -1) { return declared }
        let (_, pr, _, pl) = parsePadding(st["padding"])
        let gap = gap(node)
        if nodeType(node) == "disclosure" {
            let kids = visibleChildren(node, ctx)
            let inner = kids.map { naturalW($0.1, ctx) }.max() ?? 0
            return inner + pl + pr
        }
        if node["foreach"] as? [String: Any] != nil, node["do"] != nil {
            let template = (node["do"] as? [String: Any]) ?? [:]
            return naturalW(template, ctx) + pl + pr
        }
        let (kids, placed) = splitPositioned(visibleChildren(node, ctx))
        // B.8: the natural width reaches the rightmost positioned child.
        let reach = placed.map { (positionI($0.1)?.0 ?? 0) + naturalW($0.1, ctx) }.max() ?? 0
        return max(flowNaturalW(node, kids, gap, ctx) + pl + pr, reach + pl)
    }

    /// The natural width of a container's FLOW children (B.8: positioned
    /// children are not in it), without padding.
    private static func flowNaturalW(_ node: [String: Any], _ kids: [(Int, [String: Any])],
                                     _ gap: Int, _ ctx: [String: Any]) -> Int {
        let lay = resolvedLayout(node)
        if lay == "row" && kids.contains(where: { hasCol($0.1) }) {
            var best = 0
            for line in gridLines(kids) {
                let m = line.count
                let lineW = line.reduce(0) { $0 + naturalW($1.1, ctx) } + gap * (m > 0 ? m - 1 : 0)
                best = max(best, lineW)
            }
            return best
        }
        if lay == "row" {
            let n = kids.count
            return kids.reduce(0) { $0 + naturalW($1.1, ctx) } + (n > 0 ? gap * (n - 1) : 0)
        }
        return kids.map { naturalW($0.1, ctx) }.max() ?? 0
    }

    /// Returns (w, h, items) with item coords RELATIVE to this node's origin.
    private static func measure(_ n: [String: Any], path: [Int], availW: Int,
                               availH: Int, ctx: [String: Any]) -> (Int, Int, [MItem]) {
        let st = style(n)
        let (pt, pr, pb, pl) = parsePadding(st["padding"])
        let gap = gap(n)
        // B.5: a container's declared width is honoured as its height is (B.4),
        // clamped to the width it is given; its children are laid out in it.
        var availW = availW
        if isContainer(n) || nodeType(n) == "disclosure",
           let declared = resolveDim(dim(st["width"], ctx), availW) {
            availW = availW > 0 ? min(declared, availW) : declared
        }
        let innerW = availW - pl - pr
        let innerH = availH > 0 ? (availH - pt - pb) : 0

        if isContainer(n) || nodeType(n) == "disclosure" {
            let chItems: [MItem]
            let contentH: Int
            if nodeType(n) == "disclosure" {
                (chItems, contentH) = disclosure(n, path: path, innerW: innerW, gap: gap, ctx: ctx)
            } else if let fe = n["foreach"] as? [String: Any], n["do"] != nil {
                (chItems, contentH) = foreach(n, foreachSpec: fe, path: path,
                                              innerW: innerW, gap: gap, ctx: ctx)
            } else if nodeType(n) == "grid" {
                (chItems, contentH) = grid2d(visibleChildren(n, ctx), path: path, innerW: innerW,
                                             gap: gap, cols: gridCols(n), ctx: ctx)
            } else {
                let (children, placed) = splitPositioned(visibleChildren(n, ctx))
                let lay = resolvedLayout(n)
                var flowItems: [MItem]
                var flowH: Int
                if lay == "row" && children.contains(where: { hasCol($0.1) }) {
                    (flowItems, flowH) = grid(children, path: path, innerW: innerW, gap: gap, ctx: ctx)
                } else if lay == "row" {
                    (flowItems, flowH) = flow(children, path: path, innerW: innerW, gap: gap, ctx: ctx,
                                              stretch: stretchH(n, pt, pb))
                } else {
                    (flowItems, flowH) = column(children, path: path, innerW: innerW,
                                                gap: gap, availH: innerH, ctx: ctx)
                }
                if !placed.isEmpty {
                    let (pItems, pBottom) = positioned(placed, path: path, innerW: innerW, ctx: ctx)
                    flowH = max(flowH, pBottom)
                    // Pre-order in child-index order: each child's items are
                    // contiguous and lead with the child's own path. Swift's
                    // sort is not stable, so the original position breaks ties.
                    let depth = path.count
                    flowItems = (flowItems + pItems).enumerated()
                        .sorted { ($0.element.path[depth], $0.offset) < ($1.element.path[depth], $1.offset) }
                        .map { $0.element }
                }
                (chItems, contentH) = (flowItems, flowH)
            }
            let expH = resolveDim(st["height"], 0)
            // Fill the width given; with no constraint (availW <= 0) report the
            // container's natural content width so a parent row can size it.
            let w = availW > 0 ? availW : naturalW(n, ctx)
            var h = expH ?? (contentH + pt + pb)
            // B.6: a declared min_height floors the height, declared or content.
            if let m = resolveDim(st["min_height"], 0) { h = max(h, m) }
            var items = [MItem(path: path, x: 0, y: 0, w: w, h: h, node: n, ctx: ctx)]
            for var it in chItems {
                it.x += pl
                it.y += pt
                items.append(it)
            }
            return (w, h, items)
        } else {
            let (lw, _, _) = leafSize(n, availW: availW, ctx: ctx)
            // A leaf renders at its own width regardless of its slot; clamp it
            // to the width available so it cannot overrun a neighbour.
            let w = (availW > 0 && lw > availW) ? availW : lw
            let h = leafH(n, w)
            return (w, h, [MItem(path: path, x: 0, y: 0, w: w, h: h, node: n, ctx: ctx)])
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
                            innerW: Int, gap: Int, ctx: [String: Any],
                            stretch: Int? = nil) -> ([MItem], Int) {
        let n = children.count
        let nat = children.map { naturalW($0.1, ctx) }
        let weights = children.map { flexWeight($0.1) }
        let sumw = weights.reduce(0, +)
        let fixed = nat.reduce(0, +) + (n > 0 ? gap * (n - 1) : 0)
        var widths = nat
        if innerW > 0 && fixed > innerW {
            // Over-subscribed: shrink every cell proportionally to fit the row,
            // never below a floor it declares (STATUS-flask 705 (1b)).
            let avail = innerW - gap * (n > 0 ? n - 1 : 0)
            let total = nat.reduce(0, +)
            if total > 0 && avail > 0 {
                widths = shrink(nat, children.map { floorW($0.1, ctx) }, avail)
            }
        } else if innerW > 0 && sumw > 0 {
            // Fits: distribute the leftover width to flex-weighted children.
            let leftover = innerW - fixed
            if leftover > 0 {
                var base = (0..<n).map { leftover * weights[$0] / sumw }
                var rem = leftover - base.reduce(0, +)
                for k in 0..<n {
                    if rem <= 0 { break }
                    if weights[k] > 0 {
                        base[k] += 1
                        rem -= 1
                    }
                }
                widths = (0..<n).map { nat[$0] + base[$0] }
            }
        }
        // Lay each child out at its final width; a leaf already clamps itself to
        // the width it is given (see measure), so nothing overruns the next cell.
        var placed: [(items: [MItem], h: Int)] = []
        var rowH = 0
        for (k, (i, c)) in children.enumerated() {
            let (_, ch, cit0) = measure(c, path: path + [i], availW: widths[k], availH: 0, ctx: ctx)
            var cit = cit0
            if !cit.isEmpty && cit[0].w > widths[k] {
                cit[0].w = widths[k]
            }
            placed.append((cit, ch))
            rowH = max(rowH, ch)
        }
        // STATUS-flask 705 (2), CSS's align-items: stretch. A heightless leaf
        // takes the row's inner height (its declared one, else its tallest
        // child), floored by the leaf's own min_height, and sits at the top.
        let stretched = children.indices.map { k in
            stretch != nil && !placed[k].items.isEmpty && stretches(children[k].1)
        }
        if stretched.contains(true) {
            let lineH: Int
            if let st = stretch, st > 0 { lineH = st } else { lineH = rowH }
            for k in children.indices where stretched[k] {
                let floor = resolveDim(style(children[k].1)["min_height"], 0)
                let sh = floor.map { max(lineH, $0) } ?? lineH
                placed[k].items[0].h = sh
                placed[k].h = sh
                rowH = max(rowH, sh)
            }
        }
        var items: [MItem] = []
        var cx = 0
        for k in 0..<placed.count {
            let ch = placed[k].h
            var cit = placed[k].items
            let dy = stretched[k] ? 0 : (rowH - ch) / 2
            for j in cit.indices {
                cit[j].x += cx
                cit[j].y += dy
            }
            items.append(contentsOf: cit)
            cx += widths[k] + gap
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
            let n = line.count
            // Each cell wants at least its Bootstrap-12 share, grown to fit its
            // content's intrinsic width: a leaf renders at its own width
            // regardless of how narrow its column is, so a wide label / icon must
            // not overrun its neighbour. Layout containers fill their cell, so
            // they contribute no intrinsic minimum (they shrink/grow with it).
            var desired: [Int] = []
            for (_, c, span) in line {
                let bw = (2 * innerW * span + 12) / 24 // round-half-up, exact
                desired.append(max(bw, naturalW(c, ctx)))
            }
            let avail = innerW - gap * (n - 1)
            let total = desired.reduce(0, +)
            var widths: [Int]
            if total <= avail || total <= 0 {
                widths = desired
            } else if avail > 0 {
                // Over-subscribed row: shrink cells in proportion, never below
                // a floor a cell declares, as `flow` does (STATUS-jas row 68).
                // With no floor this is the proportional rule below, remainder
                // order included.
                widths = shrink(desired, line.map { floorW($0.1, ctx) }, avail)
            } else {
                // Over-subscribed row: shrink cells proportionally to fit, then
                // hand the rounding remainder out one pixel at a time.
                widths = desired.map { $0 * avail / total }
                var rem = avail - widths.reduce(0, +)
                var k = 0
                while rem > 0 {
                    widths[k] += 1
                    rem -= 1
                    k = (k + 1) % n
                }
            }
            var cx = 0
            var lineH = 0
            var cells: [(items: [MItem], h: Int, cellX: Int)] = []
            for (idx, (i, c, _)) in line.enumerated() {
                let cellW = widths[idx]
                let (_, ch, cit0) = measure(c, path: path + [i], availW: cellW, availH: 0, ctx: ctx)
                var cit = cit0
                // Clamp the child to its cell so it cannot overrun the next column.
                if !cit.isEmpty && cit[0].w > cellW {
                    cit[0].w = cellW
                }
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

    /// Canonical disclosure header bar height.
    private static let disclosureHeaderH = 24

    /// A disclosure is a header bar (the bound label) + a body. v1 lays out the
    /// body (children, column) below a fixed-height header (assumed expanded);
    /// the header is drawn by the widget itself (no separate rect). The body's
    /// inner foreach (swatch / brush grids) expands through the normal recursion.
    /// B.7: a 2-D `type: grid` -- `cols` columns, `gap` between cells. The
    /// reference's `_grid2d` and Rust's `grid_2d`, line for line: cell width
    /// `(innerW - gap*(cols-1)) / cols` (floored, never below 0); the cell at
    /// column `c` starts at `c * (cw + gap)`; a child's cell is its
    /// `grid: {row, col}` (the column clamped), else the next cell in reading
    /// order after the previous child's; a row is as tall as its tallest child;
    /// rows are `gap` apart, top to bottom by row number, and a row number no
    /// child uses takes no space.
    private static func grid2d(_ children: [(Int, [String: Any])], path: [Int],
                               innerW: Int, gap: Int, cols: Int,
                               ctx: [String: Any]) -> ([MItem], Int) {
        func floorDiv(_ a: Int, _ b: Int) -> Int {
            let q = a / b
            return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
        }
        let cw = innerW > 0 ? max(floorDiv(innerW - gap * (cols - 1), cols), 0) : 0
        var placed: [(r: Int, k: Int, i: Int, c: [String: Any])] = []
        var next = 0
        for (i, c) in children {
            let r: Int, k: Int
            if let g = c["grid"] as? [String: Any], let gr = strictInt(g["row"]),
               let gc = strictInt(g["col"]) {
                r = gr
                k = min(max(gc, 0), cols - 1)
            } else {
                r = floorDiv(next, cols)
                k = next - r * cols
            }
            next = r * cols + k + 1
            placed.append((r, k, i, c))
        }
        var measured: [(r: Int, k: Int, h: Int, items: [MItem])] = []
        for p in placed {
            let (_, h, items) = measure(p.c, path: path + [p.i], availW: cw, availH: 0, ctx: ctx)
            measured.append((p.r, p.k, h, items))
        }
        let rows = Array(Set(measured.map { $0.r })).sorted()
        var rowY: [Int: Int] = [:]
        var y = 0
        for r in rows {
            rowY[r] = y
            y += (measured.filter { $0.r == r }.map { $0.h }.max() ?? 0) + gap
        }
        let contentH = rows.isEmpty ? 0 : y - gap
        var out: [MItem] = []
        for m in measured {
            for var it in m.items {
                it.x += m.k * (cw + gap)
                it.y += rowY[m.r] ?? 0
                out.append(it)
            }
        }
        return (out, contentH)
    }

    private static func disclosure(_ node: [String: Any], path: [Int],
                                  innerW: Int, gap: Int, ctx: [String: Any]) -> ([MItem], Int) {
        let children = visibleChildren(node, ctx)
        var (chItems, bodyH) = column(children, path: path, innerW: innerW,
                                      gap: gap, availH: 0, ctx: ctx)
        for j in chItems.indices {
            chItems[j].y += disclosureHeaderH
        }
        return (chItems, disclosureHeaderH + bodyH)
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
