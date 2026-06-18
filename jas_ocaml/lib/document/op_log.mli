(** Operation-log spine — the typed Transaction journal (OP_LOG.md
    Increment 2). Mirrors [jas_dioxus/src/document/op_log.rs] and
    [jas/document/op_log.py]. *)

(** The default actor for human edits ([artist]). *)
val actor_artist : string

(** A primitive op: one entry in a transaction's ordered op list (OP_LOG.md
    section 5) — the verb + its flat params (the fixture payload verbatim),
    plus [targets] (Fork 4): the resolved [common.id]s of elements written. *)
type primitive_op = {
  op : string;
  params : Yojson.Safe.t;
  targets : string list;
}

(** A transaction: the atomic / reversible / summarizable unit (OP_LOG.md
    section 5). [txn_id] is a deterministic per-Model counter ([txn-0],
    [txn-1], …, section 7) so the journal is byte-shareable across apps;
    the causal metadata ([actor] / [parent] / [lamport] / [label],
    section 8) is reserved now. *)
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

(** Build a primitive op with no resolved targets (the default for the
    op_apply / harness path, which mirrors the fixture payload verbatim). *)
val make_primitive_op :
  ?targets:string list -> op:string -> params:Yojson.Safe.t -> unit ->
  primitive_op
