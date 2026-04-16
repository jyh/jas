//! Application state types extracted from `app.rs`.
//!
//! Contains `TabState`, `AppState`, and the `Act` / `AppHandle` type aliases.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use web_sys::{CanvasRenderingContext2d, HtmlCanvasElement};
use wasm_bindgen::JsCast;

use crate::canvas::render;
use crate::document::controller::Controller;
use crate::document::model::Model;
use crate::geometry::element::{Color, Fill, Stroke, LineCap, LineJoin, StrokeAlign, Arrowhead, ArrowAlign, Element as GeoElement};
use crate::tools::partial_selection_tool::PartialSelectionTool;
use crate::tools::interior_selection_tool::InteriorSelectionTool;
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
use crate::tools::tool::{CanvasTool, ToolKind};

/// Shared application state handle, available via `use_context::<AppHandle>()`.
pub(crate) type AppHandle = Rc<RefCell<AppState>>;

/// Universal state mutation handle, available via `use_context::<Act>()`.
/// Call `(act.0.borrow_mut())(Box::new(|st| { ... }))` to mutate AppState.
#[derive(Clone)]
pub(crate) struct Act(pub Rc<RefCell<dyn FnMut(Box<dyn FnOnce(&mut AppState)>)>>);

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

    pub(crate) fn with_model(model: Model) -> Self {
        let mut tools: HashMap<ToolKind, Box<dyn CanvasTool>> = HashMap::new();
        tools.insert(ToolKind::Selection, Box::new(SelectionTool::new()));
        tools.insert(ToolKind::PartialSelection, Box::new(PartialSelectionTool::new()));
        tools.insert(ToolKind::InteriorSelection, Box::new(InteriorSelectionTool::new()));
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
    /// Color panel mode (panel-local, not persisted).
    pub(crate) color_panel_mode: super::color_panel_view::ColorMode,
    /// App-level default fill (used when no document is open).
    pub(crate) app_default_fill: Option<Fill>,
    /// App-level default stroke (used when no document is open).
    pub(crate) app_default_stroke: Option<Stroke>,
    /// Mutable swatch libraries (initialized from workspace data).
    pub(crate) swatch_libraries: serde_json::Value,
    /// Stroke panel state — mirrored to/from global state for selection sync.
    pub(crate) stroke_panel: StrokePanelState,
    /// Element path currently being renamed in the layers panel, or None.
    pub(crate) layers_renaming: Option<Vec<usize>>,
    /// Collapsed element paths in the layers panel. Elements not in this
    /// set are expanded (open) by default.
    pub(crate) layers_collapsed: std::collections::HashSet<Vec<usize>>,
    /// Panel-selected element paths in the layers panel. Independent of
    /// element selection (select square). Used for menu operations and drag.
    pub(crate) layers_panel_selection: Vec<Vec<usize>>,
    /// Active drag in the layers panel: drop target path and position.
    /// The drop inserts before the element at this path.
    pub(crate) layers_drag_target: Option<Vec<usize>>,
    /// Context menu state: (screen_x, screen_y, right-clicked element path).
    pub(crate) layers_context_menu: Option<(f64, f64, Vec<usize>)>,
    /// Layers panel search query (case-insensitive name filter).
    pub(crate) layers_search_query: String,
    /// Isolation mode stack. Each entry is the path of a container that
    /// has been entered. Panel and canvas restrict interaction to
    /// descendants of the deepest (last) isolated container.
    pub(crate) layers_isolation_stack: Vec<Vec<usize>>,
    /// Solo visibility state: when Option-clicking the eye button, the
    /// clicked element's siblings get saved and hidden. Second Option-click
    /// on the same element restores them. Map from sibling path to saved
    /// visibility state. None when no solo is active.
    pub(crate) layers_solo_state: Option<LayerSoloState>,
}

/// Solo/unsolo state for the layers panel.
#[derive(Debug, Clone)]
pub(crate) struct LayerSoloState {
    /// Path of the element that was Option-clicked (the soloed sibling).
    pub(crate) soloed_path: Vec<usize>,
    /// Saved visibility of each sibling before solo.
    pub(crate) saved: std::collections::HashMap<Vec<usize>, crate::geometry::element::Visibility>,
}

/// Stroke panel state fields that sync with global state and the selection.
#[derive(Debug, Clone)]
pub(crate) struct StrokePanelState {
    pub cap: String,
    pub join: String,
    pub miter_limit: f64,
    pub align: String,
    pub dashed: bool,
    pub dash_1: f64,
    pub gap_1: f64,
    pub dash_2: Option<f64>,
    pub gap_2: Option<f64>,
    pub dash_3: Option<f64>,
    pub gap_3: Option<f64>,
    pub start_arrowhead: String,
    pub end_arrowhead: String,
    pub start_arrowhead_scale: f64,
    pub end_arrowhead_scale: f64,
    pub link_arrowhead_scale: bool,
    pub arrow_align: String,
    pub profile: String,
    pub profile_flipped: bool,
}

impl Default for StrokePanelState {
    fn default() -> Self {
        Self {
            cap: "butt".into(),
            join: "miter".into(),
            miter_limit: 10.0,
            align: "center".into(),
            dashed: false,
            dash_1: 12.0,
            gap_1: 12.0,
            dash_2: None,
            gap_2: None,
            dash_3: None,
            gap_3: None,
            start_arrowhead: "none".into(),
            end_arrowhead: "none".into(),
            start_arrowhead_scale: 100.0,
            end_arrowhead_scale: 100.0,
            link_arrowhead_scale: false,
            arrow_align: "tip_at_end".into(),
            profile: "uniform".into(),
            profile_flipped: false,
        }
    }
}

impl AppState {
    pub(crate) fn new() -> Self {
        let app_config = Self::load_app_config();
        let workspace_layout = Self::load_or_migrate_workspace(&app_config);
        // Restore tabs from previous session, if any.
        let (tabs, active_tab) =
            if let Some((saved_active, restored)) = super::session::load_session() {
                let tabs: Vec<TabState> = restored
                    .into_iter()
                    .map(|(filename, doc)| TabState::with_model(Model::new(doc, Some(filename))))
                    .collect();
                let active = saved_active.min(tabs.len().saturating_sub(1));
                (tabs, active)
            } else {
                (vec![], 0)
            };

        Self {
            tabs,
            active_tab,
            active_tool: ToolKind::Selection,
            app_config,
            workspace_layout,
            fill_on_top: true,
            color_panel_mode: super::color_panel_view::ColorMode::Hsb,
            app_default_fill: Some(Fill::new(Color::WHITE)),
            app_default_stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            swatch_libraries: crate::interpreter::workspace::Workspace::load()
                .map(|ws| ws.data().get("swatch_libraries").cloned().unwrap_or(serde_json::json!({})))
                .unwrap_or(serde_json::json!({})),
            stroke_panel: StrokePanelState::default(),
            layers_renaming: None,
            layers_collapsed: std::collections::HashSet::new(),
            layers_panel_selection: Vec::new(),
            layers_drag_target: None,
            layers_context_menu: None,
            layers_search_query: String::new(),
            layers_isolation_stack: Vec::new(),
            layers_solo_state: None,
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
    pub(crate) fn save_app_config(&self) {
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
    pub(crate) fn save_workspace_layout(&self) {
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
            // Capture the active appearance from JS before serializing.
            let active_appearance = js_sys::eval("getActiveAppearance()")
                .ok()
                .and_then(|v| v.as_string())
                .unwrap_or_else(|| "dark_gray".to_string());
            self.workspace_layout.appearance = active_appearance;

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
        // Restore the saved appearance for this layout.
        #[cfg(target_arch = "wasm32")]
        {
            let appearance = self.workspace_layout.appearance.clone();
            let _ = js_sys::eval(&format!("applyAppearance('{}')", appearance));
        }
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
    pub(crate) fn toggle_fill_on_top(&mut self) {
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

    /// Set the active color (fill or stroke, per fill_on_top) and push to recent colors.
    pub(crate) fn set_active_color(&mut self, color: Color) {
        // Always update app-level defaults
        if self.fill_on_top {
            self.app_default_fill = Some(Fill::new(color));
        } else {
            let width = self.app_default_stroke.map(|s| s.width).unwrap_or(1.0);
            self.app_default_stroke = Some(Stroke::new(color, width));
        }
        // Update per-tab state if a document is open
        if let Some(tab) = self.tabs.get_mut(self.active_tab) {
            if self.fill_on_top {
                tab.model.default_fill = Some(Fill::new(color));
                if !tab.model.document().selection.is_empty() {
                    tab.model.snapshot();
                    Controller::set_selection_fill(&mut tab.model, Some(Fill::new(color)));
                }
            } else {
                let width = tab.model.default_stroke.map(|s| s.width).unwrap_or(1.0);
                tab.model.default_stroke = Some(Stroke::new(color, width));
                if !tab.model.document().selection.is_empty() {
                    tab.model.snapshot();
                    Controller::set_selection_stroke(&mut tab.model, Some(Stroke::new(color, width)));
                }
            }
            // Push to recent colors (move-to-front dedup, max 10)
            let hex = color.to_hex();
            if let Some(pos) = tab.model.recent_colors.iter().position(|c| c == &hex) {
                tab.model.recent_colors.remove(pos);
            }
            tab.model.recent_colors.insert(0, hex);
            tab.model.recent_colors.truncate(10);
        }
    }

    /// Set the active color (fill or stroke, per fill_on_top) without pushing to recent colors.
    /// Used for live slider drag updates.
    pub(crate) fn set_active_color_live(&mut self, color: Color) {
        if let Some(tab) = self.tabs.get_mut(self.active_tab) {
            if self.fill_on_top {
                tab.model.default_fill = Some(Fill::new(color));
            } else {
                let width = tab.model.default_stroke.map(|s| s.width).unwrap_or(1.0);
                tab.model.default_stroke = Some(Stroke::new(color, width));
            }
        }
    }

    /// Apply the current stroke panel state to the selected element(s).
    /// Builds a Stroke from the panel fields and calls set_selection_stroke.
    pub(crate) fn apply_stroke_panel_to_selection(&mut self) {
        let sp = &self.stroke_panel;
        if let Some(tab) = self.tabs.get_mut(self.active_tab) {
            // Color/opacity come from the selected element (preserve what's there).
            // Width comes from the default stroke (updated by the weight input).
            let sel_stroke = {
                let doc = tab.model.document();
                doc.selection.first()
                    .and_then(|es| doc.get_element(&es.path))
                    .and_then(|e| e.stroke().cloned())
            };
            let default_stroke = tab.model.default_stroke.or(self.app_default_stroke);
            let current_stroke = sel_stroke.or(default_stroke);
            if let Some(base) = current_stroke {
                // Use the default stroke width (set by weight input), not the
                // selected element's width which may not have been updated yet.
                let width = default_stroke.map(|s| s.width).unwrap_or(base.width);
                let linecap = match sp.cap.as_str() {
                    "round" => LineCap::Round,
                    "square" => LineCap::Square,
                    _ => LineCap::Butt,
                };
                let linejoin = match sp.join.as_str() {
                    "round" => LineJoin::Round,
                    "bevel" => LineJoin::Bevel,
                    _ => LineJoin::Miter,
                };
                // Build dash pattern from panel state
                let mut dash_pattern = [0.0f64; 6];
                let mut dash_len: u8 = 0;
                if sp.dashed {
                    dash_pattern[0] = sp.dash_1;
                    dash_pattern[1] = sp.gap_1;
                    dash_len = 2;
                    if let (Some(d), Some(g)) = (sp.dash_2, sp.gap_2) {
                        dash_pattern[2] = d;
                        dash_pattern[3] = g;
                        dash_len = 4;
                    }
                    if let (Some(d), Some(g)) = (sp.dash_3, sp.gap_3) {
                        dash_pattern[4] = d;
                        dash_pattern[5] = g;
                        dash_len = 6;
                    }
                }
                let new_stroke = Stroke {
                    color: base.color,
                    width,
                    linecap,
                    linejoin,
                    miter_limit: sp.miter_limit,
                    align: match sp.align.as_str() {
                        "inside" => StrokeAlign::Inside,
                        "outside" => StrokeAlign::Outside,
                        _ => StrokeAlign::Center,
                    },
                    dash_pattern,
                    dash_len,
                    start_arrow: Arrowhead::from_str(&sp.start_arrowhead),
                    end_arrow: Arrowhead::from_str(&sp.end_arrowhead),
                    start_arrow_scale: sp.start_arrowhead_scale,
                    end_arrow_scale: sp.end_arrowhead_scale,
                    arrow_align: if sp.arrow_align == "center_at_end" {
                        ArrowAlign::CenterAtEnd
                    } else {
                        ArrowAlign::TipAtEnd
                    },
                    opacity: base.opacity,
                };
                // Update default stroke
                tab.model.default_stroke = Some(new_stroke);
                self.app_default_stroke = Some(new_stroke);
                // Apply to selection
                if !tab.model.document().selection.is_empty() {
                    tab.model.snapshot();
                    Controller::set_selection_stroke(&mut tab.model, Some(new_stroke));
                    // Apply width profile
                    let width_pts = crate::geometry::element::profile_to_width_points(
                        &sp.profile, width, sp.profile_flipped,
                    );
                    Controller::set_selection_width_profile(&mut tab.model, width_pts);
                }
            }
        }
    }

    /// Sync stroke panel state from the first selected element's stroke.
    /// Called after selection changes so the panel reflects the selection.
    pub(crate) fn sync_stroke_panel_from_selection(&mut self) {
        let stroke = if let Some(tab) = self.tab() {
            let doc = tab.model.document();
            if let Some(es) = doc.selection.first() {
                doc.get_element(&es.path).and_then(|e| e.stroke().cloned())
            } else {
                None
            }
        } else {
            None
        };
        if let Some(s) = stroke {
            self.stroke_panel.cap = match s.linecap {
                LineCap::Butt => "butt",
                LineCap::Round => "round",
                LineCap::Square => "square",
            }.into();
            self.stroke_panel.join = match s.linejoin {
                LineJoin::Miter => "miter",
                LineJoin::Round => "round",
                LineJoin::Bevel => "bevel",
            }.into();
            // Update default stroke to match selection
            if let Some(tab) = self.tabs.get_mut(self.active_tab) {
                tab.model.default_stroke = Some(s);
            }
            self.app_default_stroke = Some(s);
        }
    }

    /// Get the active color (fill or stroke, per fill_on_top).
    /// Falls back to app-level defaults when no document is open.
    pub(crate) fn active_color(&self) -> Option<Color> {
        if let Some(tab) = self.tab() {
            if self.fill_on_top {
                tab.model.default_fill.map(|f| f.color)
            } else {
                tab.model.default_stroke.map(|s| s.color)
            }
        } else {
            if self.fill_on_top {
                self.app_default_fill.map(|f| f.color)
            } else {
                self.app_default_stroke.map(|s| s.color)
            }
        }
    }

    /// Get recent colors for the active tab.
    pub(crate) fn recent_colors(&self) -> &[String] {
        self.tab()
            .map(|tab| tab.model.recent_colors.as_slice())
            .unwrap_or(&[])
    }

    pub(crate) fn repaint(&self) {
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
