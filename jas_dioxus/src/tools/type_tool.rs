//! Type tool with native in-place text editing.
//!
// `select_editing_element` and `selected_text` are exposed for the
// editor shell's selection-aware menus, which aren't wired yet.
#![allow(dead_code)]
//!
//! Click on existing unlocked text to start editing it; click on empty
//! canvas to create a new (initially empty) text element and immediately
//! enter editing mode. Drag to create an area text box.
//!
//! While editing:
//!  - Mouse drag inside the editing element extends the selection.
//!  - Standard text editing keys (arrows, backspace, delete, Home/End,
//!    Cmd+A/C/X/V/Z) are routed to the session via [`on_key_event`].
//!  - The browser mouse cursor is hidden; a vertical text caret is drawn
//!    at the insertion point and flashes at the standard 530 ms cadence.
//!  - All character-level edits go through a per-session undo stack and
//!    only collapse to a *single* document-undo step (a snapshot taken
//!    on first edit).

use web_sys::CanvasRenderingContext2d;

use crate::document::controller::Controller;
use crate::document::document::ElementSelection;
use crate::document::model::Model;
use crate::geometry::element::{Color, Element, TextElem};
use crate::algorithms::text_layout::{layout, TextLayout};

use super::tool::{CanvasTool, KeyMods, DRAG_THRESHOLD};
use super::text_edit::{
    empty_text_elem, EditTarget, TextEditSession, BLINK_HALF_PERIOD_MS,
};
use super::text_measure::{font_string, make_measurer};

#[derive(Debug, Clone, Copy)]
enum State {
    Idle,
    Dragging {
        start_x: f64,
        start_y: f64,
        cur_x: f64,
        cur_y: f64,
    },
}

pub struct TypeTool {
    state: State,
    session: Option<TextEditSession>,
    /// Whether the model has been snapshotted for the current edit session.
    /// We snapshot lazily on the first content-modifying operation so that
    /// merely clicking into a text element does not pollute the undo stack.
    did_snapshot: bool,
    /// True iff the last pointer position is over an unlocked Text element.
    /// Drives the I-beam hover cursor when no session is active.
    hover_text: bool,
}

impl TypeTool {
    pub fn new() -> Self {
        Self {
            state: State::Idle,
            session: None,
            did_snapshot: false,
            hover_text: false,
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

    /// Build the layout for the currently edited Text element, if any.
    fn build_layout(&self, model: &Model) -> Option<(TextElem, TextLayout)> {
        let session = self.session.as_ref()?;
        if session.target != EditTarget::Text {
            return None;
        }
        let elem = model.document().get_element(&session.path)?;
        if let Element::Text(t) = elem {
            let mut t = t.clone();
            t.tspans = vec![crate::geometry::tspan::Tspan {
                content: session.content.clone(),
                ..crate::geometry::tspan::Tspan::default_tspan()
            }];
            let font = font_string(&t.font_style, &t.font_weight, t.font_size, &t.font_family);
            let measure = make_measurer(&font, t.font_size);
            let max_width = if t.is_area_text() { t.width } else { 0.0 };
            let content_str = t.content();
            let lay = layout(&content_str, max_width, t.font_size, measure.as_ref());
            Some((t, lay))
        } else {
            None
        }
    }

    /// Locate an unlocked Text element whose draw bounds contain (x, y).
    /// Returns (path, element clone) for the topmost match.
    fn hit_test_text(model: &Model, x: f64, y: f64) -> Option<(Vec<usize>, TextElem)> {
        fn rec(
            elem: &Element,
            path: &mut Vec<usize>,
            x: f64,
            y: f64,
            out: &mut Option<(Vec<usize>, TextElem)>,
        ) {
            match elem {
                Element::Layer(l) => {
                    for (i, child) in l.children.iter().enumerate() {
                        path.push(i);
                        rec(child, path, x, y, out);
                        path.pop();
                    }
                }
                Element::Group(g) => {
                    if g.common.locked {
                        return;
                    }
                    for (i, child) in g.children.iter().enumerate() {
                        path.push(i);
                        rec(child, path, x, y, out);
                        path.pop();
                    }
                }
                Element::Text(t) => {
                    if t.common.locked {
                        return;
                    }
                    let (tx, ty, tw, th) = text_draw_bounds(t);
                    if x >= tx && x <= tx + tw && y >= ty && y <= ty + th {
                        *out = Some((path.clone(), t.clone()));
                    }
                }
                _ => {}
            }
        }

        let doc = model.document();
        let mut out = None;
        for (li, layer) in doc.layers.iter().enumerate() {
            let mut path = vec![li];
            rec(layer, &mut path, x, y, &mut out);
        }
        out
    }

    /// Convert a canvas-space click into a cursor index inside the editing
    /// element's text. Returns 0 if there is no active session.
    fn cursor_at(&self, model: &Model, x: f64, y: f64) -> usize {
        let Some((t, lay)) = self.build_layout(model) else { return 0; };
        lay.hit_test(x - t.x, y - t.y)
    }

    fn ensure_snapshot(&mut self, model: &mut Model) {
        if !self.did_snapshot {
            model.snapshot();
            self.did_snapshot = true;
        }
    }

    /// Re-apply the session's content to the model document. Caller is
    /// responsible for calling [`ensure_snapshot`] beforehand if the call
    /// represents a content change.
    fn sync_to_model(&self, model: &mut Model) {
        let Some(session) = &self.session else { return; };
        if let Some(new_doc) = session.apply_to_document(model.document()) {
            model.set_document(new_doc);
        }
    }

    fn select_editing_element(&self, model: &mut Model) {
        let Some(session) = &self.session else { return; };
        Controller::select_element(model, &session.path);
    }

    /// Begin a new editing session on the element at `path` (which must be
    /// a Text element) with the insertion point at `cursor`.
    fn begin_session_existing(
        &mut self,
        model: &mut Model,
        path: Vec<usize>,
        elem: &TextElem,
        cursor: usize,
    ) {
        self.session = Some(TextEditSession::new(
            path.clone(),
            EditTarget::Text,
            elem.content(),
            cursor,
            now_ms(),
        ));
        self.did_snapshot = false;
        Controller::select_element(model, &path);
    }

    /// Create a new empty text element and start editing it.
    fn begin_session_new(
        &mut self,
        model: &mut Model,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    ) {
        // Inserting an element is itself a content change, so snapshot.
        model.snapshot();
        self.did_snapshot = true;
        let elem = empty_text_elem(x, y, width, height);
        let mut doc = model.document().clone();
        let layer_idx = doc.selected_layer;
        let path = if let Some(children) = doc.layers[layer_idx].children_mut() {
            let new_idx = children.len();
            children.push(std::rc::Rc::new(Element::Text(elem.clone())));
            vec![layer_idx, new_idx]
        } else {
            return;
        };
        doc.selection = vec![ElementSelection::all(path.clone())];
        model.set_document(doc);
        self.session = Some(TextEditSession::new(
            path,
            EditTarget::Text,
            String::new(),
            0,
            now_ms(),
        ));
    }

    /// End the current editing session, leaving the element in place.
    fn end_session(&mut self) {
        self.session = None;
        self.did_snapshot = false;
        self.state = State::Idle;
    }

    /// Insert clipboard text into the active session, if any. Returns true
    /// if handled (to suppress the app's element-paste path).
    ///
    /// Tspan-aware paste: when the session's tspan clipboard matches
    /// the flat text (i.e. the user cut/copied earlier in this
    /// session and the system clipboard hasn't been replaced), the
    /// captured tspan overrides splice back in at the caret rather
    /// than collapsing to a plain insert. Otherwise it falls through
    /// to the flat `insert` path.
    pub fn paste_text(&mut self, model: &mut Model, text: &str) -> bool {
        let Some(session) = self.session.as_ref() else { return false };
        // Snapshot path + clipboard match up-front so we can borrow
        // model mutably below.
        let path = session.path.clone();
        let elem_tspans: Option<Vec<crate::geometry::tspan::Tspan>> =
            model.document().get_element(&path).and_then(|e| match e {
                Element::Text(t) => Some(t.tspans.clone()),
                Element::TextPath(tp) => Some(tp.tspans.clone()),
                _ => None,
            });
        // Rich-paste preference order:
        //   1. Session-scoped tspan clipboard (fastest path, within-
        //      session cut/paste of an unchanged selection).
        //   2. App-global rich clipboard (cross-session, same-app).
        //   3. Flat insert (cross-app or mismatched flat text).
        let tspan_result = elem_tspans.as_ref()
            .and_then(|tsp| session.try_paste_tspans(tsp, text))
            .or_else(|| {
                let tsp = elem_tspans.as_ref()?;
                let payload = crate::workspace::clipboard::rich_clipboard_read_matching(text)?;
                Some(crate::geometry::tspan::insert_tspans_at(
                    tsp, session.insertion, &payload))
            });
        self.ensure_snapshot(model);
        if let Some(new_tspans) = tspan_result {
            // Tspan-aware paste: update the element directly.
            let mut doc = model.document().clone();
            if let Some(elem) = doc.get_element(&path) {
                let new_elem = match elem {
                    Element::Text(t) => {
                        let mut new_t = t.clone();
                        new_t.tspans = new_tspans.clone();
                        Element::Text(new_t)
                    }
                    Element::TextPath(tp) => {
                        let mut new_tp = tp.clone();
                        new_tp.tspans = new_tspans.clone();
                        Element::TextPath(new_tp)
                    }
                    _ => return false,
                };
                doc = doc.replace_element(&path, new_elem);
                model.set_document(doc);
            }
            let session = self.session.as_mut().unwrap();
            session.content = crate::geometry::tspan::concat_content(&new_tspans);
            session.insertion = session.insertion + text.chars().count();
            session.anchor = session.insertion;
            session.blink_epoch_ms = now_ms();
            return true;
        }
        // Flat paste fallback.
        self.session.as_mut().unwrap().insert(text);
        self.session.as_mut().unwrap().blink_epoch_ms = now_ms();
        self.sync_to_model(model);
        true
    }

    /// Returns the substring currently selected in the editor, if any.
    pub fn selected_text(&self) -> Option<String> {
        self.session.as_ref().and_then(|s| s.copy_selection())
    }
}

/// Bounding box used to hit-test a Text element. Both point text and area
/// text are treated as having `e.y` at their top edge (matching the actual
/// rendering in [`canvas::render`]).
fn text_draw_bounds(t: &TextElem) -> (f64, f64, f64, f64) {
    if t.is_area_text() {
        (t.x, t.y, t.width.max(1.0), t.height.max(1.0))
    } else {
        // Approximate width per line, using the widest line; height grows
        // with the number of hard-broken lines so multi-line point text
        // hit-tests correctly.
        let content_str = t.content();
        let lines: Vec<&str> = if content_str.is_empty() {
            vec![""]
        } else {
            content_str.split('\n').collect()
        };
        let max_chars = lines.iter().map(|l| l.chars().count()).max().unwrap_or(0);
        let w = (max_chars.max(1) as f64) * t.font_size * 0.55;
        let h = lines.len() as f64 * t.font_size;
        (t.x, t.y, w, h)
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

/// CSS color string for the caret / selection accents derived from the
/// element's fill (falling back to stroke, then black).
fn accent_color_css(t: &TextElem) -> String {
    let c = t
        .fill
        .as_ref()
        .map(|f| f.color)
        .or_else(|| t.stroke.as_ref().map(|s| s.color))
        .unwrap_or(Color::BLACK);
    let (r, g, b, _) = c.to_rgba();
    format!(
        "rgb({},{},{})",
        (r * 255.0) as u8,
        (g * 255.0) as u8,
        (b * 255.0) as u8,
    )
}

/// Pick a selection-highlight color that contrasts with both the fill and
/// the stroke. Defaults to light blue, falls back to a yellow if light blue
/// is too close in luminance to either text color.
fn selection_color_css(t: &TextElem) -> String {
    let mut light_blue_ok = true;
    let candidates = [t.fill.as_ref().map(|f| f.color), t.stroke.as_ref().map(|s| s.color)];
    let blue_lum = relative_luminance(0.529, 0.808, 0.980); // light sky blue
    for c in candidates.into_iter().flatten() {
        let (r, g, b, _) = c.to_rgba();
        let lum = relative_luminance(r, g, b);
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

impl CanvasTool for TypeTool {
    fn on_press(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool) {
        // Already editing? Either move the caret inside the same element
        // or end the session and re-process the click.
        if let Some(session) = &self.session {
            // Is the click inside the editing element's draw bounds?
            let same_elem_path = session.path.clone();
            let in_elem = if let Some(Element::Text(t)) = model.document().get_element(&same_elem_path) {
                let (tx, ty, tw, th) = text_draw_bounds(t);
                x >= tx && x <= tx + tw && y >= ty && y <= ty + th
            } else {
                false
            };
            if in_elem {
                let cursor = self.cursor_at(model, x, y);
                let s = self.session.as_mut().unwrap();
                s.set_insertion(cursor, false);
                s.drag_active = true;
                s.blink_epoch_ms = now_ms();
                return;
            }
            // Click outside the editing element: end the session and fall
            // through to the normal press handling below.
            self.end_session();
        }

        // Not editing. Hit-test for an unlocked text element.
        if let Some((path, t)) = Self::hit_test_text(model, x, y) {
            self.begin_session_existing(model, path, &t, 0);
            // Reposition caret based on click point.
            let cursor = self.cursor_at(model, x, y);
            let s = self.session.as_mut().unwrap();
            s.set_insertion(cursor, false);
            s.drag_active = true;
            s.blink_epoch_ms = now_ms();
            return;
        }

        // Empty space: start a press/drag that may create a new text on release.
        self.state = State::Dragging {
            start_x: x,
            start_y: y,
            cur_x: x,
            cur_y: y,
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
        // While editing and dragging: extend selection.
        if let Some(session) = &mut self.session
            && session.drag_active && dragging {
                let cursor = self.cursor_at(model, x, y);
                let s = self.session.as_mut().unwrap();
                s.set_insertion(cursor, true);
                s.blink_epoch_ms = now_ms();
                return;
            }

        // While dragging on empty canvas: update preview rect.
        if let State::Dragging {
            start_x, start_y, ..
        } = self.state
        {
            self.state = State::Dragging {
                start_x,
                start_y,
                cur_x: x,
                cur_y: y,
            };
        }

        // Update hover state for cursor display.
        if self.session.is_some() {
            self.hover_text = false;
        } else {
            self.hover_text = Self::hit_test_text(model, x, y).is_some();
        }
    }

    fn on_release(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool) {
        if let Some(session) = self.session.as_mut() {
            session.drag_active = false;
            session.blink_epoch_ms = now_ms();
            // Don't fall through into the dragging-create branch.
            self.state = State::Idle;
            return;
        }
        if let State::Dragging {
            start_x, start_y, ..
        } = self.state
        {
            let w = (x - start_x).abs();
            let h = (y - start_y).abs();
            if w > DRAG_THRESHOLD || h > DRAG_THRESHOLD {
                let bx = start_x.min(x);
                let by = start_y.min(y);
                self.begin_session_new(model, bx, by, w, h);
            } else {
                self.begin_session_new(model, start_x, start_y, 0.0, 0.0);
            }
        }
        self.state = State::Idle;
    }

    fn on_double_click(&mut self, _model: &mut Model, _x: f64, _y: f64) {
        if let Some(s) = &mut self.session {
            // Select word at cursor (simple: select the entire content).
            s.select_all();
            s.blink_epoch_ms = now_ms();
        }
    }

    fn on_key(&mut self, model: &mut Model, key: &str) -> bool {
        self.on_key_event(model, key, KeyMods::default())
    }

    fn on_key_event(&mut self, model: &mut Model, key: &str, mods: KeyMods) -> bool {
        let Some(session) = self.session.as_mut() else {
            return false;
        };

        // Standard editing shortcuts.
        if mods.cmd() {
            match key {
                "a" | "A" => {
                    session.select_all();
                    session.blink_epoch_ms = now_ms();
                    return true;
                }
                "z" | "Z" => {
                    if mods.shift {
                        session.redo();
                    } else {
                        session.undo();
                    }
                    session.blink_epoch_ms = now_ms();
                    self.sync_to_model(model);
                    return true;
                }
                "c" | "C" => {
                    // Capture the selection's flat text and tspan
                    // overrides in one shot — the tspan payload is
                    // consumed on paste within the same session when
                    // the system-clipboard flat text still matches.
                    let elem_tspans: Vec<crate::geometry::tspan::Tspan> = model
                        .document()
                        .get_element(&session.path)
                        .and_then(|e| match e {
                            Element::Text(t) => Some(t.tspans.clone()),
                            Element::TextPath(tp) => Some(tp.tspans.clone()),
                            _ => None,
                        })
                        .unwrap_or_default();
                    if let Some(text) = self.session.as_mut().unwrap()
                        .copy_selection_with_tspans(&elem_tspans)
                    {
                        if let Some((_, payload)) =
                            self.session.as_ref().unwrap().tspan_clipboard.clone()
                        {
                            crate::workspace::clipboard::rich_clipboard_write(
                                text.clone(), payload);
                        }
                        clipboard_write(text);
                    }
                    return true;
                }
                "x" | "X" => {
                    let elem_tspans: Vec<crate::geometry::tspan::Tspan> = model
                        .document()
                        .get_element(&session.path)
                        .and_then(|e| match e {
                            Element::Text(t) => Some(t.tspans.clone()),
                            Element::TextPath(tp) => Some(tp.tspans.clone()),
                            _ => None,
                        })
                        .unwrap_or_default();
                    if let Some(text) = self.session.as_mut().unwrap()
                        .copy_selection_with_tspans(&elem_tspans)
                    {
                        if let Some((_, payload)) =
                            self.session.as_ref().unwrap().tspan_clipboard.clone()
                        {
                            crate::workspace::clipboard::rich_clipboard_write(
                                text.clone(), payload);
                        }
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
            "Escape" => {
                self.end_session();
                return true;
            }
            "Enter" => {
                self.ensure_snapshot(model);
                let s = self.session.as_mut().unwrap();
                s.insert("\n");
                s.blink_epoch_ms = now_ms();
                self.sync_to_model(model);
                return true;
            }
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
            "ArrowUp" | "ArrowDown" => {
                let Some((_, lay)) = self.build_layout(model) else { return true; };
                let s = self.session.as_mut().unwrap();
                let new_pos = if key == "ArrowUp" {
                    lay.cursor_up(s.insertion)
                } else {
                    lay.cursor_down(s.insertion)
                };
                s.set_insertion(new_pos, mods.shift);
                s.blink_epoch_ms = now_ms();
                return true;
            }
            "Home" => {
                let Some((_, lay)) = self.build_layout(model) else { return true; };
                let s = self.session.as_mut().unwrap();
                let line = lay.line_for_cursor(s.insertion);
                let new_pos = lay.lines[line].start;
                s.set_insertion(new_pos, mods.shift);
                s.blink_epoch_ms = now_ms();
                return true;
            }
            "End" => {
                let Some((_, lay)) = self.build_layout(model) else { return true; };
                let s = self.session.as_mut().unwrap();
                let line = lay.line_for_cursor(s.insertion);
                let new_pos = lay.lines[line].end;
                s.set_insertion(new_pos, mods.shift);
                s.blink_epoch_ms = now_ms();
                return true;
            }
            _ => {}
        }

        // Printable character. Filter out single-key control keys we don't
        // want to insert (anything multi-character that wasn't matched).
        if key.chars().count() == 1 && !mods.cmd() {
            self.ensure_snapshot(model);
            self.session.as_mut().unwrap().insert(key);
            self.session.as_mut().unwrap().blink_epoch_ms = now_ms();
            self.sync_to_model(model);
            return true;
        }

        false
    }

    fn captures_keyboard(&self) -> bool {
        self.session.is_some()
    }

    fn cursor_css_override(&self) -> Option<String> {
        // While editing, always use the system I-beam ("text" in CSS).
        // Matches the Swift / OCaml / Python ports.
        if self.session.is_some() {
            return Some("text".to_string());
        }
        if self.hover_text {
            return Some(
                "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24'%3E%3Cline x1='12' y1='3' x2='12' y2='21' stroke='black' stroke-width='1.5'/%3E%3Cline x1='8' y1='3' x2='16' y2='3' stroke='black' stroke-width='1.5'/%3E%3Cline x1='8' y1='21' x2='16' y2='21' stroke='black' stroke-width='1.5'/%3E%3C/svg%3E\") 12 12, text"
                    .to_string(),
            );
        }
        None
    }

    fn is_editing(&self) -> bool {
        self.session.is_some()
    }

    fn paste_text(&mut self, model: &mut Model, text: &str) -> bool {
        TypeTool::paste_text(self, model, text)
    }

    fn edit_session_mut(&mut self) -> Option<&mut TextEditSession> {
        self.session.as_mut()
    }

    fn deactivate(&mut self, _model: &mut Model) {
        self.end_session();
    }

    fn draw_overlay(&self, model: &Model, ctx: &CanvasRenderingContext2d) {
        // Drag-create preview rectangle.
        if self.session.is_none()
            && let State::Dragging {
                start_x,
                start_y,
                cur_x,
                cur_y,
            } = self.state
            {
                let rx = start_x.min(cur_x);
                let ry = start_y.min(cur_y);
                let rw = (cur_x - start_x).abs();
                let rh = (cur_y - start_y).abs();
                if rw > 1.0 && rh > 1.0 {
                    ctx.set_stroke_style_str("rgb(100,100,100)");
                    ctx.set_line_width(1.0);
                    ctx.set_line_dash(&js_sys::Array::of2(&4.0.into(), &4.0.into()).into())
                        .ok();
                    ctx.stroke_rect(rx, ry, rw, rh);
                    ctx.set_line_dash(&js_sys::Array::new().into()).ok();
                }
            }

        // Editing overlay: selection highlights and caret.
        let Some(session) = &self.session else { return; };
        let Some((t, lay)) = self.build_layout(model) else { return; };

        let sel_color = selection_color_css(&t);
        let caret_color = accent_color_css(&t);

        // Selection rectangles.
        if session.has_selection() {
            let (lo, hi) = session.selection_range();
            ctx.set_fill_style_str(&sel_color);
            for (line_idx, line) in lay.lines.iter().enumerate() {
                let line_lo = line.start.max(lo);
                let line_hi = line.end.min(hi);
                if line_lo >= line_hi {
                    continue;
                }
                let x_lo = if line_lo == line.start {
                    0.0
                } else {
                    lay.glyphs
                        .iter()
                        .find(|g| g.idx == line_lo && g.line == line_idx)
                        .map(|g| g.x)
                        .unwrap_or(0.0)
                };
                let x_hi = if line_hi == line.end {
                    line.width
                } else {
                    lay.glyphs
                        .iter()
                        .find(|g| g.idx == line_hi && g.line == line_idx)
                        .map(|g| g.x)
                        .unwrap_or(line.width)
                };
                ctx.fill_rect(t.x + x_lo, t.y + line.top, x_hi - x_lo, line.height);
            }
        }

        // The bounding box around the edited text is not drawn
        // here — the Type tool selects the element when it starts
        // editing, so the selection overlay (see
        // `draw_selection_overlays` in `canvas/render.rs`) is
        // responsible for rendering the box. That keeps the rule
        // "area text shows its bbox iff the element is selected"
        // in a single place.

        // Caret (only if no selection or anchor==insertion, but we always
        // draw it at the insertion edge — even with a selection — so the
        // user can see where new typing will land).
        if cursor_visible(session.blink_epoch_ms) {
            let (cx, cy, ch) = lay.cursor_xy(session.insertion);
            ctx.set_stroke_style_str(&caret_color);
            ctx.set_line_width(1.5);
            ctx.begin_path();
            ctx.move_to(t.x + cx, t.y + cy - ch * 0.8);
            ctx.line_to(t.x + cx, t.y + cy + ch * 0.2);
            ctx.stroke();
        }
    }
}

/// Best-effort write to the system clipboard. Silent on failure.
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
    use crate::document::model::Model;
    use crate::geometry::element::{Color, CommonProps, Fill, LayerElem, TextElem};
    use std::rc::Rc;

    fn fresh_model() -> Model {
        Model::default()
    }

    fn model_with_text(content: &str, x: f64, y: f64) -> Model {
        let mut model = Model::default();
        let mut doc = model.document().clone();
        let elem = Element::Text(TextElem::from_string(
            x,
            y,
            content,
            "sans-serif",
            16.0,
            "normal",
            "normal",
            "none",
            0.0,
            0.0,
            Some(Fill::new(Color::BLACK)),
            None,
            CommonProps::default(),
        ));
        if let Some(children) = doc.layers[0].children_mut() {
            children.push(Rc::new(elem));
        }
        let _ = LayerElem {
            name: String::new(),
            children: Vec::new(),
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        };
        model.set_document(doc);
        model
    }

    #[test]
    fn new_tool_is_idle() {
        let tool = TypeTool::new();
        assert!(tool.is_idle());
    }

    #[test]
    fn click_on_empty_creates_text_and_starts_session() {
        let mut tool = TypeTool::new();
        let mut model = fresh_model();
        tool.on_press(&mut model, 50.0, 50.0, false, false);
        tool.on_release(&mut model, 50.0, 50.0, false, false);
        assert!(tool.session.is_some());
        let layer = &model.document().layers[0];
        if let Some(children) = layer.children() {
            assert_eq!(children.len(), 1);
            assert!(matches!(&*children[0], Element::Text(_)));
        }
    }

    #[test]
    fn click_on_existing_text_starts_session() {
        let mut tool = TypeTool::new();
        let mut model = model_with_text("hello", 100.0, 100.0);
        tool.on_press(&mut model, 105.0, 105.0, false, false);
        tool.on_release(&mut model, 105.0, 105.0, false, false);
        assert!(tool.session.is_some());
        let s = tool.session.as_ref().unwrap();
        assert_eq!(s.content, "hello");
    }

    #[test]
    fn typing_inserts_into_session() {
        let mut tool = TypeTool::new();
        let mut model = fresh_model();
        tool.on_press(&mut model, 50.0, 50.0, false, false);
        tool.on_release(&mut model, 50.0, 50.0, false, false);
        tool.on_key_event(&mut model, "a", KeyMods::default());
        tool.on_key_event(&mut model, "b", KeyMods::default());
        let s = tool.session.as_ref().unwrap();
        assert_eq!(s.content, "ab");
        // The model should reflect the new content too.
        let layer = &model.document().layers[0];
        if let Some(children) = layer.children() {
            if let Element::Text(t) = &*children[0] {
                assert_eq!(t.content(), "ab");
            } else {
                panic!("expected text element");
            }
        }
    }

    #[test]
    fn escape_ends_session_keeps_element() {
        let mut tool = TypeTool::new();
        let mut model = fresh_model();
        tool.on_press(&mut model, 50.0, 50.0, false, false);
        tool.on_release(&mut model, 50.0, 50.0, false, false);
        tool.on_key_event(&mut model, "Escape", KeyMods::default());
        assert!(tool.session.is_none());
        // The empty element should remain in the document.
        if let Some(children) = model.document().layers[0].children() {
            assert_eq!(children.len(), 1);
        }
    }

    #[test]
    fn one_snapshot_per_session_for_existing_text() {
        let mut tool = TypeTool::new();
        let mut model = model_with_text("hello", 100.0, 100.0);
        let initial_undo_depth = if model.can_undo() { 1 } else { 0 };
        tool.on_press(&mut model, 105.0, 105.0, false, false);
        tool.on_release(&mut model, 105.0, 105.0, false, false);
        // Click alone should NOT snapshot.
        assert_eq!(model.can_undo(), initial_undo_depth == 1);
        tool.on_key_event(&mut model, "X", KeyMods::default());
        assert!(model.can_undo());
        // Multiple keystrokes should not stack additional document snapshots.
        tool.on_key_event(&mut model, "Y", KeyMods::default());
        tool.on_key_event(&mut model, "Z", KeyMods::default());
        // Single document undo should restore the pre-edit state.
        model.undo();
        if let Some(children) = model.document().layers[0].children() {
            if let Element::Text(t) = &*children[0] {
                assert_eq!(t.content(), "hello");
            }
        }
    }

    #[test]
    fn cursor_override_returns_none_when_editing() {
        let mut tool = TypeTool::new();
        let mut model = fresh_model();
        tool.on_press(&mut model, 50.0, 50.0, false, false);
        tool.on_release(&mut model, 50.0, 50.0, false, false);
        // While editing, the override is the system I-beam ("text").
        assert_eq!(tool.cursor_css_override().as_deref(), Some("text"));
    }

    #[test]
    fn text_draw_bounds_grows_with_hard_line_breaks() {
        let one = TextElem::from_string(
            0.0, 0.0, "a",
            "sans-serif", 20.0,
            "normal", "normal", "none",
            0.0, 0.0,
            Some(Fill::new(Color::BLACK)), None,
            CommonProps::default(),
        );
        let mut three = one.clone();
        three.tspans = vec![crate::geometry::tspan::Tspan {
            content: "a\nb\nc".to_string(),
            ..crate::geometry::tspan::Tspan::default_tspan()
        }];
        let (_, _, _, h1) = text_draw_bounds(&one);
        let (_, _, _, h3) = text_draw_bounds(&three);
        assert_eq!(h1, 20.0);
        assert_eq!(h3, 60.0);
    }

    #[test]
    fn text_draw_bounds_width_is_widest_line() {
        let mut t = TextElem::from_string(
            0.0, 0.0, "hi\nhello",
            "sans-serif", 10.0,
            "normal", "normal", "none",
            0.0, 0.0,
            Some(Fill::new(Color::BLACK)), None,
            CommonProps::default(),
        );
        let (_, _, w_multi, _) = text_draw_bounds(&t);
        t.tspans = vec![crate::geometry::tspan::Tspan {
            content: "hello".to_string(),
            ..crate::geometry::tspan::Tspan::default_tspan()
        }];
        let (_, _, w_one, _) = text_draw_bounds(&t);
        assert_eq!(w_multi, w_one);
    }

    #[test]
    fn click_on_second_line_of_multiline_text_stays_in_session() {
        // After typing Enter then more text, a click on the second line
        // should be recognized as "inside" the edited element rather
        // than ending the session and starting a new one.
        let mut tool = TypeTool::new();
        let mut model = fresh_model();
        // Create text at (50, 50) so its first line spans roughly
        // y=[50, 66] and second line y=[66, 82] with font_size=16.
        tool.on_press(&mut model, 50.0, 50.0, false, false);
        tool.on_release(&mut model, 50.0, 50.0, false, false);
        tool.on_key_event(&mut model, "a", KeyMods::default());
        tool.on_key_event(&mut model, "Enter", KeyMods::default());
        tool.on_key_event(&mut model, "b", KeyMods::default());
        // Sanity: still one element.
        if let Some(children) = model.document().layers[0].children() {
            assert_eq!(children.len(), 1);
        }
        // Click on the second line area (well inside y range 66..82).
        tool.on_press(&mut model, 52.0, 72.0, false, false);
        tool.on_release(&mut model, 52.0, 72.0, false, false);
        // Session should still be active and no new element created.
        assert!(tool.session.is_some());
        if let Some(children) = model.document().layers[0].children() {
            assert_eq!(children.len(), 1);
        }
    }

    #[test]
    fn cursor_is_system_ibeam_throughout_session() {
        // While a session is active the cursor override is the system
        // I-beam ("text") regardless of pointer position. The previous
        // "hide while inside, restore while outside" behavior was
        // dropped to match the other ports.
        let mut tool = TypeTool::new();
        let mut model = model_with_text("hello", 100.0, 100.0);
        tool.on_press(&mut model, 105.0, 105.0, false, false);
        tool.on_release(&mut model, 105.0, 105.0, false, false);
        assert_eq!(tool.cursor_css_override().as_deref(), Some("text"));
        tool.on_move(&mut model, 1000.0, 1000.0, false, false, false);
        assert_eq!(tool.cursor_css_override().as_deref(), Some("text"));
        tool.on_move(&mut model, 110.0, 108.0, false, false, false);
        assert_eq!(tool.cursor_css_override().as_deref(), Some("text"));
    }

    #[test]
    fn captures_keyboard_only_while_editing() {
        let mut tool = TypeTool::new();
        let mut model = fresh_model();
        assert!(!tool.captures_keyboard());
        tool.on_press(&mut model, 50.0, 50.0, false, false);
        tool.on_release(&mut model, 50.0, 50.0, false, false);
        assert!(tool.captures_keyboard());
        tool.on_key_event(&mut model, "Escape", KeyMods::default());
        assert!(!tool.captures_keyboard());
    }

    #[test]
    fn arrow_keys_move_cursor() {
        let mut tool = TypeTool::new();
        let mut model = model_with_text("hello", 100.0, 100.0);
        tool.on_press(&mut model, 105.0, 105.0, false, false);
        tool.on_release(&mut model, 105.0, 105.0, false, false);
        tool.session.as_mut().unwrap().set_insertion(0, false);
        tool.on_key_event(&mut model, "ArrowRight", KeyMods::default());
        tool.on_key_event(&mut model, "ArrowRight", KeyMods::default());
        assert_eq!(tool.session.as_ref().unwrap().insertion, 2);
        tool.on_key_event(&mut model, "ArrowLeft", KeyMods::default());
        assert_eq!(tool.session.as_ref().unwrap().insertion, 1);
    }

    #[test]
    fn cmd_a_selects_all() {
        let mut tool = TypeTool::new();
        let mut model = model_with_text("hello", 100.0, 100.0);
        tool.on_press(&mut model, 105.0, 105.0, false, false);
        tool.on_release(&mut model, 105.0, 105.0, false, false);
        let mods = KeyMods { meta: true, ..Default::default() };
        tool.on_key_event(&mut model, "a", mods);
        let s = tool.session.as_ref().unwrap();
        assert_eq!(s.selection_range(), (0, 5));
    }

    #[test]
    fn cmd_z_undoes_text_edit_inside_session() {
        let mut tool = TypeTool::new();
        let mut model = model_with_text("ab", 100.0, 100.0);
        tool.on_press(&mut model, 105.0, 105.0, false, false);
        tool.on_release(&mut model, 105.0, 105.0, false, false);
        tool.session.as_mut().unwrap().set_insertion(2, false);
        tool.on_key_event(&mut model, "X", KeyMods::default());
        assert_eq!(tool.session.as_ref().unwrap().content, "abX");
        let mods = KeyMods { meta: true, ..Default::default() };
        tool.on_key_event(&mut model, "z", mods);
        assert_eq!(tool.session.as_ref().unwrap().content, "ab");
    }

    #[test]
    fn paste_text_inserts_at_caret() {
        let mut tool = TypeTool::new();
        let mut model = model_with_text("ab", 100.0, 100.0);
        tool.on_press(&mut model, 105.0, 105.0, false, false);
        tool.on_release(&mut model, 105.0, 105.0, false, false);
        tool.session.as_mut().unwrap().set_insertion(1, false);
        let handled = tool.paste_text(&mut model, "XY");
        assert!(handled);
        assert_eq!(tool.session.as_ref().unwrap().content, "aXYb");
    }

    #[test]
    fn paste_text_returns_false_when_not_editing() {
        let mut tool = TypeTool::new();
        let mut model = fresh_model();
        assert!(!tool.paste_text(&mut model, "hi"));
    }

    #[test]
    fn click_outside_ends_session_and_starts_new() {
        let mut tool = TypeTool::new();
        let mut model = model_with_text("hi", 100.0, 100.0);
        // First click: enter session on existing text.
        tool.on_press(&mut model, 105.0, 105.0, false, false);
        tool.on_release(&mut model, 105.0, 105.0, false, false);
        assert!(tool.session.is_some());
        // Click far away on empty space.
        tool.on_press(&mut model, 500.0, 500.0, false, false);
        tool.on_release(&mut model, 500.0, 500.0, false, false);
        // A new (empty) text element exists, and the session targets it.
        if let Some(children) = model.document().layers[0].children() {
            assert_eq!(children.len(), 2);
        }
        let s = tool.session.as_ref().unwrap();
        assert_eq!(s.content, "");
    }

    #[test]
    fn select_all_via_cmd_a_then_typing_replaces() {
        let mut tool = TypeTool::new();
        let mut model = model_with_text("hello", 100.0, 100.0);
        tool.on_press(&mut model, 105.0, 105.0, false, false);
        tool.on_release(&mut model, 105.0, 105.0, false, false);
        let cmd = KeyMods { meta: true, ..Default::default() };
        tool.on_key_event(&mut model, "a", cmd);
        tool.on_key_event(&mut model, "Z", KeyMods::default());
        assert_eq!(tool.session.as_ref().unwrap().content, "Z");
    }

    #[test]
    fn backspace_in_session_removes_char_before_caret() {
        let mut tool = TypeTool::new();
        let mut model = model_with_text("hello", 100.0, 100.0);
        tool.on_press(&mut model, 105.0, 105.0, false, false);
        tool.on_release(&mut model, 105.0, 105.0, false, false);
        tool.session.as_mut().unwrap().set_insertion(5, false);
        tool.on_key_event(&mut model, "Backspace", KeyMods::default());
        assert_eq!(tool.session.as_ref().unwrap().content, "hell");
    }

    #[test]
    fn home_and_end_jump_to_line_bounds() {
        let mut tool = TypeTool::new();
        let mut model = model_with_text("hello", 100.0, 100.0);
        tool.on_press(&mut model, 105.0, 105.0, false, false);
        tool.on_release(&mut model, 105.0, 105.0, false, false);
        tool.session.as_mut().unwrap().set_insertion(2, false);
        tool.on_key_event(&mut model, "Home", KeyMods::default());
        assert_eq!(tool.session.as_ref().unwrap().insertion, 0);
        tool.on_key_event(&mut model, "End", KeyMods::default());
        assert_eq!(tool.session.as_ref().unwrap().insertion, 5);
    }

    #[test]
    fn delete_forward_removes_char_after_caret() {
        let mut tool = TypeTool::new();
        let mut model = model_with_text("hello", 100.0, 100.0);
        tool.on_press(&mut model, 105.0, 105.0, false, false);
        tool.on_release(&mut model, 105.0, 105.0, false, false);
        tool.session.as_mut().unwrap().set_insertion(0, false);
        tool.on_key_event(&mut model, "Delete", KeyMods::default());
        assert_eq!(tool.session.as_ref().unwrap().content, "ello");
    }

    #[test]
    fn shift_arrow_extends_selection() {
        let mut tool = TypeTool::new();
        let mut model = model_with_text("hello", 100.0, 100.0);
        tool.on_press(&mut model, 105.0, 105.0, false, false);
        tool.on_release(&mut model, 105.0, 105.0, false, false);
        tool.session.as_mut().unwrap().set_insertion(1, false);
        let shift = KeyMods { shift: true, ..Default::default() };
        tool.on_key_event(&mut model, "ArrowRight", shift);
        tool.on_key_event(&mut model, "ArrowRight", shift);
        let s = tool.session.as_ref().unwrap();
        assert_eq!(s.insertion, 3);
        assert_eq!(s.selection_range(), (1, 3));
    }

    #[test]
    fn cmd_x_cuts_selection() {
        let mut tool = TypeTool::new();
        let mut model = model_with_text("hello", 100.0, 100.0);
        tool.on_press(&mut model, 105.0, 105.0, false, false);
        tool.on_release(&mut model, 105.0, 105.0, false, false);
        let s = tool.session.as_mut().unwrap();
        s.set_insertion(0, false);
        s.set_insertion(3, true);
        let cmd = KeyMods { meta: true, ..Default::default() };
        tool.on_key_event(&mut model, "x", cmd);
        assert_eq!(tool.session.as_ref().unwrap().content, "lo");
    }

    #[test]
    fn deactivate_ends_session() {
        let mut tool = TypeTool::new();
        let mut model = model_with_text("hi", 100.0, 100.0);
        tool.on_press(&mut model, 105.0, 105.0, false, false);
        tool.on_release(&mut model, 105.0, 105.0, false, false);
        assert!(tool.session.is_some());
        tool.deactivate(&mut model);
        assert!(tool.session.is_none());
        assert!(!tool.captures_keyboard());
    }

    #[test]
    fn cmd_shift_z_redoes_text_edit() {
        let mut tool = TypeTool::new();
        let mut model = model_with_text("ab", 100.0, 100.0);
        tool.on_press(&mut model, 105.0, 105.0, false, false);
        tool.on_release(&mut model, 105.0, 105.0, false, false);
        tool.session.as_mut().unwrap().set_insertion(2, false);
        tool.on_key_event(&mut model, "X", KeyMods::default());
        let cmd = KeyMods { meta: true, ..Default::default() };
        let cmd_shift = KeyMods { meta: true, shift: true, ..Default::default() };
        tool.on_key_event(&mut model, "z", cmd);
        assert_eq!(tool.session.as_ref().unwrap().content, "ab");
        tool.on_key_event(&mut model, "z", cmd_shift);
        assert_eq!(tool.session.as_ref().unwrap().content, "abX");
    }

    #[test]
    fn multiple_typed_chars_share_one_document_snapshot() {
        let mut tool = TypeTool::new();
        let mut model = model_with_text("hi", 100.0, 100.0);
        let baseline = model.can_undo();
        tool.on_press(&mut model, 105.0, 105.0, false, false);
        tool.on_release(&mut model, 105.0, 105.0, false, false);
        tool.session.as_mut().unwrap().set_insertion(2, false);
        tool.on_key_event(&mut model, "a", KeyMods::default());
        tool.on_key_event(&mut model, "b", KeyMods::default());
        tool.on_key_event(&mut model, "c", KeyMods::default());
        tool.on_key_event(&mut model, "Escape", KeyMods::default());
        // Exactly one undo step should restore the original.
        assert!(model.can_undo());
        model.undo();
        if let Some(children) = model.document().layers[0].children() {
            if let Element::Text(t) = &*children[0] {
                assert_eq!(t.content(), "hi");
            }
        }
        // And no further undo if there was none before.
        assert_eq!(model.can_undo(), baseline);
    }

    #[test]
    fn cmd_v_when_idle_is_not_captured() {
        let mut tool = TypeTool::new();
        let mut model = fresh_model();
        // No session: paste_text should refuse.
        assert!(!tool.paste_text(&mut model, "hi"));
    }

    #[test]
    fn enter_inserts_newline() {
        let mut tool = TypeTool::new();
        let mut model = fresh_model();
        tool.on_press(&mut model, 50.0, 50.0, false, false);
        tool.on_release(&mut model, 50.0, 50.0, false, false);
        tool.on_key_event(&mut model, "a", KeyMods::default());
        tool.on_key_event(&mut model, "Enter", KeyMods::default());
        tool.on_key_event(&mut model, "b", KeyMods::default());
        assert_eq!(tool.session.as_ref().unwrap().content, "a\nb");
    }
}
