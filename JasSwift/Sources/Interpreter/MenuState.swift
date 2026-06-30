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
    private static func evalBool(_ expr: String, _ ctx: [String: Any]) -> Bool {
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
            out.append([
                "path": path,
                "action": (node["action"] as? String) ?? "",
                "enabled": enabled,
                "checked": checked,
            ])
        }
    }
}
