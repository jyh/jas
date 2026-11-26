/// Tests for where a dock panel's hamburger menu is popped.
///
/// Measured on the Mac test box (row 275, 11-26): the menu was popped only
/// `if let event = NSApp.currentEvent`, anchored to that event. A real
/// click popped it; an AXPress (an accessibility press, which carries no
/// mouse event) popped nothing, and after a dock scroll a real click popped
/// nothing either. The rule below anchors the menu to the button's own view
/// whenever that view is known, so the menu opens the same way however the
/// button was pressed.

import AppKit
import Testing
@testable import JasLib

@Suite struct PanelMenuPlacementTests {
    @Test func anAnchorViewWinsOverAMouseEvent() {
        #expect(panelMenuPlacement(hasAnchor: true, eventType: .leftMouseUp) == .belowAnchor)
    }

    @Test func anAnchorViewIsUsedWithNoEventAtAll() {
        // An AXPress: the action runs with no current event.
        #expect(panelMenuPlacement(hasAnchor: true, eventType: nil) == .belowAnchor)
    }

    @Test func anAnchorViewIsUsedWhenTheCurrentEventIsNotAMouseEvent() {
        #expect(panelMenuPlacement(hasAnchor: true, eventType: .scrollWheel) == .belowAnchor)
    }

    @Test func withoutAnAnchorAMouseEventIsTheFallback() {
        #expect(panelMenuPlacement(hasAnchor: false, eventType: .leftMouseUp) == .atEvent)
        #expect(panelMenuPlacement(hasAnchor: false, eventType: .leftMouseDown) == .atEvent)
        #expect(panelMenuPlacement(hasAnchor: false, eventType: .rightMouseDown) == .atEvent)
    }

    @Test func withoutAnAnchorANonMouseEventPopsNothing() {
        #expect(panelMenuPlacement(hasAnchor: false, eventType: .scrollWheel) == .none)
        #expect(panelMenuPlacement(hasAnchor: false, eventType: .keyDown) == .none)
    }

    @Test func withoutAnAnchorOrAnEventPopsNothing() {
        #expect(panelMenuPlacement(hasAnchor: false, eventType: nil) == .none)
    }

    @Test func theMenuDropsBelowTheAnchorInEitherCoordinateFlip() {
        // `popUp(positioning:at:in:)` places the menu's top-left at the
        // point, in the view's own coordinates: the view's bottom edge is
        // y = height when flipped and y = 0 when not.
        #expect(panelMenuAnchorPoint(width: 31, height: 16, isFlipped: true) == NSPoint(x: 0, y: 16))
        #expect(panelMenuAnchorPoint(width: 31, height: 16, isFlipped: false) == NSPoint(x: 0, y: 0))
    }
}
