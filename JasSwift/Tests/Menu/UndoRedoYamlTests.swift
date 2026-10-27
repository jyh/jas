import Testing
import Foundation
@testable import JasLib

/// STATUS-jas item 36: Edit > Undo / Redo run their actions' YAML
/// (`doc.op: {op: undo|redo}`) on the menu and Cmd-Z routes, as the engine's
/// door and the web do, rather than a native `model.undo()` per route.
@Suite struct UndoRedoYamlTests {

    @Test func undoAndRedoRunTheirYaml() {
        let m = Model(document: Document(layers: [Layer(name: "L", children: [])],
                                         selectedLayer: 0, selection: []))
        var doc = m.document
        doc = Document(layers: doc.layers + [Layer(name: "M", children: [])],
                       selectedLayer: 0, selection: [])
        m.editDocument(doc)
        #expect(m.document.layers.count == 2, "the control: the edit landed")
        LayersPanel.dispatchYamlAction("undo", model: m)
        #expect(m.document.layers.count == 1, "undo ran")
        LayersPanel.dispatchYamlAction("redo", model: m)
        #expect(m.document.layers.count == 2, "redo ran")
    }
}
