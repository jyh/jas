mod algorithms;
mod canvas;
#[cfg(test)]
mod cross_language_test;
mod document;
mod geometry;
mod panels;
mod tools;
mod workspace;

use dioxus::prelude::*;

fn main() {
    dioxus_logger::init(dioxus_logger::tracing::Level::INFO).expect("failed to init logger");
    launch(workspace::app::App);
}
