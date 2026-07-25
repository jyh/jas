import Testing
import Foundation
@testable import JasLib

// SWIFTCONTAINER — declared pointer behaviors must not be silently dropped.
// ─────────────────────────────────────────────────────────────────────────
//
// The live bug (ported from the Rust BRUSHDEAD fix): clicking a
// Brushes-panel brush tile did NOTHING — no apply, no state change, not even
// the tile's own selected-outline cue. The tile is a `type: container`
// carrying `behavior: [click, double_click]`, but `renderContainer` built a
// plain box with no tap gesture, so the declared behavior never reached the
// dispatcher. That is the finding-#26 disease: a widget-type render arm that
// silently drops declared behaviors. The same drop lived in `renderText`
// (Artboards / Symbols / Concepts list rows carry their `*_panel_select`
// click on a `text` widget).
//
// These pins mirror jas_dioxus renderer.rs
// (`every_click_bearing_widget_type_is_pointer_wired`,
// `brush_tile_container_is_interactive`, `eval_selected_in_...`) so the SAME
// authoritative contract gates both active ports (CLAUDE.md — equivalence
// prime directive).

// MARK: - Authoritative contract

/// Every widget `type` whose Swift render arm attaches a pointer (tap /
/// double-tap / press) handler built from the element's declared `behavior`
/// list. Grep contract: each type here wires a tap gesture in its `render_*`
/// arm — `renderContainer` / `renderText` via `PointerBehaviorModifier`
/// (single → `handleWidgetClick`, double → `handleBehaviorClick`),
/// `renderIconButton` / `renderButton` / `renderToggle` via a SwiftUI
/// `Button` / `Toggle`, `renderColorSwatch` / `renderGradientTile` /
/// `renderGradientSlider` via `.onTapGesture`, and `renderTreeView` via the
/// native Layers tree. If you give a NEW widget type a click behavior in the
/// YAML you MUST both wire its tap in the render arm and register it here, or
/// `everyClickBearingWidgetTypeIsPointerWired` fails.
///
/// Scope (mirrors the Rust pin): the demonstrated defect class —
/// click-family pointer behaviors (`click` / `double_click` /
/// `click_and_wait`). change/commit/input behaviors ride each input arm's
/// native onChange/onCommit closure and drag/toggle ride their own
/// subsystems; those are out of scope here.
private func wiresPointerClick(_ widgetType: String) -> Bool {
    switch widgetType {
    case "container", "row", "col",   // renderContainer
         "icon_button",               // renderIconButton
         "color_swatch",              // renderColorSwatch
         "gradient_tile",             // renderGradientTile
         "gradient_slider",           // renderGradientSlider
         "text",                      // renderText
         "button",                    // renderButton
         "toggle", "checkbox",        // renderToggle
         "tree_view":                 // renderTreeView (native)
        return true
    default:
        return false
    }
}

/// Collect `(type, event)` for every node whose `behavior[]` declares a
/// click-family pointer event, walking the compiled bundle.
private func collectClickBearing(_ node: Any, _ out: inout [(String, String)]) {
    if let map = node as? [String: Any] {
        if let t = map["type"] as? String, let behaviors = map["behavior"] as? [Any] {
            for bAny in behaviors {
                guard let b = bAny as? [String: Any] else { continue }
                let ev = (b["event"] as? String) ?? "click"
                if ev == "click" || ev == "double_click" || ev == "click_and_wait" {
                    out.append((t, ev))
                }
            }
        }
        for v in map.values { collectClickBearing(v, &out) }
    } else if let arr = node as? [Any] {
        for v in arr { collectClickBearing(v, &out) }
    }
}

/// First node in the bundle whose `id` matches `want` (ids may carry
/// `{{...}}` templating, matched literally).
private func findById(_ node: Any, _ want: String) -> [String: Any]? {
    if let map = node as? [String: Any] {
        if (map["id"] as? String) == want { return map }
        for v in map.values { if let r = findById(v, want) { return r } }
    } else if let arr = node as? [Any] {
        for v in arr { if let r = findById(v, want) { return r } }
    }
    return nil
}

// MARK: - Completeness pin

// Walk the COMPILED bundle (workspace.json) and assert every widget type
// carrying a click-family behavior maps to a render arm that wires a pointer
// handler. This is the guard against the whole class: if a render arm
// silently drops declared pointer behaviors (as renderContainer / renderText
// did), any bundle widget of that type is dead — and this test names it.
@Test func everyClickBearingWidgetTypeIsPointerWired() {
    guard let ws = WorkspaceData.load() else {
        Issue.record("workspace bundle failed to load")
        return
    }
    var found: [(String, String)] = []
    collectClickBearing(ws.data, &found)

    // Sanity: the bundle actually carries click behaviors (guards against a
    // walker that silently finds nothing).
    #expect(!found.isEmpty, "bundle should declare click-family behaviors on widgets")

    let unwired = Array(Set(
        found.filter { !wiresPointerClick($0.0) }.map { "\($0.0)/\($0.1)" }
    )).sorted()
    #expect(
        unwired.isEmpty,
        """
        widget types carry a click/double_click behavior in the bundle but \
        their render arm attaches no pointer handler (silently dead clicks — \
        the SWIFTCONTAINER/BRUSHDEAD disease): \(unwired)
        """
    )

    // The container fix specifically must be represented: the bundle DOES
    // ship a click-bearing container (the brush tile), so this must be a live
    // case, not a hypothetical.
    #expect(
        found.contains { $0.0 == "container" },
        "expected a click-bearing container in the bundle (the brush tile)"
    )
}

// MARK: - Brushes-specific pin

// The brush tile must be a container that declares BOTH a click behavior
// (select + set stroke_brush + apply) and a double_click behavior (open
// options), and `renderContainer` must treat that shape as interactive.
// `widgetHasPointerBehavior` is the exact predicate renderContainer gates its
// interactive branch on, so asserting it here locks the wiring decision for
// the tile.
@Test func brushTileContainerIsInteractive() {
    guard let ws = WorkspaceData.load() else {
        Issue.record("workspace bundle failed to load")
        return
    }
    guard let tile = findById(ws.data, "bp_tile_{{lib.id}}_{{brush.slug}}") else {
        Issue.record("brush tile present in compiled bundle")
        return
    }

    #expect((tile["type"] as? String) == "container", "brush tile is a container")

    let events = ((tile["behavior"] as? [Any]) ?? [])
        .compactMap { ($0 as? [String: Any])?["event"] as? String }
    #expect(events.contains("click"), "tile declares a click behavior")
    #expect(events.contains("double_click"), "tile declares a double_click behavior")

    // The render arm's own interactivity gate must fire for this node.
    #expect(
        widgetHasPointerBehavior(tile),
        "renderContainer must classify the brush tile as interactive"
    )
    // And the tile's type must be pointer-wired per the contract.
    #expect(wiresPointerClick("container"))
}

// The tile also carries a `selected_in` bind for its highlight; the shared
// `widgetSelectedIn` must report membership so the accent outline shows once
// the brush is in `panel.selected_brushes`.
@Test func evalSelectedInMatchesBundleTileShape() {
    // Mirror the tile: identity is read from the click behavior's first
    // `select.target` (here a literal), tested against the bound list.
    let el: [String: Any] = [
        "type": "container",
        "bind": ["selected_in": "panel.selected_brushes"],
        "behavior": [
            [
                "event": "click",
                "effects": [
                    ["select": ["target": "\"acme/round\"", "list": "selected_brushes"]]
                ]
            ]
        ]
    ]
    let ctxIn: [String: Any] = ["panel": ["selected_brushes": ["acme/round"]]]
    let ctxOut: [String: Any] = ["panel": ["selected_brushes": ["acme/flat"]]]
    #expect(widgetSelectedIn(el, context: ctxIn), "tile is selected when its id is in the list")
    #expect(!widgetSelectedIn(el, context: ctxOut), "tile is not selected otherwise")
}
