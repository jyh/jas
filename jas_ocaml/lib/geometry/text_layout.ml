(** Pure word-wrap text layout. See [text_layout.mli]. *)

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
}

type t = {
  glyphs : glyph array;
  lines : line_info array;
  font_size : float;
  char_count : int;
}

let is_space c = c = ' ' || c = '\t'

let layout content max_width font_size measure =
  let line_height = font_size in
  let ascent = font_size *. 0.8 in
  let glyphs = ref [] in
  let lines = ref [] in
  let n = String.length content in
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
    let c = content.[!idx] in
    if c = '\n' then begin
      push_line !line_start_char !idx true !x;
      incr line_no;
      line_start_char := !idx + 1;
      x := 0.0;
      incr idx
    end else begin
      let is_ws = is_space c in
      let end_ = ref (!idx + 1) in
      while !end_ < n && content.[!end_] <> '\n'
            && (is_space content.[!end_] = is_ws) do
        incr end_
      done;
      let token = String.sub content !idx (!end_ - !idx) in
      let token_w = measure token in
      if is_ws then begin
        for k = 0 to String.length token - 1 do
          let cw = measure (String.make 1 token.[k]) in
          add_glyph (!idx + k) !line_no !x cw;
          x := !x +. cw
        done;
        idx := !end_
      end else begin
        if max_width > 0.0 && !x +. token_w > max_width && !x > 0.0 then begin
          (* Mark trailing whitespace glyphs on current line as trailing *)
          List.iter (fun g ->
            if g.line = !line_no && is_space content.[g.idx] then
              g.is_trailing_space <- true
          ) !glyphs;
          push_line !line_start_char !idx false !x;
          incr line_no;
          line_start_char := !idx;
          x := 0.0
        end;
        if max_width > 0.0 && token_w > max_width && !x = 0.0 then begin
          (* Char-by-char break *)
          for k = 0 to String.length token - 1 do
            let cw = measure (String.make 1 token.[k]) in
            if !x +. cw > max_width && !x > 0.0 then begin
              push_line !line_start_char (!idx + k) false !x;
              incr line_no;
              line_start_char := !idx + k;
              x := 0.0
            end;
            add_glyph (!idx + k) !line_no !x cw;
            x := !x +. cw
          done
        end else begin
          let cur_x = ref !x in
          for k = 0 to String.length token - 1 do
            let cw = measure (String.make 1 token.[k]) in
            add_glyph (!idx + k) !line_no !cur_x cw;
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
           top = 0.0; baseline_y = ascent; height = line_height; width = 0.0 } |]
    else lines_arr
  in
  {
    glyphs = Array.of_list (List.rev !glyphs);
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
    Array.iter (fun g -> if g.line = line_no then last := Some g) t.glyphs;
    let x = match !last with Some g -> g.right | None -> 0.0 in
    (x, baseline_y, height)
  end else begin
    let result = ref (0.0, baseline_y, height) in
    let found = ref false in
    Array.iter (fun g ->
      if not !found && g.idx = cursor then begin
        result := (g.x, baseline_y, height);
        found := true
      end
    ) t.glyphs;
    !result
  end

let glyphs_on_line t line_no =
  let result = ref [] in
  Array.iter (fun g ->
    if g.line = line_no && not g.is_trailing_space then result := g :: !result
  ) t.glyphs;
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
