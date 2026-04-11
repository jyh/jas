(** Observable model that holds the current document. *)

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
end

val create : ?document:Document.document -> ?filename:string -> unit -> model
