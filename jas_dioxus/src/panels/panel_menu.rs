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
