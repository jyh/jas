import AppKit

/// When the Layers tree's Delete monitor holds the keys (STATUS-jas row 208
/// R4). A click on a row selected it and Delete then did nothing: the monitor
/// tested a `@FocusState` that nothing set. The monitor now keeps its own flag
/// and applies this rule to every event it sees: a press (primary or
/// secondary) on a row gives the tree the keys, as the web tree's `tabindex`
/// takes focus from the click; a press anywhere else takes them away, so a
/// Delete after a canvas click goes to the canvas; every other event, and any
/// event while a row is being renamed (the field sits on a row, and its
/// Delete edits the name), leaves the flag as it is.
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
