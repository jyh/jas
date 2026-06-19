/// CLI tool for cross-language workspace layout testing.
///
/// Usage:
///   workspace_roundtrip default                       -- output canonical JSON for default_layout()
///   workspace_roundtrip default_with_panes <w> <h>    -- output canonical JSON with pane layout
///   workspace_roundtrip parse <workspace.json>        -- parse workspace JSON, output canonical test JSON
///   workspace_roundtrip apply <workspace.json>        -- parse, apply ops from stdin, output canonical test JSON

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: {} default|default_with_panes|parse|apply ...", args[0]);
        std::process::exit(1);
    }

    let mode = &args[1];

    match mode.as_str() {
        "default" => {
            let layout = jas_dioxus::workspace::workspace::WorkspaceLayout::default_layout();
            print!("{}", jas_dioxus::workspace::test_json::workspace_to_test_json(&layout));
        }
        "default_with_panes" => {
            if args.len() < 4 {
                eprintln!("Usage: {} default_with_panes <width> <height>", args[0]);
                std::process::exit(1);
            }
            let w: f64 = args[2].parse().unwrap_or_else(|_| {
                eprintln!("Invalid width: {}", args[2]);
                std::process::exit(1);
            });
            let h: f64 = args[3].parse().unwrap_or_else(|_| {
                eprintln!("Invalid height: {}", args[3]);
                std::process::exit(1);
            });
            let mut layout = jas_dioxus::workspace::workspace::WorkspaceLayout::default_layout();
            layout.ensure_pane_layout(w, h);
            print!("{}", jas_dioxus::workspace::test_json::workspace_to_test_json(&layout));
        }
        "parse" => {
            if args.len() < 3 {
                eprintln!("Usage: {} parse <workspace.json>", args[0]);
                std::process::exit(1);
            }
            let json = std::fs::read_to_string(&args[2])
                .unwrap_or_else(|e| { eprintln!("Failed to read {}: {}", args[2], e); std::process::exit(1); });
            let layout = jas_dioxus::workspace::test_json::test_json_to_workspace(json.trim());
            print!("{}", jas_dioxus::workspace::test_json::workspace_to_test_json(&layout));
        }
        "apply" => {
            if args.len() < 3 {
                eprintln!("Usage: {} apply <workspace.json>  (ops from stdin)", args[0]);
                std::process::exit(1);
            }
            let json = std::fs::read_to_string(&args[2])
                .unwrap_or_else(|e| { eprintln!("Failed to read {}: {}", args[2], e); std::process::exit(1); });
            let mut layout = jas_dioxus::workspace::test_json::test_json_to_workspace(json.trim());

            let mut ops_str = String::new();
            std::io::Read::read_to_string(&mut std::io::stdin(), &mut ops_str)
                .unwrap_or_else(|e| { eprintln!("Failed to read stdin: {}", e); std::process::exit(1); });

            let ops: serde_json::Value = serde_json::from_str(&ops_str)
                .unwrap_or_else(|e| { eprintln!("Failed to parse ops JSON: {}", e); std::process::exit(1); });

            for op in ops.as_array().unwrap_or(&vec![]) {
                apply_op(&mut layout, op);
            }

            print!("{}", jas_dioxus::workspace::test_json::workspace_to_test_json(&layout));
        }
        _ => {
            eprintln!("Unknown mode: {} (use 'default', 'default_with_panes', 'parse', or 'apply')", mode);
            std::process::exit(1);
        }
    }
}

/// Apply one primitive LAYOUT op to `layout`. Delegates to the SINGLE runtime
/// dispatcher `jas_dioxus::workspace::layout_apply::layout_apply` — the SAME
/// per-verb mutation body the production layout-mutation sites and the
/// `cross_language_test.rs` harness shim route through (3d-2, OP_LOG.md §12 Fork
/// 5). This CLI is the cross-language test oracle the other apps validate
/// against; sharing the one dispatcher means the in-process corpus and the CLI
/// oracle cannot drift in op-shape or behavior — there is exactly ONE layout
/// verb body in the crate now.
///
/// `layout_apply` is hardened to SKIP a malformed/unknown op rather than panic.
/// The cross-language corpus only ever feeds well-formed, known verbs, so the
/// prior per-verb `.unwrap()` parsing and the `Unknown workspace op` exit are
/// unreachable on the real input; keeping the unknown-verb diagnostic for CLI
/// users is retained as a thin pre-check below before delegating.
fn apply_op(layout: &mut jas_dioxus::workspace::workspace::WorkspaceLayout, op: &serde_json::Value) {
    // Preserve the CLI's loud-fail on an unrecognized verb (the runtime
    // dispatcher silently skips, which is right for production but unhelpful for
    // a test-oracle invocation fed a typo). The KNOWN-verb set must stay in sync
    // with `layout_apply`'s match arms.
    const KNOWN: &[&str] = &[
        "toggle_group_collapsed", "set_active_panel", "close_panel", "show_panel",
        "reorder_panel", "move_panel_to_group", "detach_group", "redock",
        "set_pane_position", "tile_panes", "toggle_canvas_maximized", "resize_pane",
        "hide_pane", "show_pane", "bring_pane_to_front",
    ];
    match op["op"].as_str() {
        Some(name) if KNOWN.contains(&name) => {}
        other => {
            eprintln!("Unknown workspace op: {}", other.unwrap_or("<missing>"));
            std::process::exit(1);
        }
    }
    jas_dioxus::workspace::layout_apply::layout_apply(layout, op);
}
