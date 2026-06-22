//! Menu bar data: structure, items, and commands.
//!
// DISPATCH_COMMANDS is used by tests to verify menu ↔ command coverage
// but isn't currently called from the Dioxus UI dispatch path.
#![allow(dead_code)]
//!
//! Defines the menu layout as static data so it can be tested independently
//! of the Dioxus UI.

/// A menu item: (label, command, shortcut_hint).
/// Label "---" denotes a separator.
pub type MenuItem = (&'static str, &'static str, &'static str);

/// Separator item.
pub const SEP: MenuItem = ("---", "", "");

/// Complete menu bar definition: &[(menu_title, &[items])].
pub const MENU_BAR: &[(&str, &[MenuItem])] = &[
    ("File", &[
        ("New", "new", "\u{2318}N"),
        ("Open...", "open", "\u{2318}O"),
        ("Save", "save", "\u{2318}S"),
        SEP,
        ("Document Setup...", "document_setup", ""),
        ("Print...", "print", "\u{2318}P"),
        ("Export to PDF...", "export_to_pdf", ""),
        SEP,
        ("Close Tab", "close", "\u{2318}W"),
    ]),
    ("Edit", &[
        ("Undo", "undo", "\u{2318}Z"),
        ("Redo", "redo", "\u{21e7}\u{2318}Z"),
        SEP,
        ("Cut", "cut", "\u{2318}X"),
        ("Copy", "copy", "\u{2318}C"),
        ("Paste", "paste", "\u{2318}V"),
        ("Paste in Place", "paste_in_place", "\u{21e7}\u{2318}V"),
        SEP,
        ("Delete", "delete", "\u{232b}"),
        ("Select All", "select_all", "\u{2318}A"),
    ]),
    ("Object", &[
        ("Group", "group", "\u{2318}G"),
        ("Ungroup", "ungroup", "\u{21e7}\u{2318}G"),
        ("Ungroup All", "ungroup_all", ""),
        SEP,
        ("Lock", "lock", "\u{2318}2"),
        ("Unlock All", "unlock_all", "\u{2325}\u{2318}2"),
        SEP,
        ("Hide", "hide", "\u{2318}3"),
        ("Show All", "show_all", "\u{2325}\u{2318}3"),
        SEP,
        ("Make Instance", "make_instance", ""),
        ("Simplify", "simplify", ""),
    ]),
    ("Window", &[
        ("Workspace \u{25B6}", "workspace_submenu", ""),
        ("Appearance \u{25B6}", "appearance_submenu", ""),
        SEP,
        ("Tile", "tile_panes", ""),
        SEP,
        ("Toolbar", "toggle_pane_toolbar", ""),
        ("Panels", "toggle_pane_dock", ""),
        SEP,
        // Panels in alphabetical order.
        ("Align", "toggle_panel_align", ""),
        ("Artboards", "toggle_panel_artboards", ""),
        ("Boolean", "toggle_panel_boolean", ""),
        ("Character", "toggle_panel_character", ""),
        ("Color", "toggle_panel_color", ""),
        ("Layers", "toggle_panel_layers", ""),
        ("Magic Wand", "toggle_panel_magic_wand", ""),
        ("Opacity", "toggle_panel_opacity", ""),
        ("Paragraph", "toggle_panel_paragraph", ""),
        ("Properties", "toggle_panel_properties", ""),
        ("Stroke", "toggle_panel_stroke", ""),
        ("Swatches", "toggle_panel_swatches", ""),
        ("Symbols", "toggle_panel_symbols", ""),
    ]),
];

/// All known dispatch command strings.
pub const DISPATCH_COMMANDS: &[&str] = &[
    "new", "open", "save", "close",
    "document_setup", "print", "export_to_pdf",
    "undo", "redo",
    "cut", "copy", "paste", "paste_in_place",
    "select_all", "delete",
    "group", "ungroup", "ungroup_all",
    "lock", "unlock_all",
    "hide", "show_all",
    "make_instance",
    "simplify",
    "workspace_submenu",
    "appearance_submenu",
    "tile_panes",
    "toggle_pane_toolbar", "toggle_pane_dock",
    "toggle_panel_align", "toggle_panel_artboards",
    "toggle_panel_boolean", "toggle_panel_character",
    "toggle_panel_color", "toggle_panel_layers",
    "toggle_panel_magic_wand", "toggle_panel_opacity",
    "toggle_panel_paragraph", "toggle_panel_properties",
    "toggle_panel_stroke", "toggle_panel_swatches",
    "toggle_panel_symbols",
];

// ---------------------------------------------------------------------------
// Bundle-derived menu model
// ---------------------------------------------------------------------------
// The static MENU_BAR above had drifted from menubar.yaml (it lost the View
// menu and carried stale File/Edit/Object items). `menu_bar_model()` projects
// the single source of truth — the compiled `menubar` (menubar.yaml) — so the
// Rust menu bar can no longer diverge from the spec. The dynamic Workspace /
// Appearance submenus stay runtime-populated by bespoke code in menu_bar.rs;
// the model only carries their trigger + identity.

/// Which runtime-populated submenu a `DynamicSubmenu` entry drives.
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
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn menu_bar_has_four_menus() {
        assert_eq!(MENU_BAR.len(), 4);
    }

    #[test]
    fn menu_titles() {
        let titles: Vec<&str> = MENU_BAR.iter().map(|(t, _)| *t).collect();
        assert_eq!(titles, vec!["File", "Edit", "Object", "Window"]);
    }

    #[test]
    fn file_menu_exists() {
        let (title, items) = &MENU_BAR[0];
        assert_eq!(*title, "File");
        assert!(!items.is_empty());
    }

    #[test]
    fn edit_menu_exists() {
        let (title, items) = &MENU_BAR[1];
        assert_eq!(*title, "Edit");
        assert!(!items.is_empty());
    }

    #[test]
    fn object_menu_exists() {
        let (title, items) = &MENU_BAR[2];
        assert_eq!(*title, "Object");
        assert!(!items.is_empty());
    }

    #[test]
    fn file_menu_items() {
        let (_, items) = &MENU_BAR[0];
        let labels: Vec<&str> = items.iter().map(|(l, _, _)| *l).collect();
        assert!(labels.contains(&"New"));
        assert!(labels.contains(&"Open..."));
        assert!(labels.contains(&"Save"));
        assert!(labels.contains(&"Close Tab"));
    }

    #[test]
    fn edit_menu_items() {
        let (_, items) = &MENU_BAR[1];
        let labels: Vec<&str> = items.iter().map(|(l, _, _)| *l).collect();
        assert!(labels.contains(&"Undo"));
        assert!(labels.contains(&"Redo"));
        assert!(labels.contains(&"Cut"));
        assert!(labels.contains(&"Copy"));
        assert!(labels.contains(&"Paste"));
        assert!(labels.contains(&"Paste in Place"));
        assert!(labels.contains(&"Delete"));
        assert!(labels.contains(&"Select All"));
    }

    #[test]
    fn object_menu_items() {
        let (_, items) = &MENU_BAR[2];
        let labels: Vec<&str> = items.iter().map(|(l, _, _)| *l).collect();
        assert!(labels.contains(&"Group"));
        assert!(labels.contains(&"Ungroup"));
        assert!(labels.contains(&"Ungroup All"));
        assert!(labels.contains(&"Lock"));
        assert!(labels.contains(&"Unlock All"));
    }

    #[test]
    fn separators_use_dashes() {
        for (_, items) in MENU_BAR {
            for &(label, cmd, shortcut) in *items {
                if label == "---" {
                    assert_eq!(cmd, "");
                    assert_eq!(shortcut, "");
                }
            }
        }
    }

    #[test]
    fn all_non_separator_items_have_commands() {
        for (_, items) in MENU_BAR {
            for &(label, cmd, _) in *items {
                if label != "---" {
                    assert!(!cmd.is_empty(), "Menu item '{}' has no command", label);
                }
            }
        }
    }

    #[test]
    fn all_commands_are_known() {
        let known: HashSet<&str> = DISPATCH_COMMANDS.iter().copied().collect();
        for (_, items) in MENU_BAR {
            for &(label, cmd, _) in *items {
                if label != "---" {
                    assert!(known.contains(cmd),
                        "Menu item '{}' has unknown command '{}'", label, cmd);
                }
            }
        }
    }

    #[test]
    fn no_duplicate_commands_within_menu() {
        for (title, items) in MENU_BAR {
            let cmds: Vec<&str> = items.iter()
                .filter(|(l, _, _)| *l != "---")
                .map(|(_, c, _)| *c)
                .collect();
            let unique: HashSet<&str> = cmds.iter().copied().collect();
            assert_eq!(cmds.len(), unique.len(),
                "Duplicate commands in menu '{}'", title);
        }
    }

    #[test]
    fn all_non_separator_items_have_labels() {
        for (_, items) in MENU_BAR {
            for &(label, _, _) in *items {
                if label != "---" {
                    assert!(!label.is_empty());
                }
            }
        }
    }

    #[test]
    fn file_menu_has_separator() {
        let (_, items) = &MENU_BAR[0];
        assert!(items.iter().any(|(l, _, _)| *l == "---"));
    }

    #[test]
    fn edit_menu_has_separators() {
        let (_, items) = &MENU_BAR[1];
        let sep_count = items.iter().filter(|(l, _, _)| *l == "---").count();
        assert_eq!(sep_count, 2);
    }

    #[test]
    fn total_menu_item_count() {
        let total: usize = MENU_BAR.iter().map(|(_, items)| items.len()).sum();
        // 9 (File: +Document Setup +Print +Export to PDF +separator)
        // + 10 (Edit) + 12 (Object: + separator + Make Instance + Simplify)
        // + 21 (Window: alphabetised panels incl. Align / Boolean /
        // Magic Wand / Opacity / Symbols) = 52
        assert_eq!(total, 52);
    }

    #[test]
    fn file_menu_has_print_pipeline_entries() {
        let (_, items) = &MENU_BAR[0];
        let labels: Vec<&str> = items.iter().map(|(l, _, _)| *l).collect();
        assert!(labels.contains(&"Document Setup..."));
        assert!(labels.contains(&"Print..."));
        assert!(labels.contains(&"Export to PDF..."));
    }

    #[test]
    fn object_menu_has_hide_and_show_all() {
        let (_, items) = &MENU_BAR[2];
        let labels: Vec<&str> = items.iter().map(|(l, _, _)| *l).collect();
        assert!(labels.contains(&"Hide"));
        assert!(labels.contains(&"Show All"));
    }

    // ----- Bundle-derived model (the source of truth the UI renders from) -----

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
