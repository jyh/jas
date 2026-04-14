//! Value types for the expression language.

use std::fmt;

use super::expr_parser::Expr;

/// The value types in the expression language.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Number(f64),
    Str(String),
    Color(String), // normalized #rrggbb
    List(Vec<serde_json::Value>),
    /// Closure: params, body, captured JSON context, and captured local scope.
    Closure {
        params: Vec<String>,
        body: Box<Expr>,
        captured_ctx: serde_json::Value,
        /// Local scope bindings (for closures captured in let-bindings).
        /// Stored as Option<Box<HashMap>> to keep the enum size reasonable.
        captured_scope: Option<Box<std::collections::HashMap<String, Value>>>,
    },
}

impl Value {
    /// Normalize a color string: 3-digit → 6-digit, lowercase.
    pub fn color(s: &str) -> Self {
        let s = s.to_lowercase();
        if s.len() == 4 && s.starts_with('#') {
            let expanded = format!(
                "#{}{}{}{}{}{}",
                &s[1..2], &s[1..2], &s[2..3], &s[2..3], &s[3..4], &s[3..4]
            );
            Value::Color(expanded)
        } else {
            Value::Color(s)
        }
    }

    /// Convert a serde_json::Value to a typed Value.
    pub fn from_json(v: &serde_json::Value) -> Self {
        match v {
            serde_json::Value::Null => Value::Null,
            serde_json::Value::Bool(b) => Value::Bool(*b),
            serde_json::Value::Number(n) => {
                Value::Number(n.as_f64().unwrap_or(0.0))
            }
            serde_json::Value::String(s) => {
                // Detect hex color patterns
                if s.starts_with('#') && (s.len() == 4 || s.len() == 7) {
                    let hex = &s[1..];
                    if hex.chars().all(|c| c.is_ascii_hexdigit()) {
                        return Value::color(s);
                    }
                }
                Value::Str(s.clone())
            }
            serde_json::Value::Array(arr) => {
                Value::List(arr.clone())
            }
            serde_json::Value::Object(_) => {
                // Keep as JSON for property access
                Value::Str(v.to_string())
            }
        }
    }

    /// Bool coercion per spec §4.8.
    pub fn to_bool(&self) -> bool {
        match self {
            Value::Null => false,
            Value::Bool(b) => *b,
            Value::Number(n) => *n != 0.0,
            Value::Str(s) => !s.is_empty(),
            Value::Color(_) => true,
            Value::List(l) => !l.is_empty(),
            Value::Closure { .. } => true,
        }
    }

    /// String coercion for text interpolation.
    pub fn to_string_coerce(&self) -> String {
        match self {
            Value::Null => String::new(),
            Value::Bool(b) => if *b { "true" } else { "false" }.to_string(),
            Value::Number(n) => {
                if *n == (*n as i64) as f64 {
                    format!("{}", *n as i64)
                } else {
                    format!("{}", n)
                }
            }
            Value::Str(s) => s.clone(),
            Value::Color(c) => c.clone(),
            Value::List(_) => "[list]".to_string(),
            Value::Closure { .. } => "[closure]".to_string(),
        }
    }

    /// Check if this value is null.
    pub fn is_null(&self) -> bool {
        matches!(self, Value::Null)
    }

    /// Strict typed equality.
    pub fn strict_eq(&self, other: &Value) -> bool {
        match (self, other) {
            (Value::Null, Value::Null) => true,
            (Value::Bool(a), Value::Bool(b)) => a == b,
            (Value::Number(a), Value::Number(b)) => a == b,
            (Value::Str(a), Value::Str(b)) => a == b,
            (Value::Color(a), Value::Color(b)) => {
                normalize_color(a) == normalize_color(b)
            }
            _ => false, // different types → false
        }
    }
}

fn normalize_color(c: &str) -> String {
    let c = c.to_lowercase();
    if c.len() == 4 && c.starts_with('#') {
        format!(
            "#{}{}{}{}{}{}",
            &c[1..2], &c[1..2], &c[2..3], &c[2..3], &c[3..4], &c[3..4]
        )
    } else {
        c
    }
}

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_string_coerce())
    }
}
