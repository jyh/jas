// Menu enabled/checked evaluation (TESTING_STRATEGY.md chrome seam).
//
// Swift port of `workspace_interpreter/menu_state.py`. Pure, headless
// evaluation of every menubar item's `enabled_when` / `checked_when` predicate
// against a supplied context, producing a language-neutral per-item
// `{path, action, enabled, checked}` record. This is the cross-app byte-gate
// behind the menu's DYNAMIC state: all apps build the same context and evaluate
// the same bundle expressions to the same booleans, so a menu item that grays
// out (or shows a check mark) in one app does so in every app.
//
// The structural sibling of `WidgetTree`: every field is read straight from the
// compiled bundle `menubar`, and the ONLY thing evaluated is each item's
// `enabled_when` / `checked_when` expression — the exact same
// `evaluate(_:context:)` call the panel passes already make. Output is a flat
// pre-order list; `path` is `[m, i]` for a top-level menu's i-th item and
// `[m, i, j]` for a submenu child (separators consume an index but emit
// nothing; submenu nodes are not emitted but their children are recursed).

import Foundation

public enum MenuState {
    /// Walk the compiled `menubar` and evaluate each action item's
    /// `enabled_when` / `checked_when` against `ctx`.
    ///
    /// Returns a flat pre-order list of `{path, action, enabled, checked}` for
    /// every action item. Separators (bare `"separator"` strings) and the
    /// submenu nodes themselves are skipped; submenu CHILDREN are walked with an
    /// extended path so their predicates are covered. `enabled` defaults to
    /// `true` when there is no `enabled_when`; `checked` is the evaluated bool
    /// when `checked_when` is present, else `NSNull()` (serializes to JSON
    /// `null`).
    public static func menuState(_ menubar: [Any], _ ctx: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for (m, menu) in menubar.enumerated() {
            let items = (menu as? [String: Any])?["items"] as? [Any] ?? []
            walk(items, prefix: [m], ctx: ctx, out: &out)
        }
        return out
    }

    /// Evaluate `expr` against `ctx` and coerce to bool via the shared
    /// expression evaluator's truthiness (`evaluate` never raises — it returns
    /// `.null` on error, which `toBool()` reports as `false`).
    ///
    /// Deliberately shared rather than re-derived: the panel hamburger menu's
    /// check marks resolve through this exact function
    /// (`panelMenuIsChecked`), so a panel-menu `checked_when` and a menubar
    /// `checked_when` cannot answer the same expression differently. A control
    /// beside the instrument validates nothing; this is the instrument.
    public static func evalBool(_ expr: String, _ ctx: [String: Any]) -> Bool {
        evaluate(expr, context: ctx).toBool()
    }

    private static func walk(_ items: [Any], prefix: [Int], ctx: [String: Any],
                             out: inout [[String: Any]]) {
        for (i, item) in items.enumerated() {
            let path = prefix + [i]
            guard let node = item as? [String: Any] else {
                continue  // bare "separator"
            }
            if let sub = node["items"] as? [Any] {
                walk(sub, prefix: path, ctx: ctx, out: &out)  // submenu: recurse
                continue
            }
            // `if ew` in the Python reference is a truthiness test: only a
            // present, non-empty `enabled_when`/`checked_when` string is
            // evaluated; absent or empty falls back (enabled=true / checked=null).
            let ew = node["enabled_when"] as? String
            let cw = node["checked_when"] as? String
            let enabled: Any = (ew != nil && !ew!.isEmpty) ? evalBool(ew!, ctx) : true
            let checked: Any = (cw != nil && !cw!.isEmpty) ? evalBool(cw!, ctx) : NSNull()
            // The label with its `{{expr}}` regions evaluated against `ctx`,
            // so a label that says what its action will do (the Layers
            // panel's Hide/Show All Layers) is the shared walk's, never a
            // native table's; NSNull when the item has no label.
            let label: Any = (node["label"] as? String).map { evaluateText($0, context: ctx) } ?? NSNull()
            out.append([
                "path": path,
                "action": (node["action"] as? String) ?? "",
                "label": label,
                "enabled": enabled,
                "checked": checked,
            ])
        }
    }

    /// One entry of a DYNAMIC submenu (menubar.yaml `menu_workspace`,
    /// `menu_appearance`), pinned by `submenu_entries.json`.
    public struct SubmenuEntry: Equatable {
        public let name: String
        public let label: String
        public let checked: Bool
    }

    /// One row of a declared dynamic submenu (`items_from`).
    public struct ItemsFromRow {
        public let label: String?
        public let action: String
        public let params: [String: Any]
        public let enabled: Bool
        public let checked: Bool?
    }

    /// A dynamic submenu's rows from its declared `items_from` (the generic
    /// form of the two functions below; the 2026-10-28 jas brush-library
    /// design, A.2). `source` is evaluated against `ctx`; each element is bound
    /// to `as` in a copy of `ctx`; `label` is a `{{}}` template, every `params`
    /// value an expression, `enabled` true without `enabled_when`, `checked`
    /// nil without `checked_when`. A source that is not a list gives no rows.
    /// Mirrors the reference's `items_from_entries`.
    public static func itemsFromEntries(_ spec: [String: Any], _ ctx: [String: Any]) -> [ItemsFromRow] {
        guard case .list(let elements) = evaluate((spec["source"] as? String) ?? "null", context: ctx) else {
            return []
        }
        let name = (spec["as"] as? String) ?? "item"
        let item = (spec["item"] as? [String: Any]) ?? [:]
        let params = (item["params"] as? [String: Any]) ?? [:]
        return elements.map { element in
            var bound = ctx
            bound[name] = element.value
            return ItemsFromRow(
                label: (item["label"] as? String).map { evaluateText($0, context: bound) },
                action: (item["action"] as? String) ?? "",
                params: params.mapValues { v in
                    (v as? String).map { storedValue(evaluate($0, context: bound)) ?? NSNull() } ?? v
                },
                enabled: (item["enabled_when"] as? String).map { evalBool($0, bound) } ?? true,
                checked: (item["checked_when"] as? String).map { evalBool($0, bound) })
        }
    }

    /// The Workspace submenu's layout entries: every saved layout but the
    /// default one (``workspaceLayoutName``, reached by Reset to Default), in
    /// saved order, labelled by its name, the active one checked. Mirrors the
    /// reference's `workspace_entries` and jas_dioxus `menu_state::workspace_entries`.
    public static func workspaceEntries(saved: [String], active: String) -> [SubmenuEntry] {
        saved.filter { $0 != workspaceLayoutName }
            .map { SubmenuEntry(name: $0, label: $0, checked: $0 == active) }
    }

    /// The Appearance submenu's entries: every available `(name, label)` in
    /// order, the active one checked; no stored appearance means
    /// ``defaultAppearanceName`` is active. Mirrors the reference's
    /// `appearance_entries` and jas_dioxus `menu_state::appearance_entries`.
    public static func appearanceEntries(_ appearances: [(String, String)], active: String?) -> [SubmenuEntry] {
        let current = active ?? defaultAppearanceName
        return appearances.map { SubmenuEntry(name: $0.0, label: $0.1, checked: $0.0 == current) }
    }
}
