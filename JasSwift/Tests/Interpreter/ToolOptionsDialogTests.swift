import Foundation
import Testing
@testable import JasLib

/// The toolbar's double-click on a tool with a `tool_options_dialog` (Rotate,
/// Scale, Shear, the brushes, the eyedropper): ``DialogWidgetActions/openToolOptions``,
/// which ``ContentView`` calls. The dialog must open IN THE STORE, as a menu
/// or panel opener's does, or nothing behind it works: a typed field's write
/// (``DialogWidgetActions/write``) is a store write and is dropped with no
/// dialog open, `on_change` never fires, and no preview snapshot exists.
@Suite struct ToolOptionsDialogTests {
    @Test func theToolbarOpensRotateOptionsInTheStoreAndATypedFieldIsKept() throws {
        let m = Model(document: Document())
        let opened = DialogWidgetActions.openToolOptions("rotate_options", model: m)
        #expect(opened?.id == "rotate_options")
        #expect(m.stateStore.getDialogId() == "rotate_options",
                "the dialog is open in the store, not only in the view")
        DialogWidgetActions.write("angle", 30, store: m.stateStore)
        let angle = (m.stateStore.getDialogState()["angle"] as? NSNumber)?.doubleValue
        #expect(angle == 30, "a typed angle is kept by the open dialog")
        #expect((opened?.state["angle"] as? NSNumber) != nil,
                "the view's state comes from the store's dialog, so it carries its fields")
    }

    /// Opening through the store must not change what the dialog OPENS with:
    /// `init` now reads the model's store where it read `stateDefaults()`, so
    /// an unseeded store would open every field at null (the risk STATUS-jas
    /// named before item 11 seeded it). Every tool's options dialog, read from
    /// the bundle, opens with the values the view-only route gave it.
    @Test func everyToolOptionsDialogOpensWithTheValuesTheViewRouteGave() throws {
        let ws = try #require(WorkspaceData.load())
        let tools = ws.data["tools"] as? [String: Any] ?? [:]
        let ids = tools.values.compactMap { ($0 as? [String: Any])?["tool_options_dialog"] as? String }
        #expect(ids.count >= 6, "the bundle's tools declare \(ids.count) options dialogs")
        for id in Set(ids).sorted() {
            let old = try #require(openYamlDialog(dialogId: id, rawParams: [:], liveState: ws.stateDefaults()))
            let new = try #require(DialogWidgetActions.openToolOptions(id, model: Model(document: Document())))
            #expect(Set(new.state.keys) == Set(old.state.keys), "\(id): the same fields")
            for (k, v) in old.state {
                #expect("\(new.state[k] ?? "nil")" == "\(v)", "\(id).\(k): store \(new.state[k] ?? "nil"), view \(v)")
            }
        }
    }
}
