//! The `extern "C"` boundary between the Rust core and a native shell.
//!
//! S-A (2026-07-29). The boundary laws BL1-BL6 this surface obeys are stated
//! in this file: BL2/BL3/BL4 in the safety contract below, BL5 in the paragraph
//! above, BL1 and BL6 at the functions that turn on them.
//!
//! Behind `feature = "ffi"`, so the default web build and the wasm target never
//! see it. Every type here is repr(C) and every string that crosses is a UTF-8
//! byte span — never a NUL-terminated `char*`, because the default P/Invoke
//! `CharSet` is `Ansi` (cp1252 on this box) and that is this seat's day-one
//! defect class wearing an ABI costume (BL5).
//!
//! # Safety contract for every function here
//!
//! * Pointers must be either NULL or valid for `len` bytes.
//! * **BL2**: all calls for a given engine must occur on the thread that created
//!   it. The core is `Rc`-based and therefore not `Send`; this is the same
//!   constraint the single-threaded wasm build already lives under. It cannot be
//!   enforced across a C ABI, so it is documented and asserted in debug builds.
//! * **BL4**: every `JasBytes` returned is Rust-owned. Copy it, then `jas_free`.
//! * **BL3**: no function pointer is ever passed in. One direction per call.

use std::cell::RefCell;

// S-C boundary instrumentation. Every extern below records its own crossing;
// the counter is the receipt for the chatter measurement, and a static count of
// call sites would pass on a shell that never ran.
use crate::ffi_instr::{self, Crossing};

use crate::document::model::Model;
use crate::document::op_apply::{op_apply, OpError};
use crate::panel_scope::{EditOutcome, PanelRegistry, PanelState};

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// An owned UTF-8 byte span handed to the caller. **Rust owns it** (BL4):
/// copy immediately, then release with [`jas_free`].
///
/// `ptr == NULL && len == 0` is the canonical empty result and is safe to free.
#[repr(C)]
pub struct JasBytes {
    pub ptr: *const u8,
    pub len: usize,
}

impl JasBytes {
    fn empty() -> Self {
        JasBytes { ptr: std::ptr::null(), len: 0 }
    }

    /// Leak a `String` into a caller-owned span. The capacity is dropped to the
    /// length first so `jas_free` can reconstitute the exact allocation.
    fn from_string(s: String) -> Self {
        let mut boxed = s.into_bytes().into_boxed_slice();
        let ptr = boxed.as_mut_ptr();
        let len = boxed.len();
        std::mem::forget(boxed);
        if len == 0 {
            // A zero-length boxed slice has a dangling (non-null) pointer that
            // must not reach the caller as if it were real memory.
            return JasBytes::empty();
        }
        JasBytes { ptr, len }
    }
}

/// Status codes. **1-5 map one-to-one and BY POSITION onto the five frozen
/// `OpError` classes** (`document/op_apply.rs`, ratified OP_LOG.md §13). Codes
/// >= 100 are TRANSPORT faults that cannot arise from `op_apply`, kept in a
/// disjoint range so this ABI can never be mistaken for having widened a
/// ratified taxonomy: anything 1-5 is a core verdict, anything >= 100 never
/// reached the core.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JasStatus {
    Ok = 0,
    MalformedEnvelope = 1,
    UnknownVerb = 2,
    MissingParam = 3,
    BadParamType = 4,
    MissingTarget = 5,
    BadUtf8 = 100,
    BadJson = 101,
    NullHandle = 102,
}

impl JasStatus {
    fn of(err: &OpError) -> Self {
        match err {
            OpError::MalformedEnvelope => JasStatus::MalformedEnvelope,
            OpError::UnknownVerb { .. } => JasStatus::UnknownVerb,
            OpError::MissingParam { .. } => JasStatus::MissingParam,
            OpError::BadParamType { .. } => JasStatus::BadParamType,
            OpError::MissingTarget { .. } => JasStatus::MissingTarget,
        }
    }
}

/// The bare class name, spelled EXACTLY as the negative fixtures spell it in
/// their per-op `expected_error` fields, so a shell-side assertion and a corpus
/// fixture compare the same string.
fn error_class_name(err: &OpError) -> &'static str {
    match err {
        OpError::MalformedEnvelope => "MalformedEnvelope",
        OpError::UnknownVerb { .. } => "UnknownVerb",
        OpError::MissingParam { .. } => "MissingParam",
        OpError::BadParamType { .. } => "BadParamType",
        OpError::MissingTarget { .. } => "MissingTarget",
    }
}

fn error_detail_json(err: &OpError) -> String {
    let class = error_class_name(err);
    match err {
        OpError::MalformedEnvelope => format!(r#"{{"class":"{class}"}}"#),
        OpError::UnknownVerb { name } => {
            format!(r#"{{"class":"{class}","name":{}}}"#, json_str(name))
        }
        OpError::MissingParam { name } | OpError::BadParamType { name } => {
            format!(r#"{{"class":"{class}","name":{}}}"#, json_str(name))
        }
        OpError::MissingTarget { id } => {
            format!(r#"{{"class":"{class}","id":{}}}"#, json_str(id))
        }
    }
}

fn json_str(s: &str) -> String {
    serde_json::Value::String(s.to_string()).to_string()
}

/// One document session. Deliberately NOT `Send`/`Sync`: `RefCell` and the
/// `Rc`-based model make single-thread use a type-level fact on the Rust side
/// even though the C ABI cannot carry it (BL2).
pub struct JasEngine {
    model: RefCell<Model>,
    last_error: RefCell<Option<String>>,
    /// The panel state a materialized panel binds to (S-C.1).
    ///
    /// `Model` holds the DOCUMENT — and its own comment says the panel `state`
    /// namespace is "not in AppState"'s absence here deliberate. The colour
    /// panel binds 87 times into `state.*` and ~45 into `panel.*`, none of which
    /// `Model` carries, so wiring `bind_values` against the model alone would
    /// resolve every one of those to null and materialize 71 controls holding
    /// document-derived values but not the colour — on a COLOUR panel, where the
    /// state IS the content. That is a subtler empty shell than an unrendered
    /// one and would measure just as vacuously.
    ///
    /// The type and the scope it assembles MOVED to `crate::panel_scope` at
    /// S-C.2, so the write path that moves it can be tested without an ABI in
    /// the way. This file is a boundary file.
    panel: RefCell<PanelState>,
    /// Which panels the shell has materialized, and the rows each was last
    /// served — the state a DELTA needs. Enrolled by [`jas_bind_values`]:
    /// reading a panel's values is what tells the engine it is open.
    registry: RefCell<PanelRegistry>,
    /// ⭐ ROW DU: physical pixels per DIP, as the shell's display reports it.
    ///
    /// ⛔ IT LIVES HERE, NOT IN THE SHELL. The shell sends the physical pixels
    /// its swapchain is sized in, and the DIP -> document conversion happens
    /// on this side. Letting C# divide would put a display-scale bug -- the
    /// single most common Windows-app defect there is -- on the far side of the
    /// boundary, which is what BL1 exists to prevent.
    dpi_scale: std::cell::Cell<f64>,
    /// The tool the pointer drives, by index into `ffi_pointer::TOOL_IDS`.
    /// Built lazily: a `YamlTool` costs a workspace lookup and a state-store
    /// init, and most engines never take a pointer at all.
    tool: RefCell<Option<(usize, Box<dyn crate::tools::tool::CanvasTool>)>>,
}

impl JasEngine {
    /// Run `f` against the session's live document.
    ///
    /// ⛔ A CLOSURE, NOT A `&Document` RETURN, and `RefCell` is why: the borrow
    /// guard would be dropped at the end of the accessor, so a returned
    /// reference could not outlive it. Handing the borrow to a callback keeps
    /// the guard alive for exactly the call and cannot be misused.
    ///
    /// `pub(crate)` deliberately: this is not ABI. It exists so the paint seam
    /// (`ffi_paint::jas_paint_document`) can walk the document IN PLACE rather
    /// than through `jas_document_json` -- which would serialise the whole
    /// document to test JSON and parse it back on every frame, and would need a
    /// whole-document PARSER that does not exist (see the note above
    /// `jas_document_json`).
    pub(crate) fn with_document<R>(&self, f: impl FnOnce(&crate::document::document::Document) -> R) -> R {
        f(self.model.borrow().document())
    }

    /// Open `doc` as the session's document — a NEW model, not a mutation.
    ///
    /// ⛔ `Model::new`, NOT `set_document`, AND THE DIFFERENCE IS THE UNDO
    /// JOURNAL. `set_document` asserts it is inside a transaction (Arc 1 S1c),
    /// and `set_document_unbracketed` takes a `NonUndoableIntent` whose every
    /// variant is NARROW and validated — `Selection`, `PreviewReapply`,
    /// `LiveDrag`, `ActiveLayer`, `TestOnly`. None of them describes "the user
    /// opened a different file", and widening one to admit it is how a stated
    /// invariant stops meaning anything.
    ///
    /// Opening a file is not an edit to the current document; it REPLACES the
    /// session. `Model::new` is what every other construction path uses, and it
    /// drops the undo stack — which is correct: undoing across an open would
    /// restore artwork from a file the user is no longer editing.
    ///
    /// `pub(crate)`, not ABI — the boundary is `ffi_paint::jas_load_svg`.
    /// Run `f` against the session's live model, mutably. Same closure shape
    /// and same reason as [`Self::with_document`]: the `RefCell` guard must
    /// outlive the call, so it cannot be handed back.
    /// Read-only twin of [`Self::with_model_mut`]. The overlay walk needs the
    /// MODEL (view transform, tool-visible state), not just the document.
    pub(crate) fn with_model<R>(&self, f: impl FnOnce(&Model) -> R) -> R {
        f(&self.model.borrow())
    }

    pub(crate) fn with_model_mut<R>(&self, f: impl FnOnce(&mut Model) -> R) -> R {
        f(&mut self.model.borrow_mut())
    }

    pub(crate) fn dpi_scale(&self) -> f64 { self.dpi_scale.get() }
    pub(crate) fn set_dpi_scale(&self, s: f64) { self.dpi_scale.set(s); }
    pub(crate) fn tool_slot(
        &self,
    ) -> std::cell::RefMut<'_, Option<(usize, Box<dyn crate::tools::tool::CanvasTool>)>> {
        self.tool.borrow_mut()
    }

    pub(crate) fn replace_document(&self, doc: crate::document::document::Document) {
        *self.model.borrow_mut() = Model::new(doc, None);
    }

    fn new() -> Self {
        JasEngine {
            model: RefCell::new(Model::default()),
            last_error: RefCell::new(None),
            panel: RefCell::new(PanelState::default()),
            registry: RefCell::new(PanelRegistry::default()),
            dpi_scale: std::cell::Cell::new(1.0),
            tool: RefCell::new(None),
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// # Safety
/// `ptr` must be NULL or valid for `len` bytes.
unsafe fn span(ptr: *const u8, len: usize) -> Option<&'static [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

unsafe fn utf8(ptr: *const u8, len: usize) -> Result<&'static str, JasStatus> {
    let bytes = unsafe { span(ptr, len) }.ok_or(JasStatus::BadUtf8)?;
    std::str::from_utf8(bytes).map_err(|_| JasStatus::BadUtf8)
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Create one document session. Returns NULL only on allocation failure.
///
/// **BL2**: every subsequent call for this engine must be on this thread.
#[unsafe(no_mangle)]
pub extern "C" fn jas_engine_new() -> *mut JasEngine {
    ffi_instr::record(Crossing::EngineNew, 0, 0);
    Box::into_raw(Box::new(JasEngine::new()))
}

/// Destroy an engine. Idempotent on NULL.
///
/// # Safety
/// `e` must be a pointer from [`jas_engine_new`] that has not already been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_engine_free(e: *mut JasEngine) {
    ffi_instr::record(Crossing::EngineFree, 0, 0);
    if !e.is_null() {
        drop(unsafe { Box::from_raw(e) });
    }
}

/// Release a span returned by this ABI (BL4). Safe on the empty `JasBytes`.
///
/// # Safety
/// `b` must be a value returned by this ABI and not already freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_free(b: JasBytes) {
    // bytes_in is 0 DELIBERATELY: this span's bytes were already counted as
    // bytes_out when they crossed outward. Counting them again on release would
    // double every payload and inflate the chatter figure by exactly 2x.
    ffi_instr::record(Crossing::Free, 0, 0);
    if b.ptr.is_null() || b.len == 0 {
        return;
    }
    drop(unsafe {
        Box::from_raw(std::slice::from_raw_parts_mut(b.ptr as *mut u8, b.len))
    });
}

/// Build identity, for the shell to log and for the harness to prove it is
/// talking to the library it thinks it is.
#[unsafe(no_mangle)]
pub extern "C" fn jas_version() -> JasBytes {
    let out = JasBytes::from_string(format!(
        r#"{{"crate":"jas_dioxus","version":"{}","abi":1}}"#,
        env!("CARGO_PKG_VERSION")
    ));
    ffi_instr::record(Crossing::Version, 0, out.len);
    out
}

// ---------------------------------------------------------------------------
// Document
// ---------------------------------------------------------------------------

// `jas_load_document` is NOT in S-A. It was in the design sketch, but
// `geometry::test_json` has no whole-document PARSER -- only the writer -- so
// implementing it would mean inventing one, which is not what a boundary spike
// is for. No S-A gate needs it: gate (iii) starts from an empty model and
// builds through ops, which is the BL1 path anyway.

/// The session's document as canonical test JSON — the SAME bytes the
/// cross-language corpus compares (BL6: a summary, not geometry).
///
/// # Safety
/// `e` must be a live engine pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_document_json(e: *mut JasEngine) -> JasBytes {
    ffi_instr::record(Crossing::DocumentJson, 0, 0);
    let Some(engine) = (unsafe { e.as_ref() }) else {
        return JasBytes::empty();
    };
    let model = engine.model.borrow();
    let out = JasBytes::from_string(crate::geometry::test_json::document_to_test_json(
        model.document(),
    ));
    ffi_instr::record_out(Crossing::DocumentJson, out.len);
    out
}

/// The session's document as SVG — the artefact a person SAVES.
///
/// ⛔ NOT [`jas_document_json`], AND THE DIFFERENCE IS THE WHOLE POINT. That one
/// is canonical test JSON, *"a summary, not geometry"* (BL6): it is the corpus's
/// comparison surface and it is lossy about the drawing. This is
/// `geometry::svg::document_to_svg`, the same writer every port saves through,
/// so a document saved on Windows and one saved on the web are the same bytes.
///
/// **BL4**: the span is Rust-owned. Copy it, then release with [`jas_free`].
///
/// # Safety
/// `e` must be NULL or a live engine pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_document_svg(e: *mut JasEngine) -> JasBytes {
    ffi_instr::record(Crossing::DocumentSvg, 0, 0);
    let Some(engine) = (unsafe { e.as_ref() }) else {
        return JasBytes::empty();
    };
    let out = JasBytes::from_string(
        engine.with_document(crate::geometry::svg::document_to_svg),
    );
    ffi_instr::record_out(Crossing::DocumentSvg, out.len);
    out
}

/// The menubar's STATIC shape — labels, shortcuts, separators, submenu titles.
///
/// ⭐ THE OTHER HALF OF [`jas_menu_state`], AND THE REASON A SHELL NEEDS BOTH.
/// That pass answers *"which entries are enabled right now"* and deliberately
/// emits neither labels nor separators nor submenu nodes. Every port that draws
/// a menubar today gets the static half by projecting the compiled bundle
/// in-process, because every one of them is an interpreter. **The WinUI shell is
/// the first consumer that is not**, and §1's materializer law forbids it
/// authoring the menubar itself — so without this export it could build 55
/// correctly-enabled items with no text on them.
///
/// A consumer reads this ONCE and joins it to [`jas_menu_state`] on `path` at
/// each menu open. The join law — every state row's path is an `item` here — is
/// pinned by a test rather than by this comment.
///
/// ⛔ TAKES NO ENGINE, DELIBERATELY. The menubar is a property of the compiled
/// bundle, not of a document session, and this pass evaluates nothing. A `*mut
/// JasEngine` it ignored would be a dead arm wearing a driven arm's signature —
/// every caller would pass a handle believing it mattered.
///
/// **BL4**: the span is Rust-owned. Copy it, then release with [`jas_free`].
#[unsafe(no_mangle)]
pub extern "C" fn jas_menu_structure() -> JasBytes {
    ffi_instr::record(Crossing::MenuStructure, 0, 0);
    let Some(ws) = crate::interpreter::workspace::Workspace::load() else {
        return JasBytes::empty();
    };
    let menubar = ws.data()["menubar"].clone();
    if !menubar.is_array() {
        return JasBytes::empty();
    }
    let rows = crate::interpreter::menu_state::menu_structure(&menubar);
    let out = JasBytes::from_string(serde_json::to_string(&rows).unwrap_or_default());
    ffi_instr::record_out(Crossing::MenuStructure, out.len);
    out
}

/// The five `active_document.*` facts the ENGINE owns, as a JSON object.
///
/// ⛔ THE LIST IS EXHAUSTIVE ON PURPOSE AND IT IS SHORTER THAN THE NAMESPACE.
/// `menu_state.rs:19-25` names six `active_document` fields; the engine can
/// answer five. `has_filename` is NOT here because `jas_load_svg` takes BYTES —
/// the engine has never seen a path and inventing `false` for it would be the
/// shell's answer wearing the engine's authority.
fn engine_document_facts(engine: &JasEngine) -> serde_json::Map<String, serde_json::Value> {
    let model = engine.model.borrow();
    let selection_count = model.document().selection.len();
    let mut m = serde_json::Map::new();
    m.insert("has_selection".into(), (selection_count > 0).into());
    m.insert("selection_count".into(), selection_count.into());
    m.insert("can_undo".into(), model.can_undo().into());
    m.insert("can_redo".into(), model.can_redo().into());
    m.insert("is_modified".into(), model.is_modified().into());
    m
}

/// The menubar's evaluated `enabled` / `checked` state — the tenth materializer
/// function, and the one that keeps a shell from authoring a second menubar.
///
/// Returns the canonical `menu_state` array: a flat pre-order
/// `{path, action, enabled, checked}` per action item, the SAME pass the
/// cross-app byte-gate pins (`test_fixtures/algorithms/menu_state.json`).
///
/// # ⚠️ THE CTX IS A **MERGE**, AND IT IS NOT [`jas_widget_tree`]'S CONVENTION
///
/// A panel's scope is wholly the engine's, so `jas_widget_tree` can take NULL
/// and assemble it. **A menubar's is not.** Its predicates read six namespaces
/// (`menu_state.rs:19-25`) and this engine holds one document, no path, no tabs
/// and no panel visibility. So:
///
/// * the **engine** supplies `active_document.{has_selection, selection_count,
///   can_undo, can_redo, is_modified}` and **WINS** on them — a shell that could
///   assert `can_undo` would be holding document state, which is **BL1**;
/// * the **shell** supplies everything else (`state.tab_count`,
///   `active_document.has_filename`, `workspace.has_saved_layout`, `panels.*`,
///   `panes.*`) — tabs, filenames and chrome visibility are session facts and
///   have never been the engine's.
///
/// A NULL or empty ctx is therefore **not** "empty scope": it is "the shell
/// supplies nothing", and every session predicate falls to the evaluator's own
/// falsy default. That is correct for a menu opened before a document exists.
///
/// **BL4**: copy the span, then release with [`jas_free`].
///
/// # Safety
/// `e` must be NULL or live; `ctx_json` must be NULL or valid for `ctx_len`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_menu_state(
    e: *mut JasEngine,
    ctx_json: *const u8,
    ctx_len: usize,
) -> JasBytes {
    ffi_instr::record(Crossing::MenuState, ctx_len, 0);
    let Some(engine) = (unsafe { e.as_ref() }) else {
        return JasBytes::empty();
    };
    // The shell's half. A ctx that does not parse is refused as an EMPTY span
    // rather than silently treated as `{}` — a shell whose marshalling broke
    // would otherwise see a plausible menu built from no session state at all.
    let mut ctx: serde_json::Map<String, serde_json::Value> = if ctx_len == 0 {
        serde_json::Map::new()
    } else {
        match unsafe { utf8(ctx_json, ctx_len) }
            .ok()
            .and_then(|t| serde_json::from_str::<serde_json::Value>(t).ok())
        {
            Some(serde_json::Value::Object(m)) => m,
            _ => return JasBytes::empty(),
        }
    };

    // The engine's half, applied LAST so it wins on every key it owns.
    let mut active = match ctx.remove("active_document") {
        Some(serde_json::Value::Object(m)) => m,
        _ => serde_json::Map::new(),
    };
    active.extend(engine_document_facts(engine));
    ctx.insert("active_document".into(), serde_json::Value::Object(active));

    let Some(ws) = crate::interpreter::workspace::Workspace::load() else {
        return JasBytes::empty();
    };
    let menubar = ws.data()["menubar"].clone();
    if !menubar.is_array() {
        return JasBytes::empty();
    }
    let rows = crate::interpreter::menu_state::menu_state(
        &menubar,
        &serde_json::Value::Object(ctx),
    );
    let out = JasBytes::from_string(serde_json::to_string(&rows).unwrap_or_default());
    ffi_instr::record_out(Crossing::MenuState, out.len);
    out
}

/// Assemble the panel data scope INSIDE the engine.
///
/// **BL1, and it is why the extern takes only a panel id.** Exposing the pure
/// `bind_values(panel_node, ctx)` would have forced the shell to build this map,
/// which puts app state in C# -- the third interpreter's state half arriving
/// through a parameter list rather than through a rewrite.
///
/// The assembly itself lives in `panel_scope`, which also owns the write that
/// moves it. This is the one-line adapter that pairs the panel slice with the
/// document, because only the engine holds both.
fn panel_ctx(engine: &JasEngine) -> serde_json::Value {
    engine.panel.borrow().scope(engine.model.borrow().document())
}

/// The panel's resolved bind VALUES — the ninth materializer function.
///
/// `jas_widget_tree` is **value-blind by design**: it records the sorted KEY
/// NAMES of `bind`/`style`, which is what makes it stable across ports. So a
/// shell built on the surface without this one materializes native controls with
/// nothing in them. This returns the third pass — `interpreter::bind_values` —
/// against a scope the ENGINE assembles.
///
/// **It also ENROLS the panel** (S-C.2): reading a panel's values is what tells
/// the engine the shell has it open, so subsequent ticks know to keep it in
/// sync. Enrolment is a side effect of a call the shell already had to make —
/// an explicit `jas_panel_open` would have spent a boundary function to say
/// something the engine can already see.
///
/// # Safety
/// `panel_id` must be NULL or valid for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_bind_values(
    e: *mut JasEngine,
    panel_id: *const u8,
    len: usize,
) -> JasBytes {
    ffi_instr::record(Crossing::BindValues, len, 0);
    let Some(engine) = (unsafe { e.as_ref() }) else {
        return JasBytes::empty();
    };
    let Ok(id) = (unsafe { utf8(panel_id, len) }) else {
        return JasBytes::empty();
    };
    let Some(ws) = crate::interpreter::workspace::Workspace::load() else {
        return JasBytes::empty();
    };
    let Some(spec) = ws.panel(id) else {
        return JasBytes::empty();
    };
    let ctx = panel_ctx(engine);
    let rows = crate::interpreter::bind_values::bind_values(spec, &ctx);
    engine.registry.borrow_mut().record(id, &rows);
    let out = JasBytes::from_string(serde_json::to_string(&rows).unwrap_or_default());
    ffi_instr::record_out(Crossing::BindValues, out.len);
    out
}

/// **The colour tick.** One control's new value in; every bind row that MOVED,
/// across every open panel, out.
///
/// # The protocol, and what it is for
///
/// This is the S-C.2 sync protocol, and the whole of C2 is measured on it. Its
/// shape is three decisions, each of which the gate can see the consequence of:
///
/// 1. **The reply carries the delta**, so a tick is ONE crossing plus its
///    `jas_free` — **two**, where a dispatch-then-fetch protocol is three (a
///    fetch is two crossings under Rust-owns-it, BL4). The gate's derived floor
///    assumed the two were separate calls; folding them is why this comes in
///    under it.
/// 2. **Only rows that CHANGED are sent.** The trivial alternative is to re-read
///    the panel whole, which is 7,038 bytes on the colour panel and is where
///    gate ③'s ceiling comes from.
/// 3. ⭐ **Every OPEN panel is re-resolved, not just the edited one.** Refreshing
///    only the edited panel is cheaper and is WRONG in general — a colour change
///    with a selection moves what other panels display. The cost of being right
///    lands on the ENGINE, not the boundary: crossings and bytes stay flat while
///    `engine.rows_evaluated` grows with the document. That number is in the
///    counter dump because gate ⑤ requires it and because nothing else would
///    show it.
///
/// # The event, and why it names a WIDGET
///
/// `{"widget":"cp_h","key":"bind.value","value":210}` — the shell reports what
/// the user did to a CONTROL. The engine reads that widget's `bind.value` out of
/// the panel spec (`"panel.h"`) and applies it. **So the shell knows nothing
/// about colour**: no channel names, no conversion, no mode. A shell that sent
/// `{"h":210}` would be naming the engine's model, and one that sent a hex
/// would be doing the arithmetic. `key` defaults to `bind.value`.
///
/// Returns the changed rows, each tagged with its `panel`. An empty array is a
/// well-formed answer meaning *nothing moved* — and is exactly what gate ④
/// exists to stop being read as a cheap tick, so [`jas_last_error_json`] carries
/// the outcome class when the array is empty.
///
/// # Safety
/// Both spans must be NULL or valid for their stated lengths.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_panel_event(
    e: *mut JasEngine,
    panel_id: *const u8,
    panel_len: usize,
    event_json: *const u8,
    event_len: usize,
) -> JasBytes {
    ffi_instr::record(Crossing::PanelEvent, panel_len + event_len, 0);
    let Some(engine) = (unsafe { e.as_ref() }) else {
        return JasBytes::empty();
    };
    let (Ok(id), Ok(raw)) = (
        unsafe { utf8(panel_id, panel_len) },
        unsafe { utf8(event_json, event_len) },
    ) else {
        set_panel_event_error(engine, "BadUtf8", "");
        return JasBytes::empty();
    };
    let Ok(ev) = serde_json::from_str::<serde_json::Value>(raw) else {
        set_panel_event_error(engine, "BadJson", "");
        return JasBytes::empty();
    };
    let Some(ws) = crate::interpreter::workspace::Workspace::load() else {
        return JasBytes::empty();
    };
    let Some(spec) = ws.panel(id) else {
        set_panel_event_error(engine, "MissingTarget", id);
        return JasBytes::empty();
    };

    let widget = ev.get("widget").and_then(|v| v.as_str()).unwrap_or("");
    let key = ev.get("key").and_then(|v| v.as_str()).unwrap_or("bind.value");
    let value = ev.get("value").cloned().unwrap_or(serde_json::Value::Null);

    // The engine resolves widget -> binding expression. The shell never sees it.
    let Some(target) = crate::panel_scope::binding_of(spec, widget, key) else {
        set_panel_event_error(engine, "MissingTarget", widget);
        return JasBytes::empty();
    };

    let outcome = engine.panel.borrow_mut().apply_edit(&target, &value);
    if outcome == EditOutcome::NoSuchTarget {
        set_panel_event_error(engine, "BadParamType", &target);
        return JasBytes::empty();
    }

    let scope = panel_ctx(engine);
    let sync = engine.registry.borrow_mut().sync(&ws, &scope);
    ffi_instr::record_engine(sync.rows_evaluated, sync.panels_evaluated);

    // An UNCHANGED tick reports itself. Gate ④'s vacuity guard needs the shell
    // to be able to tell "nothing moved" from "the protocol is cheap", and an
    // empty array alone cannot say which.
    if outcome == EditOutcome::Unchanged {
        set_panel_event_error(engine, "Unchanged", &target);
    } else {
        *engine.last_error.borrow_mut() = None;
    }

    let out = JasBytes::from_string(serde_json::to_string(&sync.changed).unwrap_or_default());
    ffi_instr::record_out(Crossing::PanelEvent, out.len);
    out
}

/// The panel-event channel's diagnostic, in the same shape
/// [`jas_last_error_json`] already serves.
///
/// ⚠️ These classes are **NOT** the five frozen `OpError` names, even where a
/// word coincides: nothing here reached `op_apply`. The field is `panel_event`
/// rather than `class` so a shell-side assertion can never compare one to the
/// other by accident — the disjoint-range discipline `JasStatus` uses for
/// transport faults, applied to a channel that returns bytes instead of a code.
fn set_panel_event_error(engine: &JasEngine, class: &str, detail: &str) {
    *engine.last_error.borrow_mut() = Some(format!(
        r#"{{"panel_event":{},"detail":{}}}"#,
        json_str(class),
        json_str(detail)
    ));
}

// ---------------------------------------------------------------------------
// S-C INSTRUMENTATION -- THE APPARATUS, NOT THE SURFACE
//
// These two are how the shell drives the chatter measurement: reset at the
// start of a named interaction, dump at the end. They live here because
// `JasBytes` does, and because every `extern "C"` in this crate should be in
// one file where it can be counted.
//
// ***THEY ARE NOT PART OF THE MATERIALIZER SURFACE.*** The surface S-C prices
// is the 8 functions a panel actually uses; these exist only to measure it, and
// `Crossing` deliberately has no variant for either, so they cannot appear in
// their own reading. Any count of "the surface" that includes them is wrong,
// and the distinction is exactly the population error this campaign has already
// paid for once.
// ---------------------------------------------------------------------------

/// Zero every boundary counter. Call at the START of a named interaction so the
/// dump that follows describes that interaction alone.
#[unsafe(no_mangle)]
pub extern "C" fn jas_instr_reset() {
    ffi_instr::reset();
}

/// The counter dump as JSON: per-function rows plus totals, naming the surface
/// it was measured against.
///
/// **BL4**: the span is Rust-owned. Copy it, then release with [`jas_free`].
/// Releasing it does call `jas_free`, which IS a counted crossing -- so dump
/// LAST in an interaction, or reset after freeing, or the free will appear in
/// the next reading.
#[unsafe(no_mangle)]
pub extern "C" fn jas_instr_counters_json() -> JasBytes {
    JasBytes::from_string(ffi_instr::snapshot_json())
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

/// Apply one op envelope (BL1: the shell sends events, never state; BL6: the
/// journal's resolved-literal vocabulary, which was built for replay and is
/// therefore already an IPC vocabulary).
///
/// Returns [`JasStatus::Ok`] or the frozen class of the rejection. Detail via
/// [`jas_last_error_json`].
///
/// # Safety
/// `op_json` must be NULL or valid for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_dispatch_event(
    e: *mut JasEngine,
    op_json: *const u8,
    len: usize,
) -> JasStatus {
    // Recorded BEFORE the null check: a refused call still crossed.
    ffi_instr::record(Crossing::DispatchEvent, len, 0);
    let Some(engine) = (unsafe { e.as_ref() }) else {
        return JasStatus::NullHandle;
    };
    *engine.last_error.borrow_mut() = None;

    let text = match unsafe { utf8(op_json, len) } {
        Ok(t) => t,
        Err(s) => return s,
    };
    let Ok(op) = serde_json::from_str::<serde_json::Value>(text) else {
        return JasStatus::BadJson;
    };

    let mut model = engine.model.borrow_mut();
    match op_apply(&mut model, &op) {
        Ok(()) => JasStatus::Ok,
        Err(err) => {
            *engine.last_error.borrow_mut() = Some(error_detail_json(&err));
            JasStatus::of(&err)
        }
    }
}

/// Detail for the last rejection: `{"class":"...", "name"|"id":"..."}` with the
/// class spelled as the negative fixtures spell it. Empty when the last call
/// succeeded.
///
/// # Safety
/// `e` must be a live engine pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_last_error_json(e: *mut JasEngine) -> JasBytes {
    ffi_instr::record(Crossing::LastErrorJson, 0, 0);
    let Some(engine) = (unsafe { e.as_ref() }) else {
        return JasBytes::empty();
    };
    let out = match engine.last_error.borrow().as_ref() {
        Some(s) => JasBytes::from_string(s.clone()),
        None => JasBytes::empty(),
    };
    ffi_instr::record_out(Crossing::LastErrorJson, out.len);
    out
}

// ---------------------------------------------------------------------------
// Panels
// ---------------------------------------------------------------------------

/// The structural widget tree for a panel, canonically serialised.
///
/// This makes the IDENTICAL call the corpus driver makes at
/// `cross_language_test.rs:5317` — `widget_tree(&bundle["panels"][id], ctx)` —
/// which is what lets S-A gate (ii) be a byte-identical round-trip against
/// `test_fixtures/algorithms/panel_widget_tree.json` rather than a
/// self-consistency check.
///
/// # ⚠️ A NULL ctx means "engine, assemble it"; an EMPTY ctx means "empty"
///
/// The two are different on purpose, and the distinction is load-bearing:
///
/// * **`ctx_len == 0`** — the production call. The engine assembles the scope
///   itself, exactly as [`jas_bind_values`] does. **BL1**: a shell that had to
///   supply `active_document.artboards` to see a data-driven panel's rows would
///   be holding app state in C#.
/// * **`"{}"`, two bytes** — an explicit empty scope. This is what the corpus
///   driver passes for panels whose fixtures declare no ctx, and it is why
///   S-A gate (ii) is unaffected by the paragraph above: **no fixture passes
///   NULL.**
///
/// Before S-C.2 a NULL ctx meant an empty scope, and a data-driven panel
/// therefore reported its STATIC size at every document size — the second arm of
/// gate ② would have been identical to the first, measured with the widget count
/// held constant. The `bind_values` half was fixed by route (a); this is the
/// same fix on the half that reports the structure.
///
/// # Safety
/// Both spans must be NULL or valid for their stated lengths.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_widget_tree(
    e: *mut JasEngine,
    panel_id: *const u8,
    panel_len: usize,
    ctx_json: *const u8,
    ctx_len: usize,
) -> JasBytes {
    // Both inbound spans counted: the panel id AND the context JSON crossed,
    // and a chatter figure that counted only the "real" payload would understate
    // a shell that re-sends context on every tick.
    ffi_instr::record(Crossing::WidgetTree, panel_len + ctx_len, 0);
    if e.is_null() {
        return JasBytes::empty();
    }
    let Ok(id) = (unsafe { utf8(panel_id, panel_len) }) else {
        return JasBytes::empty();
    };
    let ctx: serde_json::Value = if ctx_len == 0 {
        // NULL, not empty: the engine assembles it. See the note above.
        let Some(engine) = (unsafe { e.as_ref() }) else {
            return JasBytes::empty();
        };
        panel_ctx(engine)
    } else {
        match unsafe { utf8(ctx_json, ctx_len) }.ok().and_then(|t| serde_json::from_str(t).ok()) {
            Some(v) => v,
            None => return JasBytes::empty(),
        }
    };
    let Some(ws) = crate::interpreter::workspace::Workspace::load() else {
        return JasBytes::empty();
    };
    let Some(spec) = ws.panel(id) else {
        return JasBytes::empty();
    };
    let tree = crate::interpreter::widget_tree::widget_tree(spec, &ctx);
    let out = JasBytes::from_string(serde_json::to_string(&tree).unwrap_or_default());
    ffi_instr::record_out(Crossing::WidgetTree, out.len);
    out
}

// ---------------------------------------------------------------------------
// Tests — the Rust half of the boundary, provable without a shell
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn take(b: JasBytes) -> String {
        if b.ptr.is_null() {
            return String::new();
        }
        let s = unsafe { std::slice::from_raw_parts(b.ptr, b.len) };
        let out = String::from_utf8(s.to_vec()).unwrap();
        unsafe { jas_free(b) };
        out
    }

    fn bytes(s: &str) -> (*const u8, usize) {
        (s.as_ptr(), s.len())
    }

    #[test]
    fn engine_roundtrips_and_frees() {
        // ⭐ ROW EK: the ONE crate-level counter lock. This test reaches an
        // export, and every export records a crossing on the process-global
        // counters -- so it races `ffi_instr`'s tests unless it takes this.
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        assert!(!e.is_null());
        let v = take(jas_version());
        assert!(v.contains("\"crate\":\"jas_dioxus\""), "{v}");
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn free_is_safe_on_the_empty_span() {
        // ⭐ ROW EK: the ONE crate-level counter lock. This test reaches an
        // export, and every export records a crossing on the process-global
        // counters -- so it races `ffi_instr`'s tests unless it takes this.
        let _counters = crate::ffi_instr::test_lock::lock();
        unsafe { jas_free(JasBytes::empty()) };
        unsafe { jas_engine_free(std::ptr::null_mut()) };
    }

    #[test]
    fn null_handle_is_its_own_status_not_a_core_verdict() {
        // ⭐ ROW EK: the ONE crate-level counter lock. This test reaches an
        // export, and every export records a crossing on the process-global
        // counters -- so it races `ffi_instr`'s tests unless it takes this.
        let _counters = crate::ffi_instr::test_lock::lock();
        let (p, n) = bytes("{}");
        let st = unsafe { jas_dispatch_event(std::ptr::null_mut(), p, n) };
        assert_eq!(st, JasStatus::NullHandle);
        assert!(st as i32 >= 100, "transport faults must not collide with 1-5");
    }


    #[test]
    fn bad_utf8_and_bad_json_are_transport_not_core() {
        // ⭐ ROW EK: the ONE crate-level counter lock. This test reaches an
        // export, and every export records a crossing on the process-global
        // counters -- so it races `ffi_instr`'s tests unless it takes this.
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let bad = [0xff_u8, 0xfe];
        let st = unsafe { jas_dispatch_event(e, bad.as_ptr(), bad.len()) };
        assert_eq!(st, JasStatus::BadUtf8);
        let (p, n) = bytes("{not json");
        assert_eq!(unsafe { jas_dispatch_event(e, p, n) }, JasStatus::BadJson);
        // Neither reached op_apply, so neither may report a core class.
        assert!((st as i32) >= 100);
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn the_five_frozen_classes_map_by_position() {
        // Guards the ABI's central claim: 1-5 are the ratified taxonomy in order.
        assert_eq!(JasStatus::of(&OpError::MalformedEnvelope) as i32, 1);
        assert_eq!(JasStatus::of(&OpError::UnknownVerb { name: "x".into() }) as i32, 2);
        assert_eq!(JasStatus::of(&OpError::MissingParam { name: "x" }) as i32, 3);
        assert_eq!(JasStatus::of(&OpError::BadParamType { name: "x" }) as i32, 4);
        assert_eq!(JasStatus::of(&OpError::MissingTarget { id: "x".into() }) as i32, 5);
    }

    #[test]
    fn a_rejected_op_reports_its_frozen_class_and_detail() {
        let e = jas_engine_new();
        let (p, n) = bytes(r#"{"op":"no_such_verb_at_all"}"#);
        assert_eq!(unsafe { jas_dispatch_event(e, p, n) }, JasStatus::UnknownVerb);
        let detail = take(unsafe { jas_last_error_json(e) });
        assert!(detail.contains(r#""class":"UnknownVerb""#), "{detail}");
        assert!(detail.contains("no_such_verb_at_all"), "{detail}");
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn a_malformed_envelope_reports_class_one() {
        let e = jas_engine_new();
        let (p, n) = bytes(r#"{"not_an_op":1}"#);
        assert_eq!(
            unsafe { jas_dispatch_event(e, p, n) },
            JasStatus::MalformedEnvelope
        );
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn last_error_is_cleared_by_a_successful_call() {
        let e = jas_engine_new();
        let (p, n) = bytes(r#"{"op":"nope"}"#);
        assert_ne!(unsafe { jas_dispatch_event(e, p, n) }, JasStatus::Ok);
        assert!(!take(unsafe { jas_last_error_json(e) }).is_empty());
        // A well-formed no-op verb succeeds and must reset the channel.
        let (p2, n2) = bytes(r#"{"op":"clear_selection"}"#);
        if unsafe { jas_dispatch_event(e, p2, n2) } == JasStatus::Ok {
            assert!(take(unsafe { jas_last_error_json(e) }).is_empty());
        }
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn widget_tree_matches_the_corpus_driver_exactly() {
        // The Rust half of S-A gate (ii): every case in the shared golden, through
        // the ABI, byte-identical to what the corpus driver asserts.
        let fixtures = concat!(env!("CARGO_MANIFEST_DIR"), "/../test_fixtures");
        let raw = std::fs::read_to_string(format!("{fixtures}/algorithms/panel_widget_tree.json"))
            .expect("golden");
        let cases: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let e = jas_engine_new();

        let mut checked = 0;
        for tc in cases.as_array().unwrap() {
            let name = tc["name"].as_str().unwrap();
            let panel = tc["args"]["panel"].as_str().unwrap();
            let ctx = tc["args"]
                .get("ctx")
                .cloned()
                .unwrap_or_else(|| serde_json::json!({}));
            let ctx_s = serde_json::to_string(&ctx).unwrap();

            let got = take(unsafe {
                jas_widget_tree(e, panel.as_ptr(), panel.len(), ctx_s.as_ptr(), ctx_s.len())
            });
            let got_v: serde_json::Value = serde_json::from_str(&got)
                .unwrap_or_else(|_| panic!("panel {name}: ABI returned non-JSON: {got}"));
            assert_eq!(&got_v, &tc["expected"], "panel {name} mismatch across the ABI");
            checked += 1;
        }
        assert!(checked >= 16, "expected the full panel set, checked {checked}");
        unsafe { jas_engine_free(e) };
    }

    // -----------------------------------------------------------------------
    // W1 — THE APP ABI (freeze `2026-09-08-jas-FREEZE-windows-app.md` §4, A1+A2)
    //
    // ⛔ RED FIRST. Both functions under test are written AFTER these arms and
    // these arms were seen to fail to COMPILE (the symbol does not exist), which
    // is the strongest red a Rust ABI arm can be given: there is no way to
    // mistake it for a passing assertion against a stub.
    // -----------------------------------------------------------------------

    /// A1 — the save half of the document loop. `jas_document_json` is a
    /// SUMMARY (BL6); this is the artefact a person keeps.
    ///
    /// ⛔ THE LOAD SIDE IS NOT `jas_load_svg`, AND THAT IS A PLATFORM FACT, NOT
    /// A SHORTCUT. `ffi_paint` is `cfg(all(feature = "ffi", feature = "d2d",
    /// windows))` (`lib.rs:41`), so the ABI's own loader cannot be linked on
    /// this host at all. This arm drives the SAME parser it wraps
    /// (`svg_to_document`) through the same `replace_document` seam, so what is
    /// untested here is exactly one `unsafe` span-to-`&str` conversion — stated
    /// rather than implied.
    #[test]
    fn document_svg_is_wellformed_and_survives_a_round_trip() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();

        // A document with something in it, so the round trip is not vacuous —
        // an empty document round-trips through any serializer, including one
        // that writes a constant.
        //
        // ⛔ `r##"..."##`, not `r#"..."#`: the fill colour contains `"#`, which
        // closes a single-hash raw string. The FIRST run of this arm was a
        // syntax error, not a red.
        let src = r##"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="80">
            <rect x="10" y="12" width="30" height="20" fill="#ff0000"/>
        </svg>"##;
        let doc = crate::geometry::svg::svg_to_document(src);
        unsafe { e.as_ref() }.unwrap().replace_document(doc);

        let svg = take(unsafe { jas_document_svg(e) });
        assert!(svg.contains("<svg"), "not an SVG document: {svg}");

        // THE ROUND TRIP, and it is the arm that can actually fail: re-parse our
        // own output into a SECOND engine and compare the canonical JSON. A
        // serializer that dropped the rect would produce well-formed SVG and
        // fail here.
        let e2 = jas_engine_new();
        let doc2 = crate::geometry::svg::svg_to_document(&svg);
        unsafe { e2.as_ref() }.unwrap().replace_document(doc2);
        assert_eq!(
            take(unsafe { jas_document_json(e) }),
            take(unsafe { jas_document_json(e2) }),
            "document_svg lost or altered content on the round trip"
        );

        // ⭐ AND THE CONTROL THE ROUND TRIP NEEDS: the comparison above is only
        // evidence if it can DISAGREE. A different document must differ.
        let e3 = jas_engine_new();
        unsafe { e3.as_ref() }.unwrap().replace_document(
            crate::geometry::svg::svg_to_document(
                r#"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="80"/>"#,
            ),
        );
        assert_ne!(
            take(unsafe { jas_document_json(e) }),
            take(unsafe { jas_document_json(e3) }),
            "the round-trip oracle cannot distinguish two different documents"
        );

        unsafe { jas_engine_free(e3) };
        unsafe { jas_engine_free(e2) };
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn document_svg_on_a_null_handle_is_the_empty_span() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let b = unsafe { jas_document_svg(std::ptr::null_mut()) };
        assert!(b.ptr.is_null() && b.len == 0);
    }

    /// A2 arm (a) — the menu's DYNAMIC half, which is the whole reason the
    /// shell must not author a menubar: `can_undo` is a document fact.
    #[test]
    fn menu_state_reports_undo_disabled_until_the_document_is_edited() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();

        let before = take(unsafe { jas_menu_state(e, std::ptr::null(), 0) });
        let before: serde_json::Value = serde_json::from_str(&before).expect("JSON");
        assert_eq!(
            undo_enabled(&before),
            Some(false),
            "an untouched engine must report Undo DISABLED: {before}"
        );

        // One real mutation through the ABI the shell will use.
        //
        // ⛔ THE VERB IS FROM `op_apply`'s OWN MATCH, not from memory: the first
        // draft used `add_rect`, which does not exist, and the arm failed with
        // `UnknownVerb` — a red that looked like a menu-state defect and was a
        // fixture defect. A verb that is not in the vocabulary is refused, so a
        // wrong one can never silently pass.
        let op = r#"{"op":"create_artboard","id":"ab_w1_fixture"}"#;
        let st = unsafe { jas_dispatch_event(e, op.as_ptr(), op.len()) };
        assert_eq!(st, JasStatus::Ok, "the fixture op must apply: {st:?}");

        let after = take(unsafe { jas_menu_state(e, std::ptr::null(), 0) });
        let after: serde_json::Value = serde_json::from_str(&after).expect("JSON");
        assert_eq!(
            undo_enabled(&after),
            Some(true),
            "after an edit Undo must be ENABLED: {after}"
        );

        unsafe { jas_engine_free(e) };
    }

    /// A2 arm (b) — ⭐ THE MERGE BOUNDARY, IN BOTH DIRECTIONS (freeze §4.1).
    ///
    /// The engine cannot assemble `state.*` (no tabs below the shell) and the
    /// shell must not be able to assert `active_document.*` (that is BL1 — a
    /// shell that can claim `can_undo` is holding document state). One arm is
    /// not enough: a merge that ignored the shell entirely would pass the first
    /// half, and a merge that let the shell win everything would pass the
    /// second.
    #[test]
    fn menu_state_merges_the_shells_session_ctx_but_the_engine_wins_on_the_document() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();

        // The shell lies about a document fact and tells the truth about a
        // session fact, in ONE call.
        let ctx = r#"{"active_document":{"can_undo":true},"state":{"tab_count":1}}"#;
        let got = take(unsafe { jas_menu_state(e, ctx.as_ptr(), ctx.len()) });
        let got: serde_json::Value = serde_json::from_str(&got).expect("JSON");

        assert_eq!(
            undo_enabled(&got),
            Some(false),
            "the SHELL must not be able to assert a document fact: {got}"
        );
        assert_eq!(
            action_enabled(&got, "save"),
            Some(true),
            "the shell's `state.tab_count` MUST be honoured (Save is enabled_when \
             state.tab_count > 0): {got}"
        );

        unsafe { jas_engine_free(e) };
    }

    /// W1b arm (a) — THE JOIN LAW, and it is the whole reason this is a second
    /// function rather than a second copy of the walk.
    ///
    /// `jas_menu_state` supplies the DYNAMIC half and `jas_menu_structure` the
    /// STATIC half; the shell joins them on `path`. So **every state row's path
    /// must exist in the structure as an `item`** — if that ever stops holding,
    /// a shell would render an enabled/disabled verdict onto a menu entry that
    /// does not exist, or silently drop one that does.
    #[test]
    fn menu_structure_and_menu_state_join_on_path() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();

        let state: serde_json::Value =
            serde_json::from_str(&take(unsafe { jas_menu_state(e, std::ptr::null(), 0) }))
                .expect("menu_state JSON");
        let structure: serde_json::Value =
            serde_json::from_str(&take(unsafe { jas_menu_structure() }))
                .expect("menu_structure JSON");

        let items: std::collections::HashSet<String> = structure
            .as_array()
            .expect("array")
            .iter()
            .filter(|r| r["kind"] == "item")
            .map(|r| r["path"].to_string())
            .collect();

        let rows = state.as_array().expect("array");
        // ⛔ ANTI-VACUITY FIRST. Both sides empty would satisfy the subset law
        // perfectly, and this test would pass against two functions that return
        // `[]`. The count is checked BEFORE the law it is supposed to support.
        assert!(
            rows.len() >= 50,
            "menu_state returned {} rows; the join law is vacuous below a real menubar",
            rows.len()
        );
        assert_eq!(
            items.len(),
            rows.len(),
            "structure has {} items, state has {} rows — the two halves disagree \
             about how many menu entries exist",
            items.len(),
            rows.len()
        );
        for r in rows {
            assert!(
                items.contains(&r["path"].to_string()),
                "state row at path {} has no `item` in the structure — a shell \
                 joining on path would render a verdict onto nothing",
                r["path"]
            );
        }

        unsafe { jas_engine_free(e) };
    }

    /// W1b arm (b) — ⭐ THE STATIC HALF IS ACTUALLY THERE, which is the entire
    /// point of the node: `jas_menu_state` supplies `enabled` and an action id,
    /// and the shell also needs a LABEL to draw. A structure whose labels were
    /// all empty would satisfy arm (a) completely.
    #[test]
    fn menu_structure_carries_the_labels_and_shortcuts_the_state_pass_does_not() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let rows: serde_json::Value =
            serde_json::from_str(&take(unsafe { jas_menu_structure() })).expect("JSON");
        let rows = rows.as_array().expect("array");

        // Every top-level menu and every item carries a non-empty label.
        let labelled = rows
            .iter()
            .filter(|r| r["kind"] == "menu" || r["kind"] == "item")
            .count();
        assert!(labelled >= 55, "only {labelled} labelled nodes");
        for r in rows {
            if r["kind"] == "menu" || r["kind"] == "item" {
                assert!(
                    r["label"].as_str().map(|s| !s.is_empty()).unwrap_or(false),
                    "a {} node at {} has no label — the shell cannot draw it",
                    r["kind"],
                    r["path"]
                );
            }
        }

        // The `&` mnemonics survive verbatim: the shell renders them, and a pass
        // that stripped them would look correct until someone used the keyboard.
        assert!(
            rows.iter().any(|r| r["label"].as_str() == Some("&File")),
            "the File menu\'s mnemonic did not survive"
        );
        // At least one real accelerator string reaches the shell.
        assert!(
            rows.iter().any(|r| r["shortcut"].as_str() == Some("Ctrl+S")),
            "no shortcut string in the structure"
        );
    }

    /// W1b arm (c) — ⭐ SEPARATORS AND SUBMENUS ARE EMITTED HERE **because
    /// `menu_state` deliberately does not emit them** (`menu_state.rs:47-53`).
    /// That asymmetry is the reason a shell cannot build a menubar from the
    /// state pass alone, and this arm is what proves the gap is closed.
    #[test]
    fn menu_structure_emits_what_menu_state_deliberately_omits() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let rows: serde_json::Value =
            serde_json::from_str(&take(unsafe { jas_menu_structure() })).expect("JSON");
        let rows = rows.as_array().expect("array");

        let count = |k: &str| rows.iter().filter(|r| r["kind"] == k).count();
        // Measured at `workspace/menubar.yaml`: 5 top-level menus, 11 bare
        // `separator` strings, 2 submenu nodes, 55 action items. Floors rather
        // than equalities everywhere except the menus, because the menubar is
        // edited by people and this test must not have to be edited with it —
        // but a floor of ZERO would make each clause vacuous, which is the
        // whole failure this arm exists to prevent.
        assert_eq!(count("menu"), 5, "top-level menu count");
        assert!(count("separator") >= 10, "separators: {}", count("separator"));
        assert!(count("submenu") >= 2, "submenus: {}", count("submenu"));
        assert!(count("item") >= 55, "items: {}", count("item"));

        // A separator has no label and no action, and says so with nulls rather
        // than with empty strings — `absent` and `""` are different answers.
        let sep = rows.iter().find(|r| r["kind"] == "separator").expect("a separator");
        assert!(sep["label"].is_null() && sep["action"].is_null(), "separator: {sep}");
    }

    /// W1b arm (d) — the structure pass takes NO engine and must not need one.
    /// The menubar is a property of the compiled bundle, not of a document
    /// session, and a parameter it ignored would be a dead arm wearing a driven
    /// arm\'s signature.
    #[test]
    fn menu_structure_is_the_same_without_any_session() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let before = take(unsafe { jas_menu_structure() });
        let e = jas_engine_new();
        let op = r#"{"op":"create_artboard","id":"ab_w1b"}"#;
        assert_eq!(
            unsafe { jas_dispatch_event(e, op.as_ptr(), op.len()) },
            JasStatus::Ok
        );
        let after_edit = take(unsafe { jas_menu_structure() });
        unsafe { jas_engine_free(e) };
        let after_free = take(unsafe { jas_menu_structure() });

        assert!(!before.is_empty(), "the structure must be non-empty to compare");
        assert_eq!(before, after_edit, "an edit changed the STATIC half");
        assert_eq!(before, after_free, "freeing the engine changed the STATIC half");
    }

    #[test]
    fn menu_state_on_a_null_handle_is_the_empty_span() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let b = unsafe { jas_menu_state(std::ptr::null_mut(), std::ptr::null(), 0) };
        assert!(b.ptr.is_null() && b.len == 0);
    }

    /// `enabled` for a named action in a `menu_state` array, or `None` if the
    /// action is not in the menubar at all — the two are DIFFERENT and a test
    /// that collapsed them would pass against a function returning `[]`.
    fn action_enabled(rows: &serde_json::Value, action: &str) -> Option<bool> {
        rows.as_array()?
            .iter()
            .find(|r| r["action"].as_str() == Some(action))?["enabled"]
            .as_bool()
    }

    fn undo_enabled(rows: &serde_json::Value) -> Option<bool> {
        action_enabled(rows, "undo")
    }
}
