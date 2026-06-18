import Foundation

/// Operation-log spine — the typed Transaction journal (OP_LOG.md Increment 2).
///
/// The journal is layered on top of the whole-Document snapshot stacks, which
/// stay the undo/redo mechanism (OP_LOG.md §4). A ``Transaction`` is the
/// atomic / reversible / summarizable unit (VISION.md §10 item 2) that replaces
/// snapshot-boundary grouping; a ``PrimitiveOp`` is one entry in its ordered op
/// list, a superset of today's cross-language fixture op (OP_LOG.md §5).
///
/// The op-apply / harness path records ops into the open transaction so
/// ``Model/commitTxn()`` finalizes a transaction whose ``Transaction/ops``
/// replay to the same document — the checkpoint_equivalence gate (§6). Causal /
/// merge metadata (``actor`` / ``parent`` / ``lamport`` / ``label``, §8) is
/// reserved now; ``Transaction/txnId`` is a deterministic per-Model counter
/// (txn-0, txn-1, …, §7) so the journal is byte-shareable across apps.
///
/// Mirrors ``jas_dioxus``'s `op_log.rs` and the Python `op_log.py`.

/// The default actor for human edits (OP_LOG.md §8).
public let actorArtist = "artist"

/// A primitive op: one entry in a transaction's ordered op list (OP_LOG.md §5)
/// — the verb plus its flat params, plus ``targets`` (Fork 4): the resolved
/// `common.id`s of elements written. The flat ``params`` mirror the fixture
/// payload verbatim, so the existing operations fixtures keep replaying
/// unchanged. ``params`` is `[String: Any]` (the same shape the cross-language
/// harness builds each op dict in) so replay can re-dispatch through the
/// existing op applier.
public struct PrimitiveOp {
    /// The op verb, verbatim (e.g. `move_selection`, `select_rect`).
    public var op: String
    /// The flat literal payload, exactly as the fixtures carry it. Held as
    /// `[String: Any]` to match the harness op dictionaries; replay feeds this
    /// straight back into the op applier.
    public var params: [String: Any]
    /// Resolved `common.id`s of elements this op writes (Fork 4). Additive
    /// metadata, never an op rewrite. Reserved here; populated by later work.
    public var targets: [String]

    public init(op: String, params: [String: Any], targets: [String] = []) {
        self.op = op
        self.params = params
        self.targets = targets
    }
}

/// A Transaction: the atomic / reversible / summarizable unit (OP_LOG.md §5),
/// replacing snapshot-boundary grouping. Causal metadata is reserved now
/// (cheap; expensive to retrofit across five apps + the fixture corpus, §8).
public struct Transaction {
    /// Deterministic id under replay: txn-0, txn-1, … (a per-Model counter, the
    /// same discipline element ids use), so the journal is byte-shareable across
    /// apps (OP_LOG.md §7). Live runs may draw entropy.
    public var txnId: String
    /// Ordered child ops, replayed verbatim. Populated by the op-apply path;
    /// empty for opaque production transactions until the unification.
    public var ops: [PrimitiveOp]
    /// Artist/AI-legible op name → the semantic-summary surface. `nil` for an
    /// anonymous / opaque transaction (e.g. a production edit).
    public var name: String?
    /// Optional human text; else derived from name + targets later.
    public var summary: String?
    /// `artist` | `ai` | `peer:<id>` — reserved for the AI accept path and
    /// collaboration (OP_LOG.md §8). Defaults to ``actorArtist``.
    public var actor: String
    /// Causal edge to the prior transaction (single edge now → a parent-set for
    /// a merge DAG later).
    public var parent: String?
    /// Logical clock (scalar now → a per-actor vector clock later).
    public var lamport: UInt64
    /// Non-nil marks a labeled point in the stream — a version (VISION.md §6.9).
    public var label: String?

    public init(
        txnId: String,
        ops: [PrimitiveOp] = [],
        name: String? = nil,
        summary: String? = nil,
        actor: String = actorArtist,
        parent: String? = nil,
        lamport: UInt64 = 0,
        label: String? = nil
    ) {
        self.txnId = txnId
        self.ops = ops
        self.name = name
        self.summary = summary
        self.actor = actor
        self.parent = parent
        self.lamport = lamport
        self.label = label
    }
}
