"""Operation-log spine — the typed Transaction journal (OP_LOG.md Increment 2).

Mirrors ``jas_dioxus/src/document/op_log.rs``. A ``Transaction`` is the
atomic / reversible / summarizable unit (VISION.md §10 item 2) that replaces
snapshot-boundary grouping; a ``PrimitiveOp`` is one entry in its ordered op
list, a superset of today's cross-language fixture op (OP_LOG.md §5).

The journal is layered on top of the snapshot stacks (which remain the undo/redo
mechanism, §4). The op_apply / harness path records ops into the open
transaction so ``commit_txn`` finalizes a transaction whose ``ops`` replay to
the same document — the ``checkpoint_equivalence`` gate (§6). Causal / merge
metadata (``actor`` / ``parent`` / ``lamport`` / ``label``, §8) is reserved now;
``txn_id`` is a deterministic per-Model counter (``txn-0``, ``txn-1``, …, §7) so
the journal is byte-shareable across apps.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

ACTOR_ARTIST = "artist"


@dataclass
class PrimitiveOp:
    """One entry in a transaction's ordered op list (OP_LOG.md §5): the verb +
    its flat params, plus ``targets`` (Fork 4) — the resolved ``common.id``s of
    elements written. ``params`` mirrors the fixture payload verbatim."""

    op: str
    params: dict[str, Any]
    targets: list[str] = field(default_factory=list)


@dataclass
class Transaction:
    """The atomic / reversible / summarizable unit (OP_LOG.md §5)."""

    txn_id: str
    ops: list[PrimitiveOp] = field(default_factory=list)
    name: str | None = None
    summary: str | None = None
    actor: str = ACTOR_ARTIST
    parent: str | None = None
    lamport: int = 0
    label: str | None = None
