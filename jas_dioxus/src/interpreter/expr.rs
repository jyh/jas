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

/// Evaluate an expression body that may contain `target <- value_expr`.
///
/// Parses `<-` assignments pragmatically (string split, not full AST).
/// Returns a list of (target_name, evaluated_value) pairs.
/// Handles sequenced assignments: `a <- e1; b <- e2`.
pub fn eval_with_store(source: &str, ctx: &serde_json::Value) -> Vec<(String, Value)> {
    let mut assignments: Vec<(String, Value)> = Vec::new();
    // Split on ';' for sequencing
    for part in source.split(';') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        // Check for <- assignment
        // Find "<-" that's not inside a string
        if let Some(arrow_pos) = part.find("<-") {
            let target = part[..arrow_pos].trim();
            let value_expr = part[arrow_pos + 2..].trim();
            // Evaluate the value expression
            // Build updated context with previous assignments applied
            let mut updated_ctx = ctx.as_object().cloned().unwrap_or_default();
            for (k, v) in &assignments {
                updated_ctx.insert(k.clone(), super::effects::value_to_json(v));
            }
            let val = eval(value_expr, &serde_json::Value::Object(updated_ctx));
            assignments.push((target.to_string(), val));
        } else {
            // Not an assignment — evaluate for side effects (ignored)
            eval(part, ctx);
        }
    }
    assignments
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_swatch_path_resolution() {
        let ctx = serde_json::json!({
            "swatch": {
                "name": "Red",
                "color": "#ff0000",
                "color_mode": "rgb"
            },
            "lib": {
                "id": "default"
            }
        });
        assert_eq!(eval("swatch.name", &ctx), Value::Str("Red".into()));
        assert_eq!(eval("swatch.color", &ctx), Value::Color("#ff0000".into()));
        assert_eq!(eval("swatch.color_mode", &ctx), Value::Str("rgb".into()));
        assert_eq!(eval("lib.id", &ctx), Value::Str("default".into()));
    }

    #[test]
    fn test_param_resolution() {
        let ctx = serde_json::json!({
            "param": {
                "mode": "edit",
                "swatch_name": "Red",
                "color": "#ff0000",
                "color_mode": "rgb"
            }
        });
        assert_eq!(eval("param.mode", &ctx), Value::Str("edit".into()));
        assert_eq!(eval("param.swatch_name", &ctx), Value::Str("Red".into()));
        assert_eq!(eval("param.color", &ctx), Value::Color("#ff0000".into()));
        assert_eq!(eval("param.color_mode", &ctx), Value::Str("rgb".into()));
    }
}
