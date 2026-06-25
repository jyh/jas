(** Observable model that holds the current document.

    Views register callbacks via on_document_changed to be notified
    whenever the document is replaced. *)

(** Structural view of an in-place text-editing session, exposed to
    callers (the Character panel pipeline) that need to detect an
    active bare-caret editor and prime its next-typed-character
    state. The concrete [Text_edit.t] lives in [lib/tools] — we use
    an object type here to keep the layering pointed the right way
    (tools may see Document/Model, but not the other way round). *)
type edit_session_ref = <
  has_selection : bool;
  selection_range : int * int;
  path : int list;
  set_pending_override : Element.tspan -> unit;
  clear_pending_override : unit -> unit
>

(** The target that drawing tools operate on. The default is the
    document's normal content; mask-editing mode switches the
    target to a specific element's mask subtree so new shapes land
    inside [element.mask.subtree] instead of the selected layer.
    Mirrors [EditingTarget] in [jas_dioxus] / [EditingTarget] in
    JasSwift. OPACITY.md \167Preview interactions. *)
type editing_target =
  | Content
  | Mask of int list

(** A named version point (OP_LOG.md Increment 3a / VISION.md section 6.9).
    Stores the document + paired index at a labeled journal cursor position so
    restore_version is O(1) and sound regardless of whether the intervening
    transactions carry replayable ops. Mirrors the Rust [Version] struct. *)
type version = {
  label : string;
  journal_head : int;
  document : Document.document;
  id_index : Live.id_index;
}

let max_undo = 100

let next_untitled = ref 1

let fresh_filename () =
  let name = Printf.sprintf "Untitled-%d" !next_untitled in
  incr next_untitled;
  name

(** Bump [next_untitled] past any [Untitled-N] entries already in use
    (e.g. from session restore). Without this, restoring a session
    with [Untitled-2] in it then File→New produces a second
    [Untitled-2] tab — clicking × on the duplicate becomes ambiguous
    and the session save+reload loop snowballs duplicates. *)
let advance_next_untitled_past (existing_filenames : string list) : unit =
  let max_n = ref (!next_untitled - 1) in
  List.iter (fun fn ->
    let prefix = "Untitled-" in
    let pl = String.length prefix in
    if String.length fn > pl
    && String.sub fn 0 pl = prefix then
      match int_of_string_opt (String.sub fn pl (String.length fn - pl)) with
      | Some n when n > !max_n -> max_n := n
      | _ -> ()
  ) existing_filenames;
  next_untitled := !max_n + 1

(* Persistent id->element index for the document [doc]. Phase 4b
   (REFERENCE_GRAPH.md section 2.4): a pure function of the document
   (always equal to [rebuild_index doc]; checked by the [assert] gate
   below), so it is never serialized and never part of Document equality.
   Held alongside [doc] on the Model so paint reads it without rebuilding
   each frame, and paired with each undo/redo entry so a snapshot carries
   it in O(1) (Map structure sharing). Mirrors the Rust [Model.id_index]. *)
let rebuild_index (d : Document.document) : Live.id_index =
  Live.rebuild_id_index d.Document.layers d.Document.symbols

class model ?(document = Document.default_document ()) ?filename () =
  let filename = match filename with Some f -> f | None -> fresh_filename () in
  object (_self)
    val mutable doc = document
    val mutable id_index = rebuild_index document
    (* Monotonic modification generation (Phase 4c). Bumped on every path
       that replaces [doc] (set_document / restore_preview_snapshot / undo /
       redo) so paint can epoch the reference-geometry recompute cache off it:
       any edit changes the generation and drops the cache. Mirrors the Rust
       [Model.generation]. *)
    val mutable generation = 0
    (* OP_LOG.md Increment 2: the journal-head cursor. An uncapped count of
       undoable edits applied (snapshot increments it, undo/redo move it), so
       is_modified is journal_head <> saved_journal_head — undo back to the
       saved point reads as not-modified. Replaces the old identity compare
       against a saved-document reference. Both the production snapshot() path
       and the begin_txn/commit_txn bracket advance this cursor; a given flow
       uses one path or the other. *)
    val mutable journal_head = 0
    val mutable saved_journal_head = 0
    (* OP_LOG.md Increment 2 (full journal): the typed Transaction journal
       layered on the snapshot stacks. Built via begin_txn/commit_txn/record_op
       (the op_apply / harness path); production snapshot() edits advance the
       journal_head cursor but record no transaction (opaque). See op_log.ml.
       op_journal is the ordered transaction list; pending_txn accumulates the
       transaction being built between begin_txn and commit_txn; in_txn is true
       while a transaction is open; next_txn_counter drives the deterministic
       [txn-N] ids (the same discipline element_ids.json uses for element ids,
       so the journal file is byte-shareable across apps). *)
    val mutable op_journal : Op_log.transaction list = []
    (* The pending transaction, captured as (name, accumulated-ops-reversed,
       doc_at_begin). [doc_at_begin] is the pre-edit checkpoint document, used
       by commit_txn's no-op rule (physical-eq fast path, else a canonical
       document_to_test_json byte compare). The ops are accumulated reversed
       and flipped at commit so the journal preserves apply order. *)
    val mutable pending_txn :
      (string option * Op_log.primitive_op list * Document.document) option = None
    val mutable in_txn = false
    val mutable next_txn_counter = 0
    (* OP_LOG.md Increment 3a: named version points (VISION.md section 6.9).
       Each labels a journal cursor position and stores the document + paired
       index at that point, so restore_version is O(1) and sound even though
       production transactions are opaque (no op replay needed). The label is
       also written onto the journal's transaction at that head (the [label]
       field reserved in Increment 2) so it serializes into the journal
       artifact. Stored newest-last in creation order. Mirrors the Rust
       [Model.versions]. *)
    val mutable versions : version list = []
    val mutable current_filename = filename
    val mutable listeners : (Document.document -> unit) list = []
    val mutable filename_listeners : (string -> unit) list = []
    (* Each undo/redo entry pairs the document with its index so undo/redo
       restore the index in O(1) without a rebuild (Map clone is O(1)
       structure sharing). Mirrors the Rust [Vec<(Document, IdIndex)>]. *)
    val mutable undo_stack : (Document.document * Live.id_index) list = []
    val mutable redo_stack : (Document.document * Live.id_index) list = []
    val mutable default_fill : Element.fill option = None
    val mutable default_stroke : Element.stroke option =
      Some (Element.make_stroke Element.black)
    val mutable recent_colors : string list = []
    val mutable current_edit_session : edit_session_ref option = None
    (* Mask-editing mode state. [Content] is the default; flipped
       to [Mask path] when the user clicks the Opacity panel's
       MASK_PREVIEW. OPACITY.md \167Preview interactions. *)
    val mutable editing_target : editing_target = Content
    (* Mask-isolation path. When [Some path], the canvas renders
       only the mask subtree of the element at [path], hiding
       everything else. Entered by Alt/Option-clicking
       MASK_PREVIEW; exited by Alt-clicking again.
       OPACITY.md \167Preview interactions. *)
    val mutable mask_isolation_path : int list option = None
    (* Per-document view state per ZOOM_TOOL.md State persistence.
       Persists across tab switches within a session; reset to
       defaults on document open. Not serialized to disk in
       Phase 1. *)
    val mutable zoom_level : float = 1.0
    val mutable view_offset_x : float = 0.0
    val mutable view_offset_y : float = 0.0
    (* Canvas viewport dimensions in screen-space pixels. Updated
       by the canvas widget on layout / resize. Read by
       doc.zoom.fit_* effects. Defaults match
       workspace/layout.yaml canvas_pane default_position. *)
    val mutable viewport_w : float = 888.0
    val mutable viewport_h : float = 900.0

    method document = doc

    (* Borrow the persistent id->element index paired with the current
       document (REFERENCE_GRAPH.md section 2.4). Equal to
       [rebuild_index doc] at all observable points. The canvas paint path
       reads this (via [Live.resolver_of_index]) instead of rebuilding the
       index per frame. Mirrors the Rust [Model.id_index]. *)
    method id_index : Live.id_index = id_index

    (* The modification generation (Phase 4c). Read at the paint entry to
       epoch the reference-geometry recompute cache. Mirrors the Rust
       [Model.generation]. *)
    method generation : int = generation

    (* Phase 4b gate: after any path that sets [id_index], assert the stored
       index equals a from-scratch rebuild of [doc]. OCaml [assert] is on by
       default and the whole test suite runs with it active, so this proves
       the stored index always matches a fresh rebuild — pinning resolve()
       results unchanged. Mirrors the Rust [debug_assert!]. The polymorphic
       [=] is exact here: [element] has no functional fields. *)
    method private assert_index_matches_rebuild =
      assert (Live.Id_map.equal ( = ) id_index (rebuild_index doc))

    method filename = current_filename

    method set_filename (f : string) =
      current_filename <- f;
      List.iter (fun cb -> cb f) filename_listeners

    (* OP_LOG.md Increment 1 (enforced chokepoint, mirroring jas_dioxus
       [model.rs] and jas [model.py]): three public writes funnel into one
       private [write_document].

       - [set_document]            — UNDOABLE write; asserts [in_txn] is open.
       - [edit_document]           — SELF-BRACKETING undoable write (opens and
                                     commits its own txn when none is open, else
                                     joins the caller). This is what the
                                     Controller mutators use, so a standalone
                                     edit is a complete one-step undo and a
                                     nested one joins the owning action.
       - [set_document_unbracketed] — sanctioned NON-undoable write (selection /
                                     preview re-apply / live drag / view-state /
                                     undo-redo history-nav / test setup); never
                                     asserts (OP_LOG.md sections 7 and 8).

       The distinct names let the live [in_txn] guard in [set_document] tell
       "deliberately not undoable" from "forgot to open a transaction": the
       former says so by calling [set_document_unbracketed] directly. *)

    (* The single committing write to [doc]: rebuild the paired index here so
       paint never rebuilds it (REFERENCE_GRAPH.md section 2.4 Phase 4b), bump
       the modification generation, gate the index against a fresh rebuild, and
       notify listeners. All three public writes funnel here so there is exactly
       one place document content is committed. Mirrors the Rust private
       [write_document]. *)
    method private write_document (d : Document.document) =
      doc <- d;
      id_index <- rebuild_index d;
      generation <- generation + 1;
      _self#assert_index_matches_rebuild;
      List.iter (fun f -> f doc) listeners

    (* The committing write for UNDOABLE mutations. The [assert in_txn] is LIVE
       (OP_LOG.md Increment 1, enforced chokepoint): any undoable edit that
       skipped the transaction bracket fails the test suite, so the journal
       cursor is complete by construction. OCaml [assert] runs in release too,
       consistent with the id-index gate above (the existing release trust gate)
       — so this guard is the app convention, not a debug-only check.
       Self-bracketing mutators use [edit_document]; sanctioned non-undoable
       writes use [set_document_unbracketed] (which never asserts). Mirrors the
       Rust [set_document]. *)
    method set_document (d : Document.document) =
      assert in_txn;
      _self#write_document d

    (* Self-bracketing undoable write: if no transaction is open, wrap this edit
       in its own begin/commit (one undo step); if one is already open, just
       write (joining the caller transaction). This is what the [Controller]
       mutators use, so a standalone call (a unit test, or a direct Controller
       call) is a complete one-step undo, while the same method called inside a
       UI [with_txn] / [begin_txn] joins that action — production behavior is
       unchanged, and no test needs an explicit bracket. The begin/commit run
       even if [write_document] raises is NOT required (writes here do not
       raise; the body is total), so a plain try is unnecessary. Distinct from
       [set_document] (asserts a transaction is open) and
       [set_document_unbracketed] (non-undoable). Mirrors the Rust
       [edit_document]. *)
    method edit_document (d : Document.document) =
      let opened = not in_txn in
      if opened then _self#begin_txn;
      _self#write_document d;
      if opened then _self#commit_txn

    (* Committing write for sanctioned NON-undoable mutations — selection-only
       and pure view-state changes, dialog-preview re-apply, live drag, and test
       setup (OP_LOG.md sections 7 and 8). Same effect as [set_document] but the
       distinct name is what lets the live [in_txn] guard in [set_document] tell
       "deliberately not undoable" from "forgot to open a transaction": this
       path never asserts. Mirrors the Rust [set_document_unbracketed]. *)
    method set_document_unbracketed (d : Document.document) =
      _self#write_document d

    method on_document_changed (f : Document.document -> unit) =
      listeners <- f :: listeners

    method on_filename_changed (f : string -> unit) =
      filename_listeners <- f :: filename_listeners

    method snapshot =
      (* Pair the index with the document on the stack so undo/redo restore
         it in O(1) without a rebuild (Map clone is O(1) structure
         sharing). Phase 4b. *)
      undo_stack <- (doc, id_index) :: undo_stack;
      if List.length undo_stack > max_undo then
        undo_stack <- List.filteri (fun i _ -> i < max_undo) undo_stack;
      redo_stack <- [];
      (* Advance the journal cursor: one undoable edit (OP_LOG.md §5). Uncapped,
         unlike the max_undo-capped stack, so is_modified stays correct past the
         cap. *)
      journal_head <- journal_head + 1

    (* Out-of-band document snapshot for dialog Preview flows
       (Scale Options, Rotate Options, Shear Options). Captured at
       dialog open, restored on Cancel, cleared on OK. Distinct
       from undo_stack so preview-driven applies do not pollute
       undo history. See SCALE_TOOL.md \167 Preview. *)
    val mutable preview_doc_snapshot : Document.document option = None

    method capture_preview_snapshot =
      preview_doc_snapshot <- Some doc

    method restore_preview_snapshot =
      (match preview_doc_snapshot with
       | Some snap ->
         doc <- snap;
         (* The preview snapshot carries no index (it is out-of-band from
            the undo stack), so rebuild it from the restored document.
            Phase 4b; mirrors the Rust [refresh_id_index] here. *)
         id_index <- rebuild_index snap;
         generation <- generation + 1;
         _self#assert_index_matches_rebuild;
         List.iter (fun f -> f doc) listeners
       | None -> ())

    method clear_preview_snapshot =
      preview_doc_snapshot <- None

    method has_preview_snapshot = preview_doc_snapshot <> None

    method undo =
      (* History navigation ends any open edit context, so the next edit
         self-brackets fresh (OP_LOG.md Increment 1: keeps in_txn honest after
         undo, so a post-undo edit clears redo via its own commit). *)
      in_txn <- false;
      pending_txn <- None;
      match undo_stack with
      | [] -> ()
      | (prev_doc, prev_index) :: rest ->
        (* Carry the current (doc, index) onto redo and restore the paired
           index in O(1) — no rebuild (Phase 4b). The gate confirms the
           carried index equals a from-scratch rebuild of the restored
           document. *)
        redo_stack <- (doc, id_index) :: redo_stack;
        undo_stack <- rest;
        doc <- prev_doc;
        id_index <- prev_index;
        generation <- generation + 1;
        if journal_head > 0 then journal_head <- journal_head - 1;
        _self#assert_index_matches_rebuild;
        List.iter (fun f -> f doc) listeners

    method redo =
      in_txn <- false;
      pending_txn <- None;
      match redo_stack with
      | [] -> ()
      | (next_doc, next_index) :: rest ->
        undo_stack <- (doc, id_index) :: undo_stack;
        redo_stack <- rest;
        doc <- next_doc;
        id_index <- next_index;
        generation <- generation + 1;
        (* Advance the journal cursor one transaction (OP_LOG.md section 5).
           Unbounded, because the production snapshot() path advances the
           cursor without appending to op_journal (an opaque edit), so the
           cursor can legitimately exceed the journal length; redo only runs
           when redo_stack is non-empty (a prior undo decremented), keeping it
           in lock-step with the snapshot stacks. Mirrors the Python redo. *)
        journal_head <- journal_head + 1;
        _self#assert_index_matches_rebuild;
        List.iter (fun f -> f doc) listeners

    (* OP_LOG.md \167 9 unified semantics: the journal-head cursor, so undo back
       to the saved point reads as not-modified (and a non-undoable write that
       does not snapshot does not mark the document modified). *)
    method is_modified = journal_head <> saved_journal_head

    method mark_saved =
      saved_journal_head <- journal_head;
      List.iter (fun f -> f doc) listeners

    method can_undo = undo_stack <> []
    method can_redo = redo_stack <> []

    (* ── Transaction journal (OP_LOG.md Increment 2, full journal) ──────────

       begin_txn / commit_txn build the typed Transaction journal (the
       op_apply / harness path). They sit alongside snapshot (the production
       undoable-edit boundary, which advances the journal_head cursor but
       records no transaction). Both advance journal_head; a given flow uses
       one path or the other. record_op / name_txn populate the open
       transaction. *)

    (* The Transaction journal (OP_LOG.md section 5). Test/inspection
       accessor; mirrors the Rust [journal] / Python [journal]. *)
    method journal : Op_log.transaction list = op_journal

    (* The journal cursor — the count of transactions currently applied
       (0..=journal length). Test/inspection accessor. *)
    method journal_head : int = journal_head

    (* True while an undoable transaction is open (between begin_txn and
       commit_txn). Read by the effect runner's owner-bracket (OP_LOG.md section
       9): a batch OWNS the transaction only if none was open when it started,
       and by op_apply's lazy begin_txn (which is a no-op while one is already
       open). Mirrors the Rust [Model.in_txn] / Swift [Model.isInTxn]. *)
    method in_txn : bool = in_txn

    (* Open an undoable transaction: push the pre-edit checkpoint (the document
       and its paired index) onto the undo stack, exactly like snapshot but
       WITHOUT clearing the redo stack — the redo-clear happens at commit_txn,
       so a new edit clears redo only once the edit commits. Idempotent while a
       transaction is already open (a nested begin_txn is a no-op), so many
       edits can ride one checkpoint. *)
    method begin_txn =
      if not in_txn then begin
        undo_stack <- (doc, id_index) :: undo_stack;
        if List.length undo_stack > max_undo then
          undo_stack <- List.filteri (fun i _ -> i < max_undo) undo_stack;
        in_txn <- true;
        (* Capture the current document as the pre-edit checkpoint so commit_txn
           can detect a zero-net-change transaction. *)
        pending_txn <- Some (None, [], doc)
      end

    (* Finalize the open transaction. No-op rule (OP_LOG.md section 5/9): a
       zero-net-change transaction is not journaled and its undo checkpoint is
       dropped (so it leaves no undo step, keeping the undo stack and the
       journal cursor in lock-step). Fast path: physical identity of the
       current document against the checkpoint; else a canonical
       document_to_test_json byte compare (the same canonicalization the
       cross-language gate uses). Otherwise append one transaction (the
       deterministic [txn-N] id), truncating the journal's redo tail at
       journal_head, and clear redo. No-op when no transaction is open. *)
    method commit_txn =
      if in_txn then begin
        in_txn <- false;
        let pending = pending_txn in
        pending_txn <- None;
        let checkpoint = match pending with
          | Some (_, _, chk) -> Some chk
          | None ->
            (match undo_stack with (chk, _) :: _ -> Some chk | [] -> None)
        in
        let no_net_change =
          match checkpoint with
          | None -> false
          | Some chk ->
            chk == doc
            (* CANONICALLY-INVISIBLE FIELDS (OP_LOG.md section 9 Phase P6
               follow-up): [document_to_test_json] deliberately OMITS some
               authoritative fields — notably the Path [stroke_brush] /
               [stroke_brush_overrides] brush bindings — to keep the
               cross-language byte-gate compatible with legacy fixtures. That
               makes the JSON compare BLIND to a transaction whose ONLY net
               change is a brush edit (e.g. set_attr_on_selection fired on an
               already-selected path, where the selection does not change),
               which would otherwise be dropped here: neither journaled NOR
               given an undo step. So when the JSON says "no change" we
               additionally compare the authoritative element trees ([layers]
               plus the [symbols] master store, the only homes of brush-bearing
               Paths) via the polymorphic [=], which DOES see those fields. A
               transaction is a no-op only if BOTH the canonical JSON and the
               structural compare agree it changed nothing; any
               canonically-invisible field edit keeps it. Mirrors the Rust
               [Model::commit_txn] / Swift [Model.commitTxn]. *)
            || (Test_json.document_to_test_json chk
                = Test_json.document_to_test_json doc
                && chk.Document.layers = doc.Document.layers
                && chk.Document.symbols = doc.Document.symbols)
        in
        if no_net_change then begin
          (* Drop the no-op checkpoint; leave redo and the journal untouched. *)
          (match undo_stack with _ :: rest -> undo_stack <- rest | [] -> ())
        end else begin
          (* ALT-COPY PATH B (selection.yaml, Alt pressed MID-drag): the
             pre-copy drag moved the original, then doc.preview.restore reverted
             it OUTSIDE the journal before doc.copy_selection ran. That leaves
             the tip move dead (its target round-tripped) yet still journaled.
             Drop it first, so the copy lands on the pre-drag checkpoint as the
             sole entry -- one undo step, and a journal that still replays to
             the live document. The returned bool is ignored here (the no-op /
             coalesce / append decision below does not depend on it); it exists
             for symmetry with the Rust helper and for direct testability. *)
          ignore (_self#drop_round_tripped_move_before_copy pending);
          if _self#try_coalesce_drag_frame pending then begin
          (* Per-frame drag coalescing (OP_LOG.md section 9 follow-up). The
             just-finalized pending transaction was absorbed into the journal
             tip in place (its summed delta) and its redundant per-frame undo
             checkpoint was popped, so the undo stack and the journal cursor
             stay in lock-step (one continuous drag == one undo step). Nothing
             more to do here: no new journal entry, no cursor move. The no-op
             rule above runs FIRST, so a zero-delta single frame is already
             dropped before we ever reach coalescing. *)
          ()
        end else begin
          (* A real edit invalidates redo on BOTH representations: clear the
             redo snapshot stack and truncate the journal's redo tail at
             journal_head (the relocated "new edit invalidates redo"
             semantics — OP_LOG.md section 5). *)
          redo_stack <- [];
          op_journal <- List.filteri (fun i _ -> i < journal_head) op_journal;
          let parent = match List.rev op_journal with
            | last :: _ -> Some last.Op_log.txn_id
            | [] -> None
          in
          let name, ops_rev = match pending with
            | Some (n, ops_rev, _) -> n, ops_rev
            | None -> None, []
          in
          let txn = {
            Op_log.txn_id = Printf.sprintf "txn-%d" next_txn_counter;
            ops = List.rev ops_rev;
            name;
            summary = None;
            actor = Op_log.actor_artist;
            parent;
            lamport = next_txn_counter;
            label = None;
          } in
          next_txn_counter <- next_txn_counter + 1;
          op_journal <- op_journal @ [txn];
          journal_head <- List.length op_journal
          end
        end
      end

    (* Per-frame drag coalescing (OP_LOG.md section 9 follow-up). Called by
       [commit_txn] AFTER the no-op early-return and BEFORE the normal
       truncate/append: try to merge the just-finalized pending transaction
       [T_new] into the journal tip [T_prev = op_journal[journal_head - 1]] as a
       summed-delta translate. Returns [true] iff it coalesced (the caller then
       does nothing more — the pending txn was absorbed, no new journal entry,
       and the redundant undo checkpoint was popped so the undo stack stays in
       lock-step with the journal cursor: one continuous drag == one undo step).

       A live drag commits ONE transaction PER FRAME: selection.yaml fires
       doc.snapshot only on the first mousemove, and each subsequent
       on_mousemove is its own run_effects batch that begin_txns + commits. So a
       drag of N frames lands as N consecutive single-op move transactions in
       the journal — verbose, and N separate undo steps. This is the ONLY
       correct layer to merge them: record_op only ever sees the ops WITHIN one
       pending transaction (a drag puts each frame move in a SEPARATE pending
       txn), so the two consecutive drag moves only become adjacent HERE, where
       the pending txn is finalized against the journal tip.

       PREDICATE (all must hold):
        (guard) we are at the journal TIP: [journal_head = List.length
          op_journal]. If the user undid then dragged, [journal_head < len], and
          the tail about to be truncated is NOT a valid merge target.
        (a) [T_new] has EXACTLY ONE op whose verb is a coalescable translate
            ([move_selection] or [move_by_ids]).
        (b) [T_prev]'s last op exists and has the SAME verb.
        (c) targets BYTE-EQUAL ([T_prev] last op targets = [T_new] op targets;
            for [move_by_ids] the params ids array is also byte-equal, though
            predicate e already covers it).
        (d) SAME NAME ([T_prev].name = [T_new].name) — drag-scoped, so two
            DELIBERATE separate same-target moves stay distinct undo steps.
        (e) the ONLY params that differ are dx/dy (strip dx/dy from both param
            objects and require the remainder byte-equal).

       MERGE: sum [T_new]'s dx/dy into [T_prev]'s last op params in place and
       drop [T_new]. POP the redundant per-frame undo checkpoint (the same
       mechanism the no-op rule uses), so after the pop [undo_stack] head is
       [T_prev]'s ORIGIN checkpoint and the undo stack stays in lock-step with
       the unchanged journal length.

       NET-ZERO WHOLE-DRAG: if the merged delta is exactly (0,0) AND the live
       document now byte-matches [T_prev]'s origin checkpoint (the whole drag
       round-tripped), drop [T_prev] too and pop its origin checkpoint — the
       no-op rule extended across the coalesced run, leaving NO journal entry and
       NO undo step. (The bare-frame case, where [T_prev] also carries a
       select_rect that changed selection, does NOT match the origin, so it
       stays coalesced to one txn rather than dropping.) COALESCABLE is EXACTLY
       move_selection / move_by_ids; copy_selection / copy_by_ids NEVER coalesce
       (a copy is non-additive); the selection-only verbs are run boundaries;
       smooth / eraser / transform are out of scope. Mirrors the Rust
       [Model::try_coalesce_drag_frame]. *)
    method private try_coalesce_drag_frame pending : bool =
      let coalescable v = v = "move_selection" || v = "move_by_ids" in
      (* Strip dx/dy from a params object; the remainder must byte-equal. *)
      let strip (p : Yojson.Safe.t) : Yojson.Safe.t =
        match p with
        | `Assoc fields ->
          `Assoc (List.filter (fun (k, _) -> k <> "dx" && k <> "dy") fields)
        | other -> other
      in
      let num (p : Yojson.Safe.t) (key : string) : float =
        match p with
        | `Assoc fields ->
          (match List.assoc_opt key fields with
           | Some (`Float f) -> f
           | Some (`Int i) -> float_of_int i
           | _ -> 0.0)
        | _ -> 0.0
      in
      let ids_of (p : Yojson.Safe.t) : Yojson.Safe.t =
        match p with
        | `Assoc fields ->
          (match List.assoc_opt "ids" fields with Some v -> v | None -> `Null)
        | _ -> `Null
      in
      (* (guard) only at the journal tip; a post-undo drag must not merge into
         the about-to-be-truncated redo tail. *)
      if journal_head <> List.length op_journal then false
      else
        (* (a) T_new is exactly one coalescable move op. *)
        let new_op = match pending with
          | Some (_, [ op ], _) when coalescable op.Op_log.op -> Some op
          | _ -> None
        in
        match new_op with
        | None -> false
        | Some new_op ->
          let new_name = match pending with Some (n, _, _) -> n | None -> None in
          (* T_prev = the journal tip; its LAST op is the merge target. *)
          (match List.rev op_journal with
           | [] -> false
           | prev :: _ ->
             (match List.rev prev.Op_log.ops with
              | [] -> false
              | prev_op :: _ ->
                let copy_verb v =
                  v = "copy_selection" || v = "copy_by_ids" in
                (* (d) same drag-scoped name guards BOTH branches below. *)
                if prev.Op_log.name <> new_name then false
                (* Branch A: a drag-move that CONTINUES a just-laid copy. The
                   alt-drag-copy gesture (selection.yaml) journals copy_selection
                   and then drags the new duplicate with move_selection frames.
                   The copy resulting selection is what each move translates, so
                   summing the move delta into the copy op own dx/dy reproduces
                   the final position as ONE op and ONE undo step. We do NOT
                   compare targets here: the copy op records the SOURCE ids (the
                   duplicate is born id-less), while the move records the COPY
                   ids, so they legitimately differ for id-bearing elements --
                   the journal-tip plus same-name plus single-move adjacency is
                   the drag-continuation signal (mirrors the move+move case,
                   where the gesture boundary is likewise the discriminator).
                   Runs BEFORE the same-verb move+move branch. Mirrors the Rust
                   [try_coalesce_drag_frame] Branch A. *)
                else if copy_verb prev_op.Op_log.op then begin
                  let new_dx = num new_op.Op_log.params "dx" in
                  let new_dy = num new_op.Op_log.params "dy" in
                  let merged_dx = num prev_op.Op_log.params "dx" +. new_dx in
                  let merged_dy = num prev_op.Op_log.params "dy" +. new_dy in
                  let merged_params = match prev_op.Op_log.params with
                    | `Assoc fields ->
                      `Assoc (List.map (fun (k, v) ->
                        if k = "dx" then (k, `Float merged_dx)
                        else if k = "dy" then (k, `Float merged_dy)
                        else (k, v)) fields)
                    | other -> other
                  in
                  let merged_op = { prev_op with Op_log.params = merged_params } in
                  let tip_idx = List.length op_journal - 1 in
                  let n_prev_ops = List.length prev.Op_log.ops in
                  let new_prev_ops =
                    List.mapi (fun i o ->
                      if i = n_prev_ops - 1 then merged_op else o)
                      prev.Op_log.ops
                  in
                  let merged_prev =
                    { prev with Op_log.ops = new_prev_ops } in
                  op_journal <- List.mapi (fun i t ->
                    if i = tip_idx then merged_prev else t) op_journal;
                  (* Drop the per-frame checkpoint -- this frame adds no undo
                     step. *)
                  (match undo_stack with _ :: rest -> undo_stack <- rest | [] -> ());
                  true
                end
                (* Branch B: the original move+move fold (same verb).
                   (b) same verb; (c) byte-equal targets (and, for move_by_ids,
                   byte-equal ids); (e) only dx/dy differ. *)
                else if prev_op.Op_log.op <> new_op.Op_log.op then false
                else if prev_op.Op_log.targets <> new_op.Op_log.targets then false
                else if new_op.Op_log.op = "move_by_ids"
                        && ids_of prev_op.Op_log.params
                           <> ids_of new_op.Op_log.params then false
                else if strip prev_op.Op_log.params
                        <> strip new_op.Op_log.params then false
                else begin
                  (* MERGE: sum dx/dy into T_prev's last op params in place. *)
                  let new_dx = num new_op.Op_log.params "dx" in
                  let new_dy = num new_op.Op_log.params "dy" in
                  let merged_dx = num prev_op.Op_log.params "dx" +. new_dx in
                  let merged_dy = num prev_op.Op_log.params "dy" +. new_dy in
                  let merged_params = match prev_op.Op_log.params with
                    | `Assoc fields ->
                      `Assoc (List.map (fun (k, v) ->
                        if k = "dx" then (k, `Float merged_dx)
                        else if k = "dy" then (k, `Float merged_dy)
                        else (k, v)) fields)
                    | other -> other
                  in
                  let merged_op = { prev_op with Op_log.params = merged_params } in
                  (* Rebuild the tip with its last op replaced (the rest
                     unchanged), keeping the journal forward-ordered. *)
                  let tip_idx = List.length op_journal - 1 in
                  let n_prev_ops = List.length prev.Op_log.ops in
                  let new_prev_ops =
                    List.mapi (fun i o ->
                      if i = n_prev_ops - 1 then merged_op else o)
                      prev.Op_log.ops
                  in
                  let merged_prev =
                    { prev with Op_log.ops = new_prev_ops } in
                  op_journal <- List.mapi (fun i t ->
                    if i = tip_idx then merged_prev else t) op_journal;
                  (* Pop the redundant per-frame undo checkpoint (the same
                     mechanism the no-op rule uses): this frame contributes no
                     new undo step, so the undo stack stays in lock-step with the
                     (unchanged) journal length. After this pop, [undo_stack]
                     head is T_prev's ORIGIN checkpoint. *)
                  (match undo_stack with _ :: rest -> undo_stack <- rest | [] -> ());
                  (* NET-ZERO WHOLE-DRAG: the coalesced run round-tripped. If the
                     merged delta is exactly (0,0) AND the live document now
                     byte-matches T_prev's origin checkpoint, drop T_prev too and
                     pop its origin checkpoint — a round-trip drag leaves NO
                     journal entry and NO undo step. *)
                  if merged_dx = 0.0 && merged_dy = 0.0 then begin
                    let round_tripped = match undo_stack with
                      | (chk, _) :: _ ->
                        Test_json.document_to_test_json chk
                        = Test_json.document_to_test_json doc
                        && chk.Document.layers = doc.Document.layers
                        && chk.Document.symbols = doc.Document.symbols
                      | [] -> false
                    in
                    if round_tripped then begin
                      (* Drop the now-empty tip txn and pop its origin
                         checkpoint, keeping journal_head in lock-step. *)
                      let drop_idx = List.length op_journal - 1 in
                      op_journal <-
                        List.filteri (fun i _ -> i <> drop_idx) op_journal;
                      journal_head <- List.length op_journal;
                      (match undo_stack with
                       | _ :: rest -> undo_stack <- rest | [] -> ())
                    end
                  end;
                  true
                end))

    (* ALT-COPY PATH B cleanup (called by [commit_txn] just before the
       coalesce/append, when the committing transaction [T_new] is a
       copy_selection / copy_by_ids). The Selection tool mid-drag-Alt gesture
       (selection.yaml PATH B) drags the original first -- journaling a
       move_selection -- then on Alt-press does doc.preview.restore (which
       reverts that move in the DOCUMENT but NOT in the journal, because
       restore_preview_snapshot writes outside any transaction) followed by
       doc.copy_selection. The journal tip is therefore a move whose target
       round-tripped: it leaves no net change yet still occupies an undo step,
       and replaying it would move the original the copy was supposed to leave
       behind. Detect that exact shape and drop the dead move, so the copy lands
       on the pre-drag checkpoint as the sole entry -- keeping the whole gesture
       ONE undo step and the journal faithful to the live document.

       Fires ONLY when (guard) we are at the journal tip, [T_new] is a single
       copy op, the tip is a single-named move with the SAME drag-scoped name,
       the undo stack has at least 2 checkpoints, and -- the discriminating test
       -- the copy ORIGIN checkpoint (the document just before the copy, i.e.
       after the restore; top of the undo stack) is BYTE-EQUAL to the tip move
       ORIGIN checkpoint (the pre-drag document; second from top). Equality
       means the move genuinely round-tripped (a real, kept move would leave the
       copy origin different from the pre-move state, so the rule correctly
       leaves it as its own undo step). Reuses the same checkpoint-equality
       compare as the no-op rule and the net-zero whole-drag block (canonical
       document_to_test_json plus the layers / symbols structural compare).

       When all hold: pop the dead move off the journal, set journal_head to the
       journal length, and remove the now-duplicate top checkpoint (leaving the
       move identical origin as the copy checkpoint). The caller then appends the
       copy as the sole entry. Returns whether it fired (the caller ignores the
       bool; kept for symmetry and direct testability). Mirrors the Rust
       [Model::drop_round_tripped_move_before_copy]. *)
    method private drop_round_tripped_move_before_copy pending : bool =
      let copy_verb v = v = "copy_selection" || v = "copy_by_ids" in
      let move_verb v = v = "move_selection" || v = "move_by_ids" in
      (* (guard) only at the journal tip. *)
      if journal_head <> List.length op_journal then false
      else
        (* T_new is exactly one copy op. *)
        let new_copy = match pending with
          | Some (_, [ op ], _) when copy_verb op.Op_log.op -> Some op
          | _ -> None
        in
        match new_copy with
        | None -> false
        | Some _ ->
          let new_name = match pending with Some (n, _, _) -> n | None -> None in
          (* Tip is a single move with the same drag-scoped name. *)
          (match List.rev op_journal with
           | [] -> false
           | prev :: _ ->
             if prev.Op_log.name <> new_name then false
             else match prev.Op_log.ops with
               | [ tip_op ] when move_verb tip_op.Op_log.op ->
                 (* The move round-tripped iff the copy ORIGIN checkpoint (top of
                    the undo stack) byte-equals the move ORIGIN checkpoint
                    (second from top). begin_txn pushed the copy origin when the
                    copy opened; the move origin is directly beneath it (the move
                    already coalesced to a single entry, so it owns exactly one
                    checkpoint). *)
                 (match undo_stack with
                  | (copy_origin, _) :: (move_origin, move_index) :: rest ->
                    let round_tripped =
                      Test_json.document_to_test_json copy_origin
                      = Test_json.document_to_test_json move_origin
                      && copy_origin.Document.layers = move_origin.Document.layers
                      && copy_origin.Document.symbols
                         = move_origin.Document.symbols
                    in
                    if not round_tripped then false
                    else begin
                      (* Drop the dead move from the journal and remove the
                         now-duplicate copy-origin checkpoint (the top), leaving
                         the move identical origin as the copy checkpoint. The
                         caller then appends the copy at journal_head. *)
                      let drop_idx = List.length op_journal - 1 in
                      op_journal <-
                        List.filteri (fun i _ -> i <> drop_idx) op_journal;
                      journal_head <- List.length op_journal;
                      undo_stack <- (move_origin, move_index) :: rest;
                      true
                    end
                  | _ -> false)
               | _ -> false)

    (* Roll back the open transaction to its checkpoint, discarding it (no redo
       entry, no journal entry, no cursor move). A begin_txn immediately
       followed by abort_txn is a no-op. *)
    method abort_txn =
      if in_txn then begin
        in_txn <- false;
        pending_txn <- None;
        (match undo_stack with
         | (prev_doc, prev_index) :: rest ->
           undo_stack <- rest;
           doc <- prev_doc;
           id_index <- prev_index;
           generation <- generation + 1;
           _self#assert_index_matches_rebuild;
           List.iter (fun f -> f doc) listeners
         | [] -> ())
      end

    (* Run [body] inside a transaction: begin_txn, [body ()], commit_txn. The
       scoped one-shot form of the bracket. *)
    method with_txn (body : unit -> unit) =
      _self#begin_txn;
      body ();
      _self#commit_txn

    (* Append a primitive op to the open transaction's record (OP_LOG.md
       section 5): the op_apply path calls this as each op is applied, so
       commit_txn finalizes a transaction whose [ops] replay to the same
       document — the checkpoint_equivalence gate (section 6). No-op when no
       transaction is open (an op applied outside any bracket is not
       journaled), so this is safe to call unconditionally from the
       dispatcher. The ops are accumulated reversed and flipped at commit. *)
    method record_op (op : Op_log.primitive_op) =
      match pending_txn with
      | Some (n, ops_rev, chk) -> pending_txn <- Some (n, op :: ops_rev, chk)
      | None -> ()

    (* Set the open transaction's artist/AI-legible name (an actions.yaml
       verb). No-op when no transaction is open. *)
    method name_txn (name : string) =
      match pending_txn with
      | Some (_, ops_rev, chk) -> pending_txn <- Some (Some name, ops_rev, chk)
      | None -> ()

    (* ── Versioning labels (OP_LOG.md Increment 3a / VISION.md 6.9) ─────────

       label_version marks the current document state as a named version point.
       It stamps [name] onto the journal's transaction at the current head (the
       [label] field reserved in Increment 2) so the label serializes into the
       journal artifact, and stores the document + paired index (so
       restore_version is O(1) and sound even though production transactions are
       opaque). Naming is idempotent: re-labeling an existing name re-points it
       here. restore_version restores the document to a named version as an
       ordinary undoable edit (one transaction), so it stays on the linear
       undo/redo timeline rather than jumping the cursor non-linearly; the no-op
       rule makes restoring to the already-current state a no-op. Mirrors the
       Rust [label_version] / [restore_version] / [versions]. *)

    (* The named version points, in creation order. Test/inspection accessor. *)
    method versions : version list = versions

    method label_version (name : string) =
      (* Stamp the label onto the most-recent committed transaction, if any
         (a version at the origin labels no transaction). The journal is stored
         oldest-first, so the transaction at the current head is index
         [journal_head - 1]. *)
      if journal_head > 0 then
        op_journal <- List.mapi (fun i (t : Op_log.transaction) ->
          if i = journal_head - 1 then { t with Op_log.label = Some name }
          else t
        ) op_journal;
      let version = {
        label = name;
        journal_head;
        document = doc;
        id_index;
      } in
      (* Re-labeling an existing name re-points it; otherwise append in
         creation order (newest last). *)
      if List.exists (fun v -> v.label = name) versions then
        versions <- List.map (fun v ->
          if v.label = name then version else v) versions
      else
        versions <- versions @ [version]

    method restore_version (name : string) : bool =
      match List.find_opt (fun v -> v.label = name) versions with
      | None -> false
      | Some version ->
        let target_doc = version.document in
        _self#with_txn (fun () ->
          _self#name_txn (Printf.sprintf "restore version %s" name);
          _self#set_document target_doc);
        true

    method default_fill = default_fill
    method set_default_fill (f : Element.fill option) = default_fill <- f
    method default_stroke = default_stroke
    method set_default_stroke (s : Element.stroke option) = default_stroke <- s
    method recent_colors = recent_colors
    method set_recent_colors (c : string list) = recent_colors <- c

    method current_edit_session = current_edit_session
    method set_current_edit_session (s : edit_session_ref option) =
      current_edit_session <- s

    method editing_target = editing_target
    method set_editing_target (t : editing_target) =
      editing_target <- t

    method mask_isolation_path = mask_isolation_path
    method set_mask_isolation_path (p : int list option) =
      mask_isolation_path <- p

    (* View state accessors per ZOOM_TOOL.md State persistence. *)
    method zoom_level = zoom_level
    method set_zoom_level (z : float) = zoom_level <- z
    method view_offset_x = view_offset_x
    method set_view_offset_x (x : float) = view_offset_x <- x
    method view_offset_y = view_offset_y
    method set_view_offset_y (y : float) = view_offset_y <- y
    method viewport_w = viewport_w
    method set_viewport_w (w : float) = viewport_w <- w
    method viewport_h = viewport_h
    method set_viewport_h (h : float) = viewport_h <- h

    (* Center the canvas view on the current artboard using the
       stored viewport_w / viewport_h. If the artboard fits at the
       current zoom, set pan to center it; otherwise apply
       fit-inside semantics with 20px screen-space padding.
       Per ZOOM_TOOL.md Document-open behavior. *)
    method center_view_on_current_artboard =
      let abs_list = doc.Document.artboards in
      if abs_list <> [] && viewport_w > 0.0 && viewport_h > 0.0 then begin
        let ab = List.hd abs_list in
        let abw = ab.Artboard.width in
        let abh = ab.Artboard.height in
        let abx = ab.Artboard.x in
        let aby = ab.Artboard.y in
        let fits =
          abw *. zoom_level <= viewport_w
          && abh *. zoom_level <= viewport_h
        in
        if fits then begin
          view_offset_x <-
            viewport_w /. 2.0 -. (abx +. abw /. 2.0) *. zoom_level;
          view_offset_y <-
            viewport_h /. 2.0 -. (aby +. abh /. 2.0) *. zoom_level
        end else begin
          let pad = 20.0 in
          let avail_w = viewport_w -. 2.0 *. pad in
          let avail_h = viewport_h -. 2.0 *. pad in
          if avail_w > 0.0 && avail_h > 0.0 then begin
            let z_fit = min (avail_w /. abw) (avail_h /. abh) in
            let z_clamped = max 0.1 (min 64.0 z_fit) in
            zoom_level <- z_clamped;
            view_offset_x <-
              viewport_w /. 2.0 -. (abx +. abw /. 2.0) *. z_clamped;
            view_offset_y <-
              viewport_h /. 2.0 -. (aby +. abh /. 2.0) *. z_clamped
          end
        end
      end
  end

let create ?document ?filename () = new model ?document ?filename ()
