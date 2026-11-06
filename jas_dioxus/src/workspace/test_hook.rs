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
        set(&js_sys::global(), "__jasTest", &JsValue::from(obj));
    }
}

#[cfg(target_arch = "wasm32")]
pub(crate) use wasm_api::install;

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../../../test_fixtures/svg/three_rects.svg");

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
    fn view_sets_and_reports() {
        let mut st = AppState::new();
        assert_eq!(view(&mut st, Some((1.0, 0.0, 0.0))), None, "no tab, no view");
        open(&mut st, FIXTURE, "three_rects.svg");
        assert_eq!(view(&mut st, Some((2.0, 10.0, 20.0))).as_deref(), Some("view 2 10 20"));
        assert_eq!(view(&mut st, None).as_deref(), Some("view 2 10 20"));
        assert_eq!(view(&mut st, Some((1.0, 0.0, 0.0))).as_deref(), Some("view 1 0 0"));
    }

    #[test]
    fn tool_goes_through_select_tool_and_reports_the_active_tool() {
        let mut st = AppState::new();
        open(&mut st, FIXTURE, "three_rects.svg");
        assert_eq!(tool(&mut st, "rect"), "rect");
        assert_eq!(tool(&mut st, "selection"), "selection");
    }
}
