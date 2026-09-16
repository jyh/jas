//! A widget's BEHAVIOR, run in the engine (FB wave 2, A6).
//!
//! The shell reports what the user did to a control — `{"widget":
//! "align_left_button", "event": "click"}` — and the engine runs what the
//! panel spec declares for it, against the engine's own store and document.
//! The shell never sees a behavior, an action, an expression or an effect.
//!
//! RED-FIRST STUB: the arms below and in `ffi.rs` are written against this
//! shape before it does anything.

use serde_json::Value;

use crate::document::model::Model;
use crate::interpreter::effects::EffectHost;
use crate::interpreter::state_store::StateStore;

/// The colour panel's id. Its state lives in `PanelState`, not in the store.
pub const COLOUR_PANEL: &str = "color_panel_content";

/// Why a behavior did not run. `class` is the `panel_event` field of
/// `jas_last_error_json`, and `detail` its `detail`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub class: &'static str,
    pub detail: String,
}

/// What a behavior that ran did to the document.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ran {
    pub doc_changed: bool,
}

/// The shell's report of one act on one control.
#[derive(Debug, Clone, PartialEq)]
pub struct UserEvent {
    pub widget: String,
    pub event: String,
    /// `event.alt` / `event.shift` / `event.meta` / `event.ctrl`.
    pub modifiers: Value,
}

/// Read the shell's event JSON.
pub fn parse_event(_v: &Value) -> Result<UserEvent, Refusal> {
    Err(Refusal { class: "Stub", detail: String::new() })
}

/// The engine's own effects.
pub struct EngineHost {
    pub artboard_selection: Vec<String>,
}

impl EffectHost for EngineHost {
    fn run(
        &mut self,
        _key: &str,
        _arg: &Value,
        _store: &mut StateStore,
        _model: Option<&mut Model>,
    ) -> bool {
        false
    }
}

/// Run the behavior `ev` names, on panel `panel_id` whose spec is `spec`.
#[allow(clippy::too_many_arguments)]
pub fn run_widget_behavior(
    _panel_id: &str,
    _spec: &Value,
    _ev: &UserEvent,
    _scope: &Value,
    _store: &mut StateStore,
    _model: &mut Model,
    _actions: &Value,
    _dialogs: &Value,
    _host: &mut dyn EffectHost,
) -> Result<Ran, Refusal> {
    Err(Refusal { class: "Stub", detail: String::new() })
}

/// Document fixtures shared by this module's arms and the ABI's.
#[cfg(test)]
pub(crate) mod test_fixture {
    use crate::document::document::{Document, ElementSelection};
    use crate::document::model::Model;
    use crate::geometry::element::{Color, CommonProps, Element, Fill, LayerElem, RectElem};

    pub(crate) fn rect(x: f64, y: f64, w: f64, h: f64) -> Element {
        Element::Rect(RectElem {
            x, y, width: w, height: h, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        })
    }

    /// One layer holding `rects`, with `selected` (child indices) selected.
    /// Seeded unbracketed, so the model starts with nothing to undo.
    pub(crate) fn model_with(rects: Vec<Element>, selected: &[usize]) -> Model {
        let layer = Element::Layer(LayerElem {
            children: rects.into_iter().map(std::rc::Rc::new).collect(),
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { name: Some("L".into()), ..Default::default() },
        });
        let selection = selected.iter().map(|&i| ElementSelection::all(vec![0, i])).collect();
        let doc = Document { layers: vec![layer], selected_layer: 0, selection,
                             ..Document::default() };
        let mut model = Model::default();
        model.set_document_for_test(doc);
        model
    }

    /// Two rects at different x and y, both selected unless told otherwise.
    pub(crate) fn misaligned(selected: &[usize]) -> Model {
        model_with(vec![rect(10.0, 0.0, 5.0, 5.0), rect(40.0, 20.0, 5.0, 5.0)], selected)
    }
}

#[cfg(test)]
mod tests {
    use super::test_fixture::misaligned;
    use super::*;
    use crate::interpreter::workspace::Workspace;
    use serde_json::json;

    fn click(widget: &str, alt: bool) -> UserEvent {
        parse_event(&json!({"widget": widget, "event": "click", "alt": alt}))
            .expect("a well-formed click parses")
    }

    fn scope_with_selection(n: usize) -> Value {
        json!({"state": {}, "panel": {}, "active_document": {"selection_count": n}})
    }

    fn run(panel: &str, ev: &UserEvent, model: &mut Model, host: &mut dyn EffectHost)
        -> Result<Ran, Refusal>
    {
        let ws = Workspace::load().expect("workspace loads");
        let spec = ws.panel(panel).expect("panel exists");
        let mut store = StateStore::new();
        let n = model.document().selection.len();
        run_widget_behavior(panel, spec, ev, &scope_with_selection(n), &mut store, model,
                            ws.actions(), ws.dialogs(), host)
    }

    /// A host that runs the engine's effects and ALSO claims one more key,
    /// doing nothing with it. Q5's control: the refusal is about the host.
    struct EnginePlus {
        engine: EngineHost,
        extra: &'static str,
        ran_extra: usize,
    }

    impl EffectHost for EnginePlus {
        fn run(&mut self, key: &str, arg: &Value, store: &mut StateStore,
               model: Option<&mut Model>) -> bool {
            if key == self.extra {
                self.ran_extra += 1;
                return true;
            }
            self.engine.run(key, arg, store, model)
        }
    }

    #[test]
    fn an_unhosted_key_is_refused_and_the_same_batch_runs_once_a_host_claims_it() {
        let ev = click("boolean_union_button", false);
        let mut model = misaligned(&[0, 1]);
        let json = |m: &Model| crate::geometry::test_json::document_to_test_json(m.document());
        let before = json(&model);
        let refused = run("boolean_panel_content", &ev, &mut model,
                          &mut EngineHost { artboard_selection: vec![] });
        assert_eq!(refused, Err(Refusal { class: "PlatformEffect",
                                          detail: "UnknownEffect:boolean_union".into() }));
        assert_eq!(json(&model), before, "a refused batch changed the document");
        assert!(!model.in_txn(), "a refused batch left a transaction open");

        let mut plus = EnginePlus { engine: EngineHost { artboard_selection: vec![] },
                                    extra: "boolean_union", ran_extra: 0 };
        let ran = run("boolean_panel_content", &ev, &mut model, &mut plus);
        assert!(ran.is_ok(), "the same batch with the key hosted must run: {ran:?}");
        // Once in the pre-flight and once for real.
        assert_eq!(plus.ran_extra, 2);
        assert!(!model.in_txn(), "the hosted snapshot's transaction was left open");
    }

    #[test]
    fn a_behavior_condition_routes_on_the_event_modifiers() {
        // boolean.yaml gives the Union button two click behaviors, split on
        // `event.alt`. Both are unhosted, so the refusal NAMES the one that
        // was chosen; a runner that ignored `condition` would run both and
        // name the first.
        let mut model = misaligned(&[0, 1]);
        let host = &mut EngineHost { artboard_selection: vec![] };
        let plain = run("boolean_panel_content", &click("boolean_union_button", false),
                        &mut model, &mut *host);
        let alt = run("boolean_panel_content", &click("boolean_union_button", true),
                      &mut model, &mut *host);
        assert_eq!(plain.unwrap_err().detail, "UnknownEffect:boolean_union");
        assert_eq!(alt.unwrap_err().detail, "UnknownEffect:boolean_union_compound");
    }

    #[test]
    fn an_event_parses_with_its_defaults_and_refuses_without_a_widget() {
        let ev = parse_event(&json!({"widget": "w"})).expect("parses");
        assert_eq!(ev.widget, "w");
        assert_eq!(ev.event, "click", "a behavior's own default event is click");
        assert_eq!(ev.modifiers, json!({"alt": false, "shift": false, "meta": false,
                                        "ctrl": false}));
        let ev = parse_event(&json!({"widget": "w", "event": "double_click", "shift": true}))
            .expect("parses");
        assert_eq!(ev.event, "double_click");
        assert_eq!(ev.modifiers["shift"], json!(true));
        assert_eq!(parse_event(&json!({"event": "click"})),
                   Err(Refusal { class: "MissingTarget", detail: String::new() }));
        assert_eq!(parse_event(&json!(["not", "an", "object"])),
                   Err(Refusal { class: "BadJson", detail: String::new() }));
    }

    #[test]
    fn the_engine_host_runs_a_snapshot_and_the_align_keys_and_declines_the_rest() {
        let mut host = EngineHost { artboard_selection: vec![] };
        let mut store = StateStore::new();
        let mut model = misaligned(&[0, 1]);
        assert!(host.run("snapshot", &Value::Null, &mut store, Some(&mut model)));
        assert!(model.in_txn(), "snapshot opens the transaction, as the web path's does");
        assert!(host.run("align_left", &json!(true), &mut store, Some(&mut model)));
        model.commit_txn();
        assert!(model.can_undo(), "the align move landed in the transaction");
        for declined in ["boolean_union", "set", "doc.snapshot", "zz_planted"] {
            assert!(!host.run(declined, &Value::Null, &mut store, Some(&mut model)),
                    "the engine host claimed {declined}");
        }
    }

    /// D3: the pre-flight runs a batch on CLONES of the model and the store,
    /// and that is sound only while no panel behavior reaches an effect whose
    /// state lives outside both. The runner's only such arms write the
    /// thread-local point and anchor buffers (`buffer.*`, `anchor.*`).
    #[test]
    fn no_panel_behavior_reaches_an_effect_that_writes_outside_the_model_and_store() {
        let ws = Workspace::load().expect("workspace loads");
        let actions = ws.actions();
        let mut found: Vec<String> = vec![];
        let mut walked = 0usize;
        fn effect_keys(v: &Value, actions: &Value, seen: &mut Vec<String>, out: &mut Vec<String>,
                       walked: &mut usize) {
            match v {
                Value::Array(items) => {
                    for i in items {
                        effect_keys(i, actions, seen, out, walked);
                    }
                }
                Value::Object(m) => {
                    for (k, arg) in m {
                        *walked += 1;
                        if k.starts_with("buffer.") || k.starts_with("anchor.") {
                            out.push(k.clone());
                        }
                        if k == "dispatch" {
                            let name = arg.as_str()
                                .or_else(|| arg.get("action").and_then(Value::as_str))
                                .unwrap_or("");
                            if !seen.iter().any(|s| s == name) {
                                seen.push(name.to_string());
                                if let Some(body) = actions.get(name).and_then(|a| a.get("effects")) {
                                    effect_keys(body, actions, seen, out, walked);
                                }
                            }
                        }
                        effect_keys(arg, actions, seen, out, walked);
                    }
                }
                _ => {}
            }
        }
        fn behaviors(n: &Value, out: &mut Vec<Value>) {
            match n {
                Value::Object(m) => {
                    if let Some(Value::Array(bs)) = m.get("behavior") {
                        out.extend(bs.iter().cloned());
                    }
                    m.values().for_each(|c| behaviors(c, out));
                }
                Value::Array(a) => a.iter().for_each(|c| behaviors(c, out)),
                _ => {}
            }
        }
        let panels = ws.data()["panels"].as_object().expect("panels");
        let mut bs = vec![];
        for p in panels.values() {
            behaviors(p, &mut bs);
        }
        let mut seen = vec![];
        for b in &bs {
            if let Some(action) = b.get("action").and_then(Value::as_str) {
                effect_keys(&json!({"dispatch": action}), actions, &mut seen, &mut found,
                            &mut walked);
            }
            if let Some(effects) = b.get("effects") {
                effect_keys(effects, actions, &mut seen, &mut found, &mut walked);
            }
        }
        // Anti-vacuity: the census W2-0 ran walked 177 behaviors.
        assert!(bs.len() >= 177, "the walk found only {} behaviors", bs.len());
        assert!(walked > bs.len(), "the walk read no effect keys ({walked})");
        assert!(seen.len() > 10, "the walk followed only {} dispatches", seen.len());
        assert_eq!(found, Vec::<String>::new(),
                   "a panel behavior reaches a thread-local effect; the dry run is unsound");
    }
}
