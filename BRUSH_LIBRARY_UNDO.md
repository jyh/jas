# Undo for brush-library edits — the question, measured

Status: RECORDED 2026-09-26. **The question is the Captain's.** Arm A was first taken
here on the reading that keeping a promise needs no ruling. It was withdrawn within the
hour, when OP_LOG was read (§ "Why A is not the lane's" below): every arm amends a
decision he made. Until he rules, nothing changes, and the negative stays declared.

## The promise

`transcripts/BRUSHES.md`, "Undo semantics": New Brush, Duplicate Brush, Delete Brush,
Sort by Name and Brush Options → library edit → Apply each produce exactly one undoable
transaction. `workspace/actions.yaml` says "Undoable." on `duplicate_brush` and
`delete_brush`. The choice was deliberate: the same section weighs the Swatches
precedent (Delete Swatch is not undoable) and departs from it, because deleting a brush
changes how every element that references it renders.

## What is true today (measured at `2369502a`)

- **No port keeps it.** Every library edit (`brush.delete_selected`,
  `brush.duplicate_selected`, `brush.sort_by_name`) writes the STORE's
  `data.brush_libraries` and nothing else (`effects.rs` `run_brush_effect`; Swift's
  tool-table handlers; the reference's `effects.py`). A delete does not touch the
  document: an element keeps its `jas:stroke-brush` and draws as a plain stroke while
  the brush is missing.
- **An undo step holds only the document.** Rust's `Checkpoint` is
  `{doc, index, paste_run}` (`document/model.rs`), and Swift's is the same shape.
  Nothing in either records store data.
- **Libraries are app-global; undo stacks are per document.** Each tab owns a `Model`,
  and with it an undo stack (`TabState.model`); `data.brush_libraries` is one value for
  the whole app.
- **The reference has no undo model**, so no reference corpus can pin this. Equivalence
  is Rust ↔ Swift, through shared fixtures.

## The arms

- **A: keep the promise.** An undoable library edit pushes ONE checkpoint on the
  ACTIVE tab's stack that also carries the edited library's prior value; undo restores
  the document and that library together; redo re-applies both. A delete's undo
  therefore brings the brush back, and every element still naming it draws with it
  again, which is the recoverability the promise exists for.
  **Its limit, stated rather than hidden:** the snapshot is of one library at one
  moment. If another tab edits the same library afterwards, undoing the earlier edit
  in the first tab restores the older value over the later one. Undo is per document
  and the library is not, and no arm with per-document stacks avoids that.
- **B: an app-level undo stack for library data.** It needs a rule for which stack
  Cmd-Z consults, and that rule would be new product behaviour.
- **C: withdraw the promise.** Library edits are not undoable, as with Swatches. This
  is the simplest arm, and it reverses a choice the design made on purpose, so it is
  the Captain's to take, not the lane's.

## Why A is not the lane's

`OP_LOG.md` §2 records five locked decisions (2026-06-17). Row 1 makes the snapshot
undo stack and the transaction journal co-equal, kept honest by a mandatory
`replay == snapshot` gate. Row 5 says the journal records **document** ops only. And
`Model::commit_txn` drops the checkpoint of any transaction whose document is
byte-identical, so that undo steps and journal entries stay in lock step; `undo` moves
the journal cursor once per popped checkpoint.

A library-only edit changes no document, so under today's rules it can have no undo
step. Arm A needs one anyway. That means amending OP_LOG: a store-only transaction that
is journaled with no document ops and carries the library's prior value. This is a
change to a locked decision, not an implementation of the brush promise. Arm C, the
alternative, reverses the choice BRUSHES.md made on purpose. Arm B adds a second
history, which is a new product behaviour. **All three are his.**

**Recommendation: C.** Library data is app-global, and both structures that own undo
(per-tab stacks, and a journal of document ops) were built to exclude it. Withdrawing
the promise brings the spec into line with two ratified designs. Every other arm bends
one of them to fit a sentence. What C costs is named: a deleted brush is not recoverable
by Cmd-Z. The elements that used it keep their reference, so re-adding a brush of the
same slug restores their look.

**Default if no word comes:** nothing changes. The promise stays written, every port
stays as it is, and this record is the declared negative.

## A finding on the way: the web app's library edits do nothing

Measured 2026-09-26, two ways. **Decisive:** `brush.sort_by_name` with a LITERAL
library id, run through the web runner (`run_yaml_effects`) on an `AppState` whose
`brush_libraries` holds an unsorted library, leaves the library unchanged. The control
is the same effect on the same data through the shared runner (`effects::run_effects`
on a `StateStore`), which sorts it. The web runner hands only `doc.*` keys to the shared
runner, so `brush.*` is dropped whatever the scope. **Also:** the scope a web action
evaluates in (`build_appstate_ctx`) carries no `selected_library` or
`selected_brushes`, and the web `select` effect writes only `selected_swatches`, so a
Brushes tile click selects nothing either. Delete, Duplicate and Sort Brush are
therefore inert in the web app, while the engine (the WinUI shell) and Swift run them.
Undo for the web app waits on its library edits
working at all.

## What does not wait on the ruling

The web app's library edits were inert under every arm, so making them run was lane
work whatever he rules. **It landed the same day:** #256 hands the `brush.*` library
edits to the shared runner, and #257 gives a panel's actions that panel's scope and
routes a Brushes tile's `select` there too. Delete, Duplicate and Sort Brush now run in
the web app as they do in the engine and Swift. Undo for them is still this record's
open question.
