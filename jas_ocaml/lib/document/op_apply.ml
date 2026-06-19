(** The single op dispatcher — [op_apply] (OP_LOG.md section 4 / section 9,
    Increment 3b-B). See [op_apply.mli] for the design rationale.

    Mirrors [jas_dioxus] [document/op_apply.rs] and the Swift [OpApply.swift].
    Param reads are hardened so production input never raises: numbers default
    to 0.0; a missing required field (a path, an id, a transform) skips the op.
    Free of [State_store] (the interpreter layer) to avoid a circular dep — it
    consumes only the raw Yojson op value plus local hardened extractors. *)

open Yojson.Safe.Util

(* Read an f64 field, defaulting to 0.0 (the non-raising number form). *)
let num_field (op : Yojson.Safe.t) (key : string) : float =
  match member key op with
  | `Float f -> f
  | `Int i -> float_of_int i
  | _ -> 0.0

(* Read a string field, or [None] if absent / not a string. *)
let str_field (op : Yojson.Safe.t) (key : string) : string option =
  match member key op with
  | `String s -> Some s
  | _ -> None

(* Read a bool field, defaulting to [false]. *)
let bool_field (op : Yojson.Safe.t) (key : string) : bool =
  match member key op with
  | `Bool b -> b
  | _ -> false

(* Parse a JSON array of indices into an element path. Returns [None] if the
   field is absent or not an array (a malformed production payload skips the op
   rather than raising). Non-integer entries default to 0. *)
let parse_path (op : Yojson.Safe.t) (key : string) : int list option =
  match member key op with
  | `List items ->
    Some (List.map (fun i ->
      match i with `Int n -> n | `Float f -> int_of_float f | _ -> 0) items)
  | _ -> None

let op_apply (model : Model.model) (ctrl : Controller.controller)
    (op : Yojson.Safe.t) : unit =
  match member "op" op with
  | `String name ->
    (* History-navigation ops (OP_LOG.md section 5): they manage transaction
       boundaries / the journal cursor and are NOT primitive ops, so they are
       never journaled. [snapshot] commits the prior action's transaction and
       opens a new one; undo/redo end the open context and move the cursor. *)
    (match name with
     | "snapshot" -> model#commit_txn; model#begin_txn
     | "undo" -> model#undo
     | "redo" -> model#redo
     | _ ->
       (* OP_LOG.md section 9 (Increment 3b-B) — close the subsequent-drag-frame
          journaling hole. Every verb below except [select_rect] is an UNDOABLE
          mutation. OCaml [Model.set_document] does NOT self-bracket the way
          Rust [edit_document] does, so this lazy [begin_txn] is the ONLY
          safeguard against a bare drag frame (selection.yaml emits
          [doc.snapshot] only on the FIRST mousemove) losing its op: without it,
          [record_op] would drop the op and the batch owner's
          [name_txn]/[commit_txn] would have nothing to commit. Opening the
          transaction HERE — and leaving it OPEN — makes the mutation land in
          [record_op] and the batch owner ([Effects.run_effects]) names and
          commits the single transaction. [begin_txn] is a no-op while one is
          already open, so the harness (which always brackets around [op_apply])
          and the snapshot-led first frame are byte-unchanged. [select_rect] is
          EXCLUDED: it only changes selection (non-undoable, serialized state),
          so a bare marquee must stay journal-neutral — opening a txn for it
          would spuriously journal a selection-only batch as an undoable step. *)
       if name <> "select_rect" then model#begin_txn;
       (* Fork-4 [targets] (OP_LOG.md section 9). Populated for the THREE
          replay-safe verbs [capture_recipe] consumes; every other verb keeps it
          empty. [move_selection]/[copy_selection] resolve the source ids BEFORE
          the mutation (a copy is born id-less; a move can change which ids are
          selected — pre-mutation avoids the post-mutation-id hazard).
          [select_rect] resolves AFTER its Controller call (the selection it just
          established IS the keystone targets). *)
       let targets = ref [] in
       if name = "move_selection" || name = "copy_selection" then
         targets := Controller.selection_to_ids model#document;
       let proceed = ref true in
       (match name with
        | "select_rect" ->
          let extend = bool_field op "extend" in
          ctrl#select_rect ~extend
            (num_field op "x") (num_field op "y")
            (num_field op "width") (num_field op "height");
          (* Keystone: the resolved selection is this op's targets, so
             [capture_recipe] can seed its working set (empty targets ->
             empty recipe). Resolved AFTER the Controller call. *)
          targets := Controller.selection_to_ids model#document
        | "move_selection" ->
          ctrl#move_selection (num_field op "dx") (num_field op "dy")
        | "copy_selection" ->
          ctrl#copy_selection (num_field op "dx") (num_field op "dy")
        | "assign_id" ->
          (match parse_path op "path", str_field op "id" with
           | Some path, Some id -> ctrl#assign_id path id
           | _ -> proceed := false)
        | "create_reference" ->
          (match parse_path op "target_path",
                 str_field op "target_id", str_field op "ref_id" with
           | Some target_path, Some target_id, Some ref_id ->
             ctrl#create_reference target_path target_id ref_id
           | _ -> proceed := false)
        | "make_symbol" ->
          (match parse_path op "path",
                 str_field op "master_id", str_field op "ref_id" with
           | Some path, Some master_id, Some ref_id ->
             ctrl#make_symbol path master_id ref_id
           | _ -> proceed := false)
        | "place_instance" ->
          (match str_field op "master_id", str_field op "ref_id" with
           | Some master_id, Some ref_id ->
             ctrl#place_instance master_id ref_id
           | _ -> proceed := false)
        | "detach" ->
          (match parse_path op "path" with
           | Some path -> ctrl#detach path
           | None -> proceed := false)
        | "redefine" ->
          (match str_field op "master_id", parse_path op "path",
                 str_field op "ref_id" with
           | Some master_id, Some path, Some ref_id ->
             ctrl#redefine master_id path ref_id
           | _ -> proceed := false)
        | "delete_symbol" ->
          (match str_field op "master_id" with
           | Some master_id -> ctrl#delete_symbol master_id
           | None -> proceed := false)
        | "set_instance_transform" ->
          (match parse_path op "path", member "transform" op with
           | Some path, (`Assoc _ as t) ->
             let transform = {
               Element.a = num_field t "a"; b = num_field t "b";
               c = num_field t "c"; d = num_field t "d";
               e = num_field t "e"; f = num_field t "f";
             } in
             ctrl#set_instance_transform path transform
           | _ -> proceed := false)
        | "delete_selection" ->
          let new_doc = Document.delete_selection model#document in
          model#set_document new_doc
        | "lock_selection" -> ctrl#lock_selection
        | "unlock_all" -> ctrl#unlock_all
        | "hide_selection" -> ctrl#hide_selection
        | "show_all" -> ctrl#show_all
        | "boolean_union" ->
          Boolean_apply.apply_destructive_boolean model "union"
        | "simplify" ->
          let precision =
            match member "precision" op with
            | `Float f -> f | `Int i -> float_of_int i | _ -> 0.5 in
          ctrl#simplify_selection precision
        | _ ->
          (* Unknown verb: a malformed/unsupported production payload is skipped
             rather than raising. The harness corpus only carries known verbs, so
             this never fires under test — the byte-gate would catch a typo. *)
          proceed := false);
       (* Capture the op into the open transaction so the journal replays to the
          same document — the checkpoint_equivalence gate (OP_LOG.md section
          5-6). [targets] (Fork 4) is populated above for the three replay-safe
          verbs; empty for every other verb. [record_op] is a no-op when no
          transaction is open. [params] carries the full op value verbatim (verb
          included), matching the harness record-op site; the journal serializer
          strips the redundant "op" key. *)
       if !proceed then
         model#record_op
           (Op_log.make_primitive_op ~op:name ~params:op ~targets:!targets ()))
  | _ ->
    (* A primitive op with no verb is malformed; skip it (never raise). *)
    ()
