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
  (* Caret side at a tspan boundary. Defaults to [Left] per TSPAN.md
     ("new text inherits attributes of the previous character"); [Right]
     is set by callers that crossed a boundary rightward. External
     char-index APIs keep working unchanged — the affinity only matters
     at joins. *)
  mutable caret_affinity : Tspan.affinity;
  mutable drag_active : bool;
  mutable blink_epoch_ms : float;
  mutable undo_stack : snapshot list;
  mutable redo_stack : snapshot list;
  (* Session-scoped tspan clipboard. Captured on cut/copy from the
     current element's tspan structure; consumed on paste when the
     system-clipboard flat text matches. Preserves per-range overrides
     across cut/paste within a single edit session. *)
  mutable tspan_clipboard : (string * Element.tspan array) option;
  (* Next-typed-character override: a [tspan] template whose
     [Some _] fields are applied to characters inserted from
     [pending_char_start] to the current [insertion] at commit time.
     Primed by Character-panel writes when there is no selection
     (bare caret); cleared by any caret move with no selection
     extension and by undo/redo. Not persisted to the document. *)
  mutable pending_override : Element.tspan option;
  mutable pending_char_start : int option;
}

let create ~path ~target ~content ~insertion =
  let n = Text_layout.utf8_char_count content in
  let ins = min insertion n in
  {
    path; target; content;
    insertion = ins; anchor = ins;
    caret_affinity = Tspan.Left;
    drag_active = false; blink_epoch_ms = 0.0;
    undo_stack = []; redo_stack = [];
    tspan_clipboard = None;
    pending_override = None;
    pending_char_start = None;
  }

let clear_pending_override t =
  t.pending_override <- None;
  t.pending_char_start <- None

let has_pending_override t = t.pending_override <> None

let set_pending_override t overrides =
  let base = match t.pending_override with
    | Some p -> p
    | None ->
      t.pending_char_start <- Some t.insertion;
      Tspan.default_tspan ()
  in
  t.pending_override <- Some (Tspan.merge_tspan_overrides base overrides)

let pending_override t = t.pending_override
let pending_char_start t = t.pending_char_start

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
    t.anchor <- prev.s_anchor;
    clear_pending_override t

let redo t =
  match t.redo_stack with
  | [] -> ()
  | nxt :: rest ->
    t.redo_stack <- rest;
    t.undo_stack <- { s_content = t.content; s_insertion = t.insertion; s_anchor = t.anchor } :: t.undo_stack;
    t.content <- nxt.s_content;
    t.insertion <- nxt.s_insertion;
    t.anchor <- nxt.s_anchor;
    clear_pending_override t

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
  let new_pos = max 0 (min pos n) in
  (* Non-extending caret movement cancels any pending next-typed-
     character override (the user abandoned the position where the
     override was primed). *)
  if (not extend) && new_pos <> t.insertion then
    clear_pending_override t;
  t.insertion <- new_pos;
  if not extend then t.anchor <- t.insertion

let set_insertion_with_affinity t pos ~affinity ~extend =
  let n = char_count t in
  let new_pos = max 0 (min pos n) in
  if (not extend) && new_pos <> t.insertion then
    clear_pending_override t;
  t.insertion <- new_pos;
  t.caret_affinity <- affinity;
  if not extend then t.anchor <- t.insertion

let caret_affinity t = t.caret_affinity

let insertion_tspan_pos t element_tspans =
  Tspan.char_to_tspan_pos element_tspans t.insertion t.caret_affinity

let anchor_tspan_pos t element_tspans =
  Tspan.char_to_tspan_pos element_tspans t.anchor t.caret_affinity

let select_all t =
  t.anchor <- 0;
  t.insertion <- char_count t

let copy_selection t =
  if not (has_selection t) then None
  else
    let (lo, hi) = selection_range t in
    Some (Text_layout.utf8_sub t.content lo (hi - lo))

(** Capture the current selection's flat text and tspan structure
    (from [element_tspans]) into the session clipboard. Returns the
    flat text for the system clipboard. [None] if there is no
    selection. *)
let copy_selection_with_tspans t (element_tspans : Element.tspan array) =
  if not (has_selection t) then None
  else
    let (lo, hi) = selection_range t in
    let flat = Text_layout.utf8_sub t.content lo (hi - lo) in
    let tspans = Tspan.copy_range element_tspans lo hi in
    t.tspan_clipboard <- Some (flat, tspans);
    Some flat

(** Try a tspan-aware paste: when the session clipboard's flat text
    matches [text], splice the captured tspans into [element_tspans]
    at the caret via [insert_tspans_at]. Returns [None] when the
    clipboard is absent or stale; the caller falls back to the flat
    [insert] path. *)
let try_paste_tspans t (element_tspans : Element.tspan array) (text : string) =
  match t.tspan_clipboard with
  | Some (flat, payload) when flat = text ->
    Some (Tspan.insert_tspans_at element_tspans t.insertion payload)
  | _ -> None

(** Set content / insertion / anchor atomically after an external
    tspan-aware edit (paste) rewrote the element. *)
let set_content t new_content ~insertion ~anchor =
  t.content <- new_content;
  let n = Text_layout.utf8_char_count new_content in
  t.insertion <- max 0 (min insertion n);
  t.anchor <- max 0 (min anchor n)

(* Apply the pending next-typed-character override to the range
   [pending_char_start, insertion) of [tspans], then merge.
   Passthrough when pending is unset or the range is empty. When
   [?elem] is supplied, runs identity-omission (TSPAN.md step 3)
   between the merge-overrides and final merge steps so redundant
   overrides get cleared. *)
let apply_pending_to ?elem t tspans =
  match t.pending_override, t.pending_char_start with
  | Some pending, Some start when start < t.insertion ->
    let (split, first, last) = Tspan.split_range tspans start t.insertion in
    (match first, last with
     | Some f, Some l ->
       for i = f to l do
         let merged = Tspan.merge_tspan_overrides split.(i) pending in
         let finalized = match elem with
           | Some e -> Tspan.identity_omit_tspan merged e
           | None -> merged in
         split.(i) <- finalized
       done;
       Tspan.merge split
     | _ -> split)
  | _ -> tspans

let apply_to_document t doc =
  try
    let elem = Document.get_element doc t.path in
    match t.target, elem with
    | Edit_text, Element.Text r ->
      let reconciled = Tspan.reconcile_content r.tspans t.content in
      let new_tspans = apply_pending_to ~elem t reconciled in
      let new_elem = Element.Text { r with
        content = t.content;
        tspans = new_tspans
      } in
      Some (Document.replace_element doc t.path new_elem)
    | Edit_text_path, Element.Text_path r ->
      let reconciled = Tspan.reconcile_content r.tspans t.content in
      let new_tspans = apply_pending_to ~elem t reconciled in
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

let tspan_clipboard_payload t =
  match t.tspan_clipboard with
  | Some (_, payload) -> Some payload
  | None -> None

(** Wrap [t] as a structurally-typed [Model.edit_session_ref] so the
    Character-panel pipeline in [Effects] can route writes to this
    session without the [document] layer having to know about
    [Text_edit.t]. *)
let as_session_ref (t : t) : Model.edit_session_ref = object
  method has_selection = has_selection t
  method selection_range = selection_range t
  method path = t.path
  method set_pending_override o = set_pending_override t o
  method clear_pending_override () = clear_pending_override t
end
