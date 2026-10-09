/// The jas MCP server over stdio (docs/AGENT_API.md §4, node A3).
///
/// Usage:
///   jas_mcp [file.svg]     -- serve one document (blank when no file is given)
///
/// A reader thread owns stdin and forwards each line over a channel; the main
/// thread owns the session and stdout. The split is what makes the server
/// two-way: the main loop can also take events that are not client requests
/// (an artist's accept, edit or undo, once an app hosts this loop, node A4) and
/// push the notifications they produce while no request is in flight. Headless,
/// there is no artist, so the only events are the client's own lines.
use std::io::{BufRead, Write};
use std::sync::mpsc;

use jas_dioxus::document::model::Model;
use jas_dioxus::geometry::svg::svg_to_document;
use jas_dioxus::mcp::Session;

/// What the main loop can be woken by.
enum Event {
    Line(String),
    Eof,
}

fn main() {
    let doc = match std::env::args().nth(1) {
        Some(path) => {
            let svg = std::fs::read_to_string(&path).unwrap_or_else(|e| {
                eprintln!("jas_mcp: cannot read {path}: {e}");
                std::process::exit(1);
            });
            svg_to_document(&svg)
        }
        None => svg_to_document(r#"<svg xmlns="http://www.w3.org/2000/svg" width="800" height="600"/>"#),
    };
    let mut session = Session::new(Model::new(doc, None));

    let (tx, rx) = mpsc::channel::<Event>();
    std::thread::spawn(move || {
        let stdin = std::io::stdin();
        for line in stdin.lock().lines() {
            match line {
                Ok(l) if l.trim().is_empty() => continue,
                Ok(l) => {
                    if tx.send(Event::Line(l)).is_err() {
                        return;
                    }
                }
                Err(_) => break,
            }
        }
        let _ = tx.send(Event::Eof);
    });

    let stdout = std::io::stdout();
    for event in rx {
        let out = match event {
            Event::Line(l) => session.handle(&l),
            Event::Eof => break,
        };
        let mut w = stdout.lock();
        for line in out {
            // One JSON-RPC message per line (the stdio transport's framing).
            if writeln!(w, "{line}").and_then(|_| w.flush()).is_err() {
                return;
            }
        }
    }
}
