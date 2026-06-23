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

// MARK: - Pure key → action resolution (TESTING_STRATEGY.md §5 rec 3)
//
// A keyboard shortcut becomes an application command in two steps:
//   1. BINDING — the framework key event (here an AppKit `NSEvent`) is
//      normalized into a framework-neutral ``KeyChord``. This is
//      platform-specific (on macOS the ⌘ key arrives as `meta`, mapped to the
//      bundle's `Ctrl` vocabulary) and stays on the MANUAL floor.
//   2. RESOLUTION — the chord is looked up against the compiled bundle
//      `shortcuts` table to yield an action verb and its params. This step is
//      PURE and framework-free, and is the refactor target of §5 rec 3: it is
//      pinned cross-language by the key corpus so all four apps resolve a chord
//      to byte-identical {action, params}.
//
// ``parseShortcut`` above produces a SwiftUI ``EventModifiers`` set with
// macOS-specific folding (`Ctrl` → `.command`, letters lowercased) for the menu
// renderer. The resolver below instead works in the framework-NEUTRAL canonical
// vocabulary (separate ctrl/shift/alt/meta booleans, letters UPPERCASE) so its
// chord comparison is byte-identical to the Rust reference `resolve_key`. The
// two intentionally differ; ``resolveKeyChord`` is the cross-language pinned one.
//
// The live keyboard path is wired to ``resolveKeyChord`` in Phase 2 of §5 rec 3;
// until then it is exercised only by the key-resolution corpus.

/// A normalized, framework-neutral key chord. `key` is the canonical token:
/// an UPPERCASE ASCII letter (`"V"`), a digit (`"0"`), a symbol (`"="`, `"-"`,
/// `"\\"`), or a named key (`"Delete"`, `"Backspace"`). `shift` is carried as a
/// SEPARATE flag and is never folded into the character. Mirrors the Rust
/// reference `KeyChord`.
public struct KeyChord: Equatable {
    public let key: String
    public let ctrl: Bool
    public let shift: Bool
    public let alt: Bool
    public let meta: Bool

    /// Build a chord, canonicalizing the key token (single ASCII letters are
    /// uppercased; everything else kept verbatim) so live callers need not
    /// pre-normalize case. Mirrors Rust `KeyChord::new`.
    public init(key: String, ctrl: Bool = false, shift: Bool = false,
                alt: Bool = false, meta: Bool = false) {
        self.key = canonKey(key)
        self.ctrl = ctrl
        self.shift = shift
        self.alt = alt
        self.meta = meta
    }
}

/// The resolved command: an action verb plus its resolved params. Mirrors the
/// Rust reference `ResolvedCommand`. `params` is `[:]` when the shortcut entry
/// carries none.
public struct ResolvedCommand: Equatable {
    public let action: String
    public let params: [String: String]
}

/// Canonicalize a key token: a single ASCII letter is uppercased; every other
/// token (digit, symbol, named key) is returned verbatim. This makes the chord
/// comparison case-insensitive for letters while leaving `"Delete"`, `"="`,
/// `"\\"` untouched. Mirrors Rust `canon_key`.
private func canonKey(_ key: String) -> String {
    if key.count == 1, let c = key.first, c.isASCII, c.isLetter {
        return key.uppercased()
    }
    return key
}

/// Parse a bundle shortcut string (`"Ctrl+Shift+S"`, `"V"`, `"Shift+E"`,
/// `"Delete"`, `"\\"`) into a normalized chord. Tokens are split on `+`; all
/// but the last are modifiers (matched case-insensitively: `Ctrl`/`Control`,
/// `Shift`, `Alt`/`Option`, `Meta`/`Cmd`/`Command`/`Super`), and the last token
/// is the key. Returns nil for an empty string. (No shortcut in the table uses
/// `+` as its key, so splitting on `+` is unambiguous.) Mirrors Rust
/// `parse_shortcut` — note it does NOT do the macOS `Ctrl`→Command folding that
/// the menu-renderer ``parseShortcut`` above performs; the resolver stays in the
/// framework-neutral vocabulary for cross-language byte parity.
public func parseShortcutChord(_ s: String) -> KeyChord? {
    if s.isEmpty { return nil }
    // Split on "+" keeping empty subsequences so a trailing-key like "\\" or a
    // literal "+" key would survive; the bundle has no "+"-as-key entry.
    let tokens = s.components(separatedBy: "+")
    guard let keyTok = tokens.last else { return nil }
    let modToks = tokens.dropLast()
    var ctrl = false, shift = false, alt = false, meta = false
    for m in modToks {
        switch m.lowercased() {
        case "ctrl", "control": ctrl = true
        case "shift": shift = true
        case "alt", "option": alt = true
        case "meta", "cmd", "command", "super": meta = true
        // Unknown modifier token: ignore (keeps parsing total).
        default: break
        }
    }
    return KeyChord(key: keyTok, ctrl: ctrl, shift: shift, alt: alt, meta: meta)
}

/// Resolve a chord against the compiled bundle `shortcuts` table. Returns the
/// first entry whose parsed chord equals `chord`, or nil if unmapped / the
/// bundle is missing. Mirrors Rust `resolve_key`.
public func resolveKeyChord(_ chord: KeyChord) -> ResolvedCommand? {
    guard let ws = WorkspaceData.load(),
          let shortcuts = ws.data["shortcuts"] as? [Any] else { return nil }
    return resolveKeyIn(chord, shortcuts: shortcuts)
}

/// Resolve against an explicit `shortcuts` array (the testable core, so the
/// corpus can resolve every case against one loaded bundle). Returns the first
/// entry whose parsed chord equals `chord`, or nil if unmapped. Mirrors Rust
/// `resolve_key_in`.
public func resolveKeyIn(_ chord: KeyChord, shortcuts: [Any]) -> ResolvedCommand? {
    for entry in shortcuts {
        guard let obj = entry as? [String: Any],
              let keyStr = obj["key"] as? String,
              let parsed = parseShortcutChord(keyStr) else { continue }
        if parsed == chord {
            let action = (obj["action"] as? String) ?? ""
            var params: [String: String] = [:]
            if let p = obj["params"] as? [String: Any] {
                for (k, v) in p {
                    if let s = v as? String { params[k] = s }
                }
            }
            return ResolvedCommand(action: action, params: params)
        }
    }
    return nil
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
