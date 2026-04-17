//! In-place text editor state shared by [`TypeTool`] and [`TypeOnPathTool`].
//!
//! # Design overview — native in-place text editing
//!
//! Earlier versions of the type tools popped a `window.prompt()` to ask
//! the user for text. That was good enough to round-trip a string but did
//! not feel like a vector-drawing app: there was no caret, no selection,
//! no styling preview, no way to click into the middle of an existing
//! word. This module is the data core of the replacement — a fully native
//! in-place editor that lives entirely inside the canvas.
//!
//! ## Components and where they live
//!
//! The editor is split across several files so each piece can be tested
//! in isolation against a stub measurer with no DOM:
//!
//! - [`crate::algorithms::text_layout`] — pure word-wrap layout. Given a
//!   string, a max width, a font size, and a `Fn(&str) -> f64` measurer,
//!   it produces glyph rectangles, line summaries, and APIs for cursor
//!   movement (`cursor_xy`, `cursor_up`, `cursor_down`, `hit_test`,
//!   `line_for_cursor`). It is the single source of truth for *visual*
//!   cursor placement, both for rendering and for keyboard navigation.
//!
//! - [`crate::algorithms::path_text_layout`] — analogous module for
//!   text-on-path. It walks the arc length of the path, places a glyph
//!   at each character's center, and exposes `cursor_pos` and `hit_test`
//!   over arc-length. Up/Down navigation does not apply (single line).
//!
//! - [`crate::tools::text_measure`] — `make_measurer(font, size)` returns
//!   a `Box<dyn Fn(&str) -> f64>`. In the browser it lazily creates a
//!   single hidden `<canvas id="jas-text-measure">` and uses
//!   `CanvasRenderingContext2d::measure_text`. On non-wasm targets (cargo
//!   test on the host) it falls back to a deterministic `0.55 * size`
//!   stub. Layout, hit-testing, and rendering all consume this same
//!   closure so what the user sees is what the editor measures.
//!
//! - [`TextEditSession`] (this module) — the *logical* editor state for
//!   one editing session: the path to the element being edited, the
//!   current `content`, the `insertion` and `anchor` cursor positions
//!   (both in *char* indices, not byte indices), the per-session
//!   undo/redo stacks, and a `blink_epoch_ms` so the caret resets on
//!   each interaction. It exposes pure operations (`insert`, `backspace`,
//!   `delete_forward`, `set_insertion`, `select_all`, `copy_selection`,
//!   `undo`, `redo`) and a single `apply_to_document` that materializes
//!   a new `Document` with the edited content.
//!
//! - [`crate::tools::type_tool`] / [`crate::tools::type_on_path_tool`] — the
//!   `CanvasTool` impls that wire mouse and keyboard events to a
//!   `TextEditSession`. They implement hover detection, click-to-edit,
//!   click-outside-to-end, drag-to-extend-selection, the printable-key
//!   path, the special-key path (Arrows, Home, End, Delete, Backspace,
//!   Enter, Escape), and the in-session shortcuts (Cmd+A/C/X/Z and
//!   Cmd+Shift+Z). They also draw the editing overlay: bounding box,
//!   per-line selection rectangles, and the blinking vertical caret in
//!   the element's accent color.
//!
//! - [`crate::ui::app`] — wires the trait-level affordances into the
//!   Dioxus shell. When the active tool reports `captures_keyboard()`,
//!   *all* key events are routed to its `on_key_event` first, including
//!   shortcuts that would otherwise hit global handlers (Cmd+Z is the
//!   classic trap). The canvas cursor CSS is taken from
//!   `tool.cursor_css_override()`, which the type tools use to switch
//!   between the I-beam SVG (hovering text) and `none` (active session,
//!   so the rendered caret is not occluded). A 265 ms `setInterval`
//!   bumps `revision` while `tool.is_editing()`, driving the caret
//!   blink. Cmd+V is special-cased so the async clipboard read can
//!   feed the resulting plain text into `tool.paste_text(...)` without
//!   going through the usual element-paste path.
//!
//! ## Cursor model: char indices, not byte indices
//!
//! Rust strings are UTF-8 byte sequences and a single visual character
//! ('é', emoji, CJK glyphs, etc.) may take 1–4 bytes. Mixing byte and
//! char indices would be a constant source of slicing panics. The whole
//! editor pipeline therefore uses *char* indices end-to-end:
//!
//! - `insertion` and `anchor` are char indices in `0..=char_count`.
//! - `text_layout::Glyph::idx` is a char index.
//! - `apply_to_document` and selection rendering convert to byte indices
//!   only at the moment they slice into the underlying `String`, via the
//!   `char_to_byte` helper.
//!
//! Multibyte content is exercised by the `*_multibyte_*` tests.
//!
//! ## Selection model
//!
//! There is exactly one selection: the half-open char range between
//! `anchor` and `insertion` (in either order — `selection_range()`
//! returns the ordered pair). `set_insertion(pos, extend)` is the only
//! way to move the caret: with `extend=false` it collapses the selection
//! to a single point; with `extend=true` it leaves the anchor in place.
//! All selection-extending operations (mouse drag, Shift+Arrow,
//! Shift+Home/End, Cmd+A) go through this single helper, so there is
//! one place that can ever drift out of sync.
//!
//! `insert(text)`, `backspace()`, and `delete_forward()` always replace
//! the current selection if there is one — Backspace with no selection
//! deletes one char before the caret, Delete with no selection deletes
//! one char after.
//!
//! ## Layered undo: session-local vs document-wide
//!
//! Character-level editing produces dozens of micro-operations per
//! session. We do not want every keystroke to push a document-undo
//! snapshot — the user expects one Cmd+Z outside the editor to undo
//! the entire session, not the last keystroke. The editor implements
//! this with two stacks:
//!
//! 1. **Per-session** `undo` / `redo` vectors of `EditSnapshot` live on
//!    the `TextEditSession`. Each *content-changing* operation pushes
//!    the previous state. `undo()` and `redo()` walk these stacks. They
//!    are discarded on session end. Cmd+Z while editing routes here.
//!
//! 2. **Document-wide** snapshots come from `Model::snapshot()`. The
//!    tool keeps a `did_snapshot: bool` flag. The first content-changing
//!    op of the session calls `ensure_snapshot()` which lazily snapshots
//!    *once* and sets the flag. Subsequent edits in the same session do
//!    not snapshot again. When the session ends, a single document-undo
//!    step restores the pre-session state. New-element sessions
//!    (clicking on empty canvas) snapshot eagerly because creating the
//!    element is itself a content change.
//!
//! Click alone does *not* snapshot: entering an existing text element
//! to look at it is free. Tests
//! (`one_snapshot_per_session_for_existing_text` and
//! `multiple_typed_chars_share_one_document_snapshot`) lock this in.
//!
//! ## Session lifecycle
//!
//! A session begins on:
//! - Click on an unlocked Text/TextPath (existing element).
//! - Click on empty canvas with the Type tool (creates an empty Text).
//! - Drag on empty canvas with Type/TypeOnPath (creates area Text /
//!   TextPath curve).
//! - Click on an existing Path with TypeOnPath (converts to TextPath).
//!
//! and ends on:
//! - Escape key.
//! - Click outside the edited element (a click further than its
//!   bounding box).
//! - Tool change (`deactivate` is called by the app shell).
//!
//! End-of-session keeps the element even if it ended up empty (per the
//! product spec) and keeps it selected for further selection-tool
//! operations. The per-session undo stack is dropped.
//!
//! ## Rendering and the blink loop
//!
//! Rendering of text content goes through `canvas::render`, which calls
//! `text_layout::layout(...)` with the same measurer as the editor and
//! draws each line at `e.x, e.y + line.baseline_y`. This means a fresh
//! word-wrap pass happens every frame — it is cheap, deterministic, and
//! avoids any cache-coherence problems between layout and display.
//!
//! The caret is *not* rendered by `canvas::render`. It is drawn in the
//! tool's `draw_overlay` at the position reported by `cursor_xy`, with
//! visibility computed from `(now_ms() - blink_epoch_ms) % 1060ms`. The
//! 530 ms half-period matches the platform default and the
//! `blink_epoch_ms` is reset on every interaction so the caret is solid
//! the moment the user does anything.
//!
//! Selection highlight color picks light sky blue, but if its relative
//! luminance is too close to either the element's fill *or* stroke (the
//! highlight would be invisible), it falls back to yellow.
//!
//! ## Testing strategy
//!
//! Every layer is tested without a browser:
//!
//! - `text_layout` and `path_text_layout` use a `fixed(w)` deterministic
//!   measurer so geometric assertions (`cursor at idx 2 == x 20.0`) are
//!   exact.
//! - `text_edit` exercises insertion, deletion, selection mechanics,
//!   multibyte handling, undo/redo walking, and the reverse-selection
//!   ordering invariant.
//! - `type_tool` and `type_on_path` build a real `Model`, drive the
//!   tool through its `CanvasTool` methods, and assert on the resulting
//!   document state, the session content, and the document undo stack.
//!   The wasm-only paths (`js_sys::Date::now`, `web_sys::window`,
//!   clipboard write) are cfg-gated to host-safe stubs so the same
//!   tests run under `cargo test` on macOS/Linux.

use std::collections::VecDeque;

use crate::document::document::{Document, ElementPath};
use crate::geometry::element::{Element, TextElem, TextPathElem};
use crate::algorithms::text_layout::ordered_range;

/// Cursor blink half-period in milliseconds (matches the macOS default).
/// Shared by [`crate::tools::type_tool`] and [`crate::tools::type_on_path_tool`].
pub const BLINK_HALF_PERIOD_MS: f64 = 530.0;

/// Snapshot saved on the per-session undo stack.
#[derive(Debug, Clone, PartialEq)]
struct EditSnapshot {
    content: String,
    insertion: usize,
    anchor: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditTarget {
    Text,
    TextPath,
}

/// Per-edit-session state owned by the active text tool.
#[derive(Debug, Clone)]
pub struct TextEditSession {
    pub path: ElementPath,
    pub target: EditTarget,
    pub content: String,
    /// Insertion-point char index (0..=content.chars().count()).
    pub insertion: usize,
    /// Anchor of the live selection. When `anchor == insertion` there is
    /// no selection (just a caret).
    pub anchor: usize,
    /// True while the user is dragging to extend the selection.
    pub drag_active: bool,
    /// Wall-clock timestamp (ms) when the cursor was last reset; used to
    /// drive the blink animation.
    pub blink_epoch_ms: f64,
    /// Use a `VecDeque` so the O(n) cap eviction (`pop_front`) is O(1).
    undo: VecDeque<EditSnapshot>,
    redo: VecDeque<EditSnapshot>,
}

impl TextEditSession {
    pub fn new(path: ElementPath, target: EditTarget, content: String, insertion: usize, blink_epoch_ms: f64) -> Self {
        let n = content.chars().count();
        let insertion = insertion.min(n);
        Self {
            path,
            target,
            content,
            insertion,
            anchor: insertion,
            drag_active: false,
            blink_epoch_ms,
            undo: VecDeque::new(),
            redo: VecDeque::new(),
        }
    }

    pub fn has_selection(&self) -> bool {
        self.insertion != self.anchor
    }

    pub fn selection_range(&self) -> (usize, usize) {
        ordered_range(self.insertion, self.anchor)
    }

    fn snapshot(&mut self) {
        self.undo.push_back(EditSnapshot {
            content: self.content.clone(),
            insertion: self.insertion,
            anchor: self.anchor,
        });
        self.redo.clear();
        // Cap to avoid unbounded growth. `VecDeque::pop_front` is O(1).
        if self.undo.len() > 200 {
            self.undo.pop_front();
        }
    }

    pub fn undo(&mut self) {
        if let Some(prev) = self.undo.pop_back() {
            self.redo.push_back(EditSnapshot {
                content: self.content.clone(),
                insertion: self.insertion,
                anchor: self.anchor,
            });
            self.content = prev.content;
            self.insertion = prev.insertion;
            self.anchor = prev.anchor;
        }
    }

    pub fn redo(&mut self) {
        if let Some(next) = self.redo.pop_back() {
            self.undo.push_back(EditSnapshot {
                content: self.content.clone(),
                insertion: self.insertion,
                anchor: self.anchor,
            });
            self.content = next.content;
            self.insertion = next.insertion;
            self.anchor = next.anchor;
        }
    }

    /// Insert a string at the insertion point, replacing the current
    /// selection if any.
    pub fn insert(&mut self, text: &str) {
        self.snapshot();
        if self.has_selection() {
            self.delete_selection_inner();
        }
        let byte_idx = char_to_byte(&self.content, self.insertion);
        self.content.insert_str(byte_idx, text);
        let added = text.chars().count();
        self.insertion += added;
        self.anchor = self.insertion;
    }

    /// Backspace: delete the selection if any, else the char before the cursor.
    pub fn backspace(&mut self) {
        if self.has_selection() {
            self.snapshot();
            self.delete_selection_inner();
            return;
        }
        if self.insertion == 0 {
            return;
        }
        self.snapshot();
        let new_cursor = self.insertion - 1;
        let start_b = char_to_byte(&self.content, new_cursor);
        let end_b = char_to_byte(&self.content, self.insertion);
        self.content.replace_range(start_b..end_b, "");
        self.insertion = new_cursor;
        self.anchor = self.insertion;
    }

    /// Forward delete: delete the selection if any, else the char after the cursor.
    pub fn delete_forward(&mut self) {
        if self.has_selection() {
            self.snapshot();
            self.delete_selection_inner();
            return;
        }
        let n = self.content.chars().count();
        if self.insertion >= n {
            return;
        }
        self.snapshot();
        let start_b = char_to_byte(&self.content, self.insertion);
        let end_b = char_to_byte(&self.content, self.insertion + 1);
        self.content.replace_range(start_b..end_b, "");
        self.anchor = self.insertion;
    }

    fn delete_selection_inner(&mut self) {
        let (lo, hi) = self.selection_range();
        let lo_b = char_to_byte(&self.content, lo);
        let hi_b = char_to_byte(&self.content, hi);
        self.content.replace_range(lo_b..hi_b, "");
        self.insertion = lo;
        self.anchor = lo;
    }

    /// Move the insertion point. If `extend` is true, the anchor is left
    /// in place to grow the selection.
    pub fn set_insertion(&mut self, pos: usize, extend: bool) {
        let n = self.content.chars().count();
        self.insertion = pos.min(n);
        if !extend {
            self.anchor = self.insertion;
        }
    }

    pub fn select_all(&mut self) {
        self.anchor = 0;
        self.insertion = self.content.chars().count();
    }

    pub fn copy_selection(&self) -> Option<String> {
        if !self.has_selection() {
            return None;
        }
        let (lo, hi) = self.selection_range();
        let lo_b = char_to_byte(&self.content, lo);
        let hi_b = char_to_byte(&self.content, hi);
        Some(self.content[lo_b..hi_b].to_string())
    }

    /// Build a new Document with the session's current content applied to
    /// the element at `self.path`. Returns None if the path no longer points
    /// at a compatible element.
    pub fn apply_to_document(&self, doc: &Document) -> Option<Document> {
        let elem = doc.get_element(&self.path)?;
        let new_elem = match (self.target, elem) {
            (EditTarget::Text, Element::Text(t)) => {
                let mut new_t = t.clone();
                new_t.tspans = vec![crate::geometry::tspan::Tspan {
                    content: self.content.clone(),
                    ..crate::geometry::tspan::Tspan::default_tspan()
                }];
                Element::Text(new_t)
            }
            (EditTarget::TextPath, Element::TextPath(tp)) => {
                let mut new_tp = tp.clone();
                new_tp.tspans = vec![crate::geometry::tspan::Tspan {
                    content: self.content.clone(),
                    ..crate::geometry::tspan::Tspan::default_tspan()
                }];
                Element::TextPath(new_tp)
            }
            _ => return None,
        };
        Some(doc.replace_element(&self.path, new_elem))
    }
}

/// Convert a char index to a byte index in a UTF-8 string.
pub fn char_to_byte(s: &str, char_idx: usize) -> usize {
    s.char_indices()
        .nth(char_idx)
        .map(|(b, _)| b)
        .unwrap_or(s.len())
}

/// Build a new Text element with empty content at (x, y) using sensible
/// defaults. Used when the user clicks the type tool on empty canvas.
pub fn empty_text_elem(x: f64, y: f64, width: f64, height: f64) -> TextElem {
    use crate::geometry::element::{Color, CommonProps, Fill};
    TextElem::from_string(
        x,
        y,
        "",
        "sans-serif",
        16.0,
        "normal",
        "normal",
        "none",
        width,
        height,
        Some(Fill::new(Color::BLACK)),
        None,
        CommonProps::default(),
    )
}

/// Build a new TextPath element with empty content along `d`.
pub fn empty_text_path_elem(d: Vec<crate::geometry::element::PathCommand>) -> TextPathElem {
    use crate::geometry::element::{Color, CommonProps, Fill};
    TextPathElem::from_string(
        d,
        "",
        0.0,
        "sans-serif",
        16.0,
        "normal",
        "normal",
        "none",
        Some(Fill::new(Color::BLACK)),
        None,
        CommonProps::default(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(content: &str) -> TextEditSession {
        TextEditSession::new(vec![0, 0], EditTarget::Text, content.to_string(), 0, 0.0)
    }

    #[test]
    fn new_session_has_caret_at_insertion() {
        let s = TextEditSession::new(vec![0, 0], EditTarget::Text, "abc".into(), 2, 0.0);
        assert_eq!(s.insertion, 2);
        assert_eq!(s.anchor, 2);
        assert!(!s.has_selection());
    }

    #[test]
    fn insert_at_caret_advances_position() {
        let mut s = session("hello");
        s.set_insertion(5, false);
        s.insert(" world");
        assert_eq!(s.content, "hello world");
        assert_eq!(s.insertion, 11);
    }

    #[test]
    fn insert_replaces_selection() {
        let mut s = session("hello");
        s.set_insertion(0, false);
        s.set_insertion(5, true); // select all
        s.insert("hi");
        assert_eq!(s.content, "hi");
        assert_eq!(s.insertion, 2);
        assert!(!s.has_selection());
    }

    #[test]
    fn backspace_deletes_char_before_cursor() {
        let mut s = session("hello");
        s.set_insertion(5, false);
        s.backspace();
        assert_eq!(s.content, "hell");
        assert_eq!(s.insertion, 4);
    }

    #[test]
    fn backspace_at_start_is_noop() {
        let mut s = session("hi");
        s.set_insertion(0, false);
        s.backspace();
        assert_eq!(s.content, "hi");
    }

    #[test]
    fn backspace_with_selection_deletes_range() {
        let mut s = session("hello");
        s.set_insertion(1, false);
        s.set_insertion(4, true);
        s.backspace();
        assert_eq!(s.content, "ho");
        assert_eq!(s.insertion, 1);
    }

    #[test]
    fn delete_forward_removes_char_after() {
        let mut s = session("hello");
        s.set_insertion(0, false);
        s.delete_forward();
        assert_eq!(s.content, "ello");
    }

    #[test]
    fn select_all_extends_to_full_content() {
        let mut s = session("hello");
        s.select_all();
        assert_eq!(s.selection_range(), (0, 5));
    }

    #[test]
    fn copy_selection_returns_substring() {
        let mut s = session("hello");
        s.set_insertion(1, false);
        s.set_insertion(4, true);
        assert_eq!(s.copy_selection(), Some("ell".to_string()));
    }

    #[test]
    fn copy_with_no_selection_returns_none() {
        let s = session("hello");
        assert_eq!(s.copy_selection(), None);
    }

    #[test]
    fn undo_restores_previous_state() {
        let mut s = session("");
        s.insert("a");
        s.insert("b");
        assert_eq!(s.content, "ab");
        s.undo();
        assert_eq!(s.content, "a");
        s.undo();
        assert_eq!(s.content, "");
    }

    #[test]
    fn redo_replays_undone_state() {
        let mut s = session("");
        s.insert("a");
        s.undo();
        s.redo();
        assert_eq!(s.content, "a");
    }

    #[test]
    fn new_edit_clears_redo() {
        let mut s = session("");
        s.insert("a");
        s.undo();
        s.insert("b");
        s.redo();
        // The "a" redo entry was cleared by the "b" insert.
        assert_eq!(s.content, "b");
    }

    #[test]
    fn char_to_byte_handles_multibyte() {
        // 'é' is 2 bytes in UTF-8.
        let s = "aéb";
        assert_eq!(char_to_byte(s, 0), 0);
        assert_eq!(char_to_byte(s, 1), 1);
        assert_eq!(char_to_byte(s, 2), 3);
        assert_eq!(char_to_byte(s, 3), 4);
    }

    #[test]
    fn set_insertion_clamps_past_end() {
        let mut s = session("hi");
        s.set_insertion(99, false);
        assert_eq!(s.insertion, 2);
        assert_eq!(s.anchor, 2);
    }

    #[test]
    fn extend_selection_keeps_anchor() {
        let mut s = session("hello");
        s.set_insertion(2, false);
        s.set_insertion(4, true);
        assert!(s.has_selection());
        assert_eq!(s.anchor, 2);
        assert_eq!(s.insertion, 4);
        assert_eq!(s.selection_range(), (2, 4));
    }

    #[test]
    fn reverse_selection_orders_range() {
        let mut s = session("hello");
        s.set_insertion(4, false);
        s.set_insertion(1, true);
        assert!(s.has_selection());
        // anchor=4, insertion=1 → ordered (1, 4).
        assert_eq!(s.selection_range(), (1, 4));
    }

    #[test]
    fn copy_selection_handles_multibyte() {
        let mut s = session("aéb");
        s.set_insertion(0, false);
        s.set_insertion(2, true);
        assert_eq!(s.copy_selection(), Some("aé".to_string()));
    }

    #[test]
    fn delete_forward_at_end_is_noop() {
        let mut s = session("hi");
        s.set_insertion(2, false);
        s.delete_forward();
        assert_eq!(s.content, "hi");
    }

    #[test]
    fn delete_forward_with_selection_deletes_range() {
        let mut s = session("hello");
        s.set_insertion(1, false);
        s.set_insertion(4, true);
        s.delete_forward();
        assert_eq!(s.content, "ho");
    }

    #[test]
    fn multi_undo_redo_walks_history() {
        let mut s = session("");
        s.insert("a");
        s.insert("b");
        s.insert("c");
        assert_eq!(s.content, "abc");
        s.undo();
        s.undo();
        assert_eq!(s.content, "a");
        s.redo();
        assert_eq!(s.content, "ab");
        s.redo();
        assert_eq!(s.content, "abc");
    }

    #[test]
    fn undo_at_bottom_of_stack_is_noop() {
        let mut s = session("hi");
        s.undo();
        assert_eq!(s.content, "hi");
    }

    #[test]
    fn select_all_then_insert_replaces_everything() {
        let mut s = session("hello");
        s.select_all();
        s.insert("X");
        assert_eq!(s.content, "X");
        assert_eq!(s.insertion, 1);
        assert!(!s.has_selection());
    }

    #[test]
    fn backspace_with_multibyte_selection() {
        let mut s = session("aébc");
        s.set_insertion(1, false);
        s.set_insertion(3, true);
        s.backspace();
        assert_eq!(s.content, "ac");
    }

    #[test]
    fn insert_handles_multibyte_content() {
        let mut s = session("aéb");
        s.set_insertion(2, false);
        s.insert("X");
        assert_eq!(s.content, "aéXb");
    }
}
