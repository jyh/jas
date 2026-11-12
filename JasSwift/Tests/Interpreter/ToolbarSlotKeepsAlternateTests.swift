import Foundation
import Testing
@testable import JasLib

/// Row 108 phase 1 (`workspace/layout.yaml`): a toolbar slot's click keeps
/// its ACTIVE tool when one of the slot's tools is active, and selects the
/// slot's default otherwise. Before this, every slot click selected its
/// fixed default, so a double-click on a slot whose alternate was active
/// reset the tool first, and Magic Wand's, Paintbrush's and Blob Brush's
/// options could not be reached by hand on any port (measured on Windows,
/// read at the spec on every port). Twin of jas_dioxus `ffi.rs`
/// `a_slot_click_keeps_its_active_alternate`.

private func slot(_ id: String) -> [String: Any]? {
    guard let ws = WorkspaceData.load() else { return nil }
    return WidgetEvent.findWidget(in: ws.data["layout"], id: id)
}

private func clickSlot(_ id: String, activeTool: String) -> String? {
    let model = Model()
    model.stateStore.set("active_tool", activeTool)
    guard let widget = slot(id) else { return nil }
    let route = PanelWidgetEvents(model: model, panelId: "toolbar_pane",
                                  scope: ["state": ["active_tool": activeTool]])
    _ = route.click(widget)
    return model.stateStore.get("active_tool") as? String
}

@Test func aSlotClickKeepsItsActiveAlternate() {
    #expect(slot("btn_arrow_slot") != nil, "the control: the slot is found in the bundle's layout")
    #expect(clickSlot("btn_arrow_slot", activeTool: "magic_wand") == "magic_wand")
    #expect(clickSlot("btn_pencil_slot", activeTool: "paintbrush") == "paintbrush")
    #expect(clickSlot("btn_pencil_slot", activeTool: "blob_brush") == "blob_brush")
    #expect(clickSlot("btn_text_slot", activeTool: "type_on_path") == "type_on_path")
}

@Test func aSlotClickFromAnotherSlotsToolSelectsTheDefault() {
    #expect(clickSlot("btn_arrow_slot", activeTool: "selection") == "partial_selection")
    #expect(clickSlot("btn_pencil_slot", activeTool: "magic_wand") == "pencil")
    #expect(clickSlot("btn_hand_slot", activeTool: "pen") == "hand")
}

/// The slot's icon is its active tool's, declared as `bind.icon` so every
/// port reads it from the spec (the Windows shell draws what the engine's
/// plan names, and the plan resolves `bind.icon`, not a code fallback).
@Test func aSlotsBoundIconIsItsActiveToolsIcon() {
    func icon(_ id: String, _ active: String) -> String? {
        guard let expr = (slot(id)?["bind"] as? [String: Any])?["icon"] as? String else { return nil }
        if case .string(let s) = evaluate(expr, context: ["state": ["active_tool": active]]) { return s }
        return nil
    }
    #expect(icon("btn_arrow_slot", "magic_wand") == "magic_wand")
    #expect(icon("btn_arrow_slot", "interior_selection") == "interior_selection_arrow")
    #expect(icon("btn_arrow_slot", "selection") == "partial_selection_arrow")
    #expect(icon("btn_pencil_slot", "smooth") == "smooth")
    #expect(icon("btn_shape_slot", "pen") == "rect")
}
