pub mod algorithms;
pub mod interpreter;
#[cfg(feature = "web")]
pub mod canvas;
#[cfg(test)]
mod cross_language_test;
pub mod document;
pub mod geometry;
// PH1 de-risking spike — the immediate-mode Painter seam prototype. Always
// compiled (pure-native core; the Canvas2dPainter backend is feature="web").
// NOT wired into canvas/render.rs: the FLIP is unratified. See
// src/painter/SPIKE_FINDINGS.md.
pub mod painter;
#[cfg(feature = "web")]
pub mod panels;
#[cfg(feature = "web")]
pub mod recorder;
#[cfg(feature = "web")]
pub mod tools;
#[cfg(feature = "web")]
pub mod workspace;
