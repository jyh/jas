//! Menu bar data — projected from the compiled workspace `menubar`.
//!
//! The menu bar is rendered (in `menu_bar.rs`) from [`menu_bar_model`], which
//! projects the single source of truth — the compiled `menubar` (menubar.yaml)
//! — into a render model. This replaced a hand-maintained static `MENU_BAR`
//! const that had drifted from the spec: it had lost the entire View menu and
//! carried stale File/Edit/Object items. Projecting from the bundle means the
//! Rust menu bar can no longer diverge from menubar.yaml.
//!
//! The dynamic Workspace / Appearance submenus stay runtime-populated by
//! bespoke code in `menu_bar.rs`; the model only carries their trigger label
//! and identity.

/// Which runtime-populated submenu a [`MenuEntry::DynamicSubmenu`] drives.
#[derive(PartialEq, Eq, Debug, Clone, Copy)]
pub enum SubmenuKind {
    Workspace,
    Appearance,
}

/// One resolved menu entry.
pub enum MenuEntry {
    Separator,
    DynamicSubmenu {
        label: String,
        kind: SubmenuKind,
    },
    Action {
        label: String,
        action: String,
        params: serde_json::Map<String, serde_json::Value>,
        shortcut: String,
        enabled_when: Option<String>,
        checked_when: Option<String>,
    },
}

/// One top-level menu (e.g. "&File") and its entries.
pub struct MenuModel {
    pub label: String,
    pub entries: Vec<MenuEntry>,
}

/// Project the compiled `menubar` (menubar.yaml) into the render model.
/// Returns an empty Vec if the bundle is missing/corrupt (never panics).
pub fn menu_bar_model() -> Vec<MenuModel> {
    let ws = match crate::interpreter::workspace::Workspace::load() {
        Some(w) => w,
        None => return Vec::new(),
    };
    match ws.data().get("menubar").and_then(|m| m.as_array()) {
        Some(menus) => menus.iter().map(project_menu).collect(),
        None => Vec::new(),
    }
}

fn project_menu(menu: &serde_json::Value) -> MenuModel {
    let label = menu
        .get("label")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let entries = menu
        .get("items")
        .and_then(|v| v.as_array())
        .map(|items| items.iter().map(project_entry).collect())
        .unwrap_or_default();
    MenuModel { label, entries }
}

fn project_entry(item: &serde_json::Value) -> MenuEntry {
    // A bare "separator" string.
    if item.as_str() == Some("separator") {
        return MenuEntry::Separator;
    }
    // A submenu carries nested "items"; the only ones today are the dynamic
    // Workspace / Appearance submenus, rendered natively (runtime-populated).
    if item.get("items").is_some() {
        let label = item
            .get("label")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let id = item.get("id").and_then(|v| v.as_str()).unwrap_or("");
        let kind = if id.contains("appearance") || label.contains("Appearance") {
            SubmenuKind::Appearance
        } else {
            SubmenuKind::Workspace
        };
        return MenuEntry::DynamicSubmenu { label, kind };
    }
    let params = item
        .get("params")
        .and_then(|v| v.as_object())
        .cloned()
        .unwrap_or_default();
    MenuEntry::Action {
        label: item
            .get("label")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        action: item
            .get("action")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        params,
        shortcut: item
            .get("shortcut")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        enabled_when: item
            .get("enabled_when")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()),
        checked_when: item
            .get("checked_when")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn action_names(menu: &MenuModel) -> Vec<&str> {
        menu.entries
            .iter()
            .filter_map(|e| match e {
                MenuEntry::Action { action, .. } => Some(action.as_str()),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn model_has_five_menus_including_view() {
        let model = menu_bar_model();
        let labels: Vec<&str> = model.iter().map(|m| m.label.as_str()).collect();
        assert_eq!(labels, vec!["&File", "&Edit", "&Object", "&View", "&Window"]);
    }

    #[test]
    fn model_file_menu_has_print_and_export() {
        let model = menu_bar_model();
        let actions = action_names(&model[0]);
        assert!(actions.contains(&"open_print_dialog"), "File missing Print: {actions:?}");
        assert!(actions.contains(&"export_to_pdf"), "File missing Export: {actions:?}");
    }

    #[test]
    fn model_view_menu_has_zoom_and_fit() {
        let model = menu_bar_model();
        let view = model.iter().find(|m| m.label == "&View").expect("View menu present");
        let actions = action_names(view);
        assert!(actions.contains(&"zoom_in"), "View missing zoom_in: {actions:?}");
        assert!(actions.contains(&"fit_active_artboard"), "View missing fit: {actions:?}");
    }

    #[test]
    fn model_window_menu_has_dynamic_submenus() {
        let model = menu_bar_model();
        let window = model.iter().find(|m| m.label == "&Window").expect("Window menu present");
        let kinds: Vec<SubmenuKind> = window
            .entries
            .iter()
            .filter_map(|e| match e {
                MenuEntry::DynamicSubmenu { kind, .. } => Some(*kind),
                _ => None,
            })
            .collect();
        assert!(kinds.contains(&SubmenuKind::Workspace), "missing Workspace submenu");
        assert!(kinds.contains(&SubmenuKind::Appearance), "missing Appearance submenu");
    }

    #[test]
    fn model_toggle_panel_carries_panel_param() {
        let model = menu_bar_model();
        let window = model.iter().find(|m| m.label == "&Window").unwrap();
        let has_color = window.entries.iter().any(|e| matches!(
            e,
            MenuEntry::Action { action, params, .. }
                if action == "toggle_panel"
                && params.get("panel").and_then(|v| v.as_str()) == Some("color")
        ));
        assert!(has_color, "Window missing toggle_panel(color)");
    }

    #[test]
    fn model_separators_present() {
        let model = menu_bar_model();
        let file_seps = model[0]
            .entries
            .iter()
            .filter(|e| matches!(e, MenuEntry::Separator))
            .count();
        assert!(file_seps >= 1, "File menu should have separators");
    }
}
