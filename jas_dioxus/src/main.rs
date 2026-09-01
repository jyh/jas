mod algorithms;
// Mirrors lib.rs: the bin re-declares the module tree as its own crate root, so
// the two non-web-gated leaves that `tools` re-exports must be declared here too.
mod text_measure;
mod surface;
mod tool_consts;
mod canvas;
#[cfg(test)]
mod cross_language_test;
mod document;
mod geometry;
mod interpreter;
mod painter;
mod panels;
mod recorder;
mod tools;
mod workspace;

use dioxus::prelude::*;

fn main() {
    // Surface Rust panics in the browser console with their message + source
    // location. Without this a panic in a wasm event handler aborts the module
    // silently (the app "freezes", File menu dead, needs a refresh) with only a
    // cryptic "unreachable" in the console. set_once is idempotent.
    console_error_panic_hook::set_once();
    dioxus_logger::init(dioxus_logger::tracing::Level::INFO).expect("failed to init logger");
    launch(workspace::app::App);
}

