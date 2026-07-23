//! The SHARED corpus replay functions — the single code path used by
//! BOTH the cross-language corpus runners (`cross_language_test.rs`
//! delegates here) and the recorder's record-stop fidelity check, so a
//! recording is verified through exactly the pipeline the corpus gate
//! replays it with. Also consumed by the `corpus_replay` bin, which
//! `scripts/ingest_recording.py` invokes to mint `*_expected.json`
//! goldens.
//!
//! No function here reads fixture FILES — setups are passed as SVG
//! content (the wasm fidelity path has no filesystem); the test-side
//! wrappers and the bin do the file I/O.

use crate::document::model::Model;
use crate::geometry::svg::svg_to_document;
use crate::geometry::test_json::document_to_test_json;
use serde_json::Value;

/// Build the YamlTool for `tool_id` from the embedded workspace bundle
/// (`Workspace::load()`), the same path the running app uses.
pub fn build_gesture_tool(tool_id: &str) -> crate::tools::yaml_tool::YamlTool {
    let ws = crate::interpreter::workspace::Workspace::load()
        .expect("embedded workspace must parse");
    let spec_json = ws
        .data()
        .get("tools")
        .and_then(|t| t.get(tool_id))
        .unwrap_or_else(|| panic!("workspace declares no tool '{}'", tool_id));
    crate::tools::yaml_tool::YamlTool::from_workspace_tool(spec_json)
        .unwrap_or_else(|| panic!("tool spec '{}' failed to parse", tool_id))
}

/// Run a gesture case against `setup_svg` CONTENT and return the
/// resulting Model. Loads the setup into a Model under the default
/// identity view, builds the tool from the workspace spec, activates
/// it, then dispatches each event through the CanvasTool seam — the
/// corpus gesture runner, verbatim (`cross_language_test.rs` calls
/// this after resolving the fixture's `setup_svg` file reference).
pub fn run_gesture_case(tc: &Value, setup_svg: &str) -> Model {
    use crate::tools::tool::CanvasTool;

    let doc = svg_to_document(setup_svg);
    let mut model = Model::new(doc, None);

    let tool_id = tc["tool"].as_str().unwrap();
    let mut tool = build_gesture_tool(tool_id);
    tool.activate(&mut model);

    // Optional `app_state` precondition: route the case's app-level
    // state (fill_color, blob_brush_*) through the SAME production
    // bridge the canvas uses (CanvasTool::sync_global_state in
    // workspace/app.rs), so the corpus exercises the real path. A
    // blob paint without this would commit fill=None (hollow).
    if let Some(app_state) = tc.get("app_state").and_then(|v| v.as_object()) {
        tool.sync_global_state(app_state);
    }

    for ev in tc["events"].as_array().unwrap() {
        let x = ev["x"].as_f64().unwrap();
        let y = ev["y"].as_f64().unwrap();
        // shift/alt default false; dragging defaults false.
        let shift = ev.get("shift").and_then(|v| v.as_bool()).unwrap_or(false);
        let alt = ev.get("alt").and_then(|v| v.as_bool()).unwrap_or(false);
        match ev["kind"].as_str().unwrap() {
            "press" => tool.on_press(&mut model, x, y, shift, alt),
            "move" => {
                let dragging = ev.get("dragging").and_then(|v| v.as_bool()).unwrap_or(false);
                tool.on_move(&mut model, x, y, shift, alt, dragging)
            }
            "release" => tool.on_release(&mut model, x, y, shift, alt),
            other => panic!("unknown gesture event kind: {other:?}"),
        }
    }
    model
}

/// Gesture case -> canonical document test-JSON (the golden format).
pub fn run_gesture_case_json(tc: &Value, setup_svg: &str) -> String {
    document_to_test_json(run_gesture_case(tc, setup_svg).document())
}

/// Run an action case against `setup_svg` CONTENT and return the
/// resulting `AppState`. Dispatches each `actions[i]` through the REAL
/// `dispatch_action` (the same generic dispatcher the UI calls) with
/// the deterministic test id source installed, mirroring the corpus
/// action runner in all four apps. `pub(crate)` because `AppState` is
/// crate-private; external callers use [`run_action_case_json`].
pub(crate) fn run_action_case(
    tc: &Value,
    setup_svg: &str,
) -> crate::workspace::app_state::AppState {
    use crate::workspace::app_state::{AppState, TabState};

    let doc = svg_to_document(setup_svg);
    let mut st = AppState::new();
    // AppState::new may return empty tabs; guarantee one active tab.
    if st.tabs.is_empty() {
        st.tabs.push(TabState::new());
        st.active_tab = 0;
    }
    // Seed the setup document through the front-door Model constructor
    // (identity view). The tab is rebuilt whole so replay never
    // inherits state from a previous document (the test runner's
    // `set_document_for_test` is `#[cfg(test)]`-only by design).
    st.tabs[st.active_tab] = TabState::with_model(Model::new(doc, None));

    // Install a deterministic id source so creation verbs (new_artboard,
    // new_symbol, …) mint a FIXED id ("01234567" for the first 8 draws),
    // byte-identical across all four apps. A simple per-char counter avoids
    // any cross-language LCG-arithmetic mismatch; cleared after the run.
    {
        use crate::document::artboard::set_test_id_rng;
        let mut counter: u32 = 0;
        set_test_id_rng(Some(Box::new(move || {
            let v = counter;
            counter = counter.wrapping_add(1);
            v
        })));
    }

    // Seed a canvas selection if the case declares one (a list of element
    // paths, e.g. [[0,0],[0,1]]). Selection-dependent verbs (compound shape,
    // align, boolean) consume document.selection, which `select_all` cannot
    // set through the shared dispatch (it is a native intercept). Mirrors
    // run_action_model in the other three apps.
    if let Some(sel) = tc.get("selection").and_then(|v| v.as_array()) {
        use crate::document::controller::Controller;
        use crate::document::document::ElementSelection;
        let entries: Vec<ElementSelection> = sel
            .iter()
            .filter_map(|p| p.as_array())
            .map(|p| {
                ElementSelection::all(
                    p.iter()
                        .filter_map(|n| n.as_u64().map(|u| u as usize))
                        .collect(),
                )
            })
            .collect();
        Controller::set_selection(&mut st.tabs[st.active_tab].model, entries);
    }

    for step in tc["actions"].as_array().unwrap() {
        let action = step["action"].as_str().unwrap();
        // Params are an object of resolved literals (mirrors the
        // production-route transform tests). Default to empty.
        let params: serde_json::Map<String, Value> = step
            .get("params")
            .and_then(|p| p.as_object())
            .cloned()
            .unwrap_or_default();
        // Object / Edit menu model-pure verbs are bespoke-native: their
        // actions.yaml entries are `log` stubs (the real behavior lives in
        // menu_bar.rs's dispatch — NOT in dispatch_action), so the generic
        // dispatcher would no-op them. Route each to the SAME headless
        // mutation path the menu invokes — the Controller methods (and, for
        // make_instance, the shared menu_bar::make_instance_on_model that
        // mints ids in the UI layer then calls create_reference +
        // move_selection) — so the action corpus gates their cross-app
        // document mutation. Mirrors the Python _MENU_NATIVE_HANDLERS
        // intercept in _dispatch_action. The verbs self-bracket (the
        // Controller mutation rides one with_txn, exactly as the menu
        // closure does); select_all writes the non-undoable selection.
        let handled = {
            use crate::document::controller::Controller;
            let model = &mut st.tabs[st.active_tab].model;
            match action {
                "select_all" => { Controller::select_all(model); true }
                "group" => { model.with_txn(|m| Controller::group_selection(m)); true }
                "ungroup" => { model.with_txn(|m| Controller::ungroup_selection(m)); true }
                "ungroup_all" => { model.with_txn(|m| Controller::ungroup_all(m)); true }
                "lock" => { model.with_txn(|m| Controller::lock_selection(m)); true }
                "hide_selection" => { model.with_txn(|m| Controller::hide_selection(m)); true }
                "make_instance" => {
                    crate::workspace::menu_bar::make_instance_on_model(model);
                    true
                }
                _ => false,
            }
        };
        if handled { continue; }
        crate::interpreter::renderer::dispatch_action(action, &params, &mut st);
    }
    crate::document::artboard::set_test_id_rng(None);
    st
}

/// Action case -> canonical document test-JSON (the golden format).
pub fn run_action_case_json(tc: &Value, setup_svg: &str) -> String {
    let st = run_action_case(tc, setup_svg);
    document_to_test_json(st.tabs[st.active_tab].model.document())
}

/// Run a journal (operations txns-form) case against `setup_svg`
/// CONTENT: each transaction commits explicitly through the production
/// begin/name/commit bracket with every op dispatched via the
/// production `op_apply` — the operations-corpus txns path. (The legacy
/// flat-`ops` form and `history` directives stay in the corpus driver;
/// recordings always emit the txns-form.)
pub fn run_journal_case(tc: &Value, setup_svg: &str) -> Model {
    let doc = svg_to_document(setup_svg);
    let mut model = Model::new(doc, None);
    if let Some(txns) = tc.get("txns").and_then(|v| v.as_array()) {
        for txn in txns {
            model.begin_txn();
            if let Some(name) = txn.get("name").and_then(|v| v.as_str()) {
                model.name_txn(name);
            }
            for op in txn["ops"].as_array().unwrap() {
                let _ = crate::document::op_apply::op_apply(&mut model, op);
            }
            model.commit_txn();
        }
    }
    model
}

/// Journal case -> canonical document test-JSON (the golden format).
pub fn run_journal_case_json(tc: &Value, setup_svg: &str) -> String {
    document_to_test_json(run_journal_case(tc, setup_svg).document())
}

/// Canonical JSON serializer for the key corpus: object keys are
/// emitted in sorted order, arrays in document order, scalars via
/// serde_json (correct string escaping / number formatting). This is
/// the shared cross-language canonicalization — every app must
/// produce byte-identical output for the same resolved commands.
#[allow(dead_code)] // consumed by the #[cfg(test)] corpus runner and the corpus_replay bin, not the app bin
pub fn canon_value(v: &Value) -> String {
    match v {
        Value::Object(m) => {
            let mut ks: Vec<&String> = m.keys().collect();
            ks.sort();
            let body: Vec<String> = ks
                .iter()
                .map(|k| {
                    format!("{}:{}", serde_json::to_string(k).unwrap(), canon_value(&m[*k]))
                })
                .collect();
            format!("{{{}}}", body.join(","))
        }
        Value::Array(a) => {
            let body: Vec<String> = a.iter().map(canon_value).collect();
            format!("[{}]", body.join(","))
        }
        other => serde_json::to_string(other).unwrap(),
    }
}

/// Wrap a resolved command (or its absence) as the canonical result
/// value: `null` when unmapped, else `{action, params}`.
#[allow(dead_code)] // reached only via run_key_group_json (test runner / corpus_replay bin)
fn key_result_value(cmd: &Option<crate::workspace::resolve_key::ResolvedCommand>) -> Value {
    match cmd {
        None => Value::Null,
        Some(c) => {
            let mut o = serde_json::Map::new();
            o.insert("action".into(), Value::String(c.action.clone()));
            o.insert("params".into(), Value::Object(c.params.clone()));
            Value::Object(o)
        }
    }
}

/// Resolve every chord in a key fixture group against the once-loaded
/// bundle `shortcuts` table and return the canonical result array —
/// the key-corpus runner and the golden format in one.
#[allow(dead_code)] // consumed by the #[cfg(test)] corpus runner and the corpus_replay bin, not the app bin
pub fn run_key_group_json(group: &Value) -> String {
    use crate::workspace::resolve_key::{resolve_key_in, KeyChord};
    let ws = crate::interpreter::workspace::Workspace::load()
        .expect("embedded workspace must parse");
    let shortcuts = ws
        .data()
        .get("shortcuts")
        .and_then(|s| s.as_array())
        .cloned()
        .unwrap_or_default();
    let mut arr: Vec<Value> = Vec::new();
    for case in group["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let ch = &case["chord"];
        let b = |k: &str| ch.get(k).and_then(|v| v.as_bool()).unwrap_or(false);
        let chord = KeyChord::new(
            ch["key"].as_str().unwrap(),
            b("ctrl"),
            b("shift"),
            b("alt"),
            b("meta"),
        );
        let cmd = resolve_key_in(&chord, &shortcuts);
        let mut o = serde_json::Map::new();
        o.insert("name".into(), Value::String(name.to_string()));
        o.insert("result".into(), key_result_value(&cmd));
        arr.push(Value::Object(o));
    }
    canon_value(&Value::Array(arr))
}
