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
    /// Character panel state — panel-local; pushed to selected Text /
    /// TextPath via apply_character_panel_to_selection.
    pub(crate) character_panel: CharacterPanelState,
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
    /// Saved lock states for unlock-on-container. When a container is
    /// locked, each direct child's current lock state is saved here so
    /// unlocking restores them. Outer key: container path. Inner Vec:
    /// one entry per direct child.
    pub(crate) layers_saved_lock_states: std::collections::HashMap<Vec<usize>, Vec<bool>>,
    /// Set of element types currently hidden by the layers type filter.
    /// Type names: layer, group, path, rect, circle, ellipse, polyline,
    /// polygon, text, textpath, line. When empty (default), all types
    /// are shown. When non-empty, matching element types are hidden.
    pub(crate) layers_hidden_types: std::collections::HashSet<String>,
    /// Whether the type filter dropdown is open.
    pub(crate) layers_filter_dropdown_open: bool,
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

/// Character panel state fields — mirror the panel-local state
/// declared in `workspace/panels/character.yaml`. Written to by the
/// renderer when the user edits a Character panel control; read by
/// `apply_character_panel_to_selection` to push the attributes onto
/// the selected Text / TextPath element via
/// `Controller::set_character_attribute`.
#[derive(Debug, Clone)]
pub(crate) struct CharacterPanelState {
    pub font_family: String,
    pub style_name: String,
    pub font_size: f64,
    pub leading: f64,
    /// Kerning — accepts named modes `Auto` / `Optical` / `Metrics`
    /// (stored verbatim, pass through to the element attribute), or a
    /// numeric string in 1/1000 em (e.g. `"25"`). Empty / `"0"` /
    /// `"Auto"` all round-trip to an empty element attribute, matching
    /// the identity-omission rule.
    pub kerning: String,
    pub tracking: f64,
    pub vertical_scale: f64,
    pub horizontal_scale: f64,
    pub baseline_shift: f64,
    pub character_rotation: f64,
    pub all_caps: bool,
    pub small_caps: bool,
    pub superscript: bool,
    pub subscript: bool,
    pub underline: bool,
    pub strikethrough: bool,
    pub language: String,
    pub anti_aliasing: String,
    pub snap_to_glyph_visible: bool,
    pub snap_baseline: bool,
    pub snap_x_height: bool,
    pub snap_glyph_bounds: bool,
    pub snap_proximity_guides: bool,
    pub snap_angular_guides: bool,
    pub snap_anchor_point: bool,
}

impl Default for CharacterPanelState {
    fn default() -> Self {
        Self {
            font_family: "sans-serif".into(),
            style_name: "Regular".into(),
            font_size: 12.0,
            leading: 14.4,
            kerning: String::new(),
            tracking: 0.0,
            vertical_scale: 100.0,
            horizontal_scale: 100.0,
            baseline_shift: 0.0,
            character_rotation: 0.0,
            all_caps: false,
            small_caps: false,
            superscript: false,
            subscript: false,
            underline: false,
            strikethrough: false,
            language: "en".into(),
            anti_aliasing: "Sharp".into(),
            snap_to_glyph_visible: true,
            snap_baseline: false,
            snap_x_height: false,
            snap_glyph_bounds: false,
            snap_proximity_guides: false,
            snap_angular_guides: false,
            snap_anchor_point: false,
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
            character_panel: CharacterPanelState::default(),
            layers_renaming: None,
            layers_collapsed: std::collections::HashSet::new(),
            layers_panel_selection: Vec::new(),
            layers_drag_target: None,
            layers_context_menu: None,
            layers_search_query: String::new(),
            layers_isolation_stack: Vec::new(),
            layers_solo_state: None,
            layers_saved_lock_states: std::collections::HashMap::new(),
            layers_hidden_types: std::collections::HashSet::new(),
            layers_filter_dropdown_open: false,
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

    /// Push the current Character panel state to the selected text
    /// element(s). For an object-level selection (whole element), write
    /// directly to the parent Text/TextPath's attributes so the canvas
    /// renderer — which reads the parent's attributes — reflects the
    /// change. Tspan-range writes (via
    /// `Controller::set_character_attribute`) come back when partial
    /// tspan selections are supported.
    ///
    /// Currently wires `font_family`, `font_size`, and `text_decoration`
    /// (from the Underline / Strikethrough toggles). Remaining
    /// Character-panel fields (All Caps, Small Caps, Super/Sub,
    /// kerning, tracking, scales, baseline shift, rotation, language,
    /// anti-alias, Snap to Glyph) stay in panel-local state until their
    /// SVG-attribute plumbing lands.
    ///
    /// No-op when no tab is active, when the selection is empty, or
    /// when the selected element is not a Text / TextPath.
    pub(crate) fn apply_character_panel_to_selection(&mut self) {
        use crate::geometry::element::Element;
        let cp = self.character_panel.clone();
        // Combine underline + strikethrough into the CSS
        // `text-decoration` form. Empty when neither is set.
        let text_decoration = text_decoration_from_flags(cp.underline, cp.strikethrough);
        // All Caps and Small Caps are mutually exclusive per
        // CHARACTER.md; if both bools are true we prefer All Caps
        // (the panel should have enforced exclusion, but be safe).
        let text_transform = if cp.all_caps { "uppercase" } else { "" }.to_string();
        let font_variant = if cp.small_caps && !cp.all_caps { "small-caps" } else { "" }.to_string();
        // Baseline shift: the super / sub toggles take precedence
        // over the numeric pt value (CHARACTER.md mutual exclusion).
        // Zero pt + no toggle renders as empty (omit attribute).
        let baseline_shift = if cp.superscript {
            "super".to_string()
        } else if cp.subscript {
            "sub".to_string()
        } else if cp.baseline_shift != 0.0 {
            format!("{}pt", fmt_num(cp.baseline_shift))
        } else {
            String::new()
        };
        // Leading → line-height. Auto (120% of font size) is
        // represented as empty per CHARACTER.md, so a panel value at
        // the Auto ratio omits the attribute.
        let line_height = if (cp.leading - cp.font_size * 1.2).abs() < 1e-6 {
            String::new()
        } else {
            format!("{}pt", fmt_num(cp.leading))
        };
        // Tracking (1/1000 em, signed) → letter-spacing in em. Zero
        // means empty.
        let letter_spacing = if cp.tracking == 0.0 {
            String::new()
        } else {
            format!("{}em", fmt_num(cp.tracking / 1000.0))
        };
        // Language: xml:lang attribute. Blank panel field omits.
        let xml_lang = cp.language.clone();
        // Anti-aliasing: store the panel mode name verbatim. Empty =
        // default (Sharp is the panel default, but we treat it as the
        // implicit identity and only store when something different
        // would appear on export).
        let aa_mode = if cp.anti_aliasing == "Sharp" || cp.anti_aliasing.is_empty() {
            String::new()
        } else {
            cp.anti_aliasing.clone()
        };
        // Style name → font_weight + font_style. Unknown style names
        // leave the current weight/style alone (write None from
        // parse_style_name).
        let parsed_style = parse_style_name(&cp.style_name);
        // Character rotation: degrees, signed, 0 omits the attribute.
        let rotate = if cp.character_rotation == 0.0 {
            String::new()
        } else {
            fmt_num(cp.character_rotation)
        };
        // V/H scale: identity (100%) omits.
        let horizontal_scale = if cp.horizontal_scale == 100.0 {
            String::new()
        } else {
            fmt_num(cp.horizontal_scale)
        };
        let vertical_scale = if cp.vertical_scale == 100.0 {
            String::new()
        } else {
            fmt_num(cp.vertical_scale)
        };
        // Kerning combo_box: accepts Auto / Optical / Metrics (named
        // modes, passed through verbatim) or a numeric string in
        // 1/1000 em (converted to "{em}em"). Empty / "0" / "Auto" all
        // omit since Auto is the element default.
        let kerning = {
            let raw = cp.kerning.trim();
            match raw {
                "" | "0" | "Auto" => String::new(),
                "Optical" | "Metrics" => raw.to_string(),
                other => match other.parse::<f64>() {
                    Ok(n) if n == 0.0 => String::new(),
                    Ok(n) => format!("{}em", fmt_num(n / 1000.0)),
                    Err(_) => String::new(),
                }
            }
        };
        let active_tool = self.active_tool;
        let Some(tab) = self.tabs.get_mut(self.active_tab) else { return };

        // Phase 3: route to next-typed-character state when there is
        // an active edit session with a bare caret (no range
        // selection). The panel's widget click should prime the
        // session's pending override rather than rewrite the whole
        // element.
        let pending_route: Option<(Vec<usize>, Option<crate::geometry::tspan::Tspan>)> = {
            let doc = tab.model.document();
            let session_path_and_selection =
                tab.tools.get_mut(&active_tool).and_then(|tool| {
                    let s = tool.edit_session_mut()?;
                    if s.has_selection() { return None; }
                    Some(s.path.clone())
                });
            session_path_and_selection.and_then(|path| {
                let elem = doc.get_element(&path)?;
                let template = build_panel_pending_template(&cp, elem);
                Some((path, template))
            })
        };
        if let Some((_path, template)) = pending_route {
            let tool = tab.tools.get_mut(&active_tool).unwrap();
            let session = tool.edit_session_mut().unwrap();
            // Replace semantics: the panel state is authoritative for
            // the next-typed-character override. Clear first, then
            // merge the new template so subsequent panel clicks with
            // the same attributes don't accumulate duplicates.
            session.clear_pending_override();
            if let Some(tspan) = template {
                session.set_pending_override(&tspan);
            }
            return;
        }

        // Per-range write: when the active edit session has a range
        // selection, apply the panel state to that range only via
        // split_range + merge_tspan_overrides + merge. The rest of
        // the edited element is left untouched (per TSPAN.md
        // "Character attribute writes (from panels)").
        let range_route: Option<(Vec<usize>, usize, usize)> = {
            tab.tools.get_mut(&active_tool).and_then(|tool| {
                let s = tool.edit_session_mut()?;
                if !s.has_selection() { return None; }
                let (lo, hi) = s.selection_range();
                Some((s.path.clone(), lo, hi))
            })
        };
        if let Some((path, lo, hi)) = range_route {
            let overrides = build_panel_full_overrides(&cp);
            let doc = tab.model.document().clone();
            if let Some(elem) = doc.get_element(&path) {
                let new_elem = match elem {
                    Element::Text(t) => {
                        let new_tspans = apply_overrides_to_tspan_range(
                            &t.tspans, lo, hi, &overrides);
                        let mut new_t = t.clone();
                        new_t.tspans = new_tspans;
                        Some(Element::Text(new_t))
                    }
                    Element::TextPath(tp) => {
                        let new_tspans = apply_overrides_to_tspan_range(
                            &tp.tspans, lo, hi, &overrides);
                        let mut new_tp = tp.clone();
                        new_tp.tspans = new_tspans;
                        Some(Element::TextPath(new_tp))
                    }
                    _ => None,
                };
                if let Some(new_elem) = new_elem {
                    tab.model.snapshot();
                    let new_doc = doc.replace_element(&path, new_elem);
                    tab.model.set_document(new_doc);
                }
            }
            return;
        }

        let target_paths: Vec<Vec<usize>> = {
            let doc = tab.model.document();
            doc.selection
                .iter()
                .filter_map(|es| {
                    let elem = doc.get_element(&es.path)?;
                    match elem {
                        Element::Text(_) | Element::TextPath(_) => Some(es.path.clone()),
                        _ => None,
                    }
                })
                .collect()
        };
        for path in target_paths {
            let doc = tab.model.document().clone();
            let new_elem = match doc.get_element(&path) {
                Some(Element::Text(t)) => {
                    let mut new_t = t.clone();
                    new_t.font_family = cp.font_family.clone();
                    new_t.font_size = cp.font_size;
                    new_t.text_decoration = text_decoration.clone();
                    new_t.text_transform = text_transform.clone();
                    new_t.font_variant = font_variant.clone();
                    new_t.baseline_shift = baseline_shift.clone();
                    new_t.line_height = line_height.clone();
                    new_t.letter_spacing = letter_spacing.clone();
                    new_t.xml_lang = xml_lang.clone();
                    new_t.aa_mode = aa_mode.clone();
                    new_t.rotate = rotate.clone();
                    new_t.horizontal_scale = horizontal_scale.clone();
                    new_t.vertical_scale = vertical_scale.clone();
                    new_t.kerning = kerning.clone();
                    if let Some((fw, fst)) = parsed_style.clone() {
                        new_t.font_weight = fw;
                        new_t.font_style = fst;
                    }
                    Some(Element::Text(new_t))
                }
                Some(Element::TextPath(tp)) => {
                    let mut new_tp = tp.clone();
                    new_tp.font_family = cp.font_family.clone();
                    new_tp.font_size = cp.font_size;
                    new_tp.text_decoration = text_decoration.clone();
                    new_tp.text_transform = text_transform.clone();
                    new_tp.font_variant = font_variant.clone();
                    new_tp.baseline_shift = baseline_shift.clone();
                    new_tp.line_height = line_height.clone();
                    new_tp.letter_spacing = letter_spacing.clone();
                    new_tp.xml_lang = xml_lang.clone();
                    new_tp.aa_mode = aa_mode.clone();
                    new_tp.rotate = rotate.clone();
                    new_tp.horizontal_scale = horizontal_scale.clone();
                    new_tp.vertical_scale = vertical_scale.clone();
                    new_tp.kerning = kerning.clone();
                    if let Some((fw, fst)) = parsed_style.clone() {
                        new_tp.font_weight = fw;
                        new_tp.font_style = fst;
                    }
                    Some(Element::TextPath(new_tp))
                }
                _ => None,
            };
            if let Some(elem) = new_elem {
                let new_doc = doc.replace_element(&path, elem);
                tab.model.set_document(new_doc);
            }
        }
    }
}

/// Build a `Tspan` override template from the Character panel state
/// that forces every panel-driven field onto the targeted tspans
/// regardless of element-level defaults. Used by the per-range
/// Character-panel write path.
///
/// Scope mirrors [`build_panel_pending_template`]: font-family,
/// font-size, font-weight, font-style, text-decoration,
/// text-transform, font-variant, xml-lang, rotate. Complex
/// attributes still write to the element.
///
/// Unlike the pending template, this builder does NOT diff against
/// element values — clicking Regular with a bold range should clear
/// the bold explicitly, which requires emitting `Some("normal")`,
/// not "nothing changed". Identity-omission (collapsing overrides
/// that match the parent element) is a future optimization.
pub(crate) fn build_panel_full_overrides(
    cp: &CharacterPanelState,
) -> crate::geometry::tspan::Tspan {
    use crate::geometry::tspan::Tspan;
    let mut t = Tspan::default_tspan();
    t.font_family = Some(cp.font_family.clone());
    t.font_size = Some(cp.font_size);
    // Unknown style names leave font_weight/font_style alone (matching
    // the element-write semantics) — pasteStyleName returns None.
    if let Some((fw, fst)) = parse_style_name(&cp.style_name) {
        t.font_weight = Some(fw);
        t.font_style = Some(fst);
    }
    let td_str = text_decoration_from_flags(cp.underline, cp.strikethrough);
    let parts: Vec<String> = td_str
        .split_whitespace()
        .map(String::from)
        .collect();
    t.text_decoration = Some(parts);
    t.text_transform = Some(
        if cp.all_caps { "uppercase".into() } else { "".into() }
    );
    t.font_variant = Some(
        if cp.small_caps && !cp.all_caps { "small-caps".into() } else { "".into() }
    );
    t.xml_lang = Some(cp.language.clone());
    t.rotate = Some(cp.character_rotation);
    // Leading → line_height (pt). No explicit Auto state in the tspan
    // model, so always emit the value; identity-omission is a follow-up.
    t.line_height = Some(cp.leading);
    // Tracking (panel units: 1/1000 em) → letter_spacing (em).
    t.letter_spacing = Some(cp.tracking / 1000.0);
    // Baseline shift numeric (pt). Super/sub flags and kerning modes
    // stay element-level for now — Tspan.baseline_shift is Option<f64>
    // and can't express "super" / "sub" strings.
    if !cp.superscript && !cp.subscript {
        t.baseline_shift = Some(cp.baseline_shift);
    }
    // Anti-aliasing: "Sharp" (and empty) are the panel default; write
    // the mode name otherwise.
    if cp.anti_aliasing != "Sharp" && !cp.anti_aliasing.is_empty() {
        t.jas_aa_mode = Some(cp.anti_aliasing.clone());
    } else {
        t.jas_aa_mode = Some(String::new());
    }
    t
}

/// Apply `overrides` to the tspans covering the character range
/// `[char_start, char_end)`. Uses `split_range` to isolate the
/// targeted tspans, copies every `Some(...)` field from `overrides`
/// onto each one via `merge_tspan_overrides`, then calls `merge` to
/// collapse adjacent-equal tspans. Mirrors TSPAN.md's "Character
/// attribute writes (from panels)" algorithm (steps 1, 2, and 4;
/// step 3's identity-omission is a follow-up).
pub(crate) fn apply_overrides_to_tspan_range(
    tspans: &[crate::geometry::tspan::Tspan],
    char_start: usize,
    char_end: usize,
    overrides: &crate::geometry::tspan::Tspan,
) -> Vec<crate::geometry::tspan::Tspan> {
    use crate::geometry::tspan::{merge, merge_tspan_overrides, split_range};
    if char_start >= char_end {
        return tspans.to_vec();
    }
    let (mut split, first, last) = split_range(tspans, char_start, char_end);
    if let (Some(f), Some(l)) = (first, last) {
        for i in f..=l {
            let mut t = split[i].clone();
            merge_tspan_overrides(&mut t, overrides);
            split[i] = t;
        }
        merge(&split)
    } else {
        split
    }
}

/// Build a `Tspan` override template from the Character panel state
/// that contains only the fields where the panel differs from the
/// currently-edited element. Returns `None` when everything matches.
///
/// Scope (Phase 3 MVP): font-family, font-size, font-weight,
/// font-style, text-decoration, text-transform, font-variant,
/// xml-lang, rotate. Complex attributes (baseline-shift with
/// super/sub, kerning modes, transform-based scales) aren't yet
/// supported as pending overrides and are left out of the template —
/// the panel still writes those to the element normally.
pub(crate) fn build_panel_pending_template(
    cp: &CharacterPanelState,
    elem: &crate::geometry::element::Element,
) -> Option<crate::geometry::tspan::Tspan> {
    use crate::geometry::element::Element;
    use crate::geometry::tspan::Tspan;
    let (elem_ff, elem_fs, elem_fw, elem_fst, elem_td, elem_tt, elem_fv,
         elem_xl, elem_rot, elem_lh_str, elem_ls_str, elem_bs_str,
         elem_aa_str) = match elem {
        Element::Text(t) => (
            &t.font_family, t.font_size, &t.font_weight, &t.font_style,
            &t.text_decoration, &t.text_transform, &t.font_variant,
            &t.xml_lang, &t.rotate,
            &t.line_height, &t.letter_spacing, &t.baseline_shift, &t.aa_mode,
        ),
        Element::TextPath(tp) => (
            &tp.font_family, tp.font_size, &tp.font_weight, &tp.font_style,
            &tp.text_decoration, &tp.text_transform, &tp.font_variant,
            &tp.xml_lang, &tp.rotate,
            &tp.line_height, &tp.letter_spacing, &tp.baseline_shift, &tp.aa_mode,
        ),
        _ => return None,
    };
    let mut t = Tspan::default_tspan();
    let mut any = false;
    if cp.font_family != *elem_ff {
        t.font_family = Some(cp.font_family.clone());
        any = true;
    }
    if (cp.font_size - elem_fs).abs() > 1e-6 {
        t.font_size = Some(cp.font_size);
        any = true;
    }
    if let Some((fw, fst)) = parse_style_name(&cp.style_name) {
        if fw != *elem_fw {
            t.font_weight = Some(fw);
            any = true;
        }
        if fst != *elem_fst {
            t.font_style = Some(fst);
            any = true;
        }
    }
    // text-decoration: parse both sides into sorted sets, so CSS
    // "none" and "" (no decoration) collapse to the same value.
    let panel_td: Vec<String> = {
        let s = text_decoration_from_flags(cp.underline, cp.strikethrough);
        let mut v: Vec<String> = s.split_whitespace().map(String::from).collect();
        v.sort();
        v
    };
    let elem_td_parsed: Vec<String> = {
        let mut v: Vec<String> = elem_td
            .split_whitespace()
            .filter(|tok| *tok != "none")
            .map(String::from)
            .collect();
        v.sort();
        v
    };
    if panel_td != elem_td_parsed {
        t.text_decoration = Some(panel_td);
        any = true;
    }
    // text-transform: All Caps flag → "uppercase" or "".
    let tt = if cp.all_caps { "uppercase" } else { "" };
    if tt != elem_tt.as_str() {
        t.text_transform = Some(tt.to_string());
        any = true;
    }
    // font-variant: Small Caps flag → "small-caps" (when All Caps is off).
    let fv = if cp.small_caps && !cp.all_caps { "small-caps" } else { "" };
    if fv != elem_fv.as_str() {
        t.font_variant = Some(fv.to_string());
        any = true;
    }
    if cp.language != *elem_xl {
        t.xml_lang = Some(cp.language.clone());
        any = true;
    }
    // Character rotation: f64 on the panel, string on the element.
    let rot_str = if cp.character_rotation == 0.0 {
        String::new()
    } else {
        fmt_num(cp.character_rotation)
    };
    if rot_str != *elem_rot {
        t.rotate = if cp.character_rotation == 0.0 {
            None
        } else {
            Some(cp.character_rotation)
        };
        if t.rotate.is_some() { any = true; }
    }
    // Leading → line_height. Element stores as a CSS length string
    // ("14.4pt") or empty; empty means "Auto" (120% of font_size).
    let elem_lh = parse_pt(elem_lh_str).unwrap_or(elem_fs * 1.2);
    if (cp.leading - elem_lh).abs() > 1e-6 {
        t.line_height = Some(cp.leading);
        any = true;
    }
    // Tracking → letter_spacing. Element stores as "Nem"; empty
    // means 0. Panel units are 1/1000 em, so convert.
    let elem_tracking = parse_em_as_thousandths(elem_ls_str).unwrap_or(0.0);
    if (cp.tracking - elem_tracking).abs() > 1e-6 {
        t.letter_spacing = Some(cp.tracking / 1000.0);
        any = true;
    }
    // Baseline shift numeric. Super / sub stay element-level.
    if !cp.superscript && !cp.subscript {
        let elem_bs = parse_pt(elem_bs_str).unwrap_or(0.0);
        if (cp.baseline_shift - elem_bs).abs() > 1e-6 {
            t.baseline_shift = Some(cp.baseline_shift);
            any = true;
        }
    }
    // Anti-aliasing → jas_aa_mode. "Sharp" and empty both round-trip
    // to an empty element attribute.
    let aa = if cp.anti_aliasing == "Sharp" || cp.anti_aliasing.is_empty() {
        String::new()
    } else {
        cp.anti_aliasing.clone()
    };
    if aa != *elem_aa_str {
        t.jas_aa_mode = Some(aa);
        any = true;
    }
    if any { Some(t) } else { None }
}

/// Format a number for CSS length/value output: integers have no
/// decimal, fractions drop trailing zeros. Matches the visual form
/// users expect in Illustrator-style number fields (e.g. `14.4pt`,
/// `0.025em`, `5pt`).
pub(crate) fn fmt_num(n: f64) -> String {
    if n == n.trunc() {
        format!("{}", n as i64)
    } else {
        let s = format!("{:.4}", n);
        s.trim_end_matches('0').trim_end_matches('.').to_string()
    }
}

/// Parse a CSS length string in `pt` and return the numeric value, or
/// `None` if the string is empty or has an unsupported unit. Used by
/// the Character panel read-back for `line-height` and the numeric
/// branch of `baseline-shift`.
pub(crate) fn parse_pt(s: &str) -> Option<f64> {
    let s = s.trim();
    let rest = s.strip_suffix("pt").unwrap_or(s);
    rest.parse::<f64>().ok()
}

/// Parse a CSS letter-spacing value in `em`. Returns the value in
/// 1/1000 em (panel units), or None if unparseable.
pub(crate) fn parse_em_as_thousandths(s: &str) -> Option<f64> {
    let s = s.trim();
    let rest = s.strip_suffix("em").unwrap_or(s);
    rest.parse::<f64>().ok().map(|v| v * 1000.0)
}

/// Parse a Character-panel Style name into the `(font_weight,
/// font_style)` pair used on Text / TextPath elements. Returns `None`
/// for names the parser doesn't recognise — callers should leave the
/// existing weight/style alone in that case.
pub(crate) fn parse_style_name(name: &str) -> Option<(String, String)> {
    match name.trim() {
        "Regular" => Some(("normal".into(), "normal".into())),
        "Italic" => Some(("normal".into(), "italic".into())),
        "Bold" => Some(("bold".into(), "normal".into())),
        "Bold Italic" | "Italic Bold" => Some(("bold".into(), "italic".into())),
        _ => None,
    }
}

/// Inverse of `parse_style_name` — build the Character-panel display
/// name from an element's font_weight / font_style. Falls back to
/// `"Regular"` for unrecognised combinations so the dropdown always
/// shows a concrete value.
pub(crate) fn format_style_name(font_weight: &str, font_style: &str) -> String {
    let bold = font_weight == "bold" || font_weight.parse::<u16>().map(|n| n >= 600).unwrap_or(false);
    let italic = font_style == "italic" || font_style == "oblique";
    match (bold, italic) {
        (true, true) => "Bold Italic".into(),
        (true, false) => "Bold".into(),
        (false, true) => "Italic".into(),
        (false, false) => "Regular".into(),
    }
}

/// Build the CSS `text-decoration` value from two independent flags.
/// Combines them in a stable alphabetical order — matches what the SVG
/// serializer already emits for tspan text_decoration arrays.
pub(crate) fn text_decoration_from_flags(underline: bool, strikethrough: bool) -> String {
    match (underline, strikethrough) {
        (true, true) => "line-through underline".to_string(),
        (true, false) => "underline".to_string(),
        (false, true) => "line-through".to_string(),
        (false, false) => String::new(),
    }
}

/// Inverse of `text_decoration_from_flags` — extract the two flags from
/// a `text-decoration` string. Whitespace-split so "underline
/// line-through", "line-through underline", and mixed-case input all
/// round-trip cleanly through the Character panel's Underline /
/// Strikethrough toggles.
pub(crate) fn text_decoration_flags(td: &str) -> (bool, bool) {
    let mut underline = false;
    let mut strikethrough = false;
    for tok in td.split_whitespace() {
        match tok {
            "underline" => underline = true,
            "line-through" => strikethrough = true,
            _ => {}
        }
    }
    (underline, strikethrough)
}

#[cfg(test)]
mod pending_override_tests {
    use super::*;
    use crate::geometry::element::Element;

    // ── build_panel_pending_template direct tests ──────────

    #[test]
    fn template_empty_when_panel_matches_element() {
        // Align the panel defaults to the element's defaults first,
        // then verify no diff. The empty element has font_size=16 with
        // line_height="" (auto = 120% → 19.2pt) and blank letter-
        // spacing / baseline-shift / aa-mode.
        let t = crate::tools::text_edit::empty_text_elem(0.0, 0.0, 0.0, 0.0);
        let mut cp = CharacterPanelState::default();
        cp.font_size = t.font_size;
        cp.font_family = t.font_family.clone();
        cp.language = t.xml_lang.clone();
        cp.leading = t.font_size * 1.2;  // matches the auto default
        cp.tracking = 0.0;
        cp.baseline_shift = 0.0;
        cp.anti_aliasing = "Sharp".into();
        let tpl = build_panel_pending_template(&cp, &Element::Text(t));
        assert!(tpl.is_none());
    }

    #[test]
    fn template_bold_sets_font_weight_only() {
        let mut cp = CharacterPanelState::default();
        let t = crate::tools::text_edit::empty_text_elem(0.0, 0.0, 0.0, 0.0);
        cp.font_size = t.font_size;
        cp.font_family = t.font_family.clone();
        cp.language = t.xml_lang.clone();
        cp.style_name = "Bold".into();
        let tpl = build_panel_pending_template(&cp, &Element::Text(t)).unwrap();
        assert_eq!(tpl.font_weight.as_deref(), Some("bold"));
        // Regular element's font_style is "normal" and Bold parses to
        // ("bold", "normal") — so font_style doesn't differ and is omitted.
        assert!(tpl.font_style.is_none());
        assert!(tpl.font_family.is_none());
        assert!(tpl.font_size.is_none());
    }

    #[test]
    fn template_font_size_differs() {
        let mut cp = CharacterPanelState::default();
        let t = crate::tools::text_edit::empty_text_elem(0.0, 0.0, 0.0, 0.0);
        cp.font_family = t.font_family.clone();
        cp.font_size = 24.0;  // element has 16
        let tpl = build_panel_pending_template(&cp, &Element::Text(t)).unwrap();
        assert_eq!(tpl.font_size, Some(24.0));
    }

    #[test]
    fn template_text_decoration_underline_flag() {
        let mut cp = CharacterPanelState::default();
        let t = crate::tools::text_edit::empty_text_elem(0.0, 0.0, 0.0, 0.0);
        cp.font_size = t.font_size;
        cp.font_family = t.font_family.clone();
        cp.language = t.xml_lang.clone();
        cp.underline = true;
        let tpl = build_panel_pending_template(&cp, &Element::Text(t)).unwrap();
        assert_eq!(tpl.text_decoration, Some(vec!["underline".to_string()]));
    }

    #[test]
    fn template_all_caps_sets_text_transform() {
        let mut cp = CharacterPanelState::default();
        let t = crate::tools::text_edit::empty_text_elem(0.0, 0.0, 0.0, 0.0);
        cp.font_size = t.font_size;
        cp.font_family = t.font_family.clone();
        cp.language = t.xml_lang.clone();
        cp.all_caps = true;
        let tpl = build_panel_pending_template(&cp, &Element::Text(t)).unwrap();
        assert_eq!(tpl.text_transform.as_deref(), Some("uppercase"));
    }

    // ── full-override template for range writes ──────────────

    #[test]
    fn full_overrides_sets_every_scope_field() {
        let mut cp = CharacterPanelState::default();
        cp.style_name = "Bold".into();
        cp.all_caps = true;
        cp.underline = true;
        let t = build_panel_full_overrides(&cp);
        assert_eq!(t.font_family.as_deref(), Some("sans-serif"));
        assert_eq!(t.font_size, Some(12.0));
        assert_eq!(t.font_weight.as_deref(), Some("bold"));
        assert_eq!(t.font_style.as_deref(), Some("normal"));
        assert_eq!(t.text_transform.as_deref(), Some("uppercase"));
        assert_eq!(t.text_decoration.as_ref().unwrap(), &vec!["underline".to_string()]);
        // Complex attrs are part of the template now too.
        assert!(t.line_height.is_some());
        assert!(t.letter_spacing.is_some());
        assert!(t.baseline_shift.is_some());
        assert!(t.jas_aa_mode.is_some());
    }

    #[test]
    fn template_leading_differs_from_auto() {
        let t = crate::tools::text_edit::empty_text_elem(0.0, 0.0, 0.0, 0.0);
        let mut cp = CharacterPanelState::default();
        cp.font_size = t.font_size;
        cp.font_family = t.font_family.clone();
        cp.language = t.xml_lang.clone();
        cp.leading = t.font_size * 2.0;  // 2x = non-auto leading
        let tpl = build_panel_pending_template(&cp, &Element::Text(t)).unwrap();
        assert_eq!(tpl.line_height, Some(cp.leading));
    }

    #[test]
    fn template_tracking_differs_from_zero() {
        let t = crate::tools::text_edit::empty_text_elem(0.0, 0.0, 0.0, 0.0);
        let mut cp = CharacterPanelState::default();
        cp.font_size = t.font_size;
        cp.font_family = t.font_family.clone();
        cp.language = t.xml_lang.clone();
        cp.leading = t.font_size * 1.2;
        cp.tracking = 50.0;  // 50/1000 = 0.05 em
        let tpl = build_panel_pending_template(&cp, &Element::Text(t)).unwrap();
        assert!((tpl.letter_spacing.unwrap() - 0.05).abs() < 1e-9);
    }

    #[test]
    fn template_baseline_shift_numeric_differs() {
        let t = crate::tools::text_edit::empty_text_elem(0.0, 0.0, 0.0, 0.0);
        let mut cp = CharacterPanelState::default();
        cp.font_size = t.font_size;
        cp.font_family = t.font_family.clone();
        cp.language = t.xml_lang.clone();
        cp.leading = t.font_size * 1.2;
        cp.baseline_shift = 3.0;
        let tpl = build_panel_pending_template(&cp, &Element::Text(t)).unwrap();
        assert_eq!(tpl.baseline_shift, Some(3.0));
    }

    #[test]
    fn template_baseline_shift_numeric_skipped_when_super_on() {
        let t = crate::tools::text_edit::empty_text_elem(0.0, 0.0, 0.0, 0.0);
        let mut cp = CharacterPanelState::default();
        cp.font_size = t.font_size;
        cp.font_family = t.font_family.clone();
        cp.language = t.xml_lang.clone();
        cp.leading = t.font_size * 1.2;
        cp.superscript = true;
        cp.baseline_shift = 3.0;  // ignored when super is on
        let tpl = build_panel_pending_template(&cp, &Element::Text(t));
        // Super/sub are still element-level; the tspan template
        // should not carry baseline_shift in this case.
        if let Some(t) = tpl {
            assert!(t.baseline_shift.is_none());
        }
    }

    #[test]
    fn template_anti_aliasing_differs_from_sharp() {
        let t = crate::tools::text_edit::empty_text_elem(0.0, 0.0, 0.0, 0.0);
        let mut cp = CharacterPanelState::default();
        cp.font_size = t.font_size;
        cp.font_family = t.font_family.clone();
        cp.language = t.xml_lang.clone();
        cp.leading = t.font_size * 1.2;
        cp.anti_aliasing = "Smooth".into();
        let tpl = build_panel_pending_template(&cp, &Element::Text(t)).unwrap();
        assert_eq!(tpl.jas_aa_mode.as_deref(), Some("Smooth"));
    }

    #[test]
    fn full_overrides_regular_style_forces_normal_not_none() {
        // The key distinction from the pending template: clicking
        // Regular on a bold range must emit Some("normal") so the
        // range's bold override gets replaced, not skipped.
        let mut cp = CharacterPanelState::default();
        cp.style_name = "Regular".into();
        let t = build_panel_full_overrides(&cp);
        assert_eq!(t.font_weight.as_deref(), Some("normal"));
        assert_eq!(t.font_style.as_deref(), Some("normal"));
    }

    // ── apply_overrides_to_tspan_range ───────────────────────

    #[test]
    fn apply_overrides_to_range_bolds_partial_word() {
        use crate::geometry::tspan::Tspan;
        let base = vec![Tspan { content: "hello".into(), ..Tspan::default_tspan() }];
        let mut cp = CharacterPanelState::default();
        cp.style_name = "Bold".into();
        let overrides = build_panel_full_overrides(&cp);
        // Apply Bold to "ell" (chars [1..4)).
        let out = apply_overrides_to_tspan_range(&base, 1, 4, &overrides);
        assert_eq!(out.len(), 3);
        assert_eq!(out[0].content, "h");
        assert_eq!(out[1].content, "ell");
        assert_eq!(out[1].font_weight.as_deref(), Some("bold"));
        assert_eq!(out[2].content, "o");
        assert!(out[2].font_weight.as_deref() != Some("bold"));
    }

    #[test]
    fn apply_overrides_to_empty_range_is_passthrough() {
        use crate::geometry::tspan::Tspan;
        let base = vec![Tspan { content: "hello".into(), ..Tspan::default_tspan() }];
        let overrides = Tspan { font_weight: Some("bold".into()),
                                ..Tspan::default_tspan() };
        let out = apply_overrides_to_tspan_range(&base, 2, 2, &overrides);
        assert_eq!(out, base);
    }

    #[test]
    fn apply_overrides_to_range_merges_adjacent_equal() {
        use crate::geometry::tspan::Tspan;
        // Two adjacent plain tspans become one bold tspan after the
        // merge step collapses the adjacent-equal pair.
        let base = vec![
            Tspan { content: "foo".into(), ..Tspan::default_tspan() },
            Tspan { id: 1, content: "bar".into(), ..Tspan::default_tspan() },
        ];
        let overrides = Tspan { font_weight: Some("bold".into()),
                                ..Tspan::default_tspan() };
        let out = apply_overrides_to_tspan_range(&base, 0, 6, &overrides);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].content, "foobar");
        assert_eq!(out[0].font_weight.as_deref(), Some("bold"));
    }
}
