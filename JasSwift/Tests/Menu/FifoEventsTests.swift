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
}

// MARK: the SwiftUI frame registry

/// SwiftUI does not expose its accessibility identifiers to an in-process
/// walk (measured live: 1 of 608 elements carried one), so a SwiftUI target
/// records its own frame. The frame is in SwiftUI's window space (origin TOP
/// left); `locate` answers in AppKit window points (origin BOTTOM left).
@Test @MainActor func eventsLocatePrefersARecordedFrameFlippedToWindowPoints() throws {
    let w = window(with: [])
    let h = try #require(w.contentView).bounds.height
    FifoTargets.record("swiftui_row", frame: CGRect(x: 10, y: 30, width: 100, height: 24))
    defer { FifoTargets.remove("swiftui_row") }
    let p = try FifoEvents.locate("swiftui_row", in: w)
    #expect(abs(p.x - 60) < 0.5, "x \(p.x)")
    #expect(abs(p.y - (h - 42)) < 0.5, "y \(p.y), want \(h - 42)")
}

@Test @MainActor func eventsLocateRefusesARemovedTarget() {
    let w = window(with: [])
    FifoTargets.record("gone_row", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    FifoTargets.remove("gone_row")
    #expect(throws: FifoReadError.self) { try FifoEvents.locate("gone_row", in: w) }
}
