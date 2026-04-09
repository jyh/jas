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
    ]),
    ("Window", &[
        ("Layers", "toggle_panel_layers", ""),
        ("Color", "toggle_panel_color", ""),
        ("Stroke", "toggle_panel_stroke", ""),
        ("Properties", "toggle_panel_properties", ""),
        SEP,
        ("Reset Panel Layout", "reset_panel_layout", ""),
    ]),
];

/// All known dispatch command strings.
pub const DISPATCH_COMMANDS: &[&str] = &[
    "new", "open", "save", "close",
    "undo", "redo",
    "cut", "copy", "paste", "paste_in_place",
    "select_all", "delete",
    "group", "ungroup", "ungroup_all",
    "lock", "unlock_all",
    "hide", "show_all",
    "toggle_panel_layers", "toggle_panel_color",
    "toggle_panel_stroke", "toggle_panel_properties",
    "reset_panel_layout",
];

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
        assert_eq!(total, 30); // 5 + 10 + 9 + 6
    }

    #[test]
    fn object_menu_has_hide_and_show_all() {
        let (_, items) = &MENU_BAR[2];
        let labels: Vec<&str> = items.iter().map(|(l, _, _)| *l).collect();
        assert!(labels.contains(&"Hide"));
        assert!(labels.contains(&"Show All"));
    }
}
