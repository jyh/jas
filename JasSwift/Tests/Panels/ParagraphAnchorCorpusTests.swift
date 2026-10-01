import Testing
import Foundation
@testable import JasLib

// The Paragraph panel writes the POINT-TEXT anchor (council 2026-10-01, O25).
//
// Runs test_fixtures/paragraph_apply/text_anchor.json, the vector Rust runs as
// `paragraph_apply_text_anchor_corpus` (cross_language_test.rs). The corpus's
// `_doc` states the law: ALIGN_LEFT -> start (omitted, ""), ALIGN_CENTER ->
// middle, ALIGN_RIGHT -> end on the <text>; justify falls through to start;
// area text keeps the anchor the file gave it; text on a path has no field.

private func paragraphAnchorCorpus() -> [String: Any] {
    let thisFile = #filePath
    let panelsDir = (thisFile as NSString).deletingLastPathComponent
    let testsDir = (panelsDir as NSString).deletingLastPathComponent
    let jasSwiftDir = (testsDir as NSString).deletingLastPathComponent
    let fixtures = (jasSwiftDir as NSString).appendingPathComponent("../test_fixtures")
    let full = (fixtures as NSString)
        .appendingPathComponent("paragraph_apply/text_anchor.json")
    let path = (full as NSString).standardizingPath
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let dict = obj as? [String: Any] else {
        fatalError("Failed to read paragraph_apply corpus: \(path)")
    }
    return dict
}

/// Each child of layer 0 as the corpus reads it: the anchor of a Text, `nil`
/// for anything with no anchor field.
private func anchorsOfLayer0(_ doc: Document) -> [String?] {
    doc.layers[0].children.map { e -> String? in
        if case .text(let t) = e { return t.textAnchor }
        return nil
    }
}

@Suite("Paragraph panel point-text anchor corpus")
struct ParagraphAnchorCorpusTests {

    @Test("the shared text_anchor corpus")
    func textAnchorCorpus() {
        let corpus = paragraphAnchorCorpus()
        let setup = svgToDocument(corpus["setup_svg"] as! String)
        // The setup is a PRECONDITION, refused by name (mirrors the Rust arm).
        let kinds = setup.layers[0].children.map { e -> String in
            switch e {
            case .text(let t): return t.isAreaText ? "area" : "point"
            case .textPath: return "path"
            default: return "other"
            }
        }
        #expect(kinds == ["point", "point", "area", "path", "point"],
                "paragraph_apply setup does not load as the corpus describes")
        var ran = 0
        for vec in corpus["vectors"] as! [[String: Any]] {
            let name = vec["name"] as! String
            let select = (vec["select"] as! [NSNumber]).map { ElementSelection.all([0, $0.intValue]) }
            let model = Model()
            model.setDocumentForTest(setup.replacing(selection: select))
            let store = model.stateStore
            store.initPanel("paragraph_panel_content", defaults: [:])
            for (k, v) in vec["panel"] as! [String: Any] {
                store.setPanel("paragraph_panel_content", k, v)
            }
            applyParagraphPanelToSelection(store: store, controller: Controller(model: model))
            let want = (vec["expected"] as! [Any]).map { $0 is NSNull ? nil : ($0 as! String) }
            #expect(anchorsOfLayer0(model.document) == want,
                    "paragraph_apply text_anchor '\(name)'")
            ran += 1
        }
        #expect(ran >= 5, "paragraph_apply corpus ran only \(ran) vectors")
    }
}
