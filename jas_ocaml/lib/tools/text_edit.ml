(** Text editing session. See [text_edit.mli]. *)

type edit_target = Edit_text | Edit_text_path

type snapshot = {
  s_content : string;
  s_insertion : int;
  s_anchor : int;
}

type t = {
  path : int list;
  target : edit_target;
  mutable content : string;
  mutable insertion : int;
  mutable anchor : int;
  mutable drag_active : bool;
  mutable blink_epoch_ms : float;
  mutable undo_stack : snapshot list;
  mutable redo_stack : snapshot list;
}

let create ~path ~target ~content ~insertion =
  let n = String.length content in
  let ins = min insertion n in
  {
    path; target; content;
    insertion = ins; anchor = ins;
    drag_active = false; blink_epoch_ms = 0.0;
    undo_stack = []; redo_stack = [];
  }

let path t = t.path
let target t = t.target
let content t = t.content
let insertion t = t.insertion
let anchor t = t.anchor
let set_drag_active t b = t.drag_active <- b
let drag_active t = t.drag_active
let blink_epoch_ms t = t.blink_epoch_ms
let set_blink_epoch_ms t v = t.blink_epoch_ms <- v

let has_selection t = t.insertion <> t.anchor

let selection_range t = Text_layout.ordered_range t.insertion t.anchor

let snapshot t =
  let s = { s_content = t.content; s_insertion = t.insertion; s_anchor = t.anchor } in
  t.undo_stack <- s :: t.undo_stack;
  t.redo_stack <- [];
  if List.length t.undo_stack > 200 then
    t.undo_stack <- List.filteri (fun i _ -> i < 200) t.undo_stack

let undo t =
  match t.undo_stack with
  | [] -> ()
  | prev :: rest ->
    t.undo_stack <- rest;
    t.redo_stack <- { s_content = t.content; s_insertion = t.insertion; s_anchor = t.anchor } :: t.redo_stack;
    t.content <- prev.s_content;
    t.insertion <- prev.s_insertion;
    t.anchor <- prev.s_anchor

let redo t =
  match t.redo_stack with
  | [] -> ()
  | nxt :: rest ->
    t.redo_stack <- rest;
    t.undo_stack <- { s_content = t.content; s_insertion = t.insertion; s_anchor = t.anchor } :: t.undo_stack;
    t.content <- nxt.s_content;
    t.insertion <- nxt.s_insertion;
    t.anchor <- nxt.s_anchor

let delete_selection_inner t =
  let (lo, hi) = selection_range t in
  let before = String.sub t.content 0 lo in
  let after = String.sub t.content hi (String.length t.content - hi) in
  t.content <- before ^ after;
  t.insertion <- lo;
  t.anchor <- lo

let insert t text =
  snapshot t;
  if has_selection t then delete_selection_inner t;
  let before = String.sub t.content 0 t.insertion in
  let after = String.sub t.content t.insertion (String.length t.content - t.insertion) in
  t.content <- before ^ text ^ after;
  t.insertion <- t.insertion + String.length text;
  t.anchor <- t.insertion

let backspace t =
  if has_selection t then begin
    snapshot t;
    delete_selection_inner t
  end else if t.insertion > 0 then begin
    snapshot t;
    let before = String.sub t.content 0 (t.insertion - 1) in
    let after = String.sub t.content t.insertion (String.length t.content - t.insertion) in
    t.content <- before ^ after;
    t.insertion <- t.insertion - 1;
    t.anchor <- t.insertion
  end

let delete_forward t =
  if has_selection t then begin
    snapshot t;
    delete_selection_inner t
  end else if t.insertion < String.length t.content then begin
    snapshot t;
    let before = String.sub t.content 0 t.insertion in
    let after = String.sub t.content (t.insertion + 1) (String.length t.content - t.insertion - 1) in
    t.content <- before ^ after;
    t.anchor <- t.insertion
  end

let set_insertion t pos ~extend =
  let n = String.length t.content in
  t.insertion <- max 0 (min pos n);
  if not extend then t.anchor <- t.insertion

let select_all t =
  t.anchor <- 0;
  t.insertion <- String.length t.content

let copy_selection t =
  if not (has_selection t) then None
  else
    let (lo, hi) = selection_range t in
    Some (String.sub t.content lo (hi - lo))

let apply_to_document t doc =
  try
    let elem = Document.get_element doc t.path in
    match t.target, elem with
    | Edit_text, Element.Text r ->
      let new_elem = Element.Text { r with content = t.content } in
      Some (Document.replace_element doc t.path new_elem)
    | Edit_text_path, Element.Text_path r ->
      let new_elem = Element.Text_path { r with content = t.content } in
      Some (Document.replace_element doc t.path new_elem)
    | _ -> None
  with _ -> None

let empty_text_elem x y w h =
  Element.make_text
    ~text_width:w ~text_height:h
    ~fill:(Some Element.{ fill_color = { r = 0.0; g = 0.0; b = 0.0; a = 1.0 } })
    x y ""

let empty_text_path_elem d =
  Element.make_text_path
    ~fill:(Some Element.{ fill_color = { r = 0.0; g = 0.0; b = 0.0; a = 1.0 } })
    d ""
