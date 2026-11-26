/// Tests for the accessibility identifier of one foreach iteration (row 281).
///
/// Swift draws a foreach template once per item, so every iteration's
/// widgets share one AX identifier (`ap_name` on every Artboards row). A
/// level-2 driver addresses an iteration by `at`; it can only do that if
/// each iteration is its own container with an identifier of its own:
/// `<foreach id>#<index>`. A foreach with no `id` has no such identifier,
/// and the driver refuses `at` there by name rather than guess by layout.

import Foundation
import Testing
@testable import JasLib

@Suite struct RepeatIterationAxIdTests {
    @Test func anIdentifiedForeachNamesEachIteration() {
        #expect(repeatIterationAxId(foreachId: "ap_list", index: 0) == "ap_list#0")
        #expect(repeatIterationAxId(foreachId: "ap_list", index: 3) == "ap_list#3")
    }

    @Test func aForeachWithNoIdNamesNoIteration() {
        #expect(repeatIterationAxId(foreachId: nil, index: 0) == nil)
    }

    @Test func anEmptyIdNamesNoIteration() {
        // An empty string is not an identifier a driver can ask for.
        #expect(repeatIterationAxId(foreachId: "", index: 1) == nil)
    }

    @Test func distinctIterationsHaveDistinctIdentifiers() {
        let ids = (0..<4).compactMap { repeatIterationAxId(foreachId: "ap_list", index: $0) }
        #expect(Set(ids).count == 4)
    }
}
