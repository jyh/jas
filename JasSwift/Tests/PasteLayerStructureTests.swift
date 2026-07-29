import Testing
@testable import JasLib

/// PASTE AND LAYER STRUCTURE — the cases the shared corpus CANNOT reach.
/// Twin of Rust `op_apply::paste_layer_structure_tests`.
///
/// `test_fixtures/operations/paste_layers.json` is the primary gate for
/// LAYER_STRUCTURE.md R2/R3 and it is cross-language. This suite exists for
/// exactly two shapes that family cannot express, and each says which:
///
/// 1. **LOCKED and HIDDEN target layers.** This used to read "the corpus is
///    structurally blind to it, because the SVG codec does not persist `locked`
///    AT ALL". `jas:locked` (§13.1) retired that on 2026-07-28, the behaviour
///    was RULED the same day (§15), and
///    `test_fixtures/operations/paste_locked_layers.json` is now the primary,
///    CROSS-LANGUAGE gate. These probes are demoted to a per-port second
///    opinion on the same rules, and they keep the shapes the corpus still
///    cannot express — a locked SIBLING, and a hidden target seeded directly.
///    They also catch a REAL defect the old paste carried: it rebuilt the
///    target as `Layer(name:children:opacity:transform:)`, silently dropping
///    `locked`, `visibility`, `blendMode`, `mask`, `isolatedBlending`,
///    `knockoutGroup` and `id` — the Swift copy-site omission class, at a paste.
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

    /// BOUNDS-SAFE on purpose. `#expect` records and CONTINUES, unlike Rust's
    /// `assert_eq!`, so a probe that indexes a layer a mutant never created
    /// reds by TRAPPING — which aborts the whole `swift test` process and hides
    /// every later failure. Measured: mutation M7 of the PASTELOCK wave did
    /// exactly that. `[]` here is never a legitimate expectation in this suite,
    /// so the miss still reds; it just reds legibly.
    private func kids(_ doc: Document, _ i: Int) -> [[Double]] {
        guard i >= 0, i < doc.layers.count else { return [] }
        return doc.layers[i].children.map { e in
            if case .rect(let r) = e { return [r.x, r.y] }
            return [Double.nan, Double.nan]
        }
    }

    private func layerNames(_ doc: Document) -> [String] {
        doc.layers.map { $0.name ?? "<unnamed>" }
    }

    /// RULED 2026-07-28 (§15.2/§15.3): a LOCKED matching layer DIVERTS to a
    /// numerically suffixed sibling. The fragment named that layer, not the
    /// artist, so serving the artist's actual intent means creating "Sky 2"
    /// rather than declining.
    ///
    /// This probe used to assert the opposite — it pinned the pre-ruling
    /// "appends into a locked layer and leaves it locked", and said in as many
    /// words that a ruling to refuse or unlock would turn it red. It did, and
    /// this is that turn. Twin of Rust
    /// `preserve_diverts_from_a_locked_matching_layer_to_a_numeric_sibling`.
    ///
    /// What this adds over the shared golden is that the LOCKED layer is left
    /// byte-untouched, which the golden shows but does not say.
    @Test func preserveDivertsFromALockedMatchingLayerToANumericSibling() {
        let doc = docWith(Layer(name: "Sky", children: [rect(5, 5)], locked: true))
        let fragment: [Element] = [.layer(Layer(name: "Sky", children: [rect(1, 2)]))]
        let out = pasteFragmentInto(doc, fragment: fragment, offset: 24, preserveLayers: true)
        #expect(out != nil, "nothing pasted")
        guard let out else { return }
        #expect(layerNames(out) == ["Base", "Sky", "Sky 2"],
                "the locked 'Sky' must be diverted around, into a created 'Sky 2'")
        #expect(kids(out, 1) == [[5, 5]], "the LOCKED layer must be left exactly as it was")
        #expect(kids(out, 2) == [[25, 26]], "the sibling holds the paste")
        // Hard guard: see `kids`. Without it a mutant that creates no sibling
        // traps here and takes the whole run down with it.
        guard out.layers.count == 3 else {
            Issue.record("expected three layers, got \(layerNames(out))")
            return
        }
        #expect(out.layers[1].locked, "the divert must not unlock anything")
        #expect(!out.layers[2].locked, "the created sibling must be open")
        #expect(out.selection.count == 1)
        #expect(out.selection.first?.path == [2, 0])
    }

    /// The SUFFIX WALK stops at an EXISTING open sibling instead of minting a
    /// third layer — the reason `preservingLayerTarget` is a walk. Twin of Rust
    /// `preserve_diverts_into_an_existing_open_sibling_rather_than_minting_a_third`.
    @Test func preserveDivertsIntoAnExistingOpenSiblingRatherThanMintingAThird() {
        var doc = docWith(Layer(name: "Sky", children: [rect(5, 5)], locked: true))
        doc = doc.replacing(layers: doc.layers + [Layer(name: "Sky 2", children: [])])
        let fragment: [Element] = [.layer(Layer(name: "Sky", children: [rect(1, 2)]))]
        let out = pasteFragmentInto(doc, fragment: fragment, offset: 24, preserveLayers: true)
        #expect(out != nil, "nothing pasted")
        guard let out else { return }
        #expect(layerNames(out) == ["Base", "Sky", "Sky 2"],
                "no 'Sky 3' may be minted while 'Sky 2' is open")
        #expect(kids(out, 2) == [[25, 26]])
        #expect(out.selection.first?.path == [2, 0])
    }

    /// The walk KEEPS WALKING past a locked sibling: "Sky" and "Sky 2" both
    /// locked gives "Sky 3" — the case that proves the walk is a loop rather
    /// than a single `+ 1`. Twin of Rust
    /// `preserve_walks_past_a_locked_sibling_to_the_next_free_suffix`.
    @Test func preserveWalksPastALockedSiblingToTheNextFreeSuffix() {
        var doc = docWith(Layer(name: "Sky", children: [rect(5, 5)], locked: true))
        doc = doc.replacing(
            layers: doc.layers + [Layer(name: "Sky 2", children: [], locked: true)])
        let fragment: [Element] = [.layer(Layer(name: "Sky", children: [rect(1, 2)]))]
        let out = pasteFragmentInto(doc, fragment: fragment, offset: 0, preserveLayers: true)
        #expect(out != nil, "nothing pasted")
        guard let out else { return }
        #expect(layerNames(out) == ["Base", "Sky", "Sky 2", "Sky 3"])
        // `#expect` records and CONTINUES, unlike Rust's `assert_eq!`, so the
        // count is a hard guard: without it a mutant that creates no fourth
        // layer reds by TRAPPING on the index, which aborts the whole run and
        // hides every later failure. Measured — M7 did exactly that.
        guard out.layers.count == 4 else {
            Issue.record("expected four layers, got \(layerNames(out))")
            return
        }
        #expect(kids(out, 3) == [[1, 2]])
    }

    /// HIDDEN IS NOT LOCKED — RULED 2026-07-28 (§15.3 item 2). An INVISIBLE
    /// matching layer is appended into and stays invisible, so the pasted
    /// artwork is immediately hidden. That is the point: hidden is a visibility
    /// state, not a protection, and diverting there would manufacture a layer to
    /// avoid a condition that protects nothing. Deliberately visible here
    /// because "the paste appeared to do nothing" is the user-facing shape of
    /// this answer, and the artist unhides.
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
