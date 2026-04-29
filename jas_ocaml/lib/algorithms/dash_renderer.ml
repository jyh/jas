(** Dash-alignment renderer — see DASH_ALIGN.md §Algorithm.
    Lines-only port of [workspace_interpreter/dash_renderer.py];
    keep in lockstep when extending. *)

open Element

let eps = 1e-9

(* ── Path utilities ───────────────────────────────────────────── *)

let split_at_moveto path =
  let rec go acc cur = function
    | [] -> if cur = [] then List.rev acc else List.rev (List.rev cur :: acc)
    | (MoveTo _ as c) :: rest ->
      let acc' = if cur = [] then acc else (List.rev cur) :: acc in
      go acc' [c] rest
    | c :: rest -> go acc (c :: cur) rest
  in
  go [] [] path

let has_segments sub =
  List.exists (function LineTo _ | ClosePath -> true | _ -> false) sub

let is_closed sub =
  List.exists (function ClosePath -> true | _ -> false) sub

let anchor_points sub =
  List.filter_map (function
    | MoveTo (x, y) | LineTo (x, y) -> Some (x, y)
    | _ -> None) sub

let seg_len (ax, ay) (bx, by) =
  let dx = bx -. ax in
  let dy = by -. ay in
  sqrt (dx *. dx +. dy *. dy)

let cumulative seg_lengths =
  let rec go s acc = function
    | [] -> List.rev acc
    | l :: rest -> let s' = s +. l in go s' (s' :: acc) rest
  in
  0.0 :: go 0.0 [] seg_lengths

(* ── Pattern walking ─────────────────────────────────────────── *)

let locate_in_pattern offset pattern =
  let period = List.fold_left (+.) 0.0 pattern in
  if period <= 0.0 then (0, 0.0)
  else begin
    let r = mod_float offset period in
    let r = if r < 0.0 then r +. period else r in
    let rec walk o i = function
      | [] -> (0, 0.0)
      | w :: rest ->
        if o < w -. eps then (i, o)
        else walk (o -. w) (i + 1) rest
    in
    walk r 0 pattern
  end

(* ── Subpath extraction by arc-length ─────────────────────────── *)

let locate_segment cum t =
  let arr = Array.of_list cum in
  let n = Array.length arr - 1 in
  if t <= arr.(0) then 0
  else if t >= arr.(n) then n - 1
  else begin
    let i = ref 0 in
    let found = ref false in
    while not !found && !i < n do
      if arr.(!i) <= t && t < arr.(!i + 1) then found := true
      else incr i
    done;
    if !found then !i else n - 1
  end

let interpolate anchors cum t =
  let arr = Array.of_list anchors in
  let cum_arr = Array.of_list cum in
  let n = Array.length arr in
  if t <= 0.0 then arr.(0)
  else begin
    let total = cum_arr.(Array.length cum_arr - 1) in
    if t >= total then arr.(n - 1)
    else begin
      let i = locate_segment cum t in
      let seg = cum_arr.(i + 1) -. cum_arr.(i) in
      if seg <= 0.0 then arr.(i)
      else begin
        let alpha = (t -. cum_arr.(i)) /. seg in
        let (ax, ay) = arr.(i) in
        let (bx, by) = arr.(i + 1) in
        (ax +. alpha *. (bx -. ax), ay +. alpha *. (by -. ay))
      end
    end
  end

let subpath_between anchors cum t0 t1 =
  if t1 <= t0 +. eps then None
  else begin
    let (p0x, p0y) = interpolate anchors cum t0 in
    let (p1x, p1y) = interpolate anchors cum t1 in
    let i = locate_segment cum t0 in
    let j = locate_segment cum t1 in
    let arr = Array.of_list anchors in
    let cmds = ref [MoveTo (p0x, p0y)] in
    if j > i then begin
      for k = i + 1 to j do
        let (x, y) = arr.(k) in
        cmds := (LineTo (x, y)) :: !cmds
      done
    end;
    let last_match =
      match !cmds with
      | (MoveTo (lx, ly) | LineTo (lx, ly)) :: _ ->
        abs_float (lx -. p1x) <= 1e-9 && abs_float (ly -. p1y) <= 1e-9
      | _ -> false
    in
    if not last_match then
      cmds := (LineTo (p1x, p1y)) :: !cmds;
    Some (List.rev !cmds)
  end

let subpath_between_wrapping anchors cum t0 t1 closed =
  let total = match List.rev cum with [] -> 0.0 | h :: _ -> h in
  if not closed || t1 <= total +. eps then
    subpath_between anchors cum t0 (min t1 total)
  else begin
    let head = subpath_between anchors cum t0 total in
    let tail = subpath_between anchors cum 0.0 (t1 -. total) in
    match head, tail with
    | Some h, Some t ->
      (* Drop tail's leading MoveTo. *)
      let t_no_m = match t with
        | MoveTo _ :: rest -> rest
        | _ -> t in
      Some (h @ t_no_m)
    | Some h, None -> Some h
    | None, Some t -> Some t
    | None, None -> None
  end

(* ── Preserve mode ────────────────────────────────────────────── *)

let emit_dashes anchors_walk cum pattern period_offset t_start t_end =
  let period = List.fold_left (+.) 0.0 pattern in
  if period <= 0.0 then []
  else begin
    let pattern_arr = Array.of_list pattern in
    let n_pat = Array.length pattern_arr in
    let (idx0, in0) = locate_in_pattern period_offset pattern in
    let cur_idx = ref idx0 in
    let in_idx = ref in0 in
    let t = ref t_start in
    let out = ref [] in
    let continue_loop = ref true in
    while !continue_loop do
      if !t >= t_end -. eps then continue_loop := false
      else begin
        let remaining = pattern_arr.(!cur_idx) -. !in_idx in
        let next_t = min (!t +. remaining) t_end in
        let is_dash = (!cur_idx mod 2) = 0 in
        if is_dash && next_t > !t +. eps then begin
          match subpath_between anchors_walk cum !t next_t with
          | Some sub -> out := sub :: !out
          | None -> ()
        end;
        let consumed = next_t -. !t in
        in_idx := !in_idx +. consumed;
        if !in_idx >= pattern_arr.(!cur_idx) -. eps then begin
          in_idx := 0.0;
          cur_idx := (!cur_idx + 1) mod n_pat
        end;
        t := next_t
      end
    done;
    List.rev !out
  end

let expand_preserve subpath pattern =
  let anchors = anchor_points subpath in
  let anchors_walk =
    if is_closed subpath then
      match anchors with
      | [] -> []
      | first :: _ -> anchors @ [first]
    else anchors
  in
  match anchors_walk with
  | [] | [_] -> []
  | _ ->
    let seg_lengths =
      let rec pairs = function
        | a :: (b :: _ as rest) -> (seg_len a b) :: pairs rest
        | _ -> []
      in
      pairs anchors_walk
    in
    let cum = cumulative seg_lengths in
    let total = match List.rev cum with [] -> 0.0 | h :: _ -> h in
    if total <= 0.0 then []
    else emit_dashes anchors_walk cum pattern 0.0 0.0 total

(* ── Align mode ───────────────────────────────────────────────── *)

type boundary_kind = II | EE | EI | IE

let boundary_kind i n_segs closed =
  if closed then II
  else if n_segs = 1 then EE
  else if i = 0 then EI
  else if i = n_segs - 1 then IE
  else II

let solve_segment_scale seg_l pattern kind =
  let base_period = List.fold_left (+.) 0.0 pattern in
  let d0 = match pattern with d :: _ -> d | [] -> 0.0 in
  match kind with
  | II ->
    let m = max 1.0 (Float.round (seg_l /. base_period)) in
    seg_l /. (m *. base_period)
  | EE ->
    let m = max 0.0 (Float.round ((seg_l -. d0) /. base_period)) in
    let denom = m *. base_period +. d0 in
    if denom > 0.0 then seg_l /. denom else 1.0
  | EI | IE ->
    let m = max 1.0 (Float.round ((seg_l -. 0.5 *. d0) /. base_period)) in
    let denom = m *. base_period +. 0.5 *. d0 in
    if denom > 0.0 then seg_l /. denom else 1.0

let segment_dash_ranges seg_l pattern scale kind =
  let scaled = List.map (fun p -> p *. scale) pattern in
  let scaled_arr = Array.of_list scaled in
  let n_pat = Array.length scaled_arr in
  let period = List.fold_left (+.) 0.0 scaled in
  if period <= 0.0 || seg_l <= 0.0 then []
  else begin
    let half_d = scaled_arr.(0) *. 0.5 in
    let offset0 = match kind with EE | EI -> 0.0 | II | IE -> half_d in
    let (idx0, in0) = locate_in_pattern offset0 scaled in
    let cur_idx = ref idx0 in
    let in_idx = ref in0 in
    let t = ref 0.0 in
    let ranges = ref [] in
    let continue_loop = ref true in
    while !continue_loop do
      if !t >= seg_l -. eps then continue_loop := false
      else begin
        let remaining = scaled_arr.(!cur_idx) -. !in_idx in
        let next_t = min (!t +. remaining) seg_l in
        let is_dash = (!cur_idx mod 2) = 0 in
        if is_dash && next_t > !t +. eps then
          ranges := (!t, next_t) :: !ranges;
        let consumed = next_t -. !t in
        in_idx := !in_idx +. consumed;
        if !in_idx >= scaled_arr.(!cur_idx) -. eps then begin
          in_idx := 0.0;
          cur_idx := (!cur_idx + 1) mod n_pat
        end;
        t := next_t
      end
    done;
    List.rev !ranges
  end

let merge_adjacent_ranges ranges =
  let rec go acc = function
    | [] -> List.rev acc
    | r :: rest ->
      (match acc with
       | (s, e) :: tail when abs_float (e -. (fst r)) < eps ->
         go ((s, snd r) :: tail) rest
       | _ -> go (r :: acc) rest)
  in
  go [] ranges

let expand_align subpath pattern =
  let anchors = anchor_points subpath in
  let closed = is_closed subpath in
  let anchors_walk =
    if closed then
      match anchors with
      | [] -> []
      | first :: _ -> anchors @ [first]
    else anchors
  in
  let n_anchors = List.length anchors_walk in
  let n_segs = if n_anchors > 0 then n_anchors - 1 else 0 in
  if n_segs < 1 then []
  else begin
    let base_period = List.fold_left (+.) 0.0 pattern in
    if base_period <= 0.0 then []
    else begin
      let seg_lengths =
        let rec pairs = function
          | a :: (b :: _ as rest) -> (seg_len a b) :: pairs rest
          | _ -> []
        in
        pairs anchors_walk
      in
      if List.for_all (fun l -> l <= 0.0) seg_lengths then []
      else begin
        let cum = cumulative seg_lengths in
        let cum_arr = Array.of_list cum in
        let seg_arr = Array.of_list seg_lengths in
        let all_ranges = ref [] in
        for i = 0 to n_segs - 1 do
          let l_i = seg_arr.(i) in
          if l_i > 0.0 then begin
            let kind = boundary_kind i n_segs closed in
            let scale = solve_segment_scale l_i pattern kind in
            let local = segment_dash_ranges l_i pattern scale kind in
            let off = cum_arr.(i) in
            List.iter (fun (a, b) ->
              all_ranges := (a +. off, b +. off) :: !all_ranges
            ) local
          end
        done;
        let ranges = List.rev !all_ranges in
        let merged = merge_adjacent_ranges ranges in

        let merged =
          if closed && List.length merged >= 2 then begin
            let total = cum_arr.(Array.length cum_arr - 1) in
            let last = List.nth merged (List.length merged - 1) in
            let first = List.nth merged 0 in
            if abs_float (snd last -. total) < eps && abs_float (fst first) < eps then begin
              let wrapped = (fst last, snd first +. total) in
              let middle = List.filteri (fun i _ ->
                i > 0 && i < List.length merged - 1) merged in
              wrapped :: middle
            end else merged
          end else merged
        in
        List.filter_map (fun (gs, ge) ->
          subpath_between_wrapping anchors_walk cum gs ge closed
        ) merged
      end
    end
  end

(* ── Public entry ─────────────────────────────────────────────── *)

let expand_dashed_stroke path dash_array align_anchors =
  match path with
  | [] -> []
  | _ ->
    if dash_array = [] || List.for_all (fun v -> v = 0.0) dash_array then begin
      let has_non_move = List.exists (function MoveTo _ -> false | _ -> true) path in
      if has_non_move then [path] else []
    end else begin
      let pattern =
        if List.length dash_array mod 2 = 1 then dash_array @ dash_array
        else dash_array
      in
      let subpaths = split_at_moveto path in
      List.concat_map (fun sp ->
        if not (has_segments sp) then []
        else if align_anchors then expand_align sp pattern
        else expand_preserve sp pattern
      ) subpaths
    end
