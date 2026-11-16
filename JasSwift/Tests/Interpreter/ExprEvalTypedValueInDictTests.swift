import Testing
import Foundation
@testable import JasLib

// STATUS-jas row 144. A behavior's params are resolved with `toAny()`, which
// keeps a PATH as a typed `Value` on purpose. A yaml action then reads it back
// as `param.<name>`, a dotted name over a dictionary. Swift's dotted-name walk
// reached that `Value` and returned null, so on the door route a row drop's
// `target_parent` reached `move_elements` as nothing. The door reported
// `committed`, and nothing moved (jas-spec fork, desk AGU run 2, 15 of 15 drag
// scripts). The reference returns a typed value it finds in a dictionary
// (`Value.from_python` passes a `Value` through).

private let ctx: [String: Any] = ["param": [
    "target_parent": Value.path([0, 2]),
    "marker": ["__path__": [0, 2]] as [String: Any],
] as [String: Any]]

@Test func aTypedPathInADictionaryReadsBackAsThatPath() {
    #expect(evaluate("param.target_parent", context: ctx) == .path([0, 2]))
}

@Test func aTypedPathInADictionaryHasItsMembers() {
    #expect(evaluate("param.target_parent.depth", context: ctx) == .number(2))
    #expect(evaluate("param.target_parent.parent", context: ctx) == .path([0]))
}

@Test func theMarkerFormStillReadsAsAPath() {
    // CONTROL: the JSON form this walk already read.
    #expect(evaluate("param.marker", context: ctx) == .path([0, 2]))
    #expect(evaluate("param.marker", context: ctx) == evaluate("param.target_parent", context: ctx))
}
