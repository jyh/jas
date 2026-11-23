import AppKit

/// `gesture <json>`: an input script's POINTER steps (TESTING.md section 6),
/// in DOCUMENT units, delivered to the active canvas view's own handlers, for
/// the test-only `--test-fifo` channel (STATUS-jas row 249).
///
/// Why not `events`: with the console locked the app is never active
/// (`active=0 key=0`, row 208), and AppKit spends a click on an inactive
/// window's view that does not accept the first mouse on keying the window,
/// so a posted click never reaches the canvas (measured 11-23: a Selection
/// click on a shape left the selection empty, twice). This verb calls the
/// canvas view's `mouseDown` / `mouseDragged` / `mouseUp` / `mouseMoved`
/// directly, with NSEvents at the window point of each document point, so
/// everything from the view's handler inward (the tool, the model, its undo
/// steps) is the code a person's click runs.
///
/// What it does NOT witness: the window's first-mouse and key routing, the
/// window server, hardware timing, and a double-click (refused by name).
///
/// The JSON is an array of the input script's pointer steps:
///   {"kind": "press" | "move" | "release", "x": <doc>, "y": <doc>,
///    "dragging": true (a move only), "shift": bool, "alt": bool}
/// The canvas reads only shift and alt (CanvasNSView's handlers), so a
/// `ctrl` or `meta` is refused rather than dropped, and so is a `shift` on a
/// move that does not drag (`mouseMoved` passes shift false).
public enum FifoGesture {
    public enum Kind: String, Equatable { case press, move, release }

    public struct Step: Equatable {
        public var kind: Kind
        public var x: Double
        public var y: Double
        public var dragging: Bool
        public var shift: Bool
        public var alt: Bool
        public init(kind: Kind, x: Double, y: Double, dragging: Bool, shift: Bool, alt: Bool) {
            self.kind = kind; self.x = x; self.y = y
            self.dragging = dragging; self.shift = shift; self.alt = alt
        }
    }

    private static func refuse(_ why: String) -> FifoReadError {
        FifoReadError(description: "gesture REFUSED (\(why))")
    }

    private static let fields: Set<String> = ["kind", "x", "y", "dragging", "shift", "alt"]

    /// A JSON number, never a Bool (NSNumber bridges both; row 233's lesson).
    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    /// A JSON true/false, never a number.
    private static func flag(_ step: [String: Any], _ name: String, _ i: Int) throws -> Bool {
        guard let v = step[name] else { return false }
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
            throw refuse("step \(i): '\(name)' must be true or false")
        }
        return n.boolValue
    }

    /// Parse the step array. Refuses, by name, any step it cannot deliver
    /// exactly as written, so a typo never delivers a shorter gesture.
    public static func parse(_ json: String) throws -> [Step] {
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
            for name in ["ctrl", "meta"] where step[name] != nil {
                throw refuse("step \(i): the canvas reads no '\(name)'")
            }
            for name in step.keys.sorted() where !fields.contains(name) {
                throw refuse("step \(i): unknown field '\(name)'")
            }
            guard let x = number(step["x"]) else { throw refuse("step \(i) needs a number 'x'") }
            guard let y = number(step["y"]) else { throw refuse("step \(i) needs a number 'y'") }
            let dragging = try flag(step, "dragging", i)
            let shift = try flag(step, "shift", i)
            let alt = try flag(step, "alt", i)
            if dragging && kind != .move { throw refuse("step \(i): only a move drags") }
            if kind == .move && !dragging && shift {
                throw refuse("step \(i): a move that does not drag reads no 'shift'")
            }
            return Step(kind: kind, x: x, y: y, dragging: dragging, shift: shift, alt: alt)
        }
    }

    /// The ONE canvas view in `window` whose controller holds `model`.
    @MainActor
    static func canvas(for model: Model, in window: NSWindow) throws -> CanvasNSView {
        var hits: [CanvasNSView] = []
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        while let v = stack.popLast() {
            if let c = v as? CanvasNSView, c.controller?.model === model { hits.append(c) }
            stack.append(contentsOf: v.subviews)
        }
        guard !hits.isEmpty else { throw refuse("no canvas shows the active document") }
        guard hits.count == 1 else { throw refuse("\(hits.count) canvases show the active document") }
        return hits[0]
    }

    /// Deliver `steps` to `view`'s own handlers, in order, and return one
    /// token per step (`press@(20,20) drag@(25,22) …`, document units).
    @MainActor
    @discardableResult
    static func deliver(_ steps: [Step], to view: CanvasNSView) throws -> String {
        guard let window = view.window, let model = view.controller?.model else {
            throw refuse("the canvas has no window or no document")
        }
        let now = ProcessInfo.processInfo.systemUptime
        var tokens: [String] = []
        for (i, s) in steps.enumerated() {
            // A document point is a view point by the canvas's own transform
            // (mouseDown's inverse: doc = (view - offset) / zoom).
            let vp = NSPoint(x: s.x * model.zoomLevel + model.viewOffsetX,
                             y: s.y * model.zoomLevel + model.viewOffsetY)
            let wp = view.convert(vp, to: nil)
            var mods = NSEvent.ModifierFlags()
            if s.shift { mods.insert(.shift) }
            if s.alt { mods.insert(.option) }
            let type: NSEvent.EventType
            switch s.kind {
            case .press: type = .leftMouseDown
            case .release: type = .leftMouseUp
            case .move: type = s.dragging ? .leftMouseDragged : .mouseMoved
            }
            guard let e = NSEvent.mouseEvent(
                with: type, location: wp, modifierFlags: mods,
                timestamp: now + Double(i) * 0.001, windowNumber: window.windowNumber,
                context: nil, eventNumber: i, clickCount: type == .mouseMoved ? 0 : 1,
                pressure: type == .leftMouseUp || type == .mouseMoved ? 0 : 1) else {
                throw refuse("step \(i): AppKit built no \(type)")
            }
            switch type {
            case .leftMouseDown: view.mouseDown(with: e)
            case .leftMouseDragged: view.mouseDragged(with: e)
            case .leftMouseUp: view.mouseUp(with: e)
            default: view.mouseMoved(with: e)
            }
            let name = s.kind == .move ? (s.dragging ? "drag" : "move") : s.kind.rawValue
            tokens.append("\(name)@(\(fmt(s.x)),\(fmt(s.y)))")
        }
        return tokens.joined(separator: " ")
    }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}
