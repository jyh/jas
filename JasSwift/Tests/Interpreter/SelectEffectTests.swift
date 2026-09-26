import Foundation
import Testing
@testable import JasLib

// `select: { target, list, scope, scope_value, mode }`, row for row with the
// reference's `SELECT_ROWS` (test_effects.py, `TestSelectEffect`). The engine
// door hosts the same rows (effects.rs, `select_matches_the_reference_row_for_row`).

/// One row: the list and the scope after the effect, with numbers read as
/// Doubles so an Int and a Double 4 compare alike.
private func selected(_ initial: Any?, _ scope: Any?, _ extra: [String: Any] = [:],
                      event: [String: Any] = [:], active: Bool = true) -> ([Double]?, String?) {
    let store = StateStore()
    var defaults: [String: Any] = [:]
    if let v = initial { defaults["sel"] = v }
    if let v = scope { defaults["lib"] = v }
    store.initPanel("swatches", defaults: defaults)
    if active { store.setActivePanel("swatches") }
    var spec: [String: Any] = ["target": "param.t", "list": "sel", "scope": "lib", "scope_value": "param.s"]
    for (k, v) in extra { spec[k] = v }
    runEffects([["select": spec]], ctx: ["param": ["t": 4, "s": "a"], "event": event], store: store)
    let list = (store.getPanel("swatches", "sel") as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
    return (list, store.getPanel("swatches", "lib") as? String)
}

@Test func selectMatchesTheReferenceRowForRow() {
    let rows: [(String, (([Double]?, String?)), [Double], String)] = [
        ("single: a plain click replaces the list", selected([1, 2], "a"), [4], "a"),
        ("single: an empty list gets the target", selected([Int](), "a"), [4], "a"),
        ("a NEW scope sets it and restarts the list, even under ctrl",
         selected([1, 2], "b", event: ["ctrl": true]), [4], "a"),
        ("a missing scope key is a new scope", selected([1, 2], nil, event: ["shift": true]), [4], "a"),
        ("ctrl: an absent target is appended", selected([1, 2], "a", event: ["ctrl": true]), [1, 2, 4], "a"),
        ("ctrl: a present target is removed, order kept",
         selected([4, 1, 2], "a", event: ["ctrl": true]), [1, 2], "a"),
        ("ctrl: a present target is removed EVERY time it occurs",
         selected([4, 1, 4], "a", event: ["ctrl": true]), [1], "a"),
        ("meta toggles as ctrl does", selected([1, 4], "a", event: ["meta": true]), [1], "a"),
        ("shift: an int range from the FIRST entry up",
         selected([2, 9], "a", event: ["shift": true]), [2, 3, 4], "a"),
        ("shift: an int range from the first entry DOWN", selected([6], "a", event: ["shift": true]), [4, 5, 6], "a"),
        ("shift beats ctrl", selected([2], "a", event: ["shift": true, "ctrl": true]), [2, 3, 4], "a"),
        ("shift with no anchor is a single select", selected([Int](), "a", event: ["shift": true]), [4], "a"),
        ("an explicit mode ignores the modifiers",
         selected([1], "a", ["mode": "toggle"], event: ["shift": true]), [1, 4], "a"),
        ("an unknown mode is a single select", selected([1], "a", ["mode": "sideways"]), [4], "a"),
        ("a non-list value is read as empty", selected("x", "a", event: ["ctrl": true]), [4], "a"),
        ("no scope key: the scope is never read or written",
         selected([1], "zz", ["scope": ""], event: ["ctrl": true]), [1, 4], "zz"),
        ("no list key: a no-op", selected([1], "a", ["list": ""]), [1], "a"),
        ("no active panel: a no-op", selected([1], "a", active: false), [1], "a"),
    ]
    #expect(rows.count == 18, "the reference's SELECT_ROWS has 18 rows")
    for (name, got, wantList, wantScope) in rows {
        #expect(got.0 == wantList, "\(name): \(String(describing: got.0))")
        #expect(got.1 == wantScope, "\(name): scope \(String(describing: got.1))")
    }
}
