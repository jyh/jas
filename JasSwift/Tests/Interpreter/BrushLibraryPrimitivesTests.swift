import Foundation
import Testing
@testable import JasLib

// The two generic primitives under the Brushes panel's Open Brush Library
// (the 2026-10-28 jas brush-library design, A.1 and A.2). Row for row with the
// reference's `TestListToggleKeyed` (test_effects.py) and `TestKeys`
// (test_expr.py).

// ── list_toggle with key / insert ──

private func keyed(_ initial: [Any], _ value: String, insert: [String: Any]? = nil,
                   key: String? = "id") -> [Any]? {
    let store = StateStore()
    store.initPanel("brushes", defaults: ["open_libraries": initial])
    store.setActivePanel("brushes")
    var spec: [String: Any] = ["target": "panel.open_libraries", "value": value]
    if let key { spec["key"] = key }
    if let insert { spec["insert"] = insert }
    runEffects([["list_toggle": spec]], ctx: [:], store: store)
    return store.getPanel("brushes", "open_libraries") as? [Any]
}

/// The list as plain JSON text with sorted keys, so two lists of dicts compare.
private func json(_ v: Any?) -> String {
    guard let v, let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else { return "nil" }
    return String(data: d, encoding: .utf8) ?? "nil"
}

@Test func keyedListToggleAppendsTheKeyedItemWithInsert() {
    #expect(json(keyed([["id": "a", "collapsed": true]], "\"b\"", insert: ["collapsed": false]))
            == #"[{"collapsed":true,"id":"a"},{"collapsed":false,"id":"b"}]"#)
}

@Test func keyedListToggleRemovesAPresentKeyWhateverItsOtherFields() {
    // The stale-field direction: a whole-value compare would append a second "a".
    #expect(json(keyed([["id": "a", "collapsed": true], ["id": "b", "collapsed": false]], "\"a\"",
                       insert: ["collapsed": false]))
            == #"[{"collapsed":false,"id":"b"}]"#)
}

@Test func keyedListToggleRemovesOnlyTheFirstMatch() {
    #expect(json(keyed([["id": "a"], ["id": "b"], ["id": "a", "x": 1]], "\"a\""))
            == #"[{"id":"b"},{"id":"a","x":1}]"#)
}

@Test func keyedListToggleWithoutInsertAddsTheKeyAlone() {
    #expect(json(keyed([], "\"a\"")) == #"[{"id":"a"}]"#)
}

@Test func keyedListToggleKeyWinsOverInsert() {
    #expect(json(keyed([], "\"a\"", insert: ["id": "zzz", "collapsed": false]))
            == #"[{"collapsed":false,"id":"a"}]"#)
}

@Test func keyedListToggleNonObjectItemNeverMatches() {
    #expect(json(keyed(["a", ["id": "a"]], "\"a\"")) == #"["a"]"#)
}

@Test func keyedListToggleInsertIsALiteral() {
    #expect(json(keyed([], "\"a\"", insert: ["label": "param.x"])) == #"[{"id":"a","label":"param.x"}]"#)
}

@Test func unkeyedListToggleStillComparesWholeValues() {
    // The control: without `key` the same toggle appends.
    #expect(json(keyed([["id": "a", "collapsed": true]], "\"a\"", key: nil))
            == #"[{"collapsed":true,"id":"a"},"a"]"#)
}

// ── keys(map) ──

@Test func keysAreSortedByCodePoint() {
    let r = evaluate("keys(data.libs)", context: ["data": ["libs": ["b": 1, "a": 2, "Z": 3, "\u{e9}": 4]]])
    #expect(r == .list([AnyJSON("Z"), AnyJSON("a"), AnyJSON("b"), AnyJSON("\u{e9}")]))
}

@Test func keysOfAnEmptyMapIsEmpty() {
    #expect(evaluate("keys(data.libs)", context: ["data": ["libs": [String: Any]()]]) == .list([]))
}

@Test func keysOfANonMapIsEmpty() {
    #expect(evaluate("keys(data.libs)", context: ["data": ["libs": [1, 2]]]) == .list([]))
    #expect(evaluate("keys(data.libs)", context: ["data": ["libs": "ab"]]) == .list([]))
    #expect(evaluate("keys(data.libs)", context: [:]) == .list([]))
}

@Test func keysComposeWithAny() {
    #expect(evaluate("any(keys(data.libs), fun k -> k == \"a\")", context: ["data": ["libs": ["a": 1]]])
            == .bool(true))
}
