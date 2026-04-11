/// Menu item types for panel hamburger menus.

/// A menu item in a panel's hamburger menu.
public enum PanelMenuItem {
    /// A plain action: label, command string, optional shortcut hint.
    case action(label: String, command: String, shortcut: String = "")
    /// A toggle (checkbox) item.
    case toggle(label: String, command: String)
    /// A radio-group item; items sharing the same group are mutually exclusive.
    case radio(label: String, command: String, group: String)
    /// Horizontal separator line.
    case separator
}
