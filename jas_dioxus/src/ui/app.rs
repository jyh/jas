//! Main Dioxus application component.
//!
//! Hosts the toolbar, tab bar, canvas, and wires keyboard shortcuts.

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
use crate::tools::text_path::TextPathTool;
use crate::tools::tool::{CanvasTool, ToolKind, PASTE_OFFSET};

/// Per-tab state: each tab has its own document, tools, and clipboard.
struct TabState {
    model: Model,
    tools: HashMap<ToolKind, Box<dyn CanvasTool>>,
    clipboard: Vec<GeoElement>,
}

impl TabState {
    fn new() -> Self {
        Self::with_model(Model::default())
    }

    fn with_model(model: Model) -> Self {
        let mut tools: HashMap<ToolKind, Box<dyn CanvasTool>> = HashMap::new();
        tools.insert(ToolKind::Selection, Box::new(SelectionTool::new()));
        tools.insert(ToolKind::DirectSelection, Box::new(DirectSelectionTool::new()));
        tools.insert(ToolKind::GroupSelection, Box::new(GroupSelectionTool::new()));
        tools.insert(ToolKind::Pen, Box::new(PenTool::new()));
        tools.insert(ToolKind::Pencil, Box::new(PencilTool::new()));
        tools.insert(ToolKind::Text, Box::new(TextTool::new()));
        tools.insert(ToolKind::TextOnPath, Box::new(TextPathTool::new()));
        tools.insert(ToolKind::Rect, Box::new(RectTool::new()));
        tools.insert(ToolKind::Polygon, Box::new(PolygonTool::new()));
        tools.insert(ToolKind::Line, Box::new(LineTool::new()));
        Self { model, tools, clipboard: Vec::new() }
    }
}

/// Shared application state.
struct AppState {
    tabs: Vec<TabState>,
    active_tab: usize,
    active_tool: ToolKind,
}

impl AppState {
    fn new() -> Self {
        Self {
            tabs: vec![TabState::new()],
            active_tab: 0,
            active_tool: ToolKind::Selection,
        }
    }

    fn tab(&self) -> &TabState {
        &self.tabs[self.active_tab]
    }

    fn tab_mut(&mut self) -> &mut TabState {
        &mut self.tabs[self.active_tab]
    }

    fn add_tab(&mut self, tab: TabState) {
        self.tabs.push(tab);
        self.active_tab = self.tabs.len() - 1;
    }

    fn close_tab(&mut self, index: usize) {
        if self.tabs.len() <= 1 {
            return; // keep at least one tab
        }
        self.tabs.remove(index);
        if self.active_tab >= self.tabs.len() {
            self.active_tab = self.tabs.len() - 1;
        } else if self.active_tab > index {
            self.active_tab -= 1;
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
        let ctx: CanvasRenderingContext2d = match canvas.get_context("2d") {
            Ok(Some(ctx)) => ctx.unchecked_into(),
            _ => return,
        };
        let w = canvas.width() as f64;
        let h = canvas.height() as f64;
        let tab = self.tab();
        render::render(&ctx, w, h, tab.model.document());

        // Draw tool overlay
        if let Some(tool) = tab.tools.get(&self.active_tool) {
            tool.draw_overlay(&tab.model, &ctx);
        }
    }
}

/// Write text to the system clipboard (fire-and-forget async).
fn clipboard_write(text: String) {
    if let Some(window) = web_sys::window() {
        let clipboard = window.navigator().clipboard();
        let promise = clipboard.write_text(&text);
        let _ = wasm_bindgen_futures::JsFuture::from(promise);
        // Fire and forget — spawn to avoid blocking
        wasm_bindgen_futures::spawn_local(async move {
            if let Some(window) = web_sys::window() {
                let _ = wasm_bindgen_futures::JsFuture::from(
                    window.navigator().clipboard().write_text(&text)
                ).await;
            }
        });
    }
}

/// Read text from the system clipboard, then call the callback with it.
fn clipboard_read_and_paste(app: Rc<RefCell<AppState>>, mut revision: Signal<u64>, offset: f64) {
    wasm_bindgen_futures::spawn_local(async move {
        let clipboard_text = async {
            let window = web_sys::window()?;
            let clipboard = window.navigator().clipboard();
            let promise = clipboard.read_text();
            let val = wasm_bindgen_futures::JsFuture::from(promise).await.ok()?;
            val.as_string()
        }.await;

        let mut st = app.borrow_mut();
        let tab = st.tab_mut();

        // Check if clipboard contains SVG
        if let Some(text) = &clipboard_text {
            let trimmed = text.trim();
            if trimmed.starts_with("<?xml") || trimmed.starts_with("<svg") {
                let pasted_doc = svg_to_document(text);
                tab.model.snapshot();
                let mut doc = tab.model.document().clone();
                let idx = doc.selected_layer;
                let mut new_selection = Vec::new();
                let base = doc.layers[idx].children().map_or(0, |c| c.len());
                let mut j = 0;
                for layer in &pasted_doc.layers {
                    if let Some(children) = layer.children() {
                        for child in children {
                            let translated = translate_element(child, offset, offset);
                            let path = vec![idx, base + j];
                            let n = control_point_count(&translated);
                            new_selection.push(ElementSelection {
                                path,
                                control_points: (0..n).collect(),
                            });
                            if let Some(layer_children) = doc.layers[idx].children_mut() {
                                layer_children.push(Rc::new(translated));
                            }
                            j += 1;
                        }
                    }
                }
                if j > 0 {
                    doc.selection = new_selection;
                    tab.model.set_document(doc);
                    drop(st);
                    revision += 1;
                    return;
                }
            }
        }

        // Fall back to internal clipboard
        if tab.clipboard.is_empty() {
            return;
        }
        tab.model.snapshot();
        let mut doc = tab.model.document().clone();
        let idx = doc.selected_layer;
        let mut new_selection = Vec::new();
        let base = doc.layers[idx].children().map_or(0, |c| c.len());
        for (j, elem) in tab.clipboard.iter().enumerate() {
            let translated = translate_element(elem, offset, offset);
            let path = vec![idx, base + j];
            let n = control_point_count(&translated);
            new_selection.push(ElementSelection {
                path,
                control_points: (0..n).collect(),
            });
            if let Some(children) = doc.layers[idx].children_mut() {
                children.push(Rc::new(translated));
            }
        }
        doc.selection = new_selection;
        tab.model.set_document(doc);
        drop(st);
        revision += 1;
    });
}

/// Build SVG string from selected elements for clipboard export.
fn selection_to_svg(st: &AppState) -> Option<String> {
    let tab = st.tab();
    let doc = tab.model.document();
    if doc.selection.is_empty() {
        return None;
    }
    let mut elements = Vec::new();
    for es in &doc.selection {
        if let Some(elem) = doc.get_element(&es.path) {
            elements.push(elem.clone());
        }
    }
    if elements.is_empty() {
        return None;
    }
    use crate::document::document::Document;
    use crate::geometry::element::{LayerElem, CommonProps};
    let temp_doc = Document {
        layers: vec![GeoElement::Layer(LayerElem {
            children: elements.into_iter().map(Rc::new).collect(),
            name: String::new(),
            common: CommonProps::default(),
        })],
        selected_layer: 0,
        selection: Vec::new(),
    };
    Some(document_to_svg(&temp_doc))
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
    let a: web_sys::HtmlAnchorElement = match document.create_element("a") {
        Ok(el) => el.unchecked_into(),
        Err(_) => return,
    };
    a.set_href(&url);
    a.set_download(filename);
    a.click();
    let _ = web_sys::Url::revoke_object_url(&url);
}

/// Trigger a file open dialog and load the file into a new tab.
fn open_file_dialog(app: Rc<RefCell<AppState>>, revision: Signal<u64>) {
    let window = match web_sys::window() {
        Some(w) => w,
        None => return,
    };
    let document = match window.document() {
        Some(d) => d,
        None => return,
    };
    let input: web_sys::HtmlInputElement = match document.create_element("input") {
        Ok(el) => el.unchecked_into(),
        Err(_) => return,
    };
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
        let reader = match web_sys::FileReader::new() {
            Ok(r) => r,
            Err(_) => return,
        };
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
            let model = Model::new(doc, Some(filename.clone()));
            let mut st = app3.borrow_mut();
            st.add_tab(TabState::with_model(model));
            drop(st);
            revision3 += 1;
        }) as Box<dyn FnMut(web_sys::Event)>);
        reader.set_onload(Some(onload.as_ref().unchecked_ref()));
        onload.forget();
        reader.read_as_text(&file).ok();
    }) as Box<dyn FnMut(web_sys::Event)>);
    input.set_onchange(Some(onchange.as_ref().unchecked_ref()));
    onchange.forget();
    input.click();
}

/// Toolbar layout: 2-column grid matching the Python/Qt version.
/// Each entry is (row, col, primary_tool, alternates).
/// Slots with alternates show the current alternate and support long-press to switch.
const TOOLBAR_SLOTS: &[(usize, usize, &[ToolKind])] = &[
    (0, 0, &[ToolKind::Selection]),
    (0, 1, &[ToolKind::DirectSelection, ToolKind::GroupSelection]),
    (1, 0, &[ToolKind::Pen]),
    (1, 1, &[ToolKind::Pencil]),
    (2, 0, &[ToolKind::Text, ToolKind::TextOnPath]),
    (2, 1, &[ToolKind::Line]),
    (3, 0, &[ToolKind::Rect, ToolKind::Polygon]),
];

/// Long-press threshold in milliseconds.
const LONG_PRESS_MS: i32 = 500;

/// SVG path data for each tool icon (28x28 viewBox, matching Python toolbar.py).
/// Uses rgb(204,204,204) instead of #ccc to avoid Rust 2021 literal prefix issues.
const IC: &str = "rgb(204,204,204)";

fn toolbar_svg_icon(kind: ToolKind) -> String {
    let c = IC;
    match kind {
        // Filled arrow cursor
        ToolKind::Selection => format!(
            r#"<path d="M5,2 L5,24 L10,18 L15,26 L18,24 L13,16 L20,16 Z" fill="{c}" stroke="{c}" stroke-width="1"/>"#),
        // Outline arrow cursor
        ToolKind::DirectSelection => format!(
            r#"<path d="M5,2 L5,24 L10,18 L15,26 L18,24 L13,16 L20,16 Z" fill="none" stroke="{c}" stroke-width="1"/>"#),
        // Outline arrow + plus badge
        ToolKind::GroupSelection => format!(
            r#"<path d="M5,2 L5,24 L10,18 L15,26 L18,24 L13,16 L20,16 Z" fill="none" stroke="{c}" stroke-width="1"/><line x1="20" y1="20" x2="27" y2="20" stroke="{c}" stroke-width="1.5"/><line x1="23.5" y1="16.5" x2="23.5" y2="23.5" stroke="{c}" stroke-width="1.5"/>"#),
        // Pen nib
        ToolKind::Pen => format!(
            r#"<path d="M8,24 L10,18 L14,4 L18,4 L22,18 L24,24 L16,20 Z" fill="none" stroke="{c}" stroke-width="1.5"/><line x1="16" y1="10" x2="16" y2="20" stroke="{c}" stroke-width="1.5"/>"#),
        // Pencil
        ToolKind::Pencil => format!(
            r#"<path d="M6,22 L20,8 L24,4 L26,6 L22,10 L8,24 Z" fill="none" stroke="{c}" stroke-width="1.5"/><line x1="6" y1="22" x2="4" y2="26" stroke="{c}" stroke-width="1.5"/><line x1="4" y1="26" x2="8" y2="24" stroke="{c}" stroke-width="1.5"/>"#),
        // T letter
        ToolKind::Text => format!(
            r#"<text x="4" y="22" font-family="sans-serif" font-size="18" font-weight="bold" fill="{c}">T</text>"#),
        // T + wavy path
        ToolKind::TextOnPath => format!(
            r#"<text x="2" y="18" font-family="sans-serif" font-size="14" font-weight="bold" fill="{c}">T</text><path d="M12,20 C16,8 22,24 26,12" fill="none" stroke="{c}" stroke-width="1"/>"#),
        // Diagonal line with endpoint dots
        ToolKind::Line => format!(
            r#"<line x1="4" y1="24" x2="24" y2="4" stroke="{c}" stroke-width="1.5"/><circle cx="4" cy="24" r="3" fill="none" stroke="{c}" stroke-width="1.5"/><circle cx="24" cy="4" r="3" fill="none" stroke="{c}" stroke-width="1.5"/>"#),
        // Rectangle
        ToolKind::Rect => format!(
            r#"<rect x="4" y="4" width="20" height="20" fill="none" stroke="{c}" stroke-width="1.5"/>"#),
        // Hexagon (cx=14, cy=14, r=11, 6 sides, -90° start)
        ToolKind::Polygon => format!(
            r#"<path d="M14,3 L23.5,8.5 L23.5,19.5 L14,25 L4.5,19.5 L4.5,8.5 Z" fill="none" stroke="{c}" stroke-width="1.5"/>"#),
    }
}

#[component]
pub fn App() -> Element {
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
                let tab = st.tab_mut();
                if let Some(tool) = tab.tools.get_mut(&kind) {
                    tool.on_press(&mut tab.model, cx, cy, shift, alt);
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
                let tab = st.tab_mut();
                if let Some(tool) = tab.tools.get_mut(&kind) {
                    tool.on_move(&mut tab.model, cx, cy, shift, dragging);
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
                let tab = st.tab_mut();
                if let Some(tool) = tab.tools.get_mut(&kind) {
                    tool.on_release(&mut tab.model, cx, cy, shift, alt);
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
                let tab = st.tab_mut();
                if let Some(tool) = tab.tools.get_mut(&kind) {
                    tool.on_double_click(&mut tab.model, cx, cy);
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
                // --- Modifier shortcuts ---
                Key::Character(ref c) if (c == "z" || c == "Z") && cmd => {
                    evt.prevent_default();
                    if mods.shift() {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            st.tab_mut().model.redo();
                        }));
                    } else {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            st.tab_mut().model.undo();
                        }));
                    }
                }
                Key::Character(ref c) if (c == "c" || c == "C") && cmd => {
                    evt.prevent_default();
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        // Write SVG to system clipboard
                        if let Some(svg) = selection_to_svg(st) {
                            clipboard_write(svg);
                        }
                        // Also update internal clipboard
                        let tab = st.tab();
                        let doc = tab.model.document();
                        let mut elements = Vec::new();
                        for es in &doc.selection {
                            if let Some(elem) = doc.get_element(&es.path) {
                                elements.push(elem.clone());
                            }
                        }
                        st.tab_mut().clipboard = elements;
                    }));
                }
                Key::Character(ref c) if (c == "x" || c == "X") && cmd => {
                    evt.prevent_default();
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        // Write SVG to system clipboard
                        if let Some(svg) = selection_to_svg(st) {
                            clipboard_write(svg);
                        }
                        // Update internal clipboard and delete
                        let tab = st.tab();
                        let doc = tab.model.document();
                        let mut elements = Vec::new();
                        for es in &doc.selection {
                            if let Some(elem) = doc.get_element(&es.path) {
                                elements.push(elem.clone());
                            }
                        }
                        let tab = st.tab_mut();
                        tab.clipboard = elements;
                        tab.model.snapshot();
                        let new_doc = tab.model.document().delete_selection();
                        tab.model.set_document(new_doc);
                    }));
                }
                Key::Character(ref c) if (c == "v" || c == "V") && cmd => {
                    evt.prevent_default();
                    let offset = if mods.shift() { 0.0 } else { PASTE_OFFSET };
                    // Try async clipboard read first, fall back to internal
                    clipboard_read_and_paste(
                        app_for_keys.clone(),
                        revision_for_keys.clone(),
                        offset,
                    );
                }
                Key::Character(ref c) if (c == "a" || c == "A") && cmd => {
                    evt.prevent_default();
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        Controller::select_all(&mut st.tab_mut().model);
                    }));
                }
                Key::Character(ref c) if (c == "2") && cmd => {
                    evt.prevent_default();
                    if mods.alt() {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            st.tab_mut().model.snapshot();
                            Controller::unlock_all(&mut st.tab_mut().model);
                        }));
                    } else {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            st.tab_mut().model.snapshot();
                            Controller::lock_selection(&mut st.tab_mut().model);
                        }));
                    }
                }
                Key::Character(ref c) if (c == "s" || c == "S") && cmd => {
                    evt.prevent_default();
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        let tab = st.tab_mut();
                        let svg = document_to_svg(tab.model.document());
                        let filename = if tab.model.filename.ends_with(".svg") {
                            tab.model.filename.clone()
                        } else {
                            format!("{}.svg", tab.model.filename)
                        };
                        download_file(&filename, &svg);
                        tab.model.mark_saved();
                    }));
                }
                Key::Character(ref c) if (c == "o" || c == "O") && cmd => {
                    evt.prevent_default();
                    open_file_dialog(app_for_keys.clone(), revision_for_keys.clone());
                }
                Key::Character(ref c) if (c == "n" || c == "N") && cmd => {
                    evt.prevent_default();
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.add_tab(TabState::new());
                    }));
                }
                Key::Character(ref c) if (c == "w" || c == "W") && cmd => {
                    evt.prevent_default();
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        let idx = st.active_tab;
                        st.close_tab(idx);
                    }));
                }
                Key::Character(ref c) if (c == "g" || c == "G") && cmd => {
                    evt.prevent_default();
                    if mods.shift() {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            st.tab_mut().model.snapshot();
                            Controller::ungroup_selection(&mut st.tab_mut().model);
                        }));
                    } else {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            st.tab_mut().model.snapshot();
                            Controller::group_selection(&mut st.tab_mut().model);
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
                        let tab = st.tab_mut();
                        if let Some(tool) = tab.tools.get_mut(&kind) {
                            tool.on_key(&mut tab.model, "Escape");
                        }
                    }));
                }
                Key::Delete | Key::Backspace => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        let tab = st.tab_mut();
                        tab.model.snapshot();
                        let new_doc = tab.model.document().delete_selection();
                        tab.model.set_document(new_doc);
                    }));
                }
                _ => {}
            }
        }
    };

    // --- Tool buttons with shared slots ---
    // Track which alternate is visible in each shared slot.
    // Key: index into TOOLBAR_SLOTS for slots with alternates.
    let mut slot_alternates = use_signal(|| {
        let mut map = HashMap::<usize, usize>::new();
        for (i, (_r, _c, tools)) in TOOLBAR_SLOTS.iter().enumerate() {
            if tools.len() > 1 {
                map.insert(i, 0); // default to first alternate
            }
        }
        map
    });
    // Signal for which slot is showing a long-press popup (-1 = none)
    let mut popup_slot = use_signal(|| Option::<usize>::None);

    let active_tool = app.borrow().active_tool;

    // If active tool is an alternate that's not currently visible, update the slot
    for (si, (_r, _c, tools)) in TOOLBAR_SLOTS.iter().enumerate() {
        if tools.len() > 1 {
            if let Some(pos) = tools.iter().position(|&t| t == active_tool) {
                let current = *slot_alternates.read().get(&si).unwrap_or(&0);
                if current != pos {
                    slot_alternates.write().insert(si, pos);
                }
            }
        }
    }

    let tool_buttons: Vec<Result<VNode, RenderError>> = TOOLBAR_SLOTS
        .iter()
        .enumerate()
        .map(|(si, &(row, col, tools))| {
            let act = act.clone();
            let alt_idx = *slot_alternates.read().get(&si).unwrap_or(&0);
            let kind = tools[alt_idx.min(tools.len() - 1)];
            let has_alternates = tools.len() > 1;
            let is_active = tools.contains(&active_tool);
            let bg = if is_active { "#505050" } else { "transparent" };

            // Build SVG with optional alternate triangle indicator
            let svg_inner = toolbar_svg_icon(kind);
            let triangle = if has_alternates {
                format!(r#"<path d="M28,28 L23,28 L28,23 Z" fill="{IC}"/>"#)
            } else {
                String::new()
            };
            let svg_html = format!(
                r#"<svg viewBox="0 0 28 28" width="28" height="28" xmlns="http://www.w3.org/2000/svg">{svg_inner}{triangle}</svg>"#
            );
            let grid_col = col + 1;
            let grid_row = row + 1;

            rsx! {
                div {
                    key: "slot-{si}",
                    style: "grid-column:{grid_col}; grid-row:{grid_row}; width:32px; height:32px; background:{bg}; cursor:pointer; display:flex; align-items:center; justify-content:center; border-radius:2px; position:relative;",
                    title: "{kind.label()}",
                    onmousedown: {
                        let act = act.clone();
                        move |evt: Event<MouseData>| {
                            evt.stop_propagation();
                            if has_alternates {
                                // Start long-press timer via setTimeout
                                let slot_idx = si;
                                let mut popup = popup_slot.clone();
                                let Some(window) = web_sys::window() else { return; };
                                let cb = Closure::once(move || {
                                    popup.set(Some(slot_idx));
                                });
                                window.set_timeout_with_callback_and_timeout_and_arguments_0(
                                    cb.as_ref().unchecked_ref(), LONG_PRESS_MS
                                ).ok();
                                cb.forget();
                            }
                            // Normal click: select this tool
                            (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                st.active_tool = kind;
                            }));
                        }
                    },
                    onmouseup: move |_| {
                        // If popup hasn't shown yet, cancel by ignoring
                        // (timer will fire but popup will be dismissed on next click)
                    },
                    dangerous_inner_html: "{svg_html}",
                }
            }
        })
        .collect();

    // Build popup for long-press alternate selection
    let popup_node: Option<Result<VNode, RenderError>> = popup_slot().map(|si| {
        let (_row, col, tools) = TOOLBAR_SLOTS[si];
        let items: Vec<Result<VNode, RenderError>> = tools.iter().enumerate().map(|(ti, &tool_kind)| {
            let act = act.clone();
            let label = tool_kind.label();
            let is_current = tool_kind == active_tool;
            let bg = if is_current { "#606060" } else { "#4a4a4a" };
            rsx! {
                div {
                    class: "jas-tool-popup-item",
                    style: "padding:4px 10px; cursor:pointer; font-size:12px; color:#ccc; white-space:nowrap; background:{bg}; border-radius:2px;",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        slot_alternates.write().insert(si, ti);
                        popup_slot.set(None);
                        (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                            st.active_tool = tool_kind;
                        }));
                    },
                    "{label}"
                }
            }
        }).collect();
        // Position the popup next to the toolbar
        let top = _row as u32 * 34 + 4;
        let left = if col == 0 { 72 } else { 72 };
        rsx! {
            div {
                style: "position:fixed; top:{top}px; left:{left}px; background:#4a4a4a; border:1px solid #666; box-shadow:2px 2px 8px rgba(0,0,0,0.3); z-index:2000; padding:4px; border-radius:4px;",
                for item in items {
                    {item}
                }
            }
        }
    });

    // --- Tab bar ---
    let borrowed = app.borrow();
    let tab_info: Vec<(usize, String, bool)> = borrowed.tabs.iter().enumerate().map(|(i, tab)| {
        (i, tab.model.filename.clone(), i == borrowed.active_tab)
    }).collect();
    let num_tabs = borrowed.tabs.len();
    drop(borrowed);

    let tab_buttons: Vec<Result<VNode, RenderError>> = tab_info.iter().map(|(i, name, is_active)| {
        let idx = *i;
        let act = act.clone();
        let bg = if *is_active { "#fff" } else { "#e0e0e0" };
        let border_bottom = if *is_active { "2px solid #fff" } else { "2px solid #ccc" };
        let closable = num_tabs > 1;
        let display_name = name.clone();
        rsx! {
            div {
                key: "tab-{idx}",
                style: "display:inline-flex; align-items:center; padding:4px 8px; margin-right:1px; background:{bg}; border:1px solid #ccc; border-bottom:{border_bottom}; cursor:pointer; font-size:12px; user-select:none;",
                onclick: move |_| {
                    let act = act.clone();
                    (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                        st.active_tab = idx;
                    }));
                },
                span { "{display_name}" }
                if closable {
                    {
                        let act2 = act.clone();
                        rsx! {
                            span {
                                style: "margin-left:6px; color:#888; cursor:pointer; font-size:14px; line-height:1;",
                                onclick: move |evt: Event<MouseData>| {
                                    evt.stop_propagation();
                                    (act2.borrow_mut())(Box::new(move |st: &mut AppState| {
                                        st.close_tab(idx);
                                    }));
                                },
                                "\u{00d7}"
                            }
                        }
                    }
                }
            }
        }
    }).collect();

    // --- Menu dispatch ---
    // Shared dispatch function for menu items (avoids duplicating keyboard handler logic).
    let dispatch = {
        let act = act.clone();
        let app_for_menu = app.clone();
        let revision_for_menu = revision.clone();
        Rc::new(move |cmd: &str| {
            match cmd {
                "new" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.add_tab(TabState::new());
                    }));
                }
                "open" => {
                    open_file_dialog(app_for_menu.clone(), revision_for_menu.clone());
                }
                "save" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        let tab = st.tab_mut();
                        let svg = document_to_svg(tab.model.document());
                        let filename = if tab.model.filename.ends_with(".svg") {
                            tab.model.filename.clone()
                        } else {
                            format!("{}.svg", tab.model.filename)
                        };
                        download_file(&filename, &svg);
                        tab.model.mark_saved();
                    }));
                }
                "close" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        let idx = st.active_tab;
                        st.close_tab(idx);
                    }));
                }
                "undo" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.tab_mut().model.undo();
                    }));
                }
                "redo" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.tab_mut().model.redo();
                    }));
                }
                "cut" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(svg) = selection_to_svg(st) {
                            clipboard_write(svg);
                        }
                        let tab = st.tab();
                        let doc = tab.model.document();
                        let elements: Vec<GeoElement> = doc.selection.iter()
                            .filter_map(|es| doc.get_element(&es.path).cloned())
                            .collect();
                        let tab = st.tab_mut();
                        tab.clipboard = elements;
                        tab.model.snapshot();
                        let new_doc = tab.model.document().delete_selection();
                        tab.model.set_document(new_doc);
                    }));
                }
                "copy" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(svg) = selection_to_svg(st) {
                            clipboard_write(svg);
                        }
                        let tab = st.tab();
                        let doc = tab.model.document();
                        let elements: Vec<GeoElement> = doc.selection.iter()
                            .filter_map(|es| doc.get_element(&es.path).cloned())
                            .collect();
                        st.tab_mut().clipboard = elements;
                    }));
                }
                "paste" => {
                    clipboard_read_and_paste(
                        app_for_menu.clone(), revision_for_menu.clone(), PASTE_OFFSET,
                    );
                }
                "paste_in_place" => {
                    clipboard_read_and_paste(
                        app_for_menu.clone(), revision_for_menu.clone(), 0.0,
                    );
                }
                "select_all" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        Controller::select_all(&mut st.tab_mut().model);
                    }));
                }
                "delete" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        let tab = st.tab_mut();
                        tab.model.snapshot();
                        let new_doc = tab.model.document().delete_selection();
                        tab.model.set_document(new_doc);
                    }));
                }
                "group" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.tab_mut().model.snapshot();
                        Controller::group_selection(&mut st.tab_mut().model);
                    }));
                }
                "ungroup" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.tab_mut().model.snapshot();
                        Controller::ungroup_selection(&mut st.tab_mut().model);
                    }));
                }
                "ungroup_all" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.tab_mut().model.snapshot();
                        Controller::ungroup_all(&mut st.tab_mut().model);
                    }));
                }
                "lock" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.tab_mut().model.snapshot();
                        Controller::lock_selection(&mut st.tab_mut().model);
                    }));
                }
                "unlock_all" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.tab_mut().model.snapshot();
                        Controller::unlock_all(&mut st.tab_mut().model);
                    }));
                }
                _ => {}
            }
        })
    };

    // --- Menu bar data ---
    let mut open_menu = use_signal(|| Option::<String>::None);

    let menus = super::menu::MENU_BAR;

    // Pre-build each menu dropdown as a complete VNode
    let menu_nodes: Vec<Result<VNode, RenderError>> = menus.iter().enumerate().map(|(mi, (menu_name, items))| {
        let menu_name_str = menu_name.to_string();
        let menu_name_str2 = menu_name_str.clone();
        let is_open = open_menu() == Some(menu_name_str.clone());
        let dispatch = dispatch.clone();
        let mut open_menu_sig = open_menu.clone();

        // Pre-build item nodes for this menu
        let item_nodes: Vec<Result<VNode, RenderError>> = if is_open {
            items.iter().map(|&(label, cmd, shortcut)| {
                if label == "---" {
                    rsx! {
                        div {
                            style: "height:1px; background:#ddd; margin:4px 8px;",
                        }
                    }
                } else {
                    let dispatch = dispatch.clone();
                    let cmd = cmd.to_string();
                    let mut open_menu_sig2 = open_menu_sig.clone();
                    rsx! {
                        div {
                            class: "jas-menu-item",
                            style: "padding:4px 24px 4px 16px; cursor:pointer; font-size:13px; display:flex; justify-content:space-between; white-space:nowrap; border-radius:3px; margin:0 4px;",
                            onmousedown: move |evt: Event<MouseData>| {
                                evt.stop_propagation();
                                dispatch(&cmd);
                                open_menu_sig2.set(None);
                            },
                            span { "{label}" }
                            span {
                                style: "color:#999; margin-left:24px; font-size:12px;",
                                "{shortcut}"
                            }
                        }
                    }
                }
            }).collect()
        } else {
            Vec::new()
        };

        let bg = if is_open { "#d0d0d0" } else { "transparent" };
        rsx! {
            div {
                key: "menu-{mi}",
                style: "position:relative; display:inline-block;",
                div {
                    class: "jas-menu-title",
                    style: "padding:3px 8px; cursor:pointer; font-size:13px; user-select:none; border-radius:3px; background:{bg};",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        let name = menu_name_str2.clone();
                        if open_menu() == Some(name.clone()) {
                            open_menu_sig.set(None);
                        } else {
                            open_menu_sig.set(Some(name));
                        }
                    },
                    "{menu_name_str}"
                }
                if is_open {
                    div {
                        style: "position:absolute; top:100%; left:0; background:#fff; border:1px solid #ccc; box-shadow:2px 2px 8px rgba(0,0,0,0.15); min-width:200px; z-index:1000; padding:4px 0;",
                        for node in item_nodes {
                            {node}
                        }
                    }
                }
            }
        }
    }).collect();

    // Close menu/popup when clicking anywhere outside
    let on_main_mousedown = {
        let mut open_menu_sig = open_menu.clone();
        move |_: Event<MouseData>| {
            open_menu_sig.set(None);
            popup_slot.set(None);
        }
    };

    rsx! {
        style { r#"
            .jas-menu-title:hover {{ background: #d0d0d0; }}
            .jas-menu-item:hover {{ background: #e8e8e8; }}
            .jas-tool-popup-item:hover {{ background: #606060 !important; }}
        "#  }
        div {
            tabindex: "0",
            onkeydown: on_keydown,
            onmousedown: move |_| {
                popup_slot.set(None);
            },
            style: "display:flex; height:100vh; outline:none; font-family:sans-serif;",

            // Toolbar
            div {
                style: "width:72px; background:#3c3c3c; border-right:1px solid #555; padding:4px 2px; display:grid; grid-template-columns:32px 32px; grid-auto-rows:32px; gap:2px; justify-content:center; align-content:start;",
                onmousedown: move |_| {
                    // Close menu dropdowns when clicking on toolbar
                    open_menu.set(None);
                },
                for btn in tool_buttons {
                    {btn}
                }
            }

            // Tool alternate popup (shown on long-press)
            if let Some(popup) = popup_node {
                {popup}
            }

            // Main area (menu + tabs + canvas)
            div {
                style: "flex:1; display:flex; flex-direction:column; overflow:hidden;",
                onmousedown: on_main_mousedown,

                // Menu bar
                div {
                    style: "display:flex; background:#f0f0f0; border-bottom:1px solid #ddd; padding:0 4px; min-height:24px; align-items:center;",
                    for node in menu_nodes {
                        {node}
                    }
                }

                // Tab bar
                div {
                    style: "display:flex; background:#e8e8e8; border-bottom:1px solid #ccc; padding:2px 4px 0; min-height:28px; align-items:flex-end;",
                    for btn in tab_buttons {
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
}
