//! Immutable lexical scope for expression evaluation.
//!
//! Bindings are stored as an immutable map. New scopes are created via
//! `extend()` (push child scope) or `merge()` (add bindings at same level).
//! The scope chain implements static scoping — inner scopes shadow outer
//! bindings without mutating them.

use std::collections::HashMap;
use std::sync::Arc;

/// Immutable lexical scope with parent chain.
#[derive(Clone, Debug)]
pub struct Scope {
    bindings: Arc<HashMap<String, serde_json::Value>>,
    parent: Option<Arc<Scope>>,
}

impl Scope {
    /// Create a scope from bindings with an optional parent.
    pub fn new(bindings: HashMap<String, serde_json::Value>) -> Self {
        Scope {
            bindings: Arc::new(bindings),
            parent: None,
        }
    }

    /// Create a scope from a serde_json::Value (must be an Object).
    pub fn from_json(ctx: &serde_json::Value) -> Self {
        let map = ctx.as_object()
            .map(|m| m.iter().map(|(k, v)| (k.clone(), v.clone())).collect())
            .unwrap_or_default();
        Self::new(map)
    }

    /// Resolve a top-level key through the scope chain.
    pub fn get(&self, key: &str) -> Option<&serde_json::Value> {
        if let Some(v) = self.bindings.get(key) {
            return Some(v);
        }
        if let Some(ref parent) = self.parent {
            return parent.get(key);
        }
        None
    }

    /// Push a child scope. Self becomes the parent.
    pub fn extend(&self, bindings: HashMap<String, serde_json::Value>) -> Self {
        Scope {
            bindings: Arc::new(bindings),
            parent: Some(Arc::new(self.clone())),
        }
    }

    /// Merge: create a new scope at the same level with additional bindings.
    pub fn merge(&self, extra: HashMap<String, serde_json::Value>) -> Self {
        let mut merged: HashMap<String, serde_json::Value> = (*self.bindings).clone();
        merged.extend(extra);
        Scope {
            bindings: Arc::new(merged),
            parent: self.parent.clone(),
        }
    }

    /// Flatten the scope chain to a serde_json::Value Object.
    pub fn to_json(&self) -> serde_json::Value {
        let mut map = if let Some(ref parent) = self.parent {
            match parent.to_json() {
                serde_json::Value::Object(m) => m,
                _ => serde_json::Map::new(),
            }
        } else {
            serde_json::Map::new()
        };
        for (k, v) in self.bindings.iter() {
            map.insert(k.clone(), v.clone());
        }
        serde_json::Value::Object(map)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lookup() {
        let s = Scope::new(HashMap::from([
            ("x".into(), serde_json::json!(1)),
        ]));
        assert_eq!(s.get("x"), Some(&serde_json::json!(1)));
        assert_eq!(s.get("y"), None);
    }

    #[test]
    fn extend_and_shadow() {
        let parent = Scope::new(HashMap::from([
            ("x".into(), serde_json::json!(1)),
        ]));
        let child = parent.extend(HashMap::from([
            ("x".into(), serde_json::json!(99)),
            ("y".into(), serde_json::json!(2)),
        ]));
        assert_eq!(child.get("x"), Some(&serde_json::json!(99)));
        assert_eq!(child.get("y"), Some(&serde_json::json!(2)));
        // Parent unchanged
        assert_eq!(parent.get("x"), Some(&serde_json::json!(1)));
        assert_eq!(parent.get("y"), None);
    }

    #[test]
    fn merge_preserves_parent() {
        let parent = Scope::new(HashMap::from([("a".into(), serde_json::json!(1))]));
        let child = Scope {
            bindings: Arc::new(HashMap::from([("b".into(), serde_json::json!(2))])),
            parent: Some(Arc::new(parent)),
        };
        let merged = child.merge(HashMap::from([("c".into(), serde_json::json!(3))]));
        assert_eq!(merged.get("a"), Some(&serde_json::json!(1)));
        assert_eq!(merged.get("b"), Some(&serde_json::json!(2)));
        assert_eq!(merged.get("c"), Some(&serde_json::json!(3)));
    }

    #[test]
    fn to_json_flattens() {
        let root = Scope::new(HashMap::from([("state".into(), serde_json::json!({"x": 1}))]));
        let child = root.extend(HashMap::from([("lib".into(), serde_json::json!({"id": "web"}))]));
        let j = child.to_json();
        assert_eq!(j["state"]["x"], serde_json::json!(1));
        assert_eq!(j["lib"]["id"], serde_json::json!("web"));
    }

    #[test]
    fn sibling_scopes_independent() {
        let root = Scope::new(HashMap::from([("x".into(), serde_json::json!(0))]));
        let a = root.extend(HashMap::from([("item".into(), serde_json::json!("a"))]));
        let b = root.extend(HashMap::from([("item".into(), serde_json::json!("b"))]));
        assert_eq!(a.get("item"), Some(&serde_json::json!("a")));
        assert_eq!(b.get("item"), Some(&serde_json::json!("b")));
        assert_eq!(root.get("item"), None);
    }
}
