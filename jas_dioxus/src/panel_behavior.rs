//! A widget's BEHAVIOR, run in the engine (FB wave 2, A6).
//!
//! The shell reports what the user did to a control, as
//! `{"widget": "align_left_button", "event": "click", "alt": false}`. The engine
//! runs what the panel spec declares for that event, against its own store and
//! document. The shell never sees a behavior, an action, an expression or an
//! effect.
//!
//! # The order, and why each step is where it is
//!
//! 1. **The widget is found, or refused by name.** Refusals: `PanelNotHosted`
//!    (the colour panel's state is not in the store), `MissingTarget`, and
//!    `NotAddressable` (a widget under a `foreach`: its id names a template,
//!    not one row).
//! 2. **`disabled` is evaluated in the engine's scope**, and a disabled widget
//!    is refused as `Disabled`. The web app never gets this far, because the
//!    browser does not deliver a click to a disabled button. The engine has no
//!    DOM to do that for it.
//! 3. **The behaviors for the event are chosen**, each by its `condition`,
//!    against the scope plus `event.{alt,shift,meta,ctrl}`, as the web click
//!    handler does (`renderer.rs`, `build_mouse_event_handler`). Their effects,
//!    and then their action as a `dispatch`, form ONE batch. No behavior, or one
//!    with no body, is refused as `EmptyBehavior`.
//! 4. **PRE-FLIGHT.** The batch runs on CLONES of the store and the model. If
//!    the report names anything, NOTHING runs, and the refusal is
//!    `PlatformEffect` with `<Kind>:<payload>` of the first item. A
//!    half-applied behavior is worse than a refused one. The dry run is exact
//!    for THIS click: the report is dynamic, and a clone is the real state.
//!    ⛔ It is sound only because no panel behavior reaches an effect whose
//!    state lives outside the model and the store. An arm below walks every
//!    panel and fails if one ever does.
//! 5. **The batch runs for real**, and the runner's owner rule makes it one
//!    undo step. The host runs `snapshot` as `begin_txn`, as the web renderer
//!    does, so the step is named by the action that opened it.
//!
//! # What this does NOT do, stated as negatives
//!
//! * `init:` is not evaluated when a panel's store scope is seeded (the web
//!   app does not evaluate it either). Align's `init:` only mirrors
//!   `state.yaml` defaults that agree with its own.
//! * A behavior's `params` go to the runner, which evaluates them. The web
//!   click handler resolves them first, against the render scope. The two agree
//!   on a bare identifier (`dispatch_param_value`), and they are not otherwise
//!   compared.
//! * There is no Artboards panel selection in the engine, so Artboard mode
//!   aligns to the FIRST artboard (`EngineHost::artboard_selection` is `[]`).
//! * A behavior that WRITES one of the colour slice's three `state.*` keys
//!   writes the store's copy only. No align behavior does.

use serde_json::{json, Map, Value};

use crate::document::model::Model;
use crate::interpreter::align_host::{self, AlignInput};
use crate::interpreter::effects::{run_effects_hosted, EffectHost, Unhandled};
use crate::interpreter::expr::eval;
use crate::interpreter::state_store::StateStore;
pub use crate::panel_scope::COLOUR_PANEL;

/// The Align panel's id. Its store scope is where [`EngineHost`] reads the
/// align settings, whichever panel's behavior dispatched the operation.
pub const ALIGN_PANEL: &str = "align_panel_content";

/// Why a behavior did not run. `class` is the `panel_event` field of
/// `jas_last_error_json`, and `detail` its `detail`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub class: &'static str,
    pub detail: String,
}

impl Refusal {
    fn new(class: &'static str, detail: impl Into<String>) -> Self {
        Refusal { class, detail: detail.into() }
    }
}

/// What a behavior that ran changed. Both halves, because a click can move
/// the engine's state and leave the document alone (an Align-To toggle on a
/// closed panel), and that is not "nothing happened".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ran {
    pub doc_changed: bool,
    /// The store read differently after the run: global state, the panel's
    /// own state, a dialog.
    pub state_changed: bool,
}

/// The shell's report of one act on one control.
#[derive(Debug, Clone, PartialEq)]
pub struct UserEvent {
    pub widget: String,
    pub event: String,
    /// `event.alt` / `event.shift` / `event.meta` / `event.ctrl`, the names the
    /// web click handler gives a behavior's `condition`.
    pub modifiers: Value,
}

/// Read the shell's event JSON. `event` defaults to `click`, as a behavior's
/// own `event` does; each modifier defaults to `false`.
pub fn parse_event(v: &Value) -> Result<UserEvent, Refusal> {
    let Some(obj) = v.as_object() else {
        return Err(Refusal::new("BadJson", ""));
    };
    let widget = obj.get("widget").and_then(Value::as_str).unwrap_or("");
    if widget.is_empty() {
        return Err(Refusal::new("MissingTarget", ""));
    }
    let event = obj.get("event").and_then(Value::as_str).unwrap_or("click");
    let flag = |k: &str| Value::Bool(obj.get(k).and_then(Value::as_bool).unwrap_or(false));
    Ok(UserEvent {
        widget: widget.to_string(),
        event: event.to_string(),
        modifiers: json!({"alt": flag("alt"), "shift": flag("shift"),
                          "meta": flag("meta"), "ctrl": flag("ctrl")}),
    })
}

/// The engine's own effects: the ones the web renderer runs outside the
/// effects runner, for the panels wave 2a hosts.
///
/// * `snapshot` opens the transaction (`renderer.rs`, both spellings).
/// * The fourteen Align operations run through `align_host`, the one
///   implementation the web app calls too.
///
/// Everything else is declined, so the runner reports it.
pub struct EngineHost {
    pub artboard_selection: Vec<String>,
}

impl EffectHost for EngineHost {
    fn run(
        &mut self,
        key: &str,
        _arg: &Value,
        store: &mut StateStore,
        model: Option<&mut Model>,
    ) -> bool {
        let Some(model) = model else { return false };
        if key == "snapshot" {
            model.begin_txn();
            return true;
        }
        if align_host::hosts(key) {
            let input = AlignInput::from_panel_state(store, ALIGN_PANEL,
                                                     self.artboard_selection.clone());
            align_host::apply_align_operation(model, key, &input);
            return true;
        }
        false
    }
}

/// `<Kind>:<payload>`, the refusal detail for one report item.
fn unhandled_detail(u: &Unhandled) -> String {
    let (kind, payload) = match u {
        Unhandled::UnknownEffect(s) => ("UnknownEffect", s),
        Unhandled::UnknownDocEffect(s) => ("UnknownDocEffect", s),
        Unhandled::NoModel(s) => ("NoModel", s),
        Unhandled::BareString(s) => ("BareString", s),
        Unhandled::NotAnEffect(s) => ("NotAnEffect", s),
        Unhandled::Logged(s) => ("Logged", s),
        Unhandled::UnknownAction(s) => ("UnknownAction", s),
        Unhandled::EmptyAction(s) => ("EmptyAction", s),
        Unhandled::UnknownDialog(s) => ("UnknownDialog", s),
    };
    format!("{kind}:{payload}")
}

/// The first node with id `widget` under `node`, and whether it sits under a
/// `foreach`. First wins, as `panel_scope::binding_of` has it.
fn find_widget<'a>(node: &'a Value, widget: &str, in_foreach: bool) -> Option<(&'a Value, bool)> {
    if node.get("id").and_then(Value::as_str) == Some(widget) {
        return Some((node, in_foreach));
    }
    let under = in_foreach || node.get("foreach").is_some();
    for k in ["children", "do"] {
        match node.get(k) {
            Some(Value::Array(items)) => {
                for c in items {
                    if let Some(hit) = find_widget(c, widget, under) {
                        return Some(hit);
                    }
                }
            }
            Some(c @ Value::Object(_)) => {
                if let Some(hit) = find_widget(c, widget, under) {
                    return Some(hit);
                }
            }
            _ => {}
        }
    }
    None
}

/// Run the behavior `ev` names, on panel `panel_id` whose spec is `spec`,
/// with `scope` the engine's scope for that panel. See the module doc for the
/// order of the steps.
#[allow(clippy::too_many_arguments)]
pub fn run_widget_behavior(
    panel_id: &str,
    spec: &Value,
    ev: &UserEvent,
    scope: &Value,
    store: &mut StateStore,
    model: &mut Model,
    actions: &Value,
    dialogs: &Value,
    host: &mut dyn EffectHost,
) -> Result<Ran, Refusal> {
    if panel_id == COLOUR_PANEL {
        return Err(Refusal::new("PanelNotHosted", panel_id));
    }
    let content = spec.get("content").unwrap_or(&Value::Null);
    let Some((node, in_foreach)) = find_widget(content, &ev.widget, false) else {
        return Err(Refusal::new("MissingTarget", ev.widget.clone()));
    };
    if in_foreach {
        return Err(Refusal::new("NotAddressable", ev.widget.clone()));
    }
    if let Some(expr) = node.get("bind").and_then(|b| b.get("disabled")).and_then(Value::as_str) {
        if eval(expr, scope).to_bool() {
            return Err(Refusal::new("Disabled", ev.widget.clone()));
        }
    }

    let mut cond_scope = scope.clone();
    if let Some(m) = cond_scope.as_object_mut() {
        m.insert("event".into(), ev.modifiers.clone());
    }
    let mut batch: Vec<Value> = vec![];
    let mut chosen = 0usize;
    for b in node.get("behavior").and_then(Value::as_array).into_iter().flatten() {
        if b.get("event").and_then(Value::as_str).unwrap_or("click") != ev.event {
            continue;
        }
        if let Some(cond) = b.get("condition").and_then(Value::as_str) {
            if !eval(cond, &cond_scope).to_bool() {
                continue;
            }
        }
        chosen += 1;
        let effects = b.get("effects").and_then(Value::as_array);
        let action = b.get("action").and_then(Value::as_str);
        if effects.map_or(true, |e| e.is_empty()) && action.is_none() {
            return Err(Refusal::new("EmptyBehavior", ev.widget.clone()));
        }
        batch.extend(effects.into_iter().flatten().cloned());
        if let Some(action) = action {
            let mut d = Map::new();
            d.insert("action".into(), Value::String(action.to_string()));
            if let Some(params) = b.get("params") {
                d.insert("params".into(), params.clone());
            }
            batch.push(json!({"dispatch": Value::Object(d)}));
        }
    }
    if chosen == 0 {
        return Err(Refusal::new("EmptyBehavior", ev.widget.clone()));
    }

    // The runner reads `state` and `panel` from the STORE, live, so a `set`
    // early in the batch is seen by an expression later in it. The context
    // carries only what the store does not hold.
    let ctx = json!({
        "active_document": scope.get("active_document").cloned().unwrap_or(Value::Null),
        "event": ev.modifiers.clone(),
    });
    // `set_panel_state` writes the ACTIVE panel. It is set on the copy for the
    // pre-flight and on the live store only once the pre-flight passes: a
    // refusal changes nothing, not even which panel is active.
    let mut dry_store = store.clone();
    dry_store.set_active_panel(Some(panel_id));
    let mut dry_model = model.clone();
    let preflight = run_effects_hosted(&batch, &ctx, &mut dry_store, Some(&mut dry_model),
                                       Some(actions), Some(dialogs), None, &mut *host);
    if let Some(first) = preflight.unhandled.first() {
        return Err(Refusal::new("PlatformEffect", unhandled_detail(first)));
    }

    store.set_active_panel(Some(panel_id));
    let state_before = store.eval_context();
    let generation = model.generation();
    let report = run_effects_hosted(&batch, &ctx, store, Some(&mut *model), Some(actions),
                                    Some(dialogs), None, host);
    debug_assert!(report.all_handled(),
                  "the pre-flight passed and the real run did not: {report:?}");
    Ok(Ran {
        doc_changed: model.generation() != generation,
        state_changed: store.eval_context() != state_before,
    })
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

    /// Every report kind gets its own name in a refusal. The second method is
    /// the variant's `Debug` name, so a swapped or shared arm reds.
    #[test]
    fn a_refusal_names_every_report_kind() {
        let all = [
            Unhandled::UnknownEffect("k".into()),
            Unhandled::UnknownDocEffect("k".into()),
            Unhandled::NoModel("k".into()),
            Unhandled::BareString("k".into()),
            Unhandled::NotAnEffect("k".into()),
            Unhandled::Logged("k".into()),
            Unhandled::UnknownAction("k".into()),
            Unhandled::EmptyAction("k".into()),
            Unhandled::UnknownDialog("k".into()),
        ];
        let mut names = vec![];
        for u in &all {
            let debug = format!("{u:?}");
            let kind = debug.split('(').next().unwrap();
            assert_eq!(unhandled_detail(u), format!("{kind}:k"));
            names.push(kind.to_string());
        }
        names.dedup();
        assert_eq!(names.len(), all.len(), "two kinds share a name");
    }

    /// A synthetic panel: one widget per property the real panels cannot
    /// reach. `zz_mark` is claimed by the test host below, which counts it.
    fn synthetic_panel() -> Value {
        json!({"content": {"type": "container", "id": "root", "children": [
            {"id": "edits_first", "type": "icon_button", "behavior": [{"event": "click", "effects": [
                "snapshot",
                {"doc.clear_selection": {}},
                {"zz_first": true},
                {"zz_second": true},
            ]}]},
            {"id": "reads_live", "type": "icon_button", "behavior": [{"event": "click", "effects": [
                {"set_panel_state": {"key": "x", "value": "1"}},
                {"if": {"condition": "panel.x == 1 and active_document.selection_count == 2",
                        "then": [{"zz_mark": true}]}},
            ]}]},
            {"id": "clicks_only", "type": "icon_button", "behavior": [
                {"event": "click", "effects": [{"zz_mark": true}]},
            ]},
            {"id": "acts_with_params", "type": "icon_button", "behavior": [
                {"event": "click", "action": "zz_take", "params": {"target": "artboard"}},
            ]},
        ]}})
    }

    fn synthetic_actions() -> Value {
        json!({"zz_take": {"effects": [
            {"set_panel_state": {"key": "got", "value": "param.target"}},
        ]}})
    }

    struct MarkHost {
        engine: EngineHost,
        marks: usize,
    }

    impl EffectHost for MarkHost {
        fn run(&mut self, key: &str, arg: &Value, store: &mut StateStore,
               model: Option<&mut Model>) -> bool {
            if key == "zz_mark" {
                self.marks += 1;
                return true;
            }
            self.engine.run(key, arg, store, model)
        }
    }

    fn run_synthetic(widget: &str, event: &str, model: &mut Model, store: &mut StateStore,
                     host: &mut MarkHost) -> Result<Ran, Refusal> {
        let ev = parse_event(&json!({"widget": widget, "event": event})).unwrap();
        let scope = json!({"state": {}, "panel": {},
                           "active_document": {"selection_count": model.document().selection.len()}});
        run_widget_behavior("zz_panel", &synthetic_panel(), &ev, &scope, store, model,
                            &synthetic_actions(), &json!({}), host)
    }

    /// Q5 where it is hardest: the batch EDITS the document before the effect
    /// the engine cannot run. Nothing reaches the live model, and the refusal
    /// names the FIRST unhosted effect.
    #[test]
    fn a_refused_batch_that_edits_first_leaves_the_model_untouched() {
        let mut model = misaligned(&[0, 1]);
        let mut store = StateStore::new();
        let mut host = MarkHost { engine: EngineHost { artboard_selection: vec![] }, marks: 0 };
        let generation = model.generation();
        let r = run_synthetic("edits_first", "click", &mut model, &mut store, &mut host);
        assert_eq!(r, Err(Refusal::new("PlatformEffect", "UnknownEffect:zz_first")));
        assert_eq!(model.document().selection.len(), 2, "the dry run's edit reached the model");
        assert_eq!(model.generation(), generation);
        assert!(!model.in_txn());
    }

    /// The runner reads `panel.*` from the store LIVE, so a `set_panel_state`
    /// early in the batch is seen by a condition later in it; and the context
    /// carries `active_document`. A context holding the scope's `panel` would
    /// have shadowed the write, and the mark would never run.
    #[test]
    fn a_batch_reads_its_own_panel_writes_and_the_document_facts() {
        let mut model = misaligned(&[0, 1]);
        let mut store = StateStore::new();
        store.init_panel("zz_panel", Default::default());
        let mut host = MarkHost { engine: EngineHost { artboard_selection: vec![] }, marks: 0 };
        let r = run_synthetic("reads_live", "click", &mut model, &mut store, &mut host);
        assert_eq!(r, Ok(Ran { doc_changed: false, state_changed: true }));
        assert_eq!(host.marks, 2, "once in the pre-flight and once for real");
        assert_eq!(store.get_panel("zz_panel", "x"), &json!(1));
        // The control: with one element selected the condition is false.
        let mut one = misaligned(&[0]);
        let mut store = StateStore::new();
        store.init_panel("zz_panel", Default::default());
        host.marks = 0;
        let r = run_synthetic("reads_live", "click", &mut one, &mut store, &mut host);
        assert_eq!(r, Ok(Ran { doc_changed: false, state_changed: true }));
        assert_eq!(host.marks, 0);
    }

    /// Only the behaviors for THIS event run. A widget with a click behavior
    /// and no double-click behavior refuses a double click, by name.
    #[test]
    fn only_the_named_events_behaviors_run() {
        let mut model = misaligned(&[0, 1]);
        let mut store = StateStore::new();
        let mut host = MarkHost { engine: EngineHost { artboard_selection: vec![] }, marks: 0 };
        let r = run_synthetic("clicks_only", "double_click", &mut model, &mut store, &mut host);
        assert_eq!(r, Err(Refusal::new("EmptyBehavior", "clicks_only")));
        assert_eq!(host.marks, 0);
        let r = run_synthetic("clicks_only", "click", &mut model, &mut store, &mut host);
        assert_eq!(r, Ok(Ran { doc_changed: false, state_changed: false }));
        assert_eq!(host.marks, 2);
    }

    /// A behavior's `action` runs with its `params`, and a bare identifier
    /// among them is its own name. No real panel reaches this path by id
    /// today (the one that does sits under a `foreach`), so it is driven here.
    #[test]
    fn a_behavior_action_runs_with_its_params() {
        let mut model = misaligned(&[0, 1]);
        let mut store = StateStore::new();
        store.init_panel("zz_panel", Default::default());
        let mut host = MarkHost { engine: EngineHost { artboard_selection: vec![] }, marks: 0 };
        let r = run_synthetic("acts_with_params", "click", &mut model, &mut store, &mut host);
        assert_eq!(r, Ok(Ran { doc_changed: false, state_changed: true }));
        assert_eq!(store.get_panel("zz_panel", "got"), &json!("artboard"));
    }

    /// A declared behavior with no body (`layers.yaml`'s tree drag, whose work
    /// is native) is refused by name. The runner never sees it.
    #[test]
    fn a_behavior_with_no_body_is_refused_by_name() {
        let mut model = misaligned(&[0, 1]);
        let ev = parse_event(&json!({"widget": "lp_tree", "event": "drag_move"})).unwrap();
        let r = run("layers_panel_content", &ev, &mut model,
                    &mut EngineHost { artboard_selection: vec![] });
        assert_eq!(r, Err(Refusal::new("EmptyBehavior", "lp_tree")));
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
