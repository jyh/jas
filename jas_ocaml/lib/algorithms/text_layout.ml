(** Pure word-wrap text layout. See [text_layout.mli].

    Strings are treated as UTF-8 byte sequences but all indices exposed
    by this module — [start], [end_], [idx], [insertion], [anchor] — are
    *char* (Unicode scalar value) indices, not byte indices. Helpers
    below convert between the two when slicing into the byte string. *)

(* ------------------------------------------------------------------ *)
(* UTF-8 helpers                                                       *)
(* ------------------------------------------------------------------ *)

let utf8_char_count s =
  let n = String.length s in
  let i = ref 0 and c = ref 0 in
  while !i < n do
    let d = String.get_utf_8_uchar s !i in
    let len = Uchar.utf_decode_length d in
    i := !i + (if len <= 0 then 1 else len);
    incr c
  done;
  !c

(** Byte index of the [k]-th char (0-based). Returns [String.length s] if
    [k >= utf8_char_count s]. *)
let char_to_byte s k =
  let n = String.length s in
  let i = ref 0 and c = ref 0 in
  while !i < n && !c < k do
    let d = String.get_utf_8_uchar s !i in
    let len = Uchar.utf_decode_length d in
    i := !i + (if len <= 0 then 1 else len);
    incr c
  done;
  !i

(** Substring from char index [k] to char index [k + n]. *)
let utf8_sub s k n =
  let bi = char_to_byte s k in
  let bj = char_to_byte s (k + n) in
  String.sub s bi (bj - bi)

(** Iterate Unicode chars (as Uchar.t) one by one. *)
let utf8_iteri f s =
  let n = String.length s in
  let i = ref 0 and c = ref 0 in
  while !i < n do
    let d = String.get_utf_8_uchar s !i in
    let len = Uchar.utf_decode_length d in
    let len = if len <= 0 then 1 else len in
    let u = Uchar.utf_decode_uchar d in
    f !c u;
    i := !i + len;
    incr c
  done

(* Whitespace test mirroring Rust's [char::is_whitespace] (Unicode-aware). *)
let uchar_is_whitespace u =
  if not (Uchar.is_valid (Uchar.to_int u)) then false
  else
    let i = Uchar.to_int u in
    (* Common ASCII whitespace plus NBSP and a few line separators. *)
    i = 0x09 || i = 0x0A || i = 0x0B || i = 0x0C || i = 0x0D
    || i = 0x20 || i = 0x85 || i = 0xA0
    || i = 0x1680
    || (i >= 0x2000 && i <= 0x200A)
    || i = 0x2028 || i = 0x2029
    || i = 0x202F || i = 0x205F || i = 0x3000

let uchar_is_newline u = Uchar.to_int u = 0x0A  (* '\n' *)

(* ------------------------------------------------------------------ *)
(* Layout                                                              *)
(* ------------------------------------------------------------------ *)

type glyph = {
  idx : int;
  line : int;
  x : float;
  right : float;
  baseline_y : float;
  top : float;
  height : float;
  mutable is_trailing_space : bool;
}

type line_info = {
  start : int;
  end_ : int;
  hard_break : bool;
  top : float;
  baseline_y : float;
  height : float;
  width : float;
  mutable glyph_start : int;
  mutable glyph_end : int;
}

type t = {
  glyphs : glyph array;
  lines : line_info array;
  font_size : float;
  char_count : int;
}

let layout content max_width font_size measure =
  let line_height = font_size in
  let ascent = font_size *. 0.8 in
  (* Decode content once into a char array. *)
  let chars =
    let acc = ref [] in
    utf8_iteri (fun _ u -> acc := u :: !acc) content;
    Array.of_list (List.rev !acc)
  in
  (* `uchar_str u` returns the UTF-8 byte string for a single char. *)
  let uchar_str u =
    let b = Buffer.create 4 in
    Buffer.add_utf_8_uchar b u;
    Buffer.contents b
  in
  let chars_str lo hi =
    let b = Buffer.create (4 * (hi - lo)) in
    for k = lo to hi - 1 do Buffer.add_utf_8_uchar b chars.(k) done;
    Buffer.contents b
  in
  let glyphs = ref [] in
  let lines = ref [] in
  let n = Array.length chars in
  let idx = ref 0 in
  let line_no = ref 0 in
  let line_start_char = ref 0 in
  let x = ref 0.0 in

  let push_line start end_ hard_break line_width =
    let top = float_of_int !line_no *. line_height in
    lines := {
      start; end_; hard_break;
      top; baseline_y = top +. ascent;
      height = line_height; width = line_width;
      glyph_start = 0; glyph_end = 0;
    } :: !lines
  in

  let add_glyph i ln gx gw =
    let top = float_of_int ln *. line_height in
    glyphs := {
      idx = i; line = ln; x = gx; right = gx +. gw;
      baseline_y = top +. ascent; top; height = line_height;
      is_trailing_space = false;
    } :: !glyphs
  in

  while !idx < n do
    let c = chars.(!idx) in
    if uchar_is_newline c then begin
      push_line !line_start_char !idx true !x;
      incr line_no;
      line_start_char := !idx + 1;
      x := 0.0;
      incr idx
    end else begin
      let is_ws = uchar_is_whitespace c in
      let end_ = ref (!idx + 1) in
      while !end_ < n && not (uchar_is_newline chars.(!end_))
            && (uchar_is_whitespace chars.(!end_) = is_ws) do
        incr end_
      done;
      let token = chars_str !idx !end_ in
      let token_w = measure token in
      if is_ws then begin
        for k = !idx to !end_ - 1 do
          let cw = measure (uchar_str chars.(k)) in
          add_glyph k !line_no !x cw;
          x := !x +. cw
        done;
        idx := !end_
      end else begin
        if max_width > 0.0 && !x +. token_w > max_width && !x > 0.0 then begin
          (* Mark trailing whitespace glyphs on current line as trailing *)
          List.iter (fun g ->
            if g.line = !line_no && uchar_is_whitespace chars.(g.idx) then
              g.is_trailing_space <- true
          ) !glyphs;
          push_line !line_start_char !idx false !x;
          incr line_no;
          line_start_char := !idx;
          x := 0.0
        end;
        if max_width > 0.0 && token_w > max_width && !x = 0.0 then begin
          (* Char-by-char break *)
          for k = !idx to !end_ - 1 do
            let cw = measure (uchar_str chars.(k)) in
            if !x +. cw > max_width && !x > 0.0 then begin
              push_line !line_start_char k false !x;
              incr line_no;
              line_start_char := k;
              x := 0.0
            end;
            add_glyph k !line_no !x cw;
            x := !x +. cw
          done
        end else begin
          let cur_x = ref !x in
          for k = !idx to !end_ - 1 do
            let cw = measure (uchar_str chars.(k)) in
            add_glyph k !line_no !cur_x cw;
            cur_x := !cur_x +. cw
          done;
          x := !cur_x
        end;
        idx := !end_
      end
    end
  done;
  push_line !line_start_char n false !x;
  let lines_arr = Array.of_list (List.rev !lines) in
  let lines_arr = if Array.length lines_arr = 0 then
      [| { start = 0; end_ = 0; hard_break = false;
           top = 0.0; baseline_y = ascent; height = line_height; width = 0.0;
           glyph_start = 0; glyph_end = 0 } |]
    else lines_arr
  in
  let glyphs_arr = Array.of_list (List.rev !glyphs) in
  (* Sweep glyphs once to fill line glyph ranges. *)
  let gi = ref 0 in
  Array.iteri (fun li line ->
    line.glyph_start <- !gi;
    while !gi < Array.length glyphs_arr && glyphs_arr.(!gi).line = li do
      incr gi
    done;
    line.glyph_end <- !gi
  ) lines_arr;
  {
    glyphs = glyphs_arr;
    lines = lines_arr;
    font_size; char_count = n;
  }

let line_for_cursor t cursor =
  let nlines = Array.length t.lines in
  let result = ref (nlines - 1) in
  let found = ref false in
  Array.iteri (fun i l ->
    if not !found then begin
      if cursor < l.end_ then begin result := i; found := true end
      else if cursor = l.end_ then begin
        if l.hard_break then begin result := i; found := true end
        else if i = nlines - 1 then begin result := i; found := true end
        else begin result := i + 1; found := true end
      end
    end
  ) t.lines;
  !result

let cursor_xy t cursor =
  let cursor = min cursor t.char_count in
  let line_no = line_for_cursor t cursor in
  let line = t.lines.(line_no) in
  let height = line.height in
  let baseline_y = line.baseline_y in
  if cursor = line.start then (0.0, baseline_y, height)
  else if cursor >= line.end_ then begin
    let last = ref None in
    for i = line.glyph_start to line.glyph_end - 1 do
      last := Some t.glyphs.(i)
    done;
    let x = match !last with Some g -> g.right | None -> 0.0 in
    (x, baseline_y, height)
  end else begin
    let result = ref (0.0, baseline_y, height) in
    let found = ref false in
    for i = line.glyph_start to line.glyph_end - 1 do
      if not !found && t.glyphs.(i).idx = cursor then begin
        result := (t.glyphs.(i).x, baseline_y, height);
        found := true
      end
    done;
    !result
  end

let glyphs_on_line t line_no =
  let line = t.lines.(line_no) in
  let result = ref [] in
  for i = line.glyph_start to line.glyph_end - 1 do
    let g = t.glyphs.(i) in
    if not g.is_trailing_space then result := g :: !result
  done;
  List.rev !result

let hit_test t x y =
  if Array.length t.lines = 0 then 0
  else begin
    let line_no = ref (Array.length t.lines - 1) in
    let found = ref false in
    Array.iteri (fun i l ->
      if not !found && y < l.top +. l.height then begin
        line_no := i; found := true
      end
    ) t.lines;
    let line = t.lines.(!line_no) in
    let gs = glyphs_on_line t !line_no in
    match gs with
    | [] -> line.start
    | first :: _ ->
      if x <= first.x then line.start
      else begin
        let result = ref None in
        List.iter (fun g ->
          if !result = None then begin
            let mid = (g.x +. g.right) /. 2.0 in
            if x < mid then result := Some g.idx
          end
        ) gs;
        match !result with
        | Some i -> i
        | None ->
          let last = List.nth gs (List.length gs - 1) in
          let last_visible = last.idx + 1 in
          if line.hard_break then line.end_
          else max line.start (min last_visible line.end_)
      end
  end

let cursor_at_line_x t line_no target_x =
  let line = t.lines.(line_no) in
  let gs = glyphs_on_line t line_no in
  match gs with
  | [] -> line.start
  | first :: _ ->
    if target_x <= first.x then line.start
    else begin
      let result = ref None in
      List.iter (fun g ->
        if !result = None then begin
          let mid = (g.x +. g.right) /. 2.0 in
          if target_x < mid then result := Some g.idx
        end
      ) gs;
      match !result with
      | Some i -> i
      | None -> line.end_
    end

let cursor_up t cursor =
  let line_no = line_for_cursor t cursor in
  if line_no = 0 then 0
  else
    let (x, _, _) = cursor_xy t cursor in
    cursor_at_line_x t (line_no - 1) x

let cursor_down t cursor =
  let line_no = line_for_cursor t cursor in
  if line_no + 1 >= Array.length t.lines then t.char_count
  else
    let (x, _, _) = cursor_xy t cursor in
    cursor_at_line_x t (line_no + 1) x

let ordered_range a b = if a <= b then (a, b) else (b, a)

(* ── Phase 5 paragraph-aware layout ─────────────────────── *)

type text_align = Left | Center | Right

type paragraph_segment = {
  char_start : int;
  char_end : int;
  left_indent : float;
  right_indent : float;
  first_line_indent : float;
  space_before : float;
  space_after : float;
  text_align : text_align;
  list_style : string option;
  marker_gap : float;
  hanging_punctuation : bool;
}

let default_segment = {
  char_start = 0; char_end = 0;
  left_indent = 0.0; right_indent = 0.0; first_line_indent = 0.0;
  space_before = 0.0; space_after = 0.0;
  text_align = Left;
  list_style = None; marker_gap = 0.0;
  hanging_punctuation = false;
}

(* ── Phase 7: hanging punctuation char-class predicates ── *)

let is_left_hanger (c : Uchar.t) : bool =
  let v = Uchar.to_int c in
  v = 0x0022 || v = 0x0027                         (* straight quotes *)
  || v = 0x201C || v = 0x2018                      (* left curly quotes *)
  || v = 0x00AB || v = 0x2039                      (* left angle quotes *)
  || v = 0x0028 || v = 0x005B || v = 0x007B        (* open brackets *)

let is_right_hanger (c : Uchar.t) : bool =
  let v = Uchar.to_int c in
  v = 0x0022 || v = 0x0027                         (* straight quotes *)
  || v = 0x201D || v = 0x2019                      (* right curly quotes *)
  || v = 0x00BB || v = 0x203A                      (* right angle quotes *)
  || v = 0x0029 || v = 0x005D || v = 0x007D        (* close brackets *)
  || v = 0x002E || v = 0x002C                      (* period and comma *)
  || v = 0x002D || v = 0x2013 || v = 0x2014        (* hyphen, en dash, em dash *)

(** Visible width of a line: max [right] of any non-trailing-space glyph. *)
let _trimmed_line_width (line : line_info) (glyphs : glyph array) : float =
  let w = ref 0.0 in
  for gi = line.glyph_start to line.glyph_end - 1 do
    let g = glyphs.(gi) in
    if not g.is_trailing_space && g.right > !w then w := g.right
  done;
  !w

let layout_with_paragraphs (content : string) (max_width : float)
    (font_size : float) (paragraphs : paragraph_segment list)
    (measure : string -> float) : t =
  let n = utf8_char_count content in
  let line_height = font_size in
  let ascent = font_size *. 0.8 in

  (* Build effective segment list: gap-fill so every char is covered. *)
  let segs = ref [] in
  let cursor = ref 0 in
  List.iter (fun (p : paragraph_segment) ->
    let start = max p.char_start !cursor in
    let s = min start n in
    let e = min (max p.char_end s) n in
    if s > !cursor then
      segs := { default_segment with char_start = !cursor; char_end = s } :: !segs;
    if e > s then
      segs := { p with char_start = s; char_end = e } :: !segs;
    cursor := e
  ) paragraphs;
  if !cursor < n then
    segs := { default_segment with char_start = !cursor; char_end = n } :: !segs;
  if !segs = [] then
    segs := [{ default_segment with char_start = 0; char_end = n }];
  let segs = List.rev !segs in

  let all_glyphs = ref [] in
  let all_lines = ref [] in
  let glyph_count = ref 0 in
  let line_count = ref 0 in
  let y_offset = ref 0.0 in

  List.iteri (fun pi seg ->
    if pi > 0 then y_offset := !y_offset +. seg.space_before;
    let slice = utf8_sub content seg.char_start (seg.char_end - seg.char_start) in
    (* Phase 6: an active list adds marker_gap to the effective left
       indent (so the marker has room before the text) AND suppresses
       first_line_indent — the marker already occupies the first-line
       position so a separate first-line offset would push the text
       away from the marker. *)
    let has_list = seg.list_style <> None in
    let list_indent = if has_list then seg.marker_gap else 0.0 in
    let effective_max =
      if max_width > 0.0
      then Float.max 0.0
             (max_width -. seg.left_indent -. list_indent -. seg.right_indent)
      else 0.0 in
    let para = layout slice effective_max font_size measure in
    let first_line_extra =
      if has_list then 0.0 else Float.max 0.0 seg.first_line_indent in
    let first_line_no_in_combined = !line_count in
    let para_lines = Array.length para.lines in
    Array.iteri (fun li (line : line_info) ->
      let x_shift = seg.left_indent +. list_indent
                  +. (if li = 0 then first_line_extra else 0.0) in
      let line_avail =
        if effective_max > 0.0
        then Float.max 0.0 (effective_max
                            -. (if li = 0 then first_line_extra else 0.0))
        else 0.0 in
      let visible_w = _trimmed_line_width line para.glyphs in
      (* Phase 7: hanging punctuation. Offset hangable chars at line
         start / end outside the effective edge. Alignment per spec:
         left-aligned hangs only left, right-aligned only right,
         centered both. *)
      let first_visible = ref None in
      let last_visible = ref None in
      for gi = line.glyph_start to line.glyph_end - 1 do
        let g = para.glyphs.(gi) in
        if not g.is_trailing_space then begin
          if !first_visible = None then first_visible := Some g;
          last_visible := Some g
        end
      done;
      let char_at idx =
        let byte = char_to_byte content (seg.char_start + idx) in
        let d = String.get_utf_8_uchar content byte in
        Uchar.utf_decode_uchar d
      in
      let left_hang_w = ref 0.0 in
      let right_hang_w = ref 0.0 in
      if seg.hanging_punctuation then begin
        let allow_left = seg.text_align = Left || seg.text_align = Center in
        let allow_right = seg.text_align = Right || seg.text_align = Center in
        if allow_left then
          (match !first_visible with
           | Some g ->
             let c = char_at g.idx in
             if is_left_hanger c then left_hang_w := g.right -. g.x
           | None -> ());
        if allow_right then
          (match !last_visible with
           | Some g ->
             let c = char_at g.idx in
             if is_right_hanger c then right_hang_w := g.right -. g.x
           | None -> ())
      end;
      let effective_visible_w =
        Float.max 0.0 (visible_w -. !left_hang_w -. !right_hang_w) in
      let align_shift = match seg.text_align with
        | Left -> -. !left_hang_w
        | Center ->
          if line_avail > effective_visible_w
          then (line_avail -. effective_visible_w) /. 2.0 -. !left_hang_w
          else -. !left_hang_w
        | Right ->
          if line_avail > effective_visible_w
          then line_avail -. effective_visible_w else 0.0
      in
      let total_shift = x_shift +. align_shift in
      let orig_start = seg.char_start + line.start in
      let orig_end = seg.char_start + line.end_ in
      let baseline = !y_offset +. line.baseline_y in
      let top = !y_offset +. line.top in
      let glyph_start_combined = !glyph_count in
      for gi = line.glyph_start to line.glyph_end - 1 do
        let g = para.glyphs.(gi) in
        all_glyphs := {
          idx = seg.char_start + g.idx;
          line = first_line_no_in_combined + li;
          x = g.x +. total_shift;
          right = g.right +. total_shift;
          baseline_y = g.baseline_y +. !y_offset;
          top = g.top +. !y_offset;
          height = g.height;
          is_trailing_space = g.is_trailing_space;
        } :: !all_glyphs;
        incr glyph_count
      done;
      let glyph_end_combined = !glyph_count in
      all_lines := {
        start = orig_start; end_ = orig_end;
        hard_break = line.hard_break;
        top; baseline_y = baseline;
        height = line.height;
        width = visible_w +. total_shift;
        glyph_start = glyph_start_combined;
        glyph_end = glyph_end_combined;
      } :: !all_lines;
      incr line_count
    ) para.lines;
    if para_lines > 0 then
      y_offset := !y_offset +. (Float.of_int para_lines) *. line_height;
    y_offset := !y_offset +. seg.space_after
  ) segs;

  let lines = Array.of_list (List.rev !all_lines) in
  let glyphs = Array.of_list (List.rev !all_glyphs) in
  let lines = if Array.length lines = 0 then
    (* Empty content — keep single-empty-line invariant. *)
    [| { start = 0; end_ = 0; hard_break = false;
         top = 0.0; baseline_y = ascent; height = line_height;
         width = 0.0; glyph_start = 0; glyph_end = 0 } |]
  else lines in
  { glyphs; lines; font_size; char_count = n }
