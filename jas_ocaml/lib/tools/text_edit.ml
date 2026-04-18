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
  let n = Text_layout.utf8_char_count content in
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

let char_count t = Text_layout.utf8_char_count t.content

(* Replace a char-indexed range [lo..hi) with [ins]. *)
let splice t lo hi ins =
  let lo_b = Text_layout.char_to_byte t.content lo in
  let hi_b = Text_layout.char_to_byte t.content hi in
  let before = String.sub t.content 0 lo_b in
  let after = String.sub t.content hi_b (String.length t.content - hi_b) in
  t.content <- before ^ ins ^ after

let delete_selection_inner t =
  let (lo, hi) = selection_range t in
  splice t lo hi "";
  t.insertion <- lo;
  t.anchor <- lo

let insert t text =
  snapshot t;
  if has_selection t then delete_selection_inner t;
  splice t t.insertion t.insertion text;
  t.insertion <- t.insertion + Text_layout.utf8_char_count text;
  t.anchor <- t.insertion

let backspace t =
  if has_selection t then begin
    snapshot t;
    delete_selection_inner t
  end else if t.insertion > 0 then begin
    snapshot t;
    splice t (t.insertion - 1) t.insertion "";
    t.insertion <- t.insertion - 1;
    t.anchor <- t.insertion
  end

let delete_forward t =
  if has_selection t then begin
    snapshot t;
    delete_selection_inner t
  end else if t.insertion < char_count t then begin
    snapshot t;
    splice t t.insertion (t.insertion + 1) "";
    t.anchor <- t.insertion
  end

let set_insertion t pos ~extend =
  let n = char_count t in
  t.insertion <- max 0 (min pos n);
  if not extend then t.anchor <- t.insertion

let select_all t =
  t.anchor <- 0;
  t.insertion <- char_count t

let copy_selection t =
  if not (has_selection t) then None
  else
    let (lo, hi) = selection_range t in
    Some (Text_layout.utf8_sub t.content lo (hi - lo))

let apply_to_document t doc =
  (* Tspan-aware commit: reconcile the session's flat content against
     the element's current tspan structure. Unchanged prefix and
     suffix regions keep their original tspan assignments (and all
     per-range overrides); the changed middle is absorbed into the
     first overlapping tspan, with adjacent-equal tspans collapsed
     by the merge pass. *)
  try
    let elem = Document.get_element doc t.path in
    match t.target, elem with
    | Edit_text, Element.Text r ->
      let new_tspans = Tspan.reconcile_content r.tspans t.content in
      let new_elem = Element.Text { r with
        content = t.content;
        tspans = new_tspans
      } in
      Some (Document.replace_element doc t.path new_elem)
    | Edit_text_path, Element.Text_path r ->
      let new_tspans = Tspan.reconcile_content r.tspans t.content in
      let new_elem = Element.Text_path { r with
        content = t.content;
        tspans = new_tspans
      } in
      Some (Document.replace_element doc t.path new_elem)
    | _ -> None
  with _ -> None

let empty_text_elem x y w h =
  Element.make_text
    ~text_width:w ~text_height:h
    ~fill:(Some Element.{ fill_color = Rgb { r = 0.0; g = 0.0; b = 0.0; a = 1.0 }; fill_opacity = 1.0 })
    x y ""

let empty_text_path_elem d =
  Element.make_text_path
    ~fill:(Some Element.{ fill_color = Rgb { r = 0.0; g = 0.0; b = 0.0; a = 1.0 }; fill_opacity = 1.0 })
    d ""
