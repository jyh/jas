(** Observable model that holds the current document. *)

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

class model : ?document:Document.document -> ?filename:string -> unit -> object
  method document : Document.document
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
