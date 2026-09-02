//! S-B SPIKE SEAM: paint into a DXGI surface the host owns.
//!
//! **This is a spike entry point, not ratified ABI.** It lives outside `ffi.rs`
//! deliberately: `ffi.rs` is the S-A surface that BL1-BL6 were written for, and
//! this function exists only while S-B decides whether the C#/WinUI-3
//! materializer variant is viable.
//!
//! SEPARATE MODULES DO NOT KEEP IT OUT OF THE HEADER, and this comment used to
//! claim they did. **cbindgen does not evaluate `#[cfg]`** — it parses the whole
//! crate from `lib.rs` and emitted this seam as an unconditional declaration,
//! producing precisely the header-that-lies the separation was supposed to
//! prevent: a consumer building without `d2d` compiling against a symbol absent
//! from the library. `check_cbindgen_freshness.py` caught it minutes after the
//! seam was written, which is the gate doing exactly its job on its author.
//!
//! The real fix is the `[defines]` block in `cbindgen.toml`, which maps
//! `feature = d2d` and `windows` onto `JAS_WITH_D2D` / `_WIN32` so the generated
//! declarations carry `#if` guards. **A C consumer must define `JAS_WITH_D2D`
//! to see anything in this module.**
//!
//! WHAT IT PROVES, AND WHAT IT DOES NOT. It proves the whole seam: that a
//! WinUI-3 host can create a D3D11 device and a composition swapchain, hand
//! Rust a back buffer, and have Direct2D pixels appear on the desktop. It does
//! NOT paint a document — that is the next checkpoint, and it needs the element
//! render path rather than a new boundary.
//!
//! THE OWNERSHIP RULE, which is the part that must survive into real ABI:
//! **the surface is BORROWED for the duration of the call.** Rust addrefs
//! nothing, retains nothing, and frees nothing. The host owns the device, the
//! swapchain and the back buffer, and is free to resize or drop them the moment
//! this returns. That is what keeps BL4 to a single rule — every crossing
//! allocation Rust owns is released by `jas_free`, and this call allocates
//! nothing that crosses.
//!
//! BL2 still applies: call on the thread that owns the device context. For a
//! WinUI host that is the UI thread, which is also where
//! `ISwapChainPanelNative::SetSwapChain` must be called.

use core::ffi::c_void;

use windows::core::Interface;
use windows::Win32::Graphics::Direct2D::Common::{D2D1_COLOR_F, D2D_RECT_F};
use windows::Win32::Graphics::Direct3D11::{ID3D11Device, ID3D11DeviceContext, ID3D11Resource};
use windows::Win32::Graphics::Dxgi::{IDXGIDevice, IDXGISurface};

use crate::document::document::Document;
use crate::painter::capability::Caps;
use crate::painter::direct2d::painter::Direct2DPainter;
use crate::painter::element_render::subtree_needs_legacy;
use crate::painter::direct2d::replay::replay;
use crate::painter::direct2d::surface::SurfaceTarget;

/// Status codes for the spike seam. Deliberately NOT `JasStatus`: that enum is
/// the frozen five-class contract of the S-A surface, and widening a frozen
/// vocabulary for a spike is how a spike becomes load-bearing by accident.
pub const JAS_PAINT_OK: i32 = 0;
/// Caller passed NULL. POSITIVE so it cannot collide with an HRESULT.
pub const JAS_PAINT_NULL_SURFACE: i32 = 1;
/// The pointer was not a usable `IDXGISurface`. Positive, same reason.
pub const JAS_PAINT_NOT_A_SURFACE: i32 = 2;
/// The two surfaces disagree on size or format, so the copy would be DROPPED.
/// Positive, same reason.
///
/// EXISTS BECAUSE THE FAILURE IT NAMES IS OTHERWISE SILENT. `CopyResource`
/// returns `void`; D3D11 drops a mismatched copy rather than faulting; and the
/// debug layer that would report the drop is unavailable on this box (Graphics
/// Tools is not installed). Without this code the seam returns `JAS_PAINT_OK`
/// and the host presents a stale frame -- a status truthful about the wrong
/// thing. See `d3d11_silently_drops_a_size_mismatched_copy_...` for the
/// measurement, driven rather than cited.
pub const JAS_PAINT_SIZE_MISMATCH: i32 = 3;
/// The two surfaces belong to DIFFERENT D3D11 devices. Positive, same reason.
///
/// THIS ONE IS NOT ABOUT SILENCE - IT IS ABOUT ATTRIBUTION. Unlike a size
/// mismatch, which D3D11 drops quietly, a cross-device `CopyResource` REMOVES the
/// destination's device: measured on WARP, `GetDeviceRemovedReason` goes to
/// `0x887A0020` (`DXGI_ERROR_DRIVER_INTERNAL_ERROR`) while the source's device
/// stays healthy. Everything created on the dead device fails afterwards, several
/// calls away from the cause.
///
/// `DRIVER_INTERNAL_ERROR` is exactly the error that gets blamed on hardware or a
/// driver. Refusing here is the difference between a bug report about the GPU and
/// one about a half-finished device-lost recovery.
pub const JAS_PAINT_DEVICE_MISMATCH: i32 = 4;
/// The scene bytes were not valid UTF-8 JSON, or not a JSON array of commands.
/// Positive, same reason as the sentinels above.
pub const JAS_PAINT_BAD_SCENE: i32 = 5;
/// The scene was decoded and replayed, but the painter could not draw every
/// command in it.
///
/// ⛔ THIS IS A REFUSAL, NOT A WARNING, AND THAT IS THE WHOLE POINT. A replay
/// that silently drops the commands it does not understand paints a PARTIAL
/// document and returns OK -- the host then presents a frame that is missing
/// artwork with nothing anywhere reporting it. That is the same class as the
/// dropped `CopyResource` above: a status truthful about the wrong thing. The
/// seam refuses instead, and `ReplayReport::unsupported` is the work list.
pub const JAS_PAINT_SCENE_INCOMPLETE: i32 = 6;
/// Reserved by the RED half of this increment; no shipped path returns it.
pub const JAS_PAINT_NOT_IMPLEMENTED: i32 = 7;
/// Caller passed a NULL engine to [`jas_paint_document`].
///
/// Distinct from `JAS_PAINT_NULL_SURFACE` because the two are different
/// mistakes with different fixes: one is a dead session, the other a dead
/// buffer, and collapsing them sends the reader to the wrong half of the shell.
pub const JAS_PAINT_NULL_ENGINE: i32 = 8;
/// ⛔ THE DOCUMENT HOLDS SOMETHING THIS SEAM CANNOT DRAW, so nothing was drawn.
///
/// SEPARATE FROM `JAS_PAINT_SCENE_INCOMPLETE`, and the distinction is the whole
/// value of the code. Both mean "the frame would be missing artwork", but the
/// REMEDIES are unrelated:
///
/// * `SCENE_INCOMPLETE` — the BACKEND lacks something (the declared non-Normal
///   blend gap). Fixed in `Direct2DPainter`.
/// * `DOCUMENT_INCOMPLETE` — the ELEMENT still routes to the legacy renderer
///   (`element_needs_legacy`): text, a freeform gradient, an un-ported piece of
///   the node-2 delta. Fixed in `element_render`, and it shrinks every time a
///   slice of the delta lands.
///
/// One code for both would report a backend bug for what is really a
/// not-yet-ported element, and vice versa.
pub const JAS_PAINT_DOCUMENT_INCOMPLETE: i32 = 9;
/// The bytes handed to [`jas_load_svg`] are not parseable.
///
/// ⛔ THIS CODE IS THE POINT OF THAT FUNCTION. `svg_to_document` answers
/// `Document::default()` for a malformed file, which is byte-identical to a
/// legitimately blank drawing — so a shell built on it would open a truncated
/// file, show an empty canvas, and report success. Well-formedness is the only
/// thing checked: a well-formed SVG with nothing drawable IS an empty document
/// and loads fine.
pub const JAS_PAINT_BAD_SVG: i32 = 10;

// ANY OTHER NON-ZERO RETURN IS THE RAW HRESULT, and that is a repair rather than
// a design. The first version collapsed every COM failure into a single -3, so
// the host learned only that `SurfaceTarget::from_dxgi_surface` had failed --
// which is the WHERE and never the WHY. Diagnosing it then required editing and
// rebuilding both sides. HRESULTs are negative on failure and the two sentinels
// above are positive, so the spaces cannot overlap.

/// The probe pattern's background, as `(r, g, b)` in 0..=255.
///
/// CHOSEN TO BE UNLIKELY, NOT TO BE PRETTY. The desktop verifier proves the
/// frame reached the screen by counting pixels of exactly these two colours in
/// a screenshot, so a colour the Windows shell also uses would let a run pass
/// on somebody else's pixels. That is the same law the CI lane guard runs on:
/// assert a value only the thing actually running can produce.
pub const PROBE_BG: (u8, u8, u8) = (0, 96, 96);
/// The probe pattern's square.
pub const PROBE_FG: (u8, u8, u8) = (255, 0, 255);

fn srgb(c: (u8, u8, u8)) -> D2D1_COLOR_F {
    D2D1_COLOR_F {
        r: c.0 as f32 / 255.0,
        g: c.1 as f32 / 255.0,
        b: c.2 as f32 / 255.0,
        a: 1.0,
    }
}

/// Paint the S-B probe pattern into a caller-owned DXGI surface.
///
/// Returns `JAS_PAINT_OK` (0), a positive sentinel for a bad pointer, or the
/// raw HRESULT of whichever COM call failed. The host presents; this does not.
///
/// # Safety
/// `surface` must be NULL or a valid `IDXGISurface` COM pointer that stays
/// alive for the duration of the call. Ownership is NOT transferred: the caller
/// still releases it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_paint_probe_surface(surface: *mut c_void, width: f32, height: f32) -> i32 {
    if surface.is_null() {
        return JAS_PAINT_NULL_SURFACE;
    }

    // BORROWED, not owned: `from_raw_borrowed` does not addref and will not
    // release. Getting this wrong in the other direction -- `from_raw` -- would
    // hand Rust an owning reference to the host's back buffer and free it out
    // from under the swapchain on drop.
    let surface: &IDXGISurface = match unsafe { IDXGISurface::from_raw_borrowed(&surface) } {
        Some(s) => s,
        None => return JAS_PAINT_NOT_A_SURFACE,
    };

    let target = match SurfaceTarget::from_dxgi_surface(surface) {
        Ok(t) => t,
        Err(e) => return e.code().0,
    };

    let dc = target.context();
    unsafe {
        dc.BeginDraw();
        dc.Clear(Some(&srgb(PROBE_BG)));

        // A centred square at a third of the smaller dimension, so the pattern
        // is recognisable at any panel size and the verifier's pixel counts do
        // not depend on the window happening to be a particular shape.
        let side = (width.min(height) / 3.0).max(8.0);
        let (cx, cy) = (width / 2.0, height / 2.0);
        let brush = match dc.CreateSolidColorBrush(&srgb(PROBE_FG), None) {
            Ok(b) => b,
            Err(e) => {
                let _ = dc.EndDraw(None, None);
                return e.code().0;
            }
        };
        dc.FillRectangle(
            &D2D_RECT_F {
                left: cx - side / 2.0,
                top: cy - side / 2.0,
                right: cx + side / 2.0,
                bottom: cy + side / 2.0,
            },
            &brush,
        );

        if let Err(e) = dc.EndDraw(None, None) {
            return e.code().0;
        }
    }

    JAS_PAINT_OK
}

/// Paint an OFFSCREEN surface, then GPU-copy it into the host's back buffer.
///
/// The route the direct path cannot currently take. `jas_paint_probe_surface`
/// paints the back buffer itself and the host's subsequent `Present` fails with
/// `E_NOINTERFACE`; here Direct2D never touches the back buffer at all, so if
/// `Present` succeeds afterwards it confirms the mechanism by sidestepping it.
///
/// THE COPY LIVES HERE RATHER THAN IN THE HOST, and not for tidiness. C#'s
/// `ID3D11DeviceContext::CopyResource` threw `InvalidCastException` out of
/// `InterfaceMarshaler.ConvertToNative` even with both arguments already typed
/// as `ID3D11Resource` -- a CLR marshalling wrinkle around the generated
/// interop. windows-rs calls COM directly with no marshaller in between.
///
/// Ownership is unchanged: BOTH surfaces are the host's, borrowed for the call.
///
/// # Safety
/// Both pointers must be NULL or valid `IDXGISurface` COM pointers alive for the
/// duration of the call. Neither is released here.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_paint_probe_offscreen(
    back: *mut c_void,
    offscreen: *mut c_void,
    width: f32,
    height: f32,
) -> i32 {
    if back.is_null() || offscreen.is_null() {
        return JAS_PAINT_NULL_SURFACE;
    }

    let back_s: &IDXGISurface = match unsafe { IDXGISurface::from_raw_borrowed(&back) } {
        Some(s) => s,
        None => return JAS_PAINT_NOT_A_SURFACE,
    };
    let off_s: &IDXGISurface = match unsafe { IDXGISurface::from_raw_borrowed(&offscreen) } {
        Some(s) => s,
        None => return JAS_PAINT_NOT_A_SURFACE,
    };

    // THE DEVICE CHECK RUNS FIRST, because its failure is the expensive one.
    //
    // A cross-device copy does not merely fail: it REMOVES the destination's
    // device (measured -- 0x887A0020, DXGI_ERROR_DRIVER_INTERNAL_ERROR), and
    // every later call on that device fails somewhere else entirely. Size and
    // format are then compared on surfaces already established to share a
    // device, which is also the only order in which comparing them means
    // anything.
    unsafe {
        let (Ok(back_dev), Ok(off_dev)) = (
            back_s.GetDevice::<IDXGIDevice>(),
            off_s.GetDevice::<IDXGIDevice>(),
        ) else {
            return JAS_PAINT_NOT_A_SURFACE;
        };
        // COM identity is IUnknown identity: two interface pointers on the same
        // object differ, so comparing IDXGIDevice pointers directly would be a
        // coin flip. Cast both and compare what the rule actually names.
        let (Ok(a), Ok(b)) = (
            back_dev.cast::<windows::core::IUnknown>(),
            off_dev.cast::<windows::core::IUnknown>(),
        ) else {
            return JAS_PAINT_NOT_A_SURFACE;
        };
        if a.as_raw() != b.as_raw() {
            return JAS_PAINT_DEVICE_MISMATCH;
        }
    }

    // THE AGREEMENT CHECK, AND IT HAS TO BE HERE RATHER THAN AT THE COPY.
    //
    // `CopyResource` returns `void` and D3D11 DROPS a mismatched copy instead of
    // faulting, so downstream there is nothing left to detect: the call cannot
    // report its own refusal. The one instrument that would -- the D3D11 debug
    // layer -- is unavailable on this box, Graphics Tools being uninstalled. So
    // the choice is to check the descriptors up front or to ship a seam that
    // returns OK while the host presents a stale frame.
    //
    // WHEN THIS FIRES IN PRACTICE: the host resizes its swapchain and the
    // offscreen target keeps the size it was created with. Today that cannot
    // happen -- `SwapChainHost` creates the texture exactly once and the
    // `_started` latch drops every later `SizeChanged` -- which is precisely why
    // no S-B run has ever exhibited it. This guard is what makes the resize path
    // testable rather than something that fails quietly once it is built.
    //
    // Sample count is compared too: `CopyResource` requires it to match, and a
    // guard that checked only width and height would pass a pair the platform
    // still drops. One dimension is not the class.
    unsafe {
        let back_desc = match back_s.GetDesc() {
            Ok(d) => d,
            Err(e) => return e.code().0,
        };
        let off_desc = match off_s.GetDesc() {
            Ok(d) => d,
            Err(e) => return e.code().0,
        };
        if back_desc.Width != off_desc.Width
            || back_desc.Height != off_desc.Height
            || back_desc.Format != off_desc.Format
            || back_desc.SampleDesc.Count != off_desc.SampleDesc.Count
        {
            return JAS_PAINT_SIZE_MISMATCH;
        }
    }

    // Paint the offscreen surface with the ordinary path. If that fails there is
    // nothing worth copying, and its status code is already meaningful.
    //
    // AFTER the agreement check, not before: painting a surface that is then
    // refused burns a frame's work to reach the same answer.
    let rc = unsafe { jas_paint_probe_surface(offscreen, width, height) };
    if rc != JAS_PAINT_OK {
        return rc;
    }

    unsafe {
        // The device again comes FROM the surface, so no D3D11CreateDevice.
        let dxgi_device: IDXGIDevice = match off_s.GetDevice() {
            Ok(d) => d,
            Err(e) => return e.code().0,
        };
        let d3d: ID3D11Device = match dxgi_device.cast() {
            Ok(d) => d,
            Err(e) => return e.code().0,
        };
        let ctx: ID3D11DeviceContext = match d3d.GetImmediateContext() {
            Ok(c) => c,
            Err(e) => return e.code().0,
        };

        let dst: ID3D11Resource = match back_s.cast() {
            Ok(r) => r,
            Err(e) => return e.code().0,
        };
        let src: ID3D11Resource = match off_s.cast() {
            Ok(r) => r,
            Err(e) => return e.code().0,
        };
        ctx.CopyResource(&dst, &src);
        ctx.Flush();
    }

    JAS_PAINT_OK
}


/// Paint a RECORDED DISPLAY LIST into a caller-owned DXGI surface.
///
/// ⭐ THE NODE THIS WHOLE LANE WAS MISSING. `jas_paint_probe_surface` above
/// draws a centred square -- a fixed pattern that proves the SEAM and says
/// nothing about the document. `Direct2DPainter` (1,163 lines) can draw a real
/// recorded scene, and `SurfaceTarget` can wrap the buffer the host presents.
/// Measured 2026-08-31: `SurfaceTarget` was referenced by this file and its own
/// module and NOWHERE ELSE, and every `Direct2DPainter` test drove a
/// `HeadlessTarget` (a WIC bitmap) instead. **Two proven halves that had never
/// been joined** -- so no jas artwork had ever reached the surface a window
/// presents, on any run, ever.
///
/// # Safety
/// `surface` must be NULL or a valid `IDXGISurface` that outlives the call;
/// ownership is not transferred. `scene` must be NULL or point to `len` readable
/// bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_paint_scene(
    surface: *mut c_void,
    scene: *const u8,
    len: usize,
    width: f32,
    height: f32,
) -> i32 {
    if surface.is_null() {
        return JAS_PAINT_NULL_SURFACE;
    }
    // A NULL pointer is a caller error and an EMPTY slice is a (useless but
    // legitimate) empty scene. Collapsing them would let a marshalling bug on
    // the C# side read as "nothing to draw" and present a blank frame at OK.
    if scene.is_null() {
        return JAS_PAINT_BAD_SCENE;
    }
    let bytes = unsafe { core::slice::from_raw_parts(scene, len) };
    let value: serde_json::Value = match serde_json::from_slice(bytes) {
        Ok(v) => v,
        Err(_) => return JAS_PAINT_BAD_SCENE,
    };
    // `replay` walks an ARRAY of commands. A bare object or a string decodes as
    // valid JSON and would replay as zero commands -- complete, drawn nothing,
    // and therefore OK. Refused by shape rather than discovered as a blank
    // window.
    if !value.is_array() {
        return JAS_PAINT_BAD_SCENE;
    }

    // BORROWED, not owned -- see `jas_paint_probe_surface`: `from_raw` here
    // would hand Rust an owning reference to the host's back buffer and free it
    // out from under the swapchain on drop.
    let surface: &IDXGISurface = match unsafe { IDXGISurface::from_raw_borrowed(&surface) } {
        Some(s) => s,
        None => return JAS_PAINT_NOT_A_SURFACE,
    };
    // ⚠️ `width`/`height` ARE ACCEPTED AND NOT YET USED, and that is stated
    // rather than hidden behind a silent `_`. A recorded display list carries
    // ABSOLUTE document coordinates, so nothing here needs the surface extent
    // to draw correctly today. They are in the signature because the moment
    // this seam gains a view transform -- pan, zoom, or the DIP-vs-physical
    // scaling booked as jyh/jas#16 -- it needs them, and widening a C ABI later
    // is a change every caller has to make in step. Keeping the parameters
    // costs nothing and keeps that change on one side of the boundary.
    //
    // An UNUSED parameter is a claim a reader will test, so: the probe path
    // above genuinely uses these to centre its square; this path genuinely does
    // not. Do not "fix" it by scaling the scene to fit -- the display list is
    // authored in document space and refitting it here would silently disagree
    // with every other backend.
    let _ = (width, height);

    let target = match SurfaceTarget::from_dxgi_surface(surface) {
        Ok(t) => t,
        Err(e) => return e.code().0,
    };
    let rt = target.render_target();

    let report = unsafe {
        rt.BeginDraw();
        // Transparent, NOT `PROBE_BG`. The probe's colours are chosen to be
        // recognisable to the desktop verifier; borrowing them here would make
        // a scene frame and a probe frame share a background and weaken the one
        // assertion that distinguishes this path from the square.
        rt.Clear(Some(&D2D1_COLOR_F { r: 0.0, g: 0.0, b: 0.0, a: 0.0 }));
        let mut painter = Direct2DPainter::new(rt);
        let report = replay(&mut painter, &value);
        // EndDraw runs on EVERY path, including the incomplete one: leaving a
        // render target open would poison the next frame with a failure whose
        // cause is a frame earlier.
        if let Err(e) = rt.EndDraw(None, None) {
            return e.code().0;
        }
        report
    };

    // ⛔ THE REFUSAL, and it is the reason this function is not three lines.
    // `replay` reports what it could not draw instead of throwing; a seam that
    // ignored that would present a document with artwork missing and return OK.
    if !report.is_complete() {
        return JAS_PAINT_SCENE_INCOMPLETE;
    }
    JAS_PAINT_OK
}

// ---------------------------------------------------------------------------
// OPENING A FILE — the step between "draws goldens" and "draws YOUR drawing"
// ---------------------------------------------------------------------------

/// Replace the engine's document with one parsed from SVG bytes.
///
/// ⭐ WHY THIS EXISTS AND WHY IT IS NOT IN THE NODE LIST. `ffi.rs` records that
/// `jas_load_document` is *"NOT in S-A"* because *"`geometry::test_json` has no
/// whole-document PARSER — only the writer"*. That is true of test JSON and
/// **false of SVG**: `geometry::svg::svg_to_document` exists, is not web-gated,
/// and compiles in the native build. Measured 2026-09-01 over
/// `test_fixtures/svg/`: **51 of 70 documents parse AND paint completely**
/// through `emit_element` on `Direct2DPainter`.
///
/// So the distance from "a window that draws recorded goldens" to "a window that
/// draws a real illustration" was one export over a function already in the
/// crate.
///
/// ⚠️ WHAT IT DOES **NOT** CATCH, MEASURED NOT ASSUMED: **truncation.**
/// `parse_xml` is lenient — `"<svg><rect"`, with an unclosed tag, parses as far
/// as it got and loads as a partial document. So this refuses NON-XML and
/// NON-UTF-8 only. Detecting truncation belongs in the shared parser, not in a
/// heuristic at an ABI (which is how a good file gets refused); the limit is
/// pinned by an arm, so a future tightening reds that arm rather than silently
/// outdating this comment.
///
/// ⛔ BYTES, NOT A STRING (BL5). The default P/Invoke `CharSet` is `Ansi` —
/// cp1252 on the box this ships to — and an SVG is UTF-8 that would be mangled
/// in both directions. Non-UTF-8 input is refused by name rather than
/// lossily converted, because a mangled `<text>` is a wrong drawing rather than
/// a missing one.
///
/// # Safety
/// `engine` must be NULL or a live `JasEngine`. `svg` must be NULL or point to
/// `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_load_svg(engine: *mut c_void, svg: *const u8, len: usize) -> i32 {
    let engine_ptr = engine.cast::<crate::ffi::JasEngine>();
    let Some(engine) = (unsafe { engine_ptr.as_ref() }) else {
        return JAS_PAINT_NULL_ENGINE;
    };
    // A NULL pointer is a caller error; an EMPTY slice is a zero-byte file,
    // which is not well-formed XML and refuses below as one. Collapsing them
    // would let a marshalling bug read as "an empty drawing".
    if svg.is_null() {
        return JAS_PAINT_BAD_SVG;
    }
    let bytes = unsafe { core::slice::from_raw_parts(svg, len) };
    let Ok(text) = core::str::from_utf8(bytes) else {
        return JAS_PAINT_BAD_SVG;
    };
    let Some(doc) = crate::geometry::svg::try_svg_to_document(text) else {
        return JAS_PAINT_BAD_SVG;
    };
    engine.replace_document(doc);
    JAS_PAINT_OK
}

// ---------------------------------------------------------------------------
// NODE 3 — PAINT THE LIVE DOCUMENT (no JSON round-trip)
// ---------------------------------------------------------------------------

/// Would every layer of `doc` paint completely through `emit_element` on a
/// backend with `caps`? Returns the first element path that would not.
///
/// ⛔ THIS EXISTS BECAUSE `emit_element` DROPS SILENTLY. Its contract is that a
/// legacy-only element paints NOTHING and returns — which is correct for a
/// reference renderer sitting beside `render.rs`, and catastrophic for a native
/// walk that is the ONLY renderer. Without this check `jas_paint_document`
/// would present a document with elements quietly missing and return
/// `JAS_PAINT_OK`: the same silent-success class as the dropped `CopyResource`
/// this file already refuses, reached through the element router instead of
/// through D3D11.
///
/// ⭐ AND IT MUST RUN BEFORE ANY PAINTING. Checking as we go would leave a
/// half-drawn document in the back buffer and then refuse — and the host, which
/// owns the swapchain, may present it anyway. A refusal is only a refusal if
/// nothing was written.
///
/// `subtree_needs_legacy`, not `element_needs_legacy`: a legacy-only DESCENDANT
/// is dropped just as silently as a legacy-only root.
fn first_unpaintable(doc: &Document, caps: Caps) -> Option<usize> {
    doc.layers
        .iter()
        .position(|layer| subtree_needs_legacy(layer, caps))
}

/// Paint every layer of `doc` into `surface`, or refuse having drawn nothing.
///
/// ⛔ THE ORDER IS THE CONTRACT: decide, then draw. See [`first_unpaintable`].
///
/// Shared by the extern below and by the tests, which need to supply a
/// `Document` directly -- `JasEngine` has no whole-document parser (see
/// `ffi.rs`: "`jas_load_document` is NOT in S-A"), so a test that could only
/// reach this through the engine could not build an interesting document at
/// all. Splitting the boundary from the work is what makes the refusal arm
/// testable, and the refusal is the reason this node is not three lines.
unsafe fn paint_document_into(
    surface: *mut c_void,
    doc: &Document,
) -> i32 {
    if surface.is_null() {
        return JAS_PAINT_NULL_SURFACE;
    }
    // BORROWED, not owned -- see `jas_paint_probe_surface`.
    let surface: &IDXGISurface = match unsafe { IDXGISurface::from_raw_borrowed(&surface) } {
        Some(s) => s,
        None => return JAS_PAINT_NOT_A_SURFACE,
    };
    let target = match SurfaceTarget::from_dxgi_surface(surface) {
        Ok(t) => t,
        Err(e) => return e.code().0,
    };
    let rt = target.render_target();

    // ⭐ THE CAPABILITIES COME FROM THE PAINTER THAT WILL DO THE WORK, not from a
    // constant. Asking a different backend's answers would make the refusal
    // either too strict (dropping what this one can draw) or too loose (the
    // silent-drop this whole function exists to prevent).
    let caps = {
        let painter = Direct2DPainter::new(rt);
        Caps::of(&painter)
    };
    if first_unpaintable(doc, caps).is_some() {
        // ⛔ RETURN BEFORE `BeginDraw`. Nothing has touched the surface, which is
        // what makes this a refusal rather than a report about a frame the host
        // is about to present anyway.
        return JAS_PAINT_DOCUMENT_INCOMPLETE;
    }

    unsafe {
        rt.BeginDraw();
        rt.Clear(Some(&D2D1_COLOR_F { r: 0.0, g: 0.0, b: 0.0, a: 0.0 }));
        let mut painter = Direct2DPainter::new(rt);
        // ⭐ ROW CV -- `emit_document`, NOT A BARE LAYER LOOP. This used to walk
        // `doc.layers` calling `emit_element` directly, which is the whole walk
        // MINUS the paint context `canvas::render::render()` installs as its
        // first act. That was invisible while `Element::Live` was legacy-only
        // (`first_unpaintable` refused any document carrying one); the moment
        // row CV let live geometry through the router it became a SILENT DROP --
        // every by-id reference resolving against an empty index, the document
        // presenting with its live elements missing, and this function returning
        // `JAS_PAINT_OK`. See `document::paint`, which owns the install so a
        // caller cannot forget it.
        //
        // ⚠️ `DEFAULT_PRECISION` IS NAMED HERE, AT THE CALL SITE, BECAUSE IT IS A
        // KNOWN DIVERGENCE AND NOT A DEFAULT WORTH HIDING. The web walk
        // evaluates live geometry at the Boolean panel's precision; this host
        // has no such control yet, so a document whose panel is off the default
        // tessellates differently on the two ports. When the WinUI host grows a
        // precision it passes it here and the divergence closes.
        crate::document::paint::emit_document(
            &mut painter,
            doc,
            crate::geometry::live::DEFAULT_PRECISION,
        );
        // EndDraw on EVERY path, including the error one: leaving a render
        // target open poisons the NEXT frame with a failure a frame older.
        if let Err(e) = rt.EndDraw(None, None) {
            return e.code().0;
        }
    }
    JAS_PAINT_OK
}

/// Test seam: the walk against a `Document` this crate built, with no engine.
#[cfg(test)]
unsafe fn jas_paint_document_for_test(
    surface: *mut c_void,
    doc: &Document,
    _width: f32,
    _height: f32,
) -> i32 {
    unsafe { paint_document_into(surface, doc) }
}

/// Paint the ENGINE'S LIVE DOCUMENT into a caller-owned DXGI surface.
///
/// ⭐ NODE 3, AND IT IS THE ONE THAT REMOVES THE ROUND TRIP. `jas_paint_scene`
/// takes a RECORDED display list, which means a document must first be walked,
/// serialised to JSON, and handed back across the boundary to be parsed again.
/// This walks the live `Document` in place: no serialisation, no parse, and no
/// second representation to drift.
///
/// # Safety
/// `engine` must be NULL or a live `JasEngine` from `jas_engine_new`. `surface`
/// must be NULL or a valid `IDXGISurface` that outlives the call; ownership is
/// not transferred.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_paint_document(
    engine: *mut c_void,
    surface: *mut c_void,
    width: f32,
    height: f32,
) -> i32 {
    // THE ENGINE IS CHECKED FIRST, and the order is not arbitrary: without a
    // session there is no document, so reporting a surface problem would send
    // the reader to the wrong half of the shell.
    let engine = engine.cast::<crate::ffi::JasEngine>();
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        return JAS_PAINT_NULL_ENGINE;
    };
    // Same as `jas_paint_scene`: a display list carries absolute document
    // coordinates, so the extent is not needed to draw correctly today. Kept in
    // the signature because the first view transform (pan/zoom, or the
    // DIP-vs-physical scaling booked as jyh/jas#16) needs it, and widening a C
    // ABI later is a change every caller makes in step.
    let _ = (width, height);
    engine.with_document(|doc| unsafe { paint_document_into(surface, doc) })
}

// ---------------------------------------------------------------------------
// THE EMBEDDED CORPUS, HANDED ACROSS THE BOUNDARY (node 4)
// ---------------------------------------------------------------------------
//
// ⭐ WHY THE SHELL IS NOT ALLOWED TO READ `testdata/` ITSELF. `painter/corpus.rs`
// exists because "display-list equivalence" is a claim about ONE ARTIFACT, and a
// backend that cannot touch a filesystem must be driven by that same artifact
// rather than by a copy. A C# host walking the directory would become a SECOND
// source of the corpus — the exact staleness `corpus::SCENES` was built to
// prevent, and which its own anti-drift arm
// (`corpus::tests::embedded_corpus_matches_the_directory`) polices for every
// other consumer. So the shell gets the embedded artifact, through here.
//
// It also makes the app self-contained: a double-clicked `SbWinUi.exe` paints
// the goldens with no repo checkout under it.
//
// ⛔ NOTHING HERE ALLOCATES, so nothing here is freed. Every pointer returned is
// into `&'static str` data baked into the library by `include_str!`. That is a
// deliberate departure from BL4 ("every crossing allocation Rust owns is
// released by `jas_free`") and it is safe only because the antecedent is false:
// there is no allocation to own. A future variant that formats or filters must
// go back to the `jas_free` rule rather than extend this one.

/// The one bounds-and-NULL check both corpus accessors share.
///
/// ⛔ WRITTEN ONCE ON PURPOSE. The two exports have identical refusal rules, and
/// a second copy is a second thing to get wrong -- the failure being a wild
/// write or a slice over NULL, neither of which announces itself. `pick` selects
/// which half of the corpus entry is wanted.
///
/// # Safety
/// `out_len` must be NULL or point to a writable `usize`.
unsafe fn static_slice(
    index: usize,
    out_len: *mut usize,
    pick: fn(&'static (&'static str, &'static str)) -> &'static str,
) -> *const u8 {
    // A NULL `out_len` is refused BEFORE the bounds check, because the refusal
    // path below writes through it. Ordering these the other way round would
    // make an out-of-range index on a NULL length a wild store -- the guard
    // causing the fault it exists to prevent.
    if out_len.is_null() {
        return core::ptr::null();
    }
    let Some(entry) = crate::painter::corpus::SCENES.get(index) else {
        // ZEROED, not left alone: the caller's `len` may hold anything, and a
        // NULL pointer paired with a stale non-zero length is the exact shape
        // that turns a bounds refusal into an out-of-bounds read one frame up.
        unsafe { *out_len = 0 };
        return core::ptr::null();
    };
    let s = pick(entry);
    unsafe { *out_len = s.len() };
    s.as_ptr()
}

/// How many recorded goldens the embedded corpus holds.
#[unsafe(no_mangle)]
pub extern "C" fn jas_corpus_len() -> usize {
    crate::painter::corpus::SCENES.len()
}

/// The UTF-8 name of golden `index` (e.g. `ref_gradients.json`), and its length.
///
/// Returns NULL, writing `0` through `out_len`, when `index` is out of range or
/// `out_len` is NULL. The bytes are `'static` and must not be freed.
///
/// # Safety
/// `out_len` must be NULL or point to a writable `usize`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_corpus_name(index: usize, out_len: *mut usize) -> *const u8 {
    unsafe { static_slice(index, out_len, |(name, _)| name) }
}

/// The JSON bytes of golden `index` — the recorded display list, exactly as
/// `jas_paint_scene` wants them — and its length.
///
/// Returns NULL, writing `0` through `out_len`, when `index` is out of range or
/// `out_len` is NULL. The bytes are `'static` and must not be freed.
///
/// # Safety
/// `out_len` must be NULL or point to a writable `usize`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jas_corpus_scene(index: usize, out_len: *mut usize) -> *const u8 {
    unsafe { static_slice(index, out_len, |(_, body)| body) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::Foundation::HMODULE;
    use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_WARP;
    use windows::Win32::Graphics::Direct3D11::{
        D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D,
        D3D11_BIND_RENDER_TARGET, D3D11_CPU_ACCESS_READ, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        D3D11_MAPPED_SUBRESOURCE, D3D11_MAP_READ, D3D11_SDK_VERSION, D3D11_TEXTURE2D_DESC,
        D3D11_USAGE_DEFAULT, D3D11_USAGE_STAGING,
    };
    use windows::Win32::Graphics::Dxgi::Common::{
        DXGI_FORMAT, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_SAMPLE_DESC,
    };

    const W: u32 = 90;
    const H: u32 = 60;

    fn warp() -> (ID3D11Device, ID3D11DeviceContext) {
        let mut d = None;
        let mut c = None;
        unsafe {
            D3D11CreateDevice(
                None,
                D3D_DRIVER_TYPE_WARP,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                None,
                D3D11_SDK_VERSION,
                Some(&mut d),
                None,
                Some(&mut c),
            )
            .expect("WARP");
        }
        (d.unwrap(), c.unwrap())
    }

    fn tex(dev: &ID3D11Device, staging: bool) -> ID3D11Texture2D {
        tex_wh(dev, staging, W, H)
    }

    /// `tex` at an arbitrary size.
    ///
    /// Split out for the resize tests, which need two textures that DISAGREE --
    /// and a fixed-size helper structurally cannot express that pair. That is
    /// not an incidental limitation: it is why every S-B run to date was
    /// size-matched, and therefore why none of them could exhibit the defect
    /// below.
    fn tex_wh(dev: &ID3D11Device, staging: bool, w: u32, h: u32) -> ID3D11Texture2D {
        let desc = D3D11_TEXTURE2D_DESC {
            Width: w,
            Height: h,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: if staging { D3D11_USAGE_STAGING } else { D3D11_USAGE_DEFAULT },
            BindFlags: if staging { 0 } else { D3D11_BIND_RENDER_TARGET.0 as u32 },
            CPUAccessFlags: if staging { D3D11_CPU_ACCESS_READ.0 as u32 } else { 0 },
            MiscFlags: 0,
        };
        let mut t = None;
        unsafe { dev.CreateTexture2D(&desc, None, Some(&mut t)).expect("tex") };
        t.unwrap()
    }

    /// A render-target texture at `W`x`H` in a CHOSEN format, for the format
    /// arm of the guard.
    fn tex_fmt(dev: &ID3D11Device, w: u32, h: u32, fmt: DXGI_FORMAT) -> ID3D11Texture2D {
        let desc = D3D11_TEXTURE2D_DESC {
            Width: w,
            Height: h,
            MipLevels: 1,
            ArraySize: 1,
            Format: fmt,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: D3D11_BIND_RENDER_TARGET.0 as u32,
            CPUAccessFlags: 0,
            MiscFlags: 0,
        };
        let mut t = None;
        unsafe { dev.CreateTexture2D(&desc, None, Some(&mut t)).expect("tex_fmt") };
        t.unwrap()
    }

    fn read(dev: &ID3D11Device, ctx: &ID3D11DeviceContext, src: &ID3D11Texture2D) -> Vec<u8> {
        read_wh(dev, ctx, src, W, H)
    }

    /// `read` at an arbitrary size -- the resize test reads a bigger back buffer
    /// than `W`x`H`, and a fixed-size reader would either truncate it or index
    /// past the staging texture.
    fn read_wh(
        dev: &ID3D11Device,
        ctx: &ID3D11DeviceContext,
        src: &ID3D11Texture2D,
        w: u32,
        h: u32,
    ) -> Vec<u8> {
        let staging = tex_wh(dev, true, w, h);
        let mut out = vec![0u8; (w * h * 4) as usize];
        unsafe {
            ctx.CopyResource(&staging, src);
            let mut m = D3D11_MAPPED_SUBRESOURCE::default();
            ctx.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut m)).expect("map");
            for y in 0..h as usize {
                std::ptr::copy_nonoverlapping(
                    (m.pData as *const u8).add(y * m.RowPitch as usize),
                    out.as_mut_ptr().add(y * w as usize * 4),
                    w as usize * 4,
                );
            }
            ctx.Unmap(&staging, 0);
        }
        out
    }

    fn rgb_at(buf: &[u8], x: u32, y: u32) -> (u8, u8, u8) {
        rgb_at_w(buf, x, y, W)
    }

    /// `rgb_at` against a buffer of a stated row width.
    fn rgb_at_w(buf: &[u8], x: u32, y: u32, w: u32) -> (u8, u8, u8) {
        let i = ((y * w + x) * 4) as usize;
        (buf[i + 2], buf[i + 1], buf[i])
    }

    /// The seam, exercised exactly as the C# host will call it: a raw pointer in,
    /// a status code out, pixels on a surface this code did not create.
    #[test]
    fn the_probe_paints_through_a_raw_pointer() {
        let (dev, ctx) = warp();
        let t = tex(&dev, false);
        let surface: IDXGISurface = t.cast().expect("surface");

        let rc = unsafe {
            jas_paint_probe_surface(surface.as_raw(), W as f32, H as f32)
        };
        assert_eq!(rc, JAS_PAINT_OK, "paint status");

        let buf = read(&dev, &ctx, &t);
        assert_eq!(rgb_at(&buf, W / 2, H / 2), PROBE_FG, "centre is the square");
        assert_eq!(rgb_at(&buf, 2, 2), PROBE_BG, "corner is the background");
    }

    /// THE OFFSCREEN ROUTE, tested WITHOUT a GUI.
    ///
    /// Written because the WinUI host died with `0xC0000374`
    /// (STATUS_HEAP_CORRUPTION) in ntdll the first time it took this route, while
    /// the direct route ran fine in the same build. Heap corruption deserves a
    /// deterministic reproduction rather than another launch of a windowed app:
    /// if this passes, the Rust half is not the corrupting side and the search
    /// moves to the host's COM reference handling.
    ///
    /// Two WARP textures on ONE device, exactly as the host has one device with a
    /// back buffer and an offscreen target.
    #[test]
    fn the_offscreen_route_paints_and_copies_without_corrupting_the_heap() {
        let (dev, ctx) = warp();
        let dst = tex(&dev, false);
        let src = tex(&dev, false);
        let dst_s: IDXGISurface = dst.cast().expect("dst surface");
        let src_s: IDXGISurface = src.cast().expect("src surface");

        // Run it repeatedly: a single call can corrupt the heap without tripping
        // over the damage, and the host was doing sixty frames.
        for _ in 0..16 {
            let rc = unsafe {
                jas_paint_probe_offscreen(dst_s.as_raw(), src_s.as_raw(), W as f32, H as f32)
            };
            assert_eq!(rc, JAS_PAINT_OK, "offscreen paint+copy status");
        }

        // The DESTINATION must carry the pattern -- proving the copy happened and
        // not merely that the paint did.
        let buf = read(&dev, &ctx, &dst);
        assert_eq!(rgb_at(&buf, W / 2, H / 2), PROBE_FG, "copied centre");
        assert_eq!(rgb_at(&buf, 2, 2), PROBE_BG, "copied corner");
    }

    /// A NULL surface must be a status code, never a crash. The host is C#, and
    /// a panic across an `extern "C"` boundary is undefined behaviour, not an
    /// exception the CLR can catch.
    #[test]
    fn a_null_surface_is_a_status_not_a_crash() {
        let rc = unsafe { jas_paint_probe_surface(std::ptr::null_mut(), 10.0, 10.0) };
        assert_eq!(rc, JAS_PAINT_NULL_SURFACE);
    }

    /// THE RESIZE ASSERTION, and its ABSENCE is the finding of 2026-08-27.
    ///
    /// A window resize makes the host's back buffer bigger while the offscreen
    /// texture keeps the size it was created with -- `SwapChainHost` creates it
    /// exactly once, and `MainWindow`'s `_started` latch drops every
    /// `SizeChanged` after the first. Four properties then compose:
    ///
    /// 1. `CopyResource` returns `void`, so there is no status to propagate;
    /// 2. D3D11 DROPS a size-mismatched copy instead of faulting;
    /// 3. after a resize every copy is a mismatch;
    /// 4. the debug layer that would report the drop is unavailable here.
    ///
    /// Result: the seam returns `JAS_PAINT_OK` and the host presents a STALE
    /// frame. Paint really did succeed -- into a surface nobody will see again.
    ///
    /// This is breadcrumb 5b's TRAP 6, the inverse family: an instrument that
    /// cannot report failure reads as success no matter what is true. And note
    /// WHY it survived this long -- EVERY S-B RUN EVER PERFORMED WAS FIXED-SIZE,
    /// so no run this spike has made could have exhibited it. Same shape as a
    /// `38;5` fixture that can never emit the `38;2` byte.
    #[test]
    fn a_size_mismatched_offscreen_copy_is_refused_not_reported_ok() {
        let (dev, _ctx) = warp();
        // The back buffer as it stands AFTER a resize...
        let dst = tex_wh(&dev, false, W * 2, H * 2);
        // ...and the offscreen target, still the size it was created with.
        let src = tex_wh(&dev, false, W, H);
        let dst_s: IDXGISurface = dst.cast().expect("dst surface");
        let src_s: IDXGISurface = src.cast().expect("src surface");

        let rc = unsafe {
            jas_paint_probe_offscreen(dst_s.as_raw(), src_s.as_raw(), W as f32, H as f32)
        };

        assert_ne!(
            rc, JAS_PAINT_OK,
            "a copy between surfaces of different sizes must NOT report success"
        );
        assert_eq!(rc, JAS_PAINT_SIZE_MISMATCH, "and it must say why");
    }

    /// A FORMAT disagreement must be refused on the same footing as a size one.
    ///
    /// Written because the guard is cheap to under-build: comparing width and
    /// height alone would pass a pair that `CopyResource` still drops. The DIP
    /// defect (issue #16) is a *different* size-agreement failure on this same
    /// route, which is the standing reminder that one dimension check is not the
    /// class.
    #[test]
    fn a_format_mismatched_offscreen_copy_is_refused_too() {
        let (dev, _ctx) = warp();
        let dst = tex_fmt(&dev, W, H, DXGI_FORMAT_R8G8B8A8_UNORM);
        let src = tex_wh(&dev, false, W, H);
        let dst_s: IDXGISurface = dst.cast().expect("dst surface");
        let src_s: IDXGISurface = src.cast().expect("src surface");

        let rc = unsafe {
            jas_paint_probe_offscreen(dst_s.as_raw(), src_s.as_raw(), W as f32, H as f32)
        };
        assert_eq!(rc, JAS_PAINT_SIZE_MISMATCH, "format disagreement is a mismatch too");
    }

    /// THE PLATFORM CONTRACT THE GUARD EXISTS FOR, DRIVEN RATHER THAN CITED.
    ///
    /// The 08/27 finding rested on ONE link I had read and not run: that D3D11
    /// silently DROPS a size-mismatched `CopyResource` rather than faulting.
    /// This drives it at the raw D3D11 call, BELOW our seam, so the claim stops
    /// being documentation and becomes a measurement.
    ///
    /// METHOD, and it has to be indirect: `CopyResource` is `void`, so there is
    /// no return value to consult -- which is the very property that makes the
    /// guard necessary. So paint the DESTINATION with the probe, then copy a
    /// DIFFERENTLY SIZED source over it. If the copy were honoured the
    /// destination would change; if it is dropped the probe survives untouched.
    ///
    /// A POSITIVE CONTROL RIDES ALONG: the same copy with MATCHING sizes must
    /// actually overwrite. Without it this test would pass just as happily if
    /// `CopyResource` were a no-op in every case, or if the probe colours were
    /// being read from the wrong texture -- proving the drop while the machinery
    /// was dead.
    #[test]
    fn d3d11_silently_drops_a_size_mismatched_copy_which_is_why_the_guard_exists() {
        let (dev, ctx) = warp();

        // --- the control: a MATCHED copy must overwrite ----------------------
        let seeded = tex_wh(&dev, false, W, H);
        let seeded_s: IDXGISurface = seeded.cast().expect("seeded surface");
        assert_eq!(
            unsafe { jas_paint_probe_surface(seeded_s.as_raw(), W as f32, H as f32) },
            JAS_PAINT_OK,
            "seed paint"
        );
        let blank = tex_wh(&dev, false, W, H);
        unsafe { ctx.CopyResource(&seeded, &blank) };
        let after_matched = read(&dev, &ctx, &seeded);
        assert_ne!(
            rgb_at(&after_matched, W / 2, H / 2),
            PROBE_FG,
            "CONTROL: a matched copy must really overwrite -- if this fails the              test below proves nothing, because the copy machinery is dead"
        );

        // --- the subject: a MISMATCHED copy must be dropped ------------------
        let dst = tex_wh(&dev, false, W, H);
        let dst_s: IDXGISurface = dst.cast().expect("dst surface");
        assert_eq!(
            unsafe { jas_paint_probe_surface(dst_s.as_raw(), W as f32, H as f32) },
            JAS_PAINT_OK,
            "seed paint"
        );
        let bigger = tex_wh(&dev, false, W * 2, H * 2);
        unsafe { ctx.CopyResource(&dst, &bigger) };

        let after = read(&dev, &ctx, &dst);
        assert_eq!(
            rgb_at(&after, W / 2, H / 2),
            PROBE_FG,
            "the mismatched copy was DROPPED: the destination still carries the probe"
        );
        assert_eq!(rgb_at(&after, 2, 2), PROBE_BG, "and its background survives too");
    }

    /// THE RESIZE PROTOCOL THE HOST MUST FOLLOW, pinned before the host follows it.
    ///
    /// This is the contract `SwapChainHost` has to satisfy once the `_started`
    /// latch comes off, written as an executable statement rather than as prose
    /// in a doc comment -- which is exactly how the CURRENT resize claim was
    /// recorded, and it turned out to describe code that did not exist.
    ///
    /// Three phases, in the order a real window produces them:
    ///
    ///   1. steady state at the original size -- the copy lands;
    ///   2. the back buffer grows (`ResizeBuffers`) and the offscreen target is
    ///      NOT recreated -- the seam must REFUSE, loudly;
    ///   3. the host recreates the offscreen target at the new size -- the copy
    ///      lands again, and the pixels are really there.
    ///
    /// Phase 3 is what stops this being a test of the guard alone: a guard that
    /// refused EVERYTHING would pass phases 1 and 2 and fail here. It is the
    /// positive control for the recovery, sitting inside the same test as the
    /// refusal so neither can be read without the other.
    #[test]
    fn the_resize_protocol_the_host_must_follow() {
        let (dev, ctx) = warp();

        // --- phase 1: steady state ------------------------------------------
        let back = tex_wh(&dev, false, W, H);
        let off = tex_wh(&dev, false, W, H);
        let back_s: IDXGISurface = back.cast().expect("back");
        let off_s: IDXGISurface = off.cast().expect("off");
        assert_eq!(
            unsafe { jas_paint_probe_offscreen(back_s.as_raw(), off_s.as_raw(), W as f32, H as f32) },
            JAS_PAINT_OK,
            "phase 1: the steady-state copy must land"
        );
        assert_eq!(
            rgb_at(&read(&dev, &ctx, &back), W / 2, H / 2),
            PROBE_FG,
            "phase 1: and the pixels must really be in the back buffer"
        );

        // --- phase 2: the back buffer grew, the target did not ---------------
        // This is a window resize with the host doing HALF the job -- exactly the
        // state today's code is permanently in, since it never resizes at all.
        let grown = tex_wh(&dev, false, W * 2, H * 2);
        let grown_s: IDXGISurface = grown.cast().expect("grown");
        assert_eq!(
            unsafe { jas_paint_probe_offscreen(grown_s.as_raw(), off_s.as_raw(), W as f32, H as f32) },
            JAS_PAINT_SIZE_MISMATCH,
            "phase 2: a half-done resize must be REFUSED, not silently dropped"
        );

        // --- phase 3: the host finishes the job ------------------------------
        let regrown = tex_wh(&dev, false, W * 2, H * 2);
        let regrown_s: IDXGISurface = regrown.cast().expect("regrown");
        assert_eq!(
            unsafe {
                jas_paint_probe_offscreen(
                    grown_s.as_raw(),
                    regrown_s.as_raw(),
                    (W * 2) as f32,
                    (H * 2) as f32,
                )
            },
            JAS_PAINT_OK,
            "phase 3: recreating the target at the new size must restore the route"
        );
        // POSITIVE CONTROL FOR THE RECOVERY: a guard that refused everything would
        // reach here having passed phases 1 and 2. Read the grown back buffer and
        // require the pattern in it.
        let after = read_wh(&dev, &ctx, &grown, W * 2, H * 2);
        assert_eq!(
            rgb_at_w(&after, W, H, W * 2),
            PROBE_FG,
            "phase 3: the pattern must be in the RESIZED back buffer, not merely allowed"
        );
    }

    /// THE DEVICE-LOST SHAPE - MEASURED, and it is the INVERSE of the resize one.
    ///
    /// Device-lost is the second event the ruling's surviving leg names. Its
    /// half-done state is not a size disagreement but a DEVICE disagreement: the
    /// host recreates its device and swapchain after a removal and reuses an
    /// offscreen target belonging to the OLD device. Both surfaces are valid and
    /// agree on size and format; they belong to different D3D11 devices.
    ///
    /// THE PLATFORM DOES NOT DROP THIS ONE QUIETLY - IT KILLS THE DEVICE.
    /// Measured on WARP, walked one step at a time because the first attempt died
    /// in a later call and the stack line alone would have blamed the wrong step:
    ///
    /// ```text
    ///   two WARP devices coexist ......... both reasons 0x00000000, textures ok
    ///   cross-device CopyResource ........ device A reason -> 0x887A0020
    ///                                      device B reason -> 0x00000000
    /// ```
    ///
    /// `0x887A0020` is `DXGI_ERROR_DRIVER_INTERNAL_ERROR`. Only the DESTINATION's
    /// device dies. Everything created on it afterwards fails - which is how the
    /// first version of this test died, in a staging-texture creation three calls
    /// later.
    ///
    /// THE TWO HALVES OF THE COUPLING ARGUMENT FAIL IN OPPOSITE DIRECTIONS:
    ///
    /// | half-done state | what the platform does |
    /// |---|---|
    /// | resize - sizes disagree | silent drop, seam returns OK, stale frame |
    /// | device-lost - devices disagree | device removal, loud, catastrophic |
    ///
    /// The guard still earns its place on the loud one, for a different reason
    /// than on the quiet one: `DRIVER_INTERNAL_ERROR` is precisely the error that
    /// gets blamed on hardware or a driver. Turning it into a named refusal is
    /// the difference between a bug report about the GPU and one about a
    /// half-finished device-lost recovery.
    #[test]
    fn a_cross_device_copy_removes_the_device_rather_than_dropping_silently() {
        fn removed_reason(d: &ID3D11Device) -> i32 {
            // Projected as Result<(), Error>; Ok(()) IS healthy. Reading it as a
            // raw code and testing `== 0` would work here by accident.
            match unsafe { d.GetDeviceRemovedReason() } {
                Ok(()) => 0,
                Err(e) => e.code().0,
            }
        }
        let (dev_a, ctx_a) = warp();
        let (dev_b, _ctx_b) = warp();

        // CONTROL: two devices coexisting is not itself a removal. Without this
        // the test could credit the copy for a death caused by the second
        // device's creation - which is exactly what I first suspected.
        assert_eq!(removed_reason(&dev_a), 0, "CONTROL: A healthy with B created");
        assert_eq!(removed_reason(&dev_b), 0, "CONTROL: B healthy with A created");

        let dst = tex_wh(&dev_a, false, W, H);
        let foreign = tex_wh(&dev_b, false, W, H);
        unsafe { ctx_a.CopyResource(&dst, &foreign) };
        unsafe { ctx_a.Flush() };

        assert_ne!(
            removed_reason(&dev_a),
            0,
            "MEASURED: the cross-device copy must remove the DESTINATION's device"
        );
        assert_eq!(
            removed_reason(&dev_b),
            0,
            "and it must leave the SOURCE's device alone - the asymmetry is the              evidence that the copy did it, not mere coexistence"
        );
    }

    /// THE DEVICE GUARD, whose absence lets the seam kill the process's device.
    ///
    /// Red before the guard existed: the seam took the pair, painted, copied, and
    /// the caller's device was gone by the time it returned `JAS_PAINT_OK`.
    #[test]
    fn a_cross_device_offscreen_copy_is_refused_before_it_kills_the_device() {
        let (dev_a, _ctx_a) = warp();
        let (dev_b, _ctx_b) = warp();
        let back = tex_wh(&dev_a, false, W, H);
        let off = tex_wh(&dev_b, false, W, H);
        let back_s: IDXGISurface = back.cast().expect("back");
        let off_s: IDXGISurface = off.cast().expect("off");

        let rc = unsafe {
            jas_paint_probe_offscreen(back_s.as_raw(), off_s.as_raw(), W as f32, H as f32)
        };
        assert_eq!(
            rc, JAS_PAINT_DEVICE_MISMATCH,
            "surfaces from different devices must be refused by name"
        );

        // AND THE DEVICE MUST STILL BE ALIVE. Returning the right code while
        // having already performed the copy would satisfy the assertion above and
        // lose the device anyway - the status correct, the damage done.
        let alive = matches!(unsafe { dev_a.GetDeviceRemovedReason() }, Ok(()));
        assert!(alive, "the guard must refuse BEFORE the copy, not report after it");
    }

    /// PINNED: `DXGI_STATUS_OCCLUDED` IS A **SUCCESS** CODE, SO `Failed` MISSES IT.
    ///
    /// The third event the ruling's surviving leg names is occlusion, and it is
    /// the nastiest of the three for a MEASUREMENT harness. Measured from the
    /// Windows SDK on this box rather than recalled -- `winerror.h`
    /// (10.0.22621.0:58184), under a heading that says it outright:
    ///
    /// ```text
    ///   // DXGI status (success) codes
    ///   // MessageId: DXGI_STATUS_OCCLUDED
    ///   // MessageText:
    ///   // The Present operation was invisible to the user.
    ///   #define DXGI_STATUS_OCCLUDED  _HRESULT_TYPEDEF_(0x087A0001L)
    /// ```
    ///
    /// ⇒ **A code whose documented meaning is "nobody saw this frame" is filed by
    /// the platform as SUCCESS.** The HRESULT contract makes failure the sign
    /// bit, `0x087A0001` has it clear, and so every `hr.Failed` / `is_err()` test
    /// in every language answers **false**.
    ///
    /// THIS TEST EXISTS TO STOP A SIMPLIFICATION. `SwapChainHost.RenderFrame`
    /// checked only `hr.Failed` and therefore counted an invisible present as an
    /// ordinary frame; it now classifies this code by name. Anyone who later
    /// "tidies" that back to a bare success test will fail here and read why.
    ///
    /// It is a CHARACTERIZATION of the platform, green from the start -- the same
    /// kind as the silent-drop test, and stated as such rather than dressed up as
    /// a regression that once failed.
    #[test]
    fn dxgi_status_occluded_is_a_success_code_which_is_why_failed_cannot_be_the_test() {
        // The value as the SDK defines it, written as the SDK writes it.
        const DXGI_STATUS_OCCLUDED: i32 = 0x087A0001u32 as i32;

        let hr = windows::core::HRESULT(DXGI_STATUS_OCCLUDED);
        assert!(
            hr.is_ok(),
            "the platform classifies an INVISIBLE present as success; a harness              that tests only for failure cannot see occlusion at all"
        );
        assert!(
            DXGI_STATUS_OCCLUDED > 0,
            "sign bit clear -- this is why every Failed/is_err test answers false"
        );

        // The positive control: a code that IS a failure must classify as one, so
        // this test cannot pass on an HRESULT type that calls everything ok.
        const DXGI_ERROR_DEVICE_REMOVED: i32 = 0x887A0005u32 as i32;
        assert!(
            windows::core::HRESULT(DXGI_ERROR_DEVICE_REMOVED).is_err(),
            "CONTROL: a real DXGI failure must still read as a failure"
        );
    }

    /// The two probe colours must stay distinguishable from each other and from
    /// black and white, because the desktop verifier counts them in a
    /// screenshot. If someone "tidies" them to nearby values this fails here
    /// rather than as an unexplained verifier miss later.
    #[test]
    fn the_probe_colours_are_far_apart_and_not_shell_colours() {
        let d = |a: (u8, u8, u8), b: (u8, u8, u8)| {
            (a.0 as i32 - b.0 as i32).abs()
                + (a.1 as i32 - b.1 as i32).abs()
                + (a.2 as i32 - b.2 as i32).abs()
        };
        assert!(d(PROBE_BG, PROBE_FG) > 300, "probe colours must be far apart");
        assert!(d(PROBE_BG, (0, 0, 0)) > 100, "background must not be near black");
        assert!(d(PROBE_FG, (255, 255, 255)) > 100, "square must not be near white");
    }

    // ================================================================
    // THE JOIN: a recorded display list must reach the surface the host
    // presents. Added 2026-08-31 (flask). Every arm below is HEADLESS on
    // WARP -- no window, no Smart App Control surface, no .NET SDK.
    // ================================================================

    /// Load one recorded scene by name from the painter corpus.
    fn scene_named(name: &str) -> serde_json::Value {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("src/painter/testdata")
            .join(name);
        let txt = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("scene {name}: {e}"));
        serde_json::from_str(&txt).expect("scene json")
    }

    /// Wrap a render-target texture as an IDXGISurface pointer for the seam.
    fn as_surface(t: &ID3D11Texture2D) -> IDXGISurface {
        t.cast::<IDXGISurface>().expect("texture is a DXGI surface")
    }

    /// ⭐ THE NODE. A real recorded scene, through the real Direct2D painter,
    /// into the real `SurfaceTarget` -- the type the host's back buffer becomes.
    ///
    /// Before this existed, `SurfaceTarget` was referenced by this file alone and
    /// every painter test drove a WIC `HeadlessTarget` instead, so no jas artwork
    /// had ever reached this surface type on any run.
    #[test]
    fn a_recorded_scene_reaches_the_surface_the_host_presents() {
        let (dev, ctx) = warp();
        let rt = tex(&dev, false);
        let scene = scene_named("ref_gradients.json");
        let bytes = serde_json::to_vec(&scene).unwrap();

        let rc = unsafe {
            jas_paint_scene(
                as_surface(&rt).as_raw(),
                bytes.as_ptr(),
                bytes.len(),
                W as f32,
                H as f32,
            )
        };
        assert_eq!(rc, JAS_PAINT_OK, "the scene seam refused a corpus scene");

        // ANTI-VACUITY: a seam that cleared and drew nothing would also return
        // OK. Assert the surface carries pixels that are NOT the clear colour.
        let px = read(&dev, &ctx, &rt);
        let painted = px.chunks(4).filter(|q| q[3] != 0).count();
        assert!(
            painted > 0,
            "the scene path returned OK and painted nothing -- exactly the              silent-success class this seam already refuses elsewhere"
        );
    }

    /// ⛔ AND IT MUST NOT BE THE PROBE SQUARE. The strongest way for this
    /// increment to be fake is for the new export to quietly call the old probe:
    /// the pixel count above would pass, the return code would pass, and nothing
    /// would say the document had not been drawn. So drive BOTH paths on
    /// identical surfaces and require the results to DIFFER.
    #[test]
    fn the_scene_path_is_not_the_probe_pattern_wearing_a_new_name() {
        let (dev, ctx) = warp();

        let probe_tex = tex(&dev, false);
        let probe_rc = unsafe {
            jas_paint_probe_surface(as_surface(&probe_tex).as_raw(), W as f32, H as f32)
        };
        assert_eq!(probe_rc, JAS_PAINT_OK);
        let probe_px = read(&dev, &ctx, &probe_tex);

        let scene_tex = tex(&dev, false);
        let scene = scene_named("ref_gradients.json");
        let bytes = serde_json::to_vec(&scene).unwrap();
        let scene_rc = unsafe {
            jas_paint_scene(
                as_surface(&scene_tex).as_raw(),
                bytes.as_ptr(),
                bytes.len(),
                W as f32,
                H as f32,
            )
        };
        assert_eq!(scene_rc, JAS_PAINT_OK);
        let scene_px = read(&dev, &ctx, &scene_tex);

        assert_ne!(
            probe_px, scene_px,
            "the scene path produced the probe pattern byte for byte -- it is              drawing the square, not the document"
        );

        // ⛔ AND THE BUFFER COMPARISON ALONE IS TOO WEAK -- measured, not
        // supposed. A mutant that drew the probe SQUARE from inside the scene
        // path still passed the assertion above, because the two paths clear to
        // different colours (transparent here, PROBE_BG there) and the
        // backgrounds differ even when the content is identical. So the
        // comparison was distinguishing the CLEAR, not the drawing.
        //
        // Content, then: the probe is two flat colours by construction. A
        // gradient scene cannot be. Counting DISTINCT colours separates them on
        // what was drawn rather than on what it was drawn over.
        let distinct = |px: &[u8]| {
            px.chunks(4).map(|q| [q[0], q[1], q[2], q[3]])
                .collect::<std::collections::HashSet<_>>().len()
        };
        let (dp, ds) = (distinct(&probe_px), distinct(&scene_px));
        assert!(dp <= 2, "the probe should be exactly its two flat colours, got {dp}");
        assert!(
            ds > 8,
            "the scene path produced {ds} distinct colours -- a gradient scene              cannot be that flat, so this is the probe square, not the document"
        );
    }

    /// A replay that could not draw every command must REFUSE, not report OK
    /// over a partial frame. Driven with a fabricated command, the same
    /// specimen `replay`'s own suite uses.
    #[test]
    fn a_scene_the_painter_cannot_fully_draw_is_refused_not_reported_ok() {
        let (dev, _ctx) = warp();
        let rt = tex(&dev, false);
        let scene = serde_json::json!([{ "cmd": "teleport_the_artboard" }]);
        let bytes = serde_json::to_vec(&scene).unwrap();
        let rc = unsafe {
            jas_paint_scene(
                as_surface(&rt).as_raw(),
                bytes.as_ptr(),
                bytes.len(),
                W as f32,
                H as f32,
            )
        };
        assert_eq!(
            rc, JAS_PAINT_SCENE_INCOMPLETE,
            "an undrawable command must surface as a refusal"
        );
    }

    #[test]
    fn a_null_surface_is_a_status_not_a_crash_on_the_scene_path() {
        let bytes = b"[]";
        let rc = unsafe {
            jas_paint_scene(std::ptr::null_mut(), bytes.as_ptr(), bytes.len(), 8.0, 8.0)
        };
        assert_eq!(rc, JAS_PAINT_NULL_SURFACE);
    }

    #[test]
    fn a_scene_that_is_not_json_is_refused_by_name() {
        let (dev, _ctx) = warp();
        let rt = tex(&dev, false);
        let junk = b"{ this is not a scene";
        let rc = unsafe {
            jas_paint_scene(
                as_surface(&rt).as_raw(),
                junk.as_ptr(),
                junk.len(),
                W as f32,
                H as f32,
            )
        };
        assert_eq!(rc, JAS_PAINT_BAD_SCENE);
    }

    /// A NULL scene pointer is a caller error, not an empty scene. Distinguished
    /// deliberately: an empty scene is a legitimate (if useless) request, and
    /// collapsing the two would let a marshalling bug read as "nothing to draw".
    #[test]
    fn a_null_scene_pointer_is_refused_rather_than_read_as_empty() {
        let (dev, _ctx) = warp();
        let rt = tex(&dev, false);
        // ⛔ len is NON-ZERO ON PURPOSE, and the first draft's `0` is why this
        // arm exists in this shape. With len 0 a missing guard still returns
        // BAD_SCENE -- `from_raw_parts(null, 0)` yields an empty slice in
        // practice and serde refuses it -- so the mutant SURVIVED: dropping the
        // null check reddened nothing. It is not decoration, though. A null
        // pointer is UB for `from_raw_parts` at ANY length, and at a non-zero
        // length it is the reachable kind: the seam would read 16 bytes from
        // address zero. Only the guard can answer this, so only this shape
        // tests it.
        let rc = unsafe {
            jas_paint_scene(as_surface(&rt).as_raw(), std::ptr::null(), 16, W as f32, H as f32)
        };
        assert_eq!(rc, JAS_PAINT_BAD_SCENE);
    }

    // -----------------------------------------------------------------------
    // NODE 4 — the corpus crossing, and the set of goldens the app can run
    // -----------------------------------------------------------------------

    use crate::painter::corpus::SCENES;

    /// Read back what the export handed out, as a C consumer would.
    ///
    /// # Safety
    /// Only called on pointers this module just produced.
    unsafe fn borrow(ptr: *const u8, len: usize) -> &'static [u8] {
        assert!(!ptr.is_null(), "a non-NULL pointer was expected");
        unsafe { core::slice::from_raw_parts(ptr, len) }
    }

    #[test]
    fn the_corpus_export_reports_the_embedded_count() {
        assert_eq!(jas_corpus_len(), SCENES.len(),
                   "the boundary must report the embedded corpus, not a copy of it");
        assert!(jas_corpus_len() >= 20,
                "the corpus shrank -- {} goldens", jas_corpus_len());
    }

    /// ⛔ THE ANTI-DRIFT ARM AT THE BOUNDARY. `corpus.rs` already proves the
    /// embedded list matches `testdata/`; this proves the BOUNDARY hands out
    /// that same list rather than a re-encoded, re-ordered or truncated view of
    /// it. Without it, a marshalling bug could hand the shell 19 goldens and 20
    /// would still be reported by the count arm above.
    #[test]
    fn every_exported_golden_is_byte_identical_to_the_embedded_artifact() {
        for (i, (name, body)) in SCENES.iter().enumerate() {
            let mut nlen = 0usize;
            let np = unsafe { jas_corpus_name(i, &mut nlen) };
            assert_eq!(unsafe { borrow(np, nlen) }, name.as_bytes(),
                       "name of golden {i} disagrees with the embedded corpus");

            let mut blen = 0usize;
            let bp = unsafe { jas_corpus_scene(i, &mut blen) };
            assert_eq!(unsafe { borrow(bp, blen) }, body.as_bytes(),
                       "bytes of golden {i} ({name}) disagree with the embedded corpus");
        }
    }

    /// An out-of-range index is a caller error and must be REFUSED, not read.
    /// A silent NULL with a stale `out_len` would let the shell build a slice
    /// over a null pointer, which is UB at any length.
    #[test]
    fn an_out_of_range_index_returns_null_and_zeroes_the_length() {
        let n = jas_corpus_len();
        for i in [n, n + 1, usize::MAX] {
            // Pre-load a NON-ZERO length: the guard must OVERWRITE it, not
            // merely leave it alone. A guard that only returns NULL passes a
            // zero-initialised probe by accident.
            let mut nlen = 999usize;
            assert!(unsafe { jas_corpus_name(i, &mut nlen) }.is_null(), "name at {i}");
            assert_eq!(nlen, 0, "name length at {i} must be zeroed, not left stale");

            let mut blen = 999usize;
            assert!(unsafe { jas_corpus_scene(i, &mut blen) }.is_null(), "scene at {i}");
            assert_eq!(blen, 0, "scene length at {i} must be zeroed, not left stale");
        }
    }

    /// A NULL `out_len` must not be written through. The caller gets NULL and
    /// no store happens; the alternative is a wild write on a marshalling slip.
    #[test]
    fn a_null_out_len_is_refused_rather_than_written_through() {
        assert!(unsafe { jas_corpus_name(0, core::ptr::null_mut()) }.is_null());
        assert!(unsafe { jas_corpus_scene(0, core::ptr::null_mut()) }.is_null());
    }

    /// ⭐ THE NODE-4 ARM: every golden the shell will be handed, driven through
    /// the REAL seam onto a REAL DXGI surface — the same call, on the same
    /// pointers, that the C# host makes.
    ///
    /// ⛔ IT ASSERTS THE SET, NOT A COUNT. "18 of 20 painted" is satisfied by
    /// any 18; naming them is what makes a change visible. The refusals are the
    /// backend's ONE declared gap (non-Normal blend needs an effect graph) —
    /// see `direct2d::replay`'s `DECLARED` list, which this must stay consistent
    /// with. A golden moving in or out of this set is a real change to what a
    /// Windows app can show and must be read, not absorbed.
    #[test]
    fn every_exported_golden_paints_through_the_real_seam() {
        let (dev, _ctx) = warp();
        let t = tex(&dev, false);
        let surface: IDXGISurface = t.cast().expect("surface");

        let mut refused: Vec<(String, i32)> = Vec::new();
        let mut painted = 0usize;
        for i in 0..jas_corpus_len() {
            let mut nlen = 0usize;
            let np = unsafe { jas_corpus_name(i, &mut nlen) };
            let name = String::from_utf8(unsafe { borrow(np, nlen) }.to_vec()).expect("utf-8");

            let mut blen = 0usize;
            let bp = unsafe { jas_corpus_scene(i, &mut blen) };

            let rc = unsafe {
                jas_paint_scene(surface.as_raw(), bp, blen, W as f32, H as f32)
            };
            if rc == JAS_PAINT_OK {
                painted += 1;
            } else {
                refused.push((name, rc));
            }
        }

        // ⛔ NOT ONE REFUSAL MAY BE ANYTHING BUT THE DECLARED GAP. A decode
        // error (5) or a surface fault would otherwise hide inside "some
        // scenes refuse", which is exactly the reading this arm exists to
        // prevent.
        for (name, rc) in &refused {
            assert_eq!(*rc, JAS_PAINT_SCENE_INCOMPLETE,
                       "{name} refused with {rc}, which is not the declared gap");
        }

        // ⭐ `a6_blend.json` LEFT THIS SET ON 2026-09-01 — 18/20 -> 19/20. The
        // isolated-layer blend is built (`CLSID_D2D1Blend` against a
        // `CopyFromRenderTarget` backdrop, once at the closing composite), so a
        // golden carrying `multiply` on `push_isolated_layer` now reaches the
        // presented surface.
        //
        // 📌 THIS ARM IS WHY THAT COULD NOT HAPPEN QUIETLY. It names the set
        // rather than counting it, so closing a gap REDS the test that asserted
        // the gap — which is the notice, not a nuisance.
        let names: Vec<&str> = refused.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(names, vec!["group_blend.json"],
                   "the incomplete set changed -- a golden moved in or out of \
                    what a Windows app can show; painted {painted}");
        assert_eq!(painted, jas_corpus_len() - 1,
                   "every other golden must paint, not merely not-refuse");
        assert!(painted >= 19, "only {painted} goldens reach the surface");
    }

    /// ⛔ THE COLOUR THE DESKTOP VERIFIER LOOKS FOR, PINNED HERE.
    ///
    /// `verify_window.ps1 -ExpectColor` asserts that pixels only the Rust core
    /// could have produced reached the screen. For the goldens run that colour
    /// is `ref_shapes.json`'s large flat fill, and the script has it written
    /// down as a literal.
    ///
    /// A LITERAL IN A POWERSHELL SCRIPT CANNOT NOTICE THAT A GOLDEN CHANGED.
    /// Re-authoring `ref_shapes.json`, or a colour-handling change in the
    /// backend, would leave the script hunting for a colour nothing paints any
    /// more -- and its own honest design reports that as INCONCLUSIVE ("either
    /// the core did not paint, or the camera cannot see this surface"), which is
    /// exactly the reading that would hide the regression. So the two are pinned
    /// together HERE, where a change reds a test instead of quietly weakening an
    /// oracle.
    ///
    /// The area matters as much as the value: the script samples every third
    /// pixel and needs >= 50 hits, so a colour present in a thin stroke would
    /// pass this test and fail the screen. Measured 2026-09-01 on WARP:
    /// 12,556 pixels at 400x300.
    #[test]
    fn the_verifier_colour_is_one_the_goldens_actually_paint() {
        const VERIFY_COLOUR: (u8, u8, u8) = (51, 102, 204);
        let (dev, ctx) = warp();
        let (w, h) = (400u32, 300u32);
        let t = tex_wh(&dev, false, w, h);
        let surface: IDXGISurface = t.cast().expect("surface");

        let (_, body) = SCENES
            .iter()
            .find(|(n, _)| *n == "ref_shapes.json")
            .expect("ref_shapes.json is the goldens run's final frame");
        let rc = unsafe {
            jas_paint_scene(surface.as_raw(), body.as_ptr(), body.len(), w as f32, h as f32)
        };
        assert_eq!(rc, JAS_PAINT_OK, "the final frame must paint completely");

        let buf = read_wh(&dev, &ctx, &t, w, h);
        let hits = (0..h)
            .flat_map(|y| (0..w).map(move |x| (x, y)))
            .filter(|(x, y)| rgb_at_w(&buf, *x, *y, w) == VERIFY_COLOUR)
            .count();
        assert!(hits >= 2000,
                "verify_window.ps1 looks for {VERIFY_COLOUR:?} and this golden \
                 paints it {hits} time(s) -- the desktop oracle has gone stale");

        // ⛔ AND IT MUST NOT BE A PROBE COLOUR. The whole point of asserting it
        // on the desktop is that ONLY a golden can produce it; sharing a value
        // with the probe would make the screenshot prove nothing about which
        // path ran.
        assert_ne!(VERIFY_COLOUR, PROBE_BG);
        assert_ne!(VERIFY_COLOUR, PROBE_FG);

        // ⭐⭐ AND IT MUST BE EXACTLY REPRESENTABLE, WHICH IS THE ARM THIS TEST
        // EXISTS FOR AND THE ONE I LEARNED THE HARD WAY.
        //
        // The oracle compares bytes exactly. A scene colour is authored as a
        // float, and `f * 255.0` lands on a .5 boundary for some values -- where
        // the rounding is the RASTERISER's choice, not the format's. Measured
        // 2026-09-01, the same goldens, WARP against this box's hardware:
        //
        //   0.2/0.4/0.8 -> 51,102,204 exactly       -> MATCHED on both
        //   0.9         -> 229.5      -> WARP 230, hardware 229   -> MISSED
        //   0.5         -> 127.5      -> WARP 128,  hardware 127   -> MISSED
        //
        // I picked a second colour off a WARP readback and the desktop arm
        // reported it absent -- which, under the DXGI eye, reads as A RENDERING
        // FAILURE. The rendering was perfect; the COLOUR was unassertable. An
        // oracle that can be wrong for a reason unrelated to the thing it judges
        // is worse than no oracle, so the constraint is enforced here rather
        // than left as a note for whoever picks the next one.
        //
        // ⚠️ Alpha is the other half and cannot be checked from a constant: a
        // partially transparent region composites over the WINDOW background on
        // screen and over a TRANSPARENT clear in this readback, so its two
        // values legitimately differ. Only a fully opaque region is assertable
        // on the desktop. `ref_shapes`'s flat fill is opaque; its rounded rect
        // is not, which is why only one colour travels to the verifier.
        for ch in [VERIFY_COLOUR.0, VERIFY_COLOUR.1, VERIFY_COLOUR.2] {
            let f = ch as f64 / 255.0;
            assert!((f * 255.0 - ch as f64).abs() < 1e-9,
                    "{ch} is not exactly representable as f*255, so its rounding                      is the rasteriser's choice and the desktop oracle would                      compare bytes that legitimately differ between backends");
        }
    }

    // -----------------------------------------------------------------------
    // NODE 3 — the live-document walk, and its refusal
    // -----------------------------------------------------------------------

    use crate::document::document::Document;
    use crate::geometry::element::{
        Color, CommonProps, Element, Fill, Gradient, GradientType, RectElem,
    };
    use crate::painter::capability::Caps;

    fn doc_with(layers: Vec<Element>) -> Document {
        Document { layers, ..Document::default() }
    }

    fn a_paintable_rect() -> Element {
        Element::Rect(RectElem {
            x: 5.0, y: 5.0, width: 60.0, height: 40.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color: Color::rgb(0.2, 0.4, 0.8), opacity: 1.0 }),
            stroke: None,
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        })
    }

    /// An element the native walk cannot draw.
    ///
    /// ⛔ A FREEFORM GRADIENT, DELIBERATELY, AND NOT TEXT. Text is the obvious
    /// choice and it is the WRONG one: text is legacy only until `measure_text`
    /// arrives as a caller-owned service, at which point this arm would start
    /// passing for the wrong reason -- or worse, quietly stop testing anything
    /// while still going green. A freeform gradient is legacy BY CONTRACT (A5:
    /// a build-time lowering concern the seam never carries; no backend answer
    /// unlocks it), so the arm stays meaningful however much of the delta lands.
    fn an_unpaintable_element() -> Element {
        let mut r = match a_paintable_rect() {
            Element::Rect(r) => r,
            _ => unreachable!(),
        };
        r.fill_gradient = Some(Box::new(Gradient {
            gtype: GradientType::Freeform,
            ..Gradient::default()
        }));
        Element::Rect(r)
    }

    /// A document of PH1-expressible layers paints, and the surface CHANGES.
    ///
    /// "Returned OK" is not the assertion -- a function that did nothing would
    /// also return OK. The pixels are.
    #[test]
    fn a_live_document_reaches_the_surface_the_host_presents() {
        let (dev, ctx) = warp();
        let t = tex(&dev, false);
        let surface: IDXGISurface = t.cast().expect("surface");

        let before = read(&dev, &ctx, &t);
        let doc = doc_with(vec![a_paintable_rect()]);
        let rc = unsafe {
            jas_paint_document_for_test(surface.as_raw(), &doc, W as f32, H as f32)
        };
        assert_eq!(rc, JAS_PAINT_OK, "status");

        let after = read(&dev, &ctx, &t);
        assert_ne!(before, after, "the document must have changed the surface");
        assert_eq!(rgb_at(&after, 20, 20), (51, 102, 204),
                   "and it must be THE DOCUMENT'S colour, not merely different");
    }

    /// ⛔ THE ARM THIS NODE EXISTS FOR. A document holding an element the seam
    /// cannot draw is REFUSED **and the surface is left untouched**.
    ///
    /// Refusing after painting would be no refusal at all: the host owns the
    /// swapchain and presents whatever is in the back buffer, so a half-drawn
    /// document would reach the screen with an error code nobody can un-present.
    /// Asserting the pixels are UNCHANGED is the only way to state that; a status
    /// code alone cannot.
    #[test]
    fn a_document_with_an_unpaintable_element_is_refused_before_anything_is_drawn() {
        let (dev, ctx) = warp();
        let t = tex(&dev, false);
        let surface: IDXGISurface = t.cast().expect("surface");

        let before = read(&dev, &ctx, &t);
        // The paintable rect comes FIRST, so a walk that painted as it went
        // would have drawn it before reaching the text. That ordering is the
        // whole point of the arm.
        let doc = doc_with(vec![a_paintable_rect(), an_unpaintable_element()]);
        let rc = unsafe {
            jas_paint_document_for_test(surface.as_raw(), &doc, W as f32, H as f32)
        };
        assert_eq!(rc, JAS_PAINT_DOCUMENT_INCOMPLETE,
                   "an element that routes to legacy must refuse, not drop silently");

        let after = read(&dev, &ctx, &t);
        assert_eq!(before, after,
                   "a refusal that already painted is not a refusal -- the host \
                    presents the back buffer either way");
    }

    /// An EMPTY document is complete, not incomplete. Nothing to draw is a
    /// legitimate state (a new file), and refusing it would make the app unable
    /// to open one.
    #[test]
    fn an_empty_document_is_complete() {
        let (dev, _ctx) = warp();
        let t = tex(&dev, false);
        let surface: IDXGISurface = t.cast().expect("surface");
        let rc = unsafe {
            jas_paint_document_for_test(surface.as_raw(), &doc_with(vec![]), W as f32, H as f32)
        };
        assert_eq!(rc, JAS_PAINT_OK, "an empty document draws nothing, successfully");
    }

    /// A NULL engine and a NULL surface are DIFFERENT mistakes and must not
    /// collapse into one code -- one is a dead session, the other a dead buffer.
    #[test]
    fn a_null_engine_and_a_null_surface_are_told_apart() {
        assert_eq!(
            unsafe { jas_paint_document(core::ptr::null_mut(), core::ptr::null_mut(), 1.0, 1.0) },
            JAS_PAINT_NULL_ENGINE,
            "the engine is checked first: without a session there is nothing to paint"
        );

        let e = crate::ffi::jas_engine_new();
        let rc = unsafe { jas_paint_document(e.cast(), core::ptr::null_mut(), 1.0, 1.0) };
        unsafe { crate::ffi::jas_engine_free(e) };
        assert_eq!(rc, JAS_PAINT_NULL_SURFACE);
    }

    /// ⛔ THE ROUTER IS THE MEASURE, AND IT MUST HAVE TEETH IN BOTH DIRECTIONS.
    /// If `first_unpaintable` answered `None` for everything, the refusal arm
    /// above could never fire and would be passing over dead machinery.
    #[test]
    fn the_completeness_check_distinguishes_the_two_documents() {
        let caps = Caps::NONE
            .with(crate::painter::capability::Capability::IsolatedLayers)
            .with(crate::painter::capability::Capability::MaskLayers);
        assert_eq!(first_unpaintable(&doc_with(vec![a_paintable_rect()]), caps), None);
        assert_eq!(
            first_unpaintable(&doc_with(vec![a_paintable_rect(), an_unpaintable_element()]), caps),
            Some(1),
            "and it must name WHICH layer, not merely that one exists"
        );
    }

    // -----------------------------------------------------------------------
    // OPENING A FILE — and the silent-blank-canvas hole it closes
    // -----------------------------------------------------------------------

    /// ⛔ THE ARM THIS EXPORT EXISTS FOR. A malformed file must REFUSE, not open
    /// as an empty drawing.
    ///
    /// `svg_to_document` answers `Document::default()` for unparseable input,
    /// which is byte-identical to a legitimately blank SVG. A shell built on it
    /// would open a truncated file, show a blank canvas, and report success --
    /// and the user would conclude their artwork was lost rather than that the
    /// file was bad. Those are opposite diagnoses.
    #[test]
    fn a_malformed_file_is_refused_rather_than_opened_as_a_blank_drawing() {
        let e = crate::ffi::jas_engine_new();
        for bad in ["", "not xml at all", "\u{0}\u{1}\u{2}"] {
            let rc = unsafe { jas_load_svg(e.cast(), bad.as_ptr(), bad.len()) };
            assert_eq!(rc, JAS_PAINT_BAD_SVG, "input {bad:?} must refuse");
        }

        // ⛔ AND HERE IS THE LIMIT, PINNED RATHER THAN HIDDEN. A TRUNCATED file
        // -- `"<svg><rect"`, an unclosed tag -- is ACCEPTED: `parse_xml` is
        // lenient and parses as far as it got. Measured 2026-09-01; my first
        // draft of this arm asserted a refusal and was simply wrong.
        //
        // So `jas_load_svg` refuses NON-XML and NON-UTF-8, and does NOT detect
        // truncation. That is a property of the shared parser rather than of
        // this boundary, and "fixing" it here would mean a heuristic at an ABI
        // -- which is how a good file gets refused.
        //
        // It is stated so the hole is KNOWN rather than found by a user with a
        // half-copied file, and ASSERTED so that if the parser ever tightens,
        // this line reds and the doc comment gets corrected instead of quietly
        // going stale.
        let truncated = "<svg><rect";
        assert_eq!(
            unsafe { jas_load_svg(e.cast(), truncated.as_ptr(), truncated.len()) },
            JAS_PAINT_OK,
            "if this now REFUSES, the XML parser gained truncation detection -- \
             good news, but jas_load_svg's doc comment says it does not, and \
             that comment must be corrected"
        );
        // ⛔ AND NON-UTF-8 IS REFUSED BY NAME, not lossily converted. A mangled
        // `<text>` is a WRONG drawing, not a missing one.
        let invalid_utf8: [u8; 4] = [0xff, 0xfe, 0x00, 0x41];
        assert_eq!(
            unsafe { jas_load_svg(e.cast(), invalid_utf8.as_ptr(), invalid_utf8.len()) },
            JAS_PAINT_BAD_SVG
        );
        assert_eq!(
            unsafe { jas_load_svg(e.cast(), core::ptr::null(), 8) },
            JAS_PAINT_BAD_SVG,
            "a NULL pointer is a caller error, not an empty file"
        );
        unsafe { crate::ffi::jas_engine_free(e) };
    }

    /// ⛔ THE CONTROL THAT KEEPS THE ARM ABOVE HONEST: a well-formed SVG with
    /// nothing drawable in it IS an empty document and must LOAD. Without this,
    /// "refuse everything" would pass every assertion above.
    #[test]
    fn a_well_formed_but_empty_drawing_loads_rather_than_refusing() {
        let e = crate::ffi::jas_engine_new();
        let empty = r#"<svg xmlns="http://www.w3.org/2000/svg"></svg>"#;
        assert_eq!(
            unsafe { jas_load_svg(e.cast(), empty.as_ptr(), empty.len()) },
            JAS_PAINT_OK,
            "a blank drawing is a legitimate file, not a malformed one"
        );
        unsafe { crate::ffi::jas_engine_free(e) };
    }

    /// ⭐ END TO END: a real file off disk, opened through the boundary, painted
    /// through the SAME `jas_paint_document` the shell calls, onto a real
    /// surface -- and it must put THE FILE'S OWN COLOUR on it.
    ///
    /// This is the whole "double-click and draw" path minus the double-click,
    /// and it is asserted on PIXELS rather than on a status code, because a
    /// loader that parsed nothing would return OK and paint an empty document
    /// perfectly successfully.
    #[test]
    fn a_real_svg_file_opens_and_paints_its_own_colour_onto_the_surface() {
        let e = crate::ffi::jas_engine_new();
        // Authored here rather than read from `test_fixtures/` so the arm states
        // its own expectation: the colour asserted below is visible in the
        // source of the thing being drawn.
        // r##"..."## -- NOT r#"..."#: the payload contains `fill="#`, and `"#`
        // is exactly what terminates a single-hash raw string.
        let svg = r##"<svg xmlns="http://www.w3.org/2000/svg" width="90" height="60">
             <rect x="0" y="0" width="90" height="60" fill="#3366cc"/>
           </svg>"##;
        assert_eq!(
            unsafe { jas_load_svg(e.cast(), svg.as_ptr(), svg.len()) },
            JAS_PAINT_OK, "load"
        );

        let (dev, ctx) = warp();
        let t = tex(&dev, false);
        let surface: IDXGISurface = t.cast().expect("surface");
        let rc = unsafe {
            jas_paint_document(e.cast(), surface.as_raw(), W as f32, H as f32)
        };
        assert_eq!(rc, JAS_PAINT_OK, "paint");

        let buf = read(&dev, &ctx, &t);
        // #3366cc == (51, 102, 204) -- exactly representable as f*255, which is
        // the one class of colour safe to assert across rasterisers. See
        // `the_verifier_colour_is_one_the_goldens_actually_paint`.
        assert_eq!(rgb_at(&buf, W / 2, H / 2), (51, 102, 204),
                   "the FILE'S colour must be on the surface");
        unsafe { crate::ffi::jas_engine_free(e) };
    }

    /// A NULL engine is told apart from a bad file: one is a dead session, the
    /// other a bad input, and they send the reader to different places.
    #[test]
    fn loading_into_a_null_engine_says_so() {
        let svg = "<svg/>";
        assert_eq!(
            unsafe { jas_load_svg(core::ptr::null_mut(), svg.as_ptr(), svg.len()) },
            JAS_PAINT_NULL_ENGINE
        );
    }

    // -----------------------------------------------------------------------
    // ROW DA — what the SVG corpus can present, and what still cannot
    // -----------------------------------------------------------------------

    /// The first capability a layer still needs, or `None` if it paints.
    fn still_needs(e: &crate::geometry::element::Element, caps: Caps) -> Option<&'static str> {
        use crate::geometry::element::Element;
        if crate::painter::element_render::element_needs_legacy(e, caps) {
            return Some(match e {
                Element::TextPath(_) => "TEXT-ON-PATH",
                Element::Text(t) if !t.render_is_flat() => "SEGMENTED-TEXT(tspans)",
                Element::Text(_) => "TEXT-FEATURE(spacing/kerning/baseline/decoration)",
                _ => "other",
            });
        }
        if let Some(ch) = e.children() {
            for c in ch {
                if let Some(w) = still_needs(c, caps) {
                    return Some(w);
                }
            }
        }
        if let Some(m) = e.common().mask.as_ref() {
            if let Some(w) = still_needs(&m.subtree, caps) {
                return Some(w);
            }
        }
        None
    }

    /// ⭐ ROW DA's PREDICTION, HELD AS AN ARM: **flat text flips 4 documents,
    /// and the 5 that stay are named with the capability they are waiting on.**
    ///
    /// ⛔ IT NAMES THEM RATHER THAN COUNTING THEM. "61 of 70" is satisfied by any
    /// 61; a later narrowing that closed `text_path_basic` while silently
    /// breaking `text_basic` would keep the count and change the picture. The
    /// SET is the claim.
    ///
    /// ⚠️ AND IT COUNTS **DOCUMENTS**, NOT LAYERS, because that is what a user
    /// opens. `locked_all_kinds.svg` holds a flat `<text>` AND a `<textPath>`,
    /// so five documents *contain* newly-paintable flat text while only four
    /// flip. Counting layers reports 5 and is wrong about what anyone can see.
    #[test]
    fn the_svg_corpus_presents_what_row_da_predicted() {
        let (dev, _ctx) = warp();
        let t = tex(&dev, false);
        let surface: IDXGISurface = t.cast().expect("surface");
        let target = SurfaceTarget::from_dxgi_surface(&surface).expect("target");
        let caps = Caps::of(&Direct2DPainter::new(target.render_target()));

        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../test_fixtures/svg");
        let mut paths: Vec<_> = std::fs::read_dir(dir)
            .expect("svg fixtures")
            .filter_map(Result::ok)
            .map(|e| e.path())
            .filter(|p| p.extension().map(|x| x == "svg").unwrap_or(false))
            .collect();
        paths.sort();

        let mut total = 0usize;
        let mut refusing: Vec<(String, &'static str)> = Vec::new();
        for path in paths {
            let txt = std::fs::read_to_string(&path).expect("read");
            let doc = crate::geometry::svg::svg_to_document(&txt);
            total += 1;
            if let Some(why) = doc.layers.iter().find_map(|l| still_needs(l, caps)) {
                refusing.push((path.file_name().unwrap().to_string_lossy().into_owned(), why));
            }
        }

        assert_eq!(total, 70, "the fixture corpus changed size");
        assert_eq!(
            refusing,
            vec![
                ("locked_all_kinds.svg".to_string(), "TEXT-ON-PATH"),
                ("setup_text_ab_bold_b.svg".to_string(), "SEGMENTED-TEXT(tspans)"),
                ("text_path_basic.svg".to_string(), "TEXT-ON-PATH"),
                ("text_path_with_tspans.svg".to_string(), "TEXT-ON-PATH"),
                ("text_with_tspans.svg".to_string(), "SEGMENTED-TEXT(tspans)"),
            ],
            "the refusing SET changed -- a document moved in or out of what a \
             Windows app can present. 65 of 70 should now paint (was 61): flat \
             text flipped complex_document, setup_text_hello, text_basic and \
             text_xml_space_preserve. Each remaining entry names the capability \
             it waits on, and each is a LATER narrowing with its own arm."
        );
        assert_eq!(total - refusing.len(), 65, "65 of 70 documents present");
    }
}
