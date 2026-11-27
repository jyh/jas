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
    jas_last_error_json, jas_panel_behavior, jas_panel_menu, jas_panel_row_menu, JasBytes, JasEngine, JasStatus,
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

/// **The Gradient panel's trash button deletes the selected stop** (GRADIENT.md
/// TRASH_BUTTON: disabled when no stop is selected or only two remain; the law
/// is `delete_stop`, pinned by `gradient_stop/slider.json`). Until row 198 the
/// YAML declared the button with no behavior, so a click did nothing in any
/// port. A slider `add` at 40 gives the rect's seed (blue to white) a third
/// stop, and a press/release on stop 0 selects the blue, so the click leaves
/// the added stop at 40 and the white. The control is the same click on the
/// two-stop seed, refused as Disabled.
#[test]
fn the_gradient_trash_button_deletes_the_selected_stop() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let script = |steps: Value| serde_json::json!({
        "item": "t", "setup_svg": "rect_with_stroke.svg", "tool": "selection", "app_state": {},
        "steps": steps, "expected_json": "-"});
    let press = serde_json::json!([{"kind": "press", "x": 36, "y": 18}, {"kind": "release", "x": 36, "y": 18}]);
    let slider = |event: &str, value: Value| serde_json::json!({"panel": "gradient_panel_content",
        "widget": "grad_slider", "event": event, "value": value});
    let add = slider("add", serde_json::json!({"location": 40}));
    let pick0 = slider("press", serde_json::json!({"index": 0, "location": 0}));
    let up0 = slider("release", serde_json::json!({"location": 0, "dy": 0}));
    let trash = serde_json::json!({"panel": "gradient_panel_content", "widget": "grad_trash_button", "event": "click"});
    let read = serde_json::json!({"read": "document"});
    let three = replay(&script(serde_json::json!([press[0], press[1], add, pick0, up0, read])));
    let three: Value = serde_json::from_str(three.as_ref().expect("the add and the pick must run")).unwrap();
    assert_eq!(three["layers"][0]["children"][0]["fill_gradient"]["stops"].as_array().map(Vec::len), Some(3),
        "the setup must reach three stops before the click means anything, got {three}");
    let deleted = replay(&script(serde_json::json!([press[0], press[1], add, pick0, up0, trash, read])));
    let doc = deleted.as_ref().expect("the trash click on three stops must run");
    let v: Value = serde_json::from_str(doc).unwrap();
    let stops = &v["layers"][0]["children"][0]["fill_gradient"]["stops"];
    let got: Vec<(f64, f64)> = stops.as_array().expect("the rect has gradient stops").iter()
        .map(|s| (s["location"].as_f64().unwrap(), s["color"]["r"].as_f64().unwrap())).collect();
    assert_eq!(got.len(), 2, "one stop deleted, got {stops}");
    assert_eq!(got[0].0, 40.0, "the selected stop 0 (blue at 0) is the one deleted, got {stops}");
    assert_eq!(got[1].0, 100.0, "got {stops}");
    let at_floor = replay(&script(serde_json::json!([press[0], press[1], trash, read])));
    assert!(at_floor.as_ref().is_err_and(|e| e.contains("Disabled")),
        "a trash click at the two-stop floor must be refused as Disabled, got {at_floor:?}");
}

/// **The Location combo on a selected midpoint moves the midpoint** (GRADIENT.md
/// STOP_LOCATION_COMBO: for a midpoint, its absolute location; the law is
/// `drag_midpoint`, pinned by `gradient_stop/slider.json`). Until row 198 the
/// commit went to the selected STOP, index -1 once a midpoint is picked, and
/// the law refused it, so the combo was enabled and did nothing. On the seed
/// (stops at 0 and 100) an absolute 30 is `midpoint_to_next` 30; the control is
/// the same commit with a stop selected, which moves that stop.
#[test]
fn the_location_combo_on_a_midpoint_moves_the_midpoint() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let script = |steps: Value| serde_json::json!({
        "item": "t", "setup_svg": "rect_with_stroke.svg", "tool": "selection", "app_state": {},
        "steps": steps, "expected_json": "-"});
    let press = serde_json::json!([{"kind": "press", "x": 36, "y": 18}, {"kind": "release", "x": 36, "y": 18}]);
    let slider = |event: &str, value: Value| serde_json::json!({"panel": "gradient_panel_content",
        "widget": "grad_slider", "event": event, "value": value});
    let pick_mid = slider("press_midpoint", serde_json::json!({"pair": 0, "location": 50}));
    let up_mid = slider("release_midpoint", serde_json::json!({"location": 50}));
    let commit = serde_json::json!({"panel": "gradient_panel_content", "widget": "grad_stop_location_combo",
        "event": "commit", "value": "30"});
    let read = serde_json::json!({"read": "document"});
    let stops_of = |r: Result<String, String>| -> Value {
        let doc: Value = serde_json::from_str(&r.expect("the script must run")).unwrap();
        doc["layers"][0]["children"][0]["fill_gradient"]["stops"].clone()
    };
    let mid = stops_of(replay(&script(serde_json::json!([press[0], press[1], pick_mid, up_mid, commit, read]))));
    assert_eq!(mid[0]["midpoint_to_next"].as_f64(), Some(30.0), "the midpoint moves to 30, got {mid}");
    assert_eq!((mid[0]["location"].as_f64(), mid[1]["location"].as_f64()), (Some(0.0), Some(100.0)),
        "the stops do not move, got {mid}");
    let stop = stops_of(replay(&script(serde_json::json!([press[0], press[1], commit, read]))));
    assert_eq!(stop[0]["location"].as_f64(), Some(30.0), "with stop 0 selected the stop moves, got {stop}");
    assert_eq!(stop[0]["midpoint_to_next"].as_f64(), Some(50.0), "got {stop}");
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
fn row_plan_path(content: &Value, widget: &str, event: &str, row: RowAddr, scope: &Value)
    -> Result<(Vec<usize>, Option<String>), String> {
    row_declaring(content, widget, event, row, scope).map(|(p, to, _)| (p, to))
}

/// How a panel step names the repeated widget it addresses (TESTING.md
/// section 6): `row`, a tree row by its element's document path, under exactly
/// one repeat; or `at` (row 281), each enclosing generic `foreach` repeat's
/// iteration index, outermost first. A widget has ONE address: `at` is refused
/// on a repeat whose rows are document elements, which `row` names.
#[derive(Clone, Copy, Debug)]
enum RowAddr<'a> {
    Row(&'a [u64]),
    At(&'a [u64]),
}

impl std::fmt::Display for RowAddr<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RowAddr::Row(r) => write!(f, "row {r:?}"),
            RowAddr::At(a) => write!(f, "at {a:?}"),
        }
    }
}

/// [`row_plan_path`] and the node the event goes to.
fn row_declaring(content: &Value, widget: &str, event: &str, row: RowAddr, scope: &Value)
    -> Result<(Vec<usize>, Option<String>, Value), String> {
    let (path, chain) = row_chain(content, widget, row, scope)?;
    // The walk ends on the widget, so the chain's last node is the widget.
    let Some(at) = chain.iter().rposition(|(_, node, _)| declares(node, event)) else {
        return Err(format!("no node on `{widget}`'s path in {row} declares `{event}`"));
    };
    let (len, node, _) = &chain[at];
    let to = (at + 1 != chain.len()).then(|| node.get("id").and_then(Value::as_str)
        .map_or_else(|| format!("{:?}", &path[..*len]), str::to_string));
    Ok((path[..*len].to_vec(), to, node.clone()))
}

/// Whether `node`'s entries for `event` declare an action or effects. A drag
/// event whose entries declare none runs nothing, in every port, so the runner
/// records it `unchanged` without a door call.
fn declares_an_act(node: &Value, event: &str) -> bool {
    node.get("behavior").and_then(Value::as_array).is_some_and(|b| b.iter().any(|entry|
        entry.get("event").and_then(Value::as_str).unwrap_or("click") == event
            && (entry.get("action").is_some() || entry.get("effects").is_some())))
}

/// Whether `node`'s `behavior:` declares `event` (an entry with no `event` is
/// a click).
fn declares(node: &Value, event: &str) -> bool {
    node.get("behavior").and_then(Value::as_array).is_some_and(|b| b.iter()
        .any(|entry| entry.get("event").and_then(Value::as_str).unwrap_or("click") == event))
}

/// The widget ITSELF in row `row`, with no bubbling: its path, its node and
/// its row's scope. A text field's own events do not bubble (section 6: an
/// `input` on a field that declares none fires nothing).
fn row_widget(content: &Value, widget: &str, row: RowAddr, scope: &Value)
    -> Result<(Vec<usize>, Value, Value), String> {
    let (path, mut chain) = row_chain(content, widget, row, scope)?;
    let (_, node, scope) = chain.pop().expect("the walk ends on the widget");
    Ok((path, node, scope))
}

/// F1c (row 145): the hover that expands a collapsed container (layers.yaml,
/// "Hovering over a collapsed container for 500ms auto-expands it").
const HOVER_EXPAND_MS: f64 = 500.0;

/// F1c (row 145, spec's SPEC-coll rule): an `into` drag that hovers `target`
/// long enough removes it from `collapsed_paths`; nothing else is touched.
/// The runner computes it from the rule, never from a shell's hover tick.
/// Twin of Swift's `formsHoverExpand`.
fn hover_expand(engine: &JasEngine, panel: &str, target: &[u64]) -> Result<(), String> {
    let state = engine.script_panel_state(panel).ok_or_else(|| format!("UnknownPanel {panel}"))?;
    let paths = canonical_panel_value(state.get("collapsed_paths").unwrap_or(&Value::Null));
    let paths = paths.as_array().cloned().unwrap_or_default();
    let target = serde_json::json!(target);
    if !paths.contains(&target) {
        return Ok(());
    }
    let kept: Vec<Value> = paths.into_iter().filter(|p| *p != target).collect();
    engine.script_seed_panel(panel, "collapsed_paths", crate::ffi::seed_panel_value(&Value::Array(kept)))
}

/// F6 (row 145, TESTING.md section 6): the ids of the fields a row step can
/// leave SHOWN on its row, which then hold key focus, as every shell focuses the
/// field an inline rename shows: each `text_input` that declares
/// `bind.visible`. The caller keeps the ones a foreach repeats and whose
/// `visible` holds in the row's scope. A field with no `visible` bind is always
/// shown and takes focus only by an `input` step. Twin of Swift's `formsShownField`.
fn shown_field_candidates(node: &Value) -> Vec<String> {
    let mut ids = vec![];
    fn walk(n: &Value, ids: &mut Vec<String>) {
        match n {
            Value::Array(a) => a.iter().for_each(|c| walk(c, ids)),
            Value::Object(m) => {
                if m.get("type").and_then(Value::as_str) == Some("text_input")
                    && m.get("bind").and_then(|b| b.get("visible")).is_some() {
                    if let Some(id) = m.get("id").and_then(Value::as_str) {
                        ids.push(id.to_string());
                    }
                }
                for k in ["children", "do"] {
                    if let Some(c) = m.get(k) {
                        walk(c, ids);
                    }
                }
            }
            _ => {}
        }
    }
    walk(node, &mut ids);
    ids
}

/// The first node whose `id` is `widget`, anywhere under `node`.
fn find_widget<'a>(node: &'a Value, widget: &str) -> Option<&'a Value> {
    match node {
        Value::Object(m) => {
            if m.get("id").and_then(Value::as_str) == Some(widget) {
                return Some(node);
            }
            m.values().find_map(|v| find_widget(v, widget))
        }
        Value::Array(a) => a.iter().find_map(|v| find_widget(v, widget)),
        _ => None,
    }
}

/// The walk from `content` to `widget` in row `row`: the widget's path, and
/// each node on the way with the path length at it and the scope it renders in.
#[allow(clippy::type_complexity)]
fn row_chain(content: &Value, widget: &str, row: RowAddr, scope: &Value)
    -> Result<(Vec<usize>, Vec<(usize, Value, Value)>), String> {
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
    fn walk(node: &Value, widget: &str, row: RowAddr, scope: &Value, path: &mut Vec<usize>, repeats: &mut usize,
            chain: &mut Vec<(usize, Value, Value)>) -> Result<bool, String> {
        chain.push((path.len(), node.clone(), scope.clone()));
        if node.get("id").and_then(Value::as_str) == Some(widget) {
            return Ok(true);
        }
        if let Some(rows) = crate::interpreter::foreach::row_scopes(node, scope) {
            let template = &node["do"];
            if !contains(template, widget) {
                return Ok(false);
            }
            let depth = *repeats;
            *repeats += 1;
            let var = node["foreach"].get("as").and_then(Value::as_str).unwrap_or("item");
            let source = node["foreach"]["source"].as_str().unwrap_or("?");
            let as_path = |v: &Value| -> Option<Vec<u64>> {
                let v = v.get("__path__").unwrap_or(v);
                v.as_array()?.iter().map(Value::as_u64).collect()
            };
            let i = match row {
                RowAddr::Row(r) => {
                    let hits: Vec<usize> = rows.iter().enumerate()
                        .filter(|(_, x)| x[var].get("path").and_then(as_path).as_deref() == Some(r))
                        .map(|(i, _)| i)
                        .collect();
                    let &[i] = hits.as_slice() else {
                        return Err(format!("row {r:?} is {} row(s) of `{source}`, not one", hits.len()));
                    };
                    i
                }
                RowAddr::At(a) => {
                    if rows.iter().any(|x| x[var].get("path").is_some()) {
                        return Err(format!("`{widget}` repeats once per document element of `{source}`; \
                            address it by `row`, not `at`"));
                    }
                    let Some(&k) = a.get(depth) else {
                        return Err(format!("`at` names {} index(es) and `{widget}` sits under more repeats", a.len()));
                    };
                    let k = k as usize;
                    if k >= rows.len() {
                        return Err(format!("at {a:?}: index {k} is past the {} row(s) of `{source}`", rows.len()));
                    }
                    k
                }
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
    match (row, repeats) {
        (RowAddr::Row(_), 0) => return Err(format!("`row` on `{widget}`, which no foreach repeats")),
        (RowAddr::Row(_), 1) => {}
        (RowAddr::Row(_), n) => return Err(format!("`{widget}` sits under {n} foreach repeats; that address is `at`")),
        (RowAddr::At(_), 0) => return Err(format!("`at` on `{widget}`, which no foreach repeats")),
        (RowAddr::At(a), n) if a.len() != n => {
            return Err(format!("`at` names {} index(es) and `{widget}` sits under {n} repeat(s)", a.len()));
        }
        (RowAddr::At(_), _) => {}
    }
    Ok((path, chain))
}

/// Each item of panel `pid`'s menu as (menu index, canonical item, yaml node)
/// (design section 8 form 4): the rows `jas_panel_menu` draws for a shell,
/// separators omitted, as `{action, params, enabled, checked}`, with the
/// node's declared `params`. `Err` names an unknown panel.
fn panel_menu_items(e: *mut JasEngine, pid: &str) -> Result<Vec<(u64, Value, Value)>, String> {
    let Some(rows) = take(unsafe { jas_panel_menu(e, pid.as_ptr(), pid.len()) }) else {
        return Err(format!("UnknownPanel {pid}"));
    };
    let rows: Vec<Value> = serde_json::from_str(&rows).map_err(|x| x.to_string())?;
    let menu = crate::interpreter::workspace::Workspace::load().map(|ws| ws.panel_menu(pid)).unwrap_or_default();
    Ok(rows.iter().filter(|r| r["kind"] == "item").map(|r| {
        let at = r["index"].as_u64().unwrap_or(0);
        let node = menu.get(at as usize).cloned().unwrap_or(Value::Null);
        let item = serde_json::json!({"action": r["action"].clone(),
            "params": node.get("params").cloned().unwrap_or_else(|| serde_json::json!({})),
            "enabled": r["enabled"].clone(), "checked": r["checked"].clone()});
        (at, item, node)
    }).collect())
}

/// A param value as text, for matching a step's param against a declared one
/// (a string is itself, any other value its JSON), as Swift's `"\(v)"`.
fn plain(v: &Value) -> String {
    v.as_str().map_or_else(|| v.to_string(), str::to_string)
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
                        engine.script_seed_panel(pid, key, crate::ffi::seed_panel_value(val))
                            .map_err(|why| format!("script {item}: app_state.panels.{pid}.{key}: {why}"))?;
                    }
                }
            }
        }
        let mut out = vec![];
        // The panel a key goes to: the last panel step's, until a pointer or
        // menu step moves the focus to the canvas or the menubar.
        let mut focus: Option<String> = None;
        // The text field that holds key focus after an `input` step, and the
        // text it holds: (panel, widget, row, text). Re-resolved at each use,
        // because the row's scope (`panel.renaming_element`) moves under it.
        let mut field: Option<(String, String, Option<Vec<u64>>, String)> = None;
        // The context menu a row `secondary_press` opened: (panel, the row
        // widget's path, the entries the ENGINE EXPORTS for it,
        // `jas_panel_row_menu`, the list a native shell draws; row 257).
        // Only the very next step can pick from it (design section 8 form 2).
        let mut menu_open: Option<(String, Vec<usize>, Vec<Value>)> = None;
        // A widget by id, or by `row` with no bubbling: its path (by row
        // only), its node and the scope its expressions read.
        #[allow(clippy::type_complexity)]
        let resolve = |panel: &str, widget: &str, row: &Option<Vec<u64>>|
            -> Result<(Option<Vec<usize>>, Value, Value), String> {
            let (Some(spec), Some(scope)) = (
                crate::interpreter::workspace::Workspace::load().and_then(|ws| ws.panel(panel).cloned()),
                engine.script_panel_scope(panel)) else {
                return Err(format!("UnknownPanel {panel}"));
            };
            let spec = crate::panel_plan::canonical_tabs(&spec, &scope);
            let content = spec.get("content").cloned().unwrap_or(Value::Null);
            match row {
                Some(r) => row_widget(&content, widget, RowAddr::Row(r), &scope).map(|(p, n, sc)| (Some(p), n, sc)),
                None => find_widget(&content, widget).cloned().map(|n| (None, n, scope.clone()))
                    .ok_or_else(|| format!("widget `{widget}` is not in the panel")),
            }
        };
        for (i, st) in steps.iter().enumerate() {
            let opened = menu_open.take();
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
                    "panel_menu" => {
                        let pid = st["panel"].as_str().unwrap_or("");
                        match panel_menu_items(e, pid) {
                            Ok(items) => out.push(json!({"step": i, "read": "panel_menu", "panel": pid,
                                "value": items.into_iter().map(|(_, item, _)| item).collect::<Vec<_>>()})),
                            Err(why) => { refuse(&mut out, why); break; }
                        }
                    }
                    // Form (e): `read: tree` reads `drawn_rows`, the rows the
                    // tree DRAWS in its visible area, which only a level-2
                    // driver can see.
                    "tree" => {
                        out.push(json!({"step": i, "read": "tree", "value": "NOT APPLICABLE (read: tree is level 2 only)"}));
                    }
                    // The open dialog's id, or null when none is open.
                    "dialog" => {
                        let open = engine.script_dialog_id();
                        out.push(json!({"step": i, "read": "dialog", "value": open}));
                    }
                    other => {
                        refuse(&mut out, format!("read: {other} is not delivered by this runner"));
                        break;
                    }
                }
            } else if let Some(kind) = st.get("kind").and_then(Value::as_str) {
                focus = None;
                field = None;
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
            } else if let (Some(key), Some((fpanel, fwidget, frow, ftext))) =
                (st.get("key").and_then(Value::as_str), field.clone()) {
                // The field that holds key focus takes the key as its
                // `keydown`, with its text as `event.value`. Typing is the
                // `input` form, so a key the field declares nothing for is
                // refused, never dropped.
                let (path, node, _) = match resolve(&fpanel, &fwidget, &frow) {
                    Ok(t) => t,
                    Err(why) => { refuse(&mut out, why); break; }
                };
                let unbound = format!("UnboundFieldKey {fwidget}: {key}");
                if !declares(&node, "keydown") {
                    refuse(&mut out, unbound);
                    break;
                }
                let mut ev = json!({"widget": fwidget, "event": "keydown", "key": key, "value": ftext,
                    "shift": flag(st, "shift"), "alt": flag(st, "alt"), "ctrl": flag(st, "ctrl")});
                if let Some(p) = path {
                    ev["path"] = json!(p);
                }
                let ev = ev.to_string();
                let reply = take(unsafe { jas_panel_behavior(e, fpanel.as_ptr(), fpanel.len(), ev.as_ptr(), ev.len()) });
                let err = last_error(e);
                // The engine refuses a `keydown` no entry matches with
                // `EmptyBehavior` (no reply, so the error is this call's), and
                // Swift's door answers `inert`: both are the key the field
                // declares nothing for (row 145).
                if (reply.is_some() && err.contains("Unchanged"))
                    || (reply.is_none() && err.contains("\"EmptyBehavior\"")) {
                    refuse(&mut out, unbound);
                    break;
                }
                if !ran(&mut out, reply, err) {
                    break;
                }
                field = None;
                focus = Some(fpanel);
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
            } else if let Some(pid) = st.get("panel_menu").and_then(Value::as_str) {
                // Design section 8 form 3: the item whose action is the step's
                // and whose declared params equal every param the step names;
                // labels are never used. It runs as a shell's pick does
                // (`jas_dispatch_action({"panel", "menu_index"})`).
                focus = None;
                field = None;
                let items = match panel_menu_items(e, pid) {
                    Ok(v) => v,
                    Err(why) => { refuse(&mut out, why); break; }
                };
                let want = st["action"].as_str().unwrap_or("");
                let named = st.get("params").and_then(Value::as_object).cloned().unwrap_or_default();
                let hits: Vec<&(u64, Value, Value)> = items.iter().filter(|(_, item, node)| item["action"] == want
                    && named.iter().all(|(k, v)| node.get("params").and_then(|p| p.get(k))
                        .is_some_and(|d| plain(d) == plain(v)))).collect();
                let &[hit] = hits.as_slice() else {
                    refuse(&mut out, format!("`{want}` is {} item(s) of {pid}'s menu, not one", hits.len()));
                    break;
                };
                if hit.1["enabled"] != true {
                    refuse(&mut out, format!("the menu item `{want}` is disabled"));
                    break;
                }
                let req = json!({"panel": pid, "menu_index": hit.0}).to_string();
                let reply = take(unsafe { jas_dispatch_action(e, req.as_ptr(), req.len()) });
                if !ran(&mut out, reply, last_error(e)) {
                    break;
                }
            } else if let Some(menu_id) = st.get("menu").and_then(Value::as_str) {
                focus = None;
                field = None;
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
                // Row 281: `at`, each enclosing generic repeat's iteration index.
                let at = match st.get("at") {
                    None => None,
                    Some(a) => match a.as_array().and_then(|a| a.iter().map(Value::as_u64).collect::<Option<Vec<u64>>>()) {
                        Some(a) => Some(a),
                        None => { refuse(&mut out, format!("at {a} is not a list of indices")); break; }
                    },
                };
                if at.is_some() && st.get("row").is_some() {
                    refuse(&mut out, "a panel step names its widget by `row` or by `at`, not both".to_string());
                    break;
                }
                if at.is_some() && (event == "secondary_press" || event == "drag"
                    || st.get("to").is_some() || st.get("hover_ms").is_some()) {
                    refuse(&mut out, format!("`at` on a {event} step is not delivered by this runner"));
                    break;
                }
                let row = match st.get("row") {
                    None => None,
                    Some(r) => match r.as_array().and_then(|a| a.iter().map(Value::as_u64).collect::<Option<Vec<u64>>>()) {
                        Some(r) => Some(r),
                        None => { refuse(&mut out, format!("row {r} is not a path")); break; }
                    },
                };
                // Design section 8 form 1: a row `secondary_press` opens the
                // `context_menu:` of the nearest node on the widget's path, with
                // the row as its `node`. It dispatches nothing of its own.
                if event == "secondary_press" {
                    let Some(r) = row.clone() else {
                        refuse(&mut out, "a secondary_press names its `row`".to_string());
                        break;
                    };
                    let (Some(spec), Some(scope)) = (
                        crate::interpreter::workspace::Workspace::load().and_then(|ws| ws.panel(panel).cloned()),
                        engine.script_panel_scope(panel)) else {
                        refuse(&mut out, format!("UnknownPanel {panel}"));
                        break;
                    };
                    let spec = crate::panel_plan::canonical_tabs(&spec, &scope);
                    // Row 257 D3: the press first runs the row's own
                    // `secondary_press`, as every shell does before it opens
                    // the menu (layers.yaml: an unselected row becomes the sole
                    // selection). A condition that holds on no entry is
                    // `EmptyBehavior` with no reply, which is the press on a
                    // selected row, recorded `unchanged`. A panel whose rows
                    // declare no `secondary_press` sends nothing.
                    if let Ok((p, _, node)) = row_declaring(spec.get("content").unwrap_or(&Value::Null),
                                                            widget, "secondary_press", RowAddr::Row(&r), &scope) {
                        if declares_an_act(&node, "secondary_press") {
                            let ev = json!({"widget": widget, "event": "secondary_press", "path": p,
                                "shift": flag(st, "shift"), "alt": flag(st, "alt"), "ctrl": flag(st, "ctrl")}).to_string();
                            let reply = take(unsafe { jas_panel_behavior(e, panel.as_ptr(), panel.len(), ev.as_ptr(), ev.len()) });
                            let err = last_error(e);
                            if reply.is_none() && err.contains(r#""panel_event":"EmptyBehavior""#) {
                                out.push(json!({"step": i, "unchanged": true}));
                            } else if !ran(&mut out, reply, err) {
                                break;
                            }
                        }
                    }
                    // The selection may have moved: the menu is resolved in the
                    // scope as it now stands.
                    let Some(scope) = engine.script_panel_scope(panel) else {
                        refuse(&mut out, format!("UnknownPanel {panel}"));
                        break;
                    };
                    let (path, _chain) = match row_chain(spec.get("content").unwrap_or(&Value::Null), widget, RowAddr::Row(&r), &scope) {
                        Ok(t) => t,
                        Err(why) => { refuse(&mut out, why); break; }
                    };
                    // The entries are the ENGINE's export for this path, the list
                    // a native shell draws (row 257), so a pick below runs exactly
                    // what was drawn.
                    let pj = serde_json::to_string(&path).unwrap_or_default();
                    let Some(drawn) = take(unsafe { jas_panel_row_menu(e, panel.as_ptr(), panel.len(), pj.as_ptr(), pj.len()) }) else {
                        refuse(&mut out, last_error(e));
                        break;
                    };
                    let items: Vec<Value> = serde_json::from_str::<Value>(&drawn).ok()
                        .and_then(|v| v.as_array().cloned()).unwrap_or_default();
                    menu_open = Some((panel.to_string(), path.clone(), items));
                    field = None;
                    focus = Some(panel.to_string());
                    continue;
                }
                // F1 (row 137, section 6): the row's three declared events,
                // `drag_start` on the pressed row, `drag_move` and `drag_end`
                // on the target. A drag event whose entry declares an action
                // is refused by name: this route cannot pass its `event.drop_*`.
                if event == "drag" || st.get("to").is_some() || st.get("hover_ms").is_some() {
                    let to_row = st.get("to").and_then(|t| t.get("row")).and_then(Value::as_array)
                        .and_then(|a| a.iter().map(Value::as_u64).collect::<Option<Vec<u64>>>());
                    let Some(to_row) = to_row.filter(|_| event == "drag") else {
                        refuse(&mut out, "a row drag needs `to`: {row, zone}".to_string());
                        break;
                    };
                    let zone = st["to"].get("zone").and_then(Value::as_str).unwrap_or("");
                    if !["before", "into", "after"].contains(&zone) {
                        refuse(&mut out, "a row drag's zone is before, into or after".to_string());
                        break;
                    }
                    let Some(pressed) = row.clone() else {
                        refuse(&mut out, "a row drag names its pressed `row`".to_string());
                        break;
                    };
                    field = None;
                    let mut ok = true;
                    for (name, at) in [("drag_start", &pressed), ("drag_move", &to_row), ("drag_end", &to_row)] {
                        // F1c (row 145): the hover over the target expands it before the drop.
                        if name == "drag_end" && zone == "into"
                            && st.get("hover_ms").and_then(Value::as_f64).unwrap_or(0.0) >= HOVER_EXPAND_MS {
                            if let Err(why) = hover_expand(engine, panel, &to_row) {
                                refuse(&mut out, why);
                                ok = false;
                                break;
                            }
                        }
                        let (Some(spec), Some(scope)) = (
                            crate::interpreter::workspace::Workspace::load().and_then(|ws| ws.panel(panel).cloned()),
                            engine.script_panel_scope(panel)) else {
                            refuse(&mut out, format!("UnknownPanel {panel}"));
                            ok = false;
                            break;
                        };
                        let spec = crate::panel_plan::canonical_tabs(&spec, &scope);
                        let (p, to, node) = match row_declaring(spec.get("content").unwrap_or(&Value::Null), widget, name, RowAddr::Row(at), &scope) {
                            Ok(t) => t,
                            Err(why) => { refuse(&mut out, why); ok = false; break; }
                        };
                        if let Some(to) = to {
                            out.push(json!({"step": i, "event": name, "bubbled_to": to}));
                        }
                        if !declares_an_act(&node, name) {
                            out.push(json!({"step": i, "unchanged": true}));
                            continue;
                        }
                        if name != "drag_start" {
                            refuse(&mut out, format!("`{name}` declares an action that reads the drop's event fields, \
                                which this runner cannot pass yet"));
                            ok = false;
                            break;
                        }
                        let ev = json!({"widget": widget, "event": name, "path": p,
                            "shift": flag(st, "shift"), "alt": flag(st, "alt"), "ctrl": flag(st, "ctrl")}).to_string();
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
                    continue;
                }
                let kind = crate::interpreter::workspace::Workspace::load()
                    .and_then(|ws| ws.panel(panel).and_then(|p| find_widget(&p["content"], widget))
                        .and_then(|n| n.get("type")).and_then(Value::as_str).map(str::to_string));
                let text_form = kind.as_deref() == Some("text_input") && ["input", "blur", "commit"].contains(&event);
                let pick_form = kind.as_deref() == Some("dropdown") && event == "commit";
                if (text_form || pick_form) && at.is_some() {
                    refuse(&mut out, format!("`at` on a {event} step of a text or pick widget is not delivered by this runner"));
                    break;
                }
                if text_form || pick_form {
                    let (path, node, scope) = match resolve(panel, widget, &row) {
                        Ok(t) => t,
                        Err(why) => { refuse(&mut out, why); break; }
                    };
                    let mut ev = json!({"widget": widget,
                        "shift": flag(st, "shift"), "alt": flag(st, "alt"), "ctrl": flag(st, "ctrl")});
                    if let Some(p) = path {
                        ev["path"] = json!(p);
                    }
                    if pick_form {
                        field = None;
                        ev["event"] = json!(if flag(st, "alt") { "alt_toggle" } else { "toggle" });
                        ev["value"] = st.get("value").cloned().unwrap_or(Value::Null);
                    } else {
                        // The field's text: what an `input` typed into this
                        // same field, else what its `bind.value` shows.
                        let mut text = node.get("bind").and_then(|b| b.get("value")).and_then(Value::as_str)
                            .map(|x| crate::interpreter::expr::eval(x, &scope).to_string_coerce())
                            .unwrap_or_default();
                        if let Some((fp, fw, fr, ft)) = &field {
                            if fp == panel && fw == widget && *fr == row {
                                text = ft.clone();
                            }
                        }
                        if let Some(v) = st.get("value").and_then(Value::as_str) {
                            text = v.to_string();
                        }
                        let name = match event {
                            // section 6: sets the text, fires the declared
                            // `input` once, and the field keeps key focus.
                            "input" => {
                                field = Some((panel.to_string(), widget.to_string(), row.clone(), text.clone()));
                                "input"
                            }
                            // section 6: a commit types the value, then
                            // presses Enter.
                            "commit" => {
                                field = None;
                                ev["key"] = json!("Enter");
                                "keydown"
                            }
                            _ => {
                                field = None;
                                "blur"
                            }
                        };
                        ev["event"] = json!(name);
                        ev["value"] = json!(text);
                        if !declares(&node, name) {
                            // A field that declares no such event fires nothing.
                            out.push(json!({"step": i, "unchanged": true}));
                            focus = Some(panel.to_string());
                            continue;
                        }
                    }
                    let ev = ev.to_string();
                    let reply = take(unsafe { jas_panel_behavior(e, panel.as_ptr(), panel.len(), ev.as_ptr(), ev.len()) });
                    if !ran(&mut out, reply, last_error(e)) {
                        break;
                    }
                    focus = Some(panel.to_string());
                    continue;
                }
                field = None;
                // Form 6: a double click delivers ONE click, then the double.
                let events: &[&str] = if event == "double_click" { &["click", "double_click"] } else { &[event] };
                let mut ok = true;
                for &name in events {
                    let mut ev = json!({"widget": widget, "event": name,
                        "shift": flag(st, "shift"), "alt": flag(st, "alt"), "ctrl": flag(st, "ctrl")});
                    if let Some(v) = st.get("value") {
                        ev["value"] = v.clone();
                    }
                    let addr = row.as_deref().map(RowAddr::Row).or(at.as_deref().map(RowAddr::At));
                    if let Some(addr) = addr {
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
                        match row_plan_path(spec.get("content").unwrap_or(&Value::Null), widget, name, addr, &scope) {
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
                // F6 (row 145): a field the step left shown on its row holds
                // key focus (`shown_field_candidates`).
                if row.is_some() {
                    let ids = crate::interpreter::workspace::Workspace::load()
                        .and_then(|ws| ws.panel(panel).map(|p| shown_field_candidates(&p["content"])))
                        .unwrap_or_default();
                    let mut shown: Vec<(String, String)> = vec![];
                    for id in ids {
                        // A field no foreach repeats is not on a row; that miss is not an error.
                        let Ok((_, node, sc)) = resolve(panel, &id, &row) else { continue };
                        let bind = node.get("bind");
                        let Some(vis) = bind.and_then(|b| b.get("visible")).and_then(Value::as_str) else { continue };
                        if !crate::interpreter::expr::eval(vis, &sc).to_bool() {
                            continue;
                        }
                        let text = bind.and_then(|b| b.get("value")).and_then(Value::as_str)
                            .map(|x| crate::interpreter::expr::eval(x, &sc).to_string_coerce())
                            .unwrap_or_default();
                        shown.push((id, text));
                    }
                    if shown.len() > 1 {
                        let names: Vec<&str> = shown.iter().map(|(w, _)| w.as_str()).collect();
                        refuse(&mut out, format!("row {:?} shows {} fields ({}); which holds key focus is not stated",
                            row.as_deref().unwrap_or(&[]), shown.len(), names.join(", ")));
                        break;
                    }
                    field = shown.pop().map(|(w, t)| (panel.to_string(), w, row.clone(), t));
                }
            } else if let Some(want) = st.get("context_menu").and_then(Value::as_str) {
                // Design section 8 form 2: the item whose action, RESOLVED at
                // open, is the step's and whose declared params equal every
                // param the step names. It runs through the engine's own door
                // (`jas_panel_behavior`, event `context_menu`), which refuses a
                // disabled item and evaluates the params as a behaviour's.
                let Some((pid, path, items)) = opened else {
                    refuse(&mut out, "a context_menu step must directly follow a row secondary_press".to_string());
                    break;
                };
                let named = st.get("params").and_then(Value::as_object).cloned().unwrap_or_default();
                // An exported item carries its action resolved at open, its
                // declared params, and its index in the DECLARED list, which is
                // the value the pick sends (separators carry no action).
                let hits: Vec<u64> = items.iter().filter(|item| {
                    item.get("action").and_then(Value::as_str) == Some(want)
                        && named.iter().all(|(k, v)| item.get("params").and_then(|p| p.get(k))
                            .is_some_and(|d| plain(d) == plain(v)))
                }).filter_map(|item| item.get("index").and_then(Value::as_u64)).collect();
                let &[at] = hits.as_slice() else {
                    refuse(&mut out, format!("`{want}` is {} item(s) of the row's context_menu, not one", hits.len()));
                    break;
                };
                // What the export DREW for this item must agree with what the
                // pick DOES: an item drawn enabled runs, one drawn disabled is
                // refused. A disagreement is refused in words that never name
                // the pick's own class, so it cannot pass for the expected one.
                let drawn_enabled = items.iter().find(|it| it.get("index").and_then(Value::as_u64) == Some(at))
                    .and_then(|it| it.get("enabled")).and_then(Value::as_bool).unwrap_or(false);
                let ev = json!({"widget": "context_menu", "path": path, "event": "context_menu", "value": at}).to_string();
                let reply = take(unsafe { jas_panel_behavior(e, pid.as_ptr(), pid.len(), ev.as_ptr(), ev.len()) });
                if reply.is_some() != drawn_enabled {
                    refuse(&mut out, format!("the row menu export and the pick disagree on item {at}: drawn enabled={drawn_enabled}, ran={}", reply.is_some()));
                    break;
                }
                if !ran(&mut out, reply, last_error(e)) {
                    break;
                }
                focus = Some(pid);
            } else if let Some(want) = st.get("dialog").and_then(Value::as_str) {
                // A DIALOG step (row 275): a widget of the OPEN dialog, by id,
                // through the door a shell's dialog view calls. The step names
                // the dialog it expects, so a route that opened another one is
                // refused, never driven.
                focus = None;
                field = None;
                let open = engine.script_dialog_id();
                let Some(open) = open else {
                    refuse(&mut out, format!("the step names dialog `{want}`, and no dialog is open"));
                    break;
                };
                if open.as_str() != want {
                    refuse(&mut out, format!("the step names dialog `{want}`; the open dialog is `{open}`"));
                    break;
                }
                let Some(widget) = st.get("widget").and_then(Value::as_str) else {
                    refuse(&mut out, "a dialog step names no widget".to_string());
                    break;
                };
                let declared = crate::interpreter::workspace::Workspace::load()
                    .and_then(|ws| ws.dialog(&open).and_then(|d| find_widget(&d["content"], widget)).cloned());
                if declared.is_none() {
                    refuse(&mut out, format!("widget `{widget}` is not in dialog `{open}`"));
                    break;
                }
                let mut ev = json!({"widget": widget, "event": st.get("event").and_then(Value::as_str).unwrap_or("click")});
                if let Some(v) = st.get("value") {
                    ev["value"] = v.clone();
                }
                let ev = ev.to_string();
                let reply = take(unsafe { crate::ffi::jas_dialog_event(e, ev.as_ptr(), ev.len()) });
                if !ran(&mut out, reply, last_error(e)) {
                    break;
                }
            } else {
                let form = ["context_menu"].into_iter().find(|k| st.get(*k).is_some());
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

/// Row 119 (STATUS-jas; the recommendation of row 76, bus 11-12 15:38): a key
/// no focused panel binds FALLS THROUGH to the menubar's shortcut, so S1's
/// `layers.eye_undo` (Ctrl+Z with the Layers tree focused after an eye click)
/// undoes the click, as the web app does through its panel door (measured
/// 11-13 on main 4abab25a). RED by design until the key law in
/// `jas_dispatch_action` changes, and NOT merged before the Mac reading lands.
/// Its expectation is a relation inside one run: the last read equals the
/// read taken before the click. Swift's twin is
/// `formsAnUnboundPanelKeyFallsThroughToTheMenubarShortcut`.
#[test]
fn an_unbound_panel_key_falls_through_to_the_menubar_shortcut() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let out = replay_forms(&layers_script(serde_json::json!([
        {"read": "document"}, {"panel": LAYERS, "widget": "lp_eye", "row": [1, 0], "event": "click"},
        {"read": "document"}, {"key": "Z", "ctrl": true}, {"read": "document"},
    ]))).unwrap();
    assert_eq!(refusal(&out), None, "Ctrl+Z on the focused tree was refused: {out:?}");
    let docs = doc_reads(&out);
    assert_eq!(docs.len(), 3, "three document reads: {out:?}");
    assert_ne!(docs[1], docs[0], "the eye click changed nothing, so this arm cannot tell an undo from a no-op");
    assert_eq!(docs[2], docs[0], "Ctrl+Z did not undo the eye click");
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
        (serde_json::json!({"panel": LAYERS, "widget": "lp_name", "at": [0], "event": "click"}), "address it by `row`"),
        (serde_json::json!({"context_menu": "x", "params": {}}), "must directly follow a row secondary_press"),
    ] {
        let out = replay_forms(&layers_script(serde_json::json!([step.clone(), read_layers()]))).unwrap();
        let why = refusal(&out).unwrap_or_default();
        assert!(why.contains(needle), "{step}: wanted a refusal naming `{needle}`, got {out:?}");
        assert!(panel_reads(&out).is_empty(), "a refusal ends the replay: {out:?}");
    }
}

// The S2 text and dropdown forms (TESTING.md section 6, row 136): the twins
// of Swift's `formsAnInputStep…`, `formsADropdownCommit…`, `formsARowCommit…`,
// `formsAnInputOnAField…` and `formsARowDrag…`.

/// The name at `path` in the LAST document read of a replay.
fn name_at(out: &[Value], path: &[usize]) -> Value {
    doc_reads(out).last().map(|d| doc_element(d, path)["name"].clone()).unwrap_or(Value::Null)
}

/// Row [0, 1]'s rename field, open: a click, then the double-click that runs
/// `rename_element` (S2's own preamble, SI-4).
fn open_rename_01() -> Vec<Value> {
    vec![
        click_row(serde_json::json!([0, 1]), &[]),
        serde_json::json!({"panel": LAYERS, "widget": "lp_name", "row": [0, 1], "event": "double_click"}),
    ]
}

fn edit_01(event: &str, value: Option<&str>) -> Value {
    let mut st = serde_json::json!({"panel": LAYERS, "widget": "lp_name_edit", "row": [0, 1], "event": event});
    if let Some(v) = value {
        st["value"] = Value::String(v.to_string());
    }
    st
}

fn with(mut steps: Vec<Value>, more: Vec<Value>) -> Value {
    steps.extend(more);
    Value::Array(steps)
}

#[test]
fn an_input_step_fires_the_fields_declared_input_with_its_value() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let out = replay_forms(&layers_script(serde_json::json!([
        {"panel": LAYERS, "widget": "lp_search_input", "event": "input", "value": "line"}, read_layers(),
    ]))).unwrap();
    assert_eq!(refusal(&out), None, "{out:?}");
    assert_eq!(panel_reads(&out)[0]["search_query"], serde_json::json!("line"), "{out:?}");
}

#[test]
fn a_dropdown_commit_picks_the_item_by_value() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let pick = |v: &str, alt: bool| serde_json::json!(
        {"panel": LAYERS, "widget": "lp_filter_button", "event": "commit", "value": v, "alt": alt});
    let filter = |steps: Vec<Value>| -> Value {
        let out = replay_forms(&layers_script(with(steps, vec![read_layers()]))).unwrap();
        assert_eq!(refusal(&out), None, "{out:?}");
        let mut f: Vec<String> = panel_reads(&out).last().and_then(|r| r["type_filter"].as_array().cloned())
            .unwrap_or_default().iter().filter_map(|v| v.as_str().map(str::to_string)).collect();
        f.sort();
        serde_json::json!(f)
    };
    assert_eq!(filter(vec![pick("circle", false)]), serde_json::json!(["circle"]));
    assert_eq!(filter(vec![pick("circle", false), pick("circle", false)]), serde_json::json!([]), "a second toggle unticks");
    assert_eq!(filter(vec![pick("circle", false), pick("__all__", false)]), serde_json::json!([]), "All restores the default");
    assert_eq!(filter(vec![pick("circle", false), pick("rectangle", false)]), serde_json::json!(["circle", "rectangle"]));
    assert_eq!(filter(vec![pick("circle", false), pick("rectangle", true)]), serde_json::json!(["rectangle"]), "Alt solos");
    let bad = replay_forms(&layers_script(serde_json::json!([pick("no_such_type", false), read_layers()]))).unwrap();
    assert!(refusal(&bad).is_some(), "an item no menu holds is refused: {bad:?}");
}

#[test]
fn a_row_commit_types_the_value_then_presses_enter() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let out = replay_forms(&layers_script(with(open_rename_01(),
        vec![edit_01("commit", Some("Ring")), read_layers(), serde_json::json!({"read": "document"})]))).unwrap();
    assert_eq!(refusal(&out), None, "{out:?}");
    assert_eq!(name_at(&out, &[0, 1]), serde_json::json!("Ring"), "{out:?}");
    assert_eq!(panel_reads(&out)[0]["renaming_element"], Value::Null, "the field closes: {out:?}");
}

#[test]
fn an_input_on_a_field_with_no_input_sets_its_text_and_the_next_key_goes_to_it() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let esc = replay_forms(&layers_script(with(open_rename_01(), vec![
        edit_01("input", Some("Ring")), serde_json::json!({"key": "Escape"}), read_layers(),
        serde_json::json!({"read": "document"}),
    ]))).unwrap();
    assert_eq!(refusal(&esc), None, "{esc:?}");
    assert!(esc.iter().any(|r| r["step"] == 2 && r["unchanged"] == true), "the input fires nothing: {esc:?}");
    assert_ne!(name_at(&esc, &[0, 1]), serde_json::json!("Ring"), "Escape: {esc:?}");
    assert_eq!(panel_reads(&esc)[0]["renaming_element"], Value::Null, "Escape closes the field: {esc:?}");

    let blur = replay_forms(&layers_script(with(open_rename_01(), vec![
        edit_01("input", Some("Ring")), edit_01("blur", None), serde_json::json!({"read": "document"}),
    ]))).unwrap();
    assert_eq!(refusal(&blur), None, "{blur:?}");
    assert_eq!(name_at(&blur, &[0, 1]), serde_json::json!("Ring"), "a blur confirms the typed text: {blur:?}");

    // The control: the same blur with no typing confirms the name unchanged.
    let plain = replay_forms(&layers_script(with(open_rename_01(), vec![
        edit_01("blur", None), serde_json::json!({"read": "document"}),
    ]))).unwrap();
    assert_eq!(refusal(&plain), None, "{plain:?}");
    assert_ne!(name_at(&plain, &[0, 1]), serde_json::json!("Ring"), "{plain:?}");
}

/// F6 (row 145): the twin of Swift's `formsARowStepThatShowsAFieldGivesItKeyFocus`.
/// A row step that leaves a field shown on its row (the double-click that opens
/// a rename shows `lp_name_edit`) gives that FIELD key focus. Enter tells the
/// routes apart: the field confirms and closes, the tree's Enter would run
/// `rename_element` again and leave it open. A key the field declares nothing
/// for is refused, never handed to the tree.
#[test]
fn a_row_step_that_shows_a_field_gives_it_key_focus() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let key = |k: &str| serde_json::json!({"key": k});
    let enter = replay_forms(&layers_script(with(open_rename_01(), vec![
        key("Enter"), read_layers(), serde_json::json!({"read": "document"}),
    ]))).unwrap();
    assert_eq!(refusal(&enter), None, "{enter:?}");
    assert_eq!(panel_reads(&enter)[0]["renaming_element"], Value::Null, "the field's Enter confirms and closes: {enter:?}");

    let esc = replay_forms(&layers_script(with(open_rename_01(), vec![read_layers(), key("Escape"), read_layers()]))).unwrap();
    assert_eq!(refusal(&esc), None, "{esc:?}");
    assert_eq!(panel_reads(&esc)[0]["renaming_element"], serde_json::json!([0, 1]), "a read keeps the field open: {esc:?}");
    assert_eq!(panel_reads(&esc)[1]["renaming_element"], Value::Null, "Escape cancels: {esc:?}");

    let arrow = replay_forms(&layers_script(with(open_rename_01(), vec![key("ArrowDown"), read_layers()]))).unwrap();
    assert_eq!(refusal(&arrow).as_deref(), Some("UnboundFieldKey lp_name_edit: ArrowDown"), "{arrow:?}");

    // The control: a row step that shows no field (a click selects, a
    // container's double-click isolates) leaves the key with the tree.
    let tree = replay_forms(&layers_script(serde_json::json!([
        click_row(serde_json::json!([0, 1]), &[]), key("Enter"), read_layers(),
    ]))).unwrap();
    assert_eq!(refusal(&tree), None, "{tree:?}");
    assert_eq!(panel_reads(&tree)[0]["renaming_element"], serde_json::json!([0, 1]), "the tree's Enter opens a rename: {tree:?}");
    let iso = replay_forms(&layers_script(serde_json::json!([
        click_row(serde_json::json!([0]), &[]),
        {"panel": LAYERS, "widget": "lp_preview", "row": [0], "event": "double_click"},
        key("ArrowDown"), read_layers(),
    ]))).unwrap();
    assert_eq!(refusal(&iso), None, "no field is shown, so the tree takes the arrow: {iso:?}");
}

/// F1c (row 145): the twin of Swift's `formsAnIntoDragHoveringACollapsedContainerExpandsIt`.
/// An `into` drag that hovers a COLLAPSED container for 500 ms or more removes
/// it from `collapsed_paths` before `drag_end`. Boundary both ways, the zone,
/// and an unrelated collapsed row that must stay.
#[test]
fn an_into_drag_hovering_a_collapsed_container_expands_it() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let collapsed = |zone: &str, hover: u64, seed: Value| -> Value {
        let mut d = drag(serde_json::json!([0, 0]), serde_json::json!([0, 2]), zone);
        d["hover_ms"] = serde_json::json!(hover);
        let mut s = layers_script(serde_json::json!([d, read_layers()]));
        s["app_state"] = serde_json::json!({"panels": {LAYERS: {"collapsed_paths": seed}}});
        let out = replay_forms(&s).unwrap();
        assert_eq!(refusal(&out), None, "{zone} {hover}: {out:?}");
        panel_reads(&out).last().map(|r| r["collapsed_paths"].clone()).unwrap_or(Value::Null)
    };
    let two = || serde_json::json!([[0, 2], [1]]);
    assert_eq!(collapsed("into", 600, two()), serde_json::json!([[1]]), "600 ms expands the target only");
    assert_eq!(collapsed("into", 500, two()), serde_json::json!([[1]]), "500 ms is enough (the rule is 'for 500ms')");
    assert_eq!(collapsed("into", 499, two()), two(), "499 ms is not");
    assert_eq!(collapsed("after", 600, two()), two(), "only an `into` hover expands");
    assert_eq!(collapsed("into", 600, serde_json::json!([[1]])), serde_json::json!([[1]]),
        "a target already expanded stays so, nothing is added");
}

fn drag(from: Value, to: Value, zone: &str) -> Value {
    serde_json::json!({"panel": LAYERS, "widget": "lp_name", "row": from, "event": "drag",
                       "to": {"row": to, "zone": zone}, "hover_ms": 0})
}

/// F1 (row 137, TESTING.md section 6): the twin of Swift's
/// `formsARowDragDeliversTheRowsDeclaredDragEvents`. `drag_start` selects the
/// pressed row; `drag_move` and `drag_end` declare no action on this build, so
/// each reads `unchanged` and nothing moves.
#[test]
fn a_row_drag_delivers_the_rows_declared_drag_events() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let out = replay_forms(&layers_script(serde_json::json!([
        {"read": "document"}, drag(serde_json::json!([0, 0]), serde_json::json!([0, 2]), "into"), read_layers(),
        {"read": "document"},
    ]))).unwrap();
    assert_eq!(refusal(&out), None, "{out:?}");
    assert_eq!(out.iter().filter(|r| r["step"] == 1 && r["unchanged"] == true).count(), 2,
        "drag_move and drag_end each read unchanged: {out:?}");
    assert_eq!(panel_reads(&out)[0]["layers_panel_selection"], serde_json::json!([[0, 0]]), "{out:?}");
    let docs = doc_reads(&out);
    assert_eq!(docs.len(), 2);
    assert_eq!(doc_element(&docs[0], &[0, 0])["type"], doc_element(&docs[1], &[0, 0])["type"], "nothing moved: {out:?}");
}

/// The twin of Swift's `formsARowDragTheRunnerCannotDeliverIsRefusedByName`.
#[test]
fn a_row_drag_the_runner_cannot_deliver_is_refused_by_name() {
    let _counters = crate::ffi_instr::test_lock::lock();
    for (step, needle) in [
        (drag(serde_json::json!([0, 0]), serde_json::json!([0, 2]), "sideways"), "zone"),
        (serde_json::json!({"panel": LAYERS, "widget": "lp_name", "row": [0, 0], "event": "drag"}), "`to`"),
        (drag(serde_json::json!([0, 0]), serde_json::json!([9]), "into"), "0 row(s)"),
    ] {
        let out = replay_forms(&layers_script(serde_json::json!([step.clone(), read_layers()]))).unwrap();
        assert!(refusal(&out).unwrap_or_default().contains(needle), "{step}: wanted `{needle}`, got {out:?}");
    }
    let acting = serde_json::json!({"behavior": [{"event": "drag_end", "action": "move_elements"}]});
    let quiet = serde_json::json!({"behavior": [{"event": "drag_end", "description": "no action"}]});
    assert!(declares_an_act(&acting, "drag_end"));
    assert!(!declares_an_act(&quiet, "drag_end"));
    assert!(declares_an_act(&serde_json::json!({"behavior": [{"event": "drag_move", "effects": []}]}), "drag_move"),
        "effects count as an act");
}

// The S3 panel-menu forms (design section 8 forms 3 and 4, row 139): the
// twins of Swift's `formsReadPanelMenu…`, `formsAPanelMenuStepRuns…` and
// `formsAPanelMenuStepThatCannot…`.

/// The Layers panel menu's item actions in declared order, from the bundle.
fn layers_menu_actions() -> Vec<Value> {
    crate::interpreter::workspace::Workspace::load().unwrap().panel_menu(LAYERS).iter()
        .filter(|n| n.get("label").is_some()).map(|n| n.get("action").cloned().unwrap_or(Value::Null)).collect()
}

fn panel_menu_reads(out: &[Value]) -> Vec<Vec<Value>> {
    out.iter().filter(|r| r["read"] == "panel_menu").map(|r| r["value"].as_array().cloned().unwrap_or_default()).collect()
}

#[test]
fn read_panel_menu_reads_the_items_in_order_with_their_state() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let want = layers_menu_actions();
    assert!(want.len() >= 8 && want.contains(&serde_json::json!("new_group")), "{want:?}");
    let out = replay_forms(&layers_script(serde_json::json!([
        {"read": "panel_menu", "panel": LAYERS}, click_row(serde_json::json!([0, 1]), &[]),
        {"read": "panel_menu", "panel": LAYERS},
    ]))).unwrap();
    assert_eq!(refusal(&out), None, "{out:?}");
    let reads = panel_menu_reads(&out);
    assert_eq!(reads.len(), 2, "{out:?}");
    assert_eq!(reads[0].iter().map(|r| r["action"].clone()).collect::<Vec<_>>(), want, "declared order: {reads:?}");
    for r in &reads[0] {
        let mut keys: Vec<&String> = r.as_object().unwrap().keys().collect();
        keys.sort();
        assert_eq!(keys, ["action", "checked", "enabled", "params"], "{r}");
    }
    let enabled = |rs: &[Value], a: &str| rs.iter().find(|r| r["action"] == a).map(|r| r["enabled"].clone());
    assert_eq!(enabled(&reads[0], "new_group"), Some(serde_json::json!(false)), "nothing panel-selected: {reads:?}");
    assert_eq!(enabled(&reads[1], "new_group"), Some(serde_json::json!(true)), "one row panel-selected: {reads:?}");
}

#[test]
fn a_panel_menu_step_runs_the_matched_item() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let out = replay_forms(&layers_script(serde_json::json!([
        {"read": "document"}, {"panel_menu": LAYERS, "action": "new_layer"}, {"read": "document"},
    ]))).unwrap();
    assert_eq!(refusal(&out), None, "{out:?}");
    let n: Vec<usize> = doc_reads(&out).iter().map(|d| d["layers"].as_array().map_or(0, Vec::len)).collect();
    assert!(n.len() == 2 && n[1] == n[0] + 1, "one more layer: {n:?}");
}

#[test]
fn a_panel_menu_step_that_cannot_run_is_refused_by_name() {
    let _counters = crate::ffi_instr::test_lock::lock();
    for (step, needle) in [
        (serde_json::json!({"panel_menu": LAYERS, "action": "no_such_action"}), "0 item(s)"),
        (serde_json::json!({"panel_menu": LAYERS, "action": "new_group"}), "disabled"),
        (serde_json::json!({"panel_menu": LAYERS, "action": "close_panel", "params": {"panel": "nope"}}), "0 item(s)"),
        (serde_json::json!({"panel_menu": "no_such_panel", "action": "new_layer"}), "UnknownPanel"),
    ] {
        let out = replay_forms(&layers_script(serde_json::json!([step.clone(), {"read": "document"}]))).unwrap();
        assert!(refusal(&out).unwrap_or_default().contains(needle), "{step}: wanted `{needle}`, got {out:?}");
        assert!(doc_reads(&out).is_empty(), "a refusal ends the replay: {out:?}");
    }
}

// G3, the row context menu (design section 8 forms 1 and 2, row 139).

fn secondary_press(row: Value) -> Value {
    serde_json::json!({"panel": LAYERS, "widget": "lp_name", "row": row, "event": "secondary_press"})
}

/// A row `secondary_press` opens that row's `context_menu:`, and the step
/// after it picks an item by action: Duplicate duplicates the panel-selected
/// row; a TEMPLATE action (Enter/Exit Isolation Mode) is matched as resolved
/// at open, in the row's scope, and runs with the row as `node`.
#[test]
fn a_row_secondary_press_opens_its_context_menu_and_the_picked_item_runs() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let out = replay_forms(&layers_script(serde_json::json!([
        {"read": "document"}, click_row(serde_json::json!([0, 1]), &[]), secondary_press(serde_json::json!([0, 1])),
        {"context_menu": "duplicate_layer_selection"}, {"read": "document"},
    ]))).unwrap();
    assert_eq!(refusal(&out), None, "{out:?}");
    let n: Vec<usize> = doc_reads(&out).iter().map(|d| d["layers"][0]["children"].as_array().map_or(0, Vec::len)).collect();
    assert!(n.len() == 2 && n[1] == n[0] + 1, "the row was duplicated: {n:?} {out:?}");

    let iso = replay_forms(&layers_script(serde_json::json!([
        secondary_press(serde_json::json!([0, 2])), {"context_menu": "enter_isolation_mode"}, read_layers(),
    ]))).unwrap();
    assert_eq!(refusal(&iso), None, "{iso:?}");
    assert_eq!(panel_reads(&iso)[0]["isolation_stack"], serde_json::json!([[0, 2]]), "the row is node: {iso:?}");
}

/// Row 257 D3: a row `secondary_press` first runs the row's own
/// `secondary_press` behaviour, as every shell does before it opens the menu,
/// so a right-click on an UNSELECTED row makes it the sole selection and the
/// menu acts on it. Before D3's runner change this replay opened the menu with
/// the old selection, and Duplicate copied the clicked row instead.
#[test]
fn a_secondary_press_on_an_unselected_row_makes_the_menu_act_on_it() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let out = replay_forms(&layers_script(serde_json::json!([
        {"read": "document"}, click_row(serde_json::json!([0, 1]), &[]), secondary_press(serde_json::json!([0, 2])),
        {"context_menu": "duplicate_layer_selection"}, {"read": "document"},
    ]))).unwrap();
    assert_eq!(refusal(&out), None, "{out:?}");
    let docs = doc_reads(&out);
    let strip = |v: &Value| { let mut v = v.clone(); if let Some(o) = v.as_object_mut() { o.remove("id"); } v };
    let before: Vec<Value> = docs[0]["layers"][0]["children"].as_array().unwrap().iter().map(strip).collect();
    let after: Vec<Value> = docs[1]["layers"][0]["children"].as_array().unwrap().iter().map(strip).collect();
    assert_ne!(before[1], before[2], "the fixture's two rows must differ for this arm to see which was copied");
    assert_eq!(after.len(), before.len() + 1, "one element was duplicated");
    assert_eq!(after.iter().filter(|c| **c == before[2]).count(), 2, "the right-clicked row [0,2] was duplicated");
    assert_eq!(after.iter().filter(|c| **c == before[1]).count(), 1, "the previously selected row [0,1] was not");
}

/// A context-menu step the menu cannot take is refused by name: with no
/// secondary press directly before it, an item whose `enabled_when` fails
/// (Options for Layer on a non-layer row), and a param that matches no item.
#[test]
fn a_context_menu_step_the_menu_cannot_take_is_refused_by_name() {
    let _counters = crate::ffi_instr::test_lock::lock();
    for (steps, needle) in [
        (serde_json::json!([{"context_menu": "duplicate_layer_selection"}]), "directly follow"),
        (serde_json::json!([secondary_press(serde_json::json!([0, 1])), read_layers(),
                            {"context_menu": "duplicate_layer_selection"}]), "directly follow"),
        (serde_json::json!([secondary_press(serde_json::json!([0, 1])),
                            {"context_menu": "open_layer_options", "params": {"mode": "edit"}}]), "Disabled"),
        (serde_json::json!([secondary_press(serde_json::json!([1])),
                            {"context_menu": "open_layer_options", "params": {"mode": "nope"}}]), "0 item(s)"),
        (serde_json::json!([secondary_press(serde_json::json!([1])), {"context_menu": "no_such_action"}]), "0 item(s)"),
    ] {
        let mut st = steps.as_array().unwrap().clone();
        st.push(serde_json::json!({"read": "document"}));
        let out = replay_forms(&layers_script(Value::Array(st))).unwrap();
        assert!(refusal(&out).unwrap_or_default().contains(needle), "{steps}: wanted `{needle}`, got {out:?}");
        assert!(doc_reads(&out).is_empty(), "a refusal ends the replay: {out:?}");
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

// ── The dialog step (row 275, docs/TESTING.md section 6) ─────────────────────

const ARTBOARDS: &str = "artboards_panel_content";

/// Artboard Options opened by the person's route: the Artboards panel menu's
/// "Artboard Options..." on the panel-selected artboard (seeded, the one form a
/// level-1 runner has for a row selection), then `mid` inside the open dialog,
/// then its OK. Reads the dialog before and after and the document at the end.
fn artboard_options_script(mid: Vec<Value>) -> Value {
    use serde_json::json;
    let mut steps = vec![
        json!({"read": "document"}),
        json!({"panel_menu": ARTBOARDS, "action": "open_artboard_options"}),
        json!({"read": "dialog"}),
    ];
    steps.extend(mid);
    steps.extend([
        json!({"dialog": "artboard_options", "widget": "ao_ok", "event": "click"}),
        json!({"read": "dialog"}),
        json!({"read": "document"}),
    ]);
    json!({"item": "forms.dialog", "setup_svg": "paragraph_justified.svg", "tool": "selection",
           "app_state": {"panels": {ARTBOARDS: {"artboards_panel_selection": ["zs8ap4x3"]}}},
           "steps": steps})
}

/// Row 281: a script on a two-artboard document (the panel menu's New Artboard
/// mints the second), ending in a read of the Artboards panel's state.
fn artboards_at_script(steps: Vec<Value>) -> Value {
    use serde_json::json;
    let mut all = vec![json!({"panel_menu": ARTBOARDS, "action": "new_artboard"}), json!({"read": "document"})];
    all.extend(steps);
    all.push(json!({"read": "panel", "panel": ARTBOARDS}));
    json!({"item": "forms.at", "setup_svg": "paragraph_justified.svg", "tool": "selection", "steps": all})
}

/// The artboard ids at the first document read, in order.
fn artboard_ids(out: &[Value]) -> Vec<Value> {
    out.iter().find(|r| r["read"] == "document").and_then(|r| r["value"]["artboards"].as_array())
        .map(|a| a.iter().map(|ab| ab["id"].clone()).collect()).unwrap_or_default()
}

/// Row 281 (TESTING.md section 6): `at` names a widget inside a generic
/// `foreach` repeat by each enclosing repeat's iteration index, outermost
/// first. A click on `ap_name` at [i] selects artboard i, so [0] and [1] must
/// select DIFFERENT artboards, each the one at that index in the document.
#[test]
fn an_at_step_clicks_the_widget_of_the_iteration_it_names() {
    let _counters = crate::ffi_instr::test_lock::lock();
    use serde_json::json;
    let mut picked = vec![];
    for i in [0u64, 1] {
        let out = replay_forms(&artboards_at_script(vec![
            json!({"panel": ARTBOARDS, "widget": "ap_name", "at": [i], "event": "click"})])).expect("replay");
        assert_eq!(refusal(&out), None, "at [{i}]: {out:?}");
        let ids = artboard_ids(&out);
        assert_eq!(ids.len(), 2, "the setup holds two artboards: {ids:?}");
        let sel = panel_reads(&out).last().cloned().unwrap_or(Value::Null)["artboards_panel_selection"].clone();
        assert_eq!(sel, json!([ids[i as usize].clone()]), "at [{i}] selects artboard {i}: {out:?}");
        picked.push(sel);
    }
    assert_ne!(picked[0], picked[1], "[0] and [1] must address different rows");
}

/// Row 281's refusals, each by name: an index past the rows, more indices than
/// enclosing repeats, `row` and `at` together, and `at` on a forms it is not
/// yet built for. (`at` on a tree widget is refused in the Layers arm above.)
#[test]
fn an_at_step_is_refused_by_name_where_it_cannot_address_one_widget() {
    let _counters = crate::ffi_instr::test_lock::lock();
    use serde_json::json;
    for (step, needle) in [
        (json!({"panel": ARTBOARDS, "widget": "ap_name", "at": [5], "event": "click"}), "past the 2 row(s)"),
        (json!({"panel": ARTBOARDS, "widget": "ap_name", "at": [0, 0], "event": "click"}), "names 2 index(es)"),
        (json!({"panel": ARTBOARDS, "widget": "ap_name", "at": [0], "row": [0], "event": "click"}), "not both"),
        (json!({"panel": ARTBOARDS, "widget": "ap_name", "at": [0], "event": "secondary_press"}), "`at` on a secondary_press"),
        (json!({"panel": ARTBOARDS, "widget": "ap_name", "at": "x", "event": "click"}), "is not a list of indices"),
    ] {
        let out = replay_forms(&artboards_at_script(vec![step.clone()])).expect("replay");
        let why = refusal(&out).unwrap_or_default();
        assert!(why.contains(needle), "{step}: refused {why:?}, want {needle:?}");
    }
}

fn dialog_reads(out: &[Value]) -> Vec<Value> {
    out.iter().filter(|r| r["read"] == "dialog").map(|r| r["value"].clone()).collect()
}

/// The fill of artboard `zs8ap4x3` at each document read, in order.
fn artboard_fills(out: &[Value]) -> Vec<Value> {
    out.iter().filter(|r| r["read"] == "document").map(|r| {
        r["value"]["artboards"].as_array().and_then(|a| a.iter().find(|ab| ab["id"] == "zs8ap4x3"))
            .map(|ab| ab["fill"].clone()).unwrap_or(Value::String("NO ARTBOARD zs8ap4x3".into()))
    }).collect()
}

/// The fill select's `white`, as the dialog's own bind reads it back: the
/// colour the select's bind maps to `'white'`, taken from the spec, not typed.
fn white_from_the_spec() -> Value {
    let ws = crate::interpreter::workspace::Workspace::load().expect("workspace");
    let spec = ws.dialog("artboard_options").expect("artboard_options");
    let node = find_widget(&spec["content"], "ao_fill_dropdown").expect("ao_fill_dropdown");
    let bind = node["bind"]["value"].as_str().expect("a value bind");
    let at = bind.find("then 'white'").expect("the bind names white");
    let colour = bind[..at].rsplit("== ").next().expect("a colour before it").trim();
    Value::String(colour.to_string())
}

#[test]
fn a_dialog_step_commits_the_fill_select_and_ok_applies_it() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let script = artboard_options_script(vec![serde_json::json!(
        {"dialog": "artboard_options", "widget": "ao_fill_dropdown", "event": "commit", "value": "white"})]);
    let out = replay_forms(&script).expect("replay");
    assert_eq!(refusal(&out), None, "{out:?}");
    assert_eq!(dialog_reads(&out), vec![Value::String("artboard_options".into()), Value::Null], "{out:?}");
    let fills = artboard_fills(&out);
    let white = white_from_the_spec();
    assert_eq!(white, Value::String("#ffffff".into()), "the bind's white literal moved: {white}");
    assert_ne!(fills[0], white, "the setup must not already be white, or this arm proves nothing: {fills:?}");
    assert_eq!(fills[1], white, "OK after the pick: {fills:?}");
}

/// The control: the same route and OK with no pick leaves the fill as it was,
/// so the arm above is the pick's, not the OK's.
#[test]
fn the_same_route_without_the_pick_leaves_the_fill() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let out = replay_forms(&artboard_options_script(vec![])).expect("replay");
    assert_eq!(refusal(&out), None, "{out:?}");
    assert_eq!(dialog_reads(&out), vec![Value::String("artboard_options".into()), Value::Null], "{out:?}");
    let fills = artboard_fills(&out);
    assert_eq!(fills[0], fills[1], "{fills:?}");
}

#[test]
fn a_dialog_step_naming_another_dialog_is_refused_by_name() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let script = artboard_options_script(vec![serde_json::json!(
        {"dialog": "rotate_options", "widget": "ao_fill_dropdown", "event": "commit", "value": "white"})]);
    let out = replay_forms(&script).expect("replay");
    let why = refusal(&out).expect("refused");
    assert!(why.contains("rotate_options") && why.contains("artboard_options"), "{why}");
}

#[test]
fn a_dialog_step_with_no_dialog_open_is_refused_by_name() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let script = serde_json::json!({"item": "forms.dialog", "setup_svg": "paragraph_justified.svg", "tool": "selection",
        "steps": [{"dialog": "artboard_options", "widget": "ao_ok", "event": "click"}, {"read": "document"}]});
    let out = replay_forms(&script).expect("replay");
    let why = refusal(&out).expect("refused");
    assert!(why.contains("no dialog is open"), "{why}");
}

#[test]
fn a_dialog_step_naming_a_widget_the_dialog_lacks_is_refused_by_name() {
    let _counters = crate::ffi_instr::test_lock::lock();
    let script = artboard_options_script(vec![serde_json::json!(
        {"dialog": "artboard_options", "widget": "no_such_widget", "event": "click"})]);
    let out = replay_forms(&script).expect("replay");
    let why = refusal(&out).expect("refused");
    assert!(why.contains("no_such_widget"), "{why}");
}

/// The A4 preset's size, from its own option label `A4 (W × H)` in the spec.
fn a4_from_the_spec() -> (f64, f64) {
    let ws = crate::interpreter::workspace::Workspace::load().expect("workspace");
    let spec = ws.dialog("artboard_options").expect("artboard_options");
    let node = find_widget(&spec["content"], "ao_preset").expect("ao_preset");
    let label = node["options"].as_array().unwrap().iter().find(|o| o["value"] == "a4").expect("an a4 option")["label"]
        .as_str().unwrap().to_string();
    let inner = &label[label.find('(').unwrap() + 1..label.find(')').unwrap()];
    let mut it = inner.split('×').map(|x| x.trim().parse::<f64>().expect("a number"));
    (it.next().unwrap(), it.next().unwrap())
}

/// Every PROPOSED script replays with no refusal, opens the dialog its steps
/// name and ends with none open. The size preset's script ends with the
/// artboard at its option label's size, and the fill's at the bind's white.
#[test]
fn every_proposed_dialog_script_replays_to_its_outcome() {
    let _counters = crate::ffi_instr::test_lock::lock();
    // The population, pinned in the corpus manifest's path form and checked
    // against the directory, so a script added there reds this arm.
    const PROPOSED: [&str; 2] = [
        "input_scripts_proposed/artboard_options.fill_white.json",
        "input_scripts_proposed/artboard_options.preset_a4.json",
    ];
    let dir = format!("{}/../test_fixtures/input_scripts_proposed", env!("CARGO_MANIFEST_DIR"));
    let mut on_disk: Vec<String> = std::fs::read_dir(&dir).expect("the proposed directory").filter_map(|d| {
        let n = d.ok()?.file_name().into_string().ok()?;
        (n.ends_with(".json") && !n.ends_with(".expected.json")).then(|| format!("input_scripts_proposed/{n}"))
    }).collect();
    on_disk.sort();
    assert_eq!(on_disk, PROPOSED, "the population moved");
    for n in PROPOSED {
        let script: Value = serde_json::from_str(&read(n)).unwrap();
        let out = replay_forms(&script).expect("replay");
        assert_eq!(refusal(&out), None, "{n}: {out:?}");
        assert_eq!(dialog_reads(&out), vec![Value::String("artboard_options".into()), Value::Null], "{n}: {out:?}");
        // The script carries its own expectations (docs/TESTING.md section 6),
        // so a driver with no test of its own can compare: one expected_dialog
        // entry per dialog read, in order, and the document read's golden.
        assert_eq!(script["expected_dialog"], Value::Array(dialog_reads(&out)), "{n}: expected_dialog");
        let golden = script["expected_json"].as_str().unwrap_or_else(|| panic!("{n}: no expected_json"));
        let want: Value = serde_json::from_str(&read(&format!("input_scripts_proposed/{golden}"))).unwrap();
        let doc = &out.iter().rev().find(|r| r["read"] == "document").expect("a document read")["value"];
        assert_eq!(doc, &want, "{n}: the document read is not {golden}:\n{doc}");
        let ab = doc["artboards"].as_array().unwrap().iter().find(|ab| ab["id"] == "zs8ap4x3").expect("zs8ap4x3");
        if n.contains("fill_white") {
            assert_eq!(ab["fill"], white_from_the_spec(), "{n}: {ab}");
        } else {
            let (w, h) = a4_from_the_spec();
            assert_eq!((ab["width"].as_f64(), ab["height"].as_f64()), (Some(w), Some(h)), "{n}: {ab}");
        }
    }
}
