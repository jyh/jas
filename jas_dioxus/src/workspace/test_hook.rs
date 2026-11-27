//! The web app's level-2 test hook (docs/TESTING.md section 6): the three
//! test-only commands the Mac app takes on its `--test-fifo`, plus its `tool`,
//! as `window.__jasTest`, so a headless browser can drive the input-script
//! corpus through the live web app (`scripts/web_l2_driver.py`).
//!
//!   open(svgText, name) -> bool    open the setup file as File > Open does,
//!                                  without the file dialog
//!   view(z?, x?, y?)    -> String  set zoom and pan when given, then report
//!                                  the view as `view z x y` (the Mac canvas's
//!                                  accessibility value), so the driver reads
//!                                  the mapping back instead of assuming it
//!   tool(id)            -> String  select a tool through the app's own
//!                                  `select_tool` action; returns the tool now
//!                                  active, so a wrong id cannot pass silently
//!   read()              -> String  `document_to_test_json` of the active
//!                                  document, byte for byte ("" with no tab)
//!   layout()            -> String  `workspace_to_test_json` of the workspace
//!                                  layout, byte for byte: the dock check
//!                                  (`web_l2_driver.py --dock`) reads where a
//!                                  dragged panel was anchored
//!   state(name)         -> String  one panel-scope value as
//!                                  `{"panel.<kind>.<key>": value}`, the Mac
//!                                  FIFO `state` reply's form, or
//!                                  `{"refused": why}` (the layers check)
//!
//! It is installed ONLY when the page's query carries `jas_test=1`. Without
//! the flag `window.__jasTest` does not exist, so the public demo exposes
//! nothing new to a visitor. The driver checks both directions.
//!
//! Everything but the wasm binding is plain functions over `AppState`, so
//! the native test target runs them.

use super::app_state::{AppState, TabState};
use crate::document::model::Model;

/// The query parameter that installs the hook.
#[cfg_attr(not(target_arch = "wasm32"), allow(dead_code))] // read by the wasm binding
pub const TEST_FLAG: &str = "jas_test=1";

/// True when a `location.search` string carries the flag as one whole
/// parameter (`?jas_test=1`, `?a=b&jas_test=1`), never as a substring of
/// another parameter (`?xjas_test=1`, `?jas_test=10`).
#[cfg_attr(not(target_arch = "wasm32"), allow(dead_code))] // read by the wasm binding
pub fn test_flag(search: &str) -> bool {
    search.trim_start_matches('?').split('&').any(|kv| kv == TEST_FLAG)
}

/// The DOM id of a panel's dock tab: the panel's YAML content id plus
/// `_tab`, the same identifier the Mac app gives the tab's accessibility
/// element. Derived from the content id, never listed.
pub fn tab_dom_id(content_id: &str) -> String {
    format!("{content_id}_tab")
}

/// The DOM id of a dock group's hamburger (row 291): the ACTIVE panel's
/// content id plus `_menu`, as the Mac's `panelMenuButtonId` names it and as
/// the shared planner's panel_menu act names it (`mac_l2_plan.MENU_SUFFIX`).
pub fn panel_menu_dom_id(content_id: &str) -> String {
    format!("{content_id}_menu")
}

/// The DOM id of that hamburger's flyout (row 291), whose action items carry
/// `role="menuitem"` and are picked by the title a person reads.
pub fn panel_menu_items_dom_id(content_id: &str) -> String {
    format!("{}_items", panel_menu_dom_id(content_id))
}

/// The DOM id of a dock GROUP's root element (row 111: Window > <panel>
/// scrolls the group it leaves a panel in into view). One statement, used by
/// the render and by the scroll.
pub fn dock_group_dom_id(dock_id: usize, group_idx: usize) -> String {
    format!("dock_group_{dock_id}_{group_idx}")
}

/// `open`: what File > Open does with the bytes it read
/// (`clipboard.rs`, the file input's onload), without the dialog.
#[cfg_attr(not(target_arch = "wasm32"), allow(dead_code))] // called by the wasm binding
pub(crate) fn open(st: &mut AppState, svg: &str, name: &str) {
    let doc = crate::geometry::svg::open_svg_document(svg);
    let model = Model::new(doc, Some(name.to_string()));
    st.add_tab(TabState::with_model_and_saved(model, Some(svg.to_string())));
}

/// `view`: set the active document's zoom and pan when all three are given,
/// then report the view the model holds. `None` with no tab.
#[cfg_attr(not(target_arch = "wasm32"), allow(dead_code))] // called by the wasm binding
pub(crate) fn view(st: &mut AppState, set: Option<(f64, f64, f64)>) -> Option<String> {
    let tab = st.tab_mut()?;
    if let Some((z, x, y)) = set {
        tab.model.zoom_level = z;
        tab.model.view_offset_x = x;
        tab.model.view_offset_y = y;
    }
    let m = &tab.model;
    Some(format!("view {} {} {}", m.zoom_level, m.view_offset_x, m.view_offset_y))
}

/// `tool`: the app's own `select_tool` action, then the tool now active.
#[cfg_attr(not(target_arch = "wasm32"), allow(dead_code))] // called by the wasm binding
pub(crate) fn tool(st: &mut AppState, id: &str) -> String {
    let mut params = serde_json::Map::new();
    params.insert("tool".into(), serde_json::Value::String(id.to_string()));
    crate::interpreter::renderer::dispatch_action("select_tool", &params, st);
    st.active_tool.panel_state_name().to_string()
}

/// `read`: the canonical test JSON of the active document.
#[cfg_attr(not(target_arch = "wasm32"), allow(dead_code))] // called by the wasm binding
pub(crate) fn read(st: &AppState) -> String {
    st.tab()
        .map(|t| crate::geometry::test_json::document_to_test_json(t.model.document()))
        .unwrap_or_default()
}

/// `layout`: the canonical test JSON of the workspace layout, the form the
/// shared `test_fixtures/workspace_operations/` corpus pins.
#[cfg_attr(not(target_arch = "wasm32"), allow(dead_code))] // called by the wasm binding
pub(crate) fn layout(st: &AppState) -> String {
    super::test_json::workspace_to_test_json(&st.workspace_layout)
}

/// `state`: one panel-scope value, as the panel's YAML expressions read it
/// (`panel_menu_ctx`: declared defaults, then the stored table, then the
/// typed slots), in the Mac FIFO `state` verb's reply form
/// `{"panel.<kind>.<key>": value}`. `<kind>` is a short kind (`layers`) or a
/// content id (`layers_panel_content`). A name it cannot resolve answers
/// `{"refused": "<why>"}`, naming what was missing, never a default.
#[cfg_attr(not(target_arch = "wasm32"), allow(dead_code))] // called by the wasm binding
pub(crate) fn state(st: &AppState, name: &str) -> String {
    let refuse = |why: String| serde_json::json!({ "refused": why }).to_string();
    let parts: Vec<&str> = name.split('.').collect();
    if parts.len() != 3 || parts[0] != "panel" || parts[1].is_empty() || parts[2].is_empty() {
        return refuse(format!("{name:?} is not panel.<kind>.<key>"));
    }
    let Some(ws) = crate::interpreter::workspace::Workspace::load() else {
        return refuse("the compiled workspace did not load".into());
    };
    let long = format!("{}_panel_content", parts[1]);
    let content_id = if ws.panel(parts[1]).is_some() {
        parts[1].to_string()
    } else if ws.panel(&long).is_some() {
        long
    } else {
        return refuse(format!("no panel {:?} (neither a content id nor a short kind)", parts[1]));
    };
    let ctx = crate::panels::panel_menu::panel_menu_ctx(&content_id, st);
    match ctx.get("panel").and_then(|p| p.get(parts[2])) {
        Some(v) => serde_json::json!({ name: v }).to_string(),
        None => refuse(format!("panel {content_id:?} has no key {:?}", parts[2])),
    }
}

/// `seed`: a script's `app_state` in its ruled form,
/// `{"panels": {<content id>: {<key>: <value>}}}` (row 291), applied as the
/// engine's seed door applies it: each key passes the shared ruled check
/// (`panel_seed::check_seed`: a panel the workspace has, a key its `state:`
/// declares) and is written in the store's form (`seed_panel_value`), here
/// through the app's own `set_panel_state` route, so the panels read it back
/// as a person's own selection. Every key is checked before any is written,
/// so a refused seed changes nothing. Answers `{"seeded": <n>}` or
/// `{"refused": "<why>"}`; the engine's refusals keep their kind as the
/// message's first word (`UnknownPanel …`, `UndeclaredPanelKey …`).
///
/// Refused by name, and not yet delivered: a seed of the Stroke panel (its
/// write re-applies the field to the selection, a different route), and a
/// STRING value (the `set_panel_state` route reads a string as an
/// expression). No script in the corpus seeds either.
#[cfg_attr(not(target_arch = "wasm32"), allow(dead_code))] // called by the wasm binding
pub(crate) fn seed(st: &mut AppState, json: &str) -> String {
    use crate::interpreter::panel_seed::{check_seed, seed_panel_value};
    let refuse = |why: String| serde_json::json!({ "refused": why }).to_string();
    let Ok(v) = serde_json::from_str::<serde_json::Value>(json) else {
        return refuse("the seed does not parse as JSON".into());
    };
    let Some(top) = v.as_object() else { return refuse("the seed is not an object".into()) };
    let mut writes = vec![];
    for (k, panels) in top {
        if k != "panels" {
            return refuse(format!("app_state.{k} is not a ruled form: seed a panel's declared state as \
                                   app_state.panels.<content id>.<key>"));
        }
        let Some(panels) = panels.as_object() else { return refuse("app_state.panels is not an object".into()) };
        for (pid, keys) in panels {
            let Some(keys) = keys.as_object() else {
                return refuse(format!("app_state.panels.{pid} is not an object"));
            };
            if pid == "stroke_panel_content" {
                return refuse(format!("app_state.panels.{pid}: the web does not seed the Stroke panel yet \
                                       (its write re-applies the field to the selection)"));
            }
            for (key, val) in keys {
                if let Err(why) = check_seed(pid, key) {
                    return refuse(why.to_string());
                }
                if val.is_string() {
                    return refuse(format!("app_state.panels.{pid}.{key} is a string: the web's set_panel_state \
                                           reads a string as an expression, so a string seed is not delivered yet"));
                }
                writes.push((pid.clone(), key.clone(), seed_panel_value(val)));
            }
        }
    }
    let n = writes.len();
    for (pid, key, val) in writes {
        let mut sps = serde_json::Map::new();
        sps.insert("panel".into(), serde_json::Value::String(pid));
        sps.insert("key".into(), serde_json::Value::String(key));
        sps.insert("value".into(), val);
        crate::interpreter::renderer::apply_set_panel_state_with_ctx(&sps, st, None);
    }
    serde_json::json!({ "seeded": n }).to_string()
}

/// `dialog`: the open dialog's id in the Mac FIFO `dialog` read's reply form,
/// `{"dialog": <id> | null}` (row 291).
#[cfg_attr(not(target_arch = "wasm32"), allow(dead_code))] // called by the wasm binding
pub(crate) fn dialog_reply(open: Option<&str>) -> String {
    serde_json::json!({ "dialog": open }).to_string()
}

#[cfg(target_arch = "wasm32")]
mod wasm_api {
    use super::*;
    use crate::workspace::app_state::AppHandle;
    use dioxus::prelude::*;
    use wasm_bindgen::prelude::*;

    fn set(obj: &js_sys::Object, name: &str, f: &JsValue) {
        let _ = js_sys::Reflect::set(obj, &name.into(), f);
    }

    /// Install `window.__jasTest` when the page's query carries the flag.
    /// `revision` is the app's re-render signal: a command that changes the
    /// state bumps it, as the File > Open path does.
    pub fn install(app: AppHandle, revision: Signal<u64>) {
        let search = web_sys::window()
            .and_then(|w| w.location().search().ok())
            .unwrap_or_default();
        if !test_flag(&search) {
            return;
        }
        let obj = js_sys::Object::new();
        {
            let app = app.clone();
            let rev = revision;
            let cb = Closure::<dyn Fn(String, String) -> bool>::new(move |svg: String, name: String| {
                let Ok(mut st) = app.try_borrow_mut() else { return false };
                open(&mut st, &svg, &name);
                drop(st);
                { let mut r = rev; r += 1; }
                true
            });
            set(&obj, "open", cb.as_ref());
            cb.forget();
        }
        {
            let app = app.clone();
            let rev = revision;
            let cb = Closure::<dyn Fn(JsValue, JsValue, JsValue) -> String>::new(
                move |z: JsValue, x: JsValue, y: JsValue| {
                    let given = match (z.as_f64(), x.as_f64(), y.as_f64()) {
                        (Some(z), Some(x), Some(y)) => Some((z, x, y)),
                        _ => None,
                    };
                    let Ok(mut st) = app.try_borrow_mut() else { return String::new() };
                    let out = view(&mut st, given).unwrap_or_default();
                    drop(st);
                    if given.is_some() {
                        { let mut r = rev; r += 1; }
                    }
                    out
                },
            );
            set(&obj, "view", cb.as_ref());
            cb.forget();
        }
        {
            let app = app.clone();
            let rev = revision;
            let cb = Closure::<dyn Fn(String) -> String>::new(move |id: String| {
                let Ok(mut st) = app.try_borrow_mut() else { return String::new() };
                let out = tool(&mut st, &id);
                drop(st);
                { let mut r = rev; r += 1; }
                out
            });
            set(&obj, "tool", cb.as_ref());
            cb.forget();
        }
        {
            let app = app.clone();
            let cb = Closure::<dyn Fn() -> String>::new(move || {
                app.try_borrow().map(|st| read(&st)).unwrap_or_default()
            });
            set(&obj, "read", cb.as_ref());
            cb.forget();
        }
        {
            let app = app.clone();
            let cb = Closure::<dyn Fn() -> String>::new(move || {
                app.try_borrow().map(|st| layout(&st)).unwrap_or_default()
            });
            set(&obj, "layout", cb.as_ref());
            cb.forget();
        }
        {
            let app = app.clone();
            let cb = Closure::<dyn Fn(String) -> String>::new(move |name: String| {
                app.try_borrow().map(|st| state(&st, &name)).unwrap_or_default()
            });
            set(&obj, "state", cb.as_ref());
            cb.forget();
        }
        {
            let app = app.clone();
            let rev = revision;
            let cb = Closure::<dyn Fn(String) -> String>::new(move |json: String| {
                let Ok(mut st) = app.try_borrow_mut() else { return String::new() };
                let out = seed(&mut st, &json);
                drop(st);
                { let mut r = rev; r += 1; }
                out
            });
            set(&obj, "seed", cb.as_ref());
            cb.forget();
        }
        set(&js_sys::global(), "__jasTest", &JsValue::from(obj));
    }

    /// Row 291: add `dialog()` to `window.__jasTest` (installed above, when the
    /// flag is set), reading the app's dialog signal, which is created after
    /// the hook is installed.
    pub fn install_dialog(dialog: Signal<Option<crate::interpreter::dialog_view::DialogState>>) {
        let Ok(obj) = js_sys::Reflect::get(&js_sys::global(), &"__jasTest".into()) else { return };
        if !obj.is_object() {
            return;
        }
        let cb = Closure::<dyn Fn() -> String>::new(move || {
            let open = dialog.try_read().ok().and_then(|d| d.as_ref().map(|s| s.id.clone()));
            dialog_reply(open.as_deref())
        });
        set(&js_sys::Object::from(obj), "dialog", cb.as_ref());
        cb.forget();
    }
}

#[cfg(target_arch = "wasm32")]
pub(crate) use wasm_api::{install, install_dialog};

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../../../test_fixtures/svg/three_rects.svg");

    /// Row 291: a dock group's hamburger is `<active panel content id>_menu`
    /// (the Mac's `panelMenuButtonId`, and the id the shared planner's
    /// panel_menu act names), and its flyout is that id plus `_items`.
    #[test]
    fn the_panel_menu_ids_derive_from_the_content_id() {
        assert_eq!(panel_menu_dom_id("artboards_panel_content"), "artboards_panel_content_menu");
        assert_eq!(panel_menu_items_dom_id("artboards_panel_content"), "artboards_panel_content_menu_items");
        assert_ne!(panel_menu_dom_id("artboards_panel_content"), tab_dom_id("artboards_panel_content"));
    }

    #[test]
    fn the_flag_is_one_whole_parameter() {
        assert!(test_flag("?jas_test=1"));
        assert!(test_flag("?a=b&jas_test=1"));
        assert!(test_flag("jas_test=1&a=b"));
        assert!(!test_flag(""));
        assert!(!test_flag("?jas_test=0"));
        assert!(!test_flag("?jas_test=10"));
        assert!(!test_flag("?xjas_test=1"));
        assert!(!test_flag("?record=gesture:x"));
    }

    #[test]
    fn every_panel_content_id_is_a_yaml_panel_and_its_tab_id_derives_from_it() {
        use crate::interpreter::workspace::{panel_kind_to_content_id, Workspace};
        use crate::workspace::workspace::PanelKind;
        let ws = Workspace::load().expect("the compiled workspace");
        for kind in PanelKind::ALL {
            let cid = panel_kind_to_content_id(*kind);
            assert!(ws.panel(cid).is_some(), "{cid} is not a panel id in the YAML");
            assert_eq!(tab_dom_id(cid), format!("{cid}_tab"));
        }
    }

    #[test]
    fn read_is_document_to_test_json_byte_for_byte() {
        let mut st = AppState::new();
        assert_eq!(read(&st), "", "no tab reads empty");
        open(&mut st, FIXTURE, "three_rects.svg");
        // An open mints a fresh 8-character artboard id, so two opens differ
        // there and nowhere else: compare with that one id normalised (the
        // level-2 comparator sets the open's artboard aside the same way).
        let engine = crate::geometry::test_json::document_to_test_json(
            &crate::geometry::svg::open_svg_document(FIXTURE),
        );
        let norm = |s: &str| {
            let i = s.find("\"id\":\"").expect("the open's artboard has an id") + 6;
            format!("{}XXXXXXXX{}", &s[..i], &s[i + 8..])
        };
        assert_ne!(read(&st), engine, "the two opens mint different artboard ids");
        assert_eq!(norm(&read(&st)), norm(&engine));
        assert_eq!(
            read(&st),
            crate::geometry::test_json::document_to_test_json(st.tab().unwrap().model.document()),
            "read() is document_to_test_json of the active document"
        );
        assert!(read(&st).contains("\"type\":\"rect\""), "the fixture's rects are read back");
    }

    #[test]
    fn layout_is_workspace_to_test_json_and_the_dock_cases_start_right() {
        let st = AppState::new();
        assert_eq!(
            layout(&st),
            crate::workspace::test_json::workspace_to_test_json(&st.workspace_layout)
        );
        // web_l2_driver.py's DOCK_CASES drag stroke, layers and align out of
        // the right dock, and refuse if any starts anywhere else.
        let v: serde_json::Value = serde_json::from_str(&layout(&st)).expect("layout() is JSON");
        let edge_of = |kind: &str| -> Vec<String> {
            v["anchored"].as_array().unwrap().iter()
                .filter(|a| a["dock"]["groups"].as_array().unwrap().iter()
                    .any(|g| g["panels"].as_array().unwrap().iter().any(|p| p == kind)))
                .map(|a| a["edge"].as_str().unwrap().to_string())
                .collect()
        };
        assert_eq!(edge_of("stroke"), vec!["right"]);
        assert_eq!(edge_of("layers"), vec!["right"]);
        assert_eq!(edge_of("align"), vec!["right"]);
    }

    #[test]
    fn view_sets_and_reports() {
        let mut st = AppState::new();
        assert_eq!(view(&mut st, Some((1.0, 0.0, 0.0))), None, "no tab, no view");
        open(&mut st, FIXTURE, "three_rects.svg");
        assert_eq!(view(&mut st, Some((2.0, 10.0, 20.0))).as_deref(), Some("view 2 10 20"));
        assert_eq!(view(&mut st, None).as_deref(), Some("view 2 10 20"));
        assert_eq!(view(&mut st, Some((1.0, 0.0, 0.0))).as_deref(), Some("view 1 0 0"));
    }

    /// Row 266: `state(name)` answers in the Mac FIFO `state` verb's form,
    /// `{"panel.<kind>.<key>": value}`, so `mac_l2_plan.layers_reduce` reads
    /// both channels' replies by one law.
    #[test]
    fn state_reads_a_layers_key_in_the_mac_reply_form() {
        let mut st = AppState::new();
        open(&mut st, FIXTURE, "three_rects.svg");
        st.layers_panel_selection = vec![vec![1], vec![1, 0]];
        st.layers_renaming = Some(vec![0]);
        let v = |s: String| serde_json::from_str::<serde_json::Value>(&s).expect("state answers JSON");
        assert_eq!(v(state(&st, "panel.layers.layers_panel_selection")),
                   serde_json::json!({"panel.layers.layers_panel_selection": [{"__path__": [1]}, {"__path__": [1, 0]}]}));
        assert_eq!(v(state(&st, "panel.layers.renaming_element")),
                   serde_json::json!({"panel.layers.renaming_element": [0]}),
                   "the plain list, as the Mac stores it after row 265");
        st.layers_renaming = None;
        assert_eq!(v(state(&st, "panel.layers.renaming_element")),
                   serde_json::json!({"panel.layers.renaming_element": null}),
                   "a closed rename reads null, a value, never a refusal");
        assert_eq!(v(state(&st, "panel.layers_panel_content.renaming_element")),
                   serde_json::json!({"panel.layers_panel_content.renaming_element": null}),
                   "the content id names the same scope as its short kind");
    }

    #[test]
    fn state_refuses_a_name_it_cannot_resolve_by_name() {
        let st = AppState::new();
        let refused = |name: &str| {
            let r: serde_json::Value = serde_json::from_str(&state(&st, name)).expect("state answers JSON");
            r.get("refused").and_then(|v| v.as_str()).map(str::to_string)
                .unwrap_or_else(|| panic!("{name} was not refused: {r}"))
        };
        assert!(refused("layers.renaming_element").contains("panel.<kind>.<key>"), "malformed");
        assert!(refused("panel.nosuch.key").contains("nosuch"), "an unknown panel");
        assert!(refused("panel.layers.nosuch_key").contains("nosuch_key"), "an absent key");
    }

    /// Row 291: `seed` applies a script's `app_state` (the ruled form) through
    /// the app's own `set_panel_state` route, after the engine's ruled check,
    /// so the Artboards menu reads the seeded selection as a person's own.
    /// Everything the engine refuses is refused here by the same kind, with
    /// nothing changed.
    #[test]
    fn seed_sets_a_declared_key_as_a_person_would_and_refuses_by_name() {
        let mut st = AppState::new();
        open(&mut st, FIXTURE, "three_rects.svg");
        let v = |s: String| serde_json::from_str::<serde_json::Value>(&s).expect("seed answers JSON");
        let ids = |st: &AppState| crate::panels::panel_menu::panel_menu_ctx("artboards_panel_content", st)
            ["active_document"]["artboards_panel_selection_ids"].clone();
        assert_eq!(ids(&st), serde_json::json!([]), "the control: nothing selected");
        assert_eq!(v(seed(&mut st, r#"{"panels":{"artboards_panel_content":{"artboards_panel_selection":["a1"]}}}"#)),
                   serde_json::json!({"seeded": 1}));
        assert_eq!(ids(&st), serde_json::json!(["a1"]), "the seed is the selection the menu reads");
        let refused = |st: &mut AppState, json: &str| {
            let r = v(seed(st, json));
            r.get("refused").and_then(|x| x.as_str()).map(str::to_string)
                .unwrap_or_else(|| panic!("{json} was not refused: {r}"))
        };
        assert!(refused(&mut st, r#"{"panels":{"no_such_panel_content":{"k":1}}}"#).starts_with("UnknownPanel "));
        assert!(refused(&mut st, r#"{"panels":{"artboards_panel_content":{"not_a_declared_key":1}}}"#)
            .starts_with("UndeclaredPanelKey "));
        assert!(refused(&mut st, r##"{"fill_color":"#fff"}"##).contains("not a ruled form"));
        assert!(refused(&mut st, r#"{"panels":{"artboards_panel_content":3}}"#).contains("is not an object"));
        assert!(refused(&mut st, "{nope").contains("does not parse"));
        assert!(refused(&mut st, r#"{"panels":{"stroke_panel_content":{"cap":"round"}}}"#)
            .contains("stroke_panel_content"), "the stroke panel's write is not this route: refused by name");
        // A refused seed changes nothing, even when a key before it was good.
        assert!(refused(&mut st, r#"{"panels":{"artboards_panel_content":{"artboards_panel_selection":[],"zz_undeclared":1}}}"#)
            .starts_with("UndeclaredPanelKey "));
        assert_eq!(ids(&st), serde_json::json!(["a1"]), "no refusal changed the state");
    }

    /// Row 291: `dialog` answers the open dialog in the Mac FIFO `dialog`
    /// read's reply form, `{"dialog": <id> | null}`.
    #[test]
    fn the_dialog_reply_is_the_mac_form() {
        let v = |s: String| serde_json::from_str::<serde_json::Value>(&s).unwrap();
        assert_eq!(v(dialog_reply(Some("artboard_options"))), serde_json::json!({"dialog": "artboard_options"}));
        assert_eq!(v(dialog_reply(None)), serde_json::json!({"dialog": null}));
    }

    #[test]
    fn tool_goes_through_select_tool_and_reports_the_active_tool() {
        let mut st = AppState::new();
        open(&mut st, FIXTURE, "three_rects.svg");
        assert_eq!(tool(&mut st, "rect"), "rect");
        assert_eq!(tool(&mut st, "selection"), "selection");
    }
}
