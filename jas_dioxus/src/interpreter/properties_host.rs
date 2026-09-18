//! The Properties panel's edit and display, hosted without a web dependency
//! (FB wave 2b, W2b-5).
//!
//! The panel's `prop_*` keys are DERIVED from the selection, never stored:
//! [`live_values`] computes the eight the panel shows, and [`apply_field`]
//! writes an edit of one of them back to the selection. This module is the
//! ONE Rust implementation of both. The web app calls them from
//! `build_live_panel_overrides` and `apply_properties_panel_field`. The engine
//! calls [`live_values`] when it assembles the Properties panel's scope, and
//! [`apply_field`] from its effect host when a behavior writes one of
//! [`FIELD_KEYS`] into the panel, as the reference's
//! `subscribe_properties_panel` does (`workspace_interpreter/effects.py`).

use serde_json::{json, Map, Value};

use crate::document::controller::Controller;
use crate::document::document::Document;
use crate::document::evaluated_bounds::selection_evaluated_bounds;
use crate::document::model::Model;
use crate::geometry::element::Transform;
use crate::interpreter::effects::value_to_json;
use crate::interpreter::expr::eval;

/// The Properties panel's id: the store scope its keys live in.
pub const PROPERTIES_PANEL: &str = "properties_panel_content";

/// The panel keys whose write reaches the selection: the reference's
/// `fields` set in `subscribe_properties_panel`, each with its `prop_`
/// prefix, in the order the panel shows them. A test reads the reference's
/// literal and requires this list to hold the same eight.
pub const FIELD_KEYS: [&str; 8] = [
    "prop_x", "prop_y", "prop_w", "prop_h",
    "prop_rotation", "prop_shear", "prop_opacity", "prop_blend",
];

/// True when a write to the Properties panel's `key` applies to the selection.
pub fn is_field_key(key: &str) -> bool {
    FIELD_KEYS.contains(&key)
}

/// The eight values the panel shows, from the selection (decision-5 Part B.1
/// and B.3). The box is the selection's EVALUATED bounds, in document points;
/// rotation, shear, opacity and blend are the FIRST selected element's.
/// Numbers are rounded to two decimals. Nothing selected reads 0 / 0 / 0 / 0,
/// 0 degrees, 0 shear, 100 percent and `normal`.
pub fn live_values(doc: &Document) -> Map<String, Value> {
    let mut m = Map::new();
    let (px, py, pw, ph) = selection_evaluated_bounds(doc);
    let r2 = |v: f64| (v * 100.0).round() / 100.0;
    m.insert("prop_x".into(), json!(r2(px)));
    m.insert("prop_y".into(), json!(r2(py)));
    m.insert("prop_w".into(), json!(r2(pw)));
    m.insert("prop_h".into(), json!(r2(ph)));
    let mut rot = 0.0_f64;
    let mut shear = 0.0_f64;
    let mut op = 100.0_f64;
    let mut blend = Value::String("normal".into());
    if let Some(e) = doc.selection.first().and_then(|es| doc.get_element(&es.path)) {
        if let Some(t) = e.transform() {
            rot = t.b.atan2(t.a).to_degrees();
            shear = prop_shear_angle_deg(t);
        }
        op = e.opacity() * 100.0;
        // Blend serializes to its snake_case id via serde.
        blend = serde_json::to_value(e.mode()).unwrap_or_else(|_| Value::String("normal".into()));
    }
    m.insert("prop_rotation".into(), json!(r2(rot)));
    m.insert("prop_shear".into(), json!(r2(shear)));
    m.insert("prop_opacity".into(), json!(r2(op)));
    m.insert("prop_blend".into(), blend);
    m
}

// ── Pure 2x3 transform math, mirroring the reference (effects.py) ───────

/// AABB (x, y, w, h) of `local_bbox`'s four corners mapped through `m`.
/// One copy: `geometry::element::aabb_through` (it also carries the A6 §3.3
/// mask-bbox contract, so a drift here would split the panel from the seam).
fn prop_aabb_through(
    local_bbox: (f64, f64, f64, f64),
    m: &crate::geometry::element::Transform,
) -> (f64, f64, f64, f64) {
    crate::geometry::element::aabb_through(local_bbox, m)
}

/// Scale the element's LOCAL axes by (rx, ry) (post-multiply, preserving
/// rotation) keeping the evaluated bbox top-left fixed.
fn prop_scaled_transform(
    mat: crate::geometry::element::Transform,
    local_bbox: (f64, f64, f64, f64),
    rx: f64,
    ry: f64,
) -> crate::geometry::element::Transform {
    use crate::geometry::element::Transform;
    // mat.multiply(scale) applies scale first (local), then mat — i.e. M·S.
    let scaled = mat.multiply(&Transform { a: rx, b: 0.0, c: 0.0, d: ry, e: 0.0, f: 0.0 });
    let old = prop_aabb_through(local_bbox, &mat);
    let new = prop_aabb_through(local_bbox, &scaled);
    Transform { e: scaled.e + (old.0 - new.0), f: scaled.f + (old.1 - new.1), ..scaled }
}

/// Shear angle (degrees) of a 2x3 transform, from the
/// M = R(theta) . ShearX(k) . Scale(sx, sy) decomposition:
/// k = (a*c + b*d) / det, shear = atan(k). Returns 0 for any shear-free
/// matrix (agrees with the prior rotation-only behavior) and 0 when the
/// matrix is degenerate (zero first-column length or zero determinant).
fn prop_shear_angle_deg(mat: &crate::geometry::element::Transform) -> f64 {
    let sx = (mat.a * mat.a + mat.b * mat.b).sqrt();
    let det = mat.a * mat.d - mat.b * mat.c;
    if sx == 0.0 || det == 0.0 {
        return 0.0;
    }
    let k = (mat.a * mat.c + mat.b * mat.d) / det;
    k.atan().to_degrees()
}

/// Set the element's rotation to `deg`, keeping the decomposed scale AND
/// shear (M = R . ShearX . Scale), rotated about the evaluated bbox center
/// so the object stays in place. For a shear-free input (k = 0) this is
/// byte-identical to the prior rotate-and-scale matrix.
fn prop_rotated_transform(
    mat: crate::geometry::element::Transform,
    local_bbox: (f64, f64, f64, f64),
    deg: f64,
) -> crate::geometry::element::Transform {
    use crate::geometry::element::Transform;
    let sx = (mat.a * mat.a + mat.b * mat.b).sqrt();
    let det = mat.a * mat.d - mat.b * mat.c;
    let sy = if sx != 0.0 { det / sx } else { 0.0 };
    let k = if det != 0.0 { (mat.a * mat.c + mat.b * mat.d) / det } else { 0.0 };
    let rad = deg.to_radians();
    let (cos_a, sin_a) = (rad.cos(), rad.sin());
    let rotated = Transform {
        a: sx * cos_a,
        b: sx * sin_a,
        c: sy * (k * cos_a - sin_a),
        d: sy * (k * sin_a + cos_a),
        e: mat.e,
        f: mat.f,
    };
    let old = prop_aabb_through(local_bbox, &mat);
    let new = prop_aabb_through(local_bbox, &rotated);
    let (ocx, ocy) = (old.0 + old.2 / 2.0, old.1 + old.3 / 2.0);
    let (ncx, ncy) = (new.0 + new.2 / 2.0, new.1 + new.3 / 2.0);
    Transform { e: rotated.e + (ocx - ncx), f: rotated.f + (ocy - ncy), ..rotated }
}

/// Set the element's shear angle to `deg`, keeping the decomposed rotation
/// and scale (M = R . ShearX . Scale), re-anchored about the evaluated bbox
/// center so the object stays put.
fn prop_sheared_transform(
    mat: crate::geometry::element::Transform,
    local_bbox: (f64, f64, f64, f64),
    deg: f64,
) -> crate::geometry::element::Transform {
    use crate::geometry::element::Transform;
    let sx = (mat.a * mat.a + mat.b * mat.b).sqrt();
    if sx == 0.0 {
        return mat;
    }
    let theta = mat.b.atan2(mat.a);
    let det = mat.a * mat.d - mat.b * mat.c;
    let sy = det / sx;
    let k = deg.to_radians().tan();
    let (cos_t, sin_t) = (theta.cos(), theta.sin());
    let sheared = Transform {
        a: sx * cos_t,
        b: sx * sin_t,
        c: sy * (k * cos_t - sin_t),
        d: sy * (k * sin_t + cos_t),
        e: mat.e,
        f: mat.f,
    };
    let old = prop_aabb_through(local_bbox, &mat);
    let new = prop_aabb_through(local_bbox, &sheared);
    let (ocx, ocy) = (old.0 + old.2 / 2.0, old.1 + old.3 / 2.0);
    let (ncx, ncy) = (new.0 + new.2 / 2.0, new.1 + new.3 / 2.0);
    Transform { e: sheared.e + (ocx - ncx), f: sheared.f + (ocy - ncy), ..sheared }
}

/// Document-space horizontal shear by `deg` about the pivot (px, py), as a
/// 2x3 transform. Maps (x, y) -> (x + k*(y - py), y) with k = tan(deg). Used
/// to shear a multi-selection as a group about its bbox center (pre-multiplied
/// onto each element transform).
fn prop_shear_about_pivot(deg: f64, _px: f64, py: f64) -> crate::geometry::element::Transform {
    use crate::geometry::element::Transform;
    let k = deg.to_radians().tan();
    Transform { a: 1.0, b: 0.0, c: k, d: 1.0, e: -k * py, f: 0.0 }
}

/// Apply a Properties-panel field edit to the selection (decision-5 Part B.2):
/// the reference's `apply_properties_field`. `key` is the panel key
/// (`prop_x` …). x/y move (any selection); w/h scale local axes (single) or
/// the group (multi); rotation and shear are absolute about the bbox center
/// (single) or a group delta (multi); opacity/blend set on every selected
/// element. `constrain` is the panel's `prop_constrain`. A key outside
/// [`FIELD_KEYS`], an empty selection, or a value that is not a number (or,
/// for blend, a mode name) writes nothing.
///
/// ⚠️ x/y belong to the S-3 transform-blind class: `move_selection` adds the
/// page delta to each element's LOCAL geometry, so a transformed element's
/// box does not land on the typed value. The reference and Swift read the
/// same (`test_properties_panel.py` records it as a strict xfail).
pub fn apply_field(model: &mut Model, key: &str, val: &Value, constrain: bool) {
    let num = || -> Option<f64> {
        if let Some(n) = val.as_f64() {
            return Some(n);
        }
        if let Some(s) = val.as_str() {
            return value_to_json(&eval(s, &json!({})))
                .as_f64();
        }
        None
    };
    let doc = model.document().clone();
    if doc.selection.is_empty() {
        return;
    }
    let bbox = selection_evaluated_bounds(&doc);
    match key {
        "prop_x" => {
            if let Some(v) = num() {
                Controller::move_selection(model, v - bbox.0, 0.0);
            }
        }
        "prop_y" => {
            if let Some(v) = num() {
                Controller::move_selection(model, 0.0, v - bbox.1);
            }
        }
        "prop_opacity" => {
            if let Some(v) = num() {
                let op = (v / 100.0).clamp(0.0, 1.0);
                let mut nd = doc.clone();
                for es in &doc.selection {
                    if let Some(e) = doc.get_element(&es.path) {
                        let mut ne = e.clone();
                        ne.common_mut().opacity = op;
                        nd = nd.replace_element(&es.path, ne);
                    }
                }
                model.edit_document(nd);
            }
        }
        "prop_blend" => {
            if let Some(s) = val.as_str() {
                if let Ok(bm) = serde_json::from_value::<crate::geometry::element::BlendMode>(
                    serde_json::Value::String(s.to_string()),
                ) {
                    let mut nd = doc.clone();
                    for es in &doc.selection {
                        if let Some(e) = doc.get_element(&es.path) {
                            let mut ne = e.clone();
                            ne.common_mut().mode = bm;
                            nd = nd.replace_element(&es.path, ne);
                        }
                    }
                    model.edit_document(nd);
                }
            }
        }
        "prop_w" | "prop_h" | "prop_rotation" | "prop_shear" => {
            if doc.selection.len() != 1 {
                // MULTI: transform the whole selection as a group about its
                // bbox (doc-space — no single local frame). W/H scale about
                // the bbox top-left; rotation rotates rigidly about the bbox
                // center by the delta from the first element's angle; shear
                // shears horizontally about the bbox center by the same delta.
                // Each element transform is pre-multiplied by the group.
                if doc.selection.is_empty() {
                    return;
                }
                let group = match key {
                    "prop_w" => {
                        let Some(v) = num() else { return };
                        if bbox.2 <= 0.0 {
                            return;
                        }
                        let r = v / bbox.2;
                        Transform::scale(r, if constrain { r } else { 1.0 })
                            .around_point(bbox.0, bbox.1)
                    }
                    "prop_h" => {
                        let Some(v) = num() else { return };
                        if bbox.3 <= 0.0 {
                            return;
                        }
                        let r = v / bbox.3;
                        Transform::scale(if constrain { r } else { 1.0 }, r)
                            .around_point(bbox.0, bbox.1)
                    }
                    "prop_shear" => {
                        let Some(v) = num() else { return };
                        let cur = doc.selection.first()
                            .and_then(|es| doc.get_element(&es.path))
                            .and_then(|e| e.transform().copied())
                            .map(|t| prop_shear_angle_deg(&t))
                            .unwrap_or(0.0);
                        let cx = bbox.0 + bbox.2 / 2.0;
                        let cy = bbox.1 + bbox.3 / 2.0;
                        prop_shear_about_pivot(v - cur, cx, cy)
                    }
                    _ => {
                        let Some(v) = num() else { return };
                        let cur = doc.selection.first()
                            .and_then(|es| doc.get_element(&es.path))
                            .and_then(|e| e.transform().copied())
                            .map(|t| t.b.atan2(t.a).to_degrees())
                            .unwrap_or(0.0);
                        let cx = bbox.0 + bbox.2 / 2.0;
                        let cy = bbox.1 + bbox.3 / 2.0;
                        Transform::rotate(v - cur).around_point(cx, cy)
                    }
                };
                let mut nd = doc.clone();
                for es in &doc.selection {
                    if let Some(e) = doc.get_element(&es.path) {
                        let old = e.transform().copied().unwrap_or(Transform::IDENTITY);
                        let mut ne = e.clone();
                        ne.common_mut().transform = Some(group.multiply(&old));
                        nd = nd.replace_element(&es.path, ne);
                    }
                }
                model.edit_document(nd);
                return;
            }
            let es = &doc.selection[0];
            let Some(e) = doc.get_element(&es.path) else { return };
            let local = e.geometric_bounds();
            let mat = e.transform().copied().unwrap_or(Transform::IDENTITY);
            let new_t = match key {
                "prop_w" => {
                    let Some(v) = num() else { return };
                    if bbox.2 <= 0.0 {
                        return;
                    }
                    let r = v / bbox.2;
                    prop_scaled_transform(mat, local, r, if constrain { r } else { 1.0 })
                }
                "prop_h" => {
                    let Some(v) = num() else { return };
                    if bbox.3 <= 0.0 {
                        return;
                    }
                    let r = v / bbox.3;
                    prop_scaled_transform(mat, local, if constrain { r } else { 1.0 }, r)
                }
                "prop_shear" => {
                    let Some(v) = num() else { return };
                    prop_sheared_transform(mat, local, v)
                }
                _ => {
                    let Some(v) = num() else { return };
                    prop_rotated_transform(mat, local, v)
                }
            };
            let mut ne = e.clone();
            ne.common_mut().transform = Some(new_t);
            let nd = doc.replace_element(&es.path, ne);
            model.edit_document(nd);
        }
        _ => {}
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::document::{Document, ElementSelection};
    use crate::geometry::element::{CommonProps, Element, LayerElem, RectElem};
    use crate::interpreter::workspace::Workspace;

    fn root() -> &'static str {
        concat!(env!("CARGO_MANIFEST_DIR"), "/..")
    }

    /// **The keys whose write applies are the reference's**, read from the
    /// set literal inside `subscribe_properties_panel`, never re-typed. The
    /// literal is a SET, so the comparison is too; the order here is the
    /// panel's.
    #[test]
    fn the_field_keys_are_the_references() {
        let src = std::fs::read_to_string(format!("{}/workspace_interpreter/effects.py", root()))
            .expect("effects.py is readable");
        let def = "def subscribe_properties_panel(";
        assert_eq!(src.matches(def).count(), 1);
        let after = &src[src.find(def).unwrap()..];
        let head = "fields = {";
        let start = after.find(head).expect("the fields literal") + head.len();
        let body = &after[start..start + after[start..].find('}').unwrap()];
        let mut want: Vec<String> = body.split(',').map(str::trim).filter(|s| !s.is_empty())
            .map(|s| {
                assert!(s.len() > 2 && s.starts_with('"') && s.ends_with('"'), "{s:?}");
                format!("prop_{}", &s[1..s.len() - 1])
            })
            .collect();
        want.sort();
        let mut got: Vec<String> = FIELD_KEYS.iter().map(|k| k.to_string()).collect();
        got.sort();
        assert_eq!(got, want);
        for k in FIELD_KEYS {
            assert!(is_field_key(k));
        }
        for k in ["prop_constrain", "x", "stroke_cap", ""] {
            assert!(!is_field_key(k), "{k:?}");
        }
    }

    /// Every field key is a declared Properties state key, and the display
    /// never computes `prop_constrain`, which is a stored preference.
    #[test]
    fn the_display_computes_exactly_the_field_keys() {
        let ws = Workspace::load().unwrap();
        let state = ws.panel(PROPERTIES_PANEL).unwrap()["state"].as_object().unwrap();
        let shown = live_values(&Document::default());
        let mut keys: Vec<&str> = shown.keys().map(String::as_str).collect();
        keys.sort();
        let mut want = FIELD_KEYS.to_vec();
        want.sort();
        assert_eq!(keys, want);
        for k in FIELD_KEYS {
            assert!(state.contains_key(k), "{k} is not declared in properties.yaml");
        }
        assert!(state.contains_key("prop_constrain"));
    }

    /// **Nothing selected shows the declared defaults**, read from the spec.
    #[test]
    fn nothing_selected_shows_the_declared_defaults() {
        let ws = Workspace::load().unwrap();
        let state = &ws.panel(PROPERTIES_PANEL).unwrap()["state"];
        let shown = live_values(&Document::default());
        for k in FIELD_KEYS {
            let want = &state[k]["default"];
            let got = &shown[k];
            let same = match (got.as_f64(), want.as_f64()) {
                (Some(a), Some(b)) => a == b,
                _ => got == want,
            };
            assert!(same, "{k}: shows {got}, declares {want}");
        }
    }

    fn one_rect(x: f64, y: f64, w: f64, h: f64) -> Model {
        let rect = Element::Rect(RectElem {
            x, y, width: w, height: h, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        });
        let layer = Element::Layer(LayerElem {
            children: vec![std::rc::Rc::new(rect)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { name: Some("L".into()), ..Default::default() },
        });
        let doc = Document { layers: vec![layer], selected_layer: 0,
                             selection: vec![ElementSelection::all(vec![0, 0])],
                             ..Document::default() };
        let mut model = Model::default();
        model.set_document_for_test(doc);
        model
    }

    /// The box is shown to two decimals, and an x edit lands where it was
    /// typed on an untransformed rect.
    #[test]
    fn the_box_is_shown_rounded_and_an_x_edit_lands() {
        let mut model = one_rect(10.004, 20.126, 30.0, 40.0);
        let shown = live_values(model.document());
        assert_eq!(shown["prop_x"], json!(10.0));
        assert_eq!(shown["prop_y"], json!(20.13));
        apply_field(&mut model, "prop_x", &json!(40.0), false);
        assert_eq!(selection_evaluated_bounds(model.document()).0, 40.0);
        assert_eq!(live_values(model.document())["prop_x"], json!(40.0));
    }

    /// AN X EDIT LANDS WHERE IT WAS TYPED ON A **TRANSFORMED** SELECTION.
    ///
    /// ⛔ THIS ARM COULD NOT HAVE BEEN WRITTEN BEFORE 2026-09-18. The
    /// wave-2b block recorded the limit in its own words — *"the X oracle
    /// holds only on an untransformed selection: X/Y belongs to the S-3
    /// class"* — and the calibrated fixture carries no transform precisely
    /// because of it. `apply_field` computes `v - bbox.0`, a DOCUMENT-space
    /// delta off the evaluated bounds, and hands it to `move_selection`,
    /// which was transform-blind: on a rotated rect the element travelled
    /// along its own axes and the box did not land on the typed number.
    /// S-3 (#188) converts that delta, so the oracle now holds for every
    /// element in the class, and the limit is CLOSED rather than filed.
    ///
    /// Rotation is chosen so the linear part is not the identity and
    /// `e = f = 0` does not hide a mistreated translation; the assertion is
    /// on the EVALUATED bounds, which is what the panel actually shows.
    /// Twin: JasSwift `anXEditLandsOnATransformedSelection`.
    #[test]
    fn an_x_edit_lands_on_a_transformed_selection() {
        for (name, t) in [
            ("rotated", Transform::rotate(30.0)),
            ("scaled", Transform::scale(2.0, 3.0)),
            ("rotated and translated",
             Transform::translate(50.0, 60.0).multiply(&Transform::rotate(30.0))),
        ] {
            let mut model = one_rect(10.0, 20.0, 30.0, 40.0);
            let mut doc = model.document().clone();
            let mut elem = doc.get_element(&vec![0, 0]).unwrap().clone();
            elem.common_mut().transform = Some(t);
            doc = doc.replace_element(&vec![0, 0], elem);
            model.set_document_for_test(doc);

            apply_field(&mut model, "prop_x", &json!(40.0), false);
            let landed = selection_evaluated_bounds(model.document()).0;
            assert!((landed - 40.0).abs() < 1e-9,
                    "{name}: x landed at {landed}, typed 40.0");
            assert_eq!(live_values(model.document())["prop_x"], json!(40.0), "{name}");
        }
    }

    /// A key outside the eight, and a value that is not a number, write
    /// nothing.
    #[test]
    fn a_key_or_value_the_panel_does_not_own_writes_nothing() {
        let mut model = one_rect(10.0, 20.0, 30.0, 40.0);
        let json_of = |m: &Model| crate::geometry::test_json::document_to_test_json(m.document());
        let before = json_of(&model);
        let generation = model.generation();
        for (k, v) in [("prop_constrain", json!(true)), ("x", json!(40.0)),
                       ("prop_x", json!("abc")), ("prop_blend", json!("no_such_mode"))] {
            apply_field(&mut model, k, &v, false);
            assert_eq!(json_of(&model), before, "{k} = {v}");
            assert_eq!(model.generation(), generation, "{k} = {v} wrote the document");
        }
    }
}
