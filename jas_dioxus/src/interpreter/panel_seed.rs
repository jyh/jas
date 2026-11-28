//! A script's `app_state` seed, the part every channel shares (row 284, row
//! 291): the ruled check (a panel the workspace has, a key its `state:`
//! declares), the refusal it answers, and the value in the store's form.
//! The FFI engine's seed door (`JasEngine::script_seed_panel`, with Rust's
//! replay behind it) and the web's level-2 hook (`test_hook::seed`) both
//! use it, so a seed one channel refuses the others refuse by the same kind.

use serde_json::Value;

/// Why a script seed was refused: its [`kind`](SeedRefusal::kind) is the
/// name a channel reports (the FFI seam's `jas_last_error_json`), and its
/// `Display` is the message the replay carries (`UnknownPanel <panel>`,
/// `UndeclaredPanelKey <panel>.<key>`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SeedRefusal {
    NoWorkspace,
    UnknownPanel(String),
    UndeclaredPanelKey(String, String),
}

impl SeedRefusal {
    // Read by the FFI seam only; the web hook reports the Display, whose first word is the kind.
    #[allow(dead_code)]
    pub(crate) fn kind(&self) -> &'static str {
        match self {
            SeedRefusal::NoWorkspace => "NoWorkspace",
            SeedRefusal::UnknownPanel(_) => "UnknownPanel",
            SeedRefusal::UndeclaredPanelKey(..) => "UndeclaredPanelKey",
        }
    }
}

impl std::fmt::Display for SeedRefusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SeedRefusal::NoWorkspace => write!(f, "no workspace"),
            SeedRefusal::UnknownPanel(p) => write!(f, "UnknownPanel {p}"),
            SeedRefusal::UndeclaredPanelKey(p, k) => write!(f, "UndeclaredPanelKey {p}.{k}"),
        }
    }
}

/// The ruled check: `panel_id` is a panel of the compiled workspace and its
/// `state:` declares `key`.
pub(crate) fn check_seed(panel_id: &str, key: &str) -> Result<(), SeedRefusal> {
    let ws = crate::interpreter::workspace::Workspace::load().ok_or(SeedRefusal::NoWorkspace)?;
    ws.panel(panel_id).ok_or_else(|| SeedRefusal::UnknownPanel(panel_id.to_string()))?;
    if !ws.panel_state_defaults(panel_id).contains_key(key) {
        return Err(SeedRefusal::UndeclaredPanelKey(panel_id.to_string(), key.to_string()));
    }
    Ok(())
}

/// A script seed's value as the store holds it: an array whose items are
/// index paths (an element's document path) has each path wrapped as
/// `{"__path__": [...]}`, the form the panel state holds a selection of
/// elements in; every other value goes as written.
pub(crate) fn seed_panel_value(v: &Value) -> Value {
    let is_path = |x: &Value| x.as_array().is_some_and(|a| a.iter().all(|i| i.as_u64().is_some()));
    match v {
        Value::Array(items) => Value::Array(items.iter()
            .map(|x| if is_path(x) { serde_json::json!({"__path__": x}) } else { x.clone() })
            .collect()),
        other => other.clone(),
    }
}
