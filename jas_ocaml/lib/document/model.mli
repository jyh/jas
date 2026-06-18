(** Observable model that holds the current document. *)

(** Advance the [Untitled-N] counter so a subsequent [fresh_filename]
    won't collide with any name in [existing_filenames]. Called by
    session-restore so freshly-created tabs don't reuse a restored
    [Untitled-N] slot. *)
val advance_next_untitled_past : string list -> unit

(** Structural view of an in-place text-editing session, exposed to
    callers (the Character panel pipeline) that need to detect an
    active bare-caret editor and prime its next-typed-character
    state. See [lib/tools/text_edit.ml] for the concrete session. *)
type edit_session_ref = <
  has_selection : bool;
  selection_range : int * int;
  path : int list;
  set_pending_override : Element.tspan -> unit;
  clear_pending_override : unit -> unit
>

(** The target that drawing tools operate on. The default is the
    document's normal content; mask-editing mode switches the
    target to a specific element's mask subtree. OPACITY.md
    \167Preview interactions. *)
type editing_target =
  | Content
  | Mask of int list

(** A named version point (OP_LOG.md Increment 3a / VISION.md section 6.9).
    Stores the document + paired index at a labeled journal cursor position so
    {!model.restore_version} is O(1) and sound regardless of whether the
    intervening transactions carry replayable ops. *)
type version = {
  label : string;
  journal_head : int;
  document : Document.document;
  id_index : Live.id_index;
}

class model : ?document:Document.document -> ?filename:string -> unit -> object
  method document : Document.document

  (** Persistent id->element index paired with the current document
      (REFERENCE_GRAPH.md section 2.4, Phase 4b). Always equal to a
      from-scratch rebuild of {!document} (held to a debug [assert] gate at
      every update). The canvas paint path reads this via
      [Live.resolver_of_index] instead of rebuilding the index per frame;
      undo/redo carry it in O(1). *)
  method id_index : Live.id_index

  (** Monotonic modification generation (Phase 4c). Bumped on every path that
      replaces the document; read at the paint entry to epoch the
      reference-geometry recompute cache. Mirrors the Rust [Model.generation]. *)
  method generation : int
  method set_document : Document.document -> unit
  method filename : string
  method set_filename : string -> unit
  method on_document_changed : (Document.document -> unit) -> unit
  method on_filename_changed : (string -> unit) -> unit
  method snapshot : unit
  method capture_preview_snapshot : unit
  method restore_preview_snapshot : unit
  method clear_preview_snapshot : unit
  method has_preview_snapshot : bool
  method undo : unit
  method redo : unit
  method is_modified : bool
  method mark_saved : unit
  method can_undo : bool
  method can_redo : bool

  (** The Transaction journal (OP_LOG.md Increment 2, full journal). The
      ordered transaction list, built by {!begin_txn} / {!commit_txn} /
      {!record_op} (the op_apply / harness path). Test/inspection accessor. *)
  method journal : Op_log.transaction list

  (** The journal cursor — the count of transactions currently applied
      (0..=journal length). {!commit_txn} truncates the journal here and
      appends; {!undo} / {!redo} move it. Drives {!is_modified}. *)
  method journal_head : int

  (** Open an undoable transaction: push the pre-edit checkpoint onto the undo
      stack (like {!snapshot} but WITHOUT clearing redo — that moves to
      {!commit_txn}). Idempotent while a transaction is already open. *)
  method begin_txn : unit

  (** Finalize the open transaction. No-op rule (OP_LOG.md section 5/9): a
      zero-net-change transaction is not journaled and its undo checkpoint is
      dropped. Otherwise append one transaction (the deterministic [txn-N]
      id), truncating the journal's redo tail at {!journal_head}, and clear
      redo. No-op when no transaction is open. *)
  method commit_txn : unit

  (** Roll back the open transaction to its checkpoint, discarding it (no redo
      entry, no journal entry, no cursor move). *)
  method abort_txn : unit

  (** Run the body inside a transaction: {!begin_txn}, body, {!commit_txn}. *)
  method with_txn : (unit -> unit) -> unit

  (** Append a primitive op to the open transaction's record (OP_LOG.md
      section 5). No-op when no transaction is open. *)
  method record_op : Op_log.primitive_op -> unit

  (** Set the open transaction's artist/AI-legible name (an actions.yaml
      verb). No-op when no transaction is open. *)
  method name_txn : string -> unit

  (** The named version points, in creation order (newest last). OP_LOG.md
      Increment 3a. Test/inspection accessor. *)
  method versions : version list

  (** Mark the current document state as a named version point (OP_LOG.md
      Increment 3a / VISION.md section 6.9). Stamps the label onto the journal's
      transaction at the current head (so it serializes into the journal
      artifact) and stores the document + paired index. Re-labeling an existing
      name re-points it. *)
  method label_version : string -> unit

  (** Restore the document to a named version as an ordinary undoable edit (one
      transaction), so it stays on the linear undo/redo timeline; restoring to
      the already-current state is a no-op. Returns [false] if no such version
      exists. *)
  method restore_version : string -> bool
  method default_fill : Element.fill option
  method set_default_fill : Element.fill option -> unit
  method default_stroke : Element.stroke option
  method set_default_stroke : Element.stroke option -> unit
  method recent_colors : string list
  method set_recent_colors : string list -> unit
  method current_edit_session : edit_session_ref option
  method set_current_edit_session : edit_session_ref option -> unit
  method editing_target : editing_target
  method set_editing_target : editing_target -> unit
  method mask_isolation_path : int list option
  method set_mask_isolation_path : int list option -> unit
  method zoom_level : float
  method set_zoom_level : float -> unit
  method view_offset_x : float
  method set_view_offset_x : float -> unit
  method view_offset_y : float
  method set_view_offset_y : float -> unit
  method viewport_w : float
  method set_viewport_w : float -> unit
  method viewport_h : float
  method set_viewport_h : float -> unit
  method center_view_on_current_artboard : unit
end

val create : ?document:Document.document -> ?filename:string -> unit -> model
