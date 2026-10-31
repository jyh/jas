import Testing
import AppKit
@testable import JasLib

// A non-modal flyout closes on Escape (SCHEMA.md, "Non-Modal Dialogs": a
// button whose effects close it, a press outside it, and Escape). Before this
// the Mac's popover closed on the backdrop tap only (STATUS-jas row 54). The
// key goes through a LOCAL event monitor so it is consumed BEFORE the canvas,
// which is first responder and has its own Escape for the active tool.

@Test func escapeAloneDismissesAFlyout() {
    #expect(flyoutEscapeDismisses(keyCode: 53, modifiers: []))
    // Caps Lock and the function key do not make it another chord.
    #expect(flyoutEscapeDismisses(keyCode: 53, modifiers: [.capsLock]))
    #expect(flyoutEscapeDismisses(keyCode: 53, modifiers: [.function]))
}

@Test func anotherKeyOrAChordDoesNotDismissAFlyout() {
    #expect(!flyoutEscapeDismisses(keyCode: 36, modifiers: []))      // Return
    #expect(!flyoutEscapeDismisses(keyCode: 0, modifiers: []))       // A
    // Cmd-Escape is the proposal bar's shortcut (ProposalBarView); it is not
    // the flyout's.
    #expect(!flyoutEscapeDismisses(keyCode: 53, modifiers: [.command]))
    #expect(!flyoutEscapeDismisses(keyCode: 53, modifiers: [.option]))
    #expect(!flyoutEscapeDismisses(keyCode: 53, modifiers: [.control]))
    #expect(!flyoutEscapeDismisses(keyCode: 53, modifiers: [.shift]))
}

// The monitor must be REMOVED when the flyout closes, or Escape is eaten for
// the rest of the session. Installing twice replaces the first monitor
// instead of stacking a second one.
@Test @MainActor func theFlyoutEscapeMonitorIsRemovedAndNeverStacks() {
    let base = FlyoutEscapeMonitor.liveCount
    var fired: [String] = []
    let m = FlyoutEscapeMonitor()
    #expect(!m.isInstalled)
    m.install { fired.append("first") }
    #expect(m.isInstalled && FlyoutEscapeMonitor.liveCount == base + 1)
    m.install { fired.append("second") }
    #expect(FlyoutEscapeMonitor.liveCount == base + 1, "a second install replaced the first")
    _ = m.handle(keyCode: 53, modifiers: [])
    #expect(fired == ["second"], "only the replacing handler fires")
    m.remove()
    #expect(!m.isInstalled && FlyoutEscapeMonitor.liveCount == base)
    m.remove()                                   // idempotent
    #expect(FlyoutEscapeMonitor.liveCount == base)
}

// The handler's decision, without the event: Escape fires the dismiss once
// and is consumed; any other key passes through and fires nothing.
@Test @MainActor func theMonitorConsumesEscapeAndPassesEverythingElse() {
    var fired = 0
    let m = FlyoutEscapeMonitor()
    m.install { fired += 1 }
    #expect(m.handle(keyCode: 53, modifiers: []) == .consumed)
    #expect(fired == 1)
    #expect(m.handle(keyCode: 0, modifiers: []) == .passed)
    #expect(m.handle(keyCode: 53, modifiers: [.command]) == .passed)
    #expect(fired == 1)
    m.remove()
    // Removed, nothing fires even for Escape.
    #expect(m.handle(keyCode: 53, modifiers: []) == .passed)
    #expect(fired == 1)
}
