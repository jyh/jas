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
