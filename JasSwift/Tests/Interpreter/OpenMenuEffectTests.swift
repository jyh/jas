import Foundation
import Testing
@testable import JasLib

// `open_menu: { id }`, the request to pop up a declared menu item's submenu
// (the 2026-10-28 jas brush-library design, A.3), recorded as the store's
// `pendingMenu` for the host. Row for row with the reference's
// test_open_menu.py.

private func run(_ effects: [[String: Any]]) -> StateStore {
    let store = StateStore()
    runEffects(effects, ctx: [:], store: store)
    return store
}

@Test func aNewStoreHasNoPendingMenu() {
    #expect(StateStore().pendingMenu == nil)
}

@Test func theMappingFormRecordsItsId() {
    #expect(run([["open_menu": ["id": "bp_menu_open_library"]]]).pendingMenu == "bp_menu_open_library")
}

@Test func theBareFormRecordsItsId() {
    #expect(run([["open_menu": "bp_menu_open_library"]]).pendingMenu == "bp_menu_open_library")
}

@Test func theIdIsALiteralNotAnExpression() {
    #expect(run([["open_menu": ["id": "param.x"]]]).pendingMenu == "param.x")
}

@Test func anEmptyOrNonStringIdRecordsNothing() {
    let specs: [Any] = [["id": ""], [String: Any](), ["id": 3], "", NSNull(), 7]
    for spec in specs {
        #expect(run([["open_menu": spec]]).pendingMenu == nil, "\(spec)")
    }
}

@Test func aLaterRequestReplacesAnEarlierOne() {
    #expect(run([["open_menu": ["id": "first"]], ["open_menu": ["id": "second"]]]).pendingMenu == "second")
}

@Test func anEmptyRequestLeavesAnEarlierOne() {
    #expect(run([["open_menu": ["id": "first"]], ["open_menu": ["id": ""]]]).pendingMenu == "first")
}
