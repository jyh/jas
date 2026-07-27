// Shared canonical panel bind-VALUE snapshot pass (TESTING_STRATEGY.md §4).
//
// Swift port of `workspace_interpreter/bind_values.py`, the third sibling of
// `PanelLayout.layoutPanel` (per-widget rects) and `WidgetTree.widgetTree`
// (per-widget structural records). Where those two are deliberately value-blind,
// this pass RESOLVES the panel's data bindings and pins the resulting strings.
//
// Why a third pass instead of widening one of the other two: `widgetTree`
// records the sorted KEY NAMES of `bind` / `style` and collapses a dynamic
// `visible` into a `dyn_visible` flag on purpose — that is what makes it stable,
// and widening it would rewrite every record it emits. `layoutPanel` resolves
// `{{ }}` text but consumes it as `unicodeScalars.count * charWidth`, so any two
// strings of equal length produce the same rect.
//
// Together those leave the bind-VALUE surface unpinned. Measured on the Color
// panel: the two data scopes that differ only in `panel.hex` — "664040" vs
// "664141", the byte pattern of the colour divergence the corpus census was
// written to answer — produce IDENTICAL `widgetTree` output and IDENTICAL
// `layoutPanel` rects, and differ in exactly one row here. Both halves are
// asserted in `bindValuesSeparatesEqualLengthHexWhereTheOlderGatesCannot`.
//
// Output is a pre-order list of
// `["path": [Int], "id": String, "key": String, "type": String, "value": String]`.
// `path` uses the same scheme as `widgetTree`. `key` is `"visible"` for a
// dynamic `visible: <expr>` string, `"bind.<name>"` per `bind` key in sorted
// order, and `"content"` / `"label"` for a node string containing `{{ }}`.
// A node with none of those emits NO row, so the snapshot's size tracks the
// panel's binding surface rather than its widget count.
//
// `value` is built only from `Value.toStringCoerce()` — the same coercion
// `{{ }}` interpolation uses — so this pass adds no new number-formatting
// surface. A `bind` expression evaluating to a JSON OBJECT becomes a JSON
// STRING inside the evaluator, whose key order is a known cross-port
// divergence; no vector in `panel_bind_values.json` binds an object.

import Foundation

public enum BindValues {
    /// Walk a compiled panel node (`{"type":"panel","content":<root>}`) into a
    /// pre-order list of resolved-binding records.
    ///
    /// `ctx` is the data scope (`state` / `panel` / `data` / `active_document`
    /// namespaces, plus any `foreach` item bindings added during the walk);
    /// defaults to empty, where every binding resolves to null.
    public static func bindValues(_ panelNode: [String: Any],
                                  ctx: [String: Any] = [:]) -> [[String: Any]] {
        guard let root = panelNode["content"] as? [String: Any] else {
            return []
        }
        var out: [[String: Any]] = []
        walk(root, path: [], ctx: ctx, out: &out)
        return out
    }

    // MARK: - canonical value form

    /// The canonical `(type, value)` pair for one evaluated value. Scalars use
    /// the shared interpolation coercion; a list is "[" + elements joined by
    /// "," + "]", each element canonicalized the same way (nested lists nest
    /// their brackets).
    static func canonValue(_ v: Value) -> (String, String) {
        switch v {
        case .null: return ("null", v.toStringCoerce())
        case .bool: return ("bool", v.toStringCoerce())
        case .number: return ("number", v.toStringCoerce())
        case .string: return ("string", v.toStringCoerce())
        case .color: return ("color", v.toStringCoerce())
        case .path: return ("path", v.toStringCoerce())
        case .closure: return ("closure", v.toStringCoerce())
        case .list(let items):
            let parts = items.map { canonValue(Value.fromJson($0.value)).1 }
            return ("list", "[" + parts.joined(separator: ",") + "]")
        }
    }

    // MARK: - record + walk

    private static func row(_ path: [Int], _ nodeId: String, _ key: String,
                            _ v: Value) -> [String: Any] {
        let (ty, val) = canonValue(v)
        return ["path": path, "id": nodeId, "key": key, "type": ty, "value": val]
    }

    /// Every resolved-binding record for one node (no recursion).
    private static func rowsFor(_ node: [String: Any], path: [Int],
                                ctx: [String: Any], out: inout [[String: Any]]) {
        let nid = (node["id"] as? String) ?? ""
        // A dynamic `visible:` expression, coerced through the shared truthiness
        // rule. The compiled bundle lands the YAML `visible: <expr>` form under
        // `bind` instead, so this arm is carried for completeness.
        if let expr = node["visible"] as? String {
            out.append(row(path, nid, "visible",
                           .bool(evaluate(expr, context: ctx).toBool())))
        }
        if let map = node["bind"] as? [String: Any] {
            for key in map.keys.sorted() {
                let entry = map[key]
                let v: Value
                if let expr = entry as? String {
                    v = evaluate(expr, context: ctx)
                } else {
                    // A non-string `bind` entry is a literal in the bundle;
                    // record it through the same coercion so rows stay uniform.
                    v = Value.fromJson(entry)
                }
                out.append(row(path, nid, "bind." + key, v))
            }
        }
        // `{{ }}`-bearing content / label: the surface layoutPanel reduces to a
        // scalar count. A literal string carries no binding and is not recorded.
        for key in ["content", "label"] {
            if let raw = node[key] as? String, raw.contains("{{") {
                out.append(row(path, nid, key,
                               .string(evaluateText(raw, context: ctx))))
            }
        }
    }

    private static func walk(_ node: [String: Any], path: [Int],
                             ctx: [String: Any], out: inout [[String: Any]]) {
        rowsFor(node, path: path, ctx: ctx, out: &out)
        // A foreach container expands its `do` template once per item of
        // evaluate(foreach.source, ctx) — the same expansion widgetTree
        // performs, so a path here names the same node it names there.
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
        // Plain container: recurse every dict child at its declared index,
        // including statically-hidden ones (mirrors widgetTree, not the layout
        // pass) so a binding on a wrongly-hidden widget stays comparable.
        if let children = node["children"] as? [Any] {
            for (i, child) in children.enumerated() {
                if let c = child as? [String: Any] {
                    walk(c, path: path + [i], ctx: ctx, out: &out)
                }
            }
        }
    }
}
