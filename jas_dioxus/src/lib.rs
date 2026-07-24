pub mod algorithms;
pub mod interpreter;
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
