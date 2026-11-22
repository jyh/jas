import AppKit

/// `events <json>`: a whole input SEQUENCE posted into the app's own event
/// queue, for the test-only `--test-fifo` channel (STATUS-jas row 208).
///
/// Why in-process: a key posted to the app's pid by `CGEventPostToPid` did
/// not reach it with the console locked (11-21: selection 0 -> 0 beside a FIFO
/// control that moved it 0 -> 2). An event posted by `NSApp.postEvent` is
/// dequeued by the app's own run loop, so AppKit routes it as it routes a
/// person's input: local monitors, hit testing, first responder, and a
/// context menu's tracking loop. The sequence is posted at once, in order,
/// because a context menu's tracking loop takes the events queued behind the
/// click that opened it; one FIFO command per event would race it.
///
/// What it does NOT witness: the window server (no cursor moves, no other
/// app sees the events) and hardware timing.
///
/// The JSON is an array of steps:
///   {"kind": "move" | "left_down" | "left_up" | "right_down" | "right_up",
///    "at": "<accessibility identifier>" | [x, y], "flags": [...]}
///   {"kind": "key", "key": "<name>", "flags": [...]}   (a keyDown and its keyUp)
/// An identifier resolves to its element's CENTRE; `[x, y]` is a point in
/// AppKit WINDOW coordinates (origin bottom-left). Flags: cmd, shift, option,
/// control.
public enum FifoEvents {
    public enum Kind: String, CaseIterable, Equatable {
        case move, key, enter, warp
        case leftDown = "left_down", leftUp = "left_up"
        case rightDown = "right_down", rightUp = "right_up"
    }

    public enum Target: Equatable {
        case id(String)
        case point(Double, Double)
    }

    public struct Spec: Equatable {
        public var kind: Kind
        public var target: Target?
        public var key: String?
        public var flags: [String]
        public init(kind: Kind, target: Target?, key: String?, flags: [String]) {
            self.kind = kind; self.target = target; self.key = key; self.flags = flags
        }
    }

    // MARK: keys

    /// Virtual key codes (Carbon `kVK_*`) and the characters AppKit reports.
    private static let keys: [String: (code: UInt16, chars: String)] = [
        "delete": (51, "\u{7F}"), "forward_delete": (117, "\u{F728}"),
        "return": (36, "\r"), "escape": (53, "\u{1B}"), "tab": (48, "\t"),
        "space": (49, " "),
        "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
        "left": (123, "\u{F702}"), "right": (124, "\u{F703}"),
        "a": (0, "a"), "c": (8, "c"), "d": (2, "d"), "v": (9, "v"),
        "x": (7, "x"), "z": (6, "z"),
    ]

    public static var keyNames: [String] { keys.keys.sorted() }

    public static func key(_ name: String) -> (code: UInt16, chars: String)? { keys[name] }

    private static let flagTable: [String: NSEvent.ModifierFlags] = [
        "cmd": .command, "shift": .shift, "option": .option, "control": .control,
    ]

    // MARK: parse

    private static func refuse(_ why: String) -> FifoReadError {
        FifoReadError(description: "events REFUSED (\(why))")
    }

    /// Parse the step array. Refuses, by name, any step it cannot post exactly
    /// as written, so a typo never posts a shorter sequence than was asked.
    public static func parse(_ json: String) throws -> [Spec] {
        guard let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            throw refuse("not a JSON array of steps")
        }
        guard !arr.isEmpty else { throw refuse("empty step array") }
        return try arr.enumerated().map { i, raw in
            guard let step = raw as? [String: Any] else { throw refuse("step \(i) is not an object") }
            let kindName = step["kind"] as? String ?? ""
            guard let kind = Kind(rawValue: kindName) else {
                throw refuse("step \(i): unknown kind '\(kindName)'")
            }
            let flags = step["flags"] as? [String] ?? []
            for f in flags where flagTable[f] == nil {
                throw refuse("step \(i): unknown flag '\(f)'")
            }
            if kind == .key {
                guard let k = step["key"] as? String else { throw refuse("step \(i): a key step needs 'key'") }
                guard keys[k] != nil else { throw refuse("step \(i): unknown key '\(k)'") }
                if step["at"] != nil { throw refuse("step \(i): a key step takes no 'at'") }
                return Spec(kind: kind, target: nil, key: k, flags: flags)
            }
            if step["key"] != nil { throw refuse("step \(i): a pointer step takes no 'key'") }
            guard let at = step["at"] else { throw refuse("step \(i): a pointer step needs 'at'") }
            if let id = at as? String, !id.isEmpty {
                return Spec(kind: kind, target: .id(id), key: nil, flags: flags)
            }
            if let xy = at as? [NSNumber], xy.count == 2 {
                return Spec(kind: kind, target: .point(xy[0].doubleValue, xy[1].doubleValue),
                            key: nil, flags: flags)
            }
            throw refuse("step \(i): 'at' must be an identifier or [x, y]")
        }
    }

    // MARK: locate

    /// The centre, in window points, of the ONE accessibility element under
    /// `window`'s content view whose identifier is `id`. Refuses none, and
    /// refuses more than one by count: a point on the wrong twin is the
    /// silent failure this exists to prevent.
    @MainActor
    public static func locate(_ id: String, in window: NSWindow) throws -> NSPoint {
        guard let root = window.contentView else { throw refuse("the window has no content view") }
        // A SwiftUI target's own recorded frame first (FifoTargets).
        if let f = FifoTargets.frame(id) {
            return NSPoint(x: f.midX, y: root.bounds.height - f.midY)
        }
        var hits: [NSRect] = []
        var seen = 0
        var visited = Set<ObjectIdentifier>()
        var named = 0
        var near: [String] = []
        // Two trees, walked together: the accessibility tree (SwiftUI's
        // elements exist only there) and the view tree (an AppKit control's
        // accessibility children are its CELL, which does not carry the
        // identifier set on the control; measured). Each object once.
        func walk(_ el: Any, depth: Int) {
            guard depth < 64, seen < 100_000, let ax = el as? NSAccessibilityProtocol else { return }
            guard visited.insert(ObjectIdentifier(ax as AnyObject)).inserted else { return }
            seen += 1
            let got = ax.accessibilityIdentifier() ?? ""
            if got == id { hits.append(ax.accessibilityFrame()) }
            if !got.isEmpty {
                named += 1
                if got.hasPrefix(String(id.prefix(6))), near.count < 5 { near.append(got) }
            }
            for c in ax.accessibilityChildren() ?? [] { walk(c, depth: depth + 1) }
            if let v = el as? NSView { for s in v.subviews { walk(s, depth: depth + 1) } }
        }
        walk(root, depth: 0)
        guard hits.count == 1 else {
            throw refuse(hits.isEmpty
                ? "no accessibility element is identified '\(id)' (\(seen) read, \(named) "
                    + "identified; same prefix: \(near.isEmpty ? "none" : near.joined(separator: ", ")))"
                : "'\(id)' identifies \(hits.count) elements")
        }
        let screen = NSPoint(x: hits[0].midX, y: hits[0].midY)
        return window.convertPoint(fromScreen: screen)
    }

    // MARK: build and post

    /// One NSEvent per pointer step and a keyDown + keyUp per key step, all
    /// addressed to `window`. Identifiers are resolved here, before anything
    /// is posted, so a refusal posts nothing.
    @MainActor
    public static func build(_ specs: [Spec], window: NSWindow) throws -> [NSEvent] {
        var out: [NSEvent] = []
        let now = ProcessInfo.processInfo.systemUptime
        for (i, s) in specs.enumerated() {
            let mods = s.flags.reduce(into: NSEvent.ModifierFlags()) { $0.insert(flagTable[$1]!) }
            let t = now + Double(i) * 0.001
            if s.kind == .key, let name = s.key, let k = keys[name] {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard let e = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: mods, timestamp: t,
                        windowNumber: window.windowNumber, context: nil,
                        characters: k.chars, charactersIgnoringModifiers: k.chars,
                        isARepeat: false, keyCode: k.code) else {
                        throw refuse("step \(i): AppKit built no \(type) for '\(name)'")
                    }
                    out.append(e)
                }
                continue
            }
            let p: NSPoint
            switch s.target {
            case .id(let id): p = try locate(id, in: window)
            case .point(let x, let y): p = NSPoint(x: x, y: y)
            case nil: throw refuse("step \(i): a pointer step has no target")
            }
            if s.kind == .warp { continue }  // `warps`: done by `post`, never here
            if s.kind == .enter {
                let areas = trackingAreas(containing: p, in: window)
                guard !areas.isEmpty else {
                    throw refuse("step \(i): no tracking area contains (\(Int(p.x)), \(Int(p.y)))")
                }
                for a in areas {
                    guard let e = NSEvent.enterExitEvent(
                        with: .mouseEntered, location: p, modifierFlags: mods, timestamp: t,
                        windowNumber: window.windowNumber, context: nil, eventNumber: i,
                        trackingNumber: Int(bitPattern: Unmanaged.passUnretained(a).toOpaque()),
                        userData: nil) else {
                        throw refuse("step \(i): AppKit built no mouseEntered")
                    }
                    out.append(e)
                }
                continue
            }
            let type: NSEvent.EventType
            switch s.kind {
            case .enter, .warp: throw refuse("step \(i): unreachable")
            case .move: type = .mouseMoved
            case .leftDown: type = .leftMouseDown
            case .leftUp: type = .leftMouseUp
            case .rightDown: type = .rightMouseDown
            case .rightUp: type = .rightMouseUp
            case .key: throw refuse("step \(i): a key step has no key")
            }
            guard let e = NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: mods, timestamp: t,
                windowNumber: window.windowNumber, context: nil, eventNumber: i,
                clickCount: type == .mouseMoved ? 0 : 1,
                pressure: (type == .leftMouseDown || type == .rightMouseDown) ? 1 : 0) else {
                throw refuse("step \(i): AppKit built no \(type)")
            }
            out.append(e)
        }
        return out
    }

    /// Whether a key step can land: keys go to the key window of an active app.
    public static func keyState(active: Bool, targetIsKey: Bool) -> String {
        "active=\(active ? 1 : 0) key=\(targetIsKey ? 1 : 0)"
    }

    /// One token per event, so the log says where each press went:
    /// `rightMouseDown@(70,50)`, `keyDown:51+cmd`.
    public static func receipt(_ events: [NSEvent]) -> String {
        events.map { e in
            var flags: [String] = []
            for (n, f) in [("cmd", NSEvent.ModifierFlags.command), ("shift", .shift),
                           ("option", .option), ("control", .control)] where e.modifierFlags.contains(f) {
                flags.append(n)
            }
            let suffix = flags.isEmpty ? "" : "+" + flags.joined(separator: "+")
            switch e.type {
            case .keyDown, .keyUp:
                return "\(e.type == .keyDown ? "keyDown" : "keyUp"):\(e.keyCode)\(suffix)"
            default:
                let p = e.locationInWindow
                let name: String
                switch e.type {
                case .mouseMoved: name = "move"
                case .mouseEntered: name = "enter"
                case .leftMouseDown: name = "leftDown"
                case .leftMouseUp: name = "leftUp"
                case .rightMouseDown: name = "rightDown"
                case .rightMouseUp: name = "rightUp"
                default: name = "type\(e.type.rawValue)"
                }
                return "\(name)@(\(Int(p.x.rounded())),\(Int(p.y.rounded())))\(suffix)"
            }
        }.joined(separator: " ")
    }

    /// `p` (window points) in Quartz global display space: origin at the TOP
    /// left of the primary display, y down.
    @MainActor
    public static func globalPoint(_ p: NSPoint, in window: NSWindow) -> CGPoint? {
        guard let primary = NSScreen.screens.first else { return nil }
        let s = window.convertPoint(toScreen: p)
        return CGPoint(x: s.x, y: primary.frame.height - s.y)
    }

    /// The tracking areas that would report the pointer entering at `p`
    /// (window points): those of the view under `p` and its ancestors whose
    /// rect contains it, innermost first. Hover comes from these, not from
    /// `mouseMoved` (measured).
    @MainActor
    static func trackingAreas(containing p: NSPoint, in window: NSWindow) -> [NSTrackingArea] {
        guard let root = window.contentView,
              var v = root.hitTest(root.convert(p, from: nil)) ?? Optional(root) else { return [] }
        var out: [NSTrackingArea] = []
        while true {
            let local = v.convert(p, from: nil)
            for a in v.trackingAreas where a.options.contains(.mouseEnteredAndExited) {
                let r = a.options.contains(.inVisibleRect) ? v.visibleRect : a.rect
                if r.contains(local) { out.append(a) }
            }
            guard v !== root, let up = v.superview else { break }
            v = up
        }
        return out
    }

    /// The global display points of the sequence's `warp` steps, in order.
    /// Resolved like any target, so a refused one posts nothing.
    @MainActor
    public static func warps(_ specs: [Spec], window: NSWindow) throws -> [CGPoint] {
        try specs.enumerated().filter { $0.element.kind == .warp }.map { i, s in
            let p: NSPoint
            switch s.target {
            case .id(let id): p = try locate(id, in: window)
            case .point(let x, let y): p = NSPoint(x: x, y: y)
            case nil: throw refuse("step \(i): a warp has no target")
            }
            guard let g = globalPoint(p, in: window) else { throw refuse("step \(i): no screen to warp on") }
            return g
        }
    }

    /// Move the REAL cursor to each warp point (it is this Mac's pointer: the
    /// test channel only), then post the built events at the BACK of the
    /// queue, in order. A warp therefore acts before ANY posted event,
    /// wherever it sits in the sequence.
    @MainActor
    public static func post(_ events: [NSEvent], warps: [CGPoint] = []) {
        for g in warps { CGWarpMouseCursorPosition(g) }
        for e in events { NSApp.postEvent(e, atStart: false) }
    }
}

/// The frames SwiftUI targets record for `events` (`.fifoTarget(id)`), in
/// SwiftUI's window space (origin TOP left). SwiftUI does not expose its
/// accessibility identifiers to an in-process walk (measured live 11-22: 1 of
/// 608 elements carried one), so a row tells the channel where it is. Records
/// only under `--test-fifo` (`enabled`); a normal launch records nothing.
public enum FifoTargets {
    @MainActor public static var enabled = false
    @MainActor private static var frames: [String: (frame: CGRect, token: UUID)] = [:]

    /// Record `id`'s frame for the view instance `token`.
    @MainActor public static func record(_ id: String, frame: CGRect, token: UUID) {
        frames[id] = (frame, token)
    }
    /// Remove `id` only if instance `token` recorded it: a re-created row
    /// records its new frame BEFORE the old instance's `onDisappear` runs
    /// (measured live), so an unconditional removal erased every row.
    @MainActor public static func remove(_ id: String, token: UUID) {
        if frames[id]?.token == token { frames[id] = nil }
    }
    @MainActor public static func frame(_ id: String) -> CGRect? { frames[id]?.frame }
}

import SwiftUI

/// Records its view's window frame under `id` (FifoTargets), per instance.
private struct FifoTargetModifier: ViewModifier {
    let id: String
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content.background(GeometryReader { g in
            let f = g.frame(in: .global)
            SwiftUI.Color.clear
                .onAppear { FifoTargets.record(id, frame: f, token: token) }
                .onChange(of: f) { FifoTargets.record(id, frame: $0, token: token) }
                .onDisappear { FifoTargets.remove(id, token: token) }
        })
    }
}

extension View {
    /// Record this view's window frame under `id` for the FIFO's `events`
    /// (FifoTargets). Inert on a normal launch.
    @MainActor @ViewBuilder
    public func fifoTarget(_ id: String) -> some View {
        if FifoTargets.enabled {
            self.modifier(FifoTargetModifier(id: id))
        } else {
            self
        }
    }
}

/// `menu <path>`: the titles of the last menu that BEGAN TRACKING, so a
/// harness reads what a context menu offered while it is open (row 208, sheet
/// 3 reading 3). Recorded at `didBeginTracking`, the moment it is shown.
public enum FifoMenuWatch {
    @MainActor private static var tokens: [NSObjectProtocol] = []
    @MainActor private static var last: [(title: String, enabled: Bool)]?
    /// How many menus are tracking now (a submenu nests inside its parent).
    @MainActor private static var tracking = 0

    /// Start observing; idempotent.
    @MainActor
    public static func start() {
        guard tokens.isEmpty else { return }
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { note in
            guard let m = note.object as? NSMenu else { return }
            let items = m.items.map { ($0.isSeparatorItem ? "-" : $0.title,
                                       !$0.isSeparatorItem && $0.isEnabled) }
            MainActor.assumeIsolated { last = items; tracking += 1 }
        })
        tokens.append(nc.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { tracking = max(0, tracking - 1) }
        })
    }

    /// Write `{"menu": [{"title", "enabled"}...], "open": Bool}`: the last menu
    /// that began tracking (`null` when none has since `start`), and whether a
    /// menu is tracking NOW, so a harness knows a pick or an Escape closed it.
    @MainActor
    public static func write(to path: String) throws {
        let menu: Any = last.map { $0.map { ["title": $0.title, "enabled": $0.enabled] } } ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: ["menu": menu, "open": tracking > 0],
                                              options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
