//! **THE INPUT SCRIPTS THROUGH THE ENGINE'S C ABI** (docs/TESTING.md section 6).
//!
//! Every script in `test_fixtures/input_scripts/` is replayed here through the
//! same calls a native shell makes: `jas_load_svg`, `jas_set_tool`,
//! `jas_pointer_event` for a pointer step, `jas_dispatch_action({"key"})` for a
//! key step, `jas_dispatch_action({"menu_item"})` for a menu step,
//! `jas_panel_behavior` for a panel step, and `jas_document_json` for
//! the read-back. The read-back must equal the script's expected file.
//!
//! This is Rust's level 1 for a PANEL step. The gesture runner
//! (`cross_language_test::script_corpus`) is web-only and the panel behaviour is
//! engine-only, and no CI lane builds both, so a panel script's Rust read-back
//! comes from here. Pointer and key scripts are replayed here too, which pins
//! the engine's path to the gesture runner's for every one of them.
//!
//! The setup document is opened by the body `jas_load_svg` wraps, since that
//! entry links only on Windows with Direct2D.
//!
//! Document units are passed as pointer coordinates unchanged: a new engine's
//! DPI scale is 1 and it has no view transform.

use crate::ffi::{
    jas_dispatch_action, jas_document_json, jas_engine_free, jas_engine_new, jas_free,
    jas_last_error_json, jas_panel_behavior, JasBytes, JasEngine, JasStatus,
};
use crate::ffi_pointer::{
    jas_pointer_event, jas_set_tool, KIND_DOUBLE_CLICK, KIND_MOVE, KIND_PRESS, KIND_RELEASE, MOD_ALT, MOD_DRAGGING,
    MOD_SHIFT, TOOL_IDS,
};
use serde_json::Value;

const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../test_fixtures");

fn read(rel: &str) -> String {
    std::fs::read_to_string(format!("{FIXTURES}/{rel}")).unwrap_or_else(|e| panic!("{rel}: {e}"))
}

fn take(b: JasBytes) -> Option<String> {
    if b.ptr.is_null() {
        return None;
    }
    let s = unsafe { std::slice::from_raw_parts(b.ptr, b.len) }.to_vec();
    unsafe { jas_free(b) };
    Some(String::from_utf8(s).unwrap())
}

fn last_error(e: *mut JasEngine) -> String {
    take(unsafe { jas_last_error_json(e) }).unwrap_or_default()
}

fn flag(st: &Value, k: &str) -> bool {
    st.get(k).and_then(Value::as_bool).unwrap_or(false)
}

/// Every script file, derived from the directory (never a list kept by hand).
fn script_files() -> Vec<String> {
    let mut out: Vec<String> = std::fs::read_dir(format!("{FIXTURES}/input_scripts"))
        .unwrap()
        .map(|d| d.unwrap().file_name().into_string().unwrap())
        .filter(|n| n.ends_with(".json") && !n.ends_with(".expected.json"))
        .collect();
    out.sort();
    out
}

/// Replay one script through the ABI and return the engine's read-back, or the
/// step that the engine refused, named.
fn replay(script: &Value) -> Result<String, String> {
    replay_then(script, |e| take(unsafe { jas_document_json(e) }).ok_or_else(|| "no read-back".to_string()))
}

/// [`replay`]'s steps, then `read` on the engine in place of the JSON read-back,
/// for an arm that needs the engine's own document rather than its bytes.
fn replay_then<T>(script: &Value, read_back: impl Fn(*mut JasEngine) -> Result<T, String>) -> Result<T, String> {
    let item = script["item"].as_str().ok_or("a script names its spec item")?;
    let steps = script["steps"].as_array().ok_or("a script has steps")?;
    if steps.last() != Some(&serde_json::json!({"read": "document"})) {
        return Err(format!("script {item}: must end on a document read"));
    }
    let tool = script["tool"].as_str().unwrap_or("");
    let tool_index = TOOL_IDS.iter().position(|t| *t == tool)
        .ok_or_else(|| format!("script {item}: tool '{tool}' is not a shell tool"))?;
    let svg = read(&format!("svg/{}", script["setup_svg"].as_str().unwrap()));

    let e = jas_engine_new();
    let result = (|| {
        // The ABI's loader (`ffi_paint::jas_load_svg`) links only on Windows
        // with Direct2D; this is the body it wraps, the opener every app uses.
        let Some(doc) = crate::geometry::svg::try_open_svg_document(&svg) else {
            return Err(format!("script {item}: the setup SVG did not open"));
        };
        unsafe { e.as_ref() }.unwrap().replace_document(doc);
        if unsafe { jas_set_tool(e, tool_index) } != JasStatus::Ok {
            return Err(format!("script {item}: jas_set_tool({tool}) refused"));
        }
        for (i, st) in steps[..steps.len() - 1].iter().enumerate() {
            if let Some(kind) = st.get("kind").and_then(Value::as_str) {
                let k = match kind {
                    "press" => KIND_PRESS,
                    "move" => KIND_MOVE,
                    "release" => KIND_RELEASE,
                    "double_click" => KIND_DOUBLE_CLICK,
                    _ => return Err(format!("script {item}: step {i} has an unknown kind '{kind}'")),
                };
                let mods = if flag(st, "shift") { MOD_SHIFT } else { 0 }
                    | if flag(st, "alt") { MOD_ALT } else { 0 }
                    | if flag(st, "dragging") { MOD_DRAGGING } else { 0 };
                if flag(st, "ctrl") || flag(st, "meta") {
                    return Err(format!("script {item}: step {i}: the pointer takes no ctrl or meta"));
                }
                let (x, y) = (st["x"].as_f64().unwrap(), st["y"].as_f64().unwrap());
                if unsafe { jas_pointer_event(e, k, x, y, mods) } != JasStatus::Ok {
                    return Err(format!("script {item}: step {i} {st}: the pointer was refused"));
                }
            } else if let Some(key) = st.get("key").and_then(Value::as_str) {
                if flag(st, "meta") {
                    return Err(format!("script {item}: step {i} carries meta, which the engine's key route does not take"));
                }
                let req = serde_json::json!({"key": key, "mods": {
                    "shift": flag(st, "shift"), "alt": flag(st, "alt"), "ctrl": flag(st, "ctrl")}})
                    .to_string();
                if take(unsafe { jas_dispatch_action(e, req.as_ptr(), req.len()) }).is_none() {
                    return Err(format!("script {item}: step {i} {st}: refused {}", last_error(e)));
                }
            } else if let Some(menu_id) = st.get("menu").and_then(Value::as_str) {
                // A MENU step: the menubar item by its id, as a shell sends it.
                let req = serde_json::json!({"menu_item": menu_id}).to_string();
                let reply = take(unsafe { jas_dispatch_action(e, req.as_ptr(), req.len()) });
                let err = last_error(e);
                if reply.is_none() || err.contains("Unchanged") {
                    return Err(format!("script {item}: step {i} {st}: the menu item did not run: {err}"));
                }
            } else if let Some(panel) = st.get("panel").and_then(Value::as_str) {
                let mut ev = serde_json::json!({
                    "widget": st["widget"].as_str().ok_or_else(|| format!("script {item}: step {i} names no widget"))?,
                    "event": st["event"].as_str().ok_or_else(|| format!("script {item}: step {i} names no event"))?,
                });
                if let Some(v) = st.get("value") {
                    ev["value"] = v.clone();
                }
                let ev = ev.to_string();
                let reply = take(unsafe { jas_panel_behavior(e, panel.as_ptr(), panel.len(), ev.as_ptr(), ev.len()) });
                let err = last_error(e);
                if reply.is_none() || err.contains("Unchanged") {
                    return Err(format!("script {item}: step {i} {st}: the panel act did not run: {err}"));
                }
            } else {
                return Err(format!("script {item}: step {i} {st} is not a pointer, key, menu or panel step"));
            }
        }
        read_back(e).map_err(|why| format!("script {item}: {why}"))
    })();
    unsafe { jas_engine_free(e) };
    result
}

/// The open's artboard, set aside exactly as the Windows level-2 oracle does
/// (`harness_common.ps1`, `Compare-SbReadBack`): every expected file is built
/// by the codec, which adds no artboard, while an engine opens the setup as a
/// person does and adds the at-least-one artboard with a fresh id. Only when
/// the expected names no artboards, and only exactly one, named `Artboard 1`
/// with an 8-character base-36 id; anything else in its place is refused by
/// name. The comparison after it is of BYTES.
fn set_aside_the_opens_artboard(got: &str, want: &str) -> Result<String, String> {
    const HEAD: &str = r#"{"artboards":["#;
    if want.contains(r#""artboards":"#) || !got.starts_with(HEAD) {
        return Ok(got.to_string());
    }
    let end = got.find("],").ok_or("the read-back opens with an artboards member this reader cannot delimit")?;
    let abs: Vec<Value> = serde_json::from_str(&got[HEAD.len() - 1..=end])
        .map_err(|_| "the read-back opens with an artboards member this reader cannot delimit".to_string())?;
    if abs.len() != 1 {
        return Err(format!("the read-back carries {} artboards where the expected names none; the open adds exactly one", abs.len()));
    }
    let id = abs[0]["id"].as_str().unwrap_or("");
    let name = abs[0]["name"].as_str().unwrap_or("");
    if id.len() != 8 || !id.bytes().all(|b| b.is_ascii_digit() || b.is_ascii_lowercase()) || name != "Artboard 1" {
        return Err(format!("an artboard the expected does not name, and not the one the open adds: id \"{id}\" name \"{name}\""));
    }
    Ok(format!("{{{}", &got[end + 2..]))
}

/// The token an expected file writes where the op MINTS an id: `boolean.divide`
/// gives each fragment of a split source a fresh id, so its read-back differs
/// on every run. At each `"id":"<minted>"` in the expected, the read-back must
/// carry an 8-character base-36 id, and those ids must be pairwise distinct
/// (fresh, not one id stamped twice). Every other id is compared as bytes, and
/// the counts of `"id":` must agree, so a dropped or an extra id is refused.
/// Each accepted id is replaced by the token, and the comparison after it is of
/// BYTES. Swift's `acceptMintedIds` is the same law.
const MINTED: &str = "<minted>";

fn accept_minted_ids(got: &str, want: &str) -> Result<String, String> {
    const KEY: &str = r#""id":""#;
    if !want.contains(&format!("{KEY}{MINTED}\"")) {
        return Ok(got.to_string());
    }
    let ids = |s: &str| -> Vec<(usize, usize)> {
        let mut out = vec![];
        let mut from = 0;
        while let Some(i) = s[from..].find(KEY) {
            let start = from + i + KEY.len();
            let end = start + s[start..].find('"').unwrap_or(0);
            out.push((start, end));
            from = end;
        }
        out
    };
    let (g, w) = (ids(got), ids(want));
    if g.len() != w.len() {
        return Err(format!("the read-back carries {} ids where the expected names {}", g.len(), w.len()));
    }
    let mut out = String::new();
    let mut seen = std::collections::HashSet::new();
    let mut at = 0;
    for (&(gs, ge), &(ws, we)) in g.iter().zip(&w) {
        if &want[ws..we] != MINTED {
            continue;
        }
        let id = &got[gs..ge];
        if id.len() != 8 || !id.bytes().all(|b| b.is_ascii_digit() || b.is_ascii_lowercase()) {
            return Err(format!("a minted id is not an 8-character base-36 id: \"{id}\""));
        }
        if !seen.insert(id) {
            return Err(format!("the minted id \"{id}\" is carried twice; a mint is fresh"));
        }
        out.push_str(&got[at..gs]);
        out.push_str(MINTED);
        at = ge;
    }
    out.push_str(&got[at..]);
    Ok(out)
}

#[test]
fn a_minted_id_is_accepted_only_where_the_expected_names_one_and_only_fresh() {
    let el = |id: &str| format!(r#"{{"id":"{id}","type":"polygon"}}"#);
    let doc = |a: &str, b: &str| format!(r#"{{"layers":[{},{}]}}"#, el(a), el(b));
    let want = doc(MINTED, MINTED);
    assert_eq!(accept_minted_ids(&doc("l006y7om", "7xkxpudp"), &want).unwrap(), want);
    // No token: the read-back is untouched, so its ids are compared as bytes.
    assert_eq!(accept_minted_ids(&doc("l006y7om", "7xkxpudp"), &doc("aaaaaaaa", "bbbbbbbb")).unwrap(),
               doc("l006y7om", "7xkxpudp"));
    // A literal id beside a token is left for the byte comparison.
    let mixed = doc("keepthis", MINTED);
    assert_eq!(accept_minted_ids(&doc("keepthis", "7xkxpudp"), &mixed).unwrap(), mixed);
    assert_ne!(accept_minted_ids(&doc("changed1", "7xkxpudp"), &mixed).unwrap(), mixed);
    // One id stamped twice, a wrong shape, a missing id: refused by name.
    assert!(accept_minted_ids(&doc("l006y7om", "l006y7om"), &want).unwrap_err().contains("carried twice"));
    assert!(accept_minted_ids(&doc("L006Y7OM", "7xkxpudp"), &want).unwrap_err().contains("not an 8-character"));
    assert!(accept_minted_ids(&doc("l006y7o", "7xkxpudp"), &want).unwrap_err().contains("not an 8-character"));
    let one = format!(r#"{{"layers":[{},{{"type":"polygon"}}]}}"#, el("l006y7om"));
    assert!(accept_minted_ids(&one, &want).unwrap_err().contains("carries 1 ids where the expected names 2"));
}

#[test]
fn the_opens_artboard_is_set_aside_only_in_the_one_shape_the_open_makes() {
    let ab = |id: &str, name: &str| format!(r#"{{"fill":"transparent","id":"{id}","name":"{name}","x":0.0}}"#);
    let rest = r#""layers":[],"selection":[]}"#;
    let want = format!("{{{rest}");
    let one = format!(r#"{{"artboards":[{}],{rest}"#, ab("pfj2j82z", "Artboard 1"));
    assert_eq!(set_aside_the_opens_artboard(&one, &want).unwrap(), want);
    // The expected names artboards: nothing is set aside.
    let named = format!(r#"{{"artboards":[],{rest}"#);
    assert_eq!(set_aside_the_opens_artboard(&one, &named).unwrap(), one);
    // Two, a wrong name, a wrong id: refused by name, never set aside.
    let two = format!(r#"{{"artboards":[{},{}],{rest}"#, ab("pfj2j82z", "Artboard 1"), ab("abcdefgh", "Artboard 2"));
    assert!(set_aside_the_opens_artboard(&two, &want).unwrap_err().contains("carries 2 artboards"));
    let renamed = format!(r#"{{"artboards":[{}],{rest}"#, ab("pfj2j82z", "Artboard 9"));
    assert!(set_aside_the_opens_artboard(&renamed, &want).unwrap_err().contains("not the one the open adds"));
    let upper = format!(r#"{{"artboards":[{}],{rest}"#, ab("PFJ2J82Z", "Artboard 1"));
    assert!(set_aside_the_opens_artboard(&upper, &want).unwrap_err().contains("not the one the open adds"));
}

/// **The engine evaluates a Stroke widget's `disabled` against the SELECTION.**
/// `stk_miter_limit` declares `disabled: panel.join != "miter"`. The engine's
/// Stroke scope was its stored panel state, whose `join` default is "miter",
/// so it applied a miter-limit commit at a bevel join, which the Mac app, the
/// web dock and the Swift runner all refuse: their scopes overlay the
/// selection's stroke. The control is the same commit after Miter is chosen.
#[test]
fn a_stroke_commit_on_a_widget_the_selection_disables_is_refused() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let script = |steps: Value| serde_json::json!({
        "item": "t", "setup_svg": "rect_with_stroke.svg", "tool": "selection", "app_state": {},
        "steps": steps, "expected_json": "-"});
    let press = serde_json::json!([{"kind": "press", "x": 36, "y": 18}, {"kind": "release", "x": 36, "y": 18}]);
    let commit = serde_json::json!({"panel": "stroke_panel_content", "widget": "stk_miter_limit", "event": "commit", "value": "4"});
    let miter = serde_json::json!({"panel": "stroke_panel_content", "widget": "stk_join_miter", "event": "click"});
    let read = serde_json::json!({"read": "document"});
    let at_bevel = replay(&script(serde_json::json!([press[0], press[1], commit, read])));
    assert!(at_bevel.as_ref().is_err_and(|e| e.contains("Disabled")),
        "a commit at a bevel join must be refused as Disabled, got {at_bevel:?}");
    let at_miter = replay(&script(serde_json::json!([press[0], press[1], miter, commit, read])));
    assert!(at_miter.as_ref().is_ok_and(|d| d.contains(r#""miter_limit":4.0"#)),
        "the commit after Miter must run, got {at_miter:?}");
}

#[test]
fn every_input_script_replays_through_the_engine_to_its_expected_read_back() {
    // The ABI's counters are process-wide; the tests that read them serialise
    // on this lock, so every other ABI caller holds it too.
    let _counters = crate::ffi_instr::test_lock::lock();
    let files = script_files();
    assert!(files.iter().any(|f| f == "align.left.json"), "the population lacks a panel script: {files:?}");
    assert!(files.iter().any(|f| f == "shortcut.undo.json"), "the population lacks a key script: {files:?}");
    let mut wrong = vec![];
    for f in &files {
        let script: Value = serde_json::from_str(&read(&format!("input_scripts/{f}"))).unwrap();
        let expected = read(&format!("input_scripts/{}", script["expected_json"].as_str().unwrap()));
        match replay(&script)
            .and_then(|got| set_aside_the_opens_artboard(&got, expected.trim()))
            .and_then(|got| accept_minted_ids(&got, expected.trim())) {
            Ok(actual) if actual == expected.trim() => {}
            Ok(actual) => wrong.push(format!("{f}: the engine read back\n{actual}\nnot\n{}", expected.trim())),
            Err(why) => wrong.push(why),
        }
    }
    assert!(wrong.is_empty(), "{} of {} scripts:\n{}", wrong.len(), files.len(), wrong.join("\n\n"));
}

/// The single Text element of a script's document, by depth-first walk. A
/// setup holding none, or more than one, is refused by name: this arm is about
/// one paragraph layout and must not silently pick one of two.
fn the_one_text(doc: &crate::document::document::Document) -> Result<crate::geometry::element::TextElem, String> {
    use crate::geometry::element::Element;
    fn walk(e: &Element, out: &mut Vec<crate::geometry::element::TextElem>) {
        if let Element::Text(t) = e {
            out.push(t.clone());
        }
        for c in e.children().unwrap_or(&[]) {
            walk(c, out);
        }
    }
    let mut out = vec![];
    for l in &doc.layers {
        walk(l, &mut out);
    }
    match out.len() {
        1 => Ok(out.pop().unwrap()),
        n => Err(format!("{n} text elements, not one")),
    }
}

/// The legacy renderer's paragraph layout of `t` (`canvas/render.rs`, the
/// `layout_with_paragraphs` call), as one string per line: the line's char
/// range, baseline, trailing hyphen and every glyph's x to 0.001, then one
/// string per list marker. ⚠️ The markers are not glyphs of the layout, and a
/// list's marker gap is 12 pt, so a list and a 12 pt left indent place every
/// glyph alike: without the markers the arm reads bullets, a numbered list
/// and that indent as one setting.
///
/// ⚠️ THE MEASURER IS THE 0.55-PER-CHARACTER APPROXIMATION ON PURPOSE, not a
/// font: this pins the LAYOUT LAW (which settings move which lines), and a real
/// face would make the arm depend on what is installed. Whether a frame moves
/// is measured on the box by flask, never inferred from this.
fn legacy_layout_lines(t: &crate::geometry::element::TextElem) -> Vec<String> {
    let fs = t.font_size;
    let measure = move |s: &str| s.chars().count() as f64 * fs * 0.55;
    let leading = match t.tspans.iter().find(|w| w.jas_role.as_deref() == Some("paragraph"))
        .and_then(|w| w.jas_auto_leading) {
        Some(pct) => fs * pct / 100.0,
        None => fs,
    };
    let content = t.content();
    let max_w = if t.is_area_text() { t.width } else { 0.0 };
    let segs = crate::algorithms::text_layout_paragraph::build_segments_from_text(
        &t.tspans, &content, t.is_area_text());
    let l = crate::algorithms::text_layout::layout_with_paragraphs(&content, max_w, leading, &segs, &measure);
    let counters = crate::algorithms::text_layout_paragraph::compute_counters(&segs);
    let markers = segs.iter().zip(&counters).filter_map(|(sg, c)| sg.list_style.as_deref()
        .map(|st| format!("marker {:?} at char {}", crate::algorithms::text_layout_paragraph::marker_text(st, *c), sg.char_start)));
    l.lines.iter().map(|ln| {
        let xs: Vec<String> = l.glyphs[ln.glyph_start..ln.glyph_end].iter()
            .map(|g| format!("{:.3}", g.x)).collect();
        format!("[{}..{}) y={:.3} hyphen={} x={}", ln.start, ln.end, ln.baseline_y, ln.trailing_hyphen, xs.join(","))
    }).chain(markers).collect()
}

#[test]
fn every_area_text_paragraph_script_moves_the_legacy_layout_and_no_two_move_it_alike() {
    // Sweep 11 (jas section 432): a Paragraph script whose act lays out exactly
    // like the untouched setup certifies a frame that cannot tell the act from
    // doing nothing. Flask found five such on the one-line `text_area_basic`.
    let _counters = crate::ffi_instr::test_lock::lock();
    let mut by_setup: std::collections::BTreeMap<String, Vec<(String, Vec<String>)>> = Default::default();
    for f in script_files() {
        let script: Value = serde_json::from_str(&read(&format!("input_scripts/{f}"))).unwrap();
        let setup = script["setup_svg"].as_str().unwrap().to_string();
        if !f.starts_with("paragraph.") || !setup.starts_with("text_area") {
            continue;
        }
        let lines = replay_then(&script, |e| {
            unsafe { e.as_ref() }.unwrap().with_model(|m| the_one_text(m.document()))
        }).unwrap_or_else(|why| panic!("{f}: {why}"));
        by_setup.entry(setup).or_default().push((f, legacy_layout_lines(&lines)));
    }
    let n: usize = by_setup.values().map(Vec::len).sum();
    // The floor is the population this arm was written for, never a target.
    assert!(n >= 10, "only {n} area-text paragraph scripts were found: the population moved");
    let mut wrong = vec![];
    for (setup, rows) in &by_setup {
        let doc = crate::geometry::svg::try_open_svg_document(&read(&format!("svg/{setup}")))
            .unwrap_or_else(|| panic!("{setup} did not open"));
        let control = legacy_layout_lines(&the_one_text(&doc).unwrap());
        for (f, lines) in rows {
            if *lines == control {
                wrong.push(format!("{f} lays out exactly as the untouched {setup}:\n  {}", control.join("\n  ")));
            }
        }
        for (i, (fa, a)) in rows.iter().enumerate() {
            for (fb, b) in &rows[i + 1..] {
                if a == b {
                    wrong.push(format!("{fa} and {fb} lay out alike on {setup}"));
                }
            }
        }
    }
    assert!(wrong.is_empty(), "{} finding(s) over {n} scripts:\n{}", wrong.len(), wrong.join("\n"));
}

// ---------------------------------------------------------------------------
// THE §6 PANEL FORMS (design 2026-10-31 "script forms runners", O96 M3): `row`,
// modifiers on a panel step, a key after a panel step, `read: panel`, reads
// anywhere in the script, and `app_state.panels`. [`replay_forms`] returns
// EVERY read-back in step order, so a script whose expected file does not
// exist yet (the M3 settling day writes them from the control) still yields
// its read-backs, and a refusal keeps the reads before it.
// ---------------------------------------------------------------------------

/// The plan path of `widget` in the row of the ONE `foreach` enclosing it whose
/// item's `path` equals `row`: declared children by index, and at a `foreach`
/// the row's index, as `panel_behavior::resolve_path` walks it. The rows come
/// from the panel's own `foreach.source`, evaluated in `scope` by the engine's
/// evaluator (`interpreter::foreach::row_scopes`), never from runner code.
/// Refused by name: a widget not found · a widget under no `foreach` · under
/// two or more (that address is `at`, not delivered) · a row path found 0 or
/// 2+ times.
///
/// THE EVENT BUBBLES, as a pointer's does in every shell: the step's event goes
/// to the NEAREST node on that path, the widget first, whose `behavior:`
/// declares it. A Layers row's click is declared on the row's container, not
/// on `lp_name`, so a click on the name selects the row; an eye's click is
/// declared on `lp_eye` itself and never reaches the row. The second value is
/// the node the event went to, when it is not the widget. A node declaring no
/// such event on the whole path is refused by name.
fn row_plan_path(content: &Value, widget: &str, event: &str, row: &[u64], scope: &Value)
    -> Result<(Vec<usize>, Option<String>), String> {
    fn contains(node: &Value, widget: &str) -> bool {
        if node.get("id").and_then(Value::as_str) == Some(widget) {
            return true;
        }
        ["children", "do"].iter().any(|k| match node.get(*k) {
            Some(Value::Array(items)) => items.iter().any(|c| contains(c, widget)),
            Some(c @ Value::Object(_)) => contains(c, widget),
            _ => false,
        })
    }
    fn walk(node: &Value, widget: &str, row: &[u64], scope: &Value, path: &mut Vec<usize>, repeats: &mut usize,
            chain: &mut Vec<(usize, Value)>) -> Result<bool, String> {
        chain.push((path.len(), node.clone()));
        if node.get("id").and_then(Value::as_str) == Some(widget) {
            return Ok(true);
        }
        if let Some(rows) = crate::interpreter::foreach::row_scopes(node, scope) {
            let template = &node["do"];
            if !contains(template, widget) {
                return Ok(false);
            }
            *repeats += 1;
            let var = node["foreach"].get("as").and_then(Value::as_str).unwrap_or("item");
            let as_path = |v: &Value| -> Option<Vec<u64>> {
                let v = v.get("__path__").unwrap_or(v);
                v.as_array()?.iter().map(Value::as_u64).collect()
            };
            let hits: Vec<usize> = rows.iter().enumerate()
                .filter(|(_, r)| r[var].get("path").and_then(as_path).as_deref() == Some(row))
                .map(|(i, _)| i)
                .collect();
            let &[i] = hits.as_slice() else {
                return Err(format!("row {row:?} is {} row(s) of `{}`, not one", hits.len(),
                    node["foreach"]["source"].as_str().unwrap_or("?")));
            };
            path.push(i);
            return walk(template, widget, row, &rows[i], path, repeats, chain);
        }
        if let Some(Value::Array(children)) = node.get("children") {
            for (i, c) in children.iter().enumerate() {
                if contains(c, widget) {
                    path.push(i);
                    return walk(c, widget, row, scope, path, repeats, chain);
                }
            }
        }
        Ok(false)
    }
    let mut path = vec![];
    let mut repeats = 0;
    let mut chain = vec![];
    if !walk(content, widget, row, scope, &mut path, &mut repeats, &mut chain)? {
        return Err(format!("widget `{widget}` is not in the panel"));
    }
    match repeats {
        0 => return Err(format!("`row` on `{widget}`, which no foreach repeats")),
        1 => {}
        n => return Err(format!("`{widget}` sits under {n} foreach repeats; that address is `at`, not delivered")),
    }
    let declares = |node: &Value| node.get("behavior").and_then(Value::as_array).is_some_and(|b| b.iter()
        .any(|entry| entry.get("event").and_then(Value::as_str).unwrap_or("click") == event));
    // The walk ends on the widget, so the chain's last node is the widget.
    let Some(at) = chain.iter().rposition(|(_, node)| declares(node)) else {
        return Err(format!("no node on `{widget}`'s path in row {row:?} declares `{event}`"));
    };
    let (len, node) = &chain[at];
    let to = (at + 1 != chain.len()).then(|| node.get("id").and_then(Value::as_str)
        .map_or_else(|| format!("{:?}", &path[..*len]), str::to_string));
    Ok((path[..*len].to_vec(), to))
}

/// A store value in the canonical form `read: panel` emits: path markers as
/// index arrays, at any depth, and every object's keys sorted. Sorted HERE,
/// never by trusting serde_json's map: a dependency can switch on its
/// `preserve_order` feature, and then the map keeps insertion order.
fn canonical_panel_value(v: &Value) -> Value {
    match v {
        Value::Object(m) if m.len() == 1 && m.contains_key("__path__") => canonical_panel_value(&m["__path__"]),
        Value::Object(m) => {
            let sorted: std::collections::BTreeMap<&String, Value> =
                m.iter().map(|(k, v)| (k, canonical_panel_value(v))).collect();
            Value::Object(sorted.into_iter().map(|(k, v)| (k.clone(), v)).collect())
        }
        Value::Array(a) => Value::Array(a.iter().map(canonical_panel_value).collect()),
        other => other.clone(),
    }
}

/// A seeded value in the store's form: in a list, an item that is a list of
/// non-negative integers is a PATH (the ruled form: "entries are PATHS").
fn seed_value(v: &Value) -> Value {
    let is_path = |x: &Value| x.as_array().is_some_and(|a| a.iter().all(|i| i.as_u64().is_some()));
    match v {
        Value::Array(items) => Value::Array(items.iter()
            .map(|x| if is_path(x) { serde_json::json!({"__path__": x}) } else { x.clone() })
            .collect()),
        other => other.clone(),
    }
}

/// Replay a script with the §6 panel forms; every read-back in step order, as
/// `{"step": i, "read": kind, "value": ...}`. A step that ran and changed
/// nothing adds `{"step": i, "unchanged": true}` and the replay goes on. A
/// refused step adds `{"step": i, "refused": why}` and ends it, keeping every
/// read before it. `Err` is a script the runner cannot start.
fn replay_forms(script: &Value) -> Result<Vec<Value>, String> {
    use serde_json::json;
    let item = script["item"].as_str().ok_or("a script names its spec item")?;
    let steps = script["steps"].as_array().ok_or("a script has steps")?;
    let tool = script["tool"].as_str().unwrap_or("");
    let tool_index = TOOL_IDS.iter().position(|t| *t == tool)
        .ok_or_else(|| format!("script {item}: tool '{tool}' is not a shell tool"))?;
    let svg = read(&format!("svg/{}", script["setup_svg"].as_str().ok_or("a script names its setup_svg")?));
    let e = jas_engine_new();
    let result = (|| {
        let engine = unsafe { e.as_ref() }.unwrap();
        let doc = crate::geometry::svg::try_open_svg_document(&svg)
            .ok_or_else(|| format!("script {item}: the setup SVG did not open"))?;
        engine.replace_document(doc);
        if unsafe { jas_set_tool(e, tool_index) } != JasStatus::Ok {
            return Err(format!("script {item}: jas_set_tool({tool}) refused"));
        }
        // `app_state.panels.<content id>.<declared key>`, and nothing else.
        if let Some(app) = script.get("app_state") {
            let app = app.as_object().ok_or_else(|| format!("script {item}: app_state is not an object"))?;
            for (k, v) in app {
                if k != "panels" {
                    return Err(format!("script {item}: app_state.{k} is not a ruled form; \
                        seed a panel's declared state as app_state.panels.<content id>.<key>"));
                }
                let panels = v.as_object().ok_or_else(|| format!("script {item}: app_state.panels is not an object"))?;
                for (pid, keys) in panels {
                    let keys = keys.as_object().ok_or_else(|| format!("script {item}: app_state.panels.{pid} is not an object"))?;
                    for (key, val) in keys {
                        engine.script_seed_panel(pid, key, seed_value(val))
                            .map_err(|why| format!("script {item}: app_state.panels.{pid}.{key}: {why}"))?;
                    }
                }
            }
        }
        let mut out = vec![];
        // The panel a key goes to: the last panel step's, until a pointer or
        // menu step moves the focus to the canvas or the menubar.
        let mut focus: Option<String> = None;
        for (i, st) in steps.iter().enumerate() {
            let refuse = |out: &mut Vec<Value>, why: String| out.push(json!({"step": i, "refused": why}));
            let ran = |out: &mut Vec<Value>, reply: Option<String>, err: String| -> bool {
                if reply.is_none() {
                    out.push(json!({"step": i, "refused": err}));
                    return false;
                }
                if err.contains("Unchanged") {
                    out.push(json!({"step": i, "unchanged": true}));
                }
                true
            };
            if let Some(kind) = st.get("read").and_then(Value::as_str) {
                match kind {
                    "document" => {
                        let doc = take(unsafe { jas_document_json(e) }).ok_or_else(|| format!("script {item}: step {i}: no read-back"))?;
                        let doc: Value = serde_json::from_str(&doc).map_err(|x| x.to_string())?;
                        out.push(json!({"step": i, "read": "document", "value": doc}));
                    }
                    "panel" => {
                        let pid = st["panel"].as_str().ok_or_else(|| format!("script {item}: step {i}: read panel names no panel"))?;
                        let Some(state) = engine.script_panel_state(pid) else {
                            refuse(&mut out, format!("UnknownPanel {pid}"));
                            break;
                        };
                        out.push(json!({"step": i, "read": "panel", "panel": pid,
                                        "value": canonical_panel_value(&Value::Object(state))}));
                    }
                    // Form (e): `read: tree` reads `drawn_rows`, the rows the
                    // tree DRAWS in its visible area, which only a level-2
                    // driver can see.
                    "tree" => {
                        out.push(json!({"step": i, "read": "tree", "value": "NOT APPLICABLE (read: tree is level 2 only)"}));
                    }
                    other => {
                        refuse(&mut out, format!("read: {other} is not delivered by this runner"));
                        break;
                    }
                }
            } else if let Some(kind) = st.get("kind").and_then(Value::as_str) {
                focus = None;
                let k = match kind {
                    "press" => KIND_PRESS,
                    "move" => KIND_MOVE,
                    "release" => KIND_RELEASE,
                    "double_click" => KIND_DOUBLE_CLICK,
                    _ => { refuse(&mut out, format!("pointer kind '{kind}' is not delivered")); break; }
                };
                if flag(st, "ctrl") || flag(st, "meta") {
                    refuse(&mut out, "the pointer takes no ctrl or meta".to_string());
                    break;
                }
                let mods = if flag(st, "shift") { MOD_SHIFT } else { 0 }
                    | if flag(st, "alt") { MOD_ALT } else { 0 }
                    | if flag(st, "dragging") { MOD_DRAGGING } else { 0 };
                let (Some(x), Some(y)) = (st["x"].as_f64(), st["y"].as_f64()) else {
                    refuse(&mut out, "a pointer step without x, y".to_string());
                    break;
                };
                if unsafe { jas_pointer_event(e, k, x, y, mods) } != JasStatus::Ok {
                    refuse(&mut out, format!("the pointer was refused: {}", last_error(e)));
                    break;
                }
            } else if let Some(key) = st.get("key").and_then(Value::as_str) {
                let mods = json!({"shift": flag(st, "shift"), "alt": flag(st, "alt"),
                                  "ctrl": flag(st, "ctrl"), "meta": flag(st, "meta")});
                let req = match &focus {
                    // A key on the focused panel runs its `keyboard:` rows
                    // (`mods.ctrl` or `mods.meta` is a row's Ctrl).
                    Some(pid) => json!({"panel": pid, "key": key, "mods": mods}),
                    None if flag(st, "meta") => {
                        refuse(&mut out, "meta on a key the canvas route does not take".to_string());
                        break;
                    }
                    None => json!({"key": key, "mods": mods}),
                }.to_string();
                let reply = take(unsafe { jas_dispatch_action(e, req.as_ptr(), req.len()) });
                if !ran(&mut out, reply, last_error(e)) {
                    break;
                }
            } else if let Some(menu_id) = st.get("menu").and_then(Value::as_str) {
                focus = None;
                let req = json!({"menu_item": menu_id}).to_string();
                let reply = take(unsafe { jas_dispatch_action(e, req.as_ptr(), req.len()) });
                if !ran(&mut out, reply, last_error(e)) {
                    break;
                }
            } else if let Some(panel) = st.get("panel").and_then(Value::as_str) {
                let (Some(widget), Some(event)) = (st["widget"].as_str(), st["event"].as_str()) else {
                    refuse(&mut out, "a panel step names a widget and an event".to_string());
                    break;
                };
                if flag(st, "meta") {
                    refuse(&mut out, "meta on a panel step is refused (TESTING.md section 6)".to_string());
                    break;
                }
                if st.get("at").is_some() {
                    refuse(&mut out, "`at` is not delivered by this runner".to_string());
                    break;
                }
                let row = match st.get("row") {
                    None => None,
                    Some(r) => match r.as_array().and_then(|a| a.iter().map(Value::as_u64).collect::<Option<Vec<u64>>>()) {
                        Some(r) => Some(r),
                        None => { refuse(&mut out, format!("row {r} is not a path")); break; }
                    },
                };
                // Form 6: a double click delivers ONE click, then the double.
                let events: &[&str] = if event == "double_click" { &["click", "double_click"] } else { &[event] };
                let mut ok = true;
                for &name in events {
                    let mut ev = json!({"widget": widget, "event": name,
                        "shift": flag(st, "shift"), "alt": flag(st, "alt"), "ctrl": flag(st, "ctrl")});
                    if let Some(v) = st.get("value") {
                        ev["value"] = v.clone();
                    }
                    if let Some(row) = &row {
                        // The rows are re-read for each event, in the scope it
                        // runs in, since the click before a double can change it.
                        let (Some(spec), Some(scope)) = (
                            crate::interpreter::workspace::Workspace::load().and_then(|ws| ws.panel(panel).cloned()),
                            engine.script_panel_scope(panel)) else {
                            refuse(&mut out, format!("UnknownPanel {panel}"));
                            ok = false;
                            break;
                        };
                        let spec = crate::panel_plan::canonical_tabs(&spec, &scope);
                        match row_plan_path(spec.get("content").unwrap_or(&Value::Null), widget, name, row, &scope) {
                            Ok((p, to)) => {
                                ev["path"] = json!(p);
                                if let Some(to) = to {
                                    out.push(json!({"step": i, "event": name, "bubbled_to": to}));
                                }
                            }
                            Err(why) => { refuse(&mut out, why); ok = false; break; }
                        }
                    }
                    let ev = ev.to_string();
                    let reply = take(unsafe { jas_panel_behavior(e, panel.as_ptr(), panel.len(), ev.as_ptr(), ev.len()) });
                    if !ran(&mut out, reply, last_error(e)) {
                        ok = false;
                        break;
                    }
                }
                if !ok {
                    break;
                }
                focus = Some(panel.to_string());
            } else {
                let form = ["dialog", "context_menu", "panel_menu"].into_iter().find(|k| st.get(*k).is_some());
                refuse(&mut out, match form {
                    Some(f) => format!("the `{f}` form is not delivered by this runner"),
                    None => format!("{st} is not a step this runner knows"),
                });
                break;
            }
        }
        Ok(out)
    })();
    unsafe { jas_engine_free(e) };
    result
}

/// A Layers script over `complex_document.svg` (tree: `[0]` Shapes holding a
/// rect, a circle and a group `[0,2]` around a line; `[1]` Text holding a
/// text), with the selection tool and the given steps.
fn layers_script(steps: Value) -> Value {
    serde_json::json!({"item": "forms.arm", "setup_svg": "complex_document.svg", "tool": "selection", "steps": steps})
}

const LAYERS: &str = "layers_panel_content";

/// The `read: panel` values of a replay, in order.
fn panel_reads(out: &[Value]) -> Vec<Value> {
    out.iter().filter(|r| r["read"] == "panel").map(|r| r["value"].clone()).collect()
}

fn refusal(out: &[Value]) -> Option<String> {
    out.iter().find_map(|r| r["refused"].as_str().map(str::to_string))
}

fn click_row(row: Value, mods: &[&str]) -> Value {
    let mut st = serde_json::json!({"panel": LAYERS, "widget": "lp_name", "row": row, "event": "click"});
    for m in mods {
        st[*m] = Value::Bool(true);
    }
    st
}

fn read_layers() -> Value {
    serde_json::json!({"read": "panel", "panel": LAYERS})
}

/// The tree's row paths in draw order, from the engine's own `element_tree`
/// (nothing collapsed), so an arm's expected row is derived, never typed.
fn tree_order() -> Vec<Value> {
    let e = jas_engine_new();
    let engine = unsafe { e.as_ref() }.unwrap();
    engine.replace_document(crate::geometry::svg::try_open_svg_document(&read("svg/complex_document.svg")).unwrap());
    let scope = engine.script_panel_scope(LAYERS).unwrap();
    unsafe { jas_engine_free(e) };
    let rows = scope["active_document"]["element_tree"].as_array().cloned().unwrap_or_default();
    assert!(rows.len() >= 7, "the tree has the setup's seven elements: {rows:?}");
    rows.iter().map(|r| r["path"].clone()).collect()
}

#[test]
fn a_row_click_on_the_name_selects_that_row_by_bubbling_to_the_row() {
    let _counters = crate::ffi_instr::test_lock::lock();
    // Two rows, so an arm that ignored `row` (or took row 0) reds one of them.
    for row in [serde_json::json!([0, 1]), serde_json::json!([1])] {
        let out = replay_forms(&layers_script(serde_json::json!([click_row(row.clone(), &[]), read_layers()]))).unwrap();
        assert_eq!(refusal(&out), None, "{out:?}");
        assert!(out.iter().any(|r| r["bubbled_to"].is_string()), "lp_name declares no click, so it bubbles: {out:?}");
        assert_eq!(panel_reads(&out)[0]["layers_panel_selection"], serde_json::json!([row]), "{out:?}");
    }
}

#[test]
fn a_shift_click_extends_and_a_plain_click_after_it_replaces() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let out = replay_forms(&layers_script(serde_json::json!([
        click_row(serde_json::json!([0, 1]), &[]), click_row(serde_json::json!([0, 0]), &["shift"]), read_layers(),
        click_row(serde_json::json!([1]), &[]), read_layers(),
    ]))).unwrap();
    assert_eq!(refusal(&out), None, "{out:?}");
    let reads = panel_reads(&out);
    let extended = reads[0]["layers_panel_selection"].as_array().cloned().unwrap_or_default();
    assert!(extended.len() >= 2 && extended.contains(&serde_json::json!([0, 1])) && extended.contains(&serde_json::json!([0, 0])),
        "Shift extends: {extended:?}");
    assert_eq!(reads[1]["layers_panel_selection"], serde_json::json!([[1]]), "a plain click replaces");
}

#[test]
fn an_eye_click_runs_on_the_eye_without_bubbling() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let out = replay_forms(&layers_script(serde_json::json!([
        {"panel": LAYERS, "widget": "lp_eye", "row": [1], "event": "click"}, read_layers(), {"read": "document"},
    ]))).unwrap();
    assert_eq!(refusal(&out), None, "{out:?}");
    assert!(!out.iter().any(|r| r["bubbled_to"].is_string()), "lp_eye declares its own click: {out:?}");
    // The read is anywhere in the script, and the document read comes after it.
    assert_eq!(out.iter().filter(|r| r["read"].is_string()).map(|r| r["read"].clone()).collect::<Vec<_>>(),
        vec![serde_json::json!("panel"), serde_json::json!("document")]);
}

/// The element at `path` in a `document` read-back.
fn doc_element<'a>(doc: &'a Value, path: &[usize]) -> &'a Value {
    let mut level = &doc["layers"];
    let mut node = &Value::Null;
    for &i in path {
        node = &level[i];
        level = &node["children"];
    }
    node
}

fn doc_reads(out: &[Value]) -> Vec<Value> {
    out.iter().filter(|r| r["read"] == "document").map(|r| r["value"].clone()).collect()
}

/// A Layers row widget's action writes the DOCUMENT, not only the panel (its
/// `snapshot` and `doc.op` effects). Swift's twin
/// `formsALayersRowActionWritesTheDocument` was red on all four checks until
/// 2026-11-06: that route dropped `doc.op`, and M3's control read every
/// document read back as the setup. This pins the same four here.
#[test]
fn a_layers_row_action_writes_the_document() {
    let _counters = crate::ffi_instr::test_lock::lock();
    for (widget, row, field, want) in [
        ("lp_eye", [0usize, 1], "visibility", serde_json::json!("outline")),
        ("lp_lock", [0, 0], "locked", serde_json::json!(true)),
    ] {
        let out = replay_forms(&layers_script(serde_json::json!([
            {"panel": LAYERS, "widget": widget, "row": row, "event": "click"}, {"read": "document"},
        ]))).unwrap();
        assert_eq!(refusal(&out), None, "{widget}: {out:?}");
        let docs = doc_reads(&out);
        assert_eq!(doc_element(&docs[0], &row)[field], want, "{widget} on {row:?}: {out:?}");
    }
    let out = replay_forms(&layers_script(serde_json::json!([
        {"panel": LAYERS, "widget": "lp_select", "row": [0, 1], "event": "click"}, {"read": "document"},
    ]))).unwrap();
    assert_eq!(doc_reads(&out)[0]["selection"].as_array().map(Vec::len), Some(1), "lp_select on [0,1]: {out:?}");
    let out = replay_forms(&layers_script(serde_json::json!([
        {"panel": LAYERS, "widget": "lp_eye", "row": [0, 1], "event": "click"}, {"read": "document"},
        {"menu": "menu_undo"}, {"read": "document"},
    ]))).unwrap();
    let vis: Vec<Value> = doc_reads(&out).iter().map(|d| doc_element(d, &[0, 1])["visibility"].clone()).collect();
    assert_eq!(vis, vec![serde_json::json!("outline"), serde_json::json!("preview")], "the click writes, undo restores: {out:?}");
}

#[test]
fn a_key_after_a_panel_step_goes_to_the_panels_keyboard_rows() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let order = tree_order();
    let at = order.iter().position(|p| *p == serde_json::json!([0, 1])).expect("[0,1] is a row");
    let next = order.get(at + 1).cloned().expect("a row below [0,1]");
    let out = replay_forms(&layers_script(serde_json::json!([
        click_row(serde_json::json!([0, 1]), &[]), {"key": "ArrowDown"}, read_layers(),
    ]))).unwrap();
    assert_eq!(refusal(&out), None, "{out:?}");
    assert_eq!(panel_reads(&out)[0]["layers_panel_selection"], serde_json::json!([next]), "{out:?}");
}

#[test]
fn read_panel_reads_exactly_the_declared_state_keys_with_paths_as_arrays() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let ws = crate::interpreter::workspace::Workspace::load().unwrap();
    let mut declared: Vec<String> = ws.panel_state_defaults(LAYERS).into_keys().collect();
    declared.sort();
    assert!(declared.iter().any(|k| k == "layers_panel_selection"), "{declared:?}");
    let out = replay_forms(&layers_script(serde_json::json!([click_row(serde_json::json!([0, 2]), &[]), read_layers()]))).unwrap();
    let read = &panel_reads(&out)[0];
    let got: Vec<String> = read.as_object().unwrap().keys().cloned().collect();
    assert_eq!(got, declared, "declared keys only, sorted");
    assert!(!read.to_string().contains("__path__"), "a path reads as an index array: {read}");
}

#[test]
fn app_state_seeds_a_declared_panel_key_as_paths() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let mut script = layers_script(serde_json::json!([read_layers()]));
    script["app_state"] = serde_json::json!({"panels": {LAYERS: {"collapsed_paths": [[0]]}}});
    let out = replay_forms(&script).unwrap();
    assert_eq!(panel_reads(&out)[0]["collapsed_paths"], serde_json::json!([[0]]), "{out:?}");
    // Control: without the seed the key reads its declared default.
    let out = replay_forms(&layers_script(serde_json::json!([read_layers()]))).unwrap();
    assert_eq!(panel_reads(&out)[0]["collapsed_paths"], serde_json::json!([]), "{out:?}");
}

/// Row 78 step 3: a canvas selection inside a collapsed group opens it, at
/// LEVEL 1, through the engine's own crossing (the spec's
/// `layers.reveal_uncollapse` script: complex_document.svg, the point at
/// (136, 48) selects [0,2,0]). Control: the same seed with no gesture keeps it.
#[test]
fn a_canvas_selection_inside_a_collapsed_group_reveals_it() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let script = |steps: Value| {
        let mut s = serde_json::json!({"item": "forms.reveal", "setup_svg": "complex_document.svg",
                                       "tool": "interior_selection", "steps": steps});
        s["app_state"] = serde_json::json!({"panels": {LAYERS: {"collapsed_paths": [[0, 2]]}}});
        s
    };
    let control = replay_forms(&script(serde_json::json!([read_layers()]))).unwrap();
    assert_eq!(panel_reads(&control)[0]["collapsed_paths"], serde_json::json!([[0, 2]]), "{control:?}");
    let out = replay_forms(&script(serde_json::json!([
        {"kind": "press", "x": 136, "y": 48}, {"kind": "release", "x": 136, "y": 48}, read_layers(),
    ]))).unwrap();
    assert_eq!(refusal(&out), None, "{out:?}");
    assert_eq!(panel_reads(&out)[0]["collapsed_paths"], serde_json::json!([]), "the reveal opened [0,2]: {out:?}");
}

#[test]
fn each_unrunnable_form_is_refused_by_name() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let mut top = layers_script(serde_json::json!([read_layers()]));
    top["app_state"] = serde_json::json!({"collapsed_paths": []});
    assert!(replay_forms(&top).unwrap_err().contains("app_state.collapsed_paths is not a ruled form"));
    let mut undeclared = layers_script(serde_json::json!([read_layers()]));
    undeclared["app_state"] = serde_json::json!({"panels": {LAYERS: {"no_such_key": 1}}});
    assert!(replay_forms(&undeclared).unwrap_err().contains("UndeclaredPanelKey"));
    for (step, needle) in [
        (click_row(serde_json::json!([9]), &[]), "0 row(s)"),
        (click_row(serde_json::json!([0, 1]), &["meta"]), "meta on a panel step"),
        (serde_json::json!({"panel": LAYERS, "widget": "lp_search_input", "row": [0], "event": "click"}), "which no foreach repeats"),
        (serde_json::json!({"panel": LAYERS, "widget": "lp_name", "event": "click"}), "NotAddressable"),
        (serde_json::json!({"panel": LAYERS, "widget": "lp_name", "at": [0], "event": "click"}), "`at` is not delivered"),
        (serde_json::json!({"context_menu": "x", "params": {}}), "the `context_menu` form is not delivered"),
        (serde_json::json!({"read": "panel_menu", "panel": LAYERS}), "read: panel_menu is not delivered"),
    ] {
        let out = replay_forms(&layers_script(serde_json::json!([step.clone(), read_layers()]))).unwrap();
        let why = refusal(&out).unwrap_or_default();
        assert!(why.contains(needle), "{step}: wanted a refusal naming `{needle}`, got {out:?}");
        assert!(panel_reads(&out).is_empty(), "a refusal ends the replay: {out:?}");
    }
}

/// THE M3 DOOR: `JAS_FORMS_DIR=<dir>` replays every `*.json` script there that
/// is not an `.expected.json`, and writes each one's read-backs to
/// `JAS_FORMS_OUT` (default `<dir>/forms-readbacks.json`), stamped with the
/// sha the caller passes in `JAS_FORMS_SHA`. Without `JAS_FORMS_DIR` it does
/// nothing and says so. A settling day runs it on the control; it is not a gate.
#[test]
fn forms_replay_of_a_named_script_directory() {
    let Ok(dir) = std::env::var("JAS_FORMS_DIR") else {
        eprintln!("forms_replay: JAS_FORMS_DIR unset, nothing replayed");
        return;
    };
    let _counters = crate::ffi_instr::test_lock::lock();
    let mut names: Vec<String> = std::fs::read_dir(&dir).unwrap()
        .map(|d| d.unwrap().file_name().into_string().unwrap())
        .filter(|n| n.ends_with(".json") && !n.ends_with(".expected.json") && n != "forms-readbacks.json")
        .collect();
    names.sort();
    assert!(!names.is_empty(), "JAS_FORMS_DIR={dir} holds no script");
    let mut all = serde_json::Map::new();
    for n in &names {
        let script: Value = serde_json::from_str(&std::fs::read_to_string(format!("{dir}/{n}")).unwrap()).unwrap();
        all.insert(n.clone(), match replay_forms(&script) {
            Ok(out) => Value::Array(out),
            Err(why) => serde_json::json!({"not_started": why}),
        });
    }
    let doc = serde_json::json!({"control-sha": std::env::var("JAS_FORMS_SHA").unwrap_or_else(|_| "UNNAMED".into()),
                                 "scripts": all});
    let path = std::env::var("JAS_FORMS_OUT").unwrap_or_else(|_| format!("{dir}/forms-readbacks.json"));
    std::fs::write(&path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
    eprintln!("forms_replay: {} script(s) -> {path}", names.len());
}

/// G11's script form (jas STATUS-flask 756): press, release, press, release,
/// `{"kind": "double_click"}` on complex_document.svg's group `[0, 2]`, then a
/// click, read back. The point is the group's line's midpoint, read from the
/// fixture, never typed; the CONTROL is the same clicks with no double.
fn g11_script(double: bool) -> Value {
    let svg = read("svg/complex_document.svg");
    let doc = crate::geometry::svg::svg_to_document(&svg);
    let (x, y) = match doc.get_element(&vec![0, 2, 0].into()) {
        Some(crate::geometry::element::Element::Line(l)) => ((l.x1 + l.x2) / 2.0, (l.y1 + l.y2) / 2.0),
        other => panic!("the fixture's [0, 2, 0] is not a line: {other:?}"),
    };
    let click = |k: &str| serde_json::json!({"kind": k, "x": x, "y": y});
    let mut steps = vec![click("press"), click("release"), click("press"), click("release")];
    if double { steps.push(click("double_click")); }
    steps.extend([click("press"), click("release"), serde_json::json!({"read": "document"})]);
    serde_json::json!({"item": "g11", "setup_svg": "complex_document.svg", "tool": "selection",
                       "app_state": {}, "steps": steps, "expected_json": "-"})
}

fn selected_paths_of(doc_json: &str) -> Vec<Value> {
    let v: Value = serde_json::from_str(doc_json).expect("the read-back is JSON");
    v["selection"].as_array().cloned().unwrap_or_default().iter().map(|s| s["path"].clone()).collect()
}

#[test]
fn the_engine_replay_delivers_a_double_click_step() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let entered = replay(&g11_script(true)).expect("the double_click step is delivered");
    assert_eq!(selected_paths_of(&entered), vec![serde_json::json!([0, 2, 0])], "isolated: the click selects the child");
    let control = replay(&g11_script(false)).unwrap();
    assert_eq!(selected_paths_of(&control), vec![serde_json::json!([0, 2])], "no double: the click selects the group");
}

#[test]
fn the_forms_replay_delivers_a_double_click_step() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let out = replay_forms(&g11_script(true)).unwrap();
    assert_eq!(refusal(&out), None, "{out:?}");
    let reads = doc_reads(&out);
    let doc = reads.last().expect("one document read");
    let text = doc.as_str().map(str::to_string).unwrap_or_else(|| doc.to_string());
    assert_eq!(selected_paths_of(&text), vec![serde_json::json!([0, 2, 0])], "isolated: the click selects the child");
}
