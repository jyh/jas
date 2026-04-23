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
use crate::tools::type_tool::TypeTool;
use crate::tools::type_on_path_tool::TypeOnPathTool;
use crate::tools::tool::{CanvasTool, ToolKind};
use crate::tools::yaml_tool::YamlTool;

/// Build a YAML-driven canvas tool from the embedded workspace's
/// `tools.<id>` spec. Shared by every migrated tool — each one is a
/// one-line `yaml_tool("rect")`-style construction in `with_model`.
///
/// All three expect() failures would indicate a build-time invariant
/// violation (workspace.json missing, corrupted, or schema-drifted
/// from the corresponding YAML source). workspace.json is embedded
/// via `include_str!`, so these paths don't cover runtime-file-IO
/// failures.
fn yaml_tool(id: &str) -> Box<dyn CanvasTool> {
    use crate::interpreter::workspace::Workspace;
    let ws = Workspace::load()
        .expect("embedded workspace.json must parse");
    let spec = ws
        .data()
        .get("tools")
        .and_then(|t| t.get(id))
        .unwrap_or_else(|| panic!("workspace.json must declare a '{id}' tool"));
    let tool = YamlTool::from_workspace_tool(spec)
        .unwrap_or_else(|| panic!("tool '{id}' spec must parse into ToolSpec"));
    Box::new(tool)
}

/// Shared application state handle, available via `use_context::<AppHandle>()`.
pub(crate) type AppHandle = Rc<RefCell<AppState>>;

/// Universal state mutation handle, available via `use_context::<Act>()`.
/// Call `(act.0.borrow_mut())(Box::new(|st| { ... }))` to mutate AppState.
#[derive(Clone)]
pub(crate) struct Act(pub Rc<RefCell<dyn FnMut(Box<dyn FnOnce(&mut AppState)>)>>);

// ---------------------------------------------------------------------------

/// Re-export of [`crate::document::model::EditingTarget`] — this
/// lived on ``TabState`` before the editing-target / mask-isolation
/// state moved to ``Model`` for parity with Swift / OCaml / Python
/// and to give drawing tools access via ``&mut Model``. Kept as an
/// alias so existing callers continue to see
/// ``crate::workspace::app_state::EditingTarget``.
pub(crate) use crate::document::model::EditingTarget;

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
        tools.insert(ToolKind::Selection, yaml_tool("selection"));
        tools.insert(ToolKind::PartialSelection, yaml_tool("partial_selection"));
        tools.insert(ToolKind::InteriorSelection, yaml_tool("interior_selection"));
        tools.insert(ToolKind::Pen, yaml_tool("pen"));
        tools.insert(ToolKind::AddAnchorPoint, yaml_tool("add_anchor_point"));
        tools.insert(ToolKind::DeleteAnchorPoint, yaml_tool("delete_anchor_point"));
        tools.insert(ToolKind::AnchorPoint, yaml_tool("anchor_point"));
        tools.insert(ToolKind::Pencil, yaml_tool("pencil"));
        tools.insert(ToolKind::PathEraser, yaml_tool("path_eraser"));
        tools.insert(ToolKind::Smooth, yaml_tool("smooth"));
        tools.insert(ToolKind::Type, Box::new(TypeTool::new()));
        tools.insert(ToolKind::TypeOnPath, Box::new(TypeOnPathTool::new()));
        tools.insert(ToolKind::Rect, yaml_tool("rect"));
        tools.insert(ToolKind::RoundedRect, yaml_tool("rounded_rect"));
        tools.insert(ToolKind::Polygon, yaml_tool("polygon"));
        tools.insert(ToolKind::Star, yaml_tool("star"));
        tools.insert(ToolKind::Line, yaml_tool("line"));
        tools.insert(ToolKind::Lasso, yaml_tool("lasso"));
        Self {
            model,
            tools,
            clipboard: Vec::new(),
        }
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
    /// Gradient panel state — mirrored to/from the active fill or stroke
    /// gradient on the selection. See `transcripts/GRADIENT.md`.
    pub(crate) gradient_panel: GradientPanelState,
    /// Character panel state — panel-local; pushed to selected Text /
    /// TextPath via apply_character_panel_to_selection.
    pub(crate) character_panel: CharacterPanelState,
    /// Paragraph panel state — panel-local; pushed to paragraph wrapper
    /// tspan(s) of selected Text / TextPath via
    /// `apply_paragraph_panel_to_selection`.
    pub(crate) paragraph_panel: ParagraphPanelState,
    /// Align panel state — mirrors state.align_* and drives the
    /// selection / artboard / key-object Align To mode. See
    /// transcripts/ALIGN.md §Panel state.
    pub(crate) align_panel: AlignPanelState,
    /// Boolean panel document-level options — mirrors
    /// state.boolean_* and is edited by the Boolean Options dialog.
    /// Read by `Controller::apply_destructive_boolean` and compound
    /// shape evaluation. See BOOLEAN.md §Boolean Options dialog.
    pub(crate) boolean_panel: BooleanPanelState,
    /// Opacity panel state — mirrors state in `workspace/panels/opacity.yaml`.
    /// `mode` and `opacity` are working values; `new_masks_*` are document
    /// preferences. See transcripts/OPACITY.md.
    pub(crate) opacity_panel: OpacityPanelState,
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

    /// Artboards panel — panel-selected artboard ids. Tracked by stable
    /// id so selection survives reorder (ARTBOARDS.md §Selection
    /// semantics).
    pub(crate) artboards_panel_selection: Vec<String>,
    /// Anchor id for shift-click range selection in the Artboards panel.
    pub(crate) artboards_panel_anchor: Option<String>,
    /// Id of the artboard currently being renamed inline, or None.
    pub(crate) artboards_renaming: Option<String>,
    /// Reference-point widget preference. One of the 9 anchor names.
    /// Persists as a panel preference, not per document.
    pub(crate) artboards_reference_point: String,
    /// Blue-dot accent flag on REARRANGE_BUTTON. True after the first
    /// list change in a session; phase-1 has no clear path (Rearrange
    /// Dialogue deferred).
    pub(crate) artboards_rearrange_dirty: bool,
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

/// Gradient panel state fields — mirror the panel-local state declared
/// in `workspace/panels/gradient.yaml`. Populated by
/// `sync_gradient_panel_from_selection` when the selection changes;
/// pushed back to the active gradient on the selection by Phase 5
/// (panel writes). See `transcripts/GRADIENT.md` §Document model.
#[derive(Debug, Clone)]
pub(crate) struct GradientPanelState {
    /// "linear", "radial", or "freeform".
    pub gtype: String,
    /// −180..+180 degrees.
    pub angle: f64,
    /// 1–1000 percentage.
    pub aspect_ratio: f64,
    /// "classic", "smooth", "points", "lines".
    pub method: String,
    pub dither: bool,
    /// "within", "along", "across".
    pub stroke_sub_mode: String,
    /// Working stops list (color hex string + per-stop fields).
    pub stops: Vec<crate::geometry::element::GradientStop>,
    /// Index of the selected stop, or `-1` when nothing is selected.
    pub selected_stop_index: i64,
    /// Index of the selected midpoint, or `-1` when nothing is selected.
    pub selected_midpoint_index: i64,
    /// Active library id (filename stem under workspace/gradients/).
    pub active_library_id: String,
    /// "small", "medium", or "large".
    pub thumbnail_size: String,
    /// True when the active attribute is solid/none and the panel is
    /// showing a seeded default — first edit promotes the attribute
    /// to a gradient.
    pub preview_state: bool,
}

impl Default for GradientPanelState {
    fn default() -> Self {
        use crate::geometry::element::{Color, GradientStop};
        Self {
            gtype: "linear".into(),
            angle: 0.0,
            aspect_ratio: 100.0,
            method: "classic".into(),
            dither: false,
            stroke_sub_mode: "within".into(),
            stops: vec![
                GradientStop {
                    color: Color::BLACK, opacity: 100.0,
                    location: 0.0, midpoint_to_next: 50.0,
                },
                GradientStop {
                    color: Color::WHITE, opacity: 100.0,
                    location: 100.0, midpoint_to_next: 50.0,
                },
            ],
            selected_stop_index: 0,
            selected_midpoint_index: -1,
            active_library_id: "neutrals".into(),
            thumbnail_size: "large".into(),
            preview_state: false,
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

/// Paragraph panel state fields — mirror the panel-local state
/// declared in `workspace/panels/paragraph.yaml`. Written to by the
/// renderer when the user edits a Paragraph panel control; read by
/// `apply_paragraph_panel_to_selection` to push the attributes onto
/// the paragraph wrapper tspan(s) inside the selected Text /
/// TextPath element. Phase 4.
#[derive(Debug, Clone)]
pub(crate) struct ParagraphPanelState {
    /// Alignment radio group — exactly one of these seven is true.
    pub align_left: bool,
    pub align_center: bool,
    pub align_right: bool,
    pub justify_left: bool,
    pub justify_center: bool,
    pub justify_right: bool,
    pub justify_all: bool,
    /// Single-attr-shared dropdowns; mutually exclusive at write time.
    /// Empty string ⇒ no marker / clears the attribute.
    pub bullets: String,
    pub numbered_list: String,
    pub left_indent: f64,
    pub right_indent: f64,
    /// Signed; negative ⇒ hanging indent.
    pub first_line_indent: f64,
    pub space_before: f64,
    pub space_after: f64,
    pub hyphenate: bool,
    pub hanging_punctuation: bool,
}

impl Default for ParagraphPanelState {
    fn default() -> Self {
        Self {
            align_left: true,
            align_center: false,
            align_right: false,
            justify_left: false,
            justify_center: false,
            justify_right: false,
            justify_all: false,
            bullets: String::new(),
            numbered_list: String::new(),
            left_indent: 0.0,
            right_indent: 0.0,
            first_line_indent: 0.0,
            space_before: 0.0,
            space_after: 0.0,
            hyphenate: false,
            hanging_punctuation: false,
        }
    }
}

/// Align panel state — mirrors the four fields documented in
/// `transcripts/ALIGN.md` §Panel state:
/// - `align_to`: selection target mode.
/// - `key_object_path`: path of the designated key object while
///   in key_object mode; `None` when no key is designated.
/// - `distribute_spacing`: explicit gap in points for Distribute
///   Spacing operations in key-object mode.
/// - `use_preview_bounds`: whether operations consult preview
///   (stroke-inclusive) bounds instead of geometric bounds.
#[derive(Debug, Clone)]
pub(crate) struct AlignPanelState {
    pub align_to: AlignTo,
    pub key_object_path: Option<crate::document::document::ElementPath>,
    pub distribute_spacing: f64,
    pub use_preview_bounds: bool,
}

/// Align-To target mode. See ALIGN.md §Align To target.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AlignTo {
    Selection,
    Artboard,
    KeyObject,
}

impl Default for AlignPanelState {
    fn default() -> Self {
        Self {
            align_to: AlignTo::Selection,
            key_object_path: None,
            distribute_spacing: 0.0,
            use_preview_bounds: false,
        }
    }
}

/// Mirror of the Boolean panel's document-level state per BOOLEAN.md
/// §Boolean Options dialog and §Repeat state. Edited by the Boolean
/// Options dialog and by every destructive / compound-creating
/// action; read by `Controller::apply_destructive_boolean`, compound
/// shape evaluation, and `Repeat Boolean Operation`.
#[derive(Debug, Clone)]
pub(crate) struct BooleanPanelState {
    /// Geometric tolerance in points. Default 0.0283 pt = 0.01 mm.
    pub precision: f64,
    /// When true, collinear points in boolean-op output within
    /// Precision are collapsed.
    pub remove_redundant_points: bool,
    /// When true, DIVIDE fragments with no fill and no stroke are
    /// discarded rather than kept as invisible paths.
    pub divide_remove_unpainted: bool,
    /// Most-recent op (one of 13 values plus None). See BOOLEAN.md
    /// §Repeat state. Populated by every destructive op and every
    /// compound-creating variant; consumed by Repeat Boolean
    /// Operation. Make / Release / Expand Compound Shape do not
    /// write this field.
    pub last_op: Option<String>,
}

impl Default for BooleanPanelState {
    fn default() -> Self {
        Self {
            precision: 0.0283,
            remove_redundant_points: false,
            divide_remove_unpainted: false,
            last_op: None,
        }
    }
}

/// Opacity panel state fields — mirror the panel-local state declared in
/// `workspace/panels/opacity.yaml`. `blend_mode` and `opacity` are working
/// values shown in the panel controls; later phases synchronize them with
/// the selection's `element.mode` / `element.opacity`. The `new_masks_*`
/// fields are document-scoped preferences (Phase 1 stores them on the panel
/// state until the document model grows per-document preferences).
///
/// Named `blend_mode` rather than `mode` to avoid a collision with the Color
/// panel's `mode` key in the shared live-overrides map.
#[derive(Debug, Clone)]
pub(crate) struct OpacityPanelState {
    /// Working blend mode.
    pub blend_mode: super::super::geometry::element::BlendMode,
    /// Working opacity (0-100). Panel range is percent, distinct from the
    /// model's 0.0-1.0 fraction; later phases convert at the binding edge.
    pub opacity: f64,
    /// Panel-local: preview row collapsed when true.
    pub thumbnails_hidden: bool,
    /// Panel-local: isolated_blending / knockout_group toggles revealed
    /// inline when true.
    pub options_shown: bool,
    /// Document preference: initial `mask.clip` for newly made masks.
    pub new_masks_clipping: bool,
    /// Document preference: initial `mask.invert` for newly made masks.
    pub new_masks_inverted: bool,
}

impl Default for OpacityPanelState {
    fn default() -> Self {
        Self {
            blend_mode: super::super::geometry::element::BlendMode::Normal,
            opacity: 100.0,
            thumbnails_hidden: false,
            options_shown: false,
            new_masks_clipping: true,
            new_masks_inverted: false,
        }
    }
}

impl AlignTo {
    pub fn as_str(self) -> &'static str {
        match self {
            AlignTo::Selection => "selection",
            AlignTo::Artboard => "artboard",
            AlignTo::KeyObject => "key_object",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "selection" => Some(AlignTo::Selection),
            "artboard" => Some(AlignTo::Artboard),
            "key_object" => Some(AlignTo::KeyObject),
            _ => None,
        }
    }
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
            gradient_panel: GradientPanelState::default(),
            character_panel: CharacterPanelState::default(),
            paragraph_panel: ParagraphPanelState::default(),
            align_panel: AlignPanelState::default(),
            boolean_panel: BooleanPanelState::default(),
            opacity_panel: OpacityPanelState::default(),
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
            artboards_panel_selection: Vec::new(),
            artboards_panel_anchor: None,
            artboards_renaming: None,
            artboards_reference_point: "center".to_string(),
            artboards_rearrange_dirty: false,
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

    /// Apply the current gradient panel state to the selected element(s).
    ///
    /// Builds a Gradient from the panel fields and writes it into either
    /// `fill_gradient` or `stroke_gradient` on each selected element
    /// (per `state.fill_on_top`). Phase 5 — the inverse of
    /// `sync_gradient_panel_from_selection`.
    ///
    /// Fill-type coupling per GRADIENT.md §Fill-type coupling: when the
    /// active attribute is solid/none and a panel edit triggers the
    /// promotion path, the seed gradient (from preview state) is what
    /// gets applied. The Fill / Stroke values themselves are left
    /// alone — the gradient field overrides paint at render time, but
    /// `fill.color` / `stroke.color` remain as the demote-target colour.
    pub(crate) fn apply_gradient_panel_to_selection(&mut self) {
        use crate::geometry::element::{
            Gradient, GradientType, GradientMethod, StrokeSubMode,
        };
        let gp = &self.gradient_panel;
        let gtype = match gp.gtype.as_str() {
            "radial" => GradientType::Radial,
            "freeform" => GradientType::Freeform,
            _ => GradientType::Linear,
        };
        let gmethod = match gp.method.as_str() {
            "smooth" => GradientMethod::Smooth,
            "points" => GradientMethod::Points,
            "lines" => GradientMethod::Lines,
            _ => GradientMethod::Classic,
        };
        let gsub = match gp.stroke_sub_mode.as_str() {
            "along" => StrokeSubMode::Along,
            "across" => StrokeSubMode::Across,
            _ => StrokeSubMode::Within,
        };
        let g = Gradient {
            gtype,
            angle: gp.angle,
            aspect_ratio: gp.aspect_ratio,
            method: gmethod,
            dither: gp.dither,
            stroke_sub_mode: gsub,
            stops: gp.stops.clone(),
            nodes: Vec::new(),
        };
        let fill_on_top = self.fill_on_top;
        if let Some(tab) = self.tabs.get_mut(self.active_tab) {
            if !tab.model.document().selection.is_empty() {
                tab.model.snapshot();
                let boxed = Some(Box::new(g));
                if fill_on_top {
                    Controller::set_selection_fill_gradient(&mut tab.model, boxed);
                } else {
                    Controller::set_selection_stroke_gradient(&mut tab.model, boxed);
                }
            }
        }
        // First-edit-after-promotion clears the preview-state flag so
        // the panel UI removes its "not applied" indicator.
        self.gradient_panel.preview_state = false;
    }

    /// Demote the selection's active-attribute gradient back to a solid
    /// color. The new solid color is taken from the current
    /// `fill.color` / `stroke.color` if present (see
    /// GRADIENT.md §Fill-type coupling, demote-from-gradient rule —
    /// "first stop's color" is the spec but the existing solid color
    /// is functionally equivalent here since the seed-on-promote rule
    /// kept the original solid as `fill.color`).
    pub(crate) fn demote_gradient_panel_selection(&mut self) {
        let fill_on_top = self.fill_on_top;
        if let Some(tab) = self.tabs.get_mut(self.active_tab) {
            if !tab.model.document().selection.is_empty() {
                tab.model.snapshot();
                if fill_on_top {
                    Controller::set_selection_fill_gradient(&mut tab.model, None);
                } else {
                    Controller::set_selection_stroke_gradient(&mut tab.model, None);
                }
            }
        }
    }

    /// Sync gradient panel state from the selection's active attribute
    /// (fill or stroke per `fill_on_top`). When the selection is uniform
    /// on a single gradient, panel fields populate from it. When mixed,
    /// fields stay at their current values and `selected_stop_index` is
    /// clamped (the renderer handles mixed-state display per
    /// GRADIENT.md §Multi-selection). When the active attribute is
    /// solid/none, `preview_state` is set true so the panel shows a
    /// seeded default; first edit will promote the attribute via the
    /// fill-type coupling rule (Phase 5).
    ///
    /// Phase 4 scope: read direction only. The panel does not yet
    /// commit edits back — that lands in Phase 5.
    pub(crate) fn sync_gradient_panel_from_selection(&mut self) {
        use crate::geometry::element::{Color, GradientStop};

        let Some(tab) = self.tab() else { return; };
        let doc = tab.model.document();

        if doc.selection.is_empty() {
            // No selection: panel keeps current defaults (acts as
            // "session defaults" mode, mirroring STROKE.md behavior).
            return;
        }

        // Read the gradient on the active attribute of every selected
        // element. Mixed = at least two distinct gradients (or some
        // have a gradient and others don't). Uniform-with-gradient =
        // all elements have the same gradient. Uniform-without =
        // every element has solid/none on the active attribute.
        let fill_on_top = self.fill_on_top;
        let mut first: Option<Option<crate::geometry::element::Gradient>> = None;
        let mut mixed = false;
        let mut first_solid_color: Option<Color> = None;
        for es in &doc.selection {
            let Some(elem) = doc.get_element(&es.path) else { continue; };
            let gradient = if fill_on_top {
                elem.fill_gradient().cloned()
            } else {
                elem.stroke_gradient().cloned()
            };
            // Capture the first element's solid color for the seed.
            if first_solid_color.is_none() && gradient.is_none() {
                let solid = if fill_on_top {
                    elem.fill().map(|f| f.color)
                } else {
                    elem.stroke().map(|s| s.color)
                };
                first_solid_color = solid;
            }
            match &first {
                None => first = Some(gradient),
                Some(prev) => {
                    if prev != &gradient { mixed = true; }
                }
            }
        }

        if mixed {
            // Mixed selection: leave panel fields at their current values;
            // the panel renderer reads selection_summary to decide
            // blank-vs-uniform display per Multi-selection table.
            self.gradient_panel.preview_state = false;
            return;
        }

        match first.flatten() {
            Some(g) => {
                // Uniform with gradient — populate the panel.
                self.gradient_panel.gtype = match g.gtype {
                    crate::geometry::element::GradientType::Linear => "linear",
                    crate::geometry::element::GradientType::Radial => "radial",
                    crate::geometry::element::GradientType::Freeform => "freeform",
                }.into();
                self.gradient_panel.angle = g.angle;
                self.gradient_panel.aspect_ratio = g.aspect_ratio;
                self.gradient_panel.method = match g.method {
                    crate::geometry::element::GradientMethod::Classic => "classic",
                    crate::geometry::element::GradientMethod::Smooth => "smooth",
                    crate::geometry::element::GradientMethod::Points => "points",
                    crate::geometry::element::GradientMethod::Lines => "lines",
                }.into();
                self.gradient_panel.dither = g.dither;
                self.gradient_panel.stroke_sub_mode = match g.stroke_sub_mode {
                    crate::geometry::element::StrokeSubMode::Within => "within",
                    crate::geometry::element::StrokeSubMode::Along => "along",
                    crate::geometry::element::StrokeSubMode::Across => "across",
                }.into();
                self.gradient_panel.stops = g.stops;
                // Clamp the selected-stop index to the new stops length.
                let len = self.gradient_panel.stops.len() as i64;
                if self.gradient_panel.selected_stop_index >= len {
                    self.gradient_panel.selected_stop_index = (len - 1).max(0);
                }
                self.gradient_panel.preview_state = false;
            }
            None => {
                // Uniform without gradient (active attr is solid/none).
                // Seed the preview gradient per GRADIENT.md §Fill-type
                // coupling — promote-from-solid rule. The first edit
                // (Phase 5) will materialise this onto the elements.
                let seed_first = first_solid_color.unwrap_or(Color::BLACK);
                self.gradient_panel.gtype = "linear".into();
                self.gradient_panel.angle = 0.0;
                self.gradient_panel.aspect_ratio = 100.0;
                self.gradient_panel.method = "classic".into();
                self.gradient_panel.dither = false;
                self.gradient_panel.stroke_sub_mode = "within".into();
                self.gradient_panel.stops = vec![
                    GradientStop {
                        color: seed_first, opacity: 100.0,
                        location: 0.0, midpoint_to_next: 50.0,
                    },
                    GradientStop {
                        color: Color::WHITE, opacity: 100.0,
                        location: 100.0, midpoint_to_next: 50.0,
                    },
                ];
                self.gradient_panel.selected_stop_index = 0;
                self.gradient_panel.selected_midpoint_index = -1;
                self.gradient_panel.preview_state = true;
            }
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
        render::render(
            &ctx,
            w,
            h,
            tab.model.document(),
            self.boolean_panel.precision,
            &self.artboards_panel_selection,
            tab.model.mask_isolation_path.as_deref(),
        );

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
                        let new_tspans = apply_overrides_to_tspan_range_with_elem(
                            &t.tspans, lo, hi, &overrides, Some(elem));
                        let mut new_t = t.clone();
                        new_t.tspans = new_tspans;
                        Some(Element::Text(new_t))
                    }
                    Element::TextPath(tp) => {
                        let new_tspans = apply_overrides_to_tspan_range_with_elem(
                            &tp.tspans, lo, hi, &overrides, Some(elem));
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

    /// Push the typed paragraph panel state onto every paragraph
    /// wrapper tspan inside the selection. The wrapper tspan is the
    /// one whose `jas_role == "paragraph"`. Per the identity-value
    /// rule, attributes equal to their default are *omitted* (set to
    /// `None`) rather than written. Phase 4.
    ///
    /// The seven alignment radio bools collapse to one
    /// `(text_align, text_align_last)` pair per the §Alignment
    /// sub-mapping; for point text / text-on-path, the same selection
    /// drives `text_anchor` on the parent `<text>` element instead.
    /// Bullets and numbered_list both write the single
    /// `jas_list_style` attribute (mutual exclusion is enforced by
    /// the setter, so at most one is non-empty).
    pub(crate) fn apply_paragraph_panel_to_selection(&mut self) {
        use crate::geometry::element::Element;
        let pp = self.paragraph_panel.clone();
        let (text_align, text_align_last) = paragraph_align_attrs(&pp);
        let text_anchor = paragraph_text_anchor(&pp);
        let list_style = if !pp.bullets.is_empty() {
            Some(pp.bullets.clone())
        } else if !pp.numbered_list.is_empty() {
            Some(pp.numbered_list.clone())
        } else {
            None
        };
        let opt_f = |v: f64| if v == 0.0 { None } else { Some(v) };
        let opt_b = |v: bool| if !v { None } else { Some(true) };
        let left_indent = opt_f(pp.left_indent);
        let right_indent = opt_f(pp.right_indent);
        let first_line_indent =
            if pp.first_line_indent == 0.0 { None } else { Some(pp.first_line_indent) };
        let space_before = opt_f(pp.space_before);
        let space_after = opt_f(pp.space_after);
        let hyph = opt_b(pp.hyphenate);
        let hang_punct = opt_b(pp.hanging_punctuation);

        let Some(tab) = self.tabs.get_mut(self.active_tab) else { return };
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
        if target_paths.is_empty() { return; }
        tab.model.snapshot();
        for path in target_paths {
            let doc = tab.model.document().clone();
            let new_elem = match doc.get_element(&path) {
                Some(Element::Text(t)) => {
                    let mut new_t = t.clone();
                    let mut tspans = new_t.tspans.clone();
                    let mut wrapper_idx: Vec<usize> = tspans.iter().enumerate()
                        .filter_map(|(i, ts)|
                            if ts.jas_role.as_deref() == Some("paragraph") { Some(i) } else { None })
                        .collect();
                    if wrapper_idx.is_empty() {
                        // Promote the first tspan to a paragraph wrapper.
                        if !tspans.is_empty() {
                            tspans[0].jas_role = Some("paragraph".into());
                            wrapper_idx.push(0);
                        }
                    }
                    for i in wrapper_idx {
                        let w = &mut tspans[i];
                        w.text_align = text_align.clone();
                        w.text_align_last = text_align_last.clone();
                        w.text_indent = first_line_indent;
                        w.jas_left_indent = left_indent;
                        w.jas_right_indent = right_indent;
                        w.jas_space_before = space_before;
                        w.jas_space_after = space_after;
                        w.jas_hyphenate = hyph;
                        w.jas_hanging_punctuation = hang_punct;
                        w.jas_list_style = list_style.clone();
                    }
                    new_t.tspans = tspans;
                    // Point text uses text-anchor on the <text> element
                    // (not the wrapper tspan) — empty text_anchor means
                    // omit per identity rule, but we store the panel
                    // mapping on the panel-anchor field which Text
                    // uses for `text-anchor`. Text element has no
                    // text_anchor field today; defer to a Phase 5
                    // rendering follow-up when text_anchor lands.
                    let _ = text_anchor;
                    Some(Element::Text(new_t))
                }
                Some(Element::TextPath(tp)) => {
                    let mut new_tp = tp.clone();
                    let mut tspans = new_tp.tspans.clone();
                    let mut wrapper_idx: Vec<usize> = tspans.iter().enumerate()
                        .filter_map(|(i, ts)|
                            if ts.jas_role.as_deref() == Some("paragraph") { Some(i) } else { None })
                        .collect();
                    if wrapper_idx.is_empty() && !tspans.is_empty() {
                        tspans[0].jas_role = Some("paragraph".into());
                        wrapper_idx.push(0);
                    }
                    for i in wrapper_idx {
                        let w = &mut tspans[i];
                        w.text_align = text_align.clone();
                        w.text_align_last = text_align_last.clone();
                        w.text_indent = first_line_indent;
                        w.jas_left_indent = left_indent;
                        w.jas_right_indent = right_indent;
                        w.jas_space_before = space_before;
                        w.jas_space_after = space_after;
                        w.jas_hyphenate = hyph;
                        w.jas_hanging_punctuation = hang_punct;
                        w.jas_list_style = list_style.clone();
                    }
                    new_tp.tspans = tspans;
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

    /// Reset every Paragraph panel control to its default per
    /// PARAGRAPH.md §Reset Panel and *remove* the corresponding
    /// `jas:*` / `text-*` attributes from every paragraph wrapper
    /// tspan in the selection (identity-value rule: defaults appear
    /// as absence). Phase 4.
    pub(crate) fn reset_paragraph_panel(&mut self) {
        self.paragraph_panel = ParagraphPanelState::default();
        self.apply_paragraph_panel_to_selection();
    }

    /// Reset every Align panel control to its default per ALIGN.md
    /// §Panel menu Reset Panel: align_to = Selection, key object
    /// path cleared, distribute_spacing = 0, use_preview_bounds =
    /// false.
    pub(crate) fn reset_align_panel(&mut self) {
        self.align_panel = AlignPanelState::default();
    }

    /// Make a compound shape from the current selection. Wraps
    /// `Controller::make_compound_shape`; a snapshot effect runs
    /// first per the yaml dispatch order, so each click is one
    /// undoable transaction.
    pub(crate) fn apply_make_compound_shape(&mut self) {
        if let Some(tab) = self.tab_mut() {
            crate::document::controller::Controller::make_compound_shape(&mut tab.model);
        }
    }

    /// Release every selected compound shape, restoring its
    /// operands. See `Controller::release_compound_shape`.
    pub(crate) fn apply_release_compound_shape(&mut self) {
        if let Some(tab) = self.tab_mut() {
            crate::document::controller::Controller::release_compound_shape(&mut tab.model);
        }
    }

    /// Expand every selected compound shape to static polygons.
    /// See `Controller::expand_compound_shape`.
    pub(crate) fn apply_expand_compound_shape(&mut self) {
        if let Some(tab) = self.tab_mut() {
            crate::document::controller::Controller::expand_compound_shape(&mut tab.model);
        }
    }

    /// Apply one of the nine destructive boolean operations.
    /// See `Controller::apply_destructive_boolean`. Reads options
    /// from `self.boolean_panel` (edited by the Boolean Options
    /// dialog).
    pub(crate) fn apply_boolean_operation(&mut self, op: &str) {
        let options = crate::document::controller::BooleanOptions {
            precision: self.boolean_panel.precision,
            remove_redundant_points: self.boolean_panel.remove_redundant_points,
            divide_remove_unpainted: self.boolean_panel.divide_remove_unpainted,
        };
        if let Some(tab) = self.tab_mut() {
            crate::document::controller::Controller::apply_destructive_boolean(
                &mut tab.model, op, &options,
            );
        }
    }

    /// Create a compound shape from the current selection using the
    /// named operation (one of union / subtract_front / intersection
    /// / exclude). Fired by Alt+click on the four Shape Mode buttons.
    pub(crate) fn apply_compound_creation(&mut self, op_name: &str) {
        use crate::geometry::live::CompoundOperation;
        let op = match op_name {
            "union" => CompoundOperation::Union,
            "subtract_front" => CompoundOperation::SubtractFront,
            "intersection" => CompoundOperation::Intersection,
            "exclude" => CompoundOperation::Exclude,
            _ => return,
        };
        if let Some(tab) = self.tab_mut() {
            crate::document::controller::Controller::make_compound_shape_with_op(
                &mut tab.model, op,
            );
        }
    }

    /// Reset the Boolean panel's transient state. Clears last_op
    /// (so Repeat becomes a no-op) without touching the Boolean
    /// Options fields.
    pub(crate) fn reset_boolean_panel(&mut self) {
        self.boolean_panel.last_op = None;
    }

    /// Re-apply the most-recent boolean operation (destructive or
    /// compound-creating) on the current selection. No-op when
    /// `boolean_panel.last_op` is None. Make / Release / Expand
    /// Compound Shape are non-repeatable per BOOLEAN.md §Repeat
    /// state so they never populate last_op.
    pub(crate) fn apply_repeat_boolean_operation(&mut self) {
        let last = match self.boolean_panel.last_op.clone() {
            Some(s) => s,
            None => return,
        };
        if let Some(op) = last.strip_suffix("_compound") {
            self.apply_compound_creation(op);
        } else {
            self.apply_boolean_operation(&last);
        }
    }

    /// Execute one of the 14 Align panel operations by name. The
    /// operation reads the current selection, builds an
    /// [`crate::algorithms::align::AlignReference`] from
    /// `self.align_panel`, calls the algorithm, and applies the
    /// resulting translations to each moved element's transform.
    ///
    /// Zero-delta outputs are discarded, so idempotent clicks
    /// don't touch the document. A snapshot must have been taken
    /// before this call (the yaml-emitted `snapshot` effect runs
    /// first, producing a single undoable transaction per button
    /// press per ALIGN.md §Undo semantics).
    pub(crate) fn apply_align_operation(&mut self, op: &str) {
        use crate::algorithms::align as aa;

        // Gather (path, &Element) pairs from the current selection.
        let Some(tab) = self.tabs.get(self.active_tab) else { return; };
        let doc = tab.model.document();
        let mut elements: Vec<(crate::document::document::ElementPath, &crate::geometry::element::Element)> = Vec::new();
        for es in &doc.selection {
            if let Some(e) = doc.get_element(&es.path) {
                elements.push((es.path.clone(), e));
            }
        }
        if elements.len() < 2 {
            return;
        }

        // Pick bounds fn per Use Preview Bounds.
        let bounds_fn: aa::BoundsFn = if self.align_panel.use_preview_bounds {
            aa::preview_bounds
        } else {
            aa::geometric_bounds
        };

        // Build reference from panel state.
        let reference = match self.align_panel.align_to {
            AlignTo::Selection => {
                let refs: Vec<&crate::geometry::element::Element> =
                    elements.iter().map(|(_, e)| *e).collect();
                aa::AlignReference::Selection(aa::union_bounds(&refs, bounds_fn))
            }
            AlignTo::Artboard => {
                // ARTBOARDS.md §Selection semantics — current =
                // topmost panel-selected artboard, else first. The
                // at-least-one invariant guarantees artboards[0]
                // exists; if it somehow doesn't, fall back to the
                // selection union so the op still moves elements.
                let selected_set: std::collections::HashSet<&str> = self
                    .artboards_panel_selection
                    .iter()
                    .map(|s| s.as_str())
                    .collect();
                let current_ab = doc
                    .artboards
                    .iter()
                    .find(|a| selected_set.contains(a.id.as_str()))
                    .or_else(|| doc.artboards.first());
                if let Some(ab) = current_ab {
                    aa::AlignReference::Artboard((ab.x, ab.y, ab.width, ab.height))
                } else {
                    let refs: Vec<&crate::geometry::element::Element> =
                        elements.iter().map(|(_, e)| *e).collect();
                    aa::AlignReference::Artboard(aa::union_bounds(&refs, bounds_fn))
                }
            }
            AlignTo::KeyObject => {
                let Some(key_path) = self.align_panel.key_object_path.clone() else {
                    return;
                };
                let Some(key_elem) = doc.get_element(&key_path) else {
                    return;
                };
                aa::AlignReference::KeyObject {
                    bbox: bounds_fn(key_elem),
                    path: key_path,
                }
            }
        };

        // Dispatch to the algorithm.
        let translations: Vec<aa::AlignTranslation> = match op {
            "align_left" => aa::align_left(&elements, &reference, bounds_fn),
            "align_horizontal_center" => aa::align_horizontal_center(&elements, &reference, bounds_fn),
            "align_right" => aa::align_right(&elements, &reference, bounds_fn),
            "align_top" => aa::align_top(&elements, &reference, bounds_fn),
            "align_vertical_center" => aa::align_vertical_center(&elements, &reference, bounds_fn),
            "align_bottom" => aa::align_bottom(&elements, &reference, bounds_fn),
            "distribute_left" => aa::distribute_left(&elements, &reference, bounds_fn),
            "distribute_horizontal_center" => aa::distribute_horizontal_center(&elements, &reference, bounds_fn),
            "distribute_right" => aa::distribute_right(&elements, &reference, bounds_fn),
            "distribute_top" => aa::distribute_top(&elements, &reference, bounds_fn),
            "distribute_vertical_center" => aa::distribute_vertical_center(&elements, &reference, bounds_fn),
            "distribute_bottom" => aa::distribute_bottom(&elements, &reference, bounds_fn),
            "distribute_vertical_spacing" => {
                let explicit = self.align_panel_explicit_gap();
                aa::distribute_vertical_spacing(&elements, &reference, explicit, bounds_fn)
            }
            "distribute_horizontal_spacing" => {
                let explicit = self.align_panel_explicit_gap();
                aa::distribute_horizontal_spacing(&elements, &reference, explicit, bounds_fn)
            }
            _ => return,
        };

        if translations.is_empty() {
            return;
        }

        // Apply translations: clone the document once, mutate each
        // moved element's transform in place.
        let tab = self.tabs.get_mut(self.active_tab).unwrap();
        let mut new_doc = tab.model.document().clone();
        for t in &translations {
            if let Some(elem) = new_doc.get_element_mut(&t.path) {
                let current = elem.common().transform.unwrap_or_default();
                elem.common_mut().transform =
                    Some(current.translated(t.dx, t.dy));
            }
        }
        tab.model.set_document(new_doc);
    }

    /// Distribute Spacing explicit gap: `Some(gap)` when the panel
    /// is in Key Object mode with a designated key, else `None`
    /// (average mode). See ALIGN.md §Distribute Spacing.
    fn align_panel_explicit_gap(&self) -> Option<f64> {
        if self.align_panel.align_to == AlignTo::KeyObject
            && self.align_panel.key_object_path.is_some()
        {
            Some(self.align_panel.distribute_spacing)
        } else {
            None
        }
    }

    /// Canvas-click intercept for key-object designation. Per
    /// ALIGN.md §Align To target, when `align_to == KeyObject` a
    /// canvas click at (x, y) designates the hit selected element
    /// as the key, toggles off if it hits the current key, or
    /// clears the key when the click falls outside any selected
    /// element.
    ///
    /// Returns `true` when the click was consumed (selection tool
    /// should not see it) and `false` when Align To is not in
    /// key-object mode (click falls through to the tool).
    pub(crate) fn try_designate_align_key_object(&mut self, x: f64, y: f64) -> bool {
        if self.align_panel.align_to != AlignTo::KeyObject {
            return false;
        }
        let Some(tab) = self.tabs.get(self.active_tab) else { return true; };
        let doc = tab.model.document();
        // Hit-test against the current selection using preview
        // bounds (matches what the user sees).
        let mut hit: Option<crate::document::document::ElementPath> = None;
        for es in &doc.selection {
            if let Some(e) = doc.get_element(&es.path) {
                let (bx, by, bw, bh) = e.bounds();
                if x >= bx && x <= bx + bw && y >= by && y <= by + bh {
                    hit = Some(es.path.clone());
                    break;
                }
            }
        }
        match hit {
            Some(p) => {
                // Toggle: clicking the current key clears it.
                if self.align_panel.key_object_path.as_ref() == Some(&p) {
                    self.align_panel.key_object_path = None;
                } else {
                    self.align_panel.key_object_path = Some(p);
                }
            }
            None => {
                self.align_panel.key_object_path = None;
            }
        }
        true
    }

    /// Clear the key-object path if the previously-designated key
    /// is no longer part of the current selection. Called after
    /// any selection change to uphold the spec guarantee:
    /// "Changing the selection so the key is no longer part of it
    /// also clears the designation automatically." Idempotent
    /// — safe to call when no key is designated.
    pub(crate) fn sync_align_key_object_from_selection(&mut self) {
        let Some(key_path) = self.align_panel.key_object_path.clone() else {
            return;
        };
        let Some(tab) = self.tabs.get(self.active_tab) else { return; };
        let doc = tab.model.document();
        let still_selected = doc.selection.iter().any(|es| es.path == key_path);
        if !still_selected {
            self.align_panel.key_object_path = None;
        }
    }

    /// Commit the 11 Justification-dialog field values onto every
    /// paragraph wrapper tspan in the selection. Per the
    /// identity-value rule each numeric value at its spec default
    /// (word-spacing 80/100/133, letter-spacing 0/0/0, glyph-scaling
    /// 100/100/100, auto-leading 120) writes `None` so the wrapper
    /// attribute is omitted. Phase 8.
    pub(crate) fn apply_justification_dialog_to_selection(
        &mut self,
        v: crate::interpreter::renderer::JustificationDialogValues,
    ) {
        use crate::geometry::element::Element;
        // Identity-value defaults from PARAGRAPH.md §Justification Dialog.
        fn opt_n(value: Option<f64>, default: f64) -> Option<f64> {
            value.and_then(|v| if (v - default).abs() < 1e-6 { None } else { Some(v) })
        }
        let ws_min = opt_n(v.word_spacing_min, 80.0);
        let ws_des = opt_n(v.word_spacing_desired, 100.0);
        let ws_max = opt_n(v.word_spacing_max, 133.0);
        let ls_min = opt_n(v.letter_spacing_min, 0.0);
        let ls_des = opt_n(v.letter_spacing_desired, 0.0);
        let ls_max = opt_n(v.letter_spacing_max, 0.0);
        let gs_min = opt_n(v.glyph_scaling_min, 100.0);
        let gs_des = opt_n(v.glyph_scaling_desired, 100.0);
        let gs_max = opt_n(v.glyph_scaling_max, 100.0);
        let auto_leading = opt_n(v.auto_leading, 120.0);
        let single_word_justify = v.single_word_justify
            .filter(|s| s != "justify");

        let Some(tab) = self.tabs.get_mut(self.active_tab) else { return };
        let target_paths: Vec<Vec<usize>> = {
            let doc = tab.model.document();
            doc.selection.iter()
                .filter_map(|es| {
                    let elem = doc.get_element(&es.path)?;
                    matches!(elem, Element::Text(_) | Element::TextPath(_))
                        .then(|| es.path.clone())
                })
                .collect()
        };
        if target_paths.is_empty() { return; }
        tab.model.snapshot();
        for path in target_paths {
            let doc = tab.model.document().clone();
            let new_elem = match doc.get_element(&path) {
                Some(Element::Text(t)) => {
                    let mut new_t = t.clone();
                    let mut tspans = new_t.tspans.clone();
                    let mut wrapper_idx: Vec<usize> = tspans.iter().enumerate()
                        .filter_map(|(i, ts)|
                            if ts.jas_role.as_deref() == Some("paragraph") { Some(i) } else { None })
                        .collect();
                    if wrapper_idx.is_empty() && !tspans.is_empty() {
                        tspans[0].jas_role = Some("paragraph".into());
                        wrapper_idx.push(0);
                    }
                    for i in wrapper_idx {
                        let w = &mut tspans[i];
                        w.jas_word_spacing_min = ws_min;
                        w.jas_word_spacing_desired = ws_des;
                        w.jas_word_spacing_max = ws_max;
                        w.jas_letter_spacing_min = ls_min;
                        w.jas_letter_spacing_desired = ls_des;
                        w.jas_letter_spacing_max = ls_max;
                        w.jas_glyph_scaling_min = gs_min;
                        w.jas_glyph_scaling_desired = gs_des;
                        w.jas_glyph_scaling_max = gs_max;
                        w.jas_auto_leading = auto_leading;
                        w.jas_single_word_justify = single_word_justify.clone();
                    }
                    new_t.tspans = tspans;
                    Some(Element::Text(new_t))
                }
                Some(Element::TextPath(tp)) => {
                    let mut new_tp = tp.clone();
                    let mut tspans = new_tp.tspans.clone();
                    let mut wrapper_idx: Vec<usize> = tspans.iter().enumerate()
                        .filter_map(|(i, ts)|
                            if ts.jas_role.as_deref() == Some("paragraph") { Some(i) } else { None })
                        .collect();
                    if wrapper_idx.is_empty() && !tspans.is_empty() {
                        tspans[0].jas_role = Some("paragraph".into());
                        wrapper_idx.push(0);
                    }
                    for i in wrapper_idx {
                        let w = &mut tspans[i];
                        w.jas_word_spacing_min = ws_min;
                        w.jas_word_spacing_desired = ws_des;
                        w.jas_word_spacing_max = ws_max;
                        w.jas_letter_spacing_min = ls_min;
                        w.jas_letter_spacing_desired = ls_des;
                        w.jas_letter_spacing_max = ls_max;
                        w.jas_glyph_scaling_min = gs_min;
                        w.jas_glyph_scaling_desired = gs_des;
                        w.jas_glyph_scaling_max = gs_max;
                        w.jas_auto_leading = auto_leading;
                        w.jas_single_word_justify = single_word_justify.clone();
                    }
                    new_tp.tspans = tspans;
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

    /// Commit the 8 Hyphenation-dialog field values onto every
    /// paragraph wrapper tspan in the selection. Per the
    /// identity-value rule each value at its spec default
    /// (master off, min-word 3, min-before 1, min-after 1,
    /// limit 0, zone 0, bias 0, capitalized off) writes `None` so
    /// the wrapper attribute is omitted. Master mirrors panel
    /// state — sync_paragraph_panel_from_selection picks up the
    /// new value next render. Phase 9.
    pub(crate) fn apply_hyphenation_dialog_to_selection(
        &mut self,
        v: crate::interpreter::renderer::HyphenationDialogValues,
    ) {
        use crate::geometry::element::Element;
        fn opt_n(value: Option<f64>, default: f64) -> Option<f64> {
            value.and_then(|v| if (v - default).abs() < 1e-6 { None } else { Some(v) })
        }
        fn opt_b(value: Option<bool>) -> Option<bool> {
            value.and_then(|v| if !v { None } else { Some(true) })
        }
        let hyph = opt_b(v.hyphenate);
        let min_word = opt_n(v.min_word, 3.0);
        let min_before = opt_n(v.min_before, 1.0);
        let min_after = opt_n(v.min_after, 1.0);
        let limit = opt_n(v.limit, 0.0);
        let zone = opt_n(v.zone, 0.0);
        let bias = opt_n(v.bias, 0.0);
        let capitalized = opt_b(v.capitalized);

        let Some(tab) = self.tabs.get_mut(self.active_tab) else { return };
        let target_paths: Vec<Vec<usize>> = {
            let doc = tab.model.document();
            doc.selection.iter()
                .filter_map(|es| {
                    let elem = doc.get_element(&es.path)?;
                    matches!(elem, Element::Text(_) | Element::TextPath(_))
                        .then(|| es.path.clone())
                })
                .collect()
        };
        if target_paths.is_empty() { return; }
        tab.model.snapshot();
        for path in target_paths {
            let doc = tab.model.document().clone();
            let new_elem = match doc.get_element(&path) {
                Some(Element::Text(t)) => {
                    let mut new_t = t.clone();
                    let mut tspans = new_t.tspans.clone();
                    let mut wrapper_idx: Vec<usize> = tspans.iter().enumerate()
                        .filter_map(|(i, ts)|
                            if ts.jas_role.as_deref() == Some("paragraph") { Some(i) } else { None })
                        .collect();
                    if wrapper_idx.is_empty() && !tspans.is_empty() {
                        tspans[0].jas_role = Some("paragraph".into());
                        wrapper_idx.push(0);
                    }
                    for i in wrapper_idx {
                        let w = &mut tspans[i];
                        w.jas_hyphenate = hyph;
                        w.jas_hyphenate_min_word = min_word;
                        w.jas_hyphenate_min_before = min_before;
                        w.jas_hyphenate_min_after = min_after;
                        w.jas_hyphenate_limit = limit;
                        w.jas_hyphenate_zone = zone;
                        w.jas_hyphenate_bias = bias;
                        w.jas_hyphenate_capitalized = capitalized;
                    }
                    new_t.tspans = tspans;
                    Some(Element::Text(new_t))
                }
                Some(Element::TextPath(tp)) => {
                    let mut new_tp = tp.clone();
                    let mut tspans = new_tp.tspans.clone();
                    let mut wrapper_idx: Vec<usize> = tspans.iter().enumerate()
                        .filter_map(|(i, ts)|
                            if ts.jas_role.as_deref() == Some("paragraph") { Some(i) } else { None })
                        .collect();
                    if wrapper_idx.is_empty() && !tspans.is_empty() {
                        tspans[0].jas_role = Some("paragraph".into());
                        wrapper_idx.push(0);
                    }
                    for i in wrapper_idx {
                        let w = &mut tspans[i];
                        w.jas_hyphenate = hyph;
                        w.jas_hyphenate_min_word = min_word;
                        w.jas_hyphenate_min_before = min_before;
                        w.jas_hyphenate_min_after = min_after;
                        w.jas_hyphenate_limit = limit;
                        w.jas_hyphenate_zone = zone;
                        w.jas_hyphenate_bias = bias;
                        w.jas_hyphenate_capitalized = capitalized;
                    }
                    new_tp.tspans = tspans;
                    Some(Element::TextPath(new_tp))
                }
                _ => None,
            };
            if let Some(elem) = new_elem {
                let new_doc = doc.replace_element(&path, elem);
                tab.model.set_document(new_doc);
            }
        }
        // Master mirror: keep the typed paragraph panel state in
        // sync so the main panel's HYPHENATE_CHECKBOX reflects the
        // dialog's commit immediately rather than waiting for the
        // next selection-change sync.
        if let Some(h) = v.hyphenate {
            self.paragraph_panel.hyphenate = h;
        }
    }

    /// Mirror the selection's paragraph wrapper attributes into the
    /// typed paragraph panel state. Called by the selection-change
    /// observer so the panel reflects the selection. When wrappers
    /// disagree the typed field stays at its prior value (the panel
    /// renderer's mixed-state aggregator independently shows blank).
    /// Phase 4.
    pub(crate) fn sync_paragraph_panel_from_selection(&mut self) {
        use crate::geometry::element::Element;
        let mut wrappers: Vec<crate::geometry::tspan::Tspan> = Vec::new();
        if let Some(tab) = self.tab() {
            let doc = tab.model.document();
            for es in doc.selection.iter() {
                if let Some(el) = doc.get_element(&es.path) {
                    let tspans: Option<&[crate::geometry::tspan::Tspan]> = match el {
                        Element::Text(t) => Some(&t.tspans[..]),
                        Element::TextPath(tp) => Some(&tp.tspans[..]),
                        _ => None,
                    };
                    if let Some(tspans) = tspans {
                        for ts in tspans {
                            if ts.jas_role.as_deref() == Some("paragraph") {
                                wrappers.push(ts.clone());
                            }
                        }
                    }
                }
            }
        }
        if wrappers.is_empty() { return; }
        fn agree<T: PartialEq + Clone>(values: &[T]) -> Option<T> {
            let first = values.first()?.clone();
            if values.iter().all(|v| *v == first) { Some(first) } else { None }
        }
        let pp = &mut self.paragraph_panel;
        let lefts: Vec<f64> = wrappers.iter().map(|w| w.jas_left_indent.unwrap_or(0.0)).collect();
        if let Some(v) = agree(&lefts) { pp.left_indent = v; }
        let rights: Vec<f64> = wrappers.iter().map(|w| w.jas_right_indent.unwrap_or(0.0)).collect();
        if let Some(v) = agree(&rights) { pp.right_indent = v; }
        let firsts: Vec<f64> = wrappers.iter().map(|w| w.text_indent.unwrap_or(0.0)).collect();
        if let Some(v) = agree(&firsts) { pp.first_line_indent = v; }
        let sb: Vec<f64> = wrappers.iter().map(|w| w.jas_space_before.unwrap_or(0.0)).collect();
        if let Some(v) = agree(&sb) { pp.space_before = v; }
        let sa: Vec<f64> = wrappers.iter().map(|w| w.jas_space_after.unwrap_or(0.0)).collect();
        if let Some(v) = agree(&sa) { pp.space_after = v; }
        let hy: Vec<bool> = wrappers.iter().map(|w| w.jas_hyphenate.unwrap_or(false)).collect();
        if let Some(v) = agree(&hy) { pp.hyphenate = v; }
        let hp: Vec<bool> = wrappers.iter().map(|w| w.jas_hanging_punctuation.unwrap_or(false)).collect();
        if let Some(v) = agree(&hp) { pp.hanging_punctuation = v; }
        let styles: Vec<String> = wrappers.iter()
            .map(|w| w.jas_list_style.clone().unwrap_or_default()).collect();
        if let Some(ls) = agree(&styles) {
            if ls.starts_with("bullet-") { pp.bullets = ls; pp.numbered_list.clear(); }
            else if ls.starts_with("num-") { pp.numbered_list = ls; pp.bullets.clear(); }
            else { pp.bullets.clear(); pp.numbered_list.clear(); }
        }
        let tas: Vec<String> = wrappers.iter()
            .map(|w| w.text_align.clone().unwrap_or_else(|| "left".into())).collect();
        let tals: Vec<String> = wrappers.iter()
            .map(|w| w.text_align_last.clone().unwrap_or_default()).collect();
        if let (Some(ta), Some(tal)) = (agree(&tas), agree(&tals)) {
            apply_align_radio(pp, &ta, &tal);
        }
    }
}

/// Map the seven alignment radio bools to a `(text_align,
/// text_align_last)` pair per PARAGRAPH.md §Alignment sub-mapping
/// (area text). Returns `(None, None)` for the default
/// `ALIGN_LEFT_BUTTON` so it is omitted per identity-value rule.
fn paragraph_align_attrs(pp: &ParagraphPanelState)
    -> (Option<String>, Option<String>) {
    if pp.align_center { (Some("center".into()), None) }
    else if pp.align_right { (Some("right".into()), None) }
    else if pp.justify_left { (Some("justify".into()), Some("left".into())) }
    else if pp.justify_center { (Some("justify".into()), Some("center".into())) }
    else if pp.justify_right { (Some("justify".into()), Some("right".into())) }
    else if pp.justify_all { (Some("justify".into()), Some("justify".into())) }
    else { (None, None) }  // ALIGN_LEFT_BUTTON (default) → omit
}

/// Map the alignment radio bools to `text-anchor` for point text /
/// text-on-path per the §Alignment sub-mapping (point text). Only
/// the three non-justify buttons map; `JUSTIFY_*` falls through to
/// the default `start` (those buttons are grayed for point text).
fn paragraph_text_anchor(pp: &ParagraphPanelState) -> Option<String> {
    if pp.align_center { Some("middle".into()) }
    else if pp.align_right { Some("end".into()) }
    else { None }  // ALIGN_LEFT_BUTTON → start (default; omit)
}

/// Inverse of `paragraph_align_attrs`: set the appropriate radio bool
/// from a `(text_align, text_align_last)` pair. Used by
/// `sync_paragraph_panel_from_selection` when reading wrappers.
fn apply_align_radio(pp: &mut ParagraphPanelState, ta: &str, tal: &str) {
    pp.align_left = false;
    pp.align_center = false;
    pp.align_right = false;
    pp.justify_left = false;
    pp.justify_center = false;
    pp.justify_right = false;
    pp.justify_all = false;
    match (ta, tal) {
        ("center", _) => pp.align_center = true,
        ("right", _) => pp.align_right = true,
        ("justify", "left") => pp.justify_left = true,
        ("justify", "center") => pp.justify_center = true,
        ("justify", "right") => pp.justify_right = true,
        ("justify", "justify") => pp.justify_all = true,
        _ => pp.align_left = true,
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

/// Drop any tspan override field that matches the parent element's
/// effective value (TSPAN.md "Character attribute writes (from
/// panels)" step 3). After this pass, the tspan only retains
/// overrides whose stored value actually differs from what the
/// element would render on its own; `merge` can then collapse
/// same-override neighbours more aggressively.
///
/// Only covers the same 13 attributes the apply pipelines emit;
/// fields that don't originate from Character-panel writes
/// (style_name, dx, fractional widths, kerning-mode, no-break,
/// text-rendering, transform) are left untouched.
pub(crate) fn identity_omit_tspan(
    t: &mut crate::geometry::tspan::Tspan,
    elem: &crate::geometry::element::Element,
) {
    use crate::geometry::element::Element;
    let (ff, fs, fw, fst, td, tt, fv, xl, rot, lh, ls, bs, aa) = match elem {
        Element::Text(te) => (
            &te.font_family, te.font_size,
            &te.font_weight, &te.font_style,
            &te.text_decoration, &te.text_transform, &te.font_variant,
            &te.xml_lang, &te.rotate,
            &te.line_height, &te.letter_spacing, &te.baseline_shift,
            &te.aa_mode,
        ),
        Element::TextPath(tp) => (
            &tp.font_family, tp.font_size,
            &tp.font_weight, &tp.font_style,
            &tp.text_decoration, &tp.text_transform, &tp.font_variant,
            &tp.xml_lang, &tp.rotate,
            &tp.line_height, &tp.letter_spacing, &tp.baseline_shift,
            &tp.aa_mode,
        ),
        _ => return,
    };
    if t.font_family.as_deref() == Some(ff.as_str()) {
        t.font_family = None;
    }
    if let Some(v) = t.font_size
        && (v - fs).abs() < 1e-6 { t.font_size = None; }
    if t.font_weight.as_deref() == Some(fw.as_str()) {
        t.font_weight = None;
    }
    if t.font_style.as_deref() == Some(fst.as_str()) {
        t.font_style = None;
    }
    // text-decoration: compare sorted parsed sets so "" and "none"
    // collapse, and "underline line-through" == "line-through underline".
    if let Some(parts) = &t.text_decoration {
        let mut a: Vec<&str> = parts.iter().map(String::as_str).collect();
        a.sort();
        let mut b: Vec<&str> = td.split_whitespace().filter(|p| *p != "none").collect();
        b.sort();
        if a == b { t.text_decoration = None; }
    }
    if t.text_transform.as_deref() == Some(tt.as_str()) {
        t.text_transform = None;
    }
    if t.font_variant.as_deref() == Some(fv.as_str()) {
        t.font_variant = None;
    }
    if t.xml_lang.as_deref() == Some(xl.as_str()) {
        t.xml_lang = None;
    }
    // rotate: element stores as string (e.g. "45"); tspan as f64.
    if let Some(v) = t.rotate {
        let elem_rot = rot.parse::<f64>().unwrap_or(0.0);
        if (v - elem_rot).abs() < 1e-6 { t.rotate = None; }
    }
    // line_height: element as "14.4pt" string; tspan as f64 (pt).
    if let Some(v) = t.line_height {
        // Empty element line_height = Auto = 120% of font_size.
        let elem_lh = parse_pt(lh).unwrap_or(fs * 1.2);
        if (v - elem_lh).abs() < 1e-6 { t.line_height = None; }
    }
    // letter_spacing: element as "0.025em"; tspan as f64 (em).
    if let Some(v) = t.letter_spacing {
        let elem_ls = parse_em_as_thousandths(ls).map(|n| n / 1000.0).unwrap_or(0.0);
        if (v - elem_ls).abs() < 1e-6 { t.letter_spacing = None; }
    }
    // baseline_shift numeric: element string may be "super" / "sub"
    // or a pt value. We can only collapse numeric values.
    if let Some(v) = t.baseline_shift {
        if let Some(elem_bs) = parse_pt(bs) {
            if (v - elem_bs).abs() < 1e-6 { t.baseline_shift = None; }
        } else if bs.is_empty() && v == 0.0 {
            t.baseline_shift = None;
        }
    }
    // jas_aa_mode: element aa_mode "Sharp" / "" both mean inherit.
    if let Some(v) = &t.jas_aa_mode {
        let elem_aa = if aa == "Sharp" { "" } else { aa.as_str() };
        if v == elem_aa {
            t.jas_aa_mode = None;
        }
    }
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
    apply_overrides_to_tspan_range_with_elem(
        tspans, char_start, char_end, overrides, None)
}

/// Same as [`apply_overrides_to_tspan_range`] but runs TSPAN.md's
/// identity-omission step when an `elem` is supplied: override fields
/// that match the parent's effective value are cleared before the
/// final `merge` so adjacent tspans can collapse freely.
pub(crate) fn apply_overrides_to_tspan_range_with_elem(
    tspans: &[crate::geometry::tspan::Tspan],
    char_start: usize,
    char_end: usize,
    overrides: &crate::geometry::tspan::Tspan,
    elem: Option<&crate::geometry::element::Element>,
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
            if let Some(e) = elem {
                identity_omit_tspan(&mut t, e);
            }
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
mod opacity_panel_state_tests {
    use super::*;
    use crate::geometry::element::BlendMode;

    #[test]
    fn default_blend_mode_is_normal() {
        let s = OpacityPanelState::default();
        assert_eq!(s.blend_mode, BlendMode::Normal);
    }

    #[test]
    fn default_opacity_is_100() {
        let s = OpacityPanelState::default();
        assert_eq!(s.opacity, 100.0);
    }

    #[test]
    fn default_thumbnails_hidden_false_options_shown_false() {
        let s = OpacityPanelState::default();
        assert!(!s.thumbnails_hidden);
        assert!(!s.options_shown);
    }

    #[test]
    fn default_new_masks_clipping_true() {
        let s = OpacityPanelState::default();
        assert!(s.new_masks_clipping);
    }

    #[test]
    fn default_new_masks_inverted_false() {
        let s = OpacityPanelState::default();
        assert!(!s.new_masks_inverted);
    }
}

#[cfg(test)]
mod editing_target_tests {
    use super::*;

    #[test]
    fn model_defaults_to_content_editing_target() {
        // Default editing target is the document's normal content —
        // mask-editing mode is entered explicitly via the
        // MASK_PREVIEW click. OPACITY.md §Preview interactions.
        let t = TabState::new();
        assert_eq!(t.model.editing_target, EditingTarget::Content);
    }

    #[test]
    fn editing_target_enter_and_exit_mask_mode() {
        let mut t = TabState::new();
        t.model.editing_target = EditingTarget::Mask(vec![0, 2, 1]);
        match &t.model.editing_target {
            EditingTarget::Mask(p) => assert_eq!(p, &vec![0, 2, 1]),
            _ => panic!("expected Mask"),
        }
        t.model.editing_target = EditingTarget::Content;
        assert_eq!(t.model.editing_target, EditingTarget::Content);
    }

    #[test]
    fn model_defaults_to_no_mask_isolation() {
        // Mask-isolation is entered explicitly via
        // Alt/Option-clicking MASK_PREVIEW. OPACITY.md §Preview
        // interactions.
        let t = TabState::new();
        assert!(t.model.mask_isolation_path.is_none());
    }

    #[test]
    fn mask_isolation_round_trips() {
        let mut t = TabState::new();
        t.model.mask_isolation_path = Some(vec![0, 3]);
        assert_eq!(t.model.mask_isolation_path, Some(vec![0, 3]));
        t.model.mask_isolation_path = None;
        assert!(t.model.mask_isolation_path.is_none());
    }
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

    // ── identity-omission ────────────────────────────────────────

    #[test]
    fn identity_omit_clears_font_weight_matching_element() {
        use crate::geometry::tspan::Tspan;
        let mut t = Tspan {
            content: "X".into(),
            font_weight: Some("normal".into()),
            ..Tspan::default_tspan()
        };
        let elem = crate::tools::text_edit::empty_text_elem(0.0, 0.0, 0.0, 0.0);
        // empty_text_elem has font_weight="normal", so the tspan's
        // Some("normal") is redundant → should be cleared.
        identity_omit_tspan(&mut t, &Element::Text(elem));
        assert!(t.font_weight.is_none());
    }

    #[test]
    fn identity_omit_keeps_font_weight_differing_from_element() {
        use crate::geometry::tspan::Tspan;
        let mut t = Tspan {
            content: "X".into(),
            font_weight: Some("bold".into()),
            ..Tspan::default_tspan()
        };
        let elem = crate::tools::text_edit::empty_text_elem(0.0, 0.0, 0.0, 0.0);
        identity_omit_tspan(&mut t, &Element::Text(elem));
        assert_eq!(t.font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn identity_omit_clears_line_height_matching_auto_default() {
        use crate::geometry::tspan::Tspan;
        let mut t = Tspan {
            content: "X".into(),
            // Element's empty line_height = Auto = 120% of font_size (16 by default).
            line_height: Some(19.2),
            ..Tspan::default_tspan()
        };
        let elem = crate::tools::text_edit::empty_text_elem(0.0, 0.0, 0.0, 0.0);
        identity_omit_tspan(&mut t, &Element::Text(elem));
        assert!(t.line_height.is_none());
    }

    #[test]
    fn identity_omit_clears_text_decoration_empty_matching_none() {
        use crate::geometry::tspan::Tspan;
        let mut t = Tspan {
            content: "X".into(),
            text_decoration: Some(vec![]),
            ..Tspan::default_tspan()
        };
        // Element text_decoration starts as "none" string.
        let elem = crate::tools::text_edit::empty_text_elem(0.0, 0.0, 0.0, 0.0);
        identity_omit_tspan(&mut t, &Element::Text(elem));
        assert!(t.text_decoration.is_none());
    }

    #[test]
    fn identity_omit_end_to_end_per_range_write() {
        // Apply font_weight="normal" to a range in an element whose
        // element-level font_weight is already "normal". After the
        // per-range write, the range should have no override — the
        // merge pass can collapse everything back into one tspan.
        use crate::geometry::tspan::Tspan;
        let base = vec![
            Tspan { content: "foo".into(), font_weight: Some("bold".into()),
                    ..Tspan::default_tspan() },
        ];
        let overrides = Tspan {
            font_weight: Some("normal".into()),
            ..Tspan::default_tspan()
        };
        let elem = Element::Text(
            crate::tools::text_edit::empty_text_elem(0.0, 0.0, 0.0, 0.0));
        let out = apply_overrides_to_tspan_range_with_elem(
            &base, 0, 3, &overrides, Some(&elem));
        // After identity-omission, the Some("normal") matches the
        // element's "normal" → cleared. Then merge collapses.
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].content, "foo");
        assert!(out[0].font_weight.is_none());
    }
}

#[cfg(test)]
mod align_panel_state_tests {
    use super::*;

    #[test]
    fn align_panel_state_defaults_match_spec() {
        let s = AlignPanelState::default();
        assert_eq!(s.align_to, AlignTo::Selection);
        assert!(s.key_object_path.is_none());
        assert_eq!(s.distribute_spacing, 0.0);
        assert!(!s.use_preview_bounds);
    }

    #[test]
    fn align_to_round_trip_string() {
        for mode in [AlignTo::Selection, AlignTo::Artboard, AlignTo::KeyObject] {
            let s = mode.as_str();
            assert_eq!(AlignTo::from_str(s), Some(mode));
        }
    }

    #[test]
    fn align_to_from_str_rejects_unknown() {
        assert_eq!(AlignTo::from_str("bogus"), None);
        assert_eq!(AlignTo::from_str(""), None);
    }

    #[test]
    fn align_to_as_str_values_match_yaml_enum() {
        assert_eq!(AlignTo::Selection.as_str(), "selection");
        assert_eq!(AlignTo::Artboard.as_str(), "artboard");
        assert_eq!(AlignTo::KeyObject.as_str(), "key_object");
    }

    #[test]
    fn app_state_default_includes_align_panel_with_defaults() {
        let st = AppState::new();
        assert_eq!(st.align_panel.align_to, AlignTo::Selection);
        assert!(st.align_panel.key_object_path.is_none());
        assert_eq!(st.align_panel.distribute_spacing, 0.0);
        assert!(!st.align_panel.use_preview_bounds);
    }

    #[test]
    fn reset_align_panel_restores_all_defaults() {
        let mut st = AppState::new();
        st.align_panel.align_to = AlignTo::KeyObject;
        st.align_panel.key_object_path = Some(vec![0, 1]);
        st.align_panel.distribute_spacing = 12.0;
        st.align_panel.use_preview_bounds = true;
        st.reset_align_panel();
        assert_eq!(st.align_panel.align_to, AlignTo::Selection);
        assert!(st.align_panel.key_object_path.is_none());
        assert_eq!(st.align_panel.distribute_spacing, 0.0);
        assert!(!st.align_panel.use_preview_bounds);
    }

    // ── apply_align_operation end-to-end ─────────────────────
    // Build a minimal document with selected rects, call
    // apply_align_operation, and verify each element's transform
    // carries the expected translation.

    use crate::document::document::{Document, ElementSelection};
    use crate::geometry::element::{Element, RectElem, CommonProps, Color, Fill, Transform};

    fn make_rect(x: f64, y: f64, w: f64, h: f64) -> Element {
        Element::Rect(RectElem {
            x, y, width: w, height: h, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })
    }

    fn state_with_three_rects(rects: Vec<Element>, selected: Vec<Vec<usize>>) -> AppState {
        use crate::geometry::element::LayerElem;
        let mut st = AppState::new();
        if st.tabs.is_empty() {
            st.tabs.push(super::TabState::new());
            st.active_tab = 0;
        }
        let layer = Element::Layer(LayerElem {
            name: "L".into(),
            children: rects.into_iter().map(std::rc::Rc::new).collect(),
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let selection: Vec<ElementSelection> = selected.into_iter()
            .map(ElementSelection::all)
            .collect();
        let doc = Document { layers: vec![layer], selected_layer: 0, selection, ..Document::default() };
        st.tabs[st.active_tab].model.set_document(doc);
        st
    }

    fn transform_at(st: &AppState, path: Vec<usize>) -> Transform {
        st.tabs[st.active_tab].model.document()
            .get_element(&path)
            .and_then(|e| e.common().transform)
            .unwrap_or_default()
    }

    #[test]
    fn apply_align_left_translates_non_extremal_rects() {
        // Three rects at x = 10, 30, 60. Selection bbox min-x = 10.
        // After align_left: rect@10 unchanged, rect@30 translated -20, rect@60 translated -50.
        let rects = vec![
            make_rect(10.0, 0.0, 10.0, 10.0),
            make_rect(30.0, 0.0, 10.0, 10.0),
            make_rect(60.0, 0.0, 10.0, 10.0),
        ];
        let mut st = state_with_three_rects(
            rects,
            vec![vec![0, 0], vec![0, 1], vec![0, 2]],
        );
        st.apply_align_operation("align_left");
        // First rect at min — no translation → identity transform.
        assert_eq!(transform_at(&st, vec![0, 0]), Transform::IDENTITY);
        // Second rect needs translation of -20 in x.
        let t1 = transform_at(&st, vec![0, 1]);
        assert_eq!(t1.e, -20.0);
        assert_eq!(t1.f, 0.0);
        // Third rect needs translation of -50 in x.
        let t2 = transform_at(&st, vec![0, 2]);
        assert_eq!(t2.e, -50.0);
        assert_eq!(t2.f, 0.0);
    }

    #[test]
    fn apply_align_operation_no_op_when_fewer_than_two_selected() {
        let rects = vec![
            make_rect(0.0, 0.0, 10.0, 10.0),
            make_rect(100.0, 0.0, 10.0, 10.0),
        ];
        let mut st = state_with_three_rects(rects, vec![vec![0, 0]]);
        st.apply_align_operation("align_left");
        // Both elements still have identity transforms.
        assert_eq!(transform_at(&st, vec![0, 0]), Transform::IDENTITY);
        assert_eq!(transform_at(&st, vec![0, 1]), Transform::IDENTITY);
    }

    #[test]
    fn apply_align_operation_unknown_op_does_nothing() {
        let rects = vec![
            make_rect(0.0, 0.0, 10.0, 10.0),
            make_rect(50.0, 0.0, 10.0, 10.0),
        ];
        let mut st = state_with_three_rects(
            rects,
            vec![vec![0, 0], vec![0, 1]],
        );
        st.apply_align_operation("not_a_real_op");
        assert_eq!(transform_at(&st, vec![0, 0]), Transform::IDENTITY);
        assert_eq!(transform_at(&st, vec![0, 1]), Transform::IDENTITY);
    }

    // ── Canvas click intercept for key-object designation ────

    #[test]
    fn try_designate_returns_false_when_not_in_key_object_mode() {
        let rects = vec![
            make_rect(0.0, 0.0, 50.0, 50.0),
            make_rect(100.0, 0.0, 50.0, 50.0),
        ];
        let mut st = state_with_three_rects(
            rects,
            vec![vec![0, 0], vec![0, 1]],
        );
        // Align To defaults to Selection, so intercept must not fire.
        assert!(!st.try_designate_align_key_object(25.0, 25.0));
        assert!(st.align_panel.key_object_path.is_none());
    }

    #[test]
    fn try_designate_sets_key_on_hit_in_key_mode() {
        let rects = vec![
            make_rect(0.0, 0.0, 50.0, 50.0),
            make_rect(100.0, 0.0, 50.0, 50.0),
        ];
        let mut st = state_with_three_rects(
            rects,
            vec![vec![0, 0], vec![0, 1]],
        );
        st.align_panel.align_to = AlignTo::KeyObject;
        let consumed = st.try_designate_align_key_object(25.0, 25.0);
        assert!(consumed);
        assert_eq!(st.align_panel.key_object_path, Some(vec![0, 0]));
    }

    #[test]
    fn try_designate_second_click_on_same_element_clears_key() {
        let rects = vec![
            make_rect(0.0, 0.0, 50.0, 50.0),
            make_rect(100.0, 0.0, 50.0, 50.0),
        ];
        let mut st = state_with_three_rects(
            rects,
            vec![vec![0, 0], vec![0, 1]],
        );
        st.align_panel.align_to = AlignTo::KeyObject;
        st.try_designate_align_key_object(25.0, 25.0);
        st.try_designate_align_key_object(25.0, 25.0);
        assert!(st.align_panel.key_object_path.is_none());
    }

    #[test]
    fn try_designate_click_outside_selection_clears_key() {
        let rects = vec![
            make_rect(0.0, 0.0, 50.0, 50.0),
            make_rect(100.0, 0.0, 50.0, 50.0),
        ];
        let mut st = state_with_three_rects(
            rects,
            vec![vec![0, 0], vec![0, 1]],
        );
        st.align_panel.align_to = AlignTo::KeyObject;
        st.align_panel.key_object_path = Some(vec![0, 0]);
        // Click far off any selected rect.
        assert!(st.try_designate_align_key_object(500.0, 500.0));
        assert!(st.align_panel.key_object_path.is_none());
    }

    #[test]
    fn try_designate_click_on_different_selected_element_swaps_key() {
        let rects = vec![
            make_rect(0.0, 0.0, 50.0, 50.0),
            make_rect(100.0, 0.0, 50.0, 50.0),
        ];
        let mut st = state_with_three_rects(
            rects,
            vec![vec![0, 0], vec![0, 1]],
        );
        st.align_panel.align_to = AlignTo::KeyObject;
        st.align_panel.key_object_path = Some(vec![0, 0]);
        // Click on the second rect.
        st.try_designate_align_key_object(125.0, 25.0);
        assert_eq!(st.align_panel.key_object_path, Some(vec![0, 1]));
    }

    #[test]
    fn sync_align_key_object_noop_when_no_key() {
        let rects = vec![
            make_rect(0.0, 0.0, 50.0, 50.0),
            make_rect(100.0, 0.0, 50.0, 50.0),
        ];
        let mut st = state_with_three_rects(
            rects,
            vec![vec![0, 0], vec![0, 1]],
        );
        st.sync_align_key_object_from_selection();
        assert!(st.align_panel.key_object_path.is_none());
    }

    #[test]
    fn sync_align_key_object_preserves_still_selected_key() {
        let rects = vec![
            make_rect(0.0, 0.0, 50.0, 50.0),
            make_rect(100.0, 0.0, 50.0, 50.0),
        ];
        let mut st = state_with_three_rects(
            rects,
            vec![vec![0, 0], vec![0, 1]],
        );
        st.align_panel.key_object_path = Some(vec![0, 1]);
        st.sync_align_key_object_from_selection();
        assert_eq!(st.align_panel.key_object_path, Some(vec![0, 1]));
    }

    #[test]
    fn sync_align_key_object_clears_when_key_no_longer_selected() {
        // Selection is [0, 0] only; key references [0, 1] which is
        // not selected.
        let rects = vec![
            make_rect(0.0, 0.0, 50.0, 50.0),
            make_rect(100.0, 0.0, 50.0, 50.0),
        ];
        let mut st = state_with_three_rects(
            rects,
            vec![vec![0, 0]],
        );
        st.align_panel.key_object_path = Some(vec![0, 1]);
        st.sync_align_key_object_from_selection();
        assert!(st.align_panel.key_object_path.is_none());
    }

    #[test]
    fn apply_align_operation_uses_preview_bounds_when_set() {
        // Two stroked lines at x = 0 and 100 (width 1pt stroke
        // inflates preview bounds by 0.5 on each side).
        use crate::geometry::element::{LineElem, Stroke};
        let rects = vec![
            Element::Line(LineElem {
                x1: 0.0, y1: 5.0, x2: 0.0, y2: 15.0,
                stroke: Some(Stroke::new(Color::BLACK, 1.0)),
                width_points: Vec::new(),
                common: CommonProps::default(),
                            stroke_gradient: None,
            }),
            Element::Line(LineElem {
                x1: 100.0, y1: 5.0, x2: 100.0, y2: 15.0,
                stroke: Some(Stroke::new(Color::BLACK, 1.0)),
                width_points: Vec::new(),
                common: CommonProps::default(),
                            stroke_gradient: None,
            }),
        ];
        let mut st = state_with_three_rects(
            rects,
            vec![vec![0, 0], vec![0, 1]],
        );
        st.align_panel.use_preview_bounds = true;
        st.apply_align_operation("align_left");
        // With preview bounds, the selection's left edge is −0.5
        // (half the stroke width). Line at x=100 has preview left
        // 99.5, so it translates by 99.5 − (−0.5) = 100 in the
        // *preview frame*; but the translation delta is relative
        // to the current preview anchor. Let me recompute: target
        // is selection min = −0.5. Line[1]'s preview min = 99.5.
        // Δ = −0.5 − 99.5 = −100.
        let t = transform_at(&st, vec![0, 1]);
        assert_eq!(t.e, -100.0);
    }
}
