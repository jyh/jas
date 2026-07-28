import AppKit
import Testing
import Foundation
@testable import JasLib

/// THE INTERNAL CLIPBOARD, CONFIRMED — the Swift half.
///
/// `transcripts/LAYER_STRUCTURE.md` §7 admitted a blind spot: only the SVG paste
/// path had been read, and JYH's ratification rode on confirming the
/// internal-clipboard path. These are the measurements for Swift.
///
/// **The headline finding was structural: Swift HAD NO internal element
/// clipboard**, where Rust carried `TabState.clipboard: Vec<Element>` and fell
/// through to it. So "the internal path" was not a path the two ports
/// implemented differently; it was a path only one port HAD. **That is now
/// resolved rather than merely watched**: JYH ruled on 2026-07-28 (D4/D5) that
/// Swift is canon, and `TabState.clipboard` is deleted — neither port has an
/// internal clipboard. The two probes that pinned the divergence are gone from
/// the end of this file; what replaces them is `ClipboardTextPasteTests` plus
/// the cross-language family `paste_clipboard_text.json`, which makes the ports
/// AGREE rather than recording that they do not.
///
/// What remains here is the still-true half: what an in-app COPY emits, and
/// what a paste does with ids and offsets.
///
/// Written as CHARACTERIZATION probes (they assert today's behaviour, not the
/// behaviour R2/R3 will require), so the evidence that they can see is their
/// MUTATION proof, recorded in the brief — not a red-first run.
@Suite struct InternalClipboardConfirmTests {

    /// Tolerance forced by the TRANSPORT, measured not guessed.
    /// `documentToSvg` scales document points to px (x4/3) and emits 4 decimal
    /// places; `svgToDocument` scales back by 3/4. So `x = 1` ships as
    /// `"1.3333"` and returns as `0.999975` — a quantization of ~2.5e-5 pt on
    /// EVERY clipboard round trip. It is a property of the SVG transport, not of
    /// paste, but it is worth stating plainly: NEITHER port has a lossless
    /// copy/paste path any more. Rust's internal fallback cloned `Element`
    /// values and was exact; deleting it (D4/D5) means Rust now quantizes
    /// exactly as Swift does — which is a convergence, and the price of it is
    /// this ~2.5e-5 pt.
    private static let svgTol = 1e-3

    private static func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(rawValue: "jas.tests.intclip.\(UUID().uuidString)"))
    }

    private static func rect(_ x: Double, _ y: Double, id: String) -> Element {
        .rect(Rect(x: x, y: y, width: 10, height: 10, name: nil, id: id))
    }

    /// Two NAMED layers, one element in each, both selected.
    private static func twoLayerModel() -> Model {
        let doc = Document(
            layers: [Layer(name: "Sky", children: [rect(0, 0, id: "r-sky")]),
                     Layer(name: "Ground", children: [rect(100, 100, id: "r-ground")])],
            selectedLayer: 0,
            selection: [ElementSelection.all([0, 0]), ElementSelection.all([1, 0])])
        return Model(document: doc)
    }

    // MARK: - Q1/Q2: what COPY stores, and whether it can carry layer identity

    /// THE FINDING THAT SETTLES Q2 FOR SWIFT: the flattening does not happen at
    /// paste, it happens at COPY. `copySelection` builds `Document(layers:
    /// [Layer(children: elements)])` — ONE layer, and an unnamed one — from a
    /// selection that spanned two named layers. Layer identity is destroyed
    /// before the payload ever reaches the pasteboard, so no paste
    /// implementation downstream could restore it.
    @Test func copyAcrossTwoLayersEmitsOneUnnamedLayerCarryingNoLayerIdentity() {
        let pb = Self.privatePasteboard()
        let model = Self.twoLayerModel()
        EditClipboard.copySelection(model, pasteboard: pb)
        let svg = pb.string(forType: .string)
        #expect(svg != nil, "copy put nothing on the pasteboard")
        guard let svg else { return }
        let round = svgToDocument(svg)
        #expect(round.layers.count == 1,
                "copy emitted \(round.layers.count) layers; a cross-layer copy is flattened AT COPY")
        guard round.layers.count == 1 else { return }
        #expect(round.layers[0].name == nil,
                "the emitted layer is named \(round.layers[0].name ?? "nil") — it should carry NO name, which is why Swift's name-match branch can never fire for an in-app copy")
        // MANDATORY GEOMETRY PAIRING: both elements really are in that one layer.
        // Order-insensitive because `Selection` is a Set — see
        // `copyEmitsAPermutationOfTheSelectionNotDocumentOrder`.
        #expect(round.layers[0].children.count == 2)
        let xs = round.layers[0].children.compactMap { c -> Double? in
            if case .rect(let r) = c { return r.x }
            return nil
        }.sorted()
        #expect(xs.count == 2, "expected two rect children, got \(xs.count)")
        guard xs.count == 2 else { return }
        #expect(abs(xs[0] - 0) < Self.svgTol,
                "the layer-0 element is at x=\(xs[0]), expected 0")
        #expect(abs(xs[1] - 100) < Self.svgTol,
                "the layer-1 element is at x=\(xs[1]), expected 100 — it is now a SIBLING of layer 0's element in one flat layer")
    }

    /// Q2, the sink half. Paste that cross-layer copy back: both elements land
    /// in the ACTIVE layer, and the document's layer count does not move.
    @Test func pasteOfACrossLayerCopyPutsEverythingInTheActiveLayer() {
        let pb = Self.privatePasteboard()
        let model = Self.twoLayerModel()
        EditClipboard.copySelection(model, pasteboard: pb)
        let layersBefore = model.document.layers.count
        EditClipboard.pasteClipboard(model, offset: 24.0, pasteboard: pb)
        let doc = model.document
        #expect(doc.layers.count == layersBefore,
                "layer count moved \(layersBefore) -> \(doc.layers.count); paste is not supposed to create one today")
        #expect(doc.selectedLayer == 0)
        #expect(doc.layers[0].children.count == 3,
                "active layer holds \(doc.layers[0].children.count) children, expected 3 (1 original + 2 pasted)")
        #expect(doc.layers[1].children.count == 1,
                "the OTHER layer gained \(doc.layers[1].children.count - 1) children; nothing should have gone there")
        // MANDATORY GEOMETRY PAIRING: the element that came from layer 1 is now
        // sitting in layer 0, offset — the flattening, stated by value.
        //
        // ORDER-INSENSITIVE ON PURPOSE, and that is itself a finding: Swift's
        // `Selection` is a `Set`, so `copySelection`'s iteration order is hash
        // order, not document order. Asserting a fixed index here would be a
        // flaky test. See `copyEmitsAPermutationOfTheSelectionNotDocumentOrder`.
        guard doc.layers[0].children.count == 3 else { return }
        let pastedXs = doc.layers[0].children[1...].compactMap { c -> Double? in
            if case .rect(let r) = c { return r.x }
            return nil
        }.sorted()
        #expect(pastedXs.count == 2, "expected two pasted rects, got \(pastedXs.count)")
        guard pastedXs.count == 2 else { return }
        #expect(abs(pastedXs[0] - 24) < Self.svgTol,
                "the Sky element landed at x=\(pastedXs[0]) in layer 0, expected 24")
        #expect(abs(pastedXs[1] - 124) < Self.svgTol,
                "the Ground element landed at x=\(pastedXs[1]) in layer 0, expected 124 — it CROSSED from layer 1")
    }

    // MARK: - Q3: does paste ever create a layer?

    /// Q3 for Swift, on a fragment the ports do NOT agree about: a two-layer SVG
    /// whose layer names appear nowhere in the document. `newLayers` starts as
    /// `doc.layers` and is only ever written at an existing index, so no layer is
    /// created and the whole fragment collapses into the active layer.
    @Test func pasteNeverCreatesALayerForATwoLayerNamedFragment() {
        let pb = Self.privatePasteboard()
        let fragment = Document(
            layers: [Layer(name: "Foreign A", children: [Self.rect(1, 2, id: "f-a")]),
                     Layer(name: "Foreign B", children: [Self.rect(3, 4, id: "f-b")])],
            selectedLayer: 0, selection: [])
        pb.clearContents()
        pb.setString(documentToSvg(fragment), forType: .string)

        let doc0 = Document(layers: [Layer(name: "Only", children: [])],
                            selectedLayer: 0, selection: [])
        let model = Model(document: doc0)
        EditClipboard.pasteClipboard(model, offset: 0.0, pasteboard: pb)

        let doc = model.document
        #expect(doc.layers.count == 1,
                "paste created \(doc.layers.count - 1) layer(s); the brief says neither port ever creates one")
        #expect(doc.layers[0].name == "Only", "the target layer was renamed to \(doc.layers[0].name ?? "nil")")
        #expect(doc.layers[0].children.count == 2,
                "expected both foreign layers' children flattened into the one layer, got \(doc.layers[0].children.count)")
        guard doc.layers[0].children.count == 2,
              case .rect(let a) = doc.layers[0].children[0],
              case .rect(let b) = doc.layers[0].children[1] else {
            Issue.record("expected two rects"); return
        }
        #expect(abs(a.x - 1) < Self.svgTol && abs(a.y - 2) < Self.svgTol,
                "first at (\(a.x), \(a.y)), expected (1, 2)")
        #expect(abs(b.x - 3) < Self.svgTol && abs(b.y - 4) < Self.svgTol,
                "second at (\(b.x), \(b.y)), expected (3, 4) — it came from 'Foreign B' and is now a sibling of 'Foreign A's child")
    }

    // MARK: - The ordering divergence found while measuring Q2

    /// AN UNRECORDED DIVERGENCE, found while measuring the cross-layer copy.
    ///
    /// `Selection` is `Set<ElementSelection>` in Swift and `Vec<ElementSelection>`
    /// in Rust. Both copy sides iterate `doc.selection` to build the payload, so
    /// Rust emits elements in the selection's stored order while Swift emits them
    /// in HASH order. Swift's `Hasher` is seeded per process, so the pasted
    /// stacking order of a multi-element selection can differ between two runs of
    /// the same build. Measured: five selected elements, ten separate `swift test`
    /// processes, ten different orders, document order never once observed.
    ///
    /// This probe pins the part that is deterministic — the payload is a
    /// PERMUTATION of the selection, nothing lost, nothing duplicated — because
    /// asserting the order itself would be a flaky test. The order question is
    /// banked for a ruling rather than decided here.
    @Test func copyEmitsAPermutationOfTheSelectionNotDocumentOrder() {
        let pb = Self.privatePasteboard()
        var kids: [Element] = []
        for i in 0..<5 {
            kids.append(Self.rect(Double(i) * 10, 0, id: "r\(i)"))
        }
        var sel: Selection = []
        for i in 0..<5 { sel.insert(ElementSelection.all([0, i])) }
        let model = Model(document: Document(layers: [Layer(children: kids)],
                                             selectedLayer: 0, selection: sel))
        EditClipboard.copySelection(model, pasteboard: pb)
        guard let svg = pb.string(forType: .string) else {
            Issue.record("copy put nothing on the pasteboard"); return
        }
        let round = svgToDocument(svg)
        #expect(round.layers.count == 1)
        guard round.layers.count == 1 else { return }
        let xs = round.layers[0].children.compactMap { c -> Double? in
            if case .rect(let r) = c { return r.x }
            return nil
        }
        #expect(xs.count == 5, "expected all five elements, got \(xs.count)")
        // Every source x is present exactly once — a permutation, not a loss.
        let slots = xs.map { Int(($0 / 10).rounded()) }.sorted()
        #expect(slots == [0, 1, 2, 3, 4],
                "copy did not emit each selected element exactly once; got slots \(slots)")
    }

    // MARK: - Q5: ids

    /// Q5. A paste is 0 -> N under the cardinality law and should mint fresh ids.
    /// It does not: the id rides through the SVG round trip verbatim, so after
    /// copy+paste the document holds TWO live elements claiming one identity.
    @Test func pasteCopiesElementIdsVerbatimSoIdentityIsDuplicated() {
        let pb = Self.privatePasteboard()
        let doc0 = Document(layers: [Layer(children: [Self.rect(0, 0, id: "keel-1")])],
                            selectedLayer: 0, selection: [ElementSelection.all([0, 0])])
        let model = Model(document: doc0)
        EditClipboard.copySelection(model, pasteboard: pb)
        EditClipboard.pasteClipboard(model, offset: 24.0, pasteboard: pb)

        let kids = model.document.layers[0].children
        #expect(kids.count == 2, "expected the original plus the paste, got \(kids.count)")
        guard kids.count == 2 else { return }
        #expect(kids[0].id == "keel-1")
        #expect(kids[1].id == "keel-1",
                "pasted id is \(kids[1].id ?? "nil"); TODAY it duplicates the source id verbatim. When the cardinality-law fix lands this probe must be inverted, not deleted.")
        // MANDATORY GEOMETRY PAIRING: they are two distinct elements at distinct
        // places sharing one id — which is exactly why the duplication matters.
        guard case .rect(let orig) = kids[0], case .rect(let copy) = kids[1] else {
            Issue.record("expected rects"); return
        }
        #expect(abs(orig.x - 0) < Self.svgTol && abs(orig.y - 0) < Self.svgTol,
                "original at (\(orig.x), \(orig.y)), expected (0, 0)")
        #expect(abs(copy.x - 24) < Self.svgTol && abs(copy.y - 24) < Self.svgTol,
                "copy at (\(copy.x), \(copy.y)), expected (24, 24)")
    }

    // MARK: - Q6: the offset, through the WHOLE paste path

    /// Q6. `PasteTranslateTests` pins the offset at the HELPER. This drives the
    /// offset through `pasteClipboard` end to end for a live compound — the kind
    /// whose offset was the previously-landed fix — so the wiring between the
    /// paste site and the helper is watched too.
    @Test func pasteAppliesTheOffsetToACompoundThroughTheWholePath() {
        let pb = Self.privatePasteboard()
        let cs = CompoundShape(operation: .union,
                               operands: [Self.rect(0, 0, id: "op-a"),
                                          Self.rect(5, 0, id: "op-b")],
                               name: nil, id: "cs-1")
        let doc0 = Document(layers: [Layer(children: [.live(.compoundShape(cs))])],
                            selectedLayer: 0, selection: [ElementSelection.all([0, 0])])
        let model = Model(document: doc0)
        EditClipboard.copySelection(model, pasteboard: pb)
        EditClipboard.pasteClipboard(model, offset: 24.0, pasteboard: pb)

        let kids = model.document.layers[0].children
        #expect(kids.count == 2, "expected 2 children, got \(kids.count)")
        guard kids.count == 2 else { return }
        // The pasted element must not sit on top of its source — the one outcome
        // the offset exists to prevent.
        let src = kids[0].bounds, pasted = kids[1].bounds
        #expect(abs(pasted.x - (src.x + 24)) < Self.svgTol,
                "pasted x \(pasted.x) is not source x \(src.x) + 24")
        #expect(abs(pasted.y - (src.y + 24)) < Self.svgTol,
                "pasted y \(pasted.y) is not source y \(src.y) + 24")
    }

    /// Q6's other half: `paste_in_place` is "no offset", end to end.
    @Test func pasteInPlaceAppliesNoOffsetThroughTheWholePath() {
        let pb = Self.privatePasteboard()
        let doc0 = Document(layers: [Layer(children: [Self.rect(7, 11, id: "r-1")])],
                            selectedLayer: 0, selection: [ElementSelection.all([0, 0])])
        let model = Model(document: doc0)
        EditClipboard.copySelection(model, pasteboard: pb)
        EditClipboard.pasteClipboard(model, offset: 0.0, pasteboard: pb)

        let kids = model.document.layers[0].children
        #expect(kids.count == 2, "expected 2 children, got \(kids.count)")
        guard kids.count == 2, case .rect(let copy) = kids[1] else {
            Issue.record("expected a rect copy"); return
        }
        // The transport's ~2.5e-5 quantization is NOT a paste offset; the
        // tolerance separates "did not move" from a real 24pt offset by four
        // orders of magnitude.
        #expect(abs(copy.x - 7) < Self.svgTol && abs(copy.y - 11) < Self.svgTol,
                "paste_in_place moved the element to (\(copy.x), \(copy.y)), expected (7, 11)")
    }

    // MARK: - A spec sentence neither port implements

    /// FOUND WHILE MEASURING Q6, and it is a SHARED defect rather than a
    /// divergence. `workspace/actions.yaml` §paste (line 186) says "Repeated
    /// pastes stack with cumulative offsets". Neither port does: paste never
    /// mutates the clipboard, so every paste of the same payload applies the
    /// SAME 24pt offset and the second paste lands exactly on the first —
    /// invisible, the outcome the offset exists to prevent, arrived at by
    /// pasting twice instead of once.
    ///
    /// Rust has the same shape: `clipboard_read_and_paste` reads `tab.clipboard`
    /// and never writes it, so its repeated pastes are equally non-cumulative.
    /// That half is READ, not driven — the sink is unreachable from
    /// `cargo test --lib` (see `internal_clipboard_confirm_tests`).
    @Test func repeatedPastesDoNotStackCumulativelyAsTheSpecRequires() {
        let pb = Self.privatePasteboard()
        let doc0 = Document(layers: [Layer(children: [Self.rect(0, 0, id: "r-1")])],
                            selectedLayer: 0, selection: [ElementSelection.all([0, 0])])
        let model = Model(document: doc0)
        EditClipboard.copySelection(model, pasteboard: pb)
        EditClipboard.pasteClipboard(model, offset: 24.0, pasteboard: pb)
        EditClipboard.pasteClipboard(model, offset: 24.0, pasteboard: pb)

        let kids = model.document.layers[0].children
        #expect(kids.count == 3, "expected original + two pastes, got \(kids.count)")
        guard kids.count == 3,
              case .rect(let first) = kids[1],
              case .rect(let second) = kids[2] else {
            Issue.record("expected three rects"); return
        }
        #expect(abs(first.x - 24) < Self.svgTol, "first paste at x=\(first.x), expected 24")
        // TODAY: 24 again, not 48. Invert this probe if cumulative stacking is
        // ever implemented — do not delete it.
        #expect(abs(second.x - 24) < Self.svgTol,
                "second paste at x=\(second.x); TODAY it repeats 24 rather than stacking to 48, so it lands exactly on the first paste")
        #expect(abs(second.x - first.x) < Self.svgTol,
                "the two pastes are NOT coincident (\(first.x) vs \(second.x)) — cumulative stacking may have landed")
    }

    // MARK: - Q4: the two points where Rust USED TO consult its internal clipboard
    //
    // Both divergences are CLOSED (D4/D5, ratified 2026-07-28: Swift is canon;
    // `TabState.clipboard` is deleted). The probes that pinned them moved to
    // `ClipboardTextPasteTests`, which asserts the RULED behaviour rather than a
    // divergence, and their cross-language twins now live in
    // `test_fixtures/operations/paste_clipboard_text.json` — where BOTH ports
    // must agree over shared goldens, which is the only place a divergence of
    // this shape can be prevented rather than merely recorded.
}
