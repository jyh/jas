//! YAML workspace interpreter: expression evaluator, state store, effects.
//!
//! Loads the compiled workspace JSON and evaluates expressions from the
//! expression language defined in SCHEMA.md. This is a Rust port of
//! the Python `workspace_interpreter` package.

pub mod color_util;
pub mod expr_types;
pub mod expr_lexer;
pub mod expr_parser;
pub mod expr_eval;
pub mod expr;
pub mod state_store;
pub mod preferences;
pub mod effects;
pub mod doc_primitives;
pub mod hit_law;
pub mod point_buffers;
pub mod anchor_buffers;
pub mod schema;
pub mod scope;
pub mod length;
pub mod document_views;
pub mod foreach;
pub mod symbols_host;
pub mod layer_doc_effects;
pub mod workspace;
pub mod panel_layout;
pub mod panel_seed;
pub mod widget_tree;
pub mod bind_values;
pub mod widget_commit;
pub mod artboard_effects;
pub mod boolean_host;
pub mod align_host;
pub mod stroke_host;
pub mod colour_host;
pub mod gradient_host;
pub mod character_host;
pub mod properties_host;
pub mod paragraph_host;
pub mod mask_facts;
pub mod menu_state;

// The toolbar double-click's options resolver: the web's renderer and the
// engine's panel door both read it. NOT gated.
pub mod tool_options;

// A tile's selection outline (`bind.selected_in`): the web's renderer and the
// engine's panel plan both read it. NOT gated.
pub mod tile_selection;

// A user's saved libraries over the bundle's (row 149): the engine's door and
// the corpus runner read it. NOT gated.
pub mod user_libraries;

// A panel row's `context_menu:` as a shell draws it: the web's renderer and
// the engine's FFI read it (row 257). NOT gated.
pub mod row_menu;

#[cfg(feature = "web")]
pub mod renderer;
#[cfg(feature = "web")]
pub mod dialog_view;
// A dialog's state and its open law. NOT gated: the corpus runner's FFI lane
// and the engine need it without a window (`dialog_view` holds it in a signal).
pub mod dialog_state;
#[cfg(feature = "web")]
pub mod timer;

#[cfg(test)]
mod tests;
