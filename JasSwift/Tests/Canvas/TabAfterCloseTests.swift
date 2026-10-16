import Testing
import Foundation
@testable import JasLib

// `remove_tab` (actions.yaml) selects the tab to the LEFT of the one it
// removed, else the new first tab; a tab that is not shown closes and the
// shown one stays. As Rust's
// closing_the_active_tab_selects_the_tab_to_its_left. Until 2026-10-16 Swift
// selected the FIRST tab whenever the shown one closed.

private let t = (0..<3).map { _ in UUID() }

@Test func closingTheShownMiddleTabSelectsTheTabToItsLeft() {
    #expect(tabAfterClose(ids: t, closing: t[1], selected: t[1]) == t[0])
}

@Test func closingTheShownLastTabSelectsTheTabToItsLeftNotTheFirst() {
    #expect(tabAfterClose(ids: t, closing: t[2], selected: t[2]) == t[1])
}

@Test func closingTheShownFirstTabSelectsTheNewFirstTab() {
    #expect(tabAfterClose(ids: t, closing: t[0], selected: t[0]) == t[1])
}

@Test func closingATabThatIsNotShownKeepsTheShownOne() {
    #expect(tabAfterClose(ids: t, closing: t[0], selected: t[2]) == t[2])
    #expect(tabAfterClose(ids: t, closing: t[2], selected: t[0]) == t[0])
}

@Test func closingTheOnlyTabLeavesNone() {
    #expect(tabAfterClose(ids: [t[0]], closing: t[0], selected: t[0]) == nil)
}
