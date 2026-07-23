import Foundation

/// The canvas right-click context menu, described as data so its item set,
/// titles, and enabled predicates are unit-testable without building an
/// NSMenu. The AppKit view (`CanvasNSView.menu(for:)`) turns this into live
/// NSMenuItems; every action is an EXISTING verb dispatched through the same
/// path the main menu / keyboard use — no new verbs are introduced here.
enum CanvasContextMenu {
    /// The edit verbs offered on the canvas, in display order. Each maps to an
    /// existing dispatch: cut/copy/paste route through ``EditClipboard`` (the
    /// same code the Edit menu now shares); delete mirrors the canvas keyboard
    /// Delete; selectAll calls ``MenuActions.selectAll``.
    enum Item: CaseIterable {
        case cut, copy, paste, delete, selectAll
    }

    /// Menu item title. Matches the main menu's Edit titles with the AppKit
    /// mnemonic (`&`) stripped; "Delete" is the standard verb for the existing
    /// keyboard delete (the Edit menu has no Delete item to borrow a title from).
    static func title(_ item: Item) -> String {
        switch item {
        case .cut:       return "Cut"
        case .copy:      return "Copy"
        case .paste:     return "Paste"
        case .delete:    return "Delete"
        case .selectAll: return "Select All"
        }
    }

    /// Whether a divider precedes this item when the menu is laid out
    /// (clipboard group | delete | select-all), mirroring the Edit menu's
    /// separator grouping.
    static func separatorBefore(_ item: Item) -> Bool {
        switch item {
        case .delete, .selectAll: return true
        default:                  return false
        }
    }

    /// Enabled state, mirroring the menubar.yaml Edit predicates:
    ///   • cut / copy      → `active_document.has_selection`
    ///   • delete          → has-selection (the keyboard Delete's natural guard)
    ///   • paste / selectAll → `state.tab_count > 0`
    /// `hasSelection` = the active document has a non-empty selection;
    /// `hasTab` = a document/tab is open on the canvas.
    static func isEnabled(_ item: Item, hasSelection: Bool, hasTab: Bool) -> Bool {
        switch item {
        case .cut, .copy, .delete: return hasSelection
        case .paste, .selectAll:   return hasTab
        }
    }
}
