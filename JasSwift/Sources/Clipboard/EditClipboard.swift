import AppKit

/// Clipboard-backed Edit verbs (Cut / Copy / Paste), shared by the main-menu
/// commands (``JasCommands``) and the canvas right-click context menu so both
/// dispatch ONE implementation — the same single-source-of-truth pattern as
/// ``MenuActions``. Unlike ``MenuActions`` (model-pure, driven by the headless
/// cross-language ACTION corpus), these touch ``NSPasteboard``, so they live in
/// the AppKit / clipboard layer rather than the model-pure menu layer.
///
/// The pasteboard is injectable so round-trip tests use a private pasteboard
/// instead of clobbering the system one (mirrors ``RichClipboardTests``). The
/// bodies moved verbatim out of ``JasCommands`` — no behavior change.
/// `public` so the `AlgorithmRoundtrip` tool target can drive
/// ``translateElement(_:dx:dy:)`` — the `paste_translate` conformance family is
/// the only thing that watches the offset `workspace/actions.yaml` §paste
/// specifies, and it must call the function the PASTE PATH calls rather than
/// the tidiest one available.
public enum EditClipboard {
    /// Serialize the current selection to SVG on the pasteboard. Clipboard-only:
    /// no document write, no undo step. No-op on an empty selection.
    static func copySelection(_ model: Model, pasteboard: NSPasteboard = .general) {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        var elements: [Element] = []
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            elements.append(elem)
        }
        guard !elements.isEmpty else { return }
        let tempDoc = Document(layers: [Layer(children: elements)])
        let svg = documentToSvg(tempDoc)
        pasteboard.clearContents()
        pasteboard.setString(svg, forType: .string)
    }

    /// Paste pasteboard contents into the document, translated by `offset` in
    /// both axes, selecting the pasted elements. Undoable — `editDocument`
    /// self-brackets one undo step. No-op on empty pasteboard text.
    ///
    /// `preserveLayers` selects R3 ("Paste, preserving layers") over R2 (plain
    /// Paste); the whole layer-targeting decision lives in
    /// ``pasteFragmentInto(_:fragment:offset:preserveLayers:)``. It is a
    /// PARAMETER with a `false` default, not a stored preference: R3 is an
    /// explicit command, and a persistent mode that silently changed what Cmd+V
    /// does would be the very defect R2 rejects.
    ///
    /// **R2 landed here as a DELETION.** This function used to merge an SVG
    /// payload's layers into document layers OF THE SAME NAME, falling back to
    /// the active layer — so where artwork landed depended on an invisible
    /// property of where it came from, and renaming a layer changed where paste
    /// landed. That branch is not deleted from the codebase, it is MOVED: it is
    /// what `preserveLayers == true` now does, plus the layer creation it always
    /// lacked. Rust's flatten is the default in both ports.
    ///
    /// **D4/D5 landed here as a LIFT, not a change of answer** (ratified
    /// 2026-07-28; Swift is canon). This function used to hold the payload
    /// dispatch itself — test for SVG, else build a Text element — where no
    /// fixture could reach it, so Rust was free to answer differently and did:
    /// it skipped the SVG branch on plain text and pasted `TabState.clipboard`,
    /// STALE INTERNAL ARTWORK the artist had not copied. The dispatch now lives
    /// in ``pasteClipboardTextInto(_:text:offset:preserveLayers:)``, which both
    /// ports call and the shared corpus family `paste_clipboard_text.json`
    /// drives. Swift's ANSWERS are unchanged; what changed is that they are now
    /// the only answers.
    ///
    /// One defect did change: the plain-text branch rebuilt the target layer
    /// from a four-field list and silently dropped its `locked`, `visibility`,
    /// `id`, `blendMode`, `mask`, `isolatedBlending` and `knockoutGroup`. See
    /// ``pasteClipboardTextInto(_:text:offset:preserveLayers:)``'s text helper.
    ///
    /// THIN CALLER, deliberately: everything below the pasteboard read is one
    /// call. The pasteboard is injectable, so `ClipboardTextPasteTests` drives
    /// this whole path end to end — Rust's equivalent read is still inside a
    /// `spawn_local` closure and is NOT reachable from `cargo test --lib`.
    static func pasteClipboard(_ model: Model, offset: Double,
                               pasteboard: NSPasteboard = .general,
                               preserveLayers: Bool = false) {
        // The payload is handed over EXACTLY as read — nil for an unreadable
        // pasteboard, "" for an empty one. Both are no-ops, decided in one place
        // rather than by a guard here and a branch there.
        applyPasteClipboardText(model, text: pasteboard.string(forType: .string),
                                offset: offset, preserveLayers: preserveLayers)
    }

    /// R3 — "Paste, preserving layers": the SEPARATE, EXPLICIT command.
    ///
    /// Same 24pt offset as plain Paste; it differs in layer TARGETING only. A
    /// fragment layer whose name matches a document layer appends into that
    /// layer; a name with no match CREATES the layer. See
    /// ``pasteFragmentInto(_:fragment:offset:preserveLayers:)`` for the three
    /// conservative sub-decisions and what remains open.
    ///
    /// A thin alias rather than a second implementation, so R2 and R3 can never
    /// drift apart: the corpus pins both over the same fragment
    /// (`paste_one_name_match_still_flattens_into_active` vs
    /// `paste_preserving_one_name_match_appends_and_creates`), and there is only
    /// one body for that pair to disagree about.
    ///
    /// NOTE, and it is the honest limit of this command: an IN-APP copy emits
    /// ONE UNNAMED layer (``copySelection`` builds `Document(layers: [Layer(children:)])`),
    /// so there is no name to preserve and this behaves exactly like plain
    /// Paste. R3 bites on FOREIGN fragments — externally-sourced SVG that names
    /// its layers — which is the case the ruling was written for. Making it bite
    /// on in-app copies means changing what COPY emits, which is a separate
    /// ruling (LAYER_STRUCTURE.md §8.0: the flattening is settled at copy).
    static func pasteClipboardPreservingLayers(_ model: Model, offset: Double,
                                               pasteboard: NSPasteboard = .general) {
        pasteClipboard(model, offset: offset, pasteboard: pasteboard, preserveLayers: true)
    }

    /// Cut = reference-aware confirm, then copy to the clipboard, then delete
    /// the selection as ONE named undo step via the shared `opApply` dispatcher.
    /// `confirmOrphaning` is injected so the caller supplies its own UI (the
    /// menu / canvas pass ``JasCommands.confirmOrphaningCut``'s NSAlert; headless
    /// tests pass a stub). Returns WITHOUT touching the clipboard if the user
    /// cancels an orphaning cut. No-op on an empty selection.
    static func cutSelection(_ model: Model, pasteboard: NSPasteboard = .general,
                             confirmOrphaning: (Int) -> Bool) {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        // Reference-aware cut (warn-then-orphan): cut = copy + delete, so it can
        // orphan live instances exactly like Delete. Same pinned predicate;
        // empty orphan set -> cut as today (no dialog). Confirm before touching
        // the clipboard so Cancel leaves it unchanged.
        let orphaned = DependencyIndex.orphanedReferences(doc, doc.selection.map(\.path))
        if !orphaned.isEmpty && !confirmOrphaning(orphaned.count) {
            return
        }
        copySelection(model, pasteboard: pasteboard)  // clipboard only — no document write
        // OP_LOG.md §9 Phase P4 — route the delete-half of the cut through the
        // SHARED `opApply` dispatcher so it JOURNALS a real `delete_selection`
        // op (one named undo step). The clipboard copy is a non-document side
        // effect (no op). Mirrors Rust's cut_orphan_confirm_ok.
        model.withTxn {
            model.nameTxn("cut_orphan_confirm_ok")
            opApply(model, Controller(model: model), ["op": "delete_selection"])
        }
    }

    // MARK: - Helpers (moved verbatim from JasCommands)

    /// Translate one pasted element by the paste offset.
    ///
    /// `workspace/actions.yaml` §paste specifies "offset 24 points down and to
    /// the right from the original position", against `paste_in_place`'s
    /// explicit "no offset" — so the zero case must be a no-op and the non-zero
    /// case must MOVE. This body used to be its own recursive walk and got both
    /// halves of that wrong for two kinds:
    ///
    /// 1. a live COMPOUND SHAPE fell through to `moveControlPoints(.all, …)`,
    ///    whose only live arm is `.reference`, so it came back UNMOVED — the
    ///    pasted compound landed exactly on top of its source, invisible, which
    ///    is the one outcome the offset exists to prevent. Rust's
    ///    `translate_element` bakes the offset into the operands, so this was a
    ///    live prime-directive divergence.
    /// 2. the `.group` arm rebuilt `Group(children:opacity:transform:locked:)`
    ///    field by field and therefore dropped `name`, `id`, `visibility`,
    ///    `blendMode`, `mask`, `isolatedBlending` and `knockoutGroup` — the
    ///    Swift copy-site omission class (EDIT_SEMANTICS_FREEZE.md §3.1),
    ///    landing at a paste. Pasting a NAMED group produced an unnamed one.
    ///
    /// Both are gone because there is nothing left here to get wrong:
    /// ``Element/translated(dx:dy:)`` is already the field-preserving,
    /// clone-then-mutate mirror of Rust's `translate_element`, compound arm
    /// included, and it was already correct while this helper was not. The
    /// duplicate is deleted rather than repaired, which is the only version of
    /// the fix that cannot drift again.
    ///
    /// Kept as a named function (rather than inlining the call at the paste
    /// site) because the `paste_translate` conformance family drives THIS
    /// symbol: a gate pointed at `Element.translated` would have been a decoy.
    public static func translateElement(_ elem: Element, dx: Double, dy: Double) -> Element {
        if dx == 0 && dy == 0 { return elem }
        return elem.translated(dx: dx, dy: dy)
    }

    // `isSvg` moved to `clipboardTextIsSvg` in OpApply.swift with the rest of
    // the payload dispatch (D4/D5) — a predicate that decides what a paste DOES
    // belongs with the body that acts on it, and the shared corpus can only see
    // it there.
}
