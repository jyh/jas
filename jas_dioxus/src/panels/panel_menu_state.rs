//! Panel menu state types for Dioxus context.
//!
//! Provides [`PanelMenuState`] and [`MenuBarState`] for reactive menu
//! open/close signalling.

use dioxus::prelude::*;

use crate::workspace::workspace::{PanelAddr, PanelKind};

/// Tracks which panel's hamburger menu is currently open.
#[derive(Clone, Copy)]
pub struct PanelMenuState {
    pub open: Signal<Option<PanelMenuOpen>>,
}

/// Data for an open panel menu: what panel, where to render.
#[derive(Debug, Clone, Copy)]
pub struct PanelMenuOpen {
    pub kind: PanelKind,
    pub addr: PanelAddr,
    /// Screen X of the hamburger button click.
    pub x: f64,
    /// Screen Y of the hamburger button click.
    pub y: f64,
}

/// Wraps the menu bar's open-menu signal so it can be accessed as a context.
#[derive(Clone, Copy)]
pub struct MenuBarState {
    pub open_menu: Signal<Option<String>>,
}
