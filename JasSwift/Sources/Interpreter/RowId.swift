import Foundation

// Row 302 (ruling 1054's Swift twin): how a foreach widget's id template
// resolves per row, and which resolved ids a collision withholds. Each function
// ports one in jas_dioxus/src/interpreter/foreach.rs or workspace.rs, and its
// arms (RowIdTests.swift, CanvasTabIdsTests.swift) port the Rust arms row for
// row. The engine's plan is the reference; the Mac's native canvas tab strip
// is the first caller.

/// The scope key naming a row's OWN loop variable, innermost wins.
/// Twin of `interpreter::foreach::ROW_AS`.
let rowAsKey = "_row_as"

/// Twin of `interpreter::foreach::row_id`: `template` resolved in a row scope
/// when EVERY `{{...}}` in it is a plain path from the row's own loop variable
/// (`ctx[rowAsKey]`) to a non-empty string or a number; nil for anything else
/// (state, an outer loop's variable, a missing key, a boolean, an object, an
/// expression, an unclosed brace), and the id stays withheld.
func rowId(_ template: String, _ ctx: [String: Any]) -> String? {
    guard let v = ctx[rowAsKey] as? String, let row = ctx[v] else { return nil }
    var out = ""
    var rest = Substring(template)
    while let open = rest.range(of: "{{") {
        out += rest[rest.startIndex..<open.lowerBound]
        // Searched from the opening brace, as the Rust searches `rest[i..]`.
        guard let close = rest[open.lowerBound...].range(of: "}}") else { return nil }
        let expr = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = expr.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.removeFirst() == v, !parts.isEmpty else { return nil }
        var cur: Any = row
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                  let d = cur as? [String: Any], let next = d[p] else { return nil }
            cur = next
        }
        guard let text = rowIdText(cur) else { return nil }
        out += text
        rest = rest[close.upperBound...]
    }
    out += rest
    return out
}

/// A resolved value's text, as serde_json prints it in the Rust: a non-empty
/// string as it is, an integer in decimal, a float with its `.0` when integral.
/// ⚠️ Foundation bridges `true` and `1` both ways, so a boolean is told by its
/// CFBoolean type, never by `as? Bool`. Pinned for integers, 1.5 and 2.0;
/// exponent forms (very large or very small floats) are NOT verified to print
/// as serde prints them, and no shipped template reads a float.
private func rowIdText(_ v: Any) -> String? {
    if let s = v as? String { return s.isEmpty ? nil : s }
    guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    switch String(cString: n.objCType) {
    case "d", "f": return "\(n.doubleValue)"
    default: return n.stringValue
    }
}

/// Twin of the web's `dom_id` (renderer.rs, row 302 slice 2): the
/// accessibility identifier (and FIFO target) `YamlElementView` gives an
/// element. A templated id resolves only from the row's own variable, any
/// other is withheld (""), and a static id is carried as is. ⚠️ Condition 3 is
/// not applied in the generic renderer; `no_panel_or_dialog_id_template_resolves_yet`
/// (workspace.rs) reds the day a shipped panel or dialog template resolves.
func yamlAxIdentifier(_ element: [String: Any], _ context: [String: Any]) -> String {
    let raw = element["id"] as? String ?? ""
    guard raw.contains("{{") else { return raw }
    return rowId(raw, context) ?? ""
}

/// One foreach row's bindings in the Mac's own expansion: `varName` bound to
/// `item` plus `_index`, and the row's own variable recorded (`rowAsKey`),
/// as the engine's `row_scopes` records it. Twin of the web's
/// `repeat_row_ctx` (row 302 slice 2).
func repeatItemBindings(_ varName: String, item: [String: Any], index: Int) -> [String: Any] {
    var data = item
    data["_index"] = index
    return [varName: data, rowAsKey: varName]
}

/// Twin of `interpreter::foreach::duplicate_resolved_ids` (ruling 1054
/// condition 3): the ids to withhold from EVERY carrier, each non-empty id
/// carried more than once when at least one carrier RESOLVED it. Two static
/// carriers of one id are not this rule's subject.
func duplicateResolvedIds(_ carried: [(String, Bool)]) -> Set<String> {
    var count: [String: Int] = [:]
    var resolved = Set<String>()
    for (id, wasResolved) in carried where !id.isEmpty {
        count[id, default: 0] += 1
        if wasResolved { resolved.insert(id) }
    }
    return resolved.filter { count[$0, default: 0] > 1 }
}

/// Twin of `interpreter::workspace::canvas_strip_ids`: a native canvas tab
/// strip's `(tab, close)` ids, one pair per open document in tab order. The
/// rows expand as the engine expands them: the bar's `foreach.source` is
/// evaluated over a `workspace.open_documents` shaped as the engine holds it
/// (`index`, `is_modified`, `name`), each item gains `_index`, and the row
/// records its own variable. Each id then follows the plan's three rules.
/// ⚠️ SCOPE: the collision census is the STRIP; the engine's plan counts the
/// whole canvas pane.
func canvasStripIds(bar: [String: Any], docs: [(name: String, isModified: Bool)]) -> [(tab: String, close: String)] {
    guard let spec = bar["foreach"] as? [String: Any], let tab = bar["do"] as? [String: Any] else { return [] }
    let source = spec["source"] as? String ?? ""
    let v = spec["as"] as? String ?? "item"
    let open: [[String: Any]] = docs.enumerated().map { i, d in
        ["index": i, "is_modified": d.isModified, "name": d.name]
    }
    let ctx: [String: Any] = ["workspace": ["open_documents": open] as [String: Any]]
    guard case .list(let items) = evaluate(source, context: ctx) else { return [] }
    let close = (tab["children"] as? [[String: Any]])?.first {
        $0["type"] as? String == "icon_button" && $0["icon"] as? String == "close"
    }
    let tabRaw = tab["id"] as? String ?? ""
    let closeRaw = close?["id"] as? String ?? ""
    func one(_ raw: String, _ row: [String: Any]) -> (String, Bool) {
        if !raw.contains("{{") { return (raw, false) }
        if let s = rowId(raw, row) { return (s, true) }
        return ("", false)
    }
    let pairs: [((String, Bool), (String, Bool))] = items.enumerated().map { i, item in
        var data = item.value as? [String: Any] ?? ["_value": item.value]
        data["_index"] = i
        var row = ctx
        row[v] = data
        row[rowAsKey] = v
        return (one(tabRaw, row), one(closeRaw, row))
    }
    let dup = duplicateResolvedIds(pairs.flatMap { [$0.0, $0.1] })
    func keep(_ id: String) -> String { dup.contains(id) ? "" : id }
    return pairs.map { (tab: keep($0.0.0), close: keep($0.1.0)) }
}

/// Twin of `interpreter::workspace::canvas_tab_ids`: the ids the Mac's native
/// canvas tab strip carries, from the compiled layout's `canvas_tab_bar`
/// (`canvas_tab_<i>`, `canvas_tab_close_<i>` today). Empty if it has none.
func canvasTabIds(docs: [(name: String, isModified: Bool)]) -> [(tab: String, close: String)] {
    guard let bar = WorkspaceData.load()?.canvasTabBar() else { return [] }
    return canvasStripIds(bar: bar, docs: docs)
}
