(** Observable model that holds the current document.

    Views register callbacks via on_document_changed to be notified
    whenever the document is replaced. *)

let max_undo = 100

class model ?(document = Document.default_document ()) () =
  object (_self)
    val mutable doc = document
    val mutable listeners : (Document.document -> unit) list = []
    val mutable undo_stack : Document.document list = []
    val mutable redo_stack : Document.document list = []

    method document = doc

    method set_document (d : Document.document) =
      doc <- d;
      List.iter (fun f -> f doc) listeners

    method on_document_changed (f : Document.document -> unit) =
      listeners <- f :: listeners

    method snapshot =
      undo_stack <- doc :: undo_stack;
      if List.length undo_stack > max_undo then
        undo_stack <- List.filteri (fun i _ -> i < max_undo) undo_stack;
      redo_stack <- []

    method undo =
      match undo_stack with
      | [] -> ()
      | prev :: rest ->
        redo_stack <- doc :: redo_stack;
        undo_stack <- rest;
        doc <- prev;
        List.iter (fun f -> f doc) listeners

    method redo =
      match redo_stack with
      | [] -> ()
      | next :: rest ->
        undo_stack <- doc :: undo_stack;
        redo_stack <- rest;
        doc <- next;
        List.iter (fun f -> f doc) listeners

    method can_undo = undo_stack <> []
    method can_redo = redo_stack <> []
  end

let create ?document () = new model ?document ()
