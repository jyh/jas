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
    jas_pointer_event, jas_set_tool, KIND_MOVE, KIND_PRESS, KIND_RELEASE, MOD_ALT, MOD_DRAGGING,
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
        take(unsafe { jas_document_json(e) }).ok_or_else(|| format!("script {item}: no read-back"))
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
        match replay(&script).and_then(|got| set_aside_the_opens_artboard(&got, expected.trim())) {
            Ok(actual) if actual == expected.trim() => {}
            Ok(actual) => wrong.push(format!("{f}: the engine read back\n{actual}\nnot\n{}", expected.trim())),
            Err(why) => wrong.push(why),
        }
    }
    assert!(wrong.is_empty(), "{} of {} scripts:\n{}", wrong.len(), files.len(), wrong.join("\n\n"));
}
