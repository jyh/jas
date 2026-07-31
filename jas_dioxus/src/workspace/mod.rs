//! # The `web` gate lives HERE, not on the module as a whole
//!
//! Until 2026-07-30 `lib.rs` read `#[cfg(feature = "web")] pub mod workspace;`,
//! which put the ENTIRE workspace layer — layout types, the layout-op
//! dispatcher, pane geometry, key-chord resolution, the menu structure, the
//! theme, and the cross-language fixture serializer — out of reach of a
//! `--no-default-features` build. **Nine of these seventeen submodules import
//! nothing from Dioxus, `web_sys`, or the app shell.** They are pure data and
//! pure functions, and they were unbuildable and untestable on a native target
//! for no reason other than the address they live at.
//!
//! Measured: moving the gate inward took the native lib test target from
//! **1839 tests to 2024** — 185 tests that could always have run natively and
//! never did.
//!
//! That matters beyond tidiness. `resolve_key` and `layout_apply` are pinned
//! CROSS-LANGUAGE by the key and workspace-operation corpora, and D1 put a
//! sixth port on this same Rust core. A shared law whose tests only run in one
//! build is a law with one witness, and this repo has already paid for that
//! shape once: the text-width law lived in web-gated `tools` while being the
//! only definition, so the native arm reimplemented it wrongly twice over and
//! nothing could see the divergence (CHARWIDTH, `text_measure.rs`). Same
//! disease, larger organ.
//!
//! **The rule for this file:** a submodule is gated only if it genuinely needs
//! the frontend — Dioxus components, `web_sys`, or `AppState`/`TabState`. Each
//! gate below says which. If you add a submodule, do not gate it by reflex;
//! gate it because the compiler says you must.

// Dioxus component tree for the whole app.
#[cfg(feature = "web")]
// Most lib-only Dioxus host code: callbacks, view helpers, and
// scaffolding wired indirectly through Dioxus signals don't trip the
// reachability analyzer.
#[allow(dead_code)]
pub mod app;
// The app shell: AppState/TabState and the live signal graph.
#[cfg(feature = "web")]
pub(crate) mod app_state;
// Reads and writes the browser clipboard through web_sys.
#[cfg(feature = "web")]
pub(crate) mod clipboard;
#[cfg(feature = "web")]
pub mod color_panel_view;
// color_picker.rs and color_picker_dialog.rs removed — uses YAML dialog system
#[cfg(feature = "web")]
pub(crate) mod dock_panel;
#[cfg(feature = "web")]
pub mod fill_stroke_widget;
// Keyboard event plumbing bound to web_sys KeyboardEvent.
#[cfg(feature = "web")]
pub(crate) mod keyboard;
// The single runtime LAYOUT-op dispatcher (OP_LOG.md §12, Fork 5, Increment
// 3d-2): production layout mutations and the cross-language harness share this
// one per-verb body. Promoted from the web-gated harness `apply_workspace_op`.
// NOT gated: it is the shared body a cross-language corpus pins.
pub mod layout_apply;
// NOT gated: the menu STRUCTURE is data; only its rendering is a view.
pub mod menu;
#[cfg(feature = "web")]
pub mod menu_bar;
// Pane layout API surface includes accessors used externally and a
// few helpers reserved for the cross-app propagation
// (project_pane_propagation memory).
// NOT gated: pane geometry is arithmetic.
#[allow(dead_code)]
pub mod pane;
// Pure key-chord → action resolution (TESTING_STRATEGY.md §5 rec 3),
// pinned cross-language by the key corpus. NOT gated — a corpus-pinned law
// must be measurable in every build that carries it.
pub mod resolve_key;
// save_dialog.rs removed — workspace save-as uses YAML dialog system
// Gated: `save_session` takes `&[TabState]`, i.e. the app shell.
#[cfg(feature = "web")]
pub(crate) mod session;
// Cross-language fixture serialization; consumed only by tests and
// the workspace_roundtrip binary, not the main lib. NOT gated: it is the
// serializer the conformance corpus compares through.
#[allow(dead_code)]
pub mod test_json;
// Gated, and this one was decided rather than assumed: `theme` carries no tests
// at all, and every one of its eight consumers is itself a web-gated view
// (app, app_state, dock_panel, menu_bar, color_panel_view, fill_stroke_widget,
// dialog_view, panel_menu_view). It emits CSS strings and baked SVG. Leaving it
// native bought 24 dead-code warnings and not one measurable line.
#[cfg(feature = "web")]
pub mod theme;
// Workspace layout types expose a wide JSON-shape API; many fields
// are used only by tests and external tooling. NOT gated: WorkspaceLayout and
// its pane tree are data.
#[allow(dead_code)]
pub mod workspace;
