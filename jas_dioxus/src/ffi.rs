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
    // The store's copy of the colour state is what an action's guard reads
    // (`state.fill_color == null`), so it carries the colour as SHOWN: the
    // selection's, as the web's action context does (`action_fill_stroke_values`).
    crate::panel_scope::sync_colour_state(
        &mut engine.store.borrow_mut(), &engine.panel.borrow().effective(&engine.model.borrow()));
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
        // Only `mode` (see `seed_colour_mode`): the slice owns the rest.
        crate::panel_scope::seed_colour_mode(&engine.panel.borrow(), &mut engine.store.borrow_mut());
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

    if id == crate::panel_scope::COLOUR_PANEL && is_value_commit(spec, &ev) {
        return colour_value_commit(engine, &ws, spec, &ev);
    }
    // Every other Color event (a swatch, a chip, swap) runs its declared
    // behaviour in the colour scope like any panel's; the value branches of
    // `run_widget_behavior` still refuse Color by name.
    let scope = panel_ctx(engine, &ws, id);
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
    let reply = serde_json::json!({"changed": sync.changed, "doc_changed": ran.doc_changed});
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
/// The reply is the behaviour door's, `{"changed", "doc_changed": false}`:
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
    let Some(target) = crate::panel_scope::binding_of(spec, &ev.widget, "bind.value") else {
        return refuse("MissingTarget", &ev.widget);
    };
    engine.panel.borrow_mut().materialize(&engine.model.borrow());
    let outcome = engine.panel.borrow_mut().apply_edit(&target, &value);
    if outcome == EditOutcome::NoSuchTarget {
        return refuse("BadParamType", &target);
    }
    crate::panel_scope::sync_colour_state(&mut engine.store.borrow_mut(), &engine.panel.borrow());
    // The slice computed the new colour (by channel and mode); COMMITTING it is
    // `set_active_color`'s, "the commit point for all color changes from the
    // Color Panel: … hex field Enter/Tab" (`actions.yaml`). So it runs here as
    // a click runs it, in the colour scope: the model's default and selection
    // follow (`colour_host`, through `global_written`), the recent colour is
    // pushed, and the runner owns the one undo step.
    let mut doc_changed = false;
    if outcome == EditOutcome::Changed {
        let key = if engine.panel.borrow().fill_on_top { "fill_color" } else { "stroke_color" };
        let colour = engine.store.borrow().get(key).clone();
        let params = serde_json::json!({"color": colour});
        let scope = panel_ctx(engine, ws, id);
        let ran = {
            let mut store = engine.store.borrow_mut();
            let mut model = engine.model.borrow_mut();
            let mut host = crate::panel_behavior::EngineHost { artboard_selection: vec![] };
            crate::panel_behavior::run_action(
                Some(id), "set_active_color", Some(&params), &scope, &mut store, &mut model,
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
    let reply = serde_json::json!({"changed": sync.changed, "doc_changed": doc_changed});
    let out = JasBytes::from_string(serde_json::to_string(&reply).unwrap_or_default());
    ffi_instr::record_out(Crossing::PanelBehavior, out.len);
    out
}

/// Run one workspace ACTION, as a menu item runs it: `{"menu_item": <id>}`, the
/// item's own `action` and `params` read from the menubar (the shell names WHICH
/// item was chosen, BL1, and never authors params; the menu structure carries
/// none), or `{"action": <id>, "params": {...}}` directly, `params` optional.
/// The core runs the action's effects as `jas_panel_behavior` runs a widget's,
/// with no panel made active.
///
/// The owner's notes (2026-10-11): the Windows menus drew every item live and
/// ran five; File > New made no tab, because nothing ran `new_document`.
///
/// # The reply
///
/// [`jas_panel_behavior`]'s: `{"changed": [<row>...], "doc_changed": <bool>}`,
/// so the shell repaints and re-reads exactly as after a click.
///
/// # ⛔ A refusal runs NOTHING
///
/// The empty span, and [`jas_last_error_json`] reads `{"panel_event":
/// "<class>","detail":"<detail>"}`: `BadUtf8`, `BadJson`, `UnknownMenuItem` (a
/// menu item id the menubar does not hold, named), `MissingAction` (no
/// `action` string), `UnknownAction` (an id the workspace does not define,
/// named), or `PlatformEffect` (an effect only the shell can run, such as a
/// native dialog, found by the pre-flight before anything moved). An action
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
    // `{"panel": <content id>, "menu_index": <i>}`: that PANEL menu's item i,
    // run with its panel active and in its panel's scope.
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
    let scope = match panel {
        Some(pid) => panel_ctx(engine, &ws, pid),
        None => crate::panel_scope::engine_scope(
            &engine.panel.borrow(), &engine.store.borrow(), &engine.model.borrow(), ""),
    };
    let ran = {
        let mut store = engine.store.borrow_mut();
        let mut model = engine.model.borrow_mut();
        let mut host = crate::panel_behavior::EngineHost { artboard_selection: vec![] };
        crate::panel_behavior::run_action(
            panel, action, params, &scope, &mut store, &mut model, ws.actions(), ws.dialogs(),
            &mut host)
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
    if ran.doc_changed || state_changed || moved {
        *engine.last_error.borrow_mut() = None;
    } else {
        set_panel_event_error(engine, "Unchanged", action);
    }
    let reply = serde_json::json!({"changed": sync.changed, "doc_changed": ran.doc_changed});
    let out = JasBytes::from_string(serde_json::to_string(&reply).unwrap_or_default());
    ffi_instr::record_out(Crossing::DispatchAction, out.len);
    out
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
                    "label": o.get("label").cloned().unwrap_or(serde_json::Value::Null),
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

    /// **W2b-17 (F-J).** The Symbols panel's verbs run in the engine through
    /// `symbols_host`, the web's own implementation, instead of reporting their
    /// `log` stubs. New Symbol promotes the selection and panel-selects the new
    /// master in the STORE; Place Instance places the store-selected master;
    /// Delete on a master that still has instances would open the orphan
    /// confirm, which the engine refuses by the dialog's name, changing nothing.
    #[test]
    fn the_symbol_verbs_run_in_the_engine_and_the_orphan_confirm_is_refused() {
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
        assert_eq!(reply, "", "delete with instances is refused");
        assert_eq!(err, refusal("PlatformEffect", "Dialog:delete_symbol_orphan_confirm"));
        assert_eq!(doc_json(e), before, "a refusal changes nothing");
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
        let plan = plan_of(e, "canvas_pane", 1600, 900);
        assert!(!plan.contains("canvas_tab_0"), "nothing ran: {plan}");
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

    /// The Type button names a tool no shell tool answers yet (the type tools
    /// are native). Its checked state must not claim a tool the pointer is not
    /// driving: `active_tool` stays the real tool, and the click says Unchanged.
    #[test]
    fn a_toolbar_click_on_a_tool_the_shell_lacks_changes_nothing() {
        let _g = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        assert_eq!(unsafe { crate::ffi_pointer::jas_set_tool(e, 0) }, JasStatus::Ok);
        let (_, err) = behave(e, TOOLBAR, r#"{"widget":"btn_text_slot","event":"click"}"#);
        assert_eq!(slot_tool(e), Some("selection"));
        assert_eq!(unsafe { &*e }.active_tool_state().as_deref(), Some("selection"),
                   "the toolbar's checked button stays the tool the pointer drives");
        assert!(err.contains("Unchanged"), "{err}");
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
                    // A render key is written by `set:` or by `swap:` (Swap
                    // Arrowheads, whose batch the engine refused until it
                    // hosted `swap_panel_state`).
                    let effects = || b["effects"].as_array().into_iter().flatten();
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
                    items.iter().for_each(|c| walk(c, out));
                }
            }
        }
        walk(&ws.panel(STROKE).unwrap()["content"], &mut clicks);
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

    /// **A12 (W2b-12).** The engine has no dialog door, so a behavior that
    /// opens a dialog is refused by the dialog's name, and nothing of its
    /// batch runs. Until A12, New Brush with a selection RAN: it opened the
    /// dialog in the engine's store, which no shell can show, and replied as a
    /// success with the error channel empty.
    #[test]
    fn panel_behavior_refuses_a_dialog_by_name() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = stroked_engine();
        let _ = plan_of(e, "brushes_panel_content", 228, 0);
        let before = doc_json(e);
        let store_before = engine_of(e).store.borrow().eval_context();
        let (reply, err) = behave(e, "brushes_panel_content",
                                  r#"{"widget":"bp_new_brush_btn","event":"click"}"#);
        assert_eq!(err, refusal("PlatformEffect", "Dialog:brush_options"));
        assert_eq!(reply, "");
        assert_eq!(doc_json(e), before);
        assert_eq!(engine_of(e).store.borrow().dialog_id(), None,
                   "the refused batch opened a dialog on the live store");
        assert_eq!(engine_of(e).store.borrow().eval_context(), store_before);
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
        let mut host = crate::panel_behavior::EngineHost { artboard_selection: vec![] };
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
