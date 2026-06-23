/// Unit oracle for the toolbar tool-options double-click lookup +
/// dispatch resolution
/// (`Sources/Interpreter/WorkspaceLoader.swift` →
/// `resolveToolOptions` / `isToolButtonElement`).
///
/// Double-clicking a TOOLBAR tool button opens the ACTIVE tool's
/// options. The active tool's entry is looked up in the compiled bundle
/// `tools` map (NOT a hardcoded list) and its options are dispatched in
/// priority order: `tool_options_panel` → `tool_options_action` →
/// `tool_options_dialog`. A tool that declares none is a no-op.
///
/// The double-click is scoped to toolbar tool slots only: an
/// `icon_button` whose `behavior` carries a `click` event dispatching
/// `select_tool`. Panels and every other `icon_button` never match.

import Foundation
import Testing
@testable import JasLib

// MARK: - resolveToolOptions (priority + bundle-driven)

@Test func resolveToolOptionsReadsDialogFromBundle() {
    // The live bundle's paintbrush/blob_brush/scale/rotate/shear/
    // eyedropper tools declare tool_options_dialog. Resolve straight
    // from the compiled bundle (no hardcoded tool list).
    let tools = WorkspaceData.load()?.data["tools"] as? [String: Any] ?? [:]
    #expect(!tools.isEmpty, "bundle tools map should be present")

    #expect(resolveToolOptions(tools: tools, activeTool: "paintbrush")
            == .dialog("paintbrush_tool_options"))
    #expect(resolveToolOptions(tools: tools, activeTool: "blob_brush")
            == .dialog("blob_brush_tool_options"))
    #expect(resolveToolOptions(tools: tools, activeTool: "eyedropper")
            == .dialog("eyedropper_tool_options"))
    #expect(resolveToolOptions(tools: tools, activeTool: "scale")
            == .dialog("scale_options"))
    #expect(resolveToolOptions(tools: tools, activeTool: "rotate")
            == .dialog("rotate_options"))
    #expect(resolveToolOptions(tools: tools, activeTool: "shear")
            == .dialog("shear_options"))
}

@Test func resolveToolOptionsReadsPanelFromBundle() {
    // magic_wand declares tool_options_panel → magic_wand (the only
    // panel-options tool in the bundle today).
    let tools = WorkspaceData.load()?.data["tools"] as? [String: Any] ?? [:]
    #expect(resolveToolOptions(tools: tools, activeTool: "magic_wand")
            == .panel("magic_wand"))
    // …and the panel id maps to a real PanelKind, so the dispatch can
    // actually show a panel.
    #expect(panelIdToKind("magic_wand") == .magicWand)
}

@Test func resolveToolOptionsReadsActionFromBundle() {
    // hand → fit_active_artboard, zoom → zoom_to_actual_size,
    // artboard → fit_all_artboards. These are the view-action arm the
    // old native path never dispatched.
    let tools = WorkspaceData.load()?.data["tools"] as? [String: Any] ?? [:]
    #expect(resolveToolOptions(tools: tools, activeTool: "hand")
            == .action("fit_active_artboard"))
    #expect(resolveToolOptions(tools: tools, activeTool: "zoom")
            == .action("zoom_to_actual_size"))
    #expect(resolveToolOptions(tools: tools, activeTool: "artboard")
            == .action("fit_all_artboards"))
}

@Test func resolveToolOptionsNoneWhenToolDeclaresNoOptions() {
    // The plain Selection tool declares no options field → no-op.
    let tools = WorkspaceData.load()?.data["tools"] as? [String: Any] ?? [:]
    #expect(resolveToolOptions(tools: tools, activeTool: "selection") == ToolOptionsDispatch.none)
    // An unknown tool id also resolves to .none (no crash, no-op).
    #expect(resolveToolOptions(tools: tools, activeTool: "no_such_tool") == ToolOptionsDispatch.none)
}

@Test func resolveToolOptionsPriorityPanelBeatsActionBeatsDialog() {
    // Synthetic specs verifying the priority order independent of the
    // live bundle: panel wins over action wins over dialog.
    let allThree: [String: Any] = [
        "x": [
            "tool_options_panel": "magic_wand",
            "tool_options_action": "fit_active_artboard",
            "tool_options_dialog": "paintbrush_tool_options",
        ] as [String: Any]
    ]
    #expect(resolveToolOptions(tools: allThree, activeTool: "x") == .panel("magic_wand"))

    let actionAndDialog: [String: Any] = [
        "x": [
            "tool_options_action": "zoom_to_actual_size",
            "tool_options_dialog": "scale_options",
        ] as [String: Any]
    ]
    #expect(resolveToolOptions(tools: actionAndDialog, activeTool: "x")
            == .action("zoom_to_actual_size"))

    // Empty-string fields are treated as absent (skip to next).
    let emptyPanel: [String: Any] = [
        "x": [
            "tool_options_panel": "",
            "tool_options_dialog": "scale_options",
        ] as [String: Any]
    ]
    #expect(resolveToolOptions(tools: emptyPanel, activeTool: "x")
            == .dialog("scale_options"))
}

// MARK: - isToolButtonElement (dblclick scoping)

@Test func isToolButtonTrueForToolbarSlots() {
    // Every tool slot in the bundle's tool_grid carries a click →
    // select_tool behavior, so all of them are tool buttons.
    let grid = WorkspaceData.load()?.toolGrid()
    let children = grid?["children"] as? [[String: Any]] ?? []
    #expect(!children.isEmpty, "tool_grid should have icon_button children")
    for child in children {
        #expect(isToolButtonElement(child),
                "tool_grid child \(child["id"] ?? "?") should be a tool button")
    }
}

@Test func isToolButtonFalseForNonToolIconButtons() {
    // A panel radio / dialog glyph icon_button with no select_tool click
    // must NOT match — the dblclick stays off panels and other buttons.
    let panelRadio: [String: Any] = [
        "type": "icon_button",
        "icon": "align_left",
        "behavior": [
            ["event": "click", "action": "align", "params": ["edge": "left"]]
        ],
    ]
    #expect(!isToolButtonElement(panelRadio))

    // An icon_button with only press behaviors (e.g. a long-press-only
    // affordance) and no select_tool click also does not match.
    let pressOnly: [String: Any] = [
        "type": "icon_button",
        "behavior": [
            ["event": "mouse_down", "effects": []],
            ["event": "mouse_up", "effects": []],
        ],
    ]
    #expect(!isToolButtonElement(pressOnly))

    // A non-icon_button element (slider, text, …) never matches even if
    // it somehow carried a select_tool behavior.
    let slider: [String: Any] = [
        "type": "slider",
        "behavior": [["event": "click", "action": "select_tool"]],
    ]
    #expect(!isToolButtonElement(slider))

    // An icon_button with no behavior at all does not match.
    #expect(!isToolButtonElement(["type": "icon_button"]))
}

@Test func isToolButtonTrueForLongPressSlot() {
    // A long-press-alternate slot carries mouse_down / mouse_up AND a
    // click → select_tool. It IS a tool button (clicking commits the
    // visible tool), so it must respond to the options dblclick too —
    // matching the prior native toolButtonWithAlternates.
    let alternateSlot: [String: Any] = [
        "type": "icon_button",
        "behavior": [
            ["event": "mouse_down", "effects": []],
            ["event": "mouse_up", "effects": []],
            ["event": "click", "action": "select_tool", "params": ["tool": "pen"]],
        ],
    ]
    #expect(isToolButtonElement(alternateSlot))
}
