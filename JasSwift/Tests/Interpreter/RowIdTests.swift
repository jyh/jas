import Foundation
import Testing
@testable import JasLib

// Row 302 / ruling 1054: `rowId` is the Swift twin of the ONE resolver of a
// foreach widget's id template, `interpreter::foreach::row_id`
// (jas_dioxus/src/interpreter/foreach.rs). Each row of this table is a row of
// the Rust table `row_id_resolves_only_plain_paths_from_the_rows_own_variable`,
// in the same order.

private func scope(_ v: String, _ row: [String: Any]) -> [String: Any] {
    ["state": ["q": "z"], "g": ["k": "G"], v: row, rowAsKey: v]
}

@Test func rowIdResolvesOnlyPlainPathsFromTheRowsOwnVariable() {
    let row: [String: Any] = ["k": "a", "n": 0, "f": 1.5, "e": "", "b": true, "o": ["p": "deep"], "_index": 3]
    let s = scope("it", row)
    let cases: [(String, String?)] = [
        ("b_{{it.k}}_{{it.n}}", "b_a_0"),   // a string and an integer
        ("x{{ it.k }}", "xa"),              // spaces inside the braces
        ("{{it.o.p}}", "deep"),             // a nested plain path
        ("t_{{it._index}}", "t_3"),         // the row's own index
        ("f_{{it.f}}", "f_1.5"),            // a float prints as serde prints it
        ("s_{{state.q}}", nil),             // state is not the row's variable
        ("o_{{g.k}}", nil),                 // nor is an outer loop's
        ("m_{{it.nope}}", nil),             // a missing key
        ("e_{{it.e}}", nil),                // an empty string
        ("b_{{it.b}}", nil),                // a boolean
        ("o_{{it.o}}", nil),                // an object
        ("v_{{it}}", nil),                  // the variable itself (depth 0)
        ("p_{{it.k|x}}", nil),              // anything but a plain path
        ("p_{{it.k + 1}}", nil),
        ("u_{{it.k", nil),                  // an unclosed brace
    ]
    for (t, want) in cases {
        #expect(rowId(t, s) == want, "template \(t)")
    }
    #expect(rowId("b_{{it.k}}", ["it": ["k": "a"]]) == nil, "no row variable recorded, no resolution")
}

// The Swift-only trap the Rust table cannot have: Foundation bridges an
// NSNumber 1 to `Bool` and a Swift `Bool` to NSNumber, so the integer 1 and
// `true` must still read as a number and as a boolean respectively.
@Test func rowIdTellsTheIntegerOneFromTrue() {
    let s = scope("it", ["one": 1, "yes": true, "two": 2.0, "n": NSNumber(value: 1)])
    #expect(rowId("{{it.one}}", s) == "1")
    #expect(rowId("{{it.n}}", s) == "1", "a Foundation integer")
    #expect(rowId("{{it.yes}}", s) == nil)
    #expect(rowId("{{it.two}}", s) == "2.0", "an integral float keeps its .0, as serde prints it")
}

// Ruling 1054 condition 3's population; twin of
// `duplicate_resolved_ids_names_only_collisions_a_resolution_took_part_in`.
@Test func duplicateResolvedIdsNamesOnlyCollisionsAResolutionTookPartIn() {
    let got = duplicateResolvedIds([
        ("d_x", false), ("d_x", true),   // static and resolved
        ("d_y", true), ("d_y", true),    // two rows
        ("s", false), ("s", false),      // two statics: not this rule's
        ("u", true),                     // resolved once
        ("", true), ("", true),          // a withheld id is no id
    ])
    #expect(got.sorted() == ["d_x", "d_y"])
}

// Row 302 slice 2: the Mac's generic renderer (`YamlElementView`) carries the
// identifier the engine's plan carries. Twin of the web's
// `a_dom_id_resolves_from_the_row_or_is_withheld_and_named` (renderer.rs).
@Test func yamlAxIdentifierResolvesFromTheRowOrIsWithheld() {
    let ctx: [String: Any] = ["it": ["k": "a"], "g": ["k": "G"], rowAsKey: "it"]
    #expect(yamlAxIdentifier(["id": "x_{{it.k}}"], ctx) == "x_a", "the row's own variable resolves")
    #expect(yamlAxIdentifier(["id": "y_{{g.k}}_{{it.k}}"], ctx) == "", "an outer loop's variable is withheld")
    #expect(yamlAxIdentifier(["id": "z"], ctx) == "z", "a static id is carried as is")
    #expect(yamlAxIdentifier(["type": "text"], ctx) == "", "no id")
}

// Twin of `a_web_repeat_row_records_its_own_variable`: the Mac's foreach
// expansion records the row's variable, innermost winning.
@Test func repeatItemBindingsRecordTheRowsOwnVariable() {
    let b = repeatItemBindings("brush", item: ["slug": "s"], index: 2)
    #expect(b[rowAsKey] as? String == "brush")
    #expect((b["brush"] as? [String: Any])?["_index"] as? Int == 2)
    var scope: [String: Any] = ["keep": 1, rowAsKey: "outer"]
    scope.merge(b) { _, new in new }
    #expect(scope[rowAsKey] as? String == "brush", "innermost wins")
    #expect(rowId("t_{{brush.slug}}_{{brush._index}}", scope) == "t_s_2")
}
