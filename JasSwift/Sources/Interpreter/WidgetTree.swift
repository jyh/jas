// Shared canonical panel widget-TREE snapshot pass (TESTING_STRATEGY.md §4).
//
// Swift port of `workspace_interpreter/widget_tree.py`. The structural sibling
// of `PanelLayout.layoutPanel`: where the layout pass computes per-widget
// rects, this pass emits a per-widget *structural record*, byte-identical
// across all four native apps, so the panel widget tree itself — its shape,
// kinds, and which widgets dispatch vs. fall to a placeholder — is a cross-app
// byte-gate instead of five framework renderings eyeballed side by side.
//
// It closes the panel-bug classes that are about *structure* rather than
// geometry: a widget an app drops surfaces as a row present in the golden but
// not the app's output; a widget whose `type:` is outside the canonical
// vocabulary records as `kind: "placeholder"` (≠ its declared `type`); a
// statically hidden (`visible: false`) widget is *recorded* (not dropped,
// unlike the layout pass) with `visible: false`.
//
// Determinism / portability (the same contract as `PanelLayout`): every field
// is read straight from the compiled bundle; the ONLY expression evaluated is a
// `foreach` source — the exact same `evaluate(_:context:)` call `layoutPanel`'s
// foreach already makes (and the panel_layout corpus already pins), so no new
// cross-language eval surface is introduced. `bind` / `style` record the SORTED
// KEY SETS (not the expressions/values), so the snapshot captures structure
// without depending on per-value formatting. Output is a pre-order (parent
// before children) list of records; `path` is the node's tree path relative to
// the panel content root (root = `[]`, its i-th declared child = `[i]`, a
// foreach's i-th expansion = `[..., i]`) — the same path scheme as
// `PanelLayout` except that statically-hidden children are kept.

import Foundation

public enum WidgetTree {
    // Canonical widget-kind vocabulary: the union of kinds rendered by at least
    // one app's panel/dialog dispatch. The single source of truth lives in
    // Python (`widget_tree.CANONICAL_WIDGET_KINDS`); the four native ports each
    // bake a copy and the panel_widget_tree.json golden enforces that they stay
    // in sync — a drifted copy changes a `kind` from its `type` to "placeholder"
    // (or back) and reddens the cross-app gate.
    private static let canonicalWidgetKinds: Set<String> = [
        "container", "row", "col", "grid",
        "text", "button", "icon", "icon_button", "icon_select",
        "slider", "number_input", "text_input", "length_input",
        "toggle", "checkbox", "select", "combo_box", "dropdown",
        "color_swatch", "color_gradient", "color_hue_bar", "color_bar",
        "radio_group", "radio", "gradient_tile", "gradient_slider",
        "separator", "spacer", "disclosure", "panel",
        "fill_stroke_widget", "tree_view", "element_preview", "tabs",
        "icon_button_group", "reference_point_widget",
        "brush_preview",
        "placeholder",
    ]

    /// Walk a compiled panel node (`{"type":"panel","content":<root>}`) into a
    /// pre-order list of structural records.
    ///
    /// `ctx` is the data scope (`state` / `panel` / `data` / `active_document`
    /// namespaces) used only to evaluate `foreach` sources; defaults to empty
    /// (a foreach over an undefined source expands to nothing).
    public static func widgetTree(_ panelNode: [String: Any], ctx: [String: Any] = [:]) -> [[String: Any]] {
        guard let root = panelNode["content"] as? [String: Any] else {
            return []
        }
        var out: [[String: Any]] = []
        walk(root, path: [], ctx: ctx, out: &out)
        return out
    }

    // MARK: - typed JSON readers

    /// A node field read as a String, or `nil` if absent / not a string.
    private static func asString(_ v: Any?) -> String? {
        v as? String
    }

    /// Distinguish a real JSON boolean from a number. JSONSerialization boxes
    /// both `true`/`false` and the integers `0`/`1` as NSNumber, and a bare
    /// `as? Bool` would bridge `NSNumber(0)`→false; the objCType encoding
    /// (`c` / `B` ⇒ CFBoolean) is the correct bool-vs-number discriminator —
    /// the same test `Value.fromJson` uses. Returns the bool only for a real
    /// boolean, `nil` for a number / anything else.
    private static func asBool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber else { return nil }
        let t = String(cString: n.objCType)
        return (t == "c" || t == "B") ? n.boolValue : nil
    }

    /// A node field read as an Int when it is a number (NOT a boolean), else 0.
    private static func asColInt(_ v: Any?) -> Int {
        guard let n = v as? NSNumber else { return 0 }
        let t = String(cString: n.objCType)
        if t == "c" || t == "B" { return 0 }
        return n.intValue
    }

    // MARK: - record + walk

    /// The structural record for one widget node (no recursion).
    private static func record(_ node: [String: Any], path: [Int]) -> [String: Any] {
        let t = asString(node["type"]) ?? ""
        let nid = asString(node["id"]) ?? ""
        let kind = canonicalWidgetKinds.contains(t) ? t : "placeholder"
        let col = asColInt(node["col"])
        // `visible` is the static literal only (false iff `visible: false`); a
        // string `visible:` expr or a `bind.visible` is dynamic — recorded as
        // `dyn_visible` rather than evaluated, so the snapshot stays eval-free.
        let vBool = asBool(node["visible"])
        let visible = (vBool == false) ? false : true
        let bind = node["bind"] as? [String: Any]
        let style = node["style"] as? [String: Any]
        let dynVisible = (node["visible"] is String)
            || (bind != nil && bind!["visible"] != nil)
        return [
            "path": path,
            "type": t,
            "id": nid,
            "kind": kind,
            "col": col,
            "visible": visible,
            "dyn_visible": dynVisible,
            "bind": bind != nil ? bind!.keys.sorted() : [],
            "style": style != nil ? style!.keys.sorted() : [],
        ]
    }

    private static func walk(_ node: [String: Any], path: [Int], ctx: [String: Any],
                             out: inout [[String: Any]]) {
        out.append(record(node, path: path))
        // A foreach container expands its `do` template once per item of
        // evaluate(foreach.source, ctx) — mirrors PanelLayout's foreach exactly
        // so the expansion count (and thus the path set) is identical to the
        // rects.
        if let spec = node["foreach"] as? [String: Any], node["do"] != nil {
            let src = (spec["source"] as? String) ?? ""
            let varName = (spec["as"] as? String) ?? "item"
            let template = node["do"]
            var items: [Any] = []
            if !src.isEmpty {
                let res = evaluate(src, context: ctx)
                if case .list(let arr) = res {
                    items = arr.map { $0.value }
                }
            }
            for (i, item) in items.enumerated() {
                var itemData: [String: Any]
                if let d = item as? [String: Any] {
                    itemData = d
                } else {
                    itemData = ["_value": item]
                }
                itemData["_index"] = i
                var childCtx = ctx
                childCtx[varName] = itemData
                if let tmpl = template as? [String: Any] {
                    walk(tmpl, path: path + [i], ctx: childCtx, out: &out)
                }
            }
            return
        }
        // A plain container recurses its declared children. Unlike the layout
        // pass (which drops `visible: false`), every dict child is kept and
        // recorded so a wrongly-hidden widget is catchable; non-dict entries
        // occupy their index but emit nothing.
        if let children = node["children"] as? [Any] {
            for (i, child) in children.enumerated() {
                if let c = child as? [String: Any] {
                    walk(c, path: path + [i], ctx: ctx, out: &out)
                }
            }
        }
    }
}
