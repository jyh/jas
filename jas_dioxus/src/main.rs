mod canvas;
mod document;
mod geometry;
mod tools;
mod ui;

use dioxus::prelude::*;

fn main() {
    dioxus_logger::init(dioxus_logger::tracing::Level::INFO).expect("failed to init logger");
    launch(ui::app::App);
}
