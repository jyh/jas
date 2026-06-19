import Foundation

/// The single op dispatcher — `opApply` (OP_LOG.md §4 / §9, Increment 3b-B).
///
/// STAGED-ASTERISK: this is the promoted, production-shared form of what was the
/// `#if DEBUG` `applyFixtureOp` dispatcher in the cross-language harness. It is
/// the §4 single-path end-state built in the increment that needs it. In 3b-B it
/// is adopted from production for **exactly three replay-safe verbs** —
/// `select_rect`, `copy_selection`, and `move_selection` — which are the ones
/// `captureRecipe` consumes. Those three populate `targets:[common.id]` (Fork 4);
/// EVERY OTHER verb here keeps `targets: []` and is reachable only from the
/// harness (which shims through this module so harness + production share ONE
/// dispatcher and ONE `recordOp` site). The other ~30 `doc.*` production verbs,
/// the AppState-level Layers-panel handlers (Duplicate / Duplicate Artboard),
/// the per-frame drag coalescing, and the full verb unification are explicitly
/// deferred per OP_LOG.md §9.
///
/// Production input must never crash, so every param read is hardened: numbers
/// resolve with a 0.0 default; a missing REQUIRED field (a path, an id, a
/// transform) returns/skips rather than force-unwrapping. The harness fixtures
/// (which always carry well-formed params) replay byte-identically.
///
/// CRITICAL (Swift): `Model.document` is the mutation chokepoint, but it does
/// NOT self-bracket a transaction the way Rust's `edit_document` does. The lazy
/// `beginTxn` here (excluding `select_rect`) is therefore the ONLY safeguard
/// against the subsequent-drag-frame journaling hole — a bare drag frame (no
/// preceding `doc.snapshot`) still opens and records into a transaction, which
/// the batch owner (`runEffects`) names and commits. So ALL THREE journaled-verb
/// paths MUST flow through `opApply`, never a direct `Controller` call.
///
/// Mirrors `jas_dioxus`'s `document/op_apply.rs`.

/// Parse a JSON array of indices into an `ElementPath`. Returns nil if the field
/// is absent or not an array of integers (a malformed production payload skips
/// the op rather than crashing).
private func parsePath(_ v: Any?) -> ElementPath? {
    guard let arr = v as? [Any] else { return nil }
    return arr.map { ($0 as? NSNumber)?.intValue ?? 0 }
}

/// Read a string field, or nil if absent / not a string.
private func strField(_ op: [String: Any], _ key: String) -> String? {
    op[key] as? String
}

/// Read an f64 field, defaulting to 0.0 (the non-crashing number form).
private func numField(_ op: [String: Any], _ key: String) -> Double {
    (op[key] as? NSNumber)?.doubleValue ?? 0.0
}

/// The single op dispatcher (OP_LOG.md §4). Applies one primitive op to the
/// model (via `controller`) and records it into the open transaction (the
/// `checkpoint_equivalence` gate, §5-6). History-navigation ops
/// (`snapshot`/`undo`/`redo`) manage the transaction boundary / journal cursor
/// and are NOT primitive ops, so they return WITHOUT being journaled. `recordOp`
/// is a no-op when no transaction is open, so this is safe to call
/// unconditionally. Mirrors Rust `op_apply`.
public func opApply(_ model: Model, _ controller: Controller, _ op: [String: Any]) {
    guard let name = op["op"] as? String else {
        // A primitive op with no verb is malformed; skip it (never crash).
        return
    }
    // History-navigation ops (OP_LOG.md §5): they manage transaction boundaries
    // / the journal cursor and are NOT primitive ops, so they are never
    // journaled. `snapshot` commits the prior action's transaction and opens a
    // new one; undo/redo end the open context and move the cursor.
    switch name {
    case "snapshot":
        model.commitTxn()
        model.beginTxn()
        return
    case "undo":
        model.undo()
        return
    case "redo":
        model.redo()
        return
    default:
        break
    }
    // OP_LOG.md §9 (Increment 3b-B) — close the subsequent-drag-frame journaling
    // hole. Every verb below except `select_rect` is an UNDOABLE mutation. On a
    // bare drag frame (selection.yaml emits `doc.snapshot` only on the FIRST
    // mousemove), no transaction is open, so `recordOp` would drop the op and
    // the batch owner's `nameTxn`/`commitTxn` would have nothing to commit.
    // Opening the transaction HERE — and leaving it OPEN — makes the mutation
    // land in `recordOp` and the batch owner (`runEffects`) names + commits the
    // single transaction. `beginTxn` is a no-op while one is already open, so
    // the harness (which always brackets around `opApply`) and the snapshot-led
    // first frame are byte-unchanged. `select_rect` is EXCLUDED: it only changes
    // selection (non-undoable, serialized state), so a bare marquee must stay
    // journal-neutral — opening a txn for it would spuriously journal a
    // selection-only batch as an undoable step.
    if name != "select_rect" && !model.isInTxn {
        model.beginTxn()
    }
    // Fork-4 `targets` (OP_LOG.md §9). Populated for the THREE replay-safe verbs
    // `captureRecipe` consumes; every other verb keeps it empty.
    // `move_selection`/`copy_selection` resolve the source ids BEFORE the
    // mutation (a copy is born id-less; a move can change which ids are
    // selected — pre-mutation avoids the post-mutation-id hazard). `select_rect`
    // resolves AFTER its Controller call (the selection it just established IS
    // the keystone targets).
    var targets: [String] = []
    if name == "move_selection" || name == "copy_selection" {
        targets = selectionToIds(model.document)
    }
    switch name {
    case "select_rect":
        controller.selectRect(
            x: numField(op, "x"),
            y: numField(op, "y"),
            width: numField(op, "width"),
            height: numField(op, "height"),
            extend: (op["extend"] as? NSNumber)?.isBool == true
                ? (op["extend"] as! NSNumber).boolValue
                : (op["extend"] as? Bool ?? false))
        // Keystone: the resolved selection is this op's targets, so
        // captureRecipe can seed its working set (empty targets ⇒ empty
        // recipe). Resolved AFTER the Controller call.
        targets = selectionToIds(model.document)
    case "move_selection":
        controller.moveSelection(dx: numField(op, "dx"), dy: numField(op, "dy"))
    case "copy_selection":
        controller.copySelection(dx: numField(op, "dx"), dy: numField(op, "dy"))
    case "assign_id":
        guard let path = parsePath(op["path"]), let id = strField(op, "id") else { return }
        controller.assignId(path, id: id)
    case "create_reference":
        guard let targetPath = parsePath(op["target_path"]),
              let targetId = strField(op, "target_id"),
              let refId = strField(op, "ref_id") else { return }
        controller.createReference(targetPath, targetId: targetId, refId: refId)
    // Symbols P2 operations (SYMBOLS.md §7). Value-in-op: the ids and paths are
    // read literally from the payload, exactly like the create_reference arm.
    case "make_symbol":
        guard let path = parsePath(op["path"]),
              let masterId = strField(op, "master_id"),
              let refId = strField(op, "ref_id") else { return }
        controller.makeSymbol(path, masterId: masterId, refId: refId)
    case "place_instance":
        guard let masterId = strField(op, "master_id"),
              let refId = strField(op, "ref_id") else { return }
        controller.placeInstance(masterId: masterId, refId: refId)
    case "detach":
        guard let path = parsePath(op["path"]) else { return }
        controller.detach(path)
    case "redefine":
        guard let masterId = strField(op, "master_id"),
              let path = parsePath(op["path"]),
              let refId = strField(op, "ref_id") else { return }
        controller.redefine(masterId: masterId, path, refId: refId)
    case "delete_symbol":
        guard let masterId = strField(op, "master_id") else { return }
        controller.deleteSymbol(masterId: masterId)
    // Symbols P4 (SYMBOLS.md §4 / Fork F2). Value-in-op: the instance transform
    // is carried in the payload as {a,b,c,d,e,f} and applied verbatim.
    case "set_instance_transform":
        guard let path = parsePath(op["path"]),
              let t = op["transform"] as? [String: Any] else { return }
        let transform = Transform(
            a: numField(t, "a"), b: numField(t, "b"), c: numField(t, "c"),
            d: numField(t, "d"), e: numField(t, "e"), f: numField(t, "f"))
        controller.setInstanceTransform(path, transform: transform)
    case "delete_selection":
        model.document = model.document.deleteSelection()
    case "lock_selection":
        controller.lockSelection()
    case "unlock_all":
        controller.unlockAll()
    case "hide_selection":
        controller.hideSelection()
    case "show_all":
        controller.showAll()
    // Boolean ops (OP_LOG.md §9): the destructive boolean combines the ≥2
    // selected sibling paths; `simplify` refits the (now-selected) output. Both
    // join the open transaction so the pair is one journaled Transaction.
    case "boolean_union":
        controller.applyDestructiveBoolean("union")
    case "simplify":
        controller.simplifySelection(precision: (op["precision"] as? NSNumber)?.doubleValue ?? 0.5)
    // Unknown verb: a malformed/unsupported production payload is skipped rather
    // than crashing. (The harness corpus only carries known verbs, so this never
    // fires under test — the byte-gate would catch a typo.)
    default:
        return
    }
    // Capture the op into the open transaction so the journal replays to the same
    // document — the checkpoint_equivalence gate (OP_LOG.md §5-6). `targets`
    // (Fork 4) is populated above for the three replay-safe verbs; empty for
    // every other verb. recordOp is a no-op when no transaction is open. `params`
    // carries the full op dict verbatim (verb included), matching the harness
    // recordOp site; the journal serializer strips the redundant "op" key.
    model.recordOp(PrimitiveOp(op: name, params: op, targets: targets))
}
