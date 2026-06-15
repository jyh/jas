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
    ws.panel_menu(content_id)
        .iter()
        .filter_map(|e| {
            // A bare `separator` YAML item compiles to the JSON string "separator".
            if e.as_str() == Some("separator") {
                return Some(PanelMenuItem::Separator);
            }
            let obj = e.as_object()?;
            let label = leak(obj.get("label")?.as_str()?);
            let command = leak(obj.get("action").and_then(|a| a.as_str()).unwrap_or(""));
            // YAML marks a checkbox item with a `checked:` expression and a
            // radio item with a `group:`; everything else is a plain action.
            // (`type: submenu` dynamic-library items are handled natively for
            // now and live only in submenu panels, which are not yet migrated.)
            Some(if obj.contains_key("checked") {
                PanelMenuItem::Toggle { label, command }
            } else if let Some(group) = obj.get("group").and_then(|g| g.as_str()) {
                PanelMenuItem::Radio { label, command, group: leak(group) }
            } else {
                PanelMenuItem::Action { label, command, shortcut: "" }
            })
        })
        .collect()
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
