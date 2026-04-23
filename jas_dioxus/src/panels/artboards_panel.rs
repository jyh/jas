//! Artboards panel menu definition (ARTBOARDS.md).
//!
//! The panel body (row list + footer) is rendered by the generic
//! YAML interpreter from `workspace/panels/artboards.yaml`; this
//! module provides the hamburger menu wiring so the panel
//! integrates with the Window menu and panel-menu chrome.
//!
//! Each menu entry fires a YAML action (see workspace/actions.yaml).
//! Actual mutations happen via `interpreter::renderer::run_yaml_effect`
//! — not via this module's `dispatch` function. The dispatch here
//! only handles container-level affordances (close_panel); every
//! artboard action flows through the YAML action pipeline.

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

/// Menu items for the Artboards panel.
///
/// Order and labels match `workspace/panels/artboards.yaml §menu`
/// and `transcripts/ARTBOARDS.md §Menu`.
pub fn menu_items() -> Vec<PanelMenuItem> {
    vec![
        PanelMenuItem::Action {
            label: "New Artboard",
            command: "new_artboard",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Duplicate Artboards",
            command: "duplicate_artboards",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Delete Artboards",
            command: "delete_artboards",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Rename",
            command: "rename_artboard",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Delete Empty Artboards",
            command: "delete_empty_artboards",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        // Phase-1 deferred per ARTBOARDS.md §Phase-1 deferrals —
        // the YAML action catalog grays these with enabled_when: false.
        PanelMenuItem::Action {
            label: "Convert to Artboards",
            command: "convert_to_artboards",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Artboard Options...",
            command: "open_artboard_options",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Rearrange...",
            command: "rearrange_artboards",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Reset Panel",
            command: "reset_artboards_panel",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Close Artboards",
            command: "close_panel",
            shortcut: "",
        },
    ]
}

/// Dispatch a menu command for the Artboards panel.
///
/// All artboard mutations route through the YAML action pipeline
/// (dispatched by `interpreter::renderer::dispatch_action`). This
/// function only handles the panel-container affordance
/// `close_panel` — every other command is a no-op here, and the
/// menu UI relies on the YAML pipeline to execute it.
pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    match cmd {
        "close_panel" => state.workspace_layout.close_panel(addr),
        _ => {}
    }
}

/// Query whether a toggle/radio command is checked.
///
/// The Artboards panel has no stateful toggles in the menu; every
/// entry is either an action or a deferred placeholder.
pub fn is_checked(_cmd: &str, _state: &AppState) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn menu_has_all_spec_entries() {
        let labels: Vec<&str> = menu_items()
            .iter()
            .filter_map(|item| match item {
                PanelMenuItem::Action { label, .. } => Some(*label),
                _ => None,
            })
            .collect();
        assert!(labels.contains(&"New Artboard"));
        assert!(labels.contains(&"Duplicate Artboards"));
        assert!(labels.contains(&"Delete Artboards"));
        assert!(labels.contains(&"Rename"));
        assert!(labels.contains(&"Delete Empty Artboards"));
        assert!(labels.contains(&"Convert to Artboards"));
        assert!(labels.contains(&"Artboard Options..."));
        assert!(labels.contains(&"Rearrange..."));
        assert!(labels.contains(&"Reset Panel"));
        assert!(labels.contains(&"Close Artboards"));
    }

    #[test]
    fn menu_commands_match_yaml_actions() {
        // Each command label in this Rust menu should correspond to an
        // action in workspace/actions.yaml (wired by Phase B). The
        // check here is purely lexical; the YAML dispatch pipeline
        // does the actual routing at runtime.
        let commands: Vec<&str> = menu_items()
            .iter()
            .filter_map(|item| match item {
                PanelMenuItem::Action { command, .. } => Some(*command),
                _ => None,
            })
            .collect();
        let expected = [
            "new_artboard",
            "duplicate_artboards",
            "delete_artboards",
            "rename_artboard",
            "delete_empty_artboards",
            "convert_to_artboards",
            "open_artboard_options",
            "rearrange_artboards",
            "reset_artboards_panel",
            "close_panel",
        ];
        for cmd in &expected {
            assert!(
                commands.contains(cmd),
                "menu should include command {cmd}"
            );
        }
    }

    #[test]
    fn is_checked_always_false() {
        // No stateful toggles in the Artboards menu.
        let st = AppState::new();
        for cmd in &[
            "new_artboard",
            "rename_artboard",
            "reset_artboards_panel",
            "close_panel",
        ] {
            assert!(!is_checked(cmd, &st));
        }
    }

    #[test]
    fn menu_has_three_separators() {
        let seps = menu_items()
            .iter()
            .filter(|item| matches!(item, PanelMenuItem::Separator))
            .count();
        // Between: Rename|Delete Empty, Delete Empty|Convert,
        // Rearrange|Reset, Reset|Close.
        assert_eq!(seps, 4);
    }
}
