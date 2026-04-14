//! Integration tests for the interpreter module.

use super::expr::eval;
use super::expr_types::Value;
use serde_json::json;

#[test]
fn smoke_test_eval() {
    let ctx = json!({"state": {"x": 42}});
    assert_eq!(eval("state.x", &ctx), Value::Number(42.0));
}
