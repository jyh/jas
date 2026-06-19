/// The single LAYOUT-op dispatcher — `layoutApply` (OP_LOG.md §12, Fork 5,
/// Increment 3d-2). The layout analogue of `Document` op-apply.
///
/// PROMOTED from the cross-language test harness (`applyWorkspaceOp` in
/// `Tests/CrossLanguageTests.swift`) into a RUNTIME module so production layout
/// mutations and the test harness share ONE dispatcher and ONE per-verb
/// mutation body. The harness shim now delegates here, and the production
/// layout-mutation sites (menu / dock-panel / the per-panel hamburger menus /
/// toolbar) build a resolved op dictionary and call `layoutApply` instead of
/// calling `WorkspaceLayout.<method>` directly. The mutation is byte-identical
/// to the pre-3d-2 direct call (same args, now serialized -> dispatched ->
/// parsed).
///
/// LAYOUT STAYS NON-UNDOABLE (OP_LOG.md §12, Option B): there is NO layout
/// journal, NO layout undo, and NO checkpoint-equivalence gate (that is Option
/// C, deliberately NOT done). `layoutApply` is purely the shared parse -> apply
/// envelope; the per-verb `WorkspaceLayout` mutators already call `bump()`
/// internally (the dirty signal), which the caller's save/`saveIfNeeded` path
/// reads via `needsSave()` to persist — unchanged.
///
/// Production input must never crash, so every param read is HARDENED: numbers
/// resolve via `intOf`/`doubleOf` (missing/garbage -> 0); a missing REQUIRED
/// string (the verb name, a panel/pane `kind`) returns/skips rather than
/// force-unwrapping; a malformed op skips. The harness fixtures (which always
/// carry well-formed params) replay byte-identically.

import Foundation

// MARK: - Kind parse / serialize (complete over all 13 PanelKinds)

/// Parse a panel-kind string to its `PanelKind`. Complete over all 13 kinds; an
/// unknown/garbage string falls back to `.layers` so a malformed op never
/// crashes. (The pre-3d-2 harness shim had a 4-kind subset; the runtime
/// dispatcher needs the full set because the production `show_panel` handler
/// covers every `PanelKind`.)
func layoutParsePanelKind(_ s: String) -> PanelKind {
    switch s {
    case "color": return .color
    case "swatches": return .swatches
    case "stroke": return .stroke
    case "properties": return .properties
    case "character": return .character
    case "paragraph": return .paragraph
    case "artboards": return .artboards
    case "align": return .align
    case "boolean": return .boolean
    case "opacity": return .opacity
    case "magic_wand": return .magicWand
    case "symbols": return .symbols
    default: return .layers
    }
}

/// Serialize a `PanelKind` to its canonical lowercase op string (the inverse of
/// `layoutParsePanelKind`). Production `show_panel` sites use this to build the
/// op dictionary, so the round-trip is lossless across all 13 kinds.
public func layoutPanelKindStr(_ k: PanelKind) -> String {
    switch k {
    case .layers: return "layers"
    case .color: return "color"
    case .swatches: return "swatches"
    case .stroke: return "stroke"
    case .properties: return "properties"
    case .character: return "character"
    case .paragraph: return "paragraph"
    case .artboards: return "artboards"
    case .align: return "align"
    case .boolean: return "boolean"
    case .opacity: return "opacity"
    case .magicWand: return "magic_wand"
    case .symbols: return "symbols"
    }
}

/// Parse a pane-kind string to its `PaneKind`. Unknown falls back to `.canvas`.
func layoutParsePaneKind(_ s: String) -> PaneKind {
    switch s {
    case "toolbar": return .toolbar
    case "dock": return .dock
    default: return .canvas
    }
}

/// Serialize a `PaneKind` to its canonical op string (inverse of
/// `layoutParsePaneKind`).
public func layoutPaneKindStr(_ k: PaneKind) -> String {
    switch k {
    case .toolbar: return "toolbar"
    case .canvas: return "canvas"
    case .dock: return "dock"
    }
}

// MARK: - Op builders (production -> dispatcher)
//
// Production layout-mutation sites build their op via these typed constructors
// and pass the result to `layoutApply`, so the op SHAPE for each verb lives in
// exactly one place (alongside the parser above) and a shape drift between the
// producer and the consumer is impossible. Each builder mirrors the field names
// the matching `layoutApply` arm reads.

/// `{op:"close_panel", dock_id, group_idx, panel_idx}`.
public func opClosePanel(_ addr: PanelAddr) -> [String: Any] {
    ["op": "close_panel",
     "dock_id": addr.group.dockId.value,
     "group_idx": addr.group.groupIdx,
     "panel_idx": addr.panelIdx]
}

/// `{op:"set_active_panel", dock_id, group_idx, panel_idx}`.
public func opSetActivePanel(_ addr: PanelAddr) -> [String: Any] {
    ["op": "set_active_panel",
     "dock_id": addr.group.dockId.value,
     "group_idx": addr.group.groupIdx,
     "panel_idx": addr.panelIdx]
}

/// `{op:"show_panel", kind}`.
public func opShowPanel(_ kind: PanelKind) -> [String: Any] {
    ["op": "show_panel", "kind": layoutPanelKindStr(kind)]
}

/// `{op:"toggle_group_collapsed", dock_id, group_idx}`.
public func opToggleGroupCollapsed(_ addr: GroupAddr) -> [String: Any] {
    ["op": "toggle_group_collapsed",
     "dock_id": addr.dockId.value,
     "group_idx": addr.groupIdx]
}

/// `{op:"reorder_panel", dock_id, group_idx, from, to}`.
public func opReorderPanel(_ group: GroupAddr, from: Int, to: Int) -> [String: Any] {
    ["op": "reorder_panel",
     "dock_id": group.dockId.value,
     "group_idx": group.groupIdx,
     "from": from,
     "to": to]
}

/// `{op:"move_panel_to_group", from_*, to_*}`.
public func opMovePanelToGroup(_ from: PanelAddr, to: GroupAddr) -> [String: Any] {
    ["op": "move_panel_to_group",
     "from_dock_id": from.group.dockId.value,
     "from_group_idx": from.group.groupIdx,
     "from_panel_idx": from.panelIdx,
     "to_dock_id": to.dockId.value,
     "to_group_idx": to.groupIdx]
}

/// `{op:"redock", dock_id}`.
public func opRedock(_ id: DockId) -> [String: Any] {
    ["op": "redock", "dock_id": id.value]
}

/// `{op:"hide_pane", kind}`.
public func opHidePane(_ kind: PaneKind) -> [String: Any] {
    ["op": "hide_pane", "kind": layoutPaneKindStr(kind)]
}

/// `{op:"show_pane", kind}`.
public func opShowPane(_ kind: PaneKind) -> [String: Any] {
    ["op": "show_pane", "kind": layoutPaneKindStr(kind)]
}

/// `{op:"bring_pane_to_front", pane_id}`.
public func opBringPaneToFront(_ id: PaneId) -> [String: Any] {
    ["op": "bring_pane_to_front", "pane_id": id.value]
}

/// `{op:"toggle_canvas_maximized"}` — no params (the verb is a pure toggle of
/// `PaneLayout.canvasMaximized`).
public func opToggleCanvasMaximized() -> [String: Any] {
    ["op": "toggle_canvas_maximized"]
}

/// `{op:"tile_panes", [set_canvas_maximized], [override_pane_id, override_width]}`.
/// `setCanvasMaximized` is opt-in: when `nil` the field is omitted and the
/// dispatcher leaves `canvasMaximized` untouched (the plain Swift menu/corpus
/// path — Swift's pre-3d-2 menu Tile did NOT clear canvas maximization, so
/// omitting the field preserves that exact behavior). `overridePane` is the
/// collapsed-dock fixed-width override the dock title-bar collapse handler
/// supplies (`nil` for the plain path).
public func opTilePanes(setCanvasMaximized: Bool?,
                        overridePane: (PaneId, Double)?) -> [String: Any] {
    var v: [String: Any] = ["op": "tile_panes"]
    if let b = setCanvasMaximized {
        v["set_canvas_maximized"] = b
    }
    if let (pid, w) = overridePane {
        v["override_pane_id"] = pid.value
        v["override_width"] = w
    }
    return v
}

// MARK: - Hardened readers
//
// A malformed production payload never crashes. A missing/wrong-typed numeric
// field reads as 0, mirroring the document op-apply discipline (the harness
// fixtures always carry well-formed params, so they replay byte-identically).
// JSONSerialization yields `NSNumber`, while op-builders write native
// `Int`/`Double`; both coerce here.

@inline(__always)
private func intOf(_ op: [String: Any], _ key: String) -> Int {
    if let n = op[key] as? Int { return n }
    if let n = op[key] as? NSNumber { return n.intValue }
    if let d = op[key] as? Double { return Int(d) }
    return 0
}

@inline(__always)
private func doubleOf(_ op: [String: Any], _ key: String) -> Double {
    if let d = op[key] as? Double { return d }
    if let n = op[key] as? NSNumber { return n.doubleValue }
    if let i = op[key] as? Int { return Double(i) }
    return 0.0
}

@inline(__always)
private func boolOf(_ op: [String: Any], _ key: String) -> Bool? {
    if let b = op[key] as? Bool { return b }
    if let n = op[key] as? NSNumber { return n.boolValue }
    return nil
}

@inline(__always)
private func stringOf(_ op: [String: Any], _ key: String) -> String? {
    op[key] as? String
}

// MARK: - The dispatcher

/// Apply one primitive LAYOUT op to `layout`. The SINGLE per-verb mutation body
/// shared by production and the cross-language harness. Hardened: an unknown
/// verb or a missing required `kind`/`op` string SKIPS (no crash, no mutation).
public func layoutApply(_ layout: inout WorkspaceLayout, _ op: [String: Any]) {
    guard let name = stringOf(op, "op") else { return } // malformed op envelope: skip
    switch name {
    // ---- Panel / dock operations (mutate WorkspaceLayout directly) ----
    case "toggle_group_collapsed":
        layout.toggleGroupCollapsed(GroupAddr(
            dockId: DockId(intOf(op, "dock_id")),
            groupIdx: intOf(op, "group_idx")))

    case "set_active_panel":
        layout.setActivePanel(PanelAddr(
            group: GroupAddr(
                dockId: DockId(intOf(op, "dock_id")),
                groupIdx: intOf(op, "group_idx")),
            panelIdx: intOf(op, "panel_idx")))

    case "close_panel":
        layout.closePanel(PanelAddr(
            group: GroupAddr(
                dockId: DockId(intOf(op, "dock_id")),
                groupIdx: intOf(op, "group_idx")),
            panelIdx: intOf(op, "panel_idx")))

    case "show_panel":
        guard let s = stringOf(op, "kind") else { return } // required field missing: skip
        layout.showPanel(layoutParsePanelKind(s))

    case "reorder_panel":
        layout.reorderPanel(
            GroupAddr(
                dockId: DockId(intOf(op, "dock_id")),
                groupIdx: intOf(op, "group_idx")),
            from: intOf(op, "from"),
            to: intOf(op, "to"))

    case "move_panel_to_group":
        layout.movePanelToGroup(
            PanelAddr(
                group: GroupAddr(
                    dockId: DockId(intOf(op, "from_dock_id")),
                    groupIdx: intOf(op, "from_group_idx")),
                panelIdx: intOf(op, "from_panel_idx")),
            to: GroupAddr(
                dockId: DockId(intOf(op, "to_dock_id")),
                groupIdx: intOf(op, "to_group_idx")))

    case "detach_group":
        _ = layout.detachGroup(
            GroupAddr(
                dockId: DockId(intOf(op, "dock_id")),
                groupIdx: intOf(op, "group_idx")),
            x: doubleOf(op, "x"),
            y: doubleOf(op, "y"))

    case "redock":
        layout.redock(DockId(intOf(op, "dock_id")))

    // ---- Pane operations (mutate the inner PaneLayout) ----
    // `panesMut` is itself the `if let Some(pl) = pane_layout` guard: it
    // mutates (and bumps) only when a pane layout exists, matching the
    // production handlers and the Rust `pane_layout.as_mut()` early-return.
    case "set_pane_position":
        layout.panesMut { pl in
            pl.setPanePosition(PaneId(intOf(op, "pane_id")),
                               x: doubleOf(op, "x"),
                               y: doubleOf(op, "y"))
        }

    case "tile_panes":
        layout.panesMut { pl in
            // The menu "Tile" handler clears canvas maximization before tiling;
            // it is opt-in via the explicit `set_canvas_maximized` bool param so
            // the bare-`{"op":"tile_panes"}` fixture path is unchanged.
            if let b = boolOf(op, "set_canvas_maximized") {
                pl.canvasMaximized = b
            }
            // Optional override: a collapsed dock is tiled at a fixed width.
            // Absent in the fixture (which tiles with `collapsedOverride: nil`);
            // present only from the menu handler when the right dock is collapsed.
            let override_: (PaneId, Double)?
            if op["override_pane_id"] != nil, op["override_width"] != nil {
                override_ = (PaneId(intOf(op, "override_pane_id")),
                             doubleOf(op, "override_width"))
            } else {
                override_ = nil
            }
            pl.tilePanes(collapsedOverride: override_)
        }

    case "toggle_canvas_maximized":
        layout.panesMut { pl in
            pl.toggleCanvasMaximized()
        }

    case "resize_pane":
        layout.panesMut { pl in
            pl.resizePane(PaneId(intOf(op, "pane_id")),
                          width: doubleOf(op, "width"),
                          height: doubleOf(op, "height"))
        }

    case "hide_pane":
        guard let s = stringOf(op, "kind") else { return } // required field missing: skip
        layout.panesMut { pl in
            pl.hidePane(layoutParsePaneKind(s))
        }

    case "show_pane":
        guard let s = stringOf(op, "kind") else { return } // required field missing: skip
        layout.panesMut { pl in
            pl.showPane(layoutParsePaneKind(s))
        }

    case "bring_pane_to_front":
        layout.panesMut { pl in
            pl.bringPaneToFront(PaneId(intOf(op, "pane_id")))
        }

    // Unknown verb: skip rather than crash (a malformed / forward-compat op
    // must not crash production; the corpus only ever sends known verbs).
    default:
        break
    }
}
