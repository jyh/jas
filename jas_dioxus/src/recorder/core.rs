//! The pure recorder core: per-seam buffers, screen->doc conversion,
//! float canonicalization, segmentation, and v1 precondition flags.
//!
//! No wasm, no globals, no I/O — everything takes `&Model` (or plain
//! values) so the core is unit-testable against synthetic event streams.
//! The wiring (`hooks`) owns the global handle and the emission path; the
//! record-stop fidelity check lives in `fidelity`.

use crate::document::model::Model;
use crate::geometry::svg::{document_to_svg, svg_to_document};
use crate::geometry::test_json::document_to_test_json;
use serde_json::{json, Map, Value};

/// Version tag stamped into every recording envelope.
pub const RECORDER_VERSION: &str = "jas-recorder-v1";

/// The four capture seams (mod.rs has the map to corpus families).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Seam {
    Gesture,
    Action,
    Key,
    Journal,
}

impl Seam {
    /// Parse the `?record=<seam>:<family>` seam token.
    pub fn parse(s: &str) -> Option<Seam> {
        match s {
            "gesture" => Some(Seam::Gesture),
            "action" => Some(Seam::Action),
            "key" => Some(Seam::Key),
            "journal" => Some(Seam::Journal),
            _ => None,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Seam::Gesture => "gesture",
            Seam::Action => "action",
            Seam::Key => "key",
            Seam::Journal => "journal",
        }
    }
}

/// Corpus float canonicalization: round to 4 decimals (the same rule the
/// canonical test-JSON serializers use), so recorded event coordinates
/// carry no sub-precision float noise.
pub fn canon4(v: f64) -> f64 {
    (v * 10000.0).round() / 10000.0
}

/// Convert a screen-space canvas point to document space using the
/// model's LIVE view — the same math as `pointer_event_payload` in
/// `yaml_tool.rs` (the production conversion every tool applies).
/// Determinism law (a): called per event, so mid-gesture pan/zoom is
/// captured correctly.
pub fn screen_to_doc(model: &Model, x: f64, y: f64) -> (f64, f64) {
    let z = model.zoom_level;
    if z == 0.0 {
        (x, y)
    } else {
        (
            (x - model.view_offset_x) / z,
            (y - model.view_offset_y) / z,
        )
    }
}

/// A recorded pointer event, already converted to doc space and
/// canonicalized.
#[derive(Debug, Clone)]
struct PointerEvent {
    kind: String,
    doc_x: f64,
    doc_y: f64,
    shift: bool,
    alt: bool,
    dragging: bool,
}

impl PointerEvent {
    /// Emit in the corpus event shape: `{kind, x, y}` plus `shift` /
    /// `alt` / `dragging` only when true (matching the hand-authored
    /// fixtures' minimal style; the runners default all three false).
    fn to_json(&self) -> Value {
        let mut o = Map::new();
        o.insert("kind".into(), json!(self.kind));
        o.insert("x".into(), json!(self.doc_x));
        o.insert("y".into(), json!(self.doc_y));
        if self.shift {
            o.insert("shift".into(), json!(true));
        }
        if self.alt {
            o.insert("alt".into(), json!(true));
        }
        if self.dragging {
            o.insert("dragging".into(), json!(true));
        }
        Value::Object(o)
    }
}

/// Setup snapshot captured at a case boundary: the serialized SVG plus
/// the v1 precondition flags the writer enforces.
#[derive(Debug, Clone)]
struct Setup {
    svg: String,
    /// Precondition violations, empty when the setup is clean. Names:
    /// `svg_roundtrip_lossy` (the setup document does NOT survive the
    /// SVG round-trip byte-identically) and `selection_not_empty`.
    violations: Vec<String>,
}

/// Capture the live document as a case setup, verifying the v1
/// preconditions: the setup must survive the SVG round-trip (the fixture
/// setup IS an SVG file) and the starting selection must be empty (SVG
/// carries no selection, so replay always starts unselected).
fn capture_setup(model: &Model) -> Setup {
    let doc = model.document();
    let svg = document_to_svg(doc);
    let mut violations = Vec::new();
    let live_json = document_to_test_json(doc);
    let roundtrip_json = document_to_test_json(&svg_to_document(&svg));
    if roundtrip_json != live_json {
        violations.push("svg_roundtrip_lossy".to_string());
    }
    if !doc.selection.is_empty() {
        violations.push("selection_not_empty".to_string());
    }
    Setup { svg, violations }
}

/// One gesture case being accumulated (the `gestures/` corpus shape).
#[derive(Debug, Clone)]
struct GestureCase {
    tool: String,
    setup: Setup,
    app_state: Map<String, Value>,
    events: Vec<PointerEvent>,
    /// Canonical doc test-JSON at case close — the fidelity oracle.
    live_end_json: Option<String>,
}

/// A recorded action step (the `actions/` corpus shape).
#[derive(Debug, Clone)]
struct ActionStep {
    action: String,
    params: Map<String, Value>,
}

/// A recorded key chord (the `keys/` corpus shape).
#[derive(Debug, Clone)]
struct KeyCase {
    key: String,
    ctrl: bool,
    shift: bool,
    alt: bool,
    meta: bool,
}

/// The per-seam recorder. Pure buffers — construction arms it, the
/// seam-specific `record_*` calls accumulate, and [`Recorder::finish`]
/// produces the recording envelope (a `serde_json::Value`) that the
/// wiring emits via the browser download path.
pub struct Recorder {
    seam: Seam,
    family: String,
    // Gesture seam.
    open_case: Option<GestureCase>,
    gesture_cases: Vec<GestureCase>,
    /// True between a recorded press and its release. The live canvas
    /// streams HOVER moves continuously; the corpus only carries
    /// gesture traffic, so moves (and strays) outside a
    /// press..release window are not recorded.
    gesture_in_flight: bool,
    // Action seam (one case per recording in v1).
    action_setup: Option<Setup>,
    action_steps: Vec<ActionStep>,
    // Key seam.
    key_cases: Vec<KeyCase>,
    // Journal seam: the journal cursor at record start; `finish`
    // serializes `journal()[base..head]` in the txns-form.
    journal_base: usize,
    journal_setup: Option<Setup>,
}

impl Recorder {
    /// Arm a recorder. For the ACTION and JOURNAL seams the setup
    /// snapshot is captured HERE (recording starts from the live
    /// document); the GESTURE seam snapshots per case at the first
    /// pointer event instead, and the KEY seam needs no document at all.
    pub fn new(seam: Seam, family: &str, model: &Model) -> Recorder {
        let (action_setup, journal_setup) = match seam {
            Seam::Action => (Some(capture_setup(model)), None),
            Seam::Journal => (None, Some(capture_setup(model))),
            _ => (None, None),
        };
        Recorder {
            seam,
            family: family.to_string(),
            open_case: None,
            gesture_cases: Vec::new(),
            gesture_in_flight: false,
            action_setup,
            action_steps: Vec::new(),
            key_cases: Vec::new(),
            journal_base: model.journal_head(),
            journal_setup,
        }
    }

    pub fn seam(&self) -> Seam {
        self.seam
    }

    pub fn family(&self) -> &str {
        &self.family
    }

    /// Record one pointer event at the CanvasTool seam (gesture seam
    /// only; other seams ignore pointer traffic). Applies the
    /// segmentation law: a tool switch or an app-state change relative
    /// to the open case closes it and starts a new case with a fresh
    /// setup snapshot. `x`/`y` are SCREEN coords; the conversion uses
    /// the model's live view at THIS event (determinism law (a)).
    #[allow(clippy::too_many_arguments)] // mirrors the CanvasTool seam signature plus capture context
    pub fn record_pointer_event(
        &mut self,
        kind: &str,
        x: f64,
        y: f64,
        shift: bool,
        alt: bool,
        dragging: bool,
        tool_id: &str,
        app_state: &Map<String, Value>,
        model: &Model,
    ) {
        if self.seam != Seam::Gesture {
            return;
        }
        // Hover filtering: the live canvas streams mousemove
        // continuously; the corpus carries only gesture traffic. Moves
        // and releases outside a press..release window are ignored, and
        // a case can only BEGIN (and segment) on a press.
        match kind {
            "press" => {
                // Segmentation: tool switch or app-state change ends the
                // case (close_open_case also clears any stale in-flight
                // state, so the flag is set AFTER segmentation).
                let needs_new_case = match &self.open_case {
                    None => true,
                    Some(c) => c.tool != tool_id || &c.app_state != app_state,
                };
                if needs_new_case {
                    self.close_open_case(model);
                    self.open_case = Some(GestureCase {
                        tool: tool_id.to_string(),
                        setup: capture_setup(model),
                        app_state: app_state.clone(),
                        events: Vec::new(),
                        live_end_json: None,
                    });
                }
                self.gesture_in_flight = true;
            }
            "move" | "release" => {
                if !self.gesture_in_flight || self.open_case.is_none() {
                    return;
                }
                if kind == "release" {
                    self.gesture_in_flight = false;
                }
            }
            _ => return,
        }
        let (doc_x, doc_y) = screen_to_doc(model, x, y);
        if let Some(c) = self.open_case.as_mut() {
            c.events.push(PointerEvent {
                kind: kind.to_string(),
                doc_x: canon4(doc_x),
                doc_y: canon4(doc_y),
                shift,
                alt,
                // `dragging` is only meaningful on move events; press /
                // release never carry it in the corpus shape.
                dragging: dragging && kind == "move",
            });
        }
    }

    /// An action was dispatched (depth-0 `dispatch_action` entry).
    /// ACTION seam: record the step. GESTURE seam: segmentation — the
    /// action may mutate the document outside the pointer seam, so the
    /// open case closes NOW (its fidelity oracle is captured before the
    /// action runs).
    pub fn record_action(
        &mut self,
        action: &str,
        params: &Map<String, Value>,
        model: &Model,
    ) {
        match self.seam {
            Seam::Action => self.action_steps.push(ActionStep {
                action: action.to_string(),
                params: params.clone(),
            }),
            Seam::Gesture => self.close_open_case(model),
            _ => {}
        }
    }

    /// Record one key chord at the `resolve_key` seam (key seam only).
    pub fn record_key(&mut self, key: &str, ctrl: bool, shift: bool, alt: bool, meta: bool) {
        if self.seam != Seam::Key {
            return;
        }
        self.key_cases.push(KeyCase {
            key: key.to_string(),
            ctrl,
            shift,
            alt,
            meta,
        });
    }

    /// External segmentation boundary: the document is about to change
    /// (or has changed) outside the recorded seam — history navigation,
    /// a native (non-YAML) tool taking pointer traffic, etc. Gesture
    /// seam: close the open case at this boundary.
    pub fn segment(&mut self, model: &Model) {
        if self.seam == Seam::Gesture {
            self.close_open_case(model);
        }
    }

    /// History navigation (undo/redo) observed — a segmentation
    /// boundary (the document jumps outside the pointer seam).
    pub fn note_history_nav(&mut self, model: &Model) {
        self.segment(model);
    }

    /// Close the open gesture case, stamping its fidelity oracle (the
    /// live document's canonical test-JSON at this boundary). Cases
    /// with no events are dropped (an armed recorder that saw no
    /// pointer traffic emits nothing). Any in-flight gesture is
    /// abandoned with the case (its release will not be recorded).
    fn close_open_case(&mut self, model: &Model) {
        self.gesture_in_flight = false;
        if let Some(mut c) = self.open_case.take() {
            if c.events.is_empty() {
                return;
            }
            c.live_end_json = Some(document_to_test_json(model.document()));
            self.gesture_cases.push(c);
        }
    }

    /// Serialize `journal()[base..head]` in the operations txns-form:
    /// `{name?, ops: [{op, ...params}]}` per transaction. Ops merge the
    /// verb into the flat params payload, exactly the fixture op shape
    /// `apply_op` replays. `targets` are NOT emitted (fixture ops never
    /// carry them; they are additive journal metadata).
    fn journal_txns_form(&self, model: &Model) -> (Vec<Value>, Vec<String>) {
        let mut violations = Vec::new();
        let head = model.journal_head();
        if head < self.journal_base {
            violations.push("history_navigated_below_baseline".to_string());
            return (Vec::new(), violations);
        }
        let mut txns = Vec::new();
        for txn in &model.journal()[self.journal_base..head] {
            let mut t = Map::new();
            if let Some(name) = &txn.name {
                t.insert("name".into(), json!(name));
            }
            let ops: Vec<Value> = txn
                .ops
                .iter()
                .map(|op| {
                    let mut o = Map::new();
                    o.insert("op".into(), json!(op.op));
                    if let Some(params) = op.params.as_object() {
                        for (k, v) in params {
                            o.insert(k.clone(), v.clone());
                        }
                    }
                    Value::Object(o)
                })
                .collect();
            if ops.is_empty() {
                // An opaque production transaction (e.g. a draw commit —
                // the op vocabulary has no creation verbs) replays to
                // NOTHING in the operations runner; flag it.
                violations.push("opaque_transaction_without_ops".to_string());
            }
            t.insert("ops".into(), Value::Array(ops));
            txns.push(Value::Object(t));
        }
        (txns, violations)
    }

    /// Finish the recording: close any open case, capture the final
    /// oracle, and produce the recording envelope. The envelope embeds
    /// setup SVG CONTENT (the wasm app has no filesystem); the ingest
    /// script materializes the `test_fixtures/svg/` files and the final
    /// corpus fixture shape. Fidelity stamps are added afterwards by
    /// [`crate::recorder::fidelity`].
    pub fn finish(mut self, model: &Model) -> Value {
        self.close_open_case(model);
        let mut env = Map::new();
        env.insert("recorder".into(), json!(RECORDER_VERSION));
        env.insert("seam".into(), json!(self.seam.as_str()));
        env.insert("family".into(), json!(self.family));

        match self.seam {
            Seam::Gesture => {
                let cases: Vec<Value> = self
                    .gesture_cases
                    .iter()
                    .enumerate()
                    .map(|(i, c)| {
                        let name = format!("{}_{}", self.family, i + 1);
                        let mut o = Map::new();
                        o.insert("name".into(), json!(name));
                        o.insert("tool".into(), json!(c.tool));
                        o.insert("setup_svg_name".into(), json!(format!("{name}_setup.svg")));
                        o.insert("setup_svg".into(), json!(c.setup.svg));
                        o.insert(
                            "precondition_violations".into(),
                            json!(c.setup.violations),
                        );
                        o.insert(
                            "app_state".into(),
                            Value::Object(c.app_state.clone()),
                        );
                        o.insert(
                            "events".into(),
                            Value::Array(c.events.iter().map(|e| e.to_json()).collect()),
                        );
                        o.insert(
                            "expected_json".into(),
                            json!(format!("{name}_expected.json")),
                        );
                        o.insert(
                            "live_doc_json".into(),
                            json!(c.live_end_json.clone().unwrap_or_default()),
                        );
                        Value::Object(o)
                    })
                    .collect();
                env.insert("cases".into(), Value::Array(cases));
            }
            Seam::Action => {
                let name = format!("{}_1", self.family);
                let setup = self.action_setup.take().expect("action seam captured setup at new()");
                let mut o = Map::new();
                o.insert("name".into(), json!(name));
                o.insert("setup_svg_name".into(), json!(format!("{name}_setup.svg")));
                o.insert("setup_svg".into(), json!(setup.svg));
                o.insert("precondition_violations".into(), json!(setup.violations));
                o.insert(
                    "actions".into(),
                    Value::Array(
                        self.action_steps
                            .iter()
                            .map(|s| {
                                let mut a = Map::new();
                                a.insert("action".into(), json!(s.action));
                                if !s.params.is_empty() {
                                    a.insert("params".into(), Value::Object(s.params.clone()));
                                }
                                Value::Object(a)
                            })
                            .collect(),
                    ),
                );
                o.insert("expected_json".into(), json!(format!("{name}_expected.json")));
                o.insert(
                    "live_doc_json".into(),
                    json!(document_to_test_json(model.document())),
                );
                env.insert("cases".into(), Value::Array(vec![Value::Object(o)]));
            }
            Seam::Key => {
                let cases: Vec<Value> = self
                    .key_cases
                    .iter()
                    .enumerate()
                    .map(|(i, k)| {
                        let mut chord = Map::new();
                        chord.insert("key".into(), json!(k.key));
                        // Only-true modifier style, matching the
                        // hand-authored key fixtures.
                        if k.ctrl {
                            chord.insert("ctrl".into(), json!(true));
                        }
                        if k.shift {
                            chord.insert("shift".into(), json!(true));
                        }
                        if k.alt {
                            chord.insert("alt".into(), json!(true));
                        }
                        if k.meta {
                            chord.insert("meta".into(), json!(true));
                        }
                        let mut o = Map::new();
                        o.insert("name".into(), json!(format!("{}_{}", self.family, i + 1)));
                        o.insert("chord".into(), Value::Object(chord));
                        Value::Object(o)
                    })
                    .collect();
                env.insert("cases".into(), Value::Array(cases));
            }
            Seam::Journal => {
                let name = format!("{}_1", self.family);
                let setup = self.journal_setup.take().expect("journal seam captured setup at new()");
                let (txns, mut violations) = self.journal_txns_form(model);
                let mut all_violations = setup.violations.clone();
                all_violations.append(&mut violations);
                let mut o = Map::new();
                o.insert("name".into(), json!(name));
                o.insert("setup_svg_name".into(), json!(format!("{name}_setup.svg")));
                o.insert("setup_svg".into(), json!(setup.svg));
                o.insert("precondition_violations".into(), json!(all_violations));
                o.insert("txns".into(), Value::Array(txns));
                o.insert("expected_json".into(), json!(format!("{name}_expected.json")));
                o.insert(
                    "live_doc_json".into(),
                    json!(document_to_test_json(model.document())),
                );
                env.insert("cases".into(), Value::Array(vec![Value::Object(o)]));
            }
        }
        Value::Object(env)
    }
}

// ---------------------------------------------------------------------------
// Unit tests: synthetic event streams against the pure core.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::document::Document;
    use crate::document::op_log::PrimitiveOp;
    use crate::geometry::element::{Color, CommonProps, Element, Fill, RectElem};
    use std::rc::Rc;

    fn rect_elem(x: f64) -> Rc<Element> {
        Rc::new(Element::Rect(RectElem {
            x,
            y: 0.0,
            width: 36.0,
            height: 36.0,
            rx: 0.0,
            ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        }))
    }

    /// A deterministic single-rect document (random layer/artboard ids
    /// cleared, matching the live-fixture generator's discipline).
    fn test_doc() -> Document {
        let mut doc = Document::default();
        doc.layers[0].common_mut().id = None;
        doc.artboards.clear();
        doc.layers[0].children_mut().unwrap().push(rect_elem(0.0));
        doc
    }

    fn test_model() -> Model {
        Model::new(test_doc(), None)
    }

    fn empty_state() -> Map<String, Value> {
        Map::new()
    }

    /// Determinism law (a): a pan/zoom mid-stream changes the conversion
    /// of every SUBSEQUENT event — each event uses the view at that
    /// event, so the recorded fixture is in doc space regardless of the
    /// live view's history.
    #[test]
    fn pointer_events_convert_per_event_under_pan_zoom() {
        let mut model = test_model();
        let mut r = Recorder::new(Seam::Gesture, "pz", &model);
        let st = empty_state();

        // Identity view: screen == doc.
        r.record_pointer_event("press", 10.0, 20.0, false, false, false, "rect", &st, &model);

        // Mid-gesture pan/zoom (e.g. alt-wheel): view changes NOW.
        model.zoom_level = 2.0;
        model.view_offset_x = 100.0;
        model.view_offset_y = -50.0;
        r.record_pointer_event("move", 300.0, 150.0, false, false, true, "rect", &st, &model);
        r.record_pointer_event("release", 300.0, 150.0, false, false, false, "rect", &st, &model);

        let env = r.finish(&model);
        let cases = env["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 1, "one tool, no segmentation: one case");
        let events = cases[0]["events"].as_array().unwrap();
        assert_eq!(events.len(), 3);
        // Event 1 under identity view.
        assert_eq!(events[0]["x"].as_f64().unwrap(), 10.0);
        assert_eq!(events[0]["y"].as_f64().unwrap(), 20.0);
        // Events 2-3 under the NEW view: doc = (screen - offset) / zoom.
        assert_eq!(events[1]["x"].as_f64().unwrap(), (300.0 - 100.0) / 2.0);
        assert_eq!(events[1]["y"].as_f64().unwrap(), (150.0 - -50.0) / 2.0);
        assert_eq!(events[1]["dragging"], json!(true));
        assert_eq!(events[2]["x"].as_f64().unwrap(), 100.0);
        // Release never carries `dragging`.
        assert!(events[2].get("dragging").is_none());
    }

    /// Determinism law (b): coordinates are canonicalized to 4 decimals.
    #[test]
    fn pointer_coords_canonicalized_to_4_decimals() {
        let mut model = test_model();
        model.zoom_level = 3.0;
        let mut r = Recorder::new(Seam::Gesture, "canon", &model);
        r.record_pointer_event(
            "press", 10.0, 20.0, false, false, false, "rect", &empty_state(), &model,
        );
        let env = r.finish(&model);
        let ev = &env["cases"][0]["events"][0];
        // 10/3 = 3.3333... -> 3.3333 exactly.
        assert_eq!(ev["x"].as_f64().unwrap(), 3.3333);
        assert_eq!(ev["y"].as_f64().unwrap(), 6.6667);
    }

    /// Segmentation law: a tool switch ends the case and starts a new
    /// one; both cases carry their own setup snapshot.
    #[test]
    fn tool_switch_segments_cases() {
        let model = test_model();
        let mut r = Recorder::new(Seam::Gesture, "seg", &model);
        let st = empty_state();
        r.record_pointer_event("press", 1.0, 1.0, false, false, false, "rect", &st, &model);
        r.record_pointer_event("release", 2.0, 2.0, false, false, false, "rect", &st, &model);
        r.record_pointer_event("press", 3.0, 3.0, false, false, false, "ellipse", &st, &model);
        r.record_pointer_event("release", 4.0, 4.0, false, false, false, "ellipse", &st, &model);
        let env = r.finish(&model);
        let cases = env["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 2);
        assert_eq!(cases[0]["tool"], json!("rect"));
        assert_eq!(cases[1]["tool"], json!("ellipse"));
        assert_eq!(cases[0]["name"], json!("seg_1"));
        assert_eq!(cases[1]["name"], json!("seg_2"));
        assert!(cases[1]["setup_svg"].as_str().unwrap().contains("<svg"));
    }

    /// Segmentation law: an app-state change (e.g. a fill-color pick
    /// between gestures) ends the case.
    #[test]
    fn app_state_change_segments_cases() {
        let model = test_model();
        let mut r = Recorder::new(Seam::Gesture, "st", &model);
        let mut s1 = Map::new();
        s1.insert("fill_color".into(), json!("#ffffff"));
        let mut s2 = Map::new();
        s2.insert("fill_color".into(), json!("#ff0000"));
        r.record_pointer_event("press", 1.0, 1.0, false, false, false, "blob_brush", &s1, &model);
        r.record_pointer_event("release", 2.0, 2.0, false, false, false, "blob_brush", &s1, &model);
        r.record_pointer_event("press", 3.0, 3.0, false, false, false, "blob_brush", &s2, &model);
        r.record_pointer_event("release", 4.0, 4.0, false, false, false, "blob_brush", &s2, &model);
        let env = r.finish(&model);
        let cases = env["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 2);
        assert_eq!(cases[0]["app_state"]["fill_color"], json!("#ffffff"));
        assert_eq!(cases[1]["app_state"]["fill_color"], json!("#ff0000"));
    }

    /// Segmentation law: an action dispatch during gesture recording
    /// closes the open case (the action may mutate the document outside
    /// the pointer seam); pointer traffic after it opens a new case.
    #[test]
    fn action_dispatch_segments_gesture_case() {
        let model = test_model();
        let mut r = Recorder::new(Seam::Gesture, "act", &model);
        let st = empty_state();
        r.record_pointer_event("press", 1.0, 1.0, false, false, false, "rect", &st, &model);
        r.record_pointer_event("release", 2.0, 2.0, false, false, false, "rect", &st, &model);
        r.record_action("toggle_all_layers_visibility", &Map::new(), &model);
        r.record_pointer_event("press", 3.0, 3.0, false, false, false, "rect", &st, &model);
        r.record_pointer_event("release", 4.0, 4.0, false, false, false, "rect", &st, &model);
        let env = r.finish(&model);
        assert_eq!(env["cases"].as_array().unwrap().len(), 2);
    }

    /// History nav during gesture recording segments too.
    #[test]
    fn history_nav_segments_gesture_case() {
        let model = test_model();
        let mut r = Recorder::new(Seam::Gesture, "nav", &model);
        let st = empty_state();
        r.record_pointer_event("press", 1.0, 1.0, false, false, false, "rect", &st, &model);
        r.note_history_nav(&model);
        r.record_pointer_event("press", 3.0, 3.0, false, false, false, "rect", &st, &model);
        let env = r.finish(&model);
        assert_eq!(env["cases"].as_array().unwrap().len(), 2);
    }

    /// Hover filtering: moves outside a press..release window are not
    /// recorded (the live canvas streams hover mousemoves continuously;
    /// the corpus carries gesture traffic only), and a case never
    /// begins on a hover move or stray release.
    #[test]
    fn hover_moves_outside_gesture_are_not_recorded() {
        let model = test_model();
        let mut r = Recorder::new(Seam::Gesture, "hov", &model);
        let st = empty_state();
        // Hover traffic before any press: ignored entirely.
        r.record_pointer_event("move", 5.0, 5.0, false, false, false, "rect", &st, &model);
        r.record_pointer_event("release", 6.0, 6.0, false, false, false, "rect", &st, &model);
        // A real gesture.
        r.record_pointer_event("press", 1.0, 1.0, false, false, false, "rect", &st, &model);
        r.record_pointer_event("move", 2.0, 2.0, false, false, true, "rect", &st, &model);
        r.record_pointer_event("release", 3.0, 3.0, false, false, false, "rect", &st, &model);
        // Hover traffic after the release: ignored.
        r.record_pointer_event("move", 9.0, 9.0, false, false, false, "rect", &st, &model);
        let env = r.finish(&model);
        let cases = env["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 1);
        let events = cases[0]["events"].as_array().unwrap();
        assert_eq!(events.len(), 3, "only the press..release window is recorded");
        assert_eq!(events[0]["kind"], json!("press"));
        assert_eq!(events[2]["kind"], json!("release"));
    }

    /// Two gestures with the same tool and app state stay in ONE case
    /// (segmentation triggers only on press with a changed context).
    #[test]
    fn same_tool_gestures_share_a_case() {
        let model = test_model();
        let mut r = Recorder::new(Seam::Gesture, "two", &model);
        let st = empty_state();
        r.record_pointer_event("press", 1.0, 1.0, false, false, false, "blob_brush", &st, &model);
        r.record_pointer_event("release", 2.0, 2.0, false, false, false, "blob_brush", &st, &model);
        r.record_pointer_event("press", 3.0, 3.0, false, false, false, "blob_brush", &st, &model);
        r.record_pointer_event("release", 4.0, 4.0, false, false, false, "blob_brush", &st, &model);
        let env = r.finish(&model);
        let cases = env["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 1);
        assert_eq!(cases[0]["events"].as_array().unwrap().len(), 4);
    }

    /// An armed recorder that saw no pointer traffic emits no cases.
    #[test]
    fn no_events_emits_no_cases() {
        let model = test_model();
        let r = Recorder::new(Seam::Gesture, "idle", &model);
        let env = r.finish(&model);
        assert_eq!(env["cases"].as_array().unwrap().len(), 0);
    }

    /// v1 precondition: a non-empty selection at case start is flagged
    /// (SVG carries no selection, so replay would diverge).
    #[test]
    fn non_empty_selection_flagged() {
        let mut doc = test_doc();
        use crate::document::document::ElementSelection;
        doc.selection = vec![ElementSelection::all(vec![0, 0])];
        let model = Model::new(doc, None);
        let mut r = Recorder::new(Seam::Gesture, "sel", &model);
        r.record_pointer_event(
            "press", 1.0, 1.0, false, false, false, "rect", &empty_state(), &model,
        );
        let env = r.finish(&model);
        let v = env["cases"][0]["precondition_violations"].as_array().unwrap();
        assert!(v.iter().any(|x| x == "selection_not_empty"), "violations: {v:?}");
    }

    /// Action seam: steps buffer in dispatch order; the setup snapshot
    /// is from record start; the envelope carries the corpus shape.
    #[test]
    fn action_seam_buffers_steps() {
        let model = test_model();
        let mut r = Recorder::new(Seam::Action, "acts", &model);
        let mut p = Map::new();
        p.insert("layer_index".into(), json!(0));
        r.record_action("toggle_all_layers_visibility", &Map::new(), &model);
        r.record_action("toggle_layer_lock", &p, &model);
        // Pointer traffic is ignored on the action seam.
        r.record_pointer_event(
            "press", 1.0, 1.0, false, false, false, "rect", &empty_state(), &model,
        );
        let env = r.finish(&model);
        let case = &env["cases"][0];
        let actions = case["actions"].as_array().unwrap();
        assert_eq!(actions.len(), 2);
        assert_eq!(actions[0]["action"], json!("toggle_all_layers_visibility"));
        assert!(actions[0].get("params").is_none(), "empty params omitted");
        assert_eq!(actions[1]["params"]["layer_index"], json!(0));
        assert!(case["setup_svg"].as_str().unwrap().contains("<svg"));
        assert!(!case["live_doc_json"].as_str().unwrap().is_empty());
    }

    /// Key seam: chords buffer in the fixture chord shape with
    /// only-true modifiers.
    #[test]
    fn key_seam_buffers_chords() {
        let model = test_model();
        let mut r = Recorder::new(Seam::Key, "keys", &model);
        r.record_key("V", false, false, false, false);
        r.record_key("Z", true, true, false, false);
        let env = r.finish(&model);
        let cases = env["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 2);
        assert_eq!(cases[0]["chord"]["key"], json!("V"));
        assert!(cases[0]["chord"].get("ctrl").is_none());
        assert_eq!(cases[1]["chord"]["ctrl"], json!(true));
        assert_eq!(cases[1]["chord"]["shift"], json!(true));
    }

    /// Journal seam: committed transactions since the record-start
    /// baseline serialize in the operations txns-form ({name?, ops:
    /// [{op, ...params}]}); an ops-less (opaque) transaction is flagged.
    #[test]
    fn journal_seam_serializes_txns_form() {
        let mut model = test_model();
        let r = {
            let r = Recorder::new(Seam::Journal, "jrn", &model);
            // One journaled txn with a recorded op (value-in-op).
            model.begin_txn();
            model.name_txn("move");
            model.record_op(PrimitiveOp {
                op: "move_selection".into(),
                params: json!({"dx": 5.0, "dy": 0.0}),
                targets: vec![],
            });
            let mut doc = model.document().clone();
            doc.layers[0].children_mut().unwrap().push(rect_elem(99.0)); // net change so commit journals
            model.set_document(doc);
            model.commit_txn();
            r
        };
        let env = r.finish(&model);
        let case = &env["cases"][0];
        let txns = case["txns"].as_array().unwrap();
        assert_eq!(txns.len(), 1);
        assert_eq!(txns[0]["name"], json!("move"));
        assert_eq!(txns[0]["ops"][0]["op"], json!("move_selection"));
        assert_eq!(txns[0]["ops"][0]["dx"], json!(5.0));
        assert!(txns[0]["ops"][0].get("targets").is_none());
    }

    /// Journal seam: an opaque (ops-less) transaction — e.g. a draw
    /// commit, since the op vocabulary has no creation verbs — is
    /// flagged as unreplayable.
    #[test]
    fn journal_seam_flags_opaque_txns() {
        let mut model = test_model();
        let r = Recorder::new(Seam::Journal, "opq", &model);
        model.begin_txn();
        let mut doc = model.document().clone();
        doc.layers[0].children_mut().unwrap().push(rect_elem(50.0));
        model.set_document(doc);
        model.commit_txn();
        let env = r.finish(&model);
        let v = env["cases"][0]["precondition_violations"].as_array().unwrap();
        assert!(
            v.iter().any(|x| x == "opaque_transaction_without_ops"),
            "violations: {v:?}"
        );
    }
}
