import Foundation
import Testing
@testable import JasLib

// W2b-18: the Brushes panel's two canvas gates and its two library actions.
// The reference's `test_brush_panel_spec.py` and Rust's arms pin the same
// laws, row for row.

private func path(_ x: Double, _ brush: String?) -> Element {
    .path(Path(d: [.moveTo(x, 0), .lineTo(x + 50, 40)],
               stroke: Stroke(color: Color(r: 0, g: 0, b: 0), width: 2),
               strokeBrush: brush, fillRule: .nonzero))
}

private let brushed = "default_brushes/flat_10"

private func facts(_ children: [Element], _ selected: [Int]) -> (Bool?, Bool?) {
    let model = Model(document: Document(
        layers: [Layer(children: children)],
        selection: selected.map { ElementSelection.all([0, $0]) }))
    let view = buildActiveDocumentView(model: model)
    return (view["selection_has_brushed_stroke"] as? Bool,
            view["selection_is_single_brushed_stroke"] as? Bool)
}

@Test func brushedStrokeFactsMatchTheReferenceTable() {
    let cases: [(String, [Element], [Int], Bool, Bool)] = [
        ("one brushed path", [path(0, brushed)], [0], true, true),
        ("one plain path", [path(0, nil)], [0], false, false),
        ("brushed + plain selected", [path(0, brushed), path(60, nil)], [0, 1], true, false),
        ("two brushed selected", [path(0, brushed), path(60, brushed)], [0, 1], true, false),
        ("brushed but NOT selected", [path(0, brushed), path(60, nil)], [1], false, false),
        ("a rect", [.rect(Rect(x: 0, y: 0, width: 10, height: 10))], [0], false, false),
        ("empty brush id", [path(0, "")], [0], false, false),
        ("nothing selected", [path(0, brushed)], [], false, false),
        ("a stale selection path", [path(0, brushed)], [7], false, false),
    ]
    for (name, children, selected, has, single) in cases {
        let (h, s) = facts(children, selected)
        #expect(h == has, "\(name): has")
        #expect(s == single, "\(name): single")
    }
    let empty = buildActiveDocumentView(model: nil)
    #expect(empty["selection_has_brushed_stroke"] as? Bool == false)
    #expect(empty["selection_is_single_brushed_stroke"] as? Bool == false)
}

private func brushModel(selected: [String]) -> Model {
    let m = Model()
    m.stateStore.setData(["brush_libraries": [
        "lib_a": ["name": "A", "brushes": [
            ["slug": "a", "name": "Alpha", "type": "calligraphic"],
            ["slug": "b", "name": "Beta", "type": "calligraphic"],
            ["slug": "c", "name": "Gamma", "type": "calligraphic"],
            ["slug": "a_copy", "name": "Alpha copy", "type": "calligraphic"]]],
        "lib_b": ["name": "B", "brushes": [
            ["slug": "a", "name": "Other alpha", "type": "art"]]],
    ] as [String: Any]])
    m.stateStore.initPanel("brushes_panel_content",
                           defaults: ["selected_library": "lib_a", "selected_brushes": selected])
    m.stateStore.setActivePanel("brushes_panel_content")
    return m
}

private func slugs(_ m: Model, _ lib: String) -> [String] {
    ((m.stateStore.getDataPath("brush_libraries.\(lib).brushes") as? [[String: Any]]) ?? [])
        .map { $0["slug"] as? String ?? "" }
}

// Before W2b-18 the action passed `{}` (the spec), and no production panel
// dispatcher registered any `brush.*` key: they lived only in the tool table,
// so `runEffects` skipped them without a word.
@Test func theRealDeleteBrushActionRemovesThePanelSelection() {
    let m = brushModel(selected: ["a", "c"])
    var layout = WorkspaceLayout.defaultLayout()
    panelDispatch(.brushes, cmd: "delete_brush", addr: PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0),
                  layout: &layout, model: m)
    #expect(slugs(m, "lib_a") == ["b", "a_copy"])
    #expect(slugs(m, "lib_b") == ["a"], "the same slug in another library")
    #expect((m.stateStore.getPanel("brushes_panel_content", "selected_brushes") as? [String]) == [])
}

@Test func theRealDuplicateBrushActionCopiesAfterEachOriginal() {
    let m = brushModel(selected: ["a", "b"])
    var layout = WorkspaceLayout.defaultLayout()
    panelDispatch(.brushes, cmd: "duplicate_brush", addr: PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0),
                  layout: &layout, model: m)
    #expect(slugs(m, "lib_a") == ["a", "a_copy_2", "b", "b_copy", "c", "a_copy"])
    #expect((m.stateStore.getPanel("brushes_panel_content", "selected_brushes") as? [String])
            == ["a_copy_2", "b_copy"])
    #expect(slugs(m, "lib_b") == ["a"])
}
