// Most lib-only Dioxus host code: callbacks, view helpers, and
// scaffolding wired indirectly through Dioxus signals don't trip the
// reachability analyzer.
#[allow(dead_code)]
pub mod app;
pub(crate) mod app_state;
pub(crate) mod clipboard;
pub mod color_panel_view;
// color_picker.rs and color_picker_dialog.rs removed — uses YAML dialog system
pub(crate) mod dock_panel;
pub mod fill_stroke_widget;
pub mod icons;
pub(crate) mod keyboard;
pub mod menu;
pub mod menu_bar;
// Pane layout API surface includes accessors used externally and a
// few helpers reserved for the cross-app propagation
// (project_pane_propagation memory).
#[allow(dead_code)]
pub mod pane;
// save_dialog.rs removed — workspace save-as uses YAML dialog system
pub(crate) mod session;
pub mod toolbar_grid;
// Cross-language fixture serialization; consumed only by tests and
// the workspace_roundtrip binary, not the main lib.
#[allow(dead_code)]
pub mod test_json;
pub mod theme;
// Workspace layout types expose a wide JSON-shape API; many fields
// are used only by tests and external tooling.
#[allow(dead_code)]
pub mod workspace;
