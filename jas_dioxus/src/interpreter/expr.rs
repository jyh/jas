//! Top-level expression evaluation entry point.
//!
//! Re-exports the parser and evaluator for convenient use.

use super::expr_eval;
use super::expr_parser;
use super::expr_types::Value;

/// Evaluate an expression string against a JSON context.
///
/// Returns `Value::Null` for empty or unparseable input.
pub fn eval(source: &str, ctx: &serde_json::Value) -> Value {
    match expr_parser::parse(source) {
        Some(ast) => expr_eval::eval_node(&ast, ctx),
        None => Value::Null,
    }
}
