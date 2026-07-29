import AppKit
import Testing
import Foundation
@testable import JasLib

/// WHAT THE CLIPBOARD HOLDS DECIDES WHAT PASTE DOES — the Swift half of D4/D5
/// (ratified 2026-07-28: **Swift is canon**, Rust drops its internal-clipboard
/// fallback).
///
/// The primary gate is the cross-language corpus family
/// `test_fixtures/operations/paste_clipboard_text.json`, driven by
/// `operationPasteClipboardText` in both ports over shared goldens. This suite
/// exists for the two things that family CANNOT reach, and each probe says
/// which:
///
/// 1. **The WIRE.** The corpus drives `pasteClipboardTextInto` through the
///    `paste` op verb; it never touches an `NSPasteboard`. These probes drive
///    `EditClipboard.pasteClipboard` with a private pasteboard, so the whole
///    production path — read the pasteboard, dispatch, edit the document — is
///    watched end to end. **Rust has no equivalent**: its read still sits in a
///    `spawn_local` closure over an `Rc<RefCell<AppState>>` and a Dioxus
///    `Signal`, unreachable from `cargo test --lib`. That asymmetry is stated
///    rather than smoothed over.
/// 2. **Layer fields the SVG codec cannot carry.** `visibility` and `id` still
///    survive no SVG round trip in either port, so no `setup_svg` can build a
///    hidden / identified target layer. (`locked` USED to be on that list;
///    `jas:locked`, §13.1, removed it on 2026-07-28, and the locked-target
///    behaviour is now gated cross-language by
///    `test_fixtures/operations/paste_locked_layers.json`.) Twin of Rust
///    `pasting_text_into_a_hidden_identified_layer_preserves_its_fields`.
@Suite struct ClipboardTextPasteTests {

    private static func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(rawValue: "jas.tests.cliptext.\(UUID().uuidString)"))
    }

    private static func rect(_ x: Double, _ y: Double, id: String) -> Element {
        .rect(Rect(x: x, y: y, width: 10, height: 10, name: nil, id: id))
    }

    /// One layer, one rect, active.
    private static func oneLayerModel() -> Model {
        Model(document: Document(layers: [Layer(children: [rect(0, 0, id: "r-1")])],
                                 selectedLayer: 0, selection: []))
    }

    // MARK: - D4 — the wire, end to end through a real pasteboard

    /// D4, THE HEADLINE. Non-SVG text on the pasteboard becomes a Text element.
    /// Rust used to paste stale internal artwork here and discard the text; it
    /// now does this.
    @Test func plainTextOnThePasteboardBecomesATextElement() {
        let pb = Self.privatePasteboard()
        pb.clearContents()
        pb.setString("hello from another app", forType: .string)
        let model = Self.oneLayerModel()
        EditClipboard.pasteClipboard(model, offset: 24.0, pasteboard: pb)

        let kids = model.document.layers[0].children
        #expect(kids.count == 2, "expected the plain text to append one element, got \(kids.count)")
        guard kids.count == 2, case .text(let t) = kids[1] else {
            Issue.record("expected a Text element from a plain-text paste")
            return
        }
        #expect(t.content == "hello from another app")
        #expect(t.x == 24 && t.y == 40, "text landed at (\(t.x), \(t.y)), expected (24, 40)")
        #expect(model.document.selection == [ElementSelection.all([0, 1])],
                "the pasted text must be the selection")
    }

    /// Markup that is not SVG stays TEXT. HTML copied from a browser arrives
    /// looking like this; handing it to `svgToDocument` would yield an empty
    /// fragment and a paste that looks like it did nothing.
    @Test func markupThatIsNotSvgOnThePasteboardIsStillText() {
        let pb = Self.privatePasteboard()
        pb.clearContents()
        pb.setString("<b>not svg</b>", forType: .string)
        let model = Self.oneLayerModel()
        EditClipboard.pasteClipboard(model, offset: 24.0, pasteboard: pb)
        let kids = model.document.layers[0].children
        guard kids.count == 2, case .text(let t) = kids[1] else {
            Issue.record("expected a Text element, layer holds \(kids.count) children")
            return
        }
        #expect(t.content == "<b>not svg</b>")
    }

    /// D5, and it is the case the ruling turned around: an EMPTY pasteboard is a
    /// no-op. Rust used to append its internal buffer here.
    @Test func anEmptyPasteboardIsANoOp() {
        let pb = Self.privatePasteboard()
        pb.clearContents()
        let model = Self.oneLayerModel()
        EditClipboard.pasteClipboard(model, offset: 24.0, pasteboard: pb)
        #expect(model.document.layers[0].children.count == 1,
                "expected a no-op, but the layer holds \(model.document.layers[0].children.count) children")
    }

    /// The empty STRING is distinct from an unreadable pasteboard and must also
    /// no-op. Without this the guard could be narrowed to a nil check and no
    /// gate would see it.
    @Test func anEmptyStringOnThePasteboardIsANoOp() {
        let pb = Self.privatePasteboard()
        pb.clearContents()
        pb.setString("", forType: .string)
        let model = Self.oneLayerModel()
        EditClipboard.pasteClipboard(model, offset: 24.0, pasteboard: pb)
        #expect(model.document.layers[0].children.count == 1,
                "expected a no-op, but the layer holds \(model.document.layers[0].children.count) children")
    }

    /// NO REGRESSION on the wire: an SVG payload on the real pasteboard still
    /// reaches the shared R2 body and lands in the ACTIVE layer.
    @Test func anSvgPayloadOnThePasteboardStillPastesArtwork() {
        let pb = Self.privatePasteboard()
        pb.clearContents()
        pb.setString("<svg xmlns=\"http://www.w3.org/2000/svg\">"
                     + "<rect x=\"16\" y=\"16\" width=\"16\" height=\"16\" fill=\"rgb(0,0,255)\"/></svg>",
                     forType: .string)
        let model = Self.oneLayerModel()
        EditClipboard.pasteClipboard(model, offset: 24.0, pasteboard: pb)
        let kids = model.document.layers[0].children
        guard kids.count == 2, case .rect(let r) = kids[1] else {
            Issue.record("expected a Rect from an SVG paste, layer holds \(kids.count) children")
            return
        }
        // 16px -> 12pt, plus the 24pt offset. Tolerance is the SVG transport's
        // ~2.5e-5 quantization, derived not guessed.
        #expect(abs(r.x - 36) < 1e-3 && abs(r.y - 36) < 1e-3,
                "SVG rect landed at (\(r.x), \(r.y)), expected (36, 36)")
    }

    // MARK: - The Preservation Law on the text branch

    /// **THE PRESERVATION LAW, on the branch the corpus is blind to.** A paste
    /// does not speak to whether the target layer is locked, hidden or
    /// identified, so it must preserve all three. Swift's plain-text branch used
    /// to rebuild the target as `Layer(name:children:opacity:transform:)` — a
    /// hand-written four-field list against a twelve-field struct — so pasting
    /// text into a LOCKED layer UNLOCKED it, into a HIDDEN layer REVEALED it,
    /// and into an IDENTIFIED layer DESTROYED its identity. That is the Swift
    /// copy-site omission class (EDIT_SEMANTICS_FREEZE.md §3.1), the same defect
    /// LAYER_STRUCTURE.md §9.5 repaired on the SVG path and left standing here.
    /// It shipped on main.
    ///
    /// The repair is the shape that cannot drift again: there is no second body
    /// left, so the text branch inherits `pasteFragmentInto`'s in-place mutation.
    /// Twin of Rust `pasting_text_into_a_hidden_identified_layer_preserves_its_fields`.
    ///
    /// **`locked` LEFT THIS VECTOR ON 2026-07-28, and it is not a weakening.**
    /// The target used to carry `locked: true` as well. §15 rules that a locked
    /// ACTIVE layer refuses the paste outright, which preserves strictly more —
    /// the layer is not touched at all — and that refusal is gated
    /// cross-language by `paste_locked_layers.json`'s
    /// `paste_clipboard_text_into_a_locked_active_layer_refuses`, plus the
    /// end-to-end pasteboard probe below. Keeping `locked` here would have made
    /// the vector assert the repealed behaviour.
    @Test func pasteOfPlainTextPreservesTheTargetLayersOwnFields() {
        let pb = Self.privatePasteboard()
        pb.clearContents()
        pb.setString("a note", forType: .string)
        let target = Layer(name: "Sky", children: [Self.rect(5, 5, id: "r-sky")],
                           visibility: .invisible, id: "lyr-sky")
        let model = Model(document: Document(layers: [target], selectedLayer: 0, selection: []))
        EditClipboard.pasteClipboard(model, offset: 24.0, pasteboard: pb)

        let l = model.document.layers[0]
        #expect(l.children.count == 2, "the text element was not appended")
        #expect(!l.locked, "nothing here should have locked the layer")
        #expect(l.visibility == .invisible, "the paste silently REVEALED the target layer")
        #expect(l.id == "lyr-sky", "the paste DESTROYED the target layer's identity")
        #expect(l.name == "Sky", "the paste dropped the target layer's name")
        guard l.children.count == 2, case .text(let t) = l.children[1] else {
            Issue.record("expected a Text element at index 1")
            return
        }
        #expect(t.content == "a note")
        #expect(t.x == 24 && t.y == 40)
    }

    /// A LOCKED ACTIVE LAYER refuses a text paste — driven THROUGH THE REAL
    /// PASTEBOARD, which is the depth Rust cannot reach at all (see item 1
    /// above). The corpus pins the pure body; this pins the whole production
    /// wire, so nothing between the pasteboard read and the document write can
    /// route around the refusal.
    ///
    /// Not merely "no text appeared": the document must come back with the
    /// layer's own child count untouched, and `canUndo` must still be false —
    /// a refusal that cost an undo step would be a mutation with a different
    /// name.
    @Test func aLockedActiveLayerRefusesAPlainTextPasteThroughThePasteboard() {
        let pb = Self.privatePasteboard()
        pb.clearContents()
        pb.setString("a note", forType: .string)
        let target = Layer(name: "Sky", children: [Self.rect(5, 5, id: "r-sky")],
                           locked: true, id: "lyr-sky")
        let model = Model(document: Document(layers: [target], selectedLayer: 0, selection: []))
        EditClipboard.pasteClipboard(model, offset: 24.0, pasteboard: pb)

        let l = model.document.layers[0]
        #expect(l.children.count == 1, "a locked active layer must refuse a text paste")
        #expect(l.locked, "the refusal must leave the lock alone")
        #expect(model.document.selection.isEmpty, "a refused paste must not set a selection")
        #expect(!model.canUndo, "a refused paste must not cost an undo step")
    }

    // MARK: - Degenerate documents (pure body, no pasteboard)

    /// A LAYERLESS document has nowhere to put a Text element. The corpus is
    /// always seeded from an SVG, which always yields at least one layer, so
    /// only a hand-built document reaches this. `nil` means the caller opens no
    /// transaction — an impossible paste must not cost an undo step. Twin of
    /// Rust `pasting_text_into_a_layerless_document_returns_none`.
    @Test func pastingTextIntoALayerlessDocumentReturnsNil() {
        let doc = Document(layers: [], selectedLayer: 0, selection: [])
        #expect(pasteClipboardTextInto(doc, text: "hello", offset: 24.0, preserveLayers: false) == nil,
                "a layerless document has nowhere to paste text")
    }

    /// Hardening, matching `pasteFragmentInto`'s clamp: an out-of-range
    /// `selectedLayer` lands the text in the LAST layer rather than trapping on
    /// the index. Unreachable from the corpus. Twin of Rust
    /// `pasting_text_with_an_out_of_range_selected_layer_clamps`.
    @Test func pastingTextWithAnOutOfRangeSelectedLayerClamps() {
        let doc = Document(layers: [Layer(name: "Base", children: []),
                                    Layer(name: "Sky", children: [])],
                           selectedLayer: 99, selection: [])
        guard let out = pasteClipboardTextInto(doc, text: "x", offset: 0.0, preserveLayers: false) else {
            Issue.record("expected a paste")
            return
        }
        #expect(out.selection == [ElementSelection.all([1, 0])], "clamped to the last layer")
        guard case .text(let t) = out.layers[1].children[0] else {
            Issue.record("expected a Text element in the last layer")
            return
        }
        #expect(t.x == 0 && t.y == 16)
    }

    /// An UNREADABLE pasteboard (nil, not the empty string) is the other half of
    /// D5 and is a distinct input. Driven on the pure body because
    /// `NSPasteboard` cannot be made to fail on demand.
    @Test func anUnreadableClipboardIsANoOp() {
        let doc = Document(layers: [Layer(children: [Self.rect(0, 0, id: "r-1")])],
                           selectedLayer: 0, selection: [])
        #expect(pasteClipboardTextInto(doc, text: nil, offset: 24.0, preserveLayers: false) == nil,
                "an unreadable clipboard has nothing to paste")
    }
}
