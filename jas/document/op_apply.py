"""The single op dispatcher — ``op_apply`` (OP_LOG.md §4 / §9, Increment 3b-B).

STAGED-ASTERISK: this is the promoted, production-shared form of what was the
``cross_language_test._apply_op`` dispatcher. It is the §4 single-path end-state
built in the increment that needs it. In 3b-B it is adopted from production for
**exactly three replay-safe verbs** — ``select_rect``, ``copy_selection``, and
``move_selection`` — which are the ones ``capture_recipe`` consumes. Those three
populate ``targets:[common.id]`` (Fork 4); EVERY OTHER verb here keeps
``targets`` empty and is reachable only from the cross-language harness (which
shims through this module so harness + production share ONE dispatcher and ONE
``record_op`` site). The other ~30 ``doc.*`` production verbs, the AppState-level
duplicate handlers, the per-frame drag coalescing, and the full 33-verb
unification are explicitly deferred per OP_LOG.md §9.

Production input must never raise, so every param read is hardened: numbers
resolve via ``num_field`` (default 0.0); a missing REQUIRED field (a path, an id,
a transform) early-returns/skips rather than indexing. The harness fixtures
(which always carry well-formed params) replay byte-identically. Mirrors the
Rust ``jas_dioxus/src/document/op_apply.rs``.
"""

from __future__ import annotations

from typing import Any

from document.controller import Controller, selection_to_ids
from document.model import Model
from document.op_log import PrimitiveOp


def parse_path(v: Any) -> tuple[int, ...] | None:
    """Parse a JSON array of indices into an element path. Returns ``None`` if
    the field is absent or not an array of integers (a malformed production
    payload skips the op rather than raising)."""
    if not isinstance(v, list):
        return None
    out: list[int] = []
    for i in v:
        if isinstance(i, bool) or not isinstance(i, (int, float)):
            return None
        out.append(int(i))
    return tuple(out)


def str_field(op: dict, key: str) -> str | None:
    """Read a string field, or ``None`` if absent / not a string."""
    v = op.get(key)
    return v if isinstance(v, str) else None


def num_field(op: dict, key: str) -> float:
    """Read an f64 field, defaulting to 0.0 (the non-raising number form)."""
    v = op.get(key)
    if isinstance(v, bool):
        return float(v)
    if isinstance(v, (int, float)):
        return float(v)
    return 0.0


def bool_field(op: dict, key: str) -> bool:
    """Read a bool field, defaulting to False (the non-raising bool form)."""
    v = op.get(key)
    return v if isinstance(v, bool) else False


def op_apply(model: Model, op: dict) -> None:
    """The single op dispatcher (OP_LOG.md §4). Applies one primitive op to the
    model and records it into the open transaction (the ``checkpoint_equivalence``
    gate, §5-6). History-navigation ops (``snapshot``/``undo``/``redo``) manage
    the transaction boundary / journal cursor and are NOT primitive ops, so they
    early-return WITHOUT being journaled. ``record_op`` is a no-op when no
    transaction is open, so this is safe to call unconditionally.
    """
    if not isinstance(op, dict):
        return
    name = op.get("op")
    if not isinstance(name, str):
        # A primitive op with no verb is malformed; skip it (never raise).
        return

    # History-navigation ops (OP_LOG.md §5): they manage transaction boundaries
    # / the journal cursor and are NOT primitive ops, so they are never
    # journaled. ``snapshot`` commits the prior action's transaction (relocated
    # redo-clear) and opens a new one, so the mutator ops that follow JOIN one
    # checkpoint; undo/redo end the open context and move the cursor.
    if name == "snapshot":
        model.commit_txn()
        model.begin_txn()
        return
    if name == "undo":
        model.undo()
        return
    if name == "redo":
        model.redo()
        return

    # OP_LOG.md §9 (Increment 3b-B) — close the subsequent-drag-frame journaling
    # hole. Every verb below except ``select_rect`` is an UNDOABLE mutation; in
    # this app the Controller methods mutate via ``replace()`` with NO txn
    # bracket and never self-bracket. On a bare drag frame (selection.yaml emits
    # ``doc.snapshot`` only on the FIRST mousemove), there is no self-commit to
    # close the txn early as there is in the self-bracketing apps, so the op
    # would simply never be recorded (no open transaction). Opening the
    # transaction HERE — and leaving it OPEN — makes ``record_op`` land the op,
    # and the batch owner (run_effects) names + commits the single transaction.
    # ``begin_txn`` is a no-op while one is already open, so the harness (which
    # always brackets around ``op_apply``) and the snapshot-led first frame are
    # byte-unchanged. ``select_rect`` is EXCLUDED: it only changes selection
    # (non-undoable, serialized state), so a bare marquee must stay
    # journal-neutral — opening a txn for it would spuriously journal a
    # selection-only batch as an undoable step.
    if name != "select_rect" and not model.in_txn:
        model.begin_txn()

    ctrl = Controller(model=model)

    # Fork-4 ``targets`` (OP_LOG.md §9). Populated for the THREE replay-safe
    # verbs ``capture_recipe`` consumes; every other verb keeps it empty.
    # ``move_selection``/``copy_selection`` resolve the source ids BEFORE the
    # mutation (a copy is born id-less; a move can change which ids are selected
    # — pre-mutation avoids the post-mutation-id hazard). ``select_rect``
    # resolves AFTER its Controller call (the selection it just established IS
    # the keystone targets).
    targets: list[str] = []
    if name in ("move_selection", "copy_selection"):
        targets = selection_to_ids(model.document)

    if name == "select_rect":
        ctrl.select_rect(
            num_field(op, "x"),
            num_field(op, "y"),
            num_field(op, "width"),
            num_field(op, "height"),
            extend=bool_field(op, "extend"),
        )
        # Keystone: the resolved selection is this op's targets, so
        # ``capture_recipe`` can seed its working set (empty targets => empty
        # recipe). Resolved AFTER the Controller call.
        targets = selection_to_ids(model.document)
    elif name == "move_selection":
        ctrl.move_selection(num_field(op, "dx"), num_field(op, "dy"))
    elif name == "copy_selection":
        ctrl.copy_selection(num_field(op, "dx"), num_field(op, "dy"))
    elif name == "assign_id":
        path = parse_path(op.get("path"))
        id_ = str_field(op, "id")
        if path is None or id_ is None:
            return
        ctrl.assign_id(path, id_)
    elif name == "create_reference":
        target_path = parse_path(op.get("target_path"))
        target_id = str_field(op, "target_id")
        ref_id = str_field(op, "ref_id")
        if target_path is None or target_id is None or ref_id is None:
            return
        ctrl.create_reference(target_path, target_id, ref_id)
    elif name == "make_symbol":
        path = parse_path(op.get("path"))
        master_id = str_field(op, "master_id")
        ref_id = str_field(op, "ref_id")
        if path is None or master_id is None or ref_id is None:
            return
        ctrl.make_symbol(path, master_id, ref_id)
    elif name == "place_instance":
        master_id = str_field(op, "master_id")
        ref_id = str_field(op, "ref_id")
        if master_id is None or ref_id is None:
            return
        ctrl.place_instance(master_id, ref_id)
    elif name == "detach":
        path = parse_path(op.get("path"))
        if path is None:
            return
        ctrl.detach(path)
    elif name == "redefine":
        master_id = str_field(op, "master_id")
        path = parse_path(op.get("path"))
        ref_id = str_field(op, "ref_id")
        if master_id is None or path is None or ref_id is None:
            return
        ctrl.redefine(master_id, path, ref_id)
    elif name == "delete_symbol":
        master_id = str_field(op, "master_id")
        if master_id is None:
            return
        ctrl.delete_symbol(master_id)
    elif name == "set_instance_transform":
        from geometry.element import Transform
        path = parse_path(op.get("path"))
        t = op.get("transform")
        if path is None or not isinstance(t, dict):
            return
        ctrl.set_instance_transform(
            path,
            Transform(
                a=num_field(t, "a"), b=num_field(t, "b"),
                c=num_field(t, "c"), d=num_field(t, "d"),
                e=num_field(t, "e"), f=num_field(t, "f"),
            ),
        )
    elif name == "delete_selection":
        model.document = model.document.delete_selection()
    elif name == "lock_selection":
        ctrl.lock_selection()
    elif name == "unlock_all":
        ctrl.unlock_all()
    elif name == "hide_selection":
        ctrl.hide_selection()
    elif name == "show_all":
        ctrl.show_all()
    elif name == "boolean_union":
        from panels.boolean_apply import apply_destructive_boolean
        apply_destructive_boolean(model, "union")
    elif name == "simplify":
        precision = op.get("precision")
        precision = float(precision) if isinstance(precision, (int, float)) else 0.5
        ctrl.simplify_selection(precision)
    else:
        # Unknown verb: a malformed/unsupported production payload is skipped
        # rather than raising. (The harness corpus only carries known verbs, so
        # this never fires under test — the byte-gate would catch a typo.)
        return

    # Capture the op into the open transaction so the journal replays to the same
    # document — the checkpoint_equivalence gate (OP_LOG.md §5-6). ``targets``
    # (Fork 4) is populated above for the three replay-safe verbs; empty for
    # every other verb. ``record_op`` is a no-op when no transaction is open.
    model.record_op(PrimitiveOp(op=name, params=dict(op), targets=targets))
