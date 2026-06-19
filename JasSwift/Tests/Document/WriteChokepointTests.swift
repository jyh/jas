import Testing
@testable import JasLib

/// OP_LOG.md Increment 1 — the enforced write chokepoint. Mirrors the Rust
/// `set_document_outside_txn_panics` test (jas_dioxus `model.rs`) plus the
/// Python `WriteChokepointTest` / OCaml `write_chokepoint` group: the three-way
/// split where `setDocument` asserts a transaction is open, `editDocument`
/// self-brackets, and `setDocumentUnbracketed` never asserts.
///
/// The live `assert(isInTxn)` in `setDocument` is the ORACLE: any undoable
/// write that skipped the transaction bracket fails the suite, so the journal is
/// complete by construction. Swift `assert` is active in the default (debug)
/// test build and stripped under `-Ounchecked`, so it costs nothing in release.
///
/// The whole group lives in a `.serialized` suite. The oracle is a Swift
/// Testing exit test, and the exit-test harness captures the subprocess
/// exit status over a pipe; under heavy *parallel* load that capture can race
/// and misread a genuine abort as a clean exit (observed ~1/45 full-suite runs
/// as `.failure -> .exitCode(0)`). The race is purely in the harness's
/// exit-status plumbing — in isolation the assert fires 100% — so we keep the
/// load-bearing assert oracle exactly as-is and instead stop the exit test from
/// racing against its siblings by serializing the suite. See OP_LOG.md
/// Increment 1.

@Suite(.serialized)
struct WriteChokepointTests {

    // MARK: - The assert oracle (set_document_outside_txn_panics equivalent)

    /// An undoable write outside a transaction must trip the `assert(isInTxn)`
    /// in `setDocument`. Swift Testing's exit test runs the body in a fresh
    /// subprocess and observes the abort the failed `assert` raises — the direct
    /// analogue of Rust's `#[should_panic]` and Python's
    /// `assertRaises(AssertionError)`.
    @Test func setDocumentOutsideTxnAborts() async {
        await #expect(processExitsWith: .failure) {
            let model = Model()
            model.setDocument(Document(layers: []))  // no beginTxn -> assert fires
        }
    }

    // MARK: - The three-way split behaviors

    @Test func setDocumentInsideTxnSucceeds() {
        let model = Model()
        model.beginTxn()
        model.setDocument(Document(layers: []))  // legal: isInTxn is open
        model.commitTxn()
        #expect(model.document.layers.count == 0)
    }

    @Test func setDocumentUnbracketedNeverAsserts() {
        // Sanctioned non-undoable write: legal with no open transaction, and it
        // does NOT advance the journal cursor (no undo step) — the property that
        // lets the live guard tell "deliberately not undoable" from "forgot a
        // transaction".
        let model = Model()
        let head = model.journalHeadValue
        model.setDocumentUnbracketed(Document(layers: []))
        #expect(model.document.layers.count == 0)
        #expect(model.journalHeadValue == head)
        #expect(!model.canUndo)
    }

    @Test func editDocumentSelfBracketsWhenNoTxnOpen() {
        // Standalone editDocument opens + commits its own one-step transaction.
        let model = Model()
        model.editDocument(Document(layers: []))
        #expect(model.journal.count == 1)
        #expect(model.journalHeadValue == 1)
        #expect(model.canUndo)
        model.undo()
        #expect(model.document.layers.count == 1, "one undo step reverts the edit")
    }

    @Test func editDocumentJoinsAnOpenTxn() {
        // Inside an open transaction, editDocument writes WITHOUT
        // opening/committing its own — it joins the caller's transaction (one
        // undo step for the whole bracket), mirroring Rust/Python edit_document.
        let model = Model()
        model.beginTxn()
        model.editDocument(Document(layers: []))
        model.editDocument(Document(layers: [Layer(name: "L", children: [])]))
        model.commitTxn()
        #expect(model.journal.count == 1, "the two joined writes commit as one txn")
        model.undo()
        #expect(model.document.layers.count == 1,
            "one undo step reverts the whole joined session")
    }
}
