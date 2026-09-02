pub mod algorithms;
pub mod interpreter;
// Plain tool scalars (hit radius, drag threshold, paste offset, ...). NOT gated:
// `tools` is web-only because it imports web_sys, but the numbers are not, and
// document-layer code and its tests need them natively. `tools::tool` re-exports
// them, so existing paths are unchanged.
pub mod tool_consts;
// The shared text-width law. NOT gated: `Element::bounds` needs it in every
// build, and it lived in web-gated `tools` while being the only definition,
// which is how the native arm drifted. `tools::text_measure` re-exports it.
pub mod text_measure;
// Caller-owned pixel surfaces: readback / writeback / composite, the services
// the Painter seam must not grow to provide (ruling 2026-08-31). Crate root,
// not web-gated: the trait, the luminance law and the memory surface are
// host-independent; only `surface::web` is behind `feature = "web"`.
pub mod surface;
// The extern "C" boundary for a native shell (S-A). Behind `feature = "ffi"`,
// so the default web build and the wasm target never see it.
#[cfg(feature = "ffi")]
pub mod ffi;
// Boundary instrumentation for S-C's chatter measurement. Behind the same gate
// as the surface it counts: a counter that could be compiled without the
// boundary would be a counter with nothing to count.
#[cfg(feature = "ffi")]
pub mod ffi_instr;
// The panel state slice, the scope the engine assembles from it, and the tick's
// write path (S-C.2). Same gate as the boundary it serves: it exists because
// BL1 forbids the shell from assembling either.
#[cfg(feature = "ffi")]
pub mod panel_scope;

// S-B SPIKE SEAM, not ratified ABI. Needs BOTH features: the paint entry
// point is meaningless without the Direct2D backend, and it is kept out of
// `ffi.rs` so it cannot reach the generated `jas_ffi.h`, where a consumer
// building without `d2d` would compile against a symbol that is not there.
#[cfg(all(feature = "ffi", feature = "d2d", windows))]
pub mod ffi_paint;
#[cfg(feature = "web")]
pub mod canvas;
#[cfg(test)]
mod cross_language_test;
pub mod document;
pub mod geometry;
// The immediate-mode Painter seam (contract v2, RATIFIED + FROZEN 2026-07-23).
// Always compiled (pure-native core; the Canvas2dPainter backend is
// feature="web"). PH1 wires it into canvas/render.rs for the one proven
// byte-identical leaf paint (a plain solid center line — see
// painter::element_render); everything else stays on the legacy raw-ctx path.
// See src/painter/SPIKE_FINDINGS.md.
pub mod painter;
#[cfg(feature = "web")]
pub mod panels;
// NOT gated as a whole. recorder/replay.rs is the SHARED corpus replay path --
// the gesture, action and key corpora, the record-stop fidelity check and the
// corpus_replay bin all call it, deliberately, so that corpus replay and
// recording verification cannot drift apart. Gating the module gated that too,
// so the instrument of the cross-port prime directive ran in exactly one build
// configuration. The gate now lives per-submodule and per-function.
pub mod recorder;
// ⭐ ROW DU / PR 1: `tools/` is NO LONGER WEB-GATED. Its only web dependency was
// `CanvasTool::draw_overlay`'s `&CanvasRenderingContext2d` -- one method of
// fifteen, over 251 drawing call sites and zero input ones. The overlay now
// draws through `painter::overlay_ctx::OverlayCtx` over a `&mut dyn Painter`,
// so a native shell can drive the tool seam and a Windows app can take the
// pointer (row DU, ruled 2026-09-02 option (c)).
pub mod tools;
// NOT gated as a whole. Nine of its seventeen submodules are pure data and pure
// functions -- layout types, the layout-op dispatcher, pane geometry, key-chord
// resolution, the menu structure, the fixture serializer -- and two of those are
// pinned CROSS-LANGUAGE by corpora. Gating the module gated them too: 185 tests
// that could run natively did not. The gate now lives per-submodule in
// workspace/mod.rs, which explains each one. Same disease as CHARWIDTH, where a
// shared law lived inside web-gated `tools` and the native arm drifted unwatched.
pub mod workspace;
