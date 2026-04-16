//! Tree-walking evaluator for the expression language AST.

use std::collections::HashMap;

use serde_json;

use super::color_util;
use super::expr_parser::{BinOp, Expr, LiteralKind};
use super::expr_types::Value;

/// Store callback type: called when an assignment `x <- val` is evaluated.
pub type StoreCb = Box<dyn Fn(&str, &Value)>;

/// Local scope for let-bindings and lambda parameters.
///
/// This is separate from the JSON context because closures (which contain
/// AST nodes) cannot be serialised into `serde_json::Value`.
#[derive(Debug, Clone)]
struct Scope {
    bindings: HashMap<String, Value>,
}

impl Scope {
    fn new() -> Self {
        Self {
            bindings: HashMap::new(),
        }
    }

    fn get(&self, name: &str) -> Option<&Value> {
        self.bindings.get(name)
    }

    fn with_binding(&self, name: &str, val: Value) -> Self {
        let mut s = self.clone();
        s.bindings.insert(name.to_string(), val);
        s
    }

    fn with_bindings(&self, pairs: &[(&str, Value)]) -> Self {
        let mut s = self.clone();
        for (k, v) in pairs {
            s.bindings.insert(k.to_string(), v.clone());
        }
        s
    }
}

/// Evaluate an AST node against a JSON context.
///
/// `ctx` is a JSON object with namespace keys like `"state"`, `"panel"`,
/// `"theme"`, `"data"`.
pub fn eval_node(node: &Expr, ctx: &serde_json::Value) -> Value {
    eval_inner(node, ctx, &Scope::new(), None)
}

/// Evaluate with an optional store callback for assignments.
pub fn eval_node_with_store(
    node: &Expr,
    ctx: &serde_json::Value,
    store_cb: Option<&StoreCb>,
) -> Value {
    eval_inner(node, ctx, &Scope::new(), store_cb)
}

/// Core evaluator that threads a scope for local bindings.
fn eval_inner(
    node: &Expr,
    ctx: &serde_json::Value,
    scope: &Scope,
    store_cb: Option<&StoreCb>,
) -> Value {
    match node {
        Expr::Literal(lit) => eval_literal(lit, ctx, scope, store_cb),
        Expr::Path(segs) => eval_path(segs, ctx, scope),
        Expr::FuncCall { name, args } => eval_func(name, args, ctx, scope, store_cb),
        Expr::DotAccess { obj, member } => eval_dot_access(obj, member, ctx, scope, store_cb),
        Expr::IndexAccess { obj, index } => eval_index_access(obj, index, ctx, scope, store_cb),
        Expr::BinaryOp { op, left, right } => eval_binary(op, left, right, ctx, scope, store_cb),
        Expr::UnaryNot(operand) => {
            let val = eval_inner(operand, ctx, scope, store_cb);
            Value::Bool(!val.to_bool())
        }
        Expr::UnaryMinus(operand) => {
            let val = eval_inner(operand, ctx, scope, store_cb);
            if let Value::Number(n) = val {
                Value::Number(-n)
            } else {
                Value::Null
            }
        }
        Expr::Ternary {
            cond,
            true_expr,
            false_expr,
        } => {
            let cond_val = eval_inner(cond, ctx, scope, store_cb);
            if cond_val.to_bool() {
                eval_inner(true_expr, ctx, scope, store_cb)
            } else {
                eval_inner(false_expr, ctx, scope, store_cb)
            }
        }
        Expr::LogicalAnd(left, right) => {
            let lv = eval_inner(left, ctx, scope, store_cb);
            if !lv.to_bool() {
                lv
            } else {
                eval_inner(right, ctx, scope, store_cb)
            }
        }
        Expr::LogicalOr(left, right) => {
            let lv = eval_inner(left, ctx, scope, store_cb);
            if lv.to_bool() {
                lv
            } else {
                eval_inner(right, ctx, scope, store_cb)
            }
        }
        Expr::Lambda { params, body } => {
            // Capture the current context + scope as the closure's environment
            Value::Closure {
                params: params.clone(),
                body: Box::new(*body.clone()),
                captured_ctx: ctx.clone(),
                captured_scope: Some(Box::new(scope.bindings.clone())),
            }
        }
        Expr::Let { name, value, body } => {
            let val = eval_inner(value, ctx, scope, store_cb);
            // Extend the scope with the new binding
            let child_scope = scope.with_binding(name, val.clone());
            // Also put non-closure values into JSON context for path resolution
            let child_ctx = if !matches!(val, Value::Closure { .. }) {
                let mut c = ctx.clone();
                if let serde_json::Value::Object(ref mut map) = c {
                    map.insert(name.clone(), value_to_json(&val));
                }
                c
            } else {
                ctx.clone()
            };
            eval_inner(body, &child_ctx, &child_scope, store_cb)
        }
        Expr::Assign { target, value } => {
            let val = eval_inner(value, ctx, scope, store_cb);
            if let Some(cb) = store_cb {
                cb(target, &val);
            }
            val
        }
        Expr::Sequence { left, right } => {
            eval_inner(left, ctx, scope, store_cb);
            eval_inner(right, ctx, scope, store_cb)
        }
    }
}

/// Convert a Value to a serde_json::Value for context storage.
fn value_to_json(val: &Value) -> serde_json::Value {
    match val {
        Value::Null => serde_json::Value::Null,
        Value::Bool(b) => serde_json::Value::Bool(*b),
        Value::Number(n) => serde_json::json!(*n),
        Value::Str(s) => serde_json::Value::String(s.clone()),
        Value::Color(c) => serde_json::Value::String(c.clone()),
        Value::List(arr) => serde_json::Value::Array(arr.clone()),
        // Path is encoded with a reserved key so from_json round-trips
        // it back to Value::Path. Users never see this JSON form.
        Value::Path(indices) => serde_json::json!({
            "__path__": indices.iter().map(|&i| i as u64).collect::<Vec<_>>()
        }),
        Value::Closure { .. } => serde_json::Value::Null,
    }
}

// -- Literals ----------------------------------------------------------------

fn eval_literal(
    lit: &LiteralKind,
    ctx: &serde_json::Value,
    scope: &Scope,
    store_cb: Option<&StoreCb>,
) -> Value {
    match lit {
        LiteralKind::Number(n) => Value::Number(*n),
        LiteralKind::Str(s) => Value::Str(s.clone()),
        LiteralKind::Color(c) => Value::color(c),
        LiteralKind::Bool(b) => Value::Bool(*b),
        LiteralKind::Null => Value::Null,
        LiteralKind::List(items) => {
            let values: Vec<serde_json::Value> = items
                .iter()
                .map(|item| value_to_json(&eval_inner(item, ctx, scope, store_cb)))
                .collect();
            Value::List(values)
        }
    }
}

// -- Path resolution ---------------------------------------------------------

/// Drill into a scope-bound Value using a sequence of dot segments.
/// Handles the Value::Str(serialized_json) representation of dicts that
/// foreach/HOF bind into scope, plus Path properties and List indexing.
fn drill_into_value(val: &Value, segments: &[String]) -> Value {
    let mut current: serde_json::Value = match val {
        Value::Str(s) => {
            // Try to deserialize — scope dicts are stored as serialized JSON
            serde_json::from_str(s).unwrap_or_else(|_| serde_json::Value::String(s.clone()))
        }
        Value::Path(indices) => {
            // Path property access via segments
            if segments.is_empty() { return val.clone(); }
            return path_property(indices, &segments[0]);
        }
        Value::List(arr) => serde_json::Value::Array(arr.clone()),
        Value::Null => return Value::Null,
        Value::Bool(b) => serde_json::json!(*b),
        Value::Number(n) => serde_json::json!(*n),
        Value::Color(c) => serde_json::Value::String(c.clone()),
        Value::Closure { .. } => return Value::Null,
    };
    for seg in segments {
        match current {
            serde_json::Value::Object(map) => match map.get(seg.as_str()) {
                Some(v) => current = v.clone(),
                None => return Value::Null,
            },
            serde_json::Value::Array(arr) => {
                if let Ok(idx) = seg.parse::<usize>() {
                    if idx < arr.len() {
                        current = arr[idx].clone();
                    } else {
                        return Value::Null;
                    }
                } else if seg == "length" {
                    return Value::Number(arr.len() as f64);
                } else {
                    return Value::Null;
                }
            }
            serde_json::Value::String(ref s) => {
                if seg == "length" {
                    return Value::Number(s.len() as f64);
                }
                return Value::Null;
            }
            _ => return Value::Null,
        }
    }
    Value::from_json(&current)
}

fn path_property(indices: &[usize], member: &str) -> Value {
    match member {
        "depth" => Value::Number(indices.len() as f64),
        "parent" => {
            if indices.is_empty() {
                Value::Null
            } else {
                Value::Path(indices[..indices.len() - 1].to_vec())
            }
        }
        "id" => Value::Str(indices.iter().map(|i| i.to_string()).collect::<Vec<_>>().join(".")),
        "indices" => Value::List(indices.iter().map(|&i| serde_json::json!(i)).collect()),
        _ => Value::Null,
    }
}

fn eval_path(segments: &[String], ctx: &serde_json::Value, scope: &Scope) -> Value {
    if segments.is_empty() {
        return Value::Null;
    }

    let namespace = &segments[0];

    // Single-segment path: check scope first (for let bindings / lambda params)
    if segments.len() == 1 {
        if let Some(val) = scope.get(namespace) {
            return val.clone();
        }
    }

    let obj = match ctx.get(namespace) {
        Some(v) => v,
        None => {
            // Check scope for the namespace — lets and foreach bindings live
            // here. For single-segment paths we already handled it above.
            // For multi-segment paths, try drilling into the scope value.
            if let Some(val) = scope.get(namespace) {
                if segments.len() == 1 {
                    return val.clone();
                }
                return drill_into_value(val, &segments[1..]);
            }
            return Value::Null;
        }
    };

    if segments.len() == 1 {
        return Value::from_json(obj);
    }

    let mut current = obj;
    // Temp storage for serialized-JSON strings we parse along the way —
    // keeps references valid across loop iterations.
    let mut parsed: Option<serde_json::Value> = None;
    for seg in &segments[1..] {
        match current {
            serde_json::Value::Object(map) => match map.get(seg.as_str()) {
                Some(v) => current = v,
                None => return Value::Null,
            },
            serde_json::Value::Array(arr) => {
                if let Ok(idx) = seg.parse::<usize>() {
                    if idx < arr.len() {
                        current = &arr[idx];
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
                // A String may be a serialized-JSON dict (from
                // Value::from_json's object-stringification path, or
                // from element_at). Try parsing and continue drilling.
                match serde_json::from_str::<serde_json::Value>(s) {
                    Ok(v @ serde_json::Value::Object(_))
                    | Ok(v @ serde_json::Value::Array(_)) => {
                        parsed = Some(v);
                        current = parsed.as_ref().unwrap();
                        match current {
                            serde_json::Value::Object(map) => match map.get(seg.as_str()) {
                                Some(v) => current = v,
                                None => return Value::Null,
                            },
                            serde_json::Value::Array(arr) => {
                                if let Ok(idx) = seg.parse::<usize>() {
                                    if idx < arr.len() {
                                        current = &arr[idx];
                                    } else {
                                        return Value::Null;
                                    }
                                } else {
                                    return Value::Null;
                                }
                            }
                            _ => return Value::Null,
                        }
                    }
                    _ => return Value::Null,
                }
            }
            _ => return Value::Null,
        }
    }

    Value::from_json(current)
}

// -- Dot access on computed values -------------------------------------------

fn eval_dot_access(
    obj_expr: &Expr,
    member: &str,
    ctx: &serde_json::Value,
    scope: &Scope,
    store_cb: Option<&StoreCb>,
) -> Value {
    let obj_val = eval_inner(obj_expr, ctx, scope, store_cb);

    // Path computed properties (Phase 3 §6.2)
    if let Value::Path(ref indices) = obj_val {
        match member {
            "depth" => return Value::Number(indices.len() as f64),
            "parent" => {
                if indices.is_empty() {
                    return Value::Null;
                }
                let mut parent = indices.clone();
                parent.pop();
                return Value::Path(parent);
            }
            "id" => {
                return Value::Str(
                    indices.iter().map(|i| i.to_string()).collect::<Vec<_>>().join(".")
                );
            }
            "indices" => {
                return Value::List(
                    indices.iter().map(|&i| serde_json::json!(i)).collect()
                );
            }
            _ => return Value::Null,
        }
    }

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
    scope: &Scope,
    store_cb: Option<&StoreCb>,
) -> Value {
    let obj_val = eval_inner(obj_expr, ctx, scope, store_cb);
    let idx_val = eval_inner(index_expr, ctx, scope, store_cb);
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

fn eval_func(
    name: &str,
    args: &[Expr],
    ctx: &serde_json::Value,
    scope: &Scope,
    store_cb: Option<&StoreCb>,
) -> Value {
    // __apply__: first arg is the callee expression result
    if name == "__apply__" && !args.is_empty() {
        let callee = eval_inner(&args[0], ctx, scope, store_cb);
        return apply_closure(&callee, &args[1..], ctx, scope, store_cb);
    }

    // Check if name resolves to a closure in scope
    if let Some(val) = scope.get(name) {
        if let Value::Closure { .. } = val {
            return apply_closure(val, args, ctx, scope, store_cb);
        }
    }

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
        let arg = eval_inner(&args[0], ctx, scope, store_cb);
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
            let arg = eval_inner(&args[0], ctx, scope, store_cb);
            let c = color_arg(&arg);
            let (r, g, b) = color_util::parse_hex(&c);
            Value::Str(format!("{:02x}{:02x}{:02x}", r, g, b))
        }

        // rgb: (r, g, b) -> color
        "rgb" => {
            if args.len() != 3 {
                return Value::Null;
            }
            let vals: Vec<Value> = args
                .iter()
                .map(|a| eval_inner(a, ctx, scope, store_cb))
                .collect();
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
            let vals: Vec<Value> = args
                .iter()
                .map(|a| eval_inner(a, ctx, scope, store_cb))
                .collect();
            let h = val_to_f64(&vals[0]);
            let s = val_to_f64(&vals[1]);
            let bv = val_to_f64(&vals[2]);
            let (r, g, b) = color_util::hsb_to_rgb(h, s, bv);
            Value::color(&color_util::rgb_to_hex(r, g, b))
        }

        // cmyk: (c, m, y, k) -> color
        "cmyk" => {
            if args.len() != 4 {
                return Value::Null;
            }
            let vals: Vec<Value> = args
                .iter()
                .map(|a| eval_inner(a, ctx, scope, store_cb))
                .collect();
            let c = val_to_f64(&vals[0]) / 100.0;
            let m = val_to_f64(&vals[1]) / 100.0;
            let y = val_to_f64(&vals[2]) / 100.0;
            let k = val_to_f64(&vals[3]) / 100.0;
            let r = ((1.0 - c) * (1.0 - k) * 255.0).round() as u8;
            let g = ((1.0 - m) * (1.0 - k) * 255.0).round() as u8;
            let b = ((1.0 - y) * (1.0 - k) * 255.0).round() as u8;
            Value::color(&color_util::rgb_to_hex(r, g, b))
        }

        // grayscale: (k) -> color  (k is 0-100, 0=white, 100=black)
        "grayscale" => {
            if args.len() != 1 {
                return Value::Null;
            }
            let k = val_to_f64(&eval_inner(&args[0], ctx, scope, store_cb));
            let v = ((1.0 - k / 100.0) * 255.0).round() as u8;
            Value::color(&color_util::rgb_to_hex(v, v, v))
        }

        // invert: color -> color
        "invert" => {
            if args.len() != 1 {
                return Value::Null;
            }
            let arg = eval_inner(&args[0], ctx, scope, store_cb);
            let c = color_arg(&arg);
            let (r, g, b) = color_util::parse_hex(&c);
            Value::color(&color_util::rgb_to_hex(255 - r, 255 - g, 255 - b))
        }

        // complement: color -> color (rotate hue 180 degrees)
        "complement" => {
            if args.len() != 1 {
                return Value::Null;
            }
            let arg = eval_inner(&args[0], ctx, scope, store_cb);
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

        // Higher-order functions (Phase 3 §6.1)
        "any" | "all" | "map" | "filter" => {
            if args.len() != 2 {
                return match name {
                    "map" | "filter" => Value::Null,
                    "all" => Value::Bool(true),
                    _ => Value::Bool(false),
                };
            }
            let lst = eval_inner(&args[0], ctx, scope, store_cb);
            let callable = eval_inner(&args[1], ctx, scope, store_cb);
            let items = match lst {
                Value::List(a) => a,
                _ => return match name {
                    "map" | "filter" => Value::Null,
                    "all" => Value::Bool(true),
                    _ => Value::Bool(false),
                },
            };
            if !matches!(callable, Value::Closure { .. }) {
                return match name {
                    "map" | "filter" => Value::Null,
                    "all" => Value::Bool(true),
                    _ => Value::Bool(false),
                };
            }
            let mut results: Vec<Value> = Vec::with_capacity(items.len());
            for item in &items {
                // Bind the item as an Expr::Literal wrapper. Since apply_closure
                // takes Expr args, we use a pre-eval path: call apply_closure_values.
                let arg_val = Value::from_json(item);
                results.push(apply_closure_values(&callable, vec![arg_val], ctx, scope, store_cb));
            }
            match name {
                "any" => Value::Bool(results.iter().any(|r| r.to_bool())),
                "all" => Value::Bool(results.iter().all(|r| r.to_bool())),
                "map" => Value::List(
                    results.into_iter()
                        .map(|r| value_to_json(&r))
                        .collect()
                ),
                "filter" => Value::List(
                    items.iter().zip(results.iter())
                        .filter(|(_, r)| r.to_bool())
                        .map(|(i, _)| i.clone())
                        .collect()
                ),
                _ => Value::Null,
            }
        }

        // Path functions (Phase 3 §6.2)
        "path" => {
            let mut idx: Vec<usize> = Vec::with_capacity(args.len());
            for a in args {
                let v = eval_inner(a, ctx, scope, store_cb);
                match v {
                    Value::Number(n) if n >= 0.0 => idx.push(n as usize),
                    _ => return Value::Null,
                }
            }
            Value::Path(idx)
        }

        "path_child" => {
            if args.len() != 2 { return Value::Null; }
            let p = eval_inner(&args[0], ctx, scope, store_cb);
            let i = eval_inner(&args[1], ctx, scope, store_cb);
            match (p, i) {
                (Value::Path(mut indices), Value::Number(n)) if n >= 0.0 => {
                    indices.push(n as usize);
                    Value::Path(indices)
                }
                _ => Value::Null,
            }
        }

        "path_from_id" => {
            if args.len() != 1 { return Value::Null; }
            let s = eval_inner(&args[0], ctx, scope, store_cb);
            let s = match s { Value::Str(s) => s, _ => return Value::Null };
            if s.is_empty() {
                return Value::Path(Vec::new());
            }
            let mut parts: Vec<usize> = Vec::new();
            for p in s.split('.') {
                match p.parse::<usize>() {
                    Ok(n) => parts.push(n),
                    Err(_) => return Value::Null,
                }
            }
            Value::Path(parts)
        }

        // element_at(path) — resolve a path against active_document's
        // layer tree. For a single-element path returns the matching
        // top-level layer view; for deeper paths descends through the
        // layer's .children. Returns Null for non-path args, out-of-range
        // indices, or empty paths (Phase 4).
        "element_at" => {
            if args.len() != 1 { return Value::Null; }
            let p = eval_inner(&args[0], ctx, scope, store_cb);
            let indices = match p {
                Value::Path(v) => v,
                _ => return Value::Null,
            };
            if indices.is_empty() { return Value::Null; }
            let top = match ctx.get("active_document")
                .and_then(|ad| ad.get("top_level_layers"))
                .and_then(|t| t.as_array())
            {
                Some(arr) => arr,
                None => return Value::Null,
            };
            let first = indices[0];
            let mut cur = match top.get(first) {
                Some(v) => v,
                None => return Value::Null,
            };
            for &idx in &indices[1..] {
                let children = match cur.get("children").and_then(|c| c.as_array()) {
                    Some(a) => a,
                    None => return Value::Null,
                };
                cur = match children.get(idx) {
                    Some(v) => v,
                    None => return Value::Null,
                };
            }
            Value::from_json(cur)
        }

        // reverse: list -> list
        "reverse" => {
            if args.len() != 1 { return Value::Null; }
            let v = eval_inner(&args[0], ctx, scope, store_cb);
            match v {
                Value::List(mut arr) => {
                    arr.reverse();
                    Value::List(arr)
                }
                _ => Value::Null,
            }
        }

        // mem: (element, list) -> bool — list membership
        "mem" => {
            if args.len() != 2 {
                return Value::Bool(false);
            }
            let elem = eval_inner(&args[0], ctx, scope, store_cb);
            let lst = eval_inner(&args[1], ctx, scope, store_cb);
            if let Value::List(ref arr) = lst {
                for item in arr {
                    let item_val = Value::from_json(item);
                    if elem.strict_eq(&item_val) {
                        return Value::Bool(true);
                    }
                }
            }
            Value::Bool(false)
        }

        // Unknown function
        _ => Value::Null,
    }
}

/// Apply a closure value to evaluated arguments.
fn apply_closure(
    callee: &Value,
    arg_exprs: &[Expr],
    ctx: &serde_json::Value,
    scope: &Scope,
    store_cb: Option<&StoreCb>,
) -> Value {
    let call_args: Vec<Value> = arg_exprs
        .iter()
        .map(|a| eval_inner(a, ctx, scope, store_cb))
        .collect();
    apply_closure_values(callee, call_args, ctx, scope, store_cb)
}

/// Apply a closure to already-evaluated Value arguments (used by HOFs).
/// Lexical scoping: the captured scope wins over the caller's scope for
/// user bindings. The caller's namespace ctx (state/panel/etc.) overrides
/// the captured one so runtime-context reads are current.
fn apply_closure_values(
    callee: &Value,
    call_args: Vec<Value>,
    ctx: &serde_json::Value,
    _caller_scope: &Scope,
    store_cb: Option<&StoreCb>,
) -> Value {
    if let Value::Closure {
        params,
        body,
        captured_ctx,
        captured_scope,
    } = callee
    {
        if call_args.len() != params.len() {
            return Value::Null;
        }

        // Namespace ctx: caller overrides captured (fresh state/panel reads).
        let call_ctx = merge_contexts(captured_ctx, ctx);

        // User scope: captured only. Do NOT overlay caller's scope —
        // that would be dynamic scoping (Phase 3 §4 closure-capture contract).
        let mut call_scope = Scope::new();
        if let Some(cs) = captured_scope {
            call_scope.bindings = *cs.clone();
        }
        for (p, a) in params.iter().zip(call_args.into_iter()) {
            call_scope.bindings.insert(p.clone(), a);
        }

        return eval_inner(body, &call_ctx, &call_scope, store_cb);
    }
    Value::Null
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

/// Merge two JSON contexts. The second context's top-level keys override the first.
fn merge_contexts(
    base: &serde_json::Value,
    overlay: &serde_json::Value,
) -> serde_json::Value {
    let mut result = base.clone();
    if let (serde_json::Value::Object(rmap), serde_json::Value::Object(omap)) =
        (&mut result, overlay)
    {
        for (k, v) in omap {
            rmap.insert(k.clone(), v.clone());
        }
    }
    result
}

// -- Binary operators --------------------------------------------------------

fn eval_binary(
    op: &BinOp,
    left: &Expr,
    right: &Expr,
    ctx: &serde_json::Value,
    scope: &Scope,
    store_cb: Option<&StoreCb>,
) -> Value {
    let lv = eval_inner(left, ctx, scope, store_cb);
    let rv = eval_inner(right, ctx, scope, store_cb);

    match op {
        BinOp::Eq => Value::Bool(lv.strict_eq(&rv)),
        BinOp::Neq => Value::Bool(!lv.strict_eq(&rv)),
        BinOp::Lt => numeric_cmp(&lv, &rv, |a, b| a < b),
        BinOp::Gt => numeric_cmp(&lv, &rv, |a, b| a > b),
        BinOp::Lte => numeric_cmp(&lv, &rv, |a, b| a <= b),
        BinOp::Gte => numeric_cmp(&lv, &rv, |a, b| a >= b),
        BinOp::Add => {
            if let (Value::Number(a), Value::Number(b)) = (&lv, &rv) {
                Value::Number(a + b)
            } else {
                // String concatenation
                Value::Str(format!("{}{}", lv.to_string_coerce(), rv.to_string_coerce()))
            }
        }
        BinOp::Sub => {
            if let (Value::Number(a), Value::Number(b)) = (&lv, &rv) {
                Value::Number(a - b)
            } else {
                Value::Null
            }
        }
        BinOp::Mul => {
            if let (Value::Number(a), Value::Number(b)) = (&lv, &rv) {
                Value::Number(a * b)
            } else {
                Value::Null
            }
        }
        BinOp::Div => {
            if let (Value::Number(a), Value::Number(b)) = (&lv, &rv) {
                if *b == 0.0 {
                    Value::Null
                } else {
                    Value::Number(a / b)
                }
            } else {
                Value::Null
            }
        }
    }
}

fn numeric_cmp(left: &Value, right: &Value, f: fn(f64, f64) -> bool) -> Value {
    match (left, right) {
        (Value::Number(a), Value::Number(b)) => Value::Bool(f(*a, *b)),
        _ => Value::Bool(false),
    }
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
    fn unary_minus() {
        assert_eq!(eval("-5", &json!({})), Value::Number(-5.0));
        let ctx = json!({"state": {"x": 10}});
        assert_eq!(eval("-state.x", &ctx), Value::Number(-10.0));
    }

    #[test]
    fn ternary_true_branch() {
        let ctx = json!({"state": {"on": true}});
        assert_eq!(
            eval("if state.on then \"yes\" else \"no\"", &ctx),
            Value::Str("yes".to_string())
        );
    }

    #[test]
    fn ternary_false_branch() {
        let ctx = json!({"state": {"on": false}});
        assert_eq!(
            eval("if state.on then \"yes\" else \"no\"", &ctx),
            Value::Str("no".to_string())
        );
    }

    #[test]
    fn func_hsb_h() {
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
        let ctx = json!({"state": {"c": "#ff0000"}});
        let result = eval("complement(state.c)", &ctx);
        assert_eq!(result, Value::Color("#00ffff".to_string()));
    }

    #[test]
    fn func_mem() {
        let ctx = json!({"data": {"list": ["a", "b", "c"]}});
        assert_eq!(eval("mem(\"b\", data.list)", &ctx), Value::Bool(true));
        assert_eq!(eval("mem(\"x\", data.list)", &ctx), Value::Bool(false));
    }

    #[test]
    fn index_access_dynamic() {
        let ctx = json!({
            "state": {"key": "b"},
            "data": {"map": {"a": 1, "b": 2, "c": 3}}
        });
        let result = eval("data.map[state.key]", &ctx);
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
        let ctx = json!({"state": {"c": "#000000"}});
        assert_eq!(eval("cmyk_k(state.c)", &ctx), Value::Number(100.0));
        assert_eq!(eval("cmyk_c(state.c)", &ctx), Value::Number(0.0));
    }

    #[test]
    fn func_hsb_construct() {
        let result = eval("hsb(0, 100, 100)", &json!({}));
        assert_eq!(result, Value::Color("#ff0000".to_string()));
    }

    #[test]
    fn panel_mode_visibility() {
        let ctx = json!({"state": {}, "panel": {"mode": "hsb"}});
        let r = eval(r#"panel.mode == "hsb""#, &ctx);
        assert_eq!(r, Value::Bool(true));
        assert!(r.to_bool());
        let r2 = eval(r#"panel.mode == "rgb""#, &ctx);
        assert_eq!(r2, Value::Bool(false));
        assert!(!r2.to_bool());
    }

    // -- Arithmetic tests ----

    #[test]
    fn arithmetic_add() {
        assert_eq!(eval("3 + 4", &json!({})), Value::Number(7.0));
    }

    #[test]
    fn arithmetic_sub() {
        assert_eq!(eval("10 - 3", &json!({})), Value::Number(7.0));
    }

    #[test]
    fn arithmetic_mul() {
        assert_eq!(eval("3 * 4", &json!({})), Value::Number(12.0));
    }

    #[test]
    fn arithmetic_div() {
        assert_eq!(eval("10 / 4", &json!({})), Value::Number(2.5));
    }

    #[test]
    fn arithmetic_div_by_zero() {
        assert_eq!(eval("10 / 0", &json!({})), Value::Null);
    }

    #[test]
    fn arithmetic_precedence() {
        // 2 + 3 * 4 = 14
        assert_eq!(eval("2 + 3 * 4", &json!({})), Value::Number(14.0));
    }

    #[test]
    fn string_concatenation() {
        assert_eq!(
            eval("\"hello\" + \" \" + \"world\"", &json!({})),
            Value::Str("hello world".to_string())
        );
    }

    // -- Lambda / Let / Sequence tests ----

    #[test]
    fn lambda_identity() {
        let result = eval("(fun x -> x)(42)", &json!({}));
        assert_eq!(result, Value::Number(42.0));
    }

    #[test]
    fn lambda_add() {
        let result = eval("(fun (a, b) -> a + b)(3, 4)", &json!({}));
        assert_eq!(result, Value::Number(7.0));
    }

    #[test]
    fn let_binding() {
        let result = eval("let x = 5 in x + 1", &json!({}));
        assert_eq!(result, Value::Number(6.0));
    }

    #[test]
    fn let_nested() {
        let result = eval("let x = 2 in let y = 3 in x * y", &json!({}));
        assert_eq!(result, Value::Number(6.0));
    }

    #[test]
    fn sequence_returns_last() {
        let result = eval("1; 2; 3", &json!({}));
        assert_eq!(result, Value::Number(3.0));
    }

    #[test]
    fn list_literal() {
        let result = eval("[1, 2, 3]", &json!({}));
        assert_eq!(
            result,
            Value::List(vec![
                serde_json::json!(1.0),
                serde_json::json!(2.0),
                serde_json::json!(3.0),
            ])
        );
    }

    #[test]
    fn list_literal_empty() {
        let result = eval("[]", &json!({}));
        assert_eq!(result, Value::List(vec![]));
    }

    #[test]
    fn let_with_lambda() {
        // let double = fun x -> x * 2 in double(5)
        let result = eval("let double = fun x -> x * 2 in double(5)", &json!({}));
        assert_eq!(result, Value::Number(10.0));
    }

    #[test]
    fn lambda_closure_capture() {
        // let a = 10 in let f = fun x -> x + a in f(5)
        let result = eval("let a = 10 in let f = fun x -> x + a in f(5)", &json!({}));
        assert_eq!(result, Value::Number(15.0));
    }

    #[test]
    fn mem_with_list_literal() {
        assert_eq!(eval("mem(2, [1, 2, 3])", &json!({})), Value::Bool(true));
        assert_eq!(eval("mem(5, [1, 2, 3])", &json!({})), Value::Bool(false));
    }

    #[test]
    fn unary_minus_in_expression() {
        // -(3 + 4)
        assert_eq!(eval("-(3 + 4)", &json!({})), Value::Number(-7.0));
    }

    #[test]
    fn assign_with_store() {
        use std::sync::{Arc, Mutex};
        let stored = Arc::new(Mutex::new(Vec::new()));
        let stored_clone = stored.clone();
        let store_cb: StoreCb = Box::new(move |name: &str, val: &Value| {
            stored_clone.lock().unwrap().push((name.to_string(), val.clone()));
        });
        let ast = parse("x <- 42").unwrap();
        let result = eval_node_with_store(&ast, &json!({}), Some(&store_cb));
        assert_eq!(result, Value::Number(42.0));
        let entries = stored.lock().unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].0, "x");
        assert_eq!(entries[0].1, Value::Number(42.0));
    }

    // ── Phase 3: HOFs ─────────────────────────────────────────

    #[test]
    fn hof_any_true() {
        assert_eq!(
            eval("any([1, 2, 3], fun n -> n > 2)", &json!({})),
            Value::Bool(true)
        );
    }

    #[test]
    fn hof_any_false() {
        assert_eq!(
            eval("any([1, 2, 3], fun n -> n > 10)", &json!({})),
            Value::Bool(false)
        );
    }

    #[test]
    fn hof_any_empty() {
        assert_eq!(
            eval("any([], fun n -> true)", &json!({})),
            Value::Bool(false)
        );
    }

    #[test]
    fn hof_all_true() {
        assert_eq!(
            eval("all([2, 4, 6], fun n -> n > 0)", &json!({})),
            Value::Bool(true)
        );
    }

    #[test]
    fn hof_all_false() {
        assert_eq!(
            eval("all([2, 4, 5], fun n -> n > 3)", &json!({})),
            Value::Bool(false)
        );
    }

    #[test]
    fn hof_all_empty() {
        assert_eq!(eval("all([], fun n -> false)", &json!({})), Value::Bool(true));
    }

    #[test]
    fn hof_map() {
        let r = eval("map([1, 2, 3], fun n -> n * 10)", &json!({}));
        match r {
            Value::List(items) => {
                assert_eq!(items.len(), 3);
                assert_eq!(items[0].as_f64(), Some(10.0));
                assert_eq!(items[1].as_f64(), Some(20.0));
                assert_eq!(items[2].as_f64(), Some(30.0));
            }
            _ => panic!("expected list, got {:?}", r),
        }
    }

    #[test]
    fn hof_filter() {
        let r = eval("filter([1, 2, 3, 4, 5], fun n -> n > 2)", &json!({}));
        match r {
            Value::List(items) => {
                assert_eq!(items.len(), 3);
                assert_eq!(items[0].as_f64(), Some(3.0));
                assert_eq!(items[2].as_f64(), Some(5.0));
            }
            _ => panic!("expected list, got {:?}", r),
        }
    }

    #[test]
    fn hof_with_captured_variable() {
        let r = eval(
            "filter([1, 2, 3, 4], fun n -> n > threshold)",
            &json!({"threshold": 2}),
        );
        match r {
            Value::List(items) => {
                assert_eq!(items.len(), 2);
                assert_eq!(items[0].as_f64(), Some(3.0));
                assert_eq!(items[1].as_f64(), Some(4.0));
            }
            _ => panic!("expected list"),
        }
    }

    // ── Phase 3: path type ─────────────────────────────────────

    #[test]
    fn path_constructor() {
        assert_eq!(eval("path(0, 2, 1)", &json!({})), Value::Path(vec![0, 2, 1]));
    }

    #[test]
    fn path_empty() {
        assert_eq!(eval("path()", &json!({})), Value::Path(vec![]));
    }

    #[test]
    fn path_depth() {
        assert_eq!(eval("path(0, 2, 1).depth", &json!({})), Value::Number(3.0));
        assert_eq!(eval("path().depth", &json!({})), Value::Number(0.0));
    }

    #[test]
    fn path_parent() {
        assert_eq!(eval("path(0, 2, 1).parent", &json!({})), Value::Path(vec![0, 2]));
        assert_eq!(eval("path().parent", &json!({})), Value::Null);
    }

    #[test]
    fn path_id() {
        assert_eq!(eval("path(0, 2, 1).id", &json!({})), Value::Str("0.2.1".to_string()));
        assert_eq!(eval("path().id", &json!({})), Value::Str("".to_string()));
    }

    #[test]
    fn path_indices() {
        let r = eval("path(0, 2, 1).indices", &json!({}));
        match r {
            Value::List(items) => {
                assert_eq!(items.len(), 3);
                assert_eq!(items[0].as_u64(), Some(0));
                assert_eq!(items[1].as_u64(), Some(2));
                assert_eq!(items[2].as_u64(), Some(1));
            }
            _ => panic!("expected list"),
        }
    }

    #[test]
    fn path_equality() {
        assert_eq!(eval("path(0, 2) == path(0, 2)", &json!({})), Value::Bool(true));
        assert_eq!(eval("path(0, 2) == path(0, 3)", &json!({})), Value::Bool(false));
        // Path vs List — distinct types
        assert_eq!(eval("path(0, 2) == [0, 2]", &json!({})), Value::Bool(false));
    }

    #[test]
    fn path_child_fn() {
        assert_eq!(
            eval("path_child(path(0, 2), 5)", &json!({})),
            Value::Path(vec![0, 2, 5])
        );
    }

    #[test]
    fn path_from_id_fn() {
        assert_eq!(eval("path_from_id('0.2.1')", &json!({})), Value::Path(vec![0, 2, 1]));
        assert_eq!(eval("path_from_id('')", &json!({})), Value::Path(vec![]));
        assert_eq!(eval("path_from_id('not-a-path')", &json!({})), Value::Null);
    }

    // ── Phase 3: lexical scoping — closure captures shadowed binding
    //    (PHASE3.md §4.4)

    #[test]
    fn closure_captures_shadowed_binding() {
        // After shadowing x, the closure f must still see the originally
        // captured x (=1), not the new x (=2).
        let r = eval(
            "let x = 1 in let f = fun _ -> x in let x = 2 in f(null)",
            &json!({}),
        );
        assert_eq!(r, Value::Number(1.0));
    }

    #[test]
    fn closure_namespace_refreshed_at_call() {
        // The closure is defined with state.x=5. Caller's ctx has state.x=9
        // at call time. The closure should see 9 (runtime namespace is fresh)
        // even though its captured_ctx had 5.
        // Hard to test fully without a runtime context switch; at least
        // verify that state reads through the closure hit the current ctx.
        let r = eval(
            "let f = fun _ -> state.x in f(null)",
            &json!({"state": {"x": 42}}),
        );
        assert_eq!(r, Value::Number(42.0));
    }
}
