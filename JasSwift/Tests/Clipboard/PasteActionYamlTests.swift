import AppKit
import Testing
import Foundation
@testable import JasLib

/// CLIPBOARD M′ (item 8): the three paste actions run their YAML.
///
/// `actions.yaml` paste / paste_in_place / paste_preserving_layers declare a
/// `clipboard` param and run `doc.paste: {text: "param.clipboard", offset,
/// preserve_layers}`. ``EditClipboard/paste(action:model:pasteboard:)`` reads
/// the pasteboard and dispatches the action, so the offsets live in the YAML
/// alone, as in the engine's door and the web.
@Suite struct PasteActionYamlTests {

    private static func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(rawValue: "jas.tests.pasteyaml.\(UUID().uuidString)"))
    }

    private static func emptyModel() -> Model {
        Model(document: Document(layers: [Layer(name: "L", children: [])],
                                 selectedLayer: 0, selection: []))
    }

    private static let rect = """
        <svg xmlns="http://www.w3.org/2000/svg">\
        <rect x="0" y="0" width="10" height="10" fill="rgb(0,0,255)" stroke="none"/></svg>
        """

    private static func xs(_ m: Model) -> [Double] {
        m.document.layers[0].children.map { el -> Double in
            guard case .rect(let r) = el else { Issue.record("pasted a non-rect: \(el)"); return .nan }
            return r.x
        }
    }

    private static func pasteboard(_ text: String?) -> NSPasteboard {
        let pb = privatePasteboard()
        pb.clearContents()
        if let text { pb.setString(text, forType: .string) }
        return pb
    }

    @Test func eachPasteActionRunsItsYamlOnThePasteboard() {
        for (action, want) in [("paste", [24.0, 48.0]), ("paste_preserving_layers", [24.0, 48.0]),
                               ("paste_in_place", [0.0, 0.0])] {
            let m = Self.emptyModel()
            let pb = Self.pasteboard(Self.rect)
            for _ in 0..<2 { EditClipboard.paste(action: action, model: m, pasteboard: pb) }
            #expect(Self.xs(m).map { ($0 * 1e6).rounded() / 1e6 } == want, "\(action)")
            m.undo()
            #expect(Self.xs(m).count == 1, "\(action): one paste is one undo step")
        }
        let m = Self.emptyModel()
        let pb = Self.pasteboard(Self.rect)
        for action in ["paste", "paste_in_place", "paste"] {
            EditClipboard.paste(action: action, model: m, pasteboard: pb)
        }
        #expect(Self.xs(m).map { ($0 * 1e6).rounded() / 1e6 } == [24, 0, 48],
                "in place neither advances nor restarts the run")
    }

    @Test func anEmptyOrUnreadablePasteboardPastesNothing() {
        for text in [nil, ""] as [String?] {
            let m = Self.emptyModel()
            EditClipboard.paste(action: "paste", model: m, pasteboard: Self.pasteboard(text))
            #expect(Self.xs(m).isEmpty, "\(String(describing: text))")
            #expect(!m.canUndo, "\(String(describing: text)): no undo step")
        }
    }

    @Test func onlyThePreservingPasteBringsANamedLayerAcross() {
        let sky = """
            <svg xmlns="http://www.w3.org/2000/svg" \
            xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape">\
            <g inkscape:groupmode="layer" inkscape:label="Sky">\
            <rect x="0" y="0" width="10" height="10"/></g></svg>
            """
        for (action, layers) in [("paste", 1), ("paste_preserving_layers", 2)] {
            let m = Self.emptyModel()
            EditClipboard.paste(action: action, model: m, pasteboard: Self.pasteboard(sky))
            #expect(m.document.layers.count == layers, "\(action)")
        }
    }

    /// Copy runs its YAML: the shared payload (``EditClipboard/selectionPayload(_:)``)
    /// lands on the pasteboard; nothing selected leaves the pasteboard alone,
    /// and a copy edits nothing.
    @Test func copyRunsItsYamlOntoThePasteboard() {
        let rect = Element.rect(Rect(x: 3, y: 4, width: 10, height: 10, name: nil, id: "r-1"))
        let m = Model(document: Document(layers: [Layer(name: "L", children: [rect])],
                                         selectedLayer: 0, selection: [ElementSelection.all([0, 0])]))
        let pb = Self.pasteboard("untouched")
        let before = m.document
        EditClipboard.copy(model: m, pasteboard: pb)
        #expect(pb.string(forType: .string) == EditClipboard.selectionPayload(m.document))
        #expect(pb.string(forType: .string) != "untouched", "the control: the copy wrote")
        #expect(m.document == before, "a copy edits nothing")
        #expect(!m.canUndo)

        let none = Model(document: Document(layers: [Layer(name: "L", children: [rect])],
                                             selectedLayer: 0, selection: []))
        let pb2 = Self.pasteboard("untouched")
        EditClipboard.copy(model: none, pasteboard: pb2)
        #expect(pb2.string(forType: .string) == "untouched", "nothing selected writes nothing")
    }

    /// No production route calls the paste law, or names an offset: each runs
    /// its action (the menubar's three verbs, the canvas context menu).
    @Test func noPasteRouteCallsTheLawOrNamesAnOffset() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for rel in ["Sources/Menu/JasCommands.swift", "Sources/Canvas/CanvasSubwindow.swift"] {
            let src = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            let code = src.split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(!code.contains("pasteClipboard("), "\(rel) calls EditClipboard.pasteClipboard; run the action")
            #expect(!code.contains("applyPasteClipboardText("), "\(rel) calls the paste law")
            #expect(!code.contains("pasteOffset"), "\(rel) names pasteOffset; the YAML carries it")
            #expect(code.contains("EditClipboard.paste(action:"), "\(rel) has no paste route (control)")
            #expect(!code.contains("EditClipboard.copySelection("), "\(rel) copies around the YAML")
            #expect(code.contains("EditClipboard.copy(model:"), "\(rel) has no copy route (control)")
        }
    }
}
