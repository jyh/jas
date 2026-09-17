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
        let panel = PanelState::default();
        let mut store = StateStore::new();
        if let Some(ws) = Workspace::load() {
            for (k, v) in ws.state_defaults() {
                store.set(&k, v);
            }
        }
        crate::panel_scope::sync_colour_state(&mut store, &panel);
        JasEngine {
            model: RefCell::new(Model::default()),
            last_error: RefCell::new(None),
            panel: RefCell::new(panel),
            registry: RefCell::new(PanelRegistry::default()),
            store: RefCell::new(store),
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
fn panel_ctx(engine: &JasEngine, ws: &Workspace, panel_id: &str) -> serde_json::Value {
    seed_panel(engine, ws, panel_id);
    crate::panel_scope::engine_scope(
        &engine.panel.borrow(), &engine.store.borrow(), &engine.model.borrow(), panel_id)
}

/// Give `panel_id` a store scope, seeded from its declared `state:` defaults,
/// the first time the engine assembles its scope. The web app seeds a panel
/// the same way (`renderer.rs`, `panel_state_defaults`); `init:` is not
/// evaluated. Never the colour panel. Callers pass only ids the workspace
/// holds.
fn seed_panel(engine: &JasEngine, ws: &Workspace, panel_id: &str) {
    if panel_id == crate::panel_scope::COLOUR_PANEL {
        return;
    }
    let mut store = engine.store.borrow_mut();
    if !store.has_panel(panel_id) {
        store.init_panel(panel_id, ws.panel_state_defaults(panel_id));
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
    let (plan, rows) = crate::panel_plan::panel_plan(spec, avail_w, avail_h, &ctx, ws.icons());
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
/// `{"changed": [<row>...], "doc_changed": <bool>}`. Each row is a
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

    let scope = if id == crate::panel_scope::COLOUR_PANEL {
        serde_json::Value::Null
    } else {
        panel_ctx(engine, &ws, id)
    };
    let ran = {
        let mut store = engine.store.borrow_mut();
        let mut model = engine.model.borrow_mut();
        let mut host = crate::panel_behavior::EngineHost { artboard_selection: vec![] };
        crate::panel_behavior::run_widget_behavior(
            id, spec, &ev, &scope, &mut store, &mut model, ws.actions(), ws.dialogs(), &mut host)
    };
    let ran = match ran {
        Ok(ran) => ran,
        Err(r) => return refuse(r),
    };

    let sync = engine.registry.borrow_mut().sync(&ws, &|pid| panel_ctx(engine, &ws, pid));
    ffi_instr::record_engine(sync.rows_evaluated, sync.panels_evaluated);
    let moved = sync.changed.as_array().map_or(false, |rows| !rows.is_empty());
    if ran.doc_changed || ran.state_changed || moved {
        *engine.last_error.borrow_mut() = None;
    } else {
        set_panel_event_error(engine, "Unchanged", &ev.widget);
    }
    let reply = serde_json::json!({"changed": sync.changed, "doc_changed": ran.doc_changed});
    let out = JasBytes::from_string(serde_json::to_string(&reply).unwrap_or_default());
    ffi_instr::record_out(Crossing::PanelBehavior, out.len);
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
                let layout = crate::interpreter::panel_layout::layout_panel(spec, w, h, &ctx);
                let rp = crate::interpreter::panel_layout::render_plan(spec, w, h, &ctx);
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
            let want = row_values(&rows);
            assert!(n > 0, "vacuous: nothing joined");
            assert_eq!(n, want.len(), "every row joined exactly once");
            assert_eq!(values, want, "plan values != jas_bind_values rows");
            values
        };

        let a = read(e);
        let hex_key = a
            .iter()
            .find(|(k, v)| k.ends_with("|bind.value") && v.as_str() == "664040")
            .map(|(k, _)| k.clone())
            .expect("the engine's seed displays 664040");

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
    const LEFT: &str = r#"{"widget":"align_left_button","event":"click"}"#;

    /// An engine whose document is `model`.
    fn engine_with(model: Model) -> *mut JasEngine {
        let e = jas_engine_new();
        unsafe { e.as_ref() }.unwrap().with_model_mut(|m| *m = model);
        e
    }

    /// (reply, error channel) for one behavior crossing.
    fn behave(e: *mut JasEngine, panel: &str, event: &str) -> (String, String) {
        let reply = take(unsafe {
            jas_panel_behavior(e, panel.as_ptr(), panel.len(), event.as_ptr(), event.len())
        });
        (reply, take(unsafe { jas_last_error_json(e) }))
    }

    fn refusal(class: &str, detail: &str) -> String {
        format!(r#"{{"panel_event":"{class}","detail":"{detail}"}}"#)
    }

    fn doc_json(e: *mut JasEngine) -> String {
        take(unsafe { jas_document_json(e) })
    }

    fn undo(e: *mut JasEngine) {
        let op = r#"{"op":"undo"}"#;
        assert_eq!(unsafe { jas_dispatch_event(e, op.as_ptr(), op.len()) }, JasStatus::Ok);
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
        assert_eq!(keys, vec!["changed", "doc_changed"], "{reply}");
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
        assert_eq!(reply, r#"{"changed":[],"doc_changed":false}"#);
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
        assert_eq!((reply.as_str(), err.as_str()), (r#"{"changed":[],"doc_changed":true}"#, ""));
        let h1 = doc_json(e);
        assert_ne!(h1, hs, "the click reported a change and the document did not move");

        // -> H1B: the selection is aligned now, and the engine SAYS so.
        assert_eq!(behave(e, ALIGN, &click),
                   (r#"{"changed":[],"doc_changed":false}"#.to_string(), refusal("Unchanged", widget)));
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
        fn walk(node: &serde_json::Value, out: &mut Vec<(String, Vec<String>)>) {
            if let (Some(id), Some(behaviors)) = (node["id"].as_str(), node["behavior"].as_array()) {
                for b in behaviors {
                    if b["event"].as_str().unwrap_or("click") != "click" {
                        continue;
                    }
                    let keys: Vec<String> = b["effects"].as_array().into_iter().flatten()
                        .filter_map(|eff| eff["set"].as_object())
                        .flat_map(|m| m.keys().cloned())
                        .filter(|k| is_render_key(k))
                        .collect();
                    let refused = b["effects"].as_array().into_iter().flatten()
                        .any(|eff| eff.get("swap_panel_state").is_some());
                    if !keys.is_empty() && !refused {
                        out.push((id.to_string(), keys));
                    }
                }
            }
            for k in ["children", "do"] {
                if let Some(items) = node[k].as_array() {
                    items.iter().for_each(|c| walk(c, out));
                }
            }
        }
        walk(&ws.panel(STROKE).unwrap()["content"], &mut clicks);
        assert!(clicks.len() >= 10, "the census read {} clicks: {clicks:?}", clicks.len());
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

    /// The calibrated fixture, all selected, after measuring the X oracle's
    /// precondition: the document carries no transform. Properties X is in the
    /// S-3 transform-blind class (`properties_host::apply_field`), so "X = 40
    /// puts the box at 40" holds only on an untransformed selection.
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

    /// **Q5.** A behavior that reaches an effect the engine cannot run is
    /// refused by name, and NO effect of its batch ran: not the snapshot that
    /// opens it, not the `set` that closes it.
    #[test]
    fn panel_behavior_refuses_an_unhosted_effect_before_any_effect_runs() {
        use crate::panel_behavior::test_fixture::misaligned;
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_with(misaligned(&[0, 1]));
        let _ = plan_of(e, BOOLEAN, 228, 0);
        let before = doc_json(e);
        let store_before = engine_of(e).store.borrow().eval_context();
        let (reply, err) = behave(e, BOOLEAN,
                                  r#"{"widget":"boolean_union_button","event":"click"}"#);
        assert_eq!(reply, "");
        assert_eq!(err, refusal("PlatformEffect", "UnknownEffect:boolean_union"));
        assert_eq!(doc_json(e), before);
        engine_of(e).with_model(|m| {
            assert!(!m.in_txn(), "the refused batch's snapshot ran on the live model");
            assert!(!m.can_undo());
        });
        assert_eq!(engine_of(e).store.borrow().eval_context(), store_before,
                   "the refused batch's `set` ran on the live store");
        // The modifier routes to the other declared behavior, and it is named.
        let (_, err) = behave(e, BOOLEAN,
            r#"{"widget":"boolean_union_button","event":"click","alt":true}"#);
        assert_eq!(err, refusal("PlatformEffect", "UnknownEffect:boolean_union_compound"));
        unsafe { jas_engine_free(e) };
    }

    /// **D6/D7.** A log-only action is a stub for work a platform supplies, and
    /// it is refused as one.
    #[test]
    fn panel_behavior_refuses_a_log_only_action_by_name() {
        use crate::panel_behavior::test_fixture::misaligned;
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_with(misaligned(&[0]));
        let (reply, err) = behave(e, "symbols_panel_content",
                                  r#"{"widget":"sym_new","event":"click"}"#);
        assert_eq!(reply, "");
        assert_eq!(err, refusal("PlatformEffect", "Logged:new_symbol"));
        unsafe { jas_engine_free(e) };
    }

    /// **D7.** Every other refusal, each with its exact string.
    #[test]
    fn panel_behavior_refuses_by_name_where_there_is_nothing_to_run() {
        use crate::panel_behavior::test_fixture::misaligned;
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = engine_with(misaligned(&[0, 1]));
        let cases: [(&str, &str, String); 6] = [
            // The colour panel's state is PanelState's, not the store's.
            ("color_panel_content", r#"{"widget":"cp_h","event":"click"}"#,
             refusal("PanelNotHosted", "color_panel_content")),
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
            let keys = engine.panel.borrow().state_keys();
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

    /// The colour panel's `panel.*` is the slice's, and nothing the engine does
    /// gives it a second home in the store.
    #[test]
    fn the_colour_panel_never_gets_a_store_scope() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let id = crate::panel_scope::COLOUR_PANEL;
        let e = jas_engine_new();
        let _ = plan_of(e, id, 228, 0);
        let _ = bind_rows(e, id);
        colour_tick(e, "cp_h", serde_json::json!(90));
        let _ = behave(e, id, r#"{"widget":"cp_h","event":"click"}"#);
        let _ = take(unsafe { jas_widget_tree(e, id.as_ptr(), id.len(), std::ptr::null(), 0) });
        assert!(!engine_of(e).store.borrow().has_panel(id));
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
}
