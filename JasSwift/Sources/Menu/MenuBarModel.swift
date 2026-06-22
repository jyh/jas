/// Top menu-bar model — projected from the compiled workspace `menubar`.
///
/// The menu bar is rendered (in `JasCommands.swift`) from ``menuBarModel()``,
/// which projects the single source of truth — the compiled `menubar`
/// (menubar.yaml) — into a render model. This replaced a hand-maintained
/// static Commands tree that could drift from the spec; projecting from the
/// bundle means the Swift menu bar can no longer diverge from menubar.yaml.
///
/// The dynamic Workspace / Appearance submenus stay runtime-populated by
/// bespoke code in `JasCommands.swift`; the model only carries their trigger
/// label and identity. Mirrors the Rust reference `workspace/menu.rs`.

import Foundation
import SwiftUI

/// Which runtime-populated submenu a ``MenuEntry/dynamicSubmenu(label:kind:)``
/// drives.
public enum SubmenuKind: Equatable {
    case workspace
    case appearance
}

/// One resolved menu entry.
public enum MenuEntry {
    case separator
    case dynamicSubmenu(label: String, kind: SubmenuKind)
    case action(label: String, action: String,
                params: [String: Any], shortcut: String,
                enabledWhen: String?)
}

/// One top-level menu (e.g. "&File") and its entries.
public struct MenuModel {
    public let label: String
    public let entries: [MenuEntry]
}

/// Project the compiled `menubar` (menubar.yaml) into the render model.
/// Returns an empty array if the bundle is missing/corrupt (never throws).
/// Mirrors the Rust reference `menu_bar_model`.
public func menuBarModel() -> [MenuModel] {
    guard let ws = WorkspaceData.load() else { return [] }
    let menus = ws.menubar()
    return menus.compactMap { entry in
        guard let menu = entry as? [String: Any] else { return nil }
        return projectMenu(menu)
    }
}

private func projectMenu(_ menu: [String: Any]) -> MenuModel {
    let label = (menu["label"] as? String) ?? ""
    let items = (menu["items"] as? [Any]) ?? []
    let entries = items.map(projectEntry)
    return MenuModel(label: label, entries: entries)
}

private func projectEntry(_ item: Any) -> MenuEntry {
    // A bare "separator" string.
    if let s = item as? String, s == "separator" {
        return .separator
    }
    guard let obj = item as? [String: Any] else {
        return .separator
    }
    // A submenu carries nested "items"; the only ones today are the dynamic
    // Workspace / Appearance submenus, rendered natively (runtime-populated).
    if obj["items"] != nil {
        let label = (obj["label"] as? String) ?? ""
        let id = (obj["id"] as? String) ?? ""
        let kind: SubmenuKind = (id.contains("appearance") || label.contains("Appearance"))
            ? .appearance : .workspace
        return .dynamicSubmenu(label: label, kind: kind)
    }
    let params = (obj["params"] as? [String: Any]) ?? [:]
    return .action(
        label: (obj["label"] as? String) ?? "",
        action: (obj["action"] as? String) ?? "",
        params: params,
        shortcut: (obj["shortcut"] as? String) ?? "",
        enabledWhen: obj["enabled_when"] as? String)
}

/// Strip Windows/GTK-style `&` mnemonic markers from a label for display.
/// The bundle labels (e.g. `&File`, `Zoom &In`) mark the accelerator key for
/// frameworks that support mnemonics; macOS menus do not, so the marker is
/// removed for display. `&&` is an escaped literal ampersand → `&`. Mirrors
/// the Rust reference `menu_bar::strip_mnemonic` verbatim.
public func stripMnemonic(_ label: String) -> String {
    var out = ""
    out.reserveCapacity(label.count)
    var iter = Array(label)
    var i = 0
    while i < iter.count {
        let c = iter[i]
        if c == "&" {
            if i + 1 < iter.count && iter[i + 1] == "&" {
                out.append("&")
                i += 2
                continue
            }
            // otherwise drop the mnemonic marker
            i += 1
            continue
        }
        out.append(c)
        i += 1
    }
    return out
}

/// A parsed keyboard shortcut: the key character plus SwiftUI modifiers.
public struct ParsedShortcut: Equatable {
    public let key: Character
    public let modifiers: EventModifiers
}

/// Parse a bundle shortcut string (e.g. `"Ctrl+Shift+S"`, `"Ctrl+="`,
/// `"Ctrl+0"`) into a SwiftUI key + modifier set. Returns nil for an empty
/// or unparseable shortcut (the renderer then emits no `.keyboardShortcut`).
///
/// Modifier spellings match the bundle's: `Ctrl` → `.command` (macOS maps the
/// platform-neutral "Ctrl" accelerator to Command), `Alt` → `.option`,
/// `Shift` → `.shift`. The final token is the key: a single letter, a digit,
/// `=`, `-`, or the literal `Delete`.
public func parseShortcut(_ shortcut: String) -> ParsedShortcut? {
    let trimmed = shortcut.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let parts = trimmed.split(separator: "+").map { String($0) }
    guard let last = parts.last else { return nil }
    var modifiers: EventModifiers = []
    for token in parts.dropLast() {
        switch token {
        case "Ctrl", "Cmd", "Command": modifiers.insert(.command)
        case "Alt", "Option": modifiers.insert(.option)
        case "Shift": modifiers.insert(.shift)
        default: break
        }
    }
    let key: Character
    switch last {
    case "Delete": key = KeyEquivalent.delete.character
    default:
        guard let first = last.first, last.count == 1 else { return nil }
        // Letter keys use their lowercase form; digits / `=` / `-` pass
        // through unchanged.
        key = Character(first.lowercased())
    }
    return ParsedShortcut(key: key, modifiers: modifiers)
}
