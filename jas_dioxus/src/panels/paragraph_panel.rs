//! Paragraph panel menu definition.
//!
//! Mirrors the menu items declared in `workspace/panels/paragraph.yaml`.
//! Hanging Punctuation is a panel-state toggle handled here directly;
//! Justification… / Hyphenation… are dialog openers handled by
//! `panel_menu_view.rs` (which has access to the dialog signal).
//! Reset Panel routes through `apply_paragraph_panel_to_selection`.

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

pub fn menu_items() -> Vec<PanelMenuItem> {
    vec![
        PanelMenuItem::Toggle {
            label: "Hanging Punctuation",
            command: "toggle_hanging_punctuation",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Justification\u{2026}",
            command: "open_paragraph_justification",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Hyphenation\u{2026}",
            command: "open_paragraph_hyphenation",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Reset Panel",
            command: "reset_paragraph_panel",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Close Paragraph",
            command: "close_panel",
            shortcut: "",
        },
    ]
}

pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    match cmd {
        "close_panel" => state.workspace_layout.close_panel(addr),
        "toggle_hanging_punctuation" => {
            state.paragraph_panel.hanging_punctuation =
                !state.paragraph_panel.hanging_punctuation;
            state.apply_paragraph_panel_to_selection();
        }
        "reset_paragraph_panel" => {
            state.reset_paragraph_panel();
        }
        // Justification / Hyphenation dialog openers need Signal
        // access; panel_menu_view.rs intercepts them before this
        // dispatch runs.
        "open_paragraph_justification" | "open_paragraph_hyphenation" => {}
        _ => {}
    }
}

pub fn is_checked(cmd: &str, state: &AppState) -> bool {
    match cmd {
        "toggle_hanging_punctuation" => state.paragraph_panel.hanging_punctuation,
        _ => false,
    }
}
