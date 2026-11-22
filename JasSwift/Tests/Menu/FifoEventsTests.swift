import Testing
import AppKit
@testable import JasLib

// The test-only `--test-fifo` `events <json>` command (STATUS-jas row 208):
// a harness posts a whole input SEQUENCE into the app's own event queue, so
// AppKit routes it as it routes a person's input (local monitors, hit
// testing, a context menu's tracking loop), with the console locked, where a
// pid-posted CGEvent does not reach the app (measured 11-21). And `menu
// <path>`: the titles of the last menu that began tracking, which is how a
// harness reads what a context menu offered.

// MARK: parse

@Test func eventsParseReadsEachKindTargetKeyAndFlags() throws {
    let specs = try FifoEvents.parse("""
        [{"kind":"move","at":"row_a"},
         {"kind":"right_down","at":[10,20]},
         {"kind":"left_up","at":"row_a","flags":["cmd"]},
         {"kind":"key","key":"down"},
         {"kind":"key","key":"z","flags":["cmd","shift"]}]
        """)
    #expect(specs == [
        .init(kind: .move, target: .id("row_a"), key: nil, flags: []),
        .init(kind: .rightDown, target: .point(10, 20), key: nil, flags: []),
        .init(kind: .leftUp, target: .id("row_a"), key: nil, flags: ["cmd"]),
        .init(kind: .key, target: nil, key: "down", flags: []),
        .init(kind: .key, target: nil, key: "z", flags: ["cmd", "shift"]),
    ])
}

/// Every malformed shape is refused BY NAME, so a typo never posts a
/// shorter sequence than the harness asked for.
@Test func eventsParseRefusesEachMalformedShapeByName() {
    let cases: [(String, String)] = [
        ("not json", "not a JSON array"),
        ("{}", "not a JSON array"),
        ("[]", "empty"),
        (#"[{"kind":"wiggle","at":"a"}]"#, "unknown kind 'wiggle'"),
        (#"[{"kind":"right_down"}]"#, "needs 'at'"),
        (#"[{"kind":"right_down","at":[1]}]"#, "'at' must be"),
        (#"[{"kind":"key"}]"#, "needs 'key'"),
        (#"[{"kind":"key","key":"nosuchkey"}]"#, "unknown key 'nosuchkey'"),
        (#"[{"kind":"key","key":"down","flags":["hyper"]}]"#, "unknown flag 'hyper'"),
        (#"[{"kind":"move","at":"a","key":"down"}]"#, "takes no 'key'"),
    ]
    for (json, needle) in cases {
        do {
            _ = try FifoEvents.parse(json)
            Issue.record("parse accepted \(json)")
        } catch {
            #expect("\(error)".contains(needle), "\(json) -> \(error), want \(needle)")
        }
    }
}

// MARK: keys

@Test func eventsKeyTableMapsTheNamedKeysToTheirVirtualCodes() {
    // The codes the app's own handlers compare against (the Layers monitor:
    // 51 Delete, 117 Forward Delete) and the menu-navigation keys.
    let want: [String: UInt16] = [
        "delete": 51, "forward_delete": 117, "return": 36, "escape": 53,
        "down": 125, "up": 126, "left": 123, "right": 124, "a": 0, "z": 6,
    ]
    for (name, code) in want {
        #expect(FifoEvents.key(name)?.code == code, "\(name)")
    }
    // Distinct codes: a collapsed table would map two keys to one press.
    let codes = FifoEvents.keyNames.compactMap { FifoEvents.key($0)?.code }
    #expect(Set(codes).count == codes.count)
}

// MARK: locate and build (a real window)

@MainActor private func window(with ids: [(String, NSRect)]) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                     styleMask: [.titled], backing: .buffered, defer: false)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    for (id, frame) in ids {
        let b = NSButton(frame: frame)
        b.setAccessibilityIdentifier(id)
        root.addSubview(b)
    }
    w.contentView = root
    return w
}

@Test @MainActor func eventsLocateReturnsTheElementsCentreInWindowPoints() throws {
    let w = window(with: [("row_a", NSRect(x: 20, y: 40, width: 100, height: 20)),
                          ("row_b", NSRect(x: 20, y: 80, width: 100, height: 20))])
    let a = try FifoEvents.locate("row_a", in: w)
    let b = try FifoEvents.locate("row_b", in: w)
    #expect(abs(a.x - 70) < 0.5 && abs(a.y - 50) < 0.5, "row_a at \(a)")
    #expect(abs(b.x - 70) < 0.5 && abs(b.y - 90) < 0.5, "row_b at \(b)")
}

@Test @MainActor func eventsLocateRefusesAMissingOrAmbiguousIdentifier() {
    let w = window(with: [("dup", NSRect(x: 0, y: 0, width: 10, height: 10)),
                          ("dup", NSRect(x: 50, y: 0, width: 10, height: 10))])
    #expect(throws: FifoReadError.self) { try FifoEvents.locate("absent", in: w) }
    do {
        _ = try FifoEvents.locate("dup", in: w)
        Issue.record("an identifier on two elements must be refused")
    } catch {
        #expect("\(error)".contains("2 elements"), "\(error)")
    }
}

@Test @MainActor func eventsBuildMakesOneEventPerPointerSpecAndTwoPerKey() throws {
    let w = window(with: [("row_a", NSRect(x: 20, y: 40, width: 100, height: 20))])
    let specs = try FifoEvents.parse("""
        [{"kind":"move","at":"row_a"},{"kind":"right_down","at":"row_a"},
         {"kind":"right_up","at":[5,6]},{"kind":"left_down","at":"row_a","flags":["cmd"]},
         {"kind":"key","key":"delete"}]
        """)
    let evs = try FifoEvents.build(specs, window: w)
    #expect(evs.map(\.type) == [.mouseMoved, .rightMouseDown, .rightMouseUp,
                                .leftMouseDown, .keyDown, .keyUp])
    #expect(evs.allSatisfy { $0.windowNumber == w.windowNumber })
    #expect(abs(evs[1].locationInWindow.x - 70) < 0.5 && abs(evs[1].locationInWindow.y - 50) < 0.5)
    #expect(evs[2].locationInWindow == NSPoint(x: 5, y: 6))
    #expect(evs[3].modifierFlags.contains(.command))
    #expect(!evs[1].modifierFlags.contains(.command))
    #expect(evs[4].keyCode == 51 && evs[5].keyCode == 51)
    let r = FifoEvents.receipt(evs).split(separator: " ").map(String.init)
    #expect(r.count == 6)
    #expect(r[1].hasSuffix("@(70,50)") && r[2].hasSuffix("@(5,6)"), "\(r)")
    #expect(r[3].hasSuffix("+cmd") && r[4] == "keyDown:51", "\(r)")
}

// MARK: menu watch

@Test @MainActor func menuWatchRecordsTheTitlesOfTheMenuThatBeganTracking() throws {
    FifoMenuWatch.start()
    let m = NSMenu(title: "row")
    m.addItem(withTitle: "Duplicate", action: nil, keyEquivalent: "")
    m.addItem(.separator())
    let off = m.addItem(withTitle: "Exit Isolation Mode", action: nil, keyEquivalent: "")
    m.autoenablesItems = false
    off.isEnabled = false
    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: m)
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("fifo-menu-\(UUID().uuidString).json").path
    try FifoMenuWatch.write(to: path)
    let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
    let items = try #require((obj as? [String: Any])?["menu"] as? [[String: Any]])
    #expect(items.map { $0["title"] as? String } == ["Duplicate", "-", "Exit Isolation Mode"])
    #expect(items.map { $0["enabled"] as? Bool } == [true, false, false])
    #expect((obj as? [String: Any])?["open"] as? Bool == true, "began, not yet ended")
    NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: m)
    try FifoMenuWatch.write(to: path)
    let after = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
    #expect((after as? [String: Any])?["open"] as? Bool == false, "ended")
    #expect(((after as? [String: Any])?["menu"] as? [Any])?.count == 3, "the titles survive the close")
}

// MARK: the SwiftUI frame registry

/// SwiftUI does not expose its accessibility identifiers to an in-process
/// walk (measured live: 1 of 608 elements carried one), so a SwiftUI target
/// records its own frame. The frame is in SwiftUI's window space (origin TOP
/// left); `locate` answers in AppKit window points (origin BOTTOM left).
@Test @MainActor func eventsLocatePrefersARecordedFrameFlippedToWindowPoints() throws {
    let w = window(with: [])
    let h = try #require(w.contentView).bounds.height
    let t = UUID()
    FifoTargets.record("swiftui_row", frame: CGRect(x: 10, y: 30, width: 100, height: 24), token: t)
    defer { FifoTargets.remove("swiftui_row", token: t) }
    let p = try FifoEvents.locate("swiftui_row", in: w)
    #expect(abs(p.x - 60) < 0.5, "x \(p.x)")
    #expect(abs(p.y - (h - 42)) < 0.5, "y \(p.y), want \(h - 42)")
}

@Test @MainActor func eventsLocateRefusesARemovedTarget() {
    let w = window(with: [])
    let t = UUID()
    FifoTargets.record("gone_row", frame: CGRect(x: 0, y: 0, width: 10, height: 10), token: t)
    FifoTargets.remove("gone_row", token: t)
    #expect(throws: FifoReadError.self) { try FifoEvents.locate("gone_row", in: w) }
}

/// A re-created SwiftUI row records its new frame BEFORE the old instance's
/// `onDisappear` runs (measured live: four rows recorded, then none found), so
/// a removal only removes the frame its own instance recorded.
@Test @MainActor func eventsTargetRemovalByAStaleInstanceKeepsTheNewFrame() throws {
    let w = window(with: [])
    let old = UUID(), new = UUID()
    FifoTargets.record("rebuilt_row", frame: CGRect(x: 0, y: 0, width: 10, height: 10), token: old)
    FifoTargets.record("rebuilt_row", frame: CGRect(x: 40, y: 0, width: 10, height: 10), token: new)
    FifoTargets.remove("rebuilt_row", token: old)
    defer { FifoTargets.remove("rebuilt_row", token: new) }
    let p = try FifoEvents.locate("rebuilt_row", in: w)
    #expect(abs(p.x - 45) < 0.5, "the new instance's frame, at \(p.x)")
}

// MARK: hover

/// `hover <path>`: the Layers row the tree believes the pointer is over, as
/// its `onHover` last set it. Row 142's monitor selects THAT row on a
/// right-click, so a harness that posts a right-click must know whether its
/// posted move set it, or a (B) reading cannot tell the app from the
/// instrument.
@Test func hoverJsonNamesTheRowOrNull() {
    #expect(FifoHover.json(row: [0, 0]) == #"{"layers_hovered_row":[0,0]}"#)
    #expect(FifoHover.json(row: nil) == #"{"layers_hovered_row":null}"#)
}

// MARK: enter (tracking areas)

/// A posted `mouseMoved` does not trip SwiftUI's `onHover` (measured live 11-22:
/// the hovered row stayed null after three move sequences): hover comes from
/// TRACKING AREAS, which the window server drives from the real cursor. An
/// `enter` step posts `mouseEntered` addressed to each tracking area, on the
/// view under the point and its ancestors, whose rect contains the point.
@Test @MainActor func eventsEnterAddressesEachTrackingAreaContainingThePoint() throws {
    let w = window(with: [])
    let root = try #require(w.contentView)
    let child = NSView(frame: NSRect(x: 20, y: 40, width: 100, height: 20))
    root.addSubview(child)
    let inner = NSTrackingArea(rect: child.bounds, options: [.mouseEnteredAndExited, .activeAlways],
                               owner: child, userInfo: nil)
    let elsewhere = NSTrackingArea(rect: NSRect(x: 0, y: 0, width: 5, height: 5),
                                   options: [.mouseEnteredAndExited, .activeAlways], owner: root, userInfo: nil)
    let outer = NSTrackingArea(rect: root.bounds, options: [.mouseEnteredAndExited, .activeAlways],
                               owner: root, userInfo: nil)
    child.addTrackingArea(inner); root.addTrackingArea(elsewhere); root.addTrackingArea(outer)
    let specs = try FifoEvents.parse(#"[{"kind":"enter","at":[70,50]}]"#)
    let evs = try FifoEvents.build(specs, window: w)
    #expect(evs.allSatisfy { $0.type == .mouseEntered })
    let areas = evs.compactMap(\.trackingArea).map(ObjectIdentifier.init)
    #expect(Set(areas) == Set([ObjectIdentifier(inner), ObjectIdentifier(outer)]), "\(evs)")
}

@Test @MainActor func eventsEnterOverNoTrackingAreaIsRefused() {
    let w = window(with: [])
    #expect(throws: FifoReadError.self) {
        try FifoEvents.build(try FifoEvents.parse(#"[{"kind":"enter","at":[70,50]}]"#), window: w)
    }
}

// MARK: warp

/// A posted `mouseEntered` + `mouseMoved` still left the hovered row null
/// (measured live 11-22), so SwiftUI's hover reads the REAL cursor. A `warp`
/// step moves it there (CGWarpMouseCursorPosition, global display space,
/// origin TOP left of the primary display) and posts nothing itself.
@Test @MainActor func eventsWarpConvertsAWindowPointToGlobalDisplaySpace() throws {
    let w = window(with: [])
    let p = NSPoint(x: 70, y: 50)
    let g = try #require(FifoEvents.globalPoint(p, in: w))
    let screen = w.convertPoint(toScreen: p)
    let primaryH = try #require(NSScreen.screens.first).frame.height
    #expect(abs(g.x - screen.x) < 0.5)
    #expect(abs(g.y - (primaryH - screen.y)) < 0.5)
    let specs = try FifoEvents.parse(#"[{"kind":"warp","at":[70,50]}]"#)
    #expect(specs.first?.kind == .warp)
    #expect(try FifoEvents.build(specs, window: w).isEmpty, "a warp builds no event (and does not move the cursor)")
    let ws = try FifoEvents.warps(specs, window: w)
    #expect(ws.count == 1 && abs(ws[0].x - g.x) < 0.5 && abs(ws[0].y - g.y) < 0.5)
}

// MARK: key delivery state

/// A posted key reached nothing (⌘A, ⌘Z and the tree's Delete, measured live
/// 11-22) while the same acts by `action` worked. Keys go to the KEY window,
/// so the `events` receipt states whether the app is active and the target
/// window is key: a key step posted to a non-key window is not a reading.
@Test func eventsKeyStateNamesActiveAndKey() {
    #expect(FifoEvents.keyState(active: true, targetIsKey: true) == "active=1 key=1")
    #expect(FifoEvents.keyState(active: false, targetIsKey: false) == "active=0 key=0")
    #expect(FifoEvents.keyState(active: true, targetIsKey: false) == "active=1 key=0")
}
