(** The single op dispatcher — [op_apply] (OP_LOG.md section 4 / section 9,
    Increment 3b-B).

    Promoted, production-shared form of what was the harness-only fixture
    dispatcher. In 3b-B it is adopted from production for exactly three
    replay-safe verbs — [select_rect], [copy_selection], and [move_selection]
    — which are the ones [Live.capture_recipe] consumes. Those three populate
    [targets:[common.id]] (Fork 4); every other verb keeps [targets] empty and
    is reachable only from the cross-language harness (which shims through this
    module so harness and production share ONE dispatcher and ONE record-op
    site). The other production verbs, the AppState-level Layers-panel handlers,
    the per-frame drag coalescing, and the full verb unification are deferred
    per OP_LOG.md section 9. Mirrors [jas_dioxus] [document/op_apply.rs] and the
    Swift [OpApply.swift].

    Production input must never crash, so every param read is hardened: numbers
    resolve with a 0.0 default; a missing required field (a path, an id, a
    transform) skips the op rather than raising. The harness fixtures (which
    always carry well-formed params) replay byte-identically. *)

(** Apply one primitive op to [model] (via [ctrl]) and record it into the open
    transaction (the checkpoint_equivalence gate, OP_LOG.md section 5-6).

    History-navigation ops ([snapshot] / [undo] / [redo]) manage the
    transaction boundary / journal cursor and are NOT primitive ops, so they
    return WITHOUT being journaled.

    The drag-frame-hole fix (OP_LOG.md section 9): for every verb except
    [select_rect], a lazy [begin_txn] opens a transaction if none is open and
    leaves it OPEN, so the mutation lands in [record_op] and the batch owner
    ([Effects.run_effects]) names and commits the single transaction. OCaml
    [Model.set_document] does NOT self-bracket, so this lazy begin is the only
    safeguard against a bare drag frame losing its op — all three journaled-verb
    paths must flow through [op_apply], never a direct [Controller] call.

    [record_op] is a no-op when no transaction is open, so this is safe to call
    unconditionally. *)
val op_apply :
  Model.model -> Controller.controller -> Yojson.Safe.t -> unit
