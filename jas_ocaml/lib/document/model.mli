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

class model : ?document:Document.document -> ?filename:string -> unit -> object
  method document : Document.document
  method set_document : Document.document -> unit
  method filename : string
  method set_filename : string -> unit
  method on_document_changed : (Document.document -> unit) -> unit
  method on_filename_changed : (string -> unit) -> unit
  method snapshot : unit
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
end

val create : ?document:Document.document -> ?filename:string -> unit -> model
