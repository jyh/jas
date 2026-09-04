//! Panel menu item types.

/// A menu item in a panel's hamburger menu.
#[derive(Debug, Clone, PartialEq)]
pub enum PanelMenuItem {
    /// A plain action: label, command string, optional shortcut hint.
    Action {
        label: &'static str,
        command: &'static str,
        shortcut: &'static str,
    },
    /// A toggle (checkbox) item.
    Toggle {
        label: &'static str,
        command: &'static str,
    },
    /// A radio-group item; items sharing the same `group` are mutually exclusive.
    Radio {
        label: &'static str,
        command: &'static str,
        group: &'static str,
    },
    /// Horizontal separator line.
    Separator,
}

impl PanelMenuItem {
    /// The command an item dispatches, or `None` for a separator.
    /// Lets per-panel tests probe menu content without naming the
    /// `Action/Toggle/Radio` variants (which count against the
    /// genericity metric).
    pub fn command(&self) -> Option<&str> {
        match self {
            PanelMenuItem::Action { command, .. }
            | PanelMenuItem::Toggle { command, .. }
            | PanelMenuItem::Radio { command, .. } => Some(command),
            PanelMenuItem::Separator => None,
        }
    }

    /// The display label of an item, or `None` for a separator.
    pub fn label(&self) -> Option<&str> {
        match self {
            PanelMenuItem::Action { label, .. }
            | PanelMenuItem::Toggle { label, .. }
            | PanelMenuItem::Radio { label, .. } => Some(label),
            PanelMenuItem::Separator => None,
        }
    }

    /// Whether this item is a separator.
    pub fn is_separator(&self) -> bool {
        matches!(self, PanelMenuItem::Separator)
    }
}

/// Build a panel's hamburger menu from the compiled workspace bundle
/// (the panel YAML `menu:` array) rather than a hand-written native list.
/// The YAML is the single source of truth (review #15); this reader is
/// what each panel's `menu_items()` now delegates to.
///
/// PanelMenuItem keeps its `&'static str` fields so the renderer and the
/// `matches!(.., command: "x")` panel tests stay unchanged. We therefore
/// leak the small, finite, app-lifetime menu strings once per panel and
/// cache the built list, keeping the leak bounded and repeat opens cheap.
pub fn menu_items_from_yaml(content_id: &str) -> Vec<PanelMenuItem> {
    static CACHE: std::sync::OnceLock<
        std::sync::Mutex<std::collections::HashMap<String, Vec<PanelMenuItem>>>,
    > = std::sync::OnceLock::new();
    let cache = CACHE.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()));
    let mut guard = cache.lock().unwrap();
    if let Some(items) = guard.get(content_id) {
        return items.clone();
    }
    let items = build_menu_items(content_id);
    guard.insert(content_id.to_string(), items.clone());
    items
}

fn build_menu_items(content_id: &str) -> Vec<PanelMenuItem> {
    let leak = |s: &str| -> &'static str { Box::leak(s.to_string().into_boxed_str()) };
    let Some(ws) = crate::interpreter::workspace::Workspace::load() else {
        return Vec::new();
    };
    let menu = ws.panel_menu(content_id);

    // A radio group is a set of menu entries that share the same `action`
    // (e.g. every "set_color_panel_mode" item, or every
    // "set_swatch_thumbnail_size" item). The YAML doesn't carry an explicit
    // `group:` key — sameness of the action *is* the grouping — so we count
    // action occurrences to tell a one-off checkbox (Toggle) apart from a
    // member of a mutually-exclusive set (Radio).
    let mut action_counts: std::collections::HashMap<&str, usize> =
        std::collections::HashMap::new();
    for e in &menu {
        if let Some(action) = e.as_object().and_then(|o| o.get("action")).and_then(|a| a.as_str()) {
            *action_counts.entry(action).or_insert(0) += 1;
        }
    }

    menu.iter()
        .filter_map(|e| {
            // A bare `separator` YAML item compiles to the JSON string "separator".
            if e.as_str() == Some("separator") {
                return Some(PanelMenuItem::Separator);
            }
            let obj = e.as_object()?;
            let label = leak(obj.get("label")?.as_str()?);
            let action = obj.get("action").and_then(|a| a.as_str());
            // A menu entry is a radio-group member when its `action` recurs
            // across the menu (the YAML expresses grouping by action sameness,
            // not an explicit `group:` key).
            let is_radio_member =
                action.map(|a| action_counts.get(a).copied().unwrap_or(0) > 1).unwrap_or(false);

            // Radio members share one action, so we fold their `params` values
            // into the command (`set_color_panel_mode:grayscale`,
            // `set_swatch_thumbnail_size:small`) to keep them distinguishable
            // when the menu view dispatches the bare command with no params.
            // Every other entry keeps its action verbatim — folding params
            // there would corrupt single-action commands like
            // `close_panel` (params: { panel: color }).
            let command: &str = if is_radio_member {
                leak(&command_with_params(obj))
            } else {
                leak(action.unwrap_or(""))
            };

            // A `checked:` / `checked_when:` expression marks a stateful item:
            // a radio-group member, or a standalone checkbox (Toggle). The
            // radio group key is the action name.
            let has_checked = obj.contains_key("checked") || obj.contains_key("checked_when");
            Some(if has_checked && is_radio_member {
                PanelMenuItem::Radio { label, command, group: leak(action.unwrap_or("")) }
            } else if has_checked {
                PanelMenuItem::Toggle { label, command }
            } else {
                // Plain actions, dynamic submenus (`type: submenu`, which carry
                // an explicit `action:` so the menu view's special-case host
                // — keyed on the command — fires), and disabled placeholders
                // (no `action:`, gated off by the panel's `is_enabled`) all
                // surface as Action.
                PanelMenuItem::Action { label, command, shortcut: "" }
            })
        })
        .collect()
}

/// Build the runtime command for a menu entry: the `action` string with any
/// `params` values appended as `:value` segments (in the compiled JSON's
/// param order). Entries with no action produce an empty command (disabled
/// placeholders). This lets several radio members share one YAML `action`
/// yet dispatch to distinct native commands without threading params through
/// the menu view.
fn command_with_params(obj: &serde_json::Map<String, serde_json::Value>) -> String {
    let action = obj.get("action").and_then(|a| a.as_str()).unwrap_or("");
    let mut cmd = action.to_string();
    if let Some(params) = obj.get("params").and_then(|p| p.as_object()) {
        for v in params.values() {
            let seg = match v {
                serde_json::Value::String(s) => s.clone(),
                other => other.to_string(),
            };
            cmd.push(':');
            cmd.push_str(&seg);
        }
    }
    cmd
}

// ---------------------------------------------------------------------------
// Generic panel-menu CHECKED state
// ---------------------------------------------------------------------------

/// The `checked_when:` (or `checked:`) predicate of the panel-menu entry whose
/// runtime command is `cmd`, or `None` when there is no such entry or it
/// declares no predicate.
///
/// The command is matched with the SAME fold `build_menu_items` applies
/// (`command_with_params` for radio members, the bare action otherwise), so a
/// caller holding a `PanelMenuItem`'s command can always find its own entry.
///
/// Both spellings are read because the panel-menu vocabulary uses both:
/// `workspace/panels/{brushes,color,opacity,stroke,swatches}.yaml` write
/// `checked_when:`, while `{align,character,paragraph}.yaml` write `checked:`.
/// `build_menu_items` above already reads both to decide Toggle vs Radio, so
/// reading only one here would leave three panels' check marks dead — the
/// exact defect this path exists to close. No expression feature is added:
/// the two keys carry the same grammar and are evaluated the same way.
pub fn checked_expr(content_id: &str, cmd: &str) -> Option<String> {
    let ws = crate::interpreter::workspace::Workspace::load()?;
    let menu = ws.panel_menu(content_id);
    let mut action_counts: std::collections::HashMap<&str, usize> =
        std::collections::HashMap::new();
    for e in &menu {
        if let Some(action) = e.as_object().and_then(|o| o.get("action")).and_then(|a| a.as_str()) {
            *action_counts.entry(action).or_insert(0) += 1;
        }
    }
    for e in &menu {
        let obj = match e.as_object() {
            Some(o) => o,
            None => continue,
        };
        let action = obj.get("action").and_then(|a| a.as_str());
        let is_radio_member =
            action.map(|a| action_counts.get(a).copied().unwrap_or(0) > 1).unwrap_or(false);
        let entry_cmd: String = if is_radio_member {
            command_with_params(obj)
        } else {
            action.unwrap_or("").to_string()
        };
        if entry_cmd != cmd || cmd.is_empty() {
            continue;
        }
        return obj
            .get("checked_when")
            .or_else(|| obj.get("checked"))
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string());
    }
    None
}

/// Whether the panel-menu entry for `cmd` is checked, evaluating its bundle
/// predicate against `ctx` through the SHARED menu-state evaluator.
///
/// An entry with no predicate — and a command that names no entry — is not
/// checked, matching `menu_state`'s `checked: null` for an item with no
/// `checked_when`.
pub fn is_checked_from_yaml(content_id: &str, cmd: &str, ctx: &serde_json::Value) -> bool {
    match checked_expr(content_id, cmd) {
        Some(expr) => crate::interpreter::menu_state::eval_bool(&expr, ctx),
        None => false,
    }
}

/// Build the expression context a panel's menu predicates are evaluated
/// against: the panel's own state table as `panel`, plus the `preferences`
/// tier the bundle ships.
///
/// `panel` starts from the bundle's declared state defaults for the panel and
/// is then overlaid with whatever this app holds LIVE for that panel. That
/// overlay is the whole of what the fourteen deleted per-panel `is_checked`
/// hooks used to encode, written once and named per panel instead of fourteen
/// times as native `match cmd` arms — jas_dioxus keeps its panel state in typed
/// `AppState` slots rather than a generic panel store, so something has to
/// publish those slots into the `panel` namespace, and this is that one place.
///
/// A panel absent from the list below contributes no live keys and evaluates
/// against the bundle defaults alone. For the Brushes panel that is currently
/// the WHOLE answer and it is a real gap, named rather than hidden: nothing in
/// `AppState` stores `view_mode` / `thumbnail_size` / `category_filter`, and
/// `renderer::apply_set_panel_state_with_ctx` has no arm for those keys, so
/// `set_brush_view_mode` and friends do not persist here. The check marks now
/// EVALUATE (they showed nothing at all before); what they evaluate is the
/// declared default until brushes panel state exists.
pub fn panel_menu_ctx(
    content_id: &str,
    st: &crate::workspace::app_state::AppState,
) -> serde_json::Value {
    use serde_json::Value as J;
    let mut panel: serde_json::Map<String, J> = crate::interpreter::workspace::Workspace::load()
        .map(|ws| ws.panel_state_defaults(content_id).into_iter().collect())
        .unwrap_or_default();
    for (k, v) in live_panel_state(content_id, st) {
        panel.insert(k, v);
    }
    let preferences = crate::interpreter::workspace::Workspace::load()
        .and_then(|ws| ws.data().get("preferences").cloned())
        .unwrap_or(J::Null);
    serde_json::json!({
        "panel": J::Object(panel),
        "preferences": preferences,
    })
}

/// The live `panel.*` values this app holds for `content_id`, keyed exactly as
/// the panel's YAML state table declares them.
///
/// Each arm replaces one deleted native `is_checked` hook, and is a statement
/// about STORAGE (where this app keeps the value) rather than about menus — the
/// predicate that reads it stays in the YAML.
fn live_panel_state(
    content_id: &str,
    st: &crate::workspace::app_state::AppState,
) -> Vec<(String, serde_json::Value)> {
    use serde_json::Value as J;
    let s = |v: &str| J::String(v.to_string());
    let b = J::Bool;
    let pairs: Vec<(&str, J)> = match content_id {
        "color_panel_content" => {
            use crate::workspace::color_panel_view::ColorMode;
            let mode = match st.color_panel_mode {
                ColorMode::Grayscale => "grayscale",
                ColorMode::Hsb => "hsb",
                ColorMode::Rgb => "rgb",
                ColorMode::Cmyk => "cmyk",
                ColorMode::WebSafeRgb => "web_safe_rgb",
            };
            vec![("mode", s(mode))]
        }
        "stroke_panel_content" => vec![
            ("cap", s(&st.stroke_panel.cap)),
            ("join", s(&st.stroke_panel.join)),
        ],
        "swatches_panel_content" => {
            vec![("thumbnail_size", s(&st.swatches_panel.thumbnail_size))]
        }
        "opacity_panel_content" => vec![
            ("thumbnails_hidden", b(st.opacity_panel.thumbnails_hidden)),
            ("options_shown", b(st.opacity_panel.options_shown)),
            ("new_masks_clipping", b(st.opacity_panel.new_masks_clipping)),
            ("new_masks_inverted", b(st.opacity_panel.new_masks_inverted)),
        ],
        "character_panel_content" => vec![
            ("snap_to_glyph_visible", b(st.character_panel.snap_to_glyph_visible)),
            ("all_caps", b(st.character_panel.all_caps)),
            ("small_caps", b(st.character_panel.small_caps)),
            ("superscript", b(st.character_panel.superscript)),
            ("subscript", b(st.character_panel.subscript)),
        ],
        "paragraph_panel_content" => {
            vec![("hanging_punctuation", b(st.paragraph_panel.hanging_punctuation))]
        }
        "align_panel_content" => vec![
            ("use_preview_bounds", b(st.align_panel.use_preview_bounds)),
            ("align_to", s(st.align_panel.align_to.as_str())),
        ],
        "properties_panel_content" => {
            vec![("prop_constrain", b(st.properties_constrain))]
        }
        _ => vec![],
    };
    pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn menu_items_from_yaml_reads_boolean_panel() {
        // The builder reads workspace/panels/boolean.yaml's `menu:` from the
        // compiled bundle and maps it to PanelMenuItem (7 actions + 3 separators).
        let items = menu_items_from_yaml("boolean_panel_content");
        assert!(
            items.iter().any(|i| matches!(
                i,
                PanelMenuItem::Action { command: "make_compound_shape", .. }
            )),
            "boolean menu should contain make_compound_shape; got {items:?}"
        );
        assert!(items.iter().any(|i| matches!(
            i,
            PanelMenuItem::Action { command: "close_panel", .. }
        )));
        assert_eq!(
            items.iter().filter(|i| matches!(i, PanelMenuItem::Separator)).count(),
            3
        );
        assert_eq!(items.len(), 10);
    }

    #[test]
    fn color_radio_members_fold_params_into_command() {
        // The Color panel's five mode rows all share `action:
        // set_color_panel_mode`, so the builder treats them as a radio
        // group and folds each `params.mode` value into the command,
        // keeping them distinguishable for the no-params menu dispatch.
        let items = menu_items_from_yaml("color_panel_content");
        let radios: Vec<(&str, &str)> = items.iter().filter_map(|i| match i {
            PanelMenuItem::Radio { command, group, .. } => Some((*command, *group)),
            _ => None,
        }).collect();
        assert!(radios.contains(&("set_color_panel_mode:grayscale", "set_color_panel_mode")));
        assert!(radios.contains(&("set_color_panel_mode:rgb", "set_color_panel_mode")));
        assert!(radios.contains(&("set_color_panel_mode:web_safe_rgb", "set_color_panel_mode")));
        // Plain actions keep their action verbatim (no param folding).
        assert!(items.iter().any(|i| matches!(
            i, PanelMenuItem::Action { command: "invert_active_color", .. })));
        // close_panel keeps its action even though the YAML carries
        // `params: { panel: color }`.
        assert!(items.iter().any(|i| matches!(
            i, PanelMenuItem::Action { command: "close_panel", .. })));
    }

    #[test]
    fn swatches_submenu_becomes_open_library_action() {
        // The dynamic "Open Swatch Library" submenu entry has an explicit
        // `action: open_swatch_library` in the YAML so the menu view's
        // submenu host (keyed on that command) still fires.
        let items = menu_items_from_yaml("swatches_panel_content");
        assert!(items.iter().any(|i| matches!(
            i, PanelMenuItem::Action { command: "open_swatch_library", .. })),
            "swatches menu should expose open_swatch_library host; got {items:?}");
        // Thumbnail-size rows are a radio group with folded params.
        let radios: Vec<&str> = items.iter().filter_map(|i| match i {
            PanelMenuItem::Radio { command, .. } => Some(*command),
            _ => None,
        }).collect();
        assert!(radios.contains(&"set_swatch_thumbnail_size:small"));
        assert!(radios.contains(&"set_swatch_thumbnail_size:large"));
    }

    #[test]
    fn standalone_checkbox_is_toggle_not_radio() {
        // The Align panel has a single `toggle_use_preview_bounds` checkbox;
        // its action does not recur, so it is a Toggle, not a Radio.
        let items = menu_items_from_yaml("align_panel_content");
        assert!(items.iter().any(|i| matches!(
            i, PanelMenuItem::Toggle { command: "toggle_use_preview_bounds", .. })));
    }

    #[test]
    fn action_item_construction() {
        let item = PanelMenuItem::Action {
            label: "Close",
            command: "close_panel",
            shortcut: "",
        };
        assert_eq!(item, PanelMenuItem::Action {
            label: "Close",
            command: "close_panel",
            shortcut: "",
        });
    }

    #[test]
    fn toggle_item_construction() {
        let item = PanelMenuItem::Toggle {
            label: "Show Options",
            command: "toggle_options",
        };
        assert!(matches!(item, PanelMenuItem::Toggle { .. }));
    }

    #[test]
    fn radio_item_construction() {
        let item = PanelMenuItem::Radio {
            label: "RGB",
            command: "set_rgb",
            group: "color_mode",
        };
        assert!(matches!(item, PanelMenuItem::Radio { group: "color_mode", .. }));
    }

    #[test]
    fn separator_equality() {
        assert_eq!(PanelMenuItem::Separator, PanelMenuItem::Separator);
    }
}
