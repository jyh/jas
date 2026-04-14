//! Tree-walking evaluator for the expression language AST.

use serde_json;

use super::color_util;
use super::expr_parser::{BinOp, Expr, LiteralKind};
use super::expr_types::Value;

/// Evaluate an AST node against a JSON context.
///
/// `ctx` is a JSON object with namespace keys like `"state"`, `"panel"`,
/// `"theme"`, `"data"`.
pub fn eval_node(node: &Expr, ctx: &serde_json::Value) -> Value {
    match node {
        Expr::Literal(lit) => eval_literal(lit),
        Expr::Path(segs) => eval_path(segs, ctx),
        Expr::FuncCall { name, args } => eval_func(name, args, ctx),
        Expr::DotAccess { obj, member } => eval_dot_access(obj, member, ctx),
        Expr::IndexAccess { obj, index } => eval_index_access(obj, index, ctx),
        Expr::BinaryOp { op, left, right } => eval_binary(op, left, right, ctx),
        Expr::UnaryNot(operand) => eval_unary_not(operand, ctx),
        Expr::Ternary {
            cond,
            true_expr,
            false_expr,
        } => eval_ternary(cond, true_expr, false_expr, ctx),
        Expr::LogicalAnd(left, right) => eval_logical_and(left, right, ctx),
        Expr::LogicalOr(left, right) => eval_logical_or(left, right, ctx),
    }
}

// -- Literals ----------------------------------------------------------------

fn eval_literal(lit: &LiteralKind) -> Value {
    match lit {
        LiteralKind::Number(n) => Value::Number(*n),
        LiteralKind::Str(s) => Value::Str(s.clone()),
        LiteralKind::Color(c) => Value::color(c),
        LiteralKind::Bool(b) => Value::Bool(*b),
        LiteralKind::Null => Value::Null,
    }
}

// -- Path resolution ---------------------------------------------------------

fn eval_path(segments: &[String], ctx: &serde_json::Value) -> Value {
    if segments.is_empty() {
        return Value::Null;
    }

    let namespace = &segments[0];
    let mut obj = match ctx.get(namespace) {
        Some(v) => v,
        None => return Value::Null,
    };

    for seg in &segments[1..] {
        match obj {
            serde_json::Value::Object(map) => {
                match map.get(seg.as_str()) {
                    Some(v) => obj = v,
                    None => return Value::Null,
                }
            }
            serde_json::Value::Array(arr) => {
                // Try numeric index first
                if let Ok(idx) = seg.parse::<usize>() {
                    if idx < arr.len() {
                        obj = &arr[idx];
                    } else {
                        return Value::Null;
                    }
                } else if seg == "length" {
                    return Value::Number(arr.len() as f64);
                } else {
                    return Value::Null;
                }
            }
            serde_json::Value::String(s) => {
                if seg == "length" {
                    return Value::Number(s.len() as f64);
                }
                return Value::Null;
            }
            _ => return Value::Null,
        }
    }

    Value::from_json(obj)
}

// -- Dot access on computed values -------------------------------------------

fn eval_dot_access(obj_expr: &Expr, member: &str, ctx: &serde_json::Value) -> Value {
    let obj_val = eval_node(obj_expr, ctx);

    // List .length
    if let Value::List(ref arr) = obj_val {
        if member == "length" {
            return Value::Number(arr.len() as f64);
        }
    }

    // String .length
    if let Value::Str(ref s) = obj_val {
        if member == "length" {
            return Value::Number(s.len() as f64);
        }
    }

    // Dict property access -- Str that is actually serialised JSON object
    // is the fallback from_json for objects. Try parsing it back.
    if let Value::Str(ref s) = obj_val {
        if let Ok(serde_json::Value::Object(map)) = serde_json::from_str::<serde_json::Value>(s) {
            if let Some(v) = map.get(member) {
                return Value::from_json(v);
            }
        }
    }

    // List numeric index via dot (e.g. computed_list.0)
    if let Value::List(ref arr) = obj_val {
        if let Ok(idx) = member.parse::<usize>() {
            if idx < arr.len() {
                return Value::from_json(&arr[idx]);
            }
        }
    }

    Value::Null
}

// -- Index access ------------------------------------------------------------

fn eval_index_access(
    obj_expr: &Expr,
    index_expr: &Expr,
    ctx: &serde_json::Value,
) -> Value {
    let obj_val = eval_node(obj_expr, ctx);
    let idx_val = eval_node(index_expr, ctx);
    let key = idx_val.to_string_coerce();

    // Dict-like access via serialised JSON object
    if let Value::Str(ref s) = obj_val {
        if let Ok(serde_json::Value::Object(map)) = serde_json::from_str::<serde_json::Value>(s) {
            if let Some(v) = map.get(&key) {
                return Value::from_json(v);
            }
        }
    }

    // List numeric index
    if let Value::List(ref arr) = obj_val {
        if let Ok(idx) = key.parse::<usize>() {
            if idx < arr.len() {
                return Value::from_json(&arr[idx]);
            }
        }
    }

    Value::Null
}

// -- Function calls ----------------------------------------------------------

/// Extract a hex color string from a Value for color functions.
fn color_arg(val: &Value) -> String {
    match val {
        Value::Color(c) => c.clone(),
        Value::Str(s) => s.clone(),
        Value::Null => "#000000".to_string(),
        _ => "#000000".to_string(),
    }
}

fn eval_func(name: &str, args: &[Expr], ctx: &serde_json::Value) -> Value {
    // Color decomposition: single color argument -> number
    let decompose: Option<fn(u8, u8, u8) -> i32> = match name {
        "hsb_h" => Some(|r, g, b| color_util::rgb_to_hsb(r, g, b).0),
        "hsb_s" => Some(|r, g, b| color_util::rgb_to_hsb(r, g, b).1),
        "hsb_b" => Some(|r, g, b| color_util::rgb_to_hsb(r, g, b).2),
        "rgb_r" => Some(|r, _g, _b| r as i32),
        "rgb_g" => Some(|_r, g, _b| g as i32),
        "rgb_b" => Some(|_r, _g, b| b as i32),
        "cmyk_c" => Some(|r, g, b| color_util::rgb_to_cmyk(r, g, b).0),
        "cmyk_m" => Some(|r, g, b| color_util::rgb_to_cmyk(r, g, b).1),
        "cmyk_y" => Some(|r, g, b| color_util::rgb_to_cmyk(r, g, b).2),
        "cmyk_k" => Some(|r, g, b| color_util::rgb_to_cmyk(r, g, b).3),
        _ => None,
    };

    if let Some(func) = decompose {
        if args.len() != 1 {
            return Value::Number(0.0);
        }
        let arg = eval_node(&args[0], ctx);
        let c = color_arg(&arg);
        let (r, g, b) = color_util::parse_hex(&c);
        return Value::Number(func(r, g, b) as f64);
    }

    match name {
        // hex: color -> string (6 hex digits without #)
        "hex" => {
            if args.len() != 1 {
                return Value::Str(String::new());
            }
            let arg = eval_node(&args[0], ctx);
            let c = color_arg(&arg);
            let (r, g, b) = color_util::parse_hex(&c);
            Value::Str(format!("{:02x}{:02x}{:02x}", r, g, b))
        }

        // rgb: (r, g, b) -> color
        "rgb" => {
            if args.len() != 3 {
                return Value::Null;
            }
            let vals: Vec<Value> = args.iter().map(|a| eval_node(a, ctx)).collect();
            let r = val_to_u8(&vals[0]);
            let g = val_to_u8(&vals[1]);
            let b = val_to_u8(&vals[2]);
            Value::color(&color_util::rgb_to_hex(r, g, b))
        }

        // hsb: (h, s, b) -> color
        "hsb" => {
            if args.len() != 3 {
                return Value::Null;
            }
            let vals: Vec<Value> = args.iter().map(|a| eval_node(a, ctx)).collect();
            let h = val_to_f64(&vals[0]);
            let s = val_to_f64(&vals[1]);
            let bv = val_to_f64(&vals[2]);
            let (r, g, b) = color_util::hsb_to_rgb(h, s, bv);
            Value::color(&color_util::rgb_to_hex(r, g, b))
        }

        // invert: color -> color
        "invert" => {
            if args.len() != 1 {
                return Value::Null;
            }
            let arg = eval_node(&args[0], ctx);
            let c = color_arg(&arg);
            let (r, g, b) = color_util::parse_hex(&c);
            Value::color(&color_util::rgb_to_hex(255 - r, 255 - g, 255 - b))
        }

        // complement: color -> color (rotate hue 180 degrees)
        "complement" => {
            if args.len() != 1 {
                return Value::Null;
            }
            let arg = eval_node(&args[0], ctx);
            let c = color_arg(&arg);
            let (r, g, b) = color_util::parse_hex(&c);
            let (h, s, bv) = color_util::rgb_to_hsb(r, g, b);
            if s == 0 {
                return Value::color(&color_util::rgb_to_hex(r, g, b));
            }
            let new_h = (h + 180) % 360;
            let (nr, ng, nb) = color_util::hsb_to_rgb(new_h as f64, s as f64, bv as f64);
            Value::color(&color_util::rgb_to_hex(nr, ng, nb))
        }

        // Unknown function
        _ => Value::Null,
    }
}

fn val_to_u8(v: &Value) -> u8 {
    match v {
        Value::Number(n) => *n as u8,
        _ => 0,
    }
}

fn val_to_f64(v: &Value) -> f64 {
    match v {
        Value::Number(n) => *n,
        _ => 0.0,
    }
}

// -- Binary operators --------------------------------------------------------

fn eval_binary(
    op: &BinOp,
    left: &Expr,
    right: &Expr,
    ctx: &serde_json::Value,
) -> Value {
    let lv = eval_node(left, ctx);
    let rv = eval_node(right, ctx);

    match op {
        BinOp::Eq => Value::Bool(lv.strict_eq(&rv)),
        BinOp::Neq => Value::Bool(!lv.strict_eq(&rv)),
        BinOp::Lt => numeric_cmp(&lv, &rv, |a, b| a < b),
        BinOp::Gt => numeric_cmp(&lv, &rv, |a, b| a > b),
        BinOp::Lte => numeric_cmp(&lv, &rv, |a, b| a <= b),
        BinOp::Gte => numeric_cmp(&lv, &rv, |a, b| a >= b),
        BinOp::In => eval_in(&lv, &rv),
    }
}

fn numeric_cmp(left: &Value, right: &Value, f: fn(f64, f64) -> bool) -> Value {
    match (left, right) {
        (Value::Number(a), Value::Number(b)) => Value::Bool(f(*a, *b)),
        _ => Value::Bool(false),
    }
}

fn eval_in(left: &Value, right: &Value) -> Value {
    match right {
        Value::List(arr) => {
            for item in arr {
                let item_val = Value::from_json(item);
                if left.strict_eq(&item_val) {
                    return Value::Bool(true);
                }
            }
            Value::Bool(false)
        }
        _ => Value::Bool(false),
    }
}

// -- Unary not ---------------------------------------------------------------

fn eval_unary_not(operand: &Expr, ctx: &serde_json::Value) -> Value {
    let val = eval_node(operand, ctx);
    Value::Bool(!val.to_bool())
}

// -- Ternary -----------------------------------------------------------------

fn eval_ternary(
    cond: &Expr,
    true_expr: &Expr,
    false_expr: &Expr,
    ctx: &serde_json::Value,
) -> Value {
    let cond_val = eval_node(cond, ctx);
    if cond_val.to_bool() {
        eval_node(true_expr, ctx)
    } else {
        eval_node(false_expr, ctx)
    }
}

// -- Logical operators (short-circuit) ---------------------------------------

fn eval_logical_and(left: &Expr, right: &Expr, ctx: &serde_json::Value) -> Value {
    let lv = eval_node(left, ctx);
    if !lv.to_bool() {
        return lv;
    }
    eval_node(right, ctx)
}

fn eval_logical_or(left: &Expr, right: &Expr, ctx: &serde_json::Value) -> Value {
    let lv = eval_node(left, ctx);
    if lv.to_bool() {
        return lv;
    }
    eval_node(right, ctx)
}

// -- Tests -------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::interpreter::expr_parser::parse;
    use serde_json::json;

    /// Helper: evaluate an expression string against a context.
    fn eval(source: &str, ctx: &serde_json::Value) -> Value {
        match parse(source) {
            Some(ast) => eval_node(&ast, ctx),
            None => Value::Null,
        }
    }

    #[test]
    fn literal_number() {
        assert_eq!(eval("42", &json!({})), Value::Number(42.0));
    }

    #[test]
    fn literal_string() {
        assert_eq!(eval("\"hello\"", &json!({})), Value::Str("hello".to_string()));
    }

    #[test]
    fn literal_color() {
        assert_eq!(eval("#ff0000", &json!({})), Value::Color("#ff0000".to_string()));
    }

    #[test]
    fn literal_bool() {
        assert_eq!(eval("true", &json!({})), Value::Bool(true));
        assert_eq!(eval("false", &json!({})), Value::Bool(false));
    }

    #[test]
    fn literal_null() {
        assert_eq!(eval("null", &json!({})), Value::Null);
    }

    #[test]
    fn path_resolution() {
        let ctx = json!({"state": {"fill_color": "#00ff00"}});
        assert_eq!(
            eval("state.fill_color", &ctx),
            Value::Color("#00ff00".to_string())
        );
    }

    #[test]
    fn path_missing() {
        let ctx = json!({"state": {}});
        assert_eq!(eval("state.missing", &ctx), Value::Null);
    }

    #[test]
    fn path_array_index() {
        let ctx = json!({"data": {"items": ["a", "b", "c"]}});
        assert_eq!(
            eval("data.items.1", &ctx),
            Value::Str("b".to_string())
        );
    }

    #[test]
    fn path_array_length() {
        let ctx = json!({"data": {"items": [1, 2, 3]}});
        assert_eq!(eval("data.items.length", &ctx), Value::Number(3.0));
    }

    #[test]
    fn comparison_eq_true() {
        let ctx = json!({"state": {"mode": "fill"}});
        assert_eq!(
            eval("state.mode == \"fill\"", &ctx),
            Value::Bool(true)
        );
    }

    #[test]
    fn comparison_eq_false() {
        let ctx = json!({"state": {"mode": "stroke"}});
        assert_eq!(
            eval("state.mode == \"fill\"", &ctx),
            Value::Bool(false)
        );
    }

    #[test]
    fn comparison_neq() {
        let ctx = json!({"state": {"mode": "stroke"}});
        assert_eq!(
            eval("state.mode != \"fill\"", &ctx),
            Value::Bool(true)
        );
    }

    #[test]
    fn comparison_lt() {
        let ctx = json!({"state": {"x": 5}});
        assert_eq!(eval("state.x < 10", &ctx), Value::Bool(true));
        assert_eq!(eval("state.x < 3", &ctx), Value::Bool(false));
    }

    #[test]
    fn comparison_different_types() {
        let ctx = json!({"state": {"x": 5}});
        assert_eq!(
            eval("state.x == \"5\"", &ctx),
            Value::Bool(false) // strict typed: number != string
        );
    }

    #[test]
    fn logical_and_short_circuit() {
        let ctx = json!({"state": {"a": false, "b": true}});
        assert_eq!(eval("state.a and state.b", &ctx), Value::Bool(false));
    }

    #[test]
    fn logical_or_short_circuit() {
        let ctx = json!({"state": {"a": true, "b": false}});
        assert_eq!(eval("state.a or state.b", &ctx), Value::Bool(true));
    }

    #[test]
    fn unary_not() {
        assert_eq!(eval("not true", &json!({})), Value::Bool(false));
        assert_eq!(eval("not false", &json!({})), Value::Bool(true));
    }

    #[test]
    fn ternary_true_branch() {
        let ctx = json!({"state": {"on": true}});
        assert_eq!(
            eval("state.on ? \"yes\" : \"no\"", &ctx),
            Value::Str("yes".to_string())
        );
    }

    #[test]
    fn ternary_false_branch() {
        let ctx = json!({"state": {"on": false}});
        assert_eq!(
            eval("state.on ? \"yes\" : \"no\"", &ctx),
            Value::Str("no".to_string())
        );
    }

    #[test]
    fn in_operator() {
        let ctx = json!({"data": {"list": ["a", "b", "c"]}});
        assert_eq!(eval("\"b\" in data.list", &ctx), Value::Bool(true));
        assert_eq!(eval("\"x\" in data.list", &ctx), Value::Bool(false));
    }

    #[test]
    fn func_hsb_h() {
        // Pure red => hue 0
        let ctx = json!({"state": {"c": "#ff0000"}});
        assert_eq!(eval("hsb_h(state.c)", &ctx), Value::Number(0.0));
    }

    #[test]
    fn func_rgb_r() {
        let ctx = json!({"state": {"c": "#ff8040"}});
        assert_eq!(eval("rgb_r(state.c)", &ctx), Value::Number(255.0));
    }

    #[test]
    fn func_hex() {
        let ctx = json!({"state": {"c": "#ff0000"}});
        assert_eq!(
            eval("hex(state.c)", &ctx),
            Value::Str("ff0000".to_string())
        );
    }

    #[test]
    fn func_rgb_construct() {
        let result = eval("rgb(255, 0, 128)", &json!({}));
        assert_eq!(result, Value::Color("#ff0080".to_string()));
    }

    #[test]
    fn func_invert() {
        let ctx = json!({"state": {"c": "#ff0000"}});
        assert_eq!(
            eval("invert(state.c)", &ctx),
            Value::Color("#00ffff".to_string())
        );
    }

    #[test]
    fn func_complement() {
        // Red (hue 0) complement => Cyan (hue 180)
        let ctx = json!({"state": {"c": "#ff0000"}});
        let result = eval("complement(state.c)", &ctx);
        assert_eq!(result, Value::Color("#00ffff".to_string()));
    }

    #[test]
    fn index_access_dynamic() {
        let ctx = json!({
            "state": {"key": "b"},
            "data": {"map": {"a": 1, "b": 2, "c": 3}}
        });
        // This uses path + index; the path resolves data.map to a JSON object
        // which is serialised to string by from_json, then index access
        // deserialises and looks up the key.
        // For direct JSON-object indexing we need the path to stop at the object.
        // Currently from_json turns objects into Str(json), so the index-access
        // path parses it back. This matches the Python semantics.
        let result = eval("data.map[state.key]", &ctx);
        // from_json serialises the object, then index_access deserialises.
        // The result should be the number 2.
        // Actually data.map resolves the path through the JSON context,
        // and from_json on {"a":1,"b":2,"c":3} produces Str("{...}").
        // Then index_access deserialises and looks up "b" => 2.
        assert_eq!(result, Value::Number(2.0));
    }

    #[test]
    fn empty_input() {
        assert_eq!(eval("", &json!({})), Value::Null);
    }

    #[test]
    fn dot_access_length_on_string() {
        let ctx = json!({"state": {"name": "hello"}});
        assert_eq!(eval("state.name.length", &ctx), Value::Number(5.0));
    }

    #[test]
    fn cmyk_functions() {
        // Black => C=0, M=0, Y=0, K=100
        let ctx = json!({"state": {"c": "#000000"}});
        assert_eq!(eval("cmyk_k(state.c)", &ctx), Value::Number(100.0));
        assert_eq!(eval("cmyk_c(state.c)", &ctx), Value::Number(0.0));
    }

    #[test]
    fn func_hsb_construct() {
        // hsb(0, 100, 100) => pure red
        let result = eval("hsb(0, 100, 100)", &json!({}));
        assert_eq!(result, Value::Color("#ff0000".to_string()));
    }
}
