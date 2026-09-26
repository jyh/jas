//! Brushes panel menu definition (BRUSHES.md).
//!
//! The panel body (library disclosure headers + brush tiles + footer
//! toolbar) is rendered by the generic YAML interpreter from
//! `workspace/panels/brushes.yaml`; this module provides the hamburger
//! menu wiring so the panel integrates with the Window menu and panel-menu
//! chrome.
//!
//! Brushes is a TOGGLE-ONLY panel: it is not part of the default layout.
//! `Window > Brushes` summons it on demand (see the `toggle_panel_brushes`
//! arm in `menu_bar.rs`, gated on group membership so the first click adds
//! the panel via `WorkspaceLayout::show_panel`).
//!
//! Each menu entry fires a YAML action (see workspace/actions.yaml); the
//! dispatch here routes the command string through the shared
//! `dispatch_action` pipeline (the same path the panel-body buttons use)
//! and handles `close_panel` locally.
//!
//! The menu's CHECK MARKS are NOT here. They are brushes.yaml's own
//! `checked_when:` predicates, evaluated by `panels::panel_is_checked`
//! through the shared menu-state evaluator. This module used to carry an
//! `is_checked` returning `false` whose comment said that was already true;
//! it was not, and all eleven check marks were dead as a result.

use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use super::panel_menu::PanelMenuItem;

/// Menu items for the Brushes panel.
///
/// Source of truth is workspace/panels/brushes.yaml's `menu:` block; the
/// generic reader builds the items from the compiled bundle.
pub fn menu_items() -> Vec<PanelMenuItem> {
    super::panel_menu::menu_items_from_yaml("brushes_panel_content")
}

/// Dispatch a menu command for the Brushes panel.
///
/// `close_panel` is handled here. Every other command is a brush action
/// defined in actions.yaml and is routed through the shared
/// `dispatch_action` pipeline so the hamburger menu fires the same effect
/// chain as the panel-body wiring.
///
/// A radio row's command arrives FOLDED from the generic builder
/// (`set_brush_view_mode:list`), because several rows share one YAML action.
/// `panel_menu::action_and_params` unfolds it back into the action and the
/// entry's declared `params`, so `param.view_mode` resolves. Passing the folded
/// string through with an empty params map — which is what this did — named no
/// action at all, so every Brushes menu row was a silent no-op.
pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    // The action evaluates with this panel's scope (selected_library,
    // selected_brushes), which the app scope alone does not carry.
    super::panel_menu::dispatch_yaml_menu("brushes_panel_content", cmd, addr, state);
}
