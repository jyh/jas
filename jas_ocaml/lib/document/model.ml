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

let max_undo = 100

let next_untitled = ref 1

let fresh_filename () =
  let name = Printf.sprintf "Untitled-%d" !next_untitled in
  incr next_untitled;
  name

class model ?(document = Document.default_document ()) ?filename () =
  let filename = match filename with Some f -> f | None -> fresh_filename () in
  object (_self)
    val mutable doc = document
    val mutable saved_doc = document
    val mutable current_filename = filename
    val mutable listeners : (Document.document -> unit) list = []
    val mutable filename_listeners : (string -> unit) list = []
    val mutable undo_stack : Document.document list = []
    val mutable redo_stack : Document.document list = []
    val mutable default_fill : Element.fill option = None
    val mutable default_stroke : Element.stroke option =
      Some (Element.make_stroke Element.black)
    val mutable recent_colors : string list = []
    val mutable current_edit_session : edit_session_ref option = None

    method document = doc

    method filename = current_filename

    method set_filename (f : string) =
      current_filename <- f;
      List.iter (fun cb -> cb f) filename_listeners

    method set_document (d : Document.document) =
      doc <- d;
      List.iter (fun f -> f doc) listeners

    method on_document_changed (f : Document.document -> unit) =
      listeners <- f :: listeners

    method on_filename_changed (f : string -> unit) =
      filename_listeners <- f :: filename_listeners

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

    method is_modified = doc != saved_doc

    method mark_saved =
      saved_doc <- doc;
      List.iter (fun f -> f doc) listeners

    method can_undo = undo_stack <> []
    method can_redo = redo_stack <> []

    method default_fill = default_fill
    method set_default_fill (f : Element.fill option) = default_fill <- f
    method default_stroke = default_stroke
    method set_default_stroke (s : Element.stroke option) = default_stroke <- s
    method recent_colors = recent_colors
    method set_recent_colors (c : string list) = recent_colors <- c

    method current_edit_session = current_edit_session
    method set_current_edit_session (s : edit_session_ref option) =
      current_edit_session <- s
  end

let create ?document ?filename () = new model ?document ?filename ()
