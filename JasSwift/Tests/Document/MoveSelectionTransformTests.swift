import Testing
@testable import JasLib

/// S-3, THE MOVE LAW: a `moveSelection` delta is DOCUMENT space.
///
/// Twin of the reference's `test_move_selection_transform.py` and of Rust's
/// `a_rect_moves_by_the_document_delta` / `a_reference_moves_by_the_document_delta`
/// in `document/controller.rs`. Control points live in the element's LOCAL
/// space, so a document-space delta must be mapped through the inverse of the
/// accumulated transform before it reaches `moveControlPoints` (which is
/// local-space by contract and is NOT the site of this correction). Until
/// 2026-09-17 no port did that, and a 30-degree rect typed to x=100 landed at
/// 83.74 — the S-3 transform-blind class,
/// `transcripts/EDIT_SEMANTICS_FREEZE.md` §3.3.
///
/// ⛔ THE TWO MOVE SPACES, which is what the reference arms exist to pin. A
/// reference has no geometry of its own: a whole-element move rides on its OWN
/// `transform`, translating its `e`/`f`, and that already lands it in the
/// PARENT's space. So for a reference the element's own transform is LEFT OUT
/// of the conversion while every ancestor's is kept. Converting a reference by
/// the full chain re-creates the very defect this repair removes, one level
/// down — it was introduced and caught inside the reference's own repair.
@Suite("S-3 move law: a moveSelection delta is document space")
struct MoveSelectionTransformTests {

    /// The element's DOCUMENT-space bbox origin — the point a translation
    /// moves. The same oracle the reference and Rust arms use, so all three
    /// agree about what document space is.
    private func evaluatedOrigin(_ doc: Document, _ path: ElementPath) -> (Double, Double) {
        guard let b = elementEvaluatedBBox(doc, path) else {
            Issue.record("path \(path) did not resolve")
            return (.nan, .nan)
        }
        return (b.x, b.y)
    }

    /// A rect at (10, 20) selected whole, optionally transformed, optionally
    /// under a transformed layer. Mirrors the reference's `_rect_model`.
    private func rectModel(_ transform: Transform?, _ layerTransform: Transform?) -> Model {
        var d = Document(layers: [Layer(
            name: "L0",
            children: [.rect(Rect(x: 10, y: 20, width: 30, height: 40, transform: transform))],
            transform: layerTransform)])
        d = d.replacing(selection: [ElementSelection.all([0, 0])])
        return Model(document: d)
    }

    private static let rot = Transform.rotate(30)
    private static let trans = Transform.translate(50, 60)

    // ── geometry-bearing elements: the delta converts by the FULL chain ──

    @Test func aRectMovesByTheDocumentDelta() {
        // ⛔ THE TRANSLATION-BEARING CASES ARE NOT DECORATION. Every rotate /
        // scale / shear here has e = f = 0, so applying the inverse as a POINT
        // and applying only its LINEAR part give the same answer — a mutant
        // that translated the delta survives all of them. A translation moves
        // points, not the vectors between them, so it must never reach a
        // delta, and only a transform that HAS one can witness that. The
        // reference arm found this by mutation; it is ported, not re-derived.
        let cases: [(String, Transform?, Transform?)] = [
            ("untransformed", nil, nil),
            ("rotated", Self.rot, nil),
            ("scaled", Transform.scale(2, 3), nil),
            ("sheared", Transform.shear(0.25, 0), nil),
            ("under a rotated layer", nil, Self.rot),
            ("rotated under a rotated layer", Self.rot, Self.rot),
            ("translated", Self.trans, nil),
            ("rotated and translated", Self.trans.multiply(Self.rot), nil),
            ("under a translated layer", nil, Self.trans),
        ]
        for (name, transform, layerTransform) in cases {
            let model = rectModel(transform, layerTransform)
            let before = evaluatedOrigin(model.document, [0, 0])
            Controller(model: model).moveSelection(dx: 12, dy: -7)
            let after = evaluatedOrigin(model.document, [0, 0])
            #expect(abs(after.0 - before.0 - 12) < 1e-9,
                    "\(name): dx was \(after.0 - before.0), expected 12")
            #expect(abs(after.1 - before.1 + 7) < 1e-9,
                    "\(name): dy was \(after.1 - before.1), expected -7")
        }
    }

    // ── references: the move rides on the element's OWN transform ──

    @Test func aReferenceMovesByTheDocumentDelta() {
        let cases: [(String, Transform?, Transform?)] = [
            ("untransformed", nil, nil),
            ("rotated", Self.rot, nil),
            ("scaled", Transform.scale(2, 3), nil),
            ("under a rotated layer", nil, Self.rot),
            ("rotated under a rotated layer", Self.rot, Self.rot),
            ("translated", Self.trans, nil),
            ("under a translated layer", nil, Self.trans),
        ]
        for (name, transform, layerTransform) in cases {
            let ctrl = Controller(model: Model())
            ctrl.addElement(.rect(Rect(x: 0, y: 0, width: 10, height: 10)))
            ctrl.makeSymbol([0, 0], masterId: "m1", refId: "i1")
            var doc = ctrl.document
            guard case .live(.reference(var r)) = doc.getElement([0, 0]) else {
                Issue.record("\(name): makeSymbol did not leave a reference at [0,0]")
                continue
            }
            r.transform = transform
            doc = doc.replaceElement([0, 0], with: .live(.reference(r)))
            if let lt = layerTransform {
                var layer = doc.layers[0]
                layer.transform = lt
                doc = doc.replacing(layers: [layer])
            }
            ctrl.model.editDocument(doc)
            ctrl.selectElement([0, 0])
            let before = evaluatedOrigin(ctrl.document, [0, 0])
            ctrl.moveSelection(dx: 12, dy: -7)
            let after = evaluatedOrigin(ctrl.document, [0, 0])
            #expect(abs(after.0 - before.0 - 12) < 1e-9,
                    "\(name): dx was \(after.0 - before.0), expected 12")
            #expect(abs(after.1 - before.1 + 7) < 1e-9,
                    "\(name): dy was \(after.1 - before.1), expected -7")
        }
    }

    @Test func anUntransformedMoveIsUnchangedByTheConversion() {
        // CONTROL. With no transform anywhere the conversion must be the
        // identity, so the delta reaches `moveControlPoints` exactly as it was
        // passed — the property that keeps every pre-existing golden valid.
        // This arm must be GREEN before the repair as well as after.
        let model = rectModel(nil, nil)
        Controller(model: model).moveSelection(dx: 12, dy: -7)
        guard case .rect(let r) = model.document.getElement([0, 0]) else {
            Issue.record("expected a Rect"); return
        }
        #expect(r.x == 22)
        #expect(r.y == 13)
    }
}
