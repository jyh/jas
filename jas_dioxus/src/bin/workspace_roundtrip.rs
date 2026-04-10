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

fn apply_op(layout: &mut jas_dioxus::workspace::workspace::WorkspaceLayout, op: &serde_json::Value) {
    use jas_dioxus::workspace::workspace::*;

    let name = op["op"].as_str().unwrap();
    match name {
        "toggle_group_collapsed" => {
            layout.toggle_group_collapsed(GroupAddr {
                dock_id: DockId(op["dock_id"].as_u64().unwrap() as usize),
                group_idx: op["group_idx"].as_u64().unwrap() as usize,
            });
        }
        "set_active_panel" => {
            layout.set_active_panel(PanelAddr {
                group: GroupAddr {
                    dock_id: DockId(op["dock_id"].as_u64().unwrap() as usize),
                    group_idx: op["group_idx"].as_u64().unwrap() as usize,
                },
                panel_idx: op["panel_idx"].as_u64().unwrap() as usize,
            });
        }
        "close_panel" => {
            layout.close_panel(PanelAddr {
                group: GroupAddr {
                    dock_id: DockId(op["dock_id"].as_u64().unwrap() as usize),
                    group_idx: op["group_idx"].as_u64().unwrap() as usize,
                },
                panel_idx: op["panel_idx"].as_u64().unwrap() as usize,
            });
        }
        "show_panel" => {
            let kind = match op["kind"].as_str().unwrap() {
                "color" => PanelKind::Color,
                "stroke" => PanelKind::Stroke,
                "properties" => PanelKind::Properties,
                _ => PanelKind::Layers,
            };
            layout.show_panel(kind);
        }
        "reorder_panel" => {
            layout.reorder_panel(
                GroupAddr {
                    dock_id: DockId(op["dock_id"].as_u64().unwrap() as usize),
                    group_idx: op["group_idx"].as_u64().unwrap() as usize,
                },
                op["from"].as_u64().unwrap() as usize,
                op["to"].as_u64().unwrap() as usize,
            );
        }
        "move_panel_to_group" => {
            layout.move_panel_to_group(
                PanelAddr {
                    group: GroupAddr {
                        dock_id: DockId(op["from_dock_id"].as_u64().unwrap() as usize),
                        group_idx: op["from_group_idx"].as_u64().unwrap() as usize,
                    },
                    panel_idx: op["from_panel_idx"].as_u64().unwrap() as usize,
                },
                GroupAddr {
                    dock_id: DockId(op["to_dock_id"].as_u64().unwrap() as usize),
                    group_idx: op["to_group_idx"].as_u64().unwrap() as usize,
                },
            );
        }
        "detach_group" => {
            layout.detach_group(
                GroupAddr {
                    dock_id: DockId(op["dock_id"].as_u64().unwrap() as usize),
                    group_idx: op["group_idx"].as_u64().unwrap() as usize,
                },
                op["x"].as_f64().unwrap(),
                op["y"].as_f64().unwrap(),
            );
        }
        "redock" => {
            layout.redock(DockId(op["dock_id"].as_u64().unwrap() as usize));
        }
        "set_pane_position" => {
            let pl = layout.pane_layout.as_mut().unwrap();
            pl.set_pane_position(
                PaneId(op["pane_id"].as_u64().unwrap() as usize),
                op["x"].as_f64().unwrap(),
                op["y"].as_f64().unwrap(),
            );
        }
        "tile_panes" => {
            let pl = layout.pane_layout.as_mut().unwrap();
            pl.tile_panes(None);
        }
        "toggle_canvas_maximized" => {
            let pl = layout.pane_layout.as_mut().unwrap();
            pl.toggle_canvas_maximized();
        }
        "resize_pane" => {
            let pl = layout.pane_layout.as_mut().unwrap();
            pl.resize_pane(
                PaneId(op["pane_id"].as_u64().unwrap() as usize),
                op["width"].as_f64().unwrap(),
                op["height"].as_f64().unwrap(),
            );
        }
        "hide_pane" => {
            let pl = layout.pane_layout.as_mut().unwrap();
            let kind = match op["kind"].as_str().unwrap() {
                "toolbar" => PaneKind::Toolbar,
                "dock" => PaneKind::Dock,
                _ => PaneKind::Canvas,
            };
            pl.hide_pane(kind);
        }
        "show_pane" => {
            let pl = layout.pane_layout.as_mut().unwrap();
            let kind = match op["kind"].as_str().unwrap() {
                "toolbar" => PaneKind::Toolbar,
                "dock" => PaneKind::Dock,
                _ => PaneKind::Canvas,
            };
            pl.show_pane(kind);
        }
        "bring_pane_to_front" => {
            let pl = layout.pane_layout.as_mut().unwrap();
            pl.bring_pane_to_front(PaneId(op["pane_id"].as_u64().unwrap() as usize));
        }
        _ => {
            eprintln!("Unknown workspace op: {}", name);
            std::process::exit(1);
        }
    }
}
