//! ⭐ ROW DU / NODE 5, PR 2 — THE POINTER CROSSES THE BOUNDARY.
//!
//! Row DU's premise needed one correction, filed as a fork and ruled on:
//! `jas_dispatch_event` takes a **document op**, not a pointer. Something has
//! to turn a pointer into an op, and in this codebase that something is
//! `CanvasTool::on_press` / `on_move` / `on_release`, driven by the workspace
//! YAML tool spec. **The shell must not do it** — hit-testing, marquee state
//! and tool modes are app logic, and putting them in C# is the BL1 violation
//! the boundary exists to prevent.
//!
//! So the pointer gets its own entry point, and the op channel keeps its job:
//! it carries what the TOOL emits, not what the mouse did.
//!
//! ⛔ **BL5: SCALARS ONLY.** No `string` parameter crosses here — not for the
//! tool id, not for the modifiers. A tool is selected by INDEX against a list
//! the shell reads back by index ([`jas_tool_count`] / [`jas_tool_name`]),
//! exactly as the corpus accessors already do, and the modifiers are bit flags.

use crate::document::model::Model;
use crate::ffi::{JasEngine, JasStatus};
use crate::tools::tool::CanvasTool;
use crate::interpreter::align_host;
use crate::panel_behavior::ALIGN_PANEL;

/// Which pointer transition crossed. Values are ABI: the shell sends these
/// integers, so they are appended to, never renumbered.
pub const KIND_PRESS: u32 = 0;
pub const KIND_MOVE: u32 = 1;
pub const KIND_RELEASE: u32 = 2;

/// Modifier bit flags. ABI, like the kinds above.
pub const MOD_SHIFT: u32 = 1 << 0;
pub const MOD_ALT: u32 = 1 << 1;
/// Whether a button is down during a move. Canvas has no such concept; the
/// tool trait does (`on_move`'s `dragging`), and the shell is the only thing
/// that knows.
pub const MOD_DRAGGING: u32 = 1 << 2;
/// The platform's command modifier (Ctrl on Windows). W5-3a carries it so a
/// menu chord is never mistaken for a bare tool letter; no chord acts yet.
pub const MOD_CMD: u32 = 1 << 3;

/// Named keys for [`jas_key_event`] (crate-private since #465), as their ASCII control codes. Any other
/// `code` is a Unicode scalar: the CHARACTER the key produced, never a
/// virtual-key number, so the shell need not know the core's key table.
pub(crate) const KEY_BACKSPACE: u32 = 0x08;
pub(crate) const KEY_ENTER: u32 = 0x0D;
pub(crate) const KEY_ESCAPE: u32 = 0x1B;
pub(crate) const KEY_DELETE: u32 = 0x7F;
// The caret keys, as the AppKit function-key code points (NSUpArrowFunctionKey
// and its neighbours, Unicode private use), so no printable character collides.
pub(crate) const KEY_ARROW_UP: u32 = 0xF700;
pub(crate) const KEY_ARROW_DOWN: u32 = 0xF701;
pub(crate) const KEY_ARROW_LEFT: u32 = 0xF702;
pub(crate) const KEY_ARROW_RIGHT: u32 = 0xF703;
pub(crate) const KEY_HOME: u32 = 0xF729;
pub(crate) const KEY_END: u32 = 0xF72B;
pub(crate) const KEY_TAB: u32 = 0x09;

/// `select_tool` targets in `workspace/shortcuts.yaml` the shell CANNOT select,
/// by declaration. A key bound to one is not handled. Empty since 2026-10-20:
/// `type`, the native Type tool, is in `TOOL_IDS` and takes the keys typed
/// (the 10-20 feel sitting, finding 3), so its `T` selects it.
pub(crate) const KEY_NOT_SELECTABLE: &[&str] = &[];

/// Tools in `TOOL_IDS` that are NATIVE, not workspace YAML tools, so the
/// workspace's tool table does not list them: built by name in `build_tool`.
#[cfg(test)]
const NATIVE_TOOL_IDS: &[&str] = &["type"];

/// The tools the shell may select, by index. Order is ABI.
///
/// ⛔ NOT `Workspace::load()`'s map order. A `serde_json::Map` iterates in
/// whatever order it was built, so an index into it would silently repoint at
/// a different tool the next time the workspace bundle is recompiled — the
/// shell would send "3" and get a different tool than the one the user picked.
/// This list is explicit and this crate owns it.
pub const TOOL_IDS: &[&str] = &[
    "selection",
    "interior_selection",
    "partial_selection",
    "rect",
    "ellipse",
    "line",
    "pen",
    "pencil",
    "zoom",
    // W5-1 (2026-10-09): every other workspace tool, APPENDED in alphabetical
    // order so the nine indexes above keep their meaning. Each builds in the
    // web-free engine (the wave-3 census, 27/27). Since W5-2 every one is
    // selectable from the shell by `SB_TOOL=<index>`: idle motion is forwarded
    // and proved safe for all of them (`an_unpressed_move_changes_no_tools_document`).
    // Keys and double-click are not forwarded yet (W5-3).
    "add_anchor_point",
    "anchor_point",
    "artboard",
    "blob_brush",
    "delete_anchor_point",
    "eyedropper",
    "hand",
    "lasso",
    "magic_wand",
    "paintbrush",
    "path_eraser",
    "polygon",
    "rotate",
    "rounded_rect",
    "scale",
    "shear",
    "smooth",
    "star",
    // 2026-10-20 (the 10-20 feel sitting, finding 3): the Type tool, APPENDED
    // so every index above keeps its meaning. It is native, not a workspace
    // YAML tool, so `build_tool` builds it by name. Type on a Path is not
    // here yet: it needs a path to place on, and is its own node.
    "type",
];

/// How many tools the shell may select. Pairs with [`jas_tool_name`].
///
/// # Safety
/// Takes no pointers; `unsafe` only for ABI uniformity with the rest of the
/// surface, so a C consumer sees one calling convention.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_tool_count() -> usize {
    TOOL_IDS.len()
}

/// The tool id at `index`, as static UTF-8 bytes plus a length.
///
/// ⛔ NO ALLOCATION AND NO `jas_free`. The ids are `&'static str` in this
/// binary, so the pointer is valid for the process and the shell copies what it
/// needs -- the same shape `jas_corpus_name` uses, and the reason BL4 has
/// nothing to say about it. Returns NULL and writes 0 for an index out of
/// range: a wild pointer is what the fail-closed doctrine is FOR.
///
/// # Safety
/// `out_len` must be NULL or valid for one `usize` write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_tool_name(index: usize, out_len: *mut usize) -> *const u8 {
    let Some(id) = TOOL_IDS.get(index) else {
        if !out_len.is_null() { unsafe { *out_len = 0 }; }
        return std::ptr::null();
    };
    if !out_len.is_null() { unsafe { *out_len = id.len() }; }
    id.as_ptr()
}

/// The [`TOOL_IDS`] index a `select_tool` routing id names: the id itself, or
/// the anchor tools' short routing form (`add_anchor` → `add_anchor_point`,
/// `ToolKind::panel_state_name`). None when no selectable tool has that id.
pub(crate) fn selectable_index(id: &str) -> Option<usize> {
    TOOL_IDS.iter().position(|t| *t == id)
        .or_else(|| TOOL_IDS.iter().position(|t| *t == format!("{id}_point")))
}

/// The two workspace state names that are not the tool's YAML id -- the
/// inverse [`selectable_index`] needs when the core WRITES `active_tool`. An
/// explicit table, not a `_point` strip: `anchor_point` is itself a tool id.
const STATE_NAME_TO_ID: &[(&str, &str)] = &[
    ("add_anchor", "add_anchor_point"),
    ("delete_anchor", "delete_anchor_point"),
];

/// The workspace state name for a [`TOOL_IDS`] id: the inverse of the above.
fn state_name_for_id(id: &str) -> &str {
    STATE_NAME_TO_ID.iter().find(|(_, i)| *i == id).map_or(id, |(n, _)| *n)
}

/// What [`sync_tool_to_state`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ToolSync {
    /// The pointer already drives the tool `active_tool` names (or none is set).
    Same,
    /// The pointer now drives it: leave, then enter.
    Switched,
    /// `active_tool` named a tool no shell tool answers, so it was written
    /// BACK to the tool the pointer drives -- the toolbar's checked button must
    /// never claim a tool that is not the one in use.
    Refused,
}

/// Make the pointer's tool agree with the workspace's `active_tool`, after
/// anything that may have written it (a toolbar click runs `select_tool`).
/// The switch is the one [`jas_set_tool`] makes: leave, then enter.
pub(crate) fn sync_tool_to_state(engine: &JasEngine) -> ToolSync {
    let Some(name) = engine.active_tool_state() else { return ToolSync::Same };
    let current = engine.tool_slot().as_ref().map(|(i, _)| *i);
    match selectable_index(&name) {
        Some(want) if current == Some(want) => ToolSync::Same,
        Some(want) if switch_tool(engine, want) == JasStatus::Ok => ToolSync::Switched,
        _ => {
            if let Some(i) = current {
                engine.set_active_tool_state(state_name_for_id(TOOL_IDS[i]));
            }
            ToolSync::Refused
        }
    }
}

/// Select the tool the pointer drives, by index into [`TOOL_IDS`].
///
/// # Safety
/// `e` must be NULL or a pointer from `jas_engine_new` that is still live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_set_tool(e: *mut JasEngine, index: usize) -> JasStatus {
    let Some(engine) = (unsafe { e.as_ref() }) else { return JasStatus::NullHandle };
    switch_tool(engine, index)
}

/// The tool switch behind [`jas_set_tool`] and [`sync_tool_to_state`]. It also
/// writes `active_tool`, so the toolbar's checked button is the tool the pointer
/// drives however the tool was picked: one truth, read by both.
fn switch_tool(engine: &JasEngine, index: usize) -> JasStatus {
    let Some(id) = TOOL_IDS.get(index) else { return JasStatus::MissingTarget };
    let Some(mut built) = build_tool(id) else { return JasStatus::MissingTarget };
    // ⛔ A SWITCH IS LEAVE-THEN-ENTER, NEVER A SLOT ASSIGNMENT (W5-0). The old
    // tool's `on_leave` is what commits work in flight (the pen's open path),
    // and the new tool's `on_enter` resets state it shares with others (the
    // pen's thread-local anchor buffer). Both apps switch this way (Swift's
    // `CanvasSubwindow` tool observer, the web app's `active_tool` route in
    // `renderer.rs`); an assignment alone drops the path and keeps the anchors.
    let mut slot = engine.tool_slot();
    if let Some((_, old)) = slot.as_mut() {
        engine.with_model_mut(|m| old.deactivate(m));
    }
    engine.with_model_mut(|m| built.activate(m));
    *slot = Some((index, built));
    drop(slot);
    engine.set_active_tool_state(state_name_for_id(id));
    JasStatus::Ok
}

/// Tell the core the display's physical-pixels-per-DIP.
///
/// ⛔ REFUSED, NOT CLAMPED, on a scale that cannot describe a display. A zero
/// or negative scale would divide every pointer into infinity or mirror it, and
/// a NaN would poison every comparison downstream silently -- the kind of bad
/// input that is far better named at the boundary than debugged at the tool.
///
/// # Safety
/// `e` must be NULL or a pointer from `jas_engine_new` that is still live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_set_dpi_scale(e: *mut JasEngine, scale: f64) -> JasStatus {
    let Some(engine) = (unsafe { e.as_ref() }) else { return JasStatus::NullHandle };
    if !(scale.is_finite() && scale > 0.0) { return JasStatus::BadParamType; }
    engine.set_dpi_scale(scale);
    JasStatus::Ok
}

/// ⭐ THE POINTER ITSELF. `x` and `y` are PHYSICAL pixels -- what the shell's
/// swapchain is sized in -- and this function converts them to DIPs before the
/// tool sees them. `mods` is a bitmask of `MOD_*`.
///
/// The tool it drives emits document ops through the channel that already
/// exists; nothing about a marquee, a hit test or a tool mode crosses the
/// boundary. That is the whole point (BL1).
///
/// # Safety
/// `e` must be NULL or a pointer from `jas_engine_new` that is still live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_pointer_event(
    e: *mut JasEngine,
    kind: u32,
    x: f64,
    y: f64,
    mods: u32,
) -> JasStatus {
    // Recorded BEFORE the null check: a refused call still crossed, and at
    // mousemove rates the refused ones are exactly the ones worth counting.
    crate::ffi_instr::record(crate::ffi_instr::Crossing::PointerEvent, 0, 0);
    let Some(engine) = (unsafe { e.as_ref() }) else { return JasStatus::NullHandle };
    if !matches!(kind, KIND_PRESS | KIND_MOVE | KIND_RELEASE) {
        return JasStatus::UnknownVerb;
    }

    // PHYSICAL -> DIP, here, on this side of the boundary.
    let s = engine.dpi_scale();
    let (dx, dy) = (x / s, y / s);

    let shift = mods & MOD_SHIFT != 0;
    let alt = mods & MOD_ALT != 0;
    let dragging = mods & MOD_DRAGGING != 0;

    // The Align panel's key-object intercept (ALIGN.md §Key-object
    // designation), in the web canvas's order (`workspace/app.rs`, mousedown):
    // while Align To is the key object, a plain press designates, re-designates
    // or clears the key and the tool never sees it. Shift and Alt presses are
    // selection modifiers and go to the tool. Until 2026-10-18 the engine had
    // no intercept, so key-object mode could never get a key and every Align
    // and Distribute button stayed disabled on Windows.
    if kind == KIND_PRESS && !shift && !alt {
        let consumed = engine.with_store_mut(|store| {
            if store.get_panel(ALIGN_PANEL, "align_to").as_str() != Some("key_object") {
                return false;
            }
            let current = align_host::path_value(store.get_panel(ALIGN_PANEL, "key_object_path"));
            let key = engine.with_model(|m| align_host::designate_key_object(m, current.as_ref(), dx, dy));
            store.set_panel(ALIGN_PANEL, "key_object_path", align_host::path_store_value(key.as_ref()));
            true
        });
        if consumed {
            return JasStatus::Ok;
        }
    }

    // The tool runs on its own store, so hand it the Artboards panel's facts
    // (selection, anchor) before every event, as the key route does for a
    // claimed key: the Artboard tool's handles, click and move read them.
    let facts = engine.artboard_facts();
    let mut slot = engine.tool_slot();
    if slot.is_none() {
        // Default to the first tool rather than refusing: a shell that never
        // called `jas_set_tool` still gets the selection tool, which is what
        // every drawing app opens with.
        let Some(mut built) = build_tool(TOOL_IDS[0]) else { return JasStatus::MissingTarget };
        // ⚠️ A SURVIVING MUTANT, RECORDED (W5-0): deleting this line reds no
        // arm, because selection's `on_enter` only writes `mode: 'idle'`, its
        // own declared default. It stays so the implicit tool is entered the
        // same way a picked one is; it gains a witness when TOOL_IDS[0] does.
        engine.with_model_mut(|m| built.activate(m));
        *slot = Some((0, built));
    }
    let (_, tool) = slot.as_mut().expect("just built");
    tool.set_document_facts(&facts);

    engine.with_model_mut(|m| match kind {
        KIND_PRESS => tool.on_press(m, dx, dy, shift, alt),
        KIND_MOVE => tool.on_move(m, dx, dy, shift, alt, dragging),
        _ => tool.on_release(m, dx, dy, shift, alt),
    });
    // A dialog the tool opened (Scale's Alt-click) moves to the engine's store,
    // where `jas_dialog_plan` reads it (flask STATUS §285); the panel writes it
    // queued (the Artboard tool's click selection) go there too.
    let opened = tool.take_opened_dialog();
    let writes = tool.drain_pending_panel_writes();
    drop(slot);
    crate::ffi::apply_tool_panel_writes(engine, writes);
    // A key that the tool's event deselected is cleared, as the web canvas
    // clears it after every press and release (ALIGN.md §Panel state).
    if kind != KIND_MOVE {
        engine.with_store_mut(|store| {
            let key = align_host::path_value(store.get_panel(ALIGN_PANEL, "key_object_path"));
            if key.is_some() {
                let kept = engine.with_model(|m| align_host::key_object_after_selection(m.document(), key.clone()));
                if kept != key {
                    store.set_panel(ALIGN_PANEL, "key_object_path", align_host::path_store_value(kept.as_ref()));
                }
            }
        });
    }
    if let Some((id, params)) = opened {
        crate::ffi::open_tool_dialog(engine, &id, &params);
    }
    JasStatus::Ok
}

/// One key press (W5-3a). ⛔ NOT EXPORTED since 2026-10-16 (#465): a shell sends
/// a key as `jas_dispatch_action({"key"})`, which calls this and replies; this
/// is the engine's key ORDER, kept in one place. `code` is a [`KEY_ESCAPE`]-style named key or the
/// Unicode scalar of the character the key produced; `mods` is `MOD_SHIFT |
/// MOD_ALT | MOD_CMD`. The order is the web keyboard path's
/// (`workspace/keyboard.rs`):
///   1. Escape, Enter, Delete and Backspace go to the ACTIVE TOOL's
///      `on_key_event` (Escape cancels a marquee, Enter commits the pen).
///   2. A character is resolved against `workspace/shortcuts.yaml` IN THE
///      CORE (`resolve_key`). Without `MOD_CMD`, a `select_tool` result
///      switches the tool as [`jas_set_tool`] does. With `MOD_CMD`, only
///      `undo` and `redo` act here (W5-3c); the clipboard chords are actions
///      `ffi::dispatch_key` runs, and other command chords stay the menu's.
/// Returns `Ok` when the key was handled and `UnknownVerb` when nothing
/// handled it, so the shell can let the key fall through to its own default.
///
/// # Safety
/// `e` must be NULL or a pointer from `jas_engine_new` that is still live.
pub(crate) unsafe fn jas_key_event(e: *mut JasEngine, code: u32, mods: u32) -> JasStatus {
    let Some(engine) = (unsafe { e.as_ref() }) else { return JasStatus::NullHandle };
    let km = crate::tools::tool::KeyMods {
        shift: mods & MOD_SHIFT != 0,
        ctrl: mods & MOD_CMD != 0,
        alt: mods & MOD_ALT != 0,
        meta: false,
    };
    // The key's NAME, as `route_key` takes it: a named key or the character.
    let name: String = match code {
        KEY_ESCAPE => "Escape".into(),
        KEY_ENTER => "Enter".into(),
        KEY_DELETE => "Delete".into(),
        KEY_BACKSPACE => "Backspace".into(),
        KEY_ARROW_UP => "ArrowUp".into(),
        KEY_ARROW_DOWN => "ArrowDown".into(),
        KEY_ARROW_LEFT => "ArrowLeft".into(),
        KEY_ARROW_RIGHT => "ArrowRight".into(),
        KEY_HOME => "Home".into(),
        KEY_END => "End".into(),
        KEY_TAB => "Tab".into(),
        _ => match char::from_u32(code) {
            Some(ch) => ch.to_string(),
            None => return JasStatus::BadParamType,
        },
    };
    use crate::workspace::resolve_key::{route_key, KeyRoute};
    // The ORDER is `route_key`'s, shared with the level-1 input-script runner.
    // flask STATUS §277: a YAML tool reports EVERY key handled once it declares
    // `on_keydown`, so its answer cannot mean "fall through": whether the tool
    // CAPTURES the keyboard or CLAIMS the key decides, as on the web.
    let route = {
        let slot = engine.tool_slot();
        route_key(&name, km, |key| {
            slot.as_ref().is_some_and(|(_, t)| t.captures_keyboard() || t.claims_key(key))
        })
    };
    match route {
        KeyRoute::DeleteSelection => delete_selection_key(engine),
        KeyRoute::ToolChar(ch) => {
            let mut slot = engine.tool_slot();
            let Some((_, tool)) = slot.as_mut() else { return JasStatus::UnknownVerb };
            let handled = engine.with_model_mut(|m| tool.on_key_event(m, &ch, km));
            if handled { JasStatus::Ok } else { JasStatus::UnknownVerb }
        }
        KeyRoute::ToolKey(key) => {
            // A claimed Delete reaches a tool that runs on its own store, so
            // hand it the Artboards panel's selection the engine's store holds
            // (the Artboard tool's Delete reads `artboards_panel_selection_ids`).
            if engine.tool_slot().as_ref().is_some_and(|(_, t)| t.claims_key(key)) {
                let facts = engine.artboard_facts();
                if let Some((_, t)) = engine.tool_slot().as_mut() {
                    t.set_document_facts(&facts);
                }
            }
            let mut slot = engine.tool_slot();
            let Some((_, tool)) = slot.as_mut() else { return JasStatus::UnknownVerb };
            let handled = engine.with_model_mut(|m| tool.on_key_event(m, key, km));
            // A dialog the key opened in the tool (the Artboard tool's Delete
            // falling through to an orphaning `delete_selection`) moves to the
            // engine's store, as a pointer event's does.
            let opened = tool.take_opened_dialog();
            drop(slot);
            if let Some((id, params)) = opened {
                crate::ffi::open_tool_dialog(engine, &id, &params);
            }
            if handled { JasStatus::Ok } else { JasStatus::UnknownVerb }
        }
        KeyRoute::Undo => { engine.with_model_mut(|m| m.undo()); JasStatus::Ok }
        KeyRoute::Redo => { engine.with_model_mut(|m| m.redo()); JasStatus::Ok }
        KeyRoute::SelectTool(id) => match selectable_index(&id) {
            Some(index) => unsafe { jas_set_tool(e, index) },
            None => JasStatus::UnknownVerb,
        },
        // A clipboard chord is an ACTION that needs the shell's clipboard:
        // `ffi::dispatch_key` runs it through `jas_dispatch_action` before
        // calling here, so this arm is the not-reached answer.
        KeyRoute::Clipboard(_) => JasStatus::UnknownVerb,
        KeyRoute::Unhandled => JasStatus::UnknownVerb,
        KeyRoute::BadKey => JasStatus::BadParamType,
    }
}

/// The Delete key's `delete_selection`, the web keyboard's reference-aware
/// form: with nothing selected nothing changes (`UnknownVerb`, so the shell may
/// let the key fall through). When deleting would ORPHAN a live instance, the
/// web asks first (`delete_orphan_confirm`); the engine cannot open that
/// dialog from a key yet, so it deletes NOTHING and names the refusal in
/// `jas_last_error` rather than delete without asking. Otherwise ONE undo step.
fn delete_selection_key(engine: &JasEngine) -> JasStatus {
    use crate::workspace::menu_native::{delete_selection, DeleteOutcome};
    match engine.with_model_mut(delete_selection) {
        DeleteOutcome::NothingSelected => JasStatus::UnknownVerb,
        DeleteOutcome::WouldOrphan(orphans) => {
            engine.set_last_error(format!(
                r#"{{"key":"Delete","refused":"delete_orphan_confirm","orphans":{orphans}}}"#
            ));
            JasStatus::UnknownVerb
        }
        DeleteOutcome::Deleted => JasStatus::Ok,
    }
}

/// How many elements the session currently has selected.
///
/// ⭐ IT EXISTS SO A RECEIPT CAN SAY A NUMBER. A photograph of a marquee proves
/// the overlay drew; it does not prove the pointer SELECTED anything, and those
/// are the two halves of node 5. With this the shell's own title bar carries the
/// count, so the picture and the claim are checked by the same run.
///
/// `usize::MAX` for a null engine -- a count cannot express a refusal, and
/// returning 0 there would read as "nothing selected", which is a lie about a
/// session that does not exist.
///
/// # Safety
/// `e` must be NULL or a pointer from `jas_engine_new` that is still live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_selection_len(e: *mut JasEngine) -> usize {
    let Some(engine) = (unsafe { e.as_ref() }) else { return usize::MAX };
    engine.with_document(|d| d.selection.len())
}

/// ⭐ ONE FRAME: the document, then the active tool's overlay on top of it.
///
/// ⛔ PAINTER-GENERIC ON PURPOSE, and that is what makes it testable. The D2D
/// export below (`ffi_paint::jas_paint_frame`) needs a GPU surface and cannot
/// run in a unit test; this function needs only a `Painter`, so a
/// `RecordingPainter` can read back exactly what a frame contains and assert
/// that the overlay is in it and lands AFTER the document.
///
/// The overlay is skipped, not faked, when no tool has been selected -- a
/// frame with no tool is a document, which is what `jas_paint_document` has
/// always drawn.
/// THE PASTEBOARD: the colour a native frame clears to, under everything,
/// in screen space -- the web canvas's layer 1 (`app_state.rs`), which fills
/// the viewport with the theme's `pane_bg` before the view transform, so a
/// white page shows against it. The active appearance's colour wins over the
/// base's. `None` when the workspace states none (the caller keeps its clear).
pub(crate) fn pasteboard_color() -> Option<crate::geometry::element::Color> {
    crate::interpreter::workspace::Workspace::load().and_then(|ws| pasteboard_color_of(ws.theme()))
}

/// [`pasteboard_color`] of a theme value (`workspace.json`'s `theme`).
pub(crate) fn pasteboard_color_of(theme: &serde_json::Value) -> Option<crate::geometry::element::Color> {
    let active = theme.get("active").and_then(serde_json::Value::as_str);
    let own = active.and_then(|a| theme.get("appearances")?.get(a)?.get("colors")?.get("pane_bg"));
    let base = || theme.get("base")?.get("colors")?.get("pane_bg");
    own.or_else(base)?.as_str().and_then(crate::geometry::element::Color::from_hex)
}

pub(crate) fn emit_frame(engine: &JasEngine, p: &mut dyn crate::painter::Painter) {
    // THE VIEW, as the web canvas applies it (`app_state.rs`:
    // `translate(view_offset) . scale(zoom)` around `render::render`): the
    // document and the selection draw under it, and the tool's overlay after
    // the pop, because a tool's state is in viewport pixels already. Every tool
    // converts the pointer through this same view, so without it a pan moved
    // the hit mapping and not the picture (the 10-20 feel sitting, finding 1).
    // The identity view pushes nothing, so a frame at it is byte-identical to
    // what it was.
    let (z, ox, oy) = engine.with_model(|m| (m.zoom_level, m.view_offset_x, m.view_offset_y));
    let viewed = (z, ox, oy) != (1.0, 0.0, 0.0) && z > 0.0;
    if viewed {
        p.push_state(crate::painter::Transform { a: z, b: 0.0, c: 0.0, d: z, e: ox, f: oy });
    }
    // The artboards, the web canvas's layers 2 and 5 (`render::render`): each
    // fill under the document, each 1 px border above it so no element covers
    // the edge (the sitting, finding 11). The pasteboard behind them is the
    // shell's, in screen space, as it is the web canvas's.
    engine.with_document(|doc| {
        for ab in &doc.artboards {
            let fill = match &ab.fill {
                // A Transparent artboard shows white (`artboard_fill_css`).
                crate::document::artboard::ArtboardFill::Transparent => Some(crate::geometry::element::Color::rgb(1.0, 1.0, 1.0)),
                crate::document::artboard::ArtboardFill::Color(hex) => crate::geometry::element::Color::from_hex(hex),
            };
            if let Some(c) = fill {
                p.fill_rect(artboard_rect(ab), &crate::painter::Brush::Solid(c), 1.0);
            }
        }
        crate::document::paint::emit_document(p, doc, crate::geometry::live::DEFAULT_PRECISION);
        let border = crate::painter::StrokeStyle {
            width: 1.0,
            cap: crate::geometry::element::LineCap::Butt,
            join: crate::geometry::element::LineJoin::Miter,
            miter: 10.0,
            dash: Vec::new(),
        };
        // `ARTBOARD_BORDER_COLOR`, rgb(48,48,48).
        let ink = crate::painter::Brush::Solid(crate::geometry::element::Color::rgb(48.0 / 255.0, 48.0 / 255.0, 48.0 / 255.0));
        for ab in &doc.artboards {
            p.stroke_rect(artboard_rect(ab), &ink, &border, 1.0);
        }
    });
    // The SELECTION HIGHLIGHT, between the document and the tool's overlay --
    // the web canvas's order. Drawn whether or not a tool is set (a selection
    // made from the menu shows too), and it draws nothing when nothing is
    // selected, so an unselected frame is still exactly a document.
    engine.with_document(|doc| {
        let mut ctx = crate::painter::overlay_ctx::OverlayCtx::new(p);
        crate::painter::selection_overlay::draw_selection_overlays(&mut ctx, doc);
        ctx.finish();
    });
    if viewed {
        p.pop_state();
    }
    let mut slot = engine.tool_slot();
    if let Some((_, tool)) = slot.as_mut() {
        let mut ctx = crate::painter::overlay_ctx::OverlayCtx::new(p);
        engine.with_model(|m| tool.draw_overlay(m, &mut ctx));
        ctx.finish();
    }
}

fn artboard_rect(ab: &crate::document::artboard::Artboard) -> crate::painter::Rect {
    crate::painter::Rect { x: ab.x, y: ab.y, w: ab.width, h: ab.height }
}

/// Build a `YamlTool` from the embedded workspace bundle -- the same path the
/// running app uses.
fn build_tool(id: &str) -> Option<Box<dyn CanvasTool>> {
    if id == "type" {
        return Some(Box::new(crate::tools::type_tool::TypeTool::new()));
    }
    let ws = crate::interpreter::workspace::Workspace::load()?;
    let spec = ws.data().get("tools")?.get(id)?;
    Some(Box::new(crate::tools::yaml_tool::YamlTool::from_workspace_tool(spec)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// THE PASTEBOARD (flask's ⚠️(1) on #595: the white page was invisible on a
    /// white canvas). The web fills the viewport with the theme's `pane_bg`
    /// before the view (`app_state.rs`, layer 1); the native frame clears to it.
    /// The ACTIVE appearance's colours win over the base's, as a theme reads.
    #[test]
    fn the_pasteboard_is_the_active_appearances_pane_bg_over_the_base() {
        let base = serde_json::json!({"active": "dark", "base": {"colors": {"pane_bg": "#3c3c3c"}},
                                      "appearances": {"dark": {"label": "Dark"}}});
        assert_eq!(pasteboard_color_of(&base), crate::geometry::element::Color::from_hex("#3c3c3c"),
                   "an appearance with no colours reads the base");
        let light = serde_json::json!({"active": "light", "base": {"colors": {"pane_bg": "#3c3c3c"}},
                                       "appearances": {"light": {"colors": {"pane_bg": "#f0f0f0"}}}});
        assert_eq!(pasteboard_color_of(&light), crate::geometry::element::Color::from_hex("#f0f0f0"),
                   "the active appearance's own colour wins");
        assert_eq!(pasteboard_color_of(&serde_json::json!({})), None, "no theme, no colour: the caller keeps its clear");
        assert_eq!(pasteboard_color_of(&serde_json::json!({"base": {"colors": {"pane_bg": "nope"}}})), None,
                   "a colour that does not parse is none, never black");
        // The shipped workspace has one, and it is what the theme file states
        // for its active appearance, read here by the same two keys.
        let ws = crate::interpreter::workspace::Workspace::load().expect("the workspace");
        let t = ws.theme();
        let active = t["active"].as_str().expect("an active appearance");
        let want = t["appearances"][active]["colors"]["pane_bg"].as_str()
            .or_else(|| t["base"]["colors"]["pane_bg"].as_str()).expect("a pane_bg");
        assert_eq!(pasteboard_color(), crate::geometry::element::Color::from_hex(want));
    }
    use crate::document::document::{Document, ElementSelection};
    use crate::geometry::element::{CommonProps, Element, LayerElem, RectElem};
    use crate::ffi::{jas_engine_free, jas_engine_new};

    /// A 100x80 rect at (20,30) in ONE layer, nothing selected.
    fn seed(e: *mut JasEngine) {
        let rect = Element::Rect(RectElem {
            x: 20.0, y: 30.0, width: 100.0, height: 80.0,
            rx: 0.0, ry: 0.0,
            // ⛔ A REAL FILL. A rect with `fill: None, stroke: None` hit-tests
            // exactly the same and paints NOTHING, so the frame arm below saw
            // an empty document and could not tell a working walk from a dead
            // one. It cost me one red to notice.
            fill: Some(crate::geometry::element::Fill::new(
                crate::geometry::element::Color::rgb(0.8, 0.16, 0.16))),
            stroke: None,
            fill_gradient: None, stroke_gradient: None,
            common: CommonProps { name: Some("R".to_string()), ..Default::default() },
        });
        let layer = Element::Layer(LayerElem {
            children: vec![std::rc::Rc::new(rect)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { name: Some("L".to_string()), ..Default::default() },
        });
        unsafe { &*e }.with_model_mut(|m| {
            *m = Model::new(
                Document { layers: vec![layer], selected_layer: 0,
                           selection: Vec::new(), ..Document::default() },
                None,
            );
        });
    }

    /// Two rects side by side: A at (20,30)+100x80, B at (220,30)+100x80.
    fn seed_two(e: *mut JasEngine) {
        let mk = |x: f64, name: &str| Element::Rect(RectElem {
            x, y: 30.0, width: 100.0, height: 80.0,
            rx: 0.0, ry: 0.0,
            fill: Some(crate::geometry::element::Fill::new(
                crate::geometry::element::Color::rgb(0.8, 0.16, 0.16))),
            stroke: None,
            fill_gradient: None, stroke_gradient: None,
            common: CommonProps { name: Some(name.to_string()), ..Default::default() },
        });
        let layer = Element::Layer(LayerElem {
            children: vec![std::rc::Rc::new(mk(20.0, "A")), std::rc::Rc::new(mk(220.0, "B"))],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { name: Some("L".to_string()), ..Default::default() },
        });
        unsafe { &*e }.with_model_mut(|m| {
            *m = Model::new(
                Document { layers: vec![layer], selected_layer: 0,
                           selection: Vec::new(), ..Document::default() },
                None,
            );
        });
    }

    fn selection_len(e: *mut JasEngine) -> usize {
        unsafe { &*e }.with_document(|d| d.selection.len())
    }

    /// ⭐ THE POINTER THAT LANDS. A press outside the rect, a drag across it,
    /// a release — and the SELECTION TOOL, running inside the core, selects
    /// the element. Nothing in the shell knew where the rect was.
    #[test]
    fn a_press_drag_release_through_the_c_abi_selects_the_element() {
        // ⭐ ROW EK: the ONE crate-level counter lock. This test reaches an
        // export, and every export records a crossing on the process-global
        // counters -- so it races `ffi_instr`'s tests unless it takes this.
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        seed(e);
        assert_eq!(selection_len(e), 0, "nothing selected before the gesture");

        unsafe {
            assert_eq!(jas_set_tool(e, 0), JasStatus::Ok, "index 0 is 'selection'");
            assert_eq!(jas_pointer_event(e, KIND_PRESS, 10.0, 20.0, 0), JasStatus::Ok);
            assert_eq!(jas_pointer_event(e, KIND_MOVE, 140.0, 120.0, MOD_DRAGGING),
                       JasStatus::Ok);
            assert_eq!(jas_pointer_event(e, KIND_RELEASE, 140.0, 120.0, 0), JasStatus::Ok);
        }

        assert_eq!(selection_len(e), 1,
                   "the marquee enclosed the rect, so the tool selected it");
        unsafe { jas_engine_free(e) };
    }

    /// ALIGN.md §Key-object designation through the C ABI: in key-object mode
    /// a PLAIN press designates the selected element under it and the tool
    /// never sees it; a SHIFT press goes to the tool (here it toggles B out of
    /// the selection), and the key that left the selection is cleared.
    #[test]
    fn a_plain_press_designates_the_key_and_a_shift_press_that_deselects_it_clears_it() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        seed_two(e);
        let key = || unsafe { &*e }.with_store_mut(|s|
            align_host::path_value(s.get_panel(ALIGN_PANEL, "key_object_path")));
        unsafe {
            assert_eq!(jas_set_tool(e, 0), JasStatus::Ok);
            jas_pointer_event(e, KIND_PRESS, 10.0, 20.0, 0);
            jas_pointer_event(e, KIND_MOVE, 330.0, 120.0, MOD_DRAGGING);
            jas_pointer_event(e, KIND_RELEASE, 330.0, 120.0, 0);
        }
        assert_eq!(selection_len(e), 2, "the marquee selected A and B");
        // Selection mode first: a plain press is the tool's (no key written).
        unsafe {
            jas_pointer_event(e, KIND_PRESS, 250.0, 60.0, 0);
            jas_pointer_event(e, KIND_RELEASE, 250.0, 60.0, 0);
        }
        assert_eq!(key(), None, "outside key-object mode nothing is designated");
        // A shell's open seeds the panel's scope; a write to an unseeded
        // scope is dropped by the store.
        unsafe { &*e }.with_store_mut(|s| {
            s.init_panel(ALIGN_PANEL, Default::default());
            s.set_panel(ALIGN_PANEL, "align_to", serde_json::json!("key_object"));
        });
        // Re-select both (the press above may have narrowed the selection).
        unsafe { &*e }.with_model_mut(|m| {
            let mut d = m.document().clone();
            d.selection = vec![ElementSelection::all(vec![0, 0]), ElementSelection::all(vec![0, 1])];
            m.set_document_for_test(d);
        });
        unsafe {
            assert_eq!(jas_pointer_event(e, KIND_PRESS, 250.0, 60.0, 0), JasStatus::Ok);
        }
        assert_eq!(key(), Some(vec![0, 1]), "a plain press on B designates B");
        assert_eq!(selection_len(e), 2, "the designating press never reached the tool");
        unsafe {
            jas_pointer_event(e, KIND_RELEASE, 250.0, 60.0, 0);
        }
        assert_eq!(key(), Some(vec![0, 1]), "the release leaves a still-selected key alone");
        unsafe {
            jas_pointer_event(e, KIND_PRESS, 250.0, 60.0, MOD_SHIFT);
            jas_pointer_event(e, KIND_RELEASE, 250.0, 60.0, MOD_SHIFT);
        }
        assert_eq!(selection_len(e), 1, "the shift press reached the tool, which toggled B off");
        assert_eq!(key(), None, "B left the selection, so the key is cleared");
        unsafe { jas_engine_free(e) };
    }

    fn element_count(e: *mut JasEngine) -> usize {
        fn walk(el: &Element) -> usize {
            match el {
                Element::Layer(l) => l.children.iter().map(|c| walk(c)).sum(),
                Element::Group(g) => g.children.iter().map(|c| walk(c)).sum(),
                _ => 1,
            }
        }
        unsafe { &*e }.with_document(|d| d.layers.iter().map(|l| walk(l)).sum())
    }

    fn tool_index(id: &str) -> usize {
        TOOL_IDS.iter().position(|t| *t == id).expect("id is in TOOL_IDS")
    }

    /// ⛔ W5-0: SWITCHING TOOLS RUNS THE OLD TOOL'S `on_leave`. The pen's
    /// `on_leave` is what commits an in-progress path, so a switch that only
    /// reassigns the slot drops the path the person was drawing. Selection is
    /// the only tool the shell selects today, which is why this was invisible.
    #[test]
    fn switching_away_from_the_pen_commits_its_path() {
        let _counters = crate::ffi_instr::test_lock::lock();
        crate::interpreter::anchor_buffers::clear("pen");
        let e = jas_engine_new();
        seed(e);
        let before = element_count(e);
        unsafe {
            assert_eq!(jas_set_tool(e, tool_index("pen")), JasStatus::Ok);
            for x in [200.0, 260.0] {
                assert_eq!(jas_pointer_event(e, KIND_PRESS, x, 200.0, 0), JasStatus::Ok);
                assert_eq!(jas_pointer_event(e, KIND_RELEASE, x, 200.0, 0), JasStatus::Ok);
            }
            assert_eq!(element_count(e), before, "two clicks place anchors and add nothing yet");
            assert_eq!(jas_set_tool(e, tool_index("rect")), JasStatus::Ok);
        }
        assert_eq!(element_count(e), before + 1,
                   "leaving the pen commits its two-anchor path as one element");
        assert_eq!(crate::interpreter::anchor_buffers::length("pen"), 0,
                   "and its anchor buffer is cleared");
        unsafe { jas_engine_free(e) };
    }

    /// ⛔ W5-0: SELECTING A TOOL RUNS ITS `on_enter`. The pen's anchor buffer
    /// is thread-local, so anchors left by anything else are still there when
    /// the pen is picked; its `on_enter` is what clears them. A stale buffer
    /// would turn the person's first click into the third anchor of a path
    /// they never started.
    #[test]
    fn selecting_the_pen_runs_its_on_enter() {
        let _counters = crate::ffi_instr::test_lock::lock();
        crate::interpreter::anchor_buffers::clear("pen");
        for x in [1.0, 2.0, 3.0] { crate::interpreter::anchor_buffers::push("pen", x, x); }
        assert_eq!(crate::interpreter::anchor_buffers::length("pen"), 3, "the control: stale anchors are present");
        let e = jas_engine_new();
        unsafe { assert_eq!(jas_set_tool(e, tool_index("pen")), JasStatus::Ok) };
        assert_eq!(crate::interpreter::anchor_buffers::length("pen"), 0,
                   "the pen's on_enter cleared the stale buffer");
        unsafe { jas_engine_free(e) };
    }

    /// ⛔ W5-1: THE SHELL CAN SELECT EVERY TOOL THE ENGINE CAN BUILD, AND THE
    /// INDEXES IT ALREADY USES DO NOT MOVE. The tool list is ABI (an index is
    /// what crosses), so it grows by APPENDING: the first nine ids are pinned
    /// here by position, deliberately, because a reorder would silently repoint
    /// a shell that sends `6` for the pen. The SET is derived from the
    /// workspace bundle, never typed, so a tool added to `workspace/tools/`
    /// without a row here reds.
    #[test]
    fn the_tool_list_is_every_workspace_tool_and_appends_only() {
        let ws = crate::interpreter::workspace::Workspace::load().expect("the workspace bundle");
        let mut want: Vec<String> = ws.data()["tools"].as_object().expect("tools").keys().cloned().collect();
        for id in NATIVE_TOOL_IDS {
            assert!(!want.iter().any(|w| w == id), "`{id}` is declared native but the workspace lists it");
            want.push(id.to_string());
        }
        want.sort();
        let mut got: Vec<String> = TOOL_IDS.iter().map(|s| s.to_string()).collect();
        got.sort();
        assert!(want.len() >= 20, "the workspace's tool set is not vacuous: {}", want.len());
        assert_eq!(got, want, "TOOL_IDS is exactly the workspace's tools and the declared native ones");
        assert_eq!(TOOL_IDS.len(), want.len(), "no id twice");
        assert_eq!(&TOOL_IDS[..9],
                   &["selection", "interior_selection", "partial_selection", "rect", "ellipse", "line", "pen", "pencil", "zoom"],
                   "the nine indexes a shell may already send keep their meaning");
        for (i, id) in TOOL_IDS.iter().enumerate() {
            assert!(build_tool(id).is_some(), "index {i} ({id}) builds in this engine");
        }
    }

    /// ⛔ THE REFUSAL LANE, BOTH SHAPES. A null engine and an unknown kind are
    /// REFUSED BY NAME, not absorbed — the fail-closed doctrine this seat has
    /// applied to every other crossing.
    #[test]
    fn a_pointer_the_boundary_cannot_honour_refuses_by_name() {
        // ⭐ ROW EK: the ONE crate-level counter lock. This test reaches an
        // export, and every export records a crossing on the process-global
        // counters -- so it races `ffi_instr`'s tests unless it takes this.
        let _counters = crate::ffi_instr::test_lock::lock();
        unsafe {
            assert_eq!(jas_pointer_event(std::ptr::null_mut(), KIND_PRESS, 0.0, 0.0, 0),
                       JasStatus::NullHandle, "a null engine must not fault");
        }
        let e = jas_engine_new();
        unsafe {
            assert_eq!(jas_pointer_event(e, 99, 0.0, 0.0, 0), JasStatus::UnknownVerb,
                       "an unknown pointer kind is refused, not treated as a press");
            assert_eq!(jas_set_tool(e, TOOL_IDS.len()), JasStatus::MissingTarget,
                       "an out-of-range tool index is refused, not clamped");

            // ⛔ AND A SCALE THAT CANNOT DESCRIBE A DISPLAY. Zero divides every
            // pointer into infinity, a negative mirrors it, and a NaN poisons
            // every comparison downstream in silence. Named at the boundary,
            // where the shell can still see which call it was.
            for bad in [0.0, -1.5, f64::NAN, f64::INFINITY] {
                assert_eq!(jas_set_dpi_scale(e, bad), JasStatus::BadParamType,
                           "scale {bad} must be refused");
            }
            assert_eq!(jas_set_dpi_scale(e, 1.25), JasStatus::Ok, "and a real one accepted");
            jas_engine_free(e);
        }
    }

    /// ⭐ THE DIP TRANSFORM IS INSIDE THE CORE, AT 100 % AND AT 150 %.
    ///
    /// The shell sends PHYSICAL pixels, because that is what its swapchain is
    /// sized in. At 150 % a physical (15,30) is DIP (10,20), and the gesture
    /// must reach the tool as the SAME document rectangle that physical
    /// (10,20) reaches at 100 %. If the shell were left to divide, every
    /// display-scale bug would be a C# bug -- exactly what BL1 forbids.
    ///
    /// The seeded rect spans DIP x 20..120, y 30..110, and this tool selects on
    /// INTERSECTION rather than enclosure (measured, not assumed: my first
    /// control asserted enclosure and the tool selected anyway).
    #[test]
    fn the_same_document_point_is_reached_at_100_and_150_percent() {
        // ⭐ ROW EK: the ONE crate-level counter lock. This test reaches an
        // export, and every export records a crossing on the process-global
        // counters -- so it races `ffi_instr`'s tests unless it takes this.
        let _counters = crate::ffi_instr::test_lock::lock();
        fn gesture(scale: f64, x0: f64, y0: f64, x1: f64, y1: f64) -> usize {
            let e = jas_engine_new();
            seed(e);
            unsafe {
                assert_eq!(jas_set_dpi_scale(e, scale), JasStatus::Ok);
                jas_set_tool(e, 0);
                jas_pointer_event(e, KIND_PRESS, x0, y0, 0);
                jas_pointer_event(e, KIND_MOVE, x1, y1, MOD_DRAGGING);
                jas_pointer_event(e, KIND_RELEASE, x1, y1, 0);
            }
            let n = selection_len(e);
            unsafe { jas_engine_free(e) };
            n
        }

        // The same DIP rectangle (10,20)-(140,120), delivered at both scales.
        assert_eq!(gesture(1.0, 10.0, 20.0, 140.0, 120.0), 1, "100 %: selects");
        assert_eq!(gesture(1.5, 15.0, 30.0, 210.0, 180.0), 1,
                   "150 %: the same DIP rectangle in scaled physical px selects too");

        // ⛔ THE DISCRIMINATOR: ONE PAIR OF PHYSICAL NUMBERS, OPPOSITE OUTCOMES.
        // (150,150)-(210,210) is DIP (100,100)-(140,140) at 150 %, which clips
        // the rect's lower-right corner -- and DIP (150,150)-(210,210) at
        // 100 %, which is past its right edge entirely. Without this the two
        // arms above would pass on a build that ignored the scale completely.
        assert_eq!(gesture(1.5, 150.0, 150.0, 210.0, 210.0), 1,
                   "at 150 % this reaches the rect");
        assert_eq!(gesture(1.0, 150.0, 150.0, 210.0, 210.0), 0,
                   "the SAME physical numbers at 100 % miss it -- so the scale                     is genuinely read, not merely accepted");
    }

    /// ⭐ THE MODIFIER BITS REACH THE TOOL. `selection.yaml` branches on
    /// `event.modifiers.shift` to make a click ADDITIVE, so a shift-click on a
    /// second element keeps the first selected and a plain click replaces it.
    /// Both directions asserted: one alone would pass on a build that ignored
    /// the bitmask entirely.
    ///
    /// ⚠️ `MOD_DRAGGING` HAS NO ARM HERE, AND THAT IS MEASURED, NOT LAZY. No
    /// workspace tool reads `event.dragging` -- it is read only by `TypeTool`
    /// and `TypeOnPathTool`, hand-written tools that `TOOL_IDS` does not yet
    /// carry -- so a mutant that hard-codes `dragging: false` survives every
    /// arm in this file. The flag is forwarded because the trait takes it and
    /// those two tools will need it the moment they are selectable; it is not
    /// yet observable through this ABI, and pretending otherwise with a
    /// passing assertion would be worse than saying so.
    #[test]
    fn the_shift_bit_reaches_the_tool_and_changes_what_it_does() {
        // ⭐ ROW EK: the ONE crate-level counter lock. This test reaches an
        // export, and every export records a crossing on the process-global
        // counters -- so it races `ffi_instr`'s tests unless it takes this.
        let _counters = crate::ffi_instr::test_lock::lock();
        fn click_two(mods_on_second: u32) -> usize {
            let e = jas_engine_new();
            seed_two(e);
            unsafe {
                jas_set_tool(e, 0);
                // First element: a plain click at (40,50), inside rect A.
                jas_pointer_event(e, KIND_PRESS, 40.0, 50.0, 0);
                jas_pointer_event(e, KIND_RELEASE, 40.0, 50.0, 0);
                // Second element: a click at (240,50), inside rect B.
                jas_pointer_event(e, KIND_PRESS, 240.0, 50.0, mods_on_second);
                jas_pointer_event(e, KIND_RELEASE, 240.0, 50.0, mods_on_second);
            }
            let n = selection_len(e);
            unsafe { jas_engine_free(e) };
            n
        }
        assert_eq!(click_two(0), 1, "a plain second click REPLACES the selection");
        assert_eq!(click_two(MOD_SHIFT), 2,
                   "a shift second click ADDS to it -- so the bit crossed");
    }

    /// ⭐ AND THE ALT BIT, WHICH DOES SOMETHING ELSE ENTIRELY: `selection.yaml`
    /// makes an alt-drag DUPLICATE the dragged element, so the layer gains a
    /// child. Without this arm a build that read the alt bit off the SHIFT flag
    /// passed everything -- a mutant that did exactly that survived until this
    /// test existed.
    #[test]
    fn the_alt_bit_reaches_the_tool_as_a_different_verb() {
        // ⭐ ROW EK: the ONE crate-level counter lock. This test reaches an
        // export, and every export records a crossing on the process-global
        // counters -- so it races `ffi_instr`'s tests unless it takes this.
        let _counters = crate::ffi_instr::test_lock::lock();
        fn drag_from_inside(mods: u32) -> usize {
            let e = jas_engine_new();
            seed(e);
            unsafe {
                jas_set_tool(e, 0);
                jas_pointer_event(e, KIND_PRESS, 40.0, 50.0, 0);
                jas_pointer_event(e, KIND_MOVE, 70.0, 80.0, mods | MOD_DRAGGING);
                jas_pointer_event(e, KIND_RELEASE, 70.0, 80.0, mods);
            }
            let n = unsafe { &*e }.with_document(|d| match &d.layers[0] {
                Element::Layer(l) => l.children.len(),
                _ => 0,
            });
            unsafe { jas_engine_free(e) };
            n
        }
        assert_eq!(drag_from_inside(0), 1, "a plain drag MOVES the one element");
        assert_eq!(drag_from_inside(MOD_ALT), 2,
                   "an alt-drag DUPLICATES it -- so the alt bit crossed, and                     crossed as alt rather than as shift");
    }

    /// ⭐ A FRAME CARRIES THE OVERLAY, AND CARRIES IT ON TOP.
    ///
    /// This is what makes a live selection PHOTOGRAPHABLE: `jas_paint_document`
    /// draws the document alone, so a selected element looked exactly like an
    /// unselected one. Asserted through a `RecordingPainter` rather than a GPU
    /// surface, which is why the law is testable at all.
    #[test]
    fn a_frame_draws_the_document_then_the_overlay_on_top() {
        // ⭐ ROW EK: the ONE crate-level counter lock. This test reaches an
        // export, and every export records a crossing on the process-global
        // counters -- so it races `ffi_instr`'s tests unless it takes this.
        let _counters = crate::ffi_instr::test_lock::lock();
        use crate::painter::recording::RecordingPainter;

        let e = jas_engine_new();
        seed(e);

        // No tool yet: a frame is exactly a document.
        let mut bare = RecordingPainter::new();
        emit_frame(unsafe { &*e }, &mut bare);
        let doc_only = bare.commands().len();
        assert!(doc_only > 0, "the seeded rect must draw");

        // Now a marquee is in flight.
        unsafe {
            jas_set_tool(e, 0);
            jas_pointer_event(e, KIND_PRESS, 10.0, 20.0, 0);
            jas_pointer_event(e, KIND_MOVE, 140.0, 120.0, MOD_DRAGGING);
        }
        let mut framed = RecordingPainter::new();
        emit_frame(unsafe { &*e }, &mut framed);
        let cmds = framed.commands().to_vec();

        assert!(cmds.len() > doc_only,
                "the frame must carry MORE than the document: {} vs {}",
                cmds.len(), doc_only);
        // ⛔ AND ON TOP, NOT UNDERNEATH. An overlay painted first is an overlay
        // the document covers -- a frame that looks right in a display list and
        // wrong on a screen.
        assert_eq!(&cmds[..doc_only], &bare.commands()[..doc_only],
                   "the document half is unchanged and comes FIRST");
        unsafe { jas_engine_free(e) };
    }

    /// ⭐ THE TYPE TOOL TYPES. The 10-20 feel sitting, finding 3: all ten of
    /// his clicks on the Type button answered `unchanged`, because no shell
    /// tool answered `type`, so he could not place a caret or type a word.
    /// Through the exports a shell calls: select it, click empty canvas, type
    /// two keys, and the document holds a text that says what was typed.
    #[test]
    fn the_type_tool_places_a_text_and_takes_the_keys_typed() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        seed(e);
        let texts = |e: *mut JasEngine| -> Vec<String> {
            unsafe { &*e }.with_model(|m| {
                fn walk(el: &crate::geometry::element::Element, out: &mut Vec<String>) {
                    if let crate::geometry::element::Element::Text(t) = el { out.push(t.content()); }
                    for c in el.children().unwrap_or(&[]) { walk(c, out); }
                }
                let mut out = vec![];
                for l in &m.document().layers { walk(l, &mut out); }
                out
            })
        };
        assert!(texts(e).is_empty(), "control: the seed holds no text");
        let ty = TOOL_IDS.iter().position(|t| *t == "type").expect("the Type tool is a shell tool");
        assert_eq!(unsafe { jas_set_tool(e, ty) }, JasStatus::Ok, "the Type tool builds in this engine");
        unsafe {
            // Empty canvas, clear of the seeded rect at (20,30)+100x80.
            jas_pointer_event(e, KIND_PRESS, 300.0, 300.0, 0);
            jas_pointer_event(e, KIND_RELEASE, 300.0, 300.0, 0);
        }
        // The route a shell's `{"key": …}` ends in (`ffi::dispatch_key`).
        for k in ['H', 'i'] {
            assert_eq!(unsafe { jas_key_event(e, k as u32, 0) }, JasStatus::Ok, "the key {k} reached the tool");
        }
        assert_eq!(texts(e), vec!["Hi".to_string()], "one text, holding what was typed");
        // The caret keys (#596's named gaps): Left, Home and End move the
        // caret the next key types at.
        let typed = |e: *mut JasEngine, key: u32, ch: char| unsafe {
            assert_eq!(jas_key_event(e, key, 0), JasStatus::Ok, "the caret key {key:#x} reached the tool");
            assert_eq!(jas_key_event(e, ch as u32, 0), JasStatus::Ok);
        };
        typed(e, KEY_ARROW_LEFT, 'X');
        assert_eq!(texts(e), vec!["HXi".to_string()], "Left moved the caret back one");
        typed(e, KEY_HOME, 'A');
        assert_eq!(texts(e), vec!["AHXi".to_string()], "Home moved it to the start");
        typed(e, KEY_END, 'Z');
        assert_eq!(texts(e), vec!["AHXiZ".to_string()], "End moved it to the end");
        typed(e, KEY_ARROW_RIGHT, 'Y');
        assert_eq!(texts(e), vec!["AHXiZY".to_string()], "Right at the end stays at the end");
        unsafe { jas_engine_free(e) };
    }

    /// ⭐ THE FRAME DRAWS THE VIEW. The 10-20 feel sitting, findings 1 and 11:
    /// a Hand drag moved the pointer's hit mapping and not the picture, and
    /// zoom and fit changed nothing he could see, because this frame drew in
    /// document space while every tool converts the pointer through the view
    /// (`yaml_tool::pointer_event_payload`). The web canvas's law
    /// (`app_state.rs`, `translate(view_offset) . scale(zoom)` around
    /// `render::render`, restored before the tool overlay): the document and
    /// the selection draw under the view; the tool's overlay draws after the
    /// pop, in viewport pixels, because a tool's state is already in them.
    #[test]
    fn a_frame_draws_the_document_and_selection_under_the_view_and_the_overlay_outside_it() {
        let _counters = crate::ffi_instr::test_lock::lock();
        use crate::painter::recording::{Command, RecordingPainter};

        let e = jas_engine_new();
        seed(e);
        // The identity view pushes nothing: a frame is exactly what it was, so
        // no baseline frozen at the identity view can move.
        let mut identity = RecordingPainter::new();
        emit_frame(unsafe { &*e }, &mut identity);
        assert!(!identity.commands().iter().any(|c| matches!(c, Command::PushState { .. })),
                "the seeded rect draws no state of its own, so a push here is the view's");

        // The sitting's own pan, (+32, -12) DIPs, at a zoom that is not 1.
        unsafe { &*e }.with_model_mut(|m| {
            m.view_offset_x = 32.0;
            m.view_offset_y = -12.0;
            m.zoom_level = 1.5;
        });
        unsafe {
            jas_set_tool(e, 0);
            jas_pointer_event(e, KIND_PRESS, 10.0, 20.0, 0);
            jas_pointer_event(e, KIND_MOVE, 140.0, 120.0, MOD_DRAGGING);
        }
        let mut framed = RecordingPainter::new();
        emit_frame(unsafe { &*e }, &mut framed);
        let cmds = framed.commands();
        let Some(Command::PushState { transform: t }) = cmds.first() else {
            panic!("the frame must open with the view: {:?}", cmds.first());
        };
        assert_eq!((t.a, t.b, t.c, t.d, t.e, t.f), (1.5, 0.0, 0.0, 1.5, 32.0, -12.0),
                   "translate(view_offset) . scale(zoom), as the web canvas pushes it");
        // The document between the push and its pop is the identity frame's.
        let n = identity.commands().len();
        assert_eq!(&cmds[1..=n], identity.commands(), "the document draws unchanged, inside the view");
        assert!(matches!(cmds[n + 1], Command::PopState), "the view closes after the document: {:?}", cmds[n + 1]);
        assert!(cmds.len() > n + 2, "the marquee draws after the pop, in viewport pixels");
        unsafe { jas_engine_free(e) };
    }

    /// ⭐ THE FRAME DRAWS THE ARTBOARD. The 10-20 feel sitting, finding 11: no
    /// artboard was drawn, so Align To: Artboard moved shapes to an edge he
    /// could not see. The web canvas's layers (`render::render`, layers 2 and
    /// 5): each artboard's fill BEFORE the document (a Transparent one shows
    /// white, `artboard_fill_css`), its 1 px rgb(48,48,48) border AFTER it, so
    /// no element covers the edge; both under the view.
    #[test]
    fn a_frame_fills_the_artboard_under_the_document_and_borders_it_above() {
        let _counters = crate::ffi_instr::test_lock::lock();
        use crate::geometry::element::Color;
        use crate::painter::recording::{Command, RecordingPainter};
        use crate::painter::{Brush, Rect};

        let e = jas_engine_new();
        seed(e);
        let ab = unsafe { &*e }.with_model(|m| m.document().artboards.clone());
        assert_eq!(ab.len(), 1, "the seeded document carries the invariant's one artboard");
        let r = Rect { x: ab[0].x, y: ab[0].y, w: ab[0].width, h: ab[0].height };
        assert_eq!((r.w, r.h), (612.0, 792.0), "the default artboard, which no rect of the seed fills");
        let mut p = RecordingPainter::new();
        emit_frame(unsafe { &*e }, &mut p);
        let cmds = p.commands();
        let fill = cmds.iter().position(|c| matches!(c,
            Command::FillRect { rect, brush: Brush::Solid(col), .. } if *rect == r && *col == Color::rgb(1.0, 1.0, 1.0)));
        let rect = cmds.iter().position(|c| matches!(c,
            Command::FillRect { rect, .. } if (rect.x, rect.y, rect.w, rect.h) == (20.0, 30.0, 100.0, 80.0)));
        let border = cmds.iter().position(|c| matches!(c,
            Command::StrokeRect { rect, brush: Brush::Solid(col), stroke, .. }
                if *rect == r && *col == Color::from_hex("303030").unwrap() && stroke.width == 1.0));
        let (Some(fill), Some(rect), Some(border)) = (fill, rect, border) else {
            panic!("the artboard fill {fill:?}, the seeded rect {rect:?} and the artboard border {border:?} must all draw: {cmds:?}");
        };
        assert!(fill < rect && rect < border, "fill {fill} < document {rect} < border {border}");
        unsafe { jas_engine_free(e) };
    }

    /// ⭐ A CLICKED ELEMENT SHOWS ITS ANCHOR POINTS. Found by the first
    /// hand-test of the Windows app, 2026-10-10: *"Anchor points do not show selection."* The
    /// frame drew the document and the tool's overlay and never the selection
    /// highlight, which lived only in the web canvas. Driven through the same
    /// exports the shell calls: click the seeded 100x80 rect at (20,30), and the
    /// frame must carry a square at each corner -- after the document, so on top.
    #[test]
    fn a_clicked_rect_shows_its_anchor_squares_in_the_frame() {
        let _counters = crate::ffi_instr::test_lock::lock();
        use crate::painter::recording::{Command, RecordingPainter};
        use crate::tool_consts::HANDLE_DRAW_SIZE;

        let e = jas_engine_new();
        seed(e);
        let mut bare = RecordingPainter::new();
        emit_frame(unsafe { &*e }, &mut bare);
        let doc_only = bare.commands().len();

        unsafe {
            assert_eq!(jas_set_tool(e, 0), JasStatus::Ok);
            jas_pointer_event(e, KIND_PRESS, 60.0, 60.0, 0);
            jas_pointer_event(e, KIND_RELEASE, 60.0, 60.0, 0);
        }
        assert_eq!(unsafe { &*e }.with_model(|m| m.document().selection.len()), 1,
                   "the click selected the rect");
        let mut framed = RecordingPainter::new();
        emit_frame(unsafe { &*e }, &mut framed);
        let cmds = framed.commands();
        assert_eq!(&cmds[..doc_only], bare.commands(), "the document comes first, unchanged");
        let h = HANDLE_DRAW_SIZE / 2.0;
        let mut corners: Vec<(f64, f64)> = cmds[doc_only..].iter().filter_map(|c| match c {
            Command::FillRect { rect, .. } if rect.w == HANDLE_DRAW_SIZE && rect.h == HANDLE_DRAW_SIZE =>
                Some((rect.x + h, rect.y + h)),
            _ => None,
        }).collect();
        corners.sort_by(|a, b| a.partial_cmp(b).unwrap());
        assert_eq!(corners, vec![(20.0, 30.0), (20.0, 110.0), (120.0, 30.0), (120.0, 110.0)],
                   "one anchor square per corner, on top of the document");
        unsafe { jas_engine_free(e) };
    }

    /// THE TOOLBAR SEAM: the workspace names a tool, the pointer drives one,
    /// and they must be the same tool.
    #[test]
    fn a_state_tool_name_maps_to_its_shell_tool() {
        let idx = |id: &str| TOOL_IDS.iter().position(|t| *t == id);
        for name in ["selection", "rect", "pen", "lasso", "hand", "artboard"] {
            assert_eq!(selectable_index(name), idx(name), "{name}");
        }
        assert_eq!(selectable_index("add_anchor"), idx("add_anchor_point"));
        assert_eq!(selectable_index("delete_anchor"), idx("delete_anchor_point"));
        // The Type tool is a shell tool since 2026-10-20 (the 10-20 feel
        // sitting, finding 3: he could not select it, so he could not type).
        assert_eq!(selectable_index("type"), idx("type"));
        assert!(idx("type").is_some(), "the Type tool is selectable");
        assert_eq!(selectable_index("no_such_tool"), None);
    }

    #[test]
    fn writing_active_tool_swaps_the_pointer_tool() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        seed(e);
        let engine = unsafe { &*e };
        assert_eq!(unsafe { jas_set_tool(e, 0) }, JasStatus::Ok);
        engine.set_active_tool_state("rect");
        assert_eq!(sync_tool_to_state(engine), ToolSync::Switched);
        let rect = TOOL_IDS.iter().position(|t| *t == "rect").unwrap();
        assert_eq!(engine.tool_slot().as_ref().map(|(i, _)| *i), Some(rect));
        // And it DRAWS: a drag on empty canvas now makes a rect.
        let before = engine.with_document(|d| d.layers[0].children().map_or(0, |c| c.len()));
        unsafe {
            jas_pointer_event(e, KIND_PRESS, 200.0, 150.0, 0);
            jas_pointer_event(e, KIND_MOVE, 260.0, 190.0, MOD_DRAGGING);
            jas_pointer_event(e, KIND_RELEASE, 260.0, 190.0, 0);
        }
        let after = engine.with_document(|d| d.layers[0].children().map_or(0, |c| c.len()));
        assert_eq!(after, before + 1, "the rect tool drew a rect");
        // Unchanged again: a second sync does nothing.
        assert_eq!(sync_tool_to_state(engine), ToolSync::Same);
        unsafe { jas_engine_free(e) };
    }

    #[test]
    fn a_name_no_tool_answers_leaves_the_pointer_tool_alone() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let engine = unsafe { &*e };
        assert_eq!(unsafe { jas_set_tool(e, 0) }, JasStatus::Ok);
        // Type on a Path is native and not a shell tool yet.
        engine.set_active_tool_state("type_on_path");
        assert_eq!(sync_tool_to_state(engine), ToolSync::Refused);
        assert_eq!(engine.tool_slot().as_ref().map(|(i, _)| *i), Some(0));
        assert_eq!(engine.active_tool_state().as_deref(), Some("selection"), "written back");
        unsafe { jas_engine_free(e) };
    }

    /// The coupling a KEY must honour too (W5-3a): `P` switches through the
    /// same switch, so the toolbar's checked button follows a keyboard switch.
    #[test]
    fn a_tool_key_writes_active_tool() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        assert_eq!(unsafe { jas_set_tool(e, 0) }, JasStatus::Ok);
        assert_eq!(unsafe { &*e }.active_tool_state().as_deref(), Some("selection"));
        assert_eq!(unsafe { jas_key_event(e, 'p' as u32, 0) }, JasStatus::Ok);
        assert_eq!(unsafe { &*e }.active_tool_state().as_deref(), Some("pen"),
                   "a key switch lights the pen button, not the old one");
        assert_eq!(unsafe { &*e }.tool_slot().as_ref().map(|(i, _)| TOOL_IDS[*i]), Some("pen"));
        unsafe { jas_engine_free(e) };
    }

    /// The other direction: a tool picked by index is the toolbar's checked one.
    #[test]
    fn jas_set_tool_writes_active_tool() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        let pen = TOOL_IDS.iter().position(|t| *t == "pen").unwrap();
        assert_eq!(unsafe { jas_set_tool(e, pen) }, JasStatus::Ok);
        assert_eq!(unsafe { &*e }.active_tool_state().as_deref(), Some("pen"));
        let add = TOOL_IDS.iter().position(|t| *t == "add_anchor_point").unwrap();
        assert_eq!(unsafe { jas_set_tool(e, add) }, JasStatus::Ok);
        assert_eq!(unsafe { &*e }.active_tool_state().as_deref(), Some("add_anchor"),
                   "written in the WORKSPACE's name, the one the toolbar binds");
        unsafe { jas_engine_free(e) };
    }

    /// W5-2: IDLE MOTION IS SAFE FOR EVERY TOOL. The shell is about to forward
    /// unpressed moves (`MOD_DRAGGING` clear), so every tool the shell can
    /// select must take them without touching the document: not its elements,
    /// not its selection, not its journal. Measured over ALL of `TOOL_IDS`, over
    /// the seeded rect and off it, because a census READ of each tool's
    /// `on_mousemove` (W4 §3) is not a measurement.
    #[test]
    fn an_unpressed_move_changes_no_tools_document() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let snapshot = |e: *mut JasEngine| unsafe { &*e }.with_model(|m| (
            crate::geometry::test_json::document_to_test_json(m.document()),
            m.journal().len(),
            m.journal_head(),
        ));
        let mut moved = Vec::new();
        for i in 0..TOOL_IDS.len() {
            let e = jas_engine_new();
            seed(e);
            assert_eq!(unsafe { jas_set_tool(e, i) }, JasStatus::Ok, "{}", TOOL_IDS[i]);
            let before = snapshot(e);
            for (x, y) in [(5.0, 5.0), (40.0, 50.0), (70.0, 70.0), (300.0, 200.0), (60.0, 40.0)] {
                assert_eq!(unsafe { jas_pointer_event(e, KIND_MOVE, x, y, 0) }, JasStatus::Ok);
            }
            if snapshot(e) != before {
                moved.push(TOOL_IDS[i]);
            }
            unsafe { jas_engine_free(e) };
        }
        assert!(TOOL_IDS.len() >= 27, "the census covers every selectable tool: {}", TOOL_IDS.len());
        assert!(moved.is_empty(), "an UNPRESSED move changed the document under: {moved:?}");
    }

    /// W5-2: and idle motion is what class B needs. The pen draws a rubber band
    /// from its last anchor to the pointer while NO button is down
    /// (`pen.yaml`'s `on_mousemove` sets `mouse_x/y` unguarded), so after one
    /// placed anchor the overlay must FOLLOW an unpressed pointer.
    #[test]
    fn the_pen_rubber_band_follows_an_unpressed_pointer() {
        let _counters = crate::ffi_instr::test_lock::lock();
        use crate::painter::recording::RecordingPainter;
        let pen = TOOL_IDS.iter().position(|t| *t == "pen").expect("pen is selectable");
        let e = jas_engine_new();
        seed(e);
        let frame = |e: *mut JasEngine| {
            let mut p = RecordingPainter::new();
            emit_frame(unsafe { &*e }, &mut p);
            format!("{:?}", p.commands())
        };
        unsafe {
            assert_eq!(jas_set_tool(e, pen), JasStatus::Ok);
            jas_pointer_event(e, KIND_PRESS, 200.0, 20.0, 0);
            jas_pointer_event(e, KIND_RELEASE, 200.0, 20.0, 0);
            jas_pointer_event(e, KIND_MOVE, 250.0, 150.0, 0);
        }
        let at_a = frame(e);
        unsafe { jas_pointer_event(e, KIND_MOVE, 320.0, 60.0, 0) };
        let at_b = frame(e);
        assert_ne!(at_a, at_b, "the pen's overlay must follow an unpressed pointer");
        // And back: the overlay is a function of where the pointer IS, not of
        // how many moves arrived.
        unsafe { jas_pointer_event(e, KIND_MOVE, 250.0, 150.0, 0) };
        assert_eq!(frame(e), at_a, "the same pointer position draws the same overlay");
        unsafe { jas_engine_free(e) };
    }

    /// The index of the engine's active tool, or None before one is built.
    fn active_tool(e: *mut JasEngine) -> Option<usize> {
        unsafe { &*e }.tool_slot().as_ref().map(|(i, _)| *i)
    }

    fn tool_at(id: &str) -> usize {
        TOOL_IDS.iter().position(|t| *t == id).unwrap_or_else(|| panic!("`{id}` is selectable"))
    }

    /// W5-3a: a bare letter resolves through `workspace/shortcuts.yaml` in the
    /// CORE and selects its tool, exactly as the web keyboard path does
    /// (`resolve_key` → `select_tool`). `P` is the pen, `Shift+V` interior
    /// selection; a modifier the table does not bind selects nothing.
    #[test]
    fn a_tool_shortcut_selects_its_tool() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let e = jas_engine_new();
        seed(e);
        unsafe {
            assert_eq!(jas_key_event(e, 'p' as u32, 0), JasStatus::Ok);
            assert_eq!(active_tool(e), Some(tool_at("pen")));
            assert_eq!(jas_key_event(e, 'V' as u32, MOD_SHIFT), JasStatus::Ok);
            assert_eq!(active_tool(e), Some(tool_at("interior_selection")));
            assert_eq!(jas_key_event(e, '=' as u32, 0), JasStatus::Ok, "a routing id maps to its tool");
            assert_eq!(active_tool(e), Some(tool_at("add_anchor_point")));
            // Unbound: Alt+P, and a key the table does not name. NOT handled,
            // and the tool does not move, so the shell may let the key fall through.
            assert_eq!(jas_key_event(e, 'p' as u32, MOD_ALT), JasStatus::UnknownVerb);
            assert_eq!(jas_key_event(e, 'j' as u32, 0), JasStatus::UnknownVerb);
            assert_eq!(active_tool(e), Some(tool_at("add_anchor_point")));
            jas_engine_free(e);
        }
    }

    /// W5-3c, his finding 2026-10-10 ("Ctrl-Z is not working"): a COMMAND chord
    /// resolves through `shortcuts.yaml` in the core like a tool letter does.
    /// Ctrl+Z undoes a drag that moved the rect, back to the document byte for
    /// byte; Ctrl+Shift+Z redoes it, back to the moved document byte for byte.
    #[test]
    fn ctrl_z_undoes_a_move_and_ctrl_shift_z_redoes_it() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let doc = |e: *mut JasEngine| unsafe { &*e }.with_document(|d| {
            crate::geometry::test_json::document_to_test_json(d)
        });
        let e = jas_engine_new();
        seed(e);
        // The oracle is the document after a plain CLICK: the selection is a
        // non-journaled channel (OP_LOG), so undo restores the geometry and
        // leaves the selection the click made.
        unsafe {
            jas_set_tool(e, 0);
            jas_pointer_event(e, KIND_PRESS, 60.0, 60.0, 0);
            jas_pointer_event(e, KIND_RELEASE, 60.0, 60.0, 0);
        }
        let before = doc(e);
        unsafe {
            jas_pointer_event(e, KIND_PRESS, 60.0, 60.0, 0);
            jas_pointer_event(e, KIND_MOVE, 110.0, 90.0, MOD_DRAGGING);
            jas_pointer_event(e, KIND_RELEASE, 110.0, 90.0, 0);
        }
        let moved = doc(e);
        assert_ne!(moved, before, "the control: the drag moved the rect");
        unsafe {
            assert_eq!(jas_key_event(e, 'z' as u32, MOD_CMD), JasStatus::Ok);
            assert_eq!(doc(e), before, "Ctrl+Z restores the document");
            assert_eq!(jas_key_event(e, 'Z' as u32, MOD_CMD | MOD_SHIFT), JasStatus::Ok);
            assert_eq!(doc(e), moved, "Ctrl+Shift+Z restores the move");
            // A chord the table binds to something the engine does not do yet is
            // NOT handled, and changes nothing.
            assert_eq!(jas_key_event(e, 'n' as u32, MOD_CMD), JasStatus::UnknownVerb);
            assert_eq!(doc(e), moved);
            jas_engine_free(e);
        }
    }

    /// W5-3a: EVERY `select_tool` target in `shortcuts.yaml` either maps to a
    /// selectable tool or is declared not selectable from the shell. A target
    /// added tomorrow that maps to neither reds here, rather than doing nothing
    /// when its key is pressed on Windows.
    #[test]
    fn every_tool_shortcut_maps_to_a_selectable_tool_or_is_declared() {
        let bundle = crate::interpreter::workspace::Workspace::load()
            .expect("the compiled workspace loads");
        let shortcuts = bundle.data().get("shortcuts").and_then(|v| v.as_array()).expect("a shortcuts table");
        let mut targets = 0;
        let mut unmapped = Vec::new();
        for s in shortcuts {
            if s["action"] != "select_tool" { continue; }
            let id = s["params"]["tool"].as_str().expect("a tool id");
            targets += 1;
            if selectable_index(id).is_none() && !KEY_NOT_SELECTABLE.contains(&id) {
                unmapped.push(id.to_string());
            }
        }
        assert!(targets >= 25, "the table names its tools: {targets}");
        assert!(unmapped.is_empty(), "select_tool targets with no tool and no declaration: {unmapped:?}");
        for id in KEY_NOT_SELECTABLE {
            assert!(selectable_index(id).is_none(), "`{id}` is declared not selectable but IS: drop it from the list");
        }
    }

    /// flask STATUS §277: Delete and Backspace delete the selection, as
    /// `shortcuts.yaml` binds them (`delete_selection`) and the web keyboard
    /// does. Before this the engine sent them ONLY to the active tool, whose
    /// YAML has no Delete branch, so Ctrl+A then Delete on Windows deleted
    /// nothing, and a following close did not prompt. The deletion is ONE undo
    /// step and makes the document modified. With nothing selected the key
    /// changes nothing and is not handled.
    #[test]
    fn delete_and_backspace_delete_the_selection_as_one_undo_step() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let doc = |e: *mut JasEngine| unsafe { &*e }.with_document(|d| {
            crate::geometry::test_json::document_to_test_json(d)
        });
        for key in [KEY_DELETE, KEY_BACKSPACE] {
            let e = jas_engine_new();
            seed(e);
            unsafe {
                jas_set_tool(e, 0);
                // Nothing selected: the key changes nothing and is not handled.
                let empty = doc(e);
                assert_eq!(jas_key_event(e, key, 0), JasStatus::UnknownVerb, "key {key:#x}, nothing selected");
                assert_eq!(doc(e), empty);
                assert_eq!(crate::ffi::jas_document_modified(e), 0);
                jas_pointer_event(e, KIND_PRESS, 60.0, 60.0, 0);
                jas_pointer_event(e, KIND_RELEASE, 60.0, 60.0, 0);
                assert_eq!(jas_selection_len(e), 1, "the control: the click selected the rect");
                let before = doc(e);
                assert_eq!(jas_key_event(e, key, 0), JasStatus::Ok, "key {key:#x}");
                assert_eq!(jas_selection_len(e), 0, "key {key:#x}: the selection is empty");
                assert_ne!(doc(e), before, "key {key:#x}: the rect is gone");
                assert!(!doc(e).contains("\"rect\""), "key {key:#x}: no rect remains: {}", doc(e));
                assert_eq!(crate::ffi::jas_document_modified(e), 1, "key {key:#x}: an edit");
                assert_eq!(jas_key_event(e, 'z' as u32, MOD_CMD), JasStatus::Ok);
                assert!(doc(e).contains("\"rect\""), "key {key:#x}: Ctrl+Z brings the rect back");
                jas_engine_free(e);
            }
        }
    }

    /// The Delete key never orphans a live instance without asking. The web
    /// opens `delete_orphan_confirm`; the engine cannot from a key yet, so it
    /// deletes NOTHING and names the refusal. The control: the same document
    /// with the instance selected too orphans nothing, and deletes.
    #[test]
    fn the_delete_key_refuses_by_name_to_orphan_an_instance() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let doc = |e: *mut JasEngine| unsafe { &*e }.with_document(|d| {
            crate::geometry::test_json::document_to_test_json(d)
        });
        let e = jas_engine_new();
        seed(e);
        unsafe {
            jas_set_tool(e, 0);
            jas_pointer_event(e, KIND_PRESS, 60.0, 60.0, 0);
            jas_pointer_event(e, KIND_RELEASE, 60.0, 60.0, 0);
            let path = (&*e).with_document(|d| d.selection.iter().next().map(|es| es.path.clone())).expect("the rect");
            (&*e).with_model_mut(crate::workspace::menu_native::make_instance);
            assert!(doc(e).contains("\"rect\"") && doc(e).matches("\"type\"").count() > 2, "the control: an instance exists");
            (&*e).with_model_mut(|m| crate::document::controller::Controller::select_element(m, &path));
            let before = doc(e);
            assert_eq!(jas_key_event(e, KEY_DELETE, 0), JasStatus::UnknownVerb);
            assert_eq!(doc(e), before, "nothing deleted");
            let err = crate::ffi::jas_last_error_json(e);
            let text = String::from_utf8_lossy(std::slice::from_raw_parts(err.ptr, err.len)).into_owned();
            crate::ffi::jas_free(err);
            assert!(text.contains("delete_orphan_confirm"), "the refusal is named: {text}");
            (&*e).with_model_mut(|m| { crate::document::controller::Controller::select_all(m); });
            assert_eq!(jas_key_event(e, KEY_DELETE, 0), JasStatus::Ok, "the control: no orphan, deleted");
            assert!(!doc(e).contains("\"rect\""));
            jas_engine_free(e);
        }
    }

    /// A dialog a TOOL opens reaches the engine's store (flask STATUS §283,
    /// §285): an Alt-held click without a drag opens the transform tool's
    /// options dialog (`scale.yaml`, `rotate.yaml`, `shear.yaml`). The tool's
    /// handlers run on its own private store, so before this its `open_dialog`
    /// resolved against no dialog table and was dropped. The control: the same
    /// click without Alt opens nothing. Scale was the only tool driven until
    /// 2026-10-15; Rotate and Shear share its shape and are driven here too.
    #[test]
    fn a_tool_opened_dialog_reaches_the_engine() {
        let _counters = crate::ffi_instr::test_lock::lock();
        let open = |tool: &str, mods: u32| -> String {
            let e = jas_engine_new();
            seed(e);
            unsafe {
                jas_set_tool(e, 0);
                jas_pointer_event(e, KIND_PRESS, 60.0, 60.0, 0);
                jas_pointer_event(e, KIND_RELEASE, 60.0, 60.0, 0);
                assert_eq!(jas_set_tool(e, selectable_index(tool).expect(tool)), JasStatus::Ok);
                assert_eq!(jas_pointer_event(e, KIND_PRESS, 80.0, 80.0, mods), JasStatus::Ok);
                assert_eq!(jas_pointer_event(e, KIND_RELEASE, 80.0, 80.0, mods), JasStatus::Ok);
                let b = crate::ffi::jas_dialog_plan(e, 380, 640);
                let plan = String::from_utf8_lossy(std::slice::from_raw_parts(b.ptr, b.len)).into_owned();
                crate::ffi::jas_free(b);
                jas_engine_free(e);
                plan
            }
        };
        for tool in ["scale", "rotate", "shear"] {
            let plain = open(tool, 0);
            assert!(plain.starts_with(r#"{"open":false"#), "{tool}: the control, no Alt, no dialog: {plain}");
            let alt = open(tool, MOD_ALT);
            let id = format!(r#""id":"{tool}_options""#);
            assert!(alt.contains(&id) && alt.contains(r#""open":true"#), "{tool}: {alt}");
        }
    }

    /// W5-3a: Escape reaches the active tool. The selection tool cancels its
    /// marquee on Escape (`selection.yaml`), so a drag that is escaped selects
    /// NOTHING on release, while the same drag unescaped selects the rect.
    #[test]
    fn escape_cancels_a_marquee() {
        let _counters = crate::ffi_instr::test_lock::lock();
        fn drag(escape: bool) -> usize {
            let e = jas_engine_new();
            seed(e);
            unsafe {
                jas_set_tool(e, 0);
                jas_pointer_event(e, KIND_PRESS, 5.0, 5.0, 0);
                jas_pointer_event(e, KIND_MOVE, 200.0, 200.0, MOD_DRAGGING);
                if escape {
                    assert_eq!(jas_key_event(e, KEY_ESCAPE, 0), JasStatus::Ok);
                }
                jas_pointer_event(e, KIND_RELEASE, 200.0, 200.0, 0);
                let n = jas_selection_len(e);
                jas_engine_free(e);
                n
            }
        }
        assert_eq!(drag(false), 1, "the control: an unescaped marquee selects the rect");
        assert_eq!(drag(true), 0, "an escaped marquee selects nothing");
    }

    /// ⛔ A COUNT CANNOT EXPRESS A REFUSAL, so a null engine does not return 0.
    #[test]
    fn the_selection_count_crosses_and_a_null_engine_is_not_zero() {
        // ⭐ ROW EK: the ONE crate-level counter lock. This test reaches an
        // export, and every export records a crossing on the process-global
        // counters -- so it races `ffi_instr`'s tests unless it takes this.
        let _counters = crate::ffi_instr::test_lock::lock();
        assert_eq!(unsafe { jas_selection_len(std::ptr::null_mut()) }, usize::MAX,
                   "0 there would read as 'nothing selected' about a session                     that does not exist");
        let e = jas_engine_new();
        seed(e);
        assert_eq!(unsafe { jas_selection_len(e) }, 0);
        unsafe {
            jas_set_tool(e, 0);
            jas_pointer_event(e, KIND_PRESS, 10.0, 20.0, 0);
            jas_pointer_event(e, KIND_MOVE, 140.0, 120.0, MOD_DRAGGING);
            jas_pointer_event(e, KIND_RELEASE, 140.0, 120.0, 0);
        }
        assert_eq!(unsafe { jas_selection_len(e) }, 1,
                   "and it reports what the gesture actually did");
        unsafe { jas_engine_free(e) };
    }

    /// ⛔ BL5: NO STRING CROSSES. The tool list is read back by INDEX, as
    /// static bytes the shell copies -- the same shape `jas_corpus_name` uses,
    /// and the reason neither needs `jas_free`.
    #[test]
    fn the_tool_list_crosses_as_indices_and_static_bytes() {
        assert_eq!(unsafe { jas_tool_count() }, TOOL_IDS.len());
        let mut len = 0usize;
        let p = unsafe { jas_tool_name(0, &mut len) };
        assert!(!p.is_null());
        let name = std::str::from_utf8(unsafe { std::slice::from_raw_parts(p, len) }).unwrap();
        assert_eq!(name, "selection");

        let mut n = 0usize;
        assert!(unsafe { jas_tool_name(TOOL_IDS.len(), &mut n) }.is_null(),
                "an out-of-range index returns NULL, not a wild pointer");
        assert_eq!(n, 0, "and writes a zero length beside it");
    }
}
