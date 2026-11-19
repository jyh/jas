//! Operation-log spine — the typed Transaction journal (OP_LOG.md Increment 2).
//!
//! The journal is layered *on top of* the whole-Document snapshot stacks, which
//! stay the O(1) undo/redo mechanism (OP_LOG.md §4). A `Transaction` is the
//! atomic / reversible / summarizable unit (`VISION.md` §10 item 2) that
//! replaces snapshot-boundary grouping; a `PrimitiveOp` is one entry in its
//! ordered op list, a superset of today's `apply_op` fixture op (§5).
//!
//! Sub-step 2.1 wired the journal as a **cursor** (drives `is_modified` and the
//! transaction count); the causal metadata (`actor`/`parent`/`lamport`/`label`,
//! OP_LOG.md §8) is recorded and mostly not yet read, hence the module-wide
//! dead-code allow. The `ops` list IS read today, by transaction coalescing
//! (`Model`, both ports) and the recorder (`recorder/core.rs`): the full list
//! of readers, each with how it treats an empty list, is
//! `scripts/check_ops_readers.py` (corrected 2026-11-18, STATUS-jas row 154;
//! until then this header said `ops` was reserved).
//!
//! ⛔ **HOST-KEY TRANSACTIONS JOURNAL WITH `ops: []`.** Six panel hosts write the
//! document from a key with no `doc.*` verb (gradient, stroke, properties,
//! character, paragraph, opacity; `panel_behavior.rs`), so their transactions
//! carry a name and no ops. Undo is unaffected (snapshot stacks). **Typed ops
//! per host through `op_apply` become REQUIRED, not optional, the day a reader
//! of `ops` is added for which an empty list is a wrong answer** (op replay,
//! `checkpoint_equivalence`, the intent ledger). `check_ops_readers.py` fails on
//! any new reader, so that decision is made when the reader is written.
#![allow(dead_code)]

/// A primitive op: one entry in a transaction's ordered op list. A superset of
/// today's `apply_op` fixture op (OP_LOG.md §5) — the verb + its flat params,
/// plus `targets` (Fork 4): the resolved `common.id`s of elements written (and,
/// where a recorded recipe needs them, read). The flat `params` mirror the
/// fixture payload verbatim (`dx`/`dy`, `path:[..]`, `transform:{a..f}`, `id`,
/// `char_start`/`char_end`, …) so the existing operations fixtures keep
/// replaying unchanged.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct PrimitiveOp {
    /// The `apply_op` verb, verbatim (e.g. `move_selection`, `select_rect`).
    pub op: String,
    /// The flat literal payload, exactly as the fixtures carry it.
    pub params: serde_json::Value,
    /// Resolved `common.id`s of elements this op writes (Fork 4). Recipe-safe
    /// rebind + merge conflict detection; additive metadata, never an op rewrite.
    pub targets: Vec<String>,
}

/// A Transaction: the atomic / reversible / summarizable unit (OP_LOG.md §5),
/// replacing snapshot-boundary grouping. Causal metadata is reserved now
/// (cheap; expensive to retrofit across five apps + the fixture corpus — §8).
#[derive(Debug, Clone, PartialEq)]
pub struct Transaction {
    /// Deterministic id under replay: `txn-0`, `txn-1`, … (a per-Model counter,
    /// the same discipline `element_ids.json` uses for `rect-0`/`group-0`), so
    /// the journal file is byte-shareable across apps (OP_LOG.md §7). Live runs
    /// may draw entropy.
    pub txn_id: String,
    /// Artist/AI-legible op name (an `actions.yaml` verb) → the semantic-summary
    /// surface. `None` for an anonymous/opaque transaction (e.g. a production
    /// edit not yet driven by the op vocabulary).
    pub name: Option<String>,
    /// Ordered child ops, replayed verbatim. Populated by the `op_apply` path
    /// (sub-step 2.2); empty for opaque production transactions until the
    /// `apply_op`↔`actions.yaml` unification.
    pub ops: Vec<PrimitiveOp>,
    /// Optional human text; else derived from `name` + `targets` + `actions.yaml`.
    pub summary: Option<String>,
    /// `artist` | `ai` | `peer:<id>` — reserved for the AI accept path and
    /// collaboration (OP_LOG.md §8).
    pub actor: String,
    /// Causal edge to the prior transaction (single edge now → a parent-set for
    /// a merge DAG later).
    pub parent: Option<String>,
    /// Logical clock (scalar now → a per-actor vector clock later).
    pub lamport: u64,
    /// Non-null marks a labeled point in the stream — a version (`VISION.md` §6.9).
    pub label: Option<String>,
}

impl Transaction {
    /// The default actor for human edits.
    pub const ACTOR_ARTIST: &'static str = "artist";
}
