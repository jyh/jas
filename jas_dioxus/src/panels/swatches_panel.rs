//! Swatches panel menu definition.
//!
//! Menu items mirror the `menu:` block in
//! `workspace/panels/swatches.yaml`. The dynamic submenu
//! ("Open Swatch Library") and a couple of data-mutating actions
//! (open_swatch_library, save_swatch_library) are placeholders that
//! log and no-op until the library-load / library-save plumbing lands.
//!
//! Wired: thumbnail size (st.swatches_panel.thumbnail_size),
//! duplicate_swatch, delete_swatch (no undo, see SWP-122),
//! sort_swatches_by_name, select_all_unused_swatches, add_used_colors.

use std::collections::HashSet;
use crate::workspace::app_state::AppState;
use crate::workspace::workspace::PanelAddr;
use crate::geometry::element::Element;
use super::panel_menu::PanelMenuItem;

/// Walk the document's element tree and collect every fill / stroke
/// color as a lowercase 6-character hex string (no `#` prefix).
/// Used by select_all_unused_swatches and add_used_colors to compare
/// document colors against library swatches.
fn collect_document_colors(state: &AppState) -> HashSet<String> {
    let mut colors = HashSet::new();
    let Some(tab) = state.tab() else { return colors; };
    let doc = tab.model.document();
    for layer in &doc.layers {
        walk_element(layer, &mut colors);
    }
    colors
}

fn walk_element(el: &Element, colors: &mut HashSet<String>) {
    if let Some(fill) = el.fill() {
        colors.insert(fill.color.to_hex());
    }
    if let Some(stroke) = el.stroke() {
        colors.insert(stroke.color.to_hex());
    }
    if let Some(children) = el.children() {
        for child in children {
            walk_element(child, colors);
        }
    }
}

/// Menu items for the Swatches panel.
pub fn menu_items() -> Vec<PanelMenuItem> {
    vec![
        PanelMenuItem::Action {
            label: "New Swatch",
            command: "new_swatch",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Duplicate Swatch",
            command: "duplicate_swatch",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Delete Swatch",
            command: "delete_swatch",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Select All Unused",
            command: "select_all_unused_swatches",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Add Used Colors",
            command: "add_used_colors",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Sort by Name",
            command: "sort_swatches_by_name",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Radio {
            label: "Small Thumbnail View",
            command: "set_swatch_thumbnail_small",
            group: "thumbnail_size",
        },
        PanelMenuItem::Radio {
            label: "Medium Thumbnail View",
            command: "set_swatch_thumbnail_medium",
            group: "thumbnail_size",
        },
        PanelMenuItem::Radio {
            label: "Large Thumbnail View",
            command: "set_swatch_thumbnail_large",
            group: "thumbnail_size",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Swatch Options...",
            command: "open_swatch_options",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        // The "Open Swatch Library" dynamic submenu would list every
        // workspace/swatches/*.json file. The PanelMenuItem enum
        // doesn't support submenus yet; surface as a placeholder
        // action for now.
        PanelMenuItem::Action {
            label: "Open Swatch Library...",
            command: "open_swatch_library",
            shortcut: "",
        },
        PanelMenuItem::Action {
            label: "Save Swatch Library",
            command: "save_swatch_library",
            shortcut: "",
        },
        PanelMenuItem::Separator,
        PanelMenuItem::Action {
            label: "Close Swatches",
            command: "close_panel",
            shortcut: "",
        },
    ]
}

/// Dispatch a menu command for the Swatches panel.
pub fn dispatch(cmd: &str, addr: PanelAddr, state: &mut AppState) {
    match cmd {
        "close_panel" => state.workspace_layout.close_panel(addr),
        "set_swatch_thumbnail_small" => {
            state.swatches_panel.thumbnail_size = "small".into();
        }
        "set_swatch_thumbnail_medium" => {
            state.swatches_panel.thumbnail_size = "medium".into();
        }
        "set_swatch_thumbnail_large" => {
            state.swatches_panel.thumbnail_size = "large".into();
        }
        "sort_swatches_by_name" => {
            // Alphabetical (case-sensitive ASCII) reorder of the
            // active library. Selection is cleared because index
            // identifiers no longer point at the same swatch.
            let lib_id = state.swatches_panel.selected_library.clone();
            if let Some(lib) = state.swatch_libraries.get_mut(&lib_id) {
                if let Some(swatches) = lib.get_mut("swatches").and_then(|s| s.as_array_mut()) {
                    swatches.sort_by(|a, b| {
                        let na = a.get("name").and_then(|n| n.as_str()).unwrap_or("");
                        let nb = b.get("name").and_then(|n| n.as_str()).unwrap_or("");
                        na.cmp(nb)
                    });
                }
            }
            state.swatches_panel.selected_swatches.clear();
        }
        "select_all_unused_swatches" => {
            // Select indices of swatches in the active library whose
            // color is NOT used anywhere in the current document. An
            // empty document marks every swatch as unused.
            let used = collect_document_colors(state);
            let lib_id = state.swatches_panel.selected_library.clone();
            let mut unused: Vec<i64> = Vec::new();
            if let Some(lib) = state.swatch_libraries.get(&lib_id) {
                if let Some(swatches) = lib.get("swatches").and_then(|s| s.as_array()) {
                    for (i, sw) in swatches.iter().enumerate() {
                        let hex = sw.get("color")
                            .and_then(|c| c.as_str())
                            .map(|c| c.trim_start_matches('#').to_lowercase())
                            .unwrap_or_default();
                        if !used.contains(&hex) {
                            unused.push(i as i64);
                        }
                    }
                }
            }
            state.swatches_panel.selected_swatches = unused;
        }
        "add_used_colors" => {
            // For each unique color used in the document that is not
            // already in the active library, append a new swatch
            // named "R={r} G={g} B={b}" (matching SWP-140's expected
            // labels). Comparison is by lowercase hex; no near-match.
            let used = collect_document_colors(state);
            let lib_id = state.swatches_panel.selected_library.clone();
            if let Some(lib) = state.swatch_libraries.get_mut(&lib_id) {
                if let Some(swatches) = lib.get_mut("swatches").and_then(|s| s.as_array_mut()) {
                    let existing: HashSet<String> = swatches.iter()
                        .filter_map(|s| s.get("color")
                            .and_then(|c| c.as_str())
                            .map(|c| c.trim_start_matches('#').to_lowercase()))
                        .collect();
                    // Sort the hex set so the order is deterministic.
                    let mut sorted_used: Vec<String> = used.into_iter().collect();
                    sorted_used.sort();
                    for hex in sorted_used {
                        if existing.contains(&hex) || hex.len() != 6 {
                            continue;
                        }
                        let r = u8::from_str_radix(&hex[0..2], 16).unwrap_or(0);
                        let g = u8::from_str_radix(&hex[2..4], 16).unwrap_or(0);
                        let b = u8::from_str_radix(&hex[4..6], 16).unwrap_or(0);
                        swatches.push(serde_json::json!({
                            "name": format!("R={r} G={g} B={b}"),
                            "color": format!("#{hex}"),
                            "color_mode": "rgb",
                            "color_type": "process",
                            "global": false,
                        }));
                    }
                }
            }
        }
        "delete_swatch" => {
            // Remove each selected swatch from the active library.
            // Iterate indices in descending order so each removal
            // doesn't shift the remaining selected positions. Selection
            // is cleared. No undo (SWP-122 known-broken).
            let lib_id = state.swatches_panel.selected_library.clone();
            let mut sorted = state.swatches_panel.selected_swatches.clone();
            sorted.sort_unstable_by(|a, b| b.cmp(a)); // descending
            if let Some(lib) = state.swatch_libraries.get_mut(&lib_id) {
                if let Some(swatches) = lib.get_mut("swatches").and_then(|s| s.as_array_mut()) {
                    for idx in sorted {
                        let i = idx as usize;
                        if i < swatches.len() {
                            swatches.remove(i);
                        }
                    }
                }
            }
            state.swatches_panel.selected_swatches.clear();
        }
        "duplicate_swatch" => {
            // Forward-iterate selected indices in ascending order;
            // each insert shifts subsequent originals by 1, tracked
            // via `offset`. New copy keeps the original's color and
            // metadata, with " copy" appended to the name. Selection
            // moves to the new copies.
            let lib_id = state.swatches_panel.selected_library.clone();
            let mut sorted = state.swatches_panel.selected_swatches.clone();
            sorted.sort_unstable();
            let mut new_selection: Vec<i64> = Vec::with_capacity(sorted.len());
            if let Some(lib) = state.swatch_libraries.get_mut(&lib_id) {
                if let Some(swatches) = lib.get_mut("swatches").and_then(|s| s.as_array_mut()) {
                    let mut offset: usize = 0;
                    for orig_idx in sorted {
                        let pos = orig_idx as usize + offset;
                        if pos >= swatches.len() { continue; }
                        let mut copy = swatches[pos].clone();
                        let orig_name = copy.get("name")
                            .and_then(|n| n.as_str())
                            .unwrap_or("")
                            .to_string();
                        copy["name"] = serde_json::Value::String(format!("{orig_name} copy"));
                        swatches.insert(pos + 1, copy);
                        new_selection.push((pos + 1) as i64);
                        offset += 1;
                    }
                }
            }
            state.swatches_panel.selected_swatches = new_selection;
        }
        // Other actions are placeholders — see module doc. Logging
        // helps surface unwired commands during manual testing.
        "new_swatch"
        | "open_swatch_options"
        | "open_swatch_library"
        | "save_swatch_library" => {
            web_sys::console::log_1(
                &format!("[swatches] command '{cmd}' is not yet wired").into());
        }
        _ => {}
    }
}

/// Query whether a toggle / radio command is checked.
pub fn is_checked(cmd: &str, state: &AppState) -> bool {
    let size = state.swatches_panel.thumbnail_size.as_str();
    match cmd {
        "set_swatch_thumbnail_small" => size == "small",
        "set_swatch_thumbnail_medium" => size == "medium",
        "set_swatch_thumbnail_large" => size == "large",
        _ => false,
    }
}

/// Query whether a menu command is enabled. Mirrors the `enabled_when`
/// expressions in `workspace/panels/swatches.yaml`.
pub fn is_enabled(cmd: &str, state: &AppState) -> bool {
    match cmd {
        // Both gated on at least one swatch being selected.
        "duplicate_swatch" | "delete_swatch" => {
            !state.swatches_panel.selected_swatches.is_empty()
        }
        _ => true,
    }
}
