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
//! # The value events (WIDGET_EVENTS.md, W2b-1b)
//!
//! A `commit`/`change` on an input kind and a `click`/`change` on a boolean
//! kind take the contract's procedures (`commit_value`, `press`) after step
//! 2. They share steps 4 and 5 (`run_batch`).
//! * **A commit** refuses `MissingValue` (no `value`) and `BadValue` (text the
//!   kind refuses, via `widget_commit::parse_commit`). Its batch is the bind
//!   write (`set_panel_state` of `event.value` into the widget's own panel,
//!   plus a `set` of the global the panel's `init:` two-way binds it to),
//!   then every `commit`/`change` behavior, in declaration order.
//! * **A press** negates the bound expression. A declared `click`/`change`
//!   behavior replaces the bind write.
//! * **Conditions:** a behavior's `condition` becomes an `if` inside the
//!   batch, so it reads the store after the bind write, as the reference does.
//! * **Inert:** a value widget with nothing to write and nothing declared is
//!   `EmptyBehavior`.
//! * **Oracle:** `test_fixtures/widget_events/corpus.json`, driven through the
//!   export in `ffi.rs`.
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
//! * A value widget bound to `dialog.<ident>` is not written: the engine hosts
//!   no dialog, and no panel carries such a bind.
//! * The door does not report how many behaviors ran, or whether the bind was
//!   written. The corpus's `behaviors_run` and `bind_written` are the
//!   reference's.

use serde_json::{json, Map, Value};

use crate::document::model::Model;
use crate::interpreter::align_host::{self, AlignInput};
use crate::interpreter::effects::{dialog_id, run_effects_hosted, EffectHost, Unhandled};
use crate::interpreter::expr::eval;
use crate::interpreter::state_store::StateStore;
use crate::interpreter::character_host::{self, CHARACTER_PANEL};
use crate::interpreter::paragraph_host::{self, PARAGRAPH_PANEL};

/// The Opacity panel's id: `workspace/panels/opacity.yaml`'s own top-level id.
const OPACITY_PANEL: &str = "opacity_panel_content";

/// The Opacity panel's two document-writing keys, mapped onto the Properties
/// law that already implements them. Returns `None` for the panel's other four
/// declared keys, which reach no element attribute: `thumbnails_hidden` and
/// `options_shown` are panel-local UI, and `new_masks_clipping` /
/// `new_masks_inverted` are document PREFERENCES parked on panel state until
/// the document model grows somewhere to keep them. A write to any of the four
/// must not push an undo step that changes nothing.
fn opacity_prop_key(key: &str) -> Option<&'static str> {
    match key {
        "opacity" => Some("prop_opacity"),
        "blend_mode" => Some("prop_blend"),
        _ => None,
    }
}
use crate::interpreter::properties_host::{self, PROPERTIES_PANEL};
use crate::interpreter::stroke_host::{self, StrokePanelState};
use crate::interpreter::widget_commit::{
    self, BOOLEAN_KINDS, COMMIT_EVENTS, INPUT_KINDS, PRESS_EVENTS,
};
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
    /// The text a person committed into an input widget (WIDGET_EVENTS.md),
    /// exactly as the shell sent it: `None` when absent. The engine parses it;
    /// the shell never does.
    pub value: Option<Value>,
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
        value: obj.get("value").cloned(),
    })
}

/// The engine's own effects: the ones the web renderer runs outside the
/// effects runner, for the panels wave 2a hosts.
///
/// * `snapshot` opens the transaction (`renderer.rs`, both spellings).
/// * The fourteen Align operations run through `align_host`, the one
///   implementation the web app calls too.
/// * A write to a Stroke render key applies the Stroke panel to the selection
///   through `stroke_host` (A11), the one implementation the web app calls
///   too.
/// * A write to one of the Properties panel's eight fields applies it to the
///   selection through `properties_host` (W2b-5), as the reference's
///   `subscribe_properties_panel` does.
/// * `open_dialog` is REFUSED by the dialog's name (A12). The engine has no
///   dialog door, and the runner's own arm would open the dialog in a store no
///   shell can show, then report success.
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

    fn refuse(&mut self, key: &str, arg: &Value) -> Option<Unhandled> {
        (key == "open_dialog").then(|| Unhandled::Dialog(dialog_id(arg).to_string()))
    }

    /// A11: a write to a Stroke render key applies that field of the Stroke
    /// panel, as the store holds it, to the selection. It opens the batch's
    /// transaction as `snapshot` does, so a batch that writes several keys is
    /// ONE undo step, and the runner's owner commits it.
    fn global_written(&mut self, key: &str, store: &mut StateStore, model: Option<&mut Model>) {
        let Some(model) = model else { return };
        if !stroke_host::is_render_key(key) {
            return;
        }
        if !model.in_txn() {
            model.begin_txn();
        }
        let panel = StrokePanelState::from_store(store);
        stroke_host::apply_stroke_panel_to_selection(model, &panel, key, None);
    }

    /// W2b-5: a write to a Properties field applies the value the store now
    /// holds, with the panel's constrain lock, to the selection. The panel's
    /// fields are derived for display (`panel_scope::engine_scope`), so the
    /// written value is read once, here, and never shown. The transaction is
    /// opened as `global_written` opens it.
    fn panel_written(&mut self, panel_id: &str, key: &str, store: &mut StateStore,
                     model: Option<&mut Model>) {
        let Some(model) = model else { return };
        if panel_id == PROPERTIES_PANEL && properties_host::is_field_key(key) {
            if !model.in_txn() {
                model.begin_txn();
            }
            let value = store.get_panel(panel_id, key).clone();
            let constrain = store.get_panel(panel_id, "prop_constrain").as_bool().unwrap_or(false);
            properties_host::apply_field(model, key, &value, constrain);
            return;
        }
        // W2b-6: a write to a Character field applies the panel AS THE STORE
        // HOLDS IT to the selection, because the edited field's SIBLINGS decide
        // the write (the three baseline-shift fields share one attribute, the
        // two case toggles share two). That is why this passes the whole store
        // and not one value, unlike Properties directly above.
        if panel_id == CHARACTER_PANEL && character_host::is_field_key(key) {
            if !model.in_txn() {
                model.begin_txn();
            }
            character_host::apply_field(model, store, key);
            return;
        }
        // W2b-7: a write to a Paragraph field applies the panel AS THE STORE
        // HOLDS IT. Like Character this passes the whole store rather than one
        // value, but for a different reason: the paragraph apply is
        // WHOLE-PANEL — every wrapper attribute is written on every call — so
        // `key` decides only WHETHER to write, never what. The panel's two
        // derived predicates (`text_selected`, `area_text_selected`) answer
        // false to `is_field_key` and never open a transaction.
        if panel_id == PARAGRAPH_PANEL && paragraph_host::is_field_key(key) {
            if !model.in_txn() {
                model.begin_txn();
            }
            paragraph_host::apply_field(model, store, key);
            return;
        }
        // W2b-8: the Opacity panel's two inputs write the SAME two element
        // attributes the Properties panel writes, so they run the SAME law.
        // ⛔ There is deliberately no `opacity_host`: `properties_host` already
        // owns `prop_opacity` and `prop_blend`, ungated and engine-reachable,
        // and a second host would be a second copy of two writes. What was
        // missing was never a law — it was this mapping.
        //
        // ⚠️ The units already line up and that is not an accident to rely on
        // silently: `panel.opacity` is PERCENT (the YAML's default is 100) and
        // `properties_host` divides by 100 and clamps. Passing the percent
        // through unconverted is correct, and an arm pins it.
        if panel_id == OPACITY_PANEL {
            if let Some(prop) = opacity_prop_key(key) {
                if !model.in_txn() {
                    model.begin_txn();
                }
                let value = store.get_panel(panel_id, key).clone();
                properties_host::apply_field(model, prop, &value, false);
            }
        }
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
        Unhandled::Dialog(s) => ("Dialog", s),
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

    // The value events (WIDGET_EVENTS.md). A commit on an input kind and a
    // press on a boolean kind follow the contract; every other event on every
    // other kind keeps the click path below.
    let kind = node.get("type").and_then(Value::as_str).unwrap_or("");
    if INPUT_KINDS.contains(&kind) && COMMIT_EVENTS.contains(&ev.event.as_str()) {
        return commit_value(panel_id, spec, node, ev, scope, store, model, actions, dialogs,
                            host);
    }
    if BOOLEAN_KINDS.contains(&kind) && PRESS_EVENTS.contains(&ev.event.as_str()) {
        return press(panel_id, spec, node, ev, scope, store, model, actions, dialogs, host);
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
    run_batch(panel_id, &batch, ev.modifiers.clone(), scope, store, model, actions, dialogs,
              host)
}

/// Pre-flight `batch` on copies, then run it for real (module doc, steps 4
/// and 5). `event` is what the batch reads as `event.*`.
#[allow(clippy::too_many_arguments)]
fn run_batch(
    panel_id: &str,
    batch: &[Value],
    event: Value,
    scope: &Value,
    store: &mut StateStore,
    model: &mut Model,
    actions: &Value,
    dialogs: &Value,
    host: &mut dyn EffectHost,
) -> Result<Ran, Refusal> {
    // The runner reads `state` and `panel` from the STORE, live, so a `set`
    // early in the batch is seen by an expression later in it. The context
    // carries only what the store does not hold.
    let ctx = json!({
        "active_document": scope.get("active_document").cloned().unwrap_or(Value::Null),
        "event": event,
    });
    // `set_panel_state` writes the ACTIVE panel. It is set on the copy for the
    // pre-flight and on the live store only once the pre-flight passes: a
    // refusal changes nothing, not even which panel is active.
    let mut dry_store = store.clone();
    dry_store.set_active_panel(Some(panel_id));
    let mut dry_model = model.clone();
    let preflight = run_effects_hosted(batch, &ctx, &mut dry_store, Some(&mut dry_model),
                                       Some(actions), Some(dialogs), None, &mut *host);
    if let Some(first) = preflight.unhandled.first() {
        return Err(Refusal::new("PlatformEffect", unhandled_detail(first)));
    }

    store.set_active_panel(Some(panel_id));
    let state_before = store.eval_context();
    let generation = model.generation();
    let report = run_effects_hosted(batch, &ctx, store, Some(&mut *model), Some(actions),
                                    Some(dialogs), None, host);
    debug_assert!(report.all_handled(),
                  "the pre-flight passed and the real run did not: {report:?}");
    Ok(Ran {
        doc_changed: model.generation() != generation,
        state_changed: store.eval_context() != state_before,
    })
}

/// A value event's behaviors, in declaration order: each one's effects and
/// then its action, as ONE entry. A `condition` becomes an `if` around its
/// behavior, so it is evaluated when that behavior's turn comes, after the
/// bind write and the behaviors before it, as the reference evaluates it.
/// Returns the batch and how many behaviors the widget DECLARES for `events`.
fn value_behaviors(node: &Value, events: &[&str], widget: &str)
                   -> Result<(Vec<Value>, usize), Refusal> {
    let mut batch = vec![];
    let mut declared = 0;
    for b in node.get("behavior").and_then(Value::as_array).into_iter().flatten() {
        let Some(event) = b.get("event").and_then(Value::as_str) else { continue };
        if !events.contains(&event) {
            continue;
        }
        declared += 1;
        let mut body: Vec<Value> = b.get("effects").and_then(Value::as_array)
            .cloned().unwrap_or_default();
        if let Some(action) = b.get("action").and_then(Value::as_str) {
            let mut d = Map::new();
            d.insert("action".into(), Value::String(action.to_string()));
            if let Some(params) = b.get("params") {
                d.insert("params".into(), params.clone());
            }
            body.push(json!({"dispatch": Value::Object(d)}));
        }
        if body.is_empty() {
            return Err(Refusal::new("EmptyBehavior", widget.to_string()));
        }
        match b.get("condition").and_then(Value::as_str) {
            Some(cond) => batch.push(json!({"if": {"condition": cond, "then": body}})),
            None => batch.extend(body),
        }
    }
    Ok((batch, declared))
}

/// The bind write as effects: the evaluated `event.value` into the widget's
/// own panel, then into the global the panel's `init:` two-way binds that
/// field to. Empty when the widget binds nothing this layer writes. A
/// `dialog.<ident>` bind is writable by the contract, and no panel the engine
/// hosts carries one, so the engine writes panel binds only.
fn bind_write(node: &Value, spec: &Value, panel_id: &str) -> Vec<Value> {
    let Some(target) = widget_commit::bound_target(node) else { return vec![] };
    let Some(("panel", key)) = widget_commit::writable_target(target) else { return vec![] };
    let mut out = vec![json!({"set_panel_state": {
        "key": key, "value": "event.value", "panel": panel_id}})];
    if let Some(global) = widget_commit::mirrored_global(spec, key) {
        out.push(json!({"set": {format!("state.{global}"): "event.value"}}));
    }
    out
}

/// `event.*` for a value event: the modifiers, plus `value`.
fn value_event(ev: &UserEvent, value: Value) -> Value {
    let mut event = ev.modifiers.clone();
    if let Some(m) = event.as_object_mut() {
        m.insert("value".into(), value);
    }
    event
}

/// A commit on an input kind (WIDGET_EVENTS.md, "Committing a value"). The
/// disabled refusal has already run. `MissingValue` for no text (or JSON
/// null), `BadValue` for text the kind refuses or a value that is not text.
/// Then ONE batch: the bind write, then every `commit`/`change` behavior.
/// A widget with neither is refused as `EmptyBehavior` (the contract's
/// `inert`).
#[allow(clippy::too_many_arguments)]
fn commit_value(
    panel_id: &str,
    spec: &Value,
    node: &Value,
    ev: &UserEvent,
    scope: &Value,
    store: &mut StateStore,
    model: &mut Model,
    actions: &Value,
    dialogs: &Value,
    host: &mut dyn EffectHost,
) -> Result<Ran, Refusal> {
    let text = match &ev.value {
        None | Some(Value::Null) => return Err(Refusal::new("MissingValue", ev.widget.clone())),
        Some(Value::String(t)) => t,
        Some(_) => return Err(Refusal::new("BadValue", ev.widget.clone())),
    };
    let Some(value) = widget_commit::parse_commit(node, text) else {
        return Err(Refusal::new("BadValue", ev.widget.clone()));
    };
    let mut batch: Vec<Value> = bind_write(node, spec, panel_id);
    let (behaviors, _) = value_behaviors(node, &COMMIT_EVENTS, &ev.widget)?;
    batch.extend(behaviors);
    if batch.is_empty() {
        return Err(Refusal::new("EmptyBehavior", ev.widget.clone()));
    }
    run_batch(panel_id, &batch, value_event(ev, value), scope, store, model, actions, dialogs,
              host)
}

/// A press on a boolean kind (WIDGET_EVENTS.md, "Pressing a boolean"). The
/// new value is the negation of the bound expression in the engine's scope.
/// A declared `click`/`change` behavior IS the press, and the bind is not
/// written; otherwise the new value is written. Neither is `EmptyBehavior`.
#[allow(clippy::too_many_arguments)]
fn press(
    panel_id: &str,
    spec: &Value,
    node: &Value,
    ev: &UserEvent,
    scope: &Value,
    store: &mut StateStore,
    model: &mut Model,
    actions: &Value,
    dialogs: &Value,
    host: &mut dyn EffectHost,
) -> Result<Ran, Refusal> {
    let current = widget_commit::bound_target(node).is_some_and(|e| eval(e, scope).to_bool());
    let value = Value::Bool(!current);
    let (behaviors, declared) = value_behaviors(node, &PRESS_EVENTS, &ev.widget)?;
    let batch = if declared > 0 {
        behaviors
    } else {
        bind_write(node, spec, panel_id)
    };
    if batch.is_empty() {
        return Err(Refusal::new("EmptyBehavior", ev.widget.clone()));
    }
    run_batch(panel_id, &batch, value_event(ev, value), scope, store, model, actions, dialogs,
              host)
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
    use super::test_fixture::{misaligned, model_with, rect};
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
            assert_eq!(host.refuse(declined, &Value::Null), None,
                       "the engine host refused {declined}");
        }
    }

    /// A12: `open_dialog` is refused by the dialog's id, in both of the
    /// argument's spellings, and never run.
    #[test]
    fn the_engine_host_refuses_a_dialog_by_its_id() {
        let mut host = EngineHost { artboard_selection: vec![] };
        let mut store = StateStore::new();
        let mut model = misaligned(&[0]);
        for (arg, id) in [(json!({"id": "brush_options", "params": {}}), "brush_options"),
                          (json!("artboard_options"), "artboard_options"),
                          (json!(7), "")] {
            assert_eq!(host.refuse("open_dialog", &arg), Some(Unhandled::Dialog(id.into())));
            assert!(!host.run("open_dialog", &arg, &mut store, Some(&mut model)));
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
            Unhandled::Dialog("k".into()),
        ];
        let mut names = vec![];
        for u in &all {
            let debug = format!("{u:?}");
            let kind = debug.split('(').next().unwrap();
            assert_eq!(unhandled_detail(u), format!("{kind}:k"));
            names.push(kind.to_string());
        }
        // `dedup` removes only ADJACENT repeats, so sort first.
        names.sort();
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
            {"id": "strokes_twice", "type": "icon_button", "behavior": [{"event": "click", "effects": [
                {"set": {"stroke_cap": "\"round\""}},
                {"set": {"stroke_join": "\"bevel\""}},
            ]}]},
            {"id": "strokes_then_refused", "type": "icon_button", "behavior": [{"event": "click", "effects": [
                {"set": {"stroke_cap": "\"round\""}},
                {"zz_first": true},
            ]}]},
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
        fn global_written(&mut self, key: &str, store: &mut StateStore, model: Option<&mut Model>) {
            self.engine.global_written(key, store, model)
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

    /// A stroked selection: `misaligned`'s rects, each given a 2pt butt/miter
    /// stroke, and that stroke as the default to build on.
    fn stroked(selected: &[usize]) -> Model {
        use crate::geometry::element::{Color, Element, Stroke};
        let stroke = Stroke::new(Color::BLACK, 2.0);
        let rects = [rect(10.0, 0.0, 5.0, 5.0), rect(40.0, 20.0, 5.0, 5.0)]
            .into_iter()
            .map(|el| match el {
                Element::Rect(mut r) => {
                    r.stroke = Some(stroke);
                    Element::Rect(r)
                }
                other => other,
            })
            .collect();
        let mut model = model_with(rects, selected);
        model.default_stroke = Some(stroke);
        model
    }

    /// **A Properties write named by the SHORT kind reaches the selection.**
    /// The store keys the scope by the content id, and reports the write the
    /// same way, so the host's content-id match sees `panel: properties` too.
    #[test]
    fn a_short_named_properties_write_reaches_the_selection() {
        let mut model = model_with(vec![rect(10.0, 0.0, 5.0, 5.0)], &[0]);
        let mut store = StateStore::new();
        store.init_panel(PROPERTIES_PANEL, std::collections::HashMap::new());
        let mut host = EngineHost { artboard_selection: vec![] };
        let batch = [json!({"set_panel_state": {"panel": "properties", "key": "prop_x", "value": "40"}})];
        let report = run_effects_hosted(&batch, &json!({}), &mut store, Some(&mut model), None,
                                        None, None, &mut host);
        assert!(report.unhandled.is_empty(), "{report:?}");
        assert_eq!(store.get_panel(PROPERTIES_PANEL, "prop_x"), &json!(40));
        let x = crate::document::evaluated_bounds::selection_evaluated_bounds(model.document()).0;
        assert_eq!(x, 40.0, "the write landed in the store and did not reach the selection");
    }

    fn caps_and_joins(model: &Model) -> Vec<String> {
        let doc = model.document();
        (0..2).map(|i| {
            let s = doc.get_element(&vec![0usize, i]).unwrap().stroke().cloned().unwrap();
            format!("{:?}/{:?}", s.linecap, s.linejoin)
        }).collect()
    }

    /// **A11 in the engine host.** A render-key write reaches the SELECTION
    /// only, in ONE undo step however many keys the batch writes; the
    /// unselected element is untouched.
    #[test]
    fn a_stroke_render_key_write_reaches_the_selection_in_one_step() {
        let mut model = stroked(&[0]);
        let mut store = StateStore::new();
        let mut host = MarkHost { engine: EngineHost { artboard_selection: vec![] }, marks: 0 };
        let r = run_synthetic("strokes_twice", "click", &mut model, &mut store, &mut host);
        assert_eq!(r, Ok(Ran { doc_changed: true, state_changed: true }));
        assert_eq!(caps_and_joins(&model), vec!["Round/Bevel", "Butt/Miter"]);
        assert!(!model.in_txn(), "the batch left its transaction open");
        model.undo();
        assert_eq!(caps_and_joins(&model), vec!["Butt/Miter", "Butt/Miter"]);
        assert!(!model.can_undo(), "two render keys took two undo steps");
    }

    /// The pre-flight covers the stroke write: the dry run applies the cap to
    /// the COPY, the batch is refused, and the live selection keeps its cap.
    #[test]
    fn a_refused_batch_that_strokes_first_leaves_the_selection_untouched() {
        let mut model = stroked(&[0, 1]);
        let mut store = StateStore::new();
        let mut host = MarkHost { engine: EngineHost { artboard_selection: vec![] }, marks: 0 };
        let generation = model.generation();
        let r = run_synthetic("strokes_then_refused", "click", &mut model, &mut store, &mut host);
        assert_eq!(r, Err(Refusal::new("PlatformEffect", "UnknownEffect:zz_first")));
        assert_eq!(model.generation(), generation);
        assert_eq!(caps_and_joins(&model), vec!["Butt/Miter", "Butt/Miter"]);
        assert!(!model.in_txn());
        // The control: the same cap write, unrefused, reaches the live model.
        let r = run_synthetic("strokes_twice", "click", &mut model, &mut store, &mut host);
        assert_eq!(r, Ok(Ran { doc_changed: true, state_changed: true }));
        assert_eq!(caps_and_joins(&model), vec!["Round/Bevel", "Round/Bevel"]);
    }

    /// The engine host's A11 arm, called directly: a render key applies the
    /// store's panel to the selection and opens the transaction as
    /// `snapshot` does; any other global, and a call with no model, does
    /// nothing.
    #[test]
    fn the_engine_host_applies_a_render_key_and_ignores_other_globals() {
        let mut host = EngineHost { artboard_selection: vec![] };
        let mut model = stroked(&[0, 1]);
        let mut store = StateStore::new();
        store.set("stroke_cap", json!("square"));
        for other in ["stroke_link_arrowhead_scale", "fill_color", "cap"] {
            host.global_written(other, &mut store, Some(&mut model));
            assert!(!model.in_txn(), "{other} opened a transaction");
        }
        host.global_written("stroke_cap", &mut store, None);
        assert_eq!(caps_and_joins(&model), vec!["Butt/Miter", "Butt/Miter"]);
        host.global_written("stroke_cap", &mut store, Some(&mut model));
        assert!(model.in_txn(), "the apply opened the batch's transaction");
        model.commit_txn();
        assert!(model.can_undo());
        assert_eq!(caps_and_joins(&model), vec!["Square/Miter", "Square/Miter"]);
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

    // ── The value door (W2b-1b, WIDGET_EVENTS.md), on hand-built widgets ──
    // The corpus drives shipped widgets through the FFI; these pin the
    // clauses no shipped widget exercises.

    const PROBE: &str = "probe_panel_content";

    /// Run `event` on `node`, alone in a probe panel whose scope is `panel`.
    fn door(node: Value, event: Value, panel: Value) -> (Result<Ran, Refusal>, StateStore) {
        door_in(json!({}), node, event, panel)
    }

    /// `door` in a panel whose `init:` is `init`.
    fn door_in(init: Value, node: Value, event: Value, panel: Value)
               -> (Result<Ran, Refusal>, StateStore) {
        let spec = json!({"init": init,
                          "content": {"type": "container", "children": [node]}});
        let mut store = StateStore::new();
        let scope_map = panel.as_object().unwrap().iter()
            .map(|(k, v)| (k.clone(), v.clone())).collect();
        store.init_panel(PROBE, scope_map);
        let ev = parse_event(&event).expect("event parses");
        let scope = json!({"state": {}, "panel": panel, "active_document": {}});
        let mut model = Model::default();
        let r = run_widget_behavior(PROBE, &spec, &ev, &scope, &mut store, &mut model,
                                    &json!({}), &json!({}),
                                    &mut EngineHost { artboard_selection: vec![] });
        (r, store)
    }

    #[test]
    fn change_is_a_commit_and_its_behavior_reads_the_new_value() {
        let node = json!({"type": "number_input", "id": "w", "bind": {"value": "panel.n"},
            "behavior": [{"event": "change", "effects": [
                {"set_panel_state": {"key": "seen", "value": "panel.n"}}]}]});
        let (r, store) = door(node, json!({"widget": "w", "event": "change", "value": "7"}),
                              json!({"n": 1, "seen": null}));
        assert!(r.is_ok(), "{r:?}");
        assert_eq!(store.get_panel(PROBE, "n").as_f64(), Some(7.0));
        assert_eq!(store.get_panel(PROBE, "seen").as_f64(), Some(7.0));
    }

    #[test]
    fn a_condition_is_read_after_the_bind_write() {
        let node = json!({"type": "number_input", "id": "w", "bind": {"value": "panel.n"},
            "behavior": [{"event": "commit", "condition": "panel.n > 10", "effects": [
                {"set_panel_state": {"key": "big", "value": "true"}}]}]});
        let ev = |t: &str| json!({"widget": "w", "event": "commit", "value": t});
        let (_, store) = door(node.clone(), ev("50"), json!({"n": 1, "big": false}));
        assert_eq!(store.get_panel(PROBE, "big"), &json!(true));
        let (r, store) = door(node, ev("5"), json!({"n": 1, "big": false}));
        assert!(r.is_ok(), "{r:?}");
        assert_eq!(store.get_panel(PROBE, "big"), &json!(false));
    }

    #[test]
    fn a_value_that_is_not_text_is_refused_and_moves_nothing() {
        let node = json!({"type": "number_input", "id": "w", "bind": {"value": "panel.n"}});
        for value in [json!(40), json!(true), json!(["40"])] {
            let (r, store) = door(node.clone(),
                                  json!({"widget": "w", "event": "commit", "value": value}),
                                  json!({"n": 1}));
            assert_eq!(r, Err(Refusal::new("BadValue", "w")), "{value}");
            assert_eq!(store.get_panel(PROBE, "n"), &json!(1));
        }
        let (r, _) = door(node, json!({"widget": "w", "event": "commit"}), json!({"n": 1}));
        assert_eq!(r, Err(Refusal::new("MissingValue", "w")));
    }

    #[test]
    fn an_undeclared_boolean_writes_its_negation() {
        for (kind, key) in [("toggle", "checked"), ("checkbox", "value")] {
            let node = json!({"type": kind, "id": "b", "bind": {key: "panel.on"}});
            let (r, store) = door(node, json!({"widget": "b"}), json!({"on": true}));
            assert!(r.is_ok_and(|ran| ran.state_changed), "{kind}");
            assert_eq!(store.get_panel(PROBE, "on"), &json!(false), "{kind}");
        }
    }

    #[test]
    fn a_declared_press_sees_the_new_boolean_and_the_field_is_not_written() {
        let node = json!({"type": "checkbox", "id": "b", "bind": {"checked": "panel.on"},
            "behavior": [{"event": "click", "effects": [
                {"set_panel_state": {"key": "seen", "value": "event.value"}}]}]});
        let (r, store) = door(node, json!({"widget": "b", "event": "change"}),
                              json!({"on": true, "seen": null}));
        assert!(r.is_ok(), "{r:?}");
        assert_eq!(store.get_panel(PROBE, "seen"), &json!(false));
        assert_eq!(store.get_panel(PROBE, "on"), &json!(true));
    }

    #[test]
    fn a_press_whose_only_behavior_is_skipped_writes_nothing() {
        let node = json!({"type": "toggle", "id": "b", "bind": {"checked": "panel.on"},
            "behavior": [{"event": "click", "condition": "panel.armed", "effects": [
                {"set_panel_state": {"key": "on", "value": "false"}}]}]});
        let (r, store) = door(node, json!({"widget": "b"}), json!({"on": true, "armed": false}));
        assert_eq!(r, Ok(Ran { doc_changed: false, state_changed: false }));
        assert_eq!(store.get_panel(PROBE, "on"), &json!(true));
    }

    #[test]
    fn an_inert_value_widget_is_refused_as_empty() {
        let (r, _) = door(json!({"type": "number_input", "id": "w"}),
                          json!({"widget": "w", "event": "commit", "value": "5"}), json!({}));
        assert_eq!(r, Err(Refusal::new("EmptyBehavior", "w")));
        let (r, _) = door(json!({"type": "toggle", "id": "b", "bind": {"checked": "state.x"}}),
                          json!({"widget": "b"}), json!({}));
        assert_eq!(r, Err(Refusal::new("EmptyBehavior", "b")));
    }

    #[test]
    fn the_two_way_bind_writes_the_mapped_global_before_the_behaviors() {
        let init = json!({"n": "state.gn", "b": "state.gb", "e": "state.a + 1"});
        let node = json!({"type": "number_input", "id": "w", "bind": {"value": "panel.n"},
            "behavior": [{"event": "commit", "effects": [
                {"set_panel_state": {"key": "seen", "value": "state.gn"}}]}]});
        let (r, store) = door_in(init.clone(), node,
                                 json!({"widget": "w", "event": "commit", "value": "7"}),
                                 json!({"n": 1, "seen": null}));
        assert!(r.is_ok(), "{r:?}");
        assert_eq!(store.get("gn").as_f64(), Some(7.0));
        assert_eq!(store.get_panel(PROBE, "seen").as_f64(), Some(7.0));
        // An expression mapping is not a two-way bind.
        let node = json!({"type": "number_input", "id": "w", "bind": {"value": "panel.e"}});
        let (_, store) = door_in(init.clone(), node,
                                 json!({"widget": "w", "event": "commit", "value": "7"}),
                                 json!({"e": 1}));
        assert_eq!(store.get("a"), &Value::Null);
        assert_eq!(store.get_panel(PROBE, "e").as_f64(), Some(7.0));
        // An undeclared press writes both; a declared one writes neither.
        let node = json!({"type": "toggle", "id": "t", "bind": {"checked": "panel.b"}});
        let (_, store) = door_in(init.clone(), node, json!({"widget": "t"}), json!({"b": true}));
        assert_eq!((store.get_panel(PROBE, "b"), store.get("gb")), (&json!(false), &json!(false)));
        let node = json!({"type": "toggle", "id": "t", "bind": {"checked": "panel.b"},
            "behavior": [{"event": "click", "effects": [
                {"set_panel_state": {"key": "x", "value": "1"}}]}]});
        let (_, store) = door_in(init, node, json!({"widget": "t"}), json!({"b": true}));
        assert_eq!((store.get_panel(PROBE, "b"), store.get("gb")), (&json!(true), &Value::Null));
    }

    #[test]
    fn text_entry_events_are_not_commits() {
        let node = json!({"type": "text_input", "id": "t", "bind": {"value": "panel.q"},
            "behavior": [{"event": "input", "effects": [
                {"set_panel_state": {"key": "typed", "value": "true"}}]}]});
        // `input` keeps the click path: its own behavior runs, nothing is parsed.
        let (r, store) = door(node.clone(), json!({"widget": "t", "event": "input"}),
                              json!({"q": "", "typed": false}));
        assert!(r.is_ok(), "{r:?}");
        assert_eq!(store.get_panel(PROBE, "typed"), &json!(true));
        // A commit writes the bind and does not run the `input` behavior.
        let (r, store) = door(node, json!({"widget": "t", "event": "commit", "value": "abc"}),
                              json!({"q": "", "typed": false}));
        assert!(r.is_ok(), "{r:?}");
        assert_eq!(store.get_panel(PROBE, "q"), &json!("abc"));
        assert_eq!(store.get_panel(PROBE, "typed"), &json!(false));
    }
}
