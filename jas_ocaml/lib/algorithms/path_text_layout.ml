(** Path text layout. See [path_text_layout.mli]. *)

type path_glyph = {
  idx : int;
  offset : float;
  width : float;
  cx : float;
  cy : float;
  angle : float;
  overflow : bool;
}

type t = {
  glyphs : path_glyph array;
  total_length : float;
  font_size : float;
  char_count : int;
}

let arc_lengths pts =
  let rec go acc prev = function
    | [] -> List.rev acc
    | (x, y) :: rest ->
      let (px, py) = prev in
      let dx = x -. px in
      let dy = y -. py in
      let len = (List.hd acc) +. sqrt (dx *. dx +. dy *. dy) in
      go (len :: acc) (x, y) rest
  in
  match pts with
  | [] -> [0.0]
  | first :: rest -> go [0.0] first rest

let sample_at_arc pts_arr len_arr arc =
  let n = Array.length pts_arr in
  if n < 2 then
    let p = if n = 1 then pts_arr.(0) else (0.0, 0.0) in
    let (x, y) = p in (x, y, 0.0)
  else begin
    let arc = max 0.0 arc in
    let result = ref None in
    (try
      for i = 1 to n - 1 do
        if len_arr.(i) >= arc then begin
          let seg = len_arr.(i) -. len_arr.(i - 1) in
          let t = if seg > 0.0 then (arc -. len_arr.(i - 1)) /. seg else 0.0 in
          let (ax, ay) = pts_arr.(i - 1) in
          let (bx, by) = pts_arr.(i) in
          let x = ax +. t *. (bx -. ax) in
          let y = ay +. t *. (by -. ay) in
          let angle = atan2 (by -. ay) (bx -. ax) in
          result := Some (x, y, angle);
          raise Exit
        end
      done
    with Exit -> ());
    match !result with
    | Some r -> r
    | None ->
      let last = n - 1 in
      let (ax, ay) = pts_arr.(last - 1) in
      let (bx, by) = pts_arr.(last) in
      (bx, by, atan2 (by -. ay) (bx -. ax))
  end

let layout d content start_offset font_size measure =
  let pts = Element.flatten_path_commands d in
  let lengths = arc_lengths pts in
  let total = match List.rev lengths with [] -> 0.0 | x :: _ -> x in
  let n = String.length content in
  if total <= 0.0 || pts = [] then
    { glyphs = [||]; total_length = total; font_size; char_count = n }
  else begin
    let pts_arr = Array.of_list pts in
    let len_arr = Array.of_list lengths in
    let start_arc = (max 0.0 (min 1.0 start_offset)) *. total in
    let cur_arc = ref start_arc in
    let glyphs = ref [] in
    for i = 0 to n - 1 do
      let cw = measure (String.make 1 content.[i]) in
      let center_arc = !cur_arc +. cw /. 2.0 in
      let overflow = center_arc > total in
      let (cx, cy, angle) = sample_at_arc pts_arr len_arr (min center_arc total) in
      glyphs := { idx = i; offset = !cur_arc; width = cw; cx; cy; angle; overflow } :: !glyphs;
      cur_arc := !cur_arc +. cw
    done;
    { glyphs = Array.of_list (List.rev !glyphs);
      total_length = total; font_size; char_count = n }
  end

let cursor_pos t cursor =
  let n = Array.length t.glyphs in
  if n = 0 then None
  else if cursor = 0 then begin
    let g = t.glyphs.(0) in
    let dx = -. cos g.angle *. g.width /. 2.0 in
    let dy = -. sin g.angle *. g.width /. 2.0 in
    Some (g.cx +. dx, g.cy +. dy, g.angle)
  end else if cursor >= n then begin
    let g = t.glyphs.(n - 1) in
    let dx = cos g.angle *. g.width /. 2.0 in
    let dy = sin g.angle *. g.width /. 2.0 in
    Some (g.cx +. dx, g.cy +. dy, g.angle)
  end else begin
    let g = t.glyphs.(cursor) in
    let dx = -. cos g.angle *. g.width /. 2.0 in
    let dy = -. sin g.angle *. g.width /. 2.0 in
    Some (g.cx +. dx, g.cy +. dy, g.angle)
  end

let hit_test t x y =
  let n = Array.length t.glyphs in
  if n = 0 then 0
  else begin
    let best_idx = ref 0 in
    let best_dist = ref infinity in
    for i = 0 to n - 1 do
      let g = t.glyphs.(i) in
      let half = g.width /. 2.0 in
      let bx = g.cx -. cos g.angle *. half in
      let by = g.cy -. sin g.angle *. half in
      let ax = g.cx +. cos g.angle *. half in
      let ay = g.cy +. sin g.angle *. half in
      let db = sqrt ((x -. bx) *. (x -. bx) +. (y -. by) *. (y -. by)) in
      let da = sqrt ((x -. ax) *. (x -. ax) +. (y -. ay) *. (y -. ay)) in
      if db < !best_dist then begin best_dist := db; best_idx := i end;
      if da < !best_dist then begin best_dist := da; best_idx := i + 1 end
    done;
    !best_idx
  end
