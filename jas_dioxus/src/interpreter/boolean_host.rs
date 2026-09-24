//! The Boolean panel's 14 effect keys, web-free (W2b-13).
//!
//! Before this module the web handled these keys in `renderer.rs`, through
//! three `AppState` functions, so the engine refused every Boolean button
//! with `UnknownEffect`. The functions read nothing but the model and five
//! option fields, which the engine store already holds as `state.boolean_*`.
//! So they are EXTRACTED here. The web's `AppState` functions call [`run`]
//! with the options of its own panel mirror, and the engine's `EngineHost`
//! calls it with [`options_from_store`].
//!
//! ⛔ S7: [`run`] NEVER BRACKETS. Its `Controller` callees self-bracket when
//! no transaction is open and JOIN one that is. So the web keeps its own
//! `with_txn` (one undo step for the op plus its optional simplify), and on
//! the engine path the batch's `snapshot` owns the step.
//!
//! Not here: the panel MENU's four keys (make, release, repeat, reset) and
//! `open_boolean_options`. No button reaches them (census 2b-iii §3a).

use serde_json::Value;

use crate::document::controller::{BooleanOptions, Controller};
use crate::document::model::Model;
use crate::geometry::live::CompoundOperation;

use super::state_store::StateStore;

/// The keys [`run`] hosts: 9 destructive, 4 compound-creating, and expand.
pub const KEYS: [&str; 14] = [
    "boolean_union", "boolean_subtract_front", "boolean_intersection", "boolean_exclude",
    "boolean_divide", "boolean_trim", "boolean_merge", "boolean_crop", "boolean_subtract_back",
    "boolean_union_compound", "boolean_subtract_front_compound",
    "boolean_intersection_compound", "boolean_exclude_compound",
    "expand_compound_shape",
];

const DESTRUCTIVE: [&str; 9] = ["union", "subtract_front", "intersection", "exclude",
                                "divide", "trim", "merge", "crop", "subtract_back"];

/// What one key does.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum BooleanKey {
    /// `boolean_<op>`: the op name `Controller::apply_destructive_boolean` takes.
    Destructive(&'static str),
    /// `boolean_<op>_compound`: a live compound shape (Alt+click on a shape mode).
    Compound(CompoundOperation),
    /// `expand_compound_shape`.
    Expand,
}

impl BooleanKey {
    pub fn from_key(key: &str) -> Option<Self> {
        if key == "expand_compound_shape" {
            return Some(Self::Expand);
        }
        let op = key.strip_prefix("boolean_")?;
        if let Some(base) = op.strip_suffix("_compound") {
            return Some(Self::Compound(match base {
                "union" => CompoundOperation::Union,
                "subtract_front" => CompoundOperation::SubtractFront,
                "intersection" => CompoundOperation::Intersection,
                "exclude" => CompoundOperation::Exclude,
                _ => return None,
            }));
        }
        DESTRUCTIVE.iter().find(|d| **d == op).map(|d| Self::Destructive(d))
    }
}

/// The five Boolean Options, as the engine store holds them (`state.boolean_*`,
/// seeded from the bundle). An absent or mistyped key takes the default, which
/// is the bundle's default.
pub fn options_from_store(store: &StateStore) -> BooleanOptions {
    let d = BooleanOptions::default();
    let num = |k: &str, dv: f64| store.get(k).as_f64().unwrap_or(dv);
    let flag = |k: &str, dv: bool| match store.get(k) {
        Value::Bool(b) => *b,
        _ => dv,
    };
    BooleanOptions {
        precision: num("boolean_precision", d.precision),
        remove_redundant_points: flag("boolean_remove_redundant_points", d.remove_redundant_points),
        divide_remove_unpainted: flag("boolean_divide_remove_unpainted", d.divide_remove_unpainted),
        apply_simplify_after_op: flag("boolean_apply_simplify_after_op", d.apply_simplify_after_op),
        simplify_precision: num("boolean_simplify_precision", d.simplify_precision),
    }
}

/// Run `key` on the model's selection. Returns false for a key this module
/// does not host. Never opens or closes a transaction (S7).
pub fn run(model: &mut Model, key: &str, options: &BooleanOptions) -> bool {
    match BooleanKey::from_key(key) {
        Some(BooleanKey::Destructive(op)) => {
            Controller::apply_destructive_boolean(model, op, options);
            // Post-op auto-simplify: the same path as Object > Simplify, on
            // the op's output, which the op leaves selected.
            if options.apply_simplify_after_op {
                Controller::simplify_selection(model, options.simplify_precision);
            }
        }
        Some(BooleanKey::Compound(op)) => Controller::make_compound_shape_with_op(model, op),
        Some(BooleanKey::Expand) => Controller::expand_compound_shape(model),
        None => return false,
    }
    true
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::document::controller::{BooleanOptions, Controller};
    use crate::document::model::Model;
    use crate::geometry::element::Element;
    use crate::interpreter::state_store::StateStore;
    use crate::document::test_fixture::{model_with, rect};

    /// Two OVERLAPPING squares, both selected, so every operation has
    /// something to do.
    fn overlapping() -> Model {
        model_with(vec![rect(0.0, 0.0, 10.0, 10.0), rect(5.0, 5.0, 10.0, 10.0)], &[0, 1])
    }

    fn top_level(m: &Model) -> Vec<Element> {
        match &m.document().layers[0] {
            Element::Layer(l) => l.children.iter().map(|c| (**c).clone()).collect(),
            other => panic!("not a layer: {other:?}"),
        }
    }

    /// The document's test-JSON with every minted id blanked: the engine and
    /// the oracle mint from entropy, so ids differ by construction (S6).
    fn shape(m: &Model) -> String {
        let j = crate::geometry::test_json::document_to_test_json(m.document());
        let mut out = String::new();
        let mut rest = j.as_str();
        while let Some(i) = rest.find("\"id\":\"") {
            out.push_str(&rest[..i + 6]);
            rest = &rest[i + 6..];
            let end = rest.find('"').expect("a closed id string");
            rest = &rest[end..];
        }
        out.push_str(rest);
        out
    }

    #[test]
    fn the_fourteen_keys_are_classified_and_nothing_else_is() {
        let destructive = ["union", "subtract_front", "intersection", "exclude",
                           "divide", "trim", "merge", "crop", "subtract_back"];
        let compound = ["union", "subtract_front", "intersection", "exclude"];
        for op in destructive {
            assert_eq!(BooleanKey::from_key(&format!("boolean_{op}")),
                       Some(BooleanKey::Destructive(op)), "{op}");
        }
        for op in compound {
            assert!(matches!(BooleanKey::from_key(&format!("boolean_{op}_compound")),
                             Some(BooleanKey::Compound(_))), "{op}");
        }
        assert_eq!(BooleanKey::from_key("expand_compound_shape"), Some(BooleanKey::Expand));
        assert_eq!(KEYS.len(), 14);
        assert!(KEYS.iter().all(|k| BooleanKey::from_key(k).is_some()));
        for no in ["boolean_divide_compound", "boolean_", "make_compound_shape",
                   "repeat_boolean_operation", "boolean_union_x"] {
            assert_eq!(BooleanKey::from_key(no), None, "{no}");
        }
    }

    #[test]
    fn options_come_from_the_stores_five_keys_and_fall_back_to_the_defaults() {
        assert_eq!(options_from_store(&StateStore::new()), BooleanOptions::default());
        let mut s = StateStore::new();
        s.set("boolean_precision", json!(0.5));
        s.set("boolean_remove_redundant_points", json!(true));
        s.set("boolean_divide_remove_unpainted", json!(true));
        s.set("boolean_apply_simplify_after_op", json!(true));
        s.set("boolean_simplify_precision", json!(2));
        let o = options_from_store(&s);
        assert_eq!(o, BooleanOptions { precision: 0.5, remove_redundant_points: true,
                                       divide_remove_unpainted: true,
                                       apply_simplify_after_op: true, simplify_precision: 2.0 });
    }

    /// THE ORACLE: the web's own path, `Controller::apply_destructive_boolean`
    /// on a clone, then `simplify_selection` when the flag is set. Ids blanked.
    #[test]
    fn a_destructive_key_equals_the_controller_path_with_and_without_simplify() {
        for simplify in [false, true] {
            let opts = BooleanOptions { apply_simplify_after_op: simplify, ..Default::default() };
            for op in ["union", "intersection", "divide"] {
                let mut m = overlapping();
                let mut oracle = overlapping();
                assert!(run(&mut m, &format!("boolean_{op}"), &opts));
                oracle.with_txn(|o| {
                    Controller::apply_destructive_boolean(o, op, &opts);
                    if simplify {
                        Controller::simplify_selection(o, opts.simplify_precision);
                    }
                });
                assert_eq!(shape(&m), shape(&oracle), "{op} simplify={simplify}");
                assert_ne!(shape(&m), shape(&overlapping()), "{op}: nothing happened");
            }
        }
    }

    #[test]
    fn a_compound_key_makes_a_live_shape_and_expand_removes_it() {
        let mut m = overlapping();
        assert!(run(&mut m, "boolean_union_compound", &BooleanOptions::default()));
        assert!(top_level(&m).iter().any(|e| matches!(e, Element::Live(_))), "no compound made");
        assert!(run(&mut m, "expand_compound_shape", &BooleanOptions::default()));
        assert!(!top_level(&m).iter().any(|e| matches!(e, Element::Live(_))), "not expanded");
    }

    /// S7: a host function never brackets. Inside a caller's open
    /// transaction it JOINS it, so the caller still owns the step.
    #[test]
    fn a_host_run_inside_an_open_transaction_leaves_it_open() {
        for key in ["boolean_union", "boolean_union_compound"] {
            let mut m = overlapping();
            m.begin_txn();
            assert!(run(&mut m, key, &BooleanOptions::default()));
            assert!(m.in_txn(), "{key} closed its caller's transaction");
            m.commit_txn();
        }
    }

    #[test]
    fn an_unknown_key_is_declined_and_changes_nothing() {
        let mut m = overlapping();
        let before = shape(&m);
        assert!(!run(&mut m, "boolean_nope", &BooleanOptions::default()));
        assert_eq!(shape(&m), before);
    }
}
