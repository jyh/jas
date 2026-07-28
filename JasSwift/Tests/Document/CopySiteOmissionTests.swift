import AppKit
import Foundation
import Testing
@testable import JasLib

/// THE SWIFT COPY-SITE OMISSION CLASS, ENUMERATED.
///
/// Swift rebuilds structs field by field where Rust writes `..clone()` /
/// `children_mut()`, so every field a hand-written argument list forgets is
/// silently reset to its default. `Group` and `Layer` carry 11 stored
/// properties; `Document` carries 8. The class has now bitten this project at
/// paste (LAYER_STRUCTURE.md §9.5) and at Ungroup All
/// (`UngroupAllPreservationTests`).
///
/// A mechanical scan of `JasSwift/Sources` for constructions of `Group`,
/// `Layer` and `Document` that READ FIELDS OFF AN EXISTING VALUE of the same
/// type (a rebuild, not a fresh construction) while naming fewer labels than
/// the type has stored properties found ten more. This suite gates the ones
/// reachable from a model-level seam. Each probe asserts BY VALUE — a `Mirror`
/// walk or whole-struct equality is structurally blind to this defect, because
/// both sides would be built through the same truncated initializer.
///
/// The two sites with NO model-level seam (`YamlPanelBodyView.swift` layer
/// rename, twice, inside SwiftUI view bodies) are repaired the same way but are
/// NOT gated here; that gap is stated in the wave record rather than hidden.
@Suite("Swift copy-site omission class")
struct CopySiteOmissionTests {

    private func rect(_ x: Double) -> Element {
        .rect(Rect(x: x, y: 0, width: 10, height: 10))
    }

    // MARK: - 1. Session restore drops the symbol masters

    /// `WorkspaceState.sessionDocument(fromBlob:)` repairs a legacy blob that predates
    /// artboards by rebuilding the Document — through an argument list naming
    /// SEVEN of eight parameters. The missing one is `symbols`, the off-canvas
    /// master store, so every Symbol master in a restored tab was deleted and
    /// every `ReferenceElem` instance pointing at one was orphaned.
    ///
    /// The blob is produced by the real encoder, so the probe is a true round
    /// trip: symbols in, artboards empty (which is what forces the repair
    /// branch), symbols expected back.
    @Test func sessionRestoreKeepsSymbolMasters() throws {
        let master = Element.rect(Rect(x: 3, y: 4, width: 5, height: 6)).withId("master-1")
        let doc = Document(layers: [Layer(name: "L", children: [rect(0)])],
                           symbols: [master],
                           artboards: [])   // empty -> the repair branch fires
        let blob = documentToBinary(doc)
        let restored = try #require(WorkspaceState.sessionDocument(fromBlob: blob))

        // The repair branch really did fire (otherwise this is vacuous).
        #expect(restored.artboards.count == 1)
        // ...and it did not eat the masters.
        #expect(restored.symbols.count == 1)
        #expect(restored.symbols.first?.id == "master-1")
    }

    // MARK: - 2. Plain-text paste resets the target layer

    /// LAYER_STRUCTURE.md §9.5 repaired the SVG paste branch. The PLAIN-TEXT
    /// branch (`EditClipboard.swift`) was left behind with the same defect:
    /// `Layer(name:children:opacity:transform:)`, four of eleven. Pasting text
    /// into a LOCKED layer UNLOCKED it, into a HIDDEN layer REVEALED it, and
    /// destroyed the layer's `id`.
    @Test func plainTextPasteKeepsTargetLayerFields() {
        let target = Layer(name: "Target", children: [],
                           locked: true, visibility: .outline,
                           blendMode: .multiply, id: "lay-1")
        let model = Model(document: Document(layers: [target],
                                             selectedLayer: 0,
                                             artboards: [Artboard(id: "ab-1")]))
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.setString("hello", forType: .string)
        EditClipboard.pasteClipboard(model, offset: 24, pasteboard: pb)

        let l = model.document.layers[0]
        // The paste happened (guard against a vacuous pass).
        #expect(l.children.count == 1)
        #expect(l.name == "Target")
        #expect(l.locked == true)
        #expect(l.visibility == .outline)
        #expect(l.blendMode == .multiply)
        #expect(l.id == "lay-1")
    }

    // MARK: - 3. The layers panel's doc.set destroys layer identity

    /// Every lock toggle, eye click and rename routed through the layers
    /// panel's `doc.set` effect rebuilt the layer as
    /// `Layer(name:children:opacity:transform:locked:visibility:)` — six of
    /// eleven. So toggling a layer's lock DESTROYED its `id` (breaking every
    /// reference resolved through it, REFERENCE_GRAPH.md §2.4), its blend mode
    /// and its mask.
    @Test func layersPanelDocSetKeepsLayerIdentity() {
        let mask = Mask(subtreeElement: .circle(Circle(cx: 1, cy: 2, r: 3)))
        let styled = Layer(name: "Styled", children: [rect(0)],
                           opacity: 0.5,
                           blendMode: .screen,
                           isolatedBlending: true,
                           knockoutGroup: true,
                           mask: mask,
                           id: "lay-keep")
        let model = Model(document: Document(layers: [styled],
                                             artboards: [Artboard(id: "ab-1")]))
        LayersPanel.runEffectsForTest(
            actionName: "toggle_element_lock",
            effects: [
                "snapshot",
                ["doc.set": ["path": "path(0)", "fields": ["common.locked": "true"]]],
            ],
            model: model
        )

        let l = model.document.layers[0]
        // The write landed (guard against a vacuous pass).
        #expect(l.locked == true)
        #expect(l.name == "Styled")
        #expect(l.opacity == 0.5)
        #expect(l.id == "lay-keep")
        #expect(l.blendMode == .screen)
        #expect(l.isolatedBlending == true)
        #expect(l.knockoutGroup == true)
        #expect(l.mask?.subtree.count == 1)
    }

    // MARK: - 4. The opacity normalizer eats blend modes and masks

    /// `normalizeDocument` runs on EVERY document read (`svgToDocument` calls
    /// it). Its group and layer arms rebuilt with seven of eleven labels, so a
    /// blend mode, a mask and both opacity-panel flags were dropped from every
    /// group and every layer on the way in — and the same function is the
    /// natural place for a future in-app normalize pass, where the loss would
    /// hit live documents.
    @Test func normalizeKeepsGroupAndLayerAttributes() {
        let gmask = Mask(subtreeElement: .circle(Circle(cx: 1, cy: 2, r: 3)))
        let lmask = Mask(subtreeElement: .circle(Circle(cx: 4, cy: 5, r: 6)))
        let g = Group(children: [rect(0)],
                      blendMode: .multiply,
                      isolatedBlending: true,
                      knockoutGroup: true,
                      mask: gmask,
                      name: "G", id: "g-1")
        let l = Layer(name: "L", children: [.group(g)],
                      blendMode: .screen,
                      isolatedBlending: true,
                      knockoutGroup: true,
                      mask: lmask,
                      id: "l-1")
        let out = normalizeDocument(Document(layers: [l],
                                             artboards: [Artboard(id: "ab-1")]))

        let nl = out.layers[0]
        #expect(nl.name == "L")
        #expect(nl.id == "l-1")
        #expect(nl.blendMode == .screen)
        #expect(nl.isolatedBlending == true)
        #expect(nl.knockoutGroup == true)
        #expect(nl.mask?.subtree.count == 1)

        guard case .group(let ng) = nl.children[0] else {
            Issue.record("the group survived normalize"); return
        }
        #expect(ng.name == "G")
        #expect(ng.id == "g-1")
        #expect(ng.blendMode == .multiply)
        #expect(ng.isolatedBlending == true)
        #expect(ng.knockoutGroup == true)
        #expect(ng.mask?.subtree.count == 1)
    }
}
