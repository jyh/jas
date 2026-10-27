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
use crate::interpreter::state_store::StateStore;
use crate::interpreter::workspace::Workspace;
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
    /// Whether the engine's one document is OPEN (flask STATUS §272, fork
    /// (a)). [`jas_document_close`] clears it after a reply names
    /// `remove_tab`; a load ([`JasEngine::replace_document`]) sets it again.
    /// While it is clear, the scope reads no tab (`tab_count` 0, `active_tab`
    /// -1, an empty `open_documents`), which is `remove_tab`'s own spec.
    document_open: std::cell::Cell<bool>,
    /// The bytes File > Revert returns to: the file last opened
    /// ([`JasEngine::open_svg`]) or saved ([`jas_document_mark_saved`]), as
    /// the web's `TabState::saved_svg`. `None` for a document the engine was
    /// handed any other way, which has nothing on disk to return to.
    saved_svg: RefCell<Option<String>>,
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
    /// The engine's state store (wave 2, A6): the workspace's global `state.*`,
    /// and each panel's own `panel.*` once the engine first assembles that
    /// panel's scope ([`seed_panel`]).
    ///
    /// ⛔ **The colour panel never gets a store scope.** Its `panel.*` is
    /// `panel`'s above, and C1/C2 are pinned on that. The store holds a COPY
    /// of the slice's three `state.*` keys, written at construction and after
    /// every colour tick (`panel_scope::sync_colour_state`), so an effect that
    /// reads them reads what the panels show.
    store: RefCell<StateStore>,
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
    /// The dock layout a shell draws (FP-2): `None` until `jas_layout_load`.
    layout: RefCell<Option<crate::workspace::workspace::WorkspaceLayout>>,
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

    /// The artboard facts the Artboards panel reads (`artboards_panel_selection_ids`,
    /// `current_artboard`, …), from the engine's store and document: what a
    /// tool running on its own store is handed before a claimed key.
    pub(crate) fn artboard_facts(&self) -> serde_json::Value {
        serde_json::Value::Object(crate::panel_scope::artboard_facts(
            &self.store.borrow(), self.model.borrow().document()))
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

    /// The engine's store, for a sibling module (the pointer route's Align
    /// key-object intercept reads and writes the Align panel's scope).
    pub(crate) fn with_store_mut<R>(&self, f: impl FnOnce(&mut StateStore) -> R) -> R {
        f(&mut self.store.borrow_mut())
    }

    /// Name a refusal for [`jas_last_error_json`] from a sibling module.
    pub(crate) fn set_last_error(&self, json: String) { *self.last_error.borrow_mut() = Some(json); }
    pub(crate) fn dpi_scale(&self) -> f64 { self.dpi_scale.get() }
    pub(crate) fn set_dpi_scale(&self, s: f64) { self.dpi_scale.set(s); }
    pub(crate) fn tool_slot(
        &self,
    ) -> std::cell::RefMut<'_, Option<(usize, Box<dyn crate::tools::tool::CanvasTool>)>> {
        self.tool.borrow_mut()
    }

    /// The workspace's `active_tool` state (the toolbar's `checked` binding
    /// reads it, `select_tool` writes it), as a string; `None` when unset.
    pub(crate) fn active_tool_state(&self) -> Option<String> {
        self.store.borrow().get("active_tool").as_str().map(str::to_string)
    }
    pub(crate) fn set_active_tool_state(&self, name: &str) {
        self.store.borrow_mut().set("active_tool", serde_json::Value::String(name.to_string()));
    }

    pub(crate) fn replace_document(&self, doc: crate::document::document::Document) {
        *self.model.borrow_mut() = Model::new(doc, None);
        self.document_open.set(true);
        *self.saved_svg.borrow_mut() = None;
    }

    /// Open a file's text as the document, as File > Open does: OPENED, not
    /// merely decoded (the pages and the at-least-one-artboard invariant), and
    /// the text kept as what Revert returns to. `false`, and nothing changed,
    /// when it does not open.
    pub(crate) fn open_svg(&self, text: &str) -> bool {
        let Some(doc) = crate::geometry::svg::try_open_svg_document(text) else { return false };
        self.replace_document(doc);
        *self.saved_svg.borrow_mut() = Some(text.to_string());
        true
    }

    /// File > Revert, the web's `apply_revert`: re-open the saved bytes and
    /// install them as ONE undoable transaction (so Undo takes a revert back),
    /// then mark the document clean. Runs only when the document is modified
    /// and there are bytes to return to; otherwise it changes nothing. Never
    /// the shell's own open, which would not be one undo step.
    fn revert(&self) -> crate::panel_behavior::Ran {
        let baseline = self.saved_svg.borrow().clone();
        let mut model = self.model.borrow_mut();
        let Some(svg) = baseline.filter(|_| model.is_modified()) else {
            return crate::panel_behavior::Ran { doc_changed: false, state_changed: false };
        };
        let doc = crate::geometry::svg::open_svg_document(&svg);
        model.with_txn(|m| m.set_document(doc));
        model.mark_saved();
        crate::panel_behavior::Ran { doc_changed: true, state_changed: false }
    }

    fn new() -> Self {
        let mut panel = PanelState::default();
        let mut store = StateStore::new();
        if let Some(ws) = Workspace::load() {
            for (k, v) in ws.state_defaults() {
                store.set(&k, v);
            }
        }
        // The colour slice starts from the SPEC's colours (`state.fill_color`,
        // `state.stroke_color`, `state.fill_on_top`), never its own constants:
        // the sync below writes the slice over the store, so a slice default
        // would replace the spec's white with the slice's (#664040 until
        // 2026-10-10, measured by the initial-state-map corpus).
        panel.adopt_store_state(&store, None);
        crate::panel_scope::sync_colour_state(&mut store, &panel);
        crate::panel_scope::seed_library_data(&mut store);
        JasEngine {
            model: RefCell::new(Model::default()),
            document_open: std::cell::Cell::new(true),
            saved_svg: RefCell::new(None),
            last_error: RefCell::new(None),
            panel: RefCell::new(panel),
            registry: RefCell::new(PanelRegistry::default()),
            store: RefCell::new(store),
            dpi_scale: std::cell::Cell::new(1.0),
            tool: RefCell::new(None),
            layout: RefCell::new(None),
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
    // The facts are `panel_scope::document_facts`, which every panel scope
    // carries too, so a menu item and a panel button cannot disagree.
    active.extend(crate::panel_scope::document_facts(&engine.model.borrow()));
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
/// moves it. This is the adapter that pairs the panel slice with the store and
/// the model, because only the engine holds all three. The scope is PER PANEL
/// (wave 2, A6): each panel reads its own `panel.*`.
/// The engine's scope for `panel_id` ("" for none), read with whether its
/// one document is open ([`jas_document_close`]).
/// Open in the ENGINE's store a dialog a tool opened (flask STATUS §285): the
/// same `open_dialog` effect an action runs, so the dialog's `init` evaluates
/// in the engine's scope. `params` arrive RESOLVED in the tool's own scope, and
/// the effect evaluates each param as an expression, so each is passed as a
/// literal (`tool_param_literal`); a param no literal can carry is recorded in
/// `jas_last_error_json` by name and the dialog is not opened.
pub(crate) fn open_tool_dialog(engine: &JasEngine, id: &str,
                               params: &serde_json::Map<String, serde_json::Value>) {
    let Some(ws) = Workspace::load() else { return };
    let mut literal = serde_json::Map::new();
    for (k, v) in params {
        match tool_param_literal(v) {
            Some(expr) => { literal.insert(k.clone(), serde_json::Value::String(expr)); }
            None => {
                set_panel_event_error(engine, "UnliteralParam", &format!("{id}.{k}"));
                return;
            }
        }
    }
    let scope = engine_scope_of(engine, "");
    let effect = serde_json::json!({"open_dialog": {"id": id, "params": literal}});
    let mut store = engine.store.borrow_mut();
    let mut model = engine.model.borrow_mut();
    let report = crate::interpreter::effects::run_effects(
        &[effect], &scope, &mut store, Some(&mut model), Some(ws.actions()), Some(ws.dialogs()), None);
    if let Some(u) = report.unhandled.first() {
        drop((store, model));
        set_panel_event_error(engine, "ToolDialogUnhandled", &format!("{u:?}"));
    }
}

/// A resolved value as an expression that evaluates back to it: a string in
/// single quotes (`None` when it holds one, which the grammar cannot escape),
/// a number or bool as its JSON text, `null`. A list or object has no literal.
fn tool_param_literal(v: &serde_json::Value) -> Option<String> {
    match v {
        serde_json::Value::String(s) if !s.contains('\'') => Some(format!("'{s}'")),
        serde_json::Value::Number(_) | serde_json::Value::Bool(_) | serde_json::Value::Null => Some(v.to_string()),
        _ => None,
    }
}

fn engine_scope_of(engine: &JasEngine, panel_id: &str) -> serde_json::Value {
    crate::panel_scope::engine_scope_open(
        &engine.panel.borrow(), &engine.store.borrow(), &engine.model.borrow(), panel_id,
        engine.document_open.get())
}

fn panel_ctx(engine: &JasEngine, ws: &Workspace, panel_id: &str) -> serde_json::Value {
    seed_panel(engine, ws, panel_id);
    // The store's copy of the colour state is what an action's guard reads
    // (`state.fill_color == null`), so it carries the colour as SHOWN: the
    // selection's, as the web's action context does (`action_fill_stroke_values`).
    crate::panel_scope::sync_colour_state(
        &mut engine.store.borrow_mut(), &engine.panel.borrow().effective(&engine.model.borrow()));
    engine_scope_of(engine, panel_id)
}

/// Give `panel_id` a store scope, seeded from its declared `state:` defaults,
/// the first time the engine assembles its scope. The web app seeds a panel
/// the same way (`renderer.rs`, `panel_state_defaults`); `init:` is not
/// evaluated. Never the colour panel. Callers pass only ids the workspace
/// holds.
fn seed_panel(engine: &JasEngine, ws: &Workspace, panel_id: &str) {
    if panel_id == crate::panel_scope::COLOUR_PANEL {
        // Only `mode` (see `seed_colour_mode`): the slice owns the rest.
        crate::panel_scope::seed_colour_mode(&engine.panel.borrow(), &mut engine.store.borrow_mut());
        return;
    }
    let mut store = engine.store.borrow_mut();
    if !store.has_panel(panel_id) {
        store.init_panel(panel_id, ws.panel_state_defaults(panel_id));
    }
}

/// Apply the panel-state writes a tool queued during one event (the Artboard
/// tool's click selection, `doc.artboard.probe_hit`) to the engine's store,
/// seeding the panel's scope first, since `set_panel` drops a write to a panel
/// with none. The web's canvas routing does the same after every event
/// (`apply_pending_panel_writes`). Until 2026-10-16 the pointer route never
/// drained them, so a canvas click never reached the Artboards panel.
pub(crate) fn apply_tool_panel_writes(engine: &JasEngine, writes: Vec<(String, String, serde_json::Value)>) {
    if writes.is_empty() {
        return;
    }
    let Some(ws) = Workspace::load() else { return };
    for (panel, key, value) in writes {
        seed_panel(engine, &ws, &crate::interpreter::state_store::panel_content_id(&panel));
        engine.store.borrow_mut().set_panel(&panel, &key, value);
    }
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
    let ctx = panel_ctx(engine, &ws, id);
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
///    the panel whole, which was 7,038 bytes on the colour panel when gate ③'s
///    ceiling was taken from it (6,945 since 2026-10-26).
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

    engine.panel.borrow_mut().materialize(&engine.model.borrow());
    let outcome = engine.panel.borrow_mut().apply_edit(&target, &value);
    if outcome == EditOutcome::NoSuchTarget {
        set_panel_event_error(engine, "BadParamType", &target);
        return JasBytes::empty();
    }
    crate::panel_scope::sync_colour_state(&mut engine.store.borrow_mut(), &engine.panel.borrow());

    let sync = engine.registry.borrow_mut().sync(&ws, &|pid| panel_ctx(engine, &ws, pid));
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

/// **The panel plan**: where each widget goes and what it displays, in one
/// crossing (wave 2, A5).
///
/// It is `render_plan`'s rects joined IN THE ENGINE, by path, with the rows
/// [`jas_bind_values`] serves, in the same engine-assembled scope. The shape is
/// documented in `crate::panel_plan`. A shell places a native control at each
/// leaf's `rect`, shows its `values` and its `static` literal display strings
/// (a label's text, a button's tooltip and icon name), and draws each named
/// icon from the plan's `icons` map (W2-5a).
///
/// ⛔ **NOTHING INTERPRETABLE CROSSES.** No node, no `{{ }}` expression, no
/// `behavior`, no binding map, no scope. A templated id, display string or
/// resolved value is named in `withheld` instead of being sent raw, and an
/// icon the workspace does not define is named in `icons_missing`. The shell
/// evaluates nothing, and the arms beside this function check every panel the
/// workspace carries.
///
/// `avail_w` / `avail_h` are the layout pass's own inputs, in canonical panel
/// units (`avail_h == 0` is content height, no vertical flex).
///
/// **It ENROLS the panel**, exactly as [`jas_bind_values`] does: the plan
/// carries the panel's values, so reading it tells the engine the panel is
/// open, and a later tick must send it the rows that move. A shell that opens
/// a panel through the plan alone would otherwise never be told.
///
/// Refusals (NULL handle, bad UTF-8, unknown panel) are the empty span.
/// **BL4**: copy the span, then release with [`jas_free`].
///
/// # Safety
/// `e` must be NULL or live; `panel_id` must be NULL or valid for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_panel_plan(
    e: *mut JasEngine,
    panel_id: *const u8,
    len: usize,
    avail_w: i64,
    avail_h: i64,
) -> JasBytes {
    ffi_instr::record(Crossing::PanelPlan, len, 0);
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
    let ctx = panel_ctx(engine, &ws, id);
    let (plan, rows) = crate::panel_plan::panel_plan(spec, avail_w, avail_h, &ctx, ws.icons(), ws.actions());
    engine.registry.borrow_mut().record(id, &rows);
    let out = JasBytes::from_string(serde_json::to_string(&plan).unwrap_or_default());
    ffi_instr::record_out(Crossing::PanelPlan, out.len);
    out
}

/// **The panels a shell can offer** (W2b-2): `[{"id":"<content id>",
/// "summary":"<display name>"}...]`, sorted by content id.
///
/// `id` is what [`jas_panel_plan`] and [`jas_panel_behavior`] take. `summary`
/// is the panel's own display name, and it is `null` when the panel has none
/// or has a template there, which never crosses raw. The shape is
/// `crate::panel_plan::panel_list`'s.
///
/// ⛔ TAKES NO ENGINE, for [`jas_menu_structure`]'s reason: the list is a
/// property of the compiled bundle, not of a document session, and it
/// evaluates nothing. A shell reads it once.
///
/// A refusal (no compiled workspace) is the empty span.
/// **BL4**: the span is Rust-owned. Copy it, then release with [`jas_free`].
#[unsafe(no_mangle)]
pub extern "C" fn jas_panel_list() -> JasBytes {
    ffi_instr::record(Crossing::PanelList, 0, 0);
    let Some(ws) = crate::interpreter::workspace::Workspace::load() else {
        return JasBytes::empty();
    };
    let list = crate::panel_plan::panel_list(ws.panels());
    let out = JasBytes::from_string(serde_json::to_string(&list).unwrap_or_default());
    ffi_instr::record_out(Crossing::PanelList, out.len);
    out
}

/// **The dock's tab groups** for a named layout of `default_layouts.yaml`:
/// `{"groups":[{"panels":["<content id>"...],"active":<index>}...]}`, in the
/// layout's order. Each id is what [`jas_panel_plan`] takes (the layout names
/// panels by their short id, `color`; this answers the content id,
/// `color_panel_content`). TAKES NO ENGINE, for [`jas_panel_list`]'s reason.
///
/// A refusal (no compiled workspace, bad UTF-8, a layout or a docked panel the
/// bundle does not hold) is the empty span, never a partial dock.
/// **BL4**: the span is Rust-owned. Copy it, then release with [`jas_free`].
///
/// # Safety
/// `name` must be NULL or valid for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_dock_layout(name: *const u8, len: usize) -> JasBytes {
    ffi_instr::record(Crossing::DockLayout, len, 0);
    let Ok(name) = (unsafe { utf8(name, len) }) else { return JasBytes::empty() };
    let Some(ws) = crate::interpreter::workspace::Workspace::load() else {
        return JasBytes::empty();
    };
    let Some(dock) = crate::panel_plan::dock_layout(ws.data(), name) else {
        return JasBytes::empty();
    };
    let out = JasBytes::from_string(serde_json::to_string(&dock).unwrap_or_default());
    ffi_instr::record_out(Crossing::DockLayout, out.len);
    out
}

/// The engine's layout as a shell draws it, or the empty span with
/// `{"panel_event":"NoLayout"}` before a load.
fn layout_reply(engine: &JasEngine) -> JasBytes {
    match engine.layout.borrow().as_ref() {
        Some(l) => JasBytes::from_string(crate::layout_seed::shell_state(l).to_string()),
        None => {
            set_panel_event_error(engine, "NoLayout", "");
            JasBytes::empty()
        }
    }
}

/// **Load the dock layout** named `name` from `default_layouts.yaml` into the
/// engine (floating panels, FP-2), replacing any layout it held, and answer it
/// as [`jas_layout_state`] does. Seeded through the same strict reader as
/// [`jas_dock_layout`], so the groups are the ones that call answers.
///
/// A refusal is the empty span and leaves any held layout unchanged:
/// `BadUtf8`, or `LayoutRefused` (detail: the name) for a layout the bundle
/// does not hold or declares defectively.
/// **BL4**: the span is Rust-owned. Copy it, then release with [`jas_free`].
///
/// # Safety
/// `e` must be NULL or an engine from [`jas_engine_new`]; `name` NULL or valid
/// for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_layout_load(e: *mut JasEngine, name: *const u8, len: usize) -> JasBytes {
    ffi_instr::record(Crossing::LayoutLoad, len, 0);
    let Some(engine) = (unsafe { e.as_ref() }) else { return JasBytes::empty() };
    let Ok(name) = (unsafe { utf8(name, len) }) else {
        set_panel_event_error(engine, "BadUtf8", "");
        return JasBytes::empty();
    };
    let seeded = crate::interpreter::workspace::Workspace::load()
        .and_then(|ws| crate::layout_seed::from_default_layout(ws.data(), name));
    let Some(layout) = seeded else {
        set_panel_event_error(engine, "LayoutRefused", name);
        return JasBytes::empty();
    };
    *engine.layout.borrow_mut() = Some(layout);
    let out = layout_reply(engine);
    ffi_instr::record_out(Crossing::LayoutLoad, out.len);
    out
}

/// **The dock layout** the engine holds, as a shell draws it:
/// `{"name", "anchored":[{"id","edge","collapsed","width","groups":[{"panels":
/// ["<content id>"...],"active","collapsed"}]}], "floating":[{... "x","y","z"}],
/// "z_order":[<dock id>...]}`; a floating dock also carries `z`, its stacking
/// index (draw in ascending `z`). The empty span with `NoLayout` before a load.
/// **BL4**: the span is Rust-owned. Copy it, then release with [`jas_free`].
///
/// # Safety
/// `e` must be NULL or an engine from [`jas_engine_new`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_layout_state(e: *mut JasEngine) -> JasBytes {
    ffi_instr::record(Crossing::LayoutState, 0, 0);
    let Some(engine) = (unsafe { e.as_ref() }) else { return JasBytes::empty() };
    let out = layout_reply(engine);
    ffi_instr::record_out(Crossing::LayoutState, out.len);
    out
}

/// **One layout verb** (`{"op":"detach_group","dock_id":0,"group_idx":1,
/// "x":..,"y":..}`), run by the same `layout_apply` the cross-language corpus
/// pins, answered with the layout after it as [`jas_layout_state`] does.
///
/// The dispatcher SKIPS what it does not know; this entry REFUSES it, because
/// a shell would read an unchanged layout as an answer. A refusal is the empty
/// span and changes nothing: `BadUtf8`, `BadJson`, `NoLayout`, or
/// `BadLayoutOp` (detail: the verb) for an op that is not an object, has no
/// `op`, names no verb, or lacks a field its verb requires.
/// **BL4**: the span is Rust-owned. Copy it, then release with [`jas_free`].
///
/// # Safety
/// `e` must be NULL or an engine from [`jas_engine_new`]; `op` NULL or valid
/// for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_layout_apply(e: *mut JasEngine, op: *const u8, len: usize) -> JasBytes {
    ffi_instr::record(Crossing::LayoutApply, len, 0);
    let Some(engine) = (unsafe { e.as_ref() }) else { return JasBytes::empty() };
    let Ok(raw) = (unsafe { utf8(op, len) }) else {
        set_panel_event_error(engine, "BadUtf8", "");
        return JasBytes::empty();
    };
    let Ok(op) = serde_json::from_str::<serde_json::Value>(raw) else {
        set_panel_event_error(engine, "BadJson", "");
        return JasBytes::empty();
    };
    {
        let mut held = engine.layout.borrow_mut();
        let Some(layout) = held.as_mut() else {
            drop(held);
            set_panel_event_error(engine, "NoLayout", "");
            return JasBytes::empty();
        };
        // Applied to a copy, so a refused op changes nothing.
        let mut next = layout.clone();
        if !crate::workspace::layout_apply::layout_apply_checked(&mut next, &op) {
            drop(held);
            set_panel_event_error(engine, "BadLayoutOp", op["op"].as_str().unwrap_or(""));
            return JasBytes::empty();
        }
        *layout = next;
    }
    let out = layout_reply(engine);
    ffi_instr::record_out(Crossing::LayoutApply, out.len);
    out
}

/// **A widget's behavior**, run in the engine (wave 2, A6).
///
/// `{"widget":"align_left_button","event":"click","alt":false}`: the shell
/// reports what the user did to a control, and the engine runs what the panel
/// spec declares for it. `event` defaults to `click`; `alt` / `shift` /
/// `meta` / `ctrl` default to `false` and reach a behavior's `condition` as
/// `event.*`. The steps and their refusals are `crate::panel_behavior`'s.
///
/// # A value widget (WIDGET_EVENTS.md)
///
/// A committed value is `{"widget":"mwp_fill_tolerance","event":"commit",
/// "value":"40"}`: `value` is the TEXT the person entered (or the picked
/// option's value), sent as a JSON string. The engine parses it by the
/// widget's kind, writes the bound field, then runs the `commit`/`change`
/// behaviors with `event.value`. A toggle or checkbox is pressed with
/// `"event":"click"` and no value. The value refusals are `MissingValue` (no
/// `value`, or JSON null) and `BadValue` (text the kind refuses, or a `value`
/// that is not a string); a refused commit changes nothing.
///
/// # The reply
///
/// `{"changed": [<row>...], "doc_changed": <bool>, "dialog": <id> | null,
/// "remove_tab": <index> | null, "close_window": <bool>,
/// "save_all_then_close": <bool>, "clipboard_write": <text> | null}`
/// ([`act_reply`]; `clipboard_write` is [`jas_dispatch_action`]'s).
/// `close_window` names a window close the shell must do (the engine owns no
/// window): `quit` with nothing edited, or Save Changes' Don't Save.
/// `save_all_then_close` (Save Changes' Save All) names "save every modified
/// document, then close the window only if every save succeeded"; it never
/// comes with `close_window`, so a shell cannot close before saving. `remove_tab` names a tab
/// the shell must remove (the engine owns no tabs): an unedited `close_tab`,
/// or Save Changes' Discard (design 2026-10-14 §10). Each row is a
/// [`jas_panel_event`] delta row, tagged with its `panel`, across every open
/// panel. `doc_changed` says the document moved, so the shell repaints.
///
/// # ⛔ A refusal runs NOTHING
///
/// A refused behavior returns the empty span, and [`jas_last_error_json`]
/// reads `{"panel_event":"<class>","detail":"<detail>"}`. Among the classes,
/// `PlatformEffect` carries `<Kind>:<key>` of the first effect the engine
/// cannot run, found by a pre-flight on copies before anything touches the
/// document or the store. A click that ran and changed nothing (not the
/// document, not the engine's state, no open panel's rows) replies normally
/// and ALSO reads `Unchanged`, so "nothing happened" is never a silent Ok. A
/// click that changed something clears the channel.
///
/// **BL4**: copy the span, then release with [`jas_free`].
///
/// # Safety
/// `e` must be NULL or live; both spans must be NULL or valid for their
/// stated lengths.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_panel_behavior(
    e: *mut JasEngine,
    panel_id: *const u8,
    panel_len: usize,
    event_json: *const u8,
    event_len: usize,
) -> JasBytes {
    ffi_instr::record(Crossing::PanelBehavior, panel_len + event_len, 0);
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
    let Some(ws) = Workspace::load() else {
        return JasBytes::empty();
    };
    let Some(spec) = ws.panel(id) else {
        set_panel_event_error(engine, "MissingTarget", id);
        return JasBytes::empty();
    };
    let refuse = |r: crate::panel_behavior::Refusal| {
        set_panel_event_error(engine, r.class, &r.detail);
        JasBytes::empty()
    };
    let ev = match crate::panel_behavior::parse_event(&ev) {
        Ok(ev) => ev,
        Err(r) => return refuse(r),
    };

    if id == crate::panel_scope::COLOUR_PANEL && is_value_commit(spec, &ev) {
        return colour_value_commit(engine, &ws, spec, &ev);
    }
    // Every other Color event (a swatch, a chip, swap) runs its declared
    // behaviour in the colour scope like any panel's; the value branches of
    // `run_widget_behavior` still refuse Color by name.
    let scope = panel_ctx(engine, &ws, id);
    let (ran, named) = {
        let mut store = engine.store.borrow_mut();
        let mut model = engine.model.borrow_mut();
        let mut host = crate::panel_behavior::EngineHost::default();
        let ran = crate::panel_behavior::run_widget_behavior(
            id, spec, &ev, &scope, &mut store, &mut model, ws.actions(), ws.dialogs(), &mut host);
        (ran, Named::of(host))
    };
    let ran = match ran {
        Ok(ran) => ran,
        Err(r) => return refuse(r),
    };
    // A toolbar click wrote `active_tool`; the pointer must now drive that tool.
    let tool = crate::ffi_pointer::sync_tool_to_state(engine);
    // A behavior writes the store's copy of the colour slice's three
    // `state.*` keys (Swatches' `set_active_color`); every scope reads the
    // slice, so the slice adopts the write and the copy is re-synced from it.
    if engine.panel.borrow_mut().adopt_store_state(&engine.store.borrow(), Some(&engine.model.borrow())) {
        crate::panel_scope::sync_colour_state(&mut engine.store.borrow_mut(), &engine.panel.borrow());
    }

    let sync = engine.registry.borrow_mut().sync(&ws, &|pid| panel_ctx(engine, &ws, pid));
    ffi_instr::record_engine(sync.rows_evaluated, sync.panels_evaluated);
    let moved = sync.changed.as_array().map_or(false, |rows| !rows.is_empty());
    // A tool write that was REFUSED was also undone, so it changed nothing.
    let state_changed = ran.state_changed && tool != crate::ffi_pointer::ToolSync::Refused;
    if ran.doc_changed || state_changed || moved {
        *engine.last_error.borrow_mut() = None;
    } else {
        set_panel_event_error(engine, "Unchanged", &ev.widget);
    }
    let reply = act_reply(engine, &sync.changed, ran.doc_changed, named);
    let out = JasBytes::from_string(serde_json::to_string(&reply).unwrap_or_default());
    ffi_instr::record_out(Crossing::PanelBehavior, out.len);
    out
}

/// A Color panel event through the behaviour door (flask §228, 2026-10-12).
///
/// The colour panel's `panel.*` is the [`PanelState`] slice, never the store
/// (`panel_scope`: the eleven channels are DERIVED), which is why the generic
/// behaviour path refuses it: its bind writes go to the store. A VALUE commit
/// on a Color input is the S-C.2 edit [`jas_panel_event`] already applies, so
/// it is applied the same way: parsed by the widget's kind
/// (`widget_commit::parse_commit`, the generic path's rule), then
/// `apply_edit` on the widget's `bind.value` binding, then the slice's state
/// is re-synced into the store. Every OTHER Color event (a click on a chip, a
/// swatch, the swap button) runs its declared behaviour in the colour scope,
/// and the slice adopts what it wrote to `state.*` (`adopt_store_state`, below
/// the run).
///
/// The reply is the behaviour door's ([`act_reply`]), with `doc_changed: false`:
/// an S-C.2 edit moves the slice and the store, never the document.
/// A commit or change on an INPUT kind: the event that writes a widget's value.
fn is_value_commit(spec: &serde_json::Value, ev: &crate::panel_behavior::UserEvent) -> bool {
    use crate::interpreter::widget_commit::{COMMIT_EVENTS, INPUT_KINDS};
    let kind = crate::panel_behavior::widget_node(spec, &ev.widget)
        .and_then(|n| n.get("type"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    COMMIT_EVENTS.contains(&ev.event.as_str()) && INPUT_KINDS.contains(&kind)
}

fn colour_value_commit(
    engine: &JasEngine,
    ws: &Workspace,
    spec: &serde_json::Value,
    ev: &crate::panel_behavior::UserEvent,
) -> JasBytes {
    use crate::interpreter::widget_commit::{parse_commit, COMMIT_EVENTS, INPUT_KINDS};
    let refuse = |class: &str, detail: &str| {
        set_panel_event_error(engine, class, detail);
        JasBytes::empty()
    };
    let id = crate::panel_scope::COLOUR_PANEL;
    let node = crate::panel_behavior::widget_node(spec, &ev.widget);
    let kind = node.and_then(|n| n.get("type")).and_then(serde_json::Value::as_str).unwrap_or("");
    if !COMMIT_EVENTS.contains(&ev.event.as_str()) || !INPUT_KINDS.contains(&kind) {
        return refuse("PanelNotHosted", id);
    }
    // A disabled widget is refused before its value is read, as the generic
    // route does: Color's hex and sliders are disabled while the active colour
    // is none.
    if node.is_some_and(|n| crate::panel_behavior::widget_disabled(n, &panel_ctx(engine, ws, id))) {
        return refuse("Disabled", &ev.widget);
    }
    let text = match &ev.value {
        None | Some(serde_json::Value::Null) => return refuse("MissingValue", &ev.widget),
        Some(serde_json::Value::String(t)) => t.clone(),
        Some(_) => return refuse("BadValue", &ev.widget),
    };
    let Some(value) = node.and_then(|n| parse_commit(n, &text)) else {
        return refuse("BadValue", &ev.widget);
    };
    // The colour bar's `change` is its LIVE drag (fork B2b): the point's colour
    // paints the default and the selection with no recent colour and no undo
    // step (`colour_host::apply_active_colour_live`); the release's `commit`
    // below takes the one step, back to before the drag.
    if kind == "color_bar" && ev.event != "commit" {
        let (u, v) = (value[0].as_f64().unwrap_or(0.0), value[1].as_f64().unwrap_or(0.0));
        let (r, g, b) = crate::interpreter::color_util::color_bar_rgb(u, v);
        let colour = crate::geometry::element::Color::rgb(r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0);
        let fill_side = engine.panel.borrow().fill_on_top;
        let doc_changed = {
            let mut model = engine.model.borrow_mut();
            let generation = model.generation();
            crate::interpreter::colour_host::apply_active_colour_live(&mut model, fill_side, colour);
            model.generation() != generation
        };
        let sync = engine.registry.borrow_mut().sync(ws, &|pid| panel_ctx(engine, ws, pid));
        ffi_instr::record_engine(sync.rows_evaluated, sync.panels_evaluated);
        *engine.last_error.borrow_mut() = None;
        let reply = act_reply(engine, &sync.changed, doc_changed, Named::default());
        let out = JasBytes::from_string(serde_json::to_string(&reply).unwrap_or_default());
        ffi_instr::record_out(Crossing::PanelBehavior, out.len);
        return out;
    }
    let active_key = if engine.panel.borrow().fill_on_top { "fill_color" } else { "stroke_color" };
    // The colour bar's point names a colour by the ONE colour-bar function,
    // committed as is: the slice is not edited first. The panel then reads the
    // committed colour back from the model (`PanelState::effective`: the
    // selection's colour, else the default the commit set), so it needs no
    // adopt step; the test's empty-selection arm is what pins that.
    let bar_colour = (kind == "color_bar").then(|| {
        let (u, v) = (value[0].as_f64().unwrap_or(0.0), value[1].as_f64().unwrap_or(0.0));
        serde_json::json!(crate::interpreter::color_util::color_bar_hex(u, v))
    });
    let outcome = if let Some(colour) = &bar_colour {
        // A pending live drag is committed whatever its colour: its undo step
        // and its recent colour are owed by THIS release.
        if !engine.model.borrow().has_live_gesture() && engine.store.borrow().get(active_key) == colour {
            EditOutcome::Unchanged
        } else {
            EditOutcome::Changed
        }
    } else {
        let Some(target) = crate::panel_scope::binding_of(spec, &ev.widget, "bind.value") else {
            return refuse("MissingTarget", &ev.widget);
        };
        engine.panel.borrow_mut().materialize(&engine.model.borrow());
        let outcome = engine.panel.borrow_mut().apply_edit(&target, &value);
        if outcome == EditOutcome::NoSuchTarget {
            return refuse("BadParamType", &target);
        }
        crate::panel_scope::sync_colour_state(&mut engine.store.borrow_mut(), &engine.panel.borrow());
        outcome
    };
    // The slice computed the new colour (by channel and mode); COMMITTING it is
    // `set_active_color`'s, "the commit point for all color changes from the
    // Color Panel: … hex field Enter/Tab" (`actions.yaml`). So it runs here as
    // a click runs it, in the colour scope: the model's default and selection
    // follow (`colour_host`, through `global_written`), the recent colour is
    // pushed, and the runner owns the one undo step.
    let mut doc_changed = false;
    if outcome == EditOutcome::Changed {
        let colour = bar_colour.clone().unwrap_or_else(|| engine.store.borrow().get(active_key).clone());
        let params = serde_json::json!({"color": colour});
        let scope = panel_ctx(engine, ws, id);
        let ran = {
            let mut store = engine.store.borrow_mut();
            let mut model = engine.model.borrow_mut();
            let mut host = crate::panel_behavior::EngineHost::default();
            crate::panel_behavior::run_action(
                Some(id), "set_active_color", Some(&params), false, &scope, &mut store, &mut model,
                ws.actions(), ws.dialogs(), &mut host)
        };
        match ran {
            Ok(ran) => doc_changed = ran.doc_changed,
            Err(r) => return refuse(r.class, &r.detail),
        }
    }
    let sync = engine.registry.borrow_mut().sync(ws, &|pid| panel_ctx(engine, ws, pid));
    ffi_instr::record_engine(sync.rows_evaluated, sync.panels_evaluated);
    if outcome == EditOutcome::Unchanged {
        set_panel_event_error(engine, "Unchanged", &ev.widget);
    } else {
        *engine.last_error.borrow_mut() = None;
    }
    let reply = act_reply(engine, &sync.changed, doc_changed, Named::default());
    let out = JasBytes::from_string(serde_json::to_string(&reply).unwrap_or_default());
    ffi_instr::record_out(Crossing::PanelBehavior, out.len);
    out
}

/// One clipboard verb, as the web menu runs it (`menu_bar.rs`), with the
/// system clipboard on the far side of the reply:
///
/// * Copy is not run here: its YAML is (`doc.copy_selection_to_clipboard`,
///   which [`EngineHost`] claims and names as `clipboard_write`).
/// * Cut names the payload and deletes the selection as ONE undo step
///   (`journal_delete_selection`, `cut_selection`), unless deleting would
///   ORPHAN a live instance: then it opens `cut_orphan_confirm` with its
///   `count` and writes nothing, so Cancel is a true no-op (its OK runs
///   `doc.copy_selection_to_clipboard`, which [`EngineHost`] names). The
///   YAML `cut` is NOT run: it would write the payload, then open the DELETE
///   confirm.
/// * A paste is not run here: its YAML is (`doc.paste`, the action's
///   `param.clipboard`), after [`paste_into_session`] has offered the text to
///   an open text session.
///
/// [`EngineHost`]: crate::panel_behavior::EngineHost
fn run_clipboard_verb(engine: &JasEngine, verb: crate::workspace::menu_native::ClipVerb,
                      clipboard: Option<&serde_json::Value>) -> (crate::panel_behavior::Ran, Named) {
    use crate::panel_behavior::Ran;
    use crate::workspace::menu_native::ClipVerb;
    let still = Ran { doc_changed: false, state_changed: false };
    match verb {
        ClipVerb::Copy => unreachable!("a copy runs its YAML (`doc.copy_selection_to_clipboard`)"),
        ClipVerb::Cut => {
            let mut store = engine.store.borrow_mut();
            let mut model = engine.model.borrow_mut();
            let paths: Vec<Vec<usize>> = model.document().selection.iter().map(|es| es.path.clone()).collect();
            let Some(payload) = crate::document::op_apply::selection_clipboard_svg(model.document()) else {
                return (still, Named::default());
            };
            let orphans = crate::document::dependency_index::orphaned_references(model.document(), &paths).len();
            if orphans > 0 {
                const ID: &str = "cut_orphan_confirm";
                let ws = Workspace::load();
                if let Some(def) = ws.as_ref().and_then(|w| w.dialog(ID)) {
                    let params = [("count".to_string(), serde_json::Value::from(orphans))].into_iter().collect();
                    crate::interpreter::effects::open_dialog_in(
                        ID, def, Some(params), None, &serde_json::Value::Null, &mut store, Some(&mut model));
                }
                return (Ran { doc_changed: false, state_changed: true }, Named::default());
            }
            crate::document::op_apply::journal_delete_selection(&mut model, "cut_selection");
            (Ran { doc_changed: true, state_changed: false },
             Named { clipboard_write: Some(payload), ..Named::default() })
        }
        ClipVerb::Paste => unreachable!("a paste runs its YAML: paste_into_session, then the action"),
    }
}

/// A paste's HOST half: a tool editing text takes the clipboard's TEXT at its
/// caret (the web's `paste_clipboard`, before the element paste), so a paste
/// into a session adds no element. `None` when no session took it; the paste
/// then runs its action's YAML (`doc.paste`, fed `param.clipboard`), where
/// the offset and the law live.
fn paste_into_session(engine: &JasEngine, clipboard: Option<&serde_json::Value>)
    -> Option<crate::panel_behavior::Ran>
{
    let text = clipboard.and_then(serde_json::Value::as_str).filter(|t| !t.is_empty())?;
    let mut slot = engine.tool_slot();
    let (_, tool) = slot.as_mut().filter(|(_, t)| t.is_editing())?;
    engine.with_model_mut(|m| tool.paste_text(m, text))
        .then_some(crate::panel_behavior::Ran { doc_changed: true, state_changed: false })
}

/// The reply to an act (a click, a commit, an action): `{"changed": [<row>...],
/// "doc_changed": <bool>, "dialog": <id> | null, "remove_tab": <index> | null,
/// "close_window": <bool>, "save_all_then_close": <bool>, "clipboard_write": <text> |
/// null}`. `dialog` is the dialog open
/// in the engine's store after the act (the dialog door, design 2026-10-14):
/// a shell that reads an id there asks for that dialog's plan, and `null`
/// means none is open, so a shell showing one closes it.
fn act_reply<T: serde::Serialize>(engine: &JasEngine, changed: &T, doc_changed: bool,
                                   named: Named) -> serde_json::Value {
    let dialog = engine.store.borrow().dialog_id().map(str::to_string);
    serde_json::json!({"changed": changed, "doc_changed": doc_changed, "dialog": dialog,
                       "remove_tab": named.remove_tab, "close_window": named.close_window,
                       "save_all_then_close": named.save_all_then_close,
                       "clipboard_write": named.clipboard_write})
}

/// The acts the host NAMES for the shell to do, because the engine owns no tabs
/// and no window and cannot save ([`EngineHost`]): each becomes a reply field.
#[derive(Clone, Default)]
struct Named {
    remove_tab: Option<i64>,
    close_window: bool,
    save_all_then_close: bool,
    /// The payload a Copy or Cut asks the shell to put on the system clipboard.
    clipboard_write: Option<String>,
}

impl Named {
    fn of(host: crate::panel_behavior::EngineHost) -> Named {
        Named { remove_tab: host.removed_tab, close_window: host.closed_window,
                save_all_then_close: host.save_all_then_close, clipboard_write: host.clipboard_write }
    }
}

/// A KEY by [`jas_dispatch_action`]: `{"key": <name>, "mods": {"shift": b,
/// "alt": b, "ctrl": b}}` (flask STATUS § 310, jas § 311). `<name>` is
/// `Delete`, `Backspace`, `Enter`, `Escape` or one character; anything else is
/// refused `BadKey`. The ENGINE resolves it, so the shell holds no binding:
///
/// * an unmodified Delete or Backspace that the active tool neither captures
///   nor claims runs the ACTION `delete_selection` (its reply names
///   `delete_orphan_confirm` when deleting would orphan an instance);
/// * every other key goes through [`crate::ffi_pointer::jas_key_event`]'s
///   order: the active tool, then `shortcuts.yaml`.
///
/// The reply is the act reply, after the same aftermath as an action. A key
/// nothing handled and that changed nothing replies EMPTY with
/// `{"panel_event":"KeyUnhandled","detail":<name>}`, so the shell may apply
/// its own default.
unsafe fn dispatch_key(e: *mut JasEngine, engine: &JasEngine, ws: &Workspace, name: &str,
                       mods: Option<&serde_json::Value>, clipboard: Option<&serde_json::Value>) -> JasBytes {
    use crate::ffi_pointer::{KEY_ARROW_DOWN, KEY_ARROW_LEFT, KEY_ARROW_RIGHT, KEY_ARROW_UP, KEY_BACKSPACE,
                             KEY_DELETE, KEY_END, KEY_ENTER, KEY_ESCAPE, KEY_HOME, KEY_TAB,
                             MOD_ALT, MOD_CMD, MOD_SHIFT};
    let code = match name {
        "Delete" => KEY_DELETE,
        "Backspace" => KEY_BACKSPACE,
        "Enter" => KEY_ENTER,
        "Escape" => KEY_ESCAPE,
        "ArrowUp" => KEY_ARROW_UP,
        "ArrowDown" => KEY_ARROW_DOWN,
        "ArrowLeft" => KEY_ARROW_LEFT,
        "ArrowRight" => KEY_ARROW_RIGHT,
        "Home" => KEY_HOME,
        "End" => KEY_END,
        "Tab" => KEY_TAB,
        _ => {
            let mut chars = name.chars();
            match (chars.next(), chars.next()) {
                (Some(c), None) => c as u32,
                _ => {
                    set_panel_event_error(engine, "BadKey", name);
                    return JasBytes::empty();
                }
            }
        }
    };
    let flag = |k: &str| mods.and_then(|m| m.get(k)).and_then(serde_json::Value::as_bool).unwrap_or(false);
    let mask = if flag("shift") { MOD_SHIFT } else { 0 }
        | if flag("alt") { MOD_ALT } else { 0 }
        | if flag("ctrl") { MOD_CMD } else { 0 };
    // A clipboard chord runs its ACTION, so the key and the menu item give the
    // same reply and the same `NeedsClipboard`; the shell's resend carries
    // `clipboard` on the key request and it is passed through.
    if mask & MOD_CMD != 0 {
        let km = crate::tools::tool::KeyMods { shift: mask & MOD_SHIFT != 0, ctrl: true,
                                               alt: mask & MOD_ALT != 0, meta: false };
        if let crate::workspace::resolve_key::KeyRoute::Clipboard(action) =
            crate::workspace::resolve_key::route_key(name, km, |_| false)
        {
            let mut req = serde_json::json!({"action": action});
            if let Some(clip) = clipboard {
                req["clipboard"] = clip.clone();
            }
            let req = req.to_string();
            return unsafe { jas_dispatch_action(e, req.as_ptr(), req.len()) };
        }
    }
    if matches!(code, KEY_DELETE | KEY_BACKSPACE) && mask & MOD_CMD == 0 {
        let taken = engine.tool_slot().as_ref()
            .is_some_and(|(_, t)| t.captures_keyboard() || t.claims_key(name));
        if !taken {
            const DELETE: &str = r#"{"action":"delete_selection"}"#;
            return unsafe { jas_dispatch_action(e, DELETE.as_ptr(), DELETE.len()) };
        }
    }
    // A bound caret key no tool takes (an arrow, or Shift with one, is
    // `nudge_selection`) runs its ACTION, as the menu would. With nothing
    // selected it changes nothing, so the shell keeps its own default.
    if mask & MOD_CMD == 0 {
        let km = crate::tools::tool::KeyMods { shift: mask & MOD_SHIFT != 0, ctrl: false,
                                               alt: mask & MOD_ALT != 0, meta: false };
        let route = {
            let slot = engine.tool_slot();
            crate::workspace::resolve_key::route_key(name, km, |key| {
                slot.as_ref().is_some_and(|(_, t)| t.captures_keyboard() || t.claims_key(key))
            })
        };
        if let crate::workspace::resolve_key::KeyRoute::Action(cmd) = route {
            if engine.with_document(|d| d.selection.is_empty()) {
                set_panel_event_error(engine, "KeyUnhandled", name);
                return JasBytes::empty();
            }
            let req = serde_json::json!({"action": cmd.action, "params": cmd.params}).to_string();
            return unsafe { jas_dispatch_action(e, req.as_ptr(), req.len()) };
        }
    }
    let generation = engine.model.borrow().generation();
    let status = unsafe { crate::ffi_pointer::jas_key_event(e, code, mask) };
    let doc_changed = engine.model.borrow().generation() != generation;
    if status != JasStatus::Ok && !doc_changed {
        // flask §556 finding H: a command chord the engine does not run
        // (W5-3c) is the menu's, and the shell has already kept it from the
        // menu's accelerator, so the refusal names the action `shortcuts.yaml`
        // binds and the shell runs that menu item. Reached only after the tool
        // declined it, so a text session's Ctrl+A never names one.
        let bound = (mask & MOD_CMD != 0).then(|| {
            let chord = crate::workspace::resolve_key::KeyChord::new(
                name, true, mask & MOD_SHIFT != 0, mask & MOD_ALT != 0, false);
            crate::workspace::resolve_key::resolve_key(&chord)
        }).flatten();
        match bound {
            Some(cmd) => *engine.last_error.borrow_mut() = Some(serde_json::json!({
                "panel_event": "KeyUnhandled", "detail": name,
                "menu_action": cmd.action, "params": cmd.params,
            }).to_string()),
            None => set_panel_event_error(engine, "KeyUnhandled", name),
        }
        return JasBytes::empty();
    }
    let _ = crate::ffi_pointer::sync_tool_to_state(engine);
    let sync = engine.registry.borrow_mut().sync(ws, &|pid| panel_ctx(engine, ws, pid));
    ffi_instr::record_engine(sync.rows_evaluated, sync.panels_evaluated);
    *engine.last_error.borrow_mut() = None;
    let reply = act_reply(engine, &sync.changed, doc_changed, Named::default());
    let out = JasBytes::from_string(serde_json::to_string(&reply).unwrap_or_default());
    ffi_instr::record_out(Crossing::DispatchAction, out.len);
    out
}

/// Run one workspace ACTION, as a menu item runs it: `{"menu_item": <id>}`, the
/// item's own `action` and `params` read from the menubar (the shell names WHICH
/// item was chosen, BL1, and never authors params; the menu structure carries
/// none), or `{"action": <id>, "params": {...}}` directly, `params` optional.
/// The core runs the action's effects as `jas_panel_behavior` runs a widget's,
/// with no panel made active. `{"panel": <content id>, "action": <id>,
/// "params": {...}}` (no `menu_index`) runs it with that panel active and in
/// its scope, as the panel's own widget runs it (a Layers breadcrumb's
/// `exit_isolation_to_level`, on no menu); its params are values, as above.
///
/// `{"key": <name>, "mods": {"shift": b, "alt": b, "ctrl": b}}` is a KEY: the
/// engine resolves it (the active tool, then `shortcuts.yaml`; an unclaimed
/// Delete or Backspace is the action `delete_selection`) and replies as for an
/// action. `<name>` is `Delete`, `Backspace`, `Enter`, `Escape` or one
/// character; anything else is refused `BadKey`. A key nothing handled replies
/// EMPTY with `KeyUnhandled`, so the shell may apply its own default.
///
/// The owner's notes (2026-10-11): the Windows menus drew every item live and
/// ran five; File > New made no tab, because nothing ran `new_document`.
///
/// # The reply
///
/// [`jas_panel_behavior`]'s ([`act_reply`]), so the shell repaints and
/// re-reads exactly as after a click, and opens the dialog it names.
///
/// # The clipboard
///
/// The engine owns no system clipboard; the shell does. Copy and Cut (the
/// menu items, the actions, Ctrl+C and Ctrl+X) reply
/// `"clipboard_write": <text>`: the selection as SVG markup, plain text, which
/// the shell puts on the system clipboard as it is, never looking inside. Every
/// other reply carries `"clipboard_write": null`, and a Cut that would orphan
/// an instance names `cut_orphan_confirm` in `dialog` and writes nothing until
/// that dialog's OK, whose reply carries the payload.
/// A paste (`paste`, `paste_in_place`, `paste_preserving_layers`, Ctrl+V,
/// Ctrl+Shift+V) sent WITHOUT a `"clipboard"` field is refused
/// `NeedsClipboard`, the action as detail, before anything runs: the shell
/// reads its clipboard's text and sends the SAME request again with
/// `"clipboard": <text>`, or `"clipboard": null` when it cannot read one.
/// Nothing to paste (null or "") replies normally and reads `Unchanged`.
///
/// # ⛔ A refusal runs NOTHING
///
/// The empty span, and [`jas_last_error_json`] reads `{"panel_event":
/// "<class>","detail":"<detail>"}`: `BadUtf8`, `BadJson`, `UnknownMenuItem` (a
/// menu item id the menubar does not hold, named), `MissingAction` (no
/// `action` string), `UnknownAction` (an id the workspace does not define,
/// named), `NeedsClipboard` (a paste sent without its `clipboard` field, the
/// action named), or `PlatformEffect` (an effect only the shell can run, such
/// as a native dialog, found by the pre-flight before anything moved). An action
/// that ran and changed nothing replies normally and ALSO reads `Unchanged`.
///
/// **BL4**: copy the span, then release with [`jas_free`].
///
/// # Safety
/// `e` must be NULL or live; the span must be NULL or valid for its length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_dispatch_action(
    e: *mut JasEngine,
    action_json: *const u8,
    action_len: usize,
) -> JasBytes {
    ffi_instr::record(Crossing::DispatchAction, action_len, 0);
    let Some(engine) = (unsafe { e.as_ref() }) else {
        return JasBytes::empty();
    };
    let Ok(raw) = (unsafe { utf8(action_json, action_len) }) else {
        set_panel_event_error(engine, "BadUtf8", "");
        return JasBytes::empty();
    };
    let Ok(req) = serde_json::from_str::<serde_json::Value>(raw) else {
        set_panel_event_error(engine, "BadJson", "");
        return JasBytes::empty();
    };
    let Some(ws) = Workspace::load() else {
        return JasBytes::empty();
    };
    // `{"key": <name>, "mods": {"shift","alt","ctrl"}}`: a KEY, resolved in the
    // engine and answered with the act reply (flask STATUS § 310, jas § 311).
    if let Some(name) = req.get("key").and_then(serde_json::Value::as_str) {
        return unsafe { dispatch_key(e, engine, &ws, name, req.get("mods"), req.get("clipboard")) };
    }
    // `{"panel": <content id>, "menu_index": <i>}`: that PANEL menu's item i,
    // run with its panel active and in its panel's scope.
    // `{"panel": <content id>, "action": <id>, "params"?}`, with no index: an
    // action a panel's own widget runs (a breadcrumb's, on no menu), run the
    // same way, its params bound as values as a menubar caller's are.
    let panel = req.get("panel").and_then(serde_json::Value::as_str);
    if let Some(pid) = panel {
        if ws.panel(pid).is_none() {
            set_panel_event_error(engine, "UnknownPanel", pid);
            return JasBytes::empty();
        }
    }
    let panel_menu = panel.map(|pid| ws.panel_menu(pid));
    // `{"menu_item": <id>}`: the item's own action and params, from the menubar.
    let item = match (req.get("menu_item").and_then(serde_json::Value::as_str), &panel_menu) {
        (Some(id), _) => match find_menu_item(&ws.data()["menubar"], id) {
            Some(item) => Some(item.clone()),
            None => {
                set_panel_event_error(engine, "UnknownMenuItem", id);
                return JasBytes::empty();
            }
        },
        (None, Some(_)) if req.get("menu_index").is_none() && req.get("action").is_some() => None,
        (None, Some(menu)) => {
            let at = req.get("menu_index").and_then(serde_json::Value::as_u64);
            match at.and_then(|i| menu.get(i as usize)) {
                Some(node) => Some(node.clone()),
                None => {
                    let named = req.get("menu_index").map_or("(none)".to_string(), |v| v.to_string());
                    set_panel_event_error(engine, "UnknownMenuItem", &format!("{}[{named}]", panel.unwrap_or("")));
                    return JasBytes::empty();
                }
            }
        }
        (None, None) => None,
    };
    let source = item.as_ref().unwrap_or(&req);
    let Some(action) = source.get("action").and_then(serde_json::Value::as_str) else {
        set_panel_event_error(engine, "MissingAction", "");
        return JasBytes::empty();
    };
    let params = source.get("params");
    // The clipboard verbs (the Windows clipboard node): the menubar's, never a
    // panel menu's. A paste needs the system clipboard, which the shell owns,
    // so a paste request with no `clipboard` field is refused `NeedsClipboard`
    // BEFORE anything runs; the shell resends it with `"clipboard": <text> |
    // null` (null: unreadable).
    let clip_verb = panel.is_none().then(|| crate::workspace::menu_native::clipboard_verb(action)).flatten();
    if matches!(clip_verb, Some(crate::workspace::menu_native::ClipVerb::Paste))
        && req.get("clipboard").is_none()
    {
        set_panel_event_error(engine, "NeedsClipboard", action);
        return JasBytes::empty();
    }
    // Every panel gets its store scope first: an action may write a panel the
    // shell has never opened (`set_brush_view_mode`, the colour panel's mode),
    // and `StateStore::set_panel` drops a write to a panel with no scope.
    // Swift's action runner seeds every panel for the same reason.
    if let Some(ids) = ws.panels().as_object() {
        for pid in ids.keys() {
            seed_panel(engine, &ws, pid);
        }
    }
    // A menubar item runs in the app's scope, no panel's: `engine_scope` with no
    // panel id reads the state and the active document and seeds nothing. A
    // panel-menu item runs in its panel's scope, seeded as a click's is.
    // Both carry the colour as SHOWN in `state.*` (the selection's, as the
    // web's action context does for every action, `action_fill_stroke_values`):
    // New Swatch and the Color Picker are menubar actions that read
    // `state.fill_color`, and until 2026-10-15 this arm read the stale copy.
    let scope = match panel {
        Some(pid) => panel_ctx(engine, &ws, pid),
        None => {
            crate::panel_scope::sync_colour_state(
                &mut engine.store.borrow_mut(), &engine.panel.borrow().effective(&engine.model.borrow()));
            engine_scope_of(engine, "")
        }
    };
    // File > Revert (finding 12 of the 10-20 sitting): a `log` stub in
    // `actions.yaml`, and its bytes are the engine's, so the engine runs it.
    let revert = (panel.is_none() && action == "revert").then(|| engine.revert());
    // A paste's clipboard read is its action's VALUE param (`null`:
    // unreadable): the YAML's `doc.paste` hands it to the paste law.
    let is_paste = matches!(clip_verb, Some(crate::workspace::menu_native::ClipVerb::Paste));
    let session = if is_paste { paste_into_session(engine, req.get("clipboard")) } else { None };
    let paste_params = is_paste.then(|| serde_json::json!({
        "clipboard": req.get("clipboard").cloned().unwrap_or(serde_json::Value::Null)}));
    let (params, params_are_values) = match &paste_params {
        Some(p) => (Some(p), true),
        None => (params, item.is_none()),
    };
    let (ran, named) = if let Some(ran) = session {
        (Ok(ran), Named::default())
    // Copy runs its YAML too (`doc.copy_selection_to_clipboard`, which
    // [`EngineHost`] claims and NAMES as `clipboard_write`); only Cut stays
    // here, because its YAML would open the DELETE confirm.
    } else if let Some(verb) = clip_verb.filter(|v| *v == crate::workspace::menu_native::ClipVerb::Cut) {
        let (ran, named) = run_clipboard_verb(engine, verb, req.get("clipboard"));
        (Ok(ran), named)
    } else if let Some(ran) = revert {
        (Ok(ran), Named::default())
    } else {
        let mut store = engine.store.borrow_mut();
        let mut model = engine.model.borrow_mut();
        let mut host = crate::panel_behavior::EngineHost::default();
        let ran = crate::panel_behavior::run_action(
            panel, action, params, params_are_values, &scope, &mut store, &mut model, ws.actions(),
            ws.dialogs(),
            &mut host);
        (ran, Named::of(host))
    };
    let ran = match ran {
        Ok(ran) => ran,
        Err(r) => {
            set_panel_event_error(engine, r.class, &r.detail);
            return JasBytes::empty();
        }
    };
    // The same aftermath as a click: the tool, the colour slice, every open
    // panel's rows.
    let tool = crate::ffi_pointer::sync_tool_to_state(engine);
    if engine.panel.borrow_mut().adopt_store_state(&engine.store.borrow(), Some(&engine.model.borrow())) {
        crate::panel_scope::sync_colour_state(&mut engine.store.borrow_mut(), &engine.panel.borrow());
    }
    let sync = engine.registry.borrow_mut().sync(&ws, &|pid| panel_ctx(engine, &ws, pid));
    ffi_instr::record_engine(sync.rows_evaluated, sync.panels_evaluated);
    let moved = sync.changed.as_array().map_or(false, |rows| !rows.is_empty());
    let state_changed = ran.state_changed && tool != crate::ffi_pointer::ToolSync::Refused;
    if ran.doc_changed || state_changed || moved || named.clipboard_write.is_some() {
        *engine.last_error.borrow_mut() = None;
    } else {
        set_panel_event_error(engine, "Unchanged", action);
    }
    let reply = act_reply(engine, &sync.changed, ran.doc_changed, named);
    let out = JasBytes::from_string(serde_json::to_string(&reply).unwrap_or_default());
    ffi_instr::record_out(Crossing::DispatchAction, out.len);
    out
}

/// Whether the active document is MODIFIED: 1 when it holds an edit since it
/// was opened or last saved, 0 when it does not, 255 for a null engine.
///
/// ⭐ IT EXISTS FOR A SHELL'S DIRTY FLAG (flask STATUS §246, ruled §247). A
/// reply's `doc_changed` means "repaint the document", and a selection change
/// sets it, so a shell that marked the document dirty on `doc_changed` made
/// Select All an edit. This is the model's own answer (`Model::is_modified`):
/// a selection and a live drag tick are not edits, and Undo back to the saved
/// state is unmodified again. 255, not 0, for a null engine: 0 would read as
/// "saved" about a session that does not exist.
///
/// # Safety
/// `e` must be NULL or a pointer from `jas_engine_new` that is still live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_document_modified(e: *mut JasEngine) -> u8 {
    let Some(engine) = (unsafe { e.as_ref() }) else { return 255 };
    u8::from(engine.with_model(|m| m.is_modified()))
}

/// **The shell wrote the document to disk: record that as the saved state**
/// (`Model::mark_saved`). The shell writes the file itself (from
/// [`jas_document_svg`]), so the model cannot know a save happened unless it is
/// told. Without this, [`jas_document_modified`] measures from the OPENED
/// state: open, edit, save, Undo would read "not modified" while the file on
/// disk holds the edit. Call it only after the write succeeded. 1 when marked,
/// 255 for a null engine.
///
/// # Safety
/// `e` must be NULL or a pointer from `jas_engine_new` that is still live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_document_mark_saved(e: *mut JasEngine) -> u8 {
    let Some(engine) = (unsafe { e.as_ref() }) else { return 255 };
    engine.with_model_mut(Model::mark_saved);
    // What the shell wrote is `jas_document_svg`'s bytes, so Revert returns here.
    *engine.saved_svg.borrow_mut() = Some(engine.with_document(crate::geometry::svg::document_to_svg));
    1
}

/// **Escape, or the dialog window's close box: dismiss the open dialog** (the
/// dialog door, design 2026-10-14). Every other dialog act is a click on one of
/// its YAML buttons; this is the one a shell makes on its own. It closes the
/// dialog exactly as the `close_dialog` effect does (`dismiss_dialog`'s whole
/// body): a preview snapshot no OK action cleared is restored, for state and
/// for the document. 1 when a dialog was closed, 0 when none was open, 255 for
/// a null engine.
///
/// # Safety
/// `e` must be NULL or a pointer from `jas_engine_new` that is still live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_dialog_dismiss(e: *mut JasEngine) -> u8 {
    let Some(engine) = (unsafe { e.as_ref() }) else { return 255 };
    let mut store = engine.store.borrow_mut();
    if store.dialog_id().is_none() {
        return 0;
    }
    engine.with_model_mut(|m| crate::interpreter::effects::close_dialog_in(&mut store, Some(m)));
    1
}

/// **The open dialog's plan** (the dialog door, design 2026-10-14): the panel
/// planner over the dialog's `content`, so the shell materializes a dialog
/// body with the code that materializes a panel. The context is the engine's
/// scope plus the dialog's own (`dialog.*`, its state; `param.*`, its params).
///
/// # The reply
///
/// `{"open": false}` when no dialog is open. Otherwise `{"open": true, "id",
/// "summary", "modal", "depth", "width", "plan"}`: `depth` is how many dialogs
/// are open (2 when the Color Picker sits over Layer Options), `width` is the
/// dialog's declared width or null (the web sizes an undeclared one to its
/// content), and `plan` is [`jas_panel_plan`]'s shape for the TOP dialog,
/// planned at the caller's `avail_w`.
///
/// A null engine is the empty span. **BL4**: copy the span, then release with
/// [`jas_free`].
///
/// # Safety
/// `e` must be NULL or a pointer from `jas_engine_new` that is still live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_dialog_plan(e: *mut JasEngine, avail_w: i64, avail_h: i64) -> JasBytes {
    let Some(engine) = (unsafe { e.as_ref() }) else {
        return JasBytes::empty();
    };
    let Some(ws) = crate::interpreter::workspace::Workspace::load() else {
        return JasBytes::empty();
    };
    let (id, depth, scope) = {
        let store = engine.store.borrow();
        let Some(id) = store.dialog_id().map(str::to_string) else {
            return JasBytes::from_string(r#"{"open":false}"#.to_string());
        };
        (id, store.dialog_depth(), store.eval_context())
    };
    let Some(def) = ws.dialog(&id) else {
        return JasBytes::from_string(r#"{"open":false}"#.to_string());
    };
    let mut spec = def.clone();
    spec["id"] = serde_json::Value::String(id.clone());
    let ctx = dialog_ctx(engine, &scope);
    let (plan, _rows) = crate::panel_plan::panel_plan(&spec, avail_w, avail_h, &ctx, ws.icons(), ws.actions());
    let reply = serde_json::json!({
        "open": true,
        "id": id,
        "summary": def.get("summary").cloned().unwrap_or(serde_json::Value::Null),
        "modal": def.get("modal").cloned().unwrap_or(serde_json::Value::Bool(false)),
        "depth": depth,
        "width": def.get("width").cloned().unwrap_or(serde_json::Value::Null),
        "plan": plan,
    });
    JasBytes::from_string(serde_json::to_string(&reply).unwrap_or_default())
}

/// The scope a widget of the open dialog is evaluated in: the engine's, plus
/// the dialog's own `dialog.*` (its state) and `param.*` (its params) and the
/// ACTIVE panel's `panel.*`, from `store_ctx`, the store's eval context, as
/// the reference evaluates a dialog widget.
fn dialog_ctx(engine: &JasEngine, store_ctx: &serde_json::Value) -> serde_json::Value {
    let mut ctx = engine_scope_of(engine, "");
    // `panel` is the ACTIVE panel's scope, as the reference's `eval_context`
    // carries it with a dialog open: Artboard Options reads the Artboards
    // panel's `panel.reference_point`.
    for key in ["dialog", "param", "panel"] {
        if let Some(v) = store_ctx.get(key) {
            ctx[key] = v.clone();
        }
    }
    ctx
}

/// **A widget of the open dialog, acted on** (the dialog door, design
/// 2026-10-14 §1.2): [`jas_panel_behavior`]'s event, addressed to the TOP
/// dialog instead of a panel. OK, Cancel, Save and Discard are YAML buttons
/// with actions, so the shell answers a dialog by CLICKING them, by plan path
/// (`{"path":[...],"event":"click"}`; a dialog's buttons carry no id) or by
/// widget id. A commit or a press writes the dialog's own `dialog.<ident>`
/// and mirrors no global, as the reference's `widget_event` writes a widget
/// with no panel; no panel is made active. Escape is [`jas_dialog_dismiss`].
///
/// # The reply
///
/// [`jas_panel_behavior`]'s ([`act_reply`]). Its `dialog` is the dialog open
/// AFTER the act: `null` when the click closed it, the parent's id when a
/// nested dialog returned to it, a new id when the click opened one. The
/// shell then re-reads [`jas_dialog_plan`].
///
/// # ⛔ A refusal runs NOTHING
///
/// The empty span, and [`jas_last_error_json`] reads `{"panel_event":
/// "<class>","detail":"<detail>"}`: `NoDialog` when no dialog is open, else
/// the classes [`jas_panel_behavior`] names. A run that changed nothing also
/// reads `Unchanged`. A null engine is the empty span.
/// **BL4**: copy the span, then release with [`jas_free`].
///
/// # Safety
/// `e` must be NULL or live; the span must be NULL or valid for its length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_dialog_event(e: *mut JasEngine, event_json: *const u8, event_len: usize) -> JasBytes {
    let Some(engine) = (unsafe { e.as_ref() }) else {
        return JasBytes::empty();
    };
    let Ok(raw) = (unsafe { utf8(event_json, event_len) }) else {
        set_panel_event_error(engine, "BadUtf8", "");
        return JasBytes::empty();
    };
    let Ok(ev) = serde_json::from_str::<serde_json::Value>(raw) else {
        set_panel_event_error(engine, "BadJson", "");
        return JasBytes::empty();
    };
    let Some(ws) = Workspace::load() else {
        return JasBytes::empty();
    };
    let (id, store_ctx) = {
        let store = engine.store.borrow();
        let Some(id) = store.dialog_id().map(str::to_string) else {
            drop(store);
            set_panel_event_error(engine, "NoDialog", "");
            return JasBytes::empty();
        };
        (id, store.eval_context())
    };
    let Some(spec) = ws.dialog(&id) else {
        set_panel_event_error(engine, "MissingTarget", &id);
        return JasBytes::empty();
    };
    let refuse = |r: crate::panel_behavior::Refusal| {
        set_panel_event_error(engine, r.class, &r.detail);
        JasBytes::empty()
    };
    let ev = match crate::panel_behavior::parse_event(&ev) {
        Ok(ev) => ev,
        Err(r) => return refuse(r),
    };
    let scope = dialog_ctx(engine, &store_ctx);
    let (ran, named) = {
        let mut store = engine.store.borrow_mut();
        let mut model = engine.model.borrow_mut();
        let mut host = crate::panel_behavior::EngineHost::default();
        let ran = crate::panel_behavior::run_dialog_widget_behavior(
            spec, &ev, &scope, &mut store, &mut model, ws.actions(), ws.dialogs(), &mut host);
        (ran, Named::of(host))
    };
    let ran = match ran {
        Ok(ran) => ran,
        Err(r) => return refuse(r),
    };
    // A dialog's OK can write the colour slice's `state.*` keys (the picker's
    // fill/stroke targets), so the slice adopts them as after a panel click.
    if engine.panel.borrow_mut().adopt_store_state(&engine.store.borrow(), Some(&engine.model.borrow())) {
        crate::panel_scope::sync_colour_state(&mut engine.store.borrow_mut(), &engine.panel.borrow());
    }
    let sync = engine.registry.borrow_mut().sync(&ws, &|pid| panel_ctx(engine, &ws, pid));
    let moved = sync.changed.as_array().map_or(false, |rows| !rows.is_empty());
    if ran.doc_changed || ran.state_changed || moved {
        *engine.last_error.borrow_mut() = None;
    } else {
        set_panel_event_error(engine, "Unchanged", &ev.widget);
    }
    let reply = act_reply(engine, &sync.changed, ran.doc_changed, named);
    JasBytes::from_string(serde_json::to_string(&reply).unwrap_or_default())
}

/// **Close the engine's one document** (flask STATUS §272, fork (a)): the
/// shell's answer to a reply that names `"remove_tab": 0`. The tab bar then
/// draws no tab, and every scope reads `tab_count` 0, `active_tab` -1 and an
/// empty `workspace.open_documents`, which is what `remove_tab`'s spec says
/// for the last tab ("set active_tab to -1"). The model is kept, unshown; a
/// load opens a document again. 1 when it closed an open document, 0 when
/// none was open, 255 for a null engine.
///
/// # Safety
/// `e` must be NULL or a pointer from `jas_engine_new` that is still live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_document_close(e: *mut JasEngine) -> u8 {
    let Some(engine) = (unsafe { e.as_ref() }) else { return 255 };
    u8::from(engine.document_open.replace(false))
}

/// **The shell names the document it opened or saved** (flask §256): the
/// model's `filename`, which the canvas tab shows (`workspace.open_documents`,
/// owner note 4b). [`crate::ffi_paint::jas_load_svg`] takes bytes only and the
/// engine names a replaced document with its next untitled name, so without
/// this an opened file's tab read `Untitled-N`. Pass the name to show (a file
/// name, not a path). Naming is not an edit.
///
/// ⛔ BYTES, NOT A STRING (BL5), as `jas_load_svg`: the default P/Invoke
/// `CharSet` is `Ansi`, which would mangle a non-ASCII name. 1 when named; 0
/// when refused (a null pointer, bytes that are not UTF-8, or an empty name),
/// changing nothing; 255 for a null engine.
///
/// # Safety
/// `e` must be NULL or a pointer from `jas_engine_new` that is still live.
/// `name` must be NULL or point to `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_document_set_filename(e: *mut JasEngine, name: *const u8, len: usize) -> u8 {
    let Some(engine) = (unsafe { e.as_ref() }) else { return 255 };
    if name.is_null() {
        return 0;
    }
    let bytes = unsafe { core::slice::from_raw_parts(name, len) };
    let Ok(text) = core::str::from_utf8(bytes) else { return 0 };
    if text.is_empty() {
        return 0;
    }
    engine.with_model_mut(|m| m.filename = text.to_string());
    1
}

/// **One panel's menu, for a shell to draw** (the owner's note 3, 2026-10-12:
/// the Windows dock had no panel menu). A JSON array with ONE ROW PER NODE of
/// the panel's `menu:`, in order, each `{"index", "kind"}`: `kind` is `item`
/// or `separator` (any other node is `unknown`, never guessed at). An item
/// also carries `label`, `action`, `enabled` and `checked` (a bool for a
/// checkable item, null otherwise).
///
/// ⭐ THE STATE IS THE SHARED WALK'S, NOT THIS FUNCTION'S. `enabled` and
/// `checked` are [`menu_state`]'s rows for the menu, evaluated in the panel's
/// engine scope, so the shell evaluates nothing and a panel menu reads what
/// the cross-language corpus (`algorithms/panel_menu_state.json`) pins. That
/// walk reads `enabled_when` and `checked_when` only, so a node spelled
/// `checked:` or `disabled: true` reads unchecked and enabled here exactly as
/// it does there.
///
/// A click goes back by index: `jas_dispatch_action({"panel", "menu_index"})`.
/// An unknown panel is the empty span with `UnknownPanel` on
/// [`jas_last_error_json`].
///
/// [`menu_state`]: crate::interpreter::menu_state::menu_state
///
/// # Safety
/// `e` is null or from [`jas_engine_new`], and `panel_id` is `len` readable
/// bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_panel_menu(
    e: *mut JasEngine,
    panel_id: *const u8,
    len: usize,
) -> JasBytes {
    ffi_instr::record(Crossing::PanelMenu, len, 0);
    let Some(engine) = (unsafe { e.as_ref() }) else {
        return JasBytes::empty();
    };
    let Ok(id) = (unsafe { utf8(panel_id, len) }) else {
        set_panel_event_error(engine, "BadUtf8", "");
        return JasBytes::empty();
    };
    let Some(ws) = Workspace::load() else {
        return JasBytes::empty();
    };
    if ws.panel(id).is_none() {
        set_panel_event_error(engine, "UnknownPanel", id);
        return JasBytes::empty();
    }
    let menu = ws.panel_menu(id);
    let ctx = panel_ctx(engine, &ws, id);
    let state = crate::interpreter::menu_state::menu_state(&serde_json::json!([{ "items": menu }]), &ctx);
    let by_index: std::collections::HashMap<i64, &serde_json::Value> = state
        .as_array()
        .map(|rows| rows.iter().filter_map(|r| Some((r["path"].get(1)?.as_i64()?, r))).collect())
        .unwrap_or_default();
    let rows: Vec<serde_json::Value> = menu
        .iter()
        .enumerate()
        .map(|(i, node)| match node {
            serde_json::Value::String(s) if s == "separator" => serde_json::json!({"index": i, "kind": "separator"}),
            serde_json::Value::Object(o) if !o.contains_key("items") => {
                let st = by_index.get(&(i as i64));
                serde_json::json!({
                    "index": i,
                    "kind": "item",
                    // The walk's label: its `{{expr}}` regions evaluated in the
                    // panel's engine scope (a raw template reached the Windows
                    // flyout until 2026-10-26, flask §564 finding J).
                    "label": st.map_or_else(
                        || o.get("label").cloned().unwrap_or(serde_json::Value::Null),
                        |r| r["label"].clone()),
                    "action": o.get("action").cloned().unwrap_or(serde_json::Value::Null),
                    "enabled": st.map_or(serde_json::Value::Bool(true), |r| r["enabled"].clone()),
                    "checked": st.map_or(serde_json::Value::Null, |r| r["checked"].clone()),
                })
            }
            _ => serde_json::json!({"index": i, "kind": "unknown"}),
        })
        .collect();
    *engine.last_error.borrow_mut() = None;
    let out = JasBytes::from_string(serde_json::Value::Array(rows).to_string());
    ffi_instr::record_out(Crossing::PanelMenu, out.len);
    out
}

/// The menubar item whose `id` is `id`, at any depth (a menu's `items`, a
/// submenu's), or `None`.
fn find_menu_item<'a>(node: &'a serde_json::Value, id: &str) -> Option<&'a serde_json::Value> {
    match node {
        serde_json::Value::Array(xs) => xs.iter().find_map(|x| find_menu_item(x, id)),
        serde_json::Value::Object(m) => {
            if m.get("id").and_then(serde_json::Value::as_str) == Some(id) && m.contains_key("action") {
                return Some(node);
            }
            m.values().find_map(|v| find_menu_item(v, id))
        }
        _ => None,
    }
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
    // The spec first: the engine seeds a store scope for a panel it assembles,
    // and must never seed one for an id the workspace does not hold.
    let Some(ws) = Workspace::load() else {
        return JasBytes::empty();
    };
    let Some(spec) = ws.panel(id) else {
        return JasBytes::empty();
    };
    let ctx: serde_json::Value = if ctx_len == 0 {
        // NULL, not empty: the engine assembles it. See the note above.
        let Some(engine) = (unsafe { e.as_ref() }) else {
            return JasBytes::empty();
        };
        panel_ctx(engine, &ws, id)
    } else {
        match unsafe { utf8(ctx_json, ctx_len) }.ok().and_then(|t| serde_json::from_str(t).ok()) {
            Some(v) => v,
            None => return JasBytes::empty(),
        }
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
        // ⭐ ROW EK: the ONE crate-level counter lock. This test reaches an
        // export, and every export records a crossing on the process-global
        // counters -- so it races `ffi_instr`'s tests unless it takes this.
        let _counters = crate::ffi_instr::test_lock::lock();
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
        // ⭐ ROW EK: the ONE crate-level counter lock. This test reaches an
        // export, and every export records a crossing on the process-global
        // counters -- so it races `ffi_instr`'s tests unless it takes this.
        let _counters = crate::ffi_instr::test_lock::lock();
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
        // ⭐ ROW EK: the ONE crate-level counter lock. This test reaches an
        // export, and every export records a crossing on the process-global
        // counters -- so it races `ffi_instr`'s tests unless it takes this.
        let _counters = crate::ffi_instr::test_lock::lock();
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
        // ⭐ ROW EK: the ONE crate-level counter lock. This test reaches an
        // export, and every export records a crossing on the process-global
        // counters -- so it races `ffi_instr`'s tests unless it takes this.
        let _counters = crate::ffi_instr::test_lock::lock();
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

    // -----------------------------------------------------------------------
    // W2-2 — THE PANEL PLAN (wave-2 design, A5; observables Q1-Q3)
    //
    // ⛔ RED FIRST: written before `jas_panel_plan` existed, and seen to fail to
    // compile on the unresolved symbol, then to fail at runtime on a stub.
    // -----------------------------------------------------------------------

    fn plan_of(e: *mut JasEngine, panel: &str, w: i64, h: i64) -> String {
        take(unsafe { jas_panel_plan(e, panel.as_ptr(), panel.len(), w, h) })
    }

    const PLAN_SIZES: [(i64, i64); 3] = [(228, 0), (228, 600), (0, 0)];

    /// The panel files' own `id:` and `summary:` lines, read from the YAML
    /// SOURCE with a line reader: a second method beside the compiled bundle
    /// `jas_panel_list` reads. Only column-0 keys count, so a widget's nested
    /// `id:` is never taken for the panel's.
    fn panel_files() -> std::collections::BTreeMap<String, Option<String>> {
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../workspace/panels");
        let mut out = std::collections::BTreeMap::new();
        for entry in std::fs::read_dir(dir).expect("workspace/panels") {
            let path = entry.expect("a dir entry").path();
            if path.extension().and_then(|x| x.to_str()) != Some("yaml") {
                continue;
            }
            let text = std::fs::read_to_string(&path).expect("a panel file");
            let top = |key: &str| {
                text.lines()
                    .find_map(|l| l.strip_prefix(key))
                    .map(|v| v.trim().trim_matches('"').to_string())
            };
            let id = top("id:").unwrap_or_else(|| panic!("{} has no top-level id", path.display()));
            assert!(out.insert(id.clone(), top("summary:")).is_none(), "{id} is declared twice");
        }
        out
    }

    fn panel_list_rows() -> Vec<serde_json::Value> {
        let got = take(jas_panel_list());
        let v: serde_json::Value =
            serde_json::from_str(&got).unwrap_or_else(|_| panic!("not JSON: {got:?}"));
        v.as_array().unwrap_or_else(|| panic!("not an array: {got}")).clone()
    }

    /// **W2b-2 (a).** The list names every panel FILE in the workspace, once,
    /// with the summary that file declares, and in id order. The expectation
    /// is read from the YAML source, not from the bundle the export reads.
    #[test]
    fn panel_list_names_every_panel_file_with_its_summary() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let files = panel_files();
        let rows = panel_list_rows();
        // ⛔ ANTI-VACUITY FIRST: two empty sides agree perfectly.
        assert!(files.len() >= 10, "only {} panel files were read", files.len());
        let ids: Vec<&str> = rows.iter().map(|r| r["id"].as_str().expect("a string id")).collect();
        let mut sorted = ids.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(ids, sorted, "the list is not sorted by id with each id once");
        let got: std::collections::BTreeMap<String, Option<String>> = rows
            .iter()
            .map(|r| {
                let keys: Vec<&String> = r.as_object().expect("a row object").keys().collect();
                assert_eq!(keys, ["id", "summary"], "a row carries exactly id and summary: {r}");
                (r["id"].as_str().unwrap().to_string(), r["summary"].as_str().map(str::to_string))
            })
            .collect();
        assert_eq!(got, files);
        // The one summary that is not its panel's name, so a list that sent a
        // title-cased id would fail here and not only in the map comparison.
        assert_eq!(got["properties_panel_content"].as_deref(), Some("Object properties"));
    }

    /// **W2b-2 (b).** Every id the list offers is one the plan export opens,
    /// so a shell that shows the list never offers a panel it cannot draw.
    #[test]
    fn panel_list_ids_each_open_a_plan() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let rows = panel_list_rows();
        assert!(rows.len() >= 10, "vacuous: {} rows", rows.len());
        let e = jas_engine_new();
        for r in &rows {
            let id = r["id"].as_str().expect("a string id");
            let plan = plan_of(e, id, 228, 0);
            assert!(plan.contains("\"leaves\""), "{id}: the plan export refused it: {plan:?}");
        }
        unsafe { jas_engine_free(e) };
    }

    /// **W2b-2 (c).** No engine, one counted crossing, the reply's bytes on
    /// the ledger, nothing interpretable, and the same bytes after an edit.
    #[test]
    fn panel_list_counts_one_crossing_and_needs_no_session() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let before = crate::ffi_instr::read(Crossing::PanelList);
        let first = take(jas_panel_list());
        let after = crate::ffi_instr::read(Crossing::PanelList);
        assert!(!first.is_empty(), "the list refused");
        assert_eq!(after.0 - before.0, 1, "calls");
        assert_eq!(after.2 - before.2, first.len() as u64, "bytes_out");
        assert!(!first.contains("{{"), "a template crossed: {first}");

        let e = jas_engine_new();
        let op = r#"{"op":"create_artboard","id":"ab_w2b2"}"#;
        assert_eq!(unsafe { jas_dispatch_event(e, op.as_ptr(), op.len()) }, JasStatus::Ok);
        let second = take(jas_panel_list());
        unsafe { jas_engine_free(e) };
        assert_eq!(first, second, "the list moved with a document edit");
    }

    /// **Q1 through the ABI.** For EVERY panel the compiled workspace carries
    /// (derived, never pinned), at three sizes, every `(path, rect)` the plan
    /// carries is `layout_panel`'s at that path, byte for byte, in the scope the
    /// engine assembles; and every `render_plan` leaf appears.
    #[test]
    fn panel_plan_rects_equal_layout_panel_on_every_panel() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let engine = unsafe { e.as_ref() }.unwrap();
        let ws = crate::interpreter::workspace::Workspace::load().unwrap();
        let panels: Vec<String> = ws.panels().as_object().unwrap().keys().cloned().collect();
        let (mut compared, mut leaves) = (0usize, 0usize);
        for pid in &panels {
            let spec = ws.panel(pid).unwrap();
            for (w, h) in PLAN_SIZES {
                let got = plan_of(e, pid, w, h);
                let plan: serde_json::Value = serde_json::from_str(&got)
                    .unwrap_or_else(|_| panic!("{pid} {w}x{h}: not JSON: {got:?}"));
                let ctx = panel_ctx(engine, &ws, pid);
                // Laid out as the plan lays it out: a group whose dynamic
                // visibility resolved false is not placed.
                let rows = crate::interpreter::bind_values::bind_values(spec, &ctx);
                let (pruned, _) = crate::panel_plan::checks::shown(spec, &rows);
                let layout = crate::interpreter::panel_layout::layout_panel(&pruned, w, h, &ctx);
                let rp = crate::interpreter::panel_layout::render_plan(&pruned, w, h, &ctx);
                compared += crate::panel_plan::checks::plan_matches_layout(&plan, &layout, &rp)
                    .unwrap_or_else(|err| panic!("{pid} {w}x{h}: {err}"));
                leaves += rp.leaves.len();
            }
        }
        assert!(!panels.is_empty() && leaves > 0 && compared >= leaves,
            "vacuous: panels={} leaves={leaves} compared={compared}", panels.len());
        unsafe { jas_engine_free(e) };
    }

    /// **Q2 through the ABI.** No plan, for any panel, carries `{{`, a `node`, a
    /// `behavior`, a `bind` map or a `ctx`. The shell evaluates nothing.
    #[test]
    fn panel_plan_carries_nothing_interpretable_on_every_panel() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let ws = crate::interpreter::workspace::Workspace::load().unwrap();
        let panels: Vec<String> = ws.panels().as_object().unwrap().keys().cloned().collect();
        let mut bytes = 0usize;
        for pid in &panels {
            for (w, h) in PLAN_SIZES {
                let got = plan_of(e, pid, w, h);
                assert!(got.contains("\"leaves\""), "{pid} {w}x{h}: not a plan: {got:?}");
                crate::panel_plan::checks::nothing_interpretable(&got)
                    .unwrap_or_else(|err| panic!("{pid} {w}x{h}: {err}"));
                bytes += got.len();
            }
        }
        assert!(!panels.is_empty() && bytes > 0, "vacuous");
        unsafe { jas_engine_free(e) };
    }

    /// **Q3 through the ABI.** The engine's own colour is the S-C seed, so the
    /// plan's values equal `jas_bind_values`' rows there. After a tick to
    /// `664141` they are equal again, and the set of values that moved in the
    /// plan is the set of rows that moved in `jas_bind_values`, `cp_hex` among
    /// them. (Through the engine the eleven channels are DERIVED from the colour,
    /// so more than one row moves; the exactly-one claim is made on the pin's own
    /// scope in `panel_plan::tests`.)
    /// THE COLOUR BAR'S PICTURE THROUGH THE ABI (STATUS-flask §249): the
    /// engine's Color panel plan places exactly one `color_bar` leaf, with a
    /// real rect, carrying `display.picture` — the picture whose every pixel is
    /// the pick's `color_bar_rgb` — so the shell draws the bar the engine picks
    /// from.
    #[test]
    fn the_color_panels_bar_carries_the_engines_picture_through_the_abi() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let plan: serde_json::Value =
            serde_json::from_str(&plan_of(e, "color_panel_content", 228, 600)).expect("plan JSON");
        let bars: Vec<&serde_json::Value> = plan["leaves"].as_array().expect("leaves").iter()
            .filter(|l| l["type"] == "color_bar").collect();
        assert_eq!(bars.len(), 1, "one colour bar placed: {plan}");
        assert!(bars[0]["rect"]["w"].as_i64().unwrap_or(0) > 0, "{}", bars[0]["rect"]);
        assert!(bars[0]["rect"]["h"].as_i64().unwrap_or(0) > 0, "{}", bars[0]["rect"]);
        assert_eq!(
            bars[0]["display"]["picture"].as_str(),
            Some(crate::color_bar_picture::data_uri().as_str()),
        );
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn panel_plan_values_equal_bind_values_through_the_abi() {
        use crate::panel_plan::checks::{plan_values, row_values};
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let id = "color_panel_content";
        let read = |e| {
            let plan: serde_json::Value =
                serde_json::from_str(&plan_of(e, id, 228, 600)).expect("plan JSON");
            let rows: serde_json::Value = serde_json::from_str(&take(unsafe {
                jas_bind_values(e, id.as_ptr(), id.len())
            }))
            .expect("rows JSON");
            let (values, n) = plan_values(&plan);
            // A hidden group's rows are not placed (`checks::shown`).
            let ws = crate::interpreter::workspace::Workspace::load().unwrap();
            let want = row_values(&crate::panel_plan::checks::shown(ws.panel(id).unwrap(), &rows).1);
            assert!(n > 0, "vacuous: nothing joined");
            assert_eq!(n, want.len(), "every row joined exactly once");
            assert_eq!(values, want, "plan values != jas_bind_values rows");
            values
        };

        let a = read(e);
        let hex_key = a
            .iter()
            .find(|(k, v)| k.ends_with("|bind.value") && v.as_str() == "ffffff")
            .map(|(k, _)| k.clone())
            .expect("the engine's seed displays the spec's ffffff");

        let ev = r#"{"widget":"cp_hex","value":"664141"}"#;
        let _ = take(unsafe { jas_panel_event(e, id.as_ptr(), id.len(), ev.as_ptr(), ev.len()) });
        let b = read(e);
        assert_eq!(b.get(&hex_key).map(String::as_str), Some("664141"), "cp_hex moved");

        let moved: std::collections::BTreeSet<&String> =
            a.keys().filter(|k| a.get(*k) != b.get(*k)).collect();
        assert!(moved.contains(&hex_key), "{moved:?}");
        assert!(moved.len() < a.len(), "a tick moved every value: {moved:?}");
        unsafe { jas_engine_free(e) };
    }

    /// Reading a panel's PLAN enrols it, exactly as reading its values does:
    /// a shell that opens a panel through the plan alone must still be sent the
    /// rows a tick moves. The control is an engine that opened nothing.
    #[test]
    fn panel_plan_enrols_the_panel_for_ticks() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let id = "color_panel_content";
        let ev = r#"{"widget":"cp_hex","value":"664141"}"#;
        let tick = |e| take(unsafe {
            jas_panel_event(e, id.as_ptr(), id.len(), ev.as_ptr(), ev.len())
        });

        let control = jas_engine_new();
        assert_eq!(tick(control), "[]", "control: nothing open, nothing sent");
        unsafe { jas_engine_free(control) };

        let e = jas_engine_new();
        let _ = plan_of(e, id, 228, 0);
        let delta = tick(e);
        assert!(delta.contains("\"cp_hex\""), "a plan-opened panel must receive the tick: {delta}");
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn panel_plan_refuses_as_the_empty_span() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let id = "color_panel_content";
        let b = unsafe { jas_panel_plan(std::ptr::null_mut(), id.as_ptr(), id.len(), 228, 0) };
        assert!(b.ptr.is_null() && b.len == 0, "null handle");
        let e = jas_engine_new();
        assert_eq!(plan_of(e, "no_such_panel", 228, 0), "", "unknown panel");
        let bad = [0xff_u8, 0xfe];
        let b = unsafe { jas_panel_plan(e, bad.as_ptr(), bad.len(), 228, 0) };
        assert!(b.ptr.is_null() && b.len == 0, "bad UTF-8");
        // The control: the same engine answers a real panel.
        assert!(plan_of(e, id, 228, 0).contains("\"leaves\""));
        unsafe { jas_engine_free(e) };
    }

    /// **W2b-15 through the ABI.** The Brushes and Swatches panels draw their
    /// open libraries from `data.brush_libraries` / `data.swatch_libraries`,
    /// which the web loads from the workspace bundle. Before it the engine's
    /// store held no data, so a library header's label resolved to `""` and it
    /// drew no tiles. The expected names come from the bundle, never typed here.
    #[test]
    fn the_library_panels_draw_the_bundles_libraries() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let ws = crate::interpreter::workspace::Workspace::load().unwrap();
        let e = jas_engine_new();
        for (panel, key, items) in [("brushes_panel_content", "brush_libraries", "brushes"),
                                    ("swatches_panel_content", "swatch_libraries", "swatches")] {
            let plan = plan_of(e, panel, 228, 600);
            let libs = ws.data()[key].as_object().expect("the bundle has libraries");
            let lib = libs.values().next().expect("at least one library");
            let lib_name = lib["name"].as_str().expect("a library name");
            assert!(plan.contains(&format!("\"{lib_name}\"")), "{panel}: no {lib_name}: {plan}");
            // A tile is a thumbnail with a templated id and no text, so count
            // the records that carry the tile's own binding, one per item.
            let v: serde_json::Value = serde_json::from_str(&plan).expect("plan JSON");
            let tiles = ["chrome", "containers", "leaves"].iter()
                .filter_map(|k| v[*k].as_array()).flatten()
                .filter(|r| r["values"].get("bind.selected_in").is_some())
                .count();
            let want = lib[items].as_array().expect("an item list").len();
            assert!(want > 1, "{panel}: a one-item library cannot tell one tile from many");
            assert_eq!(tiles, want, "{panel}: {tiles} tiles for {want} items");
        }
        unsafe { jas_engine_free(e) };
    }

    /// **W2b-15 through the ABI.** The Concepts panel's list is a `foreach` over
    /// `data.concepts`, so its plan draws one row per registered concept, with
    /// the concept's name. Before it the engine's scope had no `data` and the
    /// list drew 0 rows. The names come from the registry, never typed here.
    #[test]
    fn the_concepts_plan_draws_a_row_per_registered_concept() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let plan = plan_of(e, "concepts_panel_content", 228, 600);
        let registry = crate::interpreter::workspace::concepts_list();
        let names: Vec<&str> = registry.as_array().expect("a list")
            .iter().filter_map(|c| c["name"].as_str()).collect();
        assert_eq!(names.len(), 4, "the registry changed: {names:?}");
        for name in &names {
            assert!(plan.contains(&format!("\"{name}\"")), "{name} is not in the plan: {plan}");
        }
        unsafe { jas_engine_free(e) };
    }

    /// **W2-5a through the ABI.** The export hands the plan the workspace's own
    /// icon definitions, so the align plan names `align_left` and carries its
    /// definition; the pure arms in `panel_plan` cover the rest.
    #[test]
    fn panel_plan_carries_display_text_and_icons_through_the_abi() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let plan: serde_json::Value =
            serde_json::from_str(&plan_of(e, "align_panel_content", 228, 0)).expect("plan JSON");
        let ws = crate::interpreter::workspace::Workspace::load().unwrap();
        assert_eq!(plan["leaves"][1]["id"], "align_left_button", "{plan}");
        assert_eq!(plan["leaves"][1]["static"]["icon"], "align_left", "{plan}");
        assert_eq!(plan["icons"]["align_left"]["svg"], ws.icons()["align_left"]["svg"]);
        assert_eq!(plan["icons_missing"], serde_json::json!([]), "{plan}");
        unsafe { jas_engine_free(e) };
    }

    // -----------------------------------------------------------------------
    // jas_panel_behavior -- wave 2, A6: a click runs the widget's behavior in
    // the engine, or is refused by name before any effect of it runs.
    // -----------------------------------------------------------------------

    const ALIGN: &str = "align_panel_content";
    const BOOLEAN: &str = "boolean_panel_content";

    /// The first node with id `id` in a panel spec, pre-order.
    fn checks_node<'a>(node: &'a serde_json::Value, id: &str) -> &'a serde_json::Value {
        fn walk<'a>(n: &'a serde_json::Value, id: &str) -> Option<&'a serde_json::Value> {
            if n.get("id").and_then(|v| v.as_str()) == Some(id) {
                return Some(n);
            }
            match n {
                serde_json::Value::Object(m) => m.values().find_map(|c| walk(c, id)),
                serde_json::Value::Array(a) => a.iter().find_map(|c| walk(c, id)),
                _ => None,
            }
        }
        walk(node, id).unwrap_or_else(|| panic!("no node {id}"))
    }

    /// **§1.2 (a) through the ABI.** The Layers type filter's plan leaf carries
    /// its declared items in order, and a toggle item's `checked` follows
    /// `panel.type_filter` through a real pick at the engine door, as does
    /// the "All" row's in-force check. `ITEMS-AFTER` is the WinUI reader's
    /// fixture (`sb_winui_tests`), printed so it is copied, never typed. The labels,
    /// values and order are read from the compiled workspace, never typed.
    #[test]
    fn the_layers_filter_plan_carries_its_items_and_their_checks() {
        let _counters = crate::ffi_instr::test_lock::lock();
        const P: &str = "layers_panel_content";
        let ws = crate::interpreter::workspace::Workspace::load().unwrap();
        let declared: Vec<serde_json::Value> = checks_node(ws.panel(P).unwrap(), "lp_filter_button")["items"]
            .as_array().expect("the filter declares items").clone();
        let e = jas_engine_new();
        let items = |e| leaf(e, P, "lp_filter_button")["items"].as_array().cloned().expect("items");
        let before = items(e);
        assert_eq!(before.len(), declared.len(), "one row per declared item: {before:?}");
        for (row, item) in before.iter().zip(&declared) {
            assert_eq!(row["kind"], item["type"], "{row}");
            assert_eq!(row["value"], item["value"]);
            assert_eq!(row["label"], item["label"]);
        }
        let toggles: Vec<&serde_json::Value> = before.iter().filter(|r| r["kind"] == "toggle").collect();
        assert!(toggles.len() > 2, "fixture: {toggles:?}");
        assert!(toggles.iter().all(|r| r["checked"] == false), "the default filter checks nothing: {toggles:?}");
        // "All" is IN FORCE while nothing is checked: running it would change
        // nothing (WIDGET_EVENTS.md, "Showing an item's check").
        let all_in_force = |rows: &[serde_json::Value]| -> Vec<serde_json::Value> {
            rows.iter().filter(|r| r["kind"] == "action").map(|r| r["checked"].clone()).collect()
        };
        assert_eq!(all_in_force(&before), vec![serde_json::json!(true)], "{before:?}");

        let pick = toggles[2]["value"].as_str().unwrap().to_string();
        let ev = format!(r#"{{"widget":"lp_filter_button","event":"toggle","value":"{pick}"}}"#);
        let (reply, err) = behave(e, P, &ev);
        assert!(!reply.is_empty(), "the pick was refused: {err}");
        let after = items(e);
        let checked: Vec<&str> = after.iter().filter(|r| r["checked"] == true)
            .map(|r| r["value"].as_str().unwrap()).collect();
        assert_eq!(checked, vec![pick.as_str()]);
        assert_eq!(all_in_force(&after), vec![serde_json::json!(false)], "{after:?}");
        println!("ITEMS-AFTER {}", serde_json::Value::Array(after.clone()));
        assert_eq!(engine_of(e).store.borrow().get_panel(P, "type_filter"), &serde_json::json!([pick]));
        unsafe { jas_engine_free(e) };
    }

    /// **A library swatch is tapped by its plan path** (STATUS-flask §114: 216
    /// of 228 tiles drew and sent nothing, because the library template has no
    /// id). The door ran the tile's `select` and refused it `UnknownEffect`;
    /// with `select` hosted, the click's action `set_active_color` wrote the
    /// STORE's copy of `state.fill_color` while every scope reads the colour
    /// SLICE, so the tap reported success and the active colour did not move.
    /// Every expectation is read from the plan or the store, never typed.
    #[test]
    fn a_library_swatch_tap_selects_it_and_makes_its_colour_active() {
        let _counters = crate::ffi_instr::test_lock::lock();
        const P: &str = "swatches_panel_content";
        let e = jas_engine_new();
        let tiles = |e| -> Vec<serde_json::Value> {
            let plan: serde_json::Value = serde_json::from_str(&plan_of(e, P, 228, 600)).unwrap();
            ["chrome", "containers", "leaves"].iter()
                .filter_map(|k| plan[*k].as_array()).flatten()
                .filter(|r| r["type"] == "color_swatch" && r["values"].get("bind.selected_in").is_some())
                .cloned().collect()
        };
        let before = tiles(e);
        assert!(before.len() > 4, "fixture: too few library tiles: {}", before.len());
        let k = 3usize;
        let tile = &before[k];
        assert_eq!(tile["id"], "", "fixture: a library tile has no id, which is the point");
        assert_eq!(tile["path"].as_array().and_then(|p| p.last()), Some(&serde_json::json!(k)),
                   "fixture: the tile's last path index is its row: {tile}");
        let colour = tile["values"]["bind.color"].as_str().expect("the tile's colour").to_string();
        let slice_before = engine_of(e).panel.borrow().effective(&engine_of(e).model.borrow()).state_keys();
        assert_ne!(slice_before["fill_color"], colour.as_str(), "fixture: the tap must be able to move the fill");
        let lib = engine_of(e).store.borrow().get_panel(P, "open_libraries")[0]["id"].clone();
        assert!(lib.is_string(), "fixture: an open library: {lib}");

        let ev = format!(r#"{{"widget":"","path":{},"event":"click"}}"#, tile["path"]);
        let (reply, err) = behave(e, P, &ev);
        assert!(!reply.is_empty(), "the tap was refused: {err}");
        {
            let store = engine_of(e).store.borrow();
            assert_eq!(store.get_panel(P, "selected_swatches"), &serde_json::json!([k]));
            assert_eq!(store.get_panel(P, "selected_library"), &lib);
        }
        // The recent colour is the DOCUMENT's (`active_document.recent_colors`),
        // held on the model; until 2026-10-12 it landed in this panel's scope.
        assert_eq!(engine_of(e).model.borrow().recent_colors.first().map(String::as_str), Some(colour.as_str()));
        // The colour as SHOWN (`effective`), which every scope reads, and the
        // store's copy agree on it.
        let slice_after = engine_of(e).panel.borrow().effective(&engine_of(e).model.borrow()).state_keys();
        assert_eq!(slice_after["fill_color"], colour.as_str(), "the active colour did not move");
        assert_eq!(slice_after["stroke_color"], slice_before["stroke_color"]);
        assert_eq!(engine_of(e).store.borrow().get("fill_color"), &slice_after["fill_color"]);
        // And the next plan shows it: the tile is selected, the first recent is it.
        let after = tiles(e);
        assert!(after[k]["values"]["bind.selected_in"].as_str().unwrap_or("").contains(&k.to_string()),
                "{}", after[k]);
        assert_eq!(leaf(e, P, "sp_recent_0")["values"]["bind.color"], colour.as_str());

        // The negative control: a row past the library's end is refused by name.
        let mut past = tile["path"].clone();
        let last = past.as_array().unwrap().len() - 1;
        past[last] = serde_json::json!(before.len() + 100);
        let (reply, err) = behave(e, P, &format!(r#"{{"widget":"","path":{past},"event":"click"}}"#));
        assert!(reply.is_empty() && err.contains("NoRow"), "{err}");
        unsafe { jas_engine_free(e) };
    }

    const LEFT: &str = r#"{"widget":"align_left_button","event":"click"}"#;

    /// An engine whose document is `model`.
    fn engine_with(model: Model) -> *mut JasEngine {
        let e = jas_engine_new();
        unsafe { e.as_ref() }.unwrap().with_model_mut(|m| *m = model);
        e
    }

    /// STATUS-jas item 23. A param field is a `number_input` a `foreach`
    /// stamps out, so it has NO id; the shell can address it only by its plan
    /// path. A `commit` sent by that path runs the field's behavior with the
    /// row's item in scope (`p.name`), so the shell's address is the whole
    /// remaining gap (the field is read-only on Windows, flask §563 finding I).
    #[test]
    fn a_template_param_field_commits_by_its_plan_path() {
        let _counters = crate::ffi_instr::test_lock::lock();
        const CONCEPTS: &str = "concepts_panel_content";
        let e = engine_with(crate::document::test_fixture::model_with(vec![], &[]));
        {
            let en = unsafe { e.as_ref() }.unwrap();
            let mut store = en.store.borrow_mut();
            if store.panel_scope("concepts").is_none() {
                store.init_panel("concepts", std::collections::HashMap::new());
            }
            store.set_panel("concepts", "selected_concept", serde_json::json!("star"));
        }
        let (reply, err) = behave(e, CONCEPTS, r#"{"widget":"concept_place","event":"click"}"#);
        assert!(reply.contains(r#""doc_changed":true"#), "the control: a placed, selected star: {reply} {err}");
        let plan: serde_json::Value = serde_json::from_str(&plan_of(e, CONCEPTS, 228, 600)).expect("plan JSON");
        let inputs: Vec<&serde_json::Value> = plan["leaves"].as_array().expect("leaves").iter()
            .filter(|l| l["type"] == "number_input").collect();
        assert_eq!(inputs.len(), 3, "one field per star param: {inputs:?}");
        let first = inputs[0];
        assert!(first.get("id").and_then(|v| v.as_str()).unwrap_or("").is_empty(), "the field has no id: {first}");
        let path = first["path"].clone();
        assert!(path.is_array(), "it has a plan path: {first}");
        let points = |e: *mut JasEngine| {
            let en = unsafe { e.as_ref() }.unwrap();
            let doc = en.model.borrow().document().clone();
            match &*doc.layers[0].children().unwrap()[0] {
                crate::geometry::element::Element::Live(crate::geometry::live::LiveVariant::Generated(g)) => g.params.clone(),
                other => panic!("not a generated instance: {other:?}"),
            }
        };
        let before = points(e);
        // The bytes the Windows shell sends for an id-less field
        // (`PanelWire.EventJson("", "commit", text, …, path)`).
        let ev = serde_json::json!({
            "widget": "", "event": "commit", "value": "8",
            "alt": false, "shift": false, "ctrl": false, "meta": false, "path": path,
        }).to_string();
        let (_reply, err) = behave(e, CONCEPTS, &ev);
        let after = points(e);
        let changed: Vec<&String> = after.as_object().unwrap().iter()
            .filter(|(k, v)| before.get(k.as_str()) != Some(*v)).map(|(k, _)| k).collect();
        assert_eq!(changed.len(), 1, "exactly the row's param is set: {before} -> {after} ({err})");
        assert_eq!(after[changed[0].as_str()].as_f64(), Some(8.0), "to the committed value");
        unsafe { jas_engine_free(e) };
    }

    /// STATUS-jas item 22. The Layers panel's actions run their YAML in the
    /// engine: each `doc.*` verb they use (`create_layer insert_at insert_after
    /// clone_at delete_at set unpack_group_at wrap_in_group wrap_in_layer`) and
    /// the `as:` binding two of them return through are the shared runner's.
    /// Until 2026-10-26 they lived only in the web's runner and the engine
    /// refused every one (`UnknownDocEffect:doc.create_layer`). Each action
    /// changes the document as stated, and ONE undo restores it.
    #[test]
    fn the_layers_panel_actions_run_their_yaml_in_the_engine() {
        let _counters = crate::ffi_instr::test_lock::lock();
        use crate::document::test_fixture::{model_with, rect};
        use crate::geometry::element::{Element, Visibility};
        const LAYERS: &str = "layers_panel_content";
        let layers = |e: *mut JasEngine| unsafe { e.as_ref() }.unwrap().model.borrow().document().layers.clone();
        let kids = |e: *mut JasEngine, i: usize| layers(e)[i].children().map(|c| c.to_vec()).unwrap_or_default();
        let select = |e: *mut JasEngine, paths: &[&[usize]]| {
            let en = unsafe { e.as_ref() }.unwrap();
            let mut store = en.store.borrow_mut();
            if store.panel_scope("layers").is_none() {
                store.init_panel("layers", std::collections::HashMap::new());
            }
            let v: Vec<serde_json::Value> = paths.iter().map(|p| serde_json::json!({"__path__": p})).collect();
            store.set_panel("layers", "layers_panel_selection", serde_json::Value::Array(v));
        };
        let run = |e: *mut JasEngine, action: &str, params: serde_json::Value| {
            let req = serde_json::json!({"panel": LAYERS, "action": action, "params": params}).to_string();
            let (_reply, err) = dispatch(e, &req);
            assert!(!err.contains("Unknown"), "{action}: {err}");
        };
        let undo = |e: *mut JasEngine| unsafe { e.as_ref() }.unwrap().model.borrow_mut().undo();
        let fresh = || {
            let e = engine_with(model_with(vec![rect(0.0, 0.0, 10.0, 10.0)], &[]));
            e
        };

        // New Layer: a layer named by `next_layer_name`, one undo.
        let e = fresh();
        let before = layers(e);
        run(e, "new_layer", serde_json::json!({}));
        assert_eq!(layers(e).len(), before.len() + 1, "new_layer adds a layer");
        undo(e);
        assert_eq!(layers(e), before, "new_layer: one undo");

        // New Group, then Flatten Artwork back.
        select(e, &[&[0, 0]]);
        run(e, "new_group", serde_json::json!({}));
        assert!(matches!(&*kids(e, 0)[0], Element::Group(_)), "new_group wraps the selection");
        select(e, &[&[0, 0]]);
        run(e, "flatten_artwork", serde_json::json!({}));
        assert!(matches!(&*kids(e, 0)[0], Element::Rect(_)), "flatten_artwork unpacks the group");
        undo(e);
        assert!(matches!(&*kids(e, 0)[0], Element::Group(_)), "flatten_artwork: one undo");
        undo(e);
        assert_eq!(layers(e), before, "new_group: one undo");

        // Duplicate and Delete.
        select(e, &[&[0, 0]]);
        run(e, "duplicate_layer_selection", serde_json::json!({}));
        assert_eq!(kids(e, 0).len(), 2, "duplicate_layer_selection adds a copy");
        undo(e);
        assert_eq!(layers(e), before, "duplicate: one undo");
        select(e, &[&[0, 0]]);
        run(e, "delete_layer_selection", serde_json::json!({}));
        assert_eq!(kids(e, 0).len(), 0, "delete_layer_selection removes it");
        undo(e);
        assert_eq!(layers(e), before, "delete: one undo");

        // Collect in New Layer.
        select(e, &[&[0, 0]]);
        run(e, "collect_in_new_layer", serde_json::json!({}));
        assert_eq!(layers(e).len(), 2, "collect_in_new_layer adds a layer");
        assert_eq!(kids(e, 0).len(), 0, "and moves the selection into it");
        undo(e);
        assert_eq!(layers(e), before, "collect: one undo");

        // The three toggle-all actions.
        run(e, "toggle_all_layers_lock", serde_json::json!({}));
        assert!(layers(e)[0].common().locked, "toggle_all_layers_lock locks");
        undo(e);
        run(e, "toggle_all_layers_visibility", serde_json::json!({}));
        assert_eq!(layers(e)[0].common().visibility, Visibility::Invisible, "toggle_all_layers_visibility hides");
        undo(e);
        run(e, "toggle_all_layers_outline", serde_json::json!({}));
        assert_eq!(layers(e)[0].common().visibility, Visibility::Outline, "toggle_all_layers_outline outlines");
        undo(e);
        assert_eq!(layers(e), before, "the toggles: one undo each");

        // Layer Options OK with no layer: a new named layer.
        run(e, "layer_options_confirm",
            serde_json::json!({"layer_id": null, "name": "Inks", "show": true, "preview": true, "lock": true}));
        let ls = layers(e);
        assert_eq!(ls.len(), 2, "layer_options_confirm adds a layer");
        assert!(ls.iter().any(|l| l.common().name.as_deref() == Some("Inks") && l.common().locked),
            "named and locked as the dialog said: {ls:?}");
        undo(e);
        assert_eq!(layers(e), before, "layer options: one undo");
        unsafe { jas_engine_free(e) };
    }

    /// A Concepts-panel operation button runs its YAML in the engine
    /// (`doc.apply_concept_operation`): `add_side` on the selected
    /// regular_polygon (sides 5) writes sides 6, ONE undo; `remove_side` on a
    /// triangle clamps at 3 (`max(param.sides - 1, 3)` reads the CURRENT
    /// params); an unknown operation: nothing.
    #[test]
    fn apply_concept_operation_runs_its_yaml_in_the_engine() {
        let _counters = crate::ffi_instr::test_lock::lock();
        use crate::geometry::element::{CommonProps, Element};
        use crate::geometry::live::{GeneratedElem, LiveVariant};
        let instance = |sides: f64| Element::Live(LiveVariant::Generated(GeneratedElem::new(
            "regular_polygon".into(),
            serde_json::json!({"sides": sides, "radius": 40.0}),
            CommonProps::default(),
        )));
        let sides = |e: *mut JasEngine| {
            let en = unsafe { e.as_ref() }.unwrap();
            let doc = en.model.borrow().document().clone();
            match &*doc.layers[0].children().unwrap()[0] {
                Element::Live(LiveVariant::Generated(g)) => (g.params["sides"].as_f64(), g.params["radius"].as_f64()),
                other => panic!("not a generated instance: {other:?}"),
            }
        };
        let req = |op: &str| format!(r#"{{"action":"apply_concept_operation","params":{{"op_id":"{op}"}}}}"#);

        let e = engine_with(crate::document::test_fixture::model_with(vec![instance(5.0)], &[0]));
        let (_reply, err) = dispatch(e, &req("add_side"));
        assert_eq!(sides(e), (Some(6.0), Some(40.0)), "add_side ({err})");
        unsafe { e.as_ref() }.unwrap().model.borrow_mut().undo();
        assert_eq!(sides(e), (Some(5.0), Some(40.0)), "one undo");
        let _ = dispatch(e, &req("no_such_operation"));
        assert_eq!(sides(e), (Some(5.0), Some(40.0)), "an unknown operation: nothing");
        unsafe { jas_engine_free(e) };

        let tri = engine_with(crate::document::test_fixture::model_with(vec![instance(3.0)], &[0]));
        let _ = dispatch(tri, &req("remove_side"));
        assert_eq!(sides(tri), (Some(3.0), Some(40.0)), "remove_side clamps at 3");
        unsafe { jas_engine_free(tri) };

        // An operation that changes nothing records nothing: from 4, Remove
        // Side gives 3, a second one is a no-op, and ONE Undo gives 4 back
        // (flask STATUS § 568; an empty step would leave it at 3).
        let quad = engine_with(crate::document::test_fixture::model_with(vec![instance(4.0)], &[0]));
        let _ = dispatch(quad, &req("remove_side"));
        let journal = unsafe { quad.as_ref() }.unwrap().model.borrow().journal().len();
        let (reply, err) = dispatch(quad, &req("remove_side"));
        assert!(reply.contains(r#""doc_changed":false"#), "a no-op does not report a change: {reply} {err}");
        assert_eq!(sides(quad), (Some(3.0), Some(40.0)));
        assert_eq!(unsafe { quad.as_ref() }.unwrap().model.borrow().journal().len(), journal, "a no-op journals nothing");
        unsafe { quad.as_ref() }.unwrap().model.borrow_mut().undo();
        assert_eq!(sides(quad), (Some(4.0), Some(40.0)), "ONE undo undoes the last REAL change");
        unsafe { jas_engine_free(quad) };
    }

    /// The fill/stroke widget's Gradient button runs its YAML in the engine
    /// (`set_fill_type_gradient` -> `doc.promote_to_gradient`, GRADIENT.md
    /// §Fill-type coupling): each selected member without a gradient takes its
    /// OWN seed (red -> `[red, white]`, none -> `[black, white]`), a member
    /// holding one keeps it, the solid fill stays; ONE undo. A second click
    /// has nothing to promote: it journals nothing and reads `Unchanged`.
    #[test]
    fn set_fill_type_gradient_promotes_each_member_in_the_engine() {
        let _counters = crate::ffi_instr::test_lock::lock();
        use crate::geometry::element::{Color, CommonProps, Element, Fill, Gradient, RectElem};
        use crate::interpreter::gradient_host::seed_gradient;
        let red = Color::rgb(1.0, 0.0, 0.0);
        let rect = |fill: Option<Color>, g: Option<Gradient>| Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: fill.map(Fill::new), stroke: None, common: CommonProps::default(),
            fill_gradient: g.map(Box::new), stroke_gradient: None,
        });
        let held = Gradient { angle: 30.0, ..seed_gradient(Some(Color::rgb(0.0, 0.0, 1.0))) };
        let e = engine_with(crate::document::test_fixture::model_with(
            vec![rect(Some(red), None), rect(None, None), rect(Some(red), Some(held.clone()))], &[0, 1, 2]));
        let kids = |e: *mut JasEngine| {
            let en = unsafe { e.as_ref() }.unwrap();
            let doc = en.model.borrow().document().clone();
            doc.layers[0].children().unwrap().iter().map(|c| (**c).clone()).collect::<Vec<_>>()
        };
        let before = kids(e);
        let req = r#"{"action":"set_fill_type_gradient"}"#;
        let (_reply, err) = dispatch(e, req);
        let after = kids(e);
        assert_eq!(after[0].fill_gradient(), Some(&seed_gradient(Some(red))), "red promotes from red ({err})");
        assert_eq!(after[0].fill(), before[0].fill(), "the solid fill stays: the demote target");
        assert_eq!(after[1].fill_gradient(), Some(&seed_gradient(None)), "none promotes from black");
        assert_eq!(after[2].fill_gradient(), Some(&held), "a held gradient is kept");
        let journal = unsafe { e.as_ref() }.unwrap().model.borrow().journal().len();
        let (_reply, err) = dispatch(e, req);
        assert!(err.contains("Unchanged"), "nothing left to promote reads Unchanged: {err}");
        assert_eq!(unsafe { e.as_ref() }.unwrap().model.borrow().journal().len(), journal, "and journals nothing");
        unsafe { e.as_ref() }.unwrap().model.borrow_mut().undo();
        assert_eq!(kids(e), before, "one undo");
        unsafe { jas_engine_free(e) };
    }

    /// The fill/stroke widget's Color button demotes in the engine
    /// (`set_fill_type_solid` -> `doc.demote_to_solid`, then its null guard,
    /// GRADIENT.md §Demotion to solid): a gradient's FIRST stop becomes the
    /// solid and the gradient goes, the fill's opacity kept; ONE undo. The
    /// YAML's KNOWN LIMIT is pinned too: a member with NO solid under its
    /// gradient ends black, the null guard's, because the guard reads the
    /// colour from before the click and runs after the demote. Swift agrees;
    /// the other order would split the two ports (the §3.6 delta).
    #[test]
    fn set_fill_type_solid_demotes_a_gradient_in_the_engine() {
        let _counters = crate::ffi_instr::test_lock::lock();
        use crate::geometry::element::{Color, CommonProps, Element, Fill, Gradient, RectElem};
        let (red, green, blue) = (Color::rgb(1.0, 0.0, 0.0), Color::rgb(0.0, 1.0, 0.0), Color::rgb(0.0, 0.0, 1.0));
        let rect = |fill: Option<Fill>, g: Color| Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill, stroke: None, common: CommonProps::default(),
            fill_gradient: Some(Box::new(Gradient::seed(Some(g)))), stroke_gradient: None,
        });
        let first = |e: *mut JasEngine| {
            let en = unsafe { e.as_ref() }.unwrap();
            let doc = en.model.borrow().document().clone();
            (*doc.layers[0].children().unwrap()[0]).clone()
        };
        let req = r#"{"action":"set_fill_type_solid"}"#;

        let e = engine_with(crate::document::test_fixture::model_with(
            vec![rect(Some(Fill { color: red, opacity: 0.5 }), green)], &[0]));
        let before = first(e);
        let (_reply, err) = dispatch(e, req);
        assert_eq!(first(e).fill_gradient(), None, "the gradient goes ({err})");
        assert_eq!(first(e).fill(), Some(&Fill { color: green, opacity: 0.5 }), "the first stop, opacity kept");
        unsafe { e.as_ref() }.unwrap().model.borrow_mut().undo();
        assert_eq!(first(e), before, "one undo");
        unsafe { jas_engine_free(e) };

        let bare = engine_with(crate::document::test_fixture::model_with(vec![rect(None, blue)], &[0]));
        let _ = dispatch(bare, req);
        assert_eq!(first(bare).fill_gradient(), None);
        assert_eq!(first(bare).fill().map(|f| f.color), Some(Color::BLACK),
                   "the KNOWN LIMIT: no solid under the gradient ends on the null guard's black");
        unsafe { jas_engine_free(bare) };
    }

    /// Object > Promote to Concept runs its YAML in the engine
    /// (`doc.promote_to_concept`): the selected square (the fitter corpus's
    /// `[4, 10, 100, 20, 0]` case) becomes a Generated `regular_polygon` at
    /// translate(100, 20), ONE undo; a non-regular shape: nothing.
    #[test]
    fn promote_to_concept_runs_its_yaml_in_the_engine() {
        let _counters = crate::ffi_instr::test_lock::lock();
        use crate::geometry::element::{CommonProps, Element, PolygonElem};
        let poly = |pts: &[(f64, f64)]| Element::Polygon(PolygonElem {
            points: pts.to_vec(), fill: None, stroke: None, common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        });
        let first = |e: *mut JasEngine| {
            let en = unsafe { e.as_ref() }.unwrap();
            let doc = en.model.borrow().document().clone();
            doc.layers[0].children().unwrap()[0].clone()
        };
        let req = r#"{"action":"promote_to_concept"}"#;
        let oblong = engine_with(crate::document::test_fixture::model_with(
            vec![poly(&[(0.0, 0.0), (20.0, 0.0), (20.0, 10.0), (0.0, 10.0)])], &[0]));
        let before = first(oblong);
        let _ = dispatch(oblong, req);
        assert_eq!(first(oblong), before, "no fitter matches an oblong: nothing");
        unsafe { jas_engine_free(oblong) };

        let e = engine_with(crate::document::test_fixture::model_with(
            vec![poly(&[(110.0, 20.0), (100.0, 30.0), (90.0, 20.0), (100.0, 10.0)])], &[0]));
        let before = first(e);
        let (_reply, err) = dispatch(e, req);
        match &*first(e) {
            Element::Live(crate::geometry::live::LiveVariant::Generated(g)) => {
                assert_eq!(g.concept_id, "regular_polygon");
                assert_eq!((g.params["sides"].as_f64(), g.params["radius"].as_f64()), (Some(4.0), Some(10.0)));
                let t = g.common.transform.expect("a placement");
                assert_eq!((t.e, t.f), (100.0, 20.0));
            }
            other => panic!("not promoted: {other:?} ({err})"),
        }
        unsafe { e.as_ref() }.unwrap().model.borrow_mut().undo();
        assert_eq!(first(e), before, "one undo");
        unsafe { jas_engine_free(e) };
    }

    /// The Concepts panel's Place Instance and a parameter field's commit run
    /// their YAML in the engine (`doc.place_concept_instance` reading the
    /// STORE's `selected_concept`, `doc.set_concept_param` reading
    /// `param.*`), each ONE undo step. No concept selected: nothing.
    #[test]
    fn the_concept_verbs_run_their_yaml_in_the_engine() {
        let _counters = crate::ffi_instr::test_lock::lock();
        const CONCEPTS: &str = "concepts_panel_content";
        let e = engine_with(crate::document::test_fixture::model_with(vec![], &[]));
        let kids = |e: *mut JasEngine| {
            let en = unsafe { e.as_ref() }.unwrap();
            let doc = en.model.borrow().document().clone();
            doc.layers[0].children().map(|c| c.to_vec()).unwrap_or_default()
        };
        let (_reply, _err) = behave(e, CONCEPTS, r#"{"widget":"concept_place","event":"click"}"#);
        assert!(kids(e).is_empty(), "no concept selected: nothing");

        {
            let en = unsafe { e.as_ref() }.unwrap();
            let mut store = en.store.borrow_mut();
            if store.panel_scope("concepts").is_none() {
                store.init_panel("concepts", std::collections::HashMap::new());
            }
            store.set_panel("concepts", "selected_concept", serde_json::json!("star"));
        }
        let (reply, err) = behave(e, CONCEPTS, r#"{"widget":"concept_place","event":"click"}"#);
        assert!(reply.contains(r#""doc_changed":true"#), "place: {reply} {err}");
        let points = |e: *mut JasEngine| match &*kids(e)[0] {
            crate::geometry::element::Element::Live(crate::geometry::live::LiveVariant::Generated(g)) => {
                assert_eq!(g.concept_id, "star");
                g.params["points"].as_f64()
            }
            other => panic!("not a generated instance: {other:?}"),
        };
        assert_eq!(kids(e).len(), 1, "the instance is appended");
        assert_eq!(points(e), Some(5.0), "the concept's declared default");

        let (_reply, err) = dispatch(e, r#"{"action":"set_concept_param","params":{"name":"points","value":8}}"#);
        assert_eq!(points(e), Some(8.0), "the param is set: {err}");
        let _ = dispatch(e, r#"{"action":"set_concept_param","params":{"name":"points","value":"eight"}}"#);
        assert_eq!(points(e), Some(8.0), "not a number: nothing");
        unsafe { e.as_ref() }.unwrap().model.borrow_mut().undo();
        assert_eq!(points(e), Some(5.0), "one undo");
        unsafe { jas_engine_free(e) };
    }

    /// **W2b-17 (F-J).** The Symbols panel's verbs run in the engine through
    /// `symbols_host`, the web's own implementation, instead of reporting their
    /// `log` stubs. New Symbol promotes the selection and panel-selects the new
    /// master in the STORE; Place Instance places the store-selected master;
    /// Delete on a master that still has instances OPENS the orphan confirm in
    /// the engine's store (the dialog door; until 2026-10-14 it was refused by
    /// the dialog's name), with the instance count as its param, and changes
    /// nothing; the confirm's Delete button then deletes that master, closes
    /// the dialog and clears the panel selection.
    #[test]
    fn the_symbol_verbs_run_in_the_engine_and_the_orphan_confirm_opens() {
        let _counters = crate::ffi_instr::test_lock::lock();
        const SYMBOLS: &str = "symbols_panel_content";
        use crate::document::test_fixture::{model_with, rect};
        let e = engine_with(model_with(vec![rect(0.0, 0.0, 10.0, 10.0)], &[0]));
        let state = |e: *mut JasEngine| {
            let en = unsafe { e.as_ref() }.unwrap();
            let doc = en.model.borrow().document().clone();
            let sel = en.store.borrow().panel_scope("symbols")
                .and_then(|p| p.get("selected_symbol")).cloned();
            (doc, sel)
        };
        let (reply, err) = behave(e, SYMBOLS, r#"{"widget":"sym_new","event":"click"}"#);
        assert!(reply.contains(r#""doc_changed":true"#), "new symbol: {reply} {err}");
        let (doc, sel) = state(e);
        assert_eq!(doc.symbols.len(), 1, "one master");
        let master = doc.symbols[0].common().id.clone().expect("the master has an id");
        assert_eq!(sel, Some(serde_json::Value::String(master.clone())), "the new master is panel-selected");

        let (reply, err) = behave(e, SYMBOLS, r#"{"widget":"sym_place","event":"click"}"#);
        assert!(reply.contains(r#""doc_changed":true"#), "place: {reply} {err}");
        let rdeps = crate::document::dependency_index::dependency_index(&state(e).0)
            .rdeps.get(&master).map(|v| v.len()).unwrap_or(0);
        assert_eq!(rdeps, 2, "the promoted instance and the placed one");

        let before = doc_json(e);
        let (reply, err) = behave(e, SYMBOLS, r#"{"widget":"sym_delete","event":"click"}"#);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["dialog"], "delete_symbol_orphan_confirm", "delete with instances asks first");
        assert_eq!(doc_json(e), before, "asking changes nothing");
        {
            let ctx = engine_of(e).store.borrow().eval_context();
            assert_eq!(ctx["param"]["count"], 2, "the confirm names the two instances: {ctx}");
            assert_eq!(ctx["param"]["master"], serde_json::json!(master), "and the master it asks about");
        }
        // The shell answers by clicking the dialog's Delete button, which
        // passes the dialog's `master` to the OK action as `param.master`.
        let (reply, err) = dialog_event(e, r#"{"widget":"delete_symbol_orphan_ok_btn","event":"click"}"#);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["dialog"], serde_json::Value::Null, "OK closes the confirm");
        let (doc, sel) = state(e);
        assert!(doc.symbols.is_empty(), "OK deletes the master");
        assert_eq!(sel, Some(serde_json::Value::Null), "and clears the panel selection");
        unsafe { jas_engine_free(e) };
    }

    /// Delete Symbol on a master NO instance uses runs its YAML's other branch:
    /// the master is deleted at once, with no confirm, as ONE undo step, and
    /// the panel selection clears (`active_document.symbol_usage` reads 0).
    /// A selected id that names no master deletes nothing.
    #[test]
    fn delete_symbol_deletes_an_unused_master_at_once() {
        let _counters = crate::ffi_instr::test_lock::lock();
        use crate::document::test_fixture::{model_with, rect};
        let mut model = model_with(vec![rect(0.0, 0.0, 10.0, 10.0)], &[]);
        let mut doc = model.document().clone();
        for id in ["m1", "m2"] {
            let mut master = rect(50.0, 0.0, 10.0, 10.0);
            master.common_mut().id = Some(id.into());
            doc.symbols.push(master);
        }
        model.set_document_for_test(doc);
        let e = engine_with(model);
        let select = |id: serde_json::Value| engine_of(e).store.borrow_mut().set_panel("symbols", "selected_symbol", id);
        let ids = || engine_of(e).model.borrow().document().symbols.iter()
            .map(|m| m.common().id.clone().unwrap()).collect::<Vec<_>>();

        select(serde_json::json!("no_such_master"));
        let (reply, err) = behave(e, "symbols_panel_content", r#"{"widget":"sym_delete","event":"click"}"#);
        assert_eq!(ids(), ["m1", "m2"], "an unknown id: nothing ({reply} {err})");

        select(serde_json::json!("m1"));
        let (reply, err) = behave(e, "symbols_panel_content", r#"{"widget":"sym_delete","event":"click"}"#);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["dialog"], serde_json::Value::Null, "no instance: no confirm");
        assert_eq!(ids(), ["m2"], "the master is deleted at once");
        let sel = engine_of(e).store.borrow().panel_scope("symbols")
            .and_then(|p| p.get("selected_symbol")).cloned();
        assert_eq!(sel, Some(serde_json::Value::Null), "and the panel selection clears");
        engine_of(e).model.borrow_mut().undo();
        assert_eq!(ids(), ["m1", "m2"], "one undo");
        unsafe { jas_engine_free(e) };
    }

    /// THE ARTBOARD TOOL'S DELETE (ARTBOARD_TOOL.md §Delete behavior): with
    /// artboards selected in the Artboards panel, Delete deletes THEM; with
    /// none, it falls through to `delete_selection` (the elements). The tool
    /// says so in `artboard.yaml`'s `on_keydown`, and claims the two keys with
    /// `claims_keys`. Until 2026-10-15 every port ran the global delete first,
    /// so the tool's branch never ran (flask STATUS § 310).
    #[test]
    fn the_artboard_tools_delete_deletes_the_panel_selected_artboards() {
        let _counters = crate::ffi_instr::test_lock::lock();
        use crate::document::artboard::Artboard;
        use crate::ffi_pointer::{jas_key_event, jas_set_tool, selectable_index, KEY_DELETE};
        let setup = |panel_row: bool| -> *mut JasEngine {
            let e = engine_on("rect_with_stroke.svg");
            engine_of(e).with_model_mut(|m| {
                let mut doc = m.document().clone();
                doc.artboards = (0..3).map(|i| Artboard::default_with_id(format!("ab{i:04}"))).collect();
                m.set_document_unbracketed(doc, crate::document::model::NonUndoableIntent::TestOnly);
            });
            let _ = dispatch(e, r#"{"action":"select_all","params":{}}"#);
            unsafe { assert_eq!(jas_set_tool(e, selectable_index("artboard").expect("artboard")), JasStatus::Ok) };
            if panel_row {
                let plan: serde_json::Value =
                    serde_json::from_str(&plan_of(e, "artboards_panel_content", 228, 600)).expect("plan JSON");
                let row: serde_json::Value = ["chrome", "containers", "leaves"].iter()
                    .filter_map(|k| plan[*k].as_array()).flatten()
                    .filter(|r| r["id"] == "ap_number").map(|r| r["path"].clone()).nth(1).expect("row 1");
                let (reply, err) = behave(e, "artboards_panel_content", &format!(r#"{{"path":{row},"event":"click"}}"#));
                assert!(!reply.is_empty(), "row 1 refused: {err}");
            }
            e
        };
        let counts = |e: *mut JasEngine| engine_of(e).with_document(|d| (d.artboards.len(), d.selection.len()));

        let e = setup(true);
        let before = counts(e);
        assert!(before.1 > 0, "the control: elements are selected too");
        unsafe { jas_key_event(e, KEY_DELETE, 0) };
        assert_eq!(counts(e), (2, before.1), "the panel-selected artboard is deleted, the elements stay");
        unsafe { jas_engine_free(e) };

        let e = setup(false);
        unsafe { jas_key_event(e, KEY_DELETE, 0) };
        assert_eq!(counts(e), (3, 0), "nothing panel-selected: the elements are deleted");
        unsafe { jas_engine_free(e) };
    }

    /// THE ARTBOARD TOOL ON THE POINTER ROUTE SEES AND WRITES THE ARTBOARDS
    /// PANEL'S SELECTION (ARTBOARD_TOOL.md §Mousedown disambiguation order,
    /// §Click-to-activate). The tool runs on its own store, so the engine hands
    /// it the panel's facts before every pointer event and takes the selection
    /// writes it queues after. Until 2026-10-16 the pointer route did neither:
    /// a panel-selected artboard showed no live handles to the tool (a press on
    /// its corner MOVED it), and a canvas click never reached the panel.
    #[test]
    fn the_artboard_tool_on_the_pointer_route_sees_and_writes_the_panel_selection() {
        let _counters = crate::ffi_instr::test_lock::lock();
        use crate::document::artboard::Artboard;
        use crate::ffi_pointer::{
            jas_pointer_event, jas_set_tool, selectable_index, KIND_MOVE, KIND_PRESS, KIND_RELEASE,
            MOD_DRAGGING, MOD_SHIFT,
        };
        // Three Letter artboards side by side: ab0000 at x 0, ab0001 at 700,
        // ab0002 at 1400. Zoom 1, no pan, so a pointer point is a document point.
        let setup = |row: Option<usize>| -> *mut JasEngine {
            let mut doc = crate::document::document::Document::default();
            doc.artboards = (0..3).map(|i| {
                let mut ab = Artboard::default_with_id(format!("ab{i:04}"));
                ab.x = 700.0 * i as f64;
                ab
            }).collect();
            let mut model = Model::new(doc, None);
            model.zoom_level = 1.0;
            model.view_offset_x = 0.0;
            model.view_offset_y = 0.0;
            let e = engine_with(model);
            unsafe { assert_eq!(jas_set_tool(e, selectable_index("artboard").expect("artboard")), JasStatus::Ok) };
            if let Some(n) = row {
                let plan: serde_json::Value =
                    serde_json::from_str(&plan_of(e, "artboards_panel_content", 228, 600)).expect("plan JSON");
                let path: serde_json::Value = ["chrome", "containers", "leaves"].iter()
                    .filter_map(|k| plan[*k].as_array()).flatten()
                    .filter(|r| r["id"] == "ap_number").map(|r| r["path"].clone()).nth(n).expect("row");
                let (reply, err) = behave(e, "artboards_panel_content", &format!(r#"{{"path":{path},"event":"click"}}"#));
                assert!(!reply.is_empty(), "row {n} refused: {err}");
            }
            e
        };
        let gesture = |e: *mut JasEngine, from: (f64, f64), to: (f64, f64), mods: u32| unsafe {
            assert_eq!(jas_pointer_event(e, KIND_PRESS, from.0, from.1, mods), JasStatus::Ok);
            if from != to {
                assert_eq!(jas_pointer_event(e, KIND_MOVE, to.0, to.1, mods | MOD_DRAGGING), JasStatus::Ok);
            }
            assert_eq!(jas_pointer_event(e, KIND_RELEASE, to.0, to.1, mods), JasStatus::Ok);
        };
        let bounds = |e: *mut JasEngine, i: usize| engine_of(e).with_document(|d| {
            let ab = &d.artboards[i];
            (ab.x, ab.y, ab.width, ab.height)
        });
        let panel_selection = |e: *mut JasEngine| -> Vec<String> {
            engine_of(e).artboard_facts()["artboards_panel_selection_ids"].as_array()
                .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
                .unwrap_or_default()
        };

        // 1. A press on the SE handle of the panel-selected artboard RESIZES it.
        let e = setup(Some(1));
        assert_eq!(panel_selection(e), vec!["ab0001".to_string()], "the control: row 1 is selected");
        gesture(e, (1312.0, 792.0), (1362.0, 842.0), 0);
        assert_eq!(bounds(e, 1), (700.0, 0.0, 662.0, 842.0), "the SE handle resizes; the NW corner stays");
        assert_eq!(bounds(e, 0), (0.0, 0.0, 612.0, 792.0), "the control: ab0000 is untouched");
        unsafe { jas_engine_free(e) };

        // 2. A click inside an artboard on the canvas selects it in the panel.
        let e = setup(None);
        assert!(panel_selection(e).is_empty(), "the control: nothing is selected");
        gesture(e, (1000.0, 400.0), (1000.0, 400.0), 0);
        assert_eq!(panel_selection(e), vec!["ab0001".to_string()], "the click reaches the panel");
        assert_eq!(bounds(e, 1), (700.0, 0.0, 612.0, 792.0), "a click moves nothing");
        unsafe { jas_engine_free(e) };

        // 3. A Shift-click ranges from the anchor the panel's row click set.
        let e = setup(Some(0));
        gesture(e, (1700.0, 400.0), (1700.0, 400.0), MOD_SHIFT);
        assert_eq!(panel_selection(e), vec!["ab0000".to_string(), "ab0001".to_string(), "ab0002".to_string()],
            "the range runs from the row's anchor to the clicked artboard");
        unsafe { jas_engine_free(e) };

        // 4. MULTI-SELECT MOVE (§Drag-to-move): with two artboards selected, a
        //    plain drag on either moves BOTH. The click's selection write
        //    resolves at MOUSEUP (§Click-to-activate), so a press on an
        //    artboard already selected must not narrow the selection first.
        let two = |e: *mut JasEngine| {
            gesture(e, (1000.0, 400.0), (1000.0, 400.0), MOD_SHIFT); // anchor ab0000 (row 0) .. ab0001
            assert_eq!(panel_selection(e), vec!["ab0000".to_string(), "ab0001".to_string()],
                "the control: two artboards are selected");
        };
        let e = setup(Some(0));
        two(e);
        gesture(e, (1000.0, 400.0), (1050.0, 430.0), 0);
        assert_eq!(bounds(e, 0), (50.0, 30.0, 612.0, 792.0), "the other selected artboard moves too");
        assert_eq!(bounds(e, 1), (750.0, 30.0, 612.0, 792.0), "the grabbed artboard moves");
        assert_eq!(bounds(e, 2), (1400.0, 0.0, 612.0, 792.0), "the control: an unselected artboard stays");
        assert_eq!(panel_selection(e), vec!["ab0000".to_string(), "ab0001".to_string()],
            "a drag keeps the selection it moved");
        unsafe { jas_engine_free(e) };

        // 5. A plain CLICK (no drag) on an artboard already selected narrows
        //    the selection to it, at mouseup.
        let e = setup(Some(0));
        two(e);
        gesture(e, (1000.0, 400.0), (1000.0, 400.0), 0);
        assert_eq!(panel_selection(e), vec!["ab0001".to_string()], "a click narrows to the clicked artboard");
        assert_eq!(bounds(e, 1), (700.0, 0.0, 612.0, 792.0), "a click moves nothing");
        unsafe { jas_engine_free(e) };

        // 6. A plain drag on an artboard NOT selected selects it and moves it alone.
        let e = setup(Some(0));
        gesture(e, (1700.0, 400.0), (1750.0, 400.0), 0);
        assert_eq!(panel_selection(e), vec!["ab0002".to_string()], "the grabbed artboard becomes the selection");
        assert_eq!(bounds(e, 2), (1450.0, 0.0, 612.0, 792.0), "it moves");
        assert_eq!(bounds(e, 0), (0.0, 0.0, 612.0, 792.0), "the previously selected artboard stays");
        unsafe { jas_engine_free(e) };
    }

    /// A PLAN ENTRY NAMES THE EVENTS ITS NODE ANSWERS (flask STATUS § 315):
    /// `"events"` lists the `event`s of the node's `behavior`, in declared order
    /// and once each, with `click` for a node-level `action`. A shell routes a
    /// press on any leaf whose events hold `click` (WinUI built a `text` leaf
    /// with no pointer handler, so an Artboards row could not be selected).
    #[test]
    fn a_plan_entry_names_the_events_its_node_answers() {
        let _counters = crate::ffi_instr::test_lock::lock();
        use crate::document::artboard::Artboard;
        let mut doc = crate::document::document::Document::default();
        doc.artboards = (0..2).map(|i| Artboard::default_with_id(format!("ab{i:04}"))).collect();
        let e = engine_with(Model::new(doc, None));
        let plan: serde_json::Value =
            serde_json::from_str(&plan_of(e, "artboards_panel_content", 228, 600)).expect("plan JSON");
        let all: Vec<&serde_json::Value> = ["chrome", "containers", "leaves"].iter()
            .filter_map(|k| plan[*k].as_array()).flatten().collect();
        let events_of = |id: &str| all.iter().find(|r| r["id"] == id).map(|r| r["events"].clone());
        assert_eq!(events_of("ap_number"), Some(serde_json::json!(["click"])));
        assert_eq!(events_of("ap_name"), Some(serde_json::json!(["click", "click_and_wait"])), "declared order, once each");
        assert!(all.iter().all(|r| r["events"].is_array()), "every entry carries the key");
        assert!(all.iter().any(|r| r["events"] == serde_json::json!([])), "the control: a leaf that answers nothing");
        unsafe { jas_engine_free(e) };
    }

    /// **W2b-16 (A13, D12): a `foreach` row is addressed by its plan PATH.**
    /// The engine re-expands the foreach from the same scope the plan used,
    /// binds the row's loop variable, and runs the widget's behavior for THAT
    /// row. Row 1's `ap_number` selects artboard 1, and the plan's label on
    /// that row names the same artboard (S8). A path past the last row is
    /// refused by name, and so is a path into nothing.
    #[test]
    fn a_foreach_row_is_addressed_by_its_plan_path() {
        let _counters = crate::ffi_instr::test_lock::lock();
        use crate::document::artboard::Artboard;
        let mut doc = crate::document::document::Document::default();
        doc.artboards = (0..3).map(|i| {
            let mut a = Artboard::default_with_id(format!("ab{i:04}"));
            a.name = format!("Board {}", i + 1);
            a
        }).collect();
        let e = engine_with(Model::new(doc, None));
        let plan: serde_json::Value =
            serde_json::from_str(&plan_of(e, "artboards_panel_content", 228, 600)).expect("plan JSON");
        let rows: Vec<serde_json::Value> = ["chrome", "containers", "leaves"].iter()
            .filter_map(|k| plan[*k].as_array()).flatten()
            .filter(|r| r["id"] == "ap_number").map(|r| r["path"].clone()).collect();
        assert_eq!(rows.len(), 3, "one ap_number per artboard: {plan}");
        // S8: the row the plan LABELS "Board 2" is the row path rows[1] names.
        let name_row: Vec<String> = ["chrome", "containers", "leaves"].iter()
            .filter_map(|k| plan[*k].as_array()).flatten()
            .filter(|r| r["id"] == "ap_name" && r["path"][1] == rows[1][1])
            .map(|r| r.to_string()).collect();
        assert_eq!(name_row.len(), 1, "{plan}");
        assert!(name_row[0].contains("Board 2"), "row 1's label: {}", name_row[0]);

        let ev = format!(r#"{{"path":{},"event":"click"}}"#, rows[1]);
        let (reply, err) = behave(e, "artboards_panel_content", &ev);
        assert!(!reply.is_empty(), "row 1 refused: {err}");
        let scope = {
            let en = unsafe { e.as_ref() }.unwrap();
            crate::panel_scope::engine_scope(&en.panel.borrow(), &en.store.borrow(),
                                             &en.model.borrow(), "artboards_panel_content")
        };
        assert_eq!(scope["active_document"]["artboards_panel_selection_ids"],
                   serde_json::json!(["ab0001"]), "row 1 acts on artboard 1");

        let mut past = rows[1].clone();
        past.as_array_mut().unwrap()[1] = serde_json::json!(9);
        let (reply, err) = behave(e, "artboards_panel_content",
                                  &format!(r#"{{"path":{past},"event":"click"}}"#));
        assert_eq!(reply, "", "a row that does not exist");
        assert!(err.contains(r#""panel_event":"NoRow""#), "{err}");
        let (reply, err) = behave(e, "artboards_panel_content", r#"{"path":[7,7],"event":"click"}"#);
        assert_eq!(reply, "");
        assert!(err.contains(r#""panel_event":"MissingTarget""#), "{err}");
        unsafe { jas_engine_free(e) };
    }

    /// (reply, error channel) for one behavior crossing.
    fn behave(e: *mut JasEngine, panel: &str, event: &str) -> (String, String) {
        let reply = take(unsafe {
            jas_panel_behavior(e, panel.as_ptr(), panel.len(), event.as_ptr(), event.len())
        });
        (reply, take(unsafe { jas_last_error_json(e) }))
    }

    // -----------------------------------------------------------------------
    // A MENU ACTION, RUN BY THE CORE (the owner's notes, 2026-10-11: the
    // Windows menus drew every item live, and every item but five wrote
    // `ACTION UNIMPLEMENTED`; File > New made no tab).
    // -----------------------------------------------------------------------

    /// (reply, error channel) for one action crossing.
    fn dispatch(e: *mut JasEngine, json: &str) -> (String, String) {
        let reply = take(unsafe { jas_dispatch_action(e, json.as_ptr(), json.len()) });
        (reply, take(unsafe { jas_last_error_json(e) }))
    }

    #[test]
    fn dispatch_action_runs_a_menu_action_and_its_state_moves() {
        let _counters = crate::ffi_instr::test_lock::lock();
        // Window > Toolbar, as the menu structure names it.
        let e = jas_engine_new();
        let before = engine_of(e).store.borrow().get("toolbar_visible").clone();
        let (reply, err) = dispatch(e, r#"{"action":"toggle_pane","params":{"pane":"toolbar"}}"#);
        assert!(!reply.is_empty(), "toggle_pane ran (error: {err})");
        assert!(err.is_empty(), "a run that moved state clears the channel: {err}");
        let after = engine_of(e).store.borrow().get("toolbar_visible").clone();
        assert_ne!(before, after, "the toggle moved state.toolbar_visible");
        let _ = dispatch(e, r#"{"action":"toggle_pane","params":{"pane":"toolbar"}}"#);
        assert_eq!(engine_of(e).store.borrow().get("toolbar_visible"), &before, "and back");
        unsafe { jas_engine_free(e) };
    }

    /// THE COLOUR PANEL'S MODE SWITCH REACHES THE PLAN (flask's measurement on
    /// #360, 2026-10-12). `set_color_panel_mode` writes `panel.mode` through
    /// the store, but the engine gave the colour panel no store scope (its
    /// state is `PanelState`'s), and `StateStore::set_panel` drops a write to
    /// a panel with no scope, silently. So every mode switch ran, changed
    /// nothing, and the plan kept the HSB group.
    #[test]
    fn dispatch_set_color_panel_mode_moves_the_plans_slider_group() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let id = crate::panel_scope::COLOUR_PANEL;
        let group = |e| -> Vec<String> {
            let plan: serde_json::Value =
                serde_json::from_str(&plan_of(e, id, 228, 0)).expect("plan JSON");
            plan["leaves"].as_array().unwrap().iter()
                .filter_map(|l| l["id"].as_str())
                .filter(|i| ["cp_k", "cp_h", "cp_r", "cp_c", "cp_r_ws"].contains(i))
                .map(str::to_string)
                .collect()
        };
        assert_eq!(group(e), ["cp_h"], "the default mode, hsb, before any switch");
        for (mode, first) in [("rgb", "cp_r"), ("cmyk", "cp_c"), ("grayscale", "cp_k"),
                              ("web_safe_rgb", "cp_r_ws"), ("hsb", "cp_h")] {
            let (reply, err) = dispatch(
                e, &format!(r#"{{"action":"set_color_panel_mode","params":{{"mode":"{mode}"}}}}"#));
            assert!(!reply.is_empty(), "{mode}: the action ran (error: {err})");
            assert!(err.is_empty(), "{mode}: a switch that moved the mode is not Unchanged: {err}");
            assert_eq!(group(e), [first], "{mode}: the plan carries that mode's group alone");
        }
        unsafe { jas_engine_free(e) };
    }

    /// The same silent drop, for any panel the shell has not opened: a menu
    /// action that writes a panel's scope before its plan was ever read wrote
    /// nowhere. The dispatch now seeds every panel's scope before it runs.
    #[test]
    fn dispatch_writes_the_scope_of_a_panel_never_opened() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let (reply, err) = dispatch(
            e, r#"{"action":"set_brush_view_mode","params":{"view_mode":"list"}}"#);
        assert!(!reply.is_empty(), "the action ran (error: {err})");
        assert_eq!(engine_of(e).store.borrow().get_panel("brushes_panel_content", "view_mode"),
                   &serde_json::json!("list"));
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn dispatch_action_runs_a_menu_item_by_its_id_with_the_menubars_params() {
        // The shell sends WHICH item was chosen; the core reads that item's
        // action and params from the menubar it already parses (the menu
        // structure carries no params, and a shell must not author them).
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let before = engine_of(e).store.borrow().get("toolbar_visible").clone();
        let (reply, err) = dispatch(e, r#"{"menu_item":"menu_toolbar"}"#);
        assert!(!reply.is_empty() && err.is_empty(), "Window > Toolbar ran: {err}");
        assert_ne!(engine_of(e).store.borrow().get("toolbar_visible"), &before);
        let (reply2, err2) = dispatch(e, r#"{"menu_item":"zz_no_such_item"}"#);
        assert!(reply2.is_empty() && err2.contains("UnknownMenuItem") && err2.contains("zz_no_such_item"), "{err2}");
        unsafe { jas_engine_free(e) };
    }

    /// Every menubar item with an `action`, in menu order: (item id, action).
    fn menubar_items() -> Vec<(String, String)> {
        fn walk(node: &serde_json::Value, out: &mut Vec<(String, String)>) {
            match node {
                serde_json::Value::Array(xs) => xs.iter().for_each(|x| walk(x, out)),
                serde_json::Value::Object(m) => {
                    if let (Some(id), Some(a)) = (m.get("id").and_then(|v| v.as_str()),
                                                  m.get("action").and_then(|v| v.as_str())) {
                        out.push((id.to_string(), a.to_string()));
                    }
                    m.values().for_each(|v| walk(v, out));
                }
                _ => {}
            }
        }
        let ws = Workspace::load().expect("workspace");
        let mut out = Vec::new();
        walk(&ws.data()["menubar"], &mut out);
        out
    }

    /// THE DIALOG DOOR, E1 (design `2026-10-14-jas-DESIGN-dialog-door`): the
    /// engine OPENS a dialog in its own store, as the reference does
    /// (`effects.py`, `open_dialog`), and its reply NAMES it, so the shell
    /// knows to ask for the dialog's plan. Before the door, A12 refused
    /// `open_dialog` by name and the engine opened nothing.
    ///
    /// The oracle is the action corpus's `expected_dialog` cases, which the web
    /// runner (`assert_action_dialog`) and Swift already hold to; the
    /// population is DERIVED from the fixtures, never listed, and its floor is
    /// the count on the day the door was cut. `params` and `state` are subsets,
    /// and an ABSENT key is not a null.
    ///
    /// ⛔ **OPENING IS STRICT; THE VALUES ARE NOT YET.** Every case must open its
    /// dialog and name it. The VALUES differ in [`ENGINE_DIALOG_VALUE_GAPS`]:
    /// the engine evaluates a dialog's `init` against its own action context,
    /// which lacks fields the web's `build_dialog_outer_scope` and
    /// `build_appstate_ctx` carry (`active_document.print_preferences`, the
    /// Boolean options, a layer's fields, …), so an init writes null over a
    /// declared default. The list is TWO-SIDED: a case on it that starts
    /// passing reds this test until it is removed, so it can only shrink.
    #[test]
    fn dispatch_opens_every_expected_dialog_in_the_engine_store() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/../test_fixtures/actions");
        let mut cases = Vec::new();
        for entry in std::fs::read_dir(root).unwrap() {
            let path = entry.unwrap().path();
            if path.extension().and_then(|x| x.to_str()) != Some("json") { continue; }
            let doc: serde_json::Value =
                serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
            let list = doc.as_array().cloned()
                .or_else(|| doc.get("cases").and_then(|c| c.as_array()).cloned())
                .or_else(|| doc.get("tests").and_then(|c| c.as_array()).cloned())
                .unwrap_or_default();
            cases.extend(list.into_iter().filter(|c| c.get("expected_dialog").is_some()));
        }
        assert!(cases.len() >= 12, "the corpus holds {} expected_dialog cases", cases.len());
        let mut failures = Vec::new();
        for tc in &cases {
            let name = tc["name"].as_str().unwrap();
            let want = &tc["expected_dialog"];
            let e = engine_on(tc["setup_svg"].as_str().unwrap());
            let mut last = (String::new(), String::new());
            for act in tc["actions"].as_array().unwrap() {
                last = dispatch(e, &act.to_string());
            }
            let (reply, err) = &last;
            let reply_dialog = serde_json::from_str::<serde_json::Value>(reply).ok()
                .and_then(|v| v.get("dialog").cloned());
            if reply_dialog.as_ref() != Some(&want["id"]) {
                failures.push(format!("{name}: the reply names dialog {reply_dialog:?}, want {} (reply {reply:?}, err {err})", want["id"]));
                unsafe { jas_engine_free(e) };
                continue;
            }
            let store = engine_of(e).store.borrow();
            if store.dialog_id() != want["id"].as_str() {
                failures.push(format!("{name}: the store holds dialog {:?}", store.dialog_id()));
            }
            let ctx = store.eval_context();
            for (section, scope) in [("params", "param"), ("state", "dialog")] {
                let Some(keys) = want.get(section).and_then(|v| v.as_object()) else { continue };
                for (key, value) in keys {
                    match ctx.get(scope).and_then(|s| s.get(key)) {
                        None => failures.push(format!("{name}: {section} has no key {key:?}")),
                        Some(have) if !crate::cross_language_test::tests::json_value_eq(have, value) =>
                            failures.push(format!("{name}: {section}.{key} is {have}, the corpus pins {value}")),
                        Some(_) => {}
                    }
                }
            }
            drop(store);
            unsafe { jas_engine_free(e) };
        }
        let mut unequal: Vec<&str> = failures.iter()
            .filter(|f| !f.contains(": the reply names dialog") && !f.contains(": the store holds dialog"))
            .map(|f| f.split(':').next().unwrap()).collect();
        unequal.sort();
        unequal.dedup();
        let opening: Vec<&String> = failures.iter()
            .filter(|f| f.contains(": the reply names dialog") || f.contains(": the store holds dialog"))
            .collect();
        assert!(opening.is_empty(), "{} of {} cases did not open their dialog:\n{opening:#?}", opening.len(), cases.len());
        let new_gaps: Vec<&String> = failures.iter()
            .filter(|f| !ENGINE_DIALOG_VALUE_GAPS.contains(&f.split(':').next().unwrap())).collect();
        assert!(new_gaps.is_empty(), "values the engine's dialog does not match, outside the declared gaps:\n{new_gaps:#?}");
        // The declared gaps' values, printed (`--nocapture`), so the next repair
        // starts from a reading rather than a re-derivation.
        eprintln!("declared value gaps, {} value(s):\n{}", failures.len(), failures.join("\n"));
        let closed: Vec<&&str> = ENGINE_DIALOG_VALUE_GAPS.iter().filter(|c| !unequal.contains(c)).collect();
        assert!(closed.is_empty(), "these declared gaps now pass: remove them from ENGINE_DIALOG_VALUE_GAPS: {closed:?}");
    }

    /// The `expected_dialog` cases whose dialog the engine OPENS with values the
    /// corpus does not pin. 2026-10-14, the day the door was cut: 111 values
    /// in 8 cases. The same day: the init context's outer-`param` fix closed
    /// Boolean Options and Layer Options (create); the shared
    /// `active_document` view closed Print; the flat `let` closed Layer Options
    /// (edit); the shared artboard row closed Artboard Options. 2026-10-15:
    /// the engine's print-config field effects closed Document Setup's
    /// confirm. 2026-10-15 again: a MENUBAR action now carries the selection's
    /// colours in `state.*`, as a panel action already did, which closed New
    /// Swatch and the Color Picker. None remains; the list stays, empty, so a
    /// new gap has to be declared here to pass.
    const ENGINE_DIALOG_VALUE_GAPS: [&str; 0] = [];

    /// The path (child indices from `content`, the plan's scheme) of the ONE
    /// static node whose every `address` key equals the node's own. A dialog's
    /// buttons carry no id, and two buttons can share an action (Copy and OK),
    /// so an address is a key subset; zero or two matches refuse by name.
    /// A `foreach` row is not addressable statically and is not searched.
    fn dialog_address_path(content: &serde_json::Value, address: &serde_json::Map<String, serde_json::Value>)
        -> Result<Vec<usize>, String> {
        fn walk(node: &serde_json::Value, path: &mut Vec<usize>,
                address: &serde_json::Map<String, serde_json::Value>, out: &mut Vec<Vec<usize>>) {
            if address.iter().all(|(k, v)| node.get(k) == Some(v)) {
                out.push(path.clone());
            }
            if let Some(children) = node.get("children").and_then(|c| c.as_array()) {
                for (i, child) in children.iter().enumerate() {
                    path.push(i);
                    walk(child, path, address, out);
                    path.pop();
                }
            }
        }
        let mut found = Vec::new();
        walk(content, &mut Vec::new(), address, &mut found);
        match found.len() {
            1 => Ok(found.remove(0)),
            n => Err(format!("the address {address:?} matches {n} widget(s) of the dialog, want exactly 1: {found:?}")),
        }
    }

    /// The resolver refuses an address two buttons share (Rotate's Copy and OK
    /// both run `rotate_options_confirm`) and one nothing has, and a label
    /// separates the two.
    #[test]
    fn a_dialog_address_names_exactly_one_widget() {
        let ws = Workspace::load().expect("workspace");
        let content = &ws.dialog("rotate_options").expect("rotate_options")["content"];
        let addr = |v: serde_json::Value| v.as_object().unwrap().clone();
        let shared = dialog_address_path(content, &addr(serde_json::json!({"action": "rotate_options_confirm"})));
        assert!(shared.as_ref().is_err_and(|e| e.contains("matches 2")), "{shared:?}");
        let none = dialog_address_path(content, &addr(serde_json::json!({"action": "no_such_action"})));
        assert!(none.as_ref().is_err_and(|e| e.contains("matches 0")), "{none:?}");
        let ok = dialog_address_path(content, &addr(serde_json::json!({"action": "rotate_options_confirm", "label": "OK"}))).unwrap();
        let copy = dialog_address_path(content, &addr(serde_json::json!({"action": "rotate_options_confirm", "label": "Copy"}))).unwrap();
        assert_ne!(ok, copy, "the label separates OK from Copy");
    }

    /// The dialog-action corpus's files, by name (the corpus-completeness gate
    /// reads this list as the claim; Swift's `dialogActionFixtures` is its twin).
    const DIALOG_ACTION_FIXTURES: &[&str] = &[
        "dialog_actions/transform_options.json",
        "dialog_actions/tool_options.json",
        "dialog_actions/boolean_options.json",
        "dialog_actions/paragraph_dialogs.json",
        "dialog_actions/brush_options.json",
        "dialog_actions/artboard_options.json",
        "dialog_actions/document_setup.json",
        "dialog_actions/print.json",
        "dialog_actions/panel_menu_actions.json",
        "dialog_actions/model_verbs.json",
    ];

    /// THE ACTION CORPUS, INSIDE AN OPEN DIALOG (design
    /// `2026-10-24-jas-DESIGN-dialog-action-corpus`), on the engine's route,
    /// which is the Windows shell's: `test_fixtures/dialog_actions/*.json`. A
    /// step is an action (`jas_dispatch_action`), an `open_dialog` (what a
    /// tool's double-click or an opener action performs), a `dialog_event`
    /// (`jas_dialog_event`, addressed by [`dialog_address_path`]), or a
    /// `panel_menu` click (`{"panel", "address"}`: the one row of that panel's
    /// menu the address names, sent as `{"panel", "menu_index"}`), after any
    /// `panel_state` seed (a panel's own state, as a tile click leaves it). Then:
    /// `expected_dialog` is the dialog open AFTER the last step (`null` for
    /// none; `state` is a subset), `expected_state` a subset of the globals,
    /// `expected_document` `"unchanged"` / `"changed"` against the document
    /// as the dialog opened, `expected_data` dotted paths into `data`,
    /// `expected_panel` a subset of a panel's own state, and `expected_json` the
    /// pinned golden, which Swift must match.
    #[test]
    fn dialog_action_corpus_runs_on_the_engine_route() {
        use crate::geometry::test_json::document_to_test_json;
        let _counters = crate::ffi_instr::test_lock::lock();
        let fixtures = concat!(env!("CARGO_MANIFEST_DIR"), "/../test_fixtures");
        let root = format!("{fixtures}/dialog_actions");
        let ws = Workspace::load().expect("workspace");
        let mut cases = Vec::new();
        for file in DIALOG_ACTION_FIXTURES {
            let doc: serde_json::Value = serde_json::from_str(
                &std::fs::read_to_string(format!("{fixtures}/{file}")).unwrap()).unwrap();
            cases.extend(doc.as_array().cloned().unwrap_or_default());
        }
        // The floor: the count on the day the file was cut. A floor is a minimum.
        assert!(cases.len() >= 6, "the dialog-action corpus holds {} case(s)", cases.len());
        let mut failures = Vec::new();
        for tc in &cases {
            let name = tc["name"].as_str().unwrap();
            let e = engine_on(tc["setup_svg"].as_str().unwrap());
            // `panel_state`: a panel's own state as the artist left it (a
            // selection made by clicking tiles, which no verb sets), written
            // over the panel's declared defaults. Swift seeds it the same way.
            for (pid, keys) in tc.get("panel_state").and_then(|v| v.as_object()).into_iter().flatten() {
                seed_panel(engine_of(e), &ws, pid);
                for (k, v) in keys.as_object().into_iter().flatten() {
                    engine_of(e).store.borrow_mut().set_panel(pid, k, v.clone());
                }
            }
            // `state`: globals as an earlier session left them (the operation
            // Repeat remembers), written before the first step. Swift the same.
            for (k, v) in tc.get("state").and_then(|v| v.as_object()).into_iter().flatten() {
                engine_of(e).store.borrow_mut().set(k, v.clone());
            }
            // `expected_document` compares against the document as the dialog
            // OPENED (after the setup steps), never the setup file itself.
            let mut at_open: Option<String> = None;
            let mut step_failed = false;
            for step in tc["actions"].as_array().unwrap() {
                if let Some(od) = step.get("open_dialog") {
                    let id = od["id"].as_str().unwrap();
                    let Some(spec) = ws.dialog(id) else {
                        failures.push(format!("{name}: no dialog {id:?} in the bundle"));
                        step_failed = true;
                        break;
                    };
                    let params = od.get("params").and_then(|p| p.as_object()).map(|m|
                        m.iter().map(|(k, v)| (k.clone(), v.clone())).collect());
                    let en = engine_of(e);
                    at_open.get_or_insert_with(|| document_to_test_json(en.model.borrow().document()));
                    let ctx = en.store.borrow().eval_context();
                    crate::interpreter::effects::open_dialog_in(
                        id, spec, params, None, &ctx,
                        &mut en.store.borrow_mut(), Some(&mut *en.model.borrow_mut()));
                } else if let Some(pm) = step.get("panel_menu") {
                    // A panel-menu click, through the shell's own door: the ONE row
                    // of the panel's menu whose every `address` key equals its own
                    // (zero or two refuse by name), sent back by index.
                    let pid = pm["panel"].as_str().unwrap_or_default();
                    let address = pm["address"].as_object().cloned().unwrap_or_default();
                    let hits: Vec<usize> = ws.panel_menu(pid).iter().enumerate()
                        .filter(|(_, n)| n.is_object() && address.iter().all(|(k, v)| n.get(k) == Some(v)))
                        .map(|(i, _)| i).collect();
                    if hits.len() != 1 {
                        failures.push(format!("{name}: the address {address:?} matches {} row(s) of {pid}'s menu, want exactly 1", hits.len()));
                        step_failed = true;
                        break;
                    }
                    let msg = serde_json::json!({"panel": pid, "menu_index": hits[0]}).to_string();
                    let (reply, err) = dispatch(e, &msg);
                    if reply.is_empty() {
                        failures.push(format!("{name}: the panel menu refused {msg}: {err}"));
                        step_failed = true;
                        break;
                    }
                } else if let Some(pe) = step.get("panel_event") {
                    // A panel widget's event, through the shell's own door
                    // (`jas_panel_behavior`): the ONE static widget of the panel's
                    // content whose every `address` key equals its own, by its id.
                    let pid = pe["panel"].as_str().unwrap_or_default();
                    let Some(panel) = ws.panel(pid) else {
                        failures.push(format!("{name}: no panel {pid:?} in the bundle"));
                        step_failed = true;
                        break;
                    };
                    let address = pe["address"].as_object().cloned().unwrap_or_default();
                    let node = dialog_address_path(&panel["content"], &address).map(|path|
                        path.iter().fold(&panel["content"], |n, i| &n["children"][*i]).clone());
                    let id = match node {
                        Ok(n) => match n.get("id").and_then(|v| v.as_str()) {
                            Some(id) => id.to_string(),
                            None => { failures.push(format!("{name}: the addressed widget has no id")); step_failed = true; break; }
                        },
                        Err(why) => { failures.push(format!("{name}: {why}")); step_failed = true; break; }
                    };
                    let mut msg = serde_json::json!({"widget": id, "event": pe.get("event").cloned().unwrap_or(serde_json::json!("click"))});
                    if let Some(v) = pe.get("value") { msg["value"] = v.clone(); }
                    let (reply, err) = behave(e, pid, &msg.to_string());
                    if reply.is_empty() && !err.contains("Unchanged") {
                        failures.push(format!("{name}: the panel refused {msg}: {err}"));
                        step_failed = true;
                        break;
                    }
                } else if let Some(action) = step.get("action").and_then(|a| a.as_str()) {
                    // An action through the shell's own door, so a dialog it opens
                    // (`open_boolean_options`) resolves its params in the app's
                    // scope, as the app does. The document is taken as it opens.
                    let before = document_to_test_json(engine_of(e).model.borrow().document());
                    // `panel`, when the step names one: the action runs in that
                    // panel's scope, as its own widget runs it (a breadcrumb's).
                    let mut msg = serde_json::json!({"action": action,
                        "params": step.get("params").cloned().unwrap_or(serde_json::json!({}))});
                    if let Some(pid) = step.get("panel") { msg["panel"] = pid.clone(); }
                    let msg = msg.to_string();
                    let (reply, err) = dispatch(e, &msg);
                    if reply.is_empty() {
                        failures.push(format!("{name}: the action {action} was refused: {err}"));
                        step_failed = true;
                        break;
                    }
                    if engine_of(e).store.borrow().dialog_id().is_some() {
                        at_open.get_or_insert(before);
                    }
                } else if let Some(ev) = step.get("dialog_event") {
                    let open = engine_of(e).store.borrow().dialog_id().map(str::to_string);
                    let Some(spec) = open.as_deref().and_then(|id| ws.dialog(id)) else {
                        failures.push(format!("{name}: a dialog_event with no dialog open ({open:?})"));
                        step_failed = true;
                        break;
                    };
                    // Addressed in the form the door walks: a `tabs` node is its strip
                    // and its active page, in the dialog's own scope.
                    let scope = dialog_ctx(engine_of(e), &engine_of(e).store.borrow().eval_context());
                    let spec = crate::panel_plan::canonical_tabs(spec, &scope);
                    let path = match dialog_address_path(&spec["content"], ev["address"].as_object().unwrap()) {
                        Ok(p) => p,
                        Err(why) => { failures.push(format!("{name}: {why}")); step_failed = true; break; }
                    };
                    let mut msg = serde_json::json!({"path": path, "event": ev["event"]});
                    if let Some(v) = ev.get("value") { msg["value"] = v.clone(); }
                    let msg = msg.to_string();
                    let reply = take(unsafe { jas_dialog_event(e, msg.as_ptr(), msg.len()) });
                    if reply.is_empty() {
                        let err = take(unsafe { jas_last_error_json(e) });
                        // `Unchanged` is a run that moved nothing, not a refusal of the act.
                        if !err.contains("Unchanged") {
                            failures.push(format!("{name}: the dialog refused {msg}: {err}"));
                            step_failed = true;
                            break;
                        }
                    }
                } else {
                    failures.push(format!("{name}: a step this runner does not know: {step}"));
                    step_failed = true;
                    break;
                }
            }
            if step_failed { unsafe { jas_engine_free(e) }; continue; }
            let en = engine_of(e);
            let store = en.store.borrow();
            match tc.get("expected_dialog") {
                Some(serde_json::Value::Null) => if let Some(id) = store.dialog_id() {
                    failures.push(format!("{name}: dialog {id:?} is still open, want none"));
                },
                Some(want) => {
                    if store.dialog_id() != want["id"].as_str() {
                        failures.push(format!("{name}: the open dialog is {:?}, want {}", store.dialog_id(), want["id"]));
                    } else {
                        let ctx = store.eval_context();
                        for (key, value) in want.get("state").and_then(|s| s.as_object()).into_iter().flatten() {
                            match ctx.get("dialog").and_then(|d| d.get(key)) {
                                Some(have) if crate::cross_language_test::tests::json_value_eq(have, value) => {}
                                have => failures.push(format!("{name}: dialog.{key} is {have:?}, the corpus pins {value}")),
                            }
                        }
                    }
                }
                None => {}
            }
            for (key, value) in tc.get("expected_state").and_then(|s| s.as_object()).into_iter().flatten() {
                let have = store.get(key);
                if !crate::cross_language_test::tests::json_value_eq(have, value) {
                    failures.push(format!("{name}: state.{key} is {have}, the corpus pins {value}"));
                }
            }
            // `expected_data`: a dotted path into the store's `data` namespace
            // (Brush Options writes `brush_libraries`), where an integer segment
            // indexes an array and -1 is its last item. A path that does not
            // resolve is a failure, never a match against null.
            for (path, value) in tc.get("expected_data").and_then(|s| s.as_object()).into_iter().flatten() {
                let mut cur = store.get_data_path("");
                let mut ok = true;
                for seg in path.split('.') {
                    let next = match (&cur, seg.parse::<i64>()) {
                        (serde_json::Value::Array(a), Ok(i)) => {
                            let i = if i < 0 { a.len() as i64 + i } else { i };
                            usize::try_from(i).ok().and_then(|i| a.get(i)).cloned()
                        }
                        _ => cur.get(seg).cloned(),
                    };
                    match next { Some(v) => cur = v, None => { ok = false; break; } }
                }
                if !ok {
                    failures.push(format!("{name}: data.{path} does not resolve"));
                } else if !crate::cross_language_test::tests::json_value_eq(&cur, value) {
                    failures.push(format!("{name}: data.{path} is {cur}, the corpus pins {value}"));
                }
            }
            // `expected_panel`: a subset of a panel's own state after the last
            // step. A key the panel does not hold is a failure, never a null.
            for (pid, keys) in tc.get("expected_panel").and_then(|v| v.as_object()).into_iter().flatten() {
                for (key, value) in keys.as_object().into_iter().flatten() {
                    let have = store.get_panel(pid, key);
                    if have.is_null() || !crate::cross_language_test::tests::json_value_eq(have, value) {
                        failures.push(format!("{name}: panel {pid}.{key} is {have}, the corpus pins {value}"));
                    }
                }
            }
            drop(store);
            let after = document_to_test_json(en.model.borrow().document());
            let before = at_open.unwrap_or_default();
            match tc.get("expected_document").and_then(|v| v.as_str()) {
                Some(_) if before.is_empty() =>
                    failures.push(format!("{name}: expected_document needs an open_dialog step to compare from")),
                Some("unchanged") if after != before =>
                    failures.push(format!("{name}: the document changed, want unchanged:\n{after}")),
                Some("changed") if after == before =>
                    failures.push(format!("{name}: the document is unchanged, want changed")),
                Some("unchanged") | Some("changed") | None => {}
                Some(other) => failures.push(format!("{name}: expected_document {other:?} is neither unchanged nor changed")),
            }
            if let Some(file) = tc.get("expected_json").and_then(|v| v.as_str()) {
                match std::fs::read_to_string(format!("{root}/{file}")) {
                    Ok(want) if want.trim() == after => {}
                    Ok(_) => failures.push(format!("{name}: canonical JSON mismatch against {file}; ACTUAL:\n{after}")),
                    Err(_) => failures.push(format!("{name}: no golden {file}; ACTUAL:\n{after}")),
                }
            }
            unsafe { jas_engine_free(e) };
        }
        assert!(failures.is_empty(), "{} failure(s) over {} case(s):\n{}",
            failures.len(), cases.len(), failures.join("\n"));
    }

    /// THE DIALOG DOOR, the shell's one non-YAML act: Escape or the window's
    /// close box. `jas_dialog_dismiss` closes the open dialog as `close_dialog`
    /// does (a preview snapshot no OK action cleared is restored), and says
    /// whether one was open: 1 closed · 0 none was open · 255 a null engine.
    #[test]
    fn dialog_dismiss_closes_the_open_dialog_and_restores_its_preview() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("complex_document.svg");
        let (reply, err) = dispatch(e, r#"{"action":"open_boolean_options"}"#);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["dialog"], "boolean_options", "{reply}");
        // A preview target, written while the dialog is open, is put back.
        {
            let mut store = engine_of(e).store.borrow_mut();
            store.set("zz_preview", serde_json::json!("before"));
            let mut targets = std::collections::HashMap::new();
            targets.insert("zz_preview".to_string(), "zz_preview".to_string());
            store.capture_dialog_snapshot(&targets);
            store.set("zz_preview", serde_json::json!("during"));
        }
        assert_eq!(unsafe { jas_dialog_dismiss(e) }, 1);
        let store = engine_of(e).store.borrow();
        assert_eq!(store.dialog_id(), None, "dismissed");
        assert_eq!(store.get("zz_preview"), &serde_json::json!("before"), "the preview is restored");
        drop(store);
        assert_eq!(unsafe { jas_dialog_dismiss(e) }, 0, "none is open now");
        assert_eq!(unsafe { jas_dialog_dismiss(std::ptr::null_mut()) }, 255);
        unsafe { jas_engine_free(e) };
    }

    /// THE DIALOG DOOR, the plan: `jas_dialog_plan` is the panel planner over
    /// the OPEN dialog's `content`, evaluated with the dialog's own scope
    /// (`dialog.*`, `param.*`) beside the engine's. With no dialog open it
    /// answers `{"open": false}`, never an empty span.
    #[test]
    fn dialog_plan_plans_the_open_dialog_with_its_own_values() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("rect_with_stroke.svg");
        let plan = |e| take(unsafe { jas_dialog_plan(e, 420, 640) });
        let v: serde_json::Value = serde_json::from_str(&plan(e)).unwrap();
        assert_eq!(v, serde_json::json!({"open": false}), "nothing open");

        // An edited tab closing asks to save: the action corpus's case.
        for act in [r#"{"action":"select_all","params":{}}"#,
                    r#"{"action":"set_stroke_cap","params":{"cap":"square"}}"#] {
            let _ = dispatch(e, act);
        }
        let (reply, err) = dispatch(e, r#"{"action":"close_tab","params":{"index":0}}"#);
        assert!(reply.contains(r#""dialog":"save_changes_tab""#), "{reply} {err}");
        let v: serde_json::Value = serde_json::from_str(&plan(e)).unwrap();
        assert_eq!(v["open"], true);
        assert_eq!(v["id"], "save_changes_tab");
        assert_eq!(v["summary"], "Save Changes");
        assert_eq!(v["modal"], true);
        assert_eq!(v["depth"], 1);
        assert_eq!(v["width"], serde_json::Value::Null, "Save Changes declares no width");
        let leaves = v["plan"]["leaves"].as_array().expect("a panel-shaped plan");
        let buttons = leaves.iter().filter(|l| l["type"] == "button").count();
        assert_eq!(buttons, 3, "Cancel, Discard and Save: {leaves:?}");
        // The prompt names the document from the dialog's OWN param.
        let filename = engine_of(e).store.borrow().eval_context()["param"]["filename"].clone();
        let filename = filename.as_str().filter(|f| !f.is_empty())
            .unwrap_or_else(|| panic!("the dialog's filename param: {filename}")).to_string();
        assert!(leaves.iter().any(|l| l.to_string().contains(&format!("Save changes to \\\"{filename}\\\"?"))),
                "a text leaf resolves param.filename ({filename}): {leaves:?}");

        assert_eq!(unsafe { jas_dialog_dismiss(e) }, 1);
        let v: serde_json::Value = serde_json::from_str(&plan(e)).unwrap();
        assert_eq!(v["open"], false, "closed");
        assert_eq!(take(unsafe { jas_dialog_plan(std::ptr::null_mut(), 420, 640) }), "", "a null engine");
        unsafe { jas_engine_free(e) };
    }

    /// A nested dialog plans the TOP one and says how deep the stack is: the
    /// Color Picker over Layer Options plans the picker at depth 2, and
    /// dismissing it plans Layer Options again at depth 1. A caller's params
    /// are values (#415), so the swatch's target is passed as the string it
    /// evaluates to in the YAML.
    #[test]
    fn dialog_plan_plans_the_top_of_a_nested_stack() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("multi_layer.svg");
        let plan = |e| serde_json::from_str::<serde_json::Value>(&take(unsafe { jas_dialog_plan(e, 420, 640) })).unwrap();
        let _ = dispatch(e, r#"{"action":"open_layer_options","params":{"mode":"create"}}"#);
        let (reply, err) = dispatch(e,
            r##"{"action":"open_color_picker","params":{"target":"dialog.color","color":"#4a90d9"}}"##);
        assert!(reply.contains(r#""dialog":"color_picker""#), "{reply} {err}");
        let v = plan(e);
        assert_eq!((v["id"].clone(), v["depth"].clone()), (serde_json::json!("color_picker"), serde_json::json!(2)));
        assert_eq!(unsafe { jas_dialog_dismiss(e) }, 1);
        let v = plan(e);
        assert_eq!((v["id"].clone(), v["depth"].clone()), (serde_json::json!("layer_options"), serde_json::json!(1)));
        unsafe { jas_engine_free(e) };
    }

    /// A TABBED dialog plans its tab strip and its ACTIVE page (flask §539
    /// measured Print showing no fields on Windows: the plan walked only
    /// `children`, so no page reached it). The strip is a `select` leaf whose
    /// options are the bundle's tab ids and labels, read from the bundle here
    /// and never typed, with the active tab selected. A change on the strip
    /// re-plans with that page's widgets and none of the other's, in BOTH
    /// directions (a radio-like control is driven both ways).
    #[test]
    fn dialog_plan_plans_a_tab_strip_and_the_active_page() {
        use std::collections::BTreeSet;
        let _counters = crate::ffi_instr::test_lock::lock();
        let ws = Workspace::load().expect("workspace");
        fn find_tabs(n: &serde_json::Value) -> Option<&serde_json::Value> {
            if n["type"] == "tabs" {
                return Some(n);
            }
            n["children"].as_array().into_iter().flatten().find_map(find_tabs)
        }
        fn ids(n: &serde_json::Value, out: &mut BTreeSet<String>) {
            if let Some(id) = n["id"].as_str() {
                out.insert(id.to_string());
            }
            for c in n["children"].as_array().into_iter().flatten() {
                ids(c, out);
            }
        }
        let tabs = find_tabs(&ws.dialog("print").expect("print")["content"]).expect("Print has a tabs node").clone();
        let pages = tabs["tabs"].as_array().expect("tabs.tabs").clone();
        assert!(pages.len() >= 2, "two pages to switch between: {pages:?}");
        let page_ids: Vec<BTreeSet<String>> = pages.iter().map(|p| {
            let mut s = BTreeSet::new();
            ids(&p["content"], &mut s);
            s
        }).collect();
        // The page to switch to is the first other page with a widget of its own.
        let (other, _) = page_ids.iter().enumerate().skip(1).find(|(_, s)| !s.is_empty())
            .expect("a second page with an addressable widget");
        assert!(page_ids[0].is_disjoint(&page_ids[other]), "the two pages share no id");

        let e = engine_on("rect_with_stroke.svg");
        let (reply, err) = dispatch(e, r#"{"action":"open_print_dialog","params":{}}"#);
        assert!(reply.contains(r#""dialog":"print""#), "{reply} {err}");
        let plan = |e| -> Vec<serde_json::Value> {
            let v: serde_json::Value = serde_json::from_str(&take(unsafe { jas_dialog_plan(e, 720, 640) })).unwrap();
            v["plan"]["leaves"].as_array().expect("an open dialog's plan").clone()
        };
        let planned = |leaves: &[serde_json::Value]| -> BTreeSet<String> {
            leaves.iter().filter_map(|l| l["id"].as_str()).filter(|s| !s.is_empty()).map(str::to_string).collect()
        };
        let tab_id = tabs["id"].as_str().expect("the tabs node's id");
        let strip_of = |leaves: &[serde_json::Value]| -> serde_json::Value {
            leaves.iter().find(|l| l["id"] == tab_id).unwrap_or_else(|| panic!("no strip leaf {tab_id}: {leaves:?}")).clone()
        };
        let want = |active: usize| -> serde_json::Value {
            serde_json::Value::Array(pages.iter().enumerate().map(|(i, p)| serde_json::json!({
                "kind": "option", "value": p["id"], "label": p["label"], "selected": i == active})).collect())
        };
        let mut seen = vec![];
        for (to, from) in [(other, 0), (0, other)] {
            let leaves = plan(e);
            let strip = strip_of(&leaves);
            assert_eq!(strip["type"], "select", "{strip}");
            assert_eq!(strip["options"], want(from), "the strip's options and its selection");
            let ids = planned(&leaves);
            assert!(page_ids[from].is_subset(&ids), "page {from} is planned: missing {:?}",
                    page_ids[from].difference(&ids).collect::<Vec<_>>());
            assert!(ids.is_disjoint(&page_ids[to]), "page {to} is not: {:?}",
                    ids.intersection(&page_ids[to]).collect::<Vec<_>>());
            let ev = serde_json::json!({"widget": tab_id, "event": "change", "value": pages[to]["id"]}).to_string();
            let (reply, err) = dialog_event(e, &ev);
            assert!(!reply.is_empty(), "the switch to {to} ran: {err}");
            seen.push(engine_of(e).store.borrow().eval_context()["dialog"]["active_tab"].clone());
        }
        assert_eq!(seen, vec![pages[other]["id"].clone(), pages[0]["id"].clone()], "the bind wrote each tab id");
        unsafe { jas_engine_free(e) };
    }

    fn dialog_event(e: *mut JasEngine, json: &str) -> (String, String) {
        let reply = take(unsafe { jas_dialog_event(e, json.as_ptr(), json.len()) });
        (reply, take(unsafe { jas_last_error_json(e) }))
    }

    /// The plan path of the open dialog's leaf of `kind` whose static text
    /// contains `label` (a button carries no id, so a shell addresses it by
    /// the path the plan gave it).
    fn dialog_leaf_path(e: *mut JasEngine, kind: &str, label: &str) -> serde_json::Value {
        let v: serde_json::Value =
            serde_json::from_str(&take(unsafe { jas_dialog_plan(e, 420, 640) })).unwrap();
        let leaves = v["plan"]["leaves"].as_array().expect("an open dialog's plan");
        leaves.iter().find(|l| l["type"] == kind && l.to_string().contains(label))
            .unwrap_or_else(|| panic!("no {kind} leaf with {label:?}: {leaves:?}"))["path"].clone()
    }

    /// THE DIALOG DOOR, the event: a commit or a press on an open dialog's
    /// widget writes the DIALOG's own field (`dialog.<key>`), as the
    /// reference's `widget_event` writes a widget with no panel. Nothing is
    /// mirrored into a global, and no panel is made active.
    #[test]
    fn dialog_event_commits_and_presses_write_the_open_dialogs_own_fields() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("multi_layer.svg");
        let _ = dispatch(e, r#"{"action":"open_layer_options","params":{"mode":"create"}}"#);
        let (active, globals) = {
            let store = engine_of(e).store.borrow();
            assert_eq!(store.dialog_id(), Some("layer_options"));
            (store.active_panel_id().map(str::to_string), store.eval_context()["state"].clone())
        };
        let (reply, err) = dialog_event(e, r#"{"widget":"lo_name_input","event":"commit","value":"Ink"}"#);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["dialog"], "layer_options", "{reply}");
        assert!(err.is_empty(), "a commit that moved the dialog clears the channel: {err}");
        let lock = engine_of(e).store.borrow().get_dialog("lock").clone();
        let (reply, err) = dialog_event(e, r#"{"widget":"lo_lock","event":"click"}"#);
        assert!(!reply.is_empty(), "the press ran: {err}");
        let store = engine_of(e).store.borrow();
        assert_eq!(store.get_dialog("name"), &serde_json::json!("Ink"), "the commit wrote dialog.name");
        assert_eq!(store.get_dialog("lock"), &serde_json::Value::Bool(!lock.as_bool().unwrap_or(false)),
                   "the press negated dialog.lock ({lock})");
        assert_eq!(store.active_panel_id().map(str::to_string), active, "no panel was made active");
        assert_eq!(store.eval_context()["state"], globals, "a dialog field mirrors no global");
        drop(store);
        // Both ways: the second press reads the FIRST press's write from the
        // dialog's own scope, so a scope without `dialog.*` cannot turn it back.
        let (reply, err) = dialog_event(e, r#"{"widget":"lo_lock","event":"click"}"#);
        assert!(!reply.is_empty(), "the second press ran: {err}");
        assert_eq!(engine_of(e).store.borrow().get_dialog("lock"), &lock,
                   "the second press restored dialog.lock");
        assert!(dialog_leaf_path(e, "text_input", "Ink").is_array(), "the plan shows the committed name");
        unsafe { jas_engine_free(e) };
    }

    /// WIDGET_EVENTS.md, "Checking a radio": a press CHECKS a radio through
    /// its `on_check` and never unchecks it. Shear Options' three axis radios
    /// share `dialog.axis` through their own comparisons. (The dialog opens
    /// from a tool event, so the store opens it here.)
    #[test]
    fn dialog_event_checks_a_radio_and_a_checked_radio_is_refused_by_name() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("multi_layer.svg");
        engine_of(e).store.borrow_mut().init_dialog(
            "shear_options", [("axis".to_string(), serde_json::json!("horizontal"))].into(), None);
        let (reply, err) = dialog_event(e, r#"{"widget":"sho_axis_vertical","event":"click"}"#);
        assert!(!reply.is_empty(), "the check ran: {err}");
        assert_eq!(engine_of(e).store.borrow().get_dialog("axis"), &serde_json::json!("vertical"));
        let (reply, err) = dialog_event(e, r#"{"widget":"sho_axis_vertical","event":"change"}"#);
        assert!(reply.is_empty() && err.contains("AlreadyChecked"), "a checked radio: {reply} {err}");
        assert_eq!(engine_of(e).store.borrow().get_dialog("axis"), &serde_json::json!("vertical"));
        let (reply, err) = dialog_event(e, r#"{"widget":"sho_axis_custom","event":"click"}"#);
        assert!(!reply.is_empty(), "the control: an unchecked sibling checks: {err}");
        assert_eq!(engine_of(e).store.borrow().get_dialog("axis"), &serde_json::json!("custom"));
        unsafe { jas_engine_free(e) };
    }

    /// WIDGET_EVENTS.md, "Picking a radio option": the Color Picker's six
    /// one-option groups share `dialog.radio_channel`; a pick writes the
    /// option's id. The comparison is as TEXT, so a whole number the engine
    /// holds as 2.0 matches the id "2" (the reference's int/float note).
    #[test]
    fn dialog_event_picks_a_radio_option_by_id() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("multi_layer.svg");
        let _ = dispatch(e,
            r##"{"action":"open_color_picker","params":{"target":"dialog.color","color":"#4a90d9"}}"##);
        assert_eq!(engine_of(e).store.borrow().dialog_id(), Some("color_picker"));
        let (reply, err) = dialog_event(e, r#"{"widget":"cp_radio_s","event":"toggle","value":"s"}"#);
        assert!(!reply.is_empty(), "the pick ran: {err}");
        assert_eq!(engine_of(e).store.borrow().get_dialog("radio_channel"), &serde_json::json!("s"));
        let (reply, err) = dialog_event(e, r#"{"widget":"cp_radio_s","event":"toggle","value":"s"}"#);
        assert!(reply.is_empty() && err.contains("AlreadyChecked"), "{reply} {err}");
        for (ev, class) in [(r#"{"widget":"cp_radio_h","event":"toggle","value":"x"}"#, "BadValue"),
                            (r#"{"widget":"cp_radio_h","event":"toggle"}"#, "MissingValue"),
                            (r#"{"widget":"cp_radio_h","event":"click","value":"h"}"#, "WrongEvent")] {
            let (reply, err) = dialog_event(e, ev);
            assert!(reply.is_empty() && err.contains(class), "{ev}: {reply} {err}");
            assert_eq!(engine_of(e).store.borrow().get_dialog("radio_channel"), &serde_json::json!("s"));
        }
        let (reply, err) = dialog_event(e, r#"{"widget":"cp_radio_h","event":"toggle","value":"h"}"#);
        assert!(!reply.is_empty(), "the control: another option picks: {err}");
        engine_of(e).store.borrow_mut().set_dialog("radio_channel", serde_json::json!(2.0));
        assert_eq!(crate::panel_behavior::option_text(&crate::interpreter::expr::eval(
            "dialog.radio_channel", &engine_of(e).store.borrow().eval_context())).as_deref(), Some("2"),
            "a whole number reads as its integer text");
        unsafe { jas_engine_free(e) };
    }

    /// A tool's resolved dialog params travel as literals that evaluate back
    /// to themselves, through the same evaluator the `open_dialog` effect uses.
    #[test]
    fn a_tool_param_literal_evaluates_back_to_its_value() {
        for v in [serde_json::json!("ab12"), serde_json::json!(3.5), serde_json::json!(2),
                  serde_json::json!(true), serde_json::Value::Null] {
            let expr = super::tool_param_literal(&v).unwrap_or_else(|| panic!("{v} has a literal"));
            let back = crate::interpreter::effects::value_to_json(&crate::interpreter::expr::eval(&expr, &serde_json::json!({})));
            assert_eq!(back.as_f64().map(|f| serde_json::json!(f)).unwrap_or(back.clone()),
                       v.as_f64().map(|f| serde_json::json!(f)).unwrap_or(v.clone()), "{expr}");
        }
        assert_eq!(super::tool_param_literal(&serde_json::json!("it's")), None, "a quote cannot be escaped");
        assert_eq!(super::tool_param_literal(&serde_json::json!([1])), None);
    }

    /// The dialog's scope carries the ACTIVE PANEL's `panel.*`, as the
    /// reference's store does (`eval_context` with a dialog open). Artboard
    /// Options opens from the Artboards panel and reads its
    /// `panel.reference_point` (the 3x3 widget and the X / Y display); the
    /// engine's scope carried only `dialog` and `param`, so it read "" (flask
    /// STATUS §281).
    #[test]
    fn the_dialog_scope_reads_the_active_panels_fields() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("multi_layer.svg");
        {
            let mut store = engine_of(e).store.borrow_mut();
            store.init_panel("artboards", [("reference_point".to_string(), serde_json::json!("top_left"))].into());
            store.set_active_panel(Some("artboards"));
            store.init_dialog("artboard_options", [("width".to_string(), serde_json::json!(100.0))].into(), None);
        }
        let v: serde_json::Value =
            serde_json::from_str(&take(unsafe { jas_dialog_plan(e, 380, 640) })).unwrap();
        fn find<'a>(n: &'a serde_json::Value, id: &str) -> Option<&'a serde_json::Value> {
            if n.get("id").and_then(|v| v.as_str()) == Some(id) { return Some(n); }
            match n {
                serde_json::Value::Object(m) => m.values().find_map(|v| find(v, id)),
                serde_json::Value::Array(a) => a.iter().find_map(|v| find(v, id)),
                _ => None,
            }
        }
        let leaf = find(&v, "ao_reference_point").expect("the widget is planned");
        assert_eq!(leaf["values"]["bind.value"], "top_left", "{leaf}");
        unsafe { jas_engine_free(e) };
    }

    /// The reference-point widget is an input kind: a commit of an anchor runs
    /// its `change`, `set_artboard_reference_point` with `anchor: event.value`,
    /// which writes the Artboards panel's preference. Before it joined the
    /// contract the engine's click path carried no value, so the anchor was null.
    #[test]
    fn dialog_event_commits_a_reference_point_anchor() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("multi_layer.svg");
        {
            let mut store = engine_of(e).store.borrow_mut();
            store.init_panel("artboards", [("reference_point".to_string(), serde_json::json!("center"))].into());
            store.set_active_panel(Some("artboards"));
            store.init_dialog("artboard_options", [("width".to_string(), serde_json::json!(100.0))].into(), None);
        }
        let (reply, err) = dialog_event(e, r#"{"widget":"ao_reference_point","event":"change","value":"top_left"}"#);
        assert!(!reply.is_empty(), "the commit ran: {err}");
        assert_eq!(engine_of(e).store.borrow().get_panel("artboards", "reference_point"),
                   &serde_json::json!("top_left"));
        let (reply, err) = dialog_event(e, r#"{"widget":"ao_reference_point","event":"change","value":"middle_center"}"#);
        assert!(reply.is_empty() && err.contains("BadValue"), "not an anchor: {reply} {err}");
        unsafe { jas_engine_free(e) };
    }

    /// Artboard Options' orientation pair: Landscape on a portrait dialog runs
    /// `toggle_artboard_orientation`, now YAML effects (flask STATUS §290, it
    /// was a `log:` stub refused as a platform effect). Around the centre
    /// anchor, 100x200 at (10, 20) becomes 200x100 at (-40, 70), as the
    /// reference's `test_artboard_orientation.py` derives.
    #[test]
    fn dialog_event_landscape_swaps_the_artboard_around_its_anchor() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("multi_layer.svg");
        {
            let mut store = engine_of(e).store.borrow_mut();
            store.init_panel("artboards", [("reference_point".to_string(), serde_json::json!("center"))].into());
            store.set_active_panel(Some("artboards"));
            store.init_dialog("artboard_options", [
                ("width".to_string(), serde_json::json!(100.0)), ("height".to_string(), serde_json::json!(200.0)),
                ("x_stored".to_string(), serde_json::json!(10.0)), ("y_stored".to_string(), serde_json::json!(20.0)),
            ].into(), None);
        }
        let (reply, err) = dialog_event(e, r#"{"widget":"ao_orientation","event":"commit","value":"landscape"}"#);
        assert!(!reply.is_empty(), "the toggle ran: {err}");
        let store = engine_of(e).store.borrow();
        let n = |k: &str| store.get_dialog(k).as_f64().unwrap_or(f64::NAN);
        assert_eq!((n("width"), n("height"), n("x_stored"), n("y_stored")), (200.0, 100.0, -40.0, 70.0));
        drop(store);
        let (reply, err) = dialog_event(e, r#"{"widget":"ao_orientation","event":"commit","value":"landscape"}"#);
        assert!(reply.is_empty() || err.contains("Unchanged"), "the shown orientation runs nothing: {reply} {err}");
        unsafe { jas_engine_free(e) };
    }

    /// A dialog's buttons have no ids: the shell clicks one by its PLAN path,
    /// and the button's YAML action runs. Cancel on Save Changes closes it.
    #[test]
    fn dialog_event_clicks_a_button_by_its_plan_path() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("rect_with_stroke.svg");
        for act in [r#"{"action":"select_all","params":{}}"#,
                    r#"{"action":"set_stroke_cap","params":{"cap":"square"}}"#,
                    r#"{"action":"close_tab","params":{"index":0}}"#] {
            let _ = dispatch(e, act);
        }
        assert_eq!(engine_of(e).store.borrow().dialog_id(), Some("save_changes_tab"));
        let path = dialog_leaf_path(e, "button", "Cancel");
        let ev = serde_json::json!({"path": path, "event": "click"}).to_string();
        let (reply, err) = dialog_event(e, &ev);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["dialog"], serde_json::Value::Null, "Cancel closed the dialog: {reply}");
        assert_eq!(engine_of(e).store.borrow().dialog_id(), None);
        unsafe { jas_engine_free(e) };
    }

    /// The nested law (#416) through the shell's door: the swatch in Layer
    /// Options opens the Color Picker OVER it, and the picker's OK returns
    /// its colour to the parent's `dialog.color`, leaving the app's colours
    /// alone. The picker's colour is set in its store, as a drag on its
    /// gradient would leave it.
    #[test]
    fn dialog_event_returns_the_nested_pickers_colour_to_its_parent() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("multi_layer.svg");
        let _ = dispatch(e, r#"{"action":"open_layer_options","params":{"mode":"create"}}"#);
        let (reply, err) = dialog_event(e, r#"{"widget":"lo_color_swatch","event":"click"}"#);
        assert!(reply.contains(r#""dialog":"color_picker""#), "the swatch opened the picker: {reply} {err}");
        let app = {
            let mut store = engine_of(e).store.borrow_mut();
            assert_eq!(store.dialog_depth(), 2, "nested over Layer Options");
            store.set_dialog("color", serde_json::json!("#12ab34"));
            (store.get("fill_color").clone(), store.get("stroke_color").clone())
        };
        let ev = serde_json::json!({"path": dialog_leaf_path(e, "button", "OK"), "event": "click"}).to_string();
        let (reply, err) = dialog_event(e, &ev);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["dialog"], "layer_options", "OK returned to the parent: {reply}");
        let store = engine_of(e).store.borrow();
        assert_eq!(store.dialog_depth(), 1);
        assert_eq!(store.get_dialog("color"), &serde_json::json!("#12ab34"), "the parent took the result");
        assert_eq!((store.get("fill_color").clone(), store.get("stroke_color").clone()), app,
                   "a dialog-field target writes no app colour");
        drop(store);
        unsafe { jas_engine_free(e) };
    }

    /// The nested Color Picker's derived fields read their values in the plan
    /// the shell draws (flask §545 finding E: over Artboard Options its setter
    /// ran and every channel field read empty).
    #[test]
    fn the_nested_pickers_derived_fields_read_in_its_plan() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("multi_layer.svg");
        let _ = dispatch(e, r#"{"action":"open_layer_options","params":{"mode":"create"}}"#);
        let (reply, err) = dialog_event(e, r#"{"widget":"lo_color_swatch","event":"click"}"#);
        assert!(reply.contains(r#""dialog":"color_picker""#), "the swatch opened the picker: {reply} {err}");
        engine_of(e).store.borrow_mut().set_dialog("color", serde_json::json!("#12ab34"));
        assert_eq!(engine_of(e).store.borrow().eval_context()["dialog"]["hex"], serde_json::json!("12ab34"),
                   "the store's dialog scope carries the getter");
        let plan = take(unsafe { jas_dialog_plan(e, 420, 640) });
        let v: serde_json::Value = serde_json::from_str(&plan).unwrap();
        let mut leaves = Vec::new();
        fn walk(n: &serde_json::Value, out: &mut Vec<serde_json::Value>) {
            match n {
                serde_json::Value::Object(m) => {
                    if m.get("id").and_then(|i| i.as_str()).is_some_and(|i| i == "cp_hex" || i == "cp_r") {
                        out.push(n.clone());
                    }
                    m.values().for_each(|c| walk(c, out));
                }
                serde_json::Value::Array(a) => a.iter().for_each(|c| walk(c, out)),
                _ => {}
            }
        }
        walk(&v["plan"], &mut leaves);
        assert_eq!(leaves.len(), 2, "the plan has cp_hex and cp_r: {leaves:?}");
        let shown: Vec<String> = leaves.iter().map(|l| l["values"]["bind.value"].to_string()).collect();
        assert_eq!(shown, [r#""18""#, r#""12ab34""#], "cp_r and cp_hex show the colour: {leaves:?}");
        unsafe { jas_engine_free(e) };
    }

    /// Document Setup's OK commits through the engine (flask STATUS §270: it
    /// was refused as `UnknownDocEffect:doc.set_document_setup_field`). The
    /// eight print-config `doc.*_field` effects reach the document through
    /// `op_apply`, the verb the web's renderer already calls.
    #[test]
    fn document_setup_ok_commits_its_fields_on_the_engine() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("rect_with_stroke.svg");
        let (reply, err) = dispatch(e, r#"{"action":"open_document_setup"}"#);
        assert!(reply.contains(r#""dialog":"document_setup""#), "{reply} {err}");
        // flask STATUS §270: the plan names the dialog's declared width, so
        // the shell can size its layer (the workspace declares 300 to 720).
        let plan: serde_json::Value = serde_json::from_str(&take(unsafe { jas_dialog_plan(e, 420, 0) })).unwrap();
        let declared = crate::interpreter::workspace::Workspace::load().unwrap()
            .dialog("document_setup").unwrap()["width"].clone();
        assert!(declared.is_number(), "Document Setup declares a width: {declared}");
        assert_eq!(plan["width"], declared);
        let (reply, err) = dialog_event(e, r#"{"widget":"ds_grid_size","event":"commit","value":"42"}"#);
        assert!(!reply.is_empty(), "the grid size committed: {err}");
        assert_eq!(engine_of(e).store.borrow().get_dialog("grid_size").as_f64(), Some(42.0));
        let ev = serde_json::json!({"path": dialog_leaf_path(e, "button", "OK"), "event": "click"}).to_string();
        let (reply, err) = dialog_event(e, &ev);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["dialog"], serde_json::Value::Null, "OK closed the dialog: {reply}");
        assert_eq!(engine_of(e).model.borrow().document().document_setup.grid_size, 42.0,
                   "the document took the dialog's value");
        unsafe { jas_engine_free(e) };
    }

    /// SAVE CHANGES' DISCARD REMOVES THE TAB (design 2026-10-14 §10): the
    /// engine owns no tabs, so it NAMES the removal in its reply
    /// (`"remove_tab": <index>`) and the shell removes that tab. `close_tab`
    /// passes the index into the dialog, and Discard passes it on.
    #[test]
    fn discard_names_the_tab_to_remove_and_cancel_names_none() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("rect_with_stroke.svg");
        let ask = |e| {
            for act in [r#"{"action":"select_all","params":{}}"#,
                        r#"{"action":"set_stroke_cap","params":{"cap":"square"}}"#,
                        r#"{"action":"close_tab","params":{"index":2}}"#] {
                let _ = dispatch(e, act);
            }
            assert_eq!(engine_of(e).store.borrow().dialog_id(), Some("save_changes_tab"));
        };
        ask(e);
        let ev = serde_json::json!({"path": dialog_leaf_path(e, "button", "Cancel"), "event": "click"}).to_string();
        let (reply, err) = dialog_event(e, &ev);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["remove_tab"], serde_json::Value::Null, "Cancel keeps the tab: {reply}");
        ask(e);
        let ev = serde_json::json!({"path": dialog_leaf_path(e, "button", "Discard"), "event": "click"}).to_string();
        let (reply, err) = dialog_event(e, &ev);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["dialog"], serde_json::Value::Null, "Discard closed the dialog: {reply}");
        assert_eq!(v["remove_tab"], 2, "the tab the dialog asked about: {reply}");
        unsafe { jas_engine_free(e) };
    }

    /// An UNEDITED tab closes at once: `close_tab`'s else-arm dispatches
    /// `remove_tab`, which the engine names instead of refusing it as
    /// `UnknownEffect:remove_child` (measured before this, 2026-10-14).
    #[test]
    fn close_tab_on_an_unedited_document_names_the_tab_to_remove() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("rect_with_stroke.svg");
        let (reply, err) = dispatch(e, r#"{"action":"close_tab","params":{"index":0}}"#);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["remove_tab"], 0, "{reply} {err}");
        assert_eq!(v["dialog"], serde_json::Value::Null);
        unsafe { jas_engine_free(e) };
    }

    /// QUIT names the window close, as `close_tab` names a tab removal: the
    /// engine owns no window, so `quit` with nothing edited, and Save Changes'
    /// Don't Save, reply `"close_window": true` for the shell to act on. Until
    /// 2026-10-15 the first was a log line (`PlatformEffect Logged:quit: close
    /// window`), which a shell could read only as prose (flask STATUS # 298).
    #[test]
    fn quit_names_the_window_close_and_an_edit_asks_first() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("rect_with_stroke.svg");
        let (reply, err) = dispatch(e, r#"{"action":"quit","params":{}}"#);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["close_window"], true, "nothing edited: the window closes ({reply} {err})");
        assert_eq!(v["dialog"], serde_json::Value::Null);
        unsafe { jas_engine_free(e) };

        let e = engine_on("rect_with_stroke.svg");
        let _ = dispatch(e, r#"{"action":"select_all","params":{}}"#);
        let _ = dispatch(e, r#"{"action":"set_stroke_cap","params":{"cap":"square"}}"#);
        let (reply, err) = dispatch(e, r#"{"action":"quit","params":{}}"#);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["dialog"], "save_changes_window", "an edit asks first: {reply} {err}");
        assert_eq!(v["close_window"], false, "and does not close yet: {reply}");
        let ev = serde_json::json!({"path": dialog_leaf_path(e, "button", "Don't Save"), "event": "click"}).to_string();
        let (reply, err) = dialog_event(e, &ev);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["dialog"], serde_json::Value::Null, "Don't Save closed the dialog: {reply}");
        assert_eq!(v["close_window"], true, "and names the window close: {reply} {err}");
        unsafe { jas_engine_free(e) };
    }

    /// The paragraph wrapper the engine's document holds for its first text.
    fn first_wrapper(e: *mut JasEngine) -> crate::geometry::tspan::Tspan {
        let model = engine_of(e).model.borrow();
        crate::interpreter::paragraph_host::selected_wrappers(model.document())
            .into_iter().next().expect("the selection holds a paragraph wrapper")
    }

    /// JUSTIFICATION'S OK WRITES THE DOCUMENT IN THE ENGINE, as the web app's
    /// does. Until 2026-10-15 only the web renderer handled
    /// `paragraph_justification_confirm`, so OK on the engine closed the dialog
    /// and wrote nothing. A field the person changed is written; a field left
    /// at the paragraph's own value stays; one undo takes the whole OK back.
    #[test]
    fn justification_ok_writes_the_wrappers_in_the_engine() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("paragraph_justified.svg");
        let _ = dispatch(e, r#"{"action":"select_all","params":{}}"#);
        assert_eq!(first_wrapper(e).jas_word_spacing_min, Some(70.0), "the fixture's own value");
        let (reply, err) = dispatch(e, r#"{"action":"open_paragraph_justification","params":{}}"#);
        assert!(reply.contains("paragraph_justification"), "the dialog opened: {reply} {err}");
        let (reply, err) = dialog_event(e, r#"{"widget":"pj_word_spacing_min","event":"commit","value":"60"}"#);
        assert!(!reply.is_empty(), "the commit ran: {err}");
        let ev = serde_json::json!({"path": dialog_leaf_path(e, "button", "OK"), "event": "click"}).to_string();
        let (reply, err) = dialog_event(e, &ev);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["dialog"], serde_json::Value::Null, "OK closed the dialog: {reply}");
        assert_eq!(v["doc_changed"], true, "OK wrote the document: {reply} {err}");
        let w = first_wrapper(e);
        assert_eq!(w.jas_word_spacing_min, Some(60.0), "the changed field is written");
        assert_eq!(w.jas_word_spacing_desired, Some(95.0), "an untouched field keeps the paragraph's value");
        assert_eq!(w.jas_single_word_justify.as_deref(), Some("left"), "and so does the select");
        undo(e); // the shell sends undo as an op
        assert_eq!(first_wrapper(e).jas_word_spacing_min, Some(70.0), "one undo takes the OK back");
        unsafe { jas_engine_free(e) };
    }

    /// HYPHENATION'S OK WRITES THE DOCUMENT IN THE ENGINE, the same law: the
    /// master checkbox and a detail field reach the wrapper.
    #[test]
    fn hyphenation_ok_writes_the_wrappers_in_the_engine() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("paragraph_justified.svg");
        let _ = dispatch(e, r#"{"action":"select_all","params":{}}"#);
        assert_eq!(first_wrapper(e).jas_hyphenate, None, "the fixture does not hyphenate");
        let (reply, err) = dispatch(e, r#"{"action":"open_paragraph_hyphenation","params":{}}"#);
        assert!(reply.contains("paragraph_hyphenation"), "the dialog opened: {reply} {err}");
        let (reply, err) = dialog_event(e, r#"{"widget":"ph_master","event":"click"}"#);
        assert!(!reply.is_empty(), "the master press ran: {err}");
        let (reply, err) = dialog_event(e, r#"{"widget":"ph_min_word","event":"commit","value":"8"}"#);
        assert!(!reply.is_empty(), "the commit ran: {err}");
        let ev = serde_json::json!({"path": dialog_leaf_path(e, "button", "OK"), "event": "click"}).to_string();
        let (reply, err) = dialog_event(e, &ev);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["dialog"], serde_json::Value::Null, "OK closed the dialog: {reply}");
        assert_eq!(v["doc_changed"], true, "OK wrote the document: {reply} {err}");
        let w = first_wrapper(e);
        assert_eq!(w.jas_hyphenate, Some(true), "the master is written");
        assert_eq!(w.jas_hyphenate_min_word, Some(8.0), "and the changed detail field");
        assert_eq!(w.jas_hyphenate_min_before, None, "a field at its default is omitted");
        unsafe { jas_engine_free(e) };
    }

    /// SAVE ALL names "save every document, then close", as Don't Save names
    /// the window close. The engine can neither save nor close, so Save
    /// Changes' Save All replies `"save_all_then_close": true` and NOT
    /// `close_window`: a shell that closed on `close_window` before saving
    /// would lose the edits. Until 2026-10-15 Save All was a log line and did
    /// nothing in the engine (flask STATUS # 301, jas # 303).
    #[test]
    fn save_all_names_save_then_close_and_never_the_bare_close() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("rect_with_stroke.svg");
        let _ = dispatch(e, r#"{"action":"select_all","params":{}}"#);
        let _ = dispatch(e, r#"{"action":"set_stroke_cap","params":{"cap":"square"}}"#);
        let (reply, err) = dispatch(e, r#"{"action":"quit","params":{}}"#);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["dialog"], "save_changes_window", "an edit asks first: {reply} {err}");
        assert_eq!(v["save_all_then_close"], false, "asking is not saving: {reply}");
        let ev = serde_json::json!({"path": dialog_leaf_path(e, "button", "Save All"), "event": "click"}).to_string();
        let (reply, err) = dialog_event(e, &ev);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["dialog"], serde_json::Value::Null, "Save All closed the dialog: {reply}");
        assert_eq!(v["save_all_then_close"], true, "and names save-then-close: {reply} {err}");
        assert_eq!(v["close_window"], false, "and never the bare close: {reply}");
        assert_eq!(err, "", "nothing refused: {reply}");
        unsafe { jas_engine_free(e) };
    }

    /// The door's refusals run nothing: no dialog open is `NoDialog`; a
    /// disabled widget is `Disabled`; a bad event is `BadJson`; a null engine
    /// is the empty span.
    #[test]
    fn dialog_event_refusals_run_nothing() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("multi_layer.svg");
        let (reply, err) = dialog_event(e, r#"{"widget":"lo_lock","event":"click"}"#);
        assert_eq!(reply, "");
        assert!(err.contains(r#""panel_event":"NoDialog""#), "{err}");
        let _ = dispatch(e, r#"{"action":"open_layer_options","params":{"mode":"create"}}"#);
        let before = engine_of(e).store.borrow().eval_context();
        let (reply, err) = dialog_event(e, r#"{"widget":"lo_template","event":"click"}"#);
        assert_eq!(reply, "");
        assert!(err.contains(r#""panel_event":"Disabled""#), "{err}");
        let (reply, err) = dialog_event(e, "{not json");
        assert_eq!(reply, "");
        assert!(err.contains(r#""panel_event":"BadJson""#), "{err}");
        assert_eq!(engine_of(e).store.borrow().eval_context(), before, "a refusal changed nothing");
        let ev = r#"{"widget":"lo_lock","event":"click"}"#;
        assert_eq!(take(unsafe { jas_dialog_event(std::ptr::null_mut(), ev.as_ptr(), ev.len()) }), "");
        unsafe { jas_engine_free(e) };
    }

    /// Use Preview Bounds is a toggle on the engine's route too: its
    /// `state.align_use_preview_bounds` is the store's, so a second press
    /// turns it back off (the web route could not; see the renderer's arm).
    #[test]
    fn dispatch_toggle_use_preview_bounds_turns_on_and_back_off() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let read = |e| engine_of(e).store.borrow().get("align_use_preview_bounds").clone();
        assert_eq!(read(e), serde_json::json!(false), "starts off");
        let _ = dispatch(e, r#"{"action":"toggle_use_preview_bounds"}"#);
        assert_eq!(read(e), serde_json::json!(true));
        let _ = dispatch(e, r#"{"action":"toggle_use_preview_bounds"}"#);
        assert_eq!(read(e), serde_json::json!(false), "the second press turns it off");
        unsafe { jas_engine_free(e) };
    }

    fn engine_on(fixture: &str) -> *mut JasEngine {
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/..");
        let svg = std::fs::read_to_string(format!("{root}/test_fixtures/svg/{fixture}")).unwrap();
        let e = jas_engine_new();
        engine_of(e).replace_document(crate::geometry::svg::try_svg_to_document(&svg).unwrap());
        e
    }

    /// BRUSH OPTIONS IN LIBRARY_EDIT LOADS THE BRUSH IT EDITS, in the engine.
    /// Its inits find the brush by `filter(...brushes, fun b -> b.slug == ...)[0]`;
    /// until 2026-10-15 they read a `brushes_by_slug` index no port builds, so
    /// every edit-mode init was null. Create mode keeps the declared defaults.
    #[test]
    fn brush_options_library_edit_loads_the_brush_in_the_engine() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("rect_with_stroke.svg");
        let (reply, err) = dispatch(e, r#"{"action":"open_brush_options","params":{"mode":"library_edit","library":"default_brushes","brush_slug":"round_7pt"}}"#);
        assert!(reply.contains("brush_options"), "the dialog opened: {reply} {err}");
        let got: Vec<serde_json::Value> = ["brush_name", "brush_type", "angle", "roundness", "size"].iter()
            .map(|k| engine_of(e).store.borrow().get_dialog(k).clone()).collect();
        assert_eq!(serde_json::json!(got), serde_json::json!(["7 pt. Round", "calligraphic", 0, 100, 7]));
        unsafe { jas_engine_free(e) };

        let e = engine_on("rect_with_stroke.svg");
        let _ = dispatch(e, r#"{"action":"open_brush_options","params":{"mode":"create"}}"#);
        let got: Vec<serde_json::Value> = ["brush_name", "brush_type", "angle", "roundness", "size"].iter()
            .map(|k| engine_of(e).store.borrow().get_dialog(k).clone()).collect();
        assert_eq!(serde_json::json!(got), serde_json::json!(["", "calligraphic", 0, 100, 5]));
        unsafe { jas_engine_free(e) };
    }

    /// `delete_selection` BY ACTION, the route a tool's YAML takes (the
    /// Artboard tool's Delete dispatches it) and the action corpus runs. Since
    /// 2026-10-26 the engine runs its `actions.yaml` body: nothing selected
    /// changes nothing; an orphan (`active_document.selection_orphan_count`)
    /// opens `delete_orphan_confirm` and deletes nothing until its Delete;
    /// otherwise one undo step. (Until 10-15 the body was a `log` and the
    /// engine ran nothing; until 10-26 a native host ran the law.)
    #[test]
    fn delete_selection_by_action_runs_the_delete_keys_law() {
        let _counters = crate::ffi_instr::test_lock::lock();
        const DELETE: &str = r#"{"action":"delete_selection","params":{}}"#;
        let e = engine_on("rect_with_stroke.svg");
        let before = doc_json(e);
        let (reply, err) = dispatch(e, DELETE);
        assert_eq!(doc_json(e), before, "nothing selected: nothing deleted ({reply} {err})");

        let _ = dispatch(e, r#"{"action":"select_all","params":{}}"#);
        let path = engine_of(e).with_document(|d| d.selection.iter().next().map(|es| es.path.clone()))
            .expect("the rect");
        engine_of(e).with_model_mut(crate::workspace::menu_native::make_instance);
        engine_of(e).with_model_mut(|m| crate::document::controller::Controller::select_element(m, &path));
        let before = doc_json(e);
        let (reply, err) = dispatch(e, DELETE);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["dialog"], "delete_orphan_confirm", "an orphan asks first: {reply} {err}");
        assert_eq!(doc_json(e), before, "and deletes nothing yet");
        assert_eq!(engine_of(e).store.borrow().dialog_params().and_then(|p| p.get("count")).cloned(),
                   Some(serde_json::json!(1)), "the dialog names the count");
        let ev = serde_json::json!({"path": dialog_leaf_path(e, "button", "Delete"), "event": "click"}).to_string();
        let (reply, err) = dialog_event(e, &ev);
        assert!(!reply.is_empty(), "its Delete ran: {err}");
        assert_ne!(doc_json(e), before, "its Delete deletes");
        unsafe { jas_engine_free(e) };

        let e = engine_on("rect_with_stroke.svg");
        let _ = dispatch(e, r#"{"action":"select_all","params":{}}"#);
        let before = doc_json(e);
        let (reply, err) = dispatch(e, DELETE);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(err, "", "nothing refused: {reply}");
        assert_eq!(v["doc_changed"], true, "no orphan: deleted ({reply})");
        assert_eq!(engine_of(e).with_document(|d| d.selection.len()), 0, "the selection is empty");
        undo(e);
        assert_eq!(doc_json(e), before, "one undo brings it back");
        unsafe { jas_engine_free(e) };
    }

    /// A KEY BY `jas_dispatch_action` (flask STATUS § 310, jas § 311):
    /// `{"key": <name>, "mods": {...}}` is resolved IN THE ENGINE (the active
    /// tool, then `shortcuts.yaml`) and answered with the normal act reply, so
    /// a dialog it opens arrives in `dialog` and the shell holds no binding.
    /// Delete deletes, one undo step; an orphaning Delete names
    /// `delete_orphan_confirm` and deletes nothing; Ctrl+Z undoes; a key name
    /// the engine does not know is refused by name.
    /// The Type tool's named gaps (#596), through the route a shell sends
    /// keys by: in a text session the caret keys move the caret, and Cmd+V
    /// pastes the clipboard's TEXT at it (the web's `tool.paste_text`, before
    /// the element paste), so a paste adds no element. With no session a caret
    /// key is `KeyUnhandled` (the shell's own default), never `BadKey`.
    /// flask §556 finding H: a Ctrl chord the engine does not run itself
    /// (anything but undo, redo and the clipboard verbs, W5-3c) stays the
    /// menu's, but the shell has already kept the chord from the menu's
    /// accelerator, so the refusal NAMES the action `shortcuts.yaml` binds:
    /// `{"panel_event":"KeyUnhandled","detail":<key>,"menu_action":<action>}`,
    /// and the shell runs that menu item. A chord the engine runs, a chord
    /// nothing binds, and a chord a text session takes name nothing.
    #[test]
    fn an_unrun_command_chord_names_the_menu_action_it_binds() {
        use crate::ffi_pointer::{jas_pointer_event, jas_set_tool, KIND_PRESS, KIND_RELEASE, TOOL_IDS};
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("rect_with_stroke.svg");
        let named = |err: &str| serde_json::from_str::<serde_json::Value>(err).ok()
            .and_then(|v| v["menu_action"].as_str().map(str::to_string));
        for (key, shift, action) in [("a", false, "select_all"), ("g", false, "group"),
                                     ("g", true, "ungroup"), ("s", false, "save"),
                                     ("s", true, "save_as"), ("n", false, "new_document"),
                                     ("o", false, "open_file"), ("p", false, "open_print_dialog"),
                                     ("q", false, "quit")] {
            let msg = format!(r#"{{"key":"{key}","mods":{{"ctrl":true,"shift":{shift}}}}}"#);
            let (reply, err) = dispatch(e, &msg);
            assert_eq!(reply, "", "{msg}: the engine does not run it");
            assert!(err.contains("KeyUnhandled"), "{msg}: {err}");
            assert_eq!(named(&err).as_deref(), Some(action), "{msg}: {err}");
        }
        let (_, err) = dispatch(e, r#"{"key":"k","mods":{"ctrl":true}}"#);
        assert!(err.contains("KeyUnhandled") && named(&err).is_none(), "an unbound chord names nothing: {err}");
        let (_, err) = dispatch(e, r#"{"key":"ArrowLeft"}"#);
        assert!(err.contains("KeyUnhandled") && named(&err).is_none(), "a caret key names nothing: {err}");
        let (_, err) = dispatch(e, r#"{"key":"z","mods":{"ctrl":true}}"#);
        assert!(named(&err).is_none(), "undo is the engine's own: {err}");
        let ty = TOOL_IDS.iter().position(|t| *t == "type").expect("the Type tool");
        unsafe {
            assert_eq!(jas_set_tool(e, ty), JasStatus::Ok);
            jas_pointer_event(e, KIND_PRESS, 500.0, 500.0, 0);
            jas_pointer_event(e, KIND_RELEASE, 500.0, 500.0, 0);
        }
        let (_, err) = dispatch(e, r#"{"key":"a","mods":{"ctrl":true}}"#);
        assert!(!err.contains("KeyUnhandled") && named(&err).is_none(), "a text session takes Ctrl+A: {err}");
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn a_text_session_takes_the_caret_keys_and_a_paste_of_text() {
        use crate::ffi_pointer::{jas_pointer_event, jas_set_tool, KIND_PRESS, KIND_RELEASE, TOOL_IDS};
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("rect_with_stroke.svg");
        let (reply, err) = dispatch(e, r#"{"key":"ArrowLeft"}"#);
        assert_eq!(reply, "", "no session: nothing took it");
        assert!(err.contains("KeyUnhandled"), "unhandled, not a bad name: {err}");
        let texts = || engine_of(e).with_model(|m| {
            fn walk(el: &crate::geometry::element::Element, out: &mut Vec<String>) {
                if let crate::geometry::element::Element::Text(t) = el { out.push(t.content()); }
                for c in el.children().unwrap_or(&[]) { walk(c, out); }
            }
            let mut out = vec![];
            for l in &m.document().layers { walk(l, &mut out); }
            out
        });
        let elements = || engine_of(e).with_model(|m| m.document().layers.iter()
            .map(|l| l.children().map_or(0, |c| c.len())).sum::<usize>());
        let ty = TOOL_IDS.iter().position(|t| *t == "type").expect("the Type tool");
        unsafe {
            assert_eq!(jas_set_tool(e, ty), JasStatus::Ok);
            jas_pointer_event(e, KIND_PRESS, 500.0, 500.0, 0);
            jas_pointer_event(e, KIND_RELEASE, 500.0, 500.0, 0);
        }
        for k in ["H", "i", "ArrowLeft"] {
            let (_, err) = dispatch(e, &format!(r#"{{"key":"{k}"}}"#));
            assert!(!err.contains("BadKey") && !err.contains("KeyUnhandled"), "{k}: {err}");
        }
        let count = elements();
        let (_, err) = dispatch(e, r#"{"key":"v","mods":{"ctrl":true},"clipboard":"XY"}"#);
        assert!(!err.contains("NeedsClipboard") && !err.contains("Unchanged"), "the paste ran: {err}");
        assert_eq!(texts(), vec!["HXYi".to_string()], "the text went in at the caret");
        assert_eq!(elements(), count, "a paste into a session adds no element");
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn a_key_by_dispatch_is_resolved_in_the_engine_and_replies() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("rect_with_stroke.svg");
        let _ = dispatch(e, r#"{"action":"select_all","params":{}}"#);
        let before = doc_json(e);
        let (reply, err) = dispatch(e, r#"{"key":"Delete"}"#);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["doc_changed"], true, "Delete deleted: {reply} {err}");
        assert_eq!(engine_of(e).with_document(|d| d.selection.len()), 0);
        let (reply, err) = dispatch(e, r#"{"key":"z","mods":{"ctrl":true}}"#);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["doc_changed"], true, "Ctrl+Z undid: {reply} {err}");
        assert_eq!(doc_json(e), before, "one undo brings it back");
        let (reply, err) = dispatch(e, r#"{"key":"F13"}"#);
        assert_eq!(reply, "", "an unknown key name is refused");
        assert!(err.contains("BadKey"), "by name: {err}");
        unsafe { jas_engine_free(e) };

        let e = engine_on("rect_with_stroke.svg");
        let _ = dispatch(e, r#"{"action":"select_all","params":{}}"#);
        let path = engine_of(e).with_document(|d| d.selection.iter().next().map(|es| es.path.clone()))
            .expect("the rect");
        engine_of(e).with_model_mut(crate::workspace::menu_native::make_instance);
        engine_of(e).with_model_mut(|m| crate::document::controller::Controller::select_element(m, &path));
        let before = doc_json(e);
        let (reply, err) = dispatch(e, r#"{"key":"Backspace"}"#);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["dialog"], "delete_orphan_confirm", "an orphaning key asks, in the reply: {reply} {err}");
        assert_eq!(doc_json(e), before, "and deletes nothing yet");
        unsafe { jas_engine_free(e) };
    }

    /// THE ARROW KEYS NUDGE (the helm's ruling on flask STATUS § 522): an
    /// arrow by the key door moves the selection 1 pt, 10 with Shift, through
    /// `nudge_selection`. Consecutive nudges of one selection are ONE undo step,
    /// as a drag's frames are; an edit between them starts a new one. With
    /// nothing selected it changes nothing and stays `KeyUnhandled`, so the
    /// shell keeps its default.
    #[test]
    fn an_arrow_key_nudges_the_selection_and_a_run_of_nudges_is_one_undo_step() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("rect_with_stroke.svg");
        let before = doc_json(e);
        let (reply, err) = dispatch(e, r#"{"key":"ArrowRight"}"#);
        assert_eq!(reply, "", "nothing selected: nothing took it");
        assert!(err.contains("KeyUnhandled"), "unhandled, so the shell's default: {err}");
        assert_eq!(doc_json(e), before, "and nothing moved");

        let _ = dispatch(e, r#"{"action":"select_all","params":{}}"#);
        // The rect's own x/y: a nudge moves it, so they move by the step.
        let place = || engine_of(e).with_document(|d| {
            let es = d.selection.iter().next().expect("the rect");
            match d.get_element(&es.path) {
                Some(crate::geometry::element::Element::Rect(r)) => (r.x, r.y),
                other => panic!("the fixture's one element is a rect: {other:?}"),
            }
        });
        let (x0, y0) = place();
        let before = doc_json(e);
        let (reply, err) = dispatch(e, r#"{"key":"ArrowRight"}"#);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["doc_changed"], true, "the arrow moved it: {reply} {err}");
        let (x1, y1) = place();
        assert_eq!((x1 - x0, y1 - y0), (1.0, 0.0), "one point right");
        let (_, err) = dispatch(e, r#"{"key":"ArrowUp","mods":{"shift":true}}"#);
        let (x2, y2) = place();
        assert_eq!((x2 - x1, y2 - y1), (0.0, -10.0), "Shift: ten points up ({err})");
        undo(e);
        assert_eq!(doc_json(e), before, "one undo takes back the whole run of nudges");
        // An edit between two nudges ends the run: the second is its own step.
        let (_, err) = dispatch(e, r#"{"key":"ArrowRight"}"#);
        assert_eq!(err, "", "a nudge");
        let after_first = doc_json(e);
        let _ = dispatch(e, r#"{"action":"swap_fill_stroke","params":{}}"#);
        let swapped = doc_json(e);
        assert_ne!(swapped, after_first, "CONTROL: the swap edited the document");
        let _ = dispatch(e, r#"{"key":"ArrowRight"}"#);
        undo(e);
        assert_eq!(doc_json(e), swapped, "undo takes back the nudge after the edit only");
        let (reply, err) = dispatch(e, r#"{"key":"ArrowLeft","mods":{"alt":true}}"#);
        assert!(reply.is_empty() && err.contains("KeyUnhandled"), "Alt+arrow binds nothing: {reply} {err}");
        unsafe { jas_engine_free(e) };
    }

    /// THE KEY HAS ONE DOOR (flask STATUS § 317, #465): the shell sends a key
    /// as `jas_dispatch_action({"key"})`, so `jas_key_event` and its `KEY_*`
    /// codes are no longer part of the C surface. A second door would let a
    /// shell bypass the reply that names a key's dialog.
    #[test]
    fn the_header_exports_one_key_door() {
        // No export is called; the guard is taken because the gate reads this
        // body's string literals as calls (`check_ffi_counter_lock`).
        let _counters = crate::ffi_instr::test_lock::lock();
        let header = include_str!("../include/jas_ffi.h");
        assert!(!header.contains("jas_key_event("), "jas_key_event is not exported");
        assert!(!header.contains("KEY_DELETE"), "nor its key codes");
        assert!(header.contains("jas_dispatch_action("), "the control: the one door is");
    }

    // -----------------------------------------------------------------------
    // THE CLIPBOARD CHANNEL (the Windows clipboard node, slices 2-7). The
    // engine owns no system clipboard, so Copy and Cut NAME the payload in the
    // reply (`clipboard_write`), and a Paste with no `clipboard` field is
    // refused `NeedsClipboard` before anything runs; the shell resends the same
    // request with `"clipboard": <text> | null`.
    // -----------------------------------------------------------------------

    fn reply_of(reply: &str, err: &str) -> serde_json::Value {
        serde_json::from_str(reply).unwrap_or_else(|_| panic!("a reply, not a refusal: {reply:?} {err:?}"))
    }

    /// The first layer's children, as the document's test JSON writes them.
    fn children(e: *mut JasEngine) -> Vec<serde_json::Value> {
        let doc: serde_json::Value = serde_json::from_str(&doc_json(e)).unwrap();
        doc["layers"][0]["children"].as_array().cloned().unwrap_or_default()
    }

    /// Each child's `x`, to 1e-3: the payload is SVG in px, so a pasted edge
    /// round-trips pt -> px -> pt at 4 decimals (34 reads 33.999975).
    fn xs(e: *mut JasEngine) -> Vec<f64> {
        children(e).iter().map(|c| (c["x"].as_f64().expect("a child with an x") * 1000.0).round() / 1000.0).collect()
    }

    /// Two black rects at x 10 and 50, both selected.
    fn two_rects() -> *mut JasEngine {
        use crate::document::test_fixture::{model_with, rect};
        engine_with(model_with(vec![rect(10.0, 20.0, 30.0, 40.0), rect(50.0, 20.0, 30.0, 40.0)], &[0, 1]))
    }

    /// The payload a Copy names: the selection as ONE unnamed layer of SVG, the
    /// bytes `selection_clipboard_svg` builds (the web's and Swift's shape).
    fn copied(e: *mut JasEngine) -> String {
        let (reply, err) = dispatch(e, r#"{"menu_item":"menu_copy"}"#);
        let v = reply_of(&reply, &err);
        assert_eq!(err, "", "a copy that named a payload is not Unchanged");
        v["clipboard_write"].as_str().unwrap_or_else(|| panic!("copy names its payload: {reply}")).to_string()
    }

    fn paste_with(e: *mut JasEngine, item: &str, clip: serde_json::Value) -> (String, String) {
        let req = serde_json::json!({"menu_item": item, "clipboard": clip});
        dispatch(e, &req.to_string())
    }

    #[test]
    fn clipboard_copy_names_the_selection_and_edits_nothing() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = two_rects();
        let before = doc_json(e);
        let payload = copied(e);
        let expected = engine_of(e).with_document(crate::document::op_apply::selection_clipboard_svg);
        assert_eq!(Some(payload.clone()), expected, "the shared builder's bytes, no second format");
        let back = crate::geometry::svg::svg_to_document(&payload);
        assert_eq!(back.layers.len(), 1, "one layer: {payload}");
        assert_eq!(back.layers[0].children().map_or(0, |k| k.len()), 2, "both rects: {payload}");
        assert_eq!(doc_json(e), before, "copy is not an edit");
        assert!(!engine_of(e).with_model(|m| m.can_undo()), "copy recorded an undo step");
        unsafe { jas_engine_free(e) };

        // Nothing selected: nothing to copy, and the engine SAYS so.
        use crate::document::test_fixture::{model_with, rect};
        let e = engine_with(model_with(vec![rect(10.0, 20.0, 30.0, 40.0)], &[]));
        let (reply, err) = dispatch(e, r#"{"menu_item":"menu_copy"}"#);
        assert_eq!(reply_of(&reply, &err)["clipboard_write"], serde_json::Value::Null, "{reply}");
        assert_eq!(err, refusal("Unchanged", "copy"));
        unsafe { jas_engine_free(e) };
    }

    /// Cut = the payload, then the reference-aware delete as ONE undo step.
    #[test]
    fn clipboard_cut_names_the_payload_and_deletes_in_one_undo_step() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = two_rects();
        let before = doc_json(e);
        let expected = engine_of(e).with_document(crate::document::op_apply::selection_clipboard_svg);
        let (reply, err) = dispatch(e, r#"{"menu_item":"menu_cut"}"#);
        let v = reply_of(&reply, &err);
        assert_eq!(v["clipboard_write"].as_str().map(str::to_string), expected, "{reply}");
        assert_eq!(v["doc_changed"], true, "{reply}");
        assert_eq!(v["dialog"], serde_json::Value::Null, "nothing to orphan, nothing to ask: {reply}");
        assert!(children(e).is_empty(), "both rects are gone");
        undo(e);
        assert_eq!(doc_json(e), before, "one undo restores the cut");
        assert!(!engine_of(e).with_model(|m| m.can_undo()), "the cut was ONE step");
        unsafe { jas_engine_free(e) };
    }

    /// A cut that would orphan a live instance asks first (`cut_orphan_confirm`
    /// with its `count`) and writes NOTHING, so Cancel is a true no-op; the
    /// dialog's OK (`doc.copy_selection_to_clipboard` then the delete) names
    /// the payload and deletes.
    #[test]
    fn clipboard_cut_that_would_orphan_asks_first_and_writes_nothing() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("rect_with_stroke.svg");
        let _ = dispatch(e, r#"{"action":"select_all","params":{}}"#);
        let path = engine_of(e).with_document(|d| d.selection.iter().next().map(|es| es.path.clone()))
            .expect("the rect");
        engine_of(e).with_model_mut(crate::workspace::menu_native::make_instance);
        engine_of(e).with_model_mut(|m| crate::document::controller::Controller::select_element(m, &path));
        let before = doc_json(e);
        let expected = engine_of(e).with_document(crate::document::op_apply::selection_clipboard_svg);
        assert!(expected.is_some(), "the control: the master is selected");
        let (reply, err) = dispatch(e, r#"{"menu_item":"menu_cut"}"#);
        let v = reply_of(&reply, &err);
        assert_eq!(v["dialog"], "cut_orphan_confirm", "{reply} {err}");
        assert_eq!(v["clipboard_write"], serde_json::Value::Null, "asking writes nothing: {reply}");
        assert_eq!(doc_json(e), before, "and deletes nothing");
        assert_eq!(engine_of(e).store.borrow().dialog_params().and_then(|p| p.get("count")).cloned(),
                   Some(serde_json::json!(1)), "the orphan count");
        let (reply, err) = dispatch(e, r#"{"action":"cut_orphan_confirm_ok"}"#);
        let v = reply_of(&reply, &err);
        assert_eq!(v["clipboard_write"].as_str().map(str::to_string), expected, "OK names the payload: {reply} {err}");
        assert_eq!(v["dialog"], serde_json::Value::Null, "and closes: {reply}");
        assert_ne!(doc_json(e), before, "and deletes");
        undo(e);
        assert_eq!(doc_json(e), before, "as one undo step");
        unsafe { jas_engine_free(e) };
    }

    /// Paste asks the shell for the clipboard (refused `NeedsClipboard`, the
    /// action as detail, nothing run), then lands through the shared paste law:
    /// +24, then +48 for the same content; in place at 0; empty and unreadable
    /// change nothing; and undo restores the run.
    #[test]
    fn clipboard_paste_asks_then_lands_through_the_shared_paste_run() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = two_rects();
        let payload = copied(e);
        let before = doc_json(e);
        for (item, action) in [("menu_paste", "paste"), ("menu_paste_in_place", "paste_in_place"),
                               ("menu_paste_preserving_layers", "paste_preserving_layers")] {
            assert_eq!(dispatch(e, &format!(r#"{{"menu_item":"{item}"}}"#)),
                       (String::new(), refusal("NeedsClipboard", action)), "{item}");
            assert_eq!(doc_json(e), before, "{item}: a refusal runs nothing");
        }
        assert!(!engine_of(e).with_model(|m| m.can_undo()));

        let (reply, err) = paste_with(e, "menu_paste", payload.clone().into());
        assert_eq!(reply_of(&reply, &err)["doc_changed"], true, "{reply} {err}");
        assert_eq!(err, "");
        assert_eq!(xs(e), vec![10.0, 50.0, 34.0, 74.0], "the first paste lands +24");
        let _ = paste_with(e, "menu_paste", payload.clone().into());
        assert_eq!(xs(e)[4..], [58.0, 98.0], "the second paste of the same content +48");
        undo(e);
        let _ = paste_with(e, "menu_paste", payload.clone().into());
        assert_eq!(xs(e)[4..], [58.0, 98.0], "undo restored the run, so the redo-paste lands +48 again");
        let (reply, err) = paste_with(e, "menu_paste_in_place", payload.clone().into());
        assert_eq!(reply_of(&reply, &err)["doc_changed"], true, "{reply} {err}");
        assert_eq!(xs(e)[6..], [10.0, 50.0], "in place lands at 0");
        unsafe { jas_engine_free(e) };

        let e = two_rects();
        let before = doc_json(e);
        for clip in [serde_json::Value::Null, "".into()] {
            let (reply, err) = paste_with(e, "menu_paste", clip.clone());
            assert_eq!(reply_of(&reply, &err)["doc_changed"], false, "{clip}: {reply}");
            assert_eq!(err, refusal("Unchanged", "paste"), "{clip}");
            assert_eq!(doc_json(e), before, "{clip}");
            assert!(!engine_of(e).with_model(|m| m.can_undo()), "{clip}: no undo step");
        }
        // Another app's text is a Text element (the SVG-or-text rule).
        let (reply, err) = paste_with(e, "menu_paste", "hello".into());
        assert_eq!(reply_of(&reply, &err)["doc_changed"], true, "{reply} {err}");
        assert_eq!(children(e).last().map(|c| c["type"].clone()), Some("text".into()), "text pastes as Text");
        unsafe { jas_engine_free(e) };
    }

    /// Paste, Preserving Layers passes its `preserve` to the shared law: a
    /// payload carrying a NAMED layer lands as `apply_paste_clipboard_text(..,
    /// 24, true)` says, and differs from plain Paste (the control).
    #[test]
    fn clipboard_paste_preserving_layers_is_the_shared_law_with_preserve() {
        let _counters = crate::ffi_instr::test_lock::lock();
        use crate::document::test_fixture::{model_with, rect};
        let payload = r#"<svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape"><g inkscape:groupmode="layer" inkscape:label="Other"><rect x="0" y="0" width="4" height="4"/></g></svg>"#;
        let oracle = |preserve: bool| {
            let mut m = model_with(vec![rect(10.0, 20.0, 30.0, 40.0)], &[]);
            assert!(crate::document::op_apply::apply_paste_clipboard_text(&mut m, Some(payload), 24.0, preserve));
            unboarded(m.document())
        };
        // The artboard's id is minted per document; the paste is about layers.
        fn unboarded(d: &crate::document::document::Document) -> serde_json::Value {
            let mut v: serde_json::Value =
                serde_json::from_str(&crate::geometry::test_json::document_to_test_json(d)).unwrap();
            v.as_object_mut().unwrap().remove("artboards");
            v
        }
        assert_ne!(oracle(true), oracle(false), "the control: preserve changes where the paste lands");
        for (item, preserve) in [("menu_paste_preserving_layers", true), ("menu_paste", false)] {
            let e = engine_with(model_with(vec![rect(10.0, 20.0, 30.0, 40.0)], &[]));
            let (reply, err) = paste_with(e, item, payload.into());
            assert_eq!(reply_of(&reply, &err)["doc_changed"], true, "{item}: {reply} {err}");
            assert_eq!(engine_of(e).with_document(unboarded), oracle(preserve), "{item}");
            unsafe { jas_engine_free(e) };
        }
    }

    /// The five clipboard items are the engine's now: none is refused as a
    /// platform effect, and the three pastes refuse `NeedsClipboard` instead.
    #[test]
    fn clipboard_items_are_not_platform_effects() {
        let _counters = crate::ffi_instr::test_lock::lock();
        for (item, class) in [("menu_copy", None), ("menu_cut", None), ("menu_paste", Some("NeedsClipboard")),
                              ("menu_paste_in_place", Some("NeedsClipboard")),
                              ("menu_paste_preserving_layers", Some("NeedsClipboard"))] {
            let e = two_rects();
            let (reply, err) = dispatch(e, &format!(r#"{{"menu_item":"{item}"}}"#));
            assert!(!err.contains("PlatformEffect"), "{item}: {err}");
            match class {
                Some(c) => assert!(err.contains(c), "{item}: {err}"),
                None => assert_eq!(err, "", "{item}: {reply} {err}"),
            }
            unsafe { jas_engine_free(e) };
        }
    }

    /// Ctrl+C / Ctrl+X / Ctrl+V / Ctrl+Shift+V resolve through `shortcuts.yaml`
    /// in the engine into the same actions, with the same reply and the same
    /// `NeedsClipboard`; the resend carries `clipboard` on the KEY request.
    #[test]
    fn clipboard_keys_resolve_to_the_same_actions() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = two_rects();
        let (reply, err) = dispatch(e, r#"{"key":"c","mods":{"ctrl":true}}"#);
        let payload = reply_of(&reply, &err)["clipboard_write"].as_str()
            .unwrap_or_else(|| panic!("Ctrl+C names the payload: {reply} {err}")).to_string();
        assert_eq!(dispatch(e, r#"{"key":"v","mods":{"ctrl":true}}"#),
                   (String::new(), refusal("NeedsClipboard", "paste")));
        assert_eq!(dispatch(e, r#"{"key":"V","mods":{"ctrl":true,"shift":true}}"#),
                   (String::new(), refusal("NeedsClipboard", "paste_in_place")));
        let req = serde_json::json!({"key": "v", "mods": {"ctrl": true}, "clipboard": payload});
        let (reply, err) = dispatch(e, &req.to_string());
        assert_eq!(reply_of(&reply, &err)["doc_changed"], true, "{reply} {err}");
        assert_eq!(xs(e), vec![10.0, 50.0, 34.0, 74.0], "the key's paste is the menu's");
        let (reply, err) = dispatch(e, r#"{"key":"x","mods":{"ctrl":true}}"#);
        assert!(reply_of(&reply, &err)["clipboard_write"].is_string(), "Ctrl+X names the payload: {reply}");
        assert_eq!(xs(e), vec![10.0, 50.0], "and cuts the pasted (selected) pair");
        unsafe { jas_engine_free(e) };
    }

    /// The C surface documents the channel where a shell author reads it.
    #[test]
    fn the_header_documents_the_clipboard_channel() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let header = include_str!("../include/jas_ffi.h");
        assert!(header.contains("clipboard_write"), "the reply key");
        assert!(header.contains("NeedsClipboard"), "the refusal");
        assert!(header.contains("jas_dispatch_action("), "the control");
    }

    /// SELECT ALL FROM THE MENU (flask STATUS §242, 2026-10-13: Edit > Select
    /// All on Windows read `PlatformEffect`, `Logged:select_all`). Since
    /// 2026-10-25 its `actions.yaml` entry says what it does, `doc.op: {op:
    /// select_all}` with no `snapshot`, and the engine runs it from there.
    #[test]
    fn dispatch_menu_select_all_selects_and_records_no_undo_step() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("complex_document.svg");
        let selected = || unsafe { crate::ffi_pointer::jas_selection_len(e) };
        assert_eq!(selected(), 0, "the fixture opens with nothing selected");
        let (reply, err) = dispatch(e, r#"{"menu_item":"menu_select_all"}"#);
        assert!(err.is_empty(), "Select All ran and moved the selection: {err}");
        assert!(!reply.is_empty(), "a run replies");
        assert!(selected() >= 2, "Select All selected {}", selected());
        assert!(!engine_of(e).with_model(|m| m.can_undo()), "selecting is not an edit");
        unsafe { jas_engine_free(e) };
    }

    /// Group from the menu is an EDIT: one undo step, and Undo restores.
    #[test]
    fn dispatch_menu_group_is_one_undo_step() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("complex_document.svg");
        let before = doc_json(e);
        let _ = dispatch(e, r#"{"menu_item":"menu_select_all"}"#);
        let (_, err) = dispatch(e, r#"{"action":"group"}"#);
        assert!(err.is_empty(), "Group ran: {err}");
        assert_ne!(doc_json(e), before, "Group moved the document");
        undo(e);
        assert!(!engine_of(e).with_model(|m| m.can_undo()), "Group was ONE step");
        let restored: serde_json::Value = serde_json::from_str(&doc_json(e)).unwrap();
        let orig: serde_json::Value = serde_json::from_str(&before).unwrap();
        assert_eq!(restored["layers"], orig["layers"], "Undo restored the tree");
        unsafe { jas_engine_free(e) };
    }

    /// THE CLASS, NOT THE INSTANCE: every menubar item, run on a document with
    /// content and a selection, and every `PlatformEffect` refusal recorded as
    /// `action -> detail`. The model verbs run (from their YAML);
    /// what remains is PINNED here by class, so a newly refused item, or one
    /// that starts running, moves this list in a diff someone reads.
    #[test]
    fn dispatch_every_menubar_item_and_name_what_the_engine_refuses() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let mut refused: Vec<String> = Vec::new();
        let mut ran = 0;
        let items = menubar_items();
        assert!(items.len() >= 40, "the menubar walk read {} items", items.len());
        for (id, action) in &items {
            let e = engine_on("complex_document.svg");
            let _ = dispatch(e, r#"{"menu_item":"menu_select_all"}"#);
            let (_, err) = dispatch(e, &format!(r#"{{"menu_item":"{id}"}}"#));
            let detail = serde_json::from_str::<serde_json::Value>(&err).ok()
                .filter(|v| v["panel_event"] == "PlatformEffect")
                .and_then(|v| v["detail"].as_str().map(str::to_string));
            match detail {
                Some(d) => refused.push(format!("{action} -> {d}")),
                None => ran += 1,
            }
            unsafe { jas_engine_free(e) };
        }
        refused.sort();
        refused.dedup();
        let expected = [
            // The clipboard left this list on 2026-10-17: Copy and Cut name
            // `clipboard_write` in the reply, and the pastes refuse
            // `NeedsClipboard` (`clipboard_items_are_not_platform_effects`).
            // Files: the Windows shell runs open_file, save and save_as itself
            // (`MainWindow.Invoke`). `revert` left this list on 2026-10-20: it
            // re-opens the bytes the engine kept at the open or save
            // (`JasEngine::revert`). `quit` left this list
            // on 2026-10-15: with nothing edited it names `close_window` in the
            // reply, and with an edit it opens Save Changes.
            "open_file -> Logged:open_file: show native file dialog",
            "save -> Logged:save_as: show native save dialog",
            "save_as -> Logged:save_as: show native save dialog",
            // Undo and redo: the shell sends them as ops (`{"op":"undo"}`).
            "redo -> Logged:redo",
            "undo -> Logged:undo",
            // Dialogs open in the engine now (the dialog door, 2026-10-14), so
            // `open_document_setup`, `open_print_dialog`, `save_appearance_as`
            // and `save_workspace_as` left this list.
            // Effects no engine runs yet: a new tab, the pane layout.
            "new_document -> UnknownEffect:create_child",
            "reset_workspace -> UnknownEffect:reset_layout",
            "revert_workspace -> UnknownEffect:revert_layout",
            "tile_panes -> UnknownEffect:tile",
            // The dock: the shell shows and hides its own panels.
            "toggle_panel -> Logged:toggle_panel (native): {{param.panel}}",
        ];
        let mut expected: Vec<String> = expected.iter().map(|s| s.to_string()).collect();
        expected.sort();
        assert_eq!(refused, expected, "the menubar's PlatformEffect refusals moved");
        assert!(ran >= 9, "at least the nine model verbs ran (each from its YAML); {ran} items ran");
    }

    /// WHETHER THE DOCUMENT IS MODIFIED, FOR A SHELL'S DIRTY FLAG (flask §246,
    /// ruled §247): `doc_changed` in a reply means REPAINT, and a selection
    /// change sets it, so a shell that marks the document dirty on it marks
    /// Select All an edit. The model's own answer is `is_modified`: a selection
    /// and a live drag tick are not edits, and Undo back to the saved state is
    /// unmodified again. 255 for a null engine: a bool cannot express "no
    /// session", and 0 would read as "saved".
    #[test]
    fn the_modified_flag_is_the_models_not_the_repaint_signal() {
        use crate::document::test_fixture::{model_with, rect};
        let _counters = crate::ffi_instr::test_lock::lock();
        assert_eq!(unsafe { jas_document_modified(std::ptr::null_mut()) }, 255);
        let e = engine_with(model_with(vec![rect(10.0, 20.0, 30.0, 40.0), rect(50.0, 20.0, 30.0, 40.0)], &[]));
        let modified = || unsafe { jas_document_modified(e) };
        assert_eq!(modified(), 0, "a fresh document");
        let (reply, err) = dispatch(e, r#"{"menu_item":"menu_select_all"}"#);
        assert!(err.is_empty() && reply.contains(r#""doc_changed":true"#), "CONTROL: Select All repaints: {reply}");
        assert_eq!(modified(), 0, "a selection is not an edit");
        let _ = dispatch(e, r#"{"action":"group"}"#);
        assert_eq!(modified(), 1, "Group is an edit");
        undo(e);
        assert_eq!(modified(), 0, "Undo back to the saved state is unmodified");
        let id = crate::panel_scope::COLOUR_PANEL;
        let (reply, err) = behave(e, id, r#"{"widget":"cp_color_bar","event":"change","value":"0.3,0.3"}"#);
        assert!(err.is_empty() && reply.contains(r#""doc_changed":true"#),
                "CONTROL: the live tick ran and repainted: {err} {reply}");
        assert_eq!(modified(), 0, "a live drag tick is not an edit");
        let (_, err) = behave(e, id, r#"{"widget":"cp_color_bar","event":"commit","value":"0.3,0.3"}"#);
        assert!(err.is_empty(), "{err}");
        assert_eq!(modified(), 1, "its release is");
        unsafe { jas_engine_free(e) };
    }

    /// A SAVE MOVES THE BASELINE (flask, after #397). The shell writes the file
    /// itself, so it tells the model; `modified` then measures from the save,
    /// not from the open. The case that matters: open, edit, save, Undo is
    /// MODIFIED, because the file on disk holds the edit that Undo removed.
    #[test]
    fn a_save_the_shell_reports_is_the_baseline_the_modified_flag_measures_from() {
        use crate::document::test_fixture::{model_with, rect};
        let _counters = crate::ffi_instr::test_lock::lock();
        assert_eq!(unsafe { jas_document_mark_saved(std::ptr::null_mut()) }, 255);
        let e = engine_with(model_with(vec![rect(10.0, 20.0, 30.0, 40.0), rect(50.0, 20.0, 30.0, 40.0)], &[]));
        let modified = || unsafe { jas_document_modified(e) };
        let _ = dispatch(e, r#"{"menu_item":"menu_select_all"}"#);
        let _ = dispatch(e, r#"{"action":"group"}"#);
        assert_eq!(modified(), 1, "CONTROL: Group is an edit");
        assert_eq!(unsafe { jas_document_mark_saved(e) }, 1);
        assert_eq!(modified(), 0, "saved");
        undo(e);
        assert_eq!(modified(), 1, "Undo past the save is modified: the file holds the group");
        let op = r#"{"op":"redo"}"#;
        assert_eq!(unsafe { jas_dispatch_event(e, op.as_ptr(), op.len()) }, JasStatus::Ok);
        assert_eq!(modified(), 0, "Redo back to the saved state is not");
        unsafe { jas_engine_free(e) };
    }

    /// The engine's document as JSON with every artboard id blanked: opening a
    /// page-less file mints a fresh artboard id on each read, so two opens of
    /// the same bytes differ only there (the web's `without_artboard_ids`).
    fn doc_without_artboard_ids(e: *mut JasEngine) -> serde_json::Value {
        let mut doc: serde_json::Value = serde_json::from_str(&doc_json(e)).unwrap();
        for ab in doc["artboards"].as_array_mut().into_iter().flatten() {
            ab["id"] = serde_json::json!("");
        }
        doc
    }

    /// Open `fixture` as the shell does (`jas_load_svg` is `open_svg`).
    fn engine_loading(fixture: &str) -> *mut JasEngine {
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/..");
        let svg = std::fs::read_to_string(format!("{root}/test_fixtures/svg/{fixture}")).unwrap();
        let e = jas_engine_new();
        assert!(engine_of(e).open_svg(&svg), "{fixture} opens");
        e
    }

    /// REVERT (finding 12 of the 10-20 sitting: `revert` was `Logged:` here).
    /// The web's `apply_revert`: re-open the bytes last opened or saved, install
    /// them as ONE undoable step, then mark the document clean. So Undo takes
    /// the revert back, and the reverted document reads unmodified.
    #[test]
    fn revert_reopens_the_opened_bytes_as_one_undoable_step_and_reads_clean() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_loading("rect_with_stroke.svg");
        let modified = || unsafe { jas_document_modified(e) };
        let opened = doc_without_artboard_ids(e);
        let _ = dispatch(e, r#"{"menu_item":"menu_select_all"}"#);
        let (_, err) = dispatch(e, r#"{"action":"delete_selection"}"#);
        assert!(err.is_empty(), "{err}");
        let edited = doc_without_artboard_ids(e);
        assert_ne!(edited, opened, "CONTROL: the delete is an edit");
        assert_eq!(modified(), 1, "CONTROL: modified before the revert");
        let (reply, err) = dispatch(e, r#"{"action":"revert"}"#);
        assert!(err.is_empty(), "revert ran: {err}");
        let reply: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(reply["doc_changed"], serde_json::json!(true), "{reply}");
        assert_eq!(doc_without_artboard_ids(e), opened, "the document is the opened file again");
        assert_eq!(modified(), 0, "a reverted document is clean");
        undo(e);
        assert_eq!(doc_without_artboard_ids(e), edited, "ONE undo step takes the revert back");
        assert_eq!(modified(), 1, "and the edit is unsaved again");
        unsafe { jas_engine_free(e) };
    }

    /// A save moves what Revert returns to: the bytes the shell wrote, which
    /// are `jas_document_svg`'s, not the bytes first opened.
    #[test]
    fn revert_after_a_save_returns_to_the_save_not_the_open() {
        use crate::document::test_fixture::{model_with, rect};
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_loading("rect_with_stroke.svg");
        let opened = doc_without_artboard_ids(e);
        // Two more rects, as one edit, then a save.
        let svg = crate::geometry::svg::document_to_svg(
            &model_with(vec![rect(10.0, 20.0, 30.0, 40.0), rect(50.0, 20.0, 30.0, 40.0)], &[]).document().clone());
        assert!(engine_of(e).open_svg(&svg), "the two rects open");
        let _ = dispatch(e, r#"{"menu_item":"menu_select_all"}"#);
        let _ = dispatch(e, r#"{"action":"group"}"#);
        assert_eq!(unsafe { jas_document_mark_saved(e) }, 1);
        let saved = doc_without_artboard_ids(e);
        assert_ne!(saved, opened, "CONTROL: the save is not the first open");
        let _ = dispatch(e, r#"{"action":"ungroup"}"#);
        assert_ne!(doc_without_artboard_ids(e), saved, "CONTROL: the ungroup is an edit");
        let (_, err) = dispatch(e, r#"{"action":"revert"}"#);
        assert!(err.is_empty(), "revert ran: {err}");
        // A revert RE-OPENS, and an open selects nothing (the web's, too), so
        // the group selected at the save is not selected after it.
        let mut want = saved.clone();
        want["selection"] = serde_json::json!([]);
        assert_ne!(saved["selection"], want["selection"], "CONTROL: the save had a selection");
        assert_eq!(doc_without_artboard_ids(e), want, "the saved document, grouped, nothing selected");
        assert_eq!(unsafe { jas_document_modified(e) }, 0);
        unsafe { jas_engine_free(e) };
    }

    /// Nothing to revert: an unmodified document, and a modified one with no
    /// bytes behind it (a document the engine was handed, never opened or
    /// saved). Each changes nothing and reads `Unchanged`.
    #[test]
    fn revert_with_nothing_to_return_to_changes_nothing() {
        use crate::document::test_fixture::{model_with, rect};
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_loading("rect_with_stroke.svg");
        let before = doc_json(e);
        let (_, err) = dispatch(e, r#"{"action":"revert"}"#);
        assert!(err.contains("Unchanged"), "an unmodified document: {err}");
        assert_eq!(doc_json(e), before);
        unsafe { jas_engine_free(e) };

        let e = engine_with(model_with(vec![rect(10.0, 20.0, 30.0, 40.0)], &[]));
        let _ = dispatch(e, r#"{"menu_item":"menu_select_all"}"#);
        let _ = dispatch(e, r#"{"action":"delete_selection"}"#);
        assert_eq!(unsafe { jas_document_modified(e) }, 1, "CONTROL: modified");
        let before = doc_json(e);
        let (_, err) = dispatch(e, r#"{"action":"revert"}"#);
        assert!(err.contains("Unchanged"), "no baseline: {err}");
        assert_eq!(doc_json(e), before, "nothing ran");
        unsafe { jas_engine_free(e) };
    }

    /// A document installed any way but an open or a save has no file behind
    /// it, even when a file was opened before it: Revert must not return to
    /// THAT file's bytes, which belong to a different document.
    #[test]
    fn revert_never_returns_to_a_file_the_document_did_not_come_from() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_loading("rect_with_stroke.svg");
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/..");
        let other = std::fs::read_to_string(format!("{root}/test_fixtures/svg/text_basic.svg")).unwrap();
        engine_of(e).replace_document(crate::geometry::svg::try_open_svg_document(&other).unwrap());
        let _ = dispatch(e, r#"{"menu_item":"menu_select_all"}"#);
        let (_, err) = dispatch(e, r#"{"action":"delete_selection"}"#);
        assert!(err.is_empty(), "{err}");
        assert_eq!(unsafe { jas_document_modified(e) }, 1, "CONTROL: modified");
        let before = doc_json(e);
        let (_, err) = dispatch(e, r#"{"action":"revert"}"#);
        assert!(err.contains("Unchanged"), "the opened file is not this document's: {err}");
        assert_eq!(doc_json(e), before, "nothing ran");
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn dispatch_action_refuses_new_document_by_its_missing_effect_and_runs_nothing() {
        let _counters = crate::ffi_instr::test_lock::lock();
        // `new_document` is spec'd with `create_child`, which no port's engine
        // runs yet (the owner's note 4b, 2026-10-11: no canvas tab). Refused,
        // never a half run: no tab, and the tab bar stays hidden.
        let e = jas_engine_new();
        let (reply, err) = dispatch(e, r#"{"action":"new_document"}"#);
        assert!(reply.is_empty(), "a refused action replies nothing: {reply}");
        assert!(err.contains("PlatformEffect") && err.contains("create_child"), "{err}");
        // Nothing ran: the tab bar still shows the engine's one document,
        // and only it (owner note 4b: tabs are drawn from the open documents).
        assert_eq!(canvas_tabs(e).len(), 1, "nothing ran");
        unsafe { jas_engine_free(e) };
    }

    /// THE "NO DOCUMENT" STATE (flask STATUS §272, fork (a)): a shell told
    /// `"remove_tab": 0` closes the engine's one document. The tab bar then
    /// draws no tab, the scope reads `tab_count` 0 and `active_tab` -1 (the
    /// spec's own "no tab", `state.yaml`), and a load opens a document again.
    #[test]
    fn document_close_empties_the_tab_bar_and_a_load_reopens_it() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("rect_with_stroke.svg");
        assert_eq!(canvas_tabs(e).len(), 1, "the engine's one document");
        assert_eq!(unsafe { jas_document_close(e) }, 1, "it was open");
        // No open document hides the bar itself (it draws only while there
        // are tabs), so "no tab" is: no tab bar, or one with nothing under it.
        let plan: serde_json::Value =
            serde_json::from_str(&plan_of(e, "canvas_pane", 1600, 900)).expect("plan JSON");
        let all: Vec<&serde_json::Value> = ["chrome", "containers", "leaves"].iter()
            .flat_map(|k| plan[*k].as_array().into_iter().flatten()).collect();
        assert!(!all.is_empty(), "the canvas pane still plans: {plan}");
        assert!(all.iter().all(|x| x["id"] != "canvas_tab_bar"), "no document, no tab bar");
        let state = &panel_ctx_of(e)["state"];
        assert_eq!((state["tab_count"].clone(), state["active_tab"].clone()),
                   (serde_json::json!(0), serde_json::json!(-1)), "the scope reads no tab");
        assert_eq!(unsafe { jas_document_close(e) }, 0, "already closed");
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/..");
        let svg = std::fs::read_to_string(format!("{root}/test_fixtures/svg/rect_with_stroke.svg")).unwrap();
        engine_of(e).replace_document(crate::geometry::svg::try_svg_to_document(&svg).unwrap());
        assert_eq!(canvas_tabs(e).len(), 1, "a load opens a document again");
        assert_eq!(panel_ctx_of(e)["state"]["tab_count"], serde_json::json!(1));
        assert_eq!(unsafe { jas_document_close(std::ptr::null_mut()) }, 255);
        unsafe { jas_engine_free(e) };
    }

    /// The scope a panel's widgets are evaluated in, for a test to read.
    fn panel_ctx_of(e: *mut JasEngine) -> serde_json::Value {
        let ws = Workspace::load().unwrap();
        panel_ctx(engine_of(e), &ws, crate::panel_behavior::ALIGN_PANEL)
    }

    /// The canvas pane's document tabs: the entries one level under
    /// `canvas_tab_bar`, each with the leaves under it. A `foreach` row's
    /// templated id is WITHHELD by the plan (`static_of`), so a tab is found
    /// by its PATH, as a shell finds it.
    fn canvas_tabs(e: *mut JasEngine) -> Vec<(serde_json::Value, Vec<serde_json::Value>)> {
        let plan: serde_json::Value =
            serde_json::from_str(&plan_of(e, "canvas_pane", 1600, 900)).expect("plan JSON");
        let all: Vec<&serde_json::Value> = ["chrome", "containers", "leaves"].iter()
            .flat_map(|k| plan[*k].as_array().into_iter().flatten()).collect();
        let bar = all.iter().find(|x| x["id"] == "canvas_tab_bar").expect("the tab bar is placed");
        let bar_path = bar["path"].as_array().expect("path").clone();
        let under = |x: &serde_json::Value, depth: usize, root: &[serde_json::Value]| {
            x["path"].as_array().is_some_and(|p| p.len() == root.len() + depth && p[..root.len()] == *root)
        };
        all.iter().filter(|x| under(x, 1, &bar_path)).map(|tab| {
            let tp = tab["path"].as_array().unwrap().clone();
            let kids = all.iter().filter(|x| under(x, 1, &tp)).map(|x| (*x).clone()).collect();
            ((*tab).clone(), kids)
        }).collect()
    }

    /// A SHELL NAMES THE DOCUMENT IT OPENED (flask §256): `jas_load_svg` takes
    /// bytes only, so on Windows an opened file's tab read `Untitled-N`. The
    /// name arrives as UTF-8 BYTES (BL5), is the model's `filename`, and is
    /// what the canvas tab shows. Naming is not an edit. A null pointer,
    /// non-UTF-8 bytes or an empty name are refused (0) and change nothing.
    #[test]
    fn a_shell_names_the_document_and_the_tab_shows_the_name() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let set = |e, b: &[u8]| unsafe { jas_document_set_filename(e, b.as_ptr(), b.len()) };
        assert_eq!(unsafe { jas_document_set_filename(std::ptr::null_mut(), b"x".as_ptr(), 1) }, 255);
        let e = jas_engine_new();
        let before = unsafe { &*e }.model.borrow().filename.clone();
        // Refusals, each leaving the name as it was.
        assert_eq!(unsafe { jas_document_set_filename(e, std::ptr::null(), 3) }, 0, "null pointer");
        assert_eq!(set(e, &[0x66, 0xff, 0x2e]), 0, "not UTF-8");
        assert_eq!(set(e, b""), 0, "empty");
        assert_eq!(unsafe { &*e }.model.borrow().filename, before, "a refusal changes nothing");
        // The name, with a non-ASCII character to prove it is not read as ANSI.
        let name = "tab_r\u{e9}ct.svg";
        assert_eq!(set(e, name.as_bytes()), 1);
        assert_eq!(unsafe { &*e }.model.borrow().filename, name);
        assert_eq!(unsafe { jas_document_modified(e) }, 0, "naming is not an edit");
        let tabs = canvas_tabs(e);
        assert_eq!(tabs.len(), 1);
        assert!(tabs[0].1.iter().any(|k| k["type"] == "text" && k["values"]["content"] == serde_json::json!(name)),
                "the tab shows the name: {:?}", tabs[0].1);
        unsafe { jas_engine_free(e) };
    }

    /// OWNER NOTE 4b: THE CANVAS TAB BAR IS DRAWN FROM THE OPEN DOCUMENTS.
    /// `canvas_tab_bar` is a `foreach` over `workspace.open_documents`, and
    /// the engine holds exactly one document, so the plan a shell draws has
    /// ONE tab: shown, the front one, labelled with the model's own name (its
    /// filename, or its untitled name), with its close button. Before #4b the
    /// tab came from a `create_child` no port ran, so Windows drew no tab.
    #[test]
    fn the_canvas_tab_bar_draws_the_engines_one_document() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let name = unsafe { &*e }.model.borrow().filename.clone();
        assert!(name.starts_with("Untitled-"), "a fresh engine's document is untitled: {name:?}");
        let tabs = canvas_tabs(e);
        assert_eq!(tabs.len(), 1, "one tab for the one document: {tabs:?}");
        let (tab, kids) = &tabs[0];
        assert!(tab["rect"]["w"].as_i64().unwrap_or(0) > 0, "the tab is laid out: {}", tab["rect"]);
        assert_eq!(tab["values"]["bind.active"], "true", "the one tab is the front one");
        assert!(kids.iter().any(|k| k["type"] == "text" && k["values"]["content"] == serde_json::json!(name)),
                "the tab shows the document's name {name:?}: {kids:?}");
        assert!(kids.iter().any(|k| k["type"] == "icon_button" && k["static"]["icon"] == "close"),
                "the tab has its close button: {kids:?}");
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn dispatch_action_refuses_an_unknown_action_and_runs_nothing() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let (reply, err) = dispatch(e, r#"{"action":"zz_no_such_action"}"#);
        assert!(reply.is_empty(), "an unknown action replies nothing: {reply}");
        assert!(err.contains("zz_no_such_action"), "the refusal names the action: {err}");
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn dispatch_action_refuses_bad_json_and_a_null_engine() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let (reply, err) = dispatch(e, "{not json");
        assert!(reply.is_empty());
        assert!(err.contains("BadJson"), "{err}");
        let (reply2, _) = dispatch(e, r#"{"params":{}}"#);
        assert!(reply2.is_empty(), "no action field is refused");
        let j = r#"{"action":"new_document"}"#;
        assert!(take(unsafe { jas_dispatch_action(std::ptr::null_mut(), j.as_ptr(), j.len()) }).is_empty());
        unsafe { jas_engine_free(e) };
    }

    // -----------------------------------------------------------------------
    // THE TOOLBAR: a layout pane, addressed like a panel (the first hand-test
    // of the Windows app, 2026-10-10: "We need a toolbar")
    // -----------------------------------------------------------------------

    const TOOLBAR: &str = "toolbar_pane";

    fn slot_tool(e: *mut JasEngine) -> Option<&'static str> {
        unsafe { &*e }.tool_slot().as_ref().map(|(i, _)| crate::ffi_pointer::TOOL_IDS[*i])
    }

    /// The toolbar's `tool_grid` (`type: grid`, `cols: 2`, a `grid: {row, col}`
    /// per child) is laid out by PATH_B_DESIGN B.7, so its buttons are in the plan.
    #[test]
    fn the_toolbar_pane_plans_like_a_panel() {
        let _g = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let plan = plan_of(e, TOOLBAR, 72, 900);
        for id in ["btn_selection", "btn_shape_slot", "btn_line", "btn_pen_slot"] {
            assert!(plan.contains(id), "the toolbar plan carries {id}: {}", &plan[..plan.len().min(400)]);
        }
        unsafe { jas_engine_free(e) };
    }

    /// What IS true today: the pane plans (its fill/stroke widget is there),
    /// so the lookup reaches it; only the grid's buttons are missing (above).
    #[test]
    fn the_toolbar_pane_is_addressable_like_a_panel() {
        let _g = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let plan = plan_of(e, TOOLBAR, 72, 900);
        assert!(plan.contains("fill_swatch") && plan.contains("swap_btn"), "{}", &plan[..plan.len().min(300)]);
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn a_toolbar_click_selects_the_tool_the_pointer_drives() {
        let _g = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        assert_eq!(unsafe { crate::ffi_pointer::jas_set_tool(e, 0) }, JasStatus::Ok);
        let (reply, _) = behave(e, TOOLBAR, r#"{"widget":"btn_shape_slot","event":"click"}"#);
        assert!(!reply.is_empty(), "the click ran: {}", take(unsafe { jas_last_error_json(e) }));
        assert_eq!(unsafe { &*e }.active_tool_state().as_deref(), Some("rect"));
        assert_eq!(slot_tool(e), Some("rect"), "the pointer now drives the rect tool");
        let (_, _) = behave(e, TOOLBAR, r#"{"widget":"btn_selection","event":"click"}"#);
        assert_eq!(slot_tool(e), Some("selection"), "and back");
        unsafe { jas_engine_free(e) };
    }

    /// The Type button selects the Type tool. Until 2026-10-20 no shell tool
    /// answered `type`, so this click said Unchanged and the checked button
    /// stayed the real tool; all ten of his clicks in the 10-20 feel sitting
    /// read `outcome=unchanged` (finding 3). Now the pointer drives it, and the
    /// checked state says so.
    #[test]
    fn a_toolbar_click_on_the_type_button_selects_the_type_tool() {
        let _g = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        assert_eq!(unsafe { crate::ffi_pointer::jas_set_tool(e, 0) }, JasStatus::Ok);
        let (reply, _) = behave(e, TOOLBAR, r#"{"widget":"btn_text_slot","event":"click"}"#);
        assert!(!reply.is_empty(), "the click ran: {}", take(unsafe { jas_last_error_json(e) }));
        assert_eq!(slot_tool(e), Some("type"), "the pointer now drives the Type tool");
        assert_eq!(unsafe { &*e }.active_tool_state().as_deref(), Some("type"));
        unsafe { jas_engine_free(e) };
    }

    // -----------------------------------------------------------------------
    // THE DOCK: `default_layouts.yaml`'s tab groups (the first hand-test of the
    // Windows app, 2026-10-10: "The panel shows only one at a time")
    // -----------------------------------------------------------------------

    fn dock_of(name: &str) -> String {
        take(unsafe { jas_dock_layout(name.as_ptr(), name.len()) })
    }

    #[test]
    fn the_default_dock_is_the_layouts_five_tab_groups() {
        let _g = crate::ffi_instr::test_lock::lock();
        let dock: serde_json::Value = serde_json::from_str(&dock_of("Default"))
            .expect("the Default dock is JSON");
        let groups = dock["groups"].as_array().expect("groups");
        assert_eq!(groups.len(), 5, "{dock}");
        let ids = |g: &serde_json::Value| -> Vec<String> {
            g["panels"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect()
        };
        assert_eq!(ids(&groups[0]), ["color_panel_content", "swatches_panel_content", "brushes_panel_content"]);
        assert_eq!(ids(&groups[1]), ["align_panel_content", "boolean_panel_content"]);
        assert_eq!(ids(&groups[4]), ["artboards_panel_content", "layers_panel_content"]);
        assert!(groups.iter().all(|g| g["active"] == 0), "every group opens on its first panel");
    }

    #[test]
    fn every_docked_panel_of_every_layout_plans() {
        let _g = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        for name in ["Default", "Minimal", "Painting"] {
            let dock: serde_json::Value = serde_json::from_str(&dock_of(name)).expect(name);
            for g in dock["groups"].as_array().unwrap() {
                for id in g["panels"].as_array().unwrap() {
                    let id = id.as_str().unwrap();
                    assert!(!plan_of(e, id, 228, 0).is_empty(), "{name}: {id} plans");
                }
            }
        }
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn an_unknown_layout_is_refused_with_the_empty_span() {
        let _g = crate::ffi_instr::test_lock::lock();
        assert_eq!(dock_of("No Such Layout"), "");
        assert_eq!(take(unsafe { jas_dock_layout(std::ptr::null(), 0) }), "");
    }

    fn refusal(class: &str, detail: &str) -> String {
        format!(r#"{{"panel_event":"{class}","detail":"{detail}"}}"#)
    }

    // -----------------------------------------------------------------------
    // THE ENGINE'S DOCK LAYOUT (floating panels, FP-2): seeded from the YAML,
    // driven by `layout_apply`, refused by name where the dispatcher skips
    // -----------------------------------------------------------------------

    fn layout_op(e: *mut JasEngine, op: &str) -> String {
        take(unsafe { jas_layout_apply(e, op.as_ptr(), op.len()) })
    }

    fn layout_load(e: *mut JasEngine, name: &str) -> String {
        take(unsafe { jas_layout_load(e, name.as_ptr(), name.len()) })
    }

    fn json(s: &str) -> serde_json::Value {
        serde_json::from_str(s).unwrap_or_else(|_| panic!("not JSON: {s:?}"))
    }

    /// The loaded layout's anchored groups are the groups `jas_dock_layout`
    /// answers, so the shell can move onto the engine's layout (FP-3) without
    /// its dock changing.
    #[test]
    fn a_loaded_layout_carries_the_dock_readers_groups() {
        let _g = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let state = json(&layout_load(e, "Default"));
        let dock = json(&dock_of("Default"));
        let groups = state["anchored"][0]["groups"].as_array().unwrap();
        assert_eq!(groups.len(), dock["groups"].as_array().unwrap().len());
        for (g, d) in groups.iter().zip(dock["groups"].as_array().unwrap()) {
            assert_eq!((&g["panels"], &g["active"]), (&d["panels"], &d["active"]));
        }
        assert_eq!(state["floating"], serde_json::json!([]));
        assert_eq!(take(unsafe { jas_layout_state(e) }), state.to_string(), "state reads back the load");
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn a_verb_changes_the_held_layout_and_answers_it() {
        let _g = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        layout_load(e, "Default");
        let after = json(&layout_op(e, r#"{"op":"detach_group","dock_id":0,"group_idx":1,"x":40.0,"y":60.0}"#));
        assert_eq!(after["floating"].as_array().unwrap().len(), 1, "{after}");
        assert_eq!(after["floating"][0]["x"].as_f64(), Some(40.0));
        assert_eq!(take(unsafe { jas_layout_state(e) }), after.to_string(), "the engine holds what it answered");
        unsafe { jas_engine_free(e) };
    }

    /// Every refusal is the empty span, names its class, and leaves the held
    /// layout byte-identical; the control op between them DOES change it, so an
    /// entry that refused everything could not pass.
    #[test]
    fn a_layout_op_the_dispatcher_would_skip_is_refused_by_name() {
        let _g = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        assert_eq!(take(unsafe { jas_layout_state(e) }), "", "nothing before a load");
        assert_eq!(take(unsafe { jas_last_error_json(e) }), refusal("NoLayout", ""));
        assert_eq!(layout_op(e, r#"{"op":"redock","dock_id":1}"#), "");
        assert_eq!(take(unsafe { jas_last_error_json(e) }), refusal("NoLayout", ""));
        let held = layout_load(e, "Default");
        for (op, class, detail) in [
            (r#"{"op":"no_such_verb"}"#, "BadLayoutOp", "no_such_verb"),
            (r#"{"dock_id":0}"#, "BadLayoutOp", ""),
            (r#"["detach_group"]"#, "BadLayoutOp", ""),
            (r#"{"op":"show_panel"}"#, "BadLayoutOp", "show_panel"),
            ("{not json", "BadJson", ""),
        ] {
            assert_eq!(layout_op(e, op), "", "{op} is refused");
            assert_eq!(take(unsafe { jas_last_error_json(e) }), refusal(class, detail), "{op}");
            assert_eq!(take(unsafe { jas_layout_state(e) }), held, "{op} changed nothing");
        }
        assert_ne!(layout_op(e, r#"{"op":"toggle_group_collapsed","dock_id":0,"group_idx":0}"#), held,
                   "the control op changes the layout");
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn a_layout_the_bundle_lacks_is_refused_and_the_held_one_kept() {
        let _g = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let held = layout_load(e, "Minimal");
        assert!(!held.is_empty());
        assert_eq!(layout_load(e, "No Such Layout"), "");
        assert_eq!(take(unsafe { jas_last_error_json(e) }), refusal("LayoutRefused", "No Such Layout"));
        assert_eq!(take(unsafe { jas_layout_state(e) }), held);
        unsafe { jas_engine_free(e) };
    }

    fn doc_json(e: *mut JasEngine) -> String {
        take(unsafe { jas_document_json(e) })
    }

    fn undo(e: *mut JasEngine) {
        let op = r#"{"op":"undo"}"#;
        assert_eq!(unsafe { jas_dispatch_event(e, op.as_ptr(), op.len()) }, JasStatus::Ok);
    }

    fn panel_menu(e: *mut JasEngine, panel: &str) -> (Vec<serde_json::Value>, String) {
        let raw = take(unsafe { jas_panel_menu(e, panel.as_ptr(), panel.len()) });
        let rows = if raw.is_empty() { vec![] } else {
            serde_json::from_str::<serde_json::Value>(&raw).unwrap().as_array().unwrap().clone()
        };
        (rows, take(unsafe { jas_last_error_json(e) }))
    }

    /// STATUS-jas item 24 (flask §564 finding J). A panel-menu label that is a
    /// `{{…}}` template arrives RESOLVED: the Layers menu's toggle-all rows say
    /// what they will do to this document. Until 2026-10-26 the raw template
    /// reached the Windows flyout. The menu is read again after Hide All
    /// Layers, so a label stuck in either direction reds.
    #[test]
    fn a_panel_menu_label_template_arrives_resolved() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let label = |e: *mut JasEngine, action: &str| {
            let (rows, err) = panel_menu(e, "layers_panel_content");
            rows.iter().find(|r| r["action"] == action).map(|r| r["label"].clone())
                .unwrap_or_else(|| panic!("no {action} row: {err}"))
        };
        assert_eq!(label(e, "toggle_all_layers_visibility"), "Hide All Layers");
        assert_eq!(label(e, "toggle_all_layers_lock"), "Lock All Layers");
        let req = r#"{"panel":"layers_panel_content","action":"toggle_all_layers_visibility"}"#;
        let _reply = take(unsafe { jas_dispatch_action(e, req.as_ptr(), req.len()) });
        let err = take(unsafe { jas_last_error_json(e) });
        assert!(!err.contains("Unknown"), "hide all: {err}");
        assert_eq!(label(e, "toggle_all_layers_visibility"), "Show All Layers", "every layer is hidden now");
        assert_eq!(label(e, "toggle_all_layers_lock"), "Lock All Layers", "the control: nothing was locked");
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn panel_menu_lists_every_node_of_the_colour_panels_menu_with_the_mode_checked() {
        // The owner's note 3 (2026-10-11): the Windows dock has no panel menu.
        // The shell reads the menu from the core, labels AND state, and
        // evaluates nothing (the boundary law).
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let (rows, err) = panel_menu(e, "color_panel_content");
        let ws = Workspace::load().unwrap();
        let spec = ws.panel_menu("color_panel_content");
        assert!(err.is_empty(), "{err}");
        assert_eq!(rows.len(), spec.len(), "one row per menu node, separators included");
        for (i, r) in rows.iter().enumerate() {
            assert_eq!(r["index"], i as i64, "rows are in menu order");
        }
        let labels: Vec<&str> = rows.iter().take(5).map(|r| r["label"].as_str().unwrap()).collect();
        assert_eq!(labels, ["Grayscale", "RGB", "HSB", "CMYK", "Web Safe RGB"]);
        assert_eq!(rows[5]["kind"], "separator");
        assert_eq!(rows[0]["kind"], "item");
        assert_eq!(rows[0]["action"], "set_color_panel_mode");
        // The panel's declared default mode is hsb: exactly that row is checked.
        let checked: Vec<usize> = (0..5).filter(|&i| rows[i]["checked"] == true).collect();
        assert_eq!(checked, vec![2], "only HSB is checked: {rows:?}");
        assert!((0..5).all(|i| rows[i]["checked"].is_boolean()), "the five mode rows are checkable");
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn panel_menu_refuses_an_unknown_panel_by_name() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let (rows, err) = panel_menu(e, "zz_no_such_panel");
        assert!(rows.is_empty());
        assert!(err.contains("UnknownPanel") && err.contains("zz_no_such_panel"), "{err}");
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn dispatch_runs_a_panel_menu_item_with_its_panel_active() {
        // Align > Use Preview Bounds: `toggle_use_preview_bounds` writes the
        // ACTIVE panel's `use_preview_bounds` (a `set_panel_state` with no
        // `panel:`), so it only moves when the item runs with its panel active.
        // The shell names the panel and the item's index; the core reads the
        // item's action and params from that panel's menu.
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let pid = "align_panel_content";
        let _ = panel_menu(e, pid); // the shell reads the menu before a click
        let before = engine_of(e).store.borrow().get_panel(pid, "use_preview_bounds").clone();
        let (reply, err) = dispatch(e, r#"{"panel":"align_panel_content","menu_index":0}"#);
        assert!(!reply.is_empty() && err.is_empty(), "Use Preview Bounds ran: {err}");
        let after = engine_of(e).store.borrow().get_panel(pid, "use_preview_bounds").clone();
        assert_ne!(before, after, "the panel's own flag moved: {before} -> {after}");
        unsafe { jas_engine_free(e) };
        // CONTROL, on a fresh engine where no panel was ever made active: the
        // same action by id leaves the panel's flag. (The active panel then
        // persists, as after a widget click, so the control cannot follow the
        // panel run on the same engine.)
        let f = jas_engine_new();
        let _ = panel_menu(f, pid);
        let was = engine_of(f).store.borrow().get_panel(pid, "use_preview_bounds").clone();
        let _ = dispatch(f, r#"{"action":"toggle_use_preview_bounds"}"#);
        assert_eq!(engine_of(f).store.borrow().get_panel(pid, "use_preview_bounds"), &was,
            "without its panel the action cannot reach the panel's state");
        unsafe { jas_engine_free(f) };
    }

    #[test]
    fn dispatch_runs_an_action_by_id_in_a_named_panels_scope() {
        // `{"panel", "action"}`: an action a panel's own widget runs (a
        // breadcrumb's `exit_isolation_to_level`, on no menu), with that panel
        // active and in its scope, as the widget's click runs it. The same
        // action with no panel cannot reach the panel's state (the control in
        // the test above).
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let pid = "align_panel_content";
        let _ = panel_menu(e, pid);
        let before = engine_of(e).store.borrow().get_panel(pid, "use_preview_bounds").clone();
        let (reply, err) = dispatch(e, r#"{"panel":"align_panel_content","action":"toggle_use_preview_bounds"}"#);
        assert!(!reply.is_empty() && err.is_empty(), "the action ran in its panel: {err}");
        let after = engine_of(e).store.borrow().get_panel(pid, "use_preview_bounds").clone();
        assert_ne!(before, after, "the panel's own flag moved: {before} -> {after}");
        // Neither a menu index nor an action names nothing to run.
        let (r2, e2) = dispatch(e, r#"{"panel":"align_panel_content"}"#);
        assert!(r2.is_empty() && e2.contains("UnknownMenuItem"), "{e2}");
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn dispatch_refuses_a_panel_menu_index_or_panel_it_does_not_have_and_runs_nothing() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let (r1, e1) = dispatch(e, r#"{"panel":"zz_no_such_panel","menu_index":0}"#);
        assert!(r1.is_empty() && e1.contains("UnknownPanel") && e1.contains("zz_no_such_panel"), "{e1}");
        let (r2, e2) = dispatch(e, r#"{"panel":"align_panel_content","menu_index":99}"#);
        assert!(r2.is_empty() && e2.contains("UnknownMenuItem") && e2.contains("99"), "{e2}");
        // A separator is a node with no action: refused as MissingAction.
        let (r3, e3) = dispatch(e, r#"{"panel":"align_panel_content","menu_index":1}"#);
        assert!(r3.is_empty() && e3.contains("MissingAction"), "{e3}");
        unsafe { jas_engine_free(e) };
    }

    fn engine_of<'a>(e: *mut JasEngine) -> &'a JasEngine {
        unsafe { e.as_ref() }.unwrap()
    }

    /// The plan leaf with widget id `id`, from a fresh plan of `panel`.
    fn leaf(e: *mut JasEngine, panel: &str, id: &str) -> serde_json::Value {
        let plan: serde_json::Value = serde_json::from_str(&plan_of(e, panel, 228, 0)).unwrap();
        plan["leaves"].as_array().unwrap().iter()
            .find(|l| l["id"] == id)
            .unwrap_or_else(|| panic!("no leaf {id} in the {panel} plan"))
            .clone()
    }

    /// **Q4.** Align Left on a two-element selection gives the document the
    /// shared host gives, in ONE undo step, named as the web path names it.
    #[test]
    fn panel_behavior_align_left_is_the_shared_host_in_one_undo_step() {
        use crate::interpreter::align_host::{apply_align_operation, AlignInput, AlignTo};
        use crate::panel_behavior::test_fixture::misaligned;
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_with(misaligned(&[0, 1]));
        let before = doc_json(e);
        // The oracle: the host every port's Align button reaches, run directly
        // on a copy, with the panel's declared defaults.
        let mut copy = engine_of(e).with_model(|m| m.clone());
        let input = AlignInput { align_to: AlignTo::Selection, key_object_path: None,
                                 distribute_spacing: 0.0, use_preview_bounds: false,
                                 artboard_selection: vec![] };
        apply_align_operation(&mut copy, "align_left", &input);
        let expected = crate::geometry::test_json::document_to_test_json(copy.document());
        assert_ne!(expected, before, "fixture: Align Left must move something here");

        let (reply, err) = behave(e, ALIGN, LEFT);
        let reply: serde_json::Value = serde_json::from_str(&reply)
            .unwrap_or_else(|_| panic!("the reply must be JSON: {reply:?} (error {err:?})"));
        assert_eq!(reply["doc_changed"], true, "{reply}");
        assert_eq!(err, "", "a change leaves the error channel empty");
        assert_eq!(doc_json(e), expected, "the engine's click is not the shared host's move");
        let name = engine_of(e).with_model(|m| {
            assert!(!m.in_txn(), "the click left its transaction open");
            m.journal()[..m.journal_head()].last().and_then(|t| t.name.clone())
        });
        assert_eq!(name.as_deref(), Some("align_left"), "the web path names it align_left");

        undo(e);
        assert_eq!(doc_json(e), before, "ONE undo must restore the pre-click document");
        assert!(!engine_of(e).with_model(|m| m.can_undo()),
                "a second undo step exists, so the click took more than one");
        unsafe { jas_engine_free(e) };
    }

    /// **D8.** The reply is `{"changed": [...], "doc_changed": bool}` and a
    /// changed row carries its panel. An Align-To toggle moves the panel's own
    /// rows (its `checked` bindings) without touching the document.
    #[test]
    fn panel_behavior_replies_with_the_changed_rows_and_doc_changed() {
        use crate::panel_behavior::test_fixture::misaligned;
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_with(misaligned(&[0, 1]));
        // A second open panel whose rows read its OWN `panel.*` defaults
        // (`magic_wand`'s tolerances): resolved in Align's scope instead,
        // they would all look moved.
        let _ = plan_of(e, "magic_wand_panel_content", 228, 0);
        let before = doc_json(e);
        // Values are canonical strings (`bind_values`' row shape): "true" / "false".
        assert_eq!(leaf(e, ALIGN, "align_to_artboard_button")["values"]["bind.checked"], "false");
        let (reply, err) = behave(e, ALIGN,
                                  r#"{"widget":"align_to_artboard_button","event":"click"}"#);
        let reply: serde_json::Value = serde_json::from_str(&reply)
            .unwrap_or_else(|_| panic!("the reply must be JSON: {reply:?} (error {err:?})"));
        let keys: Vec<&String> = reply.as_object().unwrap().keys().collect();
        assert_eq!(keys, vec!["changed", "clipboard_write", "close_window", "dialog", "doc_changed", "remove_tab", "save_all_then_close"], "{reply}");
        assert_eq!(reply["doc_changed"], false);
        assert_eq!(err, "", "rows moved, so this is not Unchanged");
        let changed = reply["changed"].as_array().expect("changed is an array");
        let row = changed.iter()
            .find(|r| r["id"] == "align_to_artboard_button" && r["key"] == "bind.checked")
            .unwrap_or_else(|| panic!("the toggle's own checked row did not move: {reply}"));
        assert_eq!(row["value"], "true");
        assert_eq!(row["panel"], ALIGN);
        assert!(changed.iter().all(|r| r["panel"] == ALIGN), "{reply}");
        assert_eq!(doc_json(e), before);
        unsafe { jas_engine_free(e) };
    }

    /// **Q4's control.** A pair already aligned moves nothing, and the engine
    /// SAYS so: never a silent Ok.
    #[test]
    fn panel_behavior_an_aligned_pair_is_unchanged_and_says_so() {
        use crate::panel_behavior::test_fixture::{model_with, rect};
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_with(model_with(
            vec![rect(10.0, 0.0, 5.0, 5.0), rect(10.0, 20.0, 5.0, 5.0)], &[0, 1]));
        let before = doc_json(e);
        let (reply, err) = behave(e, ALIGN, LEFT);
        assert_eq!(reply, r#"{"changed":[],"clipboard_write":null,"close_window":false,"dialog":null,"doc_changed":false,"remove_tab":null,"save_all_then_close":false}"#);
        assert_eq!(err, refusal("Unchanged", "align_left_button"));
        assert_eq!(doc_json(e), before);
        assert!(!engine_of(e).with_model(|m| m.can_undo()), "an empty step was recorded");
        unsafe { jas_engine_free(e) };
    }

    /// **Q6's replay, on the box's own fixture and the sitting's own widget.**
    /// `Canvas.ApplyPanelSynth` drives exactly this sequence through the same
    /// two exports, and the harness (`Get-SbPaneVerdicts`) asserts what the box
    /// reads. This arm is what makes that reading predictable before any box
    /// runs it: nothing selected is REFUSED `Disabled`; `select_all` enables
    /// the button without an undo step; the click moves the document; the same
    /// click again is `Unchanged`; ONE undo restores the post-select document.
    ///
    /// ⛔ THE WIDGET ID IS READ OUT OF `sitting.ps1`, NOT TYPED HERE. The
    /// sitting's `SB_PANEL_SYNTH` value is what the box will click, so a rename
    /// in `align.yaml` reds THIS arm in CI instead of a refusal on the box.
    #[test]
    fn panel_behavior_the_q6_replay_on_the_calibrated_fixture() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/..");
        let sitting = std::fs::read_to_string(format!("{root}/prototypes/sb_winui/sitting.ps1")).unwrap();
        let knob: Vec<&str> = sitting.match_indices("SB_PANEL_SYNTH = '")
            .map(|(k, m)| {
                let rest = &sitting[k + m.len()..];
                &rest[..rest.find('\'').unwrap()]
            })
            .collect();
        assert_eq!(knob.len(), 1, "sitting.ps1 must set SB_PANEL_SYNTH exactly once: {knob:?}");
        let widget = knob[0];
        let click = format!(r#"{{"widget":"{widget}","event":"click"}}"#);

        let svg = std::fs::read_to_string(format!("{root}/test_fixtures/svg/complex_document.svg")).unwrap();
        let e = jas_engine_new();
        engine_of(e).replace_document(crate::geometry::svg::try_svg_to_document(&svg).unwrap());
        let selected = || unsafe { crate::ffi_pointer::jas_selection_len(e) };
        let dispatch = |op: &str| unsafe { jas_dispatch_event(e, op.as_ptr(), op.len()) };

        // SYNTH-H0 -> H0B: nothing is selected, so the core refuses by name.
        assert_eq!(selected(), 0, "the fixture opens with nothing selected");
        assert_eq!(leaf(e, ALIGN, widget)["values"]["bind.disabled"], "true");
        let h0 = doc_json(e);
        assert_eq!(behave(e, ALIGN, &click), (String::new(), refusal("Disabled", widget)));
        assert_eq!(doc_json(e), h0, "a refused click moved the document");

        // -> HS: select_all is selection-only, so it enables the button and
        // records no undo step.
        assert_eq!(dispatch(r#"{"op":"select_all"}"#), JasStatus::Ok);
        assert!(selected() >= 2, "Align needs two; select_all selected {}", selected());
        assert_eq!(leaf(e, ALIGN, widget)["values"]["bind.disabled"], "false");
        assert!(!engine_of(e).with_model(|m| m.can_undo()), "select_all recorded an undo step");
        let hs = doc_json(e);

        // -> H1: the behavior runs and moves the document.
        let (reply, err) = behave(e, ALIGN, &click);
        assert_eq!((reply.as_str(), err.as_str()), (r#"{"changed":[],"clipboard_write":null,"close_window":false,"dialog":null,"doc_changed":true,"remove_tab":null,"save_all_then_close":false}"#, ""));
        let h1 = doc_json(e);
        assert_ne!(h1, hs, "the click reported a change and the document did not move");

        // -> H1B: the selection is aligned now, and the engine SAYS so.
        assert_eq!(behave(e, ALIGN, &click),
                   (r#"{"changed":[],"clipboard_write":null,"close_window":false,"dialog":null,"doc_changed":false,"remove_tab":null,"save_all_then_close":false}"#.to_string(), refusal("Unchanged", widget)));
        assert_eq!(doc_json(e), h1);

        // -> H2: ONE undo restores the post-select document, so the second
        // click recorded no step.
        undo(e);
        assert_eq!(doc_json(e), hs, "one undo did not restore the pre-click document");
        assert!(!engine_of(e).with_model(|m| m.can_undo()), "more than one step was recorded");
        unsafe { jas_engine_free(e) };
    }

    /// The single value `sitting.ps1` assigns to `knob` (`KNOB = '<value>'`),
    /// or a panic naming how many it found. `SB_PANEL = '` cannot match inside
    /// `SB_PANEL_COMMIT = '`: the character after the name differs.
    fn sitting_knob(sitting: &str, knob: &str) -> String {
        let needle = format!("{knob} = '");
        let found: Vec<&str> = sitting.match_indices(needle.as_str())
            .map(|(k, m)| {
                let rest = &sitting[k + m.len()..];
                &rest[..rest.find('\'').unwrap()]
            })
            .collect();
        assert_eq!(found.len(), 1, "sitting.ps1 must set {knob} exactly once: {found:?}");
        found[0].to_string()
    }

    /// How many of `reply`'s rows for `panel` disagree with `plan`, keyed by
    /// (path, key) exactly as the shell's `DeltaMismatches` keys them. A row
    /// the plan withheld must be named in `withheld`.
    fn delta_mismatches(reply: &serde_json::Value, plan: &serde_json::Value, panel: &str) -> usize {
        let mut values = std::collections::HashMap::new();
        for list in ["chrome", "leaves", "containers"] {
            for e in plan[list].as_array().unwrap() {
                for (k, v) in e["values"].as_object().unwrap() {
                    values.insert((e["path"].to_string(), k.clone()), v.clone());
                }
            }
        }
        let withheld: std::collections::HashSet<(String, String)> = plan["withheld"]
            .as_array().unwrap().iter()
            .map(|w| (w["path"].to_string(), w["key"].as_str().unwrap().to_string()))
            .collect();
        reply["changed"].as_array().unwrap().iter()
            .filter(|r| r["panel"] == panel)
            .filter(|r| {
                let k = (r["path"].to_string(), r["key"].as_str().unwrap().to_string());
                match values.get(&k) {
                    Some(v) => *v != r["value"],
                    None => !withheld.contains(&k),
                }
            })
            .count()
    }

    /// **W2b-3's replay, on the sitting's own panel, widgets and text.**
    /// `Canvas.ApplyPanelValueSynth` drives exactly this sequence through the
    /// same two exports, re-reading the plan after every step, and the harness
    /// (`Get-SbValueVerdicts`, V1-V6) asserts what the box reads. This arm is
    /// what makes that reading predictable before any box runs it:
    ///
    ///   read     v0 d0 c0     the tolerance's value and disabled, the toggle's checked
    ///   commit   `abc`        REFUSED BadValue; nothing moves
    ///   commit   the text     a clean change; the value reads the text
    ///   press    the toggle   a clean change; checked AND disabled flip; the value holds
    ///   press    again        a clean change; both come back; the value still holds
    ///
    /// ⛔ THE PANEL, THE WIDGETS AND THE TEXT ARE READ OUT OF `sitting.ps1`, NOT
    /// TYPED HERE, with the shell's split rule (the FIRST `:`). A rename in
    /// `magic_wand.yaml` or an edit to the route reds THIS arm in CI instead of
    /// a refusal on the box.
    #[test]
    fn panel_behavior_the_value_replay_on_the_sittings_panel() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/..");
        let sitting = std::fs::read_to_string(format!("{root}/prototypes/sb_winui/sitting.ps1")).unwrap();
        let panel = sitting_knob(&sitting, "SB_PANEL");
        let commit_knob = sitting_knob(&sitting, "SB_PANEL_COMMIT");
        let press = sitting_knob(&sitting, "SB_PANEL_PRESS");
        let (commit, text) = commit_knob.split_once(':')
            .unwrap_or_else(|| panic!("SB_PANEL_COMMIT='{commit_knob}' has no ':'"));
        assert!(!commit.is_empty(), "SB_PANEL_COMMIT='{commit_knob}' names no widget");

        // The box's own start: the sitting's document, then the plan.
        let svg = std::fs::read_to_string(format!("{root}/test_fixtures/svg/complex_document.svg")).unwrap();
        let e = jas_engine_new();
        engine_of(e).replace_document(crate::geometry::svg::try_svg_to_document(&svg).unwrap());
        let plan = || -> serde_json::Value {
            let raw = plan_of(e, &panel, 228, 0);
            serde_json::from_str(&raw).unwrap_or_else(|_| panic!("{panel}: no plan: {raw:?}"))
        };
        let read = |p: &serde_json::Value, id: &str, key: &str| -> String {
            let leaf = p["leaves"].as_array().unwrap().iter()
                .find(|l| l["id"] == id)
                .unwrap_or_else(|| panic!("no leaf {id} in the {panel} plan"));
            leaf["values"][key].as_str()
                .unwrap_or_else(|| panic!("{id} carries no string {key}: {leaf}"))
                .to_string()
        };
        let readings = |p: &serde_json::Value| -> (String, String, String) {
            (read(p, commit, "bind.value"), read(p, commit, "bind.disabled"),
             read(p, press.as_str(), "bind.checked"))
        };
        let send = |ev: serde_json::Value| behave(e, &panel, &ev.to_string());
        let class = |err: &str| -> String {
            serde_json::from_str::<serde_json::Value>(err).ok()
                .and_then(|v| v["panel_event"].as_str().map(str::to_string))
                .unwrap_or_default()
        };
        let before = doc_json(e);

        // v0 d0 c0.
        let (v0, d0, c0) = readings(&plan());
        assert_eq!(d0, "false", "{commit} must start enabled: v0={v0} d0={d0} c0={c0}");
        assert_ne!(v0, text, "the commit could not be seen: v0={v0} text={text}");

        // `abc`: refused BadValue, nothing moved.
        let (reply, err) = send(serde_json::json!({"widget": commit, "event": "commit", "value": "abc"}));
        let pb = plan();
        let (vb, db, cb) = readings(&pb);
        assert_eq!((reply.as_str(), class(&err).as_str()), ("", "BadValue"),
                   "abc must be refused BadValue: reply={reply:?} err={err}");
        assert_eq!((&vb, &db, &cb), (&v0, &d0, &c0),
                   "a refused commit moved a reading: v={v0}->{vb} d={d0}->{db} c={c0}->{cb}");

        // The text: a clean change, and the value reads the text.
        let (reply, err) = send(serde_json::json!({"widget": commit, "event": "commit", "value": text}));
        let p1 = plan();
        let (v1, d1, c1) = readings(&p1);
        let r1 = reply_json(&reply, &err);
        assert_eq!(err, "", "the commit must clear the channel: reply={reply} v1={v1}");
        assert_eq!(delta_mismatches(&r1, &p1, &panel), 0, "the commit's rows disagree with the plan: {reply}");
        assert_eq!(v1, text, "the value must read the committed text: v0={v0} v1={v1}");
        assert_eq!((&d1, &c1), (&d0, &c0), "the commit moved another reading: d1={d1} c1={c1}");

        // The press: checked and disabled flip, the value holds.
        let (reply, err) = send(serde_json::json!({"widget": press, "event": "click"}));
        let p2 = plan();
        let (v2, d2, c2) = readings(&p2);
        let r2 = reply_json(&reply, &err);
        assert_eq!(err, "", "the press must clear the channel: reply={reply} c2={c2} d2={d2}");
        assert_eq!(delta_mismatches(&r2, &p2, &panel), 0, "the press's rows disagree with the plan: {reply}");
        assert_ne!(c2, c1, "the press did not flip checked: c1={c1} c2={c2}");
        assert_ne!(d2, d1, "the press did not flip disabled: d1={d1} d2={d2}");
        assert_eq!(v2, v1, "the press moved the value: v1={v1} v2={v2}");

        // Again: both come back, the value still holds.
        let (reply, err) = send(serde_json::json!({"widget": press, "event": "click"}));
        let p3 = plan();
        let (v3, d3, c3) = readings(&p3);
        let r3 = reply_json(&reply, &err);
        assert_eq!(err, "", "the second press must clear the channel: reply={reply} c3={c3} d3={d3}");
        assert_eq!(delta_mismatches(&r3, &p3, &panel), 0, "the second press's rows disagree with the plan: {reply}");
        assert_eq!((&c3, &d3), (&c0, &d0), "the second press did not restore: c={c0}->{c2}->{c3} d={d0}->{d2}->{d3}");
        assert_eq!(v3, text, "the value did not hold: v={v0}/{vb}/{v1}/{v2}/{v3}");

        // A panel's values are not the document.
        assert_eq!(doc_json(e), before, "the replay moved the document");
        eprintln!("W2b-3 value replay on {panel}: commit={commit} text={text} press={press} \
                   value={v0}/{vb}/{v1}/{v2}/{v3} disabled={d0}/{db}/{d1}/{d2}/{d3} \
                   checked={c0}/{cb}/{c1}/{c2}/{c3}");
        unsafe { jas_engine_free(e) };
    }

    // -----------------------------------------------------------------------
    // W2b-4 -- the Stroke panel's writes reach the selection (A10's stroke
    // family through A11). W2b-0 (d) measured 13 stroke clicks reading
    // `doc_changed=false` with four elements selected.
    // -----------------------------------------------------------------------

    const STROKE: &str = crate::interpreter::stroke_host::STROKE_PANEL;

    /// The calibrated fixture with everything selected, as the W2b-0 census
    /// drove it.
    fn stroked_engine() -> *mut JasEngine {
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/..");
        let svg = std::fs::read_to_string(format!("{root}/test_fixtures/svg/complex_document.svg")).unwrap();
        let e = jas_engine_new();
        engine_of(e).replace_document(crate::geometry::svg::try_svg_to_document(&svg).unwrap());
        let op = r#"{"op":"select_all"}"#;
        assert_eq!(unsafe { jas_dispatch_event(e, op.as_ptr(), op.len()) }, JasStatus::Ok);
        assert!(unsafe { crate::ffi_pointer::jas_selection_len(e) } >= 2);
        e
    }

    /// The selected elements' strokes, in selection order.
    fn selected_strokes(e: *mut JasEngine) -> Vec<Option<crate::geometry::element::Stroke>> {
        engine_of(e).with_model(|m| {
            let doc = m.document();
            doc.selection.iter()
                .map(|es| doc.get_element(&es.path).and_then(|el| el.stroke().cloned()))
                .collect()
        })
    }

    fn reply_json(reply: &str, err: &str) -> serde_json::Value {
        serde_json::from_str(reply)
            .unwrap_or_else(|_| panic!("the reply must be JSON: {reply:?} (error {err:?})"))
    }

    /// The shared host run on a copy of the engine's model, with the panel
    /// the engine's store holds NOW, for each render key in `keys`.
    fn stroke_oracle(e: *mut JasEngine, pre: &Model, keys: &[&str]) -> String {
        use crate::interpreter::stroke_host::{apply_stroke_panel_to_selection, StrokePanelState};
        let sp = StrokePanelState::from_store(&engine_of(e).store.borrow());
        let mut copy = pre.clone();
        for k in keys {
            apply_stroke_panel_to_selection(&mut copy, &sp, k, None);
        }
        crate::geometry::test_json::document_to_test_json(copy.document())
    }

    /// **W2b-4's oracle.** A Cap click on the selection writes what the shared
    /// host writes, in ONE undo step.
    #[test]
    fn stroke_cap_click_writes_the_selection_as_the_shared_host_does() {
        use crate::geometry::element::LineCap;
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = stroked_engine();
        let pre = engine_of(e).with_model(|m| m.clone());
        let before = doc_json(e);
        assert!(selected_strokes(e).iter().flatten().any(|s| s.linecap != LineCap::Round),
                "stop 2: the fixture must hold a stroke a Round cap changes");

        let (reply, err) = behave(e, STROKE, r#"{"widget":"stk_cap_round","event":"click"}"#);
        assert_eq!(reply_json(&reply, &err)["doc_changed"], true, "{reply}");
        assert_eq!(err, "");
        let after = doc_json(e);
        assert_ne!(after, before);
        assert_eq!(after, stroke_oracle(e, &pre, &["stroke_cap"]));
        // A second reading, not through the oracle: every selected element
        // that carries a stroke (a group carries none) is round.
        let strokes: Vec<_> = selected_strokes(e).into_iter().flatten().collect();
        assert!(strokes.len() >= 2 && strokes.iter().all(|s| s.linecap == LineCap::Round),
                "{strokes:?}");

        undo(e);
        assert_eq!(doc_json(e), before, "ONE undo must restore the pre-click document");
        assert!(!engine_of(e).with_model(|m| m.can_undo()), "the click took more than one step");
        unsafe { jas_engine_free(e) };
    }

    /// The RISK the W2b-1 bank carried: a Weight commit moved `panel.weight`
    /// and not the selection. It moves the selection now, through the bind
    /// write's global (`state.stroke_width`).
    #[test]
    fn stroke_weight_commit_writes_the_selection_width() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = stroked_engine();
        let pre = engine_of(e).with_model(|m| m.clone());
        let (reply, err) = behave(e, STROKE,
                                  r#"{"widget":"stk_weight","event":"commit","value":"7"}"#);
        assert_eq!(reply_json(&reply, &err)["doc_changed"], true, "{reply}");
        assert_eq!(doc_json(e), stroke_oracle(e, &pre, &["stroke_width"]));
        let strokes: Vec<_> = selected_strokes(e).into_iter().flatten().collect();
        assert!(strokes.len() >= 2 && strokes.iter().all(|s| s.width == 7.0), "{strokes:?}");
        assert_eq!(engine_of(e).store.borrow().get("stroke_width").as_f64(), Some(7.0));
        unsafe { jas_engine_free(e) };
    }

    /// **The trigger is the WRITE, not a change of the stored value.** After an
    /// undo the artwork is Butt again while the store still says Round; the
    /// same click must put Round back. (The reference's store skips an equal
    /// write, and Swift and the web app do not; this is theirs.)
    #[test]
    fn stroke_click_after_an_undo_writes_the_selection_again() {
        use crate::geometry::element::LineCap;
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = stroked_engine();
        let click = r#"{"widget":"stk_cap_round","event":"click"}"#;
        let (reply, err) = behave(e, STROKE, click);
        assert_eq!(reply_json(&reply, &err)["doc_changed"], true, "{reply}");
        undo(e);
        assert_eq!(engine_of(e).store.borrow().get("stroke_cap"), &serde_json::json!("round"),
                   "the premise: undo does not move the store");
        let (reply, err) = behave(e, STROKE, click);
        assert_eq!(reply_json(&reply, &err)["doc_changed"], true, "{reply} {err}");
        let strokes: Vec<_> = selected_strokes(e).into_iter().flatten().collect();
        assert!(strokes.len() >= 2 && strokes.iter().all(|s| s.linecap == LineCap::Round),
                "{strokes:?}");
        unsafe { jas_engine_free(e) };
    }

    /// The control: a Stroke click whose global is not a render key (the
    /// link-scales chain) moves the panel and not the artwork.
    #[test]
    fn stroke_link_scales_click_writes_no_element() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = stroked_engine();
        let before = doc_json(e);
        let (reply, err) = behave(e, STROKE,
                                  r#"{"widget":"stk_link_arrowhead_scale","event":"click"}"#);
        assert_eq!(reply_json(&reply, &err)["doc_changed"], false, "{reply}");
        assert_eq!(err, "", "the store moved, so this is not Unchanged");
        assert_eq!(doc_json(e), before);
        unsafe { jas_engine_free(e) };
    }

    /// **W2b-0 (d) re-driven, by census.** Every Stroke click whose behavior
    /// writes a render key, on a fresh engine over the calibrated fixture with
    /// everything selected, leaves the document the shared host leaves. The
    /// widgets and their keys are READ from the spec. At least one of them
    /// must change the document: (d) was every one of them reading `false`.
    #[test]
    fn every_stroke_click_that_writes_a_render_key_is_the_shared_host() {
        use crate::interpreter::stroke_host::is_render_key;
        let _counters = crate::ffi_instr::test_lock::lock();
        let ws = Workspace::load().unwrap();
        let mut clicks: Vec<(String, Vec<String>)> = vec![];
        fn walk(node: &serde_json::Value, actions: &serde_json::Value,
                out: &mut Vec<(String, Vec<String>)>) {
            if let (Some(id), Some(behaviors)) = (node["id"].as_str(), node["behavior"].as_array()) {
                for b in behaviors {
                    if b["event"].as_str().unwrap_or("click") != "click" {
                        continue;
                    }
                    // A render key is written by `set:` or by `swap:` (Swap
                    // Arrowheads, whose batch the engine refused until it
                    // hosted `swap_panel_state`). A behavior that names an
                    // `action` writes what that action's effects write (the
                    // Swap button, since 2026-10-25).
                    let body = match b["action"].as_str() {
                        Some(a) => &actions[a]["effects"],
                        None => &b["effects"],
                    };
                    let effects = || body.as_array().into_iter().flatten();
                    let keys: Vec<String> = effects()
                        .filter_map(|eff| eff["set"].as_object())
                        .flat_map(|m| m.keys().cloned())
                        .chain(effects().filter_map(|eff| eff["swap"].as_array())
                            .flat_map(|a| a.iter().filter_map(|k| k.as_str().map(String::from))))
                        .filter(|k| is_render_key(k))
                        .collect();
                    if !keys.is_empty() {
                        out.push((id.to_string(), keys));
                    }
                }
            }
            for k in ["children", "do"] {
                if let Some(items) = node[k].as_array() {
                    items.iter().for_each(|c| walk(c, actions, out));
                }
            }
        }
        walk(&ws.panel(STROKE).unwrap()["content"], ws.actions(), &mut clicks);
        assert!(clicks.len() >= 10, "the census read {} clicks: {clicks:?}", clicks.len());
        assert!(clicks.iter().any(|(w, _)| w == "stk_swap_arrowheads"),
                "the `swap:` writes are not in the census: {clicks:?}");
        let mut changed = 0;
        for (widget, keys) in &clicks {
            let e = stroked_engine();
            let pre = engine_of(e).with_model(|m| m.clone());
            let before = doc_json(e);
            let click = format!(r#"{{"widget":"{widget}","event":"click"}}"#);
            let (reply, err) = behave(e, STROKE, &click);
            let reply = reply_json(&reply, &err);
            let keys: Vec<&str> = keys.iter().map(String::as_str).collect();
            let after = doc_json(e);
            assert_eq!(after, stroke_oracle(e, &pre, &keys), "{widget}");
            assert_eq!(reply["doc_changed"] == true, after != before, "{widget}: {reply}");
            changed += usize::from(after != before);
            unsafe { jas_engine_free(e) };
        }
        assert!(changed > 0, "no stroke click changed the document: W2b-0 (d) still stands");
    }


    // -----------------------------------------------------------------------
    // W2b-5 -- the Properties panel's display and edits (A10's properties
    // family, through the store's panel-write report). W2b-0 measured one
    // Properties behavior (the constrain lock) and none of its eight fields:
    // no field declares a behavior, and the plan showed the seeded zeros.
    // -----------------------------------------------------------------------

    const PROPERTIES: &str = crate::interpreter::properties_host::PROPERTIES_PANEL;

    /// The calibrated fixture, all selected. It carries no transform, and the
    /// `assert` below keeps it that way.
    ///
    /// ⚠️ THE REASON CHANGED ON 2026-09-18 AND THE FIXTURE DID NOT. This
    /// comment used to read *"Properties X is in the S-3 transform-blind class
    /// (`properties_host::apply_field`), so 'X = 40 puts the box at 40' holds
    /// only on an untransformed selection"* — a real precondition that S-3
    /// (#188) removed: `apply_field` hands `move_selection` a document-space
    /// delta and that delta is now converted, so the oracle holds on a
    /// transformed selection too (`an_x_edit_lands_on_a_transformed_selection`).
    /// The fixture stays untransformed because it is the CALIBRATED one and
    /// changing it would move every number measured against it — which is a
    /// different reason from the one that used to be written here, and the
    /// assert is a staleness guard on the fixture, not on the oracle.
    fn untransformed_engine() -> *mut JasEngine {
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/..");
        let svg = std::fs::read_to_string(format!("{root}/test_fixtures/svg/complex_document.svg")).unwrap();
        assert_eq!(svg.matches("transform").count(), 0, "the fixture grew a transform");
        assert!(svg.matches("<rect").count() + svg.matches("<path").count() > 0);
        stroked_engine()
    }

    fn selection_box(e: *mut JasEngine) -> (f64, f64, f64, f64) {
        engine_of(e).with_model(|m| {
            crate::document::evaluated_bounds::selection_evaluated_bounds(m.document())
        })
    }

    fn plan_number(e: *mut JasEngine, id: &str) -> f64 {
        let leaf = leaf(e, PROPERTIES, id);
        leaf["values"]["bind.value"].as_str()
            .and_then(|t| t.parse::<f64>().ok())
            .unwrap_or_else(|| panic!("{id} carries no number: {leaf}"))
    }

    /// **The plan shows the selection's box**, not the panel's seeded zeros.
    /// The expectation is the box of the engine's own document, rounded as the
    /// panel shows it, computed without the scope the plan is built from.
    #[test]
    fn properties_plan_shows_the_selection_box() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = untransformed_engine();
        let (x, y, w, h) = selection_box(e);
        assert!(w > 0.0 && h > 0.0, "the selection has no box: {w} x {h}");
        let r2 = |v: f64| (v * 100.0).round() / 100.0;
        for (id, want) in [("prop_x", r2(x)), ("prop_y", r2(y)), ("prop_w", r2(w)), ("prop_h", r2(h))] {
            assert_eq!(plan_number(e, id), want, "{id}");
        }
        unsafe { jas_engine_free(e) };
    }

    // -----------------------------------------------------------------------
    // W2b-6 -- the Character panel's field-scoped apply, through the store's
    // panel-write report. The law is shared with the web app and with the
    // reference (`workspace_interpreter/character_law.py`); before W2b-6 the
    // engine could not call any of it.
    // -----------------------------------------------------------------------

    const CHARACTER: &str = crate::interpreter::character_host::CHARACTER_PANEL;

    /// `(font_size, font_family, font_weight)` of every selected Text /
    /// TextPath, in selection order. Read off the ELEMENTS, never through the
    /// host, so the oracle cannot agree with the thing it is checking.
    fn selected_text_faces(e: *mut JasEngine) -> Vec<(f64, String, String)> {
        use crate::geometry::element::Element;
        engine_of(e).with_model(|m| {
            let doc = m.document();
            doc.selection.iter()
                .filter_map(|es| match doc.get_element(&es.path) {
                    Some(Element::Text(t)) =>
                        Some((t.font_size, t.font_family.clone(), t.font_weight.clone())),
                    Some(Element::TextPath(tp)) =>
                        Some((tp.font_size, tp.font_family.clone(), tp.font_weight.clone())),
                    _ => None,
                })
                .collect()
        })
    }

    /// **W2b-6's oracle.** A font-size commit on a selected text element puts
    /// that size on the element, writes what the shared host writes, and is
    /// ONE undo step.
    ///
    /// ⭐ **The third assert is the node's whole point and the first two would
    /// pass without it:** the commit must leave the element's OTHER character
    /// attributes alone. That is the field-scoped apply law
    /// (`transcripts/CHARACTER.md`), whose defect was a single edit resetting
    /// sixteen attributes to the panel's defaults — and on the engine path it
    /// was previously untestable, because the law was behind `feature = "web"`.
    #[test]
    fn character_font_size_commit_writes_only_the_size_on_the_selection() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = untransformed_engine();
        let before_faces = selected_text_faces(e);
        assert!(!before_faces.is_empty(),
                "the calibrated fixture has no selected text element, so this \
                 oracle would be vacuous");
        assert!(before_faces.iter().all(|f| f.0 != 48.0),
                "the commit could not be seen: something is already 48pt");
        let before = doc_json(e);

        let pre = engine_of(e).with_model(|m| m.clone());
        let (reply, err) = behave(
            // ⚠️ THE WIDGET ID IS NOT THE FIELD KEY. The panel's controls are
            // `ch_`-prefixed (`ch_font_size`) and BIND `panel.font_size`, so the
            // store key the host sees is the unprefixed one. Driving the field
            // key here returns `MissingTarget` — which is how this was found.
            e, CHARACTER, r#"{"widget":"ch_font_size","event":"commit","value":"48"}"#);
        assert_eq!(err, "", "{reply}");
        let r = reply_json(&reply, &err);
        assert_eq!(r["doc_changed"], true, "{reply}");

        let after_faces = selected_text_faces(e);
        assert_eq!(after_faces.len(), before_faces.len());
        for (i, (a, b)) in after_faces.iter().zip(before_faces.iter()).enumerate() {
            assert_eq!(a.0, 48.0, "element {i} did not take the committed size");
            // FIELD SCOPING: family and weight are outside the FONT_SIZE group
            // and must be exactly what the element had.
            assert_eq!(a.1, b.1, "element {i}'s family was clobbered by a size edit");
            assert_eq!(a.2, b.2, "element {i}'s weight was clobbered by a size edit");
        }

        // The engine wrote what the SHARED host writes, applied to a copy of
        // the pre-commit model — the same equivalence W2b-5's oracle asserts.
        let mut copy = pre.clone();
        let mut cp = crate::interpreter::character_host::CharacterPanelState::from_store(
            &engine_of(e).store.borrow());
        cp.font_size = 48.0;
        crate::interpreter::character_host::apply_to_selection(&mut copy, &cp, "font_size");
        assert_eq!(doc_json(e),
                   crate::geometry::test_json::document_to_test_json(copy.document()));

        undo(e);
        assert_eq!(doc_json(e), before, "ONE undo must restore the pre-commit document");
    }

    /// A `snap_*` flag owns no element attribute, so committing one must not
    /// touch the document — not even an undo step that changes nothing.
    ///
    /// ⭐ **AND IT IS REFUSED ONE LAYER EARLIER THAN THE HOST, WHICH IS WORTH
    /// KNOWING RATHER THAN ASSUMING:** the panel declares NO behavior on these
    /// widgets, so the commit never reaches `panel_written` at all and the
    /// engine answers `EmptyBehavior`. `character_host::is_field_key` returning
    /// false for the seven flags is therefore belt-and-braces at this layer —
    /// it is load-bearing for a caller that writes the store key directly. The
    /// test asserts the refusal BY NAME, because "the document did not change"
    /// alone would also pass if the widget silently did nothing.
    #[test]
    fn a_character_ui_only_flag_writes_nothing_to_the_document() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = untransformed_engine();
        let before = doc_json(e);
        // `behave` returns (reply, err) and the refusal rides in the SECOND —
        // asserting on the first passes an empty string to `contains` and reds
        // with a blank message, which is how this line was got wrong once.
        let (reply, err) = behave(
            e, CHARACTER, r#"{"widget":"ch_snap_baseline","event":"commit","value":true}"#);
        assert!(err.contains("EmptyBehavior"),
                "expected the panel to declare no behavior on a UI-only flag: \
                 reply={reply} err={err}");
        assert_eq!(doc_json(e), before, "a UI-only flag reached the document");
        // And the host refuses it too, for a caller that reaches the store key
        // without going through a widget.
        assert!(!crate::interpreter::character_host::is_field_key("snap_baseline"));
        unsafe { jas_engine_free(e) };
    }

    // -----------------------------------------------------------------------
    // W2b-7 -- the Paragraph panel's whole-panel apply, through the store's
    // panel-write report. ⛔ UNLIKE CHARACTER THERE IS NO REFERENCE LAW HERE:
    // `workspace_interpreter` implements no paragraph law at all, so the only
    // two implementations are this one and Swift's `ParagraphPanelSync`.
    // -----------------------------------------------------------------------

    const PARAGRAPH: &str = crate::interpreter::paragraph_host::PARAGRAPH_PANEL;

    /// The paragraph wrapper tspan of every selected Text / TextPath, in
    /// selection order. Read off the ELEMENTS, never through the host, so the
    /// oracle cannot agree with the thing it is checking.
    fn selected_paragraph_wrappers(e: *mut JasEngine)
        -> Vec<Option<crate::geometry::tspan::Tspan>> {
        use crate::geometry::element::Element;
        engine_of(e).with_model(|m| {
            let doc = m.document();
            doc.selection.iter()
                .filter_map(|es| {
                    let tspans = match doc.get_element(&es.path) {
                        Some(Element::Text(t)) => t.tspans.clone(),
                        Some(Element::TextPath(tp)) => tp.tspans.clone(),
                        _ => return None,
                    };
                    Some(tspans.into_iter()
                         .find(|s| s.jas_role.as_deref() == Some("paragraph")))
                })
                .collect()
        })
    }

    /// flask STATUS 549 finding G: on Windows the Paragraph panel's Hyphenate
    /// checkbox read Off with two hyphenated paragraphs selected. The panel
    /// was opened BEFORE Select All, as flask's was, so this reads the plan the
    /// shell draws after the selection changed.
    #[test]
    fn the_paragraph_panel_hyphenate_checkbox_reads_the_selected_paragraphs() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_on("paragraph_hyphenated_mixed.svg");
        assert_eq!(leaf(e, PARAGRAPH, "pg_hyphenate")["values"]["bind.checked"], "false",
                   "nothing selected: the panel shows its default");
        let (reply, err) = dispatch(e, r#"{"action":"select_all","params":{}}"#);
        assert!(!reply.is_empty(), "select_all: {err}");
        assert_eq!(engine_of(e).with_model(|m| m.document().selection.len()), 2);
        assert_eq!(leaf(e, PARAGRAPH, "pg_hyphenate")["values"]["bind.checked"], "true",
                   "both selected paragraphs are hyphenated");
        unsafe { jas_engine_free(e) };
    }

    /// **W2b-7's oracle.** An alignment commit on a selected paragraph puts
    /// that alignment on the element's paragraph wrapper, writes what the
    /// shared host writes, and is ONE undo step.
    ///
    /// ⚠️ **The block priced this as "an alignment `icon_select`", and the
    /// alignment controls are icon-bearing CHECKBOXES** (`pg_align_center`,
    /// `type: checkbox`, `icon: para_align_center`). The panel's only two
    /// `icon_select`s are bullets and numbered-list. The oracle's SUBJECT was
    /// right and its widget type was not.
    ///
    /// ⭐ **The third assert is the one that would not pass by accident:** the
    /// paragraph write lands on the WRAPPER TSPAN and must leave the element's
    /// own character attributes alone. A whole-panel apply that reached the
    /// element would still satisfy the first two.
    #[test]
    fn paragraph_alignment_commit_writes_the_wrapper_on_the_selection() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = untransformed_engine();
        let before_wrappers = selected_paragraph_wrappers(e);
        assert!(!before_wrappers.is_empty(),
                "the calibrated fixture has no selected text element, so this \
                 oracle would be vacuous");
        assert!(before_wrappers.iter().all(|w| w.as_ref()
                    .and_then(|s| s.text_align.clone()).as_deref() != Some("center")),
                "the commit could not be seen: something is already centred");
        let before_faces = selected_text_faces(e);
        let before = doc_json(e);
        let pre = engine_of(e).with_model(|m| m.clone());

        // ⚠️ THE WIDGET ID IS NOT THE FIELD KEY: the controls are `pg_`-prefixed
        // and BIND `panel.align_center`, so the store key the host sees is the
        // unprefixed one.
        // ⚠️ A checkbox is a BOOLEAN kind, so its event is `click`/`change` and
        // the value is the NEGATION of the bound expression — not `commit`,
        // which is for input kinds and answers `EmptyBehavior` here.
        let (reply, err) = behave(
            e, PARAGRAPH, r#"{"widget":"pg_align_center","event":"click"}"#);
        assert_eq!(err, "", "{reply}");
        let r = reply_json(&reply, &err);
        assert_eq!(r["doc_changed"], true, "{reply}");

        let after = selected_paragraph_wrappers(e);
        assert_eq!(after.len(), before_wrappers.len());
        for (i, w) in after.iter().enumerate() {
            let w = w.as_ref().unwrap_or_else(||
                panic!("element {i} has no paragraph wrapper after the commit"));
            assert_eq!(w.text_align.as_deref(), Some("center"),
                       "element {i} did not take the committed alignment");
            assert!(w.content.is_empty(), "element {i}'s wrapper holds content");
        }
        // SCOPING: the paragraph write lives on the wrapper tspan and must not
        // have touched the element's own character attributes.
        assert_eq!(selected_text_faces(e), before_faces,
                   "an alignment commit changed the element's character attributes");

        // The engine wrote what the SHARED host writes, applied to a copy of
        // the pre-commit model.
        let mut copy = pre.clone();
        let pp = crate::interpreter::paragraph_host::ParagraphPanelState::from_store(
            &engine_of(e).store.borrow());
        crate::interpreter::paragraph_host::apply_to_selection(&mut copy, &pp);
        assert_eq!(doc_json(e),
                   crate::geometry::test_json::document_to_test_json(copy.document()));

        undo(e);
        assert_eq!(doc_json(e), before, "ONE undo must restore the pre-commit document");
        unsafe { jas_engine_free(e) };
    }

    /// **THE RADIO, DRIVEN IN BOTH DIRECTIONS — and the second direction is
    /// the one that can fail.** `bind_write` writes the ONE bool the user
    /// pressed and never clears its siblings, so the store can hold two
    /// alignment bools true at once. If the engine rebuilt the panel by
    /// replaying the store in `FIELDS` order, whichever key sits LATER in that
    /// array would win — which happens to be right for left -> centre and
    /// wrong for centre -> left. The order of a `const` array must not decide
    /// what a click does.
    #[test]
    fn the_alignment_radio_switches_back_as_well_as_forward() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = untransformed_engine();
        let align_of = |e: *mut JasEngine| -> Option<String> {
            selected_paragraph_wrappers(e).first().cloned().flatten()
                .and_then(|w| w.text_align)
        };

        let (reply, err) = behave(
            e, PARAGRAPH, r#"{"widget":"pg_align_center","event":"click"}"#);
        assert_eq!(err, "", "{reply}");
        assert_eq!(align_of(e).as_deref(), Some("center"), "forward: left -> centre");

        // Back to left. align_left is the default and writes NOTHING, so the
        // attribute must be ABSENT again — not still "center".
        let (reply, err) = behave(
            e, PARAGRAPH, r#"{"widget":"pg_align_left","event":"click"}"#);
        assert_eq!(err, "", "{reply}");
        assert_eq!(align_of(e), None,
                   "backward: centre -> left did not take; the store's stale \
                    sibling won over the key the user actually pressed");
        unsafe { jas_engine_free(e) };
    }

    /// **THE WHOLE-PANEL HAZARD, AND IT IS WHAT THE DOCUMENT BASE IS FOR.**
    /// A paragraph edit writes ALL sixteen fields, so every field the user did
    /// not touch is written from the base. If that base were the store — which
    /// only ever receives one key per press and is never synced from the
    /// selection — an alignment click would stamp the store's stale zeros over
    /// an indent the document actually carries.
    ///
    /// ⭐ Written because a mutant SURVIVED: basing `apply_field` on the store
    /// still passed the radio arm, because the edited-key-last line covers the
    /// radio case. Nothing witnessed the base itself until this.
    #[test]
    fn an_alignment_click_does_not_stamp_stale_values_over_untouched_fields() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = untransformed_engine();

        // Put an indent on the DOCUMENT without going through the panel, so
        // the store has never heard of it — exactly the state a fresh engine
        // is in after loading a file that already has paragraph formatting.
        engine_of(e).with_model_mut(|m| {
            let mut pp = crate::interpreter::paragraph_host::panel_from_document(
                m.document());
            pp.set_field("left_indent", &serde_json::json!(24.0));
            crate::interpreter::paragraph_host::apply_to_selection(m, &pp);
        });
        let indent_of = |e: *mut JasEngine| -> Option<f64> {
            selected_paragraph_wrappers(e).first().cloned().flatten()
                .and_then(|w| w.jas_left_indent)
        };
        assert_eq!(indent_of(e), Some(24.0), "the fixture's indent did not land");
        assert!(engine_of(e).store.borrow()
                    .get_panel(crate::interpreter::paragraph_host::PARAGRAPH_PANEL,
                               "left_indent").as_f64().unwrap_or(0.0) != 24.0,
                "the store already knows the indent, so this arm would be vacuous");

        let (reply, err) = behave(
            e, PARAGRAPH, r#"{"widget":"pg_align_center","event":"click"}"#);
        assert_eq!(err, "", "{reply}");

        // The edit landed AND the untouched field survived.
        assert_eq!(selected_paragraph_wrappers(e).first().cloned().flatten()
                       .and_then(|w| w.text_align).as_deref(), Some("center"));
        assert_eq!(indent_of(e), Some(24.0),
                   "an alignment click stamped a stale value over the indent");
        unsafe { jas_engine_free(e) };
    }

    /// A derived predicate owns no attribute, so a write to one must not reach
    /// the document. Asserted BY NAME on the refusal, because "the document
    /// did not change" alone would also pass if the whole path were dead.
    #[test]
    fn a_paragraph_derived_predicate_writes_nothing_to_the_document() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = untransformed_engine();
        let before = doc_json(e);
        let mut model = engine_of(e).with_model(|m| m.clone());
        let store = engine_of(e).store.borrow();
        // The host refuses it for a caller that reaches the store key directly,
        // which is the layer this guard is load-bearing at.
        assert!(!crate::interpreter::paragraph_host::apply_field(
                    &mut model, &store, "text_selected"));
        assert!(!crate::interpreter::paragraph_host::apply_field(
                    &mut model, &store, "area_text_selected"));
        // Anti-vacuity: a real key through the same door DOES write.
        assert!(crate::interpreter::paragraph_host::apply_field(
                    &mut model, &store, "align_center"));
        drop(store);
        assert_eq!(doc_json(e), before, "the engine's own document was disturbed");
        unsafe { jas_engine_free(e) };
    }

    // -----------------------------------------------------------------------
    // W2b-8 -- the Opacity panel. ⛔ NOT an extraction node: the document write
    // already lives in `properties_host` (`prop_opacity` / `prop_blend`), and
    // this panel's two inputs now run that same law through a mapping.
    // -----------------------------------------------------------------------

    const OPACITY: &str = "opacity_panel_content";

    /// `(opacity, blend mode)` of every selected element, read off the
    /// ELEMENTS rather than through the host, so the oracle cannot agree with
    /// the thing it is checking.
    fn selected_opacities(e: *mut JasEngine) -> Vec<(f64, String)> {
        engine_of(e).with_model(|m| {
            let doc = m.document();
            doc.selection.iter()
                .filter_map(|es| doc.get_element(&es.path))
                .map(|el| (el.opacity(),
                           serde_json::to_value(el.mode()).ok()
                               .and_then(|v| v.as_str().map(str::to_string))
                               .unwrap_or_default()))
                .collect()
        })
    }

    /// **W2b-8's oracle.** An opacity commit on the Opacity panel reaches the
    /// selection — through the law the Properties panel already owns.
    ///
    /// ⭐ **The second assert is the one that would not pass by accident: the
    /// PERCENT → FRACTION conversion.** `panel.opacity` is 0–100 and the model
    /// is 0.0–1.0, and the mapping passes the percent through unconverted
    /// because `properties_host` divides. An arm that only checked "the
    /// opacity changed" would pass with 50.0 written into a 0–1 field.
    #[test]
    fn opacity_panel_commit_writes_the_fraction_to_the_selection() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = untransformed_engine();
        let before = selected_opacities(e);
        assert!(!before.is_empty(),
                "the calibrated fixture has no selection, so this oracle would \
                 be vacuous");
        // ⚠️ NOT 50: the fixture carries `<g opacity="0.5">`, and this guard
        // caught the vacuous arm before it could pass. 40 % is unused by it.
        assert!(before.iter().all(|(o, _)| (*o - 0.4).abs() > 1e-9),
                "the commit could not be seen: something is already at 0.4");
        let doc_before = doc_json(e);

        // A number_input is an INPUT_KIND, so its event is `commit` and its
        // value is a STRING (a bare number answers `BadValue`).
        let (reply, err) = behave(
            e, OPACITY, r#"{"widget":"op_opacity","event":"commit","value":"40"}"#);
        assert_eq!(err, "", "{reply}");

        for (i, (o, _)) in selected_opacities(e).iter().enumerate() {
            assert!((o - 0.4).abs() < 1e-9,
                    "element {i} reads {o}: the percent reached the model \
                     unconverted, or the write did not land");
        }
        undo(e);
        assert_eq!(doc_json(e), doc_before, "ONE undo must restore the document");
        unsafe { jas_engine_free(e) };
    }

    /// The Opacity panel's other four declared keys reach no element
    /// attribute — two are panel-local UI and two are document preferences
    /// with nowhere yet to live. A write to one must not touch the document.
    #[test]
    fn an_opacity_panel_local_key_writes_nothing_to_the_document() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = untransformed_engine();
        let before = doc_json(e);
        for w in ["op_disclosure"] {
            let (_reply, _err) = behave(
                e, OPACITY,
                &format!(r#"{{"widget":"{w}","event":"click"}}"#));
        }
        assert_eq!(doc_json(e), before,
                   "a panel-local Opacity widget reached the document");
        unsafe { jas_engine_free(e) };
    }

    /// **The five bare predicates are IN the engine's scope**, which is what
    /// the two mask checkboxes' bindings read. Before W2b-8 the scope carried
    /// none of them, so `selection_mask_clip` evaluated to nothing and a press
    /// negated a value that was not there.
    #[test]
    fn the_engine_scope_carries_every_bare_selection_predicate() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = untransformed_engine();
        let eng = engine_of(e);
        let scope = crate::panel_scope::engine_scope(
            &eng.panel.borrow(), &eng.store.borrow(), &eng.model.borrow(), OPACITY);
        let root = scope.as_object().expect("scope is an object");
        for name in crate::interpreter::mask_facts::BARE_FACTS {
            let v = root.get(name)
                .unwrap_or_else(|| panic!("the engine scope omits `{name}`, so a \
                                           binding on it reads nothing"));
            assert!(v.is_boolean(), "`{name}` is {v}, not a bool");
        }
        // Anti-vacuity: the scope is not simply full of every name we ask for.
        assert!(root.get("selection_has_no_such_fact").is_none());
        unsafe { jas_engine_free(e) };
    }

    /// **W2b-5's oracle.** X = 40 moves the selection's box left edge to 40,
    /// writes what the shared host writes, shows 40, and is ONE undo step.
    #[test]
    fn properties_x_commit_moves_the_selection_as_the_shared_host_does() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = untransformed_engine();
        let pre = engine_of(e).with_model(|m| m.clone());
        let constrain = engine_of(e).store.borrow()
            .get_panel(PROPERTIES, "prop_constrain").as_bool().unwrap_or(false);
        let before = doc_json(e);
        assert_ne!(selection_box(e).0, 40.0, "the commit could not be seen");

        let (reply, err) = behave(e, PROPERTIES, r#"{"widget":"prop_x","event":"commit","value":"40"}"#);
        let r = reply_json(&reply, &err);
        assert_eq!(r["doc_changed"], true, "{reply} {err}");
        assert_eq!(err, "");
        let mut copy = pre.clone();
        crate::interpreter::properties_host::apply_field(&mut copy, "prop_x", &serde_json::json!(40.0), constrain);
        assert_eq!(doc_json(e), crate::geometry::test_json::document_to_test_json(copy.document()));
        assert_eq!(selection_box(e).0, 40.0);
        assert_eq!(plan_number(e, "prop_x"), 40.0);
        let plan: serde_json::Value = serde_json::from_str(&plan_of(e, PROPERTIES, 228, 0)).unwrap();
        assert_eq!(delta_mismatches(&r, &plan, PROPERTIES), 0, "the reply's rows disagree: {reply}");

        undo(e);
        assert_eq!(doc_json(e), before, "ONE undo must restore the pre-commit document");
        assert!(!engine_of(e).with_model(|m| m.can_undo()), "the commit took more than one step");
        unsafe { jas_engine_free(e) };
    }

    /// **The constrain lock reaches the W edit.** Pressed through the door, the
    /// lock makes a width commit scale the height by the same ratio; unpressed,
    /// the height holds. The expected heights come from the box the engine
    /// shows before the commit.
    #[test]
    fn properties_width_commit_honours_the_constrain_lock() {
        let _counters = crate::ffi_instr::test_lock::lock();
        for locked in [false, true] {
            let e = untransformed_engine();
            if locked {
                let (reply, err) = behave(e, PROPERTIES, r#"{"widget":"prop_constrain","event":"click"}"#);
                assert_eq!(err, "", "the lock press: {reply}");
                assert_eq!(engine_of(e).store.borrow().get_panel(PROPERTIES, "prop_constrain"),
                           &serde_json::json!(true));
            }
            let (_, _, w0, h0) = selection_box(e);
            let ev = serde_json::json!({"widget": "prop_w", "event": "commit",
                                        "value": format!("{}", w0 * 2.0)});
            let (reply, err) = behave(e, PROPERTIES, &ev.to_string());
            assert_eq!(reply_json(&reply, &err)["doc_changed"], true, "{reply} {err}");
            let (_, _, w1, h1) = selection_box(e);
            assert!((w1 - w0 * 2.0).abs() < 1e-9, "locked={locked}: w {w0} -> {w1}");
            let want_h = if locked { h0 * 2.0 } else { h0 };
            assert!((h1 - want_h).abs() < 1e-9, "locked={locked}: h {h0} -> {h1}, wanted {want_h}");
            unsafe { jas_engine_free(e) };
        }
    }

    /// Opacity (a `number_input`) and blend (a `select`) are set on EVERY
    /// selected element.
    #[test]
    fn properties_opacity_and_blend_commits_write_every_selected_element() {
        use crate::geometry::element::BlendMode;
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = untransformed_engine();
        let modes = |e| engine_of(e).with_model(|m| {
            let doc = m.document();
            doc.selection.iter()
                .map(|es| { let el = doc.get_element(&es.path).unwrap(); (el.opacity(), el.mode()) })
                .collect::<Vec<_>>()
        });
        let start = modes(e);
        assert!(start.len() >= 2, "{start:?}");
        assert!(start.iter().all(|(o, m)| *o != 0.4 && *m != BlendMode::Multiply), "{start:?}");

        for (widget, text) in [("prop_opacity_input", "40"), ("prop_blend_select", "multiply")] {
            let ev = serde_json::json!({"widget": widget, "event": "commit", "value": text});
            let (reply, err) = behave(e, PROPERTIES, &ev.to_string());
            assert_eq!(reply_json(&reply, &err)["doc_changed"], true, "{widget}: {reply} {err}");
        }
        let end = modes(e);
        assert!(end.iter().all(|(o, m)| (*o - 0.4).abs() < 1e-12 && *m == BlendMode::Multiply),
                "{end:?}");
        assert_eq!(plan_number(e, "prop_opacity_input"), 40.0);
        unsafe { jas_engine_free(e) };
    }

    /// **D5.** A disabled widget is refused by name before anything runs, and
    /// the plan the shell draws from shows the same state. Align needs two.
    #[test]
    fn panel_behavior_refuses_a_disabled_widget_and_the_plan_agrees() {
        use crate::panel_behavior::test_fixture::misaligned;
        let _counters = crate::ffi_instr::test_lock::lock();
        for (selected, disabled) in [(&[][..], true), (&[0][..], true), (&[0, 1][..], false)] {
            let e = engine_with(misaligned(selected));
            assert_eq!(leaf(e, ALIGN, "align_left_button")["values"]["bind.disabled"],
                       if disabled { "true" } else { "false" },
                       "the plan with {} selected", selected.len());
            let before = doc_json(e);
            let (reply, err) = behave(e, ALIGN, LEFT);
            if disabled {
                assert_eq!(reply, "", "{} selected", selected.len());
                assert_eq!(err, refusal("Disabled", "align_left_button"));
                assert_eq!(doc_json(e), before);
            } else {
                assert!(reply.contains(r#""doc_changed":true"#), "{reply} {err}");
            }
            unsafe { jas_engine_free(e) };
        }
    }

    /// **Properties' fields are disabled with nothing selected**, in the plan
    /// and at the door. The widgets are read from the workspace, not listed
    /// here: every Properties widget that declares a `disabled` expression
    /// anywhere. `properties.yaml` once carried all nine at the widget's top
    /// level, where no reader looks, so this arm walked nine widgets that
    /// every port drew enabled and that the door ran.
    #[test]
    fn properties_fields_are_refused_as_disabled_with_nothing_selected() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let ws = Workspace::load().unwrap();
        let spec = ws.panel(PROPERTIES).unwrap();
        fn declared(n: &serde_json::Value, out: &mut Vec<(String, String)>) {
            if let (Some(id), Some(kind)) = (n.get("id").and_then(|v| v.as_str()),
                                             n.get("type").and_then(|v| v.as_str())) {
                let top = n.get("disabled").is_some();
                let bound = n.get("bind").and_then(|b| b.get("disabled")).is_some();
                if top || bound {
                    out.push((id.to_string(), kind.to_string()));
                }
            }
            match n {
                serde_json::Value::Object(m) => m.values().for_each(|v| declared(v, out)),
                serde_json::Value::Array(a) => a.iter().for_each(|v| declared(v, out)),
                _ => {}
            }
        }
        let mut widgets = vec![];
        declared(spec, &mut widgets);
        assert!(widgets.len() >= 9, "the walk found {widgets:?}");

        let e = engine_with(crate::panel_behavior::test_fixture::model_with(
            vec![crate::panel_behavior::test_fixture::rect(10.0, 20.0, 30.0, 40.0)], &[]));
        for (id, kind) in &widgets {
            assert_eq!(leaf(e, PROPERTIES, id)["values"]["bind.disabled"], "true",
                       "{id}: the plan draws it enabled");
            let event = match kind.as_str() {
                "icon_button" => format!(r#"{{"widget":"{id}","event":"click"}}"#),
                _ => format!(r#"{{"widget":"{id}","event":"commit","value":"40"}}"#),
            };
            let before = doc_json(e);
            assert_eq!(behave(e, PROPERTIES, &event), (String::new(), refusal("Disabled", id)),
                       "{id} ({kind})");
            assert_eq!(doc_json(e), before, "{id}: a refused act moved the document");
        }
        unsafe { jas_engine_free(e) };
    }

    /// **Q5, and where its halves live now.** Q5 says a behavior that reaches an
    /// effect the engine cannot run is refused by name, and NO effect of its
    /// batch ran. This arm carried both halves on Stroke's `stk_swap_arrowheads`
    /// until the engine hosted `swap_panel_state`; it now pins that widget
    /// RUNNING through the door. A census of every widget event in every panel
    /// at this node found no other real batch with a visible write before a
    /// refused effect, so the halves moved:
    /// * "nothing of the batch ran": the planted batches in `panel_behavior`
    ///   (`a_refused_batch_that_edits_first_leaves_the_model_untouched`,
    ///   `..._strokes_first_...`), which put a document edit and a stroke write
    ///   BEFORE the refusal and so are stricter than any real widget;
    /// * "refused by name at the door": the `Dialog:` and `Logged:` arms
    ///   (`bp_new_brush_btn`, `bp_libraries_menu_btn`).
    /// The census's remaining real `UnknownEffect` is the Layers filter
    /// dropdown's `list_toggle`, which has no batch in front of it.
    #[test]
    fn the_swap_arrowheads_widget_runs_through_the_door() {
        use crate::panel_behavior::test_fixture::misaligned;
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_with(misaligned(&[0, 1]));
        let _ = plan_of(e, "stroke_panel_content", 228, 0);
        {
            let eng = engine_of(e);
            let mut st = eng.store.borrow_mut();
            st.set("stroke_start_arrowhead", serde_json::json!("simple_arrow"));
            st.set("stroke_end_arrowhead", serde_json::json!("none"));
            st.set_panel("stroke_panel_content", "start_arrowhead", serde_json::json!("simple_arrow"));
            st.set_panel("stroke_panel_content", "end_arrowhead", serde_json::json!("none"));
        }
        let (_reply, err) = behave(e, "stroke_panel_content",
                                   r#"{"widget":"stk_swap_arrowheads","event":"click"}"#);
        assert_eq!(err, "", "the door refused the swap");
        // NOT pinned, deliberately: the batch's `swap:` of the arrowhead
        // globals is a render-key write, which the engine applies to the
        // selection, and on these UNSTROKED rects that creates a 1pt stroke.
        // The refusal hid it (nothing of the batch ever ran here). Whether an
        // arrowhead swap should stroke an unstroked element is the stroke
        // apply law's question, not this effect's.
        let eng = engine_of(e);
        let st = eng.store.borrow();
        assert_eq!(st.get("stroke_start_arrowhead"), &serde_json::json!("none"), "the globals swapped");
        assert_eq!(st.get("stroke_end_arrowhead"), &serde_json::json!("simple_arrow"));
        assert_eq!(st.get_panel("stroke_panel_content", "start_arrowhead"), &serde_json::json!("none"),
                   "the panel's own values swapped");
        assert_eq!(st.get_panel("stroke_panel_content", "end_arrowhead"), &serde_json::json!("simple_arrow"));
        drop(st);
        drop(eng);
        unsafe { jas_engine_free(e) };
    }

    /// **The Layers type filter through the door** (WIDGET_EVENTS.md, "Picking
    /// a dropdown item"). A pick names the item by its `value`, and the batch
    /// reads `item.value`. Before the item kinds joined the contract the door
    /// bound no `item`, so the filter's `list_toggle`, once hosted, wrote
    /// `[null]` (measured) where it had refused by name.
    #[test]
    fn the_layers_type_filter_picks_through_the_door() {
        use crate::panel_behavior::test_fixture::misaligned;
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_with(misaligned(&[0]));
        let _ = plan_of(e, "layers_panel_content", 228, 0);
        let filter = |e: *mut JasEngine| engine_of(e).store.borrow()
            .get_panel("layers_panel_content", "type_filter").clone();
        let pick = |e: *mut JasEngine, event: &str, value: &str| behave(e, "layers_panel_content",
            &format!(r#"{{"widget":"lp_filter_button","event":"{event}","value":"{value}"}}"#));

        let (_r, err) = pick(e, "toggle", "path");
        assert_eq!(err, "", "a pick of a declared type runs");
        assert_eq!(filter(e), serde_json::json!(["path"]), "the TYPE, never null");
        let (_r, err) = pick(e, "toggle", "text");
        assert_eq!(err, "");
        assert_eq!(filter(e), serde_json::json!(["path", "text"]));
        let (_r, err) = pick(e, "toggle", "path");
        assert_eq!(err, "");
        assert_eq!(filter(e), serde_json::json!(["text"]), "a second pick toggles it out");
        let (_r, err) = pick(e, "alt_toggle", "circle");
        assert_eq!(err, "");
        assert_eq!(filter(e), serde_json::json!(["circle"]), "an Alt pick solos");
        let (_r, err) = pick(e, "toggle", "__all__");
        assert_eq!(err, "");
        assert_eq!(filter(e), serde_json::json!([]), "All runs its own action");

        let (_r, err) = behave(e, "layers_panel_content", r#"{"widget":"lp_filter_button","event":"toggle"}"#);
        assert_eq!(err, refusal("MissingValue", "lp_filter_button"));
        let (_r, err) = pick(e, "toggle", "nope");
        assert_eq!(err, refusal("BadValue", "lp_filter_button"));
        let (_r, err) = pick(e, "toggle", "separator");
        assert_eq!(err, refusal("BadValue", "lp_filter_button"), "a separator is not an item");
        let (_r, err) = pick(e, "click", "path");
        assert_eq!(err, refusal("WrongEvent", "lp_filter_button"));
        assert_eq!(filter(e), serde_json::json!([]), "no refusal wrote anything");
        unsafe { jas_engine_free(e) };
    }

    /// **D6/D7.** A log-only action is a stub for work a platform supplies, and
    /// it is refused as one. (Its example was `sym_new` until W2b-17 hosted the
    /// Symbols verbs; `open_brush_libraries_menu` is still a stub.)
    #[test]
    fn panel_behavior_refuses_a_log_only_action_by_name() {
        use crate::panel_behavior::test_fixture::misaligned;
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_with(misaligned(&[0]));
        let (reply, err) = behave(e, "brushes_panel_content",
                                  r#"{"widget":"bp_libraries_menu_btn","event":"click"}"#);
        assert_eq!(reply, "");
        assert_eq!(err, refusal("PlatformEffect", "Logged:open_brush_libraries_menu"));
        unsafe { jas_engine_free(e) };
    }

    /// **The dialog door (it replaces A12, W2b-12).** A behavior that opens a
    /// dialog opens it in the engine's store, and the reply NAMES it. Before
    /// A12, New Brush with a selection did open it there, and replied as a
    /// plain success, so no shell could know a dialog was waiting; A12 then
    /// refused it by name. The reply's `dialog` is what makes the open
    /// observable, so it is pinned here beside the store.
    #[test]
    fn panel_behavior_opens_a_dialog_and_names_it() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = stroked_engine();
        let _ = plan_of(e, "brushes_panel_content", 228, 0);
        let before = doc_json(e);
        let (reply, err) = behave(e, "brushes_panel_content",
                                  r#"{"widget":"bp_new_brush_btn","event":"click"}"#);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("{reply} {err}"));
        assert_eq!(v["dialog"], "brush_options", "{reply}");
        assert_eq!(engine_of(e).store.borrow().dialog_id(), Some("brush_options"));
        assert_eq!(doc_json(e), before, "opening a dialog does not edit the document");
        unsafe { jas_engine_free(e) };
    }

    /// **D7.** Every other refusal, each with its exact string.
    #[test]
    fn panel_behavior_refuses_by_name_where_there_is_nothing_to_run() {
        use crate::panel_behavior::test_fixture::misaligned;
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_with(misaligned(&[0, 1]));
        let cases: [(&str, &str, String); 6] = [
            // A click on a Color slider declares nothing to run. Until flask
            // §228 every Color event read `PanelNotHosted`; Color clicks now run
            // their behaviours, so a click with none is `EmptyBehavior`, refused
            // by name like any panel's. A Color VALUE through the generic
            // branches is still `PanelNotHosted`
            // (`the_generic_value_branches_refuse_color_by_name`).
            ("color_panel_content", r#"{"widget":"cp_h","event":"click"}"#,
             refusal("EmptyBehavior", "cp_h")),
            ("zz_no_such_panel", LEFT, refusal("MissingTarget", "zz_no_such_panel")),
            (ALIGN, r#"{"widget":"zz_no_such_widget","event":"click"}"#,
             refusal("MissingTarget", "zz_no_such_widget")),
            // A container with an id and no behavior at all.
            (ALIGN, r#"{"widget":"align_content","event":"click"}"#,
             refusal("EmptyBehavior", "align_content")),
            // A widget stamped out by a `foreach`: an id names a template, not
            // one row, so it is not addressable by id.
            ("symbols_panel_content", r#"{"widget":"sym_name","event":"click"}"#,
             refusal("NotAddressable", "sym_name")),
            (ALIGN, r#"{"event":"click"}"#, refusal("MissingTarget", "")),
        ];
        for (panel, event, want) in &cases {
            let before = doc_json(e);
            let (reply, err) = behave(e, panel, event);
            assert_eq!(reply, "", "{panel} {event}");
            assert_eq!(&err, want, "{panel} {event}");
            assert_eq!(doc_json(e), before);
        }
        let (_, err) = behave(e, ALIGN, "{not json");
        assert_eq!(err, refusal("BadJson", ""));
        let bad = [0xff_u8, 0xfe];
        let reply = take(unsafe {
            jas_panel_behavior(e, ALIGN.as_ptr(), ALIGN.len(), bad.as_ptr(), bad.len())
        });
        assert_eq!(reply, "");
        assert_eq!(take(unsafe { jas_last_error_json(e) }), refusal("BadUtf8", ""));
        let reply = take(unsafe {
            jas_panel_behavior(std::ptr::null_mut(), ALIGN.as_ptr(), ALIGN.len(),
                               LEFT.as_ptr(), LEFT.len())
        });
        assert_eq!(reply, "", "a null handle");
        // The control: the same engine runs a real click.
        let (reply, err) = behave(e, ALIGN, LEFT);
        assert!(reply.contains(r#""doc_changed":true"#), "{reply} {err}");
        unsafe { jas_engine_free(e) };
    }

    // -----------------------------------------------------------------------
    // D4: one scope per panel, two sources, and the colour panel unchanged.
    // -----------------------------------------------------------------------

    fn bind_rows(e: *mut JasEngine, panel: &str) -> String {
        take(unsafe { jas_bind_values(e, panel.as_ptr(), panel.len()) })
    }

    fn colour_tick(e: *mut JasEngine, widget: &str, value: serde_json::Value) {
        let id = crate::panel_scope::COLOUR_PANEL;
        let ev = serde_json::json!({"widget": widget, "value": value}).to_string();
        let _ = take(unsafe {
            jas_panel_event(e, id.as_ptr(), id.len(), ev.as_ptr(), ev.len())
        });
    }

    /// flask §228 (2026-10-12): the Windows shell commits a typed value
    /// through the BEHAVIOUR door (`jas_panel_behavior`, `{"widget","event":
    /// "commit","value":<text>}`), and the core refused every Color widget there
    /// (`PanelNotHosted`), so Color's hex did nothing on Windows. A value commit
    /// on a Color input now moves the panel to the edited colour, as the S-C.2
    /// door's tick does: the oracle is that door's COLOUR, on a fresh engine.
    /// It is not the whole row set: a commit also runs `set_active_color`,
    /// which a tick does not (`a_hex_commit_lands_as_set_active_color_does`).
    #[test]
    fn a_colour_commit_through_the_behaviour_door_lands_as_the_s_c2_tick_does() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let id = crate::panel_scope::COLOUR_PANEL;
        let a = jas_engine_new();
        let _ = bind_rows(a, id);
        colour_tick(a, "cp_hex", serde_json::json!("12ab34"));
        let want = bind_rows(a, id);
        unsafe { jas_engine_free(a) };

        let b = jas_engine_new();
        let before = bind_rows(b, id);
        assert_ne!(before, want, "fixture: the edit must move the colour rows");
        let (reply, err) = behave(b, id, r#"{"widget":"cp_hex","event":"commit","value":"12ab34"}"#);
        assert!(err.is_empty(), "the commit ran: {err}");
        assert!(reply.contains(r#""changed":["#) && !reply.contains(r#""changed":[]"#), "{reply}");
        let colour_rows = |rows: &str| -> Vec<serde_json::Value> {
            serde_json::from_str::<Vec<serde_json::Value>>(rows).unwrap().into_iter()
                .filter(|r| !r["id"].as_str().unwrap_or("").starts_with("cp_recent_")).collect()
        };
        assert_eq!(colour_rows(&bind_rows(b, id)), colour_rows(&want),
                   "the colour rows differ from the S-C.2 door's");
        // Committing the same value again moves nothing, and says so.
        let (_, err2) = behave(b, id, r#"{"widget":"cp_hex","event":"commit","value":"12ab34"}"#);
        assert!(err2.contains("Unchanged"), "{err2}");
        // A commit with no value is refused by name and runs nothing.
        let (r3, err3) = behave(b, id, r#"{"widget":"cp_hex","event":"commit"}"#);
        assert!(r3.is_empty() && err3.contains("MissingValue"), "{err3}");
        unsafe { jas_engine_free(b) };
    }

    /// The second half of flask §228: a CLICK on a Color widget runs its
    /// declared action, in the colour scope, exactly as dispatching that action
    /// with the same params does. The oracle is `jas_dispatch_action` on a fresh
    /// engine. Two shapes: an action with no params (swap; reset is left out
    /// because on the default colours it moves nothing) and one with a
    /// literal param (the black swatch's `set_active_color`).
    ///
    /// The two routes now agree EXACTLY. Until 2026-10-12 this test allowed one
    /// extra row on the click (`cp_recent_0`), because `set_active_color`
    /// pushed onto the ACTIVE panel's `panel.recent_colors` and a menu dispatch
    /// has no active panel. The list is per-document now
    /// (`active_document.recent_colors`), so the dispatch keeps it too, and
    /// the black swatch's case checks that it does.
    #[test]
    fn a_colour_click_runs_its_action_as_dispatching_it_does() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let id = crate::panel_scope::COLOUR_PANEL;
        for (widget, action, recent) in [
            ("cp_swap_btn", r#"{"action":"swap_fill_stroke"}"#, None),
            ("cp_black_swatch", r##"{"action":"set_active_color","params":{"color":"#000000"}}"##,
             Some("#000000")),
        ] {
            let a = jas_engine_new();
            let before = bind_rows(a, id);
            let (_, aerr) = dispatch(a, action);
            assert!(aerr.is_empty() || aerr.contains("Unchanged"), "oracle ran: {aerr}");
            let want = bind_rows(a, id);
            assert_ne!(want, before, "fixture: {action} must move the colour rows");
            if let Some(c) = recent {
                let w: Vec<serde_json::Value> = serde_json::from_str(&want).unwrap();
                let r = w.iter().find(|r| r["id"] == "cp_recent_0" && r["key"] == "bind.color")
                    .expect("a cp_recent_0 colour row");
                assert_eq!(r["value"], c, "{action}: the dispatch route dropped the recent colour");
            }
            unsafe { jas_engine_free(a) };

            let b = jas_engine_new();
            let _ = bind_rows(b, id);
            let ev = format!(r#"{{"widget":"{widget}","event":"click"}}"#);
            let (reply, err) = behave(b, id, &ev);
            assert!(err.is_empty(), "{widget} ran: {err}");
            assert!(!reply.is_empty(), "{widget}: {reply}");
            let got = bind_rows(b, id);
            if got != want {
                let (g, w): (Vec<serde_json::Value>, Vec<serde_json::Value>) =
                    (serde_json::from_str(&got).unwrap(), serde_json::from_str(&want).unwrap());
                let diff: Vec<String> = g.iter().zip(w.iter()).filter(|(a, b)| a != b)
                    .map(|(a, b)| format!("{}.{}: click {} vs dispatch {}", a["id"], a["key"], a["value"], b["value"]))
                    .collect();
                panic!("{widget} != {action}: {} row(s) differ (of {} / {}): {diff:?}", diff.len(), g.len(), w.len());
            }
            unsafe { jas_engine_free(b) };
        }
    }

    /// flask §235 (2026-10-12, live on `b7c58b0d`): after None, the store held
    /// `fill_color: null` while the panel kept the OLD colour and the hex stayed
    /// enabled (0 rows changed), because the slice held an RGB tuple and could
    /// not say none. `color.yaml` says what none looks like: every channel is
    /// `hsb_h(<active>)` etc., and all three evaluators read a null colour as
    /// `#000000`, so the hex reads `000000`; the sliders and the hex are
    /// disabled. Driven for fill AND stroke, then out again by a swatch.
    #[test]
    fn none_makes_the_active_colour_none_in_the_panel_and_disables_the_hex() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let id = crate::panel_scope::COLOUR_PANEL;
        for fill_on_top in [true, false] {
            let key = if fill_on_top { "fill_color" } else { "stroke_color" };
            let other = if fill_on_top { "stroke_color" } else { "fill_color" };
            let e = jas_engine_new();
            let engine = engine_of(e);
            if !fill_on_top {
                let (_, err) = dispatch(e, r#"{"action":"toggle_fill_on_top"}"#);
                assert!(err.is_empty(), "toggle_fill_on_top ran: {err}");
            }
            assert_eq!(engine.panel.borrow().effective(&engine.model.borrow()).state_keys()["fill_on_top"], fill_on_top);
            let hex = || leaf(e, id, "cp_hex")["values"].clone();
            // A colour that is not black (the default stroke IS black, and none
            // shows as black, so a black start would make the arm vacuous).
            let (_, err) = behave(e, id, r#"{"widget":"cp_hex","event":"commit","value":"12ab34"}"#);
            assert!(err.is_empty(), "{key}: the seed commit ran: {err}");
            // The control: a colour, so the hex is enabled and shows it.
            assert_eq!(hex()["bind.disabled"], "false", "{key}: the control");
            assert_ne!(hex()["bind.value"], "000000", "{key}: the fixture must not start at black");
            let kept = engine.panel.borrow().effective(&engine.model.borrow()).state_keys()[other].clone();

            let (reply, err) = dispatch(e, r#"{"action":"set_active_color_none"}"#);
            assert!(err.is_empty(), "{key}: None ran: {err}");
            assert!(!reply.contains(r#""changed":[]"#), "{key}: None changed no row: {reply}");
            let keys = engine.panel.borrow().effective(&engine.model.borrow()).state_keys();
            assert_eq!(keys[key], serde_json::Value::Null, "{key}: the slice is not none");
            assert_eq!(keys[other], kept, "{key}: None moved the other colour");
            assert_eq!(engine.store.borrow().get(key), &serde_json::Value::Null, "{key}: store");
            assert_eq!(hex()["bind.disabled"], "true", "{key}: the hex is still enabled");
            assert_eq!(hex()["bind.value"], "000000", "{key}: color.yaml's hex(null)");

            // A commit on the disabled hex is refused by name and moves nothing
            // (#375's colour route skipped the check the generic route makes).
            let (r, err) = behave(e, id, r#"{"widget":"cp_hex","event":"commit","value":"12ab34"}"#);
            assert_eq!((r.as_str(), err), ("", refusal("Disabled", "cp_hex")), "{key}");
            assert_eq!(engine.panel.borrow().effective(&engine.model.borrow()).state_keys()[key], serde_json::Value::Null, "{key}");

            // A swatch un-nones it (`color.yaml`: "Clicking any swatch …
            // implicitly un-nones the attribute").
            let (_, err) = behave(e, id, r#"{"widget":"cp_white_swatch","event":"click"}"#);
            assert!(err.is_empty(), "{key}: the white swatch ran: {err}");
            assert_eq!(engine.panel.borrow().effective(&engine.model.borrow()).state_keys()[key], "#ffffff", "{key}");
            assert_eq!(hex()["bind.disabled"], "false", "{key}");
            assert_eq!(hex()["bind.value"], "ffffff", "{key}");
            unsafe { jas_engine_free(e) };
        }
    }

    /// The reference's `subscribe_active_color` (`effects.py`): a write to
    /// `state.fill_color` / `state.stroke_color` sets the model's new-element
    /// default and recolours the selection (a null clears it), by KEY, not by
    /// `fill_on_top`. The engine had no counterpart, so on Windows every Color
    /// act moved the panel and never the document (measured 2026-10-12: a
    /// selected rect, the black swatch, a hex commit and None each left the
    /// document byte-identical). Driven per route (a swatch click, a hex
    /// commit, None, a menu action) and per side, then undone in one step.
    #[test]
    fn a_colour_act_paints_the_selection_as_the_reference_does() {
        use crate::document::test_fixture::{model_with, rect};
        use crate::geometry::element::{Color, Element, Stroke};
        let _counters = crate::ffi_instr::test_lock::lock();
        let id = crate::panel_scope::COLOUR_PANEL;
        // A black fill AND a black 2pt stroke, so None on either side has
        // something to clear and a recolour has a width to keep.
        let stroked = || match rect(10.0, 20.0, 30.0, 40.0) {
            Element::Rect(mut r) => { r.stroke = Some(Stroke::new(Color::BLACK, 2.0)); Element::Rect(r) }
            _ => unreachable!(),
        };
        let white = Some(Color::WHITE);
        let teal = Color::from_hex("12ab34");
        for fill_side in [true, false] {
            for (what, ev, want) in [
                ("swatch", Ok(r#"{"widget":"cp_white_swatch","event":"click"}"#), white),
                ("hex", Ok(r#"{"widget":"cp_hex","event":"commit","value":"12ab34"}"#), teal),
                ("none", Ok(r#"{"widget":"cp_none_swatch","event":"click"}"#), None),
                ("menu", Err(r##"{"action":"set_active_color","params":{"color":"#ffffff"}}"##), white),
            ] {
                let tag = format!("{} {what}", if fill_side { "fill" } else { "stroke" });
                let e = engine_with(model_with(vec![stroked()], &[0]));
                if !fill_side {
                    let (_, err) = dispatch(e, r#"{"action":"toggle_fill_on_top"}"#);
                    assert!(err.is_empty(), "{tag}: toggle_fill_on_top: {err}");
                }
                let el = |e| engine_of(e).model.borrow().document().layers[0].children().unwrap()[0].clone();
                let (fill0, stroke0) = (el(e).fill().cloned(), el(e).stroke().cloned());
                assert_eq!(fill0.map(|f| f.color), Some(Color::BLACK), "{tag}: fixture");
                assert_eq!(stroke0.map(|s| (s.color, s.width)), Some((Color::BLACK, 2.0)), "{tag}: fixture");
                let before = doc_json(e);

                let (_, err) = match ev {
                    Ok(ev) => behave(e, id, ev),
                    Err(action) => dispatch(e, action),
                };
                assert!(err.is_empty(), "{tag}: ran: {err}");
                let got = el(e);
                let (side, other) = if fill_side {
                    (got.fill().map(|f| f.color), got.stroke().map(|s| s.color))
                } else {
                    (got.stroke().map(|s| s.color), got.fill().map(|f| f.color))
                };
                assert_eq!(side, want, "{tag}: the selection was not painted");
                assert_eq!(other, Some(Color::BLACK), "{tag}: the other side moved");
                if !fill_side && want.is_some() {
                    assert_eq!(got.stroke().map(|s| s.width), Some(2.0), "{tag}: the width was not kept");
                }
                let model = engine_of(e).model.borrow();
                let default = if fill_side { model.default_fill.map(|f| f.color) }
                              else { model.default_stroke.map(|s| s.color) };
                assert_eq!(default, want, "{tag}: the new-element default");
                drop(model);
                // One undo step restores the document.
                undo(e);
                assert_eq!(doc_json(e), before, "{tag}: one undo did not restore it");
                unsafe { jas_engine_free(e) };
            }
        }
        // Nothing selected: the default moves and the document does not.
        let e = engine_with(model_with(vec![rect(10.0, 20.0, 30.0, 40.0)], &[]));
        let before = doc_json(e);
        let (_, err) = behave(e, id, r#"{"widget":"cp_white_swatch","event":"click"}"#);
        assert!(err.is_empty(), "{err}");
        assert_eq!(doc_json(e), before, "an empty selection painted something");
        assert_eq!(engine_of(e).model.borrow().default_fill.map(|f| f.color), white);
        unsafe { jas_engine_free(e) };
    }

    /// `set_active_color` is "the commit point for all color changes from the
    /// Color Panel: … hex field Enter/Tab" (`actions.yaml`), so a hex commit
    /// lands EXACTLY as dispatching that action with the committed colour:
    /// the panel's rows (the recent strip included), the document and the
    /// model's recent list. Until 2026-10-12 the commit edited the slice and
    /// never pushed the recent colour. A repeat commit is Unchanged and pushes
    /// nothing twice.
    #[test]
    fn a_hex_commit_lands_as_set_active_color_does() {
        use crate::document::test_fixture::{model_with, rect};
        let _counters = crate::ffi_instr::test_lock::lock();
        let id = crate::panel_scope::COLOUR_PANEL;
        let fresh = || engine_with(model_with(vec![rect(10.0, 20.0, 30.0, 40.0)], &[0]));
        let a = fresh();
        let _ = bind_rows(a, id);
        let (_, err) = dispatch(a, r##"{"action":"set_active_color","params":{"color":"#12ab34"}}"##);
        assert!(err.is_empty(), "the oracle ran: {err}");
        // The LAYERS: each fresh document draws its own artboard id.
        let layers = |e| serde_json::from_str::<serde_json::Value>(&doc_json(e)).unwrap()["layers"].clone();
        let (want_rows, want_doc) = (bind_rows(a, id), layers(a));
        let want_recent = engine_of(a).model.borrow().recent_colors.clone();
        assert_eq!(want_recent, vec!["#12ab34".to_string()], "fixture: the oracle pushes");
        unsafe { jas_engine_free(a) };

        let b = fresh();
        let _ = bind_rows(b, id);
        let (reply, err) = behave(b, id, r#"{"widget":"cp_hex","event":"commit","value":"12ab34"}"#);
        assert!(err.is_empty(), "the commit ran: {err}");
        assert!(reply.contains(r#""doc_changed":true"#), "{reply}");
        assert_eq!(bind_rows(b, id), want_rows, "the rows differ from set_active_color's");
        assert_eq!(layers(b), want_doc, "the document differs from set_active_color's");
        assert_eq!(engine_of(b).model.borrow().recent_colors, want_recent);
        let (_, err) = behave(b, id, r#"{"widget":"cp_hex","event":"commit","value":"12ab34"}"#);
        assert!(err.contains("Unchanged"), "{err}");
        assert_eq!(engine_of(b).model.borrow().recent_colors, want_recent, "a repeat pushed");
        unsafe { jas_engine_free(b) };
    }

    /// FORK B2: the colour bar's COMMIT carries a point normalized to [0,1]²
    /// (`"u,v"`), and lands EXACTLY as dispatching `set_active_color` with the
    /// colour `color_util::color_bar_hex(u, v)` names: the rows, the document
    /// and the recent list. A repeat is Unchanged. The bar's `change` (live)
    /// is refused BY NAME until the engine has a live colour path, so a shell
    /// that sends it is told, and nothing is committed by accident.
    #[test]
    fn a_colour_bar_commit_lands_as_set_active_color_does() {
        use crate::document::test_fixture::{model_with, rect};
        let _counters = crate::ffi_instr::test_lock::lock();
        let id = crate::panel_scope::COLOUR_PANEL;
        let hex = crate::interpreter::color_util::color_bar_hex(0.25, 0.5);
        assert_eq!(hex, "#66cc00", "fixture: the point's colour (color_bar.json's formula)");
        let fresh = || engine_with(model_with(vec![rect(10.0, 20.0, 30.0, 40.0)], &[0]));
        let a = fresh();
        let _ = bind_rows(a, id);
        let (_, err) = dispatch(a, &format!(r#"{{"action":"set_active_color","params":{{"color":"{hex}"}}}}"#));
        assert!(err.is_empty(), "the oracle ran: {err}");
        let layers = |e| serde_json::from_str::<serde_json::Value>(&doc_json(e)).unwrap()["layers"].clone();
        let (want_rows, want_doc) = (bind_rows(a, id), layers(a));
        let want_recent = engine_of(a).model.borrow().recent_colors.clone();
        assert_eq!(want_recent, vec![hex.clone()], "fixture: the oracle pushes");
        unsafe { jas_engine_free(a) };

        let b = fresh();
        let _ = bind_rows(b, id);
        let before = doc_json(b);
        let (reply, err) = behave(b, id, r#"{"widget":"cp_color_bar","event":"commit","value":"0.25,0.5"}"#);
        assert!(err.is_empty(), "the commit ran: {err}");
        assert!(reply.contains(r#""doc_changed":true"#), "{reply}");
        assert_eq!(bind_rows(b, id), want_rows, "the rows differ from set_active_color's");
        assert_eq!(layers(b), want_doc, "the document differs from set_active_color's");
        assert_eq!(engine_of(b).model.borrow().recent_colors, want_recent);
        let (_, err) = behave(b, id, r#"{"widget":"cp_color_bar","event":"commit","value":"0.25,0.5"}"#);
        assert!(err.contains("Unchanged"), "{err}");
        undo(b);
        assert_eq!(doc_json(b), before, "one Undo restores the document");

        unsafe { jas_engine_free(b) };

        // Nothing selected: the panel shows the committed colour from the
        // default the commit set, and the hex reads it.
        let c = engine_with(model_with(vec![rect(10.0, 20.0, 30.0, 40.0)], &[]));
        let (_, err) = behave(c, id, r#"{"widget":"cp_color_bar","event":"commit","value":"0.25,0.5"}"#);
        assert!(err.is_empty(), "{err}");
        assert_eq!(leaf(c, id, "cp_hex")["values"]["bind.value"], "66cc00");
        assert_eq!(engine_of(c).model.borrow().recent_colors, vec![hex.clone()]);
        let b = c;

        // `change` is live (B2b): it moves the document, not the recent list.
        let held = doc_json(b);
        let (reply, err) = behave(b, id, r#"{"widget":"cp_color_bar","event":"change","value":"0.9,0.1"}"#);
        assert!(err.is_empty(), "{err}");
        assert!(reply.contains(r#""doc_changed":true"#) || doc_json(b) == held, "{reply}");
        // A text outside the point grammar.
        let (_, err) = behave(b, id, r#"{"widget":"cp_color_bar","event":"commit","value":"0.5"}"#);
        assert_eq!(err, refusal("BadValue", "cp_color_bar"));
        unsafe { jas_engine_free(b) };
    }

    /// FORK B2b: the colour bar's `change` is its LIVE drag. Each one paints
    /// the selection and the default with the point's colour, pushes NO recent
    /// colour and takes NO undo step; the release's `commit` pushes the colour
    /// once and makes the whole drag ONE undo step back to before it (the
    /// model's live-drag baseline, #392). Releasing on a colour already at the
    /// front of the recent list still commits: a pending drag is never
    /// `Unchanged`.
    #[test]
    fn a_colour_bar_drag_is_live_and_its_release_is_one_undo_step() {
        use crate::document::test_fixture::{model_with, rect};
        use crate::interpreter::color_util::color_bar_hex;
        let _counters = crate::ffi_instr::test_lock::lock();
        let id = crate::panel_scope::COLOUR_PANEL;
        let e = engine_with(model_with(vec![rect(10.0, 20.0, 30.0, 40.0)], &[0]));
        let fill_hex = |e| -> String {
            let d: serde_json::Value = serde_json::from_str(&doc_json(e)).unwrap();
            let c = &d["layers"][0]["children"][0]["fill"]["color"];
            crate::interpreter::color_util::rgb_to_hex(
                (c["r"].as_f64().unwrap() * 255.0).round() as u8,
                (c["g"].as_f64().unwrap() * 255.0).round() as u8,
                (c["b"].as_f64().unwrap() * 255.0).round() as u8)
        };
        let before = doc_json(e);
        let ev = |kind: &str, at: &str| format!(r#"{{"widget":"cp_color_bar","event":"{kind}","value":"{at}"}}"#);
        for at in ["0.1,0.2", "0.6,0.7"] {
            let (reply, err) = behave(e, id, &ev("change", at));
            assert!(err.is_empty(), "{at}: {err}");
            assert!(reply.contains(r#""doc_changed":true"#), "{at}: {reply}");
            let (u, v) = at.split_once(',').unwrap();
            assert_eq!(fill_hex(e), color_bar_hex(u.parse().unwrap(), v.parse().unwrap()), "{at}: painted live");
        }
        assert!(engine_of(e).model.borrow().recent_colors.is_empty(), "a live tick pushed a recent colour");
        assert!(!engine_of(e).with_model(|m| m.can_undo()), "a live tick took an undo step");
        let (_, err) = behave(e, id, &ev("commit", "0.6,0.7"));
        assert!(err.is_empty(), "the release committed: {err}");
        assert_eq!(engine_of(e).model.borrow().recent_colors, vec![color_bar_hex(0.6, 0.7)]);
        undo(e);
        assert_eq!(doc_json(e), before, "one Undo returns to before the drag");
        assert!(!engine_of(e).with_model(|m| m.can_undo()), "the drag was ONE step");

        // A release on the colour already at the front of the recent list
        // still commits the drag (it is never `Unchanged` while one is live).
        let (_, err) = behave(e, id, &ev("change", "0.6,0.7"));
        assert!(err.is_empty(), "{err}");
        let (_, err) = behave(e, id, &ev("commit", "0.6,0.7"));
        assert!(err.is_empty(), "a pending drag's release is not Unchanged: {err}");
        undo(e);
        assert_eq!(doc_json(e), before, "and it is one Undo step too");
        unsafe { jas_engine_free(e) };

        // The STROKE on top: a drag paints the stroke and leaves the fill.
        // (The rect needs a stroke: with none, the active attribute is none
        // and the bar is Disabled, as the spec says.)
        let stroked = match rect(10.0, 20.0, 30.0, 40.0) {
            crate::geometry::element::Element::Rect(mut r) => {
                r.stroke = Some(crate::geometry::element::Stroke::new(crate::geometry::element::Color::BLACK, 1.0));
                crate::geometry::element::Element::Rect(r)
            }
            _ => unreachable!(),
        };
        let k = engine_with(model_with(vec![stroked], &[0]));
        engine_of(k).panel.borrow_mut().fill_on_top = false;
        let side = |e, which: &str| -> serde_json::Value {
            let d: serde_json::Value = serde_json::from_str(&doc_json(e)).unwrap();
            d["layers"][0]["children"][0][which].clone()
        };
        let (fill0, before_k) = (side(k, "fill"), doc_json(k));
        let (_, err) = behave(k, id, &ev("change", "0.1,0.2"));
        assert!(err.is_empty(), "{err}");
        assert_eq!(side(k, "fill"), fill0, "a stroke-side drag moved the fill");
        assert_ne!(side(k, "stroke"), serde_json::Value::Null, "the stroke was painted");
        let (_, err) = behave(k, id, &ev("commit", "0.1,0.2"));
        assert!(err.is_empty(), "{err}");
        undo(k);
        assert_eq!(doc_json(k), before_k, "the stroke drag is one Undo step too");
        unsafe { jas_engine_free(k) };

        // Nothing selected: the default follows live, and nothing is pushed.
        let c = engine_with(model_with(vec![rect(10.0, 20.0, 30.0, 40.0)], &[]));
        let (_, err) = behave(c, id, &ev("change", "0.25,0.5"));
        assert!(err.is_empty(), "{err}");
        assert_eq!(engine_of(c).model.borrow().default_fill.map(|f| f.color.to_hex()),
                   Some(color_bar_hex(0.25, 0.5).trim_start_matches('#').to_string()));
        assert!(engine_of(c).model.borrow().recent_colors.is_empty());
        unsafe { jas_engine_free(c) };
    }

    /// flask §238 (2026-10-12, live on `82bfd729`): selecting a blue rect left
    /// the Color panel at its own colour, and after Undo the panel still showed
    /// the undone colour, so retyping it was `Unchanged`. The web derives the
    /// panel's active colour from the SELECTION (`live_fill_stroke_values`:
    /// a uniform colour, or none; a mixed or empty selection falls back to the
    /// document's default, then the panel's own). Driven on flask's sequence.
    #[test]
    fn the_colour_panel_follows_the_selection_and_undo() {
        use crate::document::test_fixture::{model_with, rect};
        use crate::geometry::element::{Color, Element, Fill};
        let _counters = crate::ffi_instr::test_lock::lock();
        let id = crate::panel_scope::COLOUR_PANEL;
        let filled = |hex: Option<&str>| match rect(10.0, 20.0, 30.0, 40.0) {
            Element::Rect(mut r) => { r.fill = hex.map(|h| Fill::new(Color::from_hex(h).unwrap())); Element::Rect(r) }
            _ => unreachable!(),
        };
        let hex = |e| leaf(e, id, "cp_hex")["values"].clone();

        // A blue rect selected: the panel reads blue.
        let e = engine_with(model_with(vec![filled(Some("0000ff"))], &[0]));
        assert_eq!(hex(e)["bind.value"], "0000ff", "selecting a blue rect must load blue");
        assert_eq!(engine_of(e).store.borrow().get("fill_color"), "#0000ff",
                   "the store copy (what an action's guard reads) must follow too");
        // Commit, Undo: the panel follows the document back to blue, and the
        // same colour can be committed again.
        let (_, err) = behave(e, id, r#"{"widget":"cp_hex","event":"commit","value":"12ab34"}"#);
        assert!(err.is_empty(), "{err}");
        undo(e);
        assert_eq!(hex(e)["bind.value"], "0000ff", "after Undo the panel must read the document again");
        let (reply, err) = behave(e, id, r#"{"widget":"cp_hex","event":"commit","value":"12ab34"}"#);
        assert!(err.is_empty(), "retyping the undone colour must apply: {err}");
        assert!(reply.contains(r#""doc_changed":true"#), "{reply}");
        unsafe { jas_engine_free(e) };

        // A rect with NO fill selected: the panel is none (hex disabled).
        let e = engine_with(model_with(vec![filled(None)], &[0]));
        assert_eq!(hex(e)["bind.disabled"], "true", "a selected unfilled shape reads none");
        unsafe { jas_engine_free(e) };

        // A document that carries its OWN new-element default shows it when
        // nothing is selected, ahead of the panel's own colour (the web's
        // tab-then-app order).
        let mut m = model_with(vec![filled(Some("0000ff"))], &[]);
        m.default_fill = Some(Fill::new(Color::from_hex("ff0000").unwrap()));
        let e = engine_with(m);
        assert_eq!(hex(e)["bind.value"], "ff0000", "the document's default comes before the panel's own");
        unsafe { jas_engine_free(e) };

        // The selection's colour must never LEAK into the panel's own colour:
        // run a behaviour (which adopts store writes) while blue is selected,
        // then deselect. The panel shows its own colour again, not blue.
        let e = engine_with(model_with(vec![filled(Some("0000ff"))], &[0]));
        let own = engine_of(e).panel.borrow().state_keys()["fill_color"].clone();
        assert_ne!(own, "#0000ff", "fixture: the panel's own colour is not blue");
        // Draw the panel first, as the app does before any click: that is what
        // puts the selection's blue in the store copy the adopt step reads.
        assert_eq!(hex(e)["bind.value"], "0000ff", "fixture: the panel shows blue");
        // The reply class is not the point (a no-panel dispatch with no
        // registered panel replies Unchanged even when the mode moves); the
        // behaviour RAN, so its adopt step ran, and the mode is the receipt.
        let _ = dispatch(e, r#"{"action":"set_color_panel_mode","params":{"mode":"cmyk"}}"#);
        assert_eq!(engine_of(e).panel.borrow().mode, "cmyk", "fixture: the behaviour ran");
        engine_of(e).with_model_mut(|m| {
            let mut d = m.document().clone();
            d.selection.clear();
            m.set_document_for_test(d);
        });
        assert_eq!(format!("#{}", hex(e)["bind.value"].as_str().unwrap()), own.as_str().unwrap(),
                   "the selection's blue leaked into the panel's own colour");
        unsafe { jas_engine_free(e) };

        // A MIXED selection, and NO selection, fall back to the panel's own
        // colour (no document default has been set on a fresh model).
        for (what, sel) in [("mixed", &[0usize, 1][..]), ("empty", &[][..])] {
            let e = engine_with(model_with(vec![filled(Some("0000ff")), filled(Some("ff0000"))], sel));
            let own = engine_of(e).panel.borrow().state_keys()["fill_color"].clone();
            assert_eq!(format!("#{}", hex(e)["bind.value"].as_str().unwrap()), own.as_str().unwrap(), "{what}");
            unsafe { jas_engine_free(e) };
        }
    }

    /// A menu dispatch runs with no active panel, so the batch's change test
    /// (the store's evaluation context, which carries only the ACTIVE panel's
    /// scope) could not see a write to a panel's own scope: the Color mode
    /// moved and the reply said `Unchanged` when no panel had been drawn
    /// (found 2026-10-13 while arming #383). A repeat of the same switch IS
    /// unchanged, and must still say so.
    #[test]
    fn a_menu_dispatch_that_moves_only_a_panel_scope_is_a_change() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let switch = r#"{"action":"set_color_panel_mode","params":{"mode":"cmyk"}}"#;
        let (_, err) = dispatch(e, switch);
        assert_eq!(engine_of(e).panel.borrow().mode, "cmyk", "fixture: the mode moved");
        assert!(err.is_empty(), "a switch that moved the mode is not Unchanged: {err}");
        let (_, err) = dispatch(e, switch);
        assert!(err.contains("Unchanged"), "the repeat moved nothing: {err}");
        unsafe { jas_engine_free(e) };
    }

    /// `cp_hex`: "In Web Safe RGB mode, the entered value is snapped to the
    /// nearest web-safe color on commit." Both apps snap each channel to the
    /// nearest multiple of 51 (the web's `renderer`, Swift's
    /// `PanelWidgetEvents`); the engine committed the typed colour as is.
    /// The expected colours are the apps' rule applied to the inputs, two of
    /// them either side of a half step (`7f` -> `66`, `80` -> `99`). In any
    /// other mode the typed colour stands.
    #[test]
    fn a_hex_commit_in_web_safe_mode_snaps_to_the_web_safe_colour() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let id = crate::panel_scope::COLOUR_PANEL;
        for (typed, want) in [("123456", "#003366"), ("1a1a1a", "#333333"), ("ff7f80", "#ff6699")] {
            let e = jas_engine_new();
            let _ = dispatch(e, r#"{"action":"set_color_panel_mode","params":{"mode":"web_safe_rgb"}}"#);
            assert_eq!(engine_of(e).panel.borrow().mode, "web_safe_rgb", "fixture: the mode moved");
            let ev = format!(r#"{{"widget":"cp_hex","event":"commit","value":"{typed}"}}"#);
            let (_, err) = behave(e, id, &ev);
            assert!(err.is_empty(), "{typed}: {err}");
            assert_eq!(engine_of(e).store.borrow().get("fill_color"), want, "{typed}");
            unsafe { jas_engine_free(e) };
        }
        // The control: in RGB mode the typed colour stands.
        let e = jas_engine_new();
        let _ = dispatch(e, r#"{"action":"set_color_panel_mode","params":{"mode":"rgb"}}"#);
        let (_, err) = behave(e, id, r#"{"widget":"cp_hex","event":"commit","value":"123456"}"#);
        assert!(err.is_empty(), "{err}");
        assert_eq!(engine_of(e).store.borrow().get("fill_color"), "#123456");
        unsafe { jas_engine_free(e) };
    }

    /// A Color value still never reaches the store through the generic path:
    /// a commit goes to the slice (above), and the generic value branches
    /// refuse Color by name. Driven on the generic function directly, because
    /// the FFI door routes the commit before it gets there.
    #[test]
    fn the_generic_value_branches_refuse_color_by_name() {
        let ws = Workspace::load().unwrap();
        let id = crate::panel_scope::COLOUR_PANEL;
        let spec = ws.panel(id).unwrap();
        let ev = crate::panel_behavior::parse_event(
            &serde_json::json!({"widget":"cp_hex","event":"commit","value":"12ab34"})).unwrap();
        let mut store = crate::interpreter::state_store::StateStore::new();
        let mut model = crate::document::model::Model::default();
        let mut host = crate::panel_behavior::EngineHost::default();
        let r = crate::panel_behavior::run_widget_behavior(
            id, spec, &ev, &serde_json::json!({"state": {"fill_on_top": true, "fill_color": "#112233"}}),
            &mut store, &mut model, ws.actions(), ws.dialogs(),
            &mut host);
        assert!(matches!(r, Err(ref e) if e.class == "PanelNotHosted"), "{:?}", r.err().map(|e| e.class));
    }

    /// The colour panel's rows through the engine scope are, byte for byte,
    /// its rows through the slice's own scope, before and after a tick. The
    /// engine scope adds the store's global state and the document facts, and
    /// C1/C2 are pinned on the colour panel.
    #[test]
    fn the_colour_panel_rows_are_the_slice_scopes_rows() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let id = crate::panel_scope::COLOUR_PANEL;
        let ws = Workspace::load().unwrap();
        let e = jas_engine_new();
        let slice_rows = |e: *mut JasEngine| {
            let engine = engine_of(e);
            let scope = engine.panel.borrow().scope(engine.model.borrow().document());
            crate::interpreter::bind_values::bind_values(ws.panel(id).unwrap(), &scope).to_string()
        };
        let first = bind_rows(e, id);
        assert_eq!(first, slice_rows(e));
        colour_tick(e, "cp_hex", serde_json::json!("12ab34"));
        let second = bind_rows(e, id);
        assert_ne!(second, first, "fixture: the tick must move the colour rows");
        assert_eq!(second, slice_rows(e));
        // The slice WINS over the store's copy. A behavior that wrote the copy
        // directly must not change what the colour panel shows.
        engine_of(e).store.borrow_mut().set("fill_color", serde_json::json!("#000000"));
        assert_eq!(bind_rows(e, id), slice_rows(e), "the store's copy leaked into the colour rows");
        unsafe { jas_engine_free(e) };
    }

    /// The store holds a copy of the slice's three `state.*` keys, and the
    /// copy follows every colour tick. A behavior reading `state.fill_color`
    /// from the store must read what the colour panel shows.
    #[test]
    fn the_store_copy_of_the_colour_state_follows_every_tick() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let engine = engine_of(e);
        let agree = || {
            let keys = engine.panel.borrow().effective(&engine.model.borrow()).state_keys();
            let store = engine.store.borrow();
            for (k, v) in &keys {
                assert_eq!(store.get(k), v, "the store's {k} is not the slice's");
            }
            keys
        };
        let before = agree();
        colour_tick(e, "cp_hex", serde_json::json!("12ab34"));
        let after = agree();
        assert_ne!(before["fill_color"], after["fill_color"], "fixture: the tick moved nothing");
        assert_eq!(after["fill_color"], "#12ab34");
        unsafe { jas_engine_free(e) };
    }

    /// The colour panel's `panel.*` is the slice's. Its store scope holds ONE
    /// key, `mode` (the key a workspace action writes; `seed_colour_mode`), and
    /// that key always equals the slice's. Until 2026-10-12 the panel had no
    /// store scope at all, and every `set_color_panel_mode` was dropped.
    #[test]
    fn the_colour_panels_store_scope_is_mode_alone_and_agrees_with_the_slice() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let id = crate::panel_scope::COLOUR_PANEL;
        let e = jas_engine_new();
        let _ = plan_of(e, id, 228, 0);
        let _ = bind_rows(e, id);
        colour_tick(e, "cp_h", serde_json::json!(90));
        let _ = behave(e, id, r#"{"widget":"cp_h","event":"click"}"#);
        let _ = take(unsafe { jas_widget_tree(e, id.as_ptr(), id.len(), std::ptr::null(), 0) });
        let scope = |e| engine_of(e).store.borrow().panel_scope(id).cloned().expect("a scope");
        let keys: Vec<String> = scope(e).keys().cloned().collect();
        assert_eq!(keys, ["mode"], "no channel gets a second home in the store");
        // Both directions: an edit through the slice reaches the store, and the
        // store's value is the slice's.
        assert_eq!(engine_of(e).panel.borrow_mut().apply_edit("panel.mode", &serde_json::json!("cmyk")),
                   crate::panel_scope::EditOutcome::Changed);
        crate::panel_scope::sync_colour_state(&mut engine_of(e).store.borrow_mut(), &engine_of(e).panel.borrow());
        assert_eq!(scope(e)["mode"], serde_json::json!("cmyk"));
        assert_eq!(engine_of(e).panel.borrow().mode, "cmyk");
        // The control: the same calls on another panel DO seed it.
        let _ = plan_of(e, ALIGN, 228, 0);
        assert!(engine_of(e).store.borrow().has_panel(ALIGN));
        unsafe { jas_engine_free(e) };
    }

    /// A panel's `panel.*` is its own store scope, seeded from its declared
    /// defaults. Before the engine had a store, `panel.align_to` was null
    /// here, so no Align-To toggle read checked.
    #[test]
    fn a_panel_reads_its_own_store_scope() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let checked = |w: &str| leaf(e, ALIGN, w)["values"]["bind.checked"].clone();
        assert_eq!(checked("align_to_selection_button"), "true");
        assert_eq!(checked("align_to_artboard_button"), "false");
        assert_eq!(checked("align_to_key_object_button"), "false");
        unsafe { jas_engine_free(e) };
    }

    /// The align operation reads the Align panel's OWN `align_to`: after the
    /// Artboard toggle, Align Left aligns to the first artboard (D9: the
    /// engine has no Artboards panel selection), not to the selection.
    #[test]
    fn panel_behavior_align_reads_the_panels_own_align_to() {
        use crate::interpreter::align_host::{apply_align_operation, AlignInput, AlignTo};
        use crate::panel_behavior::test_fixture::misaligned;
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_with(misaligned(&[0, 1]));
        let oracle = |align_to: AlignTo| {
            let mut copy = engine_of(e).with_model(|m| m.clone());
            let input = AlignInput { align_to, key_object_path: None, distribute_spacing: 0.0,
                                     use_preview_bounds: false, artboard_selection: vec![] };
            apply_align_operation(&mut copy, "align_left", &input);
            crate::geometry::test_json::document_to_test_json(copy.document())
        };
        let to_artboard = oracle(AlignTo::Artboard);
        assert_ne!(to_artboard, oracle(AlignTo::Selection),
                   "fixture: the two modes must move the rects to different places");
        let (_, err) = behave(e, ALIGN, r#"{"widget":"align_to_artboard_button","event":"click"}"#);
        // The panel is not open, so no row moved; the engine's state did, and
        // that is not Unchanged.
        assert_eq!(err, "", "a toggle on a closed panel changed the engine's state");
        let (reply, err) = behave(e, ALIGN, LEFT);
        assert!(reply.contains(r#""doc_changed":true"#), "{reply} {err}");
        assert_eq!(doc_json(e), to_artboard);
        unsafe { jas_engine_free(e) };
    }

    /// Every open panel is re-resolved in ITS OWN scope. A colour tick with
    /// Align open must send no Align rows: resolved in the colour panel's
    /// scope, Align's `checked` rows would all read false and look moved.
    #[test]
    fn a_tick_resolves_each_open_panel_in_its_own_scope() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let _ = plan_of(e, ALIGN, 228, 0);
        let _ = plan_of(e, crate::panel_scope::COLOUR_PANEL, 228, 0);
        let id = crate::panel_scope::COLOUR_PANEL;
        let ev = r#"{"widget":"cp_hex","value":"12ab34"}"#;
        let delta = take(unsafe { jas_panel_event(e, id.as_ptr(), id.len(), ev.as_ptr(), ev.len()) });
        let rows: serde_json::Value = serde_json::from_str(&delta).unwrap();
        let rows = rows.as_array().unwrap();
        assert!(rows.iter().any(|r| r["panel"] == id), "fixture: the tick moved nothing: {delta}");
        assert!(rows.iter().all(|r| r["panel"] != ALIGN), "Align rows moved on a colour tick: {delta}");
        unsafe { jas_engine_free(e) };
    }

    /// A panel that binds global `state.*` reads the workspace's defaults
    /// through the engine. Before the engine had a store these were null.
    /// The INITIAL STATE MAP the engine starts from (the Windows shell's), against
    /// the reference's spec defaults over EVERY `state:` variable
    /// (`test_fixtures/algorithms/initial_state_map.json`).
    #[test]
    fn the_engine_starts_from_the_spec_defaults_for_every_state_variable() {
        let _g = crate::ffi_instr::test_lock::lock();
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../test_fixtures/algorithms/initial_state_map.json");
        let tests: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let expected = tests[0]["expected"].as_object().unwrap();
        assert!(expected.len() > 100, "the golden carries every state variable: {}", expected.len());
        let e = jas_engine_new();
        let store = unsafe { &*e }.store.borrow();
        let diffs: Vec<String> = expected.iter()
            .filter(|(k, v)| store.get(k) != *v)
            .map(|(k, v)| format!("{k}: spec {v} vs engine {}", store.get(k)))
            .collect();
        drop(store);
        unsafe { jas_engine_free(e) };
        assert!(diffs.is_empty(), "{} of {} differ:\n{}", diffs.len(), expected.len(), diffs.join("\n"));
    }

    #[test]
    fn a_panel_reads_the_global_state_defaults() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let ws = Workspace::load().unwrap();
        let defaults = ws.state_defaults();
        let want = defaults.get("magic_wand_opacity").cloned()
            .expect("fixture: state.yaml declares magic_wand_opacity");
        assert!(!want.is_null(), "fixture: a null default proves nothing");
        let e = jas_engine_new();
        let scope = {
            let engine = engine_of(e);
            let _ = plan_of(e, "magic_wand_panel_content", 228, 0);
            panel_ctx(engine, &ws, "magic_wand_panel_content")
        };
        assert_eq!(scope["state"]["magic_wand_opacity"], want);
        unsafe { jas_engine_free(e) };
    }

    /// Rows can move with nothing else moving: the plan was served before an
    /// op changed the selection (no tick runs after `jas_dispatch_event`).
    /// The click that carries those rows is not `Unchanged`.
    #[test]
    fn panel_behavior_that_only_moves_rows_is_not_unchanged() {
        use crate::panel_behavior::test_fixture::misaligned;
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_with(misaligned(&[]));
        assert_eq!(leaf(e, ALIGN, "align_left_button")["values"]["bind.disabled"], "true");
        engine_of(e).with_model_mut(|m| *m = misaligned(&[0, 1]));
        // Selection mode is already selected, so this toggle writes the values
        // the store already holds.
        let (reply, err) = behave(e, ALIGN,
                                  r#"{"widget":"align_to_selection_button","event":"click"}"#);
        let reply: serde_json::Value = serde_json::from_str(&reply)
            .unwrap_or_else(|_| panic!("the reply must be JSON: {reply:?} (error {err:?})"));
        assert_eq!(reply["doc_changed"], false);
        assert!(reply["changed"].as_array().unwrap().iter()
                    .any(|r| r["id"] == "align_left_button" && r["value"] == "false"),
                "fixture: the stale disabled row must move: {reply}");
        assert_eq!(err, "", "rows moved, so this is not Unchanged");
        unsafe { jas_engine_free(e) };
    }

    // ── W2b-1b: the widget event corpus, through the door ───────────────
    //
    // `test_fixtures/widget_events/corpus.json` is GENERATED by the reference
    // (`workspace_interpreter/widget_event.py`, WIDGET_EVENTS.md). Each case
    // is driven through `jas_panel_behavior` exactly as a shell sends it: a
    // commit carries the text as `value`, a press is a `click`. The engine's
    // store is seeded as the corpus says a consumer rebuilds it (bundle
    // defaults, then `before.state`; the panel scope is `before.panel`,
    // whole).
    //
    // What is compared: a refusal's class; the panel scope afterwards, whole;
    // and exactly which globals changed. Numbers compare as numbers. NOT
    // compared: `behaviors_run` and `bind_written`, which the door does not
    // report (a behavior's condition is evaluated inside the batch), and the
    // parsed `value`, which `widget_commit`'s own arms pin.
    //
    // ⛔ THE COLOUR PANEL IS SCOPED DIFFERENTLY, AND THIS SAYS WHY. Its
    // `panel.*` is the colour SLICE, never a store scope (`panel_scope`), and a
    // committed value is a colour edit that re-derives every channel and then
    // runs `set_active_color` (which moves `fill_color` and the recent list).
    // The corpus's panel snapshot is the reference's GENERIC store write
    // (`h` moves, `hex` does not), which is not this panel's law. So for Color
    // the case seeds the SLICE (as the engine adopts its spec colours at
    // birth), and compares the refusal class and, on a commit, the PARSED
    // value through `parse_commit`, the function the colour route calls. The
    // channel arithmetic is pinned by the colour corpus, not here.

    /// Numbers as numbers, recursively; everything else by equality.
    fn same_json(a: &serde_json::Value, b: &serde_json::Value) -> bool {
        use serde_json::Value;
        match (a, b) {
            (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
            (Value::Array(x), Value::Array(y)) => {
                x.len() == y.len() && x.iter().zip(y).all(|(p, q)| same_json(p, q))
            }
            (Value::Object(x), Value::Object(y)) => {
                x.len() == y.len()
                    && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same_json(v, w)))
            }
            _ => a == b,
        }
    }

    // `test_fixtures/widget_events/stops_gestures.json` is GENERATED by the
    // reference (`widget_event.gesture`, WIDGET_EVENTS.md §The stops kind) over
    // the shipped `grad_slider`. Each case is a SEQUENCE of gestures over one
    // store, sent through `jas_panel_behavior` as a shell sends them: the
    // gesture is the event and its raw parameters are `value`. Nothing is
    // selected, so the panel's stops are the store's (`engine_scope` overlays
    // the selection's gradient only when there is one).
    //
    // Compared after every step: the refusal class (the reference's `inert` is
    // the door's `EmptyBehavior`), the panel's stops and selection, whether a
    // press snapshot stands, and the list the `commit` behavior wrote to
    // `gradient_stops` (null when none ran). Numbers compare as numbers.
    #[test]
    fn stops_gesture_corpus_through_the_door() {
        let _counters = crate::ffi_instr::test_lock::lock();
        use std::collections::HashMap;
        use crate::interpreter::gradient_host::GRADIENT_PANEL;
        use serde_json::json;
        const CORPUS: &str = "widget_events/stops_gestures.json";
        let raw = std::fs::read_to_string(format!(
            "{}/../test_fixtures/{CORPUS}", env!("CARGO_MANIFEST_DIR")))
            .expect("the stops gesture corpus");
        let corpus: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let cases = corpus["cases"].as_array().expect("cases");
        assert!(cases.len() >= 10, "the corpus must not be empty");
        let mut failures: Vec<String> = vec![];
        let mut steps = 0;
        for c in cases {
            let name = c["name"].as_str().unwrap();
            let e = jas_engine_new();
            {
                let mut store = engine_of(e).store.borrow_mut();
                let setup = &c["setup"];
                let scope: HashMap<String, serde_json::Value> = HashMap::from([
                    ("stops".into(), setup["stops"].clone()),
                    ("selected_stop_index".into(), setup.get("stop").cloned().unwrap_or(json!(-1))),
                    ("selected_midpoint_index".into(), setup.get("midpoint").cloned().unwrap_or(json!(-1))),
                ]);
                store.init_panel(GRADIENT_PANEL, scope);
            }
            for (k, step) in c["steps"].as_array().unwrap().iter().enumerate() {
                steps += 1;
                let at = format!("{name} step {k} ({})", step["gesture"]);
                engine_of(e).store.borrow_mut().set("gradient_stops", serde_json::Value::Null);
                let ev = json!({"widget": corpus["widget"], "event": step["gesture"],
                                "value": step["params"]});
                let (_reply, err) = behave(e, GRADIENT_PANEL, &ev.to_string());
                let class = serde_json::from_str::<serde_json::Value>(&err).ok()
                    .and_then(|v| v["panel_event"].as_str().map(str::to_string))
                    .unwrap_or_default();
                let x = &step["expected"];
                let want = match x["outcome"].as_str().unwrap() {
                    "refused" => x["reason"].as_str().unwrap().to_string(),
                    "inert" => "EmptyBehavior".to_string(),
                    _ => String::new(),
                };
                if class != want && !(want.is_empty() && class == "Unchanged") {
                    failures.push(format!("{at}: refusal {class:?}, expected {want:?}"));
                }
                let store = engine_of(e).store.borrow();
                for (field, key) in [("stops", "stops"), ("stop", "selected_stop_index"),
                                     ("midpoint", "selected_midpoint_index")] {
                    let got = store.get_panel(GRADIENT_PANEL, key);
                    if !same_json(got, &x[field]) {
                        failures.push(format!("{at}: {key} {got} != {}", x[field]));
                    }
                }
                let pressed = !store.get_panel(GRADIENT_PANEL, "stops__press").is_null();
                if pressed != x["pressed"].as_bool().unwrap() {
                    failures.push(format!("{at}: pressed {pressed}"));
                }
                if !same_json(store.get("gradient_stops"), &x["committed"]) {
                    failures.push(format!("{at}: committed {} != {}", store.get("gradient_stops"), x["committed"]));
                }
            }
            unsafe { jas_engine_free(e) };
        }
        assert!(steps >= 30, "only {steps} steps ran");
        assert!(failures.is_empty(), "{} failure(s):\n{}", failures.len(), failures.join("\n"));
    }

    /// WIDGET_EVENTS.md §The stops kind, over a SELECTED element, which the
    /// corpus above cannot reach (it selects nothing). While a press snapshot
    /// stands, the panel scope shows the store's preview over the selection's
    /// gradient, and the document is untouched; the release writes the
    /// document once, and the scope then derives from it again.
    #[test]
    fn a_slider_drag_previews_in_the_scope_and_commits_the_document_once() {
        let _counters = crate::ffi_instr::test_lock::lock();
        use crate::document::test_fixture::{model_with, rect};
        use crate::interpreter::gradient_host::GRADIENT_PANEL;
        let e = engine_with(model_with(vec![rect(0.0, 0.0, 10.0, 10.0)], &[0]));
        let ws = Workspace::load().unwrap();
        let scope_locations = |e: *mut JasEngine| -> Vec<f64> {
            panel_ctx(engine_of(e), &ws, GRADIENT_PANEL)["panel"]["stops"].as_array().unwrap()
                .iter().map(|s| s["location"].as_f64().unwrap()).collect()
        };
        let doc_locations = |e: *mut JasEngine| -> Option<Vec<f64>> {
            engine_of(e).model.borrow().document().get_element(&vec![0, 0])
                .and_then(|el| el.fill_gradient().map(|g| g.stops.iter().map(|s| s.location).collect()))
        };
        let gesture = |e, g: &str, v: &str| behave(e, GRADIENT_PANEL,
            &format!(r#"{{"widget":"grad_slider","event":"{g}","value":{v}}}"#));
        // The solid selection reads as the seed: two stops at 0 and 100.
        assert_eq!(scope_locations(e), vec![0.0, 100.0]);
        let before = doc_locations(e);
        gesture(e, "press", r#"{"index":0,"location":0}"#);
        gesture(e, "drag", r#"{"location":30,"dy":0}"#);
        assert_eq!(scope_locations(e), vec![30.0, 100.0], "the preview stands over the document");
        assert_eq!(doc_locations(e), before, "a drag does not write the document");
        let (_reply, err) = gesture(e, "release", r#"{"location":35,"dy":0}"#);
        assert!(!err.contains("panel_event") || err.contains("Unchanged"), "{err}");
        assert_eq!(doc_locations(e), Some(vec![35.0, 100.0]));
        assert_eq!(scope_locations(e), vec![35.0, 100.0], "after the release the scope is the document's");
        undo(e);
        assert_eq!(doc_locations(e), before, "one gesture is one undo step");
        unsafe { jas_engine_free(e) };
    }

    /// flask §518: a release that leaves the stops as they were (a plain click
    /// on a stop, or a two-stop drag off the bar, which clamps onto itself)
    /// changes nothing, so its reply must not say `doc_changed`. It once did:
    /// `apply_stops` wrote the selection's gradient whether or not it differed,
    /// and the write moved the model's generation.
    #[test]
    fn a_release_that_moves_no_stop_changes_no_document() {
        let _counters = crate::ffi_instr::test_lock::lock();
        use crate::document::test_fixture::{model_with, rect};
        use crate::interpreter::gradient_host::GRADIENT_PANEL;
        let e = engine_with(model_with(vec![rect(0.0, 0.0, 10.0, 10.0)], &[0]));
        let gesture = |e, g: &str, v: &str| behave(e, GRADIENT_PANEL,
            &format!(r#"{{"widget":"grad_slider","event":"{g}","value":{v}}}"#));
        let doc_changed = |reply: &str| serde_json::from_str::<serde_json::Value>(reply)
            .ok().and_then(|v| v["doc_changed"].as_bool());
        // A real move first, so the selection holds a gradient (not the seed).
        gesture(e, "press", r#"{"index":0,"location":0}"#);
        let (moved, _) = gesture(e, "release", r#"{"location":35,"dy":0}"#);
        assert_eq!(doc_changed(&moved), Some(true), "the control: a move changes the document");
        let generation = engine_of(e).model.borrow().generation();
        // A plain click on stop 0: press, then release where it already is.
        gesture(e, "press", r#"{"index":0,"location":35}"#);
        let (click, _) = gesture(e, "release", r#"{"location":35,"dy":0}"#);
        assert_eq!(doc_changed(&click), Some(false), "a click on a stop: {click}");
        // Two stops, stop 1 dragged far below the bar: an ordinary move,
        // clamped to 100, where it already is.
        gesture(e, "press", r#"{"index":1,"location":100}"#);
        let (off, _) = gesture(e, "release", r#"{"location":100.1,"dy":46.3}"#);
        assert_eq!(doc_changed(&off), Some(false), "a two-stop drag off the bar: {off}");
        assert_eq!(engine_of(e).model.borrow().generation(), generation, "no write moved the generation");
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn widget_event_corpus_through_the_door() {
        // ⭐ ROW EK: the ONE crate-level counter lock. This test reaches an
        // export, and every export records a crossing on the process-global
        // counters -- so it races `ffi_instr`'s tests unless it takes this.
        let _counters = crate::ffi_instr::test_lock::lock();
        use std::collections::HashMap;
        // Fixture-relative, the shape `check_corpus_manifest.py` reads as a claim.
        const CORPUS: &str = "widget_events/corpus.json";
        let raw = std::fs::read_to_string(format!(
            "{}/../test_fixtures/{CORPUS}", env!("CARGO_MANIFEST_DIR")))
            .expect("the widget event corpus");
        let corpus: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let cases = corpus["cases"].as_array().expect("cases");
        assert!(cases.len() >= 15, "the corpus must not be empty");
        let mut failures: Vec<String> = vec![];
        let (mut refused, mut committed) = (0, 0);
        for c in cases {
            let name = c["name"].as_str().unwrap();
            let panel = c["panel"].as_str().unwrap();
            let e = jas_engine_new();
            {
                let mut store = engine_of(e).store.borrow_mut();
                for (k, v) in c["before"]["state"].as_object().unwrap() {
                    store.set(k, v.clone());
                }
                let scope: HashMap<String, serde_json::Value> = c["before"]["panel"]
                    .as_object().unwrap().iter().map(|(k, v)| (k.clone(), v.clone())).collect();
                store.init_panel(panel, scope);
            }
            let colour = panel == crate::panel_scope::COLOUR_PANEL;
            if colour {
                let en = engine_of(e);
                en.panel.borrow_mut().adopt_store_state(&en.store.borrow(), None);
                if let Some(m) = c["before"]["panel"]["mode"].as_str() {
                    en.panel.borrow_mut().mode = m.to_string();
                }
            }
            let before = engine_of(e).store.borrow().get_all().clone();
            let ev = if c["event"].get("press").is_some() {
                serde_json::json!({"widget": c["widget"], "event": "click"})
            } else {
                serde_json::json!({"widget": c["widget"], "event": "commit",
                                   "value": c["event"]["commit"]})
            };
            let (_reply, err) = behave(e, panel, &ev.to_string());
            let class = serde_json::from_str::<serde_json::Value>(&err).ok()
                .and_then(|v| v["panel_event"].as_str().map(str::to_string))
                .unwrap_or_default();
            let expected = &c["expected"];
            if expected["result"]["outcome"] == "refused" {
                refused += 1;
                let want = expected["result"]["reason"].as_str().unwrap();
                if class != want {
                    failures.push(format!("{name}: refusal {class:?}, expected {want:?}"));
                }
            } else {
                committed += 1;
                if !(class.is_empty() || class == "Unchanged") {
                    failures.push(format!("{name}: refused {err}"));
                }
            }
            if colour {
                if expected["result"]["outcome"] != "refused" {
                    let ws = Workspace::load().unwrap();
                    let node = crate::panel_behavior::widget_node(ws.panel(panel).unwrap(), c["widget"].as_str().unwrap())
                        .expect("the case's widget");
                    let text = c["event"]["commit"].as_str().unwrap();
                    let got = crate::interpreter::widget_commit::parse_commit(node, text);
                    if !got.as_ref().is_some_and(|g| same_json(g, &expected["result"]["value"])) {
                        failures.push(format!("{name}: parsed {got:?} != {}", expected["result"]["value"]));
                    }
                }
                unsafe { jas_engine_free(e) };
                continue;
            }
            let store = engine_of(e).store.borrow();
            let panel_after: serde_json::Map<String, serde_json::Value> = store
                .panel_scope(panel).unwrap().iter().map(|(k, v)| (k.clone(), v.clone())).collect();
            let panel_after = serde_json::Value::Object(panel_after);
            if !same_json(&panel_after, &expected["panel"]) {
                failures.push(format!("{name}: panel {panel_after} != {}", expected["panel"]));
            }
            let mut changed = serde_json::Map::new();
            for (k, v) in store.get_all() {
                if !before.get(k).is_some_and(|b| same_json(b, v)) {
                    changed.insert(k.clone(), v.clone());
                }
            }
            let changed = serde_json::Value::Object(changed);
            if !same_json(&changed, &expected["state_changed"]) {
                failures.push(format!("{name}: globals changed {changed} != {}",
                                      expected["state_changed"]));
            }
            drop(store);
            unsafe { jas_engine_free(e) };
        }
        assert!(refused > 0 && committed > 0, "both outcomes must be exercised");
        assert_eq!(refused + committed, cases.len());
        assert!(failures.is_empty(), "{} of {} cases:\n{}", failures.len(), cases.len(),
                failures.join("\n"));
    }

    /// THE BRUSHES PANEL'S PREVIEWS REACH THE SHELL. Until this arm every
    /// `brush_preview` leaf was sent as `values: {}` and `w: 0`: the drawing
    /// lived only in the web view, and the layout pass sized the leaf at the
    /// kind's intrinsic width, which is 0.
    ///
    /// The expectation is derived by a DIFFERENT ROUTE from the plan's: the
    /// plan reads each leaf's foreach scope; this arm walks the engine's own
    /// `panel.open_libraries` and `data.brush_libraries` in order and draws
    /// each brush with `preview_svg`. Two routes, one sequence.
    #[test]
    fn every_brush_preview_leaf_carries_its_brush_drawing_and_a_real_rect() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let ws = crate::interpreter::workspace::Workspace::load().expect("workspace");
        let plan: serde_json::Value =
            serde_json::from_str(&plan_of(e, "brushes_panel_content", 228, 0)).expect("plan JSON");
        let ctx = panel_ctx(unsafe { &*e }, &ws, "brushes_panel_content");
        let mut want = vec![];
        for lib in ctx["panel"]["open_libraries"].as_array().into_iter().flatten() {
            let id = lib["id"].as_str().unwrap_or("");
            for b in ctx["data"]["brush_libraries"][id]["brushes"].as_array().into_iter().flatten() {
                want.push(crate::brush_preview::preview_svg(b));
            }
        }
        let leaves: Vec<&serde_json::Value> = plan["leaves"].as_array().expect("leaves").iter()
            .filter(|l| l["type"] == "brush_preview").collect();
        assert!(!leaves.is_empty(), "no brush_preview leaf in the plan -- the arm is vacuous");
        assert_eq!(leaves.len(), want.len(), "one preview per brush in the open libraries");
        assert!(want.iter().any(Option::is_some), "no brush has a preview -- the display half is vacuous");
        for (i, (l, w)) in leaves.iter().zip(&want).enumerate() {
            assert_eq!(l["rect"]["w"], 38, "leaf {i}: {}", l["rect"]);
            assert_eq!(l["rect"]["h"], 38, "leaf {i}: {}", l["rect"]);
            let got = l["display"]["preview.svg"].as_str().map(String::from);
            assert_eq!(&got, w, "leaf {i}");
            let vb = l["display"]["preview.viewbox"].as_str();
            assert_eq!(vb, w.as_ref().map(|_| crate::brush_preview::VIEWBOX), "leaf {i}");
        }
        unsafe { jas_engine_free(e) };
    }
}
