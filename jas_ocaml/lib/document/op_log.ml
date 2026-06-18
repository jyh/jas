(* Operation-log spine — the typed Transaction journal (OP_LOG.md Increment 2).

   Mirrors [jas_dioxus/src/document/op_log.rs] and [jas/document/op_log.py].
   A [transaction] is the atomic / reversible / summarizable unit (VISION.md
   section 10 item 2) that replaces snapshot-boundary grouping; a
   [primitive_op] is one entry in its ordered op list, a superset of today's
   cross-language fixture op (OP_LOG.md section 5).

   The journal is layered on top of the whole-Document snapshot stacks (which
   remain the undo/redo mechanism, section 4). The op_apply / harness path
   records ops into the open transaction so [commit_txn] finalizes a
   transaction whose [ops] replay to the same document — the
   checkpoint_equivalence gate (section 6). Causal / merge metadata
   ([actor] / [parent] / [lamport] / [label], section 8) is reserved now;
   [txn_id] is a deterministic per-Model counter ([txn-0], [txn-1], …,
   section 7) so the journal is byte-shareable across apps. *)

(* The default actor for human edits. *)
let actor_artist = "artist"

(* A primitive op: one entry in a transaction's ordered op list (OP_LOG.md
   section 5): the verb + its flat params, plus [targets] (Fork 4) — the
   resolved [common.id]s of elements written. [params] mirrors the fixture
   payload verbatim, so the existing operations fixtures keep replaying
   unchanged. *)
type primitive_op = {
  op : string;
  params : Yojson.Safe.t;
  targets : string list;
}

(* A transaction: the atomic / reversible / summarizable unit (OP_LOG.md
   section 5), replacing snapshot-boundary grouping. Causal metadata is
   reserved now (cheap; expensive to retrofit across five apps + the fixture
   corpus — section 8). *)
type transaction = {
  txn_id : string;
  ops : primitive_op list;
  name : string option;
  summary : string option;
  actor : string;
  parent : string option;
  lamport : int;
  label : string option;
}

(* Build a primitive op with no resolved targets (the default for the
   op_apply / harness path, which mirrors the fixture payload verbatim). *)
let make_primitive_op ?(targets = []) ~op ~params () =
  { op; params; targets }
