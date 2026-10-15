//! Widget commit rules: the pure part of "the user typed this into a widget,
//! what gets written to state".
//!
//! Lives outside `renderer` (which is `feature = "web"` only) so the same
//! functions the running app uses are reachable from the native
//! `algorithm_roundtrip` binary, i.e. gateable against JasSwift by
//! `scripts/cross_language_algorithms.py --algo number_commit`
//! (`test_fixtures/algorithms/number_commit.json`).

/// The value a `number_input` commit writes, or `None` to leave state
/// UNCHANGED.
///
/// Accept the text only if it is a number by the live reference's rule, then
/// clamp to the bounds the widget's YAML DECLARES. `None` means the reference
/// would have refused the write (`type_mismatch`), so nothing is written —
/// where this port previously wrote `parse().unwrap_or(0.0)`, turning "abc" and
/// a cleared field into a committed 0.
pub fn number_input_commit(text: &str, min: Option<f64>, max: Option<f64>) -> Option<f64> {
    parse_numeric_string(text).map(|v| clamp_to_declared(v, min, max))
}

/// A numeric string by the live reference's grammar — `^-?\d+(\.\d+)?$`
/// (`workspace_interpreter/schema.py`'s `_NUMBER_STR_RE`, applied by
/// `coerce_value` for a `type: number` field) — parsed to `f64`; `None` if the
/// string is not of that form.
///
/// Deliberately NARROWER than `str::parse::<f64>`, which also accepts `1e10`,
/// `+5`, `.5`, `12.`, `inf` and `NaN`. Those are what a number-typed field
/// REJECTS in the reference, and JasSwift's `coerceValue` already rejected them
/// via the same grammar; parsing them here is how a typed `inf` reached the
/// clamp (and a typed `NaN` reached `serde_json`, which stores a non-finite
/// number as `null`).
///
/// The digit test is ASCII. The reference's `\d` is Python's Unicode-aware one
/// and `float()` accepts Unicode decimal digits, so `float("\u{661}\u{662}")`
/// is 12.0 there; both active ports answer `None` for that string, because
/// Rust's and Swift's float parsers are ASCII-only. That difference is real,
/// it is NOT gated by the corpus, and it is banked as such — do not read this
/// function as claiming full agreement with the reference on non-ASCII input.
pub fn parse_numeric_string(s: &str) -> Option<f64> {
    let body = s.strip_prefix('-').unwrap_or(s);
    let (int_part, frac_part) = match body.split_once('.') {
        Some((i, f)) => (i, Some(f)),
        None => (body, None),
    };
    let all_digits = |t: &str| !t.is_empty() && t.bytes().all(|b| b.is_ascii_digit());
    if !all_digits(int_part) {
        return None;
    }
    if let Some(f) = frac_part {
        if !all_digits(f) {
            return None;
        }
    }
    s.parse::<f64>().ok()
}

/// A slider's step (WIDGET_EVENTS.md, Parsing): the nearest step from `min`
/// (or 0), half up. No step, or one that is not positive, does not snap.
/// The reference's `_snap`.
pub fn snap_to_step(v: f64, min: Option<f64>, step: Option<f64>) -> f64 {
    match step {
        Some(s) if s > 0.0 => {
            let base = min.unwrap_or(0.0);
            base + ((v - base) / s + 0.5).floor() * s
        }
        _ => v,
    }
}

/// Clamp a widget commit to the bounds its YAML DECLARES, leaving an
/// undeclared bound alone (Tracking is signed and declares neither).
///
/// One function rather than an inline pair of `if`s at each call site because
/// the call sites disagreed: the panel branch of `render_number_input`
/// clamped and the dialog branch did not, so typing 150 into the Color Picker's
/// `c` field (declared `max: 100`) committed 100 in JasSwift — whose
/// `renderNumberInput` clamps on commit — and 150 here, and that 150 then
/// reached `cmyk()`. Risk R9's widget half, transcripts/CORPUS_CENSUS.md §7.
pub fn clamp_to_declared(v: f64, min: Option<f64>, max: Option<f64>) -> f64 {
    let mut v = v;
    if let Some(lo) = min {
        if v < lo {
            v = lo;
        }
    }
    if let Some(hi) = max {
        if v > hi {
            v = hi;
        }
    }
    v
}

// ── The widget event contract (WIDGET_EVENTS.md) ─────────────────────────
//
// The native half of `workspace_interpreter/widget_event.py`: the event
// table, and the parse a committed value goes through before anything is
// written. The engine's panel door (`panel_behavior`) runs the rest of the
// procedure. `workspace_interpreter/tests/test_widget_event.py` is the
// executable meaning; `test_fixtures/widget_events/corpus.json` is what this
// port is held to.

/// The input kinds: a committed value is parsed, written, then its
/// `commit`/`change` behaviors run.
pub const INPUT_KINDS: [&str; 8] = [
    "number_input", "length_input", "text_input", "select", "icon_select", "combo_box",
    "slider", "color_bar",
];
/// The boolean kinds: a declared `click`/`change` behavior IS the press.
pub const BOOLEAN_KINDS: [&str; 2] = ["toggle", "checkbox"];
/// Synonyms on an input kind: "a value was committed".
pub const COMMIT_EVENTS: [&str; 2] = ["commit", "change"];
/// Synonyms on a boolean kind: "the widget was pressed".
pub const PRESS_EVENTS: [&str; 2] = ["click", "change"];
/// Declared on `text_input`, and never a commit.
pub const TEXT_ENTRY_EVENTS: [&str; 3] = ["input", "blur", "keydown"];
/// The item kinds: a pick names one declared item by its `value`.
pub const ITEM_KINDS: [&str; 1] = ["dropdown"];
/// A plain pick and an Alt pick. NOT synonyms: each runs its own behaviors.
pub const PICK_EVENTS: [&str; 2] = ["toggle", "alt_toggle"];
/// The check kind: a press CHECKS it and never unchecks it. Its events are
/// the press synonyms ([`PRESS_EVENTS`]).
pub const CHECK_KINDS: [&str; 1] = ["radio"];
/// The option kind: a pick names one of its `options` by `id`.
pub const OPTION_KINDS: [&str; 1] = ["radio_group"];
/// The one event an option kind raises.
pub const CHOOSE_EVENTS: [&str; 1] = ["toggle"];

/// The events `kind` may declare, in the contract's order; empty for a kind
/// outside the contract.
pub fn allowed_events(kind: &str) -> Vec<&'static str> {
    if kind == "text_input" {
        COMMIT_EVENTS.iter().chain(TEXT_ENTRY_EVENTS.iter()).copied().collect()
    } else if INPUT_KINDS.contains(&kind) {
        COMMIT_EVENTS.to_vec()
    } else if BOOLEAN_KINDS.contains(&kind) || CHECK_KINDS.contains(&kind) {
        PRESS_EVENTS.to_vec()
    } else if ITEM_KINDS.contains(&kind) {
        PICK_EVENTS.to_vec()
    } else if OPTION_KINDS.contains(&kind) {
        CHOOSE_EVENTS.to_vec()
    } else {
        vec![]
    }
}

/// A declared bound, or `None`. A bool is not a number here (serde agrees).
fn declared_bound(widget: &serde_json::Value, key: &str) -> Option<f64> {
    widget.get(key).and_then(serde_json::Value::as_f64)
}

/// An option's declared value, written as the reference's `str()` writes it,
/// so the committed text can be matched against it. The panel plan's options
/// channel sends a shell exactly this text, so what it commits back matches.
pub(crate) fn option_text(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::Null => None,
        serde_json::Value::String(s) => Some(s.clone()),
        serde_json::Value::Bool(b) => Some(if *b { "True" } else { "False" }.to_string()),
        other => Some(other.to_string()),
    }
}

/// A bare list item that is a divider between groups, never a value
/// (SCHEMA.md, `options`). The same token a menubar's `items` use.
pub const OPTION_DIVIDER: &str = "separator";

/// One item of a literal `options` list, read by the rule SCHEMA.md states:
/// `None` for a divider, `Some(None)` for an item that cannot be written (a map
/// with no `value`), else `Some(Some((value, label, glyph)))`. A bare item is an
/// option labelled by its own text.
///
/// ⛔ THE ONE HOME OF THE DIVIDER RULE. `option_rows` and the native panel
/// plan's `options` channel both read items through it, so the three readers
/// of one list cannot disagree about what a divider is.
#[allow(clippy::type_complexity)]
pub fn option_item(
    item: &serde_json::Value,
) -> Option<Option<(&serde_json::Value, String, Option<&str>)>> {
    use serde_json::Value;
    if item.as_str() == Some(OPTION_DIVIDER) {
        return None;
    }
    let (value, label, glyph) = match item.as_object() {
        Some(o) => (
            o.get("value").unwrap_or(&Value::Null),
            o.get("label").and_then(Value::as_str),
            o.get("glyph").and_then(Value::as_str),
        ),
        None => (item, None, None),
    };
    Some(option_text(value).map(|text| (value, label.map_or(text, str::to_string), glyph)))
}

/// How a literal `options` list reads (SCHEMA.md, `options`), or `None` for
/// computed options (an expression), which have no declared rows.
///
/// One row per offered item, in order: `{"kind": "option", "value": v,
/// "label": s}` (plus `"glyph"` when declared) or `{"kind": "separator"}`. An
/// item [`option_item`] cannot write is not offered. Pinned by
/// `test_fixtures/algorithms/option_rows.json`.
pub fn option_rows(options: &serde_json::Value) -> Option<Vec<serde_json::Value>> {
    use serde_json::{json, Value};
    let list = options.as_array()?;
    let mut rows = vec![];
    for item in list {
        match option_item(item) {
            None => rows.push(json!({"kind": "separator"})),
            Some(None) => {}
            Some(Some((value, label, glyph))) => {
                let mut row = json!({"kind": "option", "value": value, "label": label});
                if let Some(g) = glyph {
                    row["glyph"] = Value::String(g.to_string());
                }
                rows.push(row);
            }
        }
    }
    Some(rows)
}

/// The text a person committed, parsed by the widget's kind. `None` is a
/// refusal (`BadValue`); `Some(Value::Null)` is a cleared nullable length.
pub fn parse_commit(widget: &serde_json::Value, text: &str) -> Option<serde_json::Value> {
    use serde_json::{json, Value};
    let (lo, hi) = (declared_bound(widget, "min"), declared_bound(widget, "max"));
    match widget.get("type").and_then(Value::as_str).unwrap_or("") {
        "number_input" => number_input_commit(text, lo, hi).map(|v| json!(v)),
        "length_input" => {
            if text.trim().is_empty() {
                return (widget.get("nullable") == Some(&Value::Bool(true))).then_some(Value::Null);
            }
            let unit = widget.get("unit").and_then(Value::as_str).unwrap_or("pt");
            crate::interpreter::length::parse(text, unit)
                .map(|v| json!(clamp_to_declared(v, lo, hi)))
        }
        "text_input" => Some(json!(text)),
        // A number, clamped; snapped to `step` from `min`; clamped again, so a
        // `max` off the step grid is unreachable, as on an HTML range input.
        "slider" => number_input_commit(text, lo, hi).map(|v| {
            json!(clamp_to_declared(snap_to_step(v, lo, declared_bound(widget, "step")), lo, hi))
        }),
        // A point normalized to [0,1]² (fork B2): "u,v", each coordinate in the
        // number grammar, each clamped. The colour is
        // `color_util::color_bar_rgb(u, v)`; the parse stops at the point.
        "color_bar" => {
            let parts: Vec<&str> = text.split(',').collect();
            match parts.as_slice() {
                [u, v] => match (number_input_commit(u, Some(0.0), Some(1.0)),
                                 number_input_commit(v, Some(0.0), Some(1.0))) {
                    (Some(u), Some(v)) => Some(json!([u, v])),
                    _ => None,
                },
                _ => None,
            }
        }
        // A divider is not a row a commit can match (SCHEMA.md, `options`).
        "select" | "icon_select" => match widget.get("options").and_then(option_rows) {
            Some(rows) => rows.into_iter().find_map(|r| {
                (r["kind"] == "option" && option_text(&r["value"]).as_deref() == Some(text))
                    .then(|| r["value"].clone())
            }),
            // Computed options: the shell offered what the expression produced.
            None => Some(json!(text)),
        },
        "combo_box" => {
            if text.trim().is_empty() {
                return None;
            }
            Some(match parse_numeric_string(text) {
                Some(v) => json!(clamp_to_declared(v, lo, hi)),
                None => json!(text),
            })
        }
        _ => None,
    }
}

/// The widget's bound expression: `bind.value`, else `bind.checked`, else a
/// bare-string `bind`.
pub fn bound_target(widget: &serde_json::Value) -> Option<&str> {
    match widget.get("bind")? {
        serde_json::Value::String(s) => Some(s),
        bind => ["value", "checked"].iter().find_map(|k| bind.get(*k)?.as_str()),
    }
}

/// `(scope, key)` when the event layer may write `expr`: only
/// `panel.<ident>` and `dialog.<ident>`, with an ASCII identifier.
pub fn writable_target(expr: &str) -> Option<(&'static str, &str)> {
    let expr = expr.trim();
    for scope in ["panel", "dialog"] {
        if let Some(key) = expr.strip_prefix(scope).and_then(|r| r.strip_prefix('.')) {
            let ident = !key.is_empty()
                && key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_');
            return ident.then_some((scope, key));
        }
    }
    None
}

/// The global a panel field is two-way bound to: the `<ident>` of a bare
/// `state.<ident>` in the panel's `init:` for `key`. The bind write writes it
/// with the field (WIDGET_EVENTS.md, "The bound target").
pub fn mirrored_global<'a>(panel: &'a serde_json::Value, key: &str) -> Option<&'a str> {
    let expr = panel.get("init")?.get(key)?.as_str()?.trim();
    let ident = expr.strip_prefix("state.")?;
    (!ident.is_empty() && ident.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_'))
        .then_some(ident)
}

/// Whether an action item's action is already IN FORCE: running it now would
/// change nothing (WIDGET_EVENTS.md, "Showing an item's check").
///
/// Stated as a dry run of the action's OWN effects rather than a per-item
/// expression, so the tick cannot disagree with what a pick does. It is only
/// answerable when every effect is a `set_panel_state` NAMING this panel, the
/// one kind whose whole result is visible in the scope: the row is `true`
/// exactly when each value, evaluated now, equals the key's current value.
/// Anything else (another effect kind, an unnamed or foreign panel, `params`
/// on the item, no effects, an undefined action) is `null`, never `false`,
/// because an unseen effect could change something.
pub fn action_in_force(
    item: &serde_json::Value,
    panel_id: &str,
    actions: &serde_json::Value,
    ctx: &serde_json::Value,
) -> serde_json::Value {
    if item.get("params").is_some() || panel_id.is_empty() {
        return serde_json::Value::Null;
    }
    let effects = item.get("action").and_then(serde_json::Value::as_str)
        .and_then(|a| actions.get(a))
        .and_then(|a| a.get("effects"))
        .and_then(serde_json::Value::as_array);
    let Some(effects) = effects.filter(|e| !e.is_empty()) else { return serde_json::Value::Null };
    let own = crate::interpreter::state_store::panel_content_id(panel_id);
    let mut in_force = true;
    for effect in effects {
        let sps = effect.get("set_panel_state").and_then(serde_json::Value::as_object);
        let Some(sps) = sps else { return serde_json::Value::Null };
        let named = sps.get("panel").and_then(serde_json::Value::as_str).map(crate::interpreter::state_store::panel_content_id);
        let Some(key) = sps.get("key").and_then(serde_json::Value::as_str) else { return serde_json::Value::Null };
        if named.as_deref() != Some(own.as_str()) {
            return serde_json::Value::Null;
        }
        // "null" is the runner's own default for an absent value.
        let expr = sps.get("value").and_then(serde_json::Value::as_str).unwrap_or("null");
        let next = crate::interpreter::effects::value_to_json(&crate::interpreter::expr::eval(expr, ctx));
        let now = ctx.get("panel").and_then(|p| p.get(key)).unwrap_or(&serde_json::Value::Null);
        in_force &= json_value_eq(&next, now);
    }
    serde_json::Value::Bool(in_force)
}

/// JSON equality with numbers compared by value, so a store holding `45.0`
/// equals an expression's `45`.
fn json_value_eq(a: &serde_json::Value, b: &serde_json::Value) -> bool {
    match (a, b) {
        (serde_json::Value::Number(x), serde_json::Value::Number(y)) => x.as_f64() == y.as_f64(),
        (serde_json::Value::Array(x), serde_json::Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| json_value_eq(p, q))
        }
        (serde_json::Value::Object(x), serde_json::Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| json_value_eq(v, w)))
        }
        _ => a == b,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    #[test]
    fn only_a_bare_state_init_is_a_two_way_bind() {
        let panel = json!({"init": {"n": "state.gn", "s": " state.gs ", "e": "state.a + 1",
                                    "z": "0", "f": "hsb_h(state.c)", "x": "state."}});
        assert_eq!(mirrored_global(&panel, "n"), Some("gn"));
        assert_eq!(mirrored_global(&panel, "s"), Some("gs"));
        for k in ["e", "z", "f", "x", "absent"] {
            assert_eq!(mirrored_global(&panel, k), None, "{k}");
        }
        assert_eq!(mirrored_global(&json!({}), "n"), None);
    }

    fn parse(w: Value, text: &str) -> Option<Value> {
        parse_commit(&w, text)
    }

    /// The table, READ from WIDGET_EVENTS.md, where the lint holds the
    /// reference's copy to the same block. A third copy that nobody compares
    /// is how the three executors diverged in the first place.
    #[test]
    fn the_event_table_matches_the_document() {
        let doc = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../WIDGET_EVENTS.md"))
            .expect("WIDGET_EVENTS.md is readable");
        let begin = "<!-- widget-event-table:begin -->";
        let end = "<!-- widget-event-table:end -->";
        assert_eq!(doc.matches(begin).count(), 1);
        let body = doc.split(begin).nth(1).unwrap().split(end).next().unwrap();
        let mut seen = 0;
        for line in body.lines().map(str::trim) {
            if line.is_empty() || line.starts_with("```") {
                continue;
            }
            let (kind, events) = line.split_once(':').expect("kind: events");
            let events: Vec<&str> = events.split(',').map(str::trim).collect();
            assert_eq!(allowed_events(kind.trim()), events, "{kind}");
            seen += 1;
        }
        assert_eq!(seen, INPUT_KINDS.len() + BOOLEAN_KINDS.len() + ITEM_KINDS.len()
                   + CHECK_KINDS.len() + OPTION_KINDS.len());
        // A kind outside the table has no events. `slider`, `color_bar` and
        // then `radio_group` were this control until each joined (2026-10-13
        // forks A and B2; 2026-10-15); `icon_button_group` is outside by the
        // contract's own list.
        assert!(allowed_events("icon_button_group").is_empty());
    }

    #[test]
    fn number_input_takes_the_number_rule_and_its_bounds() {
        let w = json!({"type": "number_input", "min": 0, "max": 255});
        assert_eq!(parse(w.clone(), "300"), Some(json!(255.0)));
        assert_eq!(parse(w.clone(), "12.5"), Some(json!(12.5)));
        for t in ["abc", "1e3", " 12", "12\n", "\u{661}\u{662}", ""] {
            assert_eq!(parse(w.clone(), t), None, "{t:?}");
        }
        // A bool is not a bound.
        assert_eq!(parse(json!({"type": "number_input", "min": true}), "-5"), Some(json!(-5.0)));
    }

    #[test]
    fn length_input_converts_clamps_and_reads_its_own_nullability() {
        let w = json!({"type": "length_input", "unit": "pt", "min": 0, "max": 1000});
        assert_eq!(parse(w.clone(), "3 in"), Some(json!(216.0)));
        assert_eq!(parse(w.clone(), "2000"), Some(json!(1000.0)));
        assert_eq!(parse(w.clone(), "-3"), Some(json!(0.0)));
        assert_eq!(parse(w.clone(), "5 dpi"), None);
        assert_eq!(parse(w.clone(), "  "), None);
        assert_eq!(parse(json!({"type": "length_input", "unit": "in"}), "2"), Some(json!(144.0)));
        assert_eq!(parse(json!({"type": "length_input"}), "3"), Some(json!(3.0)));
        assert_eq!(parse(json!({"type": "length_input", "nullable": true}), " "), Some(Value::Null));
        assert_eq!(parse(json!({"type": "length_input", "nullable": false}), ""), None);
    }

    #[test]
    fn text_input_is_verbatim() {
        for t in ["", "  padded  ", "12", "Layer 1"] {
            assert_eq!(parse(json!({"type": "text_input"}), t), Some(json!(t)));
        }
    }

    #[test]
    fn select_takes_the_matching_options_declared_value() {
        let w = json!({"type": "select", "options": [
            {"label": "Letter", "value": "letter"}, {"label": "Two", "value": 2}]});
        assert_eq!(parse(w.clone(), "letter"), Some(json!("letter")));
        assert_eq!(parse(w.clone(), "2"), Some(json!(2)));
        assert_eq!(parse(w.clone(), "Letter"), None);
        let icons = json!({"type": "icon_select", "options": [{"value": "", "label": "None"}]});
        assert_eq!(parse(icons.clone(), ""), Some(json!("")));
        assert_eq!(parse(icons, "x"), None);
        let computed = json!({"type": "select", "options": "state.font_families"});
        assert_eq!(parse(computed, "Helvetica"), Some(json!("Helvetica")));
    }

    #[test]
    fn combo_box_is_a_clamped_number_or_its_text_and_never_blank() {
        let w = json!({"type": "combo_box", "min": 1, "options": [50, 100]});
        assert_eq!(parse(w.clone(), "150"), Some(json!(150.0)));
        assert_eq!(parse(w.clone(), "0"), Some(json!(1.0)));
        assert_eq!(parse(w.clone(), "Auto"), Some(json!("Auto")));
        assert_eq!(parse(w.clone(), "1e3"), Some(json!("1e3")));
        assert_eq!(parse(w.clone(), "inf"), Some(json!("inf")));
        assert_eq!(parse(w.clone(), ""), None);
        assert_eq!(parse(w, "  "), None);
    }

    /// The colour bar (fork B2): a point "u,v", each coordinate clamped to
    /// [0, 1]. Mirrors the reference's `test_a_color_bar_*` lists.
    #[test]
    fn a_colour_bar_commit_is_a_clamped_point_or_refused() {
        let w = json!({"type": "color_bar"});
        for (text, want) in [("0.25,0.5", [0.25, 0.5]), ("0,0", [0.0, 0.0]), ("1,1", [1.0, 1.0]),
                             ("1.4,-0.2", [1.0, 0.0]), ("-3,7", [0.0, 1.0])] {
            assert_eq!(parse(w.clone(), text), Some(json!(want)), "{text}");
        }
        for text in ["0.5", "0.5,0.5,0.5", "0.5, 0.5", "a,b", ",0.5", "0.5,", "", ".5,.5"] {
            assert_eq!(parse(w.clone(), text), None, "{text:?}");
        }
    }

    #[test]
    fn a_boolean_or_unknown_kind_has_no_text_parse() {
        assert_eq!(parse(json!({"type": "toggle"}), "true"), None);
        // `slider`, then `color_bar`, were this example until each became an
        // input kind (forks A and B2).
        assert_eq!(parse(json!({"type": "radio_group"}), "3"), None);
    }

    /// A slider (WIDGET_EVENTS.md, Parsing; the reference's `_snap`): a
    /// number, clamped, snapped to `step` from `min` half up, clamped again,
    /// so a `max` off the step grid is unreachable. The corpus drives it
    /// through the door; these pin the arithmetic's edges directly.
    #[test]
    fn a_slider_clamps_snaps_from_min_and_clamps_again() {
        let w = json!({"type": "slider", "min": 0, "max": 255, "step": 51});
        assert_eq!(parse(w.clone(), "100"), Some(json!(102.0)), "nearest step");
        assert_eq!(parse(w.clone(), "25.5"), Some(json!(51.0)), "half up");
        assert_eq!(parse(w.clone(), "-9"), Some(json!(0.0)), "clamped below");
        assert_eq!(parse(w.clone(), "abc"), None, "not a number");
        // From `min`, not from 0: 10 + 3k.
        let w = json!({"type": "slider", "min": 10, "max": 30, "step": 3});
        assert_eq!(parse(w.clone(), "14"), Some(json!(13.0)));
        // An off-grid max: 28 is the last step; 29.9 snaps to 31, clamped to 30.
        assert_eq!(parse(w.clone(), "29.9"), Some(json!(30.0)));
        // No step, or a non-positive one, does not snap.
        assert_eq!(parse(json!({"type": "slider", "min": 0, "max": 10}), "3.7"), Some(json!(3.7)));
        assert_eq!(parse(json!({"type": "slider", "step": 0}), "3.7"), Some(json!(3.7)));
    }

    #[test]
    fn the_bound_target_and_what_is_writable() {
        assert_eq!(bound_target(&json!({"bind": {"value": "panel.a", "checked": "panel.b"}})), Some("panel.a"));
        assert_eq!(bound_target(&json!({"bind": {"checked": "panel.b"}})), Some("panel.b"));
        assert_eq!(bound_target(&json!({"bind": "dialog.c"})), Some("dialog.c"));
        assert_eq!(bound_target(&json!({"bind": {"disabled": "x"}})), None);
        assert_eq!(writable_target("panel.fill_tolerance"), Some(("panel", "fill_tolerance")));
        assert_eq!(writable_target(" dialog.web_only "), Some(("dialog", "web_only")));
        for e in ["state.x", "selection_mask_clip", "ab.name", "not panel.x",
                  "panel.stops[panel.i].opacity", "panel.", "panel.caf\u{e9}"] {
            assert_eq!(writable_target(e), None, "{e}");
        }
    }
}
