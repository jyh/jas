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

#[cfg(test)]
mod tests;
