import Foundation
import Testing
@testable import JasLib

// `items_from`, a dynamic submenu's rows declared in YAML (the 2026-10-28 jas
// brush-library design, A.2). Row for row with the reference's
// test_menu_items_from.py.

private let spec: [String: Any] = [
    "source": "keys(data.brush_libraries)",
    "as": "lib",
    "item": [
        "label": "{{data.brush_libraries[lib].name}}",
        "action": "toggle_brush_library_open",
        "params": ["library": "lib"],
        "checked_when": "any(panel.open_libraries, fun o -> o.id == lib)",
    ] as [String: Any],
]

private let ctx: [String: Any] = [
    "data": ["brush_libraries": [
        "zeta": ["name": "Zeta Brushes"],
        "default_brushes": ["name": "Default Brushes"],
    ]],
    "panel": ["open_libraries": [["id": "default_brushes", "collapsed": false]]],
]

private func with(_ item: [String: Any]) -> [String: Any] {
    var s = spec
    s["item"] = (spec["item"] as! [String: Any]).merging(item) { _, new in new }
    return s
}

@Test func itemsFromOneRowPerSourceElementInSourceOrder() {
    let rows = MenuState.itemsFromEntries(spec, ctx)
    #expect(rows.map(\.label) == ["Default Brushes", "Zeta Brushes"])
    #expect(rows.map(\.action) == ["toggle_brush_library_open", "toggle_brush_library_open"])
    #expect(rows.map { $0.params["library"] as? String } == ["default_brushes", "zeta"])
    #expect(rows.map(\.enabled) == [true, true])
    #expect(rows.map(\.checked) == [true, false], "per element; the two differ, so a once-evaluated predicate fails")
}

@Test func itemsFromEnabledWhenIsPerElement() {
    #expect(MenuState.itemsFromEntries(with(["enabled_when": "lib != \"zeta\""]), ctx).map(\.enabled) == [true, false])
}

@Test func itemsFromWithoutCheckedWhenIsNil() {
    var s = spec
    var item = spec["item"] as! [String: Any]; item.removeValue(forKey: "checked_when"); s["item"] = item
    #expect(MenuState.itemsFromEntries(s, ctx).map(\.checked) == [nil, nil])
}

@Test func itemsFromParamsAreExpressions() {
    let rows = MenuState.itemsFromEntries(with(["params": ["library": "lib + \"/x\"", "n": "1 + 1"]]), ctx)
    #expect(rows[0].params["library"] as? String == "default_brushes/x")
    #expect(rows[0].params["n"] as? Int == 2)
}

@Test func itemsFromNonListOrEmptySourceGivesNoRows() {
    for src in ["data.brush_libraries", "null", "3"] {
        var s = spec; s["source"] = src
        #expect(MenuState.itemsFromEntries(s, ctx).isEmpty, "\(src)")
    }
    #expect(MenuState.itemsFromEntries(spec, ["data": ["brush_libraries": [String: Any]()], "panel": [:]]).isEmpty)
}
