//! The record-stop fidelity check (frozen S2 clause): before a
//! recording is emitted, every captured case is REPLAYED through the
//! same code path the corpus runner uses ([`crate::recorder::replay`])
//! and the result is byte-compared against the LIVE document's
//! canonical test-JSON captured at the case boundary. A mismatch marks
//! the case (and the envelope) with a loud `UNFAITHFUL` stamp — the
//! ingest script refuses such cases — making this the first automated
//! corpus-vs-production fidelity probe.

use serde_json::{json, Value};

/// Per-case / envelope fidelity verdicts.
pub const FAITHFUL: &str = "FAITHFUL";
pub const UNFAITHFUL: &str = "UNFAITHFUL";
/// The key seam is a pure resolution (no document): nothing to compare.
pub const PURE: &str = "PURE";

/// Replay one recording case for `seam` and return the canonical
/// document test-JSON the corpus runner would produce (None for the
/// pure key seam). The recording case IS a superset of the corpus case
/// shape, so it replays directly; the embedded `setup_svg` content
/// stands in for the fixture's file reference.
fn replay_case_json(seam: &str, case: &Value) -> Option<String> {
    let setup = case["setup_svg"].as_str().unwrap_or_default();
    match seam {
        "gesture" => Some(super::replay::run_gesture_case_json(case, setup)),
        "action" => Some(super::replay::run_action_case_json(case, setup)),
        "journal" => Some(super::replay::run_journal_case_json(case, setup)),
        _ => None,
    }
}

/// Stamp fidelity verdicts onto a recording envelope (in place): each
/// case gains `"fidelity"` (and, on mismatch, `"replayed_doc_json"`
/// for diagnosis); the envelope gains the aggregate verdict.
pub fn stamp(envelope: &mut Value) {
    let seam = envelope["seam"].as_str().unwrap_or_default().to_string();
    let mut all_faithful = true;
    let mut any_doc_case = false;
    if let Some(cases) = envelope
        .get_mut("cases")
        .and_then(|c| c.as_array_mut())
    {
        for case in cases.iter_mut() {
            let verdict = match replay_case_json(&seam, case) {
                None => PURE,
                Some(replayed) => {
                    any_doc_case = true;
                    let live = case["live_doc_json"].as_str().unwrap_or_default();
                    if replayed == live {
                        FAITHFUL
                    } else {
                        if let Some(o) = case.as_object_mut() {
                            o.insert("replayed_doc_json".into(), json!(replayed));
                        }
                        all_faithful = false;
                        UNFAITHFUL
                    }
                }
            };
            if let Some(o) = case.as_object_mut() {
                o.insert("fidelity".into(), json!(verdict));
            }
        }
    }
    let aggregate = if !any_doc_case {
        PURE
    } else if all_faithful {
        FAITHFUL
    } else {
        UNFAITHFUL
    };
    if let Some(o) = envelope.as_object_mut() {
        o.insert("fidelity".into(), json!(aggregate));
    }
}

// ---------------------------------------------------------------------------
// Tests: drive the PRODUCTION tool and the recorder in lockstep (the
// exact canvas seam), then verify the stamp.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::model::Model;
    use crate::recorder::core::{Recorder, Seam};
    use crate::recorder::replay::build_gesture_tool;
    use crate::tools::tool::CanvasTool;
    use serde_json::Map;

    /// A minimal empty single-layer document (deterministic: no random
    /// layer id, no artboards) as a setup SVG string.
    fn empty_doc_model() -> Model {
        use crate::document::document::Document;
        let mut doc = Document::default();
        doc.layers[0].common_mut().id = None;
        doc.artboards.clear();
        Model::new(doc, None)
    }

    /// Drive one rect-draw through the PRODUCTION CanvasTool seam while
    /// recording each event (screen coords + live model, exactly the
    /// canvas wiring), then stamp — the recording must be FAITHFUL.
    /// Runs the gesture under a NON-IDENTITY view (pan + zoom != 1) so
    /// the screen->doc conversion is what makes replay agree — the
    /// screen-vs-doc trap that motivated determinism law (a).
    #[test]
    fn lockstep_rect_draw_under_pan_zoom_is_faithful() {
        let mut model = empty_doc_model();
        model.zoom_level = 2.0;
        model.view_offset_x = 137.0;
        model.view_offset_y = 54.0;

        let mut tool = build_gesture_tool("rect");
        tool.activate(&mut model);
        let mut rec = Recorder::new(Seam::Gesture, "fid", &model);
        let app_state: Map<String, serde_json::Value> = Map::new();

        // (screen_x, screen_y) points; the tool converts internally.
        let events: [(&str, f64, f64, bool); 3] = [
            ("press", 157.0, 94.0, false),
            ("move", 357.0, 194.0, true),
            ("release", 357.0, 194.0, false),
        ];
        for (kind, x, y, dragging) in events {
            rec.record_pointer_event(
                kind, x, y, false, false, dragging, "rect", &app_state, &model,
            );
            match kind {
                "press" => tool.on_press(&mut model, x, y, false, false),
                "move" => tool.on_move(&mut model, x, y, false, false, dragging),
                "release" => tool.on_release(&mut model, x, y, false, false),
                _ => unreachable!(),
            }
        }

        let mut env = rec.finish(&model);
        stamp(&mut env);
        assert_eq!(env["fidelity"], serde_json::json!(FAITHFUL), "envelope: {env}");
        let case = &env["cases"][0];
        assert_eq!(case["fidelity"], serde_json::json!(FAITHFUL));
        // The recorded events are DOC coords: press (157-137)/2 = 10.
        assert_eq!(case["events"][0]["x"].as_f64().unwrap(), 10.0);
        assert_eq!(case["events"][0]["y"].as_f64().unwrap(), 20.0);
        // And the committed rect is at doc (10,20)-(110,120).
        assert!(case["live_doc_json"].as_str().unwrap().contains("\"x\":10.0"));
    }

    /// A tampered live oracle must produce a loud UNFAITHFUL stamp with
    /// the replayed JSON attached for diagnosis.
    #[test]
    fn tampered_oracle_is_unfaithful() {
        let mut model = empty_doc_model();
        let mut tool = build_gesture_tool("rect");
        tool.activate(&mut model);
        let mut rec = Recorder::new(Seam::Gesture, "tamper", &model);
        let app_state: Map<String, serde_json::Value> = Map::new();
        rec.record_pointer_event("press", 10.0, 20.0, false, false, false, "rect", &app_state, &model);
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        rec.record_pointer_event("release", 60.0, 70.0, false, false, false, "rect", &app_state, &model);
        tool.on_release(&mut model, 60.0, 70.0, false, false);

        let mut env = rec.finish(&model);
        env["cases"][0]["live_doc_json"] = serde_json::json!("{\"tampered\":true}");
        stamp(&mut env);
        assert_eq!(env["fidelity"], serde_json::json!(UNFAITHFUL));
        assert_eq!(env["cases"][0]["fidelity"], serde_json::json!(UNFAITHFUL));
        assert!(env["cases"][0]["replayed_doc_json"].as_str().is_some());
    }

    /// The pure key seam stamps PURE (no document to compare).
    #[test]
    fn key_seam_stamps_pure() {
        let model = empty_doc_model();
        let mut rec = Recorder::new(Seam::Key, "k", &model);
        rec.record_key("V", false, false, false, false);
        let mut env = rec.finish(&model);
        stamp(&mut env);
        assert_eq!(env["fidelity"], serde_json::json!(PURE));
        assert_eq!(env["cases"][0]["fidelity"], serde_json::json!(PURE));
    }

    /// A document mutated OUTSIDE the recorded seam (the corpus-vs-
    /// production probe): the live doc gains an element the gesture
    /// never produced -> UNFAITHFUL.
    #[test]
    fn out_of_seam_mutation_is_unfaithful() {
        use crate::geometry::element::{Color, CommonProps, Element, Fill, RectElem};
        use std::rc::Rc;
        let mut model = empty_doc_model();
        let mut tool = build_gesture_tool("rect");
        tool.activate(&mut model);
        let mut rec = Recorder::new(Seam::Gesture, "oos", &model);
        let app_state: Map<String, serde_json::Value> = Map::new();
        rec.record_pointer_event("press", 10.0, 20.0, false, false, false, "rect", &app_state, &model);
        tool.on_press(&mut model, 10.0, 20.0, false, false);
        rec.record_pointer_event("release", 60.0, 70.0, false, false, false, "rect", &app_state, &model);
        tool.on_release(&mut model, 60.0, 70.0, false, false);

        // An unrecorded, out-of-seam mutation before stop (a properly
        // bracketed edit, as a panel/menu action would commit).
        model.with_txn(|m| {
            let mut doc = m.document().clone();
            doc.layers[0].children_mut().unwrap().push(Rc::new(Element::Rect(RectElem {
                x: 500.0, y: 0.0, width: 5.0, height: 5.0, rx: 0.0, ry: 0.0,
                fill: Some(Fill::new(Color::BLACK)), stroke: None,
                common: CommonProps::default(), fill_gradient: None, stroke_gradient: None,
            })));
            m.set_document(doc);
        });

        let mut env = rec.finish(&model);
        stamp(&mut env);
        assert_eq!(env["fidelity"], serde_json::json!(UNFAITHFUL));
    }
}
