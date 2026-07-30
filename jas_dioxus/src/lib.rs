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
// The extern "C" boundary for a native shell (S-A). Behind `feature = "ffi"`,
// so the default web build and the wasm target never see it.
#[cfg(feature = "ffi")]
pub mod ffi;
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
#[cfg(feature = "web")]
pub mod recorder;
#[cfg(feature = "web")]
pub mod tools;
#[cfg(feature = "web")]
pub mod workspace;
