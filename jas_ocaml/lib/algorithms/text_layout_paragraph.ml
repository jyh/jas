(** Build [paragraph_segment] lists from tspans. See .mli. *)

let _text_align_from (value : string option) (_is_area : bool)
  : Text_layout.text_align =
  match value with
  | Some "center" -> Text_layout.Center
  | Some "right" -> Text_layout.Right
  | Some "justify" -> Text_layout.Left  (* Phase 5 placeholder *)
  | _ -> Text_layout.Left

let build_segments_from_text (tspans : Element.tspan array) (content : string)
    (is_area : bool) : Text_layout.paragraph_segment list =
  let total_chars = Text_layout.utf8_char_count content in
  let segs = ref [] in
  let cursor = ref 0 in
  let current : Text_layout.paragraph_segment option ref = ref None in
  Array.iter (fun (t : Element.tspan) ->
    let body_chars = Text_layout.utf8_char_count t.content in
    if t.jas_role = Some "paragraph" then begin
      (match !current with
       | Some seg ->
         let seg = { seg with char_end = !cursor } in
         if seg.char_end > seg.char_start then segs := seg :: !segs
       | None -> ());
      current := Some {
        Text_layout.char_start = !cursor;
        char_end = !cursor;
        left_indent = (match t.jas_left_indent with Some v -> v | None -> 0.0);
        right_indent = (match t.jas_right_indent with Some v -> v | None -> 0.0);
        first_line_indent = (match t.text_indent with Some v -> v | None -> 0.0);
        space_before = (match t.jas_space_before with Some v -> v | None -> 0.0);
        space_after = (match t.jas_space_after with Some v -> v | None -> 0.0);
        text_align = _text_align_from t.text_align is_area;
      }
    end else
      cursor := !cursor + body_chars
  ) tspans;
  (match !current with
   | Some seg ->
     let seg = { seg with char_end = min !cursor total_chars } in
     if seg.char_end > seg.char_start then segs := seg :: !segs
   | None -> ());
  List.rev !segs
