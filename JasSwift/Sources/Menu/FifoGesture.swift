import AppKit

/// `gesture <json>`: an input script's POINTER steps (TESTING.md section 6),
/// in DOCUMENT units, delivered to the active canvas view's own handlers, for
/// the test-only `--test-fifo` channel (STATUS-jas row 249). STUB: red first.
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

    public static func parse(_ json: String) throws -> [Step] {
        throw FifoReadError(description: "gesture REFUSED (stub)")
    }

    @MainActor
    static func canvas(for model: Model, in window: NSWindow) throws -> CanvasNSView {
        throw FifoReadError(description: "gesture REFUSED (stub)")
    }

    @MainActor
    @discardableResult
    static func deliver(_ steps: [Step], to view: CanvasNSView) throws -> String {
        throw FifoReadError(description: "gesture REFUSED (stub)")
    }
}
