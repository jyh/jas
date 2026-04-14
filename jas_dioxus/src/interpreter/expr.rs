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
    if source.is_empty() {
        return Value::Null;
    }
    match expr_parser::parse(source) {
        Some(ast) => expr_eval::eval_node(&ast, ctx),
        None => Value::Null,
    }
}

/// Evaluate a text string with embedded {{expr}} regions.
///
/// Returns the string with each {{expr}} replaced by its evaluated
/// value coerced to a string. Text outside {{}} is literal.
pub fn eval_text(text: &str, ctx: &serde_json::Value) -> String {
    if !text.contains("{{") {
        return text.to_string();
    }
    let mut result = String::new();
    let mut rest = text;
    while let Some(start) = rest.find("{{") {
        result.push_str(&rest[..start]);
        let after_open = &rest[start + 2..];
        if let Some(end) = after_open.find("}}") {
            let expr_str = after_open[..end].trim();
            let val = eval(expr_str, ctx);
            result.push_str(&val.to_string_coerce());
            rest = &after_open[end + 2..];
        } else {
            result.push_str(&rest[start..]);
            return result;
        }
    }
    result.push_str(rest);
    result
}
