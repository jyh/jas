import Testing
@testable import JasLib

// TSPAN.md invariants 6 and 7: tspan ids are unique within a Text, and a new
// id is strictly greater than every id in it. `ensureParagraphWrapper` built
// each new wrapper from the default id 0, which the first body tspan already
// holds, so `paragraph.align_center` read back two tspans with id 0 in both
// ports. Mirrors Rust `a_new_wrapper_takes_a_fresh_id_on_both_insert_paths`.

private func body(_ s: String, _ id: UInt32) -> Tspan { Tspan(id: id, content: s) }
private func wrapper(_ s: String, _ id: UInt32) -> Tspan { Tspan(id: id, content: s, jasRole: "paragraph") }

@Test func aPrependedWrapperTakesMaxPlusOne() {
    var tspans = [body("hello", 0), body("world", 7)]
    _ = ensureParagraphWrapper(&tspans)
    #expect(tspans.map(\.id) == [8, 0, 7])
    #expect(tspans[0].jasRole == "paragraph" && tspans[0].content.isEmpty)
}

@Test func aRepairedWrapperIsFreshAndTheDemotedTspanKeepsItsId() {
    var tspans = [wrapper("trapped", 3), body("tail", 5)]
    _ = ensureParagraphWrapper(&tspans)
    #expect(tspans.map(\.id) == [6, 3, 5])
    #expect(tspans[1].content == "trapped" && tspans[1].jasRole == nil)
}

@Test func twoRepairedWrappersAreFreshAgainstEachOther() {
    var tspans = [wrapper("a", 0), wrapper("b", 1)]
    _ = ensureParagraphWrapper(&tspans)
    #expect(Set(tspans.map(\.id)).count == tspans.count, "ids repeat: \(tspans.map(\.id))")
}
