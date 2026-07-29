import AppKit
import Testing
import Foundation
@testable import JasLib

/// §19'S GATE — THE DUPLICATE LEAVES ITS SELECTION IN DOCUMENT ORDER, AND THE
/// ASSERTION REACHES THE CLIPBOARD (RULED 2026-07-28 by JYH: *"yes document
/// order."*). Twin of Rust
/// `workspace::clipboard::copy_payload_tests::a_duplicate_then_copy_emits_the_copies_in_document_order`.
///
/// **Why this suite exists rather than one more probe beside `copySelection`.**
/// The selection a duplicate leaves is an INTERNAL fact until a subsequent Copy
/// emits it. `EditClipboard.copySelection` walks `doc.selection` in stored order
/// and writes the elements in exactly that order, so the byproduct becomes
/// artist-visible one step from where it is created — which is why it went
/// unseen. A gate that checked the selection and not the clipboard would pass on
/// a fix that left the leak in place.
///
/// **What this reaches, stated plainly.** The cross-language corpus reaches the
/// SELECTION (`test_fixtures/operations/select_all_top_level.json`, case
/// `copy_of_a_two_element_selection_emits_a_deterministic_order`) because
/// `copy_selection` is a shared op verb. It does NOT reach the CLIPBOARD: there
/// is no copy-to-clipboard op verb in either port, and the corpus's canonical
/// JSON serializes a document, not a pasteboard. So the clipboard half is
/// in-port in each active port, written to the same shape, and the corpus is
/// what keeps the two selections identical.
@Suite struct DuplicateCopyOrderTests {

    private static func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(rawValue: "jas.tests.dupcopy.\(UUID().uuidString)"))
    }

    /// The x-coordinates the copy payload round-trips to, in PAYLOAD order.
    /// The SVG codec scales pt -> px (x4/3) and back at 4 decimals, so a
    /// coordinate returns within ~2.5e-5; the tolerance below is DERIVED from
    /// that transport property, not guessed.
    private static func payloadXs(_ model: Model) -> [Double] {
        let pb = privatePasteboard()
        EditClipboard.copySelection(model, pasteboard: pb)
        guard let svg = pb.string(forType: .string) else { return [] }
        let back = svgToDocument(svg)
        guard back.layers.count == 1 else {
            Issue.record("the copy payload must be ONE layer; got \(back.layers.count)")
            return []
        }
        return back.layers[0].children.map {
            if case .rect(let r) = $0 { return r.x }
            return Double.nan
        }
    }

    /// Alt-drag-duplicate the NON-CONTIGUOUS pair b=[0,1] and d=[0,3] of four
    /// rects, then Copy. The duplicate's descending walk is load-bearing and
    /// stays, so the document is
    ///
    ///     a@0  b@10  b'@16  c@20  d@30  d'@36
    ///
    /// and the payload must be the two COPIES, back-to-front: **[16, 36]**.
    ///
    /// THE FOUR OUTCOMES, so the assertion cannot be read as merely tidy:
    ///   * `[30, 16]` — what shipped. Reverse document order AND it carries d,
    ///     the SOURCE, because the byproduct recorded `[0,4]` before the later
    ///     insertion at [0,1] shifted d up to index 4.
    ///   * `[16, 30]` — sorted the stale paths. Order fixed, still a source.
    ///   * `[36, 16]` — fixed the paths, kept the descending order.
    ///   * `[16, 36]` — RULED.
    ///
    /// This drives the PRODUCTION mutator (`Controller.copySelection`) and the
    /// PRODUCTION payload (`EditClipboard.copySelection` onto a real
    /// `NSPasteboard`), so it is the artist's gesture pair end to end and not a
    /// reconstruction of it.
    @Test func aDuplicateThenCopyEmitsTheCopiesInDocumentOrder() {
        let rects = (0..<4).map { i in
            Element.rect(Rect(x: Double(i) * 10.0, y: 0, width: 10, height: 10))
        }
        let doc = Document(layers: [Layer(name: "L0", children: rects)],
                           selectedLayer: 0,
                           selection: [ElementSelection.all([0, 1]),
                                       ElementSelection.all([0, 3])])
        let model = Model(document: doc)
        Controller(model: model).copySelection(dx: 6, dy: 0)

        let xs = Self.payloadXs(model)
        #expect(xs.count == 2,
                "a duplicate of two elements must put two elements on the clipboard; got \(xs)")
        guard xs.count == 2 else { return }
        for (got, want) in zip(xs, [16.0, 36.0]) {
            #expect(abs(got - want) < 1e-3,
                    """
                    clipboard payload is \(xs); expected [16, 36] — the two \
                    COPIES in document order. [30, 16] is the shipped defect \
                    (reverse order, and the first entry is the SOURCE d).
                    """)
        }
    }
}
