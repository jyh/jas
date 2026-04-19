(** Build [paragraph_segment] lists from tspans. See .mli. *)

let _text_align_from (value : string option) (is_area : bool)
  : Text_layout.text_align =
  match value with
  | Some "center" -> Text_layout.Center
  | Some "right" -> Text_layout.Right
  | Some "justify" when is_area -> Text_layout.Justify
  | _ -> Text_layout.Left

(** Map [text-align-last] to the last-line alignment of a justified
    paragraph. Ignored when the paragraph is not justified. *)
let _last_line_align_from (value : string option)
    (base : Text_layout.text_align) (is_area : bool)
  : Text_layout.text_align =
  if base <> Text_layout.Justify || not is_area then Text_layout.Left
  else match value with
    | Some "center" -> Text_layout.Center
    | Some "right" -> Text_layout.Right
    | Some "justify" -> Text_layout.Justify
    | _ -> Text_layout.Left

let marker_gap_pt = 12.0

let to_alpha (n : int) (upper : bool) : string =
  if n <= 0 then ""
  else begin
    let base = if upper then Char.code 'A' else Char.code 'a' in
    let buf = Buffer.create 4 in
    let v = ref n in
    while !v > 0 do
      v := !v - 1;
      Buffer.add_char buf (Char.chr (base + (!v mod 26)));
      v := !v / 26
    done;
    let s = Buffer.contents buf in
    String.init (String.length s) (fun i -> s.[String.length s - 1 - i])
  end

let to_roman (n : int) (upper : bool) : string =
  if n <= 0 then ""
  else if n > 3999 then Printf.sprintf "(%d)" n
  else begin
    let pairs = [
      (1000, "M", "m"); (900, "CM", "cm");
      (500, "D", "d");  (400, "CD", "cd");
      (100, "C", "c");  (90, "XC", "xc");
      (50, "L", "l");   (40, "XL", "xl");
      (10, "X", "x");   (9, "IX", "ix");
      (5, "V", "v");    (4, "IV", "iv");
      (1, "I", "i");
    ] in
    let buf = Buffer.create 8 in
    let v = ref n in
    List.iter (fun (vv, u, l) ->
      while !v >= vv do
        Buffer.add_string buf (if upper then u else l);
        v := !v - vv
      done
    ) pairs;
    Buffer.contents buf
  end

let marker_text (list_style : string) (counter : int) : string =
  match list_style with
  | "bullet-disc" -> "\xE2\x80\xA2"          (* • *)
  | "bullet-open-circle" -> "\xE2\x97\x8B"   (* ○ *)
  | "bullet-square" -> "\xE2\x96\xA0"        (* ■ *)
  | "bullet-open-square" -> "\xE2\x96\xA1"   (* □ *)
  | "bullet-dash" -> "\xE2\x80\x93"          (* – *)
  | "bullet-check" -> "\xE2\x9C\x93"         (* ✓ *)
  | "num-decimal" -> Printf.sprintf "%d." counter
  | "num-lower-alpha" -> Printf.sprintf "%s." (to_alpha counter false)
  | "num-upper-alpha" -> Printf.sprintf "%s." (to_alpha counter true)
  | "num-lower-roman" -> Printf.sprintf "%s." (to_roman counter false)
  | "num-upper-roman" -> Printf.sprintf "%s." (to_roman counter true)
  | _ -> ""

let compute_counters (segs : Text_layout.paragraph_segment list) : int list =
  let counters = ref [] in
  let prev_num = ref None in
  let current = ref 0 in
  List.iter (fun (seg : Text_layout.paragraph_segment) ->
    match seg.list_style with
    | Some style when String.length style >= 4 && String.sub style 0 4 = "num-" ->
      if !prev_num = Some style then current := !current + 1
      else current := 1;
      counters := !current :: !counters;
      prev_num := Some style
    | _ ->
      counters := 0 :: !counters;
      prev_num := None;
      current := 0
  ) segs;
  List.rev !counters

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
      let list_style = t.jas_list_style in
      let marker_gap = if list_style <> None then marker_gap_pt else 0.0 in
      let hanging_punctuation =
        match t.jas_hanging_punctuation with Some v -> v | None -> false in
      let ta = _text_align_from t.text_align is_area in
      let lla = _last_line_align_from t.text_align_last ta is_area in
      current := Some {
        Text_layout.char_start = !cursor;
        char_end = !cursor;
        left_indent = (match t.jas_left_indent with Some v -> v | None -> 0.0);
        right_indent = (match t.jas_right_indent with Some v -> v | None -> 0.0);
        first_line_indent = (match t.text_indent with Some v -> v | None -> 0.0);
        space_before = (match t.jas_space_before with Some v -> v | None -> 0.0);
        space_after = (match t.jas_space_after with Some v -> v | None -> 0.0);
        text_align = ta;
        list_style;
        marker_gap;
        hanging_punctuation;
        word_spacing_min =
          (match t.jas_word_spacing_min with Some v -> v | None -> 80.0);
        word_spacing_desired =
          (match t.jas_word_spacing_desired with Some v -> v | None -> 100.0);
        word_spacing_max =
          (match t.jas_word_spacing_max with Some v -> v | None -> 133.0);
        last_line_align = lla;
        hyphenate = (match t.jas_hyphenate with Some v -> v | None -> false);
        hyphenate_min_word =
          (match t.jas_hyphenate_min_word with Some v -> Float.to_int v | None -> 3);
        hyphenate_min_before =
          (match t.jas_hyphenate_min_before with Some v -> Float.to_int v | None -> 1);
        hyphenate_min_after =
          (match t.jas_hyphenate_min_after with Some v -> Float.to_int v | None -> 1);
        hyphenate_bias =
          (match t.jas_hyphenate_bias with Some v -> Float.to_int v | None -> 0);
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
