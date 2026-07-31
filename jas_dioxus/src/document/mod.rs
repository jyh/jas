pub mod artboard;
pub mod controller;
pub mod dependency_index;
pub mod document;
pub mod document_setup;
pub mod evaluated_bounds;
pub mod id_index;
pub mod model;
pub mod op_apply;
pub mod op_log;
pub mod print_preferences;

// Container-seeded equivalence for the panel-ctx layer. See the module
// header: this is the layer panel_bind_values structurally cannot reach.
// `#[cfg(test)]`: the module is nothing but a seeder and its relation, so in a
// lib build its `wrap_at` is dead code and said so in two warnings.
#[cfg(test)]
pub mod selection_summary_seed_tests;
