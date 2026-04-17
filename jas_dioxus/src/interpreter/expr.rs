//! Top-level expression evaluation entry point.
//!
//! Re-exports the parser and evaluator for convenient use.
//!
//! Parsed ASTs are cached per source string in a thread-local
//! `Rc`-keyed map: re-evaluating the same expression (e.g. a
//! `bind:` clause inside a 216-iteration `foreach`) skips the
//! tokenize+parse step entirely. The cache is unbounded — fine
//! for workspace YAML, where the set of distinct expression
//! strings is finite and bounded by the spec.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use super::expr_eval;
use super::expr_parser::{self, Expr};
use super::expr_types::Value;

thread_local! {
    static AST_CACHE: RefCell<HashMap<String, Option<Rc<Expr>>>> =
        RefCell::new(HashMap::new());
}

/// Evaluate an expression string against a JSON context.
///
/// Returns `Value::Null` for empty or unparseable input.
pub fn eval(source: &str, ctx: &serde_json::Value) -> Value {
    if source.is_empty() {
        return Value::Null;
    }
    let ast_opt = AST_CACHE.with(|c| {
        let mut cache = c.borrow_mut();
        if let Some(cached) = cache.get(source) {
            return cached.clone();
        }
        let ast = expr_parser::parse(source).map(Rc::new);
        cache.insert(source.to_string(), ast.clone());
        ast
    });
    match ast_opt {
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

    #[test]
    fn cache_returns_correct_results_on_repeat() {
        // Sanity: same expression evaluated twice with different
        // contexts must return per-context results, not a stale
        // cached value.
        let ctx1 = serde_json::json!({"x": 1});
        let ctx2 = serde_json::json!({"x": 99});
        assert_eq!(eval("x", &ctx1), Value::Number(1.0));
        assert_eq!(eval("x", &ctx2), Value::Number(99.0));
        assert_eq!(eval("x + 1", &ctx1), Value::Number(2.0));
        assert_eq!(eval("x + 1", &ctx2), Value::Number(100.0));
        // Re-eval should be cache hits and still correct.
        assert_eq!(eval("x", &ctx1), Value::Number(1.0));
        assert_eq!(eval("x + 1", &ctx2), Value::Number(100.0));
    }

    #[test]
    fn cache_handles_unparseable_input() {
        // Garbage strings cache as None so we don't reparse.
        let ctx = serde_json::json!({});
        assert_eq!(eval(")(", &ctx), Value::Null);
        assert_eq!(eval(")(", &ctx), Value::Null);  // cache hit on None
    }

    /// Bench harness — gated behind --ignored so it doesn't run with
    /// the regular suite.  Run with:
    ///   cargo test --release -- --ignored --nocapture bench_eval_swatches
    #[test]
    #[ignore]
    fn bench_eval_swatches() {
        // Representative swatches workload: 11 expressions × 216 swatches
        // = 2376 evals per "render". The expressions are the actual ones
        // from workspace/panels/swatches.yaml bind clauses.
        let exprs = [
            "swatch.color",
            "swatch.color_mode",
            "swatch.name",
            "swatch._index",
            "lib.id",
            "lib.name",
            "panel.selected_swatches",
            "panel.selected_library",
            "panel.recent_colors",
            "state.fill_color",
            "state.fill_on_top",
        ];

        // 216 distinct contexts (one per swatch tile)
        let contexts: Vec<serde_json::Value> = (0..216)
            .map(|i| {
                serde_json::json!({
                    "swatch": {
                        "name": format!("c{}", i),
                        "color": format!("#{:06x}", i * 0x123),
                        "color_mode": "rgb",
                        "_index": i,
                    },
                    "lib": { "id": "default", "name": "Default" },
                    "panel": {
                        "selected_swatches": [],
                        "selected_library": "default",
                        "recent_colors": [],
                    },
                    "state": {
                        "fill_color": "#cc0000",
                        "fill_on_top": true,
                    },
                })
            })
            .collect();

        // Warmup
        for _ in 0..3 {
            for ctx in &contexts {
                for e in &exprs { let _ = eval(e, ctx); }
            }
        }

        // Measure: 20 "renders", each = 216 ctx × 11 exprs
        let iters = 20;
        let t0 = std::time::Instant::now();
        for _ in 0..iters {
            for ctx in &contexts {
                for e in &exprs { let _ = eval(e, ctx); }
            }
        }
        let elapsed = t0.elapsed();
        let per_render_ms = elapsed.as_secs_f64() * 1000.0 / iters as f64;
        let evals_per_render = contexts.len() * exprs.len();
        let per_eval_us = per_render_ms * 1000.0 / evals_per_render as f64;
        eprintln!(
            "\n  bench_eval_swatches: {:.2} ms/render  ({} evals × {} renders, {:.2} µs/eval)\n",
            per_render_ms, evals_per_render, iters, per_eval_us,
        );
    }
}
