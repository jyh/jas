import Testing
@testable import JasLib

/// PASTE AND LAYER STRUCTURE — the cases the shared corpus CANNOT reach.
/// Twin of Rust `op_apply::paste_layer_structure_tests`.
///
/// `test_fixtures/operations/paste_layers.json` is the primary gate for
/// LAYER_STRUCTURE.md R2/R3 and it is cross-language. This suite exists for
/// exactly two shapes that family cannot express, and each says which:
///
/// 1. **LOCKED and HIDDEN target layers** (LAYER_STRUCTURE.md §6 open question
///    2). Every corpus case is seeded from a `setup_svg`, and the SVG codec does
///    not persist `locked` AT ALL — a layer parsed from SVG is always unlocked.
///    So the corpus is structurally blind to it, and these probes build the
///    document directly instead. They also catch a REAL defect the old paste
///    carried: it rebuilt the target as
///    `Layer(name:children:opacity:transform:)`, silently dropping `locked`,
///    `visibility`, `blendMode`, `mask`, `isolatedBlending`, `knockoutGroup`
///    and `id` — the Swift copy-site omission class, landing at a paste.
/// 2. **A BARE-ELEMENT fragment.** The `paste` op verb feeds
///    `svgToDocument(...).layers`, which is always layers, so the corpus only
///    ever exercises the SVG shape.
///
/// Every probe asserts VALUES (layer names, child counts, geometry), never
/// whole-struct equality or a Mirror walk — a field-list-free comparison is
/// structurally blind to geometry.
@Suite struct PasteLayerStructureTests {

    private func rect(_ x: Double, _ y: Double) -> Element {
        .rect(Rect(x: x, y: y, width: 10, height: 10))
    }

    /// Document: `Base` (one rect at origin, active) + a second layer the caller
    /// styles.
    private func docWith(_ second: Layer) -> Document {
        Document(layers: [Layer(name: "Base", children: [rect(0, 0)]), second],
                 selectedLayer: 0, selection: [])
    }

    private func kids(_ doc: Document, _ i: Int) -> [[Double]] {
        doc.layers[i].children.map { e in
            if case .rect(let r) = e { return [r.x, r.y] }
            return [Double.nan, Double.nan]
        }
    }

    private func layerNames(_ doc: Document) -> [String] {
        doc.layers.map { $0.name ?? "<unnamed>" }
    }

    /// OPEN QUESTION 2, pinned CONSERVATIVELY, not ruled.
    /// Append into a LOCKED matching layer SUCCEEDS, and the layer stays locked.
    /// Neither port ever checked either flag on the paste path, so this pins
    /// today's answer rather than inventing one. If JYH rules that a locked
    /// layer must refuse (or must unlock), this probe is what goes red.
    @Test func preserveAppendsIntoALockedMatchingLayerAndLeavesItLocked() {
        let doc = docWith(Layer(name: "Sky", children: [rect(5, 5)], locked: true))
        let fragment: [Element] = [.layer(Layer(name: "Sky", children: [rect(1, 2)]))]
        let out = pasteFragmentInto(doc, fragment: fragment, offset: 24, preserveLayers: true)
        #expect(out != nil, "nothing pasted")
        guard let out else { return }
        #expect(layerNames(out) == ["Base", "Sky"], "no layer should have been created")
        #expect(kids(out, 1) == [[5, 5], [25, 26]],
                "the locked layer should have gained the offset rect")
        #expect(out.layers[1].locked, "paste silently UNLOCKED the target layer")
        #expect(out.selection.count == 1)
        #expect(out.selection.first?.path == [1, 1])
    }

    /// OPEN QUESTION 2's other half: an INVISIBLE matching layer is appended
    /// into and stays invisible — so the pasted artwork is immediately hidden.
    /// Conservative, banked, and deliberately visible here because "the paste
    /// appeared to do nothing" is the user-facing shape of this answer.
    @Test func preserveAppendsIntoAHiddenMatchingLayerAndLeavesItHidden() {
        let doc = docWith(Layer(name: "Sky", children: [], visibility: .invisible))
        let fragment: [Element] = [.layer(Layer(name: "Sky", children: [rect(1, 2)]))]
        let out = pasteFragmentInto(doc, fragment: fragment, offset: 0, preserveLayers: true)
        #expect(out != nil, "nothing pasted")
        guard let out else { return }
        #expect(layerNames(out) == ["Base", "Sky"], "no layer should have been created")
        #expect(kids(out, 1) == [[1, 2]])
        #expect(out.layers[1].visibility == .invisible,
                "paste silently REVEALED the target layer")
    }

    /// The same field-preservation question one axis over: the target layer's
    /// `id` must survive an append. The old paste rebuilt the Layer from a
    /// four-field list and dropped it, which would have detached the layer's
    /// identity as a side effect of pasting into it — a Preservation Law
    /// violation (an edit preserves what it does not speak to).
    @Test func appendingIntoALayerPreservesItsIdAndOpacity() {
        let doc = docWith(Layer(name: "Sky", children: [], opacity: 0.25, id: "lyr-sky"))
        let fragment: [Element] = [.layer(Layer(name: "Sky", children: [rect(1, 2)]))]
        let out = pasteFragmentInto(doc, fragment: fragment, offset: 0, preserveLayers: true)
        #expect(out != nil)
        guard let out else { return }
        #expect(out.layers[1].id == "lyr-sky", "the target layer's id was dropped by the append")
        #expect(out.layers[1].opacity == 0.25, "the target layer's opacity was reset")
        #expect(kids(out, 1) == [[1, 2]])
    }

    /// THE BARE-ELEMENT FRAGMENT. Under R3 there is nothing to preserve, so it
    /// must land in the ACTIVE layer exactly as under R2. Both commands over the
    /// same input, so the "no difference here" claim is pinned, not described.
    @Test func aBareElementFragmentLandsInTheActiveLayerUnderBothCommands() {
        let doc = docWith(Layer(name: "Sky", children: []))
        let fragment: [Element] = [rect(1, 2), rect(3, 4)]
        for preserve in [false, true] {
            let out = pasteFragmentInto(doc, fragment: fragment, offset: 24,
                                        preserveLayers: preserve)
            #expect(out != nil, "nothing pasted (preserve=\(preserve))")
            guard let out else { continue }
            #expect(layerNames(out) == ["Base", "Sky"],
                    "preserve=\(preserve): a bare element must never create a layer")
            #expect(kids(out, 0) == [[0, 0], [25, 26], [27, 28]],
                    "preserve=\(preserve): both bare elements belong in the active layer")
            #expect(kids(out, 1).isEmpty, "preserve=\(preserve)")
        }
    }

    /// R2 as its own probe, so a reader sees the ruling and not only its
    /// exceptions: a fragment layer whose name MATCHES a document layer still
    /// lands in the ACTIVE layer under plain Paste. This is the exact branch
    /// that used to fire in Swift and no longer does.
    @Test func plainPasteIgnoresAMatchingLayerNameEntirely() {
        let doc = docWith(Layer(name: "Sky", children: []))
        let fragment: [Element] = [.layer(Layer(name: "Sky", children: [rect(1, 2)]))]
        let out = pasteFragmentInto(doc, fragment: fragment, offset: 24, preserveLayers: false)
        #expect(out != nil)
        guard let out else { return }
        #expect(kids(out, 0) == [[0, 0], [25, 26]],
                "plain Paste must land in the ACTIVE layer, name match or not")
        #expect(kids(out, 1).isEmpty,
                "plain Paste reached the name-matched layer — that is the branch R2 deletes")
    }

    /// Degenerate inputs return `nil` so the caller journals nothing and opens
    /// no transaction. An empty clipboard must not cost an undo step.
    @Test func nothingToPasteReturnsNil() {
        let doc = docWith(Layer(name: "Sky", children: []))
        #expect(pasteFragmentInto(doc, fragment: [], offset: 24, preserveLayers: false) == nil,
                "empty fragment")
        let emptyLayer: [Element] = [.layer(Layer(name: "Sky", children: []))]
        #expect(pasteFragmentInto(doc, fragment: emptyLayer, offset: 24, preserveLayers: true) == nil,
                "an empty fragment layer must not create a layer either")
        let noLayers = Document(layers: [], selectedLayer: 0, selection: [])
        #expect(pasteFragmentInto(noLayers, fragment: [rect(0, 0)], offset: 0,
                                  preserveLayers: false) == nil,
                "layerless document")
    }

    /// Hardening, matching Rust: an out-of-range `selectedLayer` clamps to the
    /// last layer instead of trapping on the index.
    @Test func anOutOfRangeSelectedLayerClampsRatherThanTrapping() {
        let base = docWith(Layer(name: "Sky", children: []))
        let doc = Document(layers: base.layers, selectedLayer: 99, selection: [])
        let out = pasteFragmentInto(doc, fragment: [rect(1, 2)], offset: 0, preserveLayers: false)
        #expect(out != nil)
        guard let out else { return }
        #expect(kids(out, 1) == [[1, 2]], "clamped to the last layer")
        #expect(out.selection.first?.path == [1, 0])
    }
}
