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
use crate::geometry::element::{translate_element, Element as GeoElement};
use crate::geometry::svg::{document_to_svg, svg_to_document};
use crate::tools::direct_selection_tool::DirectSelectionTool;
use crate::tools::group_selection_tool::GroupSelectionTool;
use crate::tools::line_tool::LineTool;
use crate::tools::pen_tool::PenTool;
use crate::tools::add_anchor_point_tool::AddAnchorPointTool;
use crate::tools::delete_anchor_point_tool::DeleteAnchorPointTool;
use crate::tools::anchor_point_tool::AnchorPointTool;
use crate::tools::pencil_tool::PencilTool;
use crate::tools::path_eraser_tool::PathEraserTool;
use crate::tools::smooth_tool::SmoothTool;
use crate::tools::polygon_tool::PolygonTool;
use crate::tools::star_tool::StarTool;
use crate::tools::rect_tool::RectTool;
use crate::tools::rounded_rect_tool::RoundedRectTool;
use crate::tools::lasso_tool::LassoTool;
use crate::tools::selection_tool::SelectionTool;
use crate::tools::type_tool::TypeTool;
use crate::tools::type_on_path_tool::TypeOnPathTool;
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
        tools.insert(ToolKind::AddAnchorPoint, Box::new(AddAnchorPointTool::new()));
        tools.insert(ToolKind::DeleteAnchorPoint, Box::new(DeleteAnchorPointTool::new()));
        tools.insert(ToolKind::AnchorPoint, Box::new(AnchorPointTool::new()));
        tools.insert(ToolKind::Pencil, Box::new(PencilTool::new()));
        tools.insert(ToolKind::PathEraser, Box::new(PathEraserTool::new()));
        tools.insert(ToolKind::Smooth, Box::new(SmoothTool::new()));
        tools.insert(ToolKind::Type, Box::new(TypeTool::new()));
        tools.insert(ToolKind::TypeOnPath, Box::new(TypeOnPathTool::new()));
        tools.insert(ToolKind::Rect, Box::new(RectTool::new()));
        tools.insert(ToolKind::RoundedRect, Box::new(RoundedRectTool::new()));
        tools.insert(ToolKind::Polygon, Box::new(PolygonTool::new()));
        tools.insert(ToolKind::Star, Box::new(StarTool::new()));
        tools.insert(ToolKind::Line, Box::new(LineTool::new()));
        tools.insert(ToolKind::Lasso, Box::new(LassoTool::new()));
        Self { model, tools, clipboard: Vec::new() }
    }
}

/// Shared application state.
struct AppState {
    tabs: Vec<TabState>,
    active_tab: usize,
    active_tool: ToolKind,
    dock_layout: super::dock::DockLayout,
}

impl AppState {
    fn new() -> Self {
        Self {
            tabs: vec![],
            active_tab: 0,
            active_tool: ToolKind::Selection,
            dock_layout: super::dock::DockLayout::default_layout(),
        }
    }

    fn tab(&self) -> Option<&TabState> {
        self.tabs.get(self.active_tab)
    }

    fn tab_mut(&mut self) -> Option<&mut TabState> {
        self.tabs.get_mut(self.active_tab)
    }

    fn add_tab(&mut self, tab: TabState) {
        self.tabs.push(tab);
        self.active_tab = self.tabs.len() - 1;
    }

    fn close_tab(&mut self, index: usize) {
        if index >= self.tabs.len() {
            return;
        }
        self.tabs.remove(index);
        if self.tabs.is_empty() {
            self.active_tab = 0;
        } else if self.active_tab >= self.tabs.len() {
            self.active_tab = self.tabs.len() - 1;
        } else if self.active_tab > index {
            self.active_tab -= 1;
        }
    }

    fn set_tool(&mut self, kind: ToolKind) {
        if let Some(tab) = self.tabs.get_mut(self.active_tab) {
            let active = self.active_tool;
            if let Some(tool) = tab.tools.get_mut(&active) {
                tool.deactivate(&mut tab.model);
            }
        }
        self.active_tool = kind;
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
        // Sync canvas internal resolution to its CSS layout size
        let cw = canvas.client_width() as u32;
        let ch = canvas.client_height() as u32;
        if cw > 0 && ch > 0 && (canvas.width() != cw || canvas.height() != ch) {
            canvas.set_width(cw);
            canvas.set_height(ch);
        }
        let ctx: CanvasRenderingContext2d = match canvas.get_context("2d") {
            Ok(Some(ctx)) => ctx.unchecked_into(),
            _ => return,
        };
        let w = canvas.width() as f64;
        let h = canvas.height() as f64;
        let tab = match self.tab() {
            Some(t) => t,
            None => return,
        };
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
        if st.tab().is_none() {
            return;
        }

        // If a tool is in a text-editing session, send the plain text there.
        let active_kind = st.active_tool;
        let editing = st
            .tab()
            .and_then(|tab| tab.tools.get(&active_kind).map(|t| t.is_editing()))
            .unwrap_or(false);
        if editing {
            if let Some(text) = clipboard_text.clone() {
                let tab = st.tab_mut().unwrap();
                if let Some(tool) = tab.tools.get_mut(&active_kind) {
                    if tool.paste_text(&mut tab.model, &text) {
                        drop(st);
                        revision += 1;
                        return;
                    }
                }
            }
        }

        let tab = st.tab_mut().unwrap();

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
                            new_selection.push(ElementSelection::all(path));
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
            new_selection.push(ElementSelection::all(path));
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
    let tab = st.tab()?;
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
    (1, 0, &[ToolKind::Pen, ToolKind::AddAnchorPoint, ToolKind::DeleteAnchorPoint, ToolKind::AnchorPoint]),
    (1, 1, &[ToolKind::Pencil, ToolKind::PathEraser, ToolKind::Smooth]),
    (2, 0, &[ToolKind::Type, ToolKind::TypeOnPath]),
    (2, 1, &[ToolKind::Line]),
    (3, 0, &[ToolKind::Rect, ToolKind::RoundedRect, ToolKind::Polygon, ToolKind::Star]),
    (3, 1, &[ToolKind::Lasso]),
];

/// Long-press threshold in milliseconds.
const LONG_PRESS_MS: i32 = 500;

/// SVG path data for each tool icon (28x28 viewBox, matching Python toolbar.py).
/// Uses rgb(204,204,204) instead of #ccc to avoid Rust 2021 literal prefix issues.
const IC: &str = "rgb(204,204,204)";

fn toolbar_svg_icon(kind: ToolKind) -> String {
    let c = IC;
    match kind {
        // Black arrow with white border
        ToolKind::Selection => format!(
            r#"<path d="M5,2 L5,24 L10,18 L15,26 L18,24 L13,16 L20,16 Z" fill="black" stroke="white" stroke-width="1"/>"#),
        // White arrow with black border
        ToolKind::DirectSelection => format!(
            r#"<path d="M5,2 L5,24 L10,18 L15,26 L18,24 L13,16 L20,16 Z" fill="white" stroke="black" stroke-width="1"/>"#),
        // White arrow with black border + plus badge
        ToolKind::GroupSelection => format!(
            r#"<path d="M5,2 L5,24 L10,18 L15,26 L18,24 L13,16 L20,16 Z" fill="white" stroke="black" stroke-width="1"/><line x1="20" y1="20" x2="27" y2="20" stroke="black" stroke-width="1.5"/><line x1="23.5" y1="16.5" x2="23.5" y2="23.5" stroke="black" stroke-width="1.5"/>"#),
        // Pen nib (from SVG, scaled from 256x256 viewBox to 28x28)
        ToolKind::Pen => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M163.07,190.51l12.54,19.52-90.68,45.96-12.46-28.05C58.86,195.29,32.68,176.45.13,161.51L0,4.58C0,2.38,2.8-.28,4.11-.37s3.96.45,5.31,1.34l85.42,56.33,48.38,32.15c-7.29,34.58-4.05,71.59,19.86,101.06ZM61.7,49.58L23.48,24.2l42.08,78.11c7.48.17,14.18,2.89,17.49,8.79s3.87,13.16-.95,18.87c-6.36,7.54-17.67,8.57-24.72,3.04-7.83-6.14-9.41-16.13-2.86-24.95L12.09,30.4l.44,69.96-.29,54.31c25.62,11.65,46.88,28.2,61.53,51.84l64.8-33.24c-11.11-25.08-13.69-50.63-8.47-78.19L61.7,49.58Z" fill="rgb(204,204,204)"/><path d="M61.7,49.58l68.41,45.5c-5.22,27.56-2.64,53.1,8.47,78.19l-64.8,33.24c-14.66-23.64-35.91-40.19-61.53-51.84l.29-54.31-.44-69.96,42.43,77.66c-6.55,8.82-4.96,18.8,2.86,24.95,7.05,5.53,18.35,4.49,24.72-3.04,4.82-5.71,4.27-12.96.95-18.87s-10.01-8.62-17.49-8.79L23.48,24.2l38.22,25.38Z" fill="#3c3c3c"/></g>"##.to_string()
        },
        // Add Anchor Point (pen nib + plus sign, from SVG scaled 256→28)
        ToolKind::AddAnchorPoint => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M170.82,209.27l-88.08,46.73-10.99-25.31C60.04,197.72,31.98,175.62.51,162.2L.07,55.68,0,7.02C0,5.03.62,2.32,1.66,1.26S6.93-.46,8.2.39l130.44,88.12c-4.9,32.54-4.3,66.45,14.46,94.39l17.7,26.39Z" fill="rgb(204,204,204)"/><path d="M126.44,94.04c-2.22,11.75-2.88,21.93-2.47,32.64.52,16.1,3.8,30.8,11.11,46.23l-62.86,33.45c-14.38-22.81-34.23-39.94-60.13-51.08l-.62-125.03,41.81,77.76c-5.22,8.02-5.31,16.36.31,22.49,6.1,6.66,15.3,7.1,23.05,1.74,6.57-4.54,7.84-12.25,5.04-18.88s-8.7-11.19-17.14-10.35L22.85,24.63l103.56,69.4Z" fill="#3c3c3c"/><path d="M232.87,153.61c-3.47,3.11-8.74,5.8-13.86,7.8l-18.34-34.03-33.68,18.09-7.64-13.38,34.16-18.2-18.46-35.15,13.59-7.64,18.83,35.42,33.38-17.99,7.32,13.45-33.3,18.14,17.99,33.46Z" fill="rgb(204,204,204)"/></g>"##.to_string()
        },
        // Anchor Point (pen nib + < chevron, from SVG scaled 256→28)
        ToolKind::AnchorPoint => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M83.11,256l-17.21-39.82c-14.6-25.62-37.76-42.26-64.64-54.74l-.55-51.33L0,6.71C-.02,4.87,1.44,1.8,2.62.77s5.12-1.03,6.66.01l128.83,87.39-2.52,25.97c-2.03,20.93,1.76,44.01,13.52,61.83l21.9,33.2s-87.9,46.83-87.9,46.83Z" fill="rgb(204,204,204)"/><path d="M125.27,93.8L23.13,24.57l39.47,73.45c1.29,2.43,4.09,4.31,6.62,5.06,10.87,1.39,15.9,13.21,12.45,22.55-3.45,9.33-16.08,13.17-24.38,7.8-8.31-5.38-10.28-16.62-3.7-25.38L12.6,30.88l.27,123.04c23.7,11.46,47.42,29.86,60.53,52.12l60.89-32.47c-10.97-26.18-11.95-50.76-9.02-79.77Z" fill="#3c3c3c"/><path d="M179.5,120.04l32.26,60.93-12.56,6.65-39.41-73.7,73.14-38.92c2.57,3.76,4.72,7.63,7.25,12.71l-60.67,32.35h0Z" fill="rgb(204,204,204)"/></g>"##.to_string()
        },
        // Delete Anchor Point (pen nib + minus sign, from SVG scaled 256→28)
        ToolKind::DeleteAnchorPoint => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M171.16,209.05l-87.84,46.95c-3.95-8.26-7.66-16.33-10.98-24.89-13.5-34.82-37.51-53.77-71.54-69.91l-.4-54.61L0,6.21C0,3.95,2.53.66,4.05.16s4.42.21,6.33,1.51l127.62,86.16c-.17,5.51-.81,10.43-1.56,16.17-3.3,25.08,1.31,50.95,12.81,73.57l21.9,31.48Z" fill="rgb(204,204,204)"/><path d="M126.23,94.28c-1.59,10.88-2.27,20.24-2.17,30.44.4,16.82,3.06,32.72,10.5,48.72l-61.27,32.7c-15.09-22.6-34.96-40.67-60.57-52.09l-.37-123.25,41.01,76.81c-5.22,7.79-5.06,16.71.29,22.63,6.52,7.2,16.36,7.25,24.09,1.18,5.95-4.67,6.35-12.24,4.2-18.37-2.55-7.28-9.14-10.98-17.57-11.7L23.73,25.13l102.5,69.14Z" fill="#3c3c3c"/><rect x="158.95" y="110.41" width="93.43" height="15.36" transform="translate(-31.37 110.38) rotate(-28)" fill="rgb(204,204,204)"/></g>"##.to_string()
        },
        // Pencil (from SVG, scaled from 256→28)
        ToolKind::Pencil => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M57.6,233.77l-51.77,22c-3.79,1.61-6.42-5.57-5.71-8.78l15.63-71.11c1.24-5.63,2.19-9.52,6.08-14.09L108.97,59.4l43.76-50.24c6.91-7.93,20.11-12.57,29.23-6.1,13.11,9.3,24.18,19.89,35.98,30.87,7.38,6.86,8.71,20.57,2.31,28.2l-28.29,33.69-107.57,127.08c-9.12,4.32-17.67,7-26.79,10.88Z" fill="rgb(204,204,204)"/><path d="M208.57,55.33c4.05-7.4-1.19-14.82-6.49-19.18l-25-20.58c-10.66-8.78-22.36,11.05-28.07,18.32,14.44,13.9,28.28,26.73,44.4,38.75,5.64-5.65,11.45-10.55,15.16-17.31Z" fill="#3c3c3c"/><path d="M70.01,189.48c-5.14.35-10.35,1.24-13.94-1.12-2.83-1.86-3.93-9.72-2.84-13.56l101.24-118.96c5.95,4.89,10.67,9.06,15.66,14.57l-100.12,119.07Z" fill="#3c3c3c"/><path d="M47.55,169.12c-3.85,1.45-9.72.32-12.69-2.27l41.55-49.37,32.56-37.99,29.83-34.98c3.62.1,6.99,3.72,8.64,7.09l-45.3,52.97-54.59,64.54Z" fill="#3c3c3c"/><path d="M161.36,111.12l-68.09,80.6c-4.52,5.34-8.33,9.99-13.72,15.13-3.1-3.37-5.1-10.15-1.03-14.97l97.51-115.25c3.44.45,8.52,3.68,8.25,6.56l-22.92,27.94Z" fill="#3c3c3c"/><path d="M71.47,214.03c-11.31,4.52-21.14,8.07-32.31,13.6l-17.23-13.26c.99-5.56,1.35-11.11,2.68-16.6l4.39-18.04c1.63-3.22,11.55-2.19,13.67.71,3.2,4.4,3.19,12.25,7.13,15.82,3.97,3.6,10.62.78,14.92,3.17s4.89,9.2,6.75,14.6Z" fill="white"/></g>"##.to_string()
        },
        // Path Eraser (rotated pencil from SVG, scaled from 256→28)
        ToolKind::PathEraser => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M169.86,33.13L243.34,1.82c3.43-1.46,6.39-2.97,9.92-.52,2.21,1.54,3.34,4.88,2.41,8.76l-19.31,80.53-108.02,125.71-27.98,31.2c-9.63,10.74-24.91,11.34-35.56,1.63l-28-25.52c-9.09-8.28-9.54-23.48-1.42-32.95l40.64-47.45,93.83-110.08Z" fill="rgb(204,204,204)"/><path d="M184.63,65.93c4.88.46,9.96.27,13.5,2.32,2.91,1.68,5.44,10.2,3.01,13.03l-84.89,99c-6.97-3.72-11.86-9.07-15.89-15.76l84.27-98.59Z" fill="#3c3c3c"/><path d="M44.69,212.9c-7.74-11.08,8.68-22.32,17.05-32.78l45.05,40.93-15.82,18.47c-8.77,10.24-21.21-2.39-26.77-7.31-6.96-6.17-14.12-11.58-19.52-19.31Z" fill="#3c3c3c"/><path d="M207.17,85.96c4.81-.22,8.54.77,12.85,3.59l-65.13,76.29-23.35,27c-3.91-1.36-6.44-4.06-8.62-7.89l84.25-98.98Z" fill="#3c3c3c"/><path d="M124.64,106.13l50.36-58.45c2.8,3.96,5.01,9.06,3.33,12.12-5.2,9.48-12.82,16.62-19.83,24.82l-62.56,73.21c-1.99,2.33-5.01,1.06-6.38.14-1.59-1.07-5.25-3.97-3.15-6.5,10.19-12.26,20.7-23.56,30.54-35.78l7.69-9.56Z" fill="#3c3c3c"/><path d="M183.88,41.54c8.08-4.67,16.32-7.31,24.34-10.36,12.84-4.88,5.89-4.25,24.42,10.2,2.91.33-5.31,35.45-6.97,35.87-3.37,3.03-13.57,1.84-14.92-2.22l-4.99-15-16.7-3.81c-4.53-1.03-4.11-9.11-5.17-14.68Z" fill="white"/><rect x="88.74" y="155.97" width="14.58" height="61.84" transform="translate(299.56 239.09) rotate(131.58)" fill="white"/></g>"##.to_string()
        },
        // Smooth tool (pencil with "S" lettering, from SVG scaled 256→28)
        ToolKind::Smooth => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M70.89,227.68L4.52,255.09c-3.64,1.5-5.43-6.66-4.68-9.88l17.55-75.22c7.36-9.61,14.58-17.27,22.29-26.35l91.35-107.59,13.18-14.76c10.19-11.42,24.53-9.65,35.35-.05l25.45,22.59c9.72,8.62,8.08,22.16-.02,31.72l-30.35,35.82-88.63,105.34c-4.48,5.32-8.1,8.07-15.12,10.97Z" fill="rgb(204,204,204)"/><path d="M66.39,191.49c-3.26,3.88-11.08.74-14.17.76-1.6-4.95-2.48-7.92-2.63-12.87l95.93-113.23c5.76,4.1,10.56,8.41,15.29,13.81l-48.81,57.26-45.61,54.27Z" fill="#3c3c3c"/><path d="M194.82,68.3c-4.33,5.25-7.97,9.61-12.6,14.2l-41.17-37.77c6.53-8.97,16.36-26.16,28.28-16.01l23.3,19.83c5.9,5.02,7.29,13.58,2.2,19.76Z" fill="#3c3c3c"/><path d="M32.69,171.62c2.34-2.12,3.21-5.15,5.44-7.75l48.58-56.78,44.96-52.22c3.29,1.06,6.3,3.36,7.96,6.88l-94.82,111.41c-3.41,1.69-7.52.06-12.12-1.54Z" fill="#3c3c3c"/><path d="M74.85,208.97c-1.9-3.51-4.54-7.82-3.2-11.46l62.67-74.53c3.87-4.6,7.33-8.43,11.21-12.99l21.07-24.77c2.92,2.31,5.6,2.99,7.52,5.41-6.28,11.18-14.37,19.01-22.27,28.37l-68.4,80.98c-2.77,3.28-5,5.52-8.61,8.99Z" fill="#3c3c3c"/><path d="M61.28,200.71c2.96,4.4,4.65,9.19,5.65,14.66l-31.21,13.46-15.61-12.98,6.37-34.74c3.86.45,10.27-.54,13.02,2.69,3.65,4.3,2.7,11.09,6.13,15.66,4.75,1.4,9.49.96,15.64,1.26Z" fill="white"/><path d="M210.2,175.94c11.48,9.34,49.63,12.78,45.49,46.07-1.19,9.56-7.61,19.79-18.27,24.04-14.69,5.85-30.81,4.47-45.37-1.23.47-4.68,1.55-7.93,3.11-11.67,9.5,3.79,19.58,5.53,29.64,3.42,8.68-1.82,13.82-8.17,14.43-16.16.65-8.55-3.33-15.19-11.76-19.01l-21.46-9.72c-11.6-5.25-18.43-15.52-18.34-27.89.08-11.69,6.68-22.34,18.54-27.37,14.4-6.11,31.49-4.4,45.49,2.87-.51,4.89-3.12,8.2-4.55,12.47-13.33-8.75-41.32-8.29-43.12,7.75-.73,6.5.91,12.14,6.17,16.42Z" fill="rgb(204,204,204)"/><path d="M183.23,206.16c1.36-3.22,8.17-1.51,11.39-.84,2.35,18.66-5.1,40.07-25.23,43.67-12.58,2.25-25.25-.94-32.47-11.28-6.04-8.66-10.11-20.45-8.36-31.26.55-3.39,10.52-3.41,12.41-.91,2.42,5.85,1.22,13.66,4.25,19.58,3.34,6.52,9.26,10.96,16.14,11.19,7.35.25,13.54-4.25,17.24-10.96,3.2-5.82,2.05-12.38,4.64-19.2Z" fill="rgb(204,204,204)"/></g>"##.to_string()
        },
        // Type tool — T glyph from assets/icons/type.svg, scaled from 256→28
        ToolKind::Type => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M156.78,197.66l-56.03-.18c-3.93-3.08-4.04-16.09.02-18.64,4.02-2.53,15.24,1.59,16.75-3.47l.29-96.22c-13.59-1.73-25.59-1.5-38.2-.19l-1.84,18.33c-6.36,1.3-11.83,1.26-18.54-.07-.74-13-1.05-25.04.15-38.87h137.24c1.18,13.75.97,25.84.13,38.9-6.65,1.37-12.09,1.27-18.54,0l-1.83-18.28c-12.65-1.26-24.67-1.46-38.15.18v97.73s18.59,1.88,18.59,1.88c1.2,5.78,1.58,10.49-.04,18.91Z" fill="rgb(204,204,204)"/></g>"##.to_string()
        },
        // Type on a Path tool — from assets/icons/type on a path.svg, scaled from 256→28
        ToolKind::TypeOnPath => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><path d="M146.65,143.92c.25,5.89-10.02,3.55-13.5-.15l-17.92-19.02c-3-3.18-.32-7.5,1-9.94,1.7-3.12,8.6,2.51,10.49,1.07,15.2-12.87,29.41-28.44,43.64-43.37,2.98-3.13-2.77-7.24-4.77-8.68-6.3-4.54-20.83,10.64-19.23-6.09.62-6.48,13.52-18.6,20.25-12.75,18.17,15.8,34.79,33.15,50.51,50.94,1.89,6.41-11.7,19.89-18.09,19.49-9.05-.56,2.31-14.04-1.7-19.76-1.73-2.47-7.6-8.13-11.2-4.55l-40.04,39.78.56,13.03Z" fill="rgb(204,204,204)"/><path d="M194,177.67c2.66,10.8-4.29,21.85-11.68,25.96-23.8,13.25-44.93-14.65-61.98-34.74-14.94-17.61-31.47-32.64-47.69-49.18-3.69-3.77-9.56-5.01-13.23-2.97-12.18,6.76-4.54,18.02-13.79,18.91-18.21-.22-2.19-26.12,6.1-28.91,8.07-4.38,20.73-4.56,27.31,1.72,14.67,14.02,28.79,27.1,41.77,42.46,12.68,14.99,26.22,28.37,40.53,41.76,3.82,3.58,10.67,1.41,14.46-.14,4.52-1.84,4.83-8.04,5.72-14.43.45-3.2,11.61-3.95,12.48-.44Z" fill="rgb(204,204,204)"/></g>"##.to_string()
        },
        // Line segment (from SVG, scaled from 256→28)
        ToolKind::Line => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><line x1="30.79" y1="232.04" x2="231.78" y2="31.05" fill="none" stroke="rgb(204,204,204)" stroke-miterlimit="10" stroke-width="8"/></g>"##.to_string()
        },
        // Rectangle
        ToolKind::Rect => format!(
            r#"<rect x="4" y="4" width="20" height="20" fill="none" stroke="{c}" stroke-width="1.5"/>"#),
        // Rounded Rectangle (from SVG, scaled from 256→28)
        ToolKind::RoundedRect => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><rect x="23.33" y="58.26" width="212.06" height="139.47" rx="30" ry="30" fill="none" stroke="rgb(204,204,204)" stroke-miterlimit="10" stroke-width="8"/></g>"##.to_string()
        },
        // Hexagon (cx=14, cy=14, r=11, 6 sides, -90° start)
        ToolKind::Polygon => format!(
            r#"<path d="M14,3 L23.5,8.5 L23.5,19.5 L14,25 L4.5,19.5 L4.5,8.5 Z" fill="none" stroke="{c}" stroke-width="1.5"/>"#),
        // Star (from SVG, scaled from 256→28)
        ToolKind::Star => {
            let _c = c;
            r##"<g transform="scale(0.109375)"><polygon points="128 50.18 145.47 103.95 202.01 103.95 156.27 137.18 173.74 190.95 128 157.72 82.26 190.95 99.73 137.18 53.99 103.95 110.53 103.95 128 50.18" fill="none" stroke="rgb(204,204,204)" stroke-miterlimit="10" stroke-width="8"/></g>"##.to_string()
        },
        // Lasso (freehand loop — placeholder icon)
        ToolKind::Lasso => format!(
            r#"<path d="M14,5 C6,5 3,10 3,14 C3,20 8,24 14,22 C20,20 22,16 20,12 C18,8 12,9 12,13 C12,16 16,17 17,15" fill="none" stroke="{c}" stroke-width="1.5" stroke-linecap="round"/>"#),
    }
}

/// Find the address of a panel kind in the layout (first occurrence).
fn find_panel(layout: &super::dock::DockLayout, kind: super::dock::PanelKind) -> Option<super::dock::PanelAddr> {
    for (_, dock) in &layout.anchored {
        for (gi, group) in dock.groups.iter().enumerate() {
            if let Some(pi) = group.panels.iter().position(|&k| k == kind) {
                return Some(super::dock::PanelAddr {
                    group: super::dock::GroupAddr { dock_id: dock.id, group_idx: gi },
                    panel_idx: pi,
                });
            }
        }
    }
    for fd in &layout.floating {
        for (gi, group) in fd.dock.groups.iter().enumerate() {
            if let Some(pi) = group.panels.iter().position(|&k| k == kind) {
                return Some(super::dock::PanelAddr {
                    group: super::dock::GroupAddr { dock_id: fd.dock.id, group_idx: gi },
                    panel_idx: pi,
                });
            }
        }
    }
    None
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
            if let Ok(st) = app.try_borrow() {
                st.repaint();
            }
        });
    }

    // Blink timer: while a tool is in a text-editing session, bump the
    // revision every ~265ms so the caret blinks. The interval is installed
    // for the lifetime of the component; it cheaply checks each tick whether
    // editing is still active and only triggers a repaint then.
    {
        let app_b = app.clone();
        let mut rev_b = revision;
        use_hook(move || {
            #[cfg(target_arch = "wasm32")]
            {
                use wasm_bindgen::closure::Closure;
                let app_b = app_b.clone();
                let cb = Closure::<dyn FnMut()>::new(move || {
                    let editing = if let Ok(st) = app_b.try_borrow() {
                        let kind = st.active_tool;
                        st.tab()
                            .and_then(|tab| tab.tools.get(&kind).map(|t| t.is_editing()))
                            .unwrap_or(false)
                    } else {
                        false
                    };
                    if editing {
                        rev_b += 1;
                    }
                });
                if let Some(window) = web_sys::window() {
                    let _ = window
                        .set_interval_with_callback_and_timeout_and_arguments_0(
                            cb.as_ref().unchecked_ref(),
                            265,
                        );
                }
                // Leak the closure so it stays alive for the app lifetime.
                cb.forget();
            }
            #[cfg(not(target_arch = "wasm32"))]
            { let _ = (&app_b, &mut rev_b); }
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
                if let Some(tab) = st.tab_mut() {
                    if let Some(tool) = tab.tools.get_mut(&kind) {
                        tool.on_press(&mut tab.model, cx, cy, shift, alt);
                    }
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
            let alt = mods.alt();
            let dragging = evt.data().held_buttons().contains(dioxus::html::input_data::MouseButton::Primary);
            (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                let kind = st.active_tool;
                if let Some(tab) = st.tab_mut() {
                    if let Some(tool) = tab.tools.get_mut(&kind) {
                        tool.on_move(&mut tab.model, cx, cy, shift, alt, dragging);
                    }
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
                if let Some(tab) = st.tab_mut() {
                    if let Some(tool) = tab.tools.get_mut(&kind) {
                        tool.on_release(&mut tab.model, cx, cy, shift, alt);
                    }
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
                if let Some(tab) = st.tab_mut() {
                    if let Some(tool) = tab.tools.get_mut(&kind) {
                        tool.on_double_click(&mut tab.model, cx, cy);
                    }
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

            // If the active tool is in a text-editing session, route the
            // event there first. The tool's `on_key_event` consumes printable
            // characters, navigation, deletion, and the in-session shortcuts
            // (Cmd+A/C/X/Z). Cmd+V still goes through the async clipboard
            // path below; we then call `paste_text` on the tool.
            let tool_captures = {
                let st = app_for_keys.borrow();
                st.tab().and_then(|tab| {
                    tab.tools.get(&st.active_tool).map(|t| t.captures_keyboard())
                }).unwrap_or(false)
            };
            if tool_captures {
                // Cmd+V is handled by the async clipboard path so the tool
                // can receive the actual text.
                let is_paste = (matches!(key, Key::Character(ref c) if c == "v" || c == "V")) && cmd;
                if !is_paste {
                    let key_str: String = match &key {
                        Key::Character(c) => c.clone(),
                        Key::Enter => "Enter".to_string(),
                        Key::Escape => "Escape".to_string(),
                        Key::Backspace => "Backspace".to_string(),
                        Key::Delete => "Delete".to_string(),
                        Key::ArrowLeft => "ArrowLeft".to_string(),
                        Key::ArrowRight => "ArrowRight".to_string(),
                        Key::ArrowUp => "ArrowUp".to_string(),
                        Key::ArrowDown => "ArrowDown".to_string(),
                        Key::Home => "Home".to_string(),
                        Key::End => "End".to_string(),
                        Key::Tab => "Tab".to_string(),
                        _ => String::new(),
                    };
                    if !key_str.is_empty() {
                        evt.prevent_default();
                        let km = crate::tools::tool::KeyMods {
                            shift: mods.shift(),
                            ctrl: mods.ctrl(),
                            alt: mods.alt(),
                            meta: mods.meta(),
                        };
                        (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                            let kind = st.active_tool;
                            if let Some(tab) = st.tab_mut() {
                                if let Some(tool) = tab.tools.get_mut(&kind) {
                                    tool.on_key_event(&mut tab.model, &key_str, km);
                                }
                            }
                        }));
                        return;
                    }
                } else {
                    evt.prevent_default();
                    clipboard_read_and_paste(
                        app_for_keys.clone(),
                        revision_for_keys.clone(),
                        0.0,
                    );
                    return;
                }
            }

            match key {
                // --- Modifier shortcuts ---
                Key::Character(ref c) if (c == "z" || c == "Z") && cmd => {
                    evt.prevent_default();
                    if mods.shift() {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            if let Some(tab) = st.tab_mut() { tab.model.redo(); }
                        }));
                    } else {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            if let Some(tab) = st.tab_mut() { tab.model.undo(); }
                        }));
                    }
                }
                Key::Character(ref c) if (c == "c" || c == "C") && cmd => {
                    evt.prevent_default();
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.tab().is_none() { return; }
                        // Write SVG to system clipboard
                        if let Some(svg) = selection_to_svg(st) {
                            clipboard_write(svg);
                        }
                        // Also update internal clipboard
                        let elements = {
                            let tab = st.tab().unwrap();
                            let doc = tab.model.document();
                            doc.selection.iter()
                                .filter_map(|es| doc.get_element(&es.path).cloned())
                                .collect::<Vec<_>>()
                        };
                        st.tab_mut().unwrap().clipboard = elements;
                    }));
                }
                Key::Character(ref c) if (c == "x" || c == "X") && cmd => {
                    evt.prevent_default();
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.tab().is_none() { return; }
                        // Write SVG to system clipboard
                        if let Some(svg) = selection_to_svg(st) {
                            clipboard_write(svg);
                        }
                        // Update internal clipboard and delete
                        let elements = {
                            let tab = st.tab().unwrap();
                            let doc = tab.model.document();
                            doc.selection.iter()
                                .filter_map(|es| doc.get_element(&es.path).cloned())
                                .collect::<Vec<_>>()
                        };
                        let tab = st.tab_mut().unwrap();
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
                        if let Some(tab) = st.tab_mut() { Controller::select_all(&mut tab.model); }
                    }));
                }
                Key::Character(ref c) if (c == "2") && cmd => {
                    evt.prevent_default();
                    if mods.alt() {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            if let Some(tab) = st.tab_mut() {
                                tab.model.snapshot();
                                Controller::unlock_all(&mut tab.model);
                            }
                        }));
                    } else {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            if let Some(tab) = st.tab_mut() {
                                tab.model.snapshot();
                                Controller::lock_selection(&mut tab.model);
                            }
                        }));
                    }
                }
                Key::Character(ref c) if (c == "3") && cmd => {
                    evt.prevent_default();
                    if mods.alt() {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            if let Some(tab) = st.tab_mut() {
                                tab.model.snapshot();
                                Controller::show_all(&mut tab.model);
                            }
                        }));
                    } else {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            if let Some(tab) = st.tab_mut() {
                                tab.model.snapshot();
                                Controller::hide_selection(&mut tab.model);
                            }
                        }));
                    }
                }
                Key::Character(ref c) if (c == "s" || c == "S") && cmd => {
                    evt.prevent_default();
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            let svg = document_to_svg(tab.model.document());
                            let filename = if tab.model.filename.ends_with(".svg") {
                                tab.model.filename.clone()
                            } else {
                                format!("{}.svg", tab.model.filename)
                            };
                            download_file(&filename, &svg);
                            tab.model.mark_saved();
                        }
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
                            if let Some(tab) = st.tab_mut() {
                                tab.model.snapshot();
                                Controller::ungroup_selection(&mut tab.model);
                            }
                        }));
                    } else {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            if let Some(tab) = st.tab_mut() {
                                tab.model.snapshot();
                                Controller::group_selection(&mut tab.model);
                            }
                        }));
                    }
                }
                // --- Tool shortcuts (bare keys, no modifier) ---
                Key::Character(ref c) if c == "v" || c == "V" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.set_tool(ToolKind::Selection);
                    }));
                }
                Key::Character(ref c) if c == "a" || c == "A" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.set_tool(ToolKind::DirectSelection);
                    }));
                }
                Key::Character(ref c) if c == "p" || c == "P" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.set_tool(ToolKind::Pen);
                    }));
                }
                Key::Character(ref c) if c == "=" || c == "+" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.set_tool(ToolKind::AddAnchorPoint);
                    }));
                }
                Key::Character(ref c) if c == "-" || c == "_" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.set_tool(ToolKind::DeleteAnchorPoint);
                    }));
                }
                Key::Character(ref c) if c == "C" => {
                    // Shift+C for Anchor Point tool
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.set_tool(ToolKind::AnchorPoint);
                    }));
                }
                Key::Character(ref c) if c == "n" || c == "N" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.set_tool(ToolKind::Pencil);
                    }));
                }
                Key::Character(ref c) if c == "E" => {
                    // Shift+E for Path Eraser tool
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.set_tool(ToolKind::PathEraser);
                    }));
                }
                Key::Character(ref c) if c == "t" || c == "T" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.set_tool(ToolKind::Type);
                    }));
                }
                Key::Character(ref c) if c == "l" || c == "L" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.set_tool(ToolKind::Line);
                    }));
                }
                Key::Character(ref c) if c == "m" || c == "M" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.set_tool(ToolKind::Rect);
                    }));
                }
                Key::Escape | Key::Enter => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        let kind = st.active_tool;
                        if let Some(tab) = st.tab_mut() {
                            if let Some(tool) = tab.tools.get_mut(&kind) {
                                tool.on_key(&mut tab.model, "Escape");
                            }
                        }
                    }));
                }
                Key::Delete | Key::Backspace => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            let new_doc = tab.model.document().delete_selection();
                            tab.model.set_document(new_doc);
                        }
                    }));
                }
                _ => {}
            }
        }
    };

    let on_keyup = {
        let act = act.clone();
        move |evt: Event<KeyboardData>| {
            let key = evt.data().key();
            match key {
                Key::Character(ref c) if c == " " => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        let kind = st.active_tool;
                        if let Some(tab) = st.tab_mut() {
                            if let Some(tool) = tab.tools.get_mut(&kind) {
                                tool.on_key_up(&mut tab.model, " ");
                            }
                        }
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

    // Dock drag-and-drop state.
    let mut drag_source = use_signal(|| Option::<super::dock::DragPayload>::None);
    let mut drop_target_sig = use_signal(|| Option::<super::dock::DropTarget>::None);
    let mut was_dropped = use_signal(|| false);
    let mut last_drag_pos = use_signal(|| (0.0f64, 0.0f64));
    // Floating dock title bar drag (dock_id, offset_x, offset_y).
    let mut title_drag = use_signal(|| Option::<(super::dock::DockId, f64, f64)>::None);
    // Resize drag (group above the handle, start_y).
    let mut resize_drag = use_signal(|| Option::<(super::dock::GroupAddr, f64, f64)>::None); // (addr, start_y, start_height)

    // Read revision to trigger re-render when state changes.
    let _ = revision();
    let active_tool = app.borrow().active_tool;
    // Per-frame cursor: tools may override (e.g. Type tool returns the
    // text-insertion SVG when hovering text, and "none" while editing).
    let canvas_cursor: String = {
        let st = app.borrow();
        st.tab()
            .and_then(|tab| tab.tools.get(&active_tool).and_then(|t| t.cursor_css_override()))
            .unwrap_or_else(|| active_tool.cursor_css().to_string())
    };
    let _any_tool_editing: bool = {
        let st = app.borrow();
        st.tab()
            .and_then(|tab| tab.tools.get(&active_tool).map(|t| t.is_editing()))
            .unwrap_or(false)
    };

    // If active tool is an alternate that's not currently visible, update the slot.
    // Collect updates first, then apply — writing to signals during render can cause
    // borrow conflicts in the Dioxus runtime.
    let slot_updates: Vec<(usize, usize)> = TOOLBAR_SLOTS.iter().enumerate()
        .filter_map(|(si, (_r, _c, tools))| {
            if tools.len() > 1 {
                if let Some(pos) = tools.iter().position(|&t| t == active_tool) {
                    let current = *slot_alternates.peek().get(&si).unwrap_or(&0);
                    if current != pos {
                        return Some((si, pos));
                    }
                }
            }
            None
        })
        .collect();
    if !slot_updates.is_empty() {
        let mut alts = slot_alternates.write();
        for (si, pos) in slot_updates {
            alts.insert(si, pos);
        }
    }

    let tool_buttons: Vec<Result<VNode, RenderError>> = TOOLBAR_SLOTS
        .iter()
        .enumerate()
        .map(|(si, &(row, col, tools))| {
            let act = act.clone();
            let alt_idx = *slot_alternates.peek().get(&si).unwrap_or(&0);
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
                                st.set_tool(kind);
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
                            st.set_tool(tool_kind);
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
    let has_tabs = !borrowed.tabs.is_empty();
    drop(borrowed);

    let tab_buttons: Vec<Result<VNode, RenderError>> = tab_info.iter().map(|(i, name, is_active)| {
        let idx = *i;
        let act = act.clone();
        let bg = if *is_active { "#fff" } else { "#e0e0e0" };
        let border_bottom = if *is_active { "2px solid #fff" } else { "2px solid #ccc" };
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
                        if let Some(tab) = st.tab_mut() {
                            let svg = document_to_svg(tab.model.document());
                            let filename = if tab.model.filename.ends_with(".svg") {
                                tab.model.filename.clone()
                            } else {
                                format!("{}.svg", tab.model.filename)
                            };
                            download_file(&filename, &svg);
                            tab.model.mark_saved();
                        }
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
                        if let Some(tab) = st.tab_mut() { tab.model.undo(); }
                    }));
                }
                "redo" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() { tab.model.redo(); }
                    }));
                }
                "cut" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.tab().is_none() { return; }
                        if let Some(svg) = selection_to_svg(st) {
                            clipboard_write(svg);
                        }
                        let elements: Vec<GeoElement> = {
                            let tab = st.tab().unwrap();
                            let doc = tab.model.document();
                            doc.selection.iter()
                                .filter_map(|es| doc.get_element(&es.path).cloned())
                                .collect()
                        };
                        let tab = st.tab_mut().unwrap();
                        tab.clipboard = elements;
                        tab.model.snapshot();
                        let new_doc = tab.model.document().delete_selection();
                        tab.model.set_document(new_doc);
                    }));
                }
                "copy" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.tab().is_none() { return; }
                        if let Some(svg) = selection_to_svg(st) {
                            clipboard_write(svg);
                        }
                        let elements: Vec<GeoElement> = {
                            let tab = st.tab().unwrap();
                            let doc = tab.model.document();
                            doc.selection.iter()
                                .filter_map(|es| doc.get_element(&es.path).cloned())
                                .collect()
                        };
                        st.tab_mut().unwrap().clipboard = elements;
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
                        if let Some(tab) = st.tab_mut() { Controller::select_all(&mut tab.model); }
                    }));
                }
                "delete" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            let new_doc = tab.model.document().delete_selection();
                            tab.model.set_document(new_doc);
                        }
                    }));
                }
                "group" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            Controller::group_selection(&mut tab.model);
                        }
                    }));
                }
                "ungroup" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            Controller::ungroup_selection(&mut tab.model);
                        }
                    }));
                }
                "ungroup_all" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            Controller::ungroup_all(&mut tab.model);
                        }
                    }));
                }
                "lock" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            Controller::lock_selection(&mut tab.model);
                        }
                    }));
                }
                "unlock_all" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            Controller::unlock_all(&mut tab.model);
                        }
                    }));
                }
                "hide" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            Controller::hide_selection(&mut tab.model);
                        }
                    }));
                }
                "show_all" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if let Some(tab) = st.tab_mut() {
                            tab.model.snapshot();
                            Controller::show_all(&mut tab.model);
                        }
                    }));
                }
                // Window menu commands
                "toggle_panel_layers" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.dock_layout.is_panel_visible(super::dock::PanelKind::Layers) {
                            // Find and close it
                            if let Some(addr) = find_panel(&st.dock_layout, super::dock::PanelKind::Layers) {
                                st.dock_layout.close_panel(addr);
                            }
                        } else {
                            st.dock_layout.show_panel(super::dock::PanelKind::Layers);
                        }
                    }));
                }
                "toggle_panel_color" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.dock_layout.is_panel_visible(super::dock::PanelKind::Color) {
                            if let Some(addr) = find_panel(&st.dock_layout, super::dock::PanelKind::Color) {
                                st.dock_layout.close_panel(addr);
                            }
                        } else {
                            st.dock_layout.show_panel(super::dock::PanelKind::Color);
                        }
                    }));
                }
                "toggle_panel_stroke" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.dock_layout.is_panel_visible(super::dock::PanelKind::Stroke) {
                            if let Some(addr) = find_panel(&st.dock_layout, super::dock::PanelKind::Stroke) {
                                st.dock_layout.close_panel(addr);
                            }
                        } else {
                            st.dock_layout.show_panel(super::dock::PanelKind::Stroke);
                        }
                    }));
                }
                "toggle_panel_properties" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        if st.dock_layout.is_panel_visible(super::dock::PanelKind::Properties) {
                            if let Some(addr) = find_panel(&st.dock_layout, super::dock::PanelKind::Properties) {
                                st.dock_layout.close_panel(addr);
                            }
                        } else {
                            st.dock_layout.show_panel(super::dock::PanelKind::Properties);
                        }
                    }));
                }
                "reset_panel_layout" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.dock_layout = super::dock::DockLayout::default_layout();
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

    // --- Dock rendering helpers ---
    use super::dock::{DockLayout, DockEdge, DockId, GroupAddr, PanelAddr, DragPayload, DropTarget};

    // Build panel group nodes for a given dock. Reused for anchored and floating docks.
    fn build_dock_groups(
        dock_id: DockId,
        groups: &[super::dock::PanelGroup],
        act: &Rc<RefCell<impl FnMut(Box<dyn FnOnce(&mut AppState)>) + 'static>>,
        mut drag_source: Signal<Option<DragPayload>>,
        mut drop_target_sig: Signal<Option<DropTarget>>,
        mut was_dropped: Signal<bool>,
        mut last_drag_pos: Signal<(f64, f64)>,
    ) -> Vec<Result<VNode, RenderError>> {
        let did = dock_id;
        let group_count = groups.len();
        let cur_drag = drag_source();
        let cur_drop = drop_target_sig();

        groups.iter().enumerate().map(|(gi, group)| {
            let act_tabs = act.clone();
            let act_chevron = act.clone();
            let act_collapse = act.clone();
            let act_drop = act.clone();
            let group_collapsed = group.collapsed;

            // Tab bar buttons — each tab is individually draggable
            let tab_nodes: Vec<Result<VNode, RenderError>> = group.panels.iter().enumerate().map(|(pi, &kind)| {
                let act_dragend = act_tabs.clone();
                let act_click = act_tabs.clone();
                let label = DockLayout::panel_label(kind);
                let is_active = pi == group.active;
                let bg = if is_active { "#f0f0f0" } else { "#d8d8d8" };
                let border_bottom = if is_active { "2px solid #f0f0f0" } else { "2px solid #bbb" };
                let font_weight = if is_active { "bold" } else { "normal" };
                rsx! {
                    div {
                        key: "dock-tab-{gi}-{pi}",
                        style: "padding:3px 8px; cursor:pointer; font-size:11px; font-weight:{font_weight}; background:{bg}; border-bottom:{border_bottom}; user-select:none;",
                        draggable: "true",
                        ondragstart: move |evt: Event<DragData>| {
                            evt.stop_propagation();
                            drag_source.set(Some(DragPayload::Panel(PanelAddr {
                                group: GroupAddr { dock_id: did, group_idx: gi },
                                panel_idx: pi,
                            })));
                            was_dropped.set(false);
                        },
                        ondragend: move |_| {
                            if !was_dropped() {
                                let (x, y) = last_drag_pos();
                                (act_dragend.borrow_mut())(Box::new(move |st: &mut AppState| {
                                    st.dock_layout.detach_panel(PanelAddr {
                                        group: GroupAddr { dock_id: did, group_idx: gi },
                                        panel_idx: pi,
                                    }, x, y);
                                }));
                            }
                            drag_source.set(None);
                            drop_target_sig.set(None);
                            was_dropped.set(false);
                        },
                        onclick: move |_| {
                            (act_click.borrow_mut())(Box::new(move |st: &mut AppState| {
                                st.dock_layout.set_active_panel(PanelAddr {
                                    group: GroupAddr { dock_id: did, group_idx: gi },
                                    panel_idx: pi,
                                });
                            }));
                        },
                        "{label}"
                        // Close button
                        {
                            let act_close = act_click.clone();
                            rsx! {
                                span {
                                    style: "margin-left:4px; color:#aaa; cursor:pointer; font-size:10px; line-height:1;",
                                    onclick: move |evt: Event<MouseData>| {
                                        evt.stop_propagation();
                                        (act_close.borrow_mut())(Box::new(move |st: &mut AppState| {
                                            st.dock_layout.close_panel(PanelAddr {
                                                group: GroupAddr { dock_id: did, group_idx: gi },
                                                panel_idx: pi,
                                            });
                                        }));
                                    },
                                    "\u{00d7}"
                                }
                            }
                        }
                    }
                }
            }).collect();

            let chevron = if group_collapsed { "\u{25BC}" } else { "\u{25B2}" };
            let body_label = group.active_panel()
                .map(|k| DockLayout::panel_label(k))
                .unwrap_or("");

            // Drop indicator logic
            let show_drop_before = cur_drag.is_some()
                && cur_drop == Some(DropTarget::GroupSlot { dock_id: did, group_idx: gi });
            let drop_indicator_style = if show_drop_before {
                "height:2px; background:#4a90d9;"
            } else {
                "height:0px;"
            };
            let show_drop_after = gi == group_count - 1
                && cur_drag.is_some()
                && cur_drop == Some(DropTarget::GroupSlot { dock_id: did, group_idx: group_count });
            let drop_after_style = if show_drop_after {
                "height:2px; background:#4a90d9;"
            } else {
                "height:0px;"
            };
            // Highlight tab bar when it's a TabBar drop target
            let tab_bar_drop = cur_drag.is_some()
                && cur_drop == Some(DropTarget::TabBar(GroupAddr { dock_id: did, group_idx: gi }));
            let tab_bar_border = if tab_bar_drop { "2px solid #4a90d9" } else { "1px solid #bbb" };

            let is_dragged_group = matches!(cur_drag,
                Some(DragPayload::Group(addr)) if addr.dock_id == did && addr.group_idx == gi);
            let opacity = if is_dragged_group { "0.4" } else { "1.0" };

            rsx! {
                div {
                    key: "dock-group-{did:?}-{gi}",
                    style: "border-bottom:1px solid #ccc; opacity:{opacity};",
                    ondragover: move |evt: Event<DragData>| {
                        evt.prevent_default();
                        let coords = evt.data().page_coordinates();
                        last_drag_pos.set((coords.x, coords.y));
                        let y = evt.data().element_coordinates().y;
                        let mid = 30.0;
                        if y < mid {
                            drop_target_sig.set(Some(DropTarget::GroupSlot { dock_id: did, group_idx: gi }));
                        } else {
                            drop_target_sig.set(Some(DropTarget::GroupSlot { dock_id: did, group_idx: gi + 1 }));
                        }
                    },
                    ondrop: move |evt: Event<DragData>| {
                        evt.prevent_default();
                        was_dropped.set(true);
                        let src = drag_source();
                        let tgt = drop_target_sig();
                        if let (Some(src), Some(tgt)) = (src, tgt) {
                            (act_drop.borrow_mut())(Box::new(move |st: &mut AppState| {
                                match (src, tgt) {
                                    (DragPayload::Group(from), DropTarget::GroupSlot { dock_id: to_dock, group_idx: to_idx }) => {
                                        if from.dock_id == to_dock {
                                            st.dock_layout.move_group_within_dock(to_dock, from.group_idx, to_idx);
                                        } else {
                                            st.dock_layout.move_group_to_dock(from, to_dock, to_idx);
                                        }
                                    }
                                    (DragPayload::Panel(from), DropTarget::GroupSlot { dock_id: to_dock, group_idx: to_idx }) => {
                                        st.dock_layout.insert_panel_as_new_group(from, to_dock, to_idx);
                                    }
                                    (DragPayload::Group(from), DropTarget::TabBar(to_group)) => {
                                        // Merge: move all panels from dragged group into target group
                                        // by moving the group next to the target then transferring panels
                                        st.dock_layout.move_group_to_dock(from, to_group.dock_id, to_group.group_idx);
                                    }
                                    (DragPayload::Panel(from), DropTarget::TabBar(to_group)) => {
                                        st.dock_layout.move_panel_to_group(from, to_group);
                                    }
                                    _ => {}
                                }
                            }));
                        }
                        drag_source.set(None);
                        drop_target_sig.set(None);
                    },

                    div { style: "{drop_indicator_style}" }

                    // Tab bar with grip handle
                    div {
                        style: "display:flex; background:#d8d8d8; border-bottom:{tab_bar_border}; align-items:center;",
                        ondragover: move |evt: Event<DragData>| {
                            evt.prevent_default();
                            evt.stop_propagation();
                            let coords = evt.data().page_coordinates();
                            last_drag_pos.set((coords.x, coords.y));
                            drop_target_sig.set(Some(DropTarget::TabBar(GroupAddr { dock_id: did, group_idx: gi })));
                        },

                        // Grip handle for dragging the whole group
                        div {
                            style: "padding:2px 4px; cursor:grab; color:#999; font-size:10px; user-select:none;",
                            draggable: "true",
                            ondragstart: move |evt: Event<DragData>| {
                                evt.stop_propagation();
                                drag_source.set(Some(DragPayload::Group(GroupAddr {
                                    dock_id: did,
                                    group_idx: gi,
                                })));
                                was_dropped.set(false);
                            },
                            ondragend: move |_| {
                                if !was_dropped() {
                                    let (x, y) = last_drag_pos();
                                    let act_detach = act_collapse.clone();
                                    (act_detach.borrow_mut())(Box::new(move |st: &mut AppState| {
                                        st.dock_layout.detach_group(GroupAddr {
                                            dock_id: did,
                                            group_idx: gi,
                                        }, x, y);
                                    }));
                                }
                                drag_source.set(None);
                                drop_target_sig.set(None);
                                was_dropped.set(false);
                            },
                            "\u{2801}\u{2801}"
                        }

                        for tab in tab_nodes {
                            {tab}
                        }

                        div {
                            style: "margin-left:auto; padding:3px 6px; cursor:pointer; font-size:9px; color:#888; user-select:none;",
                            onclick: {
                                let act = act_chevron.clone();
                                move |_| {
                                    (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                        st.dock_layout.toggle_group_collapsed(GroupAddr {
                                            dock_id: did,
                                            group_idx: gi,
                                        });
                                    }));
                                }
                            },
                            "{chevron}"
                        }
                    }

                    if !group_collapsed {
                        div {
                            style: "padding:12px; min-height:60px; color:#999; font-size:12px;",
                            "{body_label}"
                        }
                    }

                    div { style: "{drop_after_style}" }
                }
            }
        }).collect()
    }

    // --- Build dock nodes ---
    let layout_snapshot = app.borrow().dock_layout.clone();
    let right_dock = layout_snapshot.anchored_dock(DockEdge::Right);
    let dock_collapsed = right_dock.map_or(true, |d| d.collapsed);
    let dock_width = if dock_collapsed { 36.0 } else { right_dock.map_or(0.0, |d| d.width) };
    let dock_id = right_dock.map_or(DockId(0), |d| d.id);

    let dock_groups: Vec<Result<VNode, RenderError>> = match right_dock {
        None => vec![],
        Some(dock) if dock.collapsed => {
            let act_dock = act.clone();
            let did = dock.id;
            dock.groups.iter().enumerate().flat_map(|(gi, group)| {
                let act_inner = act_dock.clone();
                group.panels.iter().enumerate().map(move |(pi, &kind)| {
                    let act = act_inner.clone();
                    let label = DockLayout::panel_label(kind);
                    let first_char: String = label.chars().take(1).collect();
                    rsx! {
                        div {
                            key: "dock-icon-{gi}-{pi}",
                            style: "width:28px; height:28px; margin:2px auto; background:#e0e0e0; border-radius:3px; display:flex; align-items:center; justify-content:center; cursor:pointer; font-size:12px; font-weight:bold; color:#555;",
                            title: "{label}",
                            onclick: move |_| {
                                (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                    st.dock_layout.toggle_dock_collapsed(did);
                                    st.dock_layout.set_active_panel(PanelAddr {
                                        group: GroupAddr { dock_id: did, group_idx: gi },
                                        panel_idx: pi,
                                    });
                                }));
                            },
                            "{first_char}"
                        }
                    }
                })
            }).collect()
        }
        Some(dock) => {
            build_dock_groups(dock.id, &dock.groups, &act, drag_source, drop_target_sig, was_dropped, last_drag_pos)
        }
    };

    // Build floating dock nodes
    let floating_nodes: Vec<Result<VNode, RenderError>> = layout_snapshot.floating.iter().map(|fd| {
        let fid = fd.dock.id;
        let fx = fd.x;
        let fy = fd.y;
        let fw = fd.dock.width;
        let act_front = act.clone();
        let fgroups = build_dock_groups(fid, &fd.dock.groups, &act, drag_source, drop_target_sig, was_dropped, last_drag_pos);
        let z = 900 + layout_snapshot.z_order.iter().position(|&id| id == fid).unwrap_or(0);

        rsx! {
            div {
                key: "floating-{fid:?}",
                style: "position:fixed; left:{fx}px; top:{fy}px; width:{fw}px; background:#f0f0f0; border:1px solid #aaa; box-shadow:4px 4px 12px rgba(0,0,0,0.2); border-radius:4px; z-index:{z}; display:flex; flex-direction:column; overflow:hidden;",
                onmousedown: move |evt: Event<MouseData>| {
                    evt.stop_propagation();
                    (act_front.borrow_mut())(Box::new(move |st: &mut AppState| {
                        st.dock_layout.bring_to_front(fid);
                    }));
                },

                // Title bar for repositioning
                div {
                    style: "height:20px; background:#d0d0d0; cursor:grab; display:flex; align-items:center; padding:0 6px; font-size:10px; color:#666; user-select:none;",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        let coords = evt.data().page_coordinates();
                        title_drag.set(Some((fid, coords.x - fx, coords.y - fy)));
                    },
                }

                for g in fgroups {
                    {g}
                }
            }
        }
    }).collect();

    // Dock collapse toggle
    let dock_toggle_label = if dock_collapsed { "\u{25C0}" } else { "\u{25B6}" };

    rsx! {
        style { r#"
            #main {{ height: 100%; }}
            .jas-menu-title:hover {{ background: #d0d0d0; }}
            .jas-menu-item:hover {{ background: #e8e8e8; }}
            .jas-tool-popup-item:hover {{ background: #606060 !important; }}
        "#  }
        div {
            tabindex: "0",
            onkeydown: on_keydown,
            onkeyup: on_keyup,
            onmousedown: move |_| {
                popup_slot.set(None);
            },
            onmousemove: {
                let act = act.clone();
                move |evt: Event<MouseData>| {
                    if let Some((fid, off_x, off_y)) = title_drag() {
                        let coords = evt.data().page_coordinates();
                        (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                            st.dock_layout.set_floating_position(fid, coords.x - off_x, coords.y - off_y);
                        }));
                    }
                }
            },
            onmouseup: move |_| {
                title_drag.set(None);
            },
            ondragover: move |evt: Event<DragData>| {
                // Track drag position for empty-space drops (don't prevent_default — not a drop target)
                let coords = evt.data().page_coordinates();
                last_drag_pos.set((coords.x, coords.y));
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

                // Content area (canvas + dock)
                div {
                    style: "flex:1; display:flex; overflow:hidden;",

                    // Canvas
                    div {
                        style: "flex:1; position:relative; overflow:hidden; background:#808080;",
                        if has_tabs {
                            canvas {
                                id: "jas-canvas",
                                style: "display:block; width:100%; height:100%; cursor:{canvas_cursor};",
                                onmousedown: on_mousedown,
                                onmousemove: on_mousemove,
                                onmouseup: on_mouseup,
                                ondoubleclick: on_dblclick,
                            }
                        }
                    }

                    // Dock
                    if has_tabs {
                        div {
                            style: "width:{dock_width}px; background:#f0f0f0; border-left:1px solid #ccc; display:flex; flex-direction:column; flex-shrink:0; overflow-y:auto;",
                            onmousedown: move |evt: Event<MouseData>| {
                                evt.stop_propagation();
                            },

                            // Collapse/expand toggle
                            {
                                let act = act.clone();
                                rsx! {
                                    div {
                                        style: "padding:4px; cursor:pointer; text-align:center; border-bottom:1px solid #ddd; font-size:10px; color:#888; user-select:none;",
                                        onclick: move |_| {
                                            (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                                st.dock_layout.toggle_dock_collapsed(dock_id);
                                            }));
                                        },
                                        "{dock_toggle_label}"
                                    }
                                }
                            }

                            // Panel groups
                            for group in dock_groups {
                                {group}
                            }
                        }
                    }
                }
            }

            // Floating docks (position:fixed overlays)
            for fdock in floating_nodes {
                {fdock}
            }
        }
    }
}
