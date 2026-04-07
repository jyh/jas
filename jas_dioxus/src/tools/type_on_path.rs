//! Type-on-path tool with native in-place text editing.
//!
//! Three creation flows:
//!  1. Drag on empty canvas → builds a curved path and starts editing
//!     a TextPath that flows along it.
//!  2. Click on an existing Path element → converts it to a TextPath and
//!     enters editing mode at the click position.
//!  3. Click on an existing TextPath → enters editing mode at the click
//!     position.
//!
//! Editing semantics, undo handling, and keyboard routing match
//! [`TypeTool`]; only the layout/hit-test is different.

use web_sys::CanvasRenderingContext2d;

use crate::document::controller::Controller;
use crate::document::document::ElementSelection;
use crate::document::model::Model;
use crate::geometry::element::{
    Color, Element, PathCommand, TextPathElem,
};
use crate::geometry::measure::{path_closest_offset, path_distance_to_point, path_point_at_offset};
use crate::geometry::path_text_layout::{layout_path_text, PathTextLayout};

use super::tool::{CanvasTool, KeyMods, DRAG_THRESHOLD, HIT_RADIUS};
use super::text_edit::{
    empty_text_path_elem, EditTarget, TextEditSession, BLINK_HALF_PERIOD_MS,
};
use super::text_measure::{font_string, make_measurer};

const OFFSET_HANDLE_RADIUS: f64 = 5.0;

#[derive(Debug, Clone)]
enum State {
    Idle,
    DragCreate {
        start_x: f64,
        start_y: f64,
        cur_x: f64,
        cur_y: f64,
        control: Option<(f64, f64)>,
    },
    OffsetDrag {
        path: Vec<usize>,
        preview: Option<f64>,
    },
}

pub struct TypeOnPathTool {
    state: State,
    session: Option<TextEditSession>,
    did_snapshot: bool,
    hover_textpath: bool,
    hover_path: bool,
}

impl TypeOnPathTool {
    pub fn new() -> Self {
        Self {
            state: State::Idle,
            session: None,
            did_snapshot: false,
            hover_textpath: false,
            hover_path: false,
        }
    }

    #[cfg(test)]
    pub fn is_idle(&self) -> bool {
        matches!(self.state, State::Idle) && self.session.is_none()
    }

    #[cfg(test)]
    pub fn session(&self) -> Option<&TextEditSession> {
        self.session.as_ref()
    }

    fn build_layout(&self, model: &Model) -> Option<(TextPathElem, PathTextLayout)> {
        let session = self.session.as_ref()?;
        if session.target != EditTarget::TextPath {
            return None;
        }
        let elem = model.document().get_element(&session.path)?;
        if let Element::TextPath(tp) = elem {
            let mut tp = tp.clone();
            tp.content = session.content.clone();
            let font = font_string(&tp.font_style, &tp.font_weight, tp.font_size, &tp.font_family);
            let measure = make_measurer(&font, tp.font_size);
            let lay = layout_path_text(&tp.d, &tp.content, tp.start_offset, tp.font_size, measure.as_ref());
            Some((tp, lay))
        } else {
            None
        }
    }

    /// Find the first Path or TextPath whose curve is close to (x, y).
    fn hit_test_path_curve(model: &Model, x: f64, y: f64) -> Option<(Vec<usize>, Element)> {
        let doc = model.document();
        let threshold = HIT_RADIUS + 2.0;
        for (li, layer) in doc.layers.iter().enumerate() {
            if let Some(children) = layer.children() {
                for (ci, child) in children.iter().enumerate() {
                    if child.common().locked {
                        continue;
                    }
                    match &**child {
                        Element::Path(e) => {
                            if path_distance_to_point(&e.d, x, y) <= threshold {
                                return Some((vec![li, ci], (**child).clone()));
                            }
                        }
                        Element::TextPath(e) => {
                            if path_distance_to_point(&e.d, x, y) <= threshold {
                                return Some((vec![li, ci], (**child).clone()));
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
        None
    }

    fn cursor_at(&self, model: &Model, x: f64, y: f64) -> usize {
        let Some((_, lay)) = self.build_layout(model) else { return 0; };
        lay.hit_test(x, y)
    }

    fn ensure_snapshot(&mut self, model: &mut Model) {
        if !self.did_snapshot {
            model.snapshot();
            self.did_snapshot = true;
        }
    }

    fn sync_to_model(&self, model: &mut Model) {
        let Some(session) = &self.session else { return; };
        if let Some(new_doc) = session.apply_to_document(model.document()) {
            model.set_document(new_doc);
        }
    }

    fn begin_session_existing(
        &mut self,
        model: &mut Model,
        path: Vec<usize>,
        elem: &TextPathElem,
        cursor: usize,
    ) {
        self.session = Some(TextEditSession::new(
            path.clone(),
            EditTarget::TextPath,
            elem.content.clone(),
            cursor,
            now_ms(),
        ));
        self.did_snapshot = false;
        Controller::select_element(model, &path);
    }

    /// Replace a Path element with an empty TextPath using the same `d`,
    /// then start an editing session.
    fn begin_session_convert_path(&mut self, model: &mut Model, path: Vec<usize>, d: Vec<PathCommand>, click_offset: f64) {
        model.snapshot();
        self.did_snapshot = true;
        let mut new_tp = empty_text_path_elem(d);
        new_tp.start_offset = click_offset;
        let new_doc = model
            .document()
            .replace_element(&path, Element::TextPath(new_tp.clone()));
        model.set_document(new_doc);
        Controller::select_element(model, &path);
        self.session = Some(TextEditSession::new(
            path,
            EditTarget::TextPath,
            String::new(),
            0,
            now_ms(),
        ));
    }

    /// Insert a brand new empty TextPath built from a drag gesture.
    fn begin_session_new_curve(&mut self, model: &mut Model, d: Vec<PathCommand>) {
        model.snapshot();
        self.did_snapshot = true;
        let new_tp = empty_text_path_elem(d);
        let mut doc = model.document().clone();
        let layer_idx = doc.selected_layer;
        let path = if let Some(children) = doc.layers[layer_idx].children_mut() {
            let new_idx = children.len();
            children.push(std::rc::Rc::new(Element::TextPath(new_tp)));
            vec![layer_idx, new_idx]
        } else {
            return;
        };
        doc.selection = vec![ElementSelection::all(path.clone())];
        model.set_document(doc);
        self.session = Some(TextEditSession::new(
            path,
            EditTarget::TextPath,
            String::new(),
            0,
            now_ms(),
        ));
    }

    fn end_session(&mut self) {
        self.session = None;
        self.did_snapshot = false;
        self.state = State::Idle;
    }

    pub fn paste_text(&mut self, model: &mut Model, text: &str) -> bool {
        if self.session.is_some() {
            self.ensure_snapshot(model);
            self.session.as_mut().unwrap().insert(text);
            self.session.as_mut().unwrap().blink_epoch_ms = now_ms();
            self.sync_to_model(model);
            true
        } else {
            false
        }
    }

    fn find_offset_handle(model: &Model, x: f64, y: f64) -> Option<(Vec<usize>, f64)> {
        let doc = model.document();
        for es in &doc.selection {
            if let Some(Element::TextPath(e)) = doc.get_element(&es.path) {
                if !e.d.is_empty() {
                    let (hx, hy) = path_point_at_offset(&e.d, e.start_offset);
                    if (x - hx).abs() <= OFFSET_HANDLE_RADIUS + 2.0
                        && (y - hy).abs() <= OFFSET_HANDLE_RADIUS + 2.0
                    {
                        return Some((es.path.clone(), e.start_offset));
                    }
                }
            }
        }
        None
    }

}

fn now_ms() -> f64 {
    #[cfg(target_arch = "wasm32")]
    {
        js_sys::Date::now()
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        0.0
    }
}

fn cursor_visible(epoch_ms: f64) -> bool {
    let elapsed = (now_ms() - epoch_ms).max(0.0);
    let phase = (elapsed / BLINK_HALF_PERIOD_MS).floor() as i64;
    phase % 2 == 0
}

fn accent_color_css(t: &TextPathElem) -> String {
    let c = t
        .fill
        .as_ref()
        .map(|f| f.color)
        .or_else(|| t.stroke.as_ref().map(|s| s.color))
        .unwrap_or(Color::BLACK);
    format!(
        "rgb({},{},{})",
        (c.r * 255.0) as u8,
        (c.g * 255.0) as u8,
        (c.b * 255.0) as u8,
    )
}

fn selection_color_css(t: &TextPathElem) -> String {
    let mut light_blue_ok = true;
    let candidates = [t.fill.as_ref().map(|f| f.color), t.stroke.as_ref().map(|s| s.color)];
    let blue_lum = relative_luminance(0.529, 0.808, 0.980);
    for c in candidates.into_iter().flatten() {
        let lum = relative_luminance(c.r, c.g, c.b);
        if (lum - blue_lum).abs() < 0.15 {
            light_blue_ok = false;
            break;
        }
    }
    if light_blue_ok {
        "rgba(135,206,250,0.45)".to_string()
    } else {
        "rgba(255,235,80,0.5)".to_string()
    }
}

fn relative_luminance(r: f64, g: f64, b: f64) -> f64 {
    0.2126 * r + 0.7152 * g + 0.0722 * b
}

impl CanvasTool for TypeOnPathTool {
    fn on_press(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool) {
        // Already editing? Click inside same element repositions cursor;
        // click outside ends the session and re-processes the press.
        if let Some(session) = &self.session {
            let path = session.path.clone();
            let near_elem = if let Some(Element::TextPath(tp)) = model.document().get_element(&path) {
                path_distance_to_point(&tp.d, x, y) <= 20.0
            } else {
                false
            };
            if near_elem {
                let cursor = self.cursor_at(model, x, y);
                let s = self.session.as_mut().unwrap();
                s.set_insertion(cursor, false);
                s.drag_active = true;
                s.blink_epoch_ms = now_ms();
                return;
            }
            self.end_session();
        }

        // Offset-handle drag on a selected TextPath.
        if let Some((path, _)) = Self::find_offset_handle(model, x, y) {
            self.state = State::OffsetDrag { path, preview: None };
            return;
        }

        // Hit-test for a Path or TextPath under the cursor.
        if let Some((path, elem)) = Self::hit_test_path_curve(model, x, y) {
            match elem {
                Element::TextPath(tp) => {
                    self.begin_session_existing(model, path, &tp, 0);
                    let cursor = self.cursor_at(model, x, y);
                    let s = self.session.as_mut().unwrap();
                    s.set_insertion(cursor, false);
                    s.drag_active = true;
                    s.blink_epoch_ms = now_ms();
                }
                Element::Path(pe) => {
                    let click_offset = path_closest_offset(&pe.d, x, y);
                    self.begin_session_convert_path(model, path, pe.d.clone(), click_offset);
                }
                _ => {}
            }
            return;
        }

        // Empty space: start a drag-create.
        self.state = State::DragCreate {
            start_x: x,
            start_y: y,
            cur_x: x,
            cur_y: y,
            control: None,
        };
    }

    fn on_move(
        &mut self,
        model: &mut Model,
        x: f64,
        y: f64,
        _shift: bool,
        _alt: bool,
        dragging: bool,
    ) {

        if let Some(session) = &mut self.session {
            if session.drag_active && dragging {
                let cursor = self.cursor_at(model, x, y);
                let s = self.session.as_mut().unwrap();
                s.set_insertion(cursor, true);
                s.blink_epoch_ms = now_ms();
                return;
            }
        }

        match &mut self.state {
            State::OffsetDrag { path, preview } => {
                if let Some(Element::TextPath(e)) = model.document().get_element(path) {
                    if !e.d.is_empty() {
                        *preview = Some(path_closest_offset(&e.d, x, y));
                    }
                }
            }
            State::DragCreate {
                start_x,
                start_y,
                cur_x,
                cur_y,
                control,
            } => {
                *cur_x = x;
                *cur_y = y;
                let sx = *start_x;
                let sy = *start_y;
                let dx = x - sx;
                let dy = y - sy;
                let dist = (dx * dx + dy * dy).sqrt();
                if dist > DRAG_THRESHOLD {
                    let nx = -dy / dist;
                    let ny = dx / dist;
                    let mx = (sx + x) / 2.0;
                    let my = (sy + y) / 2.0;
                    *control = Some((mx + nx * dist * 0.3, my + ny * dist * 0.3));
                }
            }
            State::Idle => {}
        }

        // Hover state for cursor display.
        if self.session.is_none() {
            let hit = Self::hit_test_path_curve(model, x, y);
            self.hover_textpath = matches!(hit.as_ref().map(|(_, e)| e), Some(Element::TextPath(_)));
            self.hover_path = matches!(hit.as_ref().map(|(_, e)| e), Some(Element::Path(_)));
        } else {
            self.hover_textpath = false;
            self.hover_path = false;
        }
    }


    fn on_release(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool) {
        if let Some(session) = self.session.as_mut() {
            session.drag_active = false;
            session.blink_epoch_ms = now_ms();
            self.state = State::Idle;
            return;
        }
        let state = std::mem::replace(&mut self.state, State::Idle);
        match state {
            State::OffsetDrag { path, preview } => {
                if let Some(new_offset) = preview {
                    let cloned = if let Some(Element::TextPath(e)) =
                        model.document().get_element(&path)
                    {
                        Some(e.clone())
                    } else {
                        None
                    };
                    if let Some(mut new_e) = cloned {
                        model.snapshot();
                        new_e.start_offset = new_offset;
                        let new_doc =
                            model.document().replace_element(&path, Element::TextPath(new_e));
                        model.set_document(new_doc);
                    }
                }
            }
            State::DragCreate {
                start_x,
                start_y,
                control,
                ..
            } => {
                let w = (x - start_x).abs();
                let h = (y - start_y).abs();
                if w <= DRAG_THRESHOLD && h <= DRAG_THRESHOLD {
                    // Click without drag on empty: do nothing (user must
                    // either drag a curve or click an existing path).
                    return;
                }
                let d = if let Some((cx, cy)) = control {
                    vec![
                        PathCommand::MoveTo { x: start_x, y: start_y },
                        PathCommand::CurveTo { x1: cx, y1: cy, x2: cx, y2: cy, x, y },
                    ]
                } else {
                    vec![
                        PathCommand::MoveTo { x: start_x, y: start_y },
                        PathCommand::LineTo { x, y },
                    ]
                };
                self.begin_session_new_curve(model, d);
            }
            State::Idle => {}
        }
    }

    fn on_double_click(&mut self, _model: &mut Model, _x: f64, _y: f64) {
        if let Some(s) = self.session.as_mut() {
            s.select_all();
            s.blink_epoch_ms = now_ms();
        }
    }

    fn on_key(&mut self, model: &mut Model, key: &str) -> bool {
        self.on_key_event(model, key, KeyMods::default())
    }

    fn on_key_event(&mut self, model: &mut Model, key: &str, mods: KeyMods) -> bool {
        let Some(session) = self.session.as_mut() else { return false; };

        if mods.cmd() {
            match key {
                "a" | "A" => { session.select_all(); session.blink_epoch_ms = now_ms(); return true; }
                "z" | "Z" => {
                    if mods.shift { session.redo(); } else { session.undo(); }
                    session.blink_epoch_ms = now_ms();
                    self.sync_to_model(model);
                    return true;
                }
                "c" | "C" => {
                    if let Some(text) = session.copy_selection() { clipboard_write(text); }
                    return true;
                }
                "x" | "X" => {
                    if let Some(text) = session.copy_selection() {
                        clipboard_write(text);
                        self.ensure_snapshot(model);
                        self.session.as_mut().unwrap().backspace();
                        self.session.as_mut().unwrap().blink_epoch_ms = now_ms();
                        self.sync_to_model(model);
                    }
                    return true;
                }
                _ => {}
            }
        }

        match key {
            "Escape" => { self.end_session(); return true; }
            "Backspace" => {
                self.ensure_snapshot(model);
                let s = self.session.as_mut().unwrap();
                s.backspace();
                s.blink_epoch_ms = now_ms();
                self.sync_to_model(model);
                return true;
            }
            "Delete" => {
                self.ensure_snapshot(model);
                let s = self.session.as_mut().unwrap();
                s.delete_forward();
                s.blink_epoch_ms = now_ms();
                self.sync_to_model(model);
                return true;
            }
            "ArrowLeft" => {
                let s = self.session.as_mut().unwrap();
                let new_pos = s.insertion.saturating_sub(1);
                s.set_insertion(new_pos, mods.shift);
                s.blink_epoch_ms = now_ms();
                return true;
            }
            "ArrowRight" => {
                let s = self.session.as_mut().unwrap();
                let new_pos = s.insertion + 1;
                s.set_insertion(new_pos, mods.shift);
                s.blink_epoch_ms = now_ms();
                return true;
            }
            "Home" => {
                let s = self.session.as_mut().unwrap();
                s.set_insertion(0, mods.shift);
                s.blink_epoch_ms = now_ms();
                return true;
            }
            "End" => {
                let n = session.content.chars().count();
                let s = self.session.as_mut().unwrap();
                s.set_insertion(n, mods.shift);
                s.blink_epoch_ms = now_ms();
                return true;
            }
            "Enter" => {
                // No multi-line support along a path.
                return true;
            }
            _ => {}
        }

        if key.chars().count() == 1 && !mods.cmd() {
            self.ensure_snapshot(model);
            self.session.as_mut().unwrap().insert(key);
            self.session.as_mut().unwrap().blink_epoch_ms = now_ms();
            self.sync_to_model(model);
            return true;
        }

        false
    }

    fn captures_keyboard(&self) -> bool { self.session.is_some() }

    fn cursor_css_override(&self) -> Option<String> {
        // While editing, always use the system I-beam ("text" in CSS).
        // Matches the Swift / OCaml / Python ports.
        if self.session.is_some() {
            return Some("text".to_string());
        }
        if self.hover_textpath || self.hover_path {
            return Some(
                "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24'%3E%3Cline x1='12' y1='3' x2='12' y2='21' stroke='black' stroke-width='1.5'/%3E%3Cline x1='8' y1='3' x2='16' y2='3' stroke='black' stroke-width='1.5'/%3E%3Cline x1='8' y1='21' x2='16' y2='21' stroke='black' stroke-width='1.5'/%3E%3C/svg%3E\") 12 12, text"
                    .to_string(),
            );
        }
        None
    }

    fn is_editing(&self) -> bool { self.session.is_some() }

    fn paste_text(&mut self, model: &mut Model, text: &str) -> bool {
        TypeOnPathTool::paste_text(self, model, text)
    }

    fn deactivate(&mut self, _model: &mut Model) {
        self.end_session();
    }

    fn draw_overlay(&self, model: &Model, ctx: &CanvasRenderingContext2d) {
        // Drag-create preview curve.
        if self.session.is_none() {
            if let State::DragCreate {
                start_x,
                start_y,
                cur_x,
                cur_y,
                control,
            } = &self.state
            {
                ctx.set_stroke_style_str("rgb(100,100,100)");
                ctx.set_line_width(1.0);
                ctx.set_line_dash(&js_sys::Array::of2(&4.0.into(), &4.0.into()).into()).ok();
                ctx.begin_path();
                ctx.move_to(*start_x, *start_y);
                if let Some((cx, cy)) = control {
                    ctx.bezier_curve_to(*cx, *cy, *cx, *cy, *cur_x, *cur_y);
                } else {
                    ctx.line_to(*cur_x, *cur_y);
                }
                ctx.stroke();
                ctx.set_line_dash(&js_sys::Array::new().into()).ok();
            }
        }

        // Offset handles for selected TextPaths (unchanged from old behavior).
        let doc = model.document();
        for es in &doc.selection {
            if let Some(Element::TextPath(e)) = doc.get_element(&es.path) {
                if e.d.is_empty() { continue; }
                let offset = if let State::OffsetDrag { path, preview } = &self.state {
                    if path == &es.path { preview.unwrap_or(e.start_offset) } else { e.start_offset }
                } else { e.start_offset };
                let (hx, hy) = path_point_at_offset(&e.d, offset);
                let r = OFFSET_HANDLE_RADIUS;
                ctx.set_stroke_style_str("rgb(255,140,0)");
                ctx.set_line_width(1.5);
                ctx.set_fill_style_str("rgb(255,200,80)");
                ctx.begin_path();
                ctx.move_to(hx, hy - r);
                ctx.line_to(hx + r, hy);
                ctx.line_to(hx, hy + r);
                ctx.line_to(hx - r, hy);
                ctx.close_path();
                ctx.fill();
                ctx.stroke();
            }
        }

        // Editing overlay.
        let Some(session) = &self.session else { return; };
        let Some((tp, lay)) = self.build_layout(model) else { return; };

        let sel_color = selection_color_css(&tp);
        let caret_color = accent_color_css(&tp);

        // Selection: highlight each glyph in the selected range with a
        // small rotated rectangle around its center.
        if session.has_selection() {
            let (lo, hi) = session.selection_range();
            ctx.set_fill_style_str(&sel_color);
            for g in &lay.glyphs {
                if g.idx < lo || g.idx >= hi { continue; }
                ctx.save();
                ctx.translate(g.cx, g.cy).ok();
                ctx.rotate(g.angle).ok();
                ctx.fill_rect(-g.width / 2.0, -tp.font_size * 0.8, g.width, tp.font_size);
                ctx.restore();
            }
        }

        // Caret.
        if cursor_visible(session.blink_epoch_ms) {
            if let Some((cx, cy, angle)) = lay.cursor_pos(session.insertion) {
                ctx.save();
                ctx.translate(cx, cy).ok();
                ctx.rotate(angle).ok();
                ctx.set_stroke_style_str(&caret_color);
                ctx.set_line_width(1.5);
                ctx.begin_path();
                ctx.move_to(0.0, -tp.font_size * 0.8);
                ctx.line_to(0.0, tp.font_size * 0.2);
                ctx.stroke();
                ctx.restore();
            }
        }
    }
}

fn clipboard_write(text: String) {
    #[cfg(target_arch = "wasm32")]
    {
        if let Some(window) = web_sys::window() {
            let promise = window.navigator().clipboard().write_text(&text);
            let _ = wasm_bindgen_futures::JsFuture::from(promise);
        }
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        let _ = text;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::{CommonProps, Fill, PathCommand, PathElem};
    use std::rc::Rc;

    fn fresh_model() -> Model { Model::default() }

    fn model_with_path() -> Model {
        let mut model = Model::default();
        let mut doc = model.document().clone();
        let path = Element::Path(PathElem {
            d: vec![
                PathCommand::MoveTo { x: 0.0, y: 100.0 },
                PathCommand::LineTo { x: 200.0, y: 100.0 },
            ],
            fill: None,
            stroke: Some(crate::geometry::element::Stroke::new(Color::BLACK, 1.0)),
            common: CommonProps::default(),
        });
        if let Some(children) = doc.layers[0].children_mut() {
            children.push(Rc::new(path));
        }
        model.set_document(doc);
        model
    }

    fn model_with_textpath(content: &str) -> Model {
        let mut model = Model::default();
        let mut doc = model.document().clone();
        let tp = Element::TextPath(TextPathElem {
            d: vec![
                PathCommand::MoveTo { x: 0.0, y: 100.0 },
                PathCommand::LineTo { x: 200.0, y: 100.0 },
            ],
            content: content.to_string(),
            start_offset: 0.0,
            font_family: "sans-serif".into(),
            font_size: 16.0,
            font_weight: "normal".into(),
            font_style: "normal".into(),
            text_decoration: "none".into(),
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            common: CommonProps::default(),
        });
        if let Some(children) = doc.layers[0].children_mut() {
            children.push(Rc::new(tp));
        }
        model.set_document(doc);
        model
    }

    #[test]
    fn new_tool_is_idle() {
        let tool = TypeOnPathTool::new();
        assert!(tool.is_idle());
    }

    #[test]
    fn drag_creates_textpath_and_starts_session() {
        let mut tool = TypeOnPathTool::new();
        let mut model = fresh_model();
        tool.on_press(&mut model, 10.0, 100.0, false, false);
        tool.on_move(&mut model, 200.0, 100.0, false, false, true);
        tool.on_release(&mut model, 200.0, 100.0, false, false);
        assert!(tool.session.is_some());
        if let Some(children) = model.document().layers[0].children() {
            assert_eq!(children.len(), 1);
            assert!(matches!(&*children[0], Element::TextPath(_)));
        }
    }

    #[test]
    fn click_existing_path_converts_to_textpath() {
        let mut tool = TypeOnPathTool::new();
        let mut model = model_with_path();
        tool.on_press(&mut model, 100.0, 100.0, false, false);
        tool.on_release(&mut model, 100.0, 100.0, false, false);
        assert!(tool.session.is_some());
        if let Some(children) = model.document().layers[0].children() {
            assert!(matches!(&*children[0], Element::TextPath(_)));
        }
    }

    #[test]
    fn click_existing_textpath_starts_session() {
        let mut tool = TypeOnPathTool::new();
        let mut model = model_with_textpath("abc");
        tool.on_press(&mut model, 50.0, 100.0, false, false);
        tool.on_release(&mut model, 50.0, 100.0, false, false);
        assert!(tool.session.is_some());
        assert_eq!(tool.session.as_ref().unwrap().content, "abc");
    }

    #[test]
    fn typing_inserts_into_textpath_session() {
        let mut tool = TypeOnPathTool::new();
        let mut model = model_with_textpath("");
        tool.on_press(&mut model, 50.0, 100.0, false, false);
        tool.on_release(&mut model, 50.0, 100.0, false, false);
        tool.on_key_event(&mut model, "a", KeyMods::default());
        tool.on_key_event(&mut model, "b", KeyMods::default());
        assert_eq!(tool.session.as_ref().unwrap().content, "ab");
        if let Some(children) = model.document().layers[0].children() {
            if let Element::TextPath(tp) = &*children[0] {
                assert_eq!(tp.content, "ab");
            }
        }
    }

    #[test]
    fn escape_ends_session() {
        let mut tool = TypeOnPathTool::new();
        let mut model = model_with_textpath("hi");
        tool.on_press(&mut model, 50.0, 100.0, false, false);
        tool.on_release(&mut model, 50.0, 100.0, false, false);
        tool.on_key_event(&mut model, "Escape", KeyMods::default());
        assert!(tool.session.is_none());
    }

    #[test]
    fn one_snapshot_per_session_for_existing_textpath() {
        let mut tool = TypeOnPathTool::new();
        let mut model = model_with_textpath("hi");
        assert!(!model.can_undo());
        tool.on_press(&mut model, 50.0, 100.0, false, false);
        tool.on_release(&mut model, 50.0, 100.0, false, false);
        // Click alone — no snapshot yet.
        assert!(!model.can_undo());
        tool.on_key_event(&mut model, "X", KeyMods::default());
        assert!(model.can_undo());
        tool.on_key_event(&mut model, "Y", KeyMods::default());
        model.undo();
        if let Some(children) = model.document().layers[0].children() {
            if let Element::TextPath(tp) = &*children[0] {
                assert_eq!(tp.content, "hi");
            }
        }
    }

    #[test]
    fn captures_keyboard_only_when_editing() {
        let mut tool = TypeOnPathTool::new();
        let mut model = model_with_textpath("hi");
        assert!(!tool.captures_keyboard());
        tool.on_press(&mut model, 50.0, 100.0, false, false);
        tool.on_release(&mut model, 50.0, 100.0, false, false);
        assert!(tool.captures_keyboard());
    }

    #[test]
    fn cursor_override_hides_during_session() {
        let mut tool = TypeOnPathTool::new();
        let mut model = model_with_textpath("hi");
        tool.on_press(&mut model, 50.0, 100.0, false, false);
        tool.on_release(&mut model, 50.0, 100.0, false, false);
        // While editing, the override is the system I-beam ("text").
        assert_eq!(tool.cursor_css_override().as_deref(), Some("text"));
    }

    #[test]
    fn cursor_is_system_ibeam_throughout_textpath_session() {
        let mut tool = TypeOnPathTool::new();
        let mut model = model_with_textpath("hi");
        tool.on_press(&mut model, 50.0, 100.0, false, false);
        tool.on_release(&mut model, 50.0, 100.0, false, false);
        assert_eq!(tool.cursor_css_override().as_deref(), Some("text"));
        // Path runs y=100 from x=0 to 200; move far away in y. The
        // system I-beam stays put — the previous "restore default
        // cursor when outside the path" behavior was dropped.
        tool.on_move(&mut model, 50.0, 1000.0, false, false, false);
        assert_eq!(tool.cursor_css_override().as_deref(), Some("text"));
    }

    #[test]
    fn backspace_in_session_removes_char() {
        let mut tool = TypeOnPathTool::new();
        let mut model = model_with_textpath("abc");
        tool.on_press(&mut model, 50.0, 100.0, false, false);
        tool.on_release(&mut model, 50.0, 100.0, false, false);
        tool.session.as_mut().unwrap().set_insertion(3, false);
        tool.on_key_event(&mut model, "Backspace", KeyMods::default());
        assert_eq!(tool.session.as_ref().unwrap().content, "ab");
    }

    #[test]
    fn delete_forward_in_session_removes_char_after() {
        let mut tool = TypeOnPathTool::new();
        let mut model = model_with_textpath("abc");
        tool.on_press(&mut model, 50.0, 100.0, false, false);
        tool.on_release(&mut model, 50.0, 100.0, false, false);
        tool.session.as_mut().unwrap().set_insertion(0, false);
        tool.on_key_event(&mut model, "Delete", KeyMods::default());
        assert_eq!(tool.session.as_ref().unwrap().content, "bc");
    }

    #[test]
    fn shift_arrow_extends_selection_on_path() {
        let mut tool = TypeOnPathTool::new();
        let mut model = model_with_textpath("abcd");
        tool.on_press(&mut model, 50.0, 100.0, false, false);
        tool.on_release(&mut model, 50.0, 100.0, false, false);
        tool.session.as_mut().unwrap().set_insertion(1, false);
        let shift = KeyMods { shift: true, ..Default::default() };
        tool.on_key_event(&mut model, "ArrowRight", shift);
        tool.on_key_event(&mut model, "ArrowRight", shift);
        let s = tool.session.as_ref().unwrap();
        assert_eq!(s.selection_range(), (1, 3));
    }

    #[test]
    fn cmd_a_then_type_replaces_textpath_content() {
        let mut tool = TypeOnPathTool::new();
        let mut model = model_with_textpath("hello");
        tool.on_press(&mut model, 50.0, 100.0, false, false);
        tool.on_release(&mut model, 50.0, 100.0, false, false);
        let cmd = KeyMods { meta: true, ..Default::default() };
        tool.on_key_event(&mut model, "a", cmd);
        tool.on_key_event(&mut model, "X", KeyMods::default());
        assert_eq!(tool.session.as_ref().unwrap().content, "X");
    }

    #[test]
    fn deactivate_ends_textpath_session() {
        let mut tool = TypeOnPathTool::new();
        let mut model = model_with_textpath("hi");
        tool.on_press(&mut model, 50.0, 100.0, false, false);
        tool.on_release(&mut model, 50.0, 100.0, false, false);
        assert!(tool.session.is_some());
        tool.deactivate(&mut model);
        assert!(tool.session.is_none());
    }

    #[test]
    fn cmd_z_undoes_textpath_edit_inside_session() {
        let mut tool = TypeOnPathTool::new();
        let mut model = model_with_textpath("ab");
        tool.on_press(&mut model, 50.0, 100.0, false, false);
        tool.on_release(&mut model, 50.0, 100.0, false, false);
        tool.session.as_mut().unwrap().set_insertion(2, false);
        tool.on_key_event(&mut model, "X", KeyMods::default());
        assert_eq!(tool.session.as_ref().unwrap().content, "abX");
        let cmd = KeyMods { meta: true, ..Default::default() };
        tool.on_key_event(&mut model, "z", cmd);
        assert_eq!(tool.session.as_ref().unwrap().content, "ab");
    }

    #[test]
    fn paste_inserts_text_at_caret() {
        let mut tool = TypeOnPathTool::new();
        let mut model = model_with_textpath("ab");
        tool.on_press(&mut model, 50.0, 100.0, false, false);
        tool.on_release(&mut model, 50.0, 100.0, false, false);
        tool.session.as_mut().unwrap().set_insertion(1, false);
        let handled = tool.paste_text(&mut model, "X");
        assert!(handled);
        assert_eq!(tool.session.as_ref().unwrap().content, "aXb");
    }
}
