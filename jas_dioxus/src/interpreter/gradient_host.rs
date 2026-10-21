//! The Gradient panel's write to the selection, hosted without a web
//! dependency.
//!
//! The law is `transcripts/GRADIENT.md` §Fill-type coupling: a Gradient panel
//! edit writes a gradient onto the ACTIVE attribute (fill or stroke, per
//! `fill_on_top`) of every selected element, and when that attribute is solid
//! or none the first edit PROMOTES it, from the seed table's gradient
//! (`[C@0, #ffffff@100]`, linear, 0°, 100 %, classic, no dither). There is no
//! reference law: the Python interpreter has no Gradient panel write.
//!
//! This module is the ONE Rust implementation of the three pieces of that law:
//! reading what the selection holds ([`selection_gradient`]), the seed
//! ([`seed_gradient`]) and the write ([`apply_gradient_to_selection`]). The web
//! app keeps a panel struct, syncs it from the selection when the selection
//! changes and applies the whole struct after a `gradient_*` write; it calls
//! all three from `AppState`. The engine keeps no such struct, so on each
//! `gradient_*` global write it takes its base from the DOCUMENT, applies the
//! one written key, and writes the result ([`apply_render_key`]) — the
//! W2b-7 rule that a panel's scope comes from the document, not the store.
//! Until 2026-10-18 the engine had no `gradient_*` branch at all: a Gradient
//! panel act replayed ACCEPTED and changed nothing.

use crate::document::controller::Controller;
use crate::document::document::Document;
use crate::document::model::Model;
use crate::geometry::element::{Color, Gradient, GradientStop};
use serde_json::{json, Value};

/// The Gradient panel's id: the store scope its fields live in.
pub const GRADIENT_PANEL: &str = "gradient_panel_content";

/// The global `state.*` keys whose write reaches the selection: the six the
/// panel's widgets and library tiles `set`. Swift's `gradientRenderKeys` is
/// the same set.
pub const GRADIENT_RENDER_KEYS: &[&str] = &[
    "gradient_type", "gradient_angle", "gradient_aspect_ratio",
    "gradient_method", "gradient_dither", "gradient_stroke_sub_mode",
];

/// True when `key` is one of [`GRADIENT_RENDER_KEYS`].
pub fn is_render_key(key: &str) -> bool {
    GRADIENT_RENDER_KEYS.contains(&key)
}

/// What the selection's active attribute holds, per GRADIENT.md
/// §Multi-selection.
#[derive(Debug, Clone, PartialEq)]
pub enum SelectionGradient {
    /// Nothing is selected.
    Empty,
    /// The elements disagree: two distinct gradients, or some gradient and
    /// some solid/none.
    Mixed,
    /// Every selected element carries this gradient.
    Uniform(Gradient),
    /// Every selected element is solid or none; the colour is the FIRST
    /// element's solid colour, the seed's first stop (`None` for none).
    Solid(Option<Color>),
}

/// Read the active attribute (`fill_on_top` ⇒ fill, else stroke) of every
/// selected element.
pub fn selection_gradient(doc: &Document, fill_on_top: bool) -> SelectionGradient {
    let mut first: Option<Option<Gradient>> = None;
    let mut first_solid: Option<Color> = None;
    for es in &doc.selection {
        let Some(elem) = doc.get_element(&es.path) else { continue };
        let g = if fill_on_top { elem.fill_gradient().cloned() } else { elem.stroke_gradient().cloned() };
        if first_solid.is_none() && g.is_none() {
            first_solid = if fill_on_top { elem.fill().map(|f| f.color) } else { elem.stroke().map(|s| s.color) };
        }
        match &first {
            None => first = Some(g),
            Some(prev) if *prev != g => return SelectionGradient::Mixed,
            Some(_) => {}
        }
    }
    match first {
        None => SelectionGradient::Empty,
        Some(Some(g)) => SelectionGradient::Uniform(g),
        Some(None) => SelectionGradient::Solid(first_solid),
    }
}

/// The seed table's gradient: from a solid colour `C`, `[C@0, #ffffff@100]`;
/// from none, `[#000000@0, #ffffff@100]`; linear, 0°, 100 %, classic, no
/// dither, within.
pub fn seed_gradient(solid: Option<Color>) -> Gradient {
    let stop = |color, location| GradientStop { color, opacity: 100.0, location, midpoint_to_next: 50.0 };
    Gradient {
        stops: vec![stop(solid.unwrap_or(Color::BLACK), 0.0), stop(Color::WHITE, 100.0)],
        ..Gradient::default()
    }
}

/// Write `g` onto the active attribute of every selected element. The solid
/// `fill` / `stroke` is left alone: it is the demote target.
pub fn apply_gradient_to_selection(model: &mut Model, fill_on_top: bool, g: Gradient) {
    let boxed = Some(Box::new(g));
    if fill_on_top {
        Controller::set_selection_fill_gradient(model, boxed);
    } else {
        Controller::set_selection_stroke_gradient(model, boxed);
    }
}

/// Set the field a render key names on `g` from a stored value. An enum
/// value outside its declared set, or a value of the wrong type, is refused
/// (returns false) and `g` is unchanged.
pub fn set_render_field(g: &mut Gradient, key: &str, value: &Value) -> bool {
    fn parse<T: serde::de::DeserializeOwned>(v: &Value) -> Option<T> {
        v.as_str().and_then(|s| serde_json::from_value(Value::String(s.into())).ok())
    }
    match key {
        "gradient_type" => parse(value).map(|t| g.gtype = t).is_some(),
        "gradient_angle" => value.as_f64().map(|n| g.angle = n).is_some(),
        "gradient_aspect_ratio" => value.as_f64().map(|n| g.aspect_ratio = n).is_some(),
        "gradient_method" => parse(value).map(|m| g.method = m).is_some(),
        "gradient_dither" => value.as_bool().map(|b| g.dither = b).is_some(),
        "gradient_stroke_sub_mode" => parse(value).map(|m| g.stroke_sub_mode = m).is_some(),
        _ => false,
    }
}

/// The engine's write: a `gradient_*` global was just written with `value`.
/// The base is what the selection holds — its shared gradient, or the seed
/// when it is solid/none (the promotion) — and the one key is applied on top.
/// A MIXED selection takes `mixed_base`, the panel as the store holds it,
/// because there is no single gradient to start from (the web app applies its
/// panel there too). Nothing selected writes nothing. Returns whether a
/// gradient was written.
pub fn apply_render_key(model: &mut Model, fill_on_top: bool, key: &str, value: &Value,
                        mixed_base: impl FnOnce() -> Gradient) -> bool {
    let mut g = match selection_gradient(model.document(), fill_on_top) {
        SelectionGradient::Empty => return false,
        SelectionGradient::Uniform(g) => g,
        SelectionGradient::Solid(c) => seed_gradient(c),
        SelectionGradient::Mixed => mixed_base(),
    };
    if !set_render_field(&mut g, key, value) {
        return false;
    }
    apply_gradient_to_selection(model, fill_on_top, g);
    true
}

/// The panel as an engine's store holds it, for a mixed selection: the six
/// render globals over the default gradient, with the panel scope's `stops`
/// (`{ color: "#rrggbb", opacity, location, midpoint_to_next }`, the YAML's
/// shape) when they parse, else the seed's.
pub fn gradient_from_store(store: &crate::interpreter::state_store::StateStore, panel_id: &str) -> Gradient {
    let mut g = seed_gradient(None);
    for key in GRADIENT_RENDER_KEYS {
        set_render_field(&mut g, key, store.get(key));
    }
    let stops: Option<Vec<GradientStop>> = store.get_panel(panel_id, "stops").as_array().and_then(|a| {
        a.iter().map(|s| Some(GradientStop {
            color: Color::from_hex(s.get("color")?.as_str()?)?,
            opacity: s.get("opacity")?.as_f64()?,
            location: s.get("location")?.as_f64()?,
            midpoint_to_next: s.get("midpoint_to_next").and_then(Value::as_f64).unwrap_or(50.0),
        })).collect()
    });
    if let Some(stops) = stops.filter(|s| !s.is_empty()) {
        g.stops = stops;
    }
    g
}

/// The Gradient panel's fields as the SELECTION holds them, for the engine's
/// panel scope (the role `stroke_host::live_values` plays for Stroke). A
/// uniform gradient reads as itself; a solid/none selection reads as the seed
/// its first edit will promote from. Nothing selected, or a mixed selection,
/// returns nothing, so the store's panel stands, as the web's
/// `sync_gradient_panel_from_selection` leaves it. `stops` is the YAML's shape,
/// the one [`gradient_from_store`] parses back.
pub fn live_values(doc: &Document, fill_on_top: bool) -> serde_json::Map<String, Value> {
    let mut m = serde_json::Map::new();
    let g = match selection_gradient(doc, fill_on_top) {
        SelectionGradient::Empty | SelectionGradient::Mixed => return m,
        SelectionGradient::Uniform(g) => g,
        SelectionGradient::Solid(c) => seed_gradient(c),
    };
    fn name(v: impl serde::Serialize) -> Value { serde_json::to_value(v).unwrap_or(Value::Null) }
    m.insert("type".into(), name(g.gtype));
    m.insert("angle".into(), json!(g.angle));
    m.insert("aspect_ratio".into(), json!(g.aspect_ratio));
    m.insert("method".into(), name(g.method));
    m.insert("dither".into(), json!(g.dither));
    m.insert("stroke_sub_mode".into(), name(g.stroke_sub_mode));
    m.insert("stops".into(), Value::Array(g.stops.iter().map(|s| json!({
        "color": format!("#{}", s.color.to_hex()),
        "opacity": s.opacity,
        "location": s.location,
        "midpoint_to_next": s.midpoint_to_next,
    })).collect()));
    m
}

/// The global keys the two stop combos `set` (their bind is an indexed path,
/// which the widget-event layer never writes), each with the stop field it
/// edits. Not render keys: they need the selected stop's index.
pub const STOP_KEYS: &[(&str, &str)] = &[
    ("gradient_stop_opacity", "opacity"),
    ("gradient_stop_location", "location"),
];

/// The stop field a [`STOP_KEYS`] key edits, or `None` for any other key.
pub fn stop_field(key: &str) -> Option<&'static str> {
    STOP_KEYS.iter().find(|(k, _)| *k == key).map(|(_, f)| *f)
}

/// The engine's stop write: stop `index` of the selection's gradient (the
/// same base as [`apply_render_key`]: its own gradient, the seed when it is
/// solid/none, `mixed_base` when mixed) gets `field` by [`edit_stop`].
/// Returns the index the stop now sits at, or `None` when nothing is
/// selected or the law refuses; nothing is written then.
pub fn apply_stop_edit(model: &mut Model, fill_on_top: bool, field: &str, value: &Value,
                       index: i64, mixed_base: impl FnOnce() -> Gradient) -> Option<usize> {
    let mut g = match selection_gradient(model.document(), fill_on_top) {
        SelectionGradient::Empty => return None,
        SelectionGradient::Uniform(g) => g,
        SelectionGradient::Solid(c) => seed_gradient(c),
        SelectionGradient::Mixed => mixed_base(),
    };
    let (stops, moved) = edit_stop(&g.stops, index, field, value)?;
    g.stops = stops;
    apply_gradient_to_selection(model, fill_on_top, g);
    Some(moved)
}

/// The Gradient panel's stop-edit law (GRADIENT.md, STOP_OPACITY_COMBO and
/// STOP_LOCATION_COMBO; the reference is `gradient_law.edit_stop`, pinned by
/// `test_fixtures/gradient_stop/stop_edit.json`). Returns `stops` with stop
/// `index`'s `field` set to `value`, and the index that stop now sits at;
/// `None` (nothing written) when `index` names no stop, `field` is not
/// `opacity` or `location`, or `value` is not a number in [0, 100].
///
/// `opacity` is a plain set. `location` sets, then re-sorts STABLY by
/// location (a tie does not cross); the index follows the moved stop, and
/// every stop whose NEXT stop changed resets `midpoint_to_next` to 50.
pub fn edit_stop(stops: &[GradientStop], index: i64, field: &str, value: &Value)
                 -> Option<(Vec<GradientStop>, usize)> {
    let i = usize::try_from(index).ok().filter(|&i| i < stops.len())?;
    let v = value.as_f64().filter(|v| (0.0..=100.0).contains(v))?;
    let mut out = stops.to_vec();
    match field {
        "opacity" => { out[i].opacity = v; return Some((out, i)); }
        "location" => out[i].location = v,
        _ => return None,
    }
    // Sort positions, not stops, so "the next stop changed" compares
    // identities (two stops may be equal as values). `sort_by` is stable.
    let mut order: Vec<usize> = (0..out.len()).collect();
    order.sort_by(|&a, &b| out[a].location.total_cmp(&out[b].location));
    for (k, &p) in order.iter().enumerate() {
        let old_next = (p + 1 < out.len()).then_some(p + 1);
        if order.get(k + 1).copied() != old_next {
            out[p].midpoint_to_next = 50.0;
        }
    }
    let moved = order.iter().position(|&p| p == i)?;
    Some((order.iter().map(|&p| out[p]).collect(), moved))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::document::ElementSelection;
    use crate::geometry::element::{CommonProps, Element, Fill, GradientType, LayerElem, RectElem};
    use serde_json::json;

    const BLUE: Color = Color::rgb(0.0, 0.0, 1.0);
    const RED: Color = Color::rgb(1.0, 0.0, 0.0);

    fn rect(fill: Option<Color>) -> Element {
        Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: fill.map(Fill::new), stroke: None,
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        })
    }

    /// One layer holding `elems`, with `selected` (child indices) selected.
    fn model_with(elems: Vec<Element>, selected: &[usize]) -> Model {
        let layer = Element::Layer(LayerElem {
            children: elems.into_iter().map(std::rc::Rc::new).collect(),
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let selection = selected.iter().map(|&i| ElementSelection::all(vec![0, i])).collect();
        let doc = Document { layers: vec![layer], selected_layer: 0, selection, ..Document::default() };
        let mut model = Model::default();
        model.set_document_for_test(doc);
        model
    }

    fn select(m: &mut Model, selected: &[usize]) {
        let mut doc = m.document().clone();
        doc.selection = selected.iter().map(|&i| ElementSelection::all(vec![0, i])).collect();
        m.set_document_for_test(doc);
    }

    fn fill_gradient(m: &Model, i: usize) -> Option<Gradient> {
        m.document().get_element(&vec![0, i]).and_then(|e| e.fill_gradient().cloned())
    }

    #[test]
    fn the_seed_is_the_solid_colour_then_white_and_none_seeds_black() {
        let g = seed_gradient(Some(BLUE));
        assert_eq!(g.stops.iter().map(|s| (s.color, s.location)).collect::<Vec<_>>(),
                   vec![(BLUE, 0.0), (Color::WHITE, 100.0)]);
        assert_eq!((g.gtype, g.angle, g.aspect_ratio, g.dither), (GradientType::Linear, 0.0, 100.0, false));
        assert_eq!(seed_gradient(None).stops[0].color, Color::BLACK);
    }

    #[test]
    fn a_first_edit_on_a_solid_selection_promotes_from_the_seed_with_the_edit_applied() {
        let mut m = model_with(vec![rect(Some(BLUE))], &[0]);
        assert!(apply_render_key(&mut m, true, "gradient_type", &json!("radial"), || panic!("not mixed")));
        let mut want = seed_gradient(Some(BLUE));
        want.gtype = GradientType::Radial;
        assert_eq!(fill_gradient(&m, 0), Some(want));
    }

    #[test]
    fn an_edit_on_a_uniform_gradient_keeps_its_stops_and_changes_one_field() {
        let mut m = model_with(vec![rect(Some(BLUE))], &[0]);
        let mut held = seed_gradient(Some(RED));
        held.angle = 30.0;
        apply_gradient_to_selection(&mut m, true, held.clone());
        assert!(apply_render_key(&mut m, true, "gradient_aspect_ratio", &json!(150.0), || panic!("not mixed")));
        held.aspect_ratio = 150.0;
        assert_eq!(fill_gradient(&m, 0), Some(held));
    }

    #[test]
    fn a_mixed_selection_takes_the_panel_and_nothing_selected_writes_nothing() {
        // Element 0 holds a gradient, element 1 is solid: both selected is mixed.
        let mut m2 = model_with(vec![rect(Some(BLUE)), rect(Some(RED))], &[0]);
        apply_gradient_to_selection(&mut m2, true, seed_gradient(Some(RED)));
        select(&mut m2, &[0, 1]);
        assert_eq!(selection_gradient(m2.document(), true), SelectionGradient::Mixed);
        let panel = seed_gradient(Some(Color::rgb(0.0, 1.0, 0.0)));
        assert!(apply_render_key(&mut m2, true, "gradient_dither", &json!(true), || panel.clone()));
        let mut want = panel;
        want.dither = true;
        assert_eq!((fill_gradient(&m2, 0), fill_gradient(&m2, 1)), (Some(want.clone()), Some(want)));

        let mut empty = model_with(vec![rect(Some(BLUE))], &[]);
        assert!(!apply_render_key(&mut empty, true, "gradient_type", &json!("radial"), || panic!("not mixed")));
        assert_eq!(fill_gradient(&empty, 0), None);
    }

    #[test]
    fn the_stroke_side_is_written_when_fill_is_not_on_top() {
        let mut m = model_with(vec![rect(Some(BLUE))], &[0]);
        assert!(apply_render_key(&mut m, false, "gradient_type", &json!("linear"), || panic!("not mixed")));
        let e = m.document().get_element(&vec![0, 0]).unwrap().clone();
        assert_eq!((e.fill_gradient().is_some(), e.stroke_gradient().is_some()), (false, true));
    }

    #[test]
    fn a_value_outside_its_set_is_refused_and_writes_nothing() {
        let mut m = model_with(vec![rect(Some(BLUE))], &[0]);
        assert!(!apply_render_key(&mut m, true, "gradient_type", &json!("conic"), || panic!("not mixed")));
        assert!(!apply_render_key(&mut m, true, "gradient_angle", &json!("45"), || panic!("not mixed")));
        assert_eq!(fill_gradient(&m, 0), None);
    }

    #[test]
    fn every_render_key_sets_a_distinct_field() {
        let base = seed_gradient(None);
        let values = [json!("radial"), json!(45.0), json!(150.0), json!("smooth"), json!(true), json!("along")];
        let mut outs = vec![];
        for (k, v) in GRADIENT_RENDER_KEYS.iter().zip(values.iter()) {
            let mut g = base.clone();
            assert!(set_render_field(&mut g, k, v), "{k}");
            assert_ne!(g, base, "{k} changed nothing");
            outs.push(g);
        }
        for i in 0..outs.len() {
            for j in i + 1..outs.len() {
                assert_ne!(outs[i], outs[j], "{} and {} set the same field", GRADIENT_RENDER_KEYS[i], GRADIENT_RENDER_KEYS[j]);
            }
        }
    }
    /// The Gradient panel's scope describes the SELECTION (W2b-7's law, the
    /// Gradient panel): a selected radial gradient reads as `radial`, with its
    /// own stops in the YAML's shape, not the store's black→white default.
    #[test]
    fn live_values_read_the_selected_gradient() {
        let mut m = model_with(vec![rect(Some(BLUE))], &[0]);
        assert!(apply_render_key(&mut m, true, "gradient_type", &json!("radial"), || panic!("not mixed")));
        let v = live_values(m.document(), true);
        assert_eq!(v["type"], json!("radial"), "{v:?}");
        assert_eq!(v["angle"], json!(0.0));
        assert_eq!(v["aspect_ratio"], json!(100.0));
        assert_eq!(v["method"], json!("classic"));
        assert_eq!(v["dither"], json!(false));
        assert_eq!(v["stroke_sub_mode"], json!("within"));
        assert_eq!(v["stops"], json!([
            {"color": "#0000ff", "opacity": 100.0, "location": 0.0, "midpoint_to_next": 50.0},
            {"color": "#ffffff", "opacity": 100.0, "location": 100.0, "midpoint_to_next": 50.0},
        ]));
    }

    /// The other attribute is read when the stroke is on top, and a solid
    /// selection reads as the seed (what the first edit will promote from).
    #[test]
    fn live_values_follow_fill_on_top_and_seed_a_solid_selection() {
        let mut m = model_with(vec![rect(Some(BLUE))], &[0]);
        assert!(apply_render_key(&mut m, true, "gradient_type", &json!("radial"), || panic!("not mixed")));
        let stroke = live_values(m.document(), false);
        assert_eq!(stroke["type"], json!("linear"), "no stroke ⇒ the black seed: {stroke:?}");
        assert_eq!(stroke["stops"][0]["color"], json!("#000000"));
        let solid = model_with(vec![rect(Some(RED))], &[0]);
        let v = live_values(solid.document(), true);
        assert_eq!(v["stops"][0]["color"], json!("#ff0000"), "{v:?}");
    }

    /// Nothing selected, or a mixed selection, contributes NOTHING, so the
    /// panel keeps the store's values exactly as the web sync leaves them.
    #[test]
    fn live_values_are_empty_with_no_selection_or_a_mixed_one() {
        assert!(live_values(model_with(vec![rect(Some(BLUE))], &[]).document(), true).is_empty());
        let mut m = model_with(vec![rect(Some(BLUE)), rect(Some(RED))], &[0]);
        assert!(apply_render_key(&mut m, true, "gradient_type", &json!("radial"), || panic!("not mixed")));
        select(&mut m, &[0, 1]);
        assert!(matches!(selection_gradient(m.document(), true), SelectionGradient::Mixed));
        assert!(live_values(m.document(), true).is_empty());
    }

    /// Every key is a declared Gradient panel state field, and the stops are
    /// the shape the write side's reader (`gradient_from_store`) parses back.
    #[test]
    fn live_values_name_declared_fields_and_round_trip_through_the_store_reader() {
        let ws = crate::interpreter::workspace::Workspace::load().expect("workspace");
        let spec = ws.panel(GRADIENT_PANEL).expect("gradient panel");
        let declared = spec["state"].as_object().expect("declared state");
        let mut m = model_with(vec![rect(Some(BLUE))], &[0]);
        assert!(apply_render_key(&mut m, true, "gradient_angle", &json!(30.0), || panic!("not mixed")));
        let v = live_values(m.document(), true);
        assert_eq!(v.len(), 7, "{v:?}");
        for k in v.keys() {
            assert!(declared.contains_key(k), "{k} is not a declared Gradient panel field");
        }
        let mut store = crate::interpreter::state_store::StateStore::new();
        store.init_panel(GRADIENT_PANEL, v.clone().into_iter().collect());
        assert_eq!(gradient_from_store(&store, GRADIENT_PANEL).stops, fill_gradient(&m, 0).unwrap().stops);
    }
}
