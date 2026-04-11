//! Main Dioxus application component.
//!
//! Hosts the toolbar, tab bar, canvas, and wires keyboard shortcuts.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

/// Shared application state handle, available via `use_context::<AppHandle>()`.
pub(crate) type AppHandle = Rc<RefCell<AppState>>;

/// Universal state mutation handle, available via `use_context::<Act>()`.
/// Call `(act.0.borrow_mut())(Box::new(|st| { ... }))` to mutate AppState.
#[derive(Clone)]
pub(crate) struct Act(pub Rc<RefCell<dyn FnMut(Box<dyn FnOnce(&mut AppState)>)>>);

use dioxus::prelude::*;
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;
use web_sys::{CanvasRenderingContext2d, HtmlCanvasElement};

use crate::canvas::render;
use crate::document::controller::{
    Controller, FillSummary, StrokeSummary,
    selection_fill_summary, selection_stroke_summary,
};
use crate::document::document::ElementSelection;
use crate::document::model::Model;
use crate::geometry::element::{translate_element, Color, Fill, Stroke, Element as GeoElement};
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
use super::theme::*;
use super::color_picker_dialog::ColorPickerDialogView;
use super::fill_stroke_widget::FillStrokeWidgetView;
use super::menu_bar::MenuBarView;
use super::save_dialog::{SaveAsDialog, SaveAsDialogView};
use super::dock_panel::{DragState, DockGroupsView, FloatingDocksView};
use super::toolbar_grid::{ToolbarGrid, TOOLBAR_SLOTS};

// ---------------------------------------------------------------------------

/// Per-tab state: each tab has its own document, tools, and clipboard.
pub(crate) struct TabState {
    pub(crate) model: Model,
    pub(crate) tools: HashMap<ToolKind, Box<dyn CanvasTool>>,
    pub(crate) clipboard: Vec<GeoElement>,
}

impl TabState {
    pub(crate) fn new() -> Self {
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
pub(crate) struct AppState {
    pub(crate) tabs: Vec<TabState>,
    pub(crate) active_tab: usize,
    pub(crate) active_tool: ToolKind,
    pub(crate) app_config: super::workspace::AppConfig,
    pub(crate) workspace_layout: super::workspace::WorkspaceLayout,
    /// Which fill/stroke square is on top (active). true = fill, false = stroke.
    pub(crate) fill_on_top: bool,
}

impl AppState {
    fn new() -> Self {
        let app_config = Self::load_app_config();
        let workspace_layout = Self::load_or_migrate_workspace(&app_config);
        Self {
            tabs: vec![],
            active_tab: 0,
            active_tool: ToolKind::Selection,
            app_config,
            workspace_layout,
            fill_on_top: true,
        }
    }

    /// Load app config from localStorage, or return default.
    fn load_app_config() -> super::workspace::AppConfig {
        #[cfg(target_arch = "wasm32")]
        {
            if let Some(json) = web_sys::window()
                .and_then(|w| w.local_storage().ok()?)
                .and_then(|s| s.get_item(super::workspace::AppConfig::STORAGE_KEY).ok()?)
            {
                return super::workspace::AppConfig::from_json(&json);
            }
        }
        super::workspace::AppConfig::default()
    }

    /// Save app config to localStorage.
    fn save_app_config(&self) {
        #[cfg(target_arch = "wasm32")]
        {
            if let Ok(json) = self.app_config.to_json() {
                if let Some(storage) = web_sys::window()
                    .and_then(|w| w.local_storage().ok()?)
                {
                    let _ = storage.set_item(super::workspace::AppConfig::STORAGE_KEY, &json);
                }
            }
        }
    }

    /// Try to load a named layout from localStorage. Returns None if not found.
    fn try_load_workspace_layout(_name: &str) -> Option<super::workspace::WorkspaceLayout> {
        #[cfg(target_arch = "wasm32")]
        {
            let key = super::workspace::WorkspaceLayout::storage_key_for(_name);
            if let Some(json) = web_sys::window()
                .and_then(|w| w.local_storage().ok()?)
                .and_then(|s| s.get_item(&key).ok()?)
            {
                return super::workspace::WorkspaceLayout::try_from_json(&json);
            }
        }
        None
    }

    /// Load a named dock layout from localStorage, or return default.
    fn load_workspace_layout(name: &str) -> super::workspace::WorkspaceLayout {
        Self::try_load_workspace_layout(name)
            .unwrap_or_else(|| super::workspace::WorkspaceLayout::named(name))
    }

    /// Load the "Workspace" working copy. If it doesn't exist, migrate
    /// from the current active_layout, or fall back to factory defaults.
    /// Always ensures the result is persisted under the "Workspace" key.
    fn load_or_migrate_workspace(
        config: &super::workspace::AppConfig,
    ) -> super::workspace::WorkspaceLayout {
        use super::workspace::WORKSPACE_LAYOUT_NAME;
        // Try loading "Workspace" directly
        if let Some(mut layout) = Self::try_load_workspace_layout(WORKSPACE_LAYOUT_NAME) {
            layout.name = WORKSPACE_LAYOUT_NAME.to_string();
            return layout;
        }
        // Migration: copy active_layout into "Workspace" and persist it
        let mut layout =
            if let Some(layout) = Self::try_load_workspace_layout(&config.active_layout) {
                layout
            } else {
                super::workspace::WorkspaceLayout::named(WORKSPACE_LAYOUT_NAME)
            };
        layout.name = WORKSPACE_LAYOUT_NAME.to_string();
        // Persist the migrated/default layout so it exists on next startup
        #[cfg(target_arch = "wasm32")]
        {
            let key = super::workspace::WorkspaceLayout::storage_key_for(WORKSPACE_LAYOUT_NAME);
            if let Ok(json) = layout.to_json() {
                if let Some(storage) = web_sys::window()
                    .and_then(|w| w.local_storage().ok()?)
                {
                    let _ = storage.set_item(&key, &json);
                }
            }
        }
        layout
    }

    /// Save the workspace layout to localStorage under the "Workspace" key.
    fn save_workspace_layout(&self) {
        #[cfg(target_arch = "wasm32")]
        {
            let key = super::workspace::WorkspaceLayout::storage_key_for(
                super::workspace::WORKSPACE_LAYOUT_NAME,
            );
            if let Ok(json) = self.workspace_layout.to_json() {
                if let Some(storage) = web_sys::window()
                    .and_then(|w| w.local_storage().ok()?)
                {
                    let _ = storage.set_item(&key, &json);
                }
            }
        }
    }

    /// Save the current workspace state as a named layout snapshot.
    pub(crate) fn save_layout_as(&mut self, name: &str) {
        #[cfg(target_arch = "wasm32")]
        {
            let key = super::workspace::WorkspaceLayout::storage_key_for(name);
            // Temporarily set name for serialization
            let saved_name = self.workspace_layout.name.clone();
            self.workspace_layout.name = name.to_string();
            if let Ok(json) = self.workspace_layout.to_json() {
                if let Some(storage) = web_sys::window()
                    .and_then(|w| w.local_storage().ok()?)
                {
                    let _ = storage.set_item(&key, &json);
                }
            }
            self.workspace_layout.name = saved_name;
        }
        self.app_config.register_layout(name);
        self.app_config.active_layout = name.to_string();
        self.save_app_config();
    }

    /// Switch to a different named layout (load it as the working copy).
    pub(crate) fn switch_layout(&mut self, name: &str) {
        // Save current working copy
        self.save_workspace_layout();
        // Load the named layout as the new working copy
        self.workspace_layout = Self::load_workspace_layout(name);
        self.workspace_layout.name = super::workspace::WORKSPACE_LAYOUT_NAME.to_string();
        self.app_config.active_layout = name.to_string();
        self.save_app_config();
        // Persist as "Workspace"
        self.save_workspace_layout();
    }

    /// Revert to the currently selected saved layout.
    pub(crate) fn revert_to_saved(&mut self) {
        let name = self.app_config.active_layout.clone();
        if name != super::workspace::WORKSPACE_LAYOUT_NAME {
            self.workspace_layout = Self::load_workspace_layout(&name);
            self.workspace_layout.name = super::workspace::WORKSPACE_LAYOUT_NAME.to_string();
            self.save_workspace_layout();
        }
    }

    /// Reset to factory defaults.
    pub(crate) fn reset_to_default(&mut self) {
        self.workspace_layout = super::workspace::WorkspaceLayout::named(
            super::workspace::WORKSPACE_LAYOUT_NAME,
        );
        self.app_config.active_layout =
            super::workspace::WORKSPACE_LAYOUT_NAME.to_string();
        self.save_app_config();
        self.save_workspace_layout();
    }

    pub(crate) fn tab(&self) -> Option<&TabState> {
        self.tabs.get(self.active_tab)
    }

    pub(crate) fn tab_mut(&mut self) -> Option<&mut TabState> {
        self.tabs.get_mut(self.active_tab)
    }

    pub(crate) fn add_tab(&mut self, tab: TabState) {
        self.tabs.push(tab);
        self.active_tab = self.tabs.len() - 1;
    }

    pub(crate) fn close_tab(&mut self, index: usize) {
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

    pub(crate) fn set_tool(&mut self, kind: ToolKind) {
        if let Some(tab) = self.tabs.get_mut(self.active_tab) {
            let active = self.active_tool;
            if let Some(tool) = tab.tools.get_mut(&active) {
                tool.deactivate(&mut tab.model);
            }
        }
        self.active_tool = kind;
    }

    /// Toggle which fill/stroke square is on top.
    fn toggle_fill_on_top(&mut self) {
        self.fill_on_top = !self.fill_on_top;
    }

    /// Swap default fill and stroke colors (including None).
    pub(crate) fn swap_fill_stroke(&mut self) {
        if let Some(tab) = self.tabs.get_mut(self.active_tab) {
            let old_fill_color = tab.model.default_fill.map(|f| f.color);
            let old_stroke_color = tab.model.default_stroke.map(|s| s.color);
            // Swap: fill gets old stroke color, stroke gets old fill color
            tab.model.default_fill = old_stroke_color.map(Fill::new);
            tab.model.default_stroke = match old_fill_color {
                Some(c) => {
                    let mut s = tab.model.default_stroke.unwrap_or(Stroke::new(c, 1.0));
                    s.color = c;
                    Some(s)
                }
                None => None,
            };
            // Apply to selection
            let new_fill = tab.model.default_fill;
            let new_stroke = tab.model.default_stroke;
            if !tab.model.document().selection.is_empty() {
                tab.model.snapshot();
                Controller::set_selection_fill(&mut tab.model, new_fill);
                Controller::set_selection_stroke(&mut tab.model, new_stroke);
            }
        }
    }

    /// Reset defaults to No Fill + Black Stroke.
    pub(crate) fn reset_fill_stroke_defaults(&mut self) {
        if let Some(tab) = self.tabs.get_mut(self.active_tab) {
            tab.model.default_fill = None;
            tab.model.default_stroke = Some(Stroke::new(Color::BLACK, 1.0));
            // Apply to selection
            if !tab.model.document().selection.is_empty() {
                tab.model.snapshot();
                Controller::set_selection_fill(&mut tab.model, None);
                Controller::set_selection_stroke(&mut tab.model, Some(Stroke::new(Color::BLACK, 1.0)));
            }
        }
    }

    /// Set the active attribute (fill or stroke, per fill_on_top) to None.
    pub(crate) fn set_active_to_none(&mut self) {
        if let Some(tab) = self.tabs.get_mut(self.active_tab) {
            if self.fill_on_top {
                tab.model.default_fill = None;
                if !tab.model.document().selection.is_empty() {
                    tab.model.snapshot();
                    Controller::set_selection_fill(&mut tab.model, None);
                }
            } else {
                tab.model.default_stroke = None;
                if !tab.model.document().selection.is_empty() {
                    tab.model.snapshot();
                    Controller::set_selection_stroke(&mut tab.model, None);
                }
            }
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
pub(crate) fn clipboard_write(text: String) {
    if let Some(_window) = web_sys::window() {
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
pub(crate) fn clipboard_read_and_paste(app: Rc<RefCell<AppState>>, mut revision: Signal<u64>, offset: f64) {
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
        if editing
            && let Some(text) = clipboard_text.clone() {
                let Some(tab) = st.tab_mut() else { return; };
                if let Some(tool) = tab.tools.get_mut(&active_kind)
                    && tool.paste_text(&mut tab.model, &text) {
                        drop(st);
                        revision += 1;
                        return;
                    }
            }

        let Some(tab) = st.tab_mut() else { return; };

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
pub(crate) fn selection_to_svg(st: &AppState) -> Option<String> {
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
pub(crate) fn download_file(filename: &str, content: &str) {
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
pub(crate) fn open_file_dialog(app: Rc<RefCell<AppState>>, revision: Signal<u64>) {
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
    let revision2 = revision;
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
        let mut revision3 = revision2;
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

/// Find the address of a panel kind in the layout (first occurrence).
pub(crate) fn find_panel(layout: &super::workspace::WorkspaceLayout, kind: super::workspace::PanelKind) -> Option<super::workspace::PanelAddr> {
    for (_, dock) in &layout.anchored {
        for (gi, group) in dock.groups.iter().enumerate() {
            if let Some(pi) = group.panels.iter().position(|&k| k == kind) {
                return Some(super::workspace::PanelAddr {
                    group: super::workspace::GroupAddr { dock_id: dock.id, group_idx: gi },
                    panel_idx: pi,
                });
            }
        }
    }
    for fd in &layout.floating {
        for (gi, group) in fd.dock.groups.iter().enumerate() {
            if let Some(pi) = group.panels.iter().position(|&k| k == kind) {
                return Some(super::workspace::PanelAddr {
                    group: super::workspace::GroupAddr { dock_id: fd.dock.id, group_idx: gi },
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

    // Window resize listener: clamp floating docks to viewport.
    {
        let app_r = app.clone();
        let mut rev_r = revision;
        use_hook(move || {
            #[cfg(target_arch = "wasm32")]
            {
                use wasm_bindgen::closure::Closure;
                let cb = Closure::<dyn FnMut()>::new(move || {
                    if let Some(win) = web_sys::window() {
                        let vw = win.inner_width().ok().and_then(|v| v.as_f64()).unwrap_or(1000.0);
                        let vh = win.inner_height().ok().and_then(|v| v.as_f64()).unwrap_or(700.0);
                        if let Ok(mut st) = app_r.try_borrow_mut() {
                            if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                pl.on_viewport_resize(vw, vh);
                            }
                            st.workspace_layout.clamp_floating_docks(vw, vh);
                            st.workspace_layout.bump();
                            st.save_workspace_layout();
                            st.workspace_layout.mark_saved();
                        }
                        rev_r += 1;
                    }
                });
                if let Some(window) = web_sys::window() {
                    let _ = window.add_event_listener_with_callback(
                        "resize",
                        cb.as_ref().unchecked_ref(),
                    );
                }
                cb.forget();
            }
            #[cfg(not(target_arch = "wasm32"))]
            { let _ = (&app_r, &mut rev_r); }
        });
    }

    // Macro-like helper: mutate state, then bump revision to trigger repaint.
    let act = {
        let app = app.clone();
        move |f: Box<dyn FnOnce(&mut AppState)>| {
            {
                let mut st = app.borrow_mut();
                f(&mut st);
                // Always bump after any mutation — pane_layout mutations
                // bypass bump(), so we ensure saves happen.
                st.workspace_layout.bump();
                st.save_workspace_layout();
                st.workspace_layout.mark_saved();
            }
            revision += 1;
        }
    };
    let act = Rc::new(RefCell::new(act));

    // Provide shared state via context so child components can access them.
    use_context_provider(|| Act(act.clone()));
    use_context_provider(|| app.clone());
    use_context_provider(|| revision);

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
                if let Some(tab) = st.tab_mut()
                    && let Some(tool) = tab.tools.get_mut(&kind) {
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
            let alt = mods.alt();
            let dragging = evt.data().held_buttons().contains(dioxus::html::input_data::MouseButton::Primary);
            (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                let kind = st.active_tool;
                if let Some(tab) = st.tab_mut()
                    && let Some(tool) = tab.tools.get_mut(&kind) {
                        tool.on_move(&mut tab.model, cx, cy, shift, alt, dragging);
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
                if let Some(tab) = st.tab_mut()
                    && let Some(tool) = tab.tools.get_mut(&kind) {
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
                if let Some(tab) = st.tab_mut()
                    && let Some(tool) = tab.tools.get_mut(&kind) {
                        tool.on_double_click(&mut tab.model, cx, cy);
                    }
            }));
        }
    };

    // --- Keyboard events ---
    let on_keydown = {
        let act = act.clone();
        let app_for_keys = app.clone();
        let revision_for_keys = revision;
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
                            if let Some(tab) = st.tab_mut()
                                && let Some(tool) = tab.tools.get_mut(&kind) {
                                    tool.on_key_event(&mut tab.model, &key_str, km);
                                }
                        }));
                        return;
                    }
                } else {
                    evt.prevent_default();
                    clipboard_read_and_paste(
                        app_for_keys.clone(),
                        revision_for_keys,
                        0.0,
                    );
                    return;
                }
            }

            match key {
                // --- Panel focus navigation ---
                Key::Tab if !tool_captures => {
                    evt.prevent_default();
                    if mods.shift() {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            st.workspace_layout.focus_prev_panel();
                        }));
                    } else {
                        (act.borrow_mut())(Box::new(|st: &mut AppState| {
                            st.workspace_layout.focus_next_panel();
                        }));
                    }
                }
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
                            let Some(tab) = st.tab() else { return; };
                            let doc = tab.model.document();
                            doc.selection.iter()
                                .filter_map(|es| doc.get_element(&es.path).cloned())
                                .collect::<Vec<_>>()
                        };
                        let Some(tab) = st.tab_mut() else { return; };
                        tab.clipboard = elements;
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
                            let Some(tab) = st.tab() else { return; };
                            let doc = tab.model.document();
                            doc.selection.iter()
                                .filter_map(|es| doc.get_element(&es.path).cloned())
                                .collect::<Vec<_>>()
                        };
                        let Some(tab) = st.tab_mut() else { return; };
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
                        revision_for_keys,
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
                    open_file_dialog(app_for_keys.clone(), revision_for_keys);
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
                        if let Some(tab) = st.tab_mut()
                            && let Some(tool) = tab.tools.get_mut(&kind) {
                                tool.on_key(&mut tab.model, "Escape");
                            }
                    }));
                }
                // --- Fill/Stroke shortcuts ---
                Key::Character(ref c) if c == "d" || c == "D" => {
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.reset_fill_stroke_defaults();
                    }));
                }
                Key::Character(ref c) if c == "x" && !cmd => {
                    // Toggle fill/stroke stacking
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.toggle_fill_on_top();
                    }));
                }
                Key::Character(ref c) if c == "X" && !cmd => {
                    // Shift+X: swap fill/stroke colors
                    (act.borrow_mut())(Box::new(|st: &mut AppState| {
                        st.swap_fill_stroke();
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
                        if let Some(tab) = st.tab_mut()
                            && let Some(tool) = tab.tools.get_mut(&kind) {
                                tool.on_key_up(&mut tab.model, " ");
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
    let slot_alternates = use_signal(|| {
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
    let drag_source = use_signal(|| Option::<super::workspace::DragPayload>::None);
    let drop_target_sig = use_signal(|| Option::<super::workspace::DropTarget>::None);
    let was_dropped = use_signal(|| false);
    let mut last_drag_pos = use_signal(|| (0.0f64, 0.0f64));
    // Floating dock title bar drag (dock_id, offset_x, offset_y).
    let mut title_drag = use_signal(|| Option::<(super::workspace::DockId, f64, f64)>::None);
    // Provide drag state via context for dock_panel components.
    use_context_provider(|| DragState {
        drag_source,
        drop_target: drop_target_sig,
        was_dropped,
        last_drag_pos,
        title_drag,
    });
    // Pane drag-and-drop state.
    // (pane_id, offset_x, offset_y)
    let mut pane_drag = use_signal(|| Option::<(super::workspace::PaneId, f64, f64)>::None);
    // (snap_idx, start_coord)
    let mut border_drag = use_signal(|| Option::<(usize, f64)>::None);
    // Pane edge resize: (pane_id, edge, start_mouse_x, start_mouse_y, start_pane_width, start_pane_height, start_pane_x, start_pane_y)
    let mut pane_resize = use_signal(|| Option::<(super::workspace::PaneId, super::workspace::EdgeSide, f64, f64, f64, f64, f64, f64)>::None);
    // Snap preview lines shown during drag
    let mut snap_preview = use_signal(Vec::<super::workspace::SnapConstraint>::new);

    // Read revision to trigger re-render when state changes.
    let _ = revision();

    // Ensure pane layout exists and repair snaps once on init.
    {
        let mut st = app.borrow_mut();
        if st.workspace_layout.pane_layout.is_none() {
            #[cfg(target_arch = "wasm32")]
            {
                if let Some(win) = web_sys::window() {
                    let vw = win.inner_width().ok().and_then(|v| v.as_f64()).unwrap_or(1000.0);
                    let vh = win.inner_height().ok().and_then(|v| v.as_f64()).unwrap_or(700.0);
                    st.workspace_layout.ensure_pane_layout(vw, vh);
                    if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                        pl.repair_snaps(vw, vh);
                    }
                }
            }
            #[cfg(not(target_arch = "wasm32"))]
            {
                st.workspace_layout.ensure_pane_layout(1000.0, 700.0);
                if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                    pl.repair_snaps(1000.0, 700.0);
                }
            }
        }
    }

    let active_tool = app.borrow().active_tool;
    let fill_on_top = app.borrow().fill_on_top;

    // Compute fill/stroke display state for toolbar widget.
    let (fs_fill_summary, fs_stroke_summary, fs_default_fill, fs_default_stroke) = {
        let st = app.borrow();
        let (fill_sum, stroke_sum, df, ds) = if let Some(tab) = st.tab() {
            let doc = tab.model.document();
            (
                selection_fill_summary(doc),
                selection_stroke_summary(doc),
                tab.model.default_fill,
                tab.model.default_stroke,
            )
        } else {
            (FillSummary::NoSelection, StrokeSummary::NoSelection, None, Some(Stroke::new(Color::BLACK, 1.0)))
        };
        (fill_sum, stroke_sum, df, ds)
    };

    // Per-frame cursor: tools may override (e.g. Type tool returns the
    // text-insertion SVG when hovering text, and "none" while editing).
    let canvas_cursor: String = {
        let st = app.borrow();
        st.tab()
            .and_then(|tab| tab.tools.get(&active_tool).and_then(|t| t.cursor_css_override()))
            .unwrap_or_else(|| active_tool.cursor_css().to_string())
    };
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
        let bg = if *is_active { THEME_BG_TAB } else { THEME_BG_TAB_INACTIVE };
        let border_bottom = if *is_active { "2px solid #4a4a4a" } else { "2px solid #555" };
        let display_name = name.clone();
        rsx! {
            div {
                key: "tab-{idx}",
                style: "display:inline-flex; align-items:center; padding:4px 8px; margin-right:1px; background:{bg}; border:1px solid {THEME_BORDER}; border-bottom:{border_bottom}; cursor:pointer; font-size:12px; color:{THEME_TEXT}; user-select:none;",
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
                            style: "margin-left:6px; color:{THEME_TEXT_BUTTON}; cursor:pointer; font-size:14px; line-height:1;",
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

    // --- Menu bar signals ---
    let mut open_menu = use_signal(|| Option::<String>::None);
    let workspace_submenu_open = use_signal(|| false);
    let save_as_dialog = use_signal(|| Option::<SaveAsDialog>::None);
    let color_picker_state = use_signal(|| Option::<super::color_picker::ColorPickerState>::None);

    // --- Build dock nodes ---
    use super::workspace::{DockEdge, DockId, DropTarget};
    #[cfg(target_arch = "wasm32")]
    use super::workspace::WorkspaceLayout;

    let layout_snapshot = app.borrow().workspace_layout.clone();
    let right_dock = layout_snapshot.anchored_dock(DockEdge::Right);
    let dock_collapsed = right_dock.is_none_or(|d| d.collapsed);
    let dock_id = right_dock.map_or(DockId(0), |d| d.id);

    // Dock collapse toggle
    let _dock_toggle_label = if dock_collapsed { "\u{25C0}" } else { "\u{25B6}" };

    // Snap indicator: show a highlight on the edge being targeted during drag
    let snap_edge = match drop_target_sig() {
        Some(DropTarget::Edge(edge)) => Some(edge),
        _ => None,
    };
    let snap_left = if snap_edge == Some(DockEdge::Left) { "4px solid #4a90d9" } else { "none" };
    let snap_right = if snap_edge == Some(DockEdge::Right) { "4px solid #4a90d9" } else { "none" };
    let snap_bottom = if snap_edge == Some(DockEdge::Bottom) { "4px solid #4a90d9" } else { "none" };

    // --- Pane positions ---
    use super::workspace::{PaneKind, PaneId, EdgeSide, SnapTarget, PaneLayout};

    let pane_snapshot = layout_snapshot.pane_layout.clone();
    let canvas_maximized = pane_snapshot.as_ref().is_some_and(|pl| pl.canvas_maximized);

    let (tx, ty, tw, th, toolbar_z) = pane_snapshot.as_ref()
        .and_then(|pl| pl.pane_by_kind(PaneKind::Toolbar))
        .map(|p| {
            let z = pane_snapshot.as_ref().unwrap().pane_z_index(p.id);
            // When canvas is maximized, toolbar floats on top
            let z = if canvas_maximized { z + 50 } else { z };
            (p.x, p.y, p.width, p.height, z)
        })
        .unwrap_or((0.0, 0.0, 72.0, 700.0, 0));
    let toolbar_pane_id = pane_snapshot.as_ref()
        .and_then(|pl| pl.pane_by_kind(PaneKind::Toolbar))
        .map(|p| p.id)
        .unwrap_or(PaneId(0));
    let toolbar_config = pane_snapshot.as_ref()
        .and_then(|pl| pl.pane_by_kind(PaneKind::Toolbar))
        .map(|p| p.config.clone())
        .unwrap_or_else(|| super::workspace::PaneConfig::for_kind(PaneKind::Toolbar));

    let (cx, cy, cw, ch, canvas_z) = pane_snapshot.as_ref()
        .and_then(|pl| pl.pane_by_kind(PaneKind::Canvas))
        .map(|p| {
            let pl = pane_snapshot.as_ref().unwrap();
            if canvas_maximized {
                (0.0, 0.0, pl.viewport_width, pl.viewport_height, 0)
            } else {
                (p.x, p.y, p.width, p.height, pl.pane_z_index(p.id))
            }
        })
        .unwrap_or((72.0, 0.0, 688.0, 700.0, 0));
    let canvas_pane_id = pane_snapshot.as_ref()
        .and_then(|pl| pl.pane_by_kind(PaneKind::Canvas))
        .map(|p| p.id)
        .unwrap_or(PaneId(1));
    let canvas_config = pane_snapshot.as_ref()
        .and_then(|pl| pl.pane_by_kind(PaneKind::Canvas))
        .map(|p| p.config.clone())
        .unwrap_or_else(|| super::workspace::PaneConfig::for_kind(PaneKind::Canvas));
    let canvas_border = if canvas_maximized { "none" } else { "1px solid #555" };

    let collapsed_dock_width = 36.0;
    let (dx, dy, dw, dh, dock_z) = pane_snapshot.as_ref()
        .and_then(|pl| pl.pane_by_kind(PaneKind::Dock))
        .map(|p| {
            let z = pane_snapshot.as_ref().unwrap().pane_z_index(p.id);
            let z = if canvas_maximized { z + 50 } else { z };
            if dock_collapsed {
                // Anchor collapsed dock at its right edge
                let right = p.x + p.width;
                (right - collapsed_dock_width, p.y, collapsed_dock_width, p.height, z)
            } else {
                (p.x, p.y, p.width, p.height, z)
            }
        })
        .unwrap_or((760.0, 0.0, 240.0, 700.0, 0));
    let dock_pane_id = pane_snapshot.as_ref()
        .and_then(|pl| pl.pane_by_kind(PaneKind::Dock))
        .map(|p| p.id)
        .unwrap_or(PaneId(2));
    let dock_config = pane_snapshot.as_ref()
        .and_then(|pl| pl.pane_by_kind(PaneKind::Dock))
        .map(|p| p.config.clone())
        .unwrap_or_else(|| super::workspace::PaneConfig::for_kind(PaneKind::Dock));

    // Collect shared border positions for rendering drag handles
    // Each entry: (snap_idx, x, y, w, h, cursor_css)
    let shared_borders: Vec<(usize, f64, f64, f64, f64, String)> = pane_snapshot.as_ref().map(|pl| {
        let mut borders = Vec::new();
        for (i, snap) in pl.snaps.iter().enumerate() {
            let (other_id, other_edge) = match snap.target {
                SnapTarget::Pane(pid, oe) => (pid, oe),
                _ => continue,
            };
            let is_vertical = snap.edge == EdgeSide::Right && other_edge == EdgeSide::Left;
            let is_horizontal = snap.edge == EdgeSide::Bottom && other_edge == EdgeSide::Top;
            if !is_vertical && !is_horizontal { continue; }
            let pane_a = match pl.pane(snap.pane) { Some(p) => p, None => continue };
            let pane_b = match pl.pane(other_id) { Some(p) => p, None => continue };
            // Skip borders where both panes are fixed-width (not draggable)
            if pane_a.config.fixed_width && pane_b.config.fixed_width { continue; }
            // Skip stale snaps where edges have separated
            if is_vertical && (pane_a.x + pane_a.width - pane_b.x).abs() > 1.0 { continue; }
            if is_horizontal && (pane_a.y + pane_a.height - pane_b.y).abs() > 1.0 { continue; }
            if is_vertical {
                let bx = pane_a.x + pane_a.width;
                let by = pane_a.y.max(pane_b.y);
                let bh = (pane_a.y + pane_a.height).min(pane_b.y + pane_b.height) - by;
                if bh > 0.0 { borders.push((i, bx - 3.0, by, 6.0, bh, "col-resize".to_string())); }
            } else {
                let by = pane_a.y + pane_a.height;
                let bx = pane_a.x.max(pane_b.x);
                let bw = (pane_a.x + pane_a.width).min(pane_b.x + pane_b.width) - bx;
                if bw > 0.0 { borders.push((i, bx, by - 3.0, bw, 6.0, "row-resize".to_string())); }
            }
        }
        borders
    }).unwrap_or_default();

    // Snap preview lines: (x, y, width, height)
    let snap_lines: Vec<(f64, f64, f64, f64)> = snap_preview().iter().filter_map(|snap| {
        let pl = pane_snapshot.as_ref()?;
        let pane = pl.pane(snap.pane)?;
        let coord = PaneLayout::pane_edge_coord(pane, snap.edge);
        match snap.edge {
            EdgeSide::Left | EdgeSide::Right => Some((coord - 2.0, pane.y, 4.0, pane.height)),
            EdgeSide::Top | EdgeSide::Bottom => Some((pane.x, coord - 2.0, pane.width, 4.0)),
        }
    }).collect();

    rsx! {
        style { r#"
            html, body {{ margin: 0; padding: 0; overflow: hidden; width: 100%; height: 100%; }}
            #main {{ height: 100%; }}
            .jas-menu-title:hover {{ background: {THEME_BG_ACTIVE}; }}
            .jas-menu-item:hover {{ background: {THEME_BG_ACTIVE}; }}
            .jas-tool-popup-item:hover {{ background: #606060 !important; }}
            .jas-dock-group {{ transition: max-height 0.15s ease, opacity 0.15s ease; }}
            .jas-dock {{ transition: width 0.15s ease; }}
            .jas-floating-dock {{ transition: opacity 0.15s ease; }}
            .jas-tab:hover {{ background: #505050 !important; }}
            .jas-border-handle {{ background: transparent; }}
            .jas-border-handle:hover {{ background: rgba(74,144,217,0.3); }}
            .jas-border-handle:active {{ background: rgba(74,144,217,0.5); }}
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
                let app = app.clone();
                move |evt: Event<MouseData>| {
                    let coords = evt.data().page_coordinates();
                    // Floating dock title bar drag
                    if let Some((fid, off_x, off_y)) = title_drag() {
                        (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                            st.workspace_layout.set_floating_position(fid, coords.x - off_x, coords.y - off_y);
                        }));
                        return;
                    }
                    // Pane drag (move with live snapping)
                    if let Some((pid, off_x, off_y)) = pane_drag() {
                        let new_x = coords.x - off_x;
                        let new_y = coords.y - off_y;
                        (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                            if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                // Move to raw mouse position first
                                pl.set_pane_position(pid, new_x, new_y);
                                // Detect snaps at raw position
                                let vw = pl.viewport_width;
                                let vh = pl.viewport_height;
                                let preview = pl.detect_snaps(pid, vw, vh);
                                // If snaps found, align pane to snap targets immediately
                                if !preview.is_empty() {
                                    pl.align_to_snaps(pid, &preview, vw, vh);
                                }
                                snap_preview.set(preview);
                            }
                        }));
                        return;
                    }
                    // Shared border drag
                    if let Some((snap_idx, start_coord)) = border_drag() {
                        // Read snap direction from live state (not stale snapshot)
                        let is_vert = {
                            let st = app.borrow();
                            st.workspace_layout.pane_layout.as_ref()
                                .and_then(|pl| pl.snaps.get(snap_idx))
                                .map(|s| s.edge == EdgeSide::Right)
                                .unwrap_or(true)
                        };
                        let delta = if is_vert { coords.x - start_coord } else { coords.y - start_coord };
                        let new_start = if is_vert { coords.x } else { coords.y };
                        border_drag.set(Some((snap_idx, new_start)));
                        (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                            if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                pl.drag_shared_border(snap_idx, delta);
                            }
                        }));
                        return;
                    }
                    // Pane edge resize
                    if let Some((pid, edge, start_mx, start_my, start_w, start_h, start_px, start_py)) = pane_resize() {
                        (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                            if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                let dx = coords.x - start_mx;
                                let dy = coords.y - start_my;
                                match edge {
                                    EdgeSide::Right => {
                                        pl.resize_pane(pid, start_w + dx, start_h);
                                    }
                                    EdgeSide::Left => {
                                        let new_w = (start_w - dx).max(
                                            pl.pane(pid).map(|p| p.config.min_width).unwrap_or(200.0)
                                        );
                                        let actual_dx = start_w - new_w;
                                        if let Some(p) = pl.pane_mut(pid) {
                                            p.x = start_px + actual_dx;
                                            p.width = new_w;
                                        }
                                    }
                                    EdgeSide::Bottom => {
                                        pl.resize_pane(pid, start_w, start_h + dy);
                                    }
                                    EdgeSide::Top => {
                                        let new_h = (start_h - dy).max(
                                            pl.pane(pid).map(|p| p.config.min_height).unwrap_or(200.0)
                                        );
                                        let actual_dy = start_h - new_h;
                                        if let Some(p) = pl.pane_mut(pid) {
                                            p.y = start_py + actual_dy;
                                            p.height = new_h;
                                        }
                                    }
                                }
                            }
                        }));
                    }
                }
            },
            onmouseup: {
                let act = act.clone();
                move |_| {
                    // Finalize pane drag: apply snaps
                    if let Some((pid, _, _)) = pane_drag() {
                        let preview = snap_preview();
                        if !preview.is_empty() {
                            (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                    let vw = pl.viewport_width;
                                    let vh = pl.viewport_height;
                                    pl.apply_snaps(pid, preview, vw, vh);
                                }
                            }));
                        }
                        snap_preview.set(vec![]);
                    }
                    pane_drag.set(None);
                    border_drag.set(None);
                    pane_resize.set(None);
                    title_drag.set(None);
                }
            },
            ondragover: move |evt: Event<DragData>| {
                // Track drag position and detect edge snapping
                let coords = evt.data().page_coordinates();
                last_drag_pos.set((coords.x, coords.y));
                // Check if near a screen edge for snap-to-dock
                #[cfg(target_arch = "wasm32")]
                {
                    if let Some(win) = web_sys::window() {
                        let vw = win.inner_width().ok().and_then(|v| v.as_f64()).unwrap_or(1000.0);
                        let vh = win.inner_height().ok().and_then(|v| v.as_f64()).unwrap_or(700.0);
                        if let Some(edge) = WorkspaceLayout::is_near_edge(coords.x, coords.y, vw, vh) {
                            drop_target_sig.set(Some(DropTarget::Edge(edge)));
                        }
                    }
                }
            },
            style: "position:relative; width:100%; height:100%; overflow:hidden; outline:none; font-family:sans-serif; background:{THEME_BG_DARK}; border-left:{snap_left}; border-right:{snap_right}; border-bottom:{snap_bottom}; box-sizing:border-box; display:flex; flex-direction:column;",

            // ===== Menu bar (full width, top of window) =====
            MenuBarView {
                open_menu,
                workspace_submenu_open,
                save_as_dialog,
            }

            // ===== Pane container (fills remaining space) =====
            div {
                style: "flex:1; position:relative; overflow:hidden;",

            // ===== Toolbar pane (position:absolute) =====
            if pane_snapshot.as_ref().is_some_and(|pl| pl.is_pane_visible(PaneKind::Toolbar)) {
            div {
                style: "position:absolute; left:{tx}px; top:{ty}px; width:{tw}px; height:{th}px; z-index:{toolbar_z}; display:flex; flex-direction:column; overflow:hidden; background:{THEME_BG}; border:1px solid {THEME_BORDER}; box-sizing:border-box;",
                onmousedown: {
                    let act = act.clone();
                    move |_| {
                        open_menu.set(None);
                        (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                            if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                pl.bring_pane_to_front(toolbar_pane_id);
                            }
                        }));
                    }
                },

                // Title bar
                div {
                    style: "height:20px; min-height:20px; cursor:grab; background:{THEME_BG_DARK}; flex-shrink:0; display:flex; align-items:center; padding:0 4px; user-select:none;",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        let coords = evt.data().page_coordinates();
                        pane_drag.set(Some((toolbar_pane_id, coords.x - tx, coords.y - ty)));
                    },
                    { let lbl = toolbar_config.label.clone(); rsx! {
                        div { style: "flex:1; font-size:10px; color:{THEME_TEXT_DIM}; overflow:hidden; white-space:nowrap;", "{lbl}" }
                    }}
                    {
                        let act = act.clone();
                        rsx! {
                            div {
                                style: "cursor:pointer; font-size:12px; color:{THEME_TEXT_BUTTON}; padding:0 2px;",
                                onmousedown: move |evt: Event<MouseData>| {
                                    evt.stop_propagation();
                                    (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                        if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                            pl.hide_pane(PaneKind::Toolbar);
                                        }
                                    }));
                                },
                                "\u{00D7}" // ×
                            }
                        }
                    }
                }

                // Tool buttons and popup
                ToolbarGrid {
                    active_tool,
                    slot_alternates,
                    popup_slot,
                }

                // --- Fill/Stroke indicator widget ---
                FillStrokeWidgetView {
                    fill_summary: fs_fill_summary.clone(),
                    stroke_summary: fs_stroke_summary.clone(),
                    default_fill: fs_default_fill,
                    default_stroke: fs_default_stroke,
                    fill_on_top,
                    color_picker_state,
                }

                // Toolbar width is not resizable
            }
            } // close toolbar visibility if

            // ===== Canvas pane (position:absolute) =====
            div {
                style: "position:absolute; left:{cx}px; top:{cy}px; width:{cw}px; height:{ch}px; z-index:{canvas_z}; display:flex; flex-direction:column; overflow:hidden; background:{THEME_BG}; border:{canvas_border}; box-sizing:border-box;",
                onmousedown: {
                    let act = act.clone();
                    move |_: Event<MouseData>| {
                        open_menu.set(None);
                        popup_slot.set(None);
                        if !canvas_maximized {
                            (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                    pl.bring_pane_to_front(canvas_pane_id);
                                }
                            }));
                        }
                    }
                },

                // Title bar (hidden when maximized)
                if !canvas_maximized {
                    div {
                        style: "height:20px; min-height:20px; cursor:grab; background:{THEME_BG_DARK}; flex-shrink:0; display:flex; align-items:center; padding:0 4px; user-select:none;",
                        onmousedown: move |evt: Event<MouseData>| {
                            evt.stop_propagation();
                            let coords = evt.data().page_coordinates();
                            pane_drag.set(Some((canvas_pane_id, coords.x - cx, coords.y - cy)));
                        },
                        ondoubleclick: {
                            let act = act.clone();
                            let can_maximize = canvas_config.double_click_action == super::workspace::DoubleClickAction::Maximize;
                            move |evt: Event<MouseData>| {
                                if !can_maximize { return; }
                                evt.stop_propagation();
                                pane_drag.set(None);
                                (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                    if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                        pl.toggle_canvas_maximized();
                                    }
                                }));
                            }
                        },
                        { let lbl = canvas_config.label.clone(); rsx! {
                            div { style: "flex:1; font-size:10px; color:{THEME_TEXT}; overflow:hidden; white-space:nowrap;", "{lbl}" }
                        }}
                    }
                }

                // Tab bar
                div {
                    style: "display:flex; background:{THEME_BG_DARK}; border-bottom:1px solid {THEME_BORDER}; padding:2px 4px 0; min-height:28px; align-items:flex-end; flex-shrink:0;",
                    for btn in tab_buttons {
                        {btn}
                    }
                }

                // Canvas
                div {
                    style: "flex:1; position:relative; overflow:hidden;",
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

                // Edge resize handles (always present; shared border handles
                // at z-index:100 take priority when they exist)
                div {
                    style: "position:absolute; top:0; left:0; width:4px; height:100%; cursor:ew-resize;",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        let coords = evt.data().page_coordinates();
                        pane_resize.set(Some((canvas_pane_id, EdgeSide::Left, coords.x, coords.y, cw, ch, cx, cy)));
                    },
                }
                div {
                    style: "position:absolute; top:0; right:0; width:4px; height:100%; cursor:ew-resize;",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        let coords = evt.data().page_coordinates();
                        pane_resize.set(Some((canvas_pane_id, EdgeSide::Right, coords.x, coords.y, cw, ch, cx, cy)));
                    },
                }
            }
            // (canvas pane is always visible, no close button)

            // ===== Dock pane (position:absolute) =====
            if pane_snapshot.as_ref().is_some_and(|pl| pl.is_pane_visible(PaneKind::Dock)) {
            div {
                style: "position:absolute; left:{dx}px; top:{dy}px; width:{dw}px; height:{dh}px; z-index:{dock_z}; display:flex; flex-direction:column; overflow:hidden; background:{THEME_BG}; border:1px solid {THEME_BORDER}; box-sizing:border-box;",
                onmousedown: {
                    let act = act.clone();
                    move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                            if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                pl.bring_pane_to_front(dock_pane_id);
                            }
                        }));
                    }
                },

                // Title bar with collapse chevron and close button
                div {
                    style: "height:20px; min-height:20px; cursor:grab; background:{THEME_BG_DARK}; flex-shrink:0; display:flex; align-items:center; padding:0 4px; user-select:none; border-bottom:1px solid {THEME_BORDER};",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        let coords = evt.data().page_coordinates();
                        pane_drag.set(Some((dock_pane_id, coords.x - dx, coords.y - dy)));
                    },
                    { let lbl = dock_config.label.clone(); rsx! {
                        div { style: "flex:1; font-size:10px; color:{THEME_TEXT_DIM}; overflow:hidden; white-space:nowrap;", "{lbl}" }
                    }}
                    // Collapse chevron (if collapsed_width is set)
                    if dock_config.collapsed_width.is_some() {
                        {
                            let act = act.clone();
                            let chevron = if dock_collapsed { "\u{00BB}" } else { "\u{00AB}" }; // >> or <<
                            rsx! {
                                div {
                                    style: "cursor:pointer; font-size:12px; color:{THEME_TEXT_BUTTON}; padding:0 4px;",
                                    title: "Collapse",
                                    onmousedown: move |evt: Event<MouseData>| {
                                        evt.stop_propagation();
                                        (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                            st.workspace_layout.toggle_dock_collapsed(dock_id);
                                        }));
                                    },
                                    "{chevron}"
                                }
                            }
                        }
                    }
                    // Close button
                    {
                        let act = act.clone();
                        rsx! {
                            div {
                                style: "cursor:pointer; font-size:12px; color:{THEME_TEXT_BUTTON}; padding:0 2px;",
                                onmousedown: move |evt: Event<MouseData>| {
                                    evt.stop_propagation();
                                    (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                        if let Some(ref mut pl) = st.workspace_layout.pane_layout {
                                            pl.hide_pane(PaneKind::Dock);
                                        }
                                    }));
                                },
                                "\u{00D7}" // x
                            }
                        }
                    }
                }

                // Panel groups
                div {
                    style: "flex:1; overflow-y:auto;",
                    DockGroupsView {}
                }

                // Left edge resize handle
                div {
                    style: "position:absolute; top:0; left:0; width:4px; height:100%; cursor:ew-resize;",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        let coords = evt.data().page_coordinates();
                        pane_resize.set(Some((dock_pane_id, EdgeSide::Left, coords.x, coords.y, dw, dh, dx, dy)));
                    },
                }
            }
            } // close dock visibility if

            // ===== Shared border drag handles =====
            for (snap_idx, bx, by, bw, bh, cursor_css) in shared_borders {
                {
                    let is_vert = cursor_css == "col-resize";
                    rsx! {
                        div {
                            key: "border-{snap_idx}",
                            class: "jas-border-handle",
                            style: "position:absolute; left:{bx}px; top:{by}px; width:{bw}px; height:{bh}px; cursor:{cursor_css}; z-index:100;",
                            onmousedown: move |evt: Event<MouseData>| {
                                evt.stop_propagation();
                                let coords = evt.data().page_coordinates();
                                let start = if is_vert { coords.x } else { coords.y };
                                border_drag.set(Some((snap_idx, start)));
                            },
                        }
                    }
                }
            }

            // ===== Snap preview lines =====
            for (i, (sl_x, sl_y, sl_w, sl_h)) in snap_lines.iter().enumerate() {
                div {
                    key: "snap-line-{i}",
                    style: "position:absolute; left:{sl_x}px; top:{sl_y}px; width:{sl_w}px; height:{sl_h}px; background:rgba(50,120,220,0.8); pointer-events:none; z-index:200;",
                }
            }

            // Floating docks (position:fixed overlays)
            FloatingDocksView {}

            } // close pane container div

            // Save As dialog
            SaveAsDialogView { save_as_dialog }

            // Color Picker dialog
            ColorPickerDialogView { color_picker_state }
        }
    }
}
