(** Observable model that holds the current document. *)

class model : ?document:Document.document -> unit -> object
  method document : Document.document
  method set_document : Document.document -> unit
  method on_document_changed : (Document.document -> unit) -> unit
  method snapshot : unit
  method undo : unit
  method redo : unit
  method can_undo : bool
  method can_redo : bool
end

val create : ?document:Document.document -> unit -> model
