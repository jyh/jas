import AppKit
import Testing
import Foundation
@testable import JasLib

/// THE PASTE STACK — `workspace/actions.yaml` paste, "Repeated pastes stack
/// with cumulative offsets".
///
/// The primary gate is the cross-language corpus family
/// `test_fixtures/operations/paste_stacking.json`, driven by
/// `operationPasteStacking` in both ports over one set of goldens. This suite
/// carries only what that lane structurally cannot reach, and each probe says
/// which:
///
/// 1. **UNDO AND REDO.** The operations runner applies a vector's `history`
///    AFTER every transaction, so no fixture can paste after an undo; an undo op
///    embedded in a transaction would desync the `checkpoint_equivalence` gate,
///    which replays `journal[0..head]` and never replays history navigation. The
///    rule that undo restores the run is pinned HERE and by the Rust twin
///    (`op_apply::paste_stacking_tests`) over identical vectors — twin per-port
///    probes, not a shared gate. Stated plainly because it is the one decision
///    in this wave that no cross-language byte watches.
/// 2. **THE PER-DOCUMENT LIFETIME.** A fixture builds one `Model`; two open
///    documents cannot be expressed.
/// 3. **THE ABORTED TRANSACTION.** No op sequence aborts.
/// 4. **THE WIRE**, which Swift alone can drive: `pasteThroughARealPasteboard`
///    runs the whole production path — `EditClipboard.pasteClipboard`, a real
///    (private) `NSPasteboard`, the dispatch, the document write. Rust's
///    equivalent read still sits in a `spawn_local` closure over an
///    `Rc<RefCell<AppState>>` and a Dioxus `Signal` and is unreachable from
///    `cargo test --lib`, so the two ports are watched to DIFFERENT depths here
///    and only the shallower depth is common.
@Suite struct PasteStackingTests {

    private static func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(rawValue: "jas.tests.pastestack.\(UUID().uuidString)"))
    }

    /// A one-layer document with nothing in it: every x below is therefore the
    /// paste offset itself, with no source coordinate to subtract.
    private static func emptyModel() -> Model {
        Model(document: Document(layers: [Layer(children: [])],
                                 selectedLayer: 0, selection: []))
    }

    /// A clipboard payload holding one rect at the origin. `a` and `b` differ,
    /// so they are different payloads for the reset rule. Mirrors the Rust
    /// twin's `A` / `B`.
    private static let a = """
        <svg xmlns="http://www.w3.org/2000/svg">\
        <rect x="0" y="0" width="10" height="10" fill="rgb(0,0,255)" stroke="none"/></svg>
        """
    private static let b = """
        <svg xmlns="http://www.w3.org/2000/svg">\
        <rect x="0" y="0" width="20" height="20" fill="rgb(0,128,0)" stroke="none"/></svg>
        """

    /// Tolerance shared with the other clipboard suites: the SVG codec's px→pt
    /// conversion makes exact equality on a round-tripped coordinate brittle,
    /// while 1e-6 still separates "did not move" from a real 24pt step by four
    /// orders of magnitude.
    private static let tol = 1e-6

    /// x-coordinates of the active layer's children, in order — the whole
    /// observable of a paste run.
    private static func xs(_ model: Model) -> [Double] {
        model.document.layers[0].children.map { child -> Double in
            if case .rect(let r) = child { return r.x }
            return Double.nan
        }
    }

    private static func expectXs(_ model: Model, _ want: [Double], _ why: String) {
        let got = xs(model)
        #expect(got.count == want.count, "\(why): expected \(want.count) children, got \(got)")
        guard got.count == want.count else { return }
        for (i, w) in want.enumerated() {
            #expect(abs(got[i] - w) < tol, "\(why): child \(i) at x=\(got[i]), expected \(w)")
        }
    }

    @discardableResult
    private static func paste(_ model: Model, _ payload: String) -> Bool {
        applyPasteClipboardText(model, text: payload, offset: 24.0, preserveLayers: false)
    }

    // MARK: - The requirement, at the production entry point

    /// The headline requirement, driven through `applyPasteClipboardText` — the
    /// entry point `EditClipboard.pasteClipboard` calls — rather than through
    /// the corpus. Duplicated on purpose: if this suite's helpers are wrong,
    /// every other probe here is measuring the wrong thing, and this is the one
    /// that says so.
    @Test func threePastesOfOnePayloadStackCumulatively() {
        let m = Self.emptyModel()
        for _ in 0..<3 { Self.paste(m, Self.a) }
        Self.expectXs(m, [24, 48, 72], "three pastes of one payload")
    }

    /// THE WIRE, end to end: copy a real selection to a real (private)
    /// pasteboard, then paste twice through `EditClipboard.pasteClipboard`. The
    /// only probe in either port that watches the stack across the actual
    /// clipboard read.
    @Test func pasteThroughARealPasteboardStacks() {
        let pb = Self.privatePasteboard()
        let doc0 = Document(
            layers: [Layer(children: [.rect(Rect(x: 0, y: 0, width: 10, height: 10,
                                                 name: nil, id: "r-1"))])],
            selectedLayer: 0, selection: [ElementSelection.all([0, 0])])
        let model = Model(document: doc0)
        EditClipboard.copySelection(model, pasteboard: pb)
        EditClipboard.pasteClipboard(model, offset: 24.0, pasteboard: pb)
        EditClipboard.pasteClipboard(model, offset: 24.0, pasteboard: pb)
        Self.expectXs(model, [0, 24, 48], "source + two pastes through a real pasteboard")
    }

    // MARK: - What the corpus cannot reach

    /// UNDO RESTORES THE RUN. `beginTxn` (inside `editDocument`) captures the
    /// PRE-paste run and the advance happens after the write, so undoing the
    /// second paste puts the next one exactly where the undone one was: 48, not
    /// 72. Anything else leaves a HOLE in the run — a slot the artist can see is
    /// empty and cannot fill by pasting.
    ///
    /// This is the concrete reason the run is NOT app state. A counter that
    /// outlives the artwork it counts has the same defect the lock save-state
    /// table was ruled a design flaw for, on the same day.
    @Test func undoRestoresTheRunSoTheNextPasteFillsTheVacatedSlot() {
        let m = Self.emptyModel()
        Self.paste(m, Self.a)
        Self.paste(m, Self.a)
        Self.expectXs(m, [24, 48], "two pastes")
        m.undo()
        Self.expectXs(m, [24], "undo removed the second paste")
        Self.paste(m, Self.a)
        Self.expectXs(m, [24, 48],
                      "the paste after an undo must REPLACE the undone one at 48, "
                      + "not skip to 72 and leave 48 empty")
    }

    /// REDO is undo's mirror: it restores the run as it stood after the redone
    /// transaction, so a further paste continues at 72 rather than re-landing on
    /// 48.
    @Test func redoRestoresTheRunItHadAdvanced() {
        let m = Self.emptyModel()
        Self.paste(m, Self.a)
        Self.paste(m, Self.a)
        m.undo()
        m.redo()
        Self.expectXs(m, [24, 48], "redo put the second paste back")
        Self.paste(m, Self.a)
        Self.expectXs(m, [24, 48, 72], "the run continued past the redo")
    }

    /// An ABORTED transaction rolls the run back with the document it rolled
    /// back: the paste inside it never happened, so the next paste is still the
    /// second of the run.
    @Test func anAbortedTransactionRollsTheRunBack() {
        let m = Self.emptyModel()
        Self.paste(m, Self.a)
        m.beginTxn()
        applyPasteClipboardText(m, text: Self.a, offset: 24.0, preserveLayers: false)
        m.abortTxn()
        Self.expectXs(m, [24], "abort removed the second paste")
        Self.paste(m, Self.a)
        Self.expectXs(m, [24, 48], "still the second of the run")
    }

    /// THE RUN IS PER-DOCUMENT. Pasting the same clipboard into a second open
    /// document starts at 24 there rather than continuing the first document's
    /// run — which falls out of living on the `Model`, one per tab, and is the
    /// reason it does not live in app state.
    @Test func theRunIsPerDocument() {
        let a = Self.emptyModel()
        let b = Self.emptyModel()
        Self.paste(a, Self.a)
        Self.paste(a, Self.a)
        Self.expectXs(a, [24, 48], "the first document's run")
        Self.paste(b, Self.a)
        Self.expectXs(b, [24], "a second document starts its own run")
    }

    /// The run is a SINGLE SLOT, and this is the corner that buys: a paste of B
    /// between two pastes of A loses A's count, so the third paste lands back on
    /// the first. BANKED, NOT RULED — the same limitation a fragment-keyed run
    /// would have, pinned here so the day a multi-slot run is ruled the byte
    /// moves. Twin of Rust `an_intervening_payload_loses_the_first_runs_count`.
    @Test func anInterveningPayloadLosesTheFirstRunsCount() {
        let m = Self.emptyModel()
        Self.paste(m, Self.a)
        Self.paste(m, Self.b)
        Self.paste(m, Self.a)
        Self.expectXs(m, [24, 24, 24], "single-slot run: A's count did not survive B")
    }
}
