(** Observable model that holds the current document. *)

class model : ?document:Document.document -> unit -> object
  method document : Document.document
  method set_document : Document.document -> unit
  method on_document_changed : (Document.document -> unit) -> unit
end

val create : ?document:Document.document -> unit -> model
