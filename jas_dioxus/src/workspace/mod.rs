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
#[allow(dead_code)]
pub mod pane;
// save_dialog.rs removed — workspace save-as uses YAML dialog system
pub(crate) mod session;
pub mod toolbar_grid;
#[allow(dead_code)]
pub mod test_json;
pub mod theme;
#[allow(dead_code)]
pub mod workspace;
