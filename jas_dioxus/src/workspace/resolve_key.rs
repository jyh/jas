//! Pure key-chord → action resolution (TESTING_STRATEGY.md §5 rec 3).
//!
//! A keyboard shortcut becomes an application command in two steps:
//!   1. BINDING — the framework key event (Dioxus `KeyboardData`, AppKit
//!      `NSEvent`, GTK `GdkEvent.Key`, Qt `QKeyEvent`) is normalized into a
//!      framework-neutral [`KeyChord`]. This is platform-specific (e.g. on
//!      macOS the ⌘ key arrives as `meta`, mapped to the bundle's `Ctrl`
//!      vocabulary) and stays on the MANUAL floor.
//!   2. RESOLUTION — the chord is looked up against the compiled bundle
//!      `shortcuts` table (workspace/shortcuts.yaml) to yield an action verb
//!      and its params. This step is PURE and framework-free, and is the
//!      refactor target of §5 rec 3: it is pinned cross-language by the key
//!      corpus in `cross_language_test.rs` so all four apps resolve a chord
//!      to byte-identical `{action, params}`.
//!
//! `shortcuts` is the single authoritative key→action table; it carries both
//! menu actions (`Ctrl+N` → `new_document`) and tool selections (`V` →
//! `select_tool {tool: selection}`), already disambiguated (no duplicate
//! chords). Resolution is therefore a first-match lookup — the list order is
//! a deterministic tie-break that the present table never exercises.

use serde_json::{Map, Value};

/// A normalized, framework-neutral key chord. `key` is the canonical token:
/// an UPPERCASE ASCII letter (`"V"`), a digit (`"0"`), a symbol (`"="`,
/// `"-"`, `"\\"`), or a named key (`"Delete"`, `"Backspace"`). `shift` is
/// carried as a SEPARATE flag and is never folded into the character.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyChord {
    pub key: String,
    pub ctrl: bool,
    pub shift: bool,
    pub alt: bool,
    pub meta: bool,
}

impl KeyChord {
    /// Build a chord, canonicalizing the key token (single ASCII letters are
    /// uppercased; everything else is kept verbatim) so live callers need not
    /// pre-normalize case.
    pub fn new(key: &str, ctrl: bool, shift: bool, alt: bool, meta: bool) -> Self {
        KeyChord { key: canon_key(key), ctrl, shift, alt, meta }
    }
}

/// The resolved command: an action verb plus its resolved params.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedCommand {
    pub action: String,
    pub params: Map<String, Value>,
}

/// Canonicalize a key token: a single ASCII letter is uppercased; every other
/// token (digit, symbol, named key) is returned verbatim. This makes the
/// chord comparison case-insensitive for letters while leaving `"Delete"`,
/// `"="`, `"\\"` untouched.
fn canon_key(key: &str) -> String {
    let chars: Vec<char> = key.chars().collect();
    if chars.len() == 1 && chars[0].is_ascii_alphabetic() {
        key.to_ascii_uppercase()
    } else {
        key.to_string()
    }
}

/// Parse a bundle shortcut string (`"Ctrl+Shift+S"`, `"V"`, `"Shift+E"`,
/// `"Delete"`, `"\\"`) into a normalized chord. Tokens are split on `+`; all
/// but the last are modifiers (matched case-insensitively: `Ctrl`/`Control`,
/// `Shift`, `Alt`/`Option`, `Meta`/`Cmd`/`Command`), and the last token is the
/// key. Returns `None` for an empty string. (No shortcut in the table uses
/// `+` as its key, so splitting on `+` is unambiguous here.)
pub fn parse_shortcut(s: &str) -> Option<KeyChord> {
    if s.is_empty() {
        return None;
    }
    let tokens: Vec<&str> = s.split('+').collect();
    let (key_tok, mod_toks) = tokens.split_last()?;
    let (mut ctrl, mut shift, mut alt, mut meta) = (false, false, false, false);
    for m in mod_toks {
        match m.to_ascii_lowercase().as_str() {
            "ctrl" | "control" => ctrl = true,
            "shift" => shift = true,
            "alt" | "option" => alt = true,
            "meta" | "cmd" | "command" | "super" => meta = true,
            // Unknown modifier token: ignore (keeps parsing total).
            _ => {}
        }
    }
    Some(KeyChord { key: canon_key(key_tok), ctrl, shift, alt, meta })
}

/// Resolve a chord against the compiled bundle `shortcuts` table. Returns the
/// first entry whose parsed chord equals `chord`, or `None` if unmapped.
pub fn resolve_key(chord: &KeyChord) -> Option<ResolvedCommand> {
    let ws = crate::interpreter::workspace::Workspace::load()?;
    let shortcuts = ws.data().get("shortcuts").and_then(|s| s.as_array())?;
    resolve_key_in(chord, shortcuts)
}

/// Resolve against an explicit `shortcuts` array (the testable core, so the
/// corpus can resolve every case against one loaded bundle).
pub fn resolve_key_in(chord: &KeyChord, shortcuts: &[Value]) -> Option<ResolvedCommand> {
    for entry in shortcuts {
        let key = match entry.get("key").and_then(|k| k.as_str()) {
            Some(k) => k,
            None => continue,
        };
        let parsed = match parse_shortcut(key) {
            Some(c) => c,
            None => continue,
        };
        if &parsed == chord {
            let action = entry
                .get("action")
                .and_then(|a| a.as_str())
                .unwrap_or("")
                .to_string();
            let params = entry
                .get("params")
                .and_then(|p| p.as_object())
                .cloned()
                .unwrap_or_default();
            return Some(ResolvedCommand { action, params });
        }
    }
    None
}

/// What one key press does, decided in ONE place (the engine's key order, and
/// the level-1 input-script runner's: docs/TESTING.md section 6). The callers
/// carry out the decision on their own model; the ORDER lives here only, so a
/// script replayed at level 1 takes the key the way the app does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyRoute {
    /// The action `delete_selection` (an unclaimed Delete or Backspace).
    DeleteSelection,
    /// A caret key no tool takes that `shortcuts.yaml` binds: this ACTION,
    /// run by the engine's action route (the arrows' `nudge_selection`).
    Action(ResolvedCommand),
    /// The active tool's `on_key_event`, with this named key.
    ToolKey(&'static str),
    /// The active tool's `on_key_event`, with this character: a tool that
    /// captures the keyboard takes every key first (the web's law).
    ToolChar(String),
    /// The model's undo.
    Undo,
    /// The model's redo.
    Redo,
    /// Switch to this tool id (a `select_tool` shortcut, unmodified).
    SelectTool(String),
    /// A clipboard command chord (Ctrl+C / X / V / Shift+V): this ACTION, run
    /// by the engine's action route, which needs the shell's clipboard
    /// (`menu_native::clipboard_verb`).
    Clipboard(String),
    /// Nothing handles it; the shell may apply its own default.
    Unhandled,
    /// Not a key token the engine takes: a named key or one character.
    BadKey,
}

/// The engine's key order (`ffi_pointer::jas_key_event`). `name` is `Escape`,
/// `Enter`, `Delete`, `Backspace` or one character; `tool_takes(key)` says
/// whether the active tool captures the keyboard or claims that key.
pub fn route_key(name: &str, mods: crate::tools::tool::KeyMods,
                 tool_takes: impl Fn(&str) -> bool) -> KeyRoute {
    let named: Option<&'static str> = match name {
        "Escape" => Some("Escape"),
        "Enter" => Some("Enter"),
        "Delete" => Some("Delete"),
        "Backspace" => Some("Backspace"),
        _ => None,
    };
    // The caret keys: a tool editing text takes them (the Type tool moves its
    // caret); otherwise a key shortcuts.yaml binds runs its action (an arrow,
    // or Shift with one, is `nudge_selection`) and the rest are unhandled.
    let caret: Option<&'static str> = match name {
        "ArrowLeft" => Some("ArrowLeft"),
        "ArrowRight" => Some("ArrowRight"),
        "ArrowUp" => Some("ArrowUp"),
        "ArrowDown" => Some("ArrowDown"),
        "Home" => Some("Home"),
        "End" => Some("End"),
        "Tab" => Some("Tab"),
        _ => None,
    };
    if let Some(key) = caret {
        if tool_takes(key) {
            return KeyRoute::ToolKey(key);
        }
        let chord = KeyChord::new(key, mods.ctrl, mods.shift, mods.alt, false);
        return match resolve_key(&chord) {
            Some(cmd) => KeyRoute::Action(cmd),
            None => KeyRoute::Unhandled,
        };
    }
    if let Some(key) = named {
        // flask STATUS § 277: an unclaimed Delete or Backspace is
        // `delete_selection` (shortcuts.yaml), unless the tool is editing text
        // or claims the key (the Artboard tool's Delete). Escape and Enter
        // always go to the tool (Escape cancels a marquee, Enter commits a pen).
        if matches!(key, "Delete" | "Backspace") && !tool_takes(key) {
            return KeyRoute::DeleteSelection;
        }
        return KeyRoute::ToolKey(key);
    }
    let mut chars = name.chars();
    let (Some(ch), None) = (chars.next(), chars.next()) else { return KeyRoute::BadKey };
    // A tool editing text takes every character and chord first, as on the
    // web (`workspace/keyboard.rs`), except Cmd+V: the paste takes the
    // clipboard path so the tool receives the clipboard's text.
    let paste = mods.ctrl && (ch == 'v' || ch == 'V');
    if !paste && tool_takes(name) {
        return KeyRoute::ToolChar(name.to_string());
    }
    let chord = KeyChord::new(&ch.to_string(), mods.ctrl, mods.shift, mods.alt, false);
    let Some(cmd) = resolve_key(&chord) else { return KeyRoute::Unhandled };
    // W5-3c: a COMMAND chord acts only where the engine can do the action
    // itself (undo, redo, and the clipboard verbs since 2026-10-17); every
    // other chord stays the menu's.
    if mods.ctrl {
        return match cmd.action.as_str() {
            "undo" => KeyRoute::Undo,
            "redo" => KeyRoute::Redo,
            a if crate::workspace::menu_native::clipboard_verb(a).is_some() => KeyRoute::Clipboard(a.to_string()),
            _ => KeyRoute::Unhandled,
        };
    }
    if cmd.action != "select_tool" {
        return KeyRoute::Unhandled;
    }
    match cmd.params.get("tool").and_then(|v| v.as_str()) {
        Some(id) => KeyRoute::SelectTool(id.to_string()),
        None => KeyRoute::Unhandled,
    }
}

#[cfg(test)]
mod route_key_tests {
    use super::{route_key, KeyRoute};
    use crate::tools::tool::KeyMods;

    fn m(ctrl: bool, shift: bool) -> KeyMods { KeyMods { shift, ctrl, alt: false, meta: false } }
    fn free(_: &str) -> bool { false }
    fn takes(_: &str) -> bool { true }

    #[test]
    fn an_unclaimed_delete_or_backspace_deletes_the_selection() {
        assert_eq!(route_key("Delete", m(false, false), free), KeyRoute::DeleteSelection);
        assert_eq!(route_key("Backspace", m(false, false), free), KeyRoute::DeleteSelection);
    }

    /// The web's law (`workspace/keyboard.rs`): while a tool captures the
    /// keyboard (a text-editing session), every key goes to it first, a
    /// character and a command chord alike, except Cmd+V, which takes the
    /// clipboard path so the tool receives the clipboard's text. Without this
    /// a typed `H` selected the Hand tool (the 10-20 feel sitting, finding 3).
    #[test]
    fn a_tool_that_captures_the_keyboard_takes_characters_and_chords_but_not_paste() {
        assert_eq!(route_key("H", m(false, false), takes), KeyRoute::ToolChar("H".into()));
        assert_eq!(route_key("i", m(false, true), takes), KeyRoute::ToolChar("i".into()));
        assert_eq!(route_key("z", m(true, false), takes), KeyRoute::ToolChar("z".into()));
        assert_eq!(route_key("v", m(true, false), takes), route_key("v", m(true, false), free),
                   "Cmd+V takes the clipboard path whether or not a tool captures");
        // Control: without a capturing tool, `H` is the Hand tool's shortcut.
        assert_eq!(route_key("H", m(false, false), free), KeyRoute::SelectTool("hand".into()));
    }

    /// The caret keys (the Type tool's named gaps, #596): a tool editing text
    /// takes them; with none, a key `shortcuts.yaml` binds runs its action (the
    /// arrows nudge) and the rest are UNHANDLED, never a bad key name.
    #[test]
    fn caret_keys_go_to_a_tool_that_takes_them_and_are_unhandled_otherwise() {
        for k in ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "Tab"] {
            assert_eq!(route_key(k, m(false, false), takes), KeyRoute::ToolKey(k), "{k} to the tool");
            assert_eq!(route_key(k, m(true, true), takes), KeyRoute::ToolKey(k), "{k}: modifiers too");
        }
        for k in ["Home", "End", "Tab"] {
            assert_eq!(route_key(k, m(false, false), free), KeyRoute::Unhandled, "{k} with no tool");
        }
        assert_eq!(route_key("F13", m(false, false), free), KeyRoute::BadKey, "CONTROL: still a bad name");
    }

    /// An arrow no tool takes is `nudge_selection` (shortcuts.yaml): 1 pt, 10
    /// with Shift, and up is toward smaller y. Every (key, shift) pair resolves
    /// to a DIFFERENT move, so a router that drops Shift or swaps an axis reds.
    #[test]
    fn an_unclaimed_arrow_nudges_one_point_or_ten_with_shift() {
        let mut seen = Vec::new();
        for (k, dx, dy) in [("ArrowLeft", -1, 0), ("ArrowRight", 1, 0), ("ArrowUp", 0, -1), ("ArrowDown", 0, 1)] {
            for (shift, n) in [(false, 1), (true, 10)] {
                let KeyRoute::Action(cmd) = route_key(k, m(false, shift), free) else {
                    panic!("{k} shift={shift}: not an action");
                };
                assert_eq!(cmd.action, "nudge_selection", "{k} shift={shift}");
                let got = (cmd.params["dx"].as_i64(), cmd.params["dy"].as_i64());
                assert_eq!(got, (Some(dx * n), Some(dy * n)), "{k} shift={shift}");
                seen.push(got);
            }
        }
        seen.sort();
        seen.dedup();
        assert_eq!(seen.len(), 8, "eight distinct moves");
    }

    /// Only a bare or Shift arrow is bound: Ctrl and Alt name no binding, so
    /// the shell keeps its own default for them.
    #[test]
    fn a_ctrl_or_alt_arrow_is_unhandled() {
        let alt = KeyMods { shift: false, ctrl: false, alt: true, meta: false };
        assert_eq!(route_key("ArrowLeft", alt, free), KeyRoute::Unhandled);
        assert_eq!(route_key("ArrowRight", m(true, false), free), KeyRoute::Unhandled);
        assert!(matches!(route_key("ArrowRight", m(false, false), free), KeyRoute::Action(_)), "CONTROL");
    }

    #[test]
    fn a_claimed_delete_goes_to_the_tool() {
        assert_eq!(route_key("Delete", m(false, false), takes), KeyRoute::ToolKey("Delete"));
        assert_eq!(route_key("Backspace", m(false, false), takes), KeyRoute::ToolKey("Backspace"));
    }

    #[test]
    fn escape_and_enter_go_to_the_tool_whether_or_not_it_captures() {
        assert_eq!(route_key("Escape", m(false, false), free), KeyRoute::ToolKey("Escape"));
        assert_eq!(route_key("Enter", m(false, false), free), KeyRoute::ToolKey("Enter"));
    }

    #[test]
    fn a_command_chord_acts_only_for_undo_and_redo() {
        assert_eq!(route_key("Z", m(true, false), free), KeyRoute::Undo);
        assert_eq!(route_key("z", m(true, false), free), KeyRoute::Undo);
        assert_eq!(route_key("Z", m(true, true), free), KeyRoute::Redo);
        // Ctrl+G is `group` in shortcuts.yaml: the menu's, not the key route's.
        assert_eq!(route_key("G", m(true, false), free), KeyRoute::Unhandled);
    }

    #[test]
    fn a_clipboard_chord_routes_to_its_action() {
        assert_eq!(route_key("c", m(true, false), free), KeyRoute::Clipboard("copy".into()));
        assert_eq!(route_key("X", m(true, false), free), KeyRoute::Clipboard("cut".into()));
        assert_eq!(route_key("v", m(true, false), free), KeyRoute::Clipboard("paste".into()));
        assert_eq!(route_key("V", m(true, true), free), KeyRoute::Clipboard("paste_in_place".into()));
        // Unmodified, `C` and `V` are tool letters, never the clipboard.
        assert!(!matches!(route_key("c", m(false, false), free), KeyRoute::Clipboard(_)));
        assert!(!matches!(route_key("v", m(false, false), free), KeyRoute::Clipboard(_)));
    }

    #[test]
    fn an_unmodified_tool_letter_selects_that_tool() {
        assert_eq!(route_key("V", m(false, false), free), KeyRoute::SelectTool("selection".into()));
        assert_eq!(route_key("M", m(false, false), free), KeyRoute::SelectTool("rect".into()));
    }

    #[test]
    fn an_unbound_character_is_unhandled_and_a_long_token_is_refused() {
        // The engine's own `jas_key_event` routes `ch.to_string()`; a token of
        // two characters never reaches it (`dispatch_key` refuses BadKey).
        assert_eq!(route_key("J", m(false, false), free), KeyRoute::Unhandled);
        // (`Tab` was this arm's long token until it became a caret key.)
        assert_eq!(route_key("PageUp", m(false, false), free), KeyRoute::BadKey);
        assert_eq!(route_key("", m(false, false), free), KeyRoute::BadKey);
    }
}
