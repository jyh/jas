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

/// Select the tool the pointer drives, by index into [`TOOL_IDS`].
///
/// # Safety
/// `e` must be NULL or a pointer from `jas_engine_new` that is still live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_set_tool(e: *mut JasEngine, index: usize) -> JasStatus {
    let Some(engine) = (unsafe { e.as_ref() }) else { return JasStatus::NullHandle };
    let Some(id) = TOOL_IDS.get(index) else { return JasStatus::MissingTarget };
    let Some(built) = build_tool(id) else { return JasStatus::MissingTarget };
    *engine.tool_slot() = Some((index, built));
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

    let mut slot = engine.tool_slot();
    if slot.is_none() {
        // Default to the first tool rather than refusing: a shell that never
        // called `jas_set_tool` still gets the selection tool, which is what
        // every drawing app opens with.
        let Some(built) = build_tool(TOOL_IDS[0]) else { return JasStatus::MissingTarget };
        *slot = Some((0, built));
    }
    let (_, tool) = slot.as_mut().expect("just built");

    engine.with_model_mut(|m| match kind {
        KIND_PRESS => tool.on_press(m, dx, dy, shift, alt),
        KIND_MOVE => tool.on_move(m, dx, dy, shift, alt, dragging),
        _ => tool.on_release(m, dx, dy, shift, alt),
    });
    JasStatus::Ok
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
pub(crate) fn emit_frame(engine: &JasEngine, p: &mut dyn crate::painter::Painter) {
    engine.with_document(|doc| {
        crate::document::paint::emit_document(p, doc, crate::geometry::live::DEFAULT_PRECISION);
    });
    let mut slot = engine.tool_slot();
    if let Some((_, tool)) = slot.as_mut() {
        let mut ctx = crate::painter::overlay_ctx::OverlayCtx::new(p);
        engine.with_model(|m| tool.draw_overlay(m, &mut ctx));
        ctx.finish();
    }
}

/// Build a `YamlTool` from the embedded workspace bundle -- the same path the
/// running app uses.
fn build_tool(id: &str) -> Option<Box<dyn CanvasTool>> {
    let ws = crate::interpreter::workspace::Workspace::load()?;
    let spec = ws.data().get("tools")?.get(id)?;
    Some(Box::new(crate::tools::yaml_tool::YamlTool::from_workspace_tool(spec)?))
}

#[cfg(test)]
mod tests {
    use super::*;
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
