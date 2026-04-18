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
    /// Caret side at a tspan boundary. Defaults to `Left` per
    /// `TSPAN.md` ("new text inherits attributes of the previous
    /// character"); `Right` is set by callers that crossed a boundary
    /// rightward. External char-index APIs keep working unchanged —
    /// the affinity only matters at joins.
    pub caret_affinity: crate::geometry::tspan::Affinity,
    /// True while the user is dragging to extend the selection.
    pub drag_active: bool,
    /// Wall-clock timestamp (ms) when the cursor was last reset; used to
    /// drive the blink animation.
    pub blink_epoch_ms: f64,
    /// Use a `VecDeque` so the O(n) cap eviction (`pop_front`) is O(1).
    undo: VecDeque<EditSnapshot>,
    redo: VecDeque<EditSnapshot>,
    /// Session-scoped tspan clipboard. Captured on copy/cut from the
    /// current element's tspan structure; consumed on paste when the
    /// system-clipboard flat text matches. Preserves per-range
    /// overrides across cut/paste within a single edit session.
    pub tspan_clipboard: Option<(String, Vec<crate::geometry::tspan::Tspan>)>,
    /// Next-typed-character override: a `Tspan` used as a template
    /// whose non-`None` fields are applied to characters inserted
    /// from `pending_char_start` to the current `insertion` at commit
    /// time. Primed by Character-panel writes when there is no
    /// selection (bare caret); cleared by any caret move with no
    /// selection extension and by undo/redo. Not persisted to the
    /// document — see `TSPAN.md` Text-edit session integration.
    pub pending_override: Option<crate::geometry::tspan::Tspan>,
    /// Char position where `pending_override` was primed. `None` iff
    /// `pending_override` is `None`.
    pub pending_char_start: Option<usize>,
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
            caret_affinity: crate::geometry::tspan::Affinity::Left,
            drag_active: false,
            blink_epoch_ms,
            undo: VecDeque::new(),
            redo: VecDeque::new(),
            tspan_clipboard: None,
            pending_override: None,
            pending_char_start: None,
        }
    }

    /// Prime the next-typed-character state. Non-`None` fields of
    /// `overrides` are merged into the existing pending template; the
    /// anchor position is captured on the first call (later calls
    /// layer on more attributes without moving the anchor).
    pub fn set_pending_override(&mut self, overrides: &crate::geometry::tspan::Tspan) {
        if self.pending_override.is_none() {
            self.pending_override = Some(crate::geometry::tspan::Tspan::default_tspan());
            self.pending_char_start = Some(self.insertion);
        }
        let target = self.pending_override.as_mut().unwrap();
        crate::geometry::tspan::merge_tspan_overrides(target, overrides);
    }

    pub fn clear_pending_override(&mut self) {
        self.pending_override = None;
        self.pending_char_start = None;
    }

    pub fn has_pending_override(&self) -> bool {
        self.pending_override.is_some()
    }

    /// Resolve the caret's `(tspan_idx, offset)` using `caret_affinity`.
    /// Used by the next-typed-character path and by any consumer that
    /// needs to know which tspan the caret belongs to at a boundary.
    pub fn insertion_tspan_pos(
        &self,
        element_tspans: &[crate::geometry::tspan::Tspan],
    ) -> (usize, usize) {
        crate::geometry::tspan::char_to_tspan_pos(
            element_tspans, self.insertion, self.caret_affinity)
    }

    /// Resolve the selection anchor's `(tspan_idx, offset)`. Anchors
    /// do not have an independent affinity; they track the caret's.
    pub fn anchor_tspan_pos(
        &self,
        element_tspans: &[crate::geometry::tspan::Tspan],
    ) -> (usize, usize) {
        crate::geometry::tspan::char_to_tspan_pos(
            element_tspans, self.anchor, self.caret_affinity)
    }

    /// Move the insertion point with an explicit affinity. Use this
    /// when crossing a tspan boundary — arrow-right lands with
    /// `Right`, arrow-left with `Left`.
    pub fn set_insertion_with_affinity(
        &mut self,
        pos: usize,
        affinity: crate::geometry::tspan::Affinity,
        extend: bool,
    ) {
        let n = self.content.chars().count();
        let new_pos = pos.min(n);
        // Non-extending caret movement cancels any pending next-typed-
        // character override.
        if !extend && new_pos != self.insertion {
            self.clear_pending_override();
        }
        self.insertion = new_pos;
        self.caret_affinity = affinity;
        if !extend {
            self.anchor = self.insertion;
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
            self.clear_pending_override();
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
            self.clear_pending_override();
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
        let new_pos = pos.min(n);
        // Non-extending caret movement cancels any pending next-typed-
        // character override (the user abandoned the position where
        // the override was primed).
        if !extend && new_pos != self.insertion {
            self.clear_pending_override();
        }
        self.insertion = new_pos;
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

    /// Capture the current selection's flat text *and* its tspan
    /// structure (from the supplied element tspans) into the session
    /// clipboard. Returns the flat text for the system clipboard.
    /// `None` when there is no selection.
    pub fn copy_selection_with_tspans(
        &mut self,
        element_tspans: &[crate::geometry::tspan::Tspan],
    ) -> Option<String> {
        if !self.has_selection() {
            return None;
        }
        let (lo, hi) = self.selection_range();
        let flat = {
            let lo_b = char_to_byte(&self.content, lo);
            let hi_b = char_to_byte(&self.content, hi);
            self.content[lo_b..hi_b].to_string()
        };
        let tspans = crate::geometry::tspan::copy_range(element_tspans, lo, hi);
        self.tspan_clipboard = Some((flat.clone(), tspans));
        Some(flat)
    }

    /// Try a tspan-aware paste: if `self.tspan_clipboard` holds a
    /// payload whose flat text equals `text`, splice the captured
    /// tspans into `element_tspans` at the caret and return the new
    /// tspan list. Returns `None` when the clipboard is absent or
    /// stale; the caller falls back to the flat `insert` path.
    pub fn try_paste_tspans(
        &self,
        element_tspans: &[crate::geometry::tspan::Tspan],
        text: &str,
    ) -> Option<Vec<crate::geometry::tspan::Tspan>> {
        let (flat, payload) = self.tspan_clipboard.as_ref()?;
        if flat != text {
            return None;
        }
        Some(crate::geometry::tspan::insert_tspans_at(
            element_tspans, self.insertion, payload,
        ))
    }

    /// Build a new Document with the session's current content applied to
    /// the element at `self.path`. Returns None if the path no longer points
    /// at a compatible element.
    ///
    /// Tspan-aware commit: the session's flat content is reconciled
    /// against the element's current tspan structure via
    /// `reconcile_content`. Unchanged prefix and suffix regions keep
    /// their original tspan assignments (and all per-range overrides);
    /// the changed middle is absorbed into the first overlapping
    /// tspan, with adjacent-equal tspans collapsed by the merge pass.
    ///
    /// Worst-case behaviour (all content replaced): the first tspan
    /// absorbs everything and everything else drops.
    pub fn apply_to_document(&self, doc: &Document) -> Option<Document> {
        use crate::geometry::tspan::reconcile_content;
        let elem = doc.get_element(&self.path)?;
        let new_elem = match (self.target, elem) {
            (EditTarget::Text, Element::Text(t)) => {
                let reconciled = reconcile_content(&t.tspans, &self.content);
                let mut new_t = t.clone();
                new_t.tspans = self.apply_pending_to(reconciled, Some(elem));
                Element::Text(new_t)
            }
            (EditTarget::TextPath, Element::TextPath(tp)) => {
                let reconciled = reconcile_content(&tp.tspans, &self.content);
                let mut new_tp = tp.clone();
                new_tp.tspans = self.apply_pending_to(reconciled, Some(elem));
                Element::TextPath(new_tp)
            }
            _ => return None,
        };
        Some(doc.replace_element(&self.path, new_elem))
    }

    /// Apply the pending next-typed-character override to the range
    /// `[pending_char_start, insertion)` of `tspans`, then merge.
    /// Passthrough when pending is not set or the range is empty.
    fn apply_pending_to(
        &self,
        tspans: Vec<crate::geometry::tspan::Tspan>,
        elem: Option<&crate::geometry::element::Element>,
    ) -> Vec<crate::geometry::tspan::Tspan> {
        use crate::geometry::tspan::{merge, merge_tspan_overrides, split_range};
        match (&self.pending_override, self.pending_char_start) {
            (Some(pending), Some(start)) if start < self.insertion => {
                let (mut split, first, last) =
                    split_range(&tspans, start, self.insertion);
                if let (Some(f), Some(l)) = (first, last) {
                    for i in f..=l {
                        merge_tspan_overrides(&mut split[i], pending);
                        // Identity-omission: drop fields that match the
                        // parent's effective value. See TSPAN.md step 3.
                        if let Some(e) = elem {
                            crate::workspace::app_state::identity_omit_tspan(
                                &mut split[i], e);
                        }
                    }
                    merge(&split)
                } else {
                    split
                }
            }
            _ => tspans,
        }
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

    // ── apply_to_document tspan preservation ────────────────────

    /// Build a Document with a single Text element whose tspans have
    /// been replaced with the given list. Content is derived from the
    /// concatenation at rendering time — TextElem.content is a method.
    fn doc_with_tspans(tspans: Vec<crate::geometry::tspan::Tspan>) -> Document {
        let mut t = empty_text_elem(0.0, 0.0, 0.0, 0.0);
        t.tspans = tspans;
        let mut doc = Document::default();
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Text(t)));
        doc
    }

    #[test]
    fn apply_preserves_tspans_when_content_matches() {
        use crate::geometry::tspan::Tspan;
        let original_tspans = vec![
            Tspan { content: "Hello ".into(), ..Tspan::default_tspan() },
            Tspan { id: 1, content: "world".into(),
                    font_weight: Some("bold".into()),
                    ..Tspan::default_tspan() },
        ];
        let doc = doc_with_tspans(original_tspans);
        let s = TextEditSession::new(vec![0, 0], EditTarget::Text,
                                     "Hello world".into(), 0, 0.0);
        let new_doc = s.apply_to_document(&doc).expect("apply");
        let Element::Text(t) = new_doc.get_element(&vec![0, 0]).unwrap()
            else { panic!("expected Text"); };
        assert_eq!(t.tspans.len(), 2);
        assert_eq!(t.tspans[0].content, "Hello ");
        assert_eq!(t.tspans[1].content, "world");
        assert_eq!(t.tspans[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn apply_reconciles_content_edit_across_tspan_boundary() {
        use crate::geometry::tspan::Tspan;
        let original_tspans = vec![
            Tspan { content: "Hello ".into(), ..Tspan::default_tspan() },
            Tspan { id: 1, content: "world".into(),
                    font_weight: Some("bold".into()),
                    ..Tspan::default_tspan() },
        ];
        let doc = doc_with_tspans(original_tspans);
        // Replace "world" with "changed" — the bold tspan absorbs
        // the change and keeps its override.
        let s = TextEditSession::new(vec![0, 0], EditTarget::Text,
                                     "Hello changed".into(), 0, 0.0);
        let new_doc = s.apply_to_document(&doc).expect("apply");
        let Element::Text(t) = new_doc.get_element(&vec![0, 0]).unwrap()
            else { panic!("expected Text"); };
        assert_eq!(t.tspans.len(), 2);
        assert_eq!(t.tspans[0].content, "Hello ");
        assert_eq!(t.tspans[1].content, "changed");
        assert_eq!(t.tspans[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn apply_preserves_bold_when_typing_in_plain_prefix() {
        use crate::geometry::tspan::Tspan;
        let original_tspans = vec![
            Tspan { content: "Hello ".into(), ..Tspan::default_tspan() },
            Tspan { id: 1, content: "world".into(),
                    font_weight: Some("bold".into()),
                    ..Tspan::default_tspan() },
        ];
        let doc = doc_with_tspans(original_tspans);
        // Insert "there " inside the plain prefix. Bold "world"
        // survives untouched.
        let s = TextEditSession::new(vec![0, 0], EditTarget::Text,
                                     "Hello there world".into(), 0, 0.0);
        let new_doc = s.apply_to_document(&doc).expect("apply");
        let Element::Text(t) = new_doc.get_element(&vec![0, 0]).unwrap()
            else { panic!("expected Text"); };
        assert_eq!(t.tspans.len(), 2);
        assert_eq!(t.tspans[0].content, "Hello there ");
        assert!(t.tspans[0].font_weight.is_none());
        assert_eq!(t.tspans[1].content, "world");
        assert_eq!(t.tspans[1].font_weight.as_deref(), Some("bold"));
    }

    // ── session-scoped tspan clipboard ──────────────────────────

    #[test]
    fn copy_selection_with_tspans_captures_and_returns_flat() {
        use crate::geometry::tspan::Tspan;
        let tspans = vec![
            Tspan { content: "foo".into(), ..Tspan::default_tspan() },
            Tspan { id: 1, content: "bar".into(),
                    font_weight: Some("bold".into()),
                    ..Tspan::default_tspan() },
        ];
        let mut s = TextEditSession::new(vec![0, 0], EditTarget::Text,
                                         "foobar".into(), 0, 0.0);
        s.set_insertion(1, false);
        s.set_insertion(5, true); // select "ooba"
        let flat = s.copy_selection_with_tspans(&tspans).expect("copy");
        assert_eq!(flat, "ooba");
        let (saved_flat, saved) = s.tspan_clipboard.as_ref().expect("clipboard");
        assert_eq!(saved_flat, "ooba");
        assert_eq!(saved.len(), 2);
        assert_eq!(saved[0].content, "oo");
        assert!(saved[0].font_weight.is_none());
        assert_eq!(saved[1].content, "ba");
        assert_eq!(saved[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn try_paste_tspans_matches_clipboard_and_splices() {
        use crate::geometry::tspan::Tspan;
        let tspans = vec![Tspan {
            content: "foo".into(),
            ..Tspan::default_tspan()
        }];
        let mut s = TextEditSession::new(vec![0, 0], EditTarget::Text,
                                         "foo".into(), 0, 0.0);
        // Seed the clipboard with a bold "X".
        s.tspan_clipboard = Some((
            "X".to_string(),
            vec![Tspan {
                content: "X".into(),
                font_weight: Some("bold".into()),
                ..Tspan::default_tspan()
            }],
        ));
        s.set_insertion(1, false);
        let result = s.try_paste_tspans(&tspans, "X").expect("paste");
        // Expect: plain "f" | bold "X" | plain "oo"
        assert_eq!(result.len(), 3);
        assert_eq!(result[0].content, "f");
        assert!(result[0].font_weight.is_none());
        assert_eq!(result[1].content, "X");
        assert_eq!(result[1].font_weight.as_deref(), Some("bold"));
        assert_eq!(result[2].content, "oo");
    }

    #[test]
    fn try_paste_tspans_returns_none_when_text_doesnt_match() {
        use crate::geometry::tspan::Tspan;
        let tspans = vec![Tspan {
            content: "foo".into(),
            ..Tspan::default_tspan()
        }];
        let mut s = TextEditSession::new(vec![0, 0], EditTarget::Text,
                                         "foo".into(), 0, 0.0);
        s.tspan_clipboard = Some(("X".to_string(), vec![]));
        assert!(s.try_paste_tspans(&tspans, "DIFFERENT").is_none());
    }

    // ── caret affinity ─────────────────────────────────────────

    #[test]
    fn new_session_caret_has_left_affinity() {
        use crate::geometry::tspan::Affinity;
        let s = session("abc");
        assert_eq!(s.caret_affinity, Affinity::Left);
    }

    #[test]
    fn insertion_tspan_pos_left_default_at_boundary() {
        use crate::geometry::tspan::{Affinity, Tspan};
        let tspans = vec![
            Tspan { content: "foo".into(), ..Tspan::default_tspan() },
            Tspan { id: 1, content: "bar".into(),
                    font_weight: Some("bold".into()),
                    ..Tspan::default_tspan() },
        ];
        let mut s = session("foobar");
        s.set_insertion(3, false);
        // Default Left affinity → end of tspan 0.
        assert_eq!(s.caret_affinity, Affinity::Left);
        assert_eq!(s.insertion_tspan_pos(&tspans), (0, 3));
    }

    #[test]
    fn set_insertion_with_affinity_right_crosses_boundary() {
        use crate::geometry::tspan::{Affinity, Tspan};
        let tspans = vec![
            Tspan { content: "foo".into(), ..Tspan::default_tspan() },
            Tspan { id: 1, content: "bar".into(),
                    font_weight: Some("bold".into()),
                    ..Tspan::default_tspan() },
        ];
        let mut s = session("foobar");
        s.set_insertion_with_affinity(3, Affinity::Right, false);
        assert_eq!(s.caret_affinity, Affinity::Right);
        assert_eq!(s.insertion_tspan_pos(&tspans), (1, 0));
    }

    #[test]
    fn anchor_tspan_pos_uses_caret_affinity() {
        use crate::geometry::tspan::{Affinity, Tspan};
        let tspans = vec![
            Tspan { content: "foo".into(), ..Tspan::default_tspan() },
            Tspan { id: 1, content: "bar".into(), ..Tspan::default_tspan() },
        ];
        let mut s = session("foobar");
        s.set_insertion(3, false);
        s.set_insertion_with_affinity(5, Affinity::Right, true); // selection [3, 5)
        // Anchor resolves with Right affinity too.
        assert_eq!(s.anchor_tspan_pos(&tspans), (1, 0));
        assert_eq!(s.insertion_tspan_pos(&tspans), (1, 2));
    }

    // ── next-typed-character state ─────────────────────────────

    /// A pending-override template carrying only `font_weight = Some("bold")`.
    fn bold_pending() -> crate::geometry::tspan::Tspan {
        use crate::geometry::tspan::Tspan;
        Tspan {
            font_weight: Some("bold".into()),
            ..Tspan::default_tspan()
        }
    }

    #[test]
    fn set_pending_override_captures_anchor_at_insertion() {
        let mut s = session("hello");
        s.set_insertion(3, false);
        s.set_pending_override(&bold_pending());
        assert!(s.has_pending_override());
        assert_eq!(s.pending_char_start, Some(3));
    }

    #[test]
    fn set_pending_override_merges_across_calls() {
        use crate::geometry::tspan::Tspan;
        let mut s = session("hello");
        s.set_pending_override(&bold_pending());
        let italic = Tspan {
            font_style: Some("italic".into()),
            ..Tspan::default_tspan()
        };
        s.set_pending_override(&italic);
        let p = s.pending_override.as_ref().expect("pending");
        assert_eq!(p.font_weight.as_deref(), Some("bold"));
        assert_eq!(p.font_style.as_deref(), Some("italic"));
        // Anchor is not moved by the second call.
        assert_eq!(s.pending_char_start, Some(0));
    }

    #[test]
    fn set_insertion_to_different_position_clears_pending() {
        let mut s = session("hello");
        s.set_insertion(3, false);
        s.set_pending_override(&bold_pending());
        s.set_insertion(2, false);
        assert!(!s.has_pending_override());
    }

    #[test]
    fn set_insertion_same_position_preserves_pending() {
        let mut s = session("hello");
        s.set_insertion(3, false);
        s.set_pending_override(&bold_pending());
        s.set_insertion(3, false);
        assert!(s.has_pending_override());
    }

    #[test]
    fn set_insertion_extend_preserves_pending() {
        let mut s = session("hello");
        s.set_insertion(3, false);
        s.set_pending_override(&bold_pending());
        s.set_insertion(4, true);
        assert!(s.has_pending_override());
    }

    #[test]
    fn undo_clears_pending() {
        let mut s = session("hello");
        s.insert("X");
        s.set_pending_override(&bold_pending());
        s.undo();
        assert!(!s.has_pending_override());
    }

    #[test]
    fn apply_to_document_writes_override_to_typed_range() {
        use crate::geometry::tspan::Tspan;
        // Start with "hello" as a single plain tspan.
        let original_tspans = vec![Tspan {
            content: "hello".into(),
            ..Tspan::default_tspan()
        }];
        let mut t = empty_text_elem(0.0, 0.0, 0.0, 0.0);
        t.tspans = original_tspans;
        let mut doc = Document::default();
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Text(t)));
        // User places caret at end, primes Bold, types "X".
        let mut s = TextEditSession::new(vec![0, 0], EditTarget::Text,
                                         "hello".into(), 5, 0.0);
        s.set_pending_override(&bold_pending());
        s.insert("X");  // content: "helloX", insertion: 6
        let new_doc = s.apply_to_document(&doc).expect("apply");
        let Element::Text(t) = new_doc.get_element(&vec![0, 0]).unwrap()
            else { panic!("expected Text"); };
        assert_eq!(t.tspans.len(), 2);
        assert_eq!(t.tspans[0].content, "hello");
        assert!(t.tspans[0].font_weight.is_none());
        assert_eq!(t.tspans[1].content, "X");
        assert_eq!(t.tspans[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn apply_with_no_pending_is_passthrough() {
        // Existing apply behavior unchanged when nothing is pending.
        use crate::geometry::tspan::Tspan;
        let original = vec![Tspan {
            content: "hello".into(),
            ..Tspan::default_tspan()
        }];
        let mut t = empty_text_elem(0.0, 0.0, 0.0, 0.0);
        t.tspans = original;
        let mut doc = Document::default();
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Text(t)));
        let mut s = TextEditSession::new(vec![0, 0], EditTarget::Text,
                                         "hello".into(), 5, 0.0);
        s.insert("X");
        let new_doc = s.apply_to_document(&doc).expect("apply");
        let Element::Text(t) = new_doc.get_element(&vec![0, 0]).unwrap()
            else { panic!("expected Text"); };
        assert_eq!(t.tspans.len(), 1);
        assert_eq!(t.tspans[0].content, "helloX");
        assert!(t.tspans[0].font_weight.is_none());
    }

    #[test]
    fn pending_applies_to_multi_char_run() {
        // User primes Bold, types "abc" in one run — all three bold.
        use crate::geometry::tspan::Tspan;
        let original = vec![Tspan {
            content: "hi".into(),
            ..Tspan::default_tspan()
        }];
        let mut t = empty_text_elem(0.0, 0.0, 0.0, 0.0);
        t.tspans = original;
        let mut doc = Document::default();
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Text(t)));
        let mut s = TextEditSession::new(vec![0, 0], EditTarget::Text,
                                         "hi".into(), 2, 0.0);
        s.set_pending_override(&bold_pending());
        s.insert("a");
        s.insert("b");
        s.insert("c");
        let new_doc = s.apply_to_document(&doc).expect("apply");
        let Element::Text(t) = new_doc.get_element(&vec![0, 0]).unwrap()
            else { panic!("expected Text"); };
        // Expect "hi" + "abc"(bold).
        assert_eq!(t.tspans.len(), 2);
        assert_eq!(t.tspans[0].content, "hi");
        assert_eq!(t.tspans[1].content, "abc");
        assert_eq!(t.tspans[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn merge_tspan_overrides_copies_only_some_fields() {
        use crate::geometry::tspan::{merge_tspan_overrides, Tspan};
        let mut target = Tspan {
            content: "hi".into(),
            font_weight: Some("normal".into()),  // should be overwritten
            font_style: Some("italic".into()),   // should survive
            ..Tspan::default_tspan()
        };
        let source = Tspan {
            font_weight: Some("bold".into()),
            // font_style is None → don't touch target's
            ..Tspan::default_tspan()
        };
        merge_tspan_overrides(&mut target, &source);
        assert_eq!(target.content, "hi");  // content untouched
        assert_eq!(target.font_weight.as_deref(), Some("bold"));
        assert_eq!(target.font_style.as_deref(), Some("italic"));
    }
}
