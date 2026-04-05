//! Main Dioxus application component.
//!
//! Hosts the toolbar, canvas, and wires keyboard shortcuts.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use dioxus::prelude::*;
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;
use web_sys::{CanvasRenderingContext2d, HtmlCanvasElement};

use crate::canvas::render;
use crate::document::controller::Controller;
use crate::document::document::ElementSelection;
use crate::document::model::Model;
use crate::geometry::element::{control_point_count, translate_element, Element as GeoElement};
use crate::geometry::svg::{document_to_svg, svg_to_document};
use crate::tools::direct_selection::DirectSelectionTool;
use crate::tools::group_selection::GroupSelectionTool;
use crate::tools::line::LineTool;
use crate::tools::pen::PenTool;
use crate::tools::pencil::PencilTool;
use crate::tools::polygon::PolygonTool;
use crate::tools::rect::RectTool;
use crate::tools::selection::SelectionTool;
use crate::tools::text::TextTool;
use crate::tools::tool::{CanvasTool, ToolKind, PASTE_OFFSET};

/// Shared application state.
struct AppState {
    model: Model,
    active_tool: ToolKind,
    tools: HashMap<ToolKind, Box<dyn CanvasTool>>,
    clipboard: Vec<GeoElement>,
}

impl AppState {
    fn new() -> Self {
        let mut tools: HashMap<ToolKind, Box<dyn CanvasTool>> = HashMap::new();
        tools.insert(ToolKind::Selection, Box::new(SelectionTool::new()));
        tools.insert(ToolKind::DirectSelection, Box::new(DirectSelectionTool::new()));
        tools.insert(ToolKind::GroupSelection, Box::new(GroupSelectionTool::new()));
        tools.insert(ToolKind::Pen, Box::new(PenTool::new()));
        tools.insert(ToolKind::Pencil, Box::new(PencilTool::new()));
        tools.insert(ToolKind::Text, Box::new(TextTool::new()));
        tools.insert(ToolKind::Rect, Box::new(RectTool::new()));
        tools.insert(ToolKind::Polygon, Box::new(PolygonTool::new()));
        tools.insert(ToolKind::Line, Box::new(LineTool::new()));
        Self {
            model: Model::default(),
            active_tool: ToolKind::Selection,
            tools,
            clipboard: Vec::new(),
        }
    }

    fn repaint(&self) {
        let window = match web_sys::window() {
            Some(w) => w,
            None => return,
        };
        let document = match window.document() {
            Some(d) => d,
            None => return,
        };
        let canvas_el = match document.get_element_by_id("jas-canvas") {
            Some(el) => el,
            None => return,
        };
        let canvas: HtmlCanvasElement = canvas_el.unchecked_into();
        let ctx: CanvasRenderingContext2d = canvas
            .get_context("2d")
            .unwrap()
            .unwrap()
            .unchecked_into();
        let w = canvas.width() as f64;
        let h = canvas.height() as f64;
        render::render(&ctx, w, h, self.model.document());

        // Draw tool overlay
        if let Some(tool) = self.tools.get(&self.active_tool) {
            tool.draw_overlay(&self.model, &ctx);
        }
    }
}

/// Download a string as a file in the browser.
fn download_file(filename: &str, content: &str) {
    let window = match web_sys::window() {
        Some(w) => w,
        None => return,
    };
    let document = match window.document() {
        Some(d) => d,
        None => return,
    };
    let parts = js_sys::Array::new();
    parts.push(&content.into());
    let opts = web_sys::BlobPropertyBag::new();
    opts.set_type("image/svg+xml");
    let blob = match web_sys::Blob::new_with_str_sequence_and_options(&parts, &opts) {
        Ok(b) => b,
        Err(_) => return,
    };
    let url = match web_sys::Url::create_object_url_with_blob(&blob) {
        Ok(u) => u,
        Err(_) => return,
    };
    let a: web_sys::HtmlAnchorElement = document
        .create_element("a")
        .unwrap()
        .unchecked_into();
    a.set_href(&url);
    a.set_download(filename);
    a.click();
    let _ = web_sys::Url::revoke_object_url(&url);
}

/// Trigger a file open dialog and call the callback with the file contents.
fn open_file_dialog(app: Rc<RefCell<AppState>>, revision: Signal<u64>) {
    let window = match web_sys::window() {
        Some(w) => w,
        None => return,
    };
    let document = match window.document() {
        Some(d) => d,
        None => return,
    };
    let input: web_sys::HtmlInputElement = document
        .create_element("input")
        .unwrap()
        .unchecked_into();
    input.set_type("file");
    input.set_attribute("accept", ".svg,image/svg+xml").ok();

    let app2 = app.clone();
    let revision2 = revision.clone();
    let input2 = input.clone();
    let onchange = Closure::wrap(Box::new(move |_evt: web_sys::Event| {
        let files = match input2.files() {
            Some(f) => f,
            None => return,
        };
        let file = match files.get(0) {
            Some(f) => f,
            None => return,
        };
        let filename = file.name();
        let reader = web_sys::FileReader::new().unwrap();
        let reader2 = reader.clone();
        let app3 = app2.clone();
        let mut revision3 = revision2.clone();
        let onload = Closure::wrap(Box::new(move |_evt: web_sys::Event| {
            let result = match reader2.result() {
                Ok(r) => r,
                Err(_) => return,
            };
            let text = match result.as_string() {
                Some(s) => s,
                None => return,
            };
            let doc = svg_to_document(&text);
            let mut st = app3.borrow_mut();
            st.model = Model::new(doc, Some(filename.clone()));
            st.clipboard.clear();
            drop(st);
            revision3 += 1;
        }) as Box<dyn FnMut(web_sys::Event)>);
        reader.set_onload(Some(onload.as_ref().unchecked_ref()));
        onload.forget(); // leak closure — it only fires once
        reader.read_as_text(&file).ok();
    }) as Box<dyn FnMut(web_sys::Event)>);
    input.set_onchange(Some(onchange.as_ref().unchecked_ref()));
    onchange.forget();
    input.click();
}

const TOOLBAR_TOOLS: &[ToolKind] = &[
    ToolKind::Selection,
    ToolKind::DirectSelection,
    ToolKind::GroupSelection,
    ToolKind::Pen,
    ToolKind::Pencil,
    ToolKind::Text,
    ToolKind::Line,
    ToolKind::Rect,
    ToolKind::Polygon,
];

fn toolbar_icon(kind: ToolKind) -> &'static str {
    match kind {
        ToolKind::Selection => "\u{25b3}",      // triangle (arrow-like)
        ToolKind::DirectSelection => "\u{25ef}", // hollow circle
        ToolKind::GroupSelection => "\u{29c9}",  // two joined squares
        ToolKind::Line => "\u{2571}",            // diagonal
        ToolKind::Rect => "\u{25a1}",            // square
        ToolKind::Pen => "\u{270e}",             // pen
        ToolKind::Pencil => "\u{270f}",          // pencil
        ToolKind::Polygon => "\u{2b53}",          // pentagon
        ToolKind::Text => "T",
        _ => "?",
    }
}

#[component]
pub fn App() -> Element {
    // Shared state wrapped in Rc<RefCell<>> for interior mutability.
    // We use a revision signal to trigger Dioxus re-renders after state changes.
    let app = use_hook(|| Rc::new(RefCell::new(AppState::new())));
    let mut revision = use_signal(|| 0u64);

    // Repaint after each render
    {
        let app = app.clone();
        use_effect(move || {
            let _rev = revision();
            app.borrow().repaint();
        });
    }

    // Macro-like helper: mutate state, then bump revision to trigger repaint.
    let act = {
        let app = app.clone();
        move |f: Box<dyn FnOnce(&mut AppState)>| {
            f(&mut app.borrow_mut());
            revision += 1;
        }
    };
    let act = Rc::new(RefCell::new(act));

    // --- Mouse events ---
    // Dioxus mouse events provide element_coordinates() for position relative
    // to the target element, and modifiers() for shift/alt/ctrl/meta.

    let on_mousedown = {
        let act = act.clone();
        move |evt: Event<MouseData>| {
            let coords = evt.data().element_coordinates();
            let cx = coords.x;
            let cy = coords.y;
            let mods = evt.data().modifiers();
            let shift = mods.shift();
            let alt = mods.alt();
            (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                let kind = st.active_tool;
                if let Some(tool) = st.tools.get_mut(&kind) {
                    tool.on_press(&mut st.model, cx, cy, shift, alt);
                }
            }));
        }
    };

    let on_mousemove = {
        let act = act.clone();
        move |evt: Event<MouseData>| {
            let coords = evt.data().element_coordinates();
            let cx = coords.x;
            let cy = coords.y;
            let mods = evt.data().modifiers();
            let shift = mods.shift();
            let dragging = evt.data().held_buttons().contains(dioxus::html::input_data::MouseButton::Primary);
            (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                let kind = st.active_tool;
                if let Some(tool) = st.tools.get_mut(&kind) {
                    tool.on_move(&mut st.model, cx, cy, shift, dragging);
                }
            }));
        }
    };

    let on_mouseup = {
        let act = act.clone();
        move |evt: Event<MouseData>| {
            let coords = evt.data().element_coordinates();
            let cx = coords.x;
            let cy = coords.y;
            let mods = evt.data().modifiers();
            let shift = mods.shift();
            let alt = mods.alt();
            (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                let kind = st.active_tool;
                if let Some(tool) = st.tools.get_mut(&kind) {
                    tool.on_release(&mut st.model, cx, cy, shift, alt);
                }
            }));
        }
    };

    let on_dblclick = {
        let act = act.clone();
        move |evt: Event<MouseData>| {
            let coords = evt.data().element_coordinates();
            let cx = coords.x;
            let cy = coords.y;
            (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                let kind = st.active_tool;
                if let Some(tool) = st.tools.get_mut(&kind) {
                    tool.on_double_click(&mut st.model, cx, cy);
                }
            }));
        }
    };

    // --- Keyboard events ---
    let on_keydown = {
        let act = act.clone();
        let app_for_keys = app.clone();
        let revision_for_keys = revision.clone();
        move |evt: Event<KeyboardData>| {
            let key = evt.data().key();
            let mods = evt.data().modifiers();
            let cmd = mods.meta() || mods.ctrl();
            match key {
                // --- Modifier shortcuts (must come before bare key shortcuts) ---
                Key::Character(ref c) if (c == "z" || c == "Z") && cmd => {
                    evt.prevent_default();
                    if mods.shift() {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            st.model.redo();
                        }));
                    } else {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            st.model.undo();
                        }));
                    }
                }
                Key::Character(ref c) if (c == "c" || c == "C") && cmd => {
                    evt.prevent_default();
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        let doc = st.model.document();
                        let mut elements = Vec::new();
                        for es in &doc.selection {
                            if let Some(elem) = doc.get_element(&es.path) {
                                elements.push(elem.clone());
                            }
                        }
                        st.clipboard = elements;
                    }));
                }
                Key::Character(ref c) if (c == "x" || c == "X") && cmd => {
                    evt.prevent_default();
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        let doc = st.model.document();
                        let mut elements = Vec::new();
                        for es in &doc.selection {
                            if let Some(elem) = doc.get_element(&es.path) {
                                elements.push(elem.clone());
                            }
                        }
                        st.clipboard = elements;
                        st.model.snapshot();
                        let new_doc = st.model.document().delete_selection();
                        st.model.set_document(new_doc);
                    }));
                }
                Key::Character(ref c) if (c == "v" || c == "V") && cmd => {
                    evt.prevent_default();
                    let offset = if mods.shift() { 0.0 } else { PASTE_OFFSET };
                    (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                        if st.clipboard.is_empty() {
                            return;
                        }
                        st.model.snapshot();
                        let mut doc = st.model.document().clone();
                        let idx = doc.selected_layer;
                        let mut new_selection = Vec::new();
                        let base = doc.layers[idx].children().map_or(0, |c| c.len());
                        for (j, elem) in st.clipboard.iter().enumerate() {
                            let translated = translate_element(elem, offset, offset);
                            let path = vec![idx, base + j];
                            let n = control_point_count(&translated);
                            new_selection.push(ElementSelection {
                                path,
                                control_points: (0..n).collect(),
                            });
                            if let Some(children) = doc.layers[idx].children_mut() {
                                children.push(translated);
                            }
                        }
                        doc.selection = new_selection;
                        st.model.set_document(doc);
                    }));
                }
                Key::Character(ref c) if (c == "a" || c == "A") && cmd => {
                    evt.prevent_default();
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        Controller::select_all(&mut st.model);
                    }));
                }
                Key::Character(ref c) if (c == "2") && cmd => {
                    evt.prevent_default();
                    if mods.alt() {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            st.model.snapshot();
                            Controller::unlock_all(&mut st.model);
                        }));
                    } else {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            st.model.snapshot();
                            Controller::lock_selection(&mut st.model);
                        }));
                    }
                }
                Key::Character(ref c) if (c == "s" || c == "S") && cmd => {
                    evt.prevent_default();
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        let svg = document_to_svg(st.model.document());
                        let filename = if st.model.filename.ends_with(".svg") {
                            st.model.filename.clone()
                        } else {
                            format!("{}.svg", st.model.filename)
                        };
                        download_file(&filename, &svg);
                        st.model.mark_saved();
                    }));
                }
                Key::Character(ref c) if (c == "o" || c == "O") && cmd => {
                    evt.prevent_default();
                    open_file_dialog(app_for_keys.clone(), revision_for_keys.clone());
                }
                Key::Character(ref c) if (c == "g" || c == "G") && cmd => {
                    evt.prevent_default();
                    if mods.shift() {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            st.model.snapshot();
                            Controller::ungroup_selection(&mut st.model);
                        }));
                    } else {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            st.model.snapshot();
                            Controller::group_selection(&mut st.model);
                        }));
                    }
                }
                // --- Tool shortcuts (bare keys, no modifier) ---
                Key::Character(ref c) if c == "v" || c == "V" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.active_tool = ToolKind::Selection;
                    }));
                }
                Key::Character(ref c) if c == "a" || c == "A" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.active_tool = ToolKind::DirectSelection;
                    }));
                }
                Key::Character(ref c) if c == "p" || c == "P" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.active_tool = ToolKind::Pen;
                    }));
                }
                Key::Character(ref c) if c == "n" || c == "N" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.active_tool = ToolKind::Pencil;
                    }));
                }
                Key::Character(ref c) if c == "t" || c == "T" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.active_tool = ToolKind::Text;
                    }));
                }
                Key::Character(ref c) if c == "l" || c == "L" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.active_tool = ToolKind::Line;
                    }));
                }
                Key::Character(ref c) if c == "m" || c == "M" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.active_tool = ToolKind::Rect;
                    }));
                }
                Key::Escape | Key::Enter => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        let kind = st.active_tool;
                        if let Some(tool) = st.tools.get_mut(&kind) {
                            tool.on_key(&mut st.model, "Escape");
                        }
                    }));
                }
                Key::Delete | Key::Backspace => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.model.snapshot();
                        let new_doc = st.model.document().delete_selection();
                        st.model.set_document(new_doc);
                    }));
                }
                _ => {}
            }
        }
    };

    // --- Tool buttons ---
    let active_tool = app.borrow().active_tool;
    let tool_buttons: Vec<Result<VNode, RenderError>> = TOOLBAR_TOOLS
        .iter()
        .map(|&kind| {
            let act = act.clone();
            let is_active = active_tool == kind;
            let bg = if is_active { "#d0d0d0" } else { "#f0f0f0" };
            rsx! {
                button {
                    key: "{kind:?}",
                    style: "display:block; width:36px; height:36px; margin:2px; border:1px solid #999; background:{bg}; cursor:pointer; font-size:18px;",
                    title: "{kind.label()}",
                    onclick: move |_| {
                        (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                            st.active_tool = kind;
                        }));
                    },
                    "{toolbar_icon(kind)}"
                }
            }
        })
        .collect();

    rsx! {
        div {
            tabindex: "0",
            onkeydown: on_keydown,
            style: "display:flex; height:100vh; outline:none; font-family:sans-serif;",

            // Toolbar
            div {
                style: "width:42px; background:#e8e8e8; border-right:1px solid #ccc; padding:4px 2px; display:flex; flex-direction:column; align-items:center;",
                for btn in tool_buttons {
                    {btn}
                }
            }

            // Canvas area
            div {
                style: "flex:1; position:relative; overflow:hidden;",
                canvas {
                    id: "jas-canvas",
                    width: "1200",
                    height: "800",
                    style: "display:block; cursor:crosshair;",
                    onmousedown: on_mousedown,
                    onmousemove: on_mousemove,
                    onmouseup: on_mouseup,
                    ondoubleclick: on_dblclick,
                }
            }
        }
    }
}
