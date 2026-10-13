//! The active colour's write to the model, hosted without a web dependency.
//!
//! The law is the reference's `subscribe_active_color`
//! (`workspace_interpreter/effects.py`): a write to `state.fill_color` or
//! `state.stroke_color` sets the model's new-element default for that side and
//! recolours every selected element's matching side, keeping its opacity and,
//! for a stroke, every other stroke attribute. A `null` clears that side
//! outright (it is not a recolour). It applies by KEY, never by `fill_on_top`:
//! a write to both keys (`reset_fill_stroke`, a swap) lands on both sides.
//!
//! The engine calls [`apply_active_colour`] from its effect host's
//! `global_written` hook, and from the Color panel's value commit, which edits
//! the colour slice rather than running an effect. Until 2026-10-12 the engine
//! had no counterpart at all, so on Windows every Color act moved the panel and
//! never the document. The web app keeps its own app-level defaults beside the
//! model's (`renderer::set_app_state_field`), and shares the two recolour
//! rules below with this module.

use serde_json::Value;

use crate::document::controller::Controller;
use crate::document::model::Model;
use crate::geometry::element::{Color, Fill, Stroke};

/// The two `state.*` keys whose write reaches the model, in the reference's
/// order (`store.subscribe(["fill_color", "stroke_color"], ...)`).
pub const ACTIVE_COLOUR_KEYS: [&str; 2] = ["fill_color", "stroke_color"];

/// A stroke with `color` replaced and every other attribute preserved.
/// `None` (nothing to recolour) becomes a plain 1pt stroke in that colour.
/// The reference's `stroke_law.recolor_stroke`; Swift's `recolorStroke`.
pub fn recolor_stroke(base: Option<Stroke>, color: Color) -> Stroke {
    match base {
        Some(mut s) => { s.color = color; s }
        None => Stroke::new(color, 1.0),
    }
}

/// A fill with `color` replaced and its opacity preserved.
/// The reference's `stroke_law.recolor_fill`.
pub fn recolor_fill(base: Option<Fill>, color: Color) -> Fill {
    match base {
        Some(mut f) => { f.color = color; f }
        None => Fill::new(color),
    }
}

/// Apply the value now held under `key` (one of [`ACTIVE_COLOUR_KEYS`]) to the
/// model: its default for that side, and the selection's. A string that is
/// not a colour, or any other non-null value, changes nothing, as in the
/// reference. Returns whether `key` was one this law owns.
///
/// At most ONE document edit, an `edit_document` (through `Controller`), so it
/// joins a bracket that is open and is its own undo step when none is.
pub fn apply_active_colour(model: &mut Model, key: &str, value: &Value) -> bool {
    let fill_side = match key {
        "fill_color" => true,
        "stroke_color" => false,
        _ => return false,
    };
    let colour = match value {
        Value::Null => None,
        Value::String(s) => match Color::from_hex(s) {
            Some(c) => Some(c),
            None => return true,
        },
        _ => return true,
    };
    let selected = !model.document().selection.is_empty();
    match (fill_side, colour) {
        (true, Some(c)) => {
            model.default_fill = Some(recolor_fill(model.default_fill, c));
            if selected {
                Controller::map_selection_fill(model, |f| Some(recolor_fill(f, c)));
            }
        }
        (true, None) => {
            model.default_fill = None;
            if selected {
                Controller::set_selection_fill(model, None);
            }
        }
        (false, Some(c)) => {
            model.default_stroke = Some(recolor_stroke(model.default_stroke, c));
            if selected {
                Controller::map_selection_stroke(model, |s| Some(recolor_stroke(s, c)));
            }
        }
        (false, None) => {
            model.default_stroke = None;
            if selected {
                Controller::set_selection_stroke(model, None);
            }
        }
    }
    true
}
