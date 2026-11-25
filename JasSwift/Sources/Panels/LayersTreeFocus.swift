import AppKit

/// When the Layers tree holds keyboard focus (STATUS-jas row 208 R4). The
/// tree's keys (layers.yaml `keyboard:`, and the Delete monitor) run only
/// while it does, and SwiftUI's `.focusable()` takes no focus from a tap, so
/// the tree's event monitor applies this rule to every event it sees: a
/// press (primary or secondary) on a row gives the tree focus, as the web
/// tree's `tabindex` takes it from the click; a press anywhere else takes it
/// away, so a Delete after a canvas click goes to the canvas; every other
/// event, and any event while a row's rename field holds the keyboard
/// (it sits on a row, and taking focus from it would end the rename), leaves
/// focus as it is.
enum LayersTreeFocus {
    static func afterEvent(_ type: NSEvent.EventType, onRow: Bool, focused: Bool,
                           renaming: Bool) -> Bool {
        if renaming { return focused }
        switch type {
        case .leftMouseDown, .rightMouseDown: return onRow
        default: return focused
        }
    }
}
