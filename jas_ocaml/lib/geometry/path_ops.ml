(** Path-level operations: anchor insertion / deletion, eraser split,
    cubic/quad evaluation + projection. The OCaml analogue of
    [jas_dioxus/src/geometry/path_ops.rs] /
    [JasSwift/Sources/Geometry/PathOps.swift].

    L2 primitives per NATIVE_BOUNDARY.md §5 — path geometry is shared
    across vector-illustration apps. [Yaml_tool_effects]'s
    [doc.path.*] effects call into this module. *)

open Element

(* ── Basic helpers ───────────────────────────────────────── *)

(** Linear interpolation. *)
let lerp a b t = a +. t *. (b -. a)

(** Evaluate a cubic Bezier at parameter t. *)
let eval_cubic x0 y0 x1 y1 x2 y2 x3 y3 t =
  let mt = 1.0 -. t in
  let x = mt *. mt *. mt *. x0
        +. 3.0 *. mt *. mt *. t *. x1
        +. 3.0 *. mt *. t *. t *. x2
        +. t *. t *. t *. x3 in
  let y = mt *. mt *. mt *. y0
        +. 3.0 *. mt *. mt *. t *. y1
        +. 3.0 *. mt *. t *. t *. y2
        +. t *. t *. t *. y3 in
  (x, y)

(** Endpoint of a path command ([None] for [ClosePath]). *)
let cmd_endpoint = function
  | MoveTo (x, y) -> Some (x, y)
  | LineTo (x, y) -> Some (x, y)
  | CurveTo (_, _, _, _, x, y) -> Some (x, y)
  | QuadTo (_, _, x, y) -> Some (x, y)
  | SmoothCurveTo (_, _, x, y) -> Some (x, y)
  | SmoothQuadTo (x, y) -> Some (x, y)
  | ArcTo (_, _, _, _, _, x, y) -> Some (x, y)
  | ClosePath -> None

(** Build a parallel list of "pen position before each command". *)
let cmd_start_points (cmds : path_command list) : (float * float) list =
  let rec walk cur acc = function
    | [] -> List.rev acc
    | cmd :: rest ->
      let next = match cmd_endpoint cmd with Some p -> p | None -> cur in
      walk next (cur :: acc) rest
  in
  walk (0.0, 0.0) [] cmds

(** Start point of the command at [cmd_idx]. [(0, 0)] when
    [cmd_idx = 0] or the prior command has no endpoint. *)
let cmd_start_point (cmds : path_command list) (cmd_idx : int)
  : float * float =
  if cmd_idx <= 0 then (0.0, 0.0)
  else
    match List.nth_opt cmds (cmd_idx - 1) with
    | Some c -> (match cmd_endpoint c with Some p -> p | None -> (0.0, 0.0))
    | None -> (0.0, 0.0)

(* ── Flattening ──────────────────────────────────────────── *)

(** Flatten path commands into a polyline with a parallel cmd-index
    map. *)
let flatten_with_cmd_map (cmds : path_command list)
  : (float * float) list * int list =
  let steps = Element.flatten_steps in
  let pts = ref [] in
  let map = ref [] in
  let cx = ref 0.0 in
  let cy = ref 0.0 in
  List.iteri (fun cmd_idx cmd ->
    match cmd with
    | MoveTo (x, y) | LineTo (x, y) ->
      pts := (x, y) :: !pts; map := cmd_idx :: !map;
      cx := x; cy := y
    | CurveTo (x1, y1, x2, y2, x, y) ->
      for i = 1 to steps do
        let t = float_of_int i /. float_of_int steps in
        let mt = 1.0 -. t in
        let px = mt *. mt *. mt *. !cx
              +. 3.0 *. mt *. mt *. t *. x1
              +. 3.0 *. mt *. t *. t *. x2
              +. t *. t *. t *. x in
        let py = mt *. mt *. mt *. !cy
              +. 3.0 *. mt *. mt *. t *. y1
              +. 3.0 *. mt *. t *. t *. y2
              +. t *. t *. t *. y in
        pts := (px, py) :: !pts; map := cmd_idx :: !map
      done;
      cx := x; cy := y
    | QuadTo (x1, y1, x, y) ->
      for i = 1 to steps do
        let t = float_of_int i /. float_of_int steps in
        let mt = 1.0 -. t in
        let px = mt *. mt *. !cx +. 2.0 *. mt *. t *. x1 +. t *. t *. x in
        let py = mt *. mt *. !cy +. 2.0 *. mt *. t *. y1 +. t *. t *. y in
        pts := (px, py) :: !pts; map := cmd_idx :: !map
      done;
      cx := x; cy := y
    | ClosePath -> ()
    | _ ->
      (match cmd_endpoint cmd with
       | Some (ex, ey) ->
         pts := (ex, ey) :: !pts; map := cmd_idx :: !map;
         cx := ex; cy := ey
       | None -> ())
  ) cmds;
  (List.rev !pts, List.rev !map)

(* ── Projection ──────────────────────────────────────────── *)

(** Closest-point projection onto a line segment.
    Returns [(distance, t)]. *)
let closest_on_line x0 y0 x1 y1 px py =
  let dx = x1 -. x0 and dy = y1 -. y0 in
  let len_sq = dx *. dx +. dy *. dy in
  if len_sq = 0.0 then
    let d = Float.sqrt ((px -. x0) *. (px -. x0) +. (py -. y0) *. (py -. y0)) in
    (d, 0.0)
  else
    let t = ((px -. x0) *. dx +. (py -. y0) *. dy) /. len_sq in
    let t = Float.max 0.0 (Float.min 1.0 t) in
    let qx = x0 +. t *. dx and qy = y0 +. t *. dy in
    let d = Float.sqrt ((px -. qx) *. (px -. qx) +. (py -. qy) *. (py -. qy)) in
    (d, t)

(** Closest-point projection onto a cubic. 50-sample coarse + 20-iter
    trisection refinement. *)
let closest_on_cubic x0 y0 x1 y1 x2 y2 x3 y3 px py =
  let steps = 50 in
  let best_dist = ref Float.infinity in
  let best_t = ref 0.0 in
  for i = 0 to steps do
    let t = float_of_int i /. float_of_int steps in
    let (bx, by) = eval_cubic x0 y0 x1 y1 x2 y2 x3 y3 t in
    let d = Float.sqrt ((px -. bx) *. (px -. bx) +. (py -. by) *. (py -. by)) in
    if d < !best_dist then begin
      best_dist := d; best_t := t
    end
  done;
  let lo = ref (Float.max (!best_t -. 1.0 /. float_of_int steps) 0.0) in
  let hi = ref (Float.min (!best_t +. 1.0 /. float_of_int steps) 1.0) in
  for _ = 0 to 19 do
    let t1 = !lo +. (!hi -. !lo) /. 3.0 in
    let t2 = !hi -. (!hi -. !lo) /. 3.0 in
    let (bx1, by1) = eval_cubic x0 y0 x1 y1 x2 y2 x3 y3 t1 in
    let (bx2, by2) = eval_cubic x0 y0 x1 y1 x2 y2 x3 y3 t2 in
    let d1 = Float.sqrt ((px -. bx1) *. (px -. bx1) +. (py -. by1) *. (py -. by1)) in
    let d2 = Float.sqrt ((px -. bx2) *. (px -. bx2) +. (py -. by2) *. (py -. by2)) in
    if d1 < d2 then hi := t2 else lo := t1
  done;
  best_t := (!lo +. !hi) /. 2.0;
  let (bx, by) = eval_cubic x0 y0 x1 y1 x2 y2 x3 y3 !best_t in
  best_dist := Float.sqrt ((px -. bx) *. (px -. bx) +. (py -. by) *. (py -. by));
  (!best_dist, !best_t)

(** Find which segment of [d] is closest to [(px, py)].
    Returns [Some (cmd_idx, t)] or [None] if no drawable segments. *)
let closest_segment_and_t (d : path_command list) (px : float) (py : float)
  : (int * float) option =
  let best_dist = ref Float.infinity in
  let best_seg = ref 0 in
  let best_t = ref 0.0 in
  let cx = ref 0.0 and cy = ref 0.0 in
  List.iteri (fun i cmd ->
    match cmd with
    | MoveTo (x, y) -> cx := x; cy := y
    | LineTo (x, y) ->
      let (dist, t) = closest_on_line !cx !cy x y px py in
      if dist < !best_dist then begin
        best_dist := dist; best_seg := i; best_t := t
      end;
      cx := x; cy := y
    | CurveTo (x1, y1, x2, y2, x, y) ->
      let (dist, t) = closest_on_cubic !cx !cy x1 y1 x2 y2 x y px py in
      if dist < !best_dist then begin
        best_dist := dist; best_seg := i; best_t := t
      end;
      cx := x; cy := y
    | _ -> ()
  ) d;
  if Float.is_finite !best_dist then Some (!best_seg, !best_t) else None

(* ── Splitting ───────────────────────────────────────────── *)

(** Split a cubic at [t]. Returns [(first, second)] where each is a
    tuple of [(x1, y1, x2, y2, x, y)] — control handles + end point. *)
let split_cubic x0 y0 x1 y1 x2 y2 x3 y3 t =
  let a1x = lerp x0 x1 t and a1y = lerp y0 y1 t in
  let a2x = lerp x1 x2 t and a2y = lerp y1 y2 t in
  let a3x = lerp x2 x3 t and a3y = lerp y2 y3 t in
  let b1x = lerp a1x a2x t and b1y = lerp a1y a2y t in
  let b2x = lerp a2x a3x t and b2y = lerp a2y a3y t in
  let mx = lerp b1x b2x t and my = lerp b1y b2y t in
  ((a1x, a1y, b1x, b1y, mx, my),
   (b2x, b2y, a3x, a3y, x3, y3))

(** Split a cubic command at t, returning two [CurveTo] commands. *)
let split_cubic_cmd_at p0 x1 y1 x2 y2 x y t =
  let (px, py) = p0 in
  let (first, second) = split_cubic px py x1 y1 x2 y2 x y t in
  let (a1x, a1y, b1x, b1y, mx, my) = first in
  let (c1x, c1y, c2x, c2y, ex, ey) = second in
  (CurveTo (a1x, a1y, b1x, b1y, mx, my),
   CurveTo (c1x, c1y, c2x, c2y, ex, ey))

(** Split a quad command at t, returning two [QuadTo] commands. *)
let split_quad_cmd_at p0 qx qy x y t =
  let (px, py) = p0 in
  let ax = lerp px qx t and ay = lerp py qy t in
  let bx = lerp qx x t and by = lerp qy y t in
  let cx = lerp ax bx t and cy = lerp ay by t in
  (QuadTo (ax, ay, cx, cy),
   QuadTo (bx, by, x, y))

(* ── Anchor deletion ─────────────────────────────────────── *)

let count_anchors (d : path_command list) : int =
  List.fold_left (fun acc cmd ->
    match cmd with MoveTo _ | LineTo _ | CurveTo _ -> acc + 1
    | _ -> acc
  ) 0 d

(** Delete the anchor at [anchor_idx] from [d]. Returns [None] if
    the result would have < 2 anchors. Interior deletion merges
    adjacent segments preserving outer handles. *)
let delete_anchor_from_path (d : path_command list) (anchor_idx : int)
  : path_command list option =
  let n = List.length d in
  if count_anchors d <= 2 then None
  else if anchor_idx = 0 then begin
    if n < 2 then None
    else
      match List.nth d 1 with
      | LineTo (nx, ny) ->
        Some (MoveTo (nx, ny) :: (List.filteri (fun i _ -> i >= 2) d))
      | CurveTo (_, _, _, _, nx, ny) ->
        Some (MoveTo (nx, ny) :: (List.filteri (fun i _ -> i >= 2) d))
      | _ -> None
  end
  else begin
    let last_cmd_idx = n - 1 in
    let has_close = (match List.nth d last_cmd_idx with ClosePath -> true | _ -> false) in
    let effective_last = if has_close then max (last_cmd_idx - 1) 0 else last_cmd_idx in
    if anchor_idx = effective_last then begin
      (* Trim trailing segment, keep any ClosePath. *)
      let prefix = List.filteri (fun i _ -> i < anchor_idx) d in
      let result = if effective_last < last_cmd_idx
        then prefix @ [ClosePath] else prefix
      in
      Some result
    end
    else begin
      (* Interior: merge this command with the next. *)
      let cmd_at = List.nth d anchor_idx in
      let cmd_after = List.nth d (anchor_idx + 1) in
      let merged = match cmd_at, cmd_after with
        | CurveTo (x1, y1, _, _, _, _),
          CurveTo (_, _, x2, y2, x, y) ->
          Some (CurveTo (x1, y1, x2, y2, x, y))
        | CurveTo (x1, y1, _, _, _, _),
          LineTo (x, y) ->
          Some (CurveTo (x1, y1, x, y, x, y))
        | LineTo _,
          CurveTo (_, _, x2, y2, x, y) ->
          let (px, py) =
            if anchor_idx > 0 then
              match cmd_endpoint (List.nth d (anchor_idx - 1)) with
              | Some p -> p | None -> (0.0, 0.0)
            else (0.0, 0.0)
          in
          Some (CurveTo (px, py, x2, y2, x, y))
        | LineTo _, LineTo (x, y) -> Some (LineTo (x, y))
        | _ -> None
      in
      let result = List.mapi (fun i c -> (i, c)) d
        |> List.filter_map (fun (i, c) ->
          if i = anchor_idx then merged
          else if i = anchor_idx + 1 then None
          else Some c)
      in
      Some result
    end
  end

(* ── Anchor insertion ────────────────────────────────────── *)

type insert_anchor_result = {
  commands : path_command list;
  first_new_idx : int;
  anchor_x : float;
  anchor_y : float;
}

(** Insert an anchor at parameter [t] along the segment at [seg_idx]. *)
let insert_point_in_path (d : path_command list) (seg_idx : int) (t : float)
  : insert_anchor_result =
  let result = ref [] in
  let cx = ref 0.0 and cy = ref 0.0 in
  let first_new_idx = ref 0 in
  let anchor_x = ref 0.0 and anchor_y = ref 0.0 in
  let idx = ref 0 in
  List.iter (fun cmd ->
    let i = !idx in
    if i = seg_idx then begin
      match cmd with
      | CurveTo (x1, y1, x2, y2, x, y) ->
        let (first, second) = split_cubic !cx !cy x1 y1 x2 y2 x y t in
        let (a1x, a1y, b1x, b1y, mx, my) = first in
        let (c1x, c1y, c2x, c2y, ex, ey) = second in
        first_new_idx := List.length !result;
        anchor_x := mx; anchor_y := my;
        result := !result @ [
          CurveTo (a1x, a1y, b1x, b1y, mx, my);
          CurveTo (c1x, c1y, c2x, c2y, ex, ey);
        ];
        cx := x; cy := y
      | LineTo (x, y) ->
        let mx = lerp !cx x t and my = lerp !cy y t in
        first_new_idx := List.length !result;
        anchor_x := mx; anchor_y := my;
        result := !result @ [LineTo (mx, my); LineTo (x, y)];
        cx := x; cy := y
      | _ ->
        (match cmd with
         | MoveTo (x, y) | LineTo (x, y) -> cx := x; cy := y
         | CurveTo (_, _, _, _, x, y) -> cx := x; cy := y
         | _ -> ());
        result := !result @ [cmd]
    end
    else begin
      (match cmd with
       | MoveTo (x, y) | LineTo (x, y) -> cx := x; cy := y
       | CurveTo (_, _, _, _, x, y) -> cx := x; cy := y
       | _ -> ());
      result := !result @ [cmd]
    end;
    incr idx
  ) d;
  { commands = !result;
    first_new_idx = !first_new_idx;
    anchor_x = !anchor_x;
    anchor_y = !anchor_y }

(* ── Liang-Barsky (eraser clipping) ──────────────────────── *)

let liang_barsky_t_min x1 y1 x2 y2 min_x min_y max_x max_y =
  let dx = x2 -. x1 and dy = y2 -. y1 in
  let t_min = ref 0.0 in
  let edges = [
    (-. dx, x1 -. min_x); (dx, max_x -. x1);
    (-. dy, y1 -. min_y); (dy, max_y -. y1);
  ] in
  List.iter (fun (p, q) ->
    if Float.abs p >= 1e-12 && p < 0.0 then
      t_min := Float.max !t_min (q /. p)
  ) edges;
  Float.max 0.0 (Float.min 1.0 !t_min)

let liang_barsky_t_max x1 y1 x2 y2 min_x min_y max_x max_y =
  let dx = x2 -. x1 and dy = y2 -. y1 in
  let t_max = ref 1.0 in
  let edges = [
    (-. dx, x1 -. min_x); (dx, max_x -. x1);
    (-. dy, y1 -. min_y); (dy, max_y -. y1);
  ] in
  List.iter (fun (p, q) ->
    if Float.abs p >= 1e-12 && p > 0.0 then
      t_max := Float.min !t_max (q /. p)
  ) edges;
  Float.max 0.0 (Float.min 1.0 !t_max)

let line_segment_intersects_rect x1 y1 x2 y2 min_x min_y max_x max_y =
  if x1 >= min_x && x1 <= max_x && y1 >= min_y && y1 <= max_y then true
  else if x2 >= min_x && x2 <= max_x && y2 >= min_y && y2 <= max_y then true
  else begin
    let t_min = ref 0.0 and t_max = ref 1.0 in
    let dx = x2 -. x1 and dy = y2 -. y1 in
    let edges = [
      (-. dx, x1 -. min_x); (dx, max_x -. x1);
      (-. dy, y1 -. min_y); (dy, max_y -. y1);
    ] in
    try
      List.iter (fun (p, q) ->
        if Float.abs p < 1e-12 then begin
          if q < 0.0 then raise Exit
        end
        else begin
          let t = q /. p in
          if p < 0.0 then t_min := Float.max !t_min t
          else t_max := Float.min !t_max t;
          if !t_min > !t_max then raise Exit
        end
      ) edges;
      true
    with Exit -> false
  end

(* ── Eraser (findEraserHit + splitPathAtEraser) ──────────── *)

type eraser_hit = {
  first_flat_idx : int;
  last_flat_idx : int;
  entry_t_seg : float;
  entry : float * float;
  exit_t_seg : float;
  exit_pt : float * float;
}

(** Walk the flattened polyline and return the first contiguous run
    of segments that intersect the rect, plus exact entry/exit points. *)
let find_eraser_hit (flat : (float * float) list)
    (min_x : float) (min_y : float) (max_x : float) (max_y : float)
  : eraser_hit option =
  let flat_arr = Array.of_list flat in
  let n = Array.length flat_arr in
  if n < 2 then None
  else begin
    let first_hit = ref (-1) in
    let last_hit = ref (-1) in
    (try
      for i = 0 to n - 2 do
        let (x1, y1) = flat_arr.(i) in
        let (x2, y2) = flat_arr.(i + 1) in
        if line_segment_intersects_rect x1 y1 x2 y2 min_x min_y max_x max_y then begin
          if !first_hit < 0 then first_hit := i;
          last_hit := i
        end
        else if !first_hit >= 0 then raise Exit
      done
    with Exit -> ());
    if !first_hit < 0 then None
    else begin
      let (ex1, ey1) = flat_arr.(!first_hit) in
      let (ex2, ey2) = flat_arr.(!first_hit + 1) in
      let entry_t_seg =
        if ex1 >= min_x && ex1 <= max_x && ey1 >= min_y && ey1 <= max_y then 0.0
        else liang_barsky_t_min ex1 ey1 ex2 ey2 min_x min_y max_x max_y
      in
      let entry = (ex1 +. entry_t_seg *. (ex2 -. ex1),
                   ey1 +. entry_t_seg *. (ey2 -. ey1)) in
      let (lx1, ly1) = flat_arr.(!last_hit) in
      let (lx2, ly2) = flat_arr.(!last_hit + 1) in
      let exit_t_seg =
        if lx2 >= min_x && lx2 <= max_x && ly2 >= min_y && ly2 <= max_y then 1.0
        else liang_barsky_t_max lx1 ly1 lx2 ly2 min_x min_y max_x max_y
      in
      let exit_pt = (lx1 +. exit_t_seg *. (lx2 -. lx1),
                     ly1 +. exit_t_seg *. (ly2 -. ly1)) in
      Some { first_flat_idx = !first_hit;
             last_flat_idx = !last_hit;
             entry_t_seg; entry; exit_t_seg; exit_pt }
    end
  end

(** Map a (flatIdx, tOnSeg) pair back to (cmd_idx, t) on the
    original command list. *)
let flat_index_to_cmd_and_t (cmds : path_command list)
    (flat_idx : int) (t_on_seg : float) : int * float =
  let steps = Element.flatten_steps in
  let flat_count = ref 0 in
  let result = ref (max 0 (List.length cmds - 1), 1.0) in
  let idx = ref 0 in
  (try
    List.iter (fun cmd ->
      let segs = match cmd with
        | MoveTo _ -> 0
        | LineTo _ -> 1
        | CurveTo _ | QuadTo _ -> steps
        | ClosePath -> 1
        | _ -> 1
      in
      if segs > 0 && flat_idx < !flat_count + segs then begin
        let local = flat_idx - !flat_count in
        let t = (float_of_int local +. t_on_seg) /. float_of_int segs in
        let t = Float.max 0.0 (Float.min 1.0 t) in
        result := (!idx, t);
        raise Exit
      end;
      flat_count := !flat_count + segs;
      incr idx
    ) cmds
  with Exit -> ());
  !result

(** First half of a command split at [t]. *)
let entry_cmd (cmd : path_command) (start : float * float) (t : float)
  : path_command =
  match cmd with
  | CurveTo (x1, y1, x2, y2, x, y) ->
    fst (split_cubic_cmd_at start x1 y1 x2 y2 x y t)
  | QuadTo (qx, qy, x, y) ->
    fst (split_quad_cmd_at start qx qy x y t)
  | _ ->
    let (sx, sy) = start in
    let (ex, ey) = match cmd_endpoint cmd with
      | Some p -> p | None -> start in
    LineTo (sx +. t *. (ex -. sx), sy +. t *. (ey -. sy))

(** Second half of a command split at [t]. *)
let exit_cmd (cmd : path_command) (start : float * float) (t : float)
  : path_command =
  match cmd with
  | CurveTo (x1, y1, x2, y2, x, y) ->
    snd (split_cubic_cmd_at start x1 y1 x2 y2 x y t)
  | QuadTo (qx, qy, x, y) ->
    snd (split_quad_cmd_at start qx qy x y t)
  | _ ->
    let (ex, ey) = match cmd_endpoint cmd with
      | Some p -> p | None -> start in
    LineTo (ex, ey)

(** Cut [cmds] at the eraser hit. Open paths produce 0–2 sub-paths;
    closed paths are unwrapped into a single open path. *)
let split_path_at_eraser (cmds : path_command list) (hit : eraser_hit)
    (is_closed : bool) : path_command list list =
  let (entry_cmd_idx, entry_t) =
    flat_index_to_cmd_and_t cmds hit.first_flat_idx hit.entry_t_seg in
  let (exit_cmd_idx, exit_t) =
    flat_index_to_cmd_and_t cmds hit.last_flat_idx hit.exit_t_seg in
  let starts = cmd_start_points cmds in
  let cmd_at_idx i = List.nth cmds i in
  let start_at_idx i = List.nth starts i in

  if is_closed then begin
    let drawing = List.mapi (fun i c -> (i, c)) cmds
      |> List.filter (fun (_, c) -> c <> ClosePath) in
    if drawing = [] then []
    else begin
      let (exx, exy) = hit.exit_pt in
      let (enx, eny) = hit.entry in
      let open_cmds = ref [MoveTo (exx, exy)] in
      if exit_t < 1.0 -. 1e-9 then begin
        match List.find_opt (fun (i, _) -> i = exit_cmd_idx) drawing with
        | Some (orig_idx, cmd) ->
          open_cmds := !open_cmds @ [exit_cmd cmd (start_at_idx orig_idx) exit_t]
        | None -> ()
      end;
      let resume_from = exit_cmd_idx + 1 in
      List.iter (fun (orig_idx, cmd) ->
        if orig_idx >= resume_from && orig_idx < List.length cmds then
          open_cmds := !open_cmds @ [cmd]
      ) drawing;
      (match drawing with
       | (_, MoveTo (mx, my)) :: _ -> open_cmds := !open_cmds @ [LineTo (mx, my)]
       | _ -> ());
      List.iter (fun (orig_idx, cmd) ->
        if orig_idx >= 1 && orig_idx < entry_cmd_idx then
          open_cmds := !open_cmds @ [cmd]
      ) drawing;
      if entry_t > 1e-9 then
        open_cmds := !open_cmds @
          [entry_cmd (cmd_at_idx entry_cmd_idx) (start_at_idx entry_cmd_idx) entry_t]
      else
        open_cmds := !open_cmds @ [LineTo (enx, eny)];
      if List.length !open_cmds >= 2 then [!open_cmds] else []
    end
  end
  else begin
    let part1 = ref [] and part2 = ref [] in
    List.iteri (fun i c ->
      if i < entry_cmd_idx then part1 := !part1 @ [c]
    ) cmds;
    (if entry_t > 1e-9 then
      part1 := !part1 @
        [entry_cmd (cmd_at_idx entry_cmd_idx) (start_at_idx entry_cmd_idx) entry_t]
    else begin
      let (enx, eny) = hit.entry in
      part1 := !part1 @ [LineTo (enx, eny)]
    end);
    let (exx, exy) = hit.exit_pt in
    part2 := !part2 @ [MoveTo (exx, exy)];
    if exit_t < 1.0 -. 1e-9 then
      part2 := !part2 @
        [exit_cmd (cmd_at_idx exit_cmd_idx) (start_at_idx exit_cmd_idx) exit_t];
    if exit_cmd_idx + 1 < List.length cmds then
      List.iteri (fun i c ->
        if i > exit_cmd_idx && c <> ClosePath then part2 := !part2 @ [c]
      ) cmds;
    let result = ref [] in
    let part1_has_non_move = List.exists
      (fun c -> match c with MoveTo _ -> false | _ -> true) !part1 in
    if List.length !part1 >= 2 && part1_has_non_move then
      result := !result @ [!part1];
    if List.length !part2 >= 2 then
      result := !result @ [!part2];
    !result
  end

(* ── Path ↔ PolygonSet adapters ─────────────────────────── *)
(*
   Blob Brush's commit path needs to hand [path_command] geometry to
   the [Boolean] module (which speaks in [polygon_set] / [ring] terms)
   and then convert the unioned or subtracted result back to a
   [path_command list] for the new element's [d] field. The algorithm
   module is deliberately geometry-only; this pair is the
   element-level bridge.

   [Boolean.polygon_set] is [ring list], [ring] is [(float * float)
   array] — same shape as [Live.flatten_path_to_rings], which we reuse
   verbatim for the forward direction. The reverse direction emits
   [MoveTo + LineTo* + ClosePath] per ring. *)

let path_to_polygon_set d =
  Live.flatten_path_to_rings d

let polygon_set_to_path ps =
  List.concat_map (fun ring ->
    let n = Array.length ring in
    if n < 3 then []
    else begin
      let (x0, y0) = ring.(0) in
      let rest = ref [] in
      for i = n - 1 downto 1 do
        let (xi, yi) = ring.(i) in
        rest := LineTo (xi, yi) :: !rest
      done;
      MoveTo (x0, y0) :: !rest @ [ClosePath]
    end) ps
