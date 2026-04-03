(** Observable model that holds the current document.

    Views register callbacks via on_document_changed to be notified
    whenever the document is replaced. *)

class model ?(document = Document.make_document []) () =
  object (_self)
    val mutable doc = document
    val mutable listeners : (Document.document -> unit) list = []

    method document = doc

    method set_document (d : Document.document) =
      doc <- d;
      List.iter (fun f -> f doc) listeners

    method on_document_changed (f : Document.document -> unit) =
      listeners <- f :: listeners
  end

let create ?document () = new model ?document ()
