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

private func brushModel(selected: [String], children: [Element]? = nil) -> Model {
    let m = children.map { Model(document: Document(layers: [Layer(children: $0)], selection: [])) }
        ?? Model()
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

// The Brushes menu's Sort by Name and Select All Unused, row for row with the
// reference's `TestSortBrushesByName` / `TestSelectAllUnusedBrushes` and
// Rust's arms. Both were log-only stubs in every port.

private func namedBrushModel(_ names: [String], children: [Element] = []) -> Model {
    let m = Model(document: Document(layers: [Layer(children: children)], selection: []))
    let brushes: [[String: Any]] = names.enumerated().map {
        ["slug": "s\($0.offset)", "name": $0.element, "type": "calligraphic"]
    }
    m.stateStore.setData(["brush_libraries": [
        "lib_a": ["name": "A", "brushes": brushes],
        "lib_b": ["name": "B", "brushes": [
            ["slug": "z", "name": "Zed", "type": "art"],
            ["slug": "a", "name": "Ay", "type": "art"]]],
    ] as [String: Any]])
    m.stateStore.initPanel("brushes_panel_content",
                           defaults: ["selected_library": "lib_a", "selected_brushes": ["s2"]])
    m.stateStore.setActivePanel("brushes_panel_content")
    return m
}

private func names(_ m: Model, _ lib: String) -> [String] {
    ((m.stateStore.getDataPath("brush_libraries.\(lib).brushes") as? [[String: Any]]) ?? [])
        .map { $0["name"] as? String ?? "" }
}

private func dispatchBrushes(_ m: Model, _ cmd: String) {
    var layout = WorkspaceLayout.defaultLayout()
    panelDispatch(.brushes, cmd: cmd, addr: PanelAddr(group: GroupAddr(dockId: DockId(0), groupIdx: 0), panelIdx: 0),
                  layout: &layout, model: m)
}

@Test func theRealSortBrushesByNameActionSortsCaseSensitivelyAndKeepsTheSelection() {
    let m = namedBrushModel(["Zebra", "Apple", "mango", "Mango"])
    dispatchBrushes(m, "sort_brushes_by_name")
    #expect(names(m, "lib_a") == ["Apple", "Mango", "Zebra", "mango"])
    #expect(slugs(m, "lib_a") == ["s1", "s3", "s0", "s2"])
    #expect((m.stateStore.getPanel("brushes_panel_content", "selected_brushes") as? [String]) == ["s2"])
    #expect(names(m, "lib_b") == ["Zed", "Ay"], "only the selected library moves")
}

// Code-point order, never Swift's String `<`, which reads the two "éclair"s
// below as EQUAL (canonical equivalence) and would keep the input order. Built
// from scalars so no combining mark sits in the source.
@Test func sortByNameOrdersByCodePoint() {
    let pre = String(Character(Unicode.Scalar(0xE9)!)) + "clair"
    let dec = "e" + String(Character(Unicode.Scalar(0x301)!)) + "clair"
    #expect(pre == dec, "the premise: Swift's String equality is canonical")
    let m = namedBrushModel([pre, "eclair", dec, "Zed", "ezra"])
    dispatchBrushes(m, "sort_brushes_by_name")
    #expect(slugs(m, "lib_a") == ["s3", "s1", "s4", "s2", "s0"])
}

@Test func sortByNameIsStableAndANamelessBrushSortsFirst() {
    let m = namedBrushModel(["B", "A", "B", "A"])
    dispatchBrushes(m, "sort_brushes_by_name")
    #expect(slugs(m, "lib_a") == ["s1", "s3", "s0", "s2"])

    let n = namedBrushModel(["B", "A"])
    var brushes = (n.stateStore.getDataPath("brush_libraries.lib_a.brushes") as? [[String: Any]]) ?? []
    brushes.append(["slug": "nameless", "type": "art"])
    n.stateStore.setDataPath("brush_libraries.lib_a.brushes", brushes)
    dispatchBrushes(n, "sort_brushes_by_name")
    #expect(slugs(n, "lib_a") == ["nameless", "s1", "s0"])
}

@Test func sortByNameWithNoOrAnUnknownLibraryIsANoOp() {
    for lib: Any in [NSNull(), "no_such_lib"] {
        let m = namedBrushModel(["B", "A"])
        m.stateStore.setPanel("brushes_panel_content", "selected_library", lib)
        dispatchBrushes(m, "sort_brushes_by_name")
        #expect(names(m, "lib_a") == ["B", "A"], "\(lib)")
    }
}

private func group(_ children: [Element]) -> Element { .group(Group(children: children)) }

@Test func theRealSelectAllUnusedActionSelectsWhatNoElementUses() {
    let rows: [(String, [Element], [String], [String])] = [
        ("nothing used", [path(0, nil)], [], ["a", "b", "c", "a_copy"]),
        ("b used, selection replaced", [path(0, "lib_a/b")], ["b"], ["a", "c", "a_copy"]),
        ("use is library-qualified", [path(0, "lib_b/a")], [], ["a", "b", "c", "a_copy"]),
        ("inside nested groups", [group([group([path(0, "lib_a/c")])]), path(60, "lib_a/a")], [],
         ["b", "a_copy"]),
        ("every brush used", [path(0, "lib_a/a"), path(10, "lib_a/b"), path(20, "lib_a/c"),
                              path(30, "lib_a/a_copy")], ["a"], []),
    ]
    for (name, children, selected, want) in rows {
        let m = brushModel(selected: selected, children: children)
        dispatchBrushes(m, "select_all_unused_brushes")
        #expect((m.stateStore.getPanel("brushes_panel_content", "selected_brushes") as? [String]) == want,
                "\(name)")
        #expect(slugs(m, "lib_a") == ["a", "b", "c", "a_copy"], "\(name): library untouched")
    }
}
